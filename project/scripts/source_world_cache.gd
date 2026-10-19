class_name SourceWorldCache
extends RefCounted

const SourceTileScript = preload("res://scripts/source_tile.gd")
const SourceRouteScript = preload("res://scripts/source_route.gd")

const DataPaths = preload("res://scripts/game_data_paths.gd")
const CACHE_MAGIC := "POKEWILDS_EXACT_WORLD"
# Bump only because M74.3.9.4 changes authored cemetery perimeter tiles.
# Existing v1 exact-world caches predate that generator repair and would otherwise
# keep the missing fence variants forever. The same seed/size is regenerated once
# and then saved as v2; save-state mutations are reapplied normally afterward.
const CACHE_VERSION := 2
## v3 stores the overworld as a WorldTileStore, already repaired by the
## adapter, so loading needs no tile objects and no repairs. v2 files are
## still read once (repaired the old way) and rewritten as v3.
const PACKED_VERSION := 3
const TILE_CHUNK_SIZE := 4096
const MAX_TILE_COUNT := 12000000
const MAX_INTERIOR_LAYERS := 102
static var online_namespace:=""

static func cache_directory()->String:
    if online_namespace.is_empty():return DataPaths.path("world_cache")
    return DataPaths.path("online_worlds").path_join(online_namespace).path_join("world_cache")

static func cache_path(seed_value: int, size_index: int, version: int = PACKED_VERSION) -> String:
    return "%s/exact_v%d_%d_%d.bin" % [
        cache_directory(), version, abs(seed_value), size_index
    ]

static func has_cache(seed_value: int, size_index: int) -> bool:
    return FileAccess.file_exists(cache_path(seed_value, size_index)) or \
        FileAccess.file_exists(cache_path(seed_value, size_index, CACHE_VERSION))

## Writes the adapted world: the packed overworld, the raw interior layers
## and everything else the adapter produced. Runs on a worker thread.
static func save_world(seed_value: int, size_index: int, world: SourceExactWorldAdapter, result: Dictionary) -> bool:
    var store := world.tiles as WorldTileStore
    if store == null or store.is_empty():
        return false
    var absolute_directory := ProjectSettings.globalize_path(cache_directory())
    if DirAccess.make_dir_recursive_absolute(absolute_directory) != OK:
        return false
    var path := cache_path(seed_value, size_index)
    var file := FileAccess.open_compressed(path + ".pending", FileAccess.WRITE, FileAccess.COMPRESSION_ZSTD)
    if file == null:
        return false
    # One route table for the overworld and the interiors, which share route
    # objects. The store's routes come first, so its route ids stay valid.
    var route_index: Dictionary = {}
    var routes: Array = []
    for route in store.routes:
        route_index[(route as SourceRoute).get_instance_id()] = routes.size()
        routes.append(route)
    var interiors: Array = result.get("interiors", []) as Array
    for raw_layer in interiors:
        if raw_layer is Dictionary:
            _collect_routes(raw_layer as Dictionary, route_index, routes)
    file.store_pascal_string(CACHE_MAGIC)
    file.store_32(PACKED_VERSION)
    file.store_64(abs(seed_value))
    file.store_32(size_index)
    file.store_var(_pack_routes(routes), false)
    file.store_var(store.to_record(), false)
    var populated_layers: Array[int] = []
    for layer_index in range(interiors.size()):
        if interiors[layer_index] is Dictionary and not (interiors[layer_index] as Dictionary).is_empty():
            populated_layers.append(layer_index)
    file.store_32(populated_layers.size())
    for layer_index in populated_layers:
        file.store_32(layer_index)
        _write_tile_layer(file, interiors[layer_index] as Dictionary, route_index)
    file.store_var(world.pokemon, false)
    file.store_var(world.burrowed_pokemon, false)
    file.store_var(result.get("interior_pokemon", []), false)
    file.store_var(_pack_edges(world.edges), false)
    file.store_var(Vector2i(result.get("bottom_left", Vector2i.ZERO)), false)
    file.store_var(Vector2i(result.get("top_right", Vector2i.ZERO)), false)
    file.store_var(world.used_dungeons, false)
    file.store_var(world.regi_relocated_cells, false)
    var error := file.get_error()
    file.close()
    if error != OK or DirAccess.rename_absolute(path + ".pending", path) != OK:
        return false
    var legacy := cache_path(seed_value, size_index, CACHE_VERSION)
    if FileAccess.file_exists(legacy): DirAccess.remove_absolute(legacy)
    return true

