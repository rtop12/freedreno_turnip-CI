#!/bin/bash

#Define variables
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
	echo -e "${green}编译完成！请查看 $workdir 目录下的 zip 文件。${nocolor}"
	echo -e "${green}======================================${nocolor}"
}

check_deps(){
	echo "Checking for required Dependencies ..."
    sudo apt-get update -qq
    sudo apt-get install -y glslang-tools python3-pip zip unzip curl patchelf
	pip install mako &> /dev/null
}

prepare_workdir(){
	mkdir -p "$workdir" && cd "$_"
	if [ ! -d "$ndkver" ]; then
		echo "正在下载 NDK..."
		curl https://dl.google.com/android/repository/"$ndkver"-linux.zip --output "$ndkver"-linux.zip &> /dev/null
		unzip -q "$ndkver"-linux.zip &> /dev/null
	fi
	if [ ! -d "mesa-main" ]; then
		echo "正在下载 Mesa 源码..."
		curl "$mesasrc" --output mesa-main.zip &> /dev/null
		unzip -q mesa-main.zip &> /dev/null
	fi
	cd mesa-main
}

# ================= 注入自定义代码 =================
inject_custom_code(){
	echo "正在注入 矩阵特征提取 代码..." $'\n'
	
	cat << 'PYEOF' > /tmp/inject.py
import sys
import re

file_path = 'src/freedreno/vulkan/tu_cmd_buffer.cc'
with open(file_path, 'r') as f:
    content = f.read()

# 添加必要的头文件
content = content.replace('#include "tu_cmd_buffer.h"', '#include "tu_cmd_buffer.h"\n#include <stdio.h>\n#include <time.h>\n#include <stdint.h>\n#include <stdlib.h>\n#include <math.h>')

# ================= 1. 拦截矩阵：抓取物体的世界坐标 (平移量) =================
push_hook_code = r'''
   // ======== 寻找世界坐标 (从 PushConstants 中提取矩阵平移量) ========
   static long last_push_sec = 0;
   struct timespec now_push;
   clock_gettime(CLOCK_MONOTONIC, &now_push);
   
   // 限制 1 秒抓取一次，防止卡死
   if (now_push.tv_sec != last_push_sec) {
       last_push_sec = now_push.tv_sec;
       
       // 4x4 矩阵 (64字节) 或 多个矩阵
       if (pPushConstantsInfo->size > 0 && pPushConstantsInfo->size % 64 == 0) {
           FILE *fp = fopen("/sdcard/turnip_matrix.txt", "a");
           if (fp) {
               float *m = (float *)pPushConstantsInfo->pValues;
               int num_matrices = pPushConstantsInfo->size / 64;
               
               fprintf(fp, "\n>>> Frame Matrix Update (Size: %u, Count: %d) <<<\n", pPushConstantsInfo->size, num_matrices);
               
               for (int i = 0; i < num_matrices; i++) {
                   float* mat = m + (i * 16);
                   // UE4 (GLSL/Vulkan) 通常使用列主序 (Column-Major)。
                   // 世界坐标 (X, Y, Z) 通常在最后一列 (索引 12, 13, 14)
                   float x = mat[12];
                   float y = mat[13];
                   float z = mat[14];
                   float w = mat[15]; // 通常是 1.0

                   // 过滤条件：W=1，且坐标在合理的地图范围内
                   if (w > 0.9f && w < 1.1f && fabs(x) < 50000.0f && fabs(y) < 50000.0f && fabs(z) < 50000.0f) {
                       // 检查矩阵是否包含有效的旋转/缩放分量
                       if (mat[0] != 0.0f || mat[5] != 0.0f || mat[10] != 0.0f) {
                           fprintf(fp, "  Mat[%d] Pos -> X:%10.3f | Y:%10.3f | Z:%10.3f\n", i, x, y, z);
                       }
                   }
               }
               fclose(fp);
           }
       }
   }
'''

target_push_header = 'tu_CmdPushConstants2KHR('
if target_push_header in content:
    # 找到函数体起始的大括号
    start_idx = content.find(target_push_header)
    brace_idx = content.find('{', start_idx)
    # 插入代码
    content = content[:brace_idx+1] + push_hook_code + content[brace_idx+1:]
    print('✅ PushConstants 矩阵坐标注入成功！')
else:
    print('❌ 找不到 tu_CmdPushConstants2KHR')


# ================= 2. 拦截 Draw Call：辅助过滤特征 =================
draw_hook_code = r'''
   // ======== 记录 Draw Call 特征 ========
   static long last_draw_sec = 0;
   struct timespec now_draw;
   clock_gettime(CLOCK_MONOTONIC, &now_draw);

   if (now_draw.tv_sec != last_draw_sec) {
       last_draw_sec = now_draw.tv_sec;
       
       // 只记录特定的 Draw Call，防止日志过大
       if (indexCount > 100) {
           FILE *fp = fopen("/sdcard/turnip_draws.txt", "a");
           if (fp) {
               fprintf(fp, "DrawCall -> IndexCount: %u | InstanceCount: %u\n", indexCount, instanceCount);
               fclose(fp);
           }
       }
   }
'''

# 注意：原函数有模板声明，使用正则寻找包含 tu_CmdDrawIndexed 的定义
match = re.search(r'VKAPI_CALL\s+tu_CmdDrawIndexed\(', content)
if match:
    start_idx = match.start()
    brace_idx = content.find('{', start_idx)
    if brace_idx != -1:
        content = content[:brace_idx+1] + draw_hook_code + content[brace_idx+1:]
        print('✅ DrawIndexed 特征注入成功！')
else:
    print('❌ 找不到 tu_CmdDrawIndexed')

with open(file_path, 'w') as f:
    f.write(content)
PYEOF

	python3 /tmp/inject.py
}

