#!/bin/bash

# ==========================================
# Turnip Vulkan 驱动层 DrawCall 模型矩阵提取 (修复版)
# ==========================================

green='\033[0;32m'
red='\033[0;31m'
nocolor='\033[0m'
workdir="$(pwd)/turnip_workdir"
magiskdir="$workdir/turnip_module"
ndkver="android-ndk-r28"
ndk="$workdir/$ndkver/toolchains/llvm/prebuilt/linux-x86_64/bin"
sdkver="34"
mesasrc="https://gitlab.freedesktop.org/mesa/mesa/-/archive/main/mesa-main.zip"

run_all(){
    check_deps
    prepare_workdir
    inject_custom_code
    build_lib_for_android
    port_lib_for_magisk
    port_lib_for_adrenotools
    echo -e "${green}======================================${nocolor}"
    echo -e "${green}编译完成！${nocolor}"
    echo -e "${green}Magisk 模块: $workdir/turnip_magisk.zip${nocolor}"
    echo -e "${green}AdrenoTools 驱动: $workdir/turnip_adrenotools.zip${nocolor}"
    echo -e "${green}======================================${nocolor}"
}

check_deps(){
    echo -e "${green}[1/6] 检查依赖...${nocolor}"
    sudo apt-get update -qq
    sudo apt-get install -y glslang-tools python3-pip zip unzip curl patchelf ccache
    pip install mako &> /dev/null
}

prepare_workdir(){
    echo -e "${green}[2/6] 准备源码...${nocolor}"
    mkdir -p "$workdir" && cd "$_"
    if [ ! -d "$ndkver" ]; then
        curl -L https://dl.google.com/android/repository/"$ndkver"-linux.zip --output "$ndkver"-linux.zip &> /dev/null
        unzip -q "$ndkver"-linux.zip &> /dev/null
    fi
    if [ ! -d "mesa-main" ]; then
        curl -L "$mesasrc" --output mesa-main.zip &> /dev/null
        unzip -q mesa-main.zip &> /dev/null
    fi
}

# ================= 核心：在绘制时抓取模型矩阵 =================
inject_custom_code(){
    echo -e "${green}[3/6] 注入 DrawCall 模型提取代码...${nocolor}"
    
    cat << 'PYEOF' > /tmp/inject.py
import sys

file_path = 'src/freedreno/vulkan/tu_cmd_buffer.cc'
with open(file_path, 'r') as f:
    content = f.read()

# 补齐头文件
if '#include <math.h>' not in content:
    content = content.replace('#include "tu_cmd_buffer.h"', '#include "tu_cmd_buffer.h"\n#include <stdio.h>\n#include <time.h>\n#include <stdint.h>\n#include <stdlib.h>\n#include <math.h>')

# ================= 拦截 tu_CmdDrawIndexed =================
draw_hook_code = r'''
   // ======== 提取 DrawCall 时的模型矩阵 ========
   static long last_draw_sec = 0;
   struct timespec now_draw;
   clock_gettime(CLOCK_MONOTONIC, &now_draw);
   
   // 限制频率：1秒抓一次，只抓大模型（过滤掉UI和简单特效）
   if (now_draw.tv_sec != last_draw_sec && indexCount > 1000) {
       last_draw_sec = now_draw.tv_sec;
       
       FILE *fp = fopen("/sdcard/ue4_models.txt", "a");
       if (fp) {
           fprintf(fp, "\n[DrawIndexed] IndexCount: %u | InstanceCount: %u\n", indexCount, instanceCount);
           
           // 获取当前绑定的描述符集 (存放模型矩阵的地方)
           struct tu_descriptor_state *desc_state = tu_get_descriptors_state(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS);
           
           for (uint32_t s = 0; s < desc_state->max_sets_bound; s++) {
               struct tu_descriptor_set *set = desc_state->sets[s];
               if (!set) continue;
               
               for (uint32_t b = 0; b < set->layout->binding_count; b++) {
                   struct tu_descriptor_set_binding_layout *binding = &set->layout->binding[b];
                   
                   // 找 UBO 或 SSBO
                   if (binding->type == VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER || 
                       binding->type == VK_DESCRIPTOR_TYPE_STORAGE_BUFFER) {
                       
                       // 如果这块内存 CPU 可读，直接暴力提取
                       if (set->mapped_ptr) {
                           float *data = (float *)((char*)set->mapped_ptr + binding->offset);
                           
                           fprintf(fp, "  Set[%u] Bind[%u] Data:\n", s, b);
                           // 打印前 16 个 float (一个 4x4 矩阵)
                           for (int k = 0; k < 16; k++) {
                               if (isfinite(data[k]) && fabs(data[k]) < 100000.0f) {
                                   fprintf(fp, "%8.2f ", data[k]);
                               } else {
                                   fprintf(fp, " [BUF]  ");
                               }
                               if ((k + 1) % 4 == 0) fprintf(fp, "\n");
                           }
                       }
                   }
               }
           }
           fclose(fp);
       }
   }
'''

target_draw = 'tu_CmdDrawIndexed('
start_idx = content.find(target_draw)
if start_idx != -1:
    # 寻找函数体内的 VK_FROM_HANDLE 宏，它定义了 cmd 变量
    handle_str = 'VK_FROM_HANDLE(tu_cmd_buffer, cmd, commandBuffer);'
    handle_idx = content.find(handle_str, start_idx)
    
    if handle_idx != -1:
        # 将代码插在 VK_FROM_HANDLE 之后
        insert_idx = handle_idx + len(handle_str)
        content = content[:insert_idx] + '\n' + draw_hook_code + content[insert_idx:]
        print('✅ CmdDrawIndexed 模型矩阵注入成功！')
    else:
        print('❌ 找不到 VK_FROM_HANDLE，注入失败')
else:
    print('❌ 找不到 tu_CmdDrawIndexed')

with open(file_path, 'w') as f:
    f.write(content)
PYEOF

    cd "$workdir/mesa-main"
    python3 /tmp/inject.py
    cd "$workdir"
}

