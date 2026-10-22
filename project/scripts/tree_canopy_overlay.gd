extends Node2D
# Redraw only the canopy above grounded actors; trunks retain existing collision.
var world: Node2D
var last_cell := Vector2i(2147483647,2147483647)
func _process(_delta: float) -> void:
    visible = world.active_area_id == "OVERWORLD" and world.active_field_move != "FLY"
    var cell: Vector2i = world._player_cell()
    if cell != last_cell:
        last_cell = cell
        queue_redraw()
func _draw() -> void:
    if world.exact_world == null: return
    var cell: Vector2i = world._player_cell()
    for y in range(cell.y-3,cell.y+4):
        for x in range(cell.x-3,cell.x+4):
            var anchor := Vector2i(x,y)
            # Names first, from the store: 49 tile objects a step otherwise.
            var names: PackedStringArray = world._exact_names_at(anchor)
            if names.is_empty(): continue
            var key := names[0]+names[1]
            if "tree" not in key or "savanna" in key or "planted" in key: continue
            var tile: SourceTile = world._frame_tile(anchor)
            for upper in [false,true]:
                var spec := SourceWorldData.render_spec(tile,upper,0,0)
                if spec.is_empty(): continue
                var size: Vector2 = spec.size
                if size.y <= 16: continue
                var origin := Vector2(anchor*16)+Vector2(spec.get("offset",Vector2.ZERO))
                var canopy := Rect2(origin,Vector2(size.x,size.y-16))
                if not canopy.has_point(world._cell_center(cell)): continue
                var region: Rect2 = spec.region
                region.size.y -= 16
                draw_texture_rect_region(spec.texture,canopy,region)
