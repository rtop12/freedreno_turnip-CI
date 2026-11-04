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
	echo "Checking system for required Dependencies ..."
    echo "Installing missing system tools ..."
    sudo apt-get update -qq
    sudo apt-get install -y glslang-tools python3-pip zip unzip curl patchelf

	for deps_chk in $deps;
		do
			sleep 0.25
			if command -v "$deps_chk" >/dev/null 2>&1 ; then
				echo -e "$green - $deps_chk found $nocolor"
			else
				echo -e "$red - $deps_chk not found $nocolor"
				deps_missing=1
			fi;
		done

	if [ "$deps_missing" == "1" ]
		then exit 1
	fi

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

# ================= 强行注入流出代码 =================
inject_custom_code(){
	echo "正在注入自定义 Turnip 流出代码..." $'\n'
	
	cat << 'PYEOF' > /tmp/inject.py
import sys

file_path = 'src/freedreno/vulkan/tu_cmd_buffer.cc'
with open(file_path, 'r') as f:
    content = f.read()

# 1. 注入安卓专属头文件
content = content.replace('#include "tu_cmd_buffer.h"', '#include "tu_cmd_buffer.h"\n#include <stdio.h>\n#include <time.h>\n#include <android/log.h>')

# 2. 注入截获代码
hook_code = r'''
         if (buf && buf->bo) {
            static struct timespec last_time = {0, 0};
            struct timespec now;
            clock_gettime(CLOCK_MONOTONIC, &now);
            long diff_ms = (now.tv_sec - last_time.tv_sec) * 1000 + (now.tv_nsec - last_time.tv_nsec) / 1000000;
            
            if (diff_ms >= 200) {
               void *map_addr = buf->bo->map;
               if (map_addr == NULL) {
                  tu_bo_map(cmd->device, buf->bo, NULL);
                  map_addr = buf->bo->map;
               }
               
               if (map_addr) {
                  float *verts = (float *)map_addr;
                  // 使用 Android 专属日志系统，Tag 为 TURNIP_HACK
                  __android_log_print(ANDROID_LOG_INFO, "TURNIP_HACK", "DATA: %.1f,%.1f,%.1f | %.1f,%.1f,%.1f | %.1f,%.1f,%.1f", 
                           verts[0], verts[1], verts[2], verts[3], verts[4], verts[5], verts[6], verts[7], verts[8]);
                  last_time = now;
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
