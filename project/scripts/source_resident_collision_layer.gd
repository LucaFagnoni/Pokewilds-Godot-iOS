extends "res://scripts/source_chunk_collision_streamer.gd"

# Retain the existing public interface and collision rules. Both travel modes
# are prepared once; movement never creates or destroys collision objects.
# Land and water use separate collision bits. SURF changes the player's mask,
# keeping the whole world's physics bodies resident during landing.
const WATER_COLLISION_BIT := 2
var resident_collision_layers: Array[TileMapLayer] = []
var resident_collision_builds := 0
var hole_collision_coords: Dictionary = {}
## Cells someone on foot can stand on. Water only needs a collision shape next
## to one of these: open sea far from any shore can never be touched on foot
## (SURF and FLY ignore the water layer), and it was ~90% of all shapes.
var foot_open: Dictionary = {}
const AROUND: Array[Vector2i] = [Vector2i(-1,-1), Vector2i(0,-1), Vector2i(1,-1), Vector2i(-1,0),
    Vector2i(1,0), Vector2i(-1,1), Vector2i(0,1), Vector2i(1,1)]

func configure(tiles, player_node: Node2D, source_tile_size: int = 16, pixel_keys: bool = false, deferred_build: bool = false) -> void:
    source_tiles = tiles
    tracked_player = player_node
    tile_size = source_tile_size
    source_keys_are_pixels = pixel_keys
    foot_open = {}
    _upper_solid_ids = {}
    _base_solid_ids = {}
    var tileset := TileSet.new()
    tileset.tile_size = Vector2i(tile_size,tile_size)
    tileset.add_physics_layer()
    tileset.set_physics_layer_collision_layer(0,1)
    tileset.set_physics_layer_collision_mask(0,1)
    var atlas := TileSetAtlasSource.new()
    var blank := Image.create(tile_size * 64,tile_size,false,Image.FORMAT_RGBA8)
    blank.fill(Color.TRANSPARENT)
    atlas.texture = ImageTexture.create_from_image(blank)
    atlas.texture_region_size = Vector2i(tile_size,tile_size)
    tileset.add_source(atlas,0)
    var half := float(tile_size)/2.0
    for index in range(2):
        atlas.create_tile(Vector2i(index,0))
        var data := atlas.get_tile_data(Vector2i(index,0),0)
        data.set_collision_polygons_count(0,1)
        var top := -half if index == 0 else 0.0
        data.set_collision_polygon_points(0,0,PackedVector2Array([Vector2(-half,top),Vector2(half,top),Vector2(half,half),Vector2(-half,half)]))
    # Reserve every hole outline before play, so digging never changes the TileSet.
    for mask in range(16):
        var suffix := ""
        for bit in range(4):
            if mask & (1 << bit): suffix += ["N","S","E","W"][bit]
        var corners: Array[String] = []
        for corner in ["NE","SE","SW","NW"]:
            if corner[0] in suffix and corner[1] in suffix: corners.append(corner)
        for fill in range(1 << corners.size()):
            var name := "hole1" + ("_"+suffix if not suffix.is_empty() else "")
            for bit in range(corners.size()):
                if fill & (1 << bit): name += "["+corners[bit]+"]"
            var coord := Vector2i(2+hole_collision_coords.size(),0)
            hole_collision_coords[name] = coord
            atlas.create_tile(coord)
            var spec := SourceWorldData.render_spec({"base":"green1","upper":name},true)
            var pixels: Image = spec.texture.get_image().get_region(Rect2i(spec.region))
            var bitmap := BitMap.new()
            bitmap.create_from_image_alpha(pixels)
            var polygons := bitmap.opaque_to_polygons(Rect2i(Vector2i.ZERO,pixels.get_size()),0.0)
            var data := atlas.get_tile_data(coord,0)
            data.set_collision_polygons_count(0,polygons.size())
            for polygon_index in range(polygons.size()):
                var points: PackedVector2Array = polygons[polygon_index]
                for point in range(points.size()): points[point] -= Vector2(half,half)
                data.set_collision_polygon_points(0,polygon_index,points)
    for index in range(2):
        var layer := TileMapLayer.new()
        layer.tile_set = tileset.duplicate(true)
        layer.tile_set.set_physics_layer_collision_layer(0, 1 if index == 0 else WATER_COLLISION_BIT)
        layer.tile_set.set_physics_layer_collision_mask(0, 0)
        layer.navigation_enabled = false
        layer.visible = false
        add_child(layer)
        resident_collision_layers.append(layer)
    if not deferred_build: refresh_now()

