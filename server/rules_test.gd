# The field rules (project/scripts/rules/) without a world, on a small
# AreaState: what DIG, CUT, SMASH, picking berries, planting and taking items
# change and give, what they refuse; the same command on the same state with
# the same random numbers always the same; a replica that takes the
# authority's changes (as records, as the binary frame) ends with the same
# overlays and tiles; a prediction rolled back leaves the state exactly as it
# was; commands from the wire checked.
# Run: godot --headless --path project -s ../server/rules_test.gd
extends SceneTree

const AreaState = preload("res://scripts/area_state.gd")
const AreaSim = preload("res://scripts/area_sim.gd")
const Rules = preload("res://scripts/rules/rules.gd")
const FieldDig = preload("res://scripts/rules/field_dig.gd")
const FieldCut = preload("res://scripts/rules/field_cut.gd")
const FieldMoveData = preload("res://scripts/field_move_data.gd")
const TileRules = preload("res://scripts/rules/tile_rules.gd")

var failed := 0
var checks := 0

func check(ok: bool, what: String) -> void:
    checks += 1
    if not ok:
        failed += 1
        printerr("RULES TEST FAIL: ", what)

## A 14x10 area: green1 everywhere, and on row 1: grass2, tree2 (upper),
## tree_large2 (upper), rock1, a ripe berry tree, a cracked fossil site; row 5
## a water channel; a route with a hidden Pokemon under the rock and the tree.
static func area() -> AreaState:
    var store := WorldTileStore.with_bounds(Rect2i(0, 0, 14, 10))
    var route := SourceRoute.new("forest1", 12)
    route.stored_pokemon = [{"name":"GEODUDE", "level":9}]
    var special := {Vector2i(1, 1): ["grass2", ""], Vector2i(3, 1): ["green1", "tree2"], Vector2i(5, 1): ["green1", "tree_large2"],
        Vector2i(7, 1): ["rock1", ""], Vector2i(9, 1): ["green1", "berrytree_pecha_full"], Vector2i(11, 1): ["green1", "forest_cracked"]}
    for y in 10:
        for x in 14:
            var cell := Vector2i(x, y)
            var names: Array = special.get(cell, ["water2" if y == 5 else "green1", ""])
            var tile := SourceTile.new(names[0], cell * 16, names[1], false, route if cell in [Vector2i(7, 1), Vector2i(9, 1)] else null)
            tile.biome = "forest"
            store._write(cell * 16, tile)
    var adapter := SourceExactWorldAdapter.new()
    adapter.tiles = store
    adapter.bottom_left_cell = Vector2i.ZERO
    adapter.top_right_cell = Vector2i(13, 9)
    var state := AreaState.new()
    state.area = "2,3"
    state.tiles = adapter
    state.bounds = adapter.bounds()
    state.wild = preload("res://scripts/wild_population.gd").new()
    state.habitat = preload("res://scripts/habitat_population.gd").new()
    state.eggs = preload("res://scripts/habitat_population.gd").new(null, "wild_eggs")
    # Shores as a generated world has them (what DIG and its replicas keep up).
    var every := []
    for y in 10:
        for x in 14: every.append(Vector2i(x, y))
    TileRules.recoastify(state, every)
    state.tracking = true
    return state

static func rng(seed_value: int) -> RandomNumberGenerator:
    var made := RandomNumberGenerator.new()
    made.seed = seed_value
    return made

static func names(state: AreaState, cell: Vector2i) -> Array:
    var tile: SourceTile = state.tile_at(cell)
    return [tile.name, tile.name_upper, tile.has_item, tile.has_item_amount]

static func store_bytes(state: AreaState) -> Array:
    var store: WorldTileStore = state.tiles.tiles
    var strings := []
    for index in store.flags.size(): strings.append([store.flags[index], store.name_at(index), store.upper_at(index), store.biome_at(index),
        store.shore_ocean_at(index), store.shore_tidal_at(index), store.has_item_at(index), store.amounts[index]])
    return strings

static func overlays(state: AreaState) -> Dictionary:
    var result := {}
    for group in AreaState.GROUPS:
        if group != "event_progress": result[group] = state.get(group).duplicate(true)
    return result

