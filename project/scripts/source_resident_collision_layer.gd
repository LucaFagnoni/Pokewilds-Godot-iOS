extends Node
const TexturePixels = preload("res://scripts/texture_pixels.gd")

## The overworld ground's collision, read from the tile store. A cell is
## worked out the first time the player's box comes near it and then kept;
## play changes go through refresh_cells / set_cell_passable with the cells
## they touched. Nothing is built at load and no physics object exists.
##
## The rules are the ones the two collision TileMapLayers had: land solids
## (layer bit 1, solid while surfing too) and water (bit 2), which blocks
## only next to a cell someone on foot can stand on, so open sea is never
## touched on foot. Empty dug holes are solid as their visible outline.
## Like the layers, the shapes come in blocks of 16x16 cells, one per layer:
## the block's cells merged into one outline and cut into convex pieces
## (collision_outline.gd), so a flat wall has no seam to catch on. A dug hole's
## outline stays a shape of its own.
const WATER_COLLISION_BIT := 2
const AROUND: Array[Vector2i] = [Vector2i(-1,-1), Vector2i(0,-1), Vector2i(1,-1), Vector2i(-1,0),
    Vector2i(1,0), Vector2i(-1,1), Vector2i(0,1), Vector2i(1,1)]
## Cell kinds, one byte each. 0 = not worked out yet.
const KNOWN := 128
const OPEN := 1        # someone on foot can stand here
const SURF_SOLID := 2  # solid while surfing as well
const HOLE := 4        # solid as its hole outline instead of the whole cell
const NONE := 8        # off the map, away from its edge: nothing at all

## The overworld's WorldTileStore.
var source_tiles
var tracked_player: Node2D
var tile_size := 16
var source_keys_are_pixels := false
var allow_water := false
var passable_cells: Dictionary = {}
var streaming_enabled := true
var _kinds := PackedByteArray()
var _outside := {}
## Cells off the map that a play change touched: worked out as any other.
var _touched := {}
var _upper_solid_ids := {}
var _base_solid_ids := {}
var _berry_ids := {}
var _hole_names := {}
var _hole_pieces := {}
const QUADRANT := 16
## The solids of the blocks near the player: Vector3i(block x, block y,
## layer) -> Array of PlayerMotion.Solid.
var _blocks := {}
const Outline := preload("res://scripts/collision_outline.gd")

func configure(tiles, player_node: Node2D, source_tile_size: int = 16, pixel_keys: bool = false) -> void:
    source_tiles = tiles
    tracked_player = player_node
    tile_size = source_tile_size
    source_keys_are_pixels = pixel_keys
    _upper_solid_ids = {}
    _base_solid_ids = {}
    _berry_ids = {}
    # The hole outlines that are solid as drawn (every other upper name
    # blocks the whole cell).
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
            _hole_names[name] = true
    refresh_now()

func _apply_collision_mode() -> void:
    # FLY deliberately has no collision mask; preserve it through transitions.
    if is_instance_valid(tracked_player) and int(tracked_player.get("collision_mask")) != 0:
        tracked_player.call("set_collision_mask_value", 2, streaming_enabled and not allow_water)

func set_allow_water(value: bool) -> void:
    allow_water = value
    _apply_collision_mode()

func set_streaming_enabled(value: bool) -> void:
    streaming_enabled = value
    _apply_collision_mode()

func set_cell_passable(cell: Vector2i, value: bool) -> void:
    if value: passable_cells[cell] = true
    else: passable_cells.erase(cell)
    _forget(cell)

func refresh_cells(cells: Array) -> void:
    # Each cell and each block once: a change's cells overlap its neighbours',
    # and a day's dig sites (some 200 changes) forgot the same ones over and
    # over, a third of a second on the host and on every player's phone.
    var forget := {}
    for cell in cells:
        for y in range(-2,3):
            for x in range(-1,2): forget[cell + Vector2i(x, y)] = true
    _forget_all(forget.keys())

## Forgets every cell: each is worked out again when next needed.
func refresh_now() -> void:
    var store: WorldTileStore = source_tiles
    _kinds = PackedByteArray()
    _kinds.resize(store.width * store.height)
    _outside.clear()
    _touched.clear()
    _blocks.clear()
    _apply_collision_mode()

