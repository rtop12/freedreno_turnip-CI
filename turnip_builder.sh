#!/bin/bash

# ==========================================
# Turnip Vulkan 驱动底层坐标拦截构建脚本
# ==========================================

# 定义颜色
green='\033[0;32m'
red='\033[0;31m'
nocolor='\033[0m'

# 定义目录和依赖
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
    echo -e "${green}构建完成！${nocolor}"
    echo -e "${green}Magisk 模块: $workdir/turnip_magisk.zip${nocolor}"
    echo -e "${green}AdrenoTools 驱动: $workdir/turnip_adrenotools.zip${nocolor}"
    echo -e "${green}======================================${nocolor}"
}

check_deps(){
    echo -e "${green}[1/6] 检查并安装依赖...${nocolor}"
    sudo apt-get update -qq
    sudo apt-get install -y glslang-tools python3-pip zip unzip curl patchelf ccache
    pip install mako &> /dev/null
}

prepare_workdir(){
    echo -e "${green}[2/6] 准备源码和 NDK...${nocolor}"
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

# ================= 核心：注入 C++ 拦截代码 =================
inject_custom_code(){
    echo -e "${green}[3/6] 正在注入底层矩阵拦截代码...${nocolor}"
    
    cat << 'PYEOF' > /tmp/inject.py
import sys
import re

file_path = 'src/freedreno/vulkan/tu_cmd_buffer.cc'
with open(file_path, 'r') as f:
    content = f.read()

# 补齐必要的头文件
if '#include <math.h>' not in content:
    content = content.replace('#include "tu_cmd_buffer.h"', '#include "tu_cmd_buffer.h"\n#include <stdio.h>\n#include <time.h>\n#include <stdint.h>\n#include <stdlib.h>\n#include <math.h>')

# ================= 拦截 1：Push Constants (主要抓相机/全局矩阵) =================
push_hook_code = r'''
   // ======== 拦截 PushConstants 矩阵 ========
   static long last_pc_sec = 0;
   struct timespec now_pc;
   clock_gettime(CLOCK_MONOTONIC, &now_pc);
   
   if (now_pc.tv_sec != last_pc_sec) {
       last_pc_sec = now_pc.tv_sec;
       
       if (pPushConstantsInfo->size >= 64) {
           FILE *fp = fopen("/sdcard/ue4_plaintext.txt", "a");
           if (fp) {
               float *m = (float *)pPushConstantsInfo->pValues;
               int count = pPushConstantsInfo->size / 64;
               fprintf(fp, "\n=== PushConstants Matrix (Size: %u) ===\n", pPushConstantsInfo->size);
               
               for (int i = 0; i < count; i++) {
                   float* mat = m + (i * 16);
                   // 判断有效性：底行/右列 W=1.0，坐标不超出正常范围
                   if (isfinite(mat[12]) && isfinite(mat[13]) && isfinite(mat[14]) && isfinite(mat[15])) {
                       if (fabs(mat[15] - 1.0f) < 0.1f && fabs(mat[12]) < 100000.0f && fabs(mat[13]) < 100000.0f) {
                           fprintf(fp, "  Mat[%d] Pos -> X: %10.3f | Y: %10.3f | Z: %10.3f\n", i, mat[12], mat[13], mat[14]);
                       }
                   }
               }
               fclose(fp);
           }
       }
   }
'''
target_push = 'tu_CmdPushConstants2KHR('
start_idx = content.find(target_push)
if start_idx != -1:
    brace_idx = content.find('{', start_idx)
    content = content[:brace_idx+1] + push_hook_code + content[brace_idx+1:]
    print('✅ PushConstants 注入成功！')
else:
    print('❌ 找不到 tu_CmdPushConstants2KHR')

# ================= 拦截 2：DescriptorSets (主要抓实体模型/敌人坐标) =================
desc_hook_code = r'''
   // ======== 拦截 DescriptorSets UBO 矩阵 ========
   static long last_desc_sec = 0;
   struct timespec now_desc;
   clock_gettime(CLOCK_MONOTONIC, &now_desc);
   
   if (now_desc.tv_sec != last_desc_sec) {
       last_desc_sec = now_desc.tv_sec;
       
       if (setCount > 0 && pDescriptorSets != NULL) {
           FILE *fp = fopen("/sdcard/ue4_plaintext.txt", "a");
           if (fp) {
               int found_any = 0;
               for (uint32_t s = 0; s < setCount; s++) {
                   struct tu_descriptor_set *set = tu_descriptor_set_from_handle(pDescriptorSets[s]);
                   if (!set || !set->mapped_ptr) continue;
                   
                   for (uint32_t i = 0; i < set->layout->binding_count; i++) {
                       struct tu_descriptor_set_binding_layout *binding = &set->layout->binding[i];
                       
                       // 只扫描 UBO
                       if (binding->type == VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER || 
                           binding->type == VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER_DYNAMIC) {
                           
                           float *ubo_data = (float *)((char*)set->mapped_ptr + binding->offset);
                           
                           // 一个 UBO 可能存放多个矩阵，假设大小足够
                           if (binding->size >= 64) {
                               int mat_count = binding->size / 64;
                               for (int m = 0; m < mat_count; m++) {
                                   float *mat = ubo_data + (m * 16);
                                   
                                   if (isfinite(mat[12]) && isfinite(mat[13]) && isfinite(mat[14]) && isfinite(mat[15])) {
                                       // 过滤条件：W=1，且坐标有实际意义
                                       if (fabs(mat[15] - 1.0f) < 0.1f && fabs(mat[12]) < 50000.0f && fabs(mat[13]) < 50000.0f) {
                                           if (!found_any) {
                                               fprintf(fp, "\n=== DescriptorSet UBO Matrix ===\n");
                                               found_any = 1;
                                           }
                                           fprintf(fp, "  Set[%u] Bind[%u] Mat[%d] -> X: %10.3f | Y: %10.3f | Z: %10.3f\n", s, i, m, mat[12], mat[13], mat[14]);
                                       }
                                   }
                               }
                           }
                       }
                   }
               }
               if (found_any) fclose(fp);
               else fclose(fp); // 关闭空文件流
           }
       }
   }
'''
target_desc = 'tu_CmdBindDescriptorSets2KHR('
start_idx = content.find(target_desc)
if start_idx != -1:
    brace_idx = content.find('{', start_idx)
    content = content[:brace_idx+1] + desc_hook_code + content[brace_idx+1:]
    print('✅ DescriptorSets 注入成功！')
else:
    print('❌ 找不到 tu_CmdBindDescriptorSets2KHR')

with open(file_path, 'w') as f:
    f.write(content)
PYEOF

    cd "$workdir/mesa-main"
    python3 /tmp/inject.py
    cd "$workdir"
}

# ================= 交叉编译 =================
build_lib_for_android(){
    echo -e "${green}[4/6] 开始 Meson/Ninja 编译...${nocolor}"
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

# ================= 打包 Magisk 模块 =================
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
description=Custom Turnip with UE4 matrix hook
EOF
    cat <<EOF >"customize.sh"
set_perm_recursive \$MODPATH/system 0 0 755 u:object_r:system_file:s0
set_perm_recursive \$MODPATH/system/vendor 0 2000 755 u:object_r:vendor_file:s0
set_perm \$MODPATH/$p1/vulkan.adreno.so 0 0 0644 u:object_r:same_process_hal_file:s0
EOF
    cp "$workdir/vulkan.adreno.so" "$magiskdir/$p1/"
    zip -r "$workdir/turnip_magisk.zip" ./* &> /dev/null
}

# ================= 打包 AdrenoTools 驱动 =================
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
