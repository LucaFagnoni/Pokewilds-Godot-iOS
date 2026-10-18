class_name TouchControls
extends Control

@onready var input_router: InputRouter = get_node("/root/InputRouterSingleton")

signal control_theme_changed
signal touch_config_requested
signal safe_area_changed(bounds: Rect2)

const SAVE_PATH := "user://touch_layout_m43.cfg"
const SETTINGS_SCHEMA_VERSION := 7
const THEME_SYSTEM := 0
const THEME_LIGHT := 1
const THEME_DARK := 2

# Each touch button emits the same InputMap action as its physical control.
const ACTIONS := {
    "Controls": [], "DPad": [], "LeftStick": [], "RightStick": [],
    "A": ["confirm"], "B": ["cancel"], "X": ["run"], "Y": ["pokedex"],
    "Start": ["start"], "Select": ["map_open"],
    "L1": ["shoulder_left", "zoom_out"], "L2": ["field_move_wheel"],
    "R1": ["shoulder_right", "zoom_in"], "R2": ["ball_mechanics"]
}
# Baseline dimensions are fractions of the usable 320x180 game canvas.
# Face buttons occupy 13.3% of its short side; sticks 22.2%.
const CONTROL_LAYOUT := {
    "Controls": Rect2(148,8,24,18),
    "LeftStick": Rect2(40,80,40,40),
    "RightStick": Rect2(173,125,40,40),
    "DPad": Rect2(88,127,36,36),
    "X": Rect2(253,76,24,24),
    "Y": Rect2(229,100,24,24),
    "A": Rect2(277,100,24,24),
    "B": Rect2(253,124,24,24),
    "L1": Rect2(42,33,24,18),
    "L2": Rect2(25,55,18,24),
    "R1": Rect2(269,33,24,18),
    "R2": Rect2(291,55,18,24),
    "Select": Rect2(272,8,18,16),
    "Start": Rect2(298,8,18,16)
}
const GLYPH = preload("res://scripts/touch_glyph.gd")
var movement_contacts: Dictionary = {}
var pointer_positions: Dictionary = {}
var edit_mode := false
var game_active := false
var touch_enabled := true
var auto_hide_controller := true
var controller_connected := false
var control_opacity := 0.72
var control_scale := 1.0
var theme_mode := THEME_SYSTEM
var dragging: Control = null
var pressed_actions: Dictionary = {}
var touch_owners: Dictionary = {}
var button_layout := 0
var face_event_epoch := 0
const JOY_BUTTONS := {
    # Node names retain their original Nintendo-position slots.
    "A": JOY_BUTTON_B, "B": JOY_BUTTON_A, "X": JOY_BUTTON_Y,
    "Y": JOY_BUTTON_X, "Start": JOY_BUTTON_START, "Select": JOY_BUTTON_BACK,
    "L1": JOY_BUTTON_LEFT_SHOULDER, "R1": JOY_BUTTON_RIGHT_SHOULDER
}

var android_runtime := false
var usable_rect := Rect2(0, 0, 320, 180)
var safe_area_poll := 0.0
const DESIGN_SIZE := Vector2(320, 180)

func _ready() -> void:
    android_runtime = OS.has_feature("mobile")
    if android_runtime:
        DisplayServer.screen_set_orientation(DisplayServer.SCREEN_SENSOR_LANDSCAPE)
    _create_reference_controls()
    _check_launch_control_sizes()
    _apply_default_layout()
    _load_layout()
    controller_connected = input_router.controller_connected
    input_router.controller_state_changed.connect(
        _on_controller_state_changed
    )
    if DisplayServer.is_dark_mode_supported():
        DisplayServer.set_system_theme_change_callback(
            _on_system_theme_changed
        )

    for control_name in ACTIONS:
        var button := get_node(control_name) as Control
        button.mouse_filter = Control.MOUSE_FILTER_IGNORE

    _apply_control_scale()
    _apply_nintendo_styles()
    _refresh_visibility()
    get_viewport().size_changed.connect(_refresh_display_layout)
    call_deferred("_refresh_display_layout")

