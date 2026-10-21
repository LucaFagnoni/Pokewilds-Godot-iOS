extends Node
## Finger input for menus. Each frame touch_surfaces.gd describes the screen
## in front of the player (tap targets, scrolling, back); this node turns taps,
## drags and pinches into calls on it and draws the touch-only buttons.
##
## Surface keys (all optional):
##   rows: Array[Rect2]       tap targets in canvas coordinates
##   tap: Callable(int[, Vector2]) a row was tapped (optionally with the point)
##   scroll: Callable(int)    vertical drag, +1 = next row
##   row_height: float        drag distance per scroll step (default 16)
##   swipe: Callable(int)     horizontal swipe, +1 = next page
##   drag: Callable(Vector2)  free one-finger drag (replaces scroll)
##   pinch: Callable(float)   two-finger zoom ratio since the last call
##   tap_at: Callable(Vector2) tap outside rows and buttons
##   back: Callable()         shows the close button
##   buttons: Array of [text, Callable, Rect2]  extra touch-only buttons
##   hotspots: Array of [_, Callable, Rect2]  tap areas over existing visuals
##   hold: Callable()         called every frame while one finger rests (after HOLD_DELAY)
##   long_press: Callable(int) a row was pressed for LONG_PRESS seconds
##   drop: Callable(int, Vector2) the finger lifted after a long press (drag and drop)
##   modal: bool              swallow every touch (default true)
##   hud: bool                buttons in the field HUD's look (hud_style.gd), not the menus'
##   hide_pad: bool           hide the gamepad overlay (default: modal)

const JOHTO_FONT := preload("res://assets/source_text_font.fnt")
const TAP_SLOP := 6.0
const SWIPE_DISTANCE := 36.0
const HOLD_DELAY := 0.3
const LONG_PRESS := 0.45

var main: Node
var surfaces: RefCounted
var enabled := false
var surface: Dictionary = {}
var chrome: Control
var close_button: Control
var extra_buttons: Array[Control] = []
var points: Dictionary = {}
var start_points: Dictionary = {}
var moved := false
var scroll_accum := 0.0
var pinch_distance := 0.0
var held_time := 0.0
var hold_used := false
var picked_row := -1

static func touch_runtime() -> bool:
    return OS.has_feature("mobile") or OS.get_cmdline_user_args().has("--touch-ui")

func configure(owner_main: Node, ui: CanvasLayer) -> void:
    main = owner_main
    enabled = touch_runtime()
    surfaces = preload("res://scripts/touch_surfaces.gd").new(owner_main, self)
    chrome = Control.new()
    chrome.name = "TouchChrome"
    chrome.mouse_filter = Control.MOUSE_FILTER_IGNORE
    chrome.z_index = 900
    ui.add_child(chrome)
    close_button = make_button(chrome, "X", Vector2(22, 20))
    close_button.hide()

const WHITE_FONT := preload("res://assets/source_text_font_white.fnt")
const BUTTON_PADDING := 4.0

## Thin pixel button: the 8 px dialogue frame leaves no room for text in a
## finger-sized button. Hit-testing is done by this node, not the GUI.
static var _button_styles := {}

## Two shared styles (selected / not): creating one per call allocated every frame.
static func button_style(selected: bool) -> StyleBoxFlat:
    if _button_styles.has(selected): return _button_styles[selected]
    var style := StyleBoxFlat.new()
    style.bg_color = Color.BLACK if selected else Color.WHITE
    style.border_color = Color.BLACK
    style.set_border_width_all(1)
    style.set_corner_radius_all(2)
    style.shadow_color = Color(0, 0, 0, 0.35)
    style.shadow_size = 1
    style.shadow_offset = Vector2(1, 1)
    style.anti_aliasing = false
    _button_styles[selected] = style
    return style

