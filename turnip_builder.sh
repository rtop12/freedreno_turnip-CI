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

    echo -e "${green}正在注入 内部存储文件写入逻辑...${nocolor}"
    
    cat << 'PYEOF' > inject_all.py
import re
import os

# ==========================================
# 1. 修改 tu_device.h
# ==========================================
filepath = "src/freedreno/vulkan/tu_device.h"
with open(filepath, "r", encoding="utf-8") as f:
    code = f.read()

if "int dump_ko_fd;" not in code:
    code = re.sub(r'(struct tu_device\s*\{\s*struct vk_device vk;)', r'\1\n   int dump_ko_fd;', code, count=1)

with open(filepath, "w", encoding="utf-8") as f:
    f.write(code)

# ==========================================
# 2. 修改 tu_device.cc
# ==========================================
filepath = "src/freedreno/vulkan/tu_device.cc"
with open(filepath, "r", encoding="utf-8") as f:
    code = f.read()
if "device->dump_ko_fd =" not in code:
    code = code.replace("device->instance = physical_device->instance;", 
                        "device->instance = physical_device->instance;\n   device->dump_ko_fd = -1;", 1)
with open(filepath, "w", encoding="utf-8") as f:
    f.write(code)

# ==========================================
# 3. 修改 tu_cmd_buffer.h
# ==========================================
filepath = "src/freedreno/vulkan/tu_cmd_buffer.h"
with open(filepath, "r", encoding="utf-8") as f:
    code = f.read()

if "uint64_t dump_vbo_ptr;" not in code:
    code = code.replace('uint32_t dirty;', 'uint32_t dirty;\n   uint64_t dump_vbo_ptr;\n   uint32_t dump_vbo_size;', 1)

with open(filepath, "w", encoding="utf-8") as f:
    f.write(code)

# ==========================================
# 4. 修改 tu_cmd_buffer.cc
# ==========================================
filepath = "src/freedreno/vulkan/tu_cmd_buffer.cc"
with open(filepath, "r", encoding="utf-8") as f:
    code = f.read()

# 4.1 定义文件写入与特征扫描逻辑
global_code = '''
#include <stdio.h>
#include <math.h>

static void tu_scan_and_write_to_file(struct tu_cmd_buffer *cmd) {
    if (!cmd->state.dump_vbo_ptr || cmd->state.dump_vbo_size < 12) return;

    // 抓取频率控制：每 100 次 Draw 写一次
    static int draw_counter = 0;
    if (draw_counter++ % 100 != 0) return; 

    // 直接写到内部存储
    FILE *fp = fopen("/sdcard/tu_dump.txt", "a");
    if (!fp) return;

    uint8_t *ptr = (uint8_t*)cmd->state.dump_vbo_ptr;
    uint32_t size = cmd->state.dump_vbo_size;
    int found_count = 0;

    // 按 4 字节 (float) 扫描
    for (uint32_t i = 0; i <= size - 12; i += 4) {
        float *f = (float*)(ptr + i);
        
        if (isnan(f[0]) || isinf(f[0]) || isnan(f[1]) || isinf(f[1]) || isnan(f[2]) || isinf(f[2])) 
            continue;
            
        // 特征判据：大世界坐标特征
        if (fabsf(f[0]) > 10000.0f || fabsf(f[1]) > 10000.0f || fabsf(f[2]) > 10000.0f) {
            fprintf(fp, "DRAW: %d | X: %f, Y: %f, Z: %f\\n", draw_counter, f[0], f[1], f[2]);
            found_count++;
            if (found_count >= 5) break; 
        }
    }

    fclose(fp);
}
'''

if "static void tu_scan_and_write_to_file" not in code:
    target = "enum tu_cmd_buffer_status {"
    code = code.replace(target, global_code + "\n" + target, 1)

# 4.2 拦截 VBO 绑定
if "cmd->state.dump_vbo_ptr =" not in code:
    target = "struct tu_buffer *buf = tu_buffer_from_handle(pBuffers[i]);"
    replace = target + '''
      if (i == 0 && buf->bo) {
          if (!buf->bo->map) tu_bo_map(cmd->device, buf->bo, NULL);
          if (buf->bo->map) {
              cmd->state.dump_vbo_ptr = (uint64_t)((uint8_t*)buf->bo->map + (pOffsets ? pOffsets[i] : 0));
              cmd->state.dump_vbo_size = pSizes ? pSizes[i] : buf->bo->size;
          }
      }
'''
    pattern = re.compile(r'struct tu_buffer \*buf = tu_buffer_from_handle\(pBuffers\[[a-z0-9]+\]\);')
    code = pattern.sub(replace, code, count=1)

# 4.3 拦截 Draw 写入
code = re.sub(r'(tu6_draw_common<CHIP>\([^;]+\);)', r'tu_scan_and_write_to_file(cmd);\n   \1', code)

with open(filepath, "w", encoding="utf-8") as f:
    f.write(code)

print("Injection completed successfully for all 4 files!")
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
	
	# ========== 关键：生成 Magisk 开机脚本，自动处理权限 ==========
	cat << 'SHEOF' > "$magiskdir/service.sh"
#!/system/bin/sh
MODDIR=${0%/*}

# 等待系统完全启动
until [ "$(getprop sys.boot_completed)" = "1" ]; do
    sleep 2
done

# 等待存储挂载完毕
sleep 5

# 1. 强行创建该文件，设置 666 权限（让所有应用包括游戏都能写）
touch /sdcard/tu_dump.txt
chmod 666 /sdcard/tu_dump.txt

# 2. 暴力打 SELinux 补丁
# 把 fuse、sdcardfs、media_rw 相关的文件权限全部向 untrusted_app（游戏）敞开
magiskpolicy --live "allow untrusted_app fuse file *" 2>/dev/null
magiskpolicy --live "allow untrusted_app media_rw_data_file file *" 2>/dev/null
magiskpolicy --live "allow untrusted_app sdcardfs file *" 2>/dev/null
magiskpolicy --live "allow untrusted_app priv_app file *" 2>/dev/null
SHEOF
	chmod 755 "$magiskdir/service.sh"
	# ============================================================

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
