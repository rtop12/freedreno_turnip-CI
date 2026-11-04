#!/bin/bash -e

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

run_all(){
	check_deps
	prepare_workdir
	inject_dump_code
	build_lib_for_android
	port_lib_for_magisk
	port_lib_for_adrenotools
}

check_deps(){
	echo "Checking system for required Dependencies ..."
	for deps_chk in $deps; do
		sleep 0.1
		if command -v "$deps_chk" >/dev/null 2>&1 ; then echo -e "$green - $deps_chk found $nocolor";
		else echo -e "$red - $deps_chk not found $nocolor"; deps_missing=1; fi;
	done
	if [ "$deps_missing" == "1" ]; then echo "Please install missing dependencies" && exit 1; fi
	pip install mako &> /dev/null
}

prepare_workdir(){
	echo "Preparing work directory ..."
	mkdir -p "$workdir" && cd "$_"
	curl https://dl.google.com/android/repository/"$ndkver"-linux.zip --output "$ndkver"-linux.zip &> /dev/null
	unzip -q "$ndkver"-linux.zip
	curl "$mesasrc" --output mesa-main.zip &> /dev/null
	unzip -q mesa-main.zip
	cd mesa-main
}

inject_dump_code(){
	echo "Injecting Hook code ..."
	
	# 1. 在 tu_util.cc 中注入纯 C 接口，不依赖任何 C++ 结构体
	cat << 'EOF' >> "$workdir/mesa-main/src/freedreno/vulkan/tu_util.cc"

#include <stdio.h>
#include <stdlib.h>
extern "C" void tu_dump_cmd(uint32_t type, uint32_t v_count, uint32_t push_size, const void* push_data, const void* vbo_data) {
    static FILE* f = NULL;
    static uint32_t count = 0;
    if (count > 2000) return; // 限制抓取次数避免卡死
    if (!f) f = fopen("/sdcard/turnip_dump.bin", "wb");
    if (!f) return;
    
    uint32_t hdr[4] = {0x54554450, type, v_count, push_size};
    fwrite(hdr, sizeof(hdr), 1, f);
    if (push_data && push_size) fwrite(push_data, 1, push_size, f);
    if (vbo_data) fwrite(vbo_data, 1, 4096, f); // 固定抓 4KB 顶点数据
    fflush(f);
    count++;
}
EOF

	cd "$workdir/mesa-main/src/freedreno/vulkan"
	
	python3 - <<'PYEOF'
import sys
file_path = "tu_cmd_buffer.cc"
with open(file_path, "r", encoding="utf-8") as f: content = f.read()

def replace(c, a, n, code):
    if a not in c: 
        print(f"ERROR: Cannot find anchor {n}"); sys.exit(1)
    return c.replace(a, code + "\n" + a, 1)

# 头文件引入和全局变量
header = """
extern "C" void tu_dump_cmd(uint32_t type, uint32_t v_count, uint32_t push_size, const void* push_data, const void* vbo_data);
static const void* g_push_ptr = NULL;
static uint32_t g_push_size = 0;
"""
content = replace(content, '#include "tu_trace_bin_layout.h"', "Header", header)

# 1. 拦截 Push Constants (直接保存指针)
push_code = """
   if (pPushConstantsInfo->stageFlags & VK_SHADER_STAGE_VERTEX_BIT) {
       g_push_ptr = pPushConstantsInfo->pValues;
       g_push_size = pPushConstantsInfo->size;
   }
"""
content = replace(content, "pPushConstantsInfo->pValues, pPushConstantsInfo->size);", "Push", push_code)

# 2. 遍历当前所有 BO 查找对应的 map 指针
# 由于我们不能用 tu_device_lookup_bo 猜 handle，我们用最原始的方式：
# turnip 的 suballoc / scratch 机制我们把指针直接转成 uint64_t 记录
vbo_hack = """
   const void* vbo_data = NULL;
   uint64_t vbo_addr = cmd->state.vb[0].base;
   if (vbo_addr) {
       // 暴力遍历 device 的 bo_map
       uint32_t max_handle = cmd->device->bo_map.size;
       for (uint32_t h = 1; h < max_handle; h++) {
           struct tu_bo *bo = (struct tu_bo *)util_sparse_array_get(&cmd->device->bo_map, h);
           if (bo && bo->iova && vbo_addr >= bo->iova && vbo_addr < bo->iova + bo->size) {
               if (bo->map) vbo_data = (char*)bo->map + (vbo_addr - bo->iova);
               break;
           }
       }
   }
"""

# 3. 拦截 CmdDraw
draw_code = vbo_hack + """
   tu_dump_cmd(0, vertexCount, g_push_size, g_push_ptr, vbo_data);
"""
content = replace(content, "tu6_emit_vs_params(cmd, NULL, 0, firstVertex, firstInstance);", "CmdDraw", draw_code)

# 4. 拦截 CmdDrawIndexed
draw_idx_code = vbo_hack + """
   tu_dump_cmd(1, indexCount, g_push_size, g_push_ptr, vbo_data);
"""
content = replace(content, "tu6_emit_vs_params(cmd, NULL, 0, vertexOffset, firstInstance);", "CmdDrawIndexed", draw_idx_code)

with open(file_path, "w", encoding="utf-8") as f: f.write(content)
print("Injection successful.")
PYEOF
}

