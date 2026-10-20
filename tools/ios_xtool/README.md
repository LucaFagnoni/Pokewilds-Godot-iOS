# iPhone IPA without a Mac (WSL + xtool)

Fallback for when GitHub has no macOS runner for the `ios` job: builds the
unsigned `Pokewilds-unsigned.ipa` on Linux with
[xtool](https://github.com/xtool-org/xtool) in place of Xcode, on a Windows PC
inside WSL or in CI (the `ios_xtool` job). Sign it with Feather as usual.

## In CI

`ios_xtool` runs on Ubuntu when the `ios` job did not build the IPA (no
runner, a failure), never on pull requests, and puts its IPA in the same
release. It runs `setup.sh` and `SMOKE=0 build_ipa.sh` (the `smoke` job already
tested the pack); only the iOS engine library is cached, never the SDK.
`Xcode.xip` comes from the release `xcode-27.1` of the private repository
`LucaFagnoni/xcode-sdk`, read with the secret `XCODE_SDK_TOKEN` (a fine-grained
token with read-only access to that repository's contents). For a newer Xcode,
upload it there as a new release and change the tag in the job.

To test it: Actions > PokeWilds build > Run workflow, tick "fallback" (skips
the macOS job).

The steps mirror the `smoke` and `ios` jobs in `.github/workflows/build.yml`:
build the stripped engine from Godot 4.7.2's source with `.github/engine/custom.py`
(for iOS, and for Linux headless for the smoke test), minify JSON, stamp
`build_id.txt` and the versions, import and export the "iOS" preset, run the
smoke test on that pack, build the app, strip it, zip `Payload/`. Godot's export
only makes an Xcode project; `Package.swift` and `xtool.yml` turn it into a
SwiftPM package that xtool builds into `Pokewilds.app`.

## What you need

- WSL 2 with Ubuntu 24.04 (`wsl -d Ubuntu`).
- `Xcode.xip` (**Xcode 27**), downloaded with your Apple ID from
  <https://developer.apple.com/download/all/?q=Xcode>. xtool only takes the iOS
  SDK out of it; there is no Apple ID login in xtool, the IPA stays unsigned.
  Note that Apple's Xcode licence only allows the SDK on Apple hardware.
- Disk on C: (the WSL disk): ~14 GB once set up (SDK 7 GB, Swift 3.6 GB,
  work folder 3 GB with the Godot source), more while the SDK is being made.

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
(`cd /mnt/d/Repositories/pokewilds/Pokewilds-Godot`) or a full clone inside WSL
(not `--depth 1`: the version is the commit count). Not from a Windows
`git worktree`: its `.git` file holds a `D:/` path. The script builds the
committed `HEAD`, not uncommitted changes.

```bash
bash tools/ios_xtool/build_ipa.sh                   # stripped engine + smoke test, like CI
ENGINE=official bash tools/ios_xtool/build_ipa.sh   # Godot's own template library, no engine build or smoke test
SMOKE=0 bash tools/ios_xtool/build_ipa.sh           # stripped engine, skip the smoke test
```

The engines are built once per Godot version and `custom.py` (the cache key is
its hash), so a change to `custom.py` rebuilds them. No extra Ubuntu packages:
Godot compiles with the Swift toolchain's clang for both iOS and Linux, and
Godot's SCons runs in a venv in the work folder.

The versions are the ones CI gives the same commit: MAJOR.MINOR from the iOS
preset plus the commit count (e.g. 0.10.166, build 166). `build_id.txt` is the
commit, so an IPA built here plays with the server zip CI built from the same
commit: a fallback when a CI run got no macOS runner.

Work happens in `~/pokewilds-ios`, on WSL's own disk (the project has ~17k
files: importing them through `/mnt/d` is very slow). Its caches (Godot
import, engines, lld's LTO cache) make the first build slow and the next ones
quick. On this PC (28 threads) the first build takes about 12 minutes: import
2, iOS engine 1.5, Linux engine 2, and 5 for the first LTO link of the engine.
Later builds take about 2 minutes.
The script prints the IPA's Windows path,
`\\wsl.localhost\Ubuntu\home\<you>\pokewilds-ios\Pokewilds-unsigned.ipa`.
`WORK=...` and `OUT=...` move the work folder and the IPA.

## Differences from the CI IPA

Compared with the CI IPA of the same commit (build-0010, ea8c5793, 0.10.168):

| | CI (Xcode on macOS) | here (xtool on WSL) |
|---|---|---|
| Engine | stripped, `custom.py`, Apple clang, thin LTO | same profile and source, Swift 6.4.1's clang 21, thin LTO |
| Binary | 48.2 MB, arm64, iOS 15.0+, SDK 26.5 | 47.0 MB, arm64, iOS 15.0+, SDK 27.1 |
| Link | Apple ld, Xcode 26.5 | lld 21 from xtool, Swift 6.4.1 driver |
| Linked libraries | same set | same set, plus weak `libswiftCoreAudio`/`libswiftCoreLocation` (on every iOS) |
| Icons | `Assets.car` + 2 PNGs, `CFBundleIconName` | 4 plain PNGs via `CFBundleIconFiles` (no `actool` on Linux) |
| Launch screen | `Launch Screen.storyboardc` (boot splash colour) | `UILaunchScreen` = `{}`: plain white or black until the boot splash (no `ibtool`) |
| Info.plist | binary; `DT*` and `BuildMachineOSBuild` keys; capabilities `wifi`, `arm64` | XML; no `DT*` keys; capabilities `arm64` only (xtool sets them) |
| Other files | `PkgInfo`, `en.lproj/InfoPlist.strings` (comment only) | none |

Same as CI: `build_id.txt` (the commit), versions (0.10.168, 168), bundle id,
orientations, file sharing, scene manifest, `PrivacyInfo.xcprivacy`, and the
`.pck`: same size (62,339,572 bytes), same 15,937 files, all data identical.
Only 4 files of Godot's own bookkeeping differ, and they differ between any
two exports: the script class and UID caches (same entries, other order: Linux
and macOS list folders differently), random `node_ids` in the exported
`main.scn`, and the UID in `assets/ios_launch.png.import`, which is not
committed, so every import makes a new one. A host only compares `build_id`,
so the CI server takes this IPA as its own build.

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

- **Icons and launch screen** stay simplified (see the table) until there is an
  `actool`/`ibtool` replacement on Linux.
