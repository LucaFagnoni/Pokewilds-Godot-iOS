# Old online worlds into the netcode rewrite's areas: an online world folder
# (server/fixtures/online_v1.zip, and with --world-from DIR a copy of a real
# server's world folder: never the live one) is loaded with the code of the
# day, from world.json and its journal and again from world.json.bak and
# journal.previous.jsonl as after a bad save; then every saved area is built as
# an AreaSim (area_sim.gd: its snapshot's terrain, the world records over it).
# Each must hold exactly its records as overlays, have its dug, cut and filled
# ground on its tiles, take a DIG by the rules and give back the same records.
# Prints how long each area took to build (the host builds them on a worker).
# Run: godot --headless --path project -s ../server/online_migrate_test.gd [-- --world-from DIR]
extends SceneTree

const Paths = preload("res://scripts/game_data_paths.gd")
const Store = preload("res://scripts/coop_store.gd")
const State = preload("res://scripts/coop_state.gd")
const AreaSim = preload("res://scripts/area_sim.gd")
const AreaState = preload("res://scripts/area_state.gd")
const Delta = preload("res://scripts/coop_world_delta.gd")
const Rules = preload("res://scripts/rules/rules.gd")
const TileRules = preload("res://scripts/rules/tile_rules.gd")
const Cache = preload("res://scripts/source_world_cache.gd")
const FIXTURE := "res://../server/fixtures/online_v1.zip"

var failed := 0
var checks := 0
var dir := ""

func check(ok: bool, what: String) -> void:
    checks += 1
    if not ok:
        failed += 1
        printerr("ONLINE MIGRATE TEST FAIL: ", what)

func _initialize() -> void:
    dir = ProjectSettings.globalize_path("user://online_migrate_test_%d" % OS.get_process_id())
    DirAccess.make_dir_recursive_absolute(dir)
    Paths.directory = dir
    var worlds := []
    worlds.append(_unzip(ProjectSettings.globalize_path(FIXTURE)))
    var args := OS.get_cmdline_user_args()
    if args.has("--world-from"): worlds.append(String(args[args.find("--world-from") + 1]))
    for world in worlds:
        if world.is_empty(): check(false, "a world to load"); continue
        _check_world(world, false)
        _check_world(world, true)
    _remove(dir)
    print("ONLINE MIGRATE TEST: %d failed (of %d checks)" % [failed, checks])
    quit(1 if failed else 0)

## The fixture's files in a folder of their own; "" when it does not read.
func _unzip(path: String) -> String:
    var zip := ZIPReader.new()
    if zip.open(path) != OK: return ""
    var target := dir.path_join("fixture")
    for name in zip.get_files():
        if name.ends_with("/"): continue
        DirAccess.make_dir_recursive_absolute(target.path_join(name).get_base_dir())
        var file := FileAccess.open(target.path_join(name), FileAccess.WRITE)
        file.store_buffer(zip.read_file(name))
        file.close()
    zip.close()
    return target

## Loads the world folder `source` (read only: its save files are copied) and
## builds each of its areas. `after_bad_save`: from the .bak and the previous journal.
func _check_world(source: String, after_bad_save: bool) -> void:
    var id := _world_id(source.path_join("world.json"))
    if id.is_empty(): id = _world_id(source.path_join("world.json.bak"))
    check(Store.valid_id(id), "%s: a world id" % source)
    if not Store.valid_id(id): return
    var homes := dir.path_join("online")
    var home := homes.path_join(id)
    _remove(home)
    DirAccess.make_dir_recursive_absolute(home)
    for name in ["world.json", "world.json.bak", "journal.previous.jsonl", "journal.folding.jsonl", "journal.jsonl"]:
        if FileAccess.file_exists(source.path_join(name)) and not (after_bad_save and name == "world.json"):
            DirAccess.copy_absolute(source.path_join(name), home.path_join(name))
    var store := Store.new(homes)
    check(store.open(id) == OK, "the world folder opens")
    var state := State.new()
    var loaded := store.load_state(state)
    var how := "from world.json.bak and the previous journal" if after_bad_save else "from world.json"
    check(not loaded.is_empty() and not state.records.is_empty(), "%s loads %s" % [source.get_file(), how])
    Cache.online_namespace = id
    var areas := 0
    for key in state.records.keys():
        if not String(key).begins_with("area/"): continue
        var area := String(key).trim_prefix("area/")
        var metadata = state.records[key]
        if not metadata is Dictionary or not metadata.get("sha256") is String: continue
        var bytes := FileAccess.get_file_as_bytes(source.path_join("snapshots").path_join(String(metadata.sha256) + ".bin"))
        if bytes.is_empty(): continue
        areas += 1
        var started := Time.get_ticks_msec()
        var sim = AreaSim.build(area, bytes, state.records)
        var took := Time.get_ticks_msec() - started
        check(sim != null and sim.state.tiles != null, "area %s builds" % area)
        if sim == null: continue
        print("ONLINE MIGRATE %s area %s (%s): %d ms, %d overlay entries, %d structures" % [source.get_file(), area, how,
            took, _overlay_count(sim.state), sim.state.structures.size()])
        _check_area(sim, state.records)
    check(areas > 0, "%s has saved areas" % source.get_file())
    Cache.online_namespace = ""

