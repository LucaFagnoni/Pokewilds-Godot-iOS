extends RefCounted
## An area a host holds without drawing it (no nodes): its AreaState built
## from the area's snapshot (the terrain cache) and the world records (its
## overlays, as the journal has them), then kept equal to them, change by
## change (apply_record). The rules run on it (rules/, coop_rules_runtime.gd)
## for the players who are there; the area the host itself plays in is its
## World's own AreaState instead.
##
## A dedicated server that is the authority of every area's Pokemon
## (coop_population_authority.gd) also runs this area's wild and habitat
## Pokemon and eggs here: read from the records (begin_population,
## load_population), kept equal to others' changes of them
## (apply_population, apply_claim) and run a frame at a time (tick) by the same
## WildPopulation and HabitatPopulation a World runs, with no World: no player
## of its own, the area's players as they were last seen (`players`).

const AreaState = preload("res://scripts/area_state.gd")
const Snapshot = preload("res://scripts/coop_world_snapshot.gd")
const Delta = preload("res://scripts/coop_world_delta.gd")
const Cache = preload("res://scripts/source_world_cache.gd")
const WildPopulation = preload("res://scripts/wild_population.gd")
const HabitatPopulation = preload("res://scripts/habitat_population.gd")
const PopulationRules = preload("res://scripts/rules/population_rules.gd")
const Population = preload("res://scripts/coop_wild_population.gd")
const Hordes = preload("res://scripts/coop_hordes.gd")
const CraftingData = preload("res://scripts/crafting_data.gd")
## The record groups of an area's Pokemon, in the order a World puts them back.
const POPULATION := ["deployed_pokemon", "wild_pokemon", "wild_eggs"]
## The order the World lays overlays on its tiles when it loads.
const LOAD_ORDER := ["terrain_changes", "removed_resources", "structures", "built_house_floor_tiles",
    "built_house_paintings", "built_house_decorations", "built_house_origins", "event_progress",
    "source_interior_mutations", "source_plant_farms"]

var state := AreaState.new()
var seed_value := 0
var size_index := 0
## Ticks (ms) since the area has had nobody in it; 0 while someone is.
var empty_since := 0
## Who keeps the area's Pokemon going and whom they chase (the populations'
## `players`).
var players := Players.new()
## True once its Pokemon are in from the records (load_population).
var populated := false
## The record keys still to read, the last first.
var _to_load: Array = []
## cell -> ecology id of the habitat Pokemon the records hold on that cell, as
## this area last heard or told them: one taken from its tile is found by it
## wherever it has walked to here since.
var habitat_ids := {}

func _init() -> void:
    state.wild = WildPopulation.new(null, state)
    state.habitat = HabitatPopulation.new(null, "deployed_pokemon", state)
    state.eggs = HabitatPopulation.new(null, "wild_eggs", state)
    state.rng.randomize()
    players.state = state
    state.wild.players = players
    state.habitat.players = players

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

## One record ("<group>/<key>"'s encoded value) taken in: the overlay and its
## tiles; a solid structure blocks its cell, as the World's collision does.
func apply_record(group: String, key: String, encoded: Variant) -> void:
    var value = Delta.decode(String(encoded)) if encoded is String else null
    if group in AreaState.SETS and value != null: value = true
    state.apply_change(group, key, value)
    if group == "structures":
        var cell := AreaState.key_cell(key)
        if value is Dictionary and structure_blocks(value): state.blocked[cell] = true
        elif state.blocked.get(cell) is bool: state.blocked.erase(cell)

## A built piece Pokemon cannot walk through (world_buildings.gd place_structure:
## its recipe's solid, a door while shut; a gate is a fence's opening).
static func structure_blocks(record: Dictionary) -> bool:
    var name := String(record.get("name", ""))
    if name == "DOOR":
        return not bool(record.get("gate", false)) and not bool(record.get("open", false))
    return bool(CraftingData.build_recipe(String(record.get("recipe_name", name))).get("solid", false))

# --- Its Pokemon -------------------------------------------------------------------

## Starts reading the area's Pokemon from the records: `keys` are theirs
## ("world/<area>/<group>/<key>"), in any order.
func begin_population(keys: Array) -> void:
    _to_load.clear()
    for group: String in POPULATION:
        var prefix := "world/" + state.area + "/" + group + "/"
        for key in keys:
            if String(key).begins_with(prefix): _to_load.append(String(key))
    _to_load.reverse()
    populated = false

## Puts in the Pokemon begin_population listed, each as `records` (the
## host's) holds it now, until `deadline` (Time.get_ticks_usec): true once
## they all are in. A wild one stands where its latest motion put it
## (`moved`: wild id -> WildPopulation.decode_motion entry, the motion the host
## keeps for the area and has not folded into the records); one someone has
## claimed (in a battle) is kept but held where it is.
func load_population(records: Dictionary, deadline: int, moved: Dictionary = {}) -> bool:
    while not _to_load.is_empty():
        if Time.get_ticks_usec() >= deadline: return false
        var key: String = _to_load.pop_back()
        var encoded = records.get(key)
        if not encoded is String: continue
        var group := key.get_slice("/", 2)
        var name := key.get_slice("/", 3).uri_decode()
        var value = Delta.decode(encoded)
        if group == "wild_pokemon" and value is Dictionary and moved.has(int(name)):
            value["x"] = int(moved[int(name)].x)
            value["y"] = int(moved[int(name)].y)
        apply_population(group, name, value)
        if group == "wild_pokemon" and records.has(Population.claim_key(state.area, int(name))):
            state.wild.claim(int(name), true)
    populated = true
    return true

