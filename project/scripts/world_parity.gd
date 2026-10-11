extends RefCounted

# Source-backed names used by Route.java and GenIsland1 in PokeWilds 0.8.11.
const ROUTE_NAMES := {
    "FOREST": "forest1",
    "DEEP_FOREST": "deep_forest",
    "SAVANNA": "savanna1",
    "MOUNTAIN": "mountain1",
    "DESERT": "desert1",
    "SNOW": "snow1",
    "WOODED_LAKE": "wooded_lake1",
    "BEACH": "beach1"
}

static func build_biome_regions(
        map_w: int,
        map_h: int,
        biome_order: Array,
        rng: RandomNumberGenerator
    ) -> Array:
    var regions: Array = []
    var center := Vector2(float(map_w) * 0.5, float(map_h) * 0.5)
    var mountain_center := center + Vector2(
        rng.randf_range(-float(map_w) * 0.045, float(map_w) * 0.045),
        rng.randf_range(-float(map_h) * 0.045, float(map_h) * 0.045)
    )
    regions.append({
        "biome": "MOUNTAIN",
        "center": mountain_center,
        "weight": 0.62
    })

    var ring_biomes: Array = []
    for biome in biome_order:
        if String(biome) != "MOUNTAIN":
            ring_biomes.append(String(biome))
    var angle_offset := rng.randf_range(0.0, TAU)
    for index in range(ring_biomes.size()):
        var angle := (
            angle_offset
            + TAU * float(index) / float(maxi(1, ring_biomes.size()))
            + rng.randf_range(-0.16, 0.16)
        )
        var region_center := center + Vector2(
            cos(angle) * float(map_w) * rng.randf_range(0.25, 0.34),
            sin(angle) * float(map_h) * rng.randf_range(0.24, 0.33)
        )
        region_center.x = clampf(region_center.x, 6.0, float(map_w - 7))
        region_center.y = clampf(region_center.y, 6.0, float(map_h - 7))
        regions.append({
            "biome": String(ring_biomes[index]),
            "center": region_center,
            "weight": rng.randf_range(0.88, 1.12)
        })
    return regions

static func terrain_kind(
        x: int,
        y: int,
        map_w: int,
        map_h: int,
        terrain_noise: FastNoiseLite,
        detail_noise: FastNoiseLite
    ) -> int:
    if x < 1 or y < 1 or x >= map_w - 1 or y >= map_h - 1:
        return 0

    var half_w := maxf(1.0, float(map_w - 4) * 0.5)
    var half_h := maxf(1.0, float(map_h - 4) * 0.5)
    var nx := (float(x) - float(map_w - 1) * 0.5) / half_w
    var ny := (float(y) - float(map_h - 1) * 0.5) / half_h
    var radial := sqrt(nx * nx + ny * ny)
    var terrain_value := terrain_noise.get_noise_2d(float(x), float(y))
    var coast_value := 1.0 - radial + terrain_value * 0.20

    if coast_value < 0.015:
        return 0
    if coast_value < 0.105:
        return 1

    var lake_value := detail_noise.get_noise_2d(float(x), float(y))
    if radial < 0.76 and terrain_value < -0.70 and lake_value < -0.12:
        return 0
    if radial < 0.79 and terrain_value < -0.61 and lake_value < -0.05:
        return 1
    return 2

static func biome_kind(
        x: int,
        y: int,
        terrain_value: int,
        map_w: int,
        map_h: int,
        regions: Array,
        biome_noise: FastNoiseLite,
        detail_noise: FastNoiseLite
    ) -> String:
    if terrain_value == 0:
        return "OCEAN"
    if terrain_value == 1:
        return "BEACH"
    if regions.is_empty():
        return "FOREST"

    var sample := Vector2(float(x), float(y))
    sample.x += biome_noise.get_noise_2d(float(x), float(y)) * float(map_w) * 0.075
    sample.y += (
        biome_noise.get_noise_2d(float(x + 173), float(y - 91))
        * float(map_h) * 0.075
    )
    var chosen := "FOREST"
    var best_score := INF
    for region in regions:
        var region_center: Vector2 = region.get("center", sample)
        var dx := (sample.x - region_center.x) / maxf(1.0, float(map_w) * 0.30)
        var dy := (sample.y - region_center.y) / maxf(1.0, float(map_h) * 0.30)
        var weight := maxf(0.2, float(region.get("weight", 1.0)))
        var score := (dx * dx + dy * dy) / weight
        if score < best_score:
            best_score = score
            chosen = String(region.get("biome", "FOREST"))
    if (
            chosen == "FOREST"
            and detail_noise.get_noise_2d(float(x), float(y)) > 0.46
        ):
        return "DEEP_FOREST"
    return chosen

