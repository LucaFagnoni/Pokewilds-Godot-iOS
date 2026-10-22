class_name SourceWorldGenerator
extends RefCounted

const NativeWorldGen = preload("res://scripts/native_world_gen.gd")

const CARDINALS: Array[Vector2i] = [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]
const EIGHT_DIRECTIONS: Array[Vector2i] = [
    Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN,
    Vector2i(-1, -1), Vector2i(1, 1), Vector2i(1, -1), Vector2i(-1, 1)
]
# DrawSetupMenu 0.8.11 computes these as
# 100 * (100,100,100,90,80) * (sizeIndex + 2), for indices 1-5.
const SOURCE_RADIUS_PRESETS: Array[int] = [30000, 40000, 50000, 54000, 56000]

var _width := 0
var _height := 0
var _seed := 0
var _random: SourceJavaRandom
var _forest_random: SourceJavaRandom
var _tiles: Dictionary = {}
var _mountain_cells: Dictionary = {}
var _habitat_routes: Dictionary = {}
var _biome_centers: Dictionary = {}
var _landmarks: Dictionary = {}
var _reserved_rects: Array[Rect2i] = []
var _source_interiors: Array = []
var _source_interior_pokemon: Array = []

static func generate(width: int, height: int, seed_value: int, size_index: int) -> Dictionary:
    var generator := SourceWorldGenerator.new()
    return generator._generate(width, height, seed_value, size_index)

static func source_radius_for_size(size_index: int) -> int:
    return SOURCE_RADIUS_PRESETS[clampi(size_index, 0, SOURCE_RADIUS_PRESETS.size() - 1)]

static func generate_exact_source_world(
        seed_value: int,
        size_index: int,
        used_dungeons: Array[String] = []
    ) -> Dictionary:
    # The engine's native port when it has one: the same world, much faster.
    if NativeWorldGen.enabled():
        return NativeWorldGen.generate(seed_value, size_index, used_dungeons)
    return generate_validated(seed_value, size_index, used_dungeons)

# Retry only rejected fresh worlds. Attempt zero preserves the existing RNGs.
# The original save/cache seed stays stable; retries are deterministic.
static func generate_validated(seed_value: int, size_index: int,
        used_dungeons: Array[String] = [], factory: Callable = Callable()) -> Dictionary:
    var failures: Array = []
    for attempt in range(3):
        var attempt_seed := seed_value if attempt == 0 else ((seed_value ^ (attempt * 0x9E3779B9)) & SourceJavaRandom.MASK_48)
        var generator
        if factory.is_valid():
            generator = factory.call(attempt_seed, size_index, attempt)
        else:
            generator = SourceIslandGenerator.new(Vector2i.ZERO, source_radius_for_size(size_index),
                SourceJavaRandom.new(attempt_seed ^ 0x50C3E811), SourceJavaRandom.new(attempt_seed),
                SourceJavaRandom.new(attempt_seed ^ 0x6F72657374), SourceJavaRandom.new(attempt_seed ^ 0x506F6B656D6F6E))
        var result: Dictionary = generator.generate_complete(used_dungeons)
        var started := Time.get_ticks_msec()
        var report: Dictionary = preload("res://scripts/source_generation_validator.gd").validate(generator)
        report["elapsed_ms"] = Time.get_ticks_msec()-started
        report["attempt"] = attempt
        report["attempt_seed"] = attempt_seed
        if report.ok:
            result["generation_validation"] = report
            if not failures.is_empty(): _log_generation_validation(seed_value,size_index,failures,report)
            return result
        failures.append(report)
        # Release rejected terrain before allocating the next attempt.
        result.clear()
        generator = null
    _log_generation_validation(seed_value,size_index,failures,{})
    return {"generation_error":"World validation failed after 3 attempts. Please try another world.",
        "generation_failures":failures}

static func _log_generation_validation(seed_value: int, size_index: int, failures: Array, accepted: Dictionary) -> void:
    var path := "user://world-generation-validation.jsonl"
    var log_file := FileAccess.open(path, FileAccess.READ_WRITE if FileAccess.file_exists(path) else FileAccess.WRITE)
    if log_file != null:
        log_file.seek_end()
        log_file.store_line(JSON.stringify({"seed":seed_value,"size":size_index,"failures":failures,"accepted":accepted}))