func make_button(parent: Node, text: String, size: Vector2, font_size: int = 10) -> Control:
    var button := Panel.new()
    button.size = size
    button.mouse_filter = Control.MOUSE_FILTER_IGNORE
    button.add_theme_stylebox_override("panel", button_style(false))
    var label := Label.new()
    label.name = "Text"
    label.mouse_filter = Control.MOUSE_FILTER_IGNORE
    label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
    label.clip_text = false
    label.add_theme_font_override("font", JOHTO_FONT)
    label.add_theme_font_size_override("font_size", font_size)
    label.add_theme_color_override("font_color", Color.BLACK)
    button.add_child(label)
    parent.add_child(button)
    set_text(button, text)
    button.resized.connect(func(): if not button.get_meta("hud", false): set_text(button, label.text))
    return button

## Centers the text inside the border and squeezes it if it would not fit.
## The Label is left-aligned and placed by hand: right after a text change it
## still reports a size shaped with the default font and would grow to that.
static func set_text(button: Control, text: String) -> void:
    var label := button.get_node("Text") as Label
    label.text = text
    label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
    label.vertical_alignment = VERTICAL_ALIGNMENT_TOP
    var font := label.get_theme_font("font")
    var font_size := label.get_theme_font_size("font_size")
    var inner_width := button.size.x - BUTTON_PADDING * 2.0
    var width := maxf(1.0, font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x)
    var squeeze := minf(1.0, inner_width / width)
    var left_aligned := bool(label.get_meta("align_left", false))
    var x := BUTTON_PADDING + (0.0 if left_aligned else (inner_width - width * squeeze) * 0.5)
    # Bitmap glyphs sit high in their line box; this lands them on the optical center.
    var y := (button.size.y - font.get_height(font_size)) * 0.5 + roundf(font_size * 0.25)
    label.pivot_offset = Vector2.ZERO
    label.scale = Vector2(squeeze, 1.0)
    label.size = Vector2.ZERO
    label.position = Vector2(roundf(x), roundf(y))

static func set_selected(button: Control, selected: bool) -> void:
    # Font overrides re-shape the label: only touch them on a real change.
    if button.has_meta("selected") and button.get_meta("selected") == selected: return
    button.set_meta("selected", selected)
    button.add_theme_stylebox_override("panel", button_style(selected))
    var label := button.get_node("Text") as Label
    label.add_theme_font_override("font", WHITE_FONT if selected else JOHTO_FONT)
    label.add_theme_color_override("font_color", Color.WHITE if selected else Color.BLACK)

const HudStyle = preload("res://scripts/hud_style.gd")

## Field buttons wear the HUD's look (glass, ring, white text, a white
## triangle for < and >); menu buttons keep the menus' white and black.
func _hud_look(button: Control, hud: bool, pointing: int) -> void:
    if button.get_meta("hud", false) == hud and button.get_meta("pointing", 0) == pointing and button.get_meta("dark", true) == HudStyle.dark:
        return
    if button.get_meta("hud", false) != hud:
        var label := button.get_node("Text") as Label
        label.text = ""
        label.scale = Vector2.ONE
        label.add_theme_font_override("font", HudStyle.FONT if hud else JOHTO_FONT)
        label.add_theme_color_override("font_color", HudStyle.INK if hud else Color.BLACK)
        button.add_theme_stylebox_override("panel", StyleBoxEmpty.new() if hud else button_style(false))
        if hud and not button.has_meta("hud_drawn"):
            button.set_meta("hud_drawn", true)
            button.draw.connect(_draw_hud_button.bind(button))
    button.set_meta("hud", hud)
    button.set_meta("pointing", pointing)
    button.set_meta("dark", HudStyle.dark)
    button.queue_redraw()

func _draw_hud_button(button: Control) -> void:
    if not button.get_meta("hud", false): return
    HudStyle.draw_shape(button, Rect2(Vector2.ZERO, button.size), false, HudStyle.INK, false, HudStyle.STROKE, true)
    var pointing := int(button.get_meta("pointing", 0))
    if pointing != 0:
        var c := button.size / 2.0
        var h := HudStyle.INK_HEIGHT / 2.0
        button.draw_colored_polygon(PackedVector2Array([c + Vector2(h * pointing, 0), c + Vector2(-h * pointing / 2.0, -h), c + Vector2(-h * pointing / 2.0, h)]), HudStyle.INK)

static func _ink_width(text: String) -> float:
    return HudStyle.FONT.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, HudStyle.FONT_SIZE).x - 1.0

