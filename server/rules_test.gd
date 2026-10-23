# The field rules (project/scripts/rules/) without a world, on a small
# AreaState: what DIG, CUT, SMASH, picking berries, planting and taking items
# change and give, what they refuse; the same command on the same state with
# the same random numbers always the same; a replica that takes the
# authority's changes (as records, as the binary frame) ends with the same
# overlays and tiles; a prediction rolled back leaves the state exactly as it
# was; commands from the wire checked. Building (rules/build.gd): what may
# go where, what it costs, how pieces join, a house's inside worked out from
# the data alone, furniture, pictures and clocks; taking pieces away
# (remove.gd) and what comes back; several predictions in flight, the middle
# one refused, undone with the one after it and that one played again;
# what a player changes on a piece (interact.gd): a sign, a torch, a plant's seed.
# Run: godot --headless --path project -s ../server/rules_test.gd
extends SceneTree

const AreaState = preload("res://scripts/area_state.gd")
const AreaSim = preload("res://scripts/area_sim.gd")
const Rules = preload("res://scripts/rules/rules.gd")
const FieldDig = preload("res://scripts/rules/field_dig.gd")
const FieldCut = preload("res://scripts/rules/field_cut.gd")
const FieldMoveData = preload("res://scripts/field_move_data.gd")
const TileRules = preload("res://scripts/rules/tile_rules.gd")
const Build = preload("res://scripts/rules/build.gd")
const Remove = preload("res://scripts/rules/remove.gd")
const Paint = preload("res://scripts/rules/paint.gd")
const Interact = preload("res://scripts/rules/interact.gd")
const Delta = preload("res://scripts/coop_world_delta.gd")

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
    check(state.source_interior_mutations.get(Vector2i(1, 1), {}).get("kind") == "TILE_NAMES", "the cut is saved")
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
    check(state.source_interior_mutations.get(Vector2i(9, 1), {}).get("kind") == "BERRY_AGITATED", "online, the tree is marked agitated for every player")
    state.edit(Vector2i(9, 1)).set_names("green1", "berrytree_pecha_full")
    (state.tile_at(Vector2i(9, 1)).route_belongs_to as SourceRoute).stored_pokemon.clear()
    berry = FieldDig.apply(state, player, {"action":"berry", "cell":Vector2i(9, 1)}, rng(1))
    check(berry.ok and berry.grant == {"PECHA BERRY":1} and names(state, Vector2i(9, 1))[1] == "berrytree_pecha_empty", "a berry picked")
    check(state.source_plant_farms.has(Vector2i(9, 1)), "the bush regrows (a farm record)")
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
    check(state.source_interior_mutations.get(Vector2i(4, 3), {}).get("upper") == "hole1_E", "the joined edge is saved on the neighbour")
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
    check(int(state.source_plant_farms.get(Vector2i(8, 7), {}).get("day", -1)) == FieldDig.plant_day(2000.0), "the farm counts its days from now")

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
    check(Rules.from_wire("build", {"recipe":"FENCE", "cell":[2, 3]}) == {"recipe":"FENCE", "cell":Vector2i(2, 3)}, "a build from the wire")
    check(Rules.from_wire("build", {"recipe":"GOLDEN THRONE", "cell":[2, 3]}) == null, "an unknown recipe: refused")
    check(Rules.from_wire("paint", {"picture":7.0, "cell":[2, 3]}) == {"picture":7, "cell":Vector2i(2, 3)}, "a picture from the wire")
    check(Rules.from_wire("paint", {"picture":21, "cell":[2, 3]}) == null, "no picture 21")
    check(Rules.from_wire("remove_build", {"move":"SMASH", "cell":[2, 3], "wipe":true}) == {"move":"SMASH", "cell":Vector2i(2, 3), "wipe":true}, "a removal from the wire")
    check(Rules.from_wire("remove_build", {"move":"HEADBUTT", "cell":[2, 3]}) == null, "a piece is cut or smashed, nothing else")
    check(Rules.from_wire("remove_build", {"move":"CUT", "cell":[2, 3], "decoration":"yes"}) == null, "flags are true or false")
    check(Rules.from_wire("interact", {"action":"sign", "cell":[2, 3], "text":"HELLO"}) == {"action":"sign", "cell":Vector2i(2, 3), "text":"HELLO"}, "a sign written, from the wire")
    check(Rules.from_wire("interact", {"action":"burn", "cell":[2, 3]}) == null and Rules.from_wire("interact", {"action":"sign", "cell":[2, 3], "text":"x".repeat(65)}) == null, "an unknown change or too many words: refused")
    check(Rules.reads("build", {"recipe":"FENCE"}) == ["bag"] and Rules.reads("paint", {}) == ["bag"] and Rules.reads("remove_build", {}).is_empty(), "builds and pictures read the bag, a removal nothing")
    _builds()
    _house()
    _in_flight()
    _interactions()
    print("RULES TEST: %d failed (of %d checks)" % [failed, checks])
    quit(1 if failed else 0)