func _generate(width: int, height: int, seed_value: int, _size_index: int) -> Dictionary:
    _width = width
    _height = height
    _seed = seed_value
    _random = SourceJavaRandom.new(seed_value ^ 0x50C3E811)
    # ApplyForestBiome constructs its own java.util.Random in 0.8.11. Keep it
    # independent from GenIsland1 while deriving a reproducible test stream.
    _forest_random = SourceJavaRandom.new(seed_value ^ 0x6F72657374)
    _tiles.clear()
    _mountain_cells.clear()
    _habitat_routes.clear()
    _biome_centers.clear()
    _landmarks.clear()
    _reserved_rects.clear()
    _source_interiors.clear()
    _source_interior_pokemon.clear()

    var center := Vector2i(int(_width / 2), int(_height / 2))
    var endpoints := _apply_mountain_spine(center)
    if endpoints.size() < 2:
        endpoints = [Vector2i(_width / 4, _height / 2), Vector2i(_width * 3 / 4, _height / 2)]
    var forest_center: Vector2i = _clamp_cell(endpoints[0])
    var desert_center: Vector2i = _clamp_cell(endpoints[1])
    var surface_radius := maxi(13, int(round(float(mini(_width, _height)) * 0.42)))

    # GenIsland1 grows one forest island and one desert lobe from the mountain
    # endpoints.  ApplyBlotch's source probability test is preserved here.
    _apply_blotch("island", forest_center, surface_radius, "forest1", 40)
    _apply_exact_forest_maze()
    _apply_blotch("desert", desert_center, maxi(11, int(surface_radius * 0.92)), "desert1", 40)

    # Overlay mountain cells after the two surface blotches, matching the
    # constructor's mountain dither order.
    _overlay_mountains(center)

    var deep_forest_center := _nearest_biome_cell(
        forest_center + Vector2i(-surface_radius / 4, -surface_radius / 5),
        ["DEEP_FOREST", "FOREST"]
    )
    _apply_blotch("graveyard1", deep_forest_center, maxi(4, surface_radius / 7), "graveyard1", 22)

    var savanna_center := _nearest_biome_cell(
        forest_center + Vector2i(surface_radius / 3, surface_radius / 5),
        ["FOREST", "DEEP_FOREST"]
    )
    _apply_blotch("savanna1", savanna_center, maxi(5, surface_radius / 5), "savanna2", 22)

    var lake_center := _nearest_biome_cell(
        forest_center + Vector2i(surface_radius / 5, -surface_radius / 3),
        ["FOREST", "DEEP_FOREST"]
    )
    _apply_blotch("wooded_lake1", lake_center, maxi(6, surface_radius / 5), "wooded_lake1", 30)
    _apply_blotch("pond1", lake_center, maxi(2, surface_radius / 11), "wooded_lake_water1", 30)

    _apply_source_river_formula()
    _coastify()
    _record_biome_centers()
    _plan_source_landmarks()
    _generate_source_landmark_interiors()
    return _build_result()

