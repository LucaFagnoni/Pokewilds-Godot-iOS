extends Control

var kind := ""
var caption := ""
var ink := Color.WHITE
var fill := Color(0.10,0.10,0.10,0.8)
var held := false
var stick_vector := Vector2.ZERO
# LANCIO draws the ball or Pokemon a tap would throw over its own icon.
var icon: Texture2D
var textures: Dictionary = {}
const KNOB = preload("res://assets/touch_ui/stick_knob.svg")

func _ready() -> void:
    mouse_filter = Control.MOUSE_FILTER_IGNORE
    texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
    # High-resolution vector textures avoid changing the game's pixel snapping.
    for state in ["dark","light","pressed"]:
        textures[state] = load("res://assets/touch_ui/%s_%s.svg" % [kind,state])

func set_face_letter(letter: String) -> void:
    if kind not in ["A", "B", "X", "Y"]: return
    caption = letter
    for state in ["dark", "light", "pressed"]:
        textures[state] = load("res://assets/touch_ui/%s_%s.svg" % [letter,state])
    queue_redraw()

func _draw() -> void:
    if textures.is_empty(): return
    var state := "pressed" if held else ("dark" if fill.a>0.6 else "light")
    if icon != null:
        # Only the ring: the Poke Ball artwork under the icon read as two icons.
        var radius := minf(size.x, size.y) * 0.46
        var centre := size * 0.5
        draw_circle(centre, radius, Color("404040", 0.9) if held else Color("191919", 0.8 if state == "dark" else 0.45))
        draw_arc(centre, radius - size.x * 0.04, 0.0, TAU, 48, Color("f0c040"), size.x * 0.08, true)
    else:
        draw_texture_rect(textures[state],Rect2(Vector2.ZERO,size),false)
    _place_icon()

## Pixel art on a nearest-filtered child, at a whole multiple of its own size:
## the glyph itself filters linearly for its vector art, which blurred the sprite.
func _place_icon() -> void:
    var view := get_node_or_null("Icon") as TextureRect
    if icon == null:
        if view != null: view.hide()
        return
    if view == null:
        view = TextureRect.new()
        view.name = "Icon"
        view.mouse_filter = Control.MOUSE_FILTER_IGNORE
        view.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
        view.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
        view.stretch_mode = TextureRect.STRETCH_SCALE
        add_child(view)
    var native := icon.get_size()
    var room := minf(size.x, size.y) * 0.66
    var factor := maxf(1.0, floorf(room / maxf(native.x, native.y)))
    if maxf(native.x, native.y) > room: factor = room / maxf(native.x, native.y)
    view.texture = icon
    view.size = native * factor
    view.position = ((size - view.size) * 0.5).round()
    view.show()
    if held and kind in ["LeftStick","RightStick"]:
        var knob_size := size*0.36
        var center := size*0.5+stick_vector*size*0.23
        draw_texture_rect(KNOB,Rect2(center-knob_size*0.5,knob_size),false)