static func _load_packed(seed_value: int, size_index: int) -> Dictionary:
    var file := FileAccess.open_compressed(cache_path(seed_value, size_index), FileAccess.READ, FileAccess.COMPRESSION_ZSTD)
    if file == null:
        return {}
    if file.get_pascal_string() != CACHE_MAGIC or int(file.get_32()) != PACKED_VERSION:
        file.close()
        return {}
    if int(file.get_64()) != abs(seed_value) or int(file.get_32()) != size_index:
        file.close()
        return {}
    var route_records = file.get_var(false)
    var record = file.get_var(false)
    if not route_records is Array or not record is Dictionary:
        file.close()
        return {}
    var routes := _unpack_routes(route_records as Array)
    for route in routes:
        if route == null:
            file.close()
            return {}
    var keys := ["origin", "width", "height", "count", "flags", "name", "upper", "biome", "shore_ocean",
        "shore_tidal", "ledge_dir", "has_item", "amount", "route", "items", "doors", "strings", "route_count"]
    for key in keys:
        if not (record as Dictionary).has(key):
            file.close()
            return {}
    if int(record.route_count) < 0 or int(record.route_count) > routes.size() or not record.strings is PackedStringArray \
            or not record.items is Dictionary or not record.doors is Dictionary or not record.origin is Vector2i:
        file.close()
        return {}
    for key in ["flags", "name", "upper", "biome", "shore_ocean", "shore_tidal", "ledge_dir", "has_item", "amount", "route"]:
        if not record[key] is PackedInt32Array:
            file.close()
            return {}
    var store := WorldTileStore.from_record(record, routes)
    if not store.is_valid_record():
        file.close()
        return {}
    var interiors: Array = []
    interiors.resize(MAX_INTERIOR_LAYERS)
    var populated_count := int(file.get_32())
    if populated_count < 0 or populated_count > MAX_INTERIOR_LAYERS:
        file.close()
        return {}
    for _entry in range(populated_count):
        var layer_index := int(file.get_32())
        if layer_index < 0 or layer_index >= MAX_INTERIOR_LAYERS:
            file.close()
            return {}
        var layer := _read_tile_layer(file, routes)
        if layer.is_empty():
            file.close()
            return {}
        interiors[layer_index] = layer
    var pokemon = file.get_var(false)
    var burrowed_pokemon = file.get_var(false)
    var interior_pokemon = file.get_var(false)
    var edges = file.get_var(false)
    var bottom_left = file.get_var(false)
    var top_right = file.get_var(false)
    var already_used_dungeons = file.get_var(false)
    var regi_relocated_cells = file.get_var(false)
    var file_error := file.get_error()
    file.close()
    if file_error != OK or not pokemon is Dictionary or not edges is Array:
        return {}
    if not bottom_left is Vector2i or not top_right is Vector2i:
        return {}
    return {
        "store": store,
        "pokemon": pokemon,
        "burrowed_pokemon": burrowed_pokemon if burrowed_pokemon is Array else [],
        "interior_pokemon": interior_pokemon if interior_pokemon is Array else [],
        "interiors": interiors,
        "edges": edges,
        "bottom_left": bottom_left,
        "top_right": top_right,
        "already_used_dungeons": already_used_dungeons if already_used_dungeons is Array else [],
        "regi_relocated_cells": regi_relocated_cells if regi_relocated_cells is Dictionary else {}
    }

static func save_result(
        seed_value: int, size_index: int, result: Dictionary
    ) -> bool:
    if not _looks_like_result(result):
        return false
    var absolute_directory := ProjectSettings.globalize_path(cache_directory())
    if DirAccess.make_dir_recursive_absolute(absolute_directory) != OK:
        return false
    var file := FileAccess.open_compressed(
        cache_path(seed_value, size_index),
        FileAccess.WRITE,
        FileAccess.COMPRESSION_ZSTD
    )
    if file == null:
        return false

    var route_index: Dictionary = {}
    var routes: Array = []
    _collect_routes(result.get("tiles", {}) as Dictionary, route_index, routes)
    var interiors: Array = result.get("interiors", []) as Array
    for raw_layer in interiors:
        if raw_layer is Dictionary:
            _collect_routes(raw_layer as Dictionary, route_index, routes)

    file.store_pascal_string(CACHE_MAGIC)
    file.store_32(CACHE_VERSION)
    file.store_64(abs(seed_value))
    file.store_32(size_index)
    file.store_var(_pack_routes(routes), false)
    _write_tile_layer(file, result.get("tiles", {}) as Dictionary, route_index)

    var populated_layers: Array[int] = []
    for layer_index in range(interiors.size()):
        if interiors[layer_index] is Dictionary and not (
                interiors[layer_index] as Dictionary).is_empty():
            populated_layers.append(layer_index)
    file.store_32(populated_layers.size())
    for layer_index in populated_layers:
        file.store_32(layer_index)
        _write_tile_layer(file, interiors[layer_index] as Dictionary, route_index)

    file.store_var(result.get("pokemon", {}), false)
    file.store_var(result.get("burrowed_pokemon", []), false)
    file.store_var(result.get("interior_pokemon", []), false)
    file.store_var(_pack_edges(result.get("edges", []) as Array), false)
    file.store_var(Vector2i(result.get("bottom_left", Vector2i.ZERO)), false)
    file.store_var(Vector2i(result.get("top_right", Vector2i.ZERO)), false)
    file.store_var(result.get("already_used_dungeons", []), false)
    file.close()
    return FileAccess.file_exists(cache_path(seed_value, size_index))