# Until the unbounded surface renderer replaces this bounded compatibility
# world, build its landmarks with the real GenIsland1 routines. This removes
# the formerly fabricated cave floors and placeholder rooms while keeping the
# UI-facing world dimensions stable.
func _generate_source_landmark_interiors() -> void:
    var island_random := SourceJavaRandom.new(_seed ^ 0x50C3E811)
    var game_random := SourceJavaRandom.new(_seed)
    var generator := SourceIslandGenerator.new(
        Vector2i(_width * 8, _height * 8),
        mini(_width, _height) * 8,
        island_random,
        game_random,
        SourceJavaRandom.new(_seed ^ 0x6F72657374),
        SourceJavaRandom.new(_seed ^ 0x506F6B656D6F6E)
    )
    var ruins: Dictionary = _landmarks.get("desert_ruins", {})
    if not ruins.is_empty():
        var ruins_position := Vector2i(ruins.get("entry", Vector2i.ZERO)) * 16
        generator.tiles_to_add[ruins_position] = SourceTile.new(
            "desert4", ruins_position, "", true, SourceRoute.new("desert1", 40)
        )
        generator.generate_desert_ruins(ruins_position)
    var fossil: Dictionary = _landmarks.get("fossil_lab", {})
    if not fossil.is_empty():
        var oasis_position := Vector2i(fossil.get("entry", Vector2i.ZERO)) * 16
        generator.tiles_to_add[oasis_position] = SourceTile.new(
            "desert4", oasis_position, "", true, SourceRoute.new("desert1", 40)
        )
        generator.generate_oasis(oasis_position)
    var mansion: Dictionary = _landmarks.get("pokemon_mansion", {})
    if not mansion.is_empty():
        var anchor := Vector2i(mansion.get("anchor", Vector2i.ZERO))
        var footprint := Vector2i(mansion.get("size", Vector2i(31, 29)))
        generator.generate_mansion((anchor + footprint / 2) * 16)
    var regi: Dictionary = _landmarks.get("regi_dungeon", {})
    if not regi.is_empty():
        generator.generate_regi_dungeon(
            Vector2i(regi.get("entry", Vector2i.ZERO)) * 16
        )

    # These routines generate the exterior tile layouts as well as their
    # interiors.  Earlier M44 builds discarded the exteriors and rebuilt each
    # landmark as a filled rectangle in world.gd.  That caused animation sheets
    # such as cave1_regi1.png and house7_all.png to be stamped once per cell,
    # producing the duplicated buildings and rows of Regi sprites.  Preserve
    # the source-generated exterior tiles instead.
    for raw_tile in generator.tiles_to_add.values():
        var tile := raw_tile as SourceTile
        if tile == null:
            continue
        var cell := SourceWorldData.pixel_to_cell(tile.position)
        if not _inside(cell, 0):
            continue
        var converted := tile.to_world_dictionary()
        if converted.is_empty():
            continue
        _tiles[cell] = converted
        _habitat_routes[cell] = String(converted.get("route", ""))
        _capture_generated_landmark_entry(tile, cell)

    _source_interiors = generator.interior_tiles_to_add
    _source_interior_pokemon = generator.interior_pokemon

func _capture_generated_landmark_entry(tile: SourceTile, cell: Vector2i) -> void:
    var base_name := tile.name.to_lower()
    var upper_name := tile.name_upper.to_lower()
    var route_name := ""
    if tile.route_belongs_to != null:
        route_name = tile.route_belongs_to.name.to_lower()
    if base_name == "cave1_door1" or upper_name == "cave1_door1":
        _set_landmark_entry_if_nearer("regi_dungeon", cell)
    elif (
            base_name == "pkmnmansion_ext_door"
            or upper_name == "pkmnmansion_ext_door"
        ):
        if route_name == "oasis1":
            _set_landmark_entry_if_nearer("fossil_lab", cell)
        else:
            _set_landmark_entry_if_nearer("pokemon_mansion", cell)

func _set_landmark_entry_if_nearer(landmark_name: String, cell: Vector2i) -> void:
    if not _landmarks.has(landmark_name):
        return
    var descriptor: Dictionary = _landmarks[landmark_name]
    var original: Vector2i = descriptor.get(
        "_planned_entry", descriptor.get("entry", cell)
    )
    descriptor["_planned_entry"] = original
    var captured_key := "_captured_entry"
    if (
            not descriptor.has(captured_key)
            or cell.distance_squared_to(original)
                < Vector2i(descriptor[captured_key]).distance_squared_to(original)
        ):
        descriptor[captured_key] = cell
        descriptor["entry"] = cell
        _landmarks[landmark_name] = descriptor

