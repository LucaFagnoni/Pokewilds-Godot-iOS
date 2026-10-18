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
##   modal: bool              swallow every touch (default true)
##   hide_pad: bool           hide the gamepad overlay (default: modal)

const JOHTO_FONT := preload("res://assets/source_text_font.fnt")
const TAP_SLOP := 6.0
const SWIPE_DISTANCE := 36.0

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

## A framed, game-styled button; hit-testing is done by this node, not the GUI.
func make_button(parent: Node, text: String, size: Vector2, font_size: int = 10) -> Control:
    var button := Panel.new()
    button.size = size
    button.mouse_filter = Control.MOUSE_FILTER_IGNORE
    button.add_theme_stylebox_override("panel", main._classic_dialogue_style())
    var label := Label.new()
    label.name = "Text"
    label.text = text
    label.mouse_filter = Control.MOUSE_FILTER_IGNORE
    label.set_anchors_preset(Control.PRESET_FULL_RECT)
    label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
    label.add_theme_font_override("font", JOHTO_FONT)
    label.add_theme_font_size_override("font_size", font_size)
    label.add_theme_color_override("font_color", Color.BLACK)
    label.offset_top = 2  # The bitmap font sits high in its line box.
    button.add_child(label)
    parent.add_child(button)
    return button

## A button showing the game's own triangle cursor (the font maps < > to PK MN).
func make_arrow(parent: Node, pointing_left: bool, size: Vector2) -> Control:
    var button := make_button(parent, "", size)
    var arrow: TextureRect = main._source_texture_rect(button, "Arrow", (size - Vector2(5, 7)) * 0.5, Vector2(5, 7), main.source_command_cursor.texture)
    arrow.stretch_mode = TextureRect.STRETCH_SCALE
    arrow.flip_h = pointing_left
    return button

func _process(_delta: float) -> void:
    if not enabled: return
    surfaces.refresh_visuals()
    surface = surfaces.build()
    var bounds: Rect2 = main.touch_controls.usable_rect
    var has_back := surface.has("back")
    close_button.visible = has_back
    if has_back:
        close_button.position = Vector2(bounds.end.x - close_button.size.x - 4, bounds.position.y + 4)
    var wanted: Array = surface.get("buttons", [])
    while extra_buttons.size() < wanted.size():
        extra_buttons.append(make_button(chrome, "", Vector2(10, 10)))
    for i in extra_buttons.size():
        var button := extra_buttons[i]
        button.visible = i < wanted.size()
        if not button.visible: continue
        var rect: Rect2 = wanted[i][2]
        button.position = rect.position
        button.size = rect.size
        (button.get_node("Text") as Label).text = String(wanted[i][0])
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
            pinch_distance = _pinch_span()
            return true
        if not start_points.has(event.index): return modal
        var start: Vector2 = start_points[event.index]
        var single := points.size() == 1
        points.erase(event.index)
        start_points.erase(event.index)
        pinch_distance = _pinch_span()
        if single and not moved:
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

func _tap(point: Vector2) -> void:
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