func _initialize() -> void:
    var player := {"area_id":"OVERWORLD", "now":1000.0, "shared":true}
    var state := area()
    # CUT grass: GRASS, the tuft gone, a TILE_NAMES mutation.
    var cut := FieldCut.apply(state, player, {"move":"CUT", "cell":Vector2i(1, 1)}, rng(1))
    check(cut.ok and int(cut.grant.get("GRASS", 0)) == 1, "CUT grass gives GRASS")
    check(names(state, Vector2i(1, 1))[0] == "green1", "the grass is cut to the ground beside it")
    check(state.source_interior_mutations.get("1,1", {}).get("kind") == "TILE_NAMES", "the cut is saved")
    var dirty := state.take_dirty()
    check(dirty.size() == 1 and dirty[0][0] == "source_interior_mutations", "only the mutation is dirty")
    # A tree: one LOG; a large tree needs an evolved Pokemon.
    cut = FieldCut.apply(state, player, {"move":"CUT", "cell":Vector2i(3, 1)}, rng(1))
    check(cut.ok and cut.grant == {"LOG":1} and names(state, Vector2i(3, 1))[1] == "", "CUT a tree: one LOG, the tree gone")
    check(cut.events.any(func(event): return event[0] == "cut_halves" and event[2] is SourceTile and event[2].name_upper == "tree2"), "the split is drawn from the tree as it was")
    cut = FieldCut.apply(state, player, {"move":"CUT", "cell":Vector2i(5, 1)}, rng(1))
    check(not cut.ok and cut.reason == "needs_evolved" and names(state, Vector2i(5, 1))[1] == "tree_large2", "a large tree needs a fully evolved Pokemon")
    var evolved := ""
    for species in ["machamp", "venusaur", "charizard", "blastoise", "scizor"]:
        if FieldMoveData.is_fully_evolved(species): evolved = species; break
    check(not evolved.is_empty(), "a fully evolved species to test with")
    var strong := player.duplicate()
    strong["species"] = evolved
    cut = FieldCut.apply(state, strong, {"move":"CUT", "cell":Vector2i(5, 1)}, rng(7))
    var logs := int(cut.grant.get("LOG", 0))
    check(cut.ok and logs >= 2 and logs <= 7, "a large tree gives 2-7 LOG")
    check(FieldCut.apply(area(), strong, {"move":"CUT", "cell":Vector2i(5, 1)}, rng(7)).grant == cut.grant, "the same random numbers, the same LOG")
    # SMASH a rock: HARD STONE and the route's hidden Pokemon.
    var smash := FieldCut.apply(state, player, {"move":"SMASH", "cell":Vector2i(7, 1)}, rng(3))
    check(smash.ok and int(smash.grant.get("HARD STONE", 0)) == 1, "SMASH gives HARD STONE")
    check(smash.events.any(func(event): return event[0] == "encounter" and event[1] == "geodude" and event[2] == 9), "the rock's Pokemon jumps out")
    check(not FieldCut.apply(state, player, {"move":"SMASH", "cell":Vector2i(4, 2)}, rng(3)).ok, "SMASH on grass: refused")
    # Berries: the route's Pokemon first (it is only read), the berry once it has gone.
    var berry := FieldDig.apply(state, player, {"action":"berry", "cell":Vector2i(9, 1)}, rng(1))
    check(berry.ok and berry.grant.is_empty() and berry.events.any(func(event): return event[0] == "encounter" and event[4] == true), "an agitated tree: a Pokemon, no berry")
    check(state.source_interior_mutations.get("9,1", {}).get("kind") == "BERRY_AGITATED", "online, the tree is marked agitated for every player")
    state.edit(Vector2i(9, 1)).set_names("green1", "berrytree_pecha_full")
    (state.tile_at(Vector2i(9, 1)).route_belongs_to as SourceRoute).stored_pokemon.clear()
    berry = FieldDig.apply(state, player, {"action":"berry", "cell":Vector2i(9, 1)}, rng(1))
    check(berry.ok and berry.grant == {"PECHA BERRY":1} and names(state, Vector2i(9, 1))[1] == "berrytree_pecha_empty", "a berry picked")
    check(state.source_plant_farms.has("9,1"), "the bush regrows (a farm record)")
    state.take_dirty()

    # DIG: a hole and its material; the cracked site buries its loot; refusals.
    var dig := FieldDig.apply(state, player, {"action":"dig", "cell":Vector2i(4, 3)}, rng(1))
    check(dig.ok and dig.grant == {"GRASS":1} and names(state, Vector2i(4, 3))[1].begins_with("hole1"), "DIG leaves a hole and GRASS")
    dig = FieldDig.apply(state, player, {"action":"dig", "cell":Vector2i(4, 3)}, rng(1))
    check(dig.ok and dig.events.any(func(event): return event[0] == "soil"), "DIG on a hole asks for soil")
    dig = FieldDig.apply(state, player, {"action":"surface", "cell":Vector2i(4, 3)}, rng(1))
    check(not dig.ok and dig.reason == "already_a_hole", "no second hole")
    dig = FieldDig.apply(state, player, {"action":"dig", "cell":Vector2i(5, 3)}, rng(1))
    check(names(state, Vector2i(4, 3))[1] == "hole1_E" and names(state, Vector2i(5, 3))[1] == "hole1_W", "holes side by side join")
    check(state.source_interior_mutations.get("4,3", {}).get("upper") == "hole1_E", "the joined edge is saved on the neighbour")
    dig = FieldDig.apply(state, player, {"action":"dig", "cell":Vector2i(11, 1)}, rng(5))
    check(dig.ok and names(state, Vector2i(11, 1))[2] == "LEAF STONE", "a fossil site buries its loot")
    var take := FieldDig.apply(state, player, {"action":"dig", "cell":Vector2i(11, 1)}, rng(5))
    check(take.ok and take.grant == {"LEAF STONE":1} and names(state, Vector2i(11, 1))[2] == "", "the next DIG takes it")
    var poor := player.duplicate()
    poor["bag"] = {"NEVERMELTICE": 0}
    var fill := FieldDig.apply(state, poor, {"action":"fill", "cell":Vector2i(4, 3), "choice":"SNOW"}, rng(1))
    check(not fill.ok and fill.reason == "not_enough_materials" and names(state, Vector2i(4, 3))[1].begins_with("hole1"), "soil needs its material")
    poor["bag"] = {"NEVERMELTICE": 2}
    fill = FieldDig.apply(state, poor, {"action":"fill", "cell":Vector2i(4, 3), "choice":"SNOW"}, rng(1))
    check(fill.ok and fill.consume == {"NEVERMELTICE":1} and names(state, Vector2i(4, 3))[0] == "snow2", "the hole filled with snow, paid")
    check(names(state, Vector2i(5, 3))[1] == "hole1", "the neighbour's edge goes with it")
    # A cell next to the water: its shore follows.
    dig = FieldDig.apply(state, player, {"action":"dig", "cell":Vector2i(6, 4)}, rng(1))
    check(names(state, Vector2i(6, 4))[1].begins_with("hole1_N"), "a hole by the water joins it (north is +Y)")
    var plant := FieldDig.apply(state, {"area_id":"OVERWORLD", "now":2000.0, "bag":{"BERRY SEED":1}}, {"action":"plant", "cell":Vector2i(8, 7), "item":"BERRY SEED"}, rng(1))
    check(plant.ok and plant.consume == {"BERRY SEED":1} and names(state, Vector2i(8, 7))[1] == "berry_planted", "a berry seed planted, paid")
    check(int(state.source_plant_farms.get("8,7", {}).get("day", -1)) == FieldDig.plant_day(2000.0), "the farm counts its days from now")

    # The same commands on the same area with the same numbers: the same result.
    var script := [["field_cut", {"move":"CUT", "cell":Vector2i(1, 1)}], ["field_dig", {"action":"dig", "cell":Vector2i(2, 7)}],
        ["field_dig", {"action":"dig", "cell":Vector2i(3, 7)}], ["field_dig", {"action":"dig", "cell":Vector2i(11, 1)}],
        ["field_cut", {"move":"CUT", "cell":Vector2i(3, 1)}], ["field_cut", {"move":"SMASH", "cell":Vector2i(7, 1)}],
        ["field_dig", {"action":"fill", "cell":Vector2i(2, 7), "choice":"DESERT"}], ["field_dig", {"action":"dig", "cell":Vector2i(6, 4)}]]
    var first := area()
    var second := area()
    var first_rng := rng(99)
    var second_rng := rng(99)
    var first_changes := []
    for step in script:
        var a := Rules.apply(step[0], first, player, step[1], first_rng)
        var b := Rules.apply(step[0], second, player, step[1], second_rng)
        check(a.ok == b.ok and a.grant == b.grant and a.reason == b.reason, "the same answer: %s" % [step])
        var changed := first.take_dirty()
        check(changed == second.take_dirty(), "the same changes: %s" % [step])
        first_changes.append_array(changed)
    check(store_bytes(first) == store_bytes(second), "the same tiles")

    # A replica takes the authority's changes as records: the same overlays and tiles.
    var replica := area()
    replica.tracking = false
    var records := {}
    for change in first_changes:
        var record := AreaSim.record_of(first.area, change[0], change[1], change[2])
        records[record[0]] = record[1]
    var sim = AreaSim.new()
    sim.state = replica
    sim.lay_records({}, records)
    check(overlays(replica).terrain_changes == overlays(first).terrain_changes, "replica: terrain")
    var holes_equal := true
    for key in first.source_interior_mutations:
        var mine: Dictionary = first.source_interior_mutations[key]
        var theirs: Dictionary = replica.source_interior_mutations.get(key, {})
        if mine.get("kind") != theirs.get("kind") or mine.get("base") != theirs.get("base") or String(mine.get("upper", "")).left(5) != String(theirs.get("upper", "")).left(5):
            holes_equal = false
            printerr("  ", key, " ", mine, " / ", theirs)
    check(holes_equal, "replica: the same mutations (holes rejoin their own edges)")
    check(store_bytes(replica) == store_bytes(first), "replica: the same tiles, edges and shores included")
    # And as the binary frame.
    var frame := AreaState.encode_changes(first.area, 5, first_changes)
    var read := AreaState.decode_changes(frame)
    check(read.get("changes", []).size() == first_changes.size(), "the changes read back from the frame")

    # A prediction undone: exactly the state it started from.
    var predicted := area()
    FieldDig.apply(predicted, player, {"action":"dig", "cell":Vector2i(4, 3)}, rng(1))
    predicted.take_dirty()
    var before_tiles := store_bytes(predicted)
    var before_overlays := overlays(predicted)
    predicted.begin()
    for step in script: Rules.apply(step[0], predicted, player, step[1], rng(4))
    check(store_bytes(predicted) != before_tiles, "the prediction changed the area")
    predicted.rollback()
    check(store_bytes(predicted) == before_tiles, "rolled back: the tiles as they were")
    check(overlays(predicted) == before_overlays, "rolled back: the overlays as they were")

    # Commands from the wire.
    check(Rules.from_wire("field_dig", {"action":"dig", "cell":[3, -4]}) == {"action":"dig", "cell":Vector2i(3, -4)}, "a dig from the wire")
    check(Rules.from_wire("field_dig", {"action":"explode", "cell":[3, 4]}) == null, "an unknown action: refused")
    check(Rules.from_wire("field_dig", {"action":"dig", "cell":[3.5, 4]}) == null, "a cell off the grid: refused")
    check(Rules.from_wire("field_cut", {"move":"CUT", "cell":[1, 1], "target":"everything"}) == null, "an unknown target: refused")
    check(Rules.from_wire("field_cut", {"move":"FLY", "cell":[1, 1]}) == null, "an unknown move: refused")
    check(Rules.from_wire("rare_candy", {"cell":[1, 1]}) == null, "an unknown op: refused")
    check(Rules.answered([["sound", "dig1"], ["material", "LOG", 1], ["encounter", "geodude", 9, {}, true, Vector2i(2, 3)]]) == [["material", "LOG", 1], ["encounter", "geodude", 9, {}, true, [2, 3]]], "the answer keeps what the player is told")
    print("RULES TEST: %d failed (of %d checks)" % [failed, checks])
    quit(1 if failed else 0)