func _apply_exact_forest_maze() -> void:
    var forest_positions: Dictionary = {}
    var bottom_left: Vector2i
    var top_right: Vector2i
    var found := false
    for raw_cell in _tiles.keys():
        var cell: Vector2i = raw_cell
        var tile_data: Dictionary = _tiles[cell]
        var route_name := String(tile_data.get("route", ""))
        if route_name not in ["forest1", "deep_forest"]:
            continue
        var pixel_position := cell * 16
        forest_positions[pixel_position] = true
        if not found:
            bottom_left = pixel_position
            top_right = pixel_position
            found = true
        else:
            bottom_left.x = mini(bottom_left.x, pixel_position.x)
            bottom_left.y = mini(bottom_left.y, pixel_position.y)
            top_right.x = maxi(top_right.x, pixel_position.x)
            top_right.y = maxi(top_right.y, pixel_position.y)
    if not found:
        return
    top_right.x -= posmod(top_right.x, 96)
    bottom_left.x -= posmod(bottom_left.x, 96)
    top_right.y += 96 - posmod(top_right.y, 96)
    bottom_left.y += 96 - posmod(bottom_left.y, 96)
    var width := int((top_right.x - bottom_left.x) * 2 / 96)
    var height := int((top_right.y - bottom_left.y) * 2 / 96)
    if width <= 0 or height <= 0:
        return
    var nodes := SourceMaze.maze_algo1(width, height, 0.1, 0.9, 96, _random)
    var forest_tiles: Dictionary = {}
    for node: Dictionary in nodes.values():
        var tile_square := SourceForestGenerator.get_tile_square(node, bottom_left, _random, true)
        for tile: SourceTile in tile_square:
            if forest_positions.has(tile.position):
                forest_tiles[tile.position] = tile
    if forest_tiles.is_empty():
        return
    SourceForestGenerator.apply_forest_biome(
        forest_tiles, bottom_left, top_right, _forest_random, true
    )
    for pixel_position: Vector2i in forest_tiles:
        var cell := SourceWorldData.pixel_to_cell(pixel_position)
        if not _tiles.has(cell):
            continue
        var source_tile := forest_tiles[pixel_position] as SourceTile
        var old_data: Dictionary = _tiles[cell]
        if source_tile.route_belongs_to == null:
            source_tile.route_belongs_to = SourceRoute.new(
                String(old_data.get("route", "")), int(old_data.get("level", 0))
            )
        source_tile.biome = String(old_data.get("biome", ""))
        _tiles[cell] = source_tile.to_world_dictionary()

func _apply_mountain_spine(origin: Vector2i) -> Array[Vector2i]:
    var raw_direction := Vector2(
        float(_random.next_int(200) - 100),
        float(_random.next_int(200) - 100)
    )
    if raw_direction.length_squared() < 1.0:
        raw_direction = Vector2.RIGHT
    raw_direction = raw_direction.normalized()
    var walkers: Array = [
        {"position": origin, "direction": raw_direction, "distance": int(mini(_width, _height) * 0.48)},
        {"position": origin, "direction": -raw_direction, "distance": int(mini(_width, _height) * 0.48)},
        {"position": origin, "direction": raw_direction.rotated(PI * 0.5), "distance": int(mini(_width, _height) * 0.24)},
        {"position": origin, "direction": raw_direction.rotated(-PI * 0.5), "distance": int(mini(_width, _height) * 0.24)}
    ]
    var endpoints: Array[Vector2i] = []
    var frontier: Array = walkers.duplicate(true)
    var guard := 0
    while not frontier.is_empty() and guard < _width * _height * 2:
        guard += 1
        var walker: Dictionary = frontier.pop_front()
        var position: Vector2i = walker["position"]
        var direction: Vector2 = walker["direction"]
        var remaining: int = walker["distance"]
        if remaining <= 0 or not _inside(position, 3):
            endpoints.append(_clamp_cell(position))
            continue
        _mountain_cells[position] = 0
        var x_weight := absi(roundi(direction.x * 100.0))
        var y_weight := absi(roundi(direction.y * 100.0))
        var roll := _random.next_int(maxi(1, x_weight + y_weight))
        var step := Vector2i.ZERO
        if roll < y_weight:
            step.y = -1 if direction.y < 0.0 else 1
        else:
            step.x = -1 if direction.x < 0.0 else 1
        var next_position := position + step
        frontier.append({"position": next_position, "direction": direction, "distance": remaining - 1})
        var branch_rate := maxi(18, int(float(mini(_width, _height)) * 0.65))
        if remaining > 5 and _random.next_int(branch_rate) == 1:
            var degrees := deg_to_rad(float(_random.next_int(80) + 10))
            var branch_length := maxi(2, int(remaining / 8))
            frontier.append({"position": position, "direction": direction.rotated(degrees), "distance": branch_length})
            frontier.append({"position": position, "direction": direction.rotated(-degrees), "distance": branch_length})
    endpoints.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
        return Vector2(a - origin).length_squared() > Vector2(b - origin).length_squared()
    )
    if endpoints.size() > 2:
        endpoints.resize(2)
    return endpoints

