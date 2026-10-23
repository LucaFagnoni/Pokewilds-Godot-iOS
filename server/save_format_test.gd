# Single-player save files (world_saves.gd): the JSON v2 saves of before
# (server/fixtures/sp_v2, written by the game before the binary format) still
# list, read and load as they were, autosave and index too; a binary save reads
# back exactly what was written, is much smaller, falls back to .bak when cut
# or from a newer game; the LOAD list reads only a save's small head.
# Run: godot --headless --path project -s ../server/save_format_test.gd -- --touch-ui
extends SceneTree

const Paths = preload("res://scripts/game_data_paths.gd")
const WorldSaves = preload("res://scripts/world_saves.gd")
const FIXTURES := "res://../server/fixtures/sp_v2"

var main: Node
var checks := 0
var failed := 0

func check(ok: bool, what: String) -> void:
    checks += 1
    if not ok:
        failed += 1
        printerr("SAVE FORMAT TEST FAIL: ", what)

func _frames(count: int) -> void:
    for i in count: await process_frame

func _open_main() -> void:
    change_scene_to_file("res://scenes/main.tscn")
    await _frames(30)
    main = current_scene
    while not main.startup_complete: await process_frame

func _load(path: String) -> void:
    main.selected_mode = "LOAD"
    main.setup_load_path = path
    main.setup_load_committed = true
    main._start_game()
    var waited := 0
    while not main.started and waited < 36000:
        await process_frame
        waited += 1

func _json(path: String) -> Dictionary:
    return JSON.parse_string(FileAccess.get_file_as_string(path))

## As JSON would have it: what old and new saves are compared by.
func _plain(value: Variant) -> Variant:
    return JSON.parse_string(JSON.stringify(value))

func _structures(data: Dictionary) -> Array:
    var result: Array = data.crafting_state.structures.map(func(piece): return [piece.name, int(piece.x), int(piece.y)])
    result.sort()
    return result