static func said(result: Dictionary, text: String) -> bool:
    return result.events.any(func(event): return event[0] == "message" and String(event[1]) == text)

static func pieces(state: AreaState) -> Dictionary:
    var result := {}
    for cell in state.structures:
        if not state.structures[cell].get("generated_stair_pair", false): result[cell] = AreaState.structure_record(cell, state.structures[cell])
    return result

## What may go where, what it costs and gives back, how pieces join.
func _builds() -> void:
    var state := area()
    var outside := {"area_id":"OVERWORLD", "shared":true}
    var made := Build.apply(state, outside, {"recipe":"FENCE", "cell":Vector2i(2, 3)}, rng(1))
    check(made.ok and made.consume == {"LOG":1, "GRASS":1}, "a FENCE placed and paid: %s" % [made])
    check(state.structures.get(Vector2i(2, 3), {}).get("name") == "FENCE" and state.blocked.has(Vector2i(2, 3)), "the FENCE stands and blocks its cell")
    check(state.take_dirty().any(func(change): return change[0] == "structures" and change[1] == Vector2i(2, 3)), "the FENCE is a changed record")
    var twice := Build.apply(state, outside, {"recipe":"FENCE", "cell":Vector2i(2, 3)}, rng(1))
    check(not twice.ok and twice.reason == "occupied", "not twice on one cell: %s" % twice.reason)
    var wet := Build.apply(state, outside, {"recipe":"FENCE", "cell":Vector2i(2, 5)}, rng(1))
    check(not wet.ok and wet.reason == "water" and not state.structures.has(Vector2i(2, 5)), "no FENCE on the water: %s" % wet.reason)
    var bridge := Build.apply(state, outside, {"recipe":"BRIDGE", "cell":Vector2i(3, 5)}, rng(1))
    check(bridge.ok and state.structures[Vector2i(3, 5)].bridged_water and not state.blocked.has(Vector2i(3, 5)), "a BRIDGE over the water, walked on")
    var grass := Build.apply(state, outside, {"recipe":"FENCE", "cell":Vector2i(1, 1)}, rng(1))
    check(not grass.ok and grass.reason == "tall_grass", "nothing built in tall grass: %s" % grass.reason)
    var broke := Build.apply(state, {"area_id":"OVERWORLD", "bag":{"LOG":1}}, {"recipe":"FENCE", "cell":Vector2i(6, 3)}, rng(1))
    check(not broke.ok and broke.reason == "not_enough_materials" and said(broke, "Not enough materials for FENCE.") and not state.structures.has(Vector2i(6, 3)), "a FENCE the bag cannot pay for: refused, said why")
    check(Build.apply(state, outside, {"recipe":"GOLDEN THRONE", "cell":Vector2i(6, 3)}, rng(1)).reason == "invalid_recipe", "an unknown recipe: refused")
    var kiln := Build.apply(state, outside, {"recipe":"KILN", "cell":Vector2i(6, 3)}, rng(1))
    check(not kiln.ok and said(kiln, "That must be built indoors."), "a KILN out in the open: refused, said why")
    # A door between two fences is a gate: no wall, walked through.
    Build.apply(state, outside, {"recipe":"DOOR", "cell":Vector2i(3, 3)}, rng(1))
    check(not state.structures[Vector2i(3, 3)].get("gate", false) and state.blocked.has(Vector2i(3, 3)), "a door with one fence beside it is shut")
    Build.apply(state, outside, {"recipe":"FENCE", "cell":Vector2i(4, 3)}, rng(1))
    check(state.structures[Vector2i(3, 3)].get("gate", false) and not state.blocked.has(Vector2i(3, 3)), "between two fences it is a gate")
    check(int(state.structures[Vector2i(2, 3)].get("connections", 0)) == 1 and int(state.structures[Vector2i(4, 3)].get("connections", 0)) == 1, "the fences join it sideways")
    # Taken away: what it cost comes back; the gate is a door again.
    var cut := Remove.apply(state, outside, {"cell":Vector2i(4, 3), "move":"CUT"}, rng(1))
    check(cut.ok and cut.grant == {"LOG":1, "GRASS":1} and cut.events.any(func(event): return event[0] == "refund"), "a FENCE cut: its cost back")
    check(not state.structures.has(Vector2i(4, 3)) and not state.blocked.has(Vector2i(4, 3)), "the FENCE is gone, its cell free")
    check(not state.structures[Vector2i(3, 3)].get("gate", true) and state.blocked.has(Vector2i(3, 3)), "the gate is a shut door again")
    check(Remove.apply(state, outside, {"cell":Vector2i(4, 3), "move":"CUT"}, rng(1)).reason == "already_removed", "nothing left to cut")
    check(Remove.apply(state, outside, {"cell":Vector2i(2, 3), "move":"SMASH"}, rng(1)).reason == "wrong_field_move", "a FENCE is cut, not smashed")
    # A GRAVE is smashed; sometimes a ghost rises (the authority's numbers).
    Build.apply(state, outside, {"recipe":"GRAVE", "cell":Vector2i(8, 3)}, rng(1))
    check(Remove.apply(state, outside, {"cell":Vector2i(8, 3), "move":"CUT"}, rng(1)).reason == "wrong_field_move", "a GRAVE is not cut")
    var risen := 0
    for seed_value in 40:
        var graves := area()
        Build.apply(graves, outside, {"recipe":"GRAVE", "cell":Vector2i(8, 3)}, rng(1))
        var smashed := Remove.apply(graves, outside, {"cell":Vector2i(8, 3), "move":"SMASH"}, rng(seed_value))
        if smashed.events.any(func(event): return event[0] == "encounter" and event[1] in Remove.GHOSTS and event[2] == 22): risen += 1
        if seed_value == 7:
            var again := area()
            Build.apply(again, outside, {"recipe":"GRAVE", "cell":Vector2i(8, 3)}, rng(1))
            check(Remove.apply(again, outside, {"cell":Vector2i(8, 3), "move":"SMASH"}, rng(7)).events == smashed.events, "the same numbers, the same ghost or none")
    check(risen > 0 and risen < 40, "a ghost rises from some GRAVEs (%d of 40)" % risen)
    # An area held without a World takes a structure record with what it blocks.
    var sim = AreaSim.new()
    sim.state = area()
    sim.apply_record("structures", "5,8", Delta.encode(AreaState.structure_record(Vector2i(5, 8), {"name":"WALL", "recipe_name":"WALL", "house_style":"DEFAULT"})))
    check(sim.state.blocked.has(Vector2i(5, 8)) and sim.state.structures[Vector2i(5, 8)].get("solid", false), "a WALL record blocks its cell in an AreaSim")
    sim.apply_record("structures", "5,8", Delta.encode(null))
    check(not sim.state.blocked.has(Vector2i(5, 8)), "and frees it when it goes")

