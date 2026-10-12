extends Texture2D

var current: Texture2D

func use(texture: Texture2D) -> void:
    current = texture
    emit_changed()

func _get_width() -> int: return current.get_width() if current != null else 1
func _get_height() -> int: return current.get_height() if current != null else 1
func _has_alpha() -> bool: return current.has_alpha() if current != null else true
func _get_rid() -> RID: return current.get_rid() if current != null else RID()
func _get_image() -> Image: return current.get_image() if current != null else null
func _is_pixel_opaque(x: int, y: int) -> bool: return current.is_pixel_opaque(x,y) if current != null else false
func _draw(canvas: RID, position: Vector2, modulate: Color, transpose: bool) -> void:
    if current != null: current.draw(canvas,position,modulate,transpose)
func _draw_rect(canvas: RID, rect: Rect2, tile: bool, modulate: Color, transpose: bool) -> void:
    if current != null: current.draw_rect(canvas,rect,tile,modulate,transpose)
func _draw_rect_region(canvas: RID, rect: Rect2, region: Rect2, modulate: Color, transpose: bool, clip_uv: bool) -> void:
    if current != null: current.draw_rect_region(canvas,rect,region,modulate,transpose,clip_uv)
