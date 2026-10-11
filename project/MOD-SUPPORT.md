# Original PokéWilds mods: initial compatibility

Double-tap physical or touch Start during gameplay to open MODS (within 280 ms).
A single Start press opens the in-game menu after that window, without flashing
the menu on a double tap. Closing MODS returns to gameplay. Start in existing
menus/battles keeps its existing action. On desktop, F8 also opens MODS.
Choose IMPORT ZIP and select a ZIP containing the original `mods/` folder.
Read the accepted/skipped report, then fully close and reopen the game.
ENABLE and DISABLE also take effect on the next launch. Importing does not
change the running world's resources halfway through a session.

One imported package is selected at a time. A new import replaces that selection.
Combine compatible mods into one ZIP yourself if desired, resolving conflicting
files first. Case-insensitive duplicate paths are rejected.

## Supported in this build

- Existing Pokémon: front/back sprites, six-frame overworld sheets, OGG cries.
- Existing player character PNG assets, mapped terrain PNG assets and mapped OGG
  music/sound replacements. Exact supported paths are in
  `data/original_mod_paths.json`; a mapped asset affects the game where the port
  actually uses that asset. A mapping is not a promise of every source feature.
- Existing species' `base_stats.asm`, `evos_attacks.asm`, and `egg_moves.asm`,
  using original source syntax and recognized types, moves, species and enums.
  Base stats require the original physical line layout, including blank lines.
- Original 16×96 Pokémon overworld sheets are converted to the port's horizontal
  six-frame layout. Front sprites accept square frames stacked vertically.
  Other PNG replacements must match the mapped original dimensions.
- Replacement OGG files retain the original resource's loop settings.

## Not supported yet

New species, new player-character selection entries, arbitrary Java/GDScript,
custom battle scripts, `anim.asm`, `shiny.pal`, and source-only ecology/world
configuration are not implemented. Existing front-sprite animation timing is
retained. Evolution changes do not rebuild the port's precomputed ancestry data.
Normal sprite replacement does not automatically replace separate shiny assets.
Unsupported files are listed, not executed. Compatible files in the same ZIP
can still load; inspect the report before playing.

## Files, saves and troubleshooting

The game stores imported ZIPs in `user://mod_packages`, selection in
`user://original_mods.cfg`, and startup results in `user://mod_report.txt`.
Advanced users can place loose source-style files in `user://mods` when no ZIP
is selected in that config. Imported packages take priority over loose files.
ZIP paths are validated and files are read without extracting into the project.

Keep a save backup before testing data mods. Existing Pokémon can retain stats
or moves already stored in the save. Disabling a mod restores built-in resources
and data on restart, but does not undo values already written into a save.

Windows native runtime checks cover importing, restart loading, sprite conversion,
player and tile overrides, species data, disabling and invalid ZIP rejection.
The Android native ZIP picker and physical-device performance are not yet tested.
This is initial compatibility, not support for every original-game mod.
