#!/bin/bash -e

#Define variables
green='\033[0;32m'
red='\033[0;31m'
nocolor='\033[0m'
deps="meson ninja patchelf unzip curl pip flex bison zip"
workdir="$(pwd)/turnip_workdir"
magiskdir="$workdir/turnip_module"
ndkver="android-ndk-r28"
ndk="$workdir/$ndkver/toolchains/llvm/prebuilt/linux-x86_64/bin"
sdkver="34"
mesasrc="https://gitlab.freedesktop.org/mesa/mesa/-/archive/main/mesa-main.zip"

clear

#There are 4 functions here, simply comment to disable.
#You can insert your own function and make a pull request.
run_all(){
	check_deps
	prepare_workdir
	inject_dump_code       # <--- 注入抓取明文代码
	build_lib_for_android
	port_lib_for_magisk
	port_lib_for_adrenotools
}

check_deps(){
	echo "Checking system for required Dependencies ..."
		for deps_chk in $deps;
			do
				sleep 0.25
				if command -v "$deps_chk" >/dev/null 2>&1 ; then
					echo -e "$green - $deps_chk found $nocolor"
				else
					echo -e "$red - $deps_chk not found, can't countinue. $nocolor"
					deps_missing=1
				fi;
			done

		if [ "$deps_missing" == "1" ]
			then echo "Please install missing dependencies" && exit 1
		fi

	echo "Installing python Mako dependency (if missing) ..." $'\n'
		pip install mako &> /dev/null
}

prepare_workdir(){
	echo "Preparing work directory ..." $'\n'
		mkdir -p "$workdir" && cd "$_"

	echo "Downloading android-ndk from google server ..." $'\n'
		curl https://dl.google.com/android/repository/"$ndkver"-linux.zip --output "$ndkver"-linux.zip &> /dev/null
	echo "Exracting android-ndk ..." $'\n'
		unzip "$ndkver"-linux.zip &> /dev/null

	echo "Downloading mesa source ..." $'\n'
		curl "$mesasrc" --output mesa-main.zip &> /dev/null
	echo "Exracting mesa source ..." $'\n'
		unzip mesa-main.zip &> /dev/null
		cd mesa-main
}

