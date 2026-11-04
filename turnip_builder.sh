#!/bin/bash -e

export TERM=xterm

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
REPO_ROOT="$(pwd)"

clear

run_all(){
	check_deps
	prepare_workdir
	build_lib_for_android
	port_lib_for_magisk
	port_lib_for_adrenotools
}

check_deps(){
	echo "Checking system for required Dependencies ..."
		for deps_chk in $deps; do
			sleep 0.25
			if command -v "$deps_chk" >/dev/null 2>&1 ; then
				echo -e "$green - $deps_chk found $nocolor"
			else
				echo -e "$red - $deps_chk not found $nocolor"
				deps_missing=1
			fi;
		done
		if [ "$deps_missing" == "1" ]; then echo "Please install missing dependencies" && exit 1; fi
	echo "Installing python dependencies ..." $'\n'
		pip install --upgrade meson mako &> /dev/null
}

prepare_workdir(){
	echo "Preparing work directory ..." $'\n'
		mkdir -p "$workdir" && cd "$_"

	echo "Downloading android-ndk ..." $'\n'
		curl -L https://dl.google.com/android/repository/"$ndkver"-linux.zip --output "$ndkver"-linux.zip &> /dev/null
		unzip -q "$ndkver"-linux.zip &> /dev/null

	echo "Downloading mesa source (main) ..." $'\n'
		curl -L "$mesasrc" --output mesa-src.zip &> /dev/null
		unzip -q mesa-src.zip &> /dev/null
		
    MESA_DIR=$(find . -maxdepth 1 -type d -name "mesa-*" ! -name "mesa-src.zip" | head -n 1)
    mv "$MESA_DIR" mesa-src
    cd mesa-src
    
    echo -e "${green}提取纯净版 tu_cmd_buffer.cc 中...${nocolor}"
    cp src/freedreno/vulkan/tu_cmd_buffer.cc "$workdir/tu_cmd_buffer_original.cc"
    cd "$workdir"
    zip -q original_tu_cmd_buffer.zip tu_cmd_buffer_original.cc
    cd mesa-src

	if [ -f "$REPO_ROOT/tu_cmd_buffer.cc" ]; then
		echo -e "${green}Found custom tu_cmd_buffer.cc, applying patch ...${nocolor}" $'\n'
		cp "$REPO_ROOT/tu_cmd_buffer.cc" src/freedreno/vulkan/tu_cmd_buffer.cc
	else
		echo -e "${red}WARNING: custom tu_cmd_buffer.cc NOT FOUND! Building original code.${nocolor}" $'\n'
	fi
}

build_lib_for_android(){
	mkdir -p "$workdir/bin"
	ln -sf "$ndk/clang" "$workdir/bin/cc"
	ln -sf "$ndk/clang++" "$workdir/bin/c++"
	export PATH="$workdir/bin:$ndk:$PATH"
	export CC=clang CXX=clang++ AR=llvm-ar RANLIB=llvm-ranlib STRIP=llvm-strip OBJDUMP=llvm-objdump OBJCOPY=llvm-objcopy
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
		-Dvulkan-beta=true \
		-Dfreedreno-kmds=kgsl \
		-Dstrip=true \
		-Degl=disabled 2>&1 | tee "$workdir/meson_log"

	if [ ${PIPESTATUS[0]} -ne 0 ]; then
		echo -e "$red Meson setup failed! $nocolor"
		exit 1
	fi

	echo "Compiling build files ..." $'\n'
	ninja -C build-android-aarch64 2>&1 | tee "$workdir/ninja_log"

	if ! [ -a "$workdir"/mesa-src/build-android-aarch64/src/freedreno/vulkan/libvulkan_freedreno.so ]; then
		echo -e "$red Build failed! $nocolor" 
		exit 1
	fi
}

port_lib_for_magisk(){
	echo "Using patchelf ..." $'\n'
	cp "$workdir"/mesa-src/build-android-aarch64/src/freedreno/vulkan/libvulkan_freedreno.so "$workdir"
	cd "$workdir"
	patchelf --set-soname vulkan.adreno.so libvulkan_freedreno.so
	mv libvulkan_freedreno.so vulkan.adreno.so

	p1="system/vendor/lib64/hw"
	mkdir -p "$magiskdir/$p1"
	
	cat <<EOF >"$magiskdir/module.prop"
id=turnip
name=turnip
version=$(cat $workdir/mesa-src/VERSION)
versionCode=1
author=MrMiy4mo
description=Turnip
EOF

	cat <<EOF >"$magiskdir/customize.sh"
set_perm_recursive \$MODPATH/system 0 0 755 u:object_r:system_file:s0
set_perm_recursive \$MODPATH/system/vendor 0 2000 755 u:object_r:vendor_file:s0
set_perm \$MODPATH/$p1/vulkan.adreno.so 0 0 0644 u:object_r:same_process_hal_file:s0
EOF

	cp "$workdir"/vulkan.adreno.so "$magiskdir/$p1"
	cd "$magiskdir"
	zip -r "$workdir/turnip.zip" ./* &> /dev/null
}

port_lib_for_adrenotools(){
	libname=vulkan.freedreno.so
	cp "$workdir"/mesa-src/build-android-aarch64/src/freedreno/vulkan/libvulkan_freedreno.so "$workdir"/$libname
	cd "$workdir"
	patchelf --set-soname $libname $libname
	
	cat <<EOF > "meta.json"
{
	"schemaVersion": 1,
	"name": "freedreno_turnip-CI",
	"description": "$(date)",
	"author": "MrMiy4mo",
	"packageVersion": "1",
	"vendor": "Mesa",
	"driverVersion": "$(cat $workdir/mesa-src/VERSION)",
	"minApi": $sdkver,
	"libraryName": "$libname"
}
EOF
	zip -9 "$workdir/turnip_adrenotools.zip" $libname meta.json &> /dev/null
}

run_all