static func build_route_network(
        terrain: Array,
        biomes: Array,
        regions: Array,
        map_w: int,
        map_h: int,
        rng: RandomNumberGenerator
    ) -> Dictionary:
    var biome_centers := {}
    var route_cells := {}
    for region in regions:
        var biome := String(region.get("biome", "FOREST"))
        var center: Vector2 = region.get("center", Vector2.ZERO)
        var desired := Vector2i(roundi(center.x), roundi(center.y))
        var land_cell := _nearest_land_cell(
            desired, 12, terrain, map_w, map_h
        )
        if land_cell.x >= 0:
            biome_centers[biome] = land_cell

    var connected: Array = []
    var remaining: Array = []
    var cell_biomes := {}
    for raw_biome in biome_centers.keys():
        var biome := String(raw_biome)
        var cell: Vector2i = biome_centers[biome]
        cell_biomes[cell] = biome
        if biome == "MOUNTAIN":
            connected.append(cell)
        else:
            remaining.append(cell)
    if connected.is_empty() and not remaining.is_empty():
        connected.append(remaining.pop_front())

    while not remaining.is_empty():
        var best_from: Vector2i = connected[0]
        var best_to: Vector2i = remaining[0]
        var best_distance := INF
        for from_cell in connected:
            for to_cell in remaining:
                var distance := Vector2(to_cell - from_cell).length_squared()
                if distance < best_distance:
                    best_distance = distance
                    best_from = from_cell
                    best_to = to_cell
        var destination_biome := String(cell_biomes.get(best_to, "FOREST"))
        _carve_route(
            best_from,
            best_to,
            String(ROUTE_NAMES.get(destination_biome, "forest1")),
            destination_biome,
            terrain,
            biomes,
            route_cells,
            map_w,
            map_h,
            rng
        )
        connected.append(best_to)
        remaining.erase(best_to)
    return {
        "route_cells": route_cells,
        "biome_centers": biome_centers
    }

static func connect_cell_to_route(
        from_cell: Vector2i,
        biome: String,
        terrain: Array,
        biomes: Array,
        route_cells: Dictionary,
        map_w: int,
        map_h: int,
        rng: RandomNumberGenerator
    ) -> void:
    var nearest := nearest_route_cell(from_cell, route_cells)
    if nearest.x < 0:
        return
    _carve_route(
        from_cell,
        nearest,
        String(ROUTE_NAMES.get(biome, "forest1")),
        biome,
        terrain,
        biomes,
        route_cells,
        map_w,
        map_h,
        rng
    )

static func plan_landmarks(
        terrain: Array,
        biomes: Array,
        biome_centers: Dictionary,
        route_cells: Dictionary,
        spawn_cell: Vector2i,
        map_w: int,
        map_h: int,
        rng: RandomNumberGenerator
    ) -> Dictionary:
    var result := {}
    var house_center: Vector2i = biome_centers.get(
        "FOREST", biome_centers.get("WOODED_LAKE", spawn_cell)
    )
    var house_anchor := _find_footprint(
        house_center + Vector2i(3, 2),
        Vector2i(2, 2),
        14,
        terrain,
        route_cells,
        map_w,
        map_h
    )
    if house_anchor.x >= 0:
        var house_door := house_anchor + Vector2i(1, 1)
        result["house_anchor"] = house_anchor
        result["house_door"] = house_door
        connect_cell_to_route(
            house_door + Vector2i.DOWN,
            String(biomes[house_anchor.y][house_anchor.x]),
            terrain,
            biomes,
            route_cells,
            map_w,
            map_h,
            rng
        )

    var cave_center: Vector2i = biome_centers.get("MOUNTAIN", spawn_cell)
    var cave_cell := _find_footprint(
        cave_center + Vector2i(-3, 1),
        Vector2i(1, 1),
        12,
        terrain,
        route_cells,
        map_w,
        map_h
    )
    if cave_cell.x >= 0:
        result["cave_door"] = cave_cell
        connect_cell_to_route(
            cave_cell + Vector2i.DOWN,
            "MOUNTAIN",
            terrain,
            biomes,
            route_cells,
            map_w,
            map_h,
            rng
        )

    var route_sign := nearest_route_cell(spawn_cell + Vector2i(3, 0), route_cells)
    if route_sign.x >= 0:
        route_sign += Vector2i.RIGHT
        if (
                route_sign.x >= 2
                and route_sign.y >= 2
                and route_sign.x < map_w - 2
                and route_sign.y < map_h - 2
                and terrain[route_sign.y][route_sign.x] == 2
            ):
            result["route_sign"] = route_sign
    return result

