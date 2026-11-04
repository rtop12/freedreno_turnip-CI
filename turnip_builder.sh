#!/bin/bash

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
}

check_deps(){
    sudo apt-get update -qq
    sudo apt-get install -y glslang-tools python3-pip zip unzip curl patchelf ccache
    pip install mako &> /dev/null
}

prepare_workdir(){
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

# ================= 拦截 1：Push Constants (主要抓相机/角色矩阵明文) =================
push_hook_code = r'''
   // ======== 拦截 PushConstants 提取矩阵明文 ========
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
                   // 检查有效性：检查第 15 个元素是否为 1.0 左右，过滤垃圾数据
                   if (isfinite(mat[12]) && isfinite(mat[13]) && isfinite(mat[14]) && isfinite(mat[15])) {
                       if (fabs(mat[15] - 1.0f) < 0.1f && fabs(mat[12]) < 100000.0f) {
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

# ================= 拦截 2：DescriptorSets (修正编译报错，只打印 IOVA 地址) =================
# 注意：这里只能打印显存地址，不能直接读明文，因为描述符里存的是指针！
desc_hook_code = r'''
   // ======== 拦截 DescriptorSets 获取 UBO IOVA 地址 ========
   static long last_desc_sec = 0;
   struct timespec now_desc;
   clock_gettime(CLOCK_MONOTONIC, &now_desc);
   
   if (now_desc.tv_sec != last_desc_sec) {
       last_desc_sec = now_desc.tv_sec;
       
       // 修正 API 变量名：使用 pBindDescriptorSetsInfo 结构体
       const VkBindDescriptorSetsInfoKHR *info = pBindDescriptorSetsInfo;
       if (info && info->descriptorSetCount > 0 && info->pDescriptorSets != NULL) {
           FILE *fp = fopen("/sdcard/ue4_plaintext.txt", "a");
           if (fp) {
               fprintf(fp, "\n=== DescriptorSet UBO Info ===\n");
               for (uint32_t s = 0; s < info->descriptorSetCount; s++) {
                   // 修正宏调用
                   VK_FROM_HANDLE(tu_descriptor_set, set, info->pDescriptorSets[s]);
                   if (!set || !set->mapped_ptr) continue;
                   
                   for (uint32_t i = 0; i < set->layout->binding_count; i++) {
                       struct tu_descriptor_set_binding_layout *binding = &set->layout->binding[i];
                       if (binding->type == VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER || 
                           binding->type == VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER_DYNAMIC) {
                           
                           // 描述符内存中存的是 64 位显存地址 (IOVA)
                           uint64_t iova = *((uint64_t*)((char*)set->mapped_ptr + binding->offset));
                           fprintf(fp, "  Set[%u] Bind[%u] UBO IOVA: 0x%llx\n", s, i, (unsigned long long)iova);
                       }
                   }
               }
               fclose(fp);
           }
       }
   }
'''
target_desc = 'tu_CmdBindDescriptorSets2KHR('
start_idx = content.find(target_desc)
if start_idx != -1:
    brace_idx = content.find('{', start_idx)
    content = content[:brace_idx+1] + desc_hook_code + content[brace_idx+1:]
    print('✅ DescriptorSets 注入成功（已修正变量名）！')

with open(file_path, 'w') as f:
    f.write(content)
PYEOF

    cd "$workdir/mesa-main"
    python3 /tmp/inject.py
    cd "$workdir"
}

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