build_lib_for_android(){
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
	echo "开始 Meson 配置..."
	meson setup build-android-aarch64 --cross-file "android-aarch64.txt" --native-file "native.txt" \
		-Dbuildtype=release -Dplatforms=android -Dplatform-sdk-version="$sdkver" \
		-Dandroid-stub=true -Dgallium-drivers= -Dvulkan-drivers=freedreno \
		-Dfreedreno-kmds=kgsl -Dstrip=true -Degl=disabled &> "$workdir/meson_log"
	if [ $? -ne 0 ]; then cat "$workdir/meson_log"; exit 1; fi
	
	echo "开始 Ninja 编译..."
	ninja -C build-android-aarch64 &> "$workdir/ninja_log"
	if [ $? -ne 0 ]; then cat "$workdir/ninja_log"; exit 1; fi
	set -e
}

port_lib_for_magisk(){
	cd "$workdir"
	cp mesa-main/build-android-aarch64/src/freedreno/vulkan/libvulkan_freedreno.so .
	patchelf --set-soname vulkan.adreno.so libvulkan_freedreno.so
	mv libvulkan_freedreno.so vulkan.adreno.so
	p1="system/vendor/lib64/hw"
	mkdir -p "$magiskdir" && cd "$_"
	mkdir -p "$p1"
	cat <<EOF >"module.prop"
id=turnip_hook
name=Turnip Hook
version=1.0
versionCode=1
author=You
description=Custom Turnip with matrix hook
EOF
	cat <<EOF >"customize.sh"
set_perm_recursive \$MODPATH/system 0 0 755 u:object_r:system_file:s0
set_perm_recursive \$MODPATH/system/vendor 0 2000 755 u:object_r:vendor_file:s0
set_perm \$MODPATH/$p1/vulkan.adreno.so 0 0 0644 u:object_r:same_process_hal_file:s0
EOF
	cp "$workdir"/vulkan.adreno.so "$magiskdir"/"$p1"
	zip -r "$workdir"/turnip_magisk.zip ./* &> /dev/null
	echo "Magisk 模块生成完毕：$workdir/turnip_magisk.zip"
}

port_lib_for_adrenotools(){
	libname=vulkan.freedreno.so
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
	zip -9 "$workdir"/turnip_adrenotools.zip $libname meta.json &> /dev/null
	echo "AdrenoTools 驱动生成完毕：$workdir/turnip_adrenotools.zip"
}

run_all
