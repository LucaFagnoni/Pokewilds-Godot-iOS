class_name InputRouter
extends Node

signal controller_state_changed(connected: bool)
signal touch_edit_changed(enabled: bool)

var touch_edit_mode := false
var controller_connected := false
var diagonal_enabled := true
var auto_run_enabled := false
# Godot reports physical face-button positions in Xbox order.
var button_layout := 1
const FACE_SWAP := {JOY_BUTTON_A:JOY_BUTTON_B, JOY_BUTTON_B:JOY_BUTTON_A, JOY_BUTTON_X:JOY_BUTTON_Y, JOY_BUTTON_Y:JOY_BUTTON_X}

func _ready() -> void:
    _install_default_actions()
    Input.joy_connection_changed.connect(_on_joy_connection_changed)
    controller_connected = Input.get_connected_joypads().size() > 0

func _install_default_actions() -> void:
    # Keyboard mapping matches PokeWilds desktop semantics:
    # Z=A/Confirm, X=B/Cancel and Run, Enter=Start, A/C=L/R.
    _ensure_key_action("move_left", KEY_LEFT)
    _ensure_key_action("move_right", KEY_RIGHT)
    _ensure_key_action("move_up", KEY_UP)
    _ensure_key_action("move_down", KEY_DOWN)
    _ensure_key_action("confirm", KEY_Z)
    _ensure_key_action("cancel", KEY_X)
    _ensure_key_action("run", KEY_X)
    _ensure_key_action("start", KEY_ENTER)
    _ensure_key_action("quit_menu", KEY_ESCAPE)
    _ensure_action("touch_config")
    _ensure_key_action("shoulder_left", KEY_C)
    _ensure_key_action("shoulder_right", KEY_V)
    _ensure_key_action("battle_catch", KEY_V)
    _ensure_key_action("build_menu", KEY_Y)
    _ensure_key_action("pokedex", KEY_P)
    _ensure_action("map_open")
    _ensure_action("field_move_wheel", 0.20)
    _ensure_mouse_button_action("zoom_in", MOUSE_BUTTON_WHEEL_UP)
    _ensure_mouse_button_action("zoom_out", MOUSE_BUTTON_WHEEL_DOWN)

    # Remove every old assignment for the controls whose jobs are exact. This
    # prevents saved/project mappings from making Select act like Android Back
    # or leaving old shoulder/trigger jobs active beside the requested ones.
    _remove_joy_button_from_all(JOY_BUTTON_Y)
    _remove_joy_button_from_all(JOY_BUTTON_BACK)
    _remove_joy_button_from_all(JOY_BUTTON_LEFT_SHOULDER)
    _remove_joy_button_from_all(JOY_BUTTON_RIGHT_SHOULDER)
    _remove_joy_axis_from_all(JOY_AXIS_TRIGGER_LEFT)
    _remove_joy_axis_from_all(JOY_AXIS_TRIGGER_RIGHT)

    # Standard Android/Godot controller mapping. Android system Back is not an
    # InputMap button; main.gd handles its window notification independently.
    _ensure_joy_button("confirm", 0)       # A / Cross
    _ensure_joy_button("cancel", 1)        # B / Circle
    _ensure_joy_button("start", 6)         # Start -> Enter/in-game menu
    _ensure_joy_button("map_open", JOY_BUTTON_BACK) # Controller Select -> map
    _ensure_joy_button("run", 2)           # X / Square
    _ensure_joy_button("pokedex", JOY_BUTTON_Y)
    # The bumpers zoom in gameplay/map views and
    # retain their directional menu actions only inside menus that consume them.
    _ensure_joy_button("shoulder_left", JOY_BUTTON_LEFT_SHOULDER)
    _ensure_joy_button("shoulder_right", JOY_BUTTON_RIGHT_SHOULDER)
    _ensure_joy_button("zoom_out", JOY_BUTTON_LEFT_SHOULDER)
    _ensure_joy_button("zoom_in", JOY_BUTTON_RIGHT_SHOULDER)
    # L2 retains the field/build wheel. The optional ball system owns R2.
    _ensure_joy_axis("field_move_wheel", JOY_AXIS_TRIGGER_LEFT, 1.0)
    _ensure_joy_axis("ball_mechanics", JOY_AXIS_TRIGGER_RIGHT, 1.0)
    _ensure_joy_button("move_up", 11)
    _ensure_joy_button("move_down", 12)
    _ensure_joy_button("move_left", 13)
    _ensure_joy_button("move_right", 14)
    _ensure_joy_axis("move_left", 0, -1.0)
    _ensure_joy_axis("move_right", 0, 1.0)
    _ensure_joy_axis("move_up", 1, -1.0)
    _ensure_joy_axis("move_down", 1, 1.0)
    _ensure_joy_axis("map_pan_left", JOY_AXIS_RIGHT_X, -1.0)
    _ensure_joy_axis("map_pan_right", JOY_AXIS_RIGHT_X, 1.0)
    _ensure_joy_axis("map_pan_up", JOY_AXIS_RIGHT_Y, -1.0)
    _ensure_joy_axis("map_pan_down", JOY_AXIS_RIGHT_Y, 1.0)