build_lib_for_android(){
	mkdir -p "$workdir/bin"
	ln -sf "$ndk/clang" "$workdir/bin/cc"
	ln -sf "$ndk/clang++" "$workdir/bin/c++"
	export PATH="$workdir/bin:$ndk:$PATH"
	export CC=clang; export CXX=clang++; export AR=llvm-ar; export RANLIB=llvm-ranlib
	export STRIP=llvm-strip; export OBJDUMP=llvm-objdump; export OBJCOPY=llvm-objcopy
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

	meson setup build-android-aarch64 --cross-file "android-aarch64.txt" --native-file "native.txt" \
		-Dbuildtype=release -Dplatforms=android -Dplatform-sdk-version="$sdkver" -Dandroid-stub=true \
		-Dgallium-drivers= -DVulkan-drivers=freedreno -DVulkan-beta=true -Dfreedreno-kmds=kgsl \
		-Db_lto=true -Dstrip=true -Degl=disabled &> "$workdir/meson_log"

	ninja -C build-android-aarch64 &> "$workdir/ninja_log"
	if ! [ -a "$workdir"/mesa-main/build-android-aarch64/src/freedreno/vulkan/libvulkan_freedreno.so ]; then
		echo -e "$red Build failed! $nocolor" && tail -n 30 "$workdir/ninja_log" && exit 1
	fi
}

port_lib_for_magisk(){
	cp "$workdir"/mesa-main/build-android-aarch64/src/freedreno/vulkan/libvulkan_freedreno.so "$workdir"
	cd "$workdir"
	patchelf --set-soname vulkan.adreno.so libvulkan_freedreno.so
	mv libvulkan_freedreno.so vulkan.adreno.so

	p1="system/vendor/lib64/hw"
	mkdir -p "$magiskdir" && cd "$_"
	mkdir -p "$p1"
	meta="META-INF/com/google/android"
	mkdir -p "$meta"

	printf '#!/system/bin/sh\numask 022\nui_print() { echo "$1"; }\nOUTFD=$2\nZIPFILE=$3\n. /data/adb/magisk/util_functions.sh\ninstall_module\nexit 0\n' > "$meta/update-binary"
	printf '#MAGISK\n' > "$meta/updater-script"
	printf 'id=turnip\nname=turnip\nversion=%s\nversionCode=1\nauthor=MrMiy4mo\ndescription=Turnip\n' "$(cat $workdir/mesa-main/VERSION)" > "module.prop"
	printf 'set_perm_recursive $MODPATH/system 0 0 755 u:object_r:system_file:s0\nset_perm_recursive $MODPATH/system/vendor 0 2000 755 u:object_r:vendor_file:s0\nset_perm $MODPATH/%s/vulkan.adreno.so 0 0 0644 u:object_r:same_process_hal_file:s0\n' "$p1" > "customize.sh"

	cp "$workdir"/vulkan.adreno.so "$magiskdir"/"$p1"
	zip -r "$workdir"/turnip.zip ./* &> /dev/null
	echo -e "$green-All done! $nocolor"
}

port_lib_for_adrenotools(){
	libname=vulkan.freedreno.so
	cp "$workdir"/mesa-main/build-android-aarch64/src/freedreno/vulkan/libvulkan_freedreno.so "$workdir"/$libname
	cd "$workdir"
	patchelf --set-soname $libname $libname
	printf '{\n\t"schemaVersion": 1,\n\t"name": "turnip",\n\t"description": "%s",\n\t"author": "MrMiy4mo, kethen",\n\t"packageVersion": "1",\n\t"vendor": "Mesa",\n\t"driverVersion": "%s",\n\t"minApi": %s,\n\t"libraryName": "%s"\n}\n' "$(date)" "$(cat $workdir/mesa-main/VERSION)" "$sdkver" "$libname" > "meta.json"
	zip -9 "$workdir"/turnip_adrenotools.zip $libname meta.json &> /dev/null
	echo -e "$green-All done! $nocolor"
}

run_all