func _create_reference_controls() -> void:
    for child in get_children():
        if child.name != "EditHint":
            remove_child(child)
            child.queue_free()
    for control_name in ACTIONS:
        var control := GLYPH.new()
        control.name = control_name
        control.kind = control_name
        control.caption = {"L1":"LB","R1":"RB","L2":"LT","R2":"RT"}.get(control_name,control_name)
        control.size = CONTROL_LAYOUT[control_name].size
        add_child(control)
    $EditHint.text = "DRAG CONTROLS - ANDROID BACK SAVES"
    $EditHint.add_theme_font_override("font", preload("res://assets/touch_ui/Anton-Regular.ttf"))
    $EditHint.add_theme_font_size_override("font_size", 7)
    $EditHint.add_theme_color_override("font_color", Color.WHITE)
    $EditHint.mouse_filter = Control.MOUSE_FILTER_IGNORE

func _check_launch_control_sizes() -> void:
    var available := size if size.x>0.0 and size.y>0.0 else DESIGN_SIZE
    var ratio := minf(available.x/DESIGN_SIZE.x,available.y/DESIGN_SIZE.y)
    for control_name in ACTIONS:
        (get_node(control_name) as Control).size = CONTROL_LAYOUT[control_name].size*ratio

func _process(delta: float) -> void:
    if not android_runtime: return
    safe_area_poll += delta
    if safe_area_poll >= 0.5:
        safe_area_poll = 0.0
        _refresh_display_layout()

static func safe_rect_in_canvas(screen_safe: Rect2, screen_transform: Transform2D, canvas_bounds: Rect2) -> Rect2:
    if not screen_safe.has_area(): return canvas_bounds
    var local_safe := screen_transform.affine_inverse() * screen_safe
    var clipped := canvas_bounds.intersection(local_safe)
    return clipped if clipped.has_area() else canvas_bounds

func _refresh_display_layout() -> void:
    var bounds := Rect2(Vector2.ZERO, size)
    if not bounds.has_area(): return
    if OS.has_feature("mobile"):
        var screen_transform := get_viewport().get_screen_transform() * get_global_transform_with_canvas()
        bounds = safe_rect_in_canvas(Rect2(DisplayServer.get_display_safe_area()), screen_transform, bounds)
    _apply_safe_rect(bounds)

func _apply_safe_rect(bounds: Rect2) -> void:
    if bounds.is_equal_approx(usable_rect): return
    _release_all()
    var previous := usable_rect
    usable_rect = bounds
    for control_name in ACTIONS:
        var button := get_node(control_name) as Control
        var extent := button.size * control_scale
        var fraction := (button.position - previous.position) / (previous.size - extent).max(Vector2.ONE)
        button.position = bounds.position + fraction.clamp(Vector2.ZERO, Vector2.ONE) * (bounds.size - extent).max(Vector2.ZERO)
        _clamp_button(button)
    safe_area_changed.emit(usable_rect)

func face_letter(control_name: String) -> String:
    if button_layout == 1:
        return {"A":"B", "B":"A", "X":"Y", "Y":"X"}.get(control_name, control_name)
    return control_name

func button_actions(control_name: String) -> Array:
    return ACTIONS.get(face_letter(control_name), [])

func set_button_layout(layout: int) -> void:
    layout = clampi(layout, 0, 1)
    if layout == button_layout: return
    _release_all()
    face_event_epoch += 1
    button_layout = layout
    for slot in ["A", "B", "X", "Y"]:
        get_node(slot).set_face_letter(face_letter(slot))
    _apply_nintendo_styles()

func _dispatch_virtual_button(event: InputEventJoypadButton, epoch: int) -> void:
    if event.pressed and epoch != face_event_epoch: return
    Input.parse_input_event(event)

func set_game_active(enabled: bool) -> void:
    game_active = enabled
    _refresh_visibility()

func set_touch_enabled(enabled: bool) -> void:
    touch_enabled = enabled
    _release_all()
    _save_layout()
    _refresh_visibility()

func set_auto_hide_controller(enabled: bool) -> void:
    auto_hide_controller = enabled
    _release_all()
    _save_layout()
    _refresh_visibility()

func set_control_opacity(value: float) -> void:
    control_opacity = clampf(value, 0.15, 1.0)
    _save_layout()
    _refresh_visibility()

