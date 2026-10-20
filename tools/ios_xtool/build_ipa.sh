#!/usr/bin/env bash
# Builds Pokewilds-unsigned.ipa without a Mac: run it inside WSL (Ubuntu) after
# setup.sh. Same steps as the CI "ios" job, with xtool in place of xcodebuild.
# It builds the committed HEAD, not uncommitted changes. See README.md.
#
#   tools/ios_xtool/build_ipa.sh            # versions from export_presets.cfg
#   RUN=7 tools/ios_xtool/build_ipa.sh      # versions CI run 7 would give: 0.10.7 (107)
set -euo pipefail

GODOT_VERSION=4.7.2
repo=$(cd "$(dirname "$0")/../.." && pwd)
# On WSL's own disk: Godot imports ~17k files, far too slow on /mnt/c or /mnt/d.
work=${WORK:-$HOME/pokewilds-ios}
out=${OUT:-$work/Pokewilds-unsigned.ipa}
cache=$work/cache
mkdir -p "$cache"
export PATH="$HOME/.local/bin:$PATH"
. "${SWIFTLY_HOME_DIR:-$HOME/.local/share/swiftly}/env.sh" 2>/dev/null || true
xtool sdk status 2>/dev/null | grep "is installed" >/dev/null || { echo "No xtool or iOS SDK: run tools/ios_xtool/setup.sh first" >&2; exit 1; }

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

# Fresh copy of the committed project; the .godot import cache is kept between runs.
mkdir -p "$work/project"
find "$work/project" -mindepth 1 -maxdepth 1 ! -name .godot -exec rm -rf {} +
git -C "$repo" -c core.autocrlf=false archive HEAD project | tar -x -C "$work"
python3 "$repo/.github/engine/minify_json.py" "$work/project"

# The commit this build comes from: hosts refuse players of another build.
git -C "$repo" rev-parse HEAD > "$work/project/build_id.txt"
if [ -n "${RUN:-}" ]; then
  VERSION="$(sed -n 's/^application\/short_version="\([0-9]*\.[0-9]*\).*/\1/p' "$work/project/export_presets.cfg").$RUN" \
  BUNDLE=$((100 + RUN)) python3 - "$work/project/export_presets.cfg" <<'EOF'
import os, re, sys
path = sys.argv[1]
text = open(path, newline="").read()
text = re.sub(r'(?m)^application/short_version="[^"]*"', 'application/short_version="%s"' % os.environ["VERSION"], text)
text = re.sub(r'(?m)^application/version="[^"]*"', 'application/version="%s"' % os.environ["BUNDLE"], text)
open(path, "w", newline="").write(text)
EOF
fi

# Export the Xcode project straight into the SwiftPM package xtool builds.
app=$work/app
rm -rf "$app" && mkdir -p "$app/Sources/Pokewilds" "$app/Sources/GodotPlugins"
cp "$repo/tools/ios_xtool/Package.swift" "$repo/tools/ios_xtool/xtool.yml" "$app/"
: > "$app/Sources/Pokewilds/stub.swift"
(cd "$work/project" && "$godot" --headless --import && "$godot" --headless --export-release "iOS" "$app/Pokewilds.ipa")
cp "$app/Pokewilds/dummy.cpp" "$app/Pokewilds/dummy.h" "$app/Sources/GodotPlugins/"

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
python3 - "$bin" "$HOME/.swiftpm/swift-sdks/darwin.artifactbundle/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk/SDKSettings.json" <<'EOF'
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
command -v wslpath >/dev/null && echo "Windows path: $(wslpath -w "$out")"