func _forget(cell: Vector2i) -> void:
    _forget_all([cell])

func _forget_all(cells: Array) -> void:
    # The water next to a cell can change with it: the blocks of the cells
    # around it too (_block_of of each of them).
    var blocks := {}
    for cell in cells:
        for by in range(floori((cell.y - 1) / float(QUADRANT)), floori((cell.y + 1) / float(QUADRANT)) + 1):
            for bx in range(floori((cell.x - 1) / float(QUADRANT)), floori((cell.x + 1) / float(QUADRANT)) + 1):
                blocks[Vector2i(bx, by)] = true
    for block in blocks:
        _blocks.erase(Vector3i(block.x, block.y, 0))
        _blocks.erase(Vector3i(block.x, block.y, 1))
    var store: WorldTileStore = source_tiles
    for cell in cells:
        if not store.has(cell * tile_size if source_keys_are_pixels else cell): _touched[cell] = true
        var at: Vector2i = cell - store.origin
        if at.x >= 0 and at.y >= 0 and at.x < store.width and at.y < store.height:
            _kinds[at.y * store.width + at.x] = 0
        else:
            _outside.erase(cell)

## Appends the solids (PlayerMotion.Solid) of the ground under `area` for a
## body colliding with `mask`.
func collect(area: Rect2, mask: int, out: Array) -> void:
    if not streaming_enabled or mask & (1 | WATER_COLLISION_BIT) == 0: return
    var span := float(tile_size * QUADRANT)
    for layer in 2:
        if mask & (1 << layer) == 0: continue
        for by in range(floori(area.position.y / span), floori(area.end.y / span) + 1):
            for bx in range(floori(area.position.x / span), floori(area.end.x / span) + 1):
                for s: PlayerMotion.Solid in _block(Vector3i(bx, by, layer)):
                    if s.aabb.intersects(area, true): out.append(s)

## One block round the player made ready per frame, so walking into new
## ground never builds several in the same frame (a block is ~1 ms, up to 8).
func _process(_delta: float) -> void:
    if not streaming_enabled or not is_instance_valid(tracked_player): return
    var mask := int(tracked_player.get("collision_mask"))
    if mask == 0: return
    var at := _block_of(Vector2i((tracked_player.position / float(tile_size)).floor()))
    for layer in 2:
        if mask & (1 << layer) == 0: continue
        for y in range(-1, 2):
            for x in range(-1, 2):
                var key := Vector3i(at.x + x, at.y + y, layer)
                if not _blocks.has(key):
                    _block(key)
                    return

func _block_of(cell: Vector2i) -> Vector2i:
    return Vector2i(floori(cell.x / float(QUADRANT)), floori(cell.y / float(QUADRANT)))

## The solids of one block of cells on one layer (0 land, 1 water).
func _block(key: Vector3i) -> Array:
    var known = _blocks.get(key)
    if known != null: return known
    if _blocks.size() >= 64:
        # Keep the blocks round the player.
        var near := Vector2i.ZERO
        if is_instance_valid(tracked_player):
            near = _block_of(Vector2i((tracked_player.position / float(tile_size)).floor()))
        for old: Vector3i in _blocks.keys():
            if absi(old.x - near.x) > 2 or absi(old.y - near.y) > 2: _blocks.erase(old)
    var cells := {}
    var shapes := []
    for y in QUADRANT:
        for x in QUADRANT:
            var cell := Vector2i(key.x * QUADRANT + x, key.y * QUADRANT + y)
            var kind := _kind(cell)
            if kind & (OPEN | NONE): continue
            if key.z == 0:
                if kind & SURF_SOLID == 0: continue
            elif kind & SURF_SOLID or not _touches_open(cell):
                continue
            if kind & HOLE == 0:
                cells[cell] = true
                continue
            var centre := Vector2(cell * tile_size) + Vector2(tile_size, tile_size) * 0.5
            for piece in _hole_shape(cell):
                shapes.append(PlayerMotion.Solid.polygon(piece, centre))
    for piece in Outline.pieces(cells, tile_size):
        shapes.append(PlayerMotion.Solid.polygon(piece, Vector2.ZERO))
    _blocks[key] = shapes
    return shapes

func _touches_open(cell: Vector2i) -> bool:
    for offset in AROUND:
        if _kind(cell + offset) & OPEN: return true
    return false