static func _world_id(path: String) -> String:
    if not FileAccess.file_exists(path): return ""
    var envelope = JSON.parse_string(FileAccess.get_file_as_string(path))
    if not envelope is Dictionary or not envelope.get("payload") is String: return ""
    var data = JSON.parse_string(envelope.payload)
    return String(data.get("id", "")) if data is Dictionary else ""

static func _overlay_count(state: AreaState) -> int:
    var count := 0
    for group in AreaState.GROUPS: count += state.get(group).size()
    return count

## The area against its records, a DIG on it, and its changes as records again.
func _check_area(sim, records: Dictionary) -> void:
    var state: AreaState = sim.state
    var area := state.area
    var prefix := "world/%s/" % area
    var missing := 0
    var extra := 0
    var ground := 0
    var off_ground := 0
    for key in records:
        if not String(key).begins_with(prefix): continue
        var group := String(key).get_slice("/", 2)
        if not group in AreaState.GROUPS: continue
        var item := String(key).get_slice("/", 3).uri_decode()
        var value = Delta.decode(String(records[key])) if records[key] is String else null
        var at: Variant = TileRules.key_cell(item) if group == "structures" else item
        var held: bool = state.get(group).has(at)
        if value == null and held:
            # A hole's neighbour rejoining it writes its own mutation: not a stray.
            if group != "source_interior_mutations": extra += 1
        elif value != null and not held: missing += 1
        if group == "source_interior_mutations" and value is Dictionary and value.get("kind") == "TILE_NAMES":
            var tile: SourceTile = state.tile_at(TileRules.key_cell(item))
            if tile == null: continue
            var upper := String(value.get("upper", tile.name_upper))
            if tile.name == String(value.get("base", tile.name)) and (tile.name_upper == upper or (upper.begins_with("hole1") and tile.name_upper.begins_with("hole1"))): ground += 1
            else: off_ground += 1
    check(missing == 0 and extra == 0, "area %s: its overlays are its records (%d missing, %d extra)" % [area, missing, extra])
    check(off_ground == 0, "area %s: its changed ground is on its tiles (%d of %d not)" % [area, off_ground, ground + off_ground])
    # A DIG by the rules somewhere plain, and what it changed as records.
    var bounds: Rect2i = state.bounds
    var dug := false
    for attempt in 4000:
        var cell := Vector2i(bounds.position.x + (attempt * 37) % bounds.size.x, bounds.position.y + (attempt * 53) % bounds.size.y)
        var tile: SourceTile = state.tile_at(cell)
        if tile == null or not TileRules.dig_surface_ok(tile) or TileRules.accepts_soil(state, cell) or TileRules.is_mountain(tile): continue
        if state.structures.has(cell) or TileRules.exact_resource_anchor(state, cell).x > -2147483648 or not tile.has_item.is_empty(): continue
        if state.source_interior_mutations.has(TileRules.cell_key(cell)): continue
        state.take_dirty()
        var rng := RandomNumberGenerator.new()
        rng.seed = 5
        var result := Rules.apply("field_dig", state, {"area_id":"OVERWORLD", "now":0.0, "shared":true}, {"action":"dig", "cell":cell}, rng)
        var changes := state.take_dirty()
        check(result.ok and not changes.is_empty() and state.tile_at(cell).name_upper.begins_with("hole1"), "area %s: a DIG at %s" % [area, cell])
        var again: Dictionary = {}
        for change in changes:
            var record := AreaSim.record_of(area, change[0], change[1], change[2])
            again[record[0]] = record[1]
        var hole = Delta.decode(String(again.get(prefix + "source_interior_mutations/" + TileRules.cell_key(cell).uri_encode(), Delta.encode(null))))
        check(hole is Dictionary and hole.get("kind") == "TILE_NAMES" and hole.get("upper") == "hole1", "area %s: the DIG goes back out as its records (a hole, its edges left to each copy)" % area)
        dug = true
        break
    check(dug, "area %s: plain ground to dig" % area)

static func _remove(path: String) -> void:
    if not DirAccess.dir_exists_absolute(path): return
    for file_name in DirAccess.get_files_at(path): DirAccess.remove_absolute(path.path_join(file_name))
    for folder in DirAccess.get_directories_at(path): _remove(path.path_join(folder))
    DirAccess.remove_absolute(path)