static func load_result(seed_value: int, size_index: int) -> Dictionary:
    if FileAccess.file_exists(cache_path(seed_value, size_index)):
        var packed := _load_packed(seed_value, size_index)
        if not packed.is_empty(): return packed
    # A v2 cache: tile objects, repaired by the adapter, then saved as v3.
    var path := cache_path(seed_value, size_index, CACHE_VERSION)
    if not FileAccess.file_exists(path):
        return {}
    var file := FileAccess.open_compressed(
        path, FileAccess.READ, FileAccess.COMPRESSION_ZSTD
    )
    if file == null:
        return {}
    if file.get_pascal_string() != CACHE_MAGIC:
        file.close()
        return {}
    if int(file.get_32()) != CACHE_VERSION:
        file.close()
        return {}
    if int(file.get_64()) != abs(seed_value) or int(file.get_32()) != size_index:
        file.close()
        return {}

    var route_records = file.get_var(false)
    if not route_records is Array:
        file.close()
        return {}
    var routes := _unpack_routes(route_records as Array)
    var tiles := _read_tile_layer(file, routes)
    if tiles.is_empty():
        file.close()
        return {}

    var interiors: Array = []
    interiors.resize(MAX_INTERIOR_LAYERS)
    var populated_count := int(file.get_32())
    if populated_count < 0 or populated_count > MAX_INTERIOR_LAYERS:
        file.close()
        return {}
    for _entry in range(populated_count):
        var layer_index := int(file.get_32())
        if layer_index < 0 or layer_index >= MAX_INTERIOR_LAYERS:
            file.close()
            return {}
        var layer := _read_tile_layer(file, routes)
        if layer.is_empty():
            file.close()
            return {}
        interiors[layer_index] = layer

    var pokemon = file.get_var(false)
    var burrowed_pokemon = file.get_var(false)
    var interior_pokemon = file.get_var(false)
    var edges = file.get_var(false)
    var bottom_left = file.get_var(false)
    var top_right = file.get_var(false)
    var already_used_dungeons = file.get_var(false)
    var file_error := file.get_error()
    file.close()
    if file_error != OK or not pokemon is Dictionary or not edges is Array:
        return {}
    if not bottom_left is Vector2i or not top_right is Vector2i:
        return {}
    return {
        "tiles": tiles,
        "_write_packed_cache": true,
        "pokemon": pokemon,
        "burrowed_pokemon": burrowed_pokemon if burrowed_pokemon is Array else [],
        "interior_pokemon": interior_pokemon if interior_pokemon is Array else [],
        "interiors": interiors,
        "edges": edges,
        "bottom_left": bottom_left,
        "top_right": top_right,
        "already_used_dungeons": (
            already_used_dungeons if already_used_dungeons is Array else []
        )
    }

static func _looks_like_result(result: Dictionary) -> bool:
    return (
        result.get("tiles", {}) is Dictionary
        and not (result.get("tiles", {}) as Dictionary).is_empty()
        and result.get("bottom_left", null) is Vector2i
        and result.get("top_right", null) is Vector2i
    )

static func _collect_routes(
        layer: Dictionary, route_index: Dictionary, routes: Array
    ) -> void:
    for raw_tile in layer.values():
        var tile := raw_tile as SourceTile
        if tile == null or tile.route_belongs_to == null:
            continue
        var instance_id := tile.route_belongs_to.get_instance_id()
        if route_index.has(instance_id):
            continue
        route_index[instance_id] = routes.size()
        routes.append(tile.route_belongs_to)

static func _pack_routes(routes: Array) -> Array:
    var records: Array = []
    records.resize(routes.size())
    for index in range(routes.size()):
        var route := routes[index] as SourceRoute
        records[index] = [
            route.name,
            route.level,
            route.stored_pokemon,
            route.musics_index,
            route.is_dungeon,
            route.dont_spawn_overworlds
        ]
    return records

static func _unpack_routes(records: Array) -> Array:
    var routes: Array = []
    routes.resize(records.size())
    for index in range(records.size()):
        var record = records[index]
        if not record is Array or (record as Array).size() < 6:
            continue
        var values := record as Array
        var route := SourceRouteScript.new(String(values[0]), int(values[1]))
        route.stored_pokemon = values[2] if values[2] is Array else []
        route.musics_index = int(values[3])
        route.is_dungeon = bool(values[4])
        route.dont_spawn_overworlds = bool(values[5])
        routes[index] = route
    return routes

