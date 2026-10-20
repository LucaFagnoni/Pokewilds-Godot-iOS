extends SceneTree
## Rebuilds res://data/battle_sprite_facts.json after battle sprites change.
## Run windowed (it reads the sprites back):
##   godot --path project -s res://tools/battle_sprite_facts.gd
## What main.gd would otherwise find by reading each imported battle sheet back
## from the GPU (a stall on iPhone): "listed" maps "path:WxH" to [idle frames,
## frames whose white background is removed...] for the sheets that differ from
## the plain case; "plain" holds the sorted hashes of the plain sheets (every
## frame animates, no background to remove).

func _initialize() -> void:
    var main = load("res://scripts/main.gd").new()
    main.battle_sprite_facts = {"listed": {}, "plain": PackedInt64Array()}
    var listed := {}
    var plain := {}
    for species in PokemonData.all_species():
        for kind in ["front", "back"]:
            for shiny in [false, true]:
                var texture: Texture2D = PokemonData.texture(species, kind, shiny)
                if not texture is CompressedTexture2D: continue
                var key := "%s:%dx%d" % [texture.resource_path, texture.get_width(), texture.get_height()]
                var entry := [main._battle_sprite_frame_count(texture)]
                for frame in int(entry[0]):
                    if main._battle_sprite_frame_at(texture, frame) is ImageTexture: entry.append(frame)
                if entry.size() == 1 and entry[0] == main._battle_sprite_sheet_frames(texture):
                    plain[key.hash()] = true
                else:
                    listed[key] = entry
    var hashes := plain.keys()
    hashes.sort()
    var file := FileAccess.open("res://data/battle_sprite_facts.json", FileAccess.WRITE)
    file.store_string(JSON.stringify({"listed": listed, "plain": hashes}) + "\n")
    print("battle_sprite_facts: %d plain, %d listed" % [hashes.size(), listed.size()])
    main.free()
    quit()
