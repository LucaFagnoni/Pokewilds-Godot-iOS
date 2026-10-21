#!/usr/bin/env bash
# Builds Pokewilds-unsigned.ipa without a Mac: run it inside WSL (Ubuntu) after
# setup.sh. Same steps as the CI "ios" job, with xtool in place of xcodebuild.
# It builds the committed HEAD, not uncommitted changes. See README.md.
#
#   tools/ios_xtool/build_ipa.sh
#   ENGINE=official tools/ios_xtool/build_ipa.sh   # Godot's own template library, no engine build
#   SMOKE=0 tools/ios_xtool/build_ipa.sh           # skip CI's smoke test of the pack
#
# The versions are the ones CI gives the same commit: MAJOR.MINOR from the iOS
# preset plus the commit count, e.g. 0.10.166 (166).
set -euo pipefail
engine=${ENGINE:-stripped}
smoke=${SMOKE:-1}
[ "$engine" = official ] && smoke=0  # the smoke test checks the stripped profile

GODOT_VERSION=4.7.2
repo=$(cd "$(dirname "$0")/../.." && pwd)
# On WSL's own disk: Godot imports ~17k files, far too slow on /mnt/c or /mnt/d.
work=${WORK:-$HOME/pokewilds-ios}
out=${OUT:-$work/Pokewilds-unsigned.ipa}
cache=$work/cache
mkdir -p "$cache"
export PATH="$HOME/.local/bin:$PATH"
. "${SWIFTLY_HOME_DIR:-$HOME/.local/share/swiftly}/env.sh" 2>/dev/null || true
# The SDK is in ~/.swiftpm or ~/.config/swiftpm, wherever SwiftPM keeps its config.
sdk=$(xtool sdk status 2>/dev/null | grep -A1 "is installed" | sed -n 's/^ *Path: //p')
[ -d "$sdk" ] || { echo "No xtool or iOS SDK: run tools/ios_xtool/setup.sh first" >&2; exit 1; }
ios_sdk=$sdk/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk
swiftbin=$(cd && swiftly use --print-location)/usr/bin

# Godot editor and the official iOS export template (downloaded once).
base=https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}-stable
godot=$cache/Godot_v${GODOT_VERSION}-stable_linux.x86_64
if [ ! -x "$godot" ]; then
  curl -fSL -o "$cache/godot.zip" "$base/Godot_v${GODOT_VERSION}-stable_linux.x86_64.zip"
  unzip -q -o "$cache/godot.zip" -d "$cache" && rm "$cache/godot.zip"
fi
tpl=$HOME/.local/share/godot/export_templates/${GODOT_VERSION}.stable
if [ ! -f "$tpl/ios.zip" ]; then
  curl -fSL -o "$cache/templates.tpz" "$base/Godot_v${GODOT_VERSION}-stable_export_templates.tpz"
  mkdir -p "$tpl"
  unzip -q -o -j "$cache/templates.tpz" templates/ios.zip templates/version.txt -d "$tpl"
  rm "$cache/templates.tpz"
fi

# The stripped engine, built from source with CI's profile: the iOS library
# (ios job) and the Linux headless engine for the smoke test (smoke job). Each is
# built once per Godot version and profile.
profile=$repo/.github/engine/custom.py
key=$GODOT_VERSION-$(sha256sum "$profile" | cut -c1-12)
ios_lib=$cache/engine/libgodot.ios.$key.a
linux_engine=$cache/engine/godot.linuxbsd.$key
src=$cache/godot-src
godot_scons() {
  (cd "$src" && "$cache/scons/bin/scons" target=template_release profile="$profile" -j"$(nproc)" "$@")
}
if { [ "$engine" = stripped ] && [ ! -f "$ios_lib" ]; } || { [ "$smoke" = 1 ] && [ ! -x "$linux_engine" ]; }; then
  [ -d "$src" ] || git clone -q --depth 1 -b "$GODOT_VERSION-stable" https://github.com/godotengine/godot.git "$src"
  # Godot's iOS cross-build ("osxcross" mode) passes the Swift resource dir of its own build container.
  sed -i "s|\"/root/Xcode.app/|\"$sdk/Xcode.app/|" "$src/platform_methods.py"
  if [ ! -x "$cache/scons/bin/scons" ]; then  # stock Ubuntu has no pip: venv + get-pip
    python3 -m venv --without-pip "$cache/scons"
    curl -fsSL https://bootstrap.pypa.io/get-pip.py | "$cache/scons/bin/python" - -q
    "$cache/scons/bin/pip" -q install scons
  fi
  mkdir -p "$cache/engine"
