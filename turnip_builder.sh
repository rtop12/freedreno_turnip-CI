#!/bin/bash

#Define variables
green='\033[0;32m'
red='\033[0;31m'
nocolor='\033[0m'
deps="meson ninja patchelf unzip curl pip flex bison zip glslangValidator"
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
	echo "Checking for required Dependencies ..."
    sudo apt-get update -qq
    sudo apt-get install -y glslang-tools python3-pip zip unzip curl patchelf
	pip install mako &> /dev/null
}

prepare_workdir(){
	mkdir -p "$workdir" && cd "$_"
	curl https://dl.google.com/android/repository/"$ndkver"-linux.zip --output "$ndkver"-linux.zip &> /dev/null
	unzip "$ndkver"-linux.zip &> /dev/null
	curl "$mesasrc" --output mesa-main.zip &> /dev/null
	unzip mesa-main.zip &> /dev/null
	cd mesa-main
}

# ================= 终极雷达扫描注入代码 =================
inject_custom_code(){
	echo "正在注入雷达扫描代码..." $'\n'
	
	cat << 'PYEOF' > /tmp/inject.py
import sys

file_path = 'src/freedreno/vulkan/tu_cmd_buffer.cc'
with open(file_path, 'r') as f:
    content = f.read()

content = content.replace('#include "tu_cmd_buffer.h"', '#include "tu_cmd_buffer.h"\n#include <stdio.h>\n#include <time.h>\n#include <stdint.h>')

hook_code = r'''
         // 只要 Buffer 够大（大于 1KB），我们就像雷达一样全盘扫描
         if (buf && buf->bo && buf->bo->size > 1024 && buf->bo->size < 5000000) {
             static long last_sec = 0;
             struct timespec now;
             clock_gettime(CLOCK_MONOTONIC, &now);
             
             if (now.tv_sec != last_sec) {
                 last_sec = now.tv_sec;
                 
                 void *map_addr = buf->bo->map;
                 if (map_addr == NULL) {
                     tu_bo_map(cmd->device, buf->bo, NULL);
                     map_addr = buf->bo->map;
                 }
                 
                 if (map_addr) {
                     float *f_data = (float *)map_addr;
                     uint32_t total_floats = buf->bo->size / 4;
                     
                     FILE *fp = fopen("/sdcard/turnip_radar.txt", "a");
                     if (fp) {
                         fprintf(fp, "\n>>> 扫描到巨型Buffer，大小: %u 字节 <<<\n", (uint32_t)buf->bo->size);
                         
                         int found_count = 0;
                         // 遍历整个 Buffer 里的所有浮点数
                         for (uint32_t k = 0; k < total_floats - 2; k++) {
                             float x = f_data[k];
                             float y = f_data[k+1];
                             float z = f_data[k+2];
                             
                             // 【核心雷达】寻找符合 3D 世界坐标特征的数据
                             // 特征：在 -5000 到 5000 之间，且不是 0，且带有小数
                             if (x > -5000 && x < 5000 && y > -5000 && y < 5000 && z > -5000 && z < 5000 &&
                                 x != 0.0f && y != 0.0f && z != 0.0f &&
                                 (x != (int)x || y != (int)y || z != (int)z)) {
                                 
                                 fprintf(fp, "定位到: X: %.3f, Y: %.3f, Z: %.3f\n", x, y, z);
                                 found_count++;
                                 // 一帧只打印 20 个，防止文件爆掉
                                 if (found_count > 20) break; 
                             }
                         }
                         fclose(fp);
                     }
                 }
             }
         }
'''

target_str = 'struct tu_buffer *buf = tu_buffer_from_handle(pBuffers[i]);'
if target_str in content:
    content = content.replace(target_str, target_str + '\n' + hook_code)
    print('✅ 源码注入成功！')
else:
    print('❌ 找不到目标函数')
    sys.exit(1)

with open(file_path, 'w') as f:
    f.write(content)
PYEOF

	python3 /tmp/inject.py
}

build_lib_for_android(){
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
	if [ $? -ne 0 ]; then cat "$workdir/meson_log"; exit 1; fi
	ninja -C build-android-aarch64 &> "$workdir/ninja_log"
	if [ $? -ne 0 ]; then cat "$workdir/ninja_log"; exit 1; fi
	set -e
}

port_lib_for_magisk(){
		cp "$workdir"/mesa-main/build-android-aarch64/src/freedreno/vulkan/libvulkan_freedreno.so "$workdir"
		cd "$workdir"
		patchelf --set-soname vulkan.adreno.so libvulkan_freedreno.so
		mv libvulkan_freedreno.so vulkan.adreno.so
		p1="system/vendor/lib64/hw"
		mkdir -p "$magiskdir" && cd "$_"
		mkdir -p "$p1"
		cat <<EOF >"module.prop"
id=turnip
name=turnip
version=Hook
versionCode=1
author=Me
description=Custom Turnip
EOF
		cat <<EOF >"customize.sh"
set_perm_recursive \$MODPATH/system 0 0 755 u:object_r:system_file:s0
set_perm_recursive \$MODPATH/system/vendor 0 2000 755 u:object_r:vendor_file:s0
set_perm \$MODPATH/$p1/vulkan.adreno.so 0 0 0644 u:object_r:same_process_hal_file:s0
EOF
		cp "$workdir"/vulkan.adreno.so "$magiskdir"/"$p1"
		zip -r "$workdir"/turnip.zip ./* &> /dev/null
}

port_lib_for_adrenotools(){
	libname=vulkan.freedreno.so
	cp "$workdir"/mesa-main/build-android-aarch64/src/freedreno/vulkan/libvulkan_freedreno.so "$workdir"/$libname
	cd "$workdir"
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
}

run_all