## A button showing the game's own triangle cursor (the font maps < > to PK MN).
func make_arrow(parent: Node, pointing_left: bool, size: Vector2) -> Control:
    var button := make_button(parent, "", size)
    var arrow: TextureRect = main._source_texture_rect(button, "Arrow", (size - Vector2(5, 7)) * 0.5, Vector2(5, 7), main.source_command_cursor.texture)
    arrow.stretch_mode = TextureRect.STRETCH_SCALE
    arrow.flip_h = pointing_left
    return button

func _process(_delta: float) -> void:
    if not enabled: return
    surfaces.refresh_visuals(_delta)
    surface = surfaces.build()
    var bounds: Rect2 = main.touch_controls.usable_rect
    var has_back := surface.has("back")
    close_button.visible = has_back
    if has_back:
        close_button.position = Vector2(bounds.end.x - close_button.size.x - 4, bounds.position.y + 4)
    var wanted: Array = surface.get("buttons", [])
    var hud := bool(surface.get("hud", false))
    while extra_buttons.size() < wanted.size():
        extra_buttons.append(make_arrow(chrome, false, Vector2(10, 10)))
    for i in extra_buttons.size():
        var button := extra_buttons[i]
        button.visible = i < wanted.size()
        if not button.visible: continue
        var rect: Rect2 = wanted[i][2]
        button.position = rect.position
        if button.size != rect.size: button.size = rect.size
        # "<" and ">" draw the game's triangle (the font maps them to PK/MN).
        var text := String(wanted[i][0])
        var arrow := button.get_node("Arrow") as TextureRect
        var pointing := 0 if text not in ["<", ">"] else (-1 if text == "<" else 1)
        arrow.visible = pointing != 0 and not hud
        arrow.flip_h = text == "<"
        arrow.position = (button.size - arrow.size) * 0.5
        if pointing != 0: text = ""
        _hud_look(button, hud, pointing)
        var label := button.get_node("Text") as Label
        if hud:
            # The ink centred both ways, as on every HUD chip.
            label.text = text
            label.position = Vector2(roundf((rect.size.x - _ink_width(text)) / 2.0), roundf(rect.size.y / 2.0 - HudStyle.INK_CENTRE))
        elif label.text != text: set_text(button, text)
    # One resting finger: fast-forward (hold) or a long press on a row.
    if points.size() == 1 and not moved:
        held_time += _delta
        if surface.has("hold") and held_time >= HOLD_DELAY:
            hold_used = true
            surface.hold.call()
        elif surface.has("long_press") and held_time >= LONG_PRESS and not hold_used:
            var start: Vector2 = start_points.values()[0]
            var rows: Array = surface.get("rows", [])
            for i in rows.size():
                if Rect2(rows[i]).has_point(start):
                    hold_used = true
                    picked_row = i
                    surface.long_press.call(i)
                    if haptics_on(): Input.vibrate_handheld(25, 0.6)
                    break
    # The gamepad overlay would cover a touch-driven screen.
    main.touch_controls.set_menu_hidden(not surface.is_empty() and surface.get("hide_pad", surface.get("modal", true)))

