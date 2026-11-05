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

    echo -e "${green}正在注入 终极全量内存池扫描 (无长度限制版)...${nocolor}"
    
    cat << 'PYEOF' > inject_all.py
import re
import os

# 1. tu_device.h 添加全局记录池
filepath = "src/freedreno/vulkan/tu_device.h"
with open(filepath, "r", encoding="utf-8") as f:
    code = f.read()
if "util_dynarray dump_buffers;" not in code:
    code = re.sub(r'(struct tu_device\s*\{\s*struct vk_device vk;)', r'\1\n   struct util_dynarray dump_buffers;', code, count=1)
with open(filepath, "w", encoding="utf-8") as f:
    f.write(code)

# 2. tu_device.cc 初始化内存池
filepath = "src/freedreno/vulkan/tu_device.cc"
with open(filepath, "r", encoding="utf-8") as f:
    code = f.read()
if "util_dynarray_init(&device->dump_buffers" not in code:
    code = code.replace("device->instance = physical_device->instance;", 
                        "device->instance = physical_device->instance;\n   util_dynarray_init(&device->dump_buffers, NULL);", 1)
with open(filepath, "w", encoding="utf-8") as f:
    f.write(code)

# 3. tu_cmd_buffer.cc
filepath = "src/freedreno/vulkan/tu_cmd_buffer.cc"
with open(filepath, "r", encoding="utf-8") as f:
    code = f.read()

global_code = '''
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <math.h>

struct dump_buffer_info {
    void *map;
    uint32_t size;
};

static void add_dump_buffer(struct tu_device *dev, void *map, uint32_t size) {
    if (!map || size == 0) return;
    struct dump_buffer_info *bufs = (struct dump_buffer_info *)dev->dump_buffers.data;
    uint32_t count = dev->dump_buffers.size / sizeof(struct dump_buffer_info);
    for (uint32_t i = 0; i < count; i++) {
        if (bufs[i].map == map) return; // 已经记录过
    }
    struct dump_buffer_info info = { .map = map, .size = size };
    // 修复编译错误：只传两个参数
    util_dynarray_append(&dev->dump_buffers, info);
}

static void tu_dump_everything(struct tu_cmd_buffer *cmd) {
    static int draw_limit = 0;
    if (draw_limit++ > 100) return;

    struct dump_buffer_info *bufs = (struct dump_buffer_info *)cmd->device->dump_buffers.data;
    uint32_t count = cmd->device->dump_buffers.size / sizeof(struct dump_buffer_info);

    int fd = open("/storage/emulated/0/Download/tu_dump.txt", O_WRONLY | O_CREAT | O_APPEND, 0666);
    if (fd < 0) return;

    // 用 dprintf 直接写文件句柄，完全不受 buffer 长度限制
    dprintf(fd, "=== DRAW %d ===\\n", draw_limit);

    for (uint32_t i = 0; i < count; i++) {
        uint32_t num_floats = bufs[i].size / 4;
        float *f = (float *)bufs[i].map;
        int found = 0;

        for (uint32_t j = 0; j <= num_floats - 3; j++) {
            if (isnan(f[j]) || isinf(f[j]) || isnan(f[j+1]) || isinf(f[j+1]) || isnan(f[j+2]) || isinf(f[j+2])) 
                continue;

            // 寻找大世界坐标特征：数值在 10000 到 10000000 之间
            if (fabsf(f[j]) > 10000.0f && fabsf(f[j]) < 10000000.0f &&
                fabsf(f[j+1]) > 10000.0f && fabsf(f[j+1]) < 10000000.0f) {
                
                if (found == 0) {
                    dprintf(fd, "[BUF %d] Size=%u\\n", i, bufs[i].size);
                }
                dprintf(fd, "  %f, %f, %f\\n", f[j], f[j+1], f[j+2]);
                found++;
                // 限制单个 buffer 最多打印 100 个，防止把手机空间撑爆
                if (found >= 100) { 
                    dprintf(fd, "  ... (more hidden)\\n");
                    break; 
                }
            }
        }
    }

    close(fd);
}
'''

if "static void tu_dump_everything" not in code:
    target = "enum tu_cmd_buffer_status {"
    code = code.replace(target, global_code + "\n" + target, 1)

# 拦截 VBO
if "add_dump_buffer(cmd->device, buf->bo->map, buf->bo->size);" not in code:
    target = "struct tu_buffer *buf = tu_buffer_from_handle(pBuffers[i]);"
    replace = target + '''
      if (buf && buf->bo) {
          if (!buf->bo->map) tu_bo_map(cmd->device, buf->bo, NULL);
          add_dump_buffer(cmd->device, buf->bo->map, buf->bo->size);
      }
'''
    pattern = re.compile(r'struct tu_buffer \*buf = tu_buffer_from_handle\(pBuffers\[[a-z0-9]+\]\);')
    code = pattern.sub(replace, code, count=1)

# 拦截 Descriptor Set（修复之前的结构体报错）
if "add_dump_buffer(cmd->device, set->mapped_ptr, set->size);" not in code:
    target = "VK_FROM_HANDLE(tu_descriptor_set, set, info->pDescriptorSets[i]);"
    replace = target + '''
      if (set && set->mapped_ptr) {
          add_dump_buffer(cmd->device, set->mapped_ptr, set->size);
      }
'''
    code = code.replace(target, replace, 1)

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
