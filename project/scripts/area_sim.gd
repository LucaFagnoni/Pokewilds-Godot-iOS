extends RefCounted
## An area a host holds without drawing it (no nodes): its AreaState built
## from the area's snapshot (the terrain cache) and the world records (its
## overlays, as the journal has them), then kept equal to them, change by
## change (apply_record). The rules run on it (rules/, coop_rules_runtime.gd)
## for the players who are there; the area the host itself plays in is its
## World's own AreaState instead.

const AreaState = preload("res://scripts/area_state.gd")
const Snapshot = preload("res://scripts/coop_world_snapshot.gd")
const Delta = preload("res://scripts/coop_world_delta.gd")
const Cache = preload("res://scripts/source_world_cache.gd")
## The order the World lays overlays on its tiles when it loads.
const LOAD_ORDER := ["terrain_changes", "removed_resources", "structures", "built_house_floor_tiles",
    "built_house_paintings", "built_house_decorations", "built_house_origins", "event_progress",
    "source_interior_mutations", "source_plant_farms"]

var state := AreaState.new()
var seed_value := 0
var size_index := 0
## Ticks (ms) since the area has had nobody in it; 0 while someone is.
var empty_since := 0

## The area from its snapshot and the records of the host ("world/<area>/...":
## the newest). On a worker thread: the cache is installed and read there.
## null when the snapshot does not read.
static func build(area: String, snapshot: PackedByteArray, records: Dictionary) -> RefCounted:
    var decoded := Snapshot.decode(snapshot)
    if decoded.is_empty(): return null
    var path := Cache.cache_path(int(decoded.seed), int(decoded["size"]))
    if not FileAccess.file_exists(path):
        DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
        var file := FileAccess.open(path + ".pending", FileAccess.WRITE)
        if file == null: return null
        file.store_buffer(decoded.cache)
        file.close()
        if DirAccess.rename_absolute(path + ".pending", path) != OK and not FileAccess.file_exists(path): return null
    var result := Cache.load_result(int(decoded.seed), int(decoded["size"]))
    if result.is_empty() or not result.get("store") is WorldTileStore: return null
    var sim = load("res://scripts/area_sim.gd").new()
    sim.seed_value = int(decoded.seed)
    sim.size_index = int(decoded["size"])
    sim.state.area = area
    # The same spawn draw as the World's (world.gd), for the same adapter.
    sim.state.tiles = SourceExactWorldAdapter.from_generator_result(result, SourceJavaRandom.new(sim.seed_value ^ 0x535041574E))
    sim.state.bounds = sim.state.tiles.bounds()
    sim.lay_records(Delta.flatten(decoded.shared), records)
    sim.state.tracking = true
    return sim

## The overlays of `flat` (Delta.flatten of a snapshot's shared part) with the
## records over them, laid on the tiles in the World's order.
func lay_records(flat: Dictionary, records: Dictionary) -> void:
    var prefix := "world/" + state.area + "/"
    for key in records:
        if String(key).begins_with(prefix): flat[String(key).trim_prefix(prefix)] = records[key]
    var by_group := {}
    for key in flat:
        var group := String(key).get_slice("/", 0)
        if not group in AreaState.GROUPS: continue
        if not by_group.has(group): by_group[group] = []
        by_group[group].append(key)
    for group in LOAD_ORDER:
        for key in by_group.get(group, []):
            apply_record(group, String(key).get_slice("/", 1).uri_decode(), flat[key])

## One record ("<group>/<key>"'s encoded value) taken in: the overlay and its tiles.
func apply_record(group: String, key: String, encoded: Variant) -> void:
    var value = Delta.decode(String(encoded)) if encoded is String else null
    if group in AreaState.SETS and value != null: value = true
    state.apply_change(group, key, value)

## The record form of a change (take_dirty's [group, key, value]): its key
## under "world/<area>/" and its encoded value, as Delta.flatten makes them
## (a set entry is its own key; a hole's edges are left to each copy).
static func record_of(area: String, group: String, key: Variant, value: Variant) -> Array:
    var text := AreaState.cell_key(key) if key is Vector2i else String(key)
    var encoded: String
    if value == null: encoded = Delta.encode(null)
    elif group in AreaState.SETS: encoded = Delta.encode(text)
    elif group == "structures": encoded = Delta.encode(AreaState.structure_record(key, value))
    elif group == "source_interior_mutations" and value is Dictionary and String(value.get("upper", "")).begins_with("hole1"):
        var plain: Dictionary = value.duplicate(true)
        plain["upper"] = "hole1"
        encoded = Delta.encode(plain)
    else: encoded = Delta.encode(value)
    return ["world/" + area + "/" + group + "/" + text.uri_encode(), encoded]