static func _write_tile_layer(
        file: FileAccess, layer: Dictionary, route_index: Dictionary
    ) -> void:
    file.store_32(layer.size())
    var chunk: Array = []
    chunk.resize(0)
    for raw_key in layer:
        var tile := layer[raw_key] as SourceTile
        if tile == null:
            continue
        chunk.append(_pack_tile(Vector2i(raw_key), tile, route_index))
        if chunk.size() >= TILE_CHUNK_SIZE:
            file.store_var(chunk, false)
            chunk = []
    if not chunk.is_empty():
        file.store_var(chunk, false)

static func _read_tile_layer(file: FileAccess, routes: Array) -> Dictionary:
    var tile_count := int(file.get_32())
    if tile_count <= 0 or tile_count > MAX_TILE_COUNT:
        return {}
    var layer: Dictionary = {}
    var remaining := tile_count
    while remaining > 0:
        var decoded = file.get_var(false)
        if not decoded is Array:
            return {}
        var chunk := decoded as Array
        if chunk.is_empty() or chunk.size() > remaining:
            return {}
        for raw_record in chunk:
            var unpacked := _unpack_tile(raw_record, routes)
            if unpacked.is_empty():
                return {}
            layer[unpacked[0]] = unpacked[1]
        remaining -= chunk.size()
    return layer

static func _pack_tile(
        key: Vector2i, tile: SourceTile, route_index: Dictionary
    ) -> Array:
    var route_slot := 0
    if tile.route_belongs_to != null:
        route_slot = int(route_index.get(
            tile.route_belongs_to.get_instance_id(), -1
        )) + 1
    var flags := 0
    flags |= 1 if tile.is_solid else 0
    flags |= 2 if tile.is_ledge else 0
    flags |= 4 if tile.is_water else 0
    flags |= 8 if tile.is_grass else 0
    flags |= 16 if tile.is_cuttable else 0
    flags |= 32 if tile.is_headbuttable else 0
    flags |= 64 if tile.is_tidal else 0
    flags |= 128 if tile.is_lava else 0
    return [
        key,
        tile.position,
        tile.name,
        tile.name_upper,
        tile.color,
        route_slot,
        tile.biome,
        flags,
        tile.ledge_dir,
        tile.is_bottom_mtn_layer,
        tile.shore_ocean,
        tile.shore_tidal,
        tile.has_item,
        tile.has_item_amount,
        tile.item_snapshot(),
        tile.door_snapshot()
    ]

static func _unpack_tile(raw_record: Variant, routes: Array) -> Array:
    if not raw_record is Array or (raw_record as Array).size() < 16:
        return []
    var record := raw_record as Array
    if not record[0] is Vector2i or not record[1] is Vector2i:
        return []
    var route: SourceRoute = null
    var route_slot := int(record[5])
    if route_slot > 0:
        var route_index := route_slot - 1
        if route_index < 0 or route_index >= routes.size():
            return []
        route = routes[route_index] as SourceRoute
        if route == null:
            return []
    # The cache already stores every flag below; avoid recalculating all tile
    # classifications only to immediately overwrite them on large saved worlds.
    var tile := SourceTileScript.new(
        String(record[2]), Vector2i(record[1]), String(record[3]),
        bool(record[4]), route, false
    )
    tile.biome = String(record[6])
    var flags := int(record[7])
    tile.is_solid = bool(flags & 1)
    tile.is_ledge = bool(flags & 2)
    tile.is_water = bool(flags & 4)
    # Repair only the omitted Java mine encounter flag in old caches.
    tile.is_grass = bool(flags & 8) or tile.name == "desert4_isGrass"
    tile.is_cuttable = bool(flags & 16)
    tile.is_headbuttable = bool(flags & 32)
    tile.is_tidal = bool(flags & 64)
    tile.is_lava = bool(flags & 128)
    tile.ledge_dir = String(record[8])
    tile.is_bottom_mtn_layer = bool(record[9])
    tile.shore_ocean = String(record[10])
    tile.shore_tidal = String(record[11])
    tile.has_item = String(record[12])
    tile.has_item_amount = int(record[13])
    if record[14] is Dictionary and not record[14].is_empty(): tile.items = record[14]
    if record[15] is Array and not record[15].is_empty(): tile.door_tiles.assign(record[15])
    return [Vector2i(record[0]), tile]

static func _pack_edges(edges: Array) -> Array[Vector2i]:
    var packed: Array[Vector2i] = []
    for raw_edge in edges:
        if raw_edge is SourceTile:
            packed.append((raw_edge as SourceTile).position)
        elif raw_edge is Vector2i:
            packed.append(raw_edge as Vector2i)
    return packed
