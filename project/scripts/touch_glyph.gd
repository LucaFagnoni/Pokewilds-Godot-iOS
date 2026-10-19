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
    if icon != null:
        var icon_size := size*0.62
        draw_texture_rect(icon,Rect2((size-icon_size)*0.5,icon_size),false)
    if held and kind in ["LeftStick","RightStick"]:
        var knob_size := size*0.36
        var center := size*0.5+stick_vector*size*0.23
        draw_texture_rect(KNOB,Rect2(center-knob_size*0.5,knob_size),false)
