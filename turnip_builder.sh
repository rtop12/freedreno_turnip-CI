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

    echo -e "${green}正在注入 严格进程过滤版探针...${nocolor}"
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

static float g_current_matrix[16] = {0};
static uint64_t g_current_vbo_iova = 0;
static uint64_t g_saved_desc_iova[MAX_SETS] = {0};

// 强力判断是不是三角洲行动
static bool is_game_process() {
    char buf[256] = {0};
    int fd = open("/proc/self/cmdline", O_RDONLY);
    if (fd < 0) return false;
    int len = read(fd, buf, sizeof(buf) - 1);
    close(fd);
    // 必须精确匹配进程名
    return strstr(buf, "com.tencent.tmgp.dfm") != NULL;
}

static void log_all_data(struct tu_cmd_buffer *cmd, const char* func_name, uint32_t count) {
    if (!is_game_process()) return;

    // 限制打印频率，防止刷屏
    static uint32_t dump_cnt = 0;
    if (dump_cnt++ % 50 != 0) return; 

    mesa_loge("ESP_GAME: --- %s (Count: %u) ---", func_name, count);
    
    // 1. 检查矩阵
    bool has_mat = false;
    for(int i=0; i<16; i++) if(g_current_matrix[i] != 0.0f) { has_mat = true; break; }
    if (has_mat) {
        mesa_loge("ESP_GAME: Matrix: %.2f %.2f %.2f %.2f | %.2f %.2f %.2f %.2f", 
              g_current_matrix[0], g_current_matrix[1], g_current_matrix[2], g_current_matrix[3],
              g_current_matrix[12], g_current_matrix[13], g_current_matrix[14], g_current_matrix[15]);
    }

    // 2. 检查 VBO
    if (g_current_vbo_iova != 0) {
        struct tu_bo *bo = tu_device_lookup_bo(cmd->device, g_current_vbo_iova);
        if (bo && bo->map) {
            float *vals = (float*)((char *)bo->map + (g_current_vbo_iova - bo->iova));
            mesa_loge("ESP_GAME: VBO Data: %.2f %.2f %.2f | %.2f %.2f %.2f", 
                      vals[0], vals[1], vals[2], vals[3], vals[4], vals[5]);
        }
    }

    // 3. 检查 Descriptor Sets
    for (int i=0; i<MAX_SETS; i++) {
        if (g_saved_desc_iova[i] == 0) continue;
        struct tu_bo *bo = tu_device_lookup_bo(cmd->device, g_saved_desc_iova[i]);
        if (bo && bo->map) {
            float *vals = (float*)((char *)bo->map + (g_saved_desc_iova[i] - bo->iova));
            mesa_loge("ESP_GAME: Desc[%d] Data: %.2f %.2f %.2f | %.2f %.2f %.2f", 
                      i, vals[0], vals[1], vals[2], vals[3], vals[4], vals[5]);
        }
    }
}
'''

code = code.replace('enum tu_cmd_buffer_status {', global_code + '\nenum tu_cmd_buffer_status {')

code = code.replace(
    'cmd->state.dirty |= TU_CMD_DIRTY_SHADER_CONSTS;\n}\nTU_GENX(tu_CmdPushConstants2KHR);',
    '''cmd->state.dirty |= TU_CMD_DIRTY_SHADER_CONSTS;
   if (pPushConstantsInfo->size >= 64) {
       memcpy(g_current_matrix, pPushConstantsInfo->pValues, 64);
   }
}
TU_GENX(tu_CmdPushConstants2KHR);'''
)

code = code.replace(
    'cmd->state.dirty |= TU_CMD_DIRTY_VERTEX_BUFFERS;\n}\n',
    '''   if (bindingCount > 0) { 
       g_current_vbo_iova = cmd->state.vb[firstBinding].base; 
   }
   cmd->state.dirty |= TU_CMD_DIRTY_VERTEX_BUFFERS;
}\n''',
    1
)

code = code.replace(
    'descriptors_state->set_iova[idx] = set ? (set->va | BINDLESS_DESCRIPTOR_64B) : 0;',
    '''descriptors_state->set_iova[idx] = set ? (set->va | BINDLESS_DESCRIPTOR_64B) : 0;
       if (set && idx < MAX_SETS) {
           g_saved_desc_iova[idx] = set->va;
       }'''
)

code = code.replace('tu6_draw_common<CHIP>(cmd, cs, false, vertexCount);', 
                    'log_all_data(cmd, "tu_CmdDraw", vertexCount);\n   tu6_draw_common<CHIP>(cmd, cs, false, vertexCount);')
code = code.replace('tu6_draw_common<CHIP>(cmd, cs, true, indexCount);', 
                    'log_all_data(cmd, "tu_CmdDrawIndexed", indexCount);\n   tu6_draw_common<CHIP>(cmd, cs, true, indexCount);')

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