func _physics_process(_delta: float) -> void:
    pass

func _apply_collision_mode() -> void:
    for index in range(resident_collision_layers.size()):
        if resident_collision_layers[index].collision_enabled != streaming_enabled:
            resident_collision_layers[index].collision_enabled = streaming_enabled
    # FLY deliberately has no collision mask; preserve it through transitions.
    if is_instance_valid(tracked_player) and tracked_player is CollisionObject2D and tracked_player.collision_mask != 0:
        tracked_player.set_collision_mask_value(2, streaming_enabled and not allow_water)

func set_allow_water(value: bool) -> void:
    allow_water = value
    _apply_collision_mode()

func set_streaming_enabled(value: bool) -> void:
    streaming_enabled = value
    _apply_collision_mode()

## Returns whether the cell is water that blocks someone on foot. In a bulk
## build the caller places that water afterwards, once every
## cell's foot_open state is known.
func _update_cell(cell: Vector2i, bulk: bool = false) -> bool:
    # _cell_needs_collision for both modes, with the neighbour rules (which
    # do not depend on the mode) worked out once.
    var normal_solid: bool
    var surf_solid: bool
    if passable_cells.has(cell):
        normal_solid = false
        surf_solid = false
    elif SourceWorldData.berry_tree_collision(source_tiles, cell, source_keys_are_pixels):
        normal_solid = true
        surf_solid = true
    else:
        var savanna := SourceWorldData.savanna_trunk_collision(source_tiles, cell, source_keys_are_pixels)
        if savanna >= 0:
            normal_solid = savanna == 1
            surf_solid = normal_solid
        else:
            # _tile_is_solid for both modes, read from the store's arrays.
            var store: WorldTileStore = source_tiles
            var raw_index: int = store.index_of(cell * tile_size if source_keys_are_pixels else cell)
            if raw_index < 0:
                normal_solid = true
                surf_solid = true
            else:
                var bits: int = store.flags[raw_index]
                var upper_id: int = store.upper_ids[raw_index]
                var ledge := bits & WorldTileStore.LEDGE != 0
                var open_grass := bits & WorldTileStore.GRASS != 0 and not ledge and not _upper_solid(store, upper_id)
                var open_plain := upper_id == 0 and not ledge and not _base_solid(store, store.name_ids[raw_index])
                normal_solid = not open_grass and not open_plain and bits & WorldTileStore.SOLID != 0
                surf_solid = normal_solid and bits & WorldTileStore.WATER == 0
    var was_open := foot_open.has(cell)
    if normal_solid: foot_open.erase(cell)
    else: foot_open[cell] = true
    # A bulk build starts from empty layers: nothing to erase.
    if surf_solid or not bulk: _place(0, cell, surf_solid)
    var water := normal_solid and not surf_solid
    if bulk: return water
    _place(1, cell, water and _touches_open(cell))
    if was_open == normal_solid:
        # Became walkable or stopped being so: the water round it follows.
        for offset in AROUND:
            var next := cell + offset
            if _is_water_cell(next): _place(1, next, _touches_open(next))
    return water

var _cursor: SourceTile
var _upper_solid_ids := {}
var _base_solid_ids := {}

func _upper_solid(store: WorldTileStore, id: int) -> bool:
    var known = _upper_solid_ids.get(id)
    if known == null:
        known = SourceWorldData.is_upper_solid(store.strings[id])
        _upper_solid_ids[id] = known
    return known

func _base_solid(store: WorldTileStore, id: int) -> bool:
    var known = _base_solid_ids.get(id)
    if known == null:
        known = SourceWorldData.is_base_solid(store.strings[id])
        _base_solid_ids[id] = known
    return known

## This layer's own re-pointable proxy (see WorldTileStore.new_cursor).
func _cursor_at(index: int) -> SourceTile:
    if _cursor == null or _cursor._store != source_tiles: _cursor = source_tiles.new_cursor()
    _cursor.repoint(index)
    return _cursor