## A house built, its inside worked out from the data alone, furnished,
## painted, and a piece of its outside cut with what stands behind it.
func _house() -> void:
    var state := area()
    var outside := {"area_id":"OVERWORLD", "shared":true}
    for x in [8, 9, 10]: Build.apply(state, outside, {"recipe":"ROOF", "cell":Vector2i(x, 6)}, rng(1))
    for piece in [["WALL", 8], ["DOOR", 9], ["WALL", 10]]: Build.apply(state, outside, {"recipe":piece[0], "cell":Vector2i(piece[1], 7)}, rng(1))
    var door := Vector2i(9, 7)
    check(Build.house_state(state, door).ready, "roof over wall, door, wall: a house")
    var inside := {"area_id":"HOUSE", "house_door":door, "species":"smeargle"}
    var wall := Build.apply(state, inside, {"recipe":"WALL", "cell":Vector2i(0, 0)}, rng(1))
    check(not wall.ok and said(wall, "WALL can only be built outside."), "no outside WALL in a house, said why")
    var ctx: Dictionary = inside.house
    var origin := Vector2i(state.bounds.size.x + 9, 5)
    check(ctx.origin == origin and ctx.size == Vector2i(3, 2) and int(state.built_house_origins.get(Vector2i(9, 7), -1)) == 5, "its room lies off the map, its origin recorded: %s" % [ctx.origin])
    check(ctx.interior.has(origin) and ctx.interior.has(origin + Vector2i(2, 1)) and ctx.walls.has(origin + Vector2i(1, -1)), "its floor and rear wall")
    check(ctx.exits.has(origin + Vector2i(1, 2)), "its door is a way out below the room")
    var bed := Build.apply(state, inside, {"recipe":"BED", "cell":origin + Vector2i(0, 1)}, rng(1))
    check(bed.ok and state.structures.get(origin + Vector2i(0, 1), {}).get("name") == "BED", "a BED in the room: %s" % bed.reason)
    check(not Build.apply(state, inside, {"recipe":"STOOL", "cell":origin}, rng(1)).ok, "nothing on a bed's head")
    var clock := Build.apply(state, inside, {"recipe":"CLOCK", "cell":origin + Vector2i(2, -1)}, rng(1))
    check(clock.ok and state.built_house_decorations.get("9,7|2,-1", {}).get("name") == "CLOCK", "a CLOCK on the rear wall: %s" % clock.reason)
    var painted := Paint.apply(state, inside, {"cell":origin + Vector2i(1, -1), "picture":7}, rng(1))
    check(painted.ok and int(state.built_house_paintings.get("9,7|1,-1", 0)) == 7 and painted.consume == {"THIN PAPER":1}, "SMEARGLE paints PICTURE 7 for a THIN PAPER")
    var machop := Paint.apply(state, {"area_id":"HOUSE", "house_door":door, "species":"machop"}, {"cell":origin + Vector2i(1, -1), "picture":3}, rng(1))
    check(not machop.ok and said(machop, "PAINT can only be used by SMEARGLE on an inside house wall."), "only SMEARGLE paints")
    var floor := Paint.apply(state, {"area_id":"HOUSE", "house_door":door, "species":"smeargle"}, {"cell":origin, "picture":3}, rng(1))
    check(not floor.ok and said(floor, "Face an inside house wall to PAINT it."), "the floor is not painted")
    var paperless := Paint.apply(state, {"area_id":"HOUSE", "house_door":door, "species":"smeargle", "bag":{}}, {"cell":origin + Vector2i(1, -1), "picture":3}, rng(1))
    check(not paperless.ok and paperless.reason == "not_enough_materials", "no THIN PAPER, no picture")
    var unhung := Remove.apply(state, {"area_id":"HOUSE", "house_door":door}, {"cell":origin + Vector2i(2, -1), "move":"CUT", "decoration":true}, rng(1))
    check(unhung.ok and unhung.grant == Build.CraftingData.build_recipe("CLOCK").cost and not state.built_house_decorations.has("9,7|2,-1"), "the CLOCK taken down, its cost back")
    # The outside's corner cut: the tile of the room behind it goes with what stands there.
    var corner := Remove.apply(state, outside, {"cell":Vector2i(8, 7), "move":"CUT"}, rng(1))
    var back: Dictionary = {}
    for item in Build.CraftingData.build_recipe("WALL").cost: back[item] = int(back.get(item, 0)) + int(Build.CraftingData.build_recipe("WALL").cost[item])
    for item in Build.CraftingData.build_recipe("BED").cost: back[item] = int(back.get(item, 0)) + int(Build.CraftingData.build_recipe("BED").cost[item])
    check(corner.ok and not state.structures.has(origin + Vector2i(0, 1)) and corner.grant == back, "the BED behind the cut WALL goes with it, both paid back: %s" % [corner.grant])

