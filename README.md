# PokeWilds for iPhone

An iPhone port of PokeWilds, remade in Godot, with a Windows dedicated server for co-op.

## Download

- **iPhone:** [Pokewilds-unsigned.ipa](https://github.com/LucaFagnoni/Pokewilds-Godot-iOS/releases/latest/download/Pokewilds-unsigned.ipa). Sign it with Feather (or a similar tool) before installing.
- **Windows server:** [PokeWilds-Server-win64.zip](https://github.com/LucaFagnoni/Pokewilds-Godot-iOS/releases/latest/download/PokeWilds-Server-win64.zip). Unzip it and run `start_server.bat`. Setup guide: [README_SERVER.md](README_SERVER.md).

Both links always point to the newest release. Each release holds an IPA and a server built from the same commit, so they always play together.

## Versions

Every build is a release named after its version, for example **PokeWilds 0.10.3**. The last number goes up with every build, so a new IPA always installs as an update. The first two numbers are set in the iOS export preset (`application/short_version` in `project/export_presets.cfg`) and are raised by hand for bigger steps. All releases: [Releases](https://github.com/LucaFagnoni/Pokewilds-Godot-iOS/releases).

## Source code

Based on [Pokewilds-Android](https://github.com/TryTheSauceBoss/Pokewilds-Android). Original source package: [source-v0.9.3](https://github.com/TryTheSauceBoss/Pokewilds-Android/releases/tag/source-v0.9.3).