func set_control_scale(value: float) -> void:
    var previous := control_scale
    control_scale = clampf(value, 0.65, 1.40)
    for control_name in ACTIONS:
        var control := get_node(control_name) as Control
        var center := control.position+control.size*previous*0.5
        if control_name in ["A","B","X","Y"]:
            center = Vector2(265,112)+(center-Vector2(265,112))*maxf(1.0,control_scale)/maxf(1.0,previous)
        control.position = center-control.size*control_scale*0.5
    _release_all()
    _apply_control_scale()
    _save_layout()

func set_theme_mode(value: int) -> void:
    theme_mode = clampi(value, THEME_SYSTEM, THEME_DARK)
    _apply_nintendo_styles()
    _save_layout()
    control_theme_changed.emit()

func refresh_system_theme() -> void:
    if theme_mode == THEME_SYSTEM:
        _apply_nintendo_styles()

func _on_system_theme_changed() -> void:
    if theme_mode != THEME_SYSTEM:
        return
    _apply_nintendo_styles()
    control_theme_changed.emit()

func resolved_theme_is_dark() -> bool:
    if theme_mode == THEME_DARK:
        return true
    if theme_mode == THEME_LIGHT:
        return false
    return (
        DisplayServer.is_dark_mode_supported()
        and DisplayServer.is_dark_mode()
    )

func begin_edit() -> void:
    if not android_runtime or not game_active:
        return
    edit_mode = true
    dragging = null
    $EditHint.visible = true
    input_router.set_touch_edit(true)
    _release_all()
    _refresh_visibility()

func end_edit() -> void:
    edit_mode = false
    dragging = null
    $EditHint.visible = false
    input_router.set_touch_edit(false)
    _release_all()
    _save_layout()
    _refresh_visibility()

func reset_layout() -> void:
    _release_all()
    _apply_default_layout()
    _apply_control_scale()
    _save_layout()
    _refresh_visibility()

func _on_controller_state_changed(connected: bool) -> void:
    controller_connected = connected
    _release_all()
    _refresh_visibility()

func _refresh_visibility() -> void:
    var hidden_by_controller := auto_hide_controller and controller_connected
    var should_show := android_runtime and game_active and (
        edit_mode or (touch_enabled and not hidden_by_controller)
    )
    if visible and not should_show:
        _release_all()
    visible = should_show
    mouse_filter = (
        Control.MOUSE_FILTER_PASS if visible
        else Control.MOUSE_FILTER_IGNORE
    )
    modulate.a = 1.0 if edit_mode else control_opacity

# Control GUI picking follows tree order, not drawing z_index. Route the
# visible overlay's contacts before underlying menu/world panels consume them.
func _input(event: InputEvent) -> void:
    if not is_visible_in_tree(): return
    if event is InputEventScreenTouch:
        _route_contact(event.index, event.position, event.pressed, event.canceled)
    elif event is InputEventScreenDrag:
        if touch_owners.has(event.index):
            _move_contact(event.index,event.position,event.relative)
            get_viewport().set_input_as_handled()
    elif event is InputEventMouseButton and event.device != InputEvent.DEVICE_ID_EMULATION:
        if event.button_index == MOUSE_BUTTON_LEFT:
            _route_contact(-1, event.position, event.pressed, false)
    elif event is InputEventMouseMotion and touch_owners.has(-1):
        _move_contact(-1,event.position,event.relative)
        get_viewport().set_input_as_handled()

func _move_contact(index: int, point: Vector2, relative: Vector2) -> void:
    var control_name: String = touch_owners[index]
    var control := get_node(control_name) as Control
    pointer_positions[index] = point
    if edit_mode:
        control.position += relative
        _clamp_button(control)
    elif control_name in ["LeftStick","RightStick","DPad"]:
        _update_direction(index,control_name,point)

func _update_direction(index: int, control_name: String, point: Vector2) -> void:
    var control = get_node(control_name)
    var rect: Rect2 = control.get_global_rect()
    var vector: Vector2 = ((point-rect.get_center())/(rect.size*0.5)).limit_length()
    if vector.length() < 0.18: vector = Vector2.ZERO
    if control_name == "DPad":
        vector = InputRouter.cardinal_dpad_vector(vector)
    control.stick_vector = vector
    control.held = true
    control.queue_redraw()
    if control_name != "RightStick":
        movement_contacts[index] = vector
        _send_movement()
    # The current game has no right-stick mapping; keep its analog feedback.