func _overlay_mountains(origin: Vector2i) -> void:
    var expanded := _mountain_cells.duplicate()
    var layers := clampi(int(round(float(mini(_width, _height)) / 16.0)), 3, 7)
    for layer in range(layers):
        var next := expanded.duplicate()
        for raw_cell in expanded.keys():
            var cell: Vector2i = raw_cell
            for direction in EIGHT_DIRECTIONS:
                var neighbour := cell + direction
                if _inside(neighbour, 1) and not next.has(neighbour):
                    next[neighbour] = -(layer + 1)
        expanded = next
    _mountain_cells = expanded
    var max_distance := maxf(1.0, float(layers))
    for raw_cell in _mountain_cells.keys():
        var cell: Vector2i = raw_cell
        var layer: int = absi(int(_mountain_cells[cell]))
        var base := "mountain3" if layer >= layers - 1 else "mountain1"
        var biome := "MOUNTAIN"
        var route := "mountain1"
        var level := clampi(10 + int(Vector2(cell - origin).length() * 0.35), 10, 33)
        if Vector2(cell - origin).length() <= max_distance + 1.0:
            base = "volcano1"
            biome = "VOLCANO"
            route = "volcano1"
            level = 22
        elif layer == 0 or (layer == 1 and (cell.x + cell.y) % 3 != 0):
            base = "snow1"
            biome = "SNOW"
            route = "snow1"
            level = 44
        _put_tile(cell, SourceWorldData.make_tile(base, "", route, level, biome), true)

func _apply_blotch(
        blotch_type: String,
        origin: Vector2i,
        radius_cells: int,
        route_name: String,
        level: int
    ) -> void:
    if not _inside(origin, 1):
        return
    var max_distance := maxi(16, radius_cells * 16)
    var frontier: Dictionary = {origin: true}
    var visited: Dictionary = {}
    while not frontier.is_empty():
        var next_frontier := {}
        for raw_cell in frontier.keys():
            var cell: Vector2i = raw_cell
            if visited.has(cell):
                continue
            visited[cell] = true
            _write_blotch_tile(blotch_type, cell, origin, radius_cells, route_name, level)
            for direction in CARDINALS:
                var neighbour := cell + direction
                if not _inside(neighbour, 1) or visited.has(neighbour):
                    continue
                var distance_pixels := int(round(Vector2(neighbour - origin).length() * 16.0))
                var put_tile := _random.next_int(max_distance) + distance_pixels
                var forced_ratio := 7
                match blotch_type:
                    "desert", "sand_pit1", "graveyard1", "volcano1", "volcano1_lava":
                        forced_ratio = 10
                    "beach1", "wooded_lake1":
                        forced_ratio = 12
                    "island":
                        forced_ratio = 8
                var should_put := distance_pixels < forced_ratio * max_distance / 16
                if put_tile < max_distance or should_put:
                    next_frontier[neighbour] = true
        frontier = next_frontier

