# iPhone IPA without a Mac (WSL + xtool)

Fallback for when GitHub has no macOS runner for the `ios` job: builds the
unsigned `Pokewilds-unsigned.ipa` on a Windows PC, inside WSL, with
[xtool](https://github.com/xtool-org/xtool) in place of Xcode. Sign it with
Feather as usual.

The steps mirror the `ios` job in `.github/workflows/build.yml`: minify JSON,
stamp `build_id.txt` and the versions, import and export the "iOS" preset with
Godot 4.7.2, build the app, strip it, zip `Payload/`. Godot's export only makes
an Xcode project; `Package.swift` and `xtool.yml` turn it into a SwiftPM
package that xtool builds into `Pokewilds.app`.

## What you need

- WSL 2 with Ubuntu 24.04 (`wsl -d Ubuntu`).
- `Xcode.xip` (**Xcode 27**), downloaded with your Apple ID from
  <https://developer.apple.com/download/all/?q=Xcode>. xtool only takes the iOS
  SDK out of it; there is no Apple ID login in xtool, the IPA stays unsigned.
  Note that Apple's Xcode licence only allows the SDK on Apple hardware.
- Disk on C: (the WSL disk): ~12 GB once set up (SDK 7 GB, Swift 3.6 GB,
  build folder 1.4 GB), more while the SDK is being made.

## One-time setup (Ubuntu terminal, from the repo)

```bash
bash tools/ios_xtool/setup.sh /mnt/e/XCode/Xcode_27.1.xip
```

It installs Swift's Ubuntu packages with `sudo apt-get` (asks your password,
only when something is missing), Swift 6.4 with swiftly in your home folder,
xtool 1.22.2 (unpacked from its AppImage), and the iOS SDK made from the
`.xip` (about a minute). Running it again only fills in what is missing.

## Build

From a checkout that Linux git can read: the main checkout on D:
(`cd /mnt/d/Repositories/pokewilds/Pokewilds-Godot`) or a clone inside WSL. Not
from a Windows `git worktree`: its `.git` file holds a `D:/` path. The script
builds the committed `HEAD`, not uncommitted changes.

```bash
bash tools/ios_xtool/build_ipa.sh           # versions from export_presets.cfg (0.10.0, 93)
RUN=7 bash tools/ios_xtool/build_ipa.sh     # the versions CI run 7 would give: 0.10.7 (107)
```

As a fallback for a CI run that got no macOS runner, pass that run's number as
`RUN` and build the same commit: `build_id.txt` is the commit, so the IPA plays
with the server zip of that commit.

Work happens in `~/pokewilds-ios`, on WSL's own disk (the project has ~17k
files: importing them through `/mnt/d` is very slow). The Godot import cache
stays there: the first build takes a few minutes, later ones under a minute.
The script prints the IPA's Windows path,
`\\wsl.localhost\Ubuntu\home\<you>\pokewilds-ios\Pokewilds-unsigned.ipa`.
`WORK=...` and `OUT=...` move the work folder and the IPA.

## Differences from the CI IPA

Compared with the CI IPA of build-0006 (0.10.6):

| | CI (Xcode on macOS) | here (xtool on WSL) |
|---|---|---|
| Engine | stripped build from `.github/engine/custom.py` (2D, GL only, few modules) | official Godot 4.7.2 template library (all modules, Vulkan via MoltenVK, 3D) |
| Binary | 48 MB, arm64, iOS 15.0+, SDK 26.5 | 67 MB, arm64, iOS 15.0+, SDK 27.1 |
| Link | Apple ld, Xcode 26.5 | lld 21 from xtool, Swift 6.4.1 driver |
| Icons | `Assets.car` + 2 PNGs, `CFBundleIconName` | 4 plain PNGs via `CFBundleIconFiles` (no `actool` on Linux) |
| Launch screen | `Launch Screen.storyboardc` (boot splash colour) | `UILaunchScreen` = `{}`: plain white or black until the boot splash (no `ibtool`) |
| Info.plist | binary; `DT*` and `BuildMachineOSBuild` keys; capabilities `wifi`, `arm64` | XML; no `DT*` keys; capabilities `arm64` only (xtool sets them) |
| Other files | `PkgInfo`, `en.lproj/InfoPlist.strings` (comment only) | none |
| Linked libraries | same set | same set plus `IOSurface` (present on every iOS) |

The `.pck` comes from the same export preset (here 2 KB apart: the CI build
is an older commit). `PrivacyInfo.xcprivacy`, bundle id, versions,
orientations, file sharing and scene manifest are the same as in CI.

Two link fixes keep the binary as compatible as the Xcode one:

- `Package.swift` tells lld to ignore the engine's auto-link of `SwiftUICore`,
  which only iOS 18+ has (Apple's linker binds through `SwiftUI` instead).
  Without it the app would not start on iOS 15-17.
- SwiftPM links through `swiftc`, which gives clang `--sysroot`; clang then
  records the deployment target (15.0) as the SDK version, so iOS would apply
  old-SDK compatibility behaviour. `build_ipa.sh` writes the real SDK version
  into the binary after linking and drops the rpath to the build machine's
  Swift toolchain.

## Not solved

- **Stripped engine.** CI swaps in an engine built from source with
  `custom.py` (smaller, less to load). Here the official template library is
  used as is. Building `libgodot.a` for iOS inside WSL (SCons with the Swift
  toolchain's clang and xtool's iOS SDK) is not tried yet.
- **Smoke test.** CI only ships a pack that passed the Linux smoke test of the
  stripped engine; this script does not run it.
- **Version numbers.** CI numbers builds by run; here you pass `RUN` by hand.
- **Icons and launch screen** stay simplified (see the table) until there is an
  `actool`/`ibtool` replacement on Linux.