inject_dump_code(){
	echo "Injecting DUMP code into tu_cmd_buffer.cc ..." $'\n'
	cd "$workdir/mesa-main/src/freedreno/vulkan"
	
	# 使用 Python 脚本进行精准文本替换，防呆设计，找不到锚点直接报错
	python3 - <<'PYEOF'
import sys

file_path = "tu_cmd_buffer.cc"
with open(file_path, "r", encoding="utf-8") as f:
    content = f.read()

def safe_replace(content, anchor, code, name):
    if anchor not in content:
        print(f"ERROR: Could not find anchor for {name}!")
        print(f"Expected anchor: {anchor}")
        sys.exit(1)
    return content.replace(anchor, code + "\n" + anchor, 1)

# 1. 注入全局变量和结构体
header_code = """
#include <stdio.h>
#include <stdlib.h>

static uint8_t* g_vbo_mapped_ptrs[MAX_VBS] = {0};
static FILE* g_dump_file = NULL;
static uint32_t g_draw_count = 0;
#define MAX_DUMP_DRAWS 5000 

struct DumpHeader {
    uint32_t magic;         // 'TUDP'
    uint32_t draw_type;     // 0: Draw, 1: DrawIndexed
    uint32_t vertex_count;
    uint32_t instance_count;
    uint32_t first_vertex;
    uint32_t first_instance;
    uint32_t index_count;
    uint32_t push_const_size;
};

static inline void tu_dump_init() {
    if (!g_dump_file) {
        g_dump_file = fopen("/sdcard/turnip_dump.bin", "wb");
    }
}
/* ================== END DUMP HEADER ================== */
"""
anchor_include = '#include "tu_trace_bin_layout.h"'
content = safe_replace(content, anchor_include, header_code, "Global Header")

# 2. 注入 VBO 映射指针获取
vbo_code = """
   /* === 插入 VBO 映射指针开始 === */
   for (uint32_t i = 0; i < bindingCount; i++) {
      if (pBuffers[i] == VK_NULL_HANDLE) {
         g_vbo_mapped_ptrs[firstBinding + i] = NULL;
      } else {
         struct tu_buffer *buf = tu_buffer_from_handle(pBuffers[i]);
         if (buf && buf->bo) {
            tu_bo_map(cmd->device, buf->bo, NULL);
            g_vbo_mapped_ptrs[firstBinding + i] = (uint8_t*)buf->bo->map + pOffsets[i];
         }
      }
   }
   /* === 插入 VBO 映射指针结束 === */
"""
anchor_vbo = "cmd->state.dirty |= TU_CMD_DIRTY_VERTEX_BUFFERS;"
content = safe_replace(content, anchor_vbo, vbo_code, "VBO Mapping")

# 3. 注入 Push Constants 截取
push_code = """
   /* === 插入 Push Constants 截取开始 === */
   if (g_draw_count < MAX_DUMP_DRAWS) {
       tu_dump_init();
       if (g_dump_file && (pPushConstantsInfo->stageFlags & VK_SHADER_STAGE_VERTEX_BIT)) {
           uint32_t magic = 0x50555348; // 'PUSH'
           fwrite(&magic, sizeof(uint32_t), 1, g_dump_file);
           fwrite(&pPushConstantsInfo->size, sizeof(uint32_t), 1, g_dump_file);
           fwrite(pPushConstantsInfo->pValues, 1, pPushConstantsInfo->size, g_dump_file);
           fflush(g_dump_file);
       }
   }
   /* === 插入 Push Constants 截取结束 === */
"""
anchor_push = "cmd->state.dirty |= TU_CMD_DIRTY_SHADER_CONSTS;"
content = safe_replace(content, anchor_push, push_code, "Push Constants")

# 4. 注入 Draw 截取
draw_code = """
   /* === 插入 Draw 截取开始 === */
   if (g_draw_count < MAX_DUMP_DRAWS) {
       tu_dump_init();
       if (g_dump_file) {
           struct DumpHeader header = { 0x54554450, 0, vertexCount, instanceCount, firstVertex, firstInstance, 0, 0 };
           fwrite(&header, sizeof(header), 1, g_dump_file);
           for (int i = 0; i < MAX_VBS; i++) {
               if (g_vbo_mapped_ptrs[i]) {
                   uint32_t dump_size = vertexCount * 32; 
                   if (dump_size > 64 * 1024) dump_size = 64 * 1024;
                   uint32_t vbo_magic = 0x56424F00 | (i & 0xFF); // 'VBO'
                   fwrite(&vbo_magic, sizeof(uint32_t), 1, g_dump_file);
                   fwrite(g_vbo_mapped_ptrs[i], 1, dump_size, g_dump_file);
               }
           }
           fflush(g_dump_file);
           g_draw_count++;
       }
   }
   /* === 插入 Draw 截取结束 === */
"""
anchor_draw = "tu6_emit_vs_params(cmd, NULL, 0, firstVertex, firstInstance);"
content = safe_replace(content, anchor_draw, draw_code, "CmdDraw")

# 5. 注入 DrawIndexed 截取
draw_indexed_code = """
   /* === 插入 DrawIndexed 截取开始 === */
   if (g_draw_count < MAX_DUMP_DRAWS) {
       tu_dump_init();
       if (g_dump_file) {
           struct DumpHeader header = { 0x54554450, 1, indexCount, instanceCount, firstIndex, firstInstance, indexCount, 0 };
           fwrite(&header, sizeof(header), 1, g_dump_file);
           for (int i = 0; i < MAX_VBS; i++) {
               if (g_vbo_mapped_ptrs[i]) {
                   uint32_t dump_size = 64 * 1024; 
                   uint32_t vbo_magic = 0x56424F00 | (i & 0xFF); // 'VBO'
                   fwrite(&vbo_magic, sizeof(uint32_t), 1, g_dump_file);
                   fwrite(g_vbo_mapped_ptrs[i], 1, dump_size, g_dump_file);
               }
           }
           fflush(g_dump_file);
           g_draw_count++;
       }
   }
   /* === 插入 DrawIndexed 截取结束 === */
"""
anchor_draw_indexed = "tu6_emit_vs_params(cmd, NULL, 0, vertexOffset, firstInstance);"
content = safe_replace(content, anchor_draw_indexed, draw_indexed_code, "CmdDrawIndexed")

with open(file_path, "w", encoding="utf-8") as f:
    f.write(content)
print("Injection successful! All 5 anchors replaced.")
PYEOF
}

