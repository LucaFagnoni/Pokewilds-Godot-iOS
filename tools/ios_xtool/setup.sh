#!/usr/bin/env bash
# One-time WSL (Ubuntu) setup for build_ipa.sh: Swift 6.4, xtool and the iOS
# SDK that xtool makes from Xcode.xip. No Apple ID login: the IPA stays unsigned.
#
#   tools/ios_xtool/setup.sh /mnt/d/Downloads/Xcode_27.0.xip
set -euo pipefail
xip=${1:?usage: setup.sh /path/to/Xcode.xip}
XTOOL_VERSION=1.22.2
SWIFT_VERSION=6.4
mkdir -p "$HOME/.local/bin"
export PATH="$HOME/.local/bin:$PATH"

# Swift's Linux dependencies (swift.org/install/linux, Ubuntu 24.04) plus zip.
# Asks for your sudo password only when something is missing.
deps="binutils git gnupg2 libc6-dev libcurl4-openssl-dev libedit2 libgcc-13-dev libncurses-dev
  libpython3-dev libsqlite3-0 libstdc++-13-dev libxml2-dev libz3-dev pkg-config tzdata unzip zip
  zlib1g-dev curl python3"
dpkg -s $deps >/dev/null 2>&1 || { sudo apt-get update && sudo apt-get install -y $deps; }

# Swift via swiftly, installed in your home directory.
if ! command -v swiftly >/dev/null; then
  tmp=$(mktemp -d)
  curl -fsSL "https://download.swift.org/swiftly/linux/swiftly-$(uname -m).tar.gz" | tar -xz -C "$tmp"
  "$tmp/swiftly" init --assume-yes --skip-install --quiet-shell-followup
  rm -rf "$tmp"
fi
. "${SWIFTLY_HOME_DIR:-$HOME/.local/share/swiftly}/env.sh"
# From $HOME: inside a checkout, swiftly would pin it with a .swift-version file.
(cd && swiftly install --use "$SWIFT_VERSION")
swift --version

# xtool, unpacked from its AppImage (no FUSE needed).
if ! xtool --version 2>/dev/null | grep "$XTOOL_VERSION" >/dev/null; then
  tmp=$(mktemp -d)
  curl -fSL -o "$tmp/xtool.AppImage" \
    "https://github.com/xtool-org/xtool/releases/download/$XTOOL_VERSION/xtool-$(uname -m).AppImage"
  chmod +x "$tmp/xtool.AppImage"
  (cd "$tmp" && ./xtool.AppImage --appimage-extract >/dev/null)
  rm -rf "$HOME/.local/opt/xtool" && mkdir -p "$HOME/.local/opt"
  mv "$tmp/squashfs-root" "$HOME/.local/opt/xtool" && rm -rf "$tmp"
  ln -sf "$HOME/.local/opt/xtool/AppRun" "$HOME/.local/bin/xtool"
fi

# The iOS SDK, made from Xcode.xip (about a minute; it unpacks all of Xcode first).
xtool sdk status | grep "is installed" >/dev/null || xtool sdk install "$xip"
xtool sdk status
