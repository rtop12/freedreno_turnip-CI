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

# ================= 注入代码：暴力提取所有绑定的 Buffer 数据 =================
inject_custom_code(){
	echo "正在注入渲染前明文提取代码..." $'\n'
	
	cat << 'PYEOF' > /tmp/inject.py
import sys

file_path = 'src/freedreno/vulkan/tu_cmd_buffer.cc'
with open(file_path, 'r') as f:
    content = f.read()

content = content.replace('#include "tu_cmd_buffer.h"', '#include "tu_cmd_buffer.h"\n#include <stdio.h>\n#include <time.h>\n#include <stdint.h>')

hook_code = r'''
         // 遍历所有绑定的 Buffer (不仅仅是 i=0)
         for (uint32_t idx = 0; idx < bindingCount; idx++) {
             if (pBuffers[idx] == VK_NULL_HANDLE) continue;
             
             struct tu_buffer *b = tu_buffer_from_handle(pBuffers[idx]);
             if (b && b->bo && b->bo->size > 500) {
                 
                 static long last_sec = 0;
                 struct timespec now;
                 clock_gettime(CLOCK_MONOTONIC, &now);
                 
                 // 每秒只抓一次，防止瞬间卡死
                 if (now.tv_sec > last_sec) {
                     last_sec = now.tv_sec;
                     
                     void *map_addr = b->bo->map;
                     if (map_addr == NULL) {
                         tu_bo_map(cmd->device, b->bo, NULL);
                         map_addr = b->bo->map;
                     }
                     
                     if (map_addr) {
                         float *verts = (float *)map_addr;
                         
                         // 简单过滤：如果前三个数全为0，说明可能是空数据或UI
                         if (!(verts[0] == 0.0f && verts[1] == 0.0f && verts[2] == 0.0f)) {
                             
                             FILE *fp = fopen("/sdcard/turnip_vertex_data.txt", "a");
                             if (fp) {
                                 // 打印哪个 Buffer，大小是多少
                                 fprintf(fp, "\n>>> Buffer[%u] Size: %u bytes <<<\n", idx, (uint32_t)b->bo->size);
                                 
                                 // 打印前 15 个顶点（45个float），足够判断是不是坐标了
                                 for (int k = 0; k < 15; k++) {
                                     if ((k * 3 + 2) * sizeof(float) < b->bo->size) {
                                         fprintf(fp, "%.2f, %.2f, %.2f\n", verts[k*3], verts[k*3+1], verts[k*3+2]);
                                     }
                                 }
                                 fclose(fp);
                             }
                         }
                     }
                 }
             }
         }
'''

target_str = 'struct tu_buffer *buf = tu_buffer_from_handle(pBuffers[i]);'
# 我们把代码插在函数最前面，用我们自己写的循环遍历，所以不需要原来的 buf 了
if target_str in content:
    content = content.replace(target_str, hook_code + '\n         ' + target_str)
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