## Three predictions in flight on a player's copy, the middle one refused by
## the authority: it is undone with the one after it, which is played again
## on what is left. The copy ends as the authority's, which never had it.
func _in_flight() -> void:
    var outside := {"area_id":"OVERWORLD", "shared":true}
    var cells := [Vector2i(2, 8), Vector2i(3, 8), Vector2i(4, 8)]
    var authority := area()
    for cell in [cells[0], cells[2]]: Build.apply(authority, outside, {"recipe":"FENCE", "cell":cell}, rng(1))
    FieldDig.apply(authority, outside, {"action":"dig", "cell":Vector2i(6, 8)}, rng(2))
    for confirmed_first in [false, true]:
        var copy := area()
        copy.begin("a")
        Build.apply(copy, outside, {"recipe":"FENCE", "cell":cells[0]}, rng(1))
        copy.begin("b")
        Build.apply(copy, outside, {"recipe":"FENCE", "cell":cells[1]}, rng(1))
        copy.begin("c")
        Build.apply(copy, outside, {"recipe":"FENCE", "cell":cells[2]}, rng(1))
        FieldDig.apply(copy, outside, {"action":"dig", "cell":Vector2i(6, 8)}, rng(2))
        check(int(copy.structures[cells[0]].get("connections", 0)) == 1, "in flight: the fences join")
        copy.commit("a")
        # The answer for "c" may come first (it is kept until "b" is settled).
        if confirmed_first: copy.commit("c")
        copy.rollback("b")
        check(copy.undone == ["c"], "the refusal undoes the one after it too: %s" % [copy.undone])
        check(not copy.structures.has(cells[1]) and not copy.structures.has(cells[2]) and copy.structures.has(cells[0]), "the first stays, the others are undone")
        check(not copy.tile_at(Vector2i(6, 8)).name_upper.begins_with("hole1"), "the undone one's hole is filled again")
        copy.begin("c")
        Build.apply(copy, outside, {"recipe":"FENCE", "cell":cells[2]}, rng(1))
        FieldDig.apply(copy, outside, {"action":"dig", "cell":Vector2i(6, 8)}, rng(2))
        copy.commit("c")
        check(not copy.recording(), "nothing left recording")
        check(pieces(copy) == pieces(authority) and copy.blocked == authority.blocked, "%s: the copy's pieces are the authority's" % ("c answered first" if confirmed_first else "in order"))
        check(store_bytes(copy) == store_bytes(authority), "%s: the copy's tiles are the authority's" % ("c answered first" if confirmed_first else "in order"))

