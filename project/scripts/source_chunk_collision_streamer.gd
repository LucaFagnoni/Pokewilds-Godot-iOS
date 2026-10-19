class_name SourceChunkCollisionStreamer
extends StaticBody2D

const DEFAULT_TILE_SIZE := 16
const COLLISION_RADIUS := Vector2i(14, 10)
const STREAM_SHIFT_CELLS := 4

## The overworld's WorldTileStore (or a Dictionary of tiles).
var source_tiles = {}
var tracked_player: Node2D
var tile_size := DEFAULT_TILE_SIZE
var source_keys_are_pixels := false
var allow_water := false
var passable_cells: Dictionary = {}
var streaming_enabled := true
var last_center := Vector2i(2147483647, 2147483647)
var active_shapes: Dictionary = {}
var shared_rectangle := RectangleShape2D.new()
var persim_crown_rectangle := RectangleShape2D.new()

func configure(
        tiles,
        player_node: Node2D,
        source_tile_size: int = DEFAULT_TILE_SIZE,
        pixel_keys: bool = false
    ) -> void:
    source_tiles = tiles
    tracked_player = player_node
    tile_size = source_tile_size
    source_keys_are_pixels = pixel_keys
    shared_rectangle.size = Vector2(tile_size, tile_size)
    persim_crown_rectangle.size = Vector2(tile_size, tile_size / 2.0)
    collision_layer = 1
    collision_mask = 1
    _refresh_collisions(true)

func set_allow_water(value: bool) -> void:
    if allow_water == value:
        return
    allow_water = value
    _refresh_collisions(true)

func set_cell_passable(cell: Vector2i, value: bool) -> void:
    if value:
        passable_cells[cell] = true
    else:
        passable_cells.erase(cell)
    _refresh_collisions(true)

func refresh_now() -> void:
    _refresh_collisions(true)

func _physics_process(_delta: float) -> void:
    if streaming_enabled:
        _refresh_collisions(false)

func set_streaming_enabled(value: bool) -> void:
    if streaming_enabled == value:
        return
    streaming_enabled = value
    if not value:
        _clear_active_shapes()
        last_center = Vector2i(2147483647, 2147483647)
    else:
        _refresh_collisions(true)

func _refresh_collisions(force: bool) -> void:
    if not streaming_enabled or tracked_player == null or not is_instance_valid(tracked_player):
        return
    var center := Vector2i(
        floori(tracked_player.global_position.x / float(tile_size)),
        floori(tracked_player.global_position.y / float(tile_size))
    )
    if (not force and
            absi(center.x - last_center.x) < STREAM_SHIFT_CELLS and
            absi(center.y - last_center.y) < STREAM_SHIFT_CELLS):
        return
    last_center = center

    var desired_cells: Dictionary = {}
    for y in range(center.y - COLLISION_RADIUS.y, center.y + COLLISION_RADIUS.y + 1):
        for x in range(center.x - COLLISION_RADIUS.x, center.x + COLLISION_RADIUS.x + 1):
            var cell := Vector2i(x, y)
            desired_cells[cell] = true

    # Retain every overlapping shape. Only the newly exposed boundary is
    # added and the expired boundary removed, avoiding a full scene-tree
    # rebuild whenever the player crosses a tile.
    for raw_cell in active_shapes.keys():
        var cell: Vector2i = raw_cell
        if desired_cells.has(cell) and _cell_needs_collision(cell):
            _position_collision_shape(active_shapes[cell], cell)
            continue
        var old_shape := active_shapes.get(cell) as CollisionShape2D
        if old_shape != null and is_instance_valid(old_shape):
            old_shape.queue_free()
        active_shapes.erase(cell)

    for raw_cell in desired_cells.keys():
        var cell: Vector2i = raw_cell
        if active_shapes.has(cell) or not _cell_needs_collision(cell):
            continue
        var shape := CollisionShape2D.new()
        _position_collision_shape(shape, cell)
        add_child(shape)
        active_shapes[cell] = shape

func _position_collision_shape(shape: CollisionShape2D, cell: Vector2i) -> void:
    # Do not shrink another solid object underneath/alongside the crown.
    var key := cell * tile_size if source_keys_are_pixels else cell
    var crown_only := SourceWorldData.persim_crown_collision(source_tiles, cell, source_keys_are_pixels) and not _tile_is_solid(SourceWorldData.tile_in(source_tiles, key))
    var desired_shape := persim_crown_rectangle if crown_only else shared_rectangle
    var desired_position := Vector2(cell * tile_size) + Vector2(tile_size / 2.0, tile_size * (0.75 if crown_only else 0.5))
    if shape.shape != desired_shape: shape.shape = desired_shape
    if shape.position != desired_position: shape.position = desired_position

func _cell_needs_collision(cell: Vector2i) -> bool:
    if passable_cells.has(cell):
        return false
    if SourceWorldData.berry_tree_collision(source_tiles, cell, source_keys_are_pixels):
        return true
    var savanna := SourceWorldData.savanna_trunk_collision(source_tiles, cell, source_keys_are_pixels)
    if savanna >= 0:
        return savanna == 1
    var lookup_key := cell * tile_size if source_keys_are_pixels else cell
    var raw_tile: Variant = SourceWorldData.tile_in(source_tiles, lookup_key)
    return _tile_is_solid(raw_tile)

func _clear_active_shapes() -> void:
    for raw_shape in active_shapes.values():
        var shape := raw_shape as CollisionShape2D
        if shape != null and is_instance_valid(shape):
            shape.queue_free()
    active_shapes.clear()

func _tile_is_solid(raw_tile: Variant) -> bool:
    if raw_tile == null:
        return true
    if raw_tile is SourceTile:
        var tile := raw_tile as SourceTile
        if allow_water and tile.is_water:
            return false
        if tile.is_grass and not SourceWorldData.is_upper_solid(
                tile.name_upper) and not tile.is_ledge:
            return false
        # Mutated/rewritten cells occasionally retain an old logical solid
        # flag even though they now render as plain floor. Collision follows
        # the visible authored names so invisible ground blockers cannot remain.
        if tile.name_upper.is_empty() and not tile.is_ledge and \
                not SourceWorldData.is_base_solid(tile.name):
            return false
        return tile.is_solid
    if raw_tile is Dictionary:
        return bool((raw_tile as Dictionary).get("solid", false))
    return false