fi
if [ "$engine" = stripped ] && [ ! -f "$ios_lib" ]; then
  # osxcross mode wants <triple>clang, ar, ranlib, libtool in
  # $APPLE_TOOLCHAIN_PATH/usr/bin: here Swift's clang and llvm-ar (named by
  # target, so clang builds for iOS) and xtool's llvm-libtool-darwin.
  tc=$cache/ios-toolchain
  mkdir -p "$tc/usr/bin"
  for t in clang clang++; do ln -sf "$swiftbin/clang" "$tc/usr/bin/arm64-apple-ios-$t"; done
  for t in ar ranlib; do ln -sf "$swiftbin/llvm-ar" "$tc/usr/bin/arm64-apple-ios-$t"; done
  ln -sf "$sdk/toolset/bin/llvm-lib" "$tc/usr/bin/arm64-apple-ios-libtool"
  OSXCROSS_IOS=1 godot_scons platform=ios arch=arm64 lto=thin cache_path="$cache/scons-ios" \
    APPLE_TOOLCHAIN_PATH="$tc" apple_target_triple=arm64-apple-ios- SWIFT_FRONTEND="$swiftbin/swift-frontend" \
    APPLE_SDK_PATH="$ios_sdk"
  cp "$src/bin/libgodot.ios.template_release.arm64.a" "$ios_lib"
fi
if [ "$smoke" = 1 ] && [ ! -x "$linux_engine" ]; then
  godot_scons platform=linuxbsd use_llvm=yes cache_path="$cache/scons-linux" disable_path_overrides=no \
    x11=no wayland=no alsa=no pulseaudio=no dbus=no speechd=no fontconfig=no udev=no
  cp "$src/bin/godot.linuxbsd.template_release.x86_64.llvm" "$linux_engine"
fi

# Fresh copy of the committed project; the .godot import cache is kept between runs.
mkdir -p "$work/project"
find "$work/project" -mindepth 1 -maxdepth 1 ! -name .godot -exec rm -rf {} +
git -C "$repo" -c core.autocrlf=false archive HEAD project | tar -x -C "$work"
python3 "$repo/.github/engine/minify_json.py" "$work/project"
# The lobby list's address and password are never committed (see coop_network.gd).
[ ! -f "$repo/project/lobby_server.txt" ] || cp "$repo/project/lobby_server.txt" "$work/project/"

# The commit this build comes from: hosts refuse players of another build.
git -C "$repo" rev-parse HEAD > "$work/project/build_id.txt"
[ "$(git -C "$repo" rev-parse --is-shallow-repository)" = false ] \
  || { echo "Shallow clone: the version is the commit count, run git fetch --unshallow" >&2; exit 1; }
count=$(git -C "$repo" rev-list --count HEAD)
version="$(sed -n 's/^application\/short_version="\([0-9]*\.[0-9]*\).*/\1/p' "$work/project/export_presets.cfg").$count"
echo "$version" > "$work/project/build_version.txt"  # shown on the title screen
VERSION=$version BUNDLE=$count python3 - "$work/project/export_presets.cfg" <<'EOF'
import os, re, sys
path = sys.argv[1]
text = open(path, newline="").read()
text = re.sub(r'(?m)^application/short_version="[^"]*"', 'application/short_version="%s"' % os.environ["VERSION"], text)
text = re.sub(r'(?m)^application/version="[^"]*"', 'application/version="%s"' % os.environ["BUNDLE"], text)
open(path, "w", newline="").write(text)
EOF

# The phone's battery for the HUD (an iOS plugin): Godot's export copies this
# library into the Xcode project and Package.swift links it, as the ios job's
# xcodebuild does. Same deployment target as the preset.
plugin=$work/project/ios/plugins/pokewilds_battery
"$swiftbin/clang" -target arm64-apple-ios15.0 -isysroot "$ios_sdk" -O2 -fobjc-arc \
  -c "$plugin/pokewilds_battery.mm" -o "$cache/pokewilds_battery.o"
"$swiftbin/llvm-ar" rcs "$plugin/libpokewilds_battery.a" "$cache/pokewilds_battery.o"
# Embedded ZeroTier for ONLINE play: the plugin and libzt, same script as the ios job.
CC="$swiftbin/clang -isysroot $ios_sdk" AR="$swiftbin/llvm-ar" LIBZT_CACHE="$cache/libzt" \
  PLUGIN_DIR="$work/project/ios/plugins/pokewilds_zerotier" bash "$repo/tools/build_libzt_ios.sh"

# Export the Xcode project straight into the SwiftPM package xtool builds.
app=$work/app
rm -rf "$app" && mkdir -p "$app/Sources/Pokewilds" "$app/Sources/GodotPlugins"
cp "$repo/tools/ios_xtool/Package.swift" "$repo/tools/ios_xtool/xtool.yml" "$app/"
: > "$app/Sources/Pokewilds/stub.swift"
(cd "$work/project" && "$godot" --headless --import && "$godot" --headless --export-release "iOS" "$app/Pokewilds.ipa")
cp "$app/Pokewilds/dummy.cpp" "$app/Pokewilds/dummy.h" "$app/Sources/GodotPlugins/"
[ "$engine" = stripped ] && cp "$ios_lib" "$app/Pokewilds.xcframework/ios-arm64/libgodot.a"

