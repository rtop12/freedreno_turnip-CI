#!/bin/bash -e

export TERM=xterm

green='\033[0;32m'
red='\033[0;31m'
nocolor='\033[0m'
deps="meson ninja patchelf unzip curl pip flex bison zip python3"
workdir="$(pwd)/turnip_workdir"
magiskdir="$workdir/turnip_module"
ndkver="android-ndk-r28"
ndk="$workdir/$ndkver/toolchains/llvm/prebuilt/linux-x86_64/bin"
sdkver="34"
mesasrc="https://gitlab.freedesktop.org/mesa/mesa/-/archive/main/mesa-main.zip"

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
	pip install --upgrade meson mako &> /dev/null
}

prepare_workdir(){
	echo "Preparing work directory ..." $'\n'
	mkdir -p "$workdir" && cd "$_"

	curl -L https://dl.google.com/android/repository/"$ndkver"-linux.zip --output "$ndkver"-linux.zip &> /dev/null
	unzip -q "$ndkver"-linux.zip &> /dev/null

	curl -L "$mesasrc" --output mesa-src.zip &> /dev/null
	unzip -q mesa-src.zip &> /dev/null
		
    MESA_DIR=$(find . -maxdepth 1 -type d -name "mesa-*" ! -name "mesa-src.zip" | head -n 1)
    mv "$MESA_DIR" mesa-src
    cd mesa-src

    echo -e "${green}正在注入 矩阵特征扫描器...${nocolor}"
    cat << 'PYEOF' > inject.py
import re

filepath = "src/freedreno/vulkan/tu_cmd_buffer.cc"
with open(filepath, "r", encoding="utf-8") as f:
    code = f.read()

global_code = '''
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <math.h>

static int g_is_game = -1; 
static bool is_game_process() {
    if (g_is_game != -1) return g_is_game == 1;
    char buf[256] = {0};
    int fd = open("/proc/self/cmdline", O_RDONLY);
    if (fd < 0) { g_is_game = 0; return false; }
    read(fd, buf, sizeof(buf) - 1);
    close(fd);
    g_is_game = (strstr(buf, "com.tencent.tmgp.dfm") != NULL) ? 1 : 0;
    return g_is_game == 1;
}

// 判断数据是否像 MVP 矩阵 (4x4)
static bool is_matrix(float *f) {
    if (isnan(f[0]) || isinf(f[0])) return false;
    // 矩阵的特征：通常包含 0.0, 1.0，且平移部分的坐标数值不会无限大
    int zeros = 0, ones = 0;
    for (int i = 0; i < 16; i++) {
        if (fabs(f[i]) < 0.001f) zeros++;
        if (fabs(f[i] - 1.0f) < 0.001f) ones++;
    }
    // 一个标准的 MVP 至少有 4 个 0 和 1 个 1
    if (zeros >= 3 && ones >= 1) {
        return true;
    }
    return false;
}

static void find_mvp_in_memory(struct tu_cmd_buffer *cmd) {
    if (!is_game_process()) return;

    static uint32_t cnt = 0;
    if (cnt++ % 100 != 0) return; // 每 100 次 Draw 扫一次，足够快了

    struct tu_descriptor_state *desc = &cmd->descriptors[VK_PIPELINE_BIND_POINT_GRAPHICS];
    for (int i = 0; i < MAX_SETS; i++) {
        uint64_t set_iova = desc->set_iova[i];
        if (!set_iova) continue;
        
        struct tu_bo *set_bo = tu_device_lookup_bo(cmd->device, set_iova);
        if (!set_bo || !set_bo->map) continue;
        
        uint32_t *set_mem = (uint32_t*)((char*)set_bo->map + (set_iova - set_bo->iova));
        
        // 扫整个描述符数组，找 IOVA 指针
        for (int j = 0; j < 128; j += 2) { // 每次跳 2 个 DWORD
            uint64_t possible_iova = (uint64_t)set_mem[j] | ((uint64_t)set_mem[j+1] << 32);
            
            if (possible_iova > 0x100000000ULL && possible_iova < 0xfffffffff000ULL) {
                struct tu_bo *data_bo = tu_device_lookup_bo(cmd->device, possible_iova);
                if (data_bo && data_bo->map) {
                    if (possible_iova - data_bo->iova + 64 <= data_bo->size) {
                        float *f = (float*)((char*)data_bo->map + (possible_iova - data_bo->iova));
                        
                        // 精准特征匹配
                        if (is_matrix(f)) {
                            mesa_loge("ESP_MVP: Found Matrix at Set[%d] IOVA=%" PRIx64, i, possible_iova);
                            mesa_loge("ESP_MVP: R0: %f %f %f %f", f[0], f[1], f[2], f[3]);
                            mesa_loge("ESP_MVP: R1: %f %f %f %f", f[4], f[5], f[6], f[7]);
                            mesa_loge("ESP_MVP: R2: %f %f %f %f", f[8], f[9], f[10], f[11]);
                            mesa_loge("ESP_MVP: R3: %f %f %f %f", f[12], f[13], f[14], f[15]);
                        }
                    }
                }
            }
        }
    }
}
'''

# 1. 注入全局
code = code.replace('enum tu_cmd_buffer_status {', global_code + '\nenum tu_cmd_buffer_status {')

# 2. 在 Draw 里调用
code = code.replace('tu6_draw_common<CHIP>(cmd, cs, false, vertexCount);', 
                    'find_mvp_in_memory(cmd);\n   tu6_draw_common<CHIP>(cmd, cs, false, vertexCount);')
code = code.replace('tu6_draw_common<CHIP>(cmd, cs, true, indexCount);', 
                    'find_mvp_in_memory(cmd);\n   tu6_draw_common<CHIP>(cmd, cs, true, indexCount);')

with open(filepath, "w", encoding="utf-8") as f:
    f.write(code)
PYEOF

    python3 inject.py
    rm inject.py
}

build_lib_for_android(){
	mkdir -p "$workdir/bin"
	ln -sf "$ndk/clang" "$workdir/bin/cc"
	ln -sf "$ndk/clang++" "$workdir/bin/c++"
	export PATH="$workdir/bin:$ndk:$PATH"
	export CC=clang CXX=clang++ AR=llvm-ar RANLIB=llvm-ranlib STRIP=llvm-strip OBJDUMP=llvm-objdump OBJCOPY=llvm-objcopy
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
		-Degl=disabled &> "$workdir/meson_log"

	ninja -C build-android-aarch64 &> "$workdir/ninja_log"

	if ! [ -a "$workdir"/mesa-src/build-android-aarch64/src/freedreno/vulkan/libvulkan_freedreno.so ]; then
		echo -e "$red Build failed! $nocolor" 
		tail -n 50 "$workdir/ninja_log"
		exit 1
	fi
}

port_lib_for_magisk(){
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
