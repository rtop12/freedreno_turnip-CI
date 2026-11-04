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

    echo -e "${green}正在向 tu_cmd_buffer.cc 注入 ESP Dump 代码...${nocolor}"
    cat << 'PYEOF' > inject.py
import re

filepath = "src/freedreno/vulkan/tu_cmd_buffer.cc"
with open(filepath, "r", encoding="utf-8") as f:
    code = f.read()

global_code = '''
#include <stdio.h>
#include <string.h>

static float g_current_matrix[16] = {0};
static uint64_t g_current_vbo_iova = 0;
static uint32_t g_current_vbo_size = 0;
static uint64_t g_last_vbo_iova = 0;

static void dump_draw_data(struct tu_device *device, uint32_t count) {
    if (count < 500 || g_current_vbo_iova == 0) return;
    if (g_current_vbo_iova == g_last_vbo_iova) return;
    g_last_vbo_iova = g_current_vbo_iova;

    struct tu_bo *bo = tu_device_lookup_bo(device, g_current_vbo_iova);
    if (bo && bo->map) {
        uint64_t offset_in_bo = g_current_vbo_iova - bo->iova;
        void *cpu_vbo_ptr = (void *)((char *)bo->map + offset_in_bo);

        // 强行写 /data/local/tmp/，配合 Magisk 脚本提权
        FILE *fp = fopen("/data/local/tmp/vulkan_dump.txt", "a+");
        if (fp) {
            fprintf(fp, "--- Draw Call (Count: %u) ---\\n", count);
            fprintf(fp, "Matrix: ");
            for (int i = 0; i < 16; i++) fprintf(fp, "%f, ", g_current_matrix[i]);
            fprintf(fp, "\\nVertices:\\n");
            
            float* verts = (float*)cpu_vbo_ptr;
            uint32_t num_verts = (g_current_vbo_size / 12);
            if (num_verts > 5) num_verts = 5; 
            for (uint32_t v = 0; v < num_verts; v++) {
                fprintf(fp, "  V%d: X=%f, Y=%f, Z=%f\\n", v, verts[v*3], verts[v*3+1], verts[v*3+2]);
            }
            fprintf(fp, "\\n");
            fclose(fp);
        }
    }
}
'''
code = code.replace('#include "tu_trace_bin_layout.h"', '#include "tu_trace_bin_layout.h"\n' + global_code)

code = code.replace(
    'cmd->state.dirty |= TU_CMD_DIRTY_SHADER_CONSTS;\n}\nTU_GENX(tu_CmdPushConstants2KHR);',
    'cmd->state.dirty |= TU_CMD_DIRTY_SHADER_CONSTS;\n   if (pPushConstantsInfo->size >= 64) memcpy(g_current_matrix, pPushConstantsInfo->pValues, 64);\n}\nTU_GENX(tu_CmdPushConstants2KHR);'
)

code = code.replace(
    'cmd->state.dirty |= TU_CMD_DIRTY_VERTEX_BUFFERS;\n}\n',
    '   if (bindingCount > 0) { g_current_vbo_iova = cmd->state.vb[firstBinding].base; g_current_vbo_size = cmd->state.vb[firstBinding].size; }\n   cmd->state.dirty |= TU_CMD_DIRTY_VERTEX_BUFFERS;\n}\n',
    1
)

code = code.replace('tu6_emit_vs_params(cmd, NULL, 0, firstVertex, firstInstance);\n\n   tu6_draw_common<CHIP>(cmd, cs, false, vertexCount);', 'dump_draw_data(cmd->device, vertexCount);\n   tu6_emit_vs_params(cmd, NULL, 0, firstVertex, firstInstance);\n\n   tu6_draw_common<CHIP>(cmd, cs, false, vertexCount);')
code = code.replace('tu6_emit_vs_params(cmd, NULL, 0, vertexOffset, firstInstance);\n\n   tu6_draw_common<CHIP>(cmd, cs, true, indexCount);', 'dump_draw_data(cmd->device, indexCount);\n   tu6_emit_vs_params(cmd, NULL, 0, vertexOffset, firstInstance);\n\n   tu6_draw_common<CHIP>(cmd, cs, true, indexCount);')
code = code.replace('tu6_draw_common<CHIP>(cmd, cs, false, 0);\n\n   const uint32_t dst_off = vs_params_offset(cmd);', 'dump_draw_data(cmd->device, 99999);\n   tu6_draw_common<CHIP>(cmd, cs, false, 0);\n\n   const uint32_t dst_off = vs_params_offset(cmd);')
code = code.replace('tu6_draw_common<CHIP>(cmd, cs, true, 0);\n\n   const uint32_t dst_off = vs_params_offset(cmd);', 'dump_draw_data(cmd->device, 99999);\n   tu6_draw_common<CHIP>(cmd, cs, true, 0);\n\n   const uint32_t dst_off = vs_params_offset(cmd);')

code = code.replace('return vk_command_buffer_end(&cmd_buffer->vk);', 'g_last_vbo_iova = 0;\n   return vk_command_buffer_end(&cmd_buffer->vk);')

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

	if [ $? -ne 0 ]; then
		echo -e "$red Meson setup failed! $nocolor" && exit 1
	fi

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

	# 【核心修改】注入提权脚本 post-fs-data.sh
	cat <<EOF >"$magiskdir/post-fs-data.sh"
#!/system/bin/sh
# 预创建文件并赋予最高权限，确保游戏进程能写
touch /data/local/tmp/vulkan_dump.txt
chmod 777 /data/local/tmp/vulkan_dump.txt
chown 2000:2000 /data/local/tmp/vulkan_dump.txt
# 改变 SELinux 上下文，允许普通应用写入
chcon u:object_r:system_file:s0 /data/local/tmp/vulkan_dump.txt
EOF
	chmod +x "$magiskdir/post-fs-data.sh"

	cat <<EOF >"$magiskdir/customize.sh"
set_perm_recursive \$MODPATH/system 0 0 755 u:object_r:system_file:s0
set_perm_recursive \$MODPATH/system/vendor 0 2000 755 u:object_r:vendor_file:s0
set_perm \$MODPATH/$p1/vulkan.adreno.so 0 0 0644 u:object_r:same_process_hal_file:s0
set_perm \$MODPATH/post-fs-data.sh 0 0 0755 u:object_r:system_file:s0
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