func _write_blotch_tile(
        blotch_type: String,
        cell: Vector2i,
        origin: Vector2i,
        radius_cells: int,
        route_name: String,
        level: int
    ) -> void:
    var distance := Vector2(cell - origin).length()
    var ratio := distance / maxf(1.0, float(radius_cells))
    var base := "green1"
    var upper := ""
    var route := route_name
    var biome := "FOREST"
    match blotch_type:
        "island":
            if ratio > 0.76:
                base = "sand1"
                biome = "BEACH"
                route = "beach1"
                if _random.next_int(36) == 0:
                    base = "rock1"
            elif ratio < 0.34:
                base = "grass4" if _random.next_int(7) == 0 else "green1"
                biome = "DEEP_FOREST"
                route = "deep_forest"
                if _random.next_int(5) == 0:
                    upper = "tree_large1"
            elif ratio > 0.58:
                biome = "SAVANNA"
                route = "savanna1"
                base = "green_savanna4"
                if _random.next_int(16) == 0:
                    upper = "tree_savanna1"
            else:
                biome = "FOREST"
                route = "forest1"
                if _random.next_int(24) == 0:
                    base = "flower4"
                elif _random.next_int(10) == 0:
                    upper = "tree2"
        "desert":
            base = "desert4"
            biome = "DESERT"
            route = "desert1"
            if _random.next_int(maxi(12, radius_cells * 3)) == 0:
                upper = ["cactus1", "cactus2", "cactus10", "desert4_cracked"][_random.next_int(4)]
        "savanna1":
            base = "green_savanna4"
            biome = "SAVANNA"
            if _random.next_int(14) == 0:
                upper = "tree_savanna1"
            elif _random.next_int(20) == 0:
                upper = "bush_savanna1"
        "graveyard1":
            base = "flower5" if _random.next_int(7) == 0 else "green12"
            biome = "GRAVEYARD"
            if _random.next_int(13) == 0:
                upper = "gravestone2"
            elif _random.next_int(35) == 0:
                upper = ["pokedoll1", "pokedoll1_mimikyu", "pokedoll1_banette"][_random.next_int(3)]
        "wooded_lake1":
            base = "green5"
            biome = "WOODED_LAKE"
            if _random.next_int(11) == 0:
                upper = "tree2"
            elif _random.next_int(13) == 0:
                base = "grass2"
        "pond1":
            base = "water2"
            biome = "WOODED_LAKE"
            route = "wooded_lake_water1"
        "oasis1":
            base = "green1"
            biome = "OASIS"
            route = "oasis1"
            if _random.next_int(15) == 0:
                upper = "aloe_large1"
        "sand_pit1":
            base = "desert2"
            biome = "DESERT"
            route = "sand_pit1"
        "volcano1":
            base = "volcano1"
            biome = "VOLCANO"
            route = "volcano1"
        "volcano1_lava":
            base = "lava1_"
            biome = "VOLCANO"
            route = "volcano1"
    _put_tile(cell, SourceWorldData.make_tile(base, upper, route, level, biome), false)

func _apply_source_river_formula() -> void:
    var replacements: Array[Vector2i] = []
    for raw_cell in _tiles.keys():
        var cell: Vector2i = raw_cell
        var tile: Dictionary = _tiles[cell]
        var biome := String(tile.get("biome", ""))
        if biome in ["DESERT", "VOLCANO", "GRAVEYARD"] or bool(tile.get("water", false)):
            continue
        var pixel := Vector2(float(cell.x * 16), float(cell.y * 16))
        var angle := -atan2(pixel.x, pixel.y)
        var rotated := pixel.rotated(angle)
        var wave_offset := sin(rotated.x / 240.0) * 4.0
        var first := absf(float(posmod(int(rotated.y / 60.0 - wave_offset), 14) - 7)) * 2.0
        var second := absf(float(posmod(int(rotated.y / 60.0 - wave_offset), 20) - 10)) * 2.0
        if first * 5.0 * second > 850.0:
            replacements.append(cell)
    for cell in replacements:
        _put_tile(cell, SourceWorldData.make_tile("water2", "", "wooded_lake_water1", 30, "RIVER"), true)

func _coastify() -> void:
    var beach_cells: Array[Vector2i] = []
    for raw_cell in _tiles.keys():
        var cell: Vector2i = raw_cell
        var tile: Dictionary = _tiles[cell]
        if bool(tile.get("water", false)) or String(tile.get("biome", "")) in ["DESERT", "VOLCANO", "SNOW", "MOUNTAIN"]:
            continue
        for direction in EIGHT_DIRECTIONS:
            var neighbour := cell + direction
            if not _tiles.has(neighbour) or bool(_tiles[neighbour].get("water", false)):
                beach_cells.append(cell)
                break
    for cell in beach_cells:
        var existing: Dictionary = _tiles[cell]
        existing["base"] = "sand3"
        existing["upper"] = ""
        existing["biome"] = "BEACH"
        existing["route"] = "beach2"
        existing["solid"] = false
        existing["water"] = false
        _tiles[cell] = existing
        _habitat_routes[cell] = "beach2"