build_lib_for_android(){
	#Workaround for using Clang as c compiler instead of GCC
	mkdir -p "$workdir/bin"
	ln -sf "$ndk/clang" "$workdir/bin/cc"
	ln -sf "$ndk/clang++" "$workdir/bin/c++"
	export PATH="$workdir/bin:$ndk:$PATH"
	export CC=clang
	export CXX=clang++
	export AR=llvm-ar
	export RANLIB=llvm-ranlib
	export STRIP=llvm-strip
	export OBJDUMP=llvm-objdump
	export OBJCOPY=llvm-objcopy
	export LDFLAGS="-fuse-ld=lld"

	echo "Generating build files ..." $'\n'
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

		meson setup build-android-aarch64 \
			--cross-file "android-aarch64.txt" \
			--native-file "native.txt" \
			-Dbuildtype=release \
			-Dplatforms=android \
			-Dplatform-sdk-version="$sdkver" \
			-Dandroid-stub=true \
			-Dgallium-drivers= \
			-DVulkan-drivers=freedreno \
			-DVulkan-beta=true \
			-Dfreedreno-kmds=kgsl \
			-Db_lto=true \
			-Dstrip=true \
			-Degl=disabled &> "$workdir/meson_log"

	echo "Compiling build files ..." $'\n'
		ninja -C build-android-aarch64 &> "$workdir/ninja_log"

	if ! [ -a "$workdir"/mesa-main/build-android-aarch64/src/freedreno/vulkan/libvulkan_freedreno.so ]; then
		echo -e "$red Build failed! $nocolor" && exit 1
	fi
}

port_lib_for_magisk(){
	echo "Using patchelf to match soname ..." $'\n'
		cp "$workdir"/mesa-main/build-android-aarch64/src/freedreno/vulkan/libvulkan_freedreno.so "$workdir"
		cd "$workdir"
		patchelf --set-soname vulkan.adreno.so libvulkan_freedreno.so
		mv libvulkan_freedreno.so vulkan.adreno.so

	echo "Prepare magisk module structure ..." $'\n'
		p1="system/vendor/lib64/hw"
		mkdir -p "$magiskdir" && cd "$_"
		mkdir -p "$p1"

		meta="META-INF/com/google/android"
		mkdir -p "$meta"

		cat <<EOF >"$meta/update-binary"
#################
# Initialization
#################
umask 022
ui_print() { echo "\$1"; }
OUTFD=\$2
ZIPFILE=\$3
. /data/adb/magisk/util_functions.sh
install_module
exit 0
EOF

		cat <<EOF >"$meta/updater-script"
#MAGISK
EOF

		cat <<EOF >"module.prop"
id=turnip
name=turnip
version=$(cat $workdir/mesa-main/VERSION)
versionCode=1
author=MrMiy4mo
description=Turnip is an open-source vulkan driver for devices with adreno GPUs.
EOF

		cat <<EOF >"customize.sh"
set_perm_recursive \$MODPATH/system 0 0 755 u:object_r:system_file:s0
set_perm_recursive \$MODPATH/system/vendor 0 2000 755 u:object_r:vendor_file:s0
set_perm \$MODPATH/$p1/vulkan.adreno.so 0 0 0644 u:object_r:same_process_hal_file:s0
EOF

	echo "Copy necessary files from work directory ..." $'\n'
		cp "$workdir"/vulkan.adreno.so "$magiskdir"/"$p1"

	echo "Packing files in to magisk module ..." $'\n'
		zip -r "$workdir"/turnip.zip ./* &> /dev/null
		if ! [ -a "$workdir"/turnip.zip ];
			then echo -e "$red-Packing failed!$nocolor" && exit 1
			else echo -e "$green-All done, the module saved to;$nocolor" && echo "$workdir"/turnip.zip
		fi
}

port_lib_for_adrenotools(){
	libname=vulkan.freedreno.so
	echo "Using patchelf to match soname" $'\n'
		cp "$workdir"/mesa-main/build-android-aarch64/src/freedreno/vulkan/libvulkan_freedreno.so "$workdir"/$libname
		cd "$workdir"
		patchelf --set-soname $libname $libname
	echo "Preparing meta.json" $'\n'
		cat <<EOF > "meta.json"
{
	"schemaVersion": 1,
	"name": "freedreno_turnip-CI",
	"description": "$(date)",
	"author": "MrMiy4mo, kethen",
	"packageVersion": "1",
	"vendor": "Mesa",
	"driverVersion": "$(cat $workdir/mesa-main/VERSION)",
	"minApi": $sdkver,
	"libraryName": "$libname"
}
EOF

	zip -9 "$workdir"/turnip_adrenotools.zip $libname meta.json &> /dev/null
	if ! [ -a "$workdir"/turnip_adrenotools.zip ];
		then echo -e "$red-Packing turnip_adrenotools.zip failed!$nocolor" && exit 1
		else echo -e "$green-All done, the module saved to;$nocolor" && echo "$workdir"/turnip_adrenotools.zip
	fi
}

run_all
