# The engine's native population (engine_modules/pokewilds, class
# PokeWildsPopulationSim) against the GDScript it ports. First its rules on
# many inputs: where a Pokemon may step, the habitat windows (names of the
# ground, what is built, flowers, landmarks, houses, night), who may mate or be
# friends, the zone query. Then an area's Pokemon frame by frame as a dedicated
# server runs them (AreaSim, with two players walking, one of them in battles
# and charming for a while): wild Pokemon wandering, chasing, fleeing a failed
# catch, charmed and fed, habitat pairs laying and harvesting, eggs, the
# ecology passes; once with each from the same start, compared after every
# frame (cells, timers, random numbers, what changed) and the whole population
# as saved every second. The World's frame is population_sim_hash.gd's: run
# it with POKEWILDS_NATIVE_POPULATION=1, its hashes must not change.
# Run: godot --headless --path project -s ../.github/engine/native_population_test.gd
extends SceneTree

const NativePopulation = preload("res://scripts/native_population.gd")
const PopulationRules = preload("res://scripts/rules/population_rules.gd")
const PokemonEcology = preload("res://scripts/pokemon_ecology.gd")
const AreaSim = preload("res://scripts/area_sim.gd")
const SEED := 12345
const FRAMES := 3600
const DELTA := 1.0 / 60.0
const SPECIES := ["rattata", "pidgey", "caterpie", "zubat", "oddish", "sentret", "magikarp", "tentacool", "geodude", "growlithe",
    "diglett", "sandshrew", "gastly", "swinub", "houndour", "dratini", "trapinch", "lapras", "araichu", "exeggutor_alolan", "ditto"]

var _failures := 0
var _tiles = null
var _rng := RandomNumberGenerator.new()

func _initialize() -> void:
    if not ClassDB.class_exists(NativePopulation.CLASS):
        printerr("NATIVE POPULATION TEST: this engine has no %s" % NativePopulation.CLASS)
        quit(1)
        return
    NativePopulation.enabled = true
    var native: Object = NativePopulation.sim()
    if native == null:
        printerr("NATIVE POPULATION TEST: %s did not start" % NativePopulation.CLASS)
        quit(1)
        return
    var started := Time.get_ticks_msec()
    var result := SourceWorldGenerator.generate_exact_source_world(SEED, 0)
    _tiles = SourceExactWorldAdapter.from_generator_result(result, SourceJavaRandom.new(SEED ^ 0x535041574E))
    print("NATIVE POPULATION TEST: world %d made in %d ms" % [SEED, Time.get_ticks_msec() - started])
    _rng.seed = 20261023
    var sim: AreaSim = await _area()
    _check_rules(native, sim.state)
    await _check_frames()
    print("NATIVE POPULATION TEST: failed %d" % _failures)
    quit(1 if _failures else 0)

func _expect(ok: bool, what: String) -> void:
    if not ok:
        _failures += 1
        printerr("NATIVE POPULATION TEST FAIL: ", what)

## A random cell of the world.
func _cell() -> Vector2i:
    var bounds: Rect2i = _tiles.bounds()
    return Vector2i(_rng.randi_range(bounds.position.x, bounds.end.x - 1), _rng.randi_range(bounds.position.y, bounds.end.y - 1))