build_lib_for_android(){
    echo -e "${green}[4/6] 编译驱动...${nocolor}"
    cd "$workdir/mesa-main"
    
    mkdir -p "$workdir/bin"
    ln -sf "$ndk/clang" "$workdir/bin/cc"
    ln -sf "$ndk/clang++" "$workdir/bin/c++"
    export PATH="$workdir/bin:$ndk:$PATH"
    export CC=clang
    export CXX=clang++
    export AR=llvm-ar
    export LDFLAGS="-fuse-ld=lld"

    cat <<EOF >"android-aarch64.txt"
[binaries]
ar = '$ndk/llvm-ar'
c = ['ccache', '$ndk/aarch64-linux-android$sdkver-clang']
cpp = ['ccache', '$ndk/aarch64-linux-android$sdkver-clang++', '-fno-exceptions', '-fno-unwind-tables', '-fno-asynchronous-unwind-tables', '--start-no-unused-arguments', '-static-libstdc++', '--end-no-unused-arguments']
c_ld = '$ndk/ld.lld'
cpp_ld = '$ndk/ld.lld'
strip = '$ndk/aarch64-linux-android-strip'
pkg-config = ['env', 'PKG_CONFIG_LIBDIR=$ndk/pkg-config', '/usr/bin/pkg-config']
[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'armv8'
endian = 'little'
EOF

    cat <<EOF >"native.txt"
[build_machine]
c = ['ccache', 'clang']
cpp = ['ccache', 'clang++']
ar = 'llvm-ar'
strip = 'llvm-strip'
c_ld = 'ld.lld'
cpp_ld = 'ld.lld'
system = 'linux'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'
EOF

    set +e
    meson setup build-android-aarch64 --cross-file "android-aarch64.txt" --native-file "native.txt" \
        -Dbuildtype=release -Dplatforms=android -Dplatform-sdk-version="$sdkver" \
        -Dandroid-stub=true -Dgallium-drivers= -Dvulkan-drivers=freedreno \
        -Dfreedreno-kmds=kgsl -Dstrip=true -Degl=disabled &> "$workdir/meson_log"
    
    if [ $? -ne 0 ]; then 
        echo -e "${red}Meson 配置失败！日志如下：${nocolor}"
        cat "$workdir/meson_log"
        exit 1
    fi
    
    ninja -C build-android-aarch64 &> "$workdir/ninja_log"
    if [ $? -ne 0 ]; then 
        echo -e "${red}Ninja 编译失败！日志如下：${nocolor}"
        tail -n 50 "$workdir/ninja_log"
        exit 1
    fi
    set -e
}

port_lib_for_magisk(){
    echo -e "${green}[5/6] 打包 Magisk 模块...${nocolor}"
    cd "$workdir"
    cp mesa-main/build-android-aarch64/src/freedreno/vulkan/libvulkan_freedreno.so .
    patchelf --set-soname vulkan.adreno.so libvulkan_freedreno.so
    mv libvulkan_freedreno.so vulkan.adreno.so
    
    p1="system/vendor/lib64/hw"
    rm -rf "$magiskdir"
    mkdir -p "$magiskdir/$p1" && cd "$magiskdir"
    
    cat <<EOF >"module.prop"
id=turnip_hook
name=Turnip Hook
version=1.0
versionCode=1
author=You
description=Custom Turnip Model Hook
EOF
    cat <<EOF >"customize.sh"
set_perm_recursive \$MODPATH/system 0 0 755 u:object_r:system_file:s0
set_perm_recursive \$MODPATH/system/vendor 0 2000 755 u:object_r:vendor_file:s0
set_perm \$MODPATH/$p1/vulkan.adreno.so 0 0 0644 u:object_r:same_process_hal_file:s0
EOF
    cp "$workdir/vulkan.adreno.so" "$magiskdir/$p1/"
    zip -r "$workdir/turnip_magisk.zip" ./* &> /dev/null
}

port_lib_for_adrenotools(){
    echo -e "${green}[6/6] 打包 AdrenoTools 驱动...${nocolor}"
    libname="vulkan.freedreno.so"
    cd "$workdir"
    cp mesa-main/build-android-aarch64/src/freedreno/vulkan/libvulkan_freedreno.so ./$libname
    patchelf --set-soname $libname $libname
    
    cat <<EOF > "meta.json"
{
    "schemaVersion": 1,
    "name": "TurnipHook",
    "author": "Me",
    "packageVersion": "1",
    "vendor": "Mesa",
    "driverVersion": "1.0",
    "minApi": 34,
    "libraryName": "$libname"
}
EOF
    zip -9 "$workdir/turnip_adrenotools.zip" $libname meta.json &> /dev/null
    rm -f $libname meta.json
}

run_all
