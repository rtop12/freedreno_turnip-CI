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

    echo -e "${green}正在注入 全量 VBO 数据实时直传逻辑...${nocolor}"
    
    cat << 'PYEOF' > inject_all.py
import re
import os

# ==========================================
# 1. 修改 tu_device.h
# ==========================================
filepath = "src/freedreno/vulkan/tu_device.h"
with open(filepath, "r", encoding="utf-8") as f:
    code = f.read()

# 在 struct tu_device 中添加 dump_ko_fd
if "int dump_ko_fd;" not in code:
    code = re.sub(r'(struct tu_device\s*\{)', r'\1\n   int dump_ko_fd;', code, count=1)

with open(filepath, "w", encoding="utf-8") as f:
    f.write(code)

# ==========================================
# 2. 修改 tu_device.cc
# ==========================================
filepath = "src/freedreno/vulkan/tu_device.cc"
with open(filepath, "r", encoding="utf-8") as f:
    code = f.read()

# 在 tu_CreateDevice 中初始化 dump_ko_fd
if "device->dump_ko_fd =" not in code:
    target = "device->instance = physical_device->instance;"
    replace = target + '\n   device->dump_ko_fd = open("/dev/my_gpu_dump", O_RDWR | O_NONBLOCK);'
    code = code.replace(target, replace, 1)
    
    # 确保包含 fcntl.h
    if "#include <fcntl.h>" not in code:
        code = "#include <fcntl.h>\n" + code

with open(filepath, "w", encoding="utf-8") as f:
    f.write(code)

# ==========================================
# 3. 修改 tu_cmd_buffer.h
# ==========================================
filepath = "src/freedreno/vulkan/tu_cmd_buffer.h"
with open(filepath, "r", encoding="utf-8") as f:
    code = f.read()

# 在 tu_cmd_state 中记录当前 VBO 的全量指针和大小
if "uint64_t dump_vbo_ptr;" not in code:
    target = "struct tu_cmd_state\n{"
    replace = target + '\n   uint64_t dump_vbo_ptr;\n   uint32_t dump_vbo_size;'
    code = code.replace(target, replace, 1)

with open(filepath, "w", encoding="utf-8") as f:
    f.write(code)

# ==========================================
# 4. 修改 tu_cmd_buffer.cc
# ==========================================
filepath = "src/freedreno/vulkan/tu_cmd_buffer.cc"
with open(filepath, "r", encoding="utf-8") as f:
    code = f.read()

# 4.1 定义数据结构与发送函数
global_code = '''
#include <sys/ioctl.h>
#include <fcntl.h>
#include <unistd.h>

#define TU_IOCTL_ALLOC_BUF _IOW('X', 1, uint32_t)
#define TU_IOCTL_SEND_VBO  _IOW('X', 2, uint32_t)

struct tu_full_cmd {
    uint32_t magic;
    uint64_t user_ptr;
    uint32_t size;
};

static void tu_dump_full_data(struct tu_cmd_buffer *cmd) {
    if (cmd->device->dump_ko_fd >= 0 && cmd->state.dump_vbo_ptr && cmd->state.dump_vbo_size > 0) {
        struct tu_full_cmd vbo_cmd;
        vbo_cmd.magic = 0xDEADBEEF;
        vbo_cmd.user_ptr = cmd->state.dump_vbo_ptr;
        vbo_cmd.size = cmd->state.dump_vbo_size; // 全量！不截断！

        ioctl(cmd->device->dump_ko_fd, TU_IOCTL_ALLOC_BUF, &vbo_cmd.size);
        ioctl(cmd->device->dump_ko_fd, TU_IOCTL_SEND_VBO, &vbo_cmd);
    }
}
'''

if "static void tu_dump_full_data" not in code:
    # 插入到全局作用域
    target = "enum tu_cmd_buffer_status {"
    code = code.replace(target, global_code + "\n" + target, 1)

# 4.2 拦截 tu_CmdBindVertexBuffers2，记录全量指针
if "cmd->state.dump_vbo_ptr =" not in code:
    # 寻找 tu_CmdBindVertexBuffers2 里的 pBuffers 循环
    target = "struct tu_buffer *buf = tu_buffer_from_handle(pBuffers[i]);"
    replace = target + '''
      if (i == 0 && buf->bo) { // 仅记录第一个绑定的VBO
          if (!buf->bo->map) tu_bo_map(cmd->device, buf->bo, NULL);
          if (buf->bo->map) {
              cmd->state.dump_vbo_ptr = (uint64_t)((uint8_t*)buf->bo->map + (pOffsets ? pOffsets[i] : 0));
              cmd->state.dump_vbo_size = pSizes ? pSizes[i] : buf->bo->size;
          }
      }
'''
    # 注意源码里可能是 pBuffers[i] 或 pBuffers[0]，直接用正则精确替换
    pattern = re.compile(r'struct tu_buffer \*buf = tu_buffer_from_handle\(pBuffers\[[a-z0-9]+\]\);')
    code = pattern.sub(replace, code, count=1)

# 4.3 拦截所有的 tu6_draw_common 调用点，全量发送
# 所有的 Direct/Indirect Draw 都会调用 tu6_draw_common<CHIP>，只需在这些调用前插入发送函数
code = re.sub(r'(tu6_draw_common<CHIP>\([^;]+\);)', r'tu_dump_full_data(cmd);\n   \1', code)

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
