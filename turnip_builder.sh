#!/bin/bash

# ==========================================
# Turnip Vulkan 驱动顶点明文提取构建脚本
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

# ================= 核心：暴力提取顶点明文 =================
inject_custom_code(){
    echo -e "${green}[3/6] 注入顶点明文提取代码...${nocolor}"
    
    cat << 'PYEOF' > /tmp/inject.py
import sys
import re

file_path = 'src/freedreno/vulkan/tu_cmd_buffer.cc'
with open(file_path, 'r') as f:
    content = f.read()

# 补齐头文件
if '#include <math.h>' not in content:
    content = content.replace('#include "tu_cmd_buffer.h"', '#include "tu_cmd_buffer.h"\n#include <stdio.h>\n#include <time.h>\n#include <stdint.h>\n#include <stdlib.h>\n#include <math.h>')

# ================= 拦截 1：抓取顶点缓冲区的真实明文数据 =================
vb_hook_code = r'''
   // ======== 提取 Vertex Buffer 裸数据 ========
   static long last_vb_sec = 0;
   struct timespec now_vb;
   clock_gettime(CLOCK_MONOTONIC, &now_vb);

   // 限制 1 秒写一次，防止卡死手机
   if (now_vb.tv_sec != last_vb_sec) {
       last_vb_sec = now_vb.tv_sec;
       
       for (uint32_t i = 0; i < bindingCount; i++) {
           if (pBuffers[i] != VK_NULL_HANDLE) {
               VK_FROM_HANDLE(tu_buffer, buf, pBuffers[i]);
               if (buf && buf->bo) {
                   // 只抓取比较大的 Buffer，过滤掉 UI 小模型
                   if (buf->vk.size > 20000) {
                       FILE *fp = fopen("/sdcard/ue4_vertex_dump.txt", "a");
                       if (fp) {
                           fprintf(fp, "\n[VB] Size: %llu | IOVA: 0x%llx | map: %p\n", 
                                   (unsigned long long)buf->vk.size, 
                                   (unsigned long long)buf->bo->iova, 
                                   buf->bo->map);
                           
                           // 如果 CPU 可以直接读（Host Visible），直接 dump 前 200 个 float 看看
                           // 注意：如果是纯显存，map 会为 null，此时强行读会闪退！
                           if (buf->bo->map) {
                               float *data = (float *)buf->bo->map;
                               int dump_count = (buf->vk.size / 4 < 200) ? (buf->vk.size / 4) : 200;
                               for (int k = 0; k < dump_count; k++) {
                                   // 过滤掉 NaN 和天文数字
                                   if (isfinite(data[k]) && fabs(data[k]) < 100000.0f) {
                                       fprintf(fp, "%10.3f ", data[k]);
                                   } else {
                                       fprintf(fp, "  [BUF]  ");
                                   }
                                   if ((k+1) % 4 == 0) fprintf(fp, "\n");
                               }
                               fprintf(fp, "\n");
                           }
                           fclose(fp);
                       }
                   }
               }
           }
       }
   }
'''
target_vb = 'tu_CmdBindVertexBuffers2('
start_idx = content.find(target_vb)
if start_idx != -1:
    brace_idx = content.find('{', start_idx)
    content = content[:brace_idx+1] + vb_hook_code + content[brace_idx+1:]
    print('✅ VertexBuffer 注入成功！')

# ================= 拦截 2：记录绘制特征，辅助定位敌人 =================
draw_hook_code = r'''
   // ======== 记录 DrawCall 特征 ========
   static long last_draw_sec = 0;
   struct timespec now_draw;
   clock_gettime(CLOCK_MONOTONIC, &now_draw);

   if (now_draw.tv_sec != last_draw_sec) {
       last_draw_sec = now_draw.tv_sec;
       // 人物模型通常在 1000 ~ 50000 个索引之间
       if (indexCount > 1000 && indexCount < 100000) {
           FILE *fp = fopen("/sdcard/ue4_draw_dump.txt", "a");
           if (fp) {
               fprintf(fp, "DrawCall -> IndexCount: %u | InstanceCount: %u\n", indexCount, instanceCount);
               fclose(fp);
           }
       }
   }
'''
target_draw = 'tu_CmdDrawIndexed('
start_idx = content.find(target_draw)
if start_idx != -1:
    brace_idx = content.find('{', start_idx)
    content = content[:brace_idx+1] + draw_hook_code + content[brace_idx+1:]
    print('✅ DrawCall 注入成功！')

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
description=Custom Turnip Vertex Hook
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