func _record_biome_centers() -> void:
    var sums := {}
    for raw_cell in _tiles.keys():
        var cell: Vector2i = raw_cell
        var biome := String(_tiles[cell].get("biome", "FOREST"))
        if biome in ["RIVER", "OCEAN"]:
            continue
        if not sums.has(biome):
            sums[biome] = {"sum": Vector2.ZERO, "count": 0}
        sums[biome]["sum"] += Vector2(cell)
        sums[biome]["count"] += 1
    for biome in sums.keys():
        var entry: Dictionary = sums[biome]
        var average: Vector2 = entry["sum"] / maxf(1.0, float(entry["count"]))
        _biome_centers[biome] = _nearest_biome_cell(Vector2i(roundi(average.x), roundi(average.y)), [String(biome)])

func _plan_source_landmarks() -> void:
    var desert_center: Vector2i = _biome_centers.get("DESERT", Vector2i(_width * 3 / 4, _height / 2))
    var forest_center: Vector2i = _biome_centers.get("DEEP_FOREST", Vector2i(_width / 4, _height / 2))
    var grave_center: Vector2i = _biome_centers.get("GRAVEYARD", forest_center)
    var ruins_anchor := _reserve_near(desert_center, Vector2i(11, 11), ["DESERT"])
    _landmarks["desert_ruins"] = {"anchor": ruins_anchor, "entry": ruins_anchor + Vector2i(5, 10), "area": "RUINS_0", "size": Vector2i(11, 11)}
    _stamp_landmark_ground(ruins_anchor, Vector2i(11, 11), "desert4", "desert_ruins1", 35, "DESERT")

    var oasis_center := _nearest_biome_cell(desert_center + Vector2i(0, maxi(7, _height / 5)), ["DESERT"])
    _apply_blotch("oasis1", oasis_center, maxi(5, mini(_width, _height) / 13), "oasis1", 30)
    _apply_blotch("pond1", oasis_center, maxi(2, mini(_width, _height) / 28), "oasis_pond1", 30)
    var fossil_anchor := _reserve_near(oasis_center + Vector2i(5, 0), Vector2i(6, 5), ["OASIS", "DESERT"])
    _landmarks["fossil_lab"] = {"anchor": fossil_anchor, "entry": fossil_anchor + Vector2i(2, 4), "area": "FOSSIL_LAB", "size": Vector2i(6, 5)}
    _stamp_landmark_ground(fossil_anchor, Vector2i(6, 5), "green1", "oasis1", 30, "OASIS")

    var mansion_anchor := _reserve_near(forest_center, Vector2i(31, 29), ["DEEP_FOREST", "FOREST"])
    _landmarks["pokemon_mansion"] = {"anchor": mansion_anchor, "entry": mansion_anchor + Vector2i(15, 28), "area": "MANSION_0", "size": Vector2i(31, 29)}
    _stamp_landmark_ground(mansion_anchor, Vector2i(31, 29), "green1", "deep_forest", 40, "DEEP_FOREST")

    var regi_anchor := _reserve_near(grave_center + Vector2i(8, 0), Vector2i(13, 10), ["GRAVEYARD", "DEEP_FOREST", "FOREST"])
    _landmarks["regi_dungeon"] = {"anchor": regi_anchor, "entry": regi_anchor + Vector2i(6, 9), "area": "REGI_CHAMBER", "size": Vector2i(13, 10)}
    _stamp_landmark_ground(regi_anchor, Vector2i(13, 10), "green12", "graveyard1", 22, "GRAVEYARD")
    _landmarks["mansion_key"] = {"cell": _nearest_biome_cell(forest_center + Vector2i(-5, 4), ["DEEP_FOREST", "FOREST"])}

func _stamp_landmark_ground(
        anchor: Vector2i,
        footprint: Vector2i,
        base_name: String,
        route_name: String,
        level: int,
        biome_name: String
    ) -> void:
    for y in range(anchor.y, anchor.y + footprint.y):
        for x in range(anchor.x, anchor.x + footprint.x):
            var cell := Vector2i(x, y)
            if _inside(cell, 0):
                _put_tile(
                    cell,
                    SourceWorldData.make_tile(
                        base_name, "", route_name, level, biome_name
                    ),
                    true
                )

