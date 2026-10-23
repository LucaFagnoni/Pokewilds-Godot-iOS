# PokeWilds for iPhone and Android

A mobile port of PokeWilds for iPhone and Android, remade in Godot, with a Windows dedicated server for co-op.

## Download

- **iPhone:** [Pokewilds-unsigned.ipa](https://github.com/LucaFagnoni/pokewilds-mobile/releases/latest/download/Pokewilds-unsigned.ipa). Sign it with Feather (or a similar tool) before installing.
- **Android:** [Pokewilds-arm64.apk](https://github.com/LucaFagnoni/pokewilds-mobile/releases/latest/download/Pokewilds-arm64.apk) (64-bit ARM phones). Signed: each new APK installs over the previous one.
- **Windows server:** [PokeWilds-Server-win64.zip](https://github.com/LucaFagnoni/pokewilds-mobile/releases/latest/download/PokeWilds-Server-win64.zip). Unzip it and run `start_server.bat`. Setup guide: [README_SERVER.md](README_SERVER.md).

Both links always point to the newest release. Each release holds an IPA, an APK and a server built from the same commit, so they always play together.

## Sideloading source

Add this source in Feather (Sources, +) or in AltStore and SideStore (Add Source) to see every version and get updates in the app:

```
https://raw.githubusercontent.com/LucaFagnoni/pokewilds-mobile/source/apps.json
```

It lists every published IPA and is updated automatically with each new release.

## Versions

Every build is a release named after its version, for example **PokeWilds 0.10.166**. The last number is the commit count of `main`, so it goes up with every change and a new IPA always installs as an update. When GitHub has no Mac to build on, the IPA is built on Linux with xtool instead ([tools/ios_xtool](tools/ios_xtool/README.md), which also works on Windows with WSL): same version, same server, simpler icons. The first two numbers are set in the iOS export preset (`application/short_version` in `project/export_presets.cfg`) and are raised by hand for bigger steps. All releases: [Releases](https://github.com/LucaFagnoni/pokewilds-mobile/releases).

## Source code

Based on [Pokewilds-Android](https://github.com/TryTheSauceBoss/Pokewilds-Android). Original source package: [source-v0.9.3](https://github.com/TryTheSauceBoss/Pokewilds-Android/releases/tag/source-v0.9.3).