func _send_movement() -> void:
    var vector := Vector2.ZERO
    for contact in movement_contacts.values(): vector += contact
    # A held D-pad remains cardinal even with a second movement contact.
    for index in movement_contacts:
        if touch_owners.get(index, "") == "DPad" and movement_contacts[index] != Vector2.ZERO:
            vector = movement_contacts[index]
            break
    vector = vector.limit_length()
    for axis in [JOY_AXIS_LEFT_X,JOY_AXIS_LEFT_Y]:
        var event := InputEventJoypadMotion.new()
        event.axis = axis
        event.axis_value = vector.x if axis == JOY_AXIS_LEFT_X else vector.y
        Input.parse_input_event.call_deferred(event)

func _route_contact(index: int, point: Vector2, pressed: bool, canceled: bool) -> void:
    if not pressed or canceled:
        if not touch_owners.has(index): return
        var control_name: String = touch_owners[index]
        touch_owners.erase(index)
        pointer_positions.erase(index)
        if movement_contacts.has(index):
            movement_contacts.erase(index)
            _send_movement()
        if edit_mode:
            _save_layout()
        elif not touch_owners.values().has(control_name):
            _set_virtual_button(control_name,false)
        get_viewport().set_input_as_handled()
        return
    # Resolve overlapping padded hit areas by the nearest visible control.
    var chosen := ""
    var nearest := INF
    for control_name in ACTIONS:
        var rect: Rect2 = (get_node(control_name) as Control).get_global_rect()
        if rect.grow(2.0*control_scale).has_point(point):
            var distance := rect.get_center().distance_squared_to(point)
            if distance < nearest:
                nearest = distance
                chosen = control_name
    if chosen.is_empty(): return
    var already_held := touch_owners.values().has(chosen)
    touch_owners[index] = chosen
    pointer_positions[index] = point
    get_viewport().set_input_as_handled()
    if chosen == "Controls":
        touch_config_requested.emit.call_deferred()
        return
    if not edit_mode:
        if chosen in ["LeftStick","RightStick","DPad"]:
            _update_direction(index,chosen,point)
        elif not already_held:
            _set_virtual_button(chosen,true)

func _set_virtual_button(control_name: String, pressed: bool) -> void:
    var control = get_node(control_name)
    control.held = pressed
    if not pressed: control.stick_vector = Vector2.ZERO
    control.queue_redraw()
    if pressed:
        pressed_actions[control_name] = button_actions(control_name).duplicate()
    else:
        pressed_actions.erase(control_name)
    # Defer injection until the original pointer event has finished propagating.
    # One joypad event preserves context-sensitive dual bindings (bumper/zoom).
    if JOY_BUTTONS.has(control_name):
        var event := InputEventJoypadButton.new()
        event.button_index = JOY_BUTTONS[control_name]
        event.pressed = pressed
        _dispatch_virtual_button.call_deferred(event, face_event_epoch)
    elif control_name in ["L2", "R2"]:
        var event := InputEventJoypadMotion.new()
        event.axis = JOY_AXIS_TRIGGER_LEFT if control_name == "L2" else JOY_AXIS_TRIGGER_RIGHT
        event.axis_value = 1.0 if pressed else 0.0
        Input.parse_input_event.call_deferred(event)

func _emit_action(action: String, pressed: bool) -> void:
    var action_event := InputEventAction.new()
    action_event.action = StringName(action)
    action_event.pressed = pressed
    action_event.strength = 1.0 if pressed else 0.0
    Input.parse_input_event(action_event)

func _release_all() -> void:
    for control_name in pressed_actions.keys():
        _set_virtual_button(String(control_name), false)
    for control_name in touch_owners.values():
        var control = get_node(String(control_name))
        control.held = false
        control.stick_vector = Vector2.ZERO
        control.queue_redraw()
    touch_owners.clear()
    pointer_positions.clear()
    if not movement_contacts.is_empty():
        movement_contacts.clear()
        _send_movement()
    dragging = null

func _notification(what: int) -> void:
    if what == NOTIFICATION_APPLICATION_FOCUS_OUT or what == NOTIFICATION_APPLICATION_PAUSED:
        _release_all()

