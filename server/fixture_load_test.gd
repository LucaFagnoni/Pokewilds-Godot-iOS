# Saves of OLD games still load: server/fixtures holds saves written by earlier
# versions of the game, and this loads each with the code of the day and checks
# what the player had. A later rewrite of the save code, the world state or the
# co-op store must keep these passing (or read them and say so): never edit a
# fixture to make it pass, add a newer one.
#   sp_v2   single-player JSON version 2 save + autosave + index (before binary saves)
#   solo_v1 single-player binary format 1 (a played world: party, box, bag, structures,
#           Pokemon left outside, discovered cells) and the same as a JSON save without
#           the keys later versions added ("legacy")
#   online_v1.zip   an online world folder: world.json (+ .bak), journal.previous.jsonl,
#           host.save and area snapshots, after a dedicated server run
# Run: godot --headless --path project -s ../server/fixture_load_test.gd -- --touch-ui
extends SceneTree

const Paths = preload("res://scripts/game_data_paths.gd")
const WorldSaves = preload("res://scripts/world_saves.gd")
const Store = preload("res://scripts/coop_store.gd")
const State = preload("res://scripts/coop_state.gd")
const HostSaves = preload("res://scripts/coop_game_saves.gd")
const FIXTURES := "res://../server/fixtures"

var main: Node
var dir := ""
var checks := 0
var failed := 0

func check(ok: bool, what: String) -> void:
    checks += 1
    if not ok:
        failed += 1
        printerr("FIXTURE LOAD TEST FAIL: ", what)

func _frames(count: int) -> void:
    for i in count: await process_frame

func _fixture(relative: String) -> String:
    return ProjectSettings.globalize_path(FIXTURES.path_join(relative))

## Copies a fixture folder's files into the fresh saves folder.
func _install(folder: String) -> void:
    var from := _fixture(folder)
    for file_name in DirAccess.get_files_at(from):
        DirAccess.copy_absolute(from.path_join(file_name), dir.path_join("saves").path_join(file_name))

func _open_main() -> void:
    change_scene_to_file("res://scenes/main.tscn")
    await _frames(30)
    main = current_scene
    while not main.startup_complete: await process_frame
    main.coop_menu.close()

## LOAD of the save at `path`, as the LOAD list does; the game saved back out.
func _load(path: String) -> Dictionary:
    await _open_main()
    main.selected_mode = "LOAD"
    main.setup_load_path = path
    main.setup_load_committed = true
    main._start_game()
    var deadline := Time.get_ticks_msec() + 180000
    while not main.started and Time.get_ticks_msec() < deadline and main.menu_status.text != "NO SAVE FILE":
        await process_frame
    if not main.started: return {}
    await _frames(10)
    return main._capture_game_save()

func _names(list: Array, key := "species") -> Array:
    return list.map(func(entry): return String(entry.get(key, "")))

func _structures(data: Dictionary) -> Array:
    var result: Array = data.crafting_state.structures.map(func(piece): return String(piece.name))
    result.sort()
    return result

## The facts of the played world (make_solo_fixture.gd), in the binary save and in the legacy JSON one.
func _check_solo(data: Dictionary, label: String) -> void:
    check(not data.is_empty(), "%s: the game started" % label)
    if data.is_empty(): return
    check(int(data.world_seed) == 12345 and int(data.world_size) == 0, "%s: its world: %s %s" % [label, data.world_seed, data.world_size])
    check(_names(data.caught_pokemon) == ["machop", "pikachu", "eevee", "onix"], "%s: the party: %s" % [label, _names(data.caught_pokemon)])
    check(data.caught_pokemon.map(func(p): return int(p.level)) == [14, 25, 12, 30], "%s: their levels" % label)
    check(data.pokemon_storage.has("BOX 1") and _names(data.pokemon_storage["BOX 1"]) == ["rattata", "zubat"], "%s: the box: %s" % [label, data.pokemon_storage.keys()])
    var bag := {"POTION": 7, "POKE BALL": 12, "LOG": 30, "GRASS": 30, "HARD STONE": 10}
    check(bag.keys().all(func(item): return int(data.inventory.get(item, -1)) == bag[item]), "%s: the bag: %s" % [label, bag.keys().map(func(item): return data.inventory.get(item))])
    check(_structures(data) == ["CAMPFIRE", "FENCE", "FENCE", "SIGN", "STORAGE BOX", "TORCH", "WALL"], "%s: structures: %s" % [label, _structures(data)])
    var outside: Array = data.crafting_state.deployed_pokemon
    var left_species := _names(outside)
    left_species.sort()
    check(left_species == ["diglett", "psyduck"], "%s: Pokemon left outside: %s" % [label, _names(outside)])
    check(outside.all(func(entry): return entry.has("x") and entry.has("y")), "%s: and where" % label)
    check(data.crafting_state.discovered_cells.size() == 3354, "%s: discovered cells: %d" % [label, data.crafting_state.discovered_cells.size()])

