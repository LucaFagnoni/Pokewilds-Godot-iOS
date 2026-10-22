# The engine's native world generator (engine_modules/pokewilds) against the
# GDScript it ports: its primitives (java.util.Random, libGDX float math,
# Java HashMap order) on many inputs, then worlds step by step (the tiles'
# hash and the three RNG states after each step of generate_complete).
# Whole worlds are worldgen_check.gd's job: run it with POKEWILDS_NATIVE_WORLDGEN=1.
# Run: godot --headless --path project -s ../.github/engine/native_worldgen_test.gd
extends SceneTree

const NativeWorldGen = preload("res://scripts/native_world_gen.gd")
const SourceLibGDXMath = preload("res://scripts/source_libgdx_math.gd")
# Seed 1's first attempt fails validation: its steps still match.
const STAGE_WORLDS := [[12345, 0], [1, 0], [424242, 1]]

var _failures := 0

func _initialize() -> void:
    if not ClassDB.class_exists(NativeWorldGen.CLASS):
        printerr("NATIVE TEST: this engine has no %s" % NativeWorldGen.CLASS)
        quit(1)
        return
    var native: Object = ClassDB.instantiate(NativeWorldGen.CLASS)
    var rng := RandomNumberGenerator.new()
    rng.seed = 20261022
    _check_random(native, rng)
    _check_libgdx(native, rng)
    _check_hash_order(native, rng)
    for world: Array in STAGE_WORLDS:
        _check_stages(world[0], world[1])
    print("NATIVE TEST: failed %d" % _failures)
    quit(1 if _failures else 0)

func _expect(ok: bool, what: String) -> void:
    if not ok:
        _failures += 1
        printerr("NATIVE TEST FAIL: ", what)

func _check_random(native: Object, rng: RandomNumberGenerator) -> void:
    var seeds := [0, 1, -1, 12345, 281474976710655, -1099511627776, 1792426775391992 ^ 0x50C3E811]
    var fixed := [-1, 1, 2, 3, 7, 13, 16, 100, 200, 512, 1000, 1 << 30, 2147483647]
    for seed_value: int in seeds:
        var bounds := PackedInt64Array()
        for index in 4000:
            bounds.append(fixed[index % fixed.size()] if index % 3 else rng.randi_range(1, 1 << 20))
        var expected := PackedInt64Array()
        var random := SourceJavaRandom.new(seed_value)
        for bound in bounds:
            expected.append(random.next_int(bound))
        _expect(native.call("java_random_ints", seed_value, bounds) == expected, "java.util.Random, seed %d" % seed_value)

func _check_libgdx(native: Object, rng: RandomNumberGenerator) -> void:
    var vectors := PackedVector2Array()
    var degrees := PackedFloat64Array()
    var targets := PackedVector2Array()
    for index in 20000:
        var whole := index % 2 == 0
        var x := float(rng.randi_range(-4000, 4000) * 16) if whole else rng.randf_range(-70000.0, 70000.0)
        var y := float(rng.randi_range(-4000, 4000) * 16) if whole else rng.randf_range(-70000.0, 70000.0)
        vectors.append(Vector2(x, y))
        targets.append(Vector2(rng.randi_range(-500, 500) * 16, rng.randi_range(-500, 500) * 16))
        degrees.append([45.0, -15.0, 90.0, 180.0, float(rng.randi_range(10, 89)), rng.randf_range(-90.0, 90.0)][index % 6])
    var rotated: PackedVector2Array = native.call("libgdx_rotate", vectors, degrees)
    var distances: PackedFloat64Array = native.call("libgdx_distance", vectors, targets)
    var bad_rotations := 0
    var bad_distances := 0
    for index in vectors.size():
        if rotated[index] != SourceLibGDXMath.rotate_deg(vectors[index], degrees[index]): bad_rotations += 1
        if distances[index] != SourceLibGDXMath.distance(vectors[index], targets[index]): bad_distances += 1
    _expect(bad_rotations == 0, "libGDX rotateDeg: %d of %d differ" % [bad_rotations, vectors.size()])
    _expect(bad_distances == 0, "libGDX dst: %d of %d differ" % [bad_distances, vectors.size()])