func _reserve_near(desired: Vector2i, footprint: Vector2i, allowed_biomes: Array[String]) -> Vector2i:
    var half := Vector2i(int(footprint.x / 2), int(footprint.y / 2))
    for radius in range(maxi(_width, _height)):
        for y in range(desired.y - radius, desired.y + radius + 1):
            for x in range(desired.x - radius, desired.x + radius + 1):
                if radius > 0 and absi(x - desired.x) != radius and absi(y - desired.y) != radius:
                    continue
                var top_left := Vector2i(x, y) - half
                var rect := Rect2i(top_left, footprint)
                if rect.position.x < 1 or rect.position.y < 1 or rect.end.x >= _width - 1 or rect.end.y >= _height - 1:
                    continue
                var overlaps := false
                for other in _reserved_rects:
                    if rect.intersects(other.grow(2)):
                        overlaps = true
                        break
                if overlaps:
                    continue
                var center_cell := top_left + half
                var biome := String(_tiles.get(center_cell, {}).get("biome", ""))
                if not allowed_biomes.is_empty() and biome not in allowed_biomes:
                    continue
                _reserved_rects.append(rect)
                return top_left
    var fallback := Vector2i(
        clampi(desired.x - half.x, 1, maxi(1, _width - footprint.x - 2)),
        clampi(desired.y - half.y, 1, maxi(1, _height - footprint.y - 2))
    )
    _reserved_rects.append(Rect2i(fallback, footprint))
    return fallback

func _build_result() -> Dictionary:
    var terrain: Array = []
    var biomes: Array = []
    for y in range(_height):
        var terrain_row: Array[int] = []
        var biome_row: Array[String] = []
        for x in range(_width):
            var cell := Vector2i(x, y)
            if not _tiles.has(cell):
                terrain_row.append(0)
                biome_row.append("OCEAN")
                continue
            var tile: Dictionary = _tiles[cell]
            if bool(tile.get("water", false)):
                terrain_row.append(0)
            elif String(tile.get("biome", "")) in ["BEACH", "DESERT"] or "sand" in String(tile.get("base", "")) or "desert" in String(tile.get("base", "")):
                terrain_row.append(1)
            else:
                terrain_row.append(2)
            biome_row.append(String(tile.get("biome", "FOREST")))
        terrain.append(terrain_row)
        biomes.append(biome_row)
    return {
        "terrain": terrain,
        "biomes": biomes,
        "source_tiles": _tiles.duplicate(true),
        "habitat_routes": _habitat_routes.duplicate(true),
        "route_cells": {},
        "biome_centers": _biome_centers.duplicate(true),
        "landmarks": _landmarks.duplicate(true),
        "source_interiors": _source_interiors,
        "source_interior_pokemon": _source_interior_pokemon,
        "source_algorithm": "GenIsland1/GenForest2 0.8.11 bounded Godot port"
    }

func _put_tile(cell: Vector2i, tile: Dictionary, overwrite: bool) -> void:
    if not _inside(cell, 0):
        return
    if _tiles.has(cell) and not overwrite:
        return
    _tiles[cell] = tile
    _habitat_routes[cell] = String(tile.get("route", ""))

func _nearest_biome_cell(origin: Vector2i, allowed: Array[String]) -> Vector2i:
    for radius in range(maxi(_width, _height)):
        for y in range(origin.y - radius, origin.y + radius + 1):
            for x in range(origin.x - radius, origin.x + radius + 1):
                if radius > 0 and absi(x - origin.x) != radius and absi(y - origin.y) != radius:
                    continue
                var cell := Vector2i(x, y)
                if not _inside(cell, 1) or not _tiles.has(cell):
                    continue
                if String(_tiles[cell].get("biome", "")) in allowed:
                    return cell
    return _clamp_cell(origin)

func _inside(cell: Vector2i, margin: int) -> bool:
    return cell.x >= margin and cell.y >= margin and cell.x < _width - margin and cell.y < _height - margin

func _clamp_cell(cell: Vector2i) -> Vector2i:
    return Vector2i(clampi(cell.x, 2, _width - 3), clampi(cell.y, 2, _height - 3))
