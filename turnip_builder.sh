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
	inject_custom_code
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

# ================= 新增：强行注入流出代码 =================
inject_custom_code(){
	echo "正在注入自定义 Turnip 流出代码..." $'\n'
	
	python3 -c "
file_path = 'src/freedreno/vulkan/tu_cmd_buffer.cc'
with open(file_path, 'r') as f:
    content = f.read()

# 1. 注入头文件
content = content.replace('#include \"tu_cmd_buffer.h\"', '#include \"tu_cmd_buffer.h\"\n#include <stdio.h>\n#include <time.h>')

# 2. 注入截获代码
hook_code = '''
         if (buf && buf->bo) {
            static struct timespec last_time = {0, 0};
            struct timespec now;
            clock_gettime(CLOCK_MONOTONIC, &now);
            long diff_ms = (now.tv_sec - last_time.tv_sec) * 1000 + (now.tv_nsec - last_time.tv_nsec) / 1000000;
            if (diff_ms >= 200) {
               void *map_addr = fd_bo_map(buf->bo);
               if (map_addr) {
                  float *verts = (float *)map_addr;
                  fprintf(stderr, \"TURNIP_DUMP: %.1f,%.1f,%.1f | %.1f,%.1f,%.1f | %.1f,%.1f,%.1f\n\", 
                           verts[0], verts[1], verts[2], verts[3], verts[4], verts[5], verts[6], verts[7], verts[8]);
                  fflush(stderr);
                  fd_bo_unmap(buf->bo);
                  last_time = now;
               }
            }
         }
'''

# 3. 强行把代码插进 tu_CmdBindVertexBuffers2 函数里
target_str = 'struct tu_buffer *buf = tu_buffer_from_handle(pBuffers[i]);'
if target_str in content:
    content = content.replace(target_str, target_str + '\n' + hook_code)
    print('✅ 源码注入成功！')
else:
    print('❌ 找不到目标函数，可能源码结构变了！')
    exit(1)

with open(file_path, 'w') as f:
    f.write(content)
"
}
# =======================================================

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
			-Dvulkan-drivers=freedreno \
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