func _clamp_button(button: Control) -> void:
    var scaled_size := button.size * control_scale
    var max_pos := usable_rect.end - scaled_size
    button.position.x = clampf(button.position.x, usable_rect.position.x, maxf(usable_rect.position.x, max_pos.x))
    button.position.y = clampf(button.position.y, usable_rect.position.y, maxf(usable_rect.position.y, max_pos.y))

func _apply_default_layout() -> void:
    for control_name in CONTROL_LAYOUT:
        var button := get_node(control_name) as Control
        var extent := button.size * control_scale
        var center: Vector2 = CONTROL_LAYOUT[control_name].get_center()
        if control_name in ["A","B","X","Y"]:
            center = Vector2(265,112)+(center-Vector2(265,112))*maxf(1.0,control_scale)
        var canonical: Vector2 = center-extent*0.5
        var fraction := canonical / (DESIGN_SIZE-extent).max(Vector2.ONE)
        button.position = usable_rect.position+fraction.clamp(Vector2.ZERO,Vector2.ONE)*(usable_rect.size-extent).max(Vector2.ZERO)

func _apply_control_scale() -> void:
    for control_name in ACTIONS:
        var button := get_node(control_name) as Control
        button.pivot_offset = Vector2.ZERO
        button.scale = Vector2(control_scale, control_scale)
        _clamp_button(button)

func _apply_nintendo_styles() -> void:
    var dark := resolved_theme_is_dark()
    var face_colors := {"A":Color("#87bd27"),"B":Color("#ee583c"),"X":Color("#169cd5"),"Y":Color("#edc12c")}
    for control_name in ACTIONS:
        var control = get_node(control_name)
        control.ink = face_colors.get(face_letter(control_name),Color.WHITE)
        # White outlines/text in every theme; retain the optional surface theme.
        control.fill = Color(0.10,0.10,0.10,0.80) if dark else Color(0.10,0.10,0.10,0.45)
        control.queue_redraw()

func _save_layout() -> void:
    var cfg := ConfigFile.new()
    cfg.set_value("settings", "touch_enabled", touch_enabled)
    cfg.set_value("settings", "schema_version", SETTINGS_SCHEMA_VERSION)
    cfg.set_value("settings", "auto_hide_controller", auto_hide_controller)
    cfg.set_value("settings", "opacity", control_opacity)
    cfg.set_value("settings", "scale", control_scale)
    cfg.set_value("settings", "theme_mode", theme_mode)
    for control_name in ACTIONS:
        cfg.set_value(
            "controls", control_name,
            _canonical_position(get_node(control_name) as Control)
        )
    cfg.save(SAVE_PATH)

func _canonical_position(button: Control) -> Vector2:
    var extent := button.size * control_scale
    var fraction := (button.position - usable_rect.position) / (usable_rect.size - extent).max(Vector2.ONE)
    return fraction.clamp(Vector2.ZERO, Vector2.ONE) * (DESIGN_SIZE - extent).max(Vector2.ZERO)

func _load_layout() -> void:
    var cfg := ConfigFile.new()
    if cfg.load(SAVE_PATH) != OK:
        return
    touch_enabled = bool(cfg.get_value("settings", "touch_enabled", true))
    var saved_schema := int(cfg.get_value("settings", "schema_version", 0))
    auto_hide_controller = bool(
        cfg.get_value("settings", "auto_hide_controller", true)
    ) if saved_schema >= 3 else true
    control_opacity = clampf(float(cfg.get_value("settings", "opacity", 0.72)), 0.15, 1.0)
    control_scale = clampf(float(cfg.get_value("settings", "scale", 1.0)), 0.65, 1.40)
    theme_mode = clampi(int(cfg.get_value("settings", "theme_mode", THEME_SYSTEM)), THEME_SYSTEM, THEME_DARK)
    if saved_schema >= SETTINGS_SCHEMA_VERSION:
        for control_name in ACTIONS:
            if cfg.has_section_key("controls",control_name):
                (get_node(control_name) as Control).position = cfg.get_value("controls",control_name)
    else:
        # The replacement layout has different shapes and anchors; keep user
        # settings but migrate old positions to the requested reference layout.
        _apply_default_layout()
        _save_layout()