## The area as a dedicated server holds it, its Pokemon placed as a new area's
## are, then things built about them, habitat pairs and wild ones given roles.
func _area() -> AreaSim:
    var sim := AreaSim.new()
    var state = sim.state
    state.area = "0,0"
    state.tiles = _tiles
    state.bounds = _tiles.bounds()
    state.rng.seed = SEED
    state.clock = 1000.0
    var next := [1]
    var add := func(species: String, level: int, cell: Vector2i, home_biome: String, source_record: Dictionary) -> int:
        var wild_id: int = next[0]
        if not PopulationRules.add_wild(state, species, level, cell, home_biome, wild_id, source_record): return -1
        next[0] = wild_id + 1
        return wild_id
    await PopulationRules.place_new(state, add)
    var layout := RandomNumberGenerator.new()
    layout.seed = SEED
    var ids: Array = state.wild.records.keys()
    ids.sort()
    # Built things, flowers, ice and blocked cells beside the wild Pokemon.
    for index in range(0, ids.size(), 7):
        var at: Vector2i = state.wild.records[ids[index]].cell + Vector2i(layout.randi_range(-3, 3), layout.randi_range(-3, 3))
        if state.wild.id_at(at) >= 0: continue
        match index % 5:
            0: state.structures[at] = {"name": ["FENCE", "flowers", "plant", "grave", "BRIDGE", "ROOF", "STATUE"][layout.randi_range(0, 6)], "gate": layout.randf() < 0.2}
            1: state.flowers[at] = true
            2: state.terrain_changes["ice:%d,%d" % [at.x, at.y]] = 1
            3: state.blocked[at] = true
    # Habitat Pokemon in pairs ready to lay, with their harvest nearly in.
    var placed := 0
    for index in range(3, ids.size(), maxi(1, ids.size() / 24)):
        var at: Vector2i = state.wild.records[ids[index]].cell
        var species: String = ["rattata", "pidgey", "oddish", "caterpie", "zubat", "sentret"][placed % 6]
        for offset in [Vector2i(2, 0), Vector2i(0, 2), Vector2i(-2, 0), Vector2i(0, -2)]:
            var first: Vector2i = at + offset
            var second: Vector2i = first + Vector2i(1, 0)
            if not _free(state, first, species) or not _free(state, second, species): continue
            for pair in 2:
                state.habitat.restore({"species": species, "level": 12, "gender": "female" if pair == 0 else "male", "lay_egg_seconds": 2.0 + placed,
                    "harvest_progress": 145.0, "friend_seconds": 1.0, "ecology_id": "owned:%d" % (placed * 2 + pair)}, first if pair == 0 else second)
            placed += 1
            break
    # Wild Pokemon that chase, flee a failed catch, are charmed or fed.
    for index in ids.size():
        var record: Dictionary = state.wild.records.get(ids[index], {})
        if record.is_empty() or bool(record.get("burrowed", false)): continue
        match index % 9:
            1: record["aggro_player"] = true
            2: record["ball_flee_until"] = state.clock + 40.0
            3: record["ball_charm_until"] = state.clock + 20.0
            4: record["fed_until"] = state.clock + 10.0
    state.tracking = true
    state.wild.take_dirty()
    state.habitat.take_dirty()
    state.eggs.take_dirty()
    return sim

func _free(state, cell: Vector2i, species: String) -> bool:
    return state.in_bounds(cell) and PopulationRules.can_enter(state, species, cell) and not state.habitat.records.has(cell) \
        and not state.eggs.records.has(cell) and state.wild.id_at(cell) < 0 and not state.structures.has(cell)

# --- Rules -----------------------------------------------------------------

