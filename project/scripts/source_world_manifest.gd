class_name SourceWorldManifest
extends RefCounted

# Canonical, renderer-independent fingerprint of a generated GenIsland1 world.
# This lets Java-oracle captures and Godot output be compared without relying on
# Dictionary/HashMap iteration order or screenshots.
static func build(result: Dictionary, spawn_seed: int) -> Dictionary:
    var tiles: Dictionary = result.get("tiles", {})
    var ocean: Array = result.get("ocean_tiles", [])
    if not ocean.is_empty():
        # A fresh world's ocean cells are ints (SourceIslandGenerator.ocean_tiles).
        tiles = tiles.duplicate()
        for key in tiles:
            if tiles[key] is int: tiles[key] = (ocean[tiles[key]] as SourceTile).copy_at(key)
    var surface_tiles := _sorted_tiles_by_position(tiles)
    var hash_context := HashingContext.new()
    hash_context.start(HashingContext.HASH_SHA256)
    var base_counts: Dictionary = {}
    var upper_counts: Dictionary = {}
    var route_counts: Dictionary = {}
    var biome_counts: Dictionary = {}
    var plain_sand_solid := 0
    var unresolved_render_tiles := 0
    var unresolved_render_counts: Dictionary = {}
    for raw_tile in surface_tiles:
        var tile := raw_tile as SourceTile
        if tile == null:
            continue
        var position := tile.position
        var route_name := ""
        var route_level := 0
        if tile.route_belongs_to != null:
            route_name = tile.route_belongs_to.name
            route_level = tile.route_belongs_to.level
        _increment(base_counts, tile.name)
        _increment(upper_counts, tile.name_upper)
        _increment(route_counts, route_name)
        _increment(biome_counts, tile.biome)
        if "sand" in tile.name and tile.name_upper.is_empty() and tile.is_solid:
            plain_sand_solid += 1
        if SourceWorldData.render_spec(tile, false).is_empty():
            unresolved_render_tiles += 1
            _increment(unresolved_render_counts, "base:" + tile.name)
        # Java uses the literal upper value "solid" as an invisible collision
        # marker. It is intentionally not a drawable source tile.
        if (not tile.name_upper.is_empty()
                and tile.name_upper != "solid"
                and SourceWorldData.render_spec(tile, true).is_empty()):
            unresolved_render_tiles += 1
            _increment(unresolved_render_counts, "upper:" + tile.name_upper)
        var record := "%d,%d|%s|%s|%s|%d|%s|%d|%d|%d\n" % [
            position.x, position.y, tile.name, tile.name_upper, route_name,
            route_level, tile.biome, int(tile.is_solid), int(tile.is_water),
            int(tile.is_ledge)
        ]
        hash_context.update(record.to_utf8_buffer())

    var interiors: Array = result.get("interiors", [])
    var interior_tile_count := 0
    var populated_interior_layers := 0
    for layer_index in range(interiors.size()):
        var raw_layer: Variant = interiors[layer_index]
        if not raw_layer is Dictionary or (raw_layer as Dictionary).is_empty():
            continue
        populated_interior_layers += 1
        var layer := raw_layer as Dictionary
        interior_tile_count += layer.size()
        hash_context.update(("LAYER:%d\n" % layer_index).to_utf8_buffer())
        for raw_tile in _sorted_tiles_by_position(layer):
            var tile := raw_tile as SourceTile
            if tile == null:
                continue
            # Java hashes Tile.position, not the HashMap key. This preserves the
            # original Mewtwo-room object-reuse quirk where two keys reference a
            # Tile whose stored position is the same.
            var position := tile.position
            hash_context.update(("%d,%d|%s|%s|%d\n" % [
                position.x, position.y, tile.name, tile.name_upper,
                int(tile.is_solid)
            ]).to_utf8_buffer())

    var adapter := SourceExactWorldAdapter.from_generator_result(
        result, SourceJavaRandom.new(spawn_seed)
    )
    return {
        "sha256": hash_context.finish().hex_encode(),
        "tile_count": tiles.size(),
        "bottom_left": _vector_array(result.get("bottom_left", Vector2i.ZERO)),
        "top_right": _vector_array(result.get("top_right", Vector2i.ZERO)),
        "edge_count": (result.get("edges", []) as Array).size(),
        "pokemon_count": (result.get("pokemon", {}) as Dictionary).size(),
        "interior_pokemon_count": (result.get("interior_pokemon", []) as Array).size(),
        "interior_tile_count": interior_tile_count,
        "populated_interior_layers": populated_interior_layers,
        "spawn_cell": _vector_array(adapter.spawn_cell),
        "spawn_reachable_dry": _reachable_dry_tiles(adapter, adapter.spawn_cell),
        "plain_sand_solid": plain_sand_solid,
        "unresolved_render_tiles": unresolved_render_tiles,
        "unresolved_render_counts": _sorted_dictionary(unresolved_render_counts),
        "base_counts": _sorted_dictionary(base_counts),
        "upper_counts": _sorted_dictionary(upper_counts),
        "route_counts": _sorted_dictionary(route_counts),
        "biome_counts": _sorted_dictionary(biome_counts)
    }

static func _increment(counts: Dictionary, key: String) -> void:
    counts[key] = int(counts.get(key, 0)) + 1

static func _sorted_tiles_by_position(layer: Dictionary) -> Array:
    var result := layer.values()
    result.sort_custom(func(a: SourceTile, b: SourceTile) -> bool:
        return (a.position.x < b.position.x
            or (a.position.x == b.position.x and a.position.y < b.position.y))
    )
    return result

static func _sorted_dictionary(source: Dictionary) -> Dictionary:
    var result: Dictionary = {}
    var keys := source.keys()
    keys.sort()
    for key in keys:
        result[key] = source[key]
    return result

static func _vector_array(value: Variant) -> Array[int]:
    var vector: Vector2i = value
    return [vector.x, vector.y]

static func _reachable_dry_tiles(
        adapter: SourceExactWorldAdapter, start: Vector2i
    ) -> int:
    var start_tile := adapter.tile_at(start)
    if start_tile == null or start_tile.is_solid or start_tile.is_water:
        return 0
    var queue: Array[Vector2i] = [start]
    var visited: Dictionary = {start: true}
    var head := 0
    while head < queue.size():
        var cell := queue[head]
        head += 1
        for raw_offset in [
                Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
            var next_cell: Vector2i = cell + Vector2i(raw_offset)
            if visited.has(next_cell):
                continue
            var tile := adapter.tile_at(next_cell)
            if tile == null or tile.is_solid or tile.is_water:
                continue
            visited[next_cell] = true
            queue.append(next_cell)
    return visited.size()