static func nearest_route_cell(
        origin: Vector2i,
        route_cells: Dictionary
    ) -> Vector2i:
    var nearest := Vector2i(-1, -1)
    var nearest_distance := INF
    for raw_cell in route_cells.keys():
        var cell: Vector2i = raw_cell
        var distance := Vector2(cell - origin).length_squared()
        if distance < nearest_distance:
            nearest = cell
            nearest_distance = distance
    return nearest

static func _nearest_land_cell(
        origin: Vector2i,
        max_radius: int,
        terrain: Array,
        map_w: int,
        map_h: int
    ) -> Vector2i:
    for radius in range(max_radius + 1):
        for y in range(origin.y - radius, origin.y + radius + 1):
            for x in range(origin.x - radius, origin.x + radius + 1):
                if (
                        radius > 0
                        and abs(x - origin.x) != radius
                        and abs(y - origin.y) != radius
                    ):
                    continue
                if (
                        x >= 2
                        and y >= 2
                        and x < map_w - 2
                        and y < map_h - 2
                        and terrain[y][x] == 2
                    ):
                    return Vector2i(x, y)
    return Vector2i(-1, -1)

static func _find_footprint(
        desired: Vector2i,
        size: Vector2i,
        max_radius: int,
        terrain: Array,
        route_cells: Dictionary,
        map_w: int,
        map_h: int
    ) -> Vector2i:
    for radius in range(max_radius + 1):
        for y in range(desired.y - radius, desired.y + radius + 1):
            for x in range(desired.x - radius, desired.x + radius + 1):
                if (
                        radius > 0
                        and abs(x - desired.x) != radius
                        and abs(y - desired.y) != radius
                    ):
                    continue
                if (
                        x < 3
                        or y < 3
                        or x + size.x >= map_w - 3
                        or y + size.y >= map_h - 3
                    ):
                    continue
                var valid := true
                for yy in range(y, y + size.y):
                    for xx in range(x, x + size.x):
                        var cell := Vector2i(xx, yy)
                        if terrain[yy][xx] != 2 or route_cells.has(cell):
                            valid = false
                            break
                    if not valid:
                        break
                if valid:
                    return Vector2i(x, y)
    return Vector2i(-1, -1)

static func _carve_route(
        from_cell: Vector2i,
        to_cell: Vector2i,
        route_name: String,
        route_biome: String,
        terrain: Array,
        biomes: Array,
        route_cells: Dictionary,
        map_w: int,
        map_h: int,
        rng: RandomNumberGenerator
    ) -> void:
    var bend := Vector2i(to_cell.x, from_cell.y)
    if rng.randf() < 0.5:
        bend = Vector2i(from_cell.x, to_cell.y)
    _carve_segment(
        from_cell, bend, route_name, route_biome,
        terrain, biomes, route_cells, map_w, map_h
    )
    _carve_segment(
        bend, to_cell, route_name, route_biome,
        terrain, biomes, route_cells, map_w, map_h
    )

static func _carve_segment(
        from_cell: Vector2i,
        to_cell: Vector2i,
        route_name: String,
        route_biome: String,
        terrain: Array,
        biomes: Array,
        route_cells: Dictionary,
        map_w: int,
        map_h: int
    ) -> void:
    var current := from_cell
    _stamp_route(
        current, route_name, route_biome,
        terrain, biomes, route_cells, map_w, map_h
    )
    while current.x != to_cell.x:
        current.x += 1 if to_cell.x > current.x else -1
        _stamp_route(
            current, route_name, route_biome,
            terrain, biomes, route_cells, map_w, map_h
        )
    while current.y != to_cell.y:
        current.y += 1 if to_cell.y > current.y else -1
        _stamp_route(
            current, route_name, route_biome,
            terrain, biomes, route_cells, map_w, map_h
        )

static func _stamp_route(
        cell: Vector2i,
        route_name: String,
        route_biome: String,
        terrain: Array,
        biomes: Array,
        route_cells: Dictionary,
        map_w: int,
        map_h: int
    ) -> void:
    if (
            cell.x < 2
            or cell.y < 2
            or cell.x >= map_w - 2
            or cell.y >= map_h - 2
        ):
        return
    terrain[cell.y][cell.x] = 2
    if String(biomes[cell.y][cell.x]) in ["OCEAN", "BEACH"]:
        biomes[cell.y][cell.x] = route_biome
    route_cells[cell] = route_name