func _check_rules(native: Object, state) -> void:
    # Where a Pokemon may step, the World's own walkable or the rules'.
    var bad := 0
    var checked := 0
    var walkable_kinds := [Callable(), func(cell: Vector2i) -> bool: return PopulationRules.is_walkable(state, cell) and (cell.x + cell.y) % 7 != 0]
    var shores := []
    for index in 30000:
        var origin := _cell()
        if index % 3 == 0 and PopulationRules.in_water(state, origin): shores.append(origin)
        var target: Vector2i = origin + [Vector2i.ZERO, Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN][index % 5]
        state.walkable = walkable_kinds[index % 2]
        var species: String = SPECIES[index % SPECIES.size()]
        checked += 1
        if PopulationRules.can_move_between(state, species, origin, target) != native.can_move_between(state, species, origin, target): bad += 1
    # From water: the shore rules.
    for origin: Vector2i in shores:
        for direction in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
            for species in ["magikarp", "lapras", "rattata", "tentacool"]:
                checked += 1
                if PopulationRules.can_move_between(state, species, origin, origin + direction) != native.can_move_between(state, species, origin, origin + direction): bad += 1
    state.walkable = Callable()
    _expect(bad == 0, "can_move_between: %d of %d differ" % [bad, checked])
    # Habitat windows, by day and by night, in a house too.
    bad = 0
    checked = 0
    var house := {}
    for cell in state.structures: house[cell] = true
    for index in 3000:
        var cell := _cell()
        if index % 4 == 0 and not state.structures.is_empty(): cell = state.structures.keys()[index % state.structures.size()] + Vector2i(index % 3 - 1, 0)
        state.clock = 1000.0 + (200.0 if index % 2 else 0.0)
        var species: String = SPECIES[index % SPECIES.size()]
        var cells: Dictionary = house if index % 5 == 0 else {}
        var expected: Dictionary = PopulationRules.refresh_record_habitat(state, {"species": species}, cell, {}, cells)
        var got: Dictionary = native.refresh_record_habitat(state, {"species": species}, cell, cells)
        checked += 1
        if got.is_empty() or JSON.stringify(expected) != JSON.stringify(got) or expected.missing_habitats.get_typed_builtin() != got.missing_habitats.get_typed_builtin():
            bad += 1
            if bad <= 3: printerr("  habitat of %s on %s: %s, native %s" % [species, cell, expected, got])
    state.clock = 1000.0
    _expect(bad == 0, "refresh_record_habitat: %d of %d differ" % [bad, checked])
    # Who may mate and be friends: the area's Pokemon and odd records.
    var records: Array = state.wild.records.values().slice(0, 120) + state.habitat.records.values()
    records.append_array([{"species": "ditto", "egg_groups": ["EGG_DITTO"]}, {"species": "Ditto"}, {"species": "pidgey", "is_egg": true},
        {"species": "pidgey", "gender": "unknown"}, {"species": "pidgey", "gender": "MALE"}, {"species": "Pidgey ", "gender": "female"},
        {"species": "rattata", "egg_groups": ["egg_field", "EGG_FIELD"], "gender": "female"}, {"species": "rattata", "egg_groups": "EGG_FIELD"},
        {"species": "rattata", "egg_groups": ["EGG_NONE"], "gender": "male"}, {}])
    bad = 0
    checked = 0
    for first in records:
        for second in records:
            checked += 1
            if PokemonEcology.can_mate(first, second) != native.can_mate(first, second): bad += 1
            if PokemonEcology.can_be_friends(first, second) != native.can_be_friends(first, second): bad += 1
    _expect(bad == 0, "can_mate/can_be_friends: %d of %d pairs differ" % [bad, checked])
    # The zone query.
    bad = 0
    for index in 400:
        var squares: Array = []
        for square in _rng.randi_range(1, 60):
            var center := _cell()
            squares.append(Vector3i(center.x, center.y, _rng.randi_range(0, 30)))
        NativePopulation.enabled = false
        var expected: PackedInt32Array = state.wild.slots_in(squares)
        NativePopulation.enabled = true
        if expected != native.slots_in(state.wild, squares): bad += 1
    _expect(bad == 0, "slots_in: %d of 400 queries differ" % bad)
    print("NATIVE POPULATION TEST: rules checked (%d steps, %d windows, %d pairs)" % [30000 + shores.size() * 16, 3000, records.size() * records.size()])

# --- Frames ----------------------------------------------------------------

## Two players walking about where the wild Pokemon are thickest; the second
## battles for a while, then charms.
func _packets(home: Vector2i, frame: int) -> Dictionary:
    var lap := [Vector2i.RIGHT, Vector2i.DOWN, Vector2i.LEFT, Vector2i.UP]
    var walked := frame / 12
    var side: Vector2i = lap[(walked / 10) % 4]
    var at := home + side * (walked % 10)
    var other := home + Vector2i(6, 0) - side * (walked % 10)
    var battle := frame > 900 and frame < 1500
    var move := "CHARM" if frame > 1800 and frame < 2400 else ""
    return {"alice": {"area": "0,0", "layer": "OVERWORLD", "cell_x": at.x, "cell_y": at.y, "battle": false, "visual": {"move": ""}, "field_level": 30, "party_level": 30},
        "bob": {"area": "0,0", "layer": "OVERWORLD", "cell_x": other.x, "cell_y": other.y, "battle": battle, "visual": {"move": move}, "field_level": 60, "party_level": 60}}

func _home(state) -> Vector2i:
    var best := Vector2i.ZERO
    var best_count := -1
    var cells: Array = []
    for record in state.wild.records.values(): cells.append(record.cell)
    for at: Vector2i in cells:
        var count := 0
        for other: Vector2i in cells:
            if maxi(absi(other.x - at.x), absi(other.y - at.y)) <= 12: count += 1
        if count > best_count:
            best_count = count
            best = at
    return best

