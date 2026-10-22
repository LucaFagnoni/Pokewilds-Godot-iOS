extends "res://scripts/source_reflection_layer.gd"

var palms_by_cell: Dictionary = {}
## The same palms by row: y -> palms in x order.
var palm_rows: Dictionary = {}
var palm_world_id := 0

func configure(world_node: Node, source_world: SourceExactWorldAdapter, player_node: Node2D) -> void:
    super.configure(world_node,source_world,player_node)
    _prepare_palms()

func _prepare_palms() -> void:
    palm_world_id = exact_world.get_instance_id()
    palms_by_cell.clear()
    # Only palm cells (tree6 above, tree5 ground) can hold a palm.
    var store: WorldTileStore = exact_world.tiles
    for tile in store.with_upper(["tree6"]): _refresh_palm(Vector2i(tile.position / 16))
    for index in store.with_name(["tree5"]): _refresh_palm(store.key_of(index) / 16)
    _sort_palms()

func _refresh_palm(cell: Vector2i) -> bool:
    var tile: SourceTile=exact_world.tile_at(cell)
    if tile==null or (tile.name_upper!="tree6" and tile.name!="tree5"):
        return palms_by_cell.erase(cell)
    var spec:=SourceWorldData.render_spec(tile,true)
    if spec.is_empty(): return palms_by_cell.erase(cell)
    var source: Rect2=spec.get("region",Rect2(0,0,16,32))
    var anchor:=Vector2(cell*16)+Vector2(spec.get("offset",Vector2.ZERO))+Vector2(0,source.size.y-8)
    var next: Array=[spec.texture,source,anchor,cell]
    if palms_by_cell.get(cell)==next: return false
    palms_by_cell[cell]=next
    return true

func _sort_palms() -> void:
    palm_rows.clear()
    for palm in palms_by_cell.values():
        if not palm_rows.has(palm[3].y): palm_rows[palm[3].y]=[]
        palm_rows[palm[3].y].append(palm)
    for row in palm_rows.values(): row.sort_custom(func(a,b): return a[3].x < b[3].x)

func refresh_cells(cells: Array) -> void:
    var changed:=false
    # Each cell once: the cells of nearby changes overlap.
    var unique:={}
    for cell in cells: unique[cell]=true
    # Only a palm's cell (tree6 above, tree5 ground) can hold one, or lose
    # one: the others are told apart in the store's arrays. A proxy for each
    # was 55 ms of the day's dig sites a player is sent.
    var store: WorldTileStore = exact_world.tiles
    var tree6: int = store.string_ids.get("tree6", -1)
    var tree5: int = store.string_ids.get("tree5", -1)
    var uppers := store.upper_ids
    var names := store.name_ids
    for cell in unique:
        var index := store.index_of(cell*16)
        if index >= 0 and uppers[index] != tree6 and names[index] != tree5 and not palms_by_cell.has(cell): continue
        if _refresh_palm(cell): changed=true
    if changed: _sort_palms()

## From the index, row by row. Looking at every cell in view instead cost
## ~10 ms each time the player stepped onto a new tile, ~25 ms zoomed out.
func _palms_in(first: Vector2i, last: Vector2i) -> Array:
    if palm_world_id != exact_world.get_instance_id(): _prepare_palms()
    var palms := []
    for y in range(first.y, last.y + 1):
        for palm in palm_rows.get(y, []):
            if palm[3].x >= first.x and palm[3].x <= last.x: palms.append(palm)
    return palms
