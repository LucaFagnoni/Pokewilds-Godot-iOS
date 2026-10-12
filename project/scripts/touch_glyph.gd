extends Control

var kind := ""
var caption := ""
var ink := Color.WHITE
var fill := Color(0.10,0.10,0.10,0.8)
var held := false
var stick_vector := Vector2.ZERO
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
    draw_texture_rect(textures[state],Rect2(Vector2.ZERO,size),false)
    if held and kind in ["LeftStick","RightStick"]:
        var knob_size := size*0.36
        var center := size*0.5+stick_vector*size*0.23
        draw_texture_rect(KNOB,Rect2(center-knob_size*0.5,knob_size),false)