func _online() -> void:
    var zip := ZIPReader.new()
    check(zip.open(_fixture("online_v1.zip")) == OK, "the online fixture opens")
    var world: Dictionary = JSON.parse_string(JSON.parse_string(zip.read_file("world.json").get_string_from_utf8()).payload)
    var id: String = world.id
    var base := dir.path_join("online_worlds")
    for name in zip.get_files():
        var target := base.path_join(id).path_join(name)
        DirAccess.make_dir_recursive_absolute(target.get_base_dir())
        var file := FileAccess.open(target, FileAccess.WRITE)
        file.store_buffer(zip.read_file(name))
        file.close()
    zip.close()
    check(Store.valid_id(id), "the world has an id")
    var store := Store.new(base)
    store.open(id)
    var state := State.new()
    var metadata := store.load_state(state)
    check(not metadata.is_empty() and metadata.world_name == "Fixture", "world.json loads: %s" % [metadata])
    var kinds := {}
    for key: String in state.records: kinds[key.get_slice("/", 0)] = int(kinds.get(key.get_slice("/", 0), 0)) + 1
    check(int(kinds.get("area", 0)) == 2 and int(kinds.get("player", 0)) == 2 and int(kinds.get("world_ready", 0)) == 2, "areas, players and ready flags: %s" % [kinds])
    check(int(kinds.get("world", 0)) > 1000 and kinds.has("clock") and kinds.has("wild_namespace"), "world records: %s" % [kinds])
    check(state.records.has("area/0,0") and state.records.has("area/1,0"), "the two areas, the second made when a player walked in")
    for key in ["area/0,0", "area/1,0"]:
        var record: Dictionary = state.records[key]
        var snapshot := home_file(base, id, "snapshots/" + String(record.snapshot))
        check(FileAccess.file_exists(snapshot) and FileAccess.get_sha256(snapshot) == String(record.sha256), "%s: its snapshot is there and its hash is right" % key)
    var revision: int = state.revision
    check(revision > 0, "revision %d" % revision)
    check(metadata.has("owner"), "the world has an owner")
    var host := HostSaves.new(base).load_host(id, String(metadata.owner))
    check(not host.is_empty() and host.has("caught_pokemon") and host.caught_pokemon.size() >= 1, "the host's own save loads")
    # Killed after the last checkpoint: the older world.json and the journal give the same world.
    DirAccess.remove_absolute(base.path_join(id).path_join("world.json"))
    var again := State.new()
    check(not store.load_state(again).is_empty(), "loads from the .bak and the journal")
    # (Movement commits are not journaled: positions and the clock are from the checkpoint.)
    check(again.revision == revision, "the same revision as with world.json: %d, %d" % [again.revision, revision])
    var settled := func(key: String) -> bool: return not key.begins_with(("player/")) and key != "clock" and not "/wild_pokemon/" in key
    var before := state.records.keys().filter(settled)
    var after := again.records.keys().filter(settled)
    check(before.size() == after.size() and before.all(func(key): return after.has(key)), "the same records as with world.json: %d, %d, e.g. %s" % [
        before.size(), after.size(), before.filter(func(key): return not after.has(key)).slice(0, 3)])

func home_file(base: String, id: String, relative: String) -> String:
    return base.path_join(id).path_join(relative)

func _initialize() -> void:
    dir = OS.get_temp_dir().path_join("fixture_load_test_%d" % Time.get_ticks_usec())
    DirAccess.make_dir_recursive_absolute(dir.path_join("saves"))
    FileAccess.open(dir.path_join(".private-saves-migrated"), FileAccess.WRITE).close()
    Paths.directory = dir
    var saves_dir := dir.path_join("saves")
    _online()

    # Single-player JSON version 2: the save, its autosave and the index.
    _install("sp_v2")
    var old: Dictionary = await _load(saves_dir.path_join("fixture_v2.json"))
    check(not old.is_empty() and int(old.world_seed) == 1792703381041111 and int(old.world_size) == 0, "sp_v2: loads")
    if not old.is_empty():
        check(_names(old.caught_pokemon) == ["machop"], "sp_v2: the party")
        check(_names(old.pokemon_storage.get("BOX 1", [])).size() == 2, "sp_v2: the box")
        check(_structures(old).size() == 5, "sp_v2: structures: %s" % [_structures(old)])
        check(old.crafting_state.discovered_cells.size() >= 89, "sp_v2: discovered cells")
        check(old.crafting_state.deployed_pokemon.is_empty(), "sp_v2: nothing left outside")

    # The played world, binary and legacy JSON (the same world, so one world cache).
    _install("solo_v1")
    _check_solo(await _load(saves_dir.path_join("fixturesolo.json")), "solo")
    _check_solo(await _load(saves_dir.path_join("fixturelegacy.json")), "legacy")
    main.saves.wait_for_cache_cleanup()

    print("FIXTURE LOAD TEST: %d checks, %d failed" % [checks, failed])
    quit(1 if failed > 0 else 0)
