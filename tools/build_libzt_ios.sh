#!/usr/bin/env bash
# Builds libpokewilds_zerotier.a, the iOS ZeroTier plugin
# (project/ios/plugins/pokewilds_zerotier): its .mm plus libzt, the embeddable
# ZeroTier node, for iOS arm64. Both IPA builds run it before Godot's export:
#   CI's ios job (Mac):  CC="xcrun -sdk iphoneos clang" AR="xcrun -sdk iphoneos ar" bash tools/build_libzt_ios.sh
#   tools/ios_xtool:     CC="<swift>/clang -isysroot <iOS SDK>" AR=<swift>/llvm-ar PLUGIN_DIR=... LIBZT_CACHE=... bash tools/build_libzt_ios.sh
#
# libzt is fetched at the commit below with its submodules and patched with
# libzt_patches.py, like the Android build (build_libzt_android.sh). No CMake:
# the sources and flags are those of libzt's CMakeLists.txt for its static
# library with the C API and no central API. The compiled libzt is kept in
# LIBZT_CACHE, one folder per commit and patch set; with it there, only the
# plugin itself is compiled.
set -euo pipefail
LIBZT_COMMIT=a707ea6ae0910efdc1125d04758c411e2e9ea4f9
repo=$(cd "$(dirname "$0")/.." && pwd)
plugin=${PLUGIN_DIR:-$repo/project/ios/plugins/pokewilds_zerotier}
: "${CC:?set CC to a clang for iOS}" "${AR:?set AR}"
target="-target arm64-apple-ios15.0"
hash=$( (cat "$repo/libzt_patches.py"; sed -n '/^# --- libzt ---/,/^# --- end ---/p' "$0") | (sha256sum 2>/dev/null || shasum -a 256) | cut -c1-12)
cache=${LIBZT_CACHE:-$HOME/.cache/pokewilds-libzt-ios}/${LIBZT_COMMIT:0:12}-$hash

# --- libzt ---
if [ ! -f "$cache/done" ]; then
  rm -rf "$cache" && mkdir -p "$cache/obj" "$cache/include"
  src=$cache/src
  git clone -q https://github.com/zerotier/libzt "$src"
  git -C "$src" -c advice.detachedHead=false checkout -q "$LIBZT_COMMIT"
  git -C "$src" submodule -q update --init
  python3 "$repo/libzt_patches.py" "$src"
  zto=$src/ext/ZeroTierOne lwip=$src/ext/lwip/src port=$src/ext/lwip-contrib/ports/unix/port
  inc="-I$zto -I$zto/include -I$zto/node -I$zto/osdep -I$zto/ext/libnatpmp
    -I$zto/ext/prometheus-cpp-lite-1.0/core/include -I$zto/ext/prometheus-cpp-lite-1.0/simpleapi/include
    -I$src/src -I$src/include -I$src/ext/concurrentqueue -I$lwip/include -I$port/include"
  # _DARWIN_UNLIMITED_SELECT: libzt_patches.py widens select()'s descriptor
  # sets; without it Darwin's select() refuses more than FD_SETSIZE.
  flags="$target -O3 -w -fstack-protector -D_DARWIN_UNLIMITED_SELECT $inc
    -DZT_SDK=1 -DZT_USE_MINIUPNPC=1 -D_USING_LWIP_DEFINITIONS_=0 -DOMIT_JSON_SUPPORT=1 -DZTS_DISABLE_CENTRAL_API=1"
  upnp="-DMINIUPNP_STATICLIB -D_DARWIN_C_SOURCE -DMINIUPNPC_SET_SOCKET_TIMEOUT -DMINIUPNPC_GET_SRC_ADDR
    -D_BSD_SOURCE -D_DEFAULT_SOURCE -DMINIUPNPC_VERSION_STRING=\\\"2.0\\\" -DUPNP_VERSION_STRING=\\\"UPnP/1.1\\\"
    -DENABLE_STRNATPMPERR -DOS_STRING=\\\"Darwin/15.0.0\\\""
  # One command line per file, run on every core.
  rules() {  # extra flags, then source files
    local extra=$1; shift
    for file in "$@"; do
      echo "$CC $(echo $flags) $extra -c $file -o $cache/obj/$(echo "${file#$src/}" | tr '/' '_').o"
    done
  }
  {
    rules "-std=c++17" "$zto"/node/*.cpp "$zto/osdep/OSUtils.cpp" "$zto/osdep/PortMapper.cpp" "$src"/src/*.cpp
    rules "-DNATPMP_EXPORTS" "$zto/ext/libnatpmp/natpmp.c" "$zto/ext/libnatpmp/getgateway.c"
    rules "$(echo $upnp) -DZT_USE_MINIUPNPC" "$zto"/ext/miniupnpc/{connecthostport,igd_desc_parse,minisoap,minissdpc,miniupnpc,miniwget,minixml,portlistingparse,receivedata,upnpcommands,upnpdev,upnperrors,upnpreplyparse}.c
    rules "-DLWIP_DBG_TYPES_ON=0" $(ls "$lwip"/netif/*.c | grep -v slipif.c) "$lwip"/api/*.c "$port/sys_arch.c" \
      "$lwip"/core/*.c "$lwip"/core/ipv4/*.c "$lwip"/core/ipv6/*.c
  } > "$cache/commands"
  tr '\n' '\0' < "$cache/commands" | xargs -0 -n1 -P"$(getconf _NPROCESSORS_ONLN)" sh -c
  cp "$src/include/ZeroTierSockets.h" "$cache/include/"
  rm -rf "$src" "$cache/commands"
  touch "$cache/done"
fi
# --- end ---

# Without C++ exceptions, like Godot's own code (a failure aborts instead).
$CC $target -O2 -fobjc-arc -fno-exceptions -std=c++17 -I"$cache/include" -c "$plugin/pokewilds_zerotier.mm" -o "$cache/pokewilds_zerotier.o"
rm -f "$plugin/libpokewilds_zerotier.a"
$AR rcs "$plugin/libpokewilds_zerotier.a" "$cache"/obj/*.o "$cache/pokewilds_zerotier.o"
echo "Built $plugin/libpokewilds_zerotier.a"