# CI's smoke test on the pack going into the IPA: the stripped engine (Linux,
# headless) loads every script and scene, then runs the game for 900 frames.
if [ "$smoke" = 1 ]; then
  log=$work/smoke.log
  timeout 600 "$linux_engine" --headless --main-pack "$app/Pokewilds.pck" -s "$repo/.github/engine/smoke.gd" 2>&1 | tee "$log" || true
  timeout 300 "$linux_engine" --headless --main-pack "$app/Pokewilds.pck" --quit-after 900 2>&1 | tee -a "$log" || true
  grep -E "ERROR|SMOKE" "$log" | sort | uniq -c
  grep -q "SMOKE: checked [0-9]*, failed 0" "$log"
  if grep -E "SMOKE FAIL|SCRIPT ERROR|Parse Error|Cannot get class|Failed to load|not declared in the current scope" "$log"; then
    echo "Smoke test failed: see $log" >&2
    exit 1
  fi
fi

# No ibtool/actool on Linux: plain PNG icons instead of Assets.car, and the
# UILaunchScreen key instead of the launch storyboard.
icons=$app/Pokewilds/Images.xcassets/AppIcon.appiconset
cp "$icons/Icon-120.png" "$app/AppIcon60x60@2x.png"
cp "$icons/Icon-180.png" "$app/AppIcon60x60@3x.png"
cp "$icons/Icon-152.png" "$app/AppIcon76x76@2x~ipad.png"
cp "$icons/Icon-167.png" "$app/AppIcon83.5x83.5@2x~ipad.png"
python3 - "$app" <<'EOF'
import plistlib, re, sys
app = sys.argv[1]
info = plistlib.load(open(f"{app}/Pokewilds/Pokewilds-Info.plist", "rb"))
pbx = open(f"{app}/Pokewilds.xcodeproj/project.pbxproj").read()
# Fill in the $(SETTING)s Xcode would, from the exported project's build settings.
def fill(v):
    if isinstance(v, str):
        return re.sub(r"\$\((\w+)\)", lambda m: re.search(r'\b%s = "?([^";]*)"?;' % m.group(1), pbx).group(1), v)
    if isinstance(v, list):
        return [fill(x) for x in v]
    if isinstance(v, dict):
        return {k: fill(x) for k, x in v.items()}
    return v
info = fill(info)
del info["UILaunchStoryboardName"], info["CFBundleSignature"]
info["UILaunchScreen"] = {}
info["CFBundleIcons"] = {"CFBundlePrimaryIcon": {"CFBundleIconFiles": ["AppIcon60x60"]}}
info["CFBundleIcons~ipad"] = {"CFBundlePrimaryIcon": {"CFBundleIconFiles": ["AppIcon60x60", "AppIcon76x76", "AppIcon83.5x83.5"]}}
plistlib.dump(info, open(f"{app}/Info.plist", "wb"))
EOF

(cd "$app" && xtool dev build --configuration release)

# Same packing as CI: drop local/debug symbols, zip the Payload folder.
rm -rf "$work/Payload" && mkdir "$work/Payload"
mv "$app/xtool/Pokewilds.app" "$work/Payload/"
bin=$work/Payload/Pokewilds.app/Pokewilds
# SwiftPM links through swiftc, which gives clang --sysroot: clang then records
# the deployment target as the SDK version (15.0) and iOS would apply old-SDK
# compatibility behaviour. Write the real SDK version, as Xcode's link does, and
# drop the rpath into this machine's Swift toolchain.
python3 - "$bin" "$ios_sdk/SDKSettings.json" <<'EOF'
import json, struct, sys
path, settings = sys.argv[1:]
data = bytearray(open(path, "rb").read())
major, minor = (json.load(open(settings))["Version"].split(".") + ["0"])[:2]
ncmds, sizeofcmds = struct.unpack_from("<II", data, 16)
off, end, patched = 32, 32 + sizeofcmds, False
for _ in range(ncmds):
    cmd, size = struct.unpack_from("<II", data, off)
    if cmd == 0x32:  # LC_BUILD_VERSION: cmd, cmdsize, platform, minos, sdk
        struct.pack_into("<I", data, off + 16, int(major) << 16 | int(minor) << 8)
        patched = True
    if cmd == 0x8000001C and not data[off + 12:off + size].startswith((b"@", b"/usr/", b"/System/")):  # LC_RPATH
        data[off:end] = data[off + size:end] + bytes(size)
        ncmds, sizeofcmds, end = ncmds - 1, sizeofcmds - size, end - size
        continue
    off += size
assert patched, "no LC_BUILD_VERSION in " + path
struct.pack_into("<II", data, 16, ncmds, sizeofcmds)
open(path, "wb").write(data)
EOF
llvm-objcopy --strip-debug --discard-all "$bin"
llvm-objdump --macho --private-headers "$bin" | grep -E "^ +(sdk|minos|path) "
du -sh "$work/Payload/Pokewilds.app"/*
rm -f "$out" && (cd "$work" && zip -qry -9 "$out" Payload)
echo "Built $out"
if command -v wslpath >/dev/null; then echo "Windows path: $(wslpath -w "$out")"; fi