func set_button_layout(layout: int) -> void:
    layout = clampi(layout, 0, 1)
    if layout == button_layout: return
    # Change only face-button events, retaining keys, axes, device filters and
    # all Start/Select/shoulder bindings. Clear held actions before remapping.
    for action in InputMap.get_actions():
        var replacements: Array = []
        for event in InputMap.action_get_events(action):
            if event is InputEventJoypadButton and FACE_SWAP.has(event.button_index):
                Input.action_release(action)
                var replacement: InputEventJoypadButton = event.duplicate()
                replacement.button_index = FACE_SWAP[event.button_index]
                replacements.append([event, replacement])
        for pair in replacements: InputMap.action_erase_event(action, pair[0])
        for pair in replacements: InputMap.action_add_event(action, pair[1])
    button_layout = layout

func face_button_name(button: int) -> String:
    var names := ["B", "A", "Y", "X"] if button_layout == 0 else ["A", "B", "X", "Y"]
    return names[button] if button >= 0 and button < names.size() else ""

func _ensure_action(action: StringName, deadzone := 0.35) -> void:
    if not InputMap.has_action(action):
        InputMap.add_action(action, deadzone)

func _ensure_key_action(action: StringName, keycode: Key) -> void:
    _ensure_action(action)
    var ev := InputEventKey.new()
    ev.physical_keycode = keycode
    InputMap.action_add_event(action, ev)

func _ensure_joy_button(action: StringName, button_index: int) -> void:
    _ensure_action(action)
    var ev := InputEventJoypadButton.new()
    ev.button_index = button_index
    InputMap.action_add_event(action, ev)

func _ensure_joy_axis(action: StringName, axis: int, value: float) -> void:
    _ensure_action(action)
    var ev := InputEventJoypadMotion.new()
    ev.axis = axis
    ev.axis_value = value
    InputMap.action_add_event(action, ev)

func _remove_joy_button_from_all(button_index: int) -> void:
    for action in InputMap.get_actions():
        for event in InputMap.action_get_events(action):
            if event is InputEventJoypadButton and \
                    (event as InputEventJoypadButton).button_index == button_index:
                InputMap.action_erase_event(action, event)

func _remove_joy_axis_from_all(axis_index: int) -> void:
    for action in InputMap.get_actions():
        for event in InputMap.action_get_events(action):
            if event is InputEventJoypadMotion and \
                    (event as InputEventJoypadMotion).axis == axis_index:
                InputMap.action_erase_event(action, event)

func _ensure_mouse_button_action(
        action: StringName,
        button_index: MouseButton
    ) -> void:
    _ensure_action(action)
    var ev := InputEventMouseButton.new()
    ev.button_index = button_index
    InputMap.action_add_event(action, ev)

func _on_joy_connection_changed(_device: int, _connected: bool) -> void:
    controller_connected = Input.get_connected_joypads().size() > 0
    controller_state_changed.emit(controller_connected)

func set_touch_edit(enabled: bool) -> void:
    if touch_edit_mode == enabled:
        return
    touch_edit_mode = enabled
    touch_edit_changed.emit(enabled)

func toggle_touch_edit() -> void:
    set_touch_edit(not touch_edit_mode)

func movement_vector() -> Vector2:
    # Gameplay only: leave the shared menu InputMap bindings untouched.
    var movement := Input.get_vector("move_left", "move_right", "move_up", "move_down").normalized()
    if movement == Vector2.ZERO:
        return Vector2.ZERO
    for device in _movement_devices():
        var dpad := Vector2(
            int(Input.is_joy_button_pressed(device, JOY_BUTTON_DPAD_RIGHT)) - int(Input.is_joy_button_pressed(device, JOY_BUTTON_DPAD_LEFT)),
            int(Input.is_joy_button_pressed(device, JOY_BUTTON_DPAD_DOWN)) - int(Input.is_joy_button_pressed(device, JOY_BUTTON_DPAD_UP)))
        if dpad != Vector2.ZERO:
            return cardinal_dpad_vector(dpad)
    return movement if diagonal_enabled else cardinal_dpad_vector(movement)

func _movement_devices() -> PackedInt32Array:
    return Input.get_connected_joypads()

static func cardinal_dpad_vector(direction: Vector2) -> Vector2:
    if maxf(absf(direction.x), absf(direction.y)) <= 0.30:
        return Vector2.ZERO
    if absf(direction.x) > absf(direction.y):
        return Vector2(signf(direction.x), 0.0)
    return Vector2(0.0, signf(direction.y))

func is_running() -> bool:
    return auto_run_enabled or Input.is_action_pressed("run")
