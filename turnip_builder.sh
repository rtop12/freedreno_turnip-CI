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

    echo -e "${green}正在注入 全量内存（含 UBO）抓取逻辑...${nocolor}"
    
    cat << 'PYEOF' > inject_all.py
import re
import os

# 1. tu_cmd_buffer.h
filepath_h = "src/freedreno/vulkan/tu_cmd_buffer.h"
with open(filepath_h, "r", encoding="utf-8") as f:
    code_h = f.read()
if "uint64_t dump_vbo_ptr;" not in code_h:
    code_h = code_h.replace('uint32_t dirty;', 'uint32_t dirty;\n   uint64_t dump_vbo_ptr;\n   uint32_t dump_vbo_size;', 1)
with open(filepath_h, "w", encoding="utf-8") as f:
    f.write(code_h)

# 2. tu_cmd_buffer.cc
filepath = "src/freedreno/vulkan/tu_cmd_buffer.cc"
with open(filepath, "r", encoding="utf-8") as f:
    code = f.read()

# 重写暴力抓取函数
global_code = '''
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <math.h>

static void tu_dump_everything(struct tu_cmd_buffer *cmd) {
    // 限制写入次数，防止游戏直接卡死。确认有数据后可以改成 1000000
    static int draw_limit = 0;
    if (draw_limit++ > 200) return;

    int fd = open("/storage/emulated/0/Download/tu_dump.txt", O_WRONLY | O_CREAT | O_APPEND, 0666);
    if (fd < 0) return;

    char buf[8192];
    int len = 0;

    len += snprintf(buf + len, sizeof(buf)-len, "=== DRAW %d ===\\n", draw_limit);

    // 1. Push Constants
    len += snprintf(buf + len, sizeof(buf)-len, "[PC]\\n");
    for(int i=0; i<16; i++) {
        len += snprintf(buf + len, sizeof(buf)-len, "%.2f ", ((float*)cmd->push_constants)[i]);
        if((i+1)%4==0) len += snprintf(buf + len, sizeof(buf)-len, "\\n");
    }

    // 2. VBO
    if (cmd->state.dump_vbo_ptr) {
        len += snprintf(buf + len, sizeof(buf)-len, "[VBO] Size=%u\\n", cmd->state.dump_vbo_size);
        for(int i=0; i<12; i++) { // 打 3 个顶点
            len += snprintf(buf + len, sizeof(buf)-len, "%.2f ", ((float*)cmd->state.dump_vbo_ptr)[i]);
            if((i+1)%3==0) len += snprintf(buf + len, sizeof(buf)-len, "\\n");
        }
    }

    // 3. 提取所有的 Descriptor Sets (极大概率矩阵和坐标在这里)
    struct tu_descriptor_state *desc = &cmd->descriptors[VK_PIPELINE_BIND_POINT_GRAPHICS];
    for(int i=0; i<MAX_SETS; i++) {
        if(desc->sets[i]) {
            len += snprintf(buf + len, sizeof(buf)-len, "[SET %d]\\n", i);
            if (desc->sets[i]->mapped_ptr) {
                for(int j=0; j<32; j++) {
                    len += snprintf(buf + len, sizeof(buf)-len, "%.2f ", ((float*)desc->sets[i]->mapped_ptr)[j]);
                    if((j+1)%4==0) len += snprintf(buf + len, sizeof(buf)-len, "\\n");
                }
            } else {
                len += snprintf(buf + len, sizeof(buf)-len, "Not Mapped\\n");
            }
        }
    }

    if (len > 0) write(fd, buf, len);
    close(fd);
}
'''

if "static void tu_dump_everything" not in code:
    target = "enum tu_cmd_buffer_status {"
    code = code.replace(target, global_code + "\n" + target, 1)

# 拦截 VBO 绑定（修改为：不管第几个，只要绑了就抓）
if "cmd->state.dump_vbo_ptr =" not in code:
    target = "struct tu_buffer *buf = tu_buffer_from_handle(pBuffers[i]);"
    replace = target + '''
      if (buf->bo) {
          if (!buf->bo->map) tu_bo_map(cmd->device, buf->bo, NULL);
          if (buf->bo->map) {
              cmd->state.dump_vbo_ptr = (uint64_t)((uint8_t*)buf->bo->map + (pOffsets ? pOffsets[i] : 0));
              cmd->state.dump_vbo_size = pSizes ? pSizes[i] : buf->bo->size;
          }
      }
'''
    pattern = re.compile(r'struct tu_buffer \*buf = tu_buffer_from_handle\(pBuffers\[[a-z0-9]+\]\);')
    code = pattern.sub(replace, code, count=1)

# 拦截 Draw
code = re.sub(r'(tu6_draw_common<CHIP>\([^;]+\);)', r'tu_dump_everything(cmd);\n   \1', code)

with open(filepath, "w", encoding="utf-8") as f:
    f.write(code)
print("Injection completed successfully!")
PYEOF

    python3 inject_all.py
    rm inject_all.py
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
	
	cat << 'SHEOF' > "$magiskdir/service.sh"
#!/system/bin/sh
MODDIR=${0%/*}
until [ "$(getprop sys.boot_completed)" = "1" ]; do sleep 2; done
sleep 5

mkdir -p /storage/emulated/0/Download
touch /storage/emulated/0/Download/tu_dump.txt
chmod 777 /storage/emulated/0/Download/tu_dump.txt
setenforce 0
SHEOF
	chmod 755 "$magiskdir/service.sh"

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
