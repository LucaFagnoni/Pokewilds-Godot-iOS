extends "res://scripts/source_chunk_collision_streamer.gd"

# Retain the existing public interface and collision rules. Both travel modes
# are prepared once; movement never creates or destroys collision objects.
# Land and water use separate collision bits. SURF changes the player's mask,
# keeping the whole world's physics bodies resident during landing.
const WATER_COLLISION_BIT := 2
var resident_collision_layers: Array[TileMapLayer] = []
var resident_collision_builds := 0
var resident_collision_revisions: Dictionary = {}
var hole_collision_coords: Dictionary = {}

func configure(tiles: Dictionary, player_node: Node2D, source_tile_size: int = 16, pixel_keys: bool = false, deferred_build: bool = false) -> void:
    source_tiles = tiles
    tracked_player = player_node
    tile_size = source_tile_size
    source_keys_are_pixels = pixel_keys
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

func _update_cell(cell: Vector2i) -> void:
    var original_mode := allow_water
    allow_water = false
    var normal_solid := _cell_needs_collision(cell)
    allow_water = true
    var surf_solid := _cell_needs_collision(cell)
    for index in range(2):
        allow_water = index == 0
        var layer := resident_collision_layers[index]
        if not (surf_solid if index == 0 else normal_solid and not surf_solid):
            if layer.get_cell_source_id(cell) >= 0: layer.erase_cell(cell)
            continue
        var key := cell * tile_size if source_keys_are_pixels else cell
        var crown := SourceWorldData.persim_crown_collision(source_tiles,cell,source_keys_are_pixels) and not _tile_is_solid(source_tiles.get(key))
        var coord := Vector2i(1 if crown else 0,0)
        var tile = source_tiles.get(key)
        if tile is SourceTile and tile.has_item.is_empty() and not SourceWorldData.is_base_solid(tile.name) and hole_collision_coords.has(tile.name_upper):
            coord = hole_collision_coords[tile.name_upper]
        if layer.get_cell_source_id(cell) != 0 or layer.get_cell_atlas_coords(cell) != coord:
            layer.set_cell(cell,0,coord)
    allow_water = original_mode

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

func refresh_now() -> void:
    if resident_collision_layers.is_empty(): return
    resident_collision_builds += 1
    var boundary := {}
    var changed: Array = []
    var current := {}
    for key in source_tiles:
        var cell: Vector2i = Vector2i(key / tile_size) if source_keys_are_pixels else key
        var tile = source_tiles[key]
        var revision = [tile.get_instance_id(),tile.resident_revision] if tile is SourceTile else hash(tile)
        current[key] = revision
        if resident_collision_revisions.get(key) == revision: continue
        changed.append(cell)
        for direction in [Vector2i.UP,Vector2i.DOWN,Vector2i.LEFT,Vector2i.RIGHT]:
            var next: Vector2i = cell + direction
            var next_key: Vector2i = next * tile_size if source_keys_are_pixels else next
            if not source_tiles.has(next_key): boundary[next] = true
    for key in resident_collision_revisions:
        if not current.has(key): changed.append(Vector2i(key / tile_size) if source_keys_are_pixels else key)
    var first_build := resident_collision_revisions.is_empty()
    resident_collision_revisions = current
    if first_build:
        for cell in changed: _update_cell(cell)
    else:
        refresh_cells(changed)
    for cell in boundary: _update_cell(cell)
    for layer in resident_collision_layers:
        layer.update_internals()
    _apply_collision_mode()

func build_initial_async() -> void:
    resident_collision_builds += 1
    var boundary := {}
    var deadline := Time.get_ticks_usec() + 6000
    for key in source_tiles:
        var cell: Vector2i = Vector2i(key / tile_size) if source_keys_are_pixels else key
        var tile = source_tiles[key]
        resident_collision_revisions[key] = [tile.get_instance_id(),tile.resident_revision] if tile is SourceTile else hash(tile)
        _update_cell(cell)
        for direction in [Vector2i.UP,Vector2i.DOWN,Vector2i.LEFT,Vector2i.RIGHT]:
            var next: Vector2i = cell + direction
            if not source_tiles.has(next * tile_size if source_keys_are_pixels else next): boundary[next] = true
        if Time.get_ticks_usec() >= deadline:
            await get_tree().process_frame
            deadline = Time.get_ticks_usec() + 6000
    for cell in boundary: _update_cell(cell)
    _apply_collision_mode()
    await get_tree().process_frame