func _check_hash_order(native: Object, rng: RandomNumberGenerator) -> void:
    var generator := SourceIslandGenerator.new(Vector2i.ZERO, 30000, SourceJavaRandom.new(1), SourceJavaRandom.new(2))
    var cases: Array = []
    for species: String in ["eevee", "poliwag", "gloom", "slowpoke", "tyrogue", "wurmple", "kirlia", "snorunt", "clamperl", "burmy", "combee"]:
        cases.append(PokemonData.info(species).get("evolutions", []))
    var parameters := ["12", "21", "36", "100", "fire_stone", "WATER_STONE", "dusk_stone", "trade", "LEVEL_UP", "happiness_day"]
    for index in 300:
        var evolutions: Array = []
        for entry in rng.randi_range(1, 24):
            evolutions.append({"parameter": parameters[rng.randi_range(0, parameters.size() - 1)] + ("" if rng.randf() < 0.5 else str(entry)),
                "species": "s%d" % entry})
        cases.append(evolutions)
    var bad := 0
    for evolutions: Array in cases:
        if native.call("java_evolution_order", evolutions) != generator._source_java_evolution_order(evolutions): bad += 1
    _expect(bad == 0, "Java HashMap order: %d of %d differ" % [bad, cases.size()])

## generate_complete's steps in GDScript, a line per step (as the native "native_qa").
func _gdscript_stages(seed_value: int, size_index: int) -> PackedStringArray:
    var g := SourceIslandGenerator.new(Vector2i.ZERO, SourceWorldGenerator.source_radius_for_size(size_index),
        SourceJavaRandom.new(seed_value ^ 0x50C3E811), SourceJavaRandom.new(seed_value),
        SourceJavaRandom.new(seed_value ^ 0x6F72657374), SourceJavaRandom.new(seed_value ^ 0x506F6B656D6F6E))
    var lines := PackedStringArray()
    g.interior_tiles_to_add.clear()
    g.interior_tiles_to_add.resize(102)
    var surface := g.generate_surface()
    lines.append(_stage(g, "surface_done"))
    var desert_tiles := surface["desert_tiles"] as Array
    var deep_forest_tiles := surface["deep_forest_tiles"] as Array
    surface.clear()
    g._restore_source_landmark_flags()
    g.done_regi_dungeon = true
    var plan := g._place_source_landmarks(desert_tiles, deep_forest_tiles)
    lines.append(_stage(g, "landmarks"))
    desert_tiles = []
    g._cleanup_and_place_deep_forest_landmarks(deep_forest_tiles, plan["hitboxes"] as Array, plan["mansion_box"] as Rect2i)
    lines.append(_stage(g, "cleanup"))
    g._postprocess_source_shores()
    lines.append(_stage(g, "shores"))
    g._postprocess_source_puddles()
    lines.append(_stage(g, "puddles"))
    g._spawn_source_overworld_pokemon()
    lines.append(_stage(g, "spawn"))
    g._add_required_regi_after_source_world(deep_forest_tiles)
    lines.append(_stage(g, "regi"))
    g._complete_missing_landmarks()
    lines.append(_stage(g, "complete"))
    for position in g.trapinch_spawns:
        var trap_tile := g.tile_at(position)
        if trap_tile != null and trap_tile.name == "desert2":
            trap_tile.items["trapinch"] = 1
    lines.append(_stage(g, "done"))
    return lines

func _stage(g: SourceIslandGenerator, stage_name: String) -> String:
    return "STAGE name=%s tiles=%d pokemon=%d sha256=%s rng=%d,%d,%d" % [stage_name, g.tiles_to_add.size(),
        g.pokemon_to_add.size(), g.qa_surface_sha256(), g.random.state(), g.global_random.state(), g.pokemon_random.state()]

func _check_stages(seed_value: int, size_index: int) -> void:
    var native_lines: Array = NativeWorldGen.generate(seed_value, size_index, [], true).get("native_qa", [])
    var expected := _gdscript_stages(seed_value, size_index)
    # The native lines of attempt 0, from surface_done on.
    var start := -1
    for index in native_lines.size():
        if String(native_lines[index]).begins_with("STAGE name=surface_done "):
            start = index
            break
    for index in expected.size():
        var got: String = native_lines[start + index] if start >= 0 and start + index < native_lines.size() else "(none)"
        var ok := got == expected[index]
        _expect(ok, "world %d size %d: %s\n  native %s" % [seed_value, size_index, expected[index], got])
        if not ok:
            return
    print("NATIVE TEST: world %d size %d, %d steps match" % [seed_value, size_index, expected.size()])
