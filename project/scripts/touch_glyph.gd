extends Control
## One on-screen button, drawn in the HUD's look (hud_style.gd): the shape and
## its ring in code, then the button's own artwork (A, B, the wheel, the ball),
## the menu bars or its caption.

const HudStyle = preload("res://scripts/hud_style.gd")
const KNOB = preload("res://assets/touch_ui/stick_knob.svg")
const SQUARE := ["Start", "L1", "R1"]

var kind := ""
var caption := ""
## The ring's colour: white, or the face/wheel/ball colour (set by TouchControls).
var ink := Color.WHITE
var held := false
var stick_vector := Vector2.ZERO
# LANCIO draws the ball or Pokemon a tap would throw over its own icon.
var icon: Texture2D
var glyph: Texture2D

func _ready() -> void:
    mouse_filter = Control.MOUSE_FILTER_IGNORE
    texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
    _load_glyph(kind)

func set_face_letter(letter: String) -> void:
    if kind not in ["A", "B", "X", "Y"]: return
    caption = letter
    _load_glyph(letter)
    queue_redraw()

## High-resolution vector artwork, white on transparent: it keeps the game's pixel snapping.
func _load_glyph(glyph_name: String) -> void:
    var path := "res://assets/touch_ui/%s.svg" % glyph_name
    glyph = load(path) if ResourceLoader.exists(path) else null

func _draw() -> void:
    # The ring stays STROKE wide whatever BUTTON SIZE or a pinch scaled the button to.
    var stroke := HudStyle.STROKE / maxf(scale.x, 0.01)
    var rect := Rect2(Vector2.ZERO, size)
    # The menu button belongs to the top row: the chips' denser glass.
    HudStyle.draw_shape(self, rect, kind not in SQUARE, ink, held, stroke, kind == "Start")
    if kind == "Start":
        HudStyle.draw_menu_icon(self, size, stroke)
    elif kind in ["L1", "R1"]:
        var width := HudStyle.FONT.get_string_size(caption, HORIZONTAL_ALIGNMENT_LEFT, -1, HudStyle.FONT_SIZE).x - 1.0
        draw_string(HudStyle.FONT, Vector2((size.x - width) / 2.0, size.y / 2.0 - HudStyle.INK_CENTRE + HudStyle.FONT.get_ascent(HudStyle.FONT_SIZE)).round(), caption, HORIZONTAL_ALIGNMENT_LEFT, -1, HudStyle.FONT_SIZE, HudStyle.INK)
    elif glyph != null and icon == null:
        draw_texture_rect(glyph, rect, false)
    if held and kind == "LeftStick":
        var knob_size := size * 0.36
        draw_texture_rect(KNOB, Rect2(size * 0.5 + stick_vector * size * 0.23 - knob_size * 0.5, knob_size), false)
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