func _kind(cell: Vector2i) -> int:
    var store: WorldTileStore = source_tiles
    var at := cell - store.origin
    var slot := -1
    if at.x >= 0 and at.y >= 0 and at.x < store.width and at.y < store.height:
        slot = at.y * store.width + at.x
        var known := _kinds[slot]
        if known: return known
    else:
        var kept = _outside.get(cell)
        if kept != null: return kept
    var kind := _work_out(cell)
    if slot >= 0: _kinds[slot] = kind
    else: _outside[cell] = kind
    return kind

## The two collision modes of a cell (on foot, surfing) and its shape.
func _work_out(cell: Vector2i) -> int:
    var store: WorldTileStore = source_tiles
    var key := cell * tile_size if source_keys_are_pixels else cell
    var raw_index: int = store.index_of(key)
    if raw_index < 0 and not store.has(key) and not _touched.has(cell) and not _on_edge(cell):
        # The layers had cells for the map and the ring round it only.
        return KNOWN | NONE
    var normal_solid: bool
    var surf_solid: bool
    if passable_cells.has(cell):
        normal_solid = false
        surf_solid = false
    elif _berry_tree(store, raw_index):
        normal_solid = true
        surf_solid = true
    else:
        var savanna := SourceWorldData.savanna_trunk_collision(source_tiles, cell, source_keys_are_pixels)
        if savanna >= 0:
            normal_solid = savanna == 1
            surf_solid = normal_solid
        elif raw_index < 0:
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
    var kind := KNOWN
    if not normal_solid: return kind | OPEN
    if surf_solid: kind |= SURF_SOLID
    if raw_index >= 0 and store.has_item_ids[raw_index] == 0 and _hole_names.has(store.strings[store.upper_ids[raw_index]]) \
            and not _base_solid(store, store.name_ids[raw_index]):
        kind |= HOLE
    return kind

## Next to a map cell (a cell of the ring round the map)?
func _on_edge(cell: Vector2i) -> bool:
    for d in [Vector2i.UP, Vector2i.DOWN, Vector2i.LEFT, Vector2i.RIGHT]:
        var next: Vector2i = cell + d
        if source_tiles.has(next * tile_size if source_keys_are_pixels else next): return true
    return false

## SourceWorldData.berry_tree_collision, by upper name id.
func _berry_tree(store: WorldTileStore, index: int) -> bool:
    if index < 0: return false
    var id: int = store.upper_ids[index]
    if id == 0: return false
    var known = _berry_ids.get(id)
    if known == null:
        known = store.strings[id].to_lower().begins_with("berrytree_")
        _berry_ids[id] = known
    return known

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

## The empty hole's outline traced from its art, as the TileSet's polygons,
## in convex pieces round the cell's centre.
func _hole_shape(cell: Vector2i) -> Array[PackedVector2Array]:
    var store: WorldTileStore = source_tiles
    var name: String = store.upper_at(store.index_of(cell * tile_size if source_keys_are_pixels else cell))
    var known = _hole_pieces.get(name)
    if known != null: return known
    var spec := SourceWorldData.render_spec({"base":"green1","upper":name},true)
    var pixels: Image = TexturePixels.of(spec.texture).get_region(Rect2i(spec.region))
    var bitmap := BitMap.new()
    bitmap.create_from_image_alpha(pixels)
    var pieces: Array[PackedVector2Array] = []
    var half := tile_size / 2.0
    for polygon: PackedVector2Array in bitmap.opaque_to_polygons(Rect2i(Vector2i.ZERO,pixels.get_size()),0.0):
        for point in range(polygon.size()): polygon[point] -= Vector2(half,half)
        pieces.append_array(_convex(polygon))
    _hole_pieces[name] = pieces
    return pieces

## TileData's shapes for a collision polygon: its convex pieces, each turned
## counter-clockwise as ConvexPolygonShape2D does.
static func _convex(polygon: PackedVector2Array) -> Array[PackedVector2Array]:
    var pieces: Array[PackedVector2Array] = []
    for piece: PackedVector2Array in Geometry2D.decompose_polygon_in_convex(polygon):
        if Geometry2D.is_polygon_clockwise(piece): piece.reverse()
        pieces.append(piece)
    return pieces