func _touches_open(cell: Vector2i) -> bool:
    for offset in AROUND:
        if foot_open.has(cell + offset): return true
    return false

## Neither walkable nor solid while surfing: water (as of the last update).
func _is_water_cell(cell: Vector2i) -> bool:
    if foot_open.has(cell) or resident_collision_layers[0].get_cell_source_id(cell) >= 0: return false
    return source_tiles.has(cell * tile_size if source_keys_are_pixels else cell)

func _place(index: int, cell: Vector2i, wanted: bool) -> void:
    var layer := resident_collision_layers[index]
    if not wanted:
        if layer.get_cell_source_id(cell) >= 0: layer.erase_cell(cell)
        return
    var original_mode := allow_water
    allow_water = index == 0
    var key := cell * tile_size if source_keys_are_pixels else cell
    var tile_index: int = source_tiles.index_of(key)
    var tile = null if tile_index < 0 else _cursor_at(tile_index)
    var crown := SourceWorldData.persim_crown_collision(source_tiles,cell,source_keys_are_pixels) and not _tile_is_solid(tile)
    var coord := Vector2i(1 if crown else 0,0)
    if tile is SourceTile and tile.has_item.is_empty() and not SourceWorldData.is_base_solid(tile.name) and hole_collision_coords.has(tile.name_upper):
        coord = hole_collision_coords[tile.name_upper]
    allow_water = original_mode
    if layer.get_cell_source_id(cell) != 0 or layer.get_cell_atlas_coords(cell) != coord:
        layer.set_cell(cell,0,coord)

func set_cell_passable(cell: Vector2i, value: bool) -> void:
    if value: passable_cells[cell] = true
    else: passable_cells.erase(cell)
    _update_cell(cell)

func refresh_cells(cells: Array) -> void:
    var affected := {}
    for cell in cells:
        for y in range(-2,3):
            for x in range(-1,2): affected[cell+Vector2i(x,y)] = true
    for cell in affected: _update_cell(cell)

## Rebuilds every cell. Play changes go through refresh_cells with the cells
## they touched; scanning all ~400k tiles for changes froze a dig for 0.5 s.
func refresh_now() -> void:
    if resident_collision_layers.is_empty(): return
    resident_collision_builds += 1
    for layer in resident_collision_layers: layer.clear()
    foot_open.clear()
    var boundary := {}
    var water: Array[Vector2i] = []
    for index in (source_tiles as WorldTileStore).indices():
        var key: Vector2i = source_tiles.key_of(index)
        var cell: Vector2i = Vector2i(key / tile_size) if source_keys_are_pixels else key
        if _update_cell(cell, true): water.append(cell)
        for direction in [Vector2i.UP,Vector2i.DOWN,Vector2i.LEFT,Vector2i.RIGHT]:
            var next: Vector2i = cell + direction
            if not source_tiles.has(next * tile_size if source_keys_are_pixels else next): boundary[next] = true
    for cell in boundary: _update_cell(cell, true)
    for cell in water:
        if _touches_open(cell): _place(1, cell, true)
    for layer in resident_collision_layers:
        layer.update_internals()
    _apply_collision_mode()

func build_initial_async() -> void:
    resident_collision_builds += 1
    var boundary := {}
    var water: Array[Vector2i] = []
    var deadline := Time.get_ticks_usec() + 13000
    for index in (source_tiles as WorldTileStore).indices():
        var key: Vector2i = source_tiles.key_of(index)
        var cell: Vector2i = Vector2i(key / tile_size) if source_keys_are_pixels else key
        if _update_cell(cell, true): water.append(cell)
        for direction in [Vector2i.UP,Vector2i.DOWN,Vector2i.LEFT,Vector2i.RIGHT]:
            var next: Vector2i = cell + direction
            if not source_tiles.has(next * tile_size if source_keys_are_pixels else next): boundary[next] = true
        if Time.get_ticks_usec() >= deadline:
            await get_tree().process_frame
            deadline = Time.get_ticks_usec() + 13000
    for cell in boundary: _update_cell(cell, true)
    for cell in water:
        if _touches_open(cell): _place(1, cell, true)
        if Time.get_ticks_usec() >= deadline:
            await get_tree().process_frame
            deadline = Time.get_ticks_usec() + 13000
    _apply_collision_mode()
    await get_tree().process_frame