## Returns true when the event was used (main then marks it handled).
func handle(event: InputEvent) -> bool:
    if not enabled: return false
    surface = surfaces.build()
    if surface.is_empty():
        points.clear()
        start_points.clear()
        return false
    var modal: bool = surface.get("modal", true)
    if event is InputEventMouse:
        # Touch also arrives as emulated mouse; old click handlers must not fire twice.
        return modal and event.device == InputEvent.DEVICE_ID_EMULATION
    if event is InputEventScreenTouch:
        if event.pressed:
            if not modal and _hit(event.position) == "": return false
            points[event.index] = event.position
            start_points[event.index] = event.position
            if points.size() == 1:
                moved = false
                scroll_accum = 0.0
                held_time = 0.0
                hold_used = false
                picked_row = -1
            pinch_distance = _pinch_span()
            return true
        if not start_points.has(event.index): return modal
        var start: Vector2 = start_points[event.index]
        var single := points.size() == 1
        points.erase(event.index)
        start_points.erase(event.index)
        pinch_distance = _pinch_span()
        if single and picked_row >= 0 and surface.has("drop"):
            surface.drop.call(picked_row, event.position)
            picked_row = -1
        elif single and not moved and not hold_used:
            _tap(start)
        elif single and surface.has("swipe"):
            var travel: Vector2 = event.position - start
            if absf(travel.x) >= SWIPE_DISTANCE and absf(travel.x) > absf(travel.y) * 1.5:
                surface.swipe.call(-1 if travel.x > 0.0 else 1)
        return true
    if event is InputEventScreenDrag:
        if not points.has(event.index): return modal
        points[event.index] = event.position
        if (event.position - Vector2(start_points[event.index])).length() > TAP_SLOP: moved = true
        if points.size() >= 2:
            var span := _pinch_span()
            if surface.has("pinch") and pinch_distance > 0.0 and span > 0.0:
                surface.pinch.call(span / pinch_distance)
            pinch_distance = span
        elif moved and surface.has("drag"):
            surface.drag.call(event.relative)
        elif moved and surface.has("scroll"):
            var step: float = surface.get("row_height", 16.0)
            scroll_accum += event.relative.y
            while absf(scroll_accum) >= step:
                var direction := 1 if scroll_accum < 0.0 else -1
                scroll_accum += step * direction
                surface.scroll.call(direction)
        return true
    return false

func _pinch_span() -> float:
    if points.size() < 2: return 0.0
    var values := points.values()
    return Vector2(values[0]).distance_to(values[1])

func _hit(point: Vector2) -> String:
    if close_button.visible and close_button.get_global_rect().grow(4).has_point(point): return "back"
    for button in extra_buttons:
        if button.visible and button.get_global_rect().grow(2).has_point(point): return "button"
    for spot in surface.get("hotspots", []):
        if Rect2(spot[2]).has_point(point): return "button"
    for rect in surface.get("rows", []):
        if Rect2(rect).has_point(point): return "row"
    return "tap_at" if surface.has("tap_at") else ""

static func haptics_on() -> bool:
    return bool(preload("res://scripts/game_options.gd").values.get("haptics", true))

func _tap(point: Vector2) -> void:
    if haptics_on(): Input.vibrate_handheld(10, 0.35)
    if close_button.visible and close_button.get_global_rect().grow(4).has_point(point):
        surface.back.call()
        return
    var wanted: Array = surface.get("buttons", [])
    for i in mini(extra_buttons.size(), wanted.size()):
        if extra_buttons[i].get_global_rect().grow(2).has_point(point):
            wanted[i][1].call()
            return
    for spot in surface.get("hotspots", []):
        if Rect2(spot[2]).grow(2).has_point(point):
            spot[1].call()
            return
    var rows: Array = surface.get("rows", [])
    for i in rows.size():
        if Rect2(rows[i]).has_point(point):
            var on_tap: Callable = surface.tap
            if on_tap.get_argument_count() >= 2: on_tap.call(i, point)
            else: on_tap.call(i)
            return
    if surface.has("tap_at"):
        surface.tap_at.call(point)

## Sends an action as if a button had been pressed and released, after the
## current input event has finished propagating.
func press(action: String) -> void:
    _emit_action.call_deferred(action)

func _emit_action(action: String) -> void:
    for pressed in [true, false]:
        var event := InputEventAction.new()
        event.action = StringName(action)
        event.pressed = pressed
        event.strength = 1.0 if pressed else 0.0
        Input.parse_input_event(event)

## Rects of the visible lines of a multi-line Label, in canvas coordinates.
static func label_lines(label: Label, count: int, width: float = -1.0) -> Array:
    var font := label.get_theme_font("font")
    var font_size := label.get_theme_font_size("font_size")
    var pitch := font.get_height(font_size) + label.get_theme_constant("line_spacing")
    var origin := label.get_global_rect().position
    var rects := []
    for i in count:
        rects.append(Rect2(origin + Vector2(-8, i * pitch - pitch * 0.2), Vector2((label.size.x if width < 0.0 else width) + 8, pitch)))
    return rects