## What a frame left: cells, timers, random numbers, what changed.
func _frame_digest(sim: AreaSim, dirty: PackedInt64Array) -> String:
    var state = sim.state
    var context := HashingContext.new()
    context.start(HashingContext.HASH_SHA256)
    for part in [state.wild.ids, state.wild.cell_x, state.wild.cell_y, state.wild.flags, state.wild.timers, dirty, state.wild.take_dirty(),
            state.habitat.take_dirty(), state.eggs.take_dirty(), state.rng.state, state.habitat.records.keys(), state.eggs.records.keys(),
            sim.players.marked.keys(), state.wild.watched, state.wild.flee_routes]:
        context.update(var_to_bytes(part))
    sim.players.marked.clear()
    return context.finish().hex_encode()

## The whole population as saved.
func _saved(state) -> String:
    return JSON.stringify([state.wild.to_save(), state.habitat.to_save(), state.eggs.to_save(), state.wild.motion, state.wild.poses], "", true, true)

## The area's frames, with the native population or the GDScript: the
## GDScript's fill `expected` (each frame's digest) and `saves` (the whole
## population every second); the native's are compared with them. With
## `stop_at` the GDScript stops there and returns the whole population.
func _run(native: bool, expected: Array, saves: Array, stop_at := -1) -> String:
    NativePopulation.enabled = native
    var sim: AreaSim = await _area()
    var home := _home(sim.state)
    var started := Time.get_ticks_usec()
    for frame in FRAMES:
        sim.state.clock += DELTA
        # The zone scan every 30th frame (it runs every 500 ms of wall time).
        sim.state.wild.watched_at = -100000 if frame % 30 == 0 else Time.get_ticks_msec()
        var observers: Array = sim.players.refresh(_packets(home, frame), "0,0")
        sim.tick(DELTA, observers)
        var digest := _frame_digest(sim, sim.state.wild._tick_dirty)
        if frame == stop_at:
            NativePopulation.enabled = true
            return _saved(sim.state)
        var saved := _saved(sim.state) if frame % 60 == 59 else ""
        if not native:
            expected.append(digest)
            saves.append(saved)
            continue
        if digest != expected[frame] or saved != saves[frame]:
            _expect(false, "frame %d differs (%s)" % [frame, "the saved population" if digest == expected[frame] else "cells, timers, RNG or changes"])
            var got := _saved(sim.state)
            _report(await _run(false, [], [], frame), got)
            NativePopulation.enabled = true
            return ""
    print("NATIVE POPULATION TEST: %d frames %s in %.0f ms (%d wild, %d habitat, %d eggs at the end)" % [FRAMES, "native" if native else "GDScript",
        (Time.get_ticks_usec() - started) / 1000.0, sim.state.wild.size(), sim.state.habitat.size(), sim.state.eggs.size()])
    NativePopulation.enabled = true
    return ""

## The first saved record that differs (`want`: the GDScript's, `got`: the native's).
func _report(want_text: String, got_text: String) -> void:
    var want: Array = JSON.parse_string(want_text)
    var got: Array = JSON.parse_string(got_text)
    var parts := ["wild", "habitat", "eggs", "motion", "poses"]
    for part in parts.size():
        if JSON.stringify(got[part]) == JSON.stringify(want[part]): continue
        if got[part] is Array and want[part] is Array:
            for index in mini(got[part].size(), want[part].size()):
                if JSON.stringify(got[part][index]) != JSON.stringify(want[part][index]):
                    printerr("  %s record %d:
    GDScript %s
    native   %s" % [parts[part], index, JSON.stringify(want[part][index]), JSON.stringify(got[part][index])])
                    return
            printerr("  %s: %d records, native %d" % [parts[part], want[part].size(), got[part].size()])
        else:
            printerr("  %s differ:
    GDScript %s
    native   %s" % [parts[part], JSON.stringify(want[part]).left(600), JSON.stringify(got[part]).left(600)])
        return
    printerr("  the saved population is the same: cells, timers, RNG or what changed differ")

func _check_frames() -> void:
    var expected: Array = []
    var saves: Array = []
    await _run(false, expected, saves)
    await _run(true, expected, saves)