func _initialize() -> void:
    var dir := OS.get_temp_dir().path_join("save_format_test_%d" % Time.get_ticks_usec())
    var saves_dir := dir.path_join("saves")
    DirAccess.make_dir_recursive_absolute(saves_dir)
    FileAccess.open(dir.path_join(".private-saves-migrated"), FileAccess.WRITE).close()
    Paths.directory = dir
    var fixtures := ProjectSettings.globalize_path(FIXTURES)
    for name in DirAccess.get_files_at(fixtures):
        DirAccess.copy_absolute(fixtures.path_join(name), saves_dir.path_join(name))
    var saves := WorldSaves.new(saves_dir)
    var save := saves.path_for_world("Fixture V2")
    var auto := WorldSaves.autosave_path(save)
    var old: Dictionary = _json(save)
    var old_auto: Dictionary = _json(auto)

    # The JSON saves of before: read as they are, listed with their autosave.
    check(old.get("version") == 2.0 and float(old_auto.player_x) != float(old.player_x), "the fixture is a JSON v2 save with its autosave")
    check(saves.read(save) == old and saves.read(auto) == old_auto, "JSON saves read as they were")
    check(saves.find("Fixture V2").get("path", "") == auto and saves.find_newest().get("path", "") == auto, "Continue resumes the autosave the index names")
    var listed := saves.entries()
    check(listed.map(func(entry): return [entry.path, entry.autosave]) == [[save, false], [auto, true]], "LOAD lists the save and its autosave: %s" % [listed])
    var head: Dictionary = listed[0].data
    check(head.world_name == old.world_name and head.player_name == old.player_name and head.world_size == old.world_size \
        and head.world_seed == old.world_seed and head.party_size == old.caught_pokemon.size(), "LOAD shows the JSON save's name, player, size and party: %s" % [head])

    # Loaded, it is the game that was saved.
    await _open_main()
    await _load(save)
    check(main.started and int(main.world.get("world_seed")) == int(old.world_seed), "the JSON save loads")
    check(main.world.get_node("Player").position.x == float(old.player_x), "at its place")
    var loaded: Dictionary = main._capture_game_save()
    for key in ["caught_pokemon", "pokemon_storage", "inventory", "player_name", "adjacent_worlds"]:
        check(_plain(loaded[key]) == old[key], "%s as saved" % key)
    check(_structures(loaded) == _structures(old), "structures as saved: %s" % [_structures(loaded)])
    for key in ["terrain_changes", "removed_resources"]:
        check(_plain(loaded.crafting_state[key]) == old.crafting_state[key], "%s as saved" % key)
    var seen := {}
    for cell in _discovered(loaded.crafting_state.discovered_cells): seen[cell] = true
    check(_discovered(old.crafting_state.discovered_cells).all(func(cell): return seen.has(cell)), "every discovered cell still discovered")

    # SAVE writes the binary format: much smaller, and it reads back as written.
    await main._save_current_game()
    check(main.message_label.text == "GAME SAVED.", "saved: %s" % main.message_label.text)
    var bytes := FileAccess.get_file_as_bytes(save)
    check(bytes.slice(0, 4).get_string_from_ascii() == WorldSaves.MAGIC, "the save is binary")
    check(_json(save + ".bak") == old, "the JSON save before it is the .bak")
    check(not FileAccess.file_exists(auto), "SAVE drops the autosave")
    var data: Dictionary = main._capture_game_save()
    data["storage_shared"] = true
    data["storage_serial"] = main.shared_storage_serial
    var written := WorldSaves.encode(data)
    var text_size := JSON.stringify(data).length()
    print("SAVE FORMAT TEST: JSON %d bytes, binary %d bytes" % [text_size, written.size()])
    check(written.size() * 3 < text_size, "binary is less than a third of JSON: %d %d" % [written.size(), text_size])
    check(saves.write(save, data) == OK and saves.read(save) == data, "a binary save reads back exactly as written")
    check(var_to_bytes(saves.read(save)) == var_to_bytes(data), "with its types and key order")
    check(saves.read_summary(save) == WorldSaves.summary(data), "its head is its summary")

    # Loaded again, the same game.
    var at: float = main.world.get_node("Player").position.x
    await _open_main()
    await _load(save)
    check(main.started and main.world.get_node("Player").position.x == at, "the binary save loads at its place")
    var reloaded: Dictionary = main._capture_game_save()
    for key in ["caught_pokemon", "pokemon_storage", "inventory", "adjacent_worlds"]:
        check(_plain(reloaded[key]) == _plain(data[key]), "%s round-trips" % key)
    check(_structures(reloaded) == _structures(data), "structures round-trip")
    check(_plain(reloaded.crafting_state.discovered_cells) == _plain(data.crafting_state.discovered_cells), "discovered cells round-trip")

    # Killed while writing, or cut: the save before is read. A save from a
    # newer game is not misread.
    FileAccess.open(save + ".pending", FileAccess.WRITE).store_buffer(written.slice(0, written.size() / 2))
    check(saves.read(save) == data, "a cut .pending is ignored")
    check(saves.write(save, data) == OK, "written again (the .bak is binary too)")
    data["player_x"] = float(data.player_x) + 16.0
    check(saves.write(save, data) == OK, "and once more")
    FileAccess.open(save, FileAccess.WRITE).store_buffer(FileAccess.get_file_as_bytes(save).slice(0, 200))
    check(WorldSaves.read_file(save).is_empty() and WorldSaves.read_file(save, false).is_empty(), "a cut binary save is told, head included")
    check(float(saves.read(save).player_x) == float(data.player_x) - 16.0, "a cut binary save falls back to .bak")
    check(saves.entries().any(func(entry): return entry.path == save), "and is still listed")
    var newer := written.duplicate()
    newer.encode_u32(4, WorldSaves.FORMAT + 1)
    FileAccess.open(save, FileAccess.WRITE).store_buffer(newer)
    check(WorldSaves.read_file(save).is_empty(), "a save from a newer game is not read")

    # The LOAD list reads just the head of each save, however big the save.
    var big := data.duplicate(true)
    var cells := []
    for i in 200000: cells.append("%d,%d" % [i % 500, i / 500])
    big.crafting_state.discovered_cells = cells
    for i in 12:
        big.world_name = "Big %d" % i
        saves.write(saves.path_for_world(big.world_name), big)
    var began := Time.get_ticks_usec()
    listed = saves.entries()
    var list_ms := (Time.get_ticks_usec() - began) / 1000.0
    began = Time.get_ticks_usec()
    saves.read(saves.path_for_world("Big 0"))
    var read_ms := (Time.get_ticks_usec() - began) / 1000.0
    print("SAVE FORMAT TEST: LOAD list of %d saves %.1f ms, one whole save %.1f ms" % [listed.size(), list_ms, read_ms])
    check(listed.size() == 13 and list_ms < read_ms, "the LOAD list is quicker than reading one save: %.1f %.1f" % [list_ms, read_ms])
    check(listed.all(func(entry): return entry.data.party_size == data.caught_pokemon.size()), "each with its party size")

    print("SAVE FORMAT TEST: %d checks, %d failed" % [checks, failed])
    quit(1 if failed > 0 else 0)

## A save's discovered cells as "x,y" keys, whichever form it has: the old list
## of keys or the bitset over the map (world.discovered_save_value()).
static func _discovered(value) -> Array:
    if not (value is Dictionary and value.has("bits")): return Array(value)
    var rect: Array = value.bounds
    var bits := Marshalls.base64_to_raw(String(value.bits))
    var result := []
    for bit in mini(int(rect[2]) * int(rect[3]), bits.size() * 8):
        if bits[bit >> 3] & (1 << (bit & 7)):
            result.append("%d,%d" % [int(rect[0]) + bit % int(rect[2]), int(rect[1]) + bit / int(rect[2])])
    return result
