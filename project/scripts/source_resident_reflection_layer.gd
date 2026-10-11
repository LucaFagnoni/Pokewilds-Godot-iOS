extends "res://scripts/source_reflection_layer.gd"

var palms_by_cell: Dictionary = {}

func configure(world_node: Node, source_world: SourceExactWorldAdapter, player_node: Node2D) -> void:
    super.configure(world_node,source_world,player_node)
    _prepare_palms()

func _prepare_palms() -> void:
    palm_cache_key = [exact_world.get_instance_id()]
    palms_by_cell.clear()
    for key in exact_world.tiles:
        _refresh_palm(Vector2i(key/16))
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
    palm_cache=palms_by_cell.values()
    palm_cache.sort_custom(func(a,b): return a[3].y < b[3].y or (a[3].y == b[3].y and a[3].x < b[3].x))

func refresh_cells(cells: Array) -> void:
    var changed:=false
    for cell in cells:
        if _refresh_palm(cell): changed=true
    if changed: _sort_palms()

func _draw_palm_reflections() -> void:
    if not is_instance_valid(tracked_player): return
    if palm_cache_key != [exact_world.get_instance_id()]: _prepare_palms()
    var camera := get_viewport().get_camera_2d()
    var zoom := Vector2.ONE if camera == null else camera.zoom
    var half_view := get_viewport_rect().size / zoom * 0.5 + Vector2(64,64)
    var center := to_local(tracked_player.global_position)
    var first := Vector2i((center-half_view).floor()/16.0)
    var last := Vector2i((center+half_view).ceil()/16.0)
    for palm in palm_cache:
        var cell: Vector2i = palm[3]
        if cell.x < first.x or cell.x > last.x or cell.y < first.y or cell.y > last.y: continue
        _draw_palm_ripple(palm[0],palm[1],palm[2])
