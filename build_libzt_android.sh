#!/bin/bash
# Builds libzt (the embeddable ZeroTier node) for Android and puts the AAR
# where the game's Gradle export picks it up:
#   project/android/build/libs/zerotier/libzt-release.aar
#
# Needs: JDK 17, Android SDK with the NDK and CMake packages below, and the
# libzt source with its submodules (git clone --recursive
# https://github.com/zerotier/libzt). Run once; rerun only to update libzt.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
LIBZT_SRC="${LIBZT_SRC:-$HERE/../third_party/libzt}"
# Build outside the source drive: exFAT/FAT volumes break Gradle and CMake.
WORK="${LIBZT_WORK:-$HOME/Library/Caches/pokewilds-libzt}"
OUT="$HERE/project/android/build/libs/zerotier"
NDK_VERSION="${NDK_VERSION:-29.0.14206865}"   # same NDK the Godot export uses
CMAKE_VERSION="${CMAKE_VERSION:-3.22.1}"

: "${ANDROID_HOME:?Set ANDROID_HOME to your Android SDK folder}"
[ -f "$LIBZT_SRC/ext/ZeroTierOne/node/Node.cpp" ] || {
    echo "libzt submodules are missing in $LIBZT_SRC (git submodule update --init)"; exit 1; }
[ -d "$ANDROID_HOME/ndk/$NDK_VERSION" ] || {
    echo "Install NDK $NDK_VERSION: sdkmanager \"ndk;$NDK_VERSION\" \"cmake;$CMAKE_VERSION\""; exit 1; }

mkdir -p "$WORK" "$OUT"
rsync -a --delete --exclude '.git' --exclude '._*' --exclude 'cache' --exclude 'dist' "$LIBZT_SRC/" "$WORK/"

python3 "$HERE/libzt_patches.py" "$WORK"

GRADLE="$WORK/pkg/android/app/build.gradle"
# Only the two ABIs the game exports, built with the game's NDK.
sed -i.bak \
    -e 's/abiFilters .*/abiFilters "armeabi-v7a", "arm64-v8a"/' \
    -e "s/ndkVersion '.*'/ndkVersion '$NDK_VERSION'/" \
    -e "s/version '3\\.22\\.1'/version '$CMAKE_VERSION'/" \
    "$GRADLE"

cd "$WORK/pkg/android"
chmod +x gradlew
./gradlew --no-daemon assembleRelease
cp app/build/outputs/aar/libzt-release.aar "$OUT/libzt-release.aar"
echo "Built $OUT/libzt-release.aar"
