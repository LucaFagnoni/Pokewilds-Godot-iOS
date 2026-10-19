class_name TouchControls
extends Control

@onready var input_router: InputRouter = get_node("/root/InputRouterSingleton")

signal control_theme_changed
signal touch_config_requested
signal safe_area_changed(bounds: Rect2)

const SAVE_PATH := "user://touch_layout_m43.cfg"
const SETTINGS_SCHEMA_VERSION := 11
const THEME_SYSTEM := 0
const THEME_LIGHT := 1
const THEME_DARK := 2

# Each touch button emits the same InputMap action as its physical control.
# One stick drives movement (and the radial wheels); the D-pad duplicated it
# and the right stick had no game mapping, so both were dropped.
# MOSSE (L2) and LANCIO (R2) replace the triggers; touch settings live in OPTIONS.
const ACTIONS := {
    "LeftStick": [],
    # B also runs while held (see _set_virtual_button); the Pokedex lives in the menu.
    "A": ["confirm"], "B": ["cancel"],
    "Start": ["start"],
    "L1": ["shoulder_left"], "L2": ["field_move_wheel"],
    "R1": ["shoulder_right"], "R2": ["ball_mechanics"]
}
# Bumpers only page menus/wheels; in free roam zoom is a pinch, so they hide.
const SHOULDERS := ["L1", "R1"]
const PINCH_STEP := 1.2
# Baseline dimensions are fractions of the usable 320x180 game canvas.
# Everything hugs the edges so the field around the player stays clear.
const FACE_CENTER := Vector2(285,134)
# Dragging from MOSSE/LANCIO steers the wheel, like the stick did.
const WHEEL_BUTTONS := ["L2", "R2"]
const WHEEL_DRAG_DEADZONE := 0.35
const CANCEL_TAP_MSEC := 350
const CONTROL_LAYOUT := {
    "LeftStick": Rect2(14,122,44,44),
    # Right thumb arc: A largest, B below-left, MOSSE and LANCIO above.
    "A": Rect2(287,116,28,28),
    "B": Rect2(253,140,26,26),
    "L2": Rect2(250,102,24,24),
    "R2": Rect2(290,78,26,26),
    # Wheel pages: on the left, free while the right thumb steers the wheel.
    "L1": Rect2(12,94,24,18),
    "R1": Rect2(40,94,24,18),
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
# Per-button size on top of control_scale, set by pinching in edit mode.
var control_factors: Dictionary = {}
const FACTOR_RANGE := Vector2(0.6, 1.8)
const EDIT_GRID := 8.0
var edit_grid: Control
var edit_pinch: Dictionary = {}
var theme_mode := THEME_SYSTEM
var dragging: Control = null
var pressed_actions: Dictionary = {}
var touch_owners: Dictionary = {}
var button_layout := 0
var face_event_epoch := 0
var shoulders_visible := true
# Touch-driven menus (touch_ui.gd) take the whole screen; the pad steps aside.
var menu_hidden := false
var stick_home := Vector2.ZERO
var floating_stick_index := -1
var wheel_drag_index := -1
var throw_icon_poll := 0.0
var cancel_down_msec := -100000
var pinch_points: Dictionary = {}
var pinch_base := 0.0
const JOY_BUTTONS := {
    # Node names retain their original Nintendo-position slots.
    "A": JOY_BUTTON_B, "B": JOY_BUTTON_A, "Start": JOY_BUTTON_START,
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
        control.caption = {"L1":"LB","R1":"RB","L2":"MOSSE","R2":"LANCIO"}.get(control_name,control_name)
        control.size = CONTROL_LAYOUT[control_name].size
        add_child(control)
    $EditHint.text = "DRAG TO MOVE  -  PINCH TO RESIZE  -  DONE TO SAVE"
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
    throw_icon_poll -= delta
    if throw_icon_poll <= 0.0 and visible:
        throw_icon_poll = 0.4
        _refresh_throw_icon()
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
        var extent := button.size * scale_of(control_name)
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
    for slot in ["A", "B"]:
        get_node(slot).set_face_letter(face_letter(slot))
    _apply_nintendo_styles()

func _dispatch_virtual_button(event: InputEventJoypadButton, epoch: int) -> void:
    if event.pressed and epoch != face_event_epoch: return
    Input.parse_input_event(event)

func set_shoulders_visible(enabled: bool) -> void:
    enabled = enabled or edit_mode
    if enabled == shoulders_visible: return
    shoulders_visible = enabled
    for control_name in SHOULDERS:
        get_node(control_name).visible = enabled
        if enabled: continue
        for index in touch_owners.keys():
            if touch_owners[index] == control_name: touch_owners.erase(index)
        if pressed_actions.has(control_name): _set_virtual_button(control_name, false)

func set_menu_hidden(hidden: bool) -> void:
    if hidden == menu_hidden: return
    menu_hidden = hidden
    _refresh_visibility()

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
        var center := control.position+control.size*previous*float(control_factors.get(control_name,1.0))*0.5
        if control_name in ["A","B","X","Y"]:
            center = FACE_CENTER+(center-FACE_CENTER)*maxf(1.0,control_scale)/maxf(1.0,previous)
        control.position = center-control.size*scale_of(control_name)*0.5
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

func _update_edit_pinch() -> void:
    var a: Vector2 = pointer_positions.get(edit_pinch.indices[0], Vector2.ZERO)
    var b: Vector2 = pointer_positions.get(edit_pinch.indices[1], Vector2.ZERO)
    var factor := clampf(float(edit_pinch.factor) * a.distance_to(b) / float(edit_pinch.distance), FACTOR_RANGE.x, FACTOR_RANGE.y)
    var control := get_node(String(edit_pinch.target)) as Control
    var center := control.position + control.size * scale_of(control.name) * 0.5
    control_factors[String(edit_pinch.target)] = factor
    control.scale = Vector2.ONE * scale_of(control.name)
    control.position = center - control.size * scale_of(control.name) * 0.5
    _clamp_button(control)

func _snap_to_grid(control: Control) -> void:
    var center := control.position + control.size * scale_of(control.name) * 0.5
    var origin := usable_rect.position
    center = origin + ((center - origin) / EDIT_GRID).round() * EDIT_GRID
    control.position = center - control.size * scale_of(control.name) * 0.5
    _clamp_button(control)

func scale_of(control_name: String) -> float:
    return control_scale * float(control_factors.get(control_name, 1.0))

func _show_edit_grid(show: bool) -> void:
    if edit_grid == null:
        edit_grid = Control.new()
        edit_grid.name = "EditGrid"
        edit_grid.mouse_filter = Control.MOUSE_FILTER_IGNORE
        edit_grid.show_behind_parent = true
        edit_grid.draw.connect(func():
            var area := usable_rect
            var colour := Color(1, 1, 1, 0.18)
            var x := area.position.x
            while x <= area.end.x:
                edit_grid.draw_line(Vector2(x, area.position.y), Vector2(x, area.end.y), colour, 1.0)
                x += EDIT_GRID
            var y := area.position.y
            while y <= area.end.y:
                edit_grid.draw_line(Vector2(area.position.x, y), Vector2(area.end.x, y), colour, 1.0)
                y += EDIT_GRID)
        add_child(edit_grid)
        move_child(edit_grid, 0)
    edit_grid.size = size
    edit_grid.visible = show
    edit_grid.queue_redraw()

func begin_edit() -> void:
    if not android_runtime or not game_active:
        return
    edit_mode = true
    dragging = null
    edit_pinch.clear()
    _show_edit_grid(true)
    # Under the DONE button, not behind it.
    $EditHint.position = Vector2(usable_rect.get_center().x - $EditHint.size.x * 0.5, usable_rect.position.y + 28)
    $EditHint.visible = true
    input_router.set_touch_edit(true)
    _release_all()
    _refresh_visibility()

func end_edit() -> void:
    edit_mode = false
    dragging = null
    edit_pinch.clear()
    _show_edit_grid(false)
    $EditHint.visible = false
    input_router.set_touch_edit(false)
    _release_all()
    _save_layout()
    _refresh_visibility()

func reset_layout() -> void:
    _release_all()
    control_factors.clear()
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
        edit_mode or (touch_enabled and not hidden_by_controller and not menu_hidden)
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
        if not event.pressed or event.canceled:
            pinch_points.erase(event.index)
        elif not touch_owners.has(event.index) and not edit_mode:
            pinch_points[event.index] = event.position
        pinch_base = 0.0
    elif event is InputEventScreenDrag:
        if touch_owners.has(event.index):
            _move_contact(event.index,event.position,event.relative)
            get_viewport().set_input_as_handled()
        elif pinch_points.has(event.index):
            pinch_points[event.index] = event.position
            _update_pinch()
    elif event is InputEventMouseButton and event.device != InputEvent.DEVICE_ID_EMULATION:
        if event.button_index == MOUSE_BUTTON_LEFT:
            _route_contact(-1, event.position, event.pressed, false)
    elif event is InputEventMouseMotion and touch_owners.has(-1):
        _move_contact(-1,event.position,event.relative)
        get_viewport().set_input_as_handled()

# Two free fingers (not on a control) zoom in steps, like the old bumpers did.
func _update_pinch() -> void:
    if pinch_points.size() != 2: return
    var points := pinch_points.values()
    var distance: float = points[0].distance_to(points[1])
    if pinch_base <= 0.0:
        pinch_base = distance
        return
    var ratio := distance / maxf(pinch_base, 1.0)
    if ratio >= PINCH_STEP or ratio <= 1.0 / PINCH_STEP:
        pinch_base = distance
        var action := "zoom_in" if ratio > 1.0 else "zoom_out"
        _emit_action.call_deferred(action, true)
        _emit_action.call_deferred(action, false)

func _move_contact(index: int, point: Vector2, relative: Vector2) -> void:
    var control_name: String = touch_owners[index]
    var control := get_node(control_name) as Control
    pointer_positions[index] = point
    if edit_mode and not edit_pinch.is_empty() and index in edit_pinch.indices:
        _update_edit_pinch()
        return
    if edit_mode:
        control.position += relative
        _clamp_button(control)
    elif control_name in ["LeftStick","RightStick","DPad"]:
        _update_direction(index,control_name,point)
    elif control_name in WHEEL_BUTTONS and index == wheel_drag_index:
        _steer_wheel(control, point)

## Dragging away from a held MOSSE/LANCIO picks a wedge, so one thumb does it all.
func _steer_wheel(control: Control, point: Vector2) -> void:
    var rect := control.get_global_rect()
    var vector := ((point - rect.get_center()) / (rect.size * 1.2)).limit_length()
    if vector.length() < WHEEL_DRAG_DEADZONE: return
    for axis in [JOY_AXIS_LEFT_X, JOY_AXIS_LEFT_Y]:
        var event := InputEventJoypadMotion.new()
        event.axis = axis
        event.axis_value = vector.x if axis == JOY_AXIS_LEFT_X else vector.y
        Input.parse_input_event.call_deferred(event)

func _end_wheel_steer() -> void:
    wheel_drag_index = -1
    # The wheel reads its wedge when the trigger lifts; centre the stick afterwards.
    await get_tree().create_timer(0.08).timeout
    _send_movement()

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
        if index == floating_stick_index:
            floating_stick_index = -1
            (get_node("LeftStick") as Control).position = stick_home
        if index == wheel_drag_index:
            _end_wheel_steer.call_deferred()
        if edit_mode:
            if not edit_pinch.is_empty() and index in edit_pinch.indices:
                edit_pinch.clear()
            else:
                _snap_to_grid(get_node(control_name) as Control)
            _save_layout()
        elif not touch_owners.values().has(control_name):
            _set_virtual_button(control_name,false)
        get_viewport().set_input_as_handled()
        return
    # Resolve overlapping padded hit areas by the nearest visible control.
    var chosen := ""
    var nearest := INF
    for control_name in ACTIONS:
        if not (get_node(control_name) as Control).visible: continue
        var rect: Rect2 = (get_node(control_name) as Control).get_global_rect()
        if rect.grow(2.0*control_scale).has_point(point):
            var distance := rect.get_center().distance_squared_to(point)
            if distance < nearest:
                nearest = distance
                chosen = control_name
    if edit_mode and not touch_owners.is_empty() and edit_pinch.is_empty():
        # A second finger while one holds a button: pinch that button's size.
        var held_index: int = touch_owners.keys()[0]
        var target: String = touch_owners[held_index]
        touch_owners[index] = target
        pointer_positions[index] = point
        edit_pinch = {"target": target, "indices": [held_index, index],
            "distance": maxf(1.0, Vector2(pointer_positions[held_index]).distance_to(point)),
            "factor": float(control_factors.get(target, 1.0))}
        get_viewport().set_input_as_handled()
        return
    if chosen.is_empty() and not edit_mode and _in_floating_stick_zone(point):
        # The stick jumps under the thumb anywhere in the lower-left area.
        var stick := get_node("LeftStick") as Control
        if not touch_owners.values().has("LeftStick"):
            stick_home = stick.position
            floating_stick_index = index
            stick.position = point - stick.size * scale_of("LeftStick") * 0.5
            chosen = "LeftStick"
    if chosen.is_empty(): return
    if not edit_mode and preload("res://scripts/touch_ui.gd").haptics_on(): Input.vibrate_handheld(8, 0.3)
    var already_held := touch_owners.values().has(chosen)
    touch_owners[index] = chosen
    pointer_positions[index] = point
    get_viewport().set_input_as_handled()
    if chosen in WHEEL_BUTTONS and not edit_mode: wheel_drag_index = index
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
    if button_actions(control_name) == ["cancel"]:
        # Hold to run, quick tap to cancel: a held B never lands a FLY by accident.
        _emit_action.call_deferred("run", pressed)
        if pressed:
            cancel_down_msec = Time.get_ticks_msec()
            return
        # A long hold only means "run" while the player can move; resting in a
        # sleeping bag, on a stool or in a paused scene, B always cancels.
        var main := get_tree().current_scene
        var can_move: bool = main != null and is_instance_valid(main.get("world")) and bool(main.world.gameplay_enabled)
        if can_move and Time.get_ticks_msec() - cancel_down_msec > CANCEL_TAP_MSEC: return
        for state in [true, false]:
            var tap := InputEventJoypadButton.new()
            tap.button_index = JOY_BUTTONS[control_name]
            tap.pressed = state
            _dispatch_virtual_button.call_deferred(tap, face_event_epoch)
        return
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

func _in_floating_stick_zone(point: Vector2) -> bool:
    var stick := get_node("LeftStick") as Control
    if not stick.visible: return false
    var zone := Rect2(usable_rect.position + Vector2(0, usable_rect.size.y * 0.4),
        Vector2(usable_rect.size.x * 0.42, usable_rect.size.y * 0.6))
    return zone.has_point(point)

func _release_all() -> void:
    if floating_stick_index >= 0:
        floating_stick_index = -1
        (get_node("LeftStick") as Control).position = stick_home
    wheel_drag_index = -1
    cancel_down_msec = -100000  # Releasing everything is not a B tap.
    for control_name in pressed_actions.keys():
        _set_virtual_button(String(control_name), false)
    for control_name in touch_owners.values():
        var control = get_node(String(control_name))
        control.held = false
        control.stick_vector = Vector2.ZERO
        control.queue_redraw()
    touch_owners.clear()
    pointer_positions.clear()
    pinch_points.clear()
    if not movement_contacts.is_empty():
        movement_contacts.clear()
        _send_movement()
    dragging = null

func _notification(what: int) -> void:
    if what == NOTIFICATION_APPLICATION_FOCUS_OUT or what == NOTIFICATION_APPLICATION_PAUSED:
        _release_all()

func _clamp_button(button: Control) -> void:
    var scaled_size := button.size * scale_of(String(button.name))
    var max_pos := usable_rect.end - scaled_size
    button.position.x = clampf(button.position.x, usable_rect.position.x, maxf(usable_rect.position.x, max_pos.x))
    button.position.y = clampf(button.position.y, usable_rect.position.y, maxf(usable_rect.position.y, max_pos.y))

func _apply_default_layout() -> void:
    for control_name in CONTROL_LAYOUT:
        var button := get_node(control_name) as Control
        var extent := button.size * scale_of(control_name)
        var center: Vector2 = CONTROL_LAYOUT[control_name].get_center()
        if control_name in ["A","B","X","Y"]:
            center = FACE_CENTER+(center-FACE_CENTER)*maxf(1.0,control_scale)
        var canonical: Vector2 = center-extent*0.5
        var fraction := canonical / (DESIGN_SIZE-extent).max(Vector2.ONE)
        button.position = usable_rect.position+fraction.clamp(Vector2.ZERO,Vector2.ONE)*(usable_rect.size-extent).max(Vector2.ZERO)

func _apply_control_scale() -> void:
    for control_name in ACTIONS:
        var button := get_node(control_name) as Control
        button.pivot_offset = Vector2.ZERO
        button.scale = Vector2.ONE * scale_of(control_name)
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
    cfg.set_value("settings", "factors", control_factors)
    cfg.set_value("settings", "theme_mode", theme_mode)
    for control_name in ACTIONS:
        cfg.set_value(
            "controls", control_name,
            _canonical_position(get_node(control_name) as Control)
        )
    cfg.save(SAVE_PATH)

func _canonical_position(button: Control) -> Vector2:
    var extent := button.size * scale_of(String(button.name))
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
    var saved_factors = cfg.get_value("settings", "factors", {})
    control_factors = saved_factors if saved_factors is Dictionary else {}
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

func _refresh_throw_icon() -> void:
    var main := get_tree().current_scene
    var mechanics = main.get("ball_mechanics") if main != null else null
    var icon: Texture2D = null
    if is_instance_valid(mechanics) and main.started:
        var member: Dictionary = mechanics.party_member()
        if not member.is_empty():
            icon = main._field_move_wheel_icon(str(member.get("species","")), PokemonData.is_shiny(member), str(member.get("form","")))
        else:
            var ball := str(mechanics.state().get("ball", ""))
            if int(main.inventory.get(ball, 0)) <= 0:
                var balls: Array = mechanics.bag_balls()
                ball = str(balls[0]) if not balls.is_empty() else ""
            if not ball.is_empty(): icon = mechanics.ball_texture(ball)
    var glyph = get_node("R2")
    if glyph.icon != icon:
        glyph.icon = icon
        glyph.queue_redraw()