## A built piece changed for everyone: a sign written, a torch put out, a
## plant's seed once a day by the authority's clock, a window's glass.
func _interactions() -> void:
    var state := area()
    var outside := {"area_id":"OVERWORLD", "now":1000.0}
    for piece in [["SIGN", Vector2i(2, 3)], ["TORCH", Vector2i(4, 3)], ["PLANT", Vector2i(6, 3)], ["WALL", Vector2i(8, 3)]]:
        Build.apply(state, outside, {"recipe":piece[0], "cell":piece[1]}, rng(1))
    var sign := Interact.apply(state, outside, {"cell":Vector2i(2, 3), "action":"sign", "text":"  WELCOME HOME  "}, rng(1))
    check(sign.ok and state.structures[Vector2i(2, 3)].text == "WELCOME HOME" and said(sign, "The SIGN now reads: WELCOME HOME"), "a SIGN written")
    check(not Interact.apply(state, outside, {"cell":Vector2i(4, 3), "action":"sign", "text":"X"}, rng(1)).ok, "a TORCH is no sign")
    var torch := Interact.apply(state, outside, {"cell":Vector2i(4, 3), "action":"torch"}, rng(1))
    check(torch.ok and state.structures[Vector2i(4, 3)].lit == false and said(torch, "The TORCH is now out."), "a TORCH put out")
    var seed := Interact.apply(state, outside, {"cell":Vector2i(6, 3), "action":"plant"}, rng(1))
    check(seed.ok and seed.grant == {"MIRACLE SEED":1} and said(seed, "The PLANT yielded a MIRACLE SEED."), "a PLANT gives its seed")
    var again := Interact.apply(state, outside, {"cell":Vector2i(6, 3), "action":"plant"}, rng(1))
    check(not again.ok and again.grant.is_empty() and said(again, "The PLANT needs another day to grow."), "once a day")
    var tomorrow := Interact.apply(state, {"area_id":"OVERWORLD", "now":1000.0 + Interact.DAY_SECONDS}, {"cell":Vector2i(6, 3), "action":"plant"}, rng(1))
    check(tomorrow.ok and tomorrow.grant == {"MIRACLE SEED":1}, "and again the next day")
    check(not Interact.apply(state, outside, {"cell":Vector2i(8, 3), "action":"glass"}, rng(1)).ok, "a bare WALL has no glass")
    Build.apply(state, outside, {"recipe":"INDOOR WINDOW 1", "cell":Vector2i(8, 3)}, rng(1))
    var glass := Interact.apply(state, outside, {"cell":Vector2i(8, 3), "action":"glass"}, rng(1))
    check(glass.ok and int(state.structures[Vector2i(8, 3)].window_variant) == 1, "an indoor window in a wall: its glass changed")