## A record of this area's Pokemon as the host's records now hold it
## (`group`, `key`; null when gone), written by a command of someone else's
## (a claim's end, a spawn, a Pokemon left in or taken from a habitat, an egg
## taken, parents angered). A wild one already here keeps the cell it has
## walked to (the records' is older: motion is not folded into them at once):
## true then, its place to be told again.
func apply_population(group: String, key: String, value: Variant) -> bool:
    match group:
        "wild_pokemon":
            var wild_id := int(key)
            if not value is Dictionary:
                state.wild.remove(wild_id)
                return false
            if state.wild.has(wild_id):
                var data: Dictionary = state.wild.records[wild_id]
                var cell: Vector2i = data.cell
                data.merge(value, true)
                data["cell"] = cell
                state.wild.refresh(wild_id)
                return true
            var at := Vector2i(int(value.get("x", -1)), int(value.get("y", -1)))
            PopulationRules.add_wild(state, String(value.get("species", "pidgey")), int(value.get("level", 2)), at,
                String(value.get("home_biome", PopulationRules.biome_at(state, at))), wild_id,
                value.get("source_record", {}) as Dictionary, value)
        "deployed_pokemon":
            var cell := AreaState.key_cell(key)
            var identity := String(habitat_ids.get(cell, ""))
            habitat_ids.erase(cell)
            if value is Dictionary:
                identity = String(value.get("ecology_id", ""))
            _take_habitat(cell, identity)
            if value is Dictionary and state.habitat.restore(value, cell):
                habitat_ids[cell] = identity
        "wild_eggs":
            var cell := AreaState.key_cell(key)
            state.eggs.take(cell)
            if value is Dictionary:
                PopulationRules.add_egg(state, String(value.get("species", "pidgey")), cell, value, -1, false)
    return false

## The habitat Pokemon on `cell`, and the one with `identity` wherever it stands.
func _take_habitat(cell: Vector2i, identity: String) -> void:
    state.habitat.take(cell)
    if identity.is_empty(): return
    for other in state.habitat.records.keys():
        if String(state.habitat.records[other].get("ecology_id", "")) == identity:
            state.habitat.take(other)
            habitat_ids.erase(other)

## A wild Pokemon claimed for a battle (held where it is) or let go: true when
## let go (where it stands is to be told again).
func apply_claim(wild_id: int, claimed: bool) -> bool:
    if not state.wild.has(wild_id): return false
    state.wild.claim(wild_id, claimed)
    return not claimed

## A frame of the area's Pokemon (state.clock already the host's): the habitat
## check, the habitat Pokemon, then the wild ones near `observers` (the area's
## players, Players.refresh), in a World's order. The Pokemon in a built house
## are left to the players inside it.
func tick(delta: float, observers: Array) -> void:
    var centers: Array = []
    for observer in observers: centers.append(Vector2i(int(observer.x), int(observer.y)))
    PopulationRules.run_ecology_step(state, delta, centers, _outdoors, true, {}, _outdoors)
    state.habitat.tick(delta, state.rng)
    state.wild.tick(delta, observers, state.rng)
    # Where each one is drawn moves on as a World's view moves it on (what is
    # asked of "a Pokemon drawn here": the Megas' steps).
    state.wild.advance(delta)

static func _outdoors(record: Dictionary) -> bool:
    return not record.has("house_door")

## The area's players as WildPopulation asks after them (its `players`): from
## where each was last seen (the host's player packets), who a Pokemon goes
## for, whose cell is taken, who charms it. No player here is this game's own.
class Players extends RefCounted:
    var state
    ## actor -> {"area", "x", "y", "battle", "move", "field_level", "party_level"}.
    var by_actor := {}
    var scope := ""
    ## Wild ids whose co-op target changed since they were last taken.
    var marked := {}

    ## The players of `area` outdoors, from `packets` (actor -> the last player
    ## packet, coop_players.gd last_packets): the observers of a frame.
    func refresh(packets: Dictionary, area: String) -> Array:
        by_actor.clear()
        scope = area + "|OVERWORLD"
        for actor in packets:
            var packet: Dictionary = packets[actor]
            if packet.get("area") != area or packet.get("layer") != "OVERWORLD": continue
            var visual = packet.get("visual", {})
            by_actor[actor] = {"area": scope, "x": int(packet.get("cell_x", 0)), "y": int(packet.get("cell_y", 0)),
                "battle": bool(packet.get("battle", false)), "move": String(visual.get("move", "")) if visual is Dictionary else "",
                "field_level": int(packet.get("field_level", 1)), "party_level": int(packet.get("party_level", 1))}
        return by_actor.values()

    func target_for(data: Dictionary, cell: Vector2i) -> Dictionary:
        var before := String(data.get("coop_target", ""))
        var target := Population.target_of(by_actor, scope, data, cell, _safe)
        if String(data.get("coop_target", "")) != before: marked[int(data.get("id", -1))] = true
        return target

    func _safe(cell: Vector2i) -> bool:
        return Hordes.safe_at(state.structures, cell)

    func occupied(cell: Vector2i) -> bool:
        return Population.occupied_by(by_actor, cell)

    func remote_charm(data: Dictionary, target: Dictionary) -> bool:
        return Population.charmed_by(data, target, state.clock)

    func mark_motion(wild_id: int) -> void:
        marked[wild_id] = true

    func local_actor() -> String:
        return ""

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
