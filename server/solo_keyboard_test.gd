# A finger tap on SOLO (title screen) must not start typing a name: the same
# touch used to reach the hidden classic WORLD NAME field under the touch setup
# screen, which opened the phone keyboard. A tap on the name field still does.
# Run: godot --headless --path project -s <this file> -- --touch-ui
extends SceneTree

const Paths = preload("res://scripts/game_data_paths.gd")

var main: Node
var checks := 0
var failed := 0

func check(ok: bool, what: String) -> void:
    checks += 1
    if not ok:
        failed += 1
        printerr("SOLO KEYBOARD TEST FAIL: ", what)

func _frames(count: int) -> void:
    for i in count: await process_frame

## A finger down and up at a point of the viewport, as the phone sends it
## (Godot also emulates the mouse from it, as on the phone).
func tap(point: Vector2, frames_between: int) -> void:
    for pressed in [true, false]:
        var touch := InputEventScreenTouch.new()
        touch.position = root.get_final_transform() * point
        touch.pressed = pressed
        Input.parse_input_event(touch)
        await _frames(frames_between)
    await _frames(3)

func centre(control: Control) -> Vector2:
    return control.get_global_transform_with_canvas() * (control.size / 2.0)

## Where a finger may land on a control: its corners (2 px in) and its centre.
func spots(control: Control) -> Array:
    var out := [centre(control)]
    for x in [2.0, control.size.x - 2.0]:
        for y in [2.0, control.size.y - 2.0]:
            out.append(control.get_global_transform_with_canvas() * Vector2(x, y))
    return out

func focused_line_edit() -> bool:
    return main.get_viewport().gui_get_focus_owner() is LineEdit

func _initialize() -> void:
    create_timer(300.0).timeout.connect(func(): printerr("SOLO KEYBOARD TEST FAIL: timed out"); quit(2))
    var dir := OS.get_temp_dir().path_join("solo_keyboard_test_%d" % Time.get_ticks_usec())
    DirAccess.make_dir_recursive_absolute(dir)
    FileAccess.open(dir.path_join(".private-saves-migrated"), FileAccess.WRITE).close()
    Paths.directory = dir
    change_scene_to_file("res://scenes/main.tscn")
    await _frames(30)
    main = current_scene
    while not main.startup_complete: await process_frame
    await _frames(10)
    main.touch_controls.android_runtime = true
    check(main.touch_ui.enabled, "the touch UI is on (--touch-ui)")
    check(ProjectSettings.get_setting("input_devices/pointing/emulate_mouse_from_touch", true), "touch emulates the mouse, as on the phone")

    # Anywhere on SOLO, same-frame and slower taps, in both remembered modes.
    var solo: Control = main.coop_menu.title_rows[0]
    for mode in ["NEW", "LOAD"]:
        for between in [0, 2]:
            for spot in spots(solo):
                main._finish_text_entry(false)
                main.selected_mode = mode
                main.coop_menu.open()
                await _frames(4)
                check(solo.is_visible_in_tree(), "SOLO shows on the title")
                await tap(spot, between)
                var what := "%s at %s, %d frames between press and release" % [mode, spot, between]
                check(not main.coop_menu.visible and main.setup_panel.visible, "SOLO opened the setup (%s)" % what)
                check(main.text_entry_target == "", "tapping SOLO began no name entry (%s): %s" % [what, main.text_entry_target])
                check(not focused_line_edit(), "tapping SOLO focused no LineEdit (%s)" % what)

    # A deliberate tap on the world name still opens the keyboard.
    main.selected_mode = "NEW"
    main._update_classic_menu_labels()
    await _frames(3)
    var screen: Control = main.touch_ui.surfaces.setup_screen
    check(screen.visible and screen.world_field.is_visible_in_tree(), "the touch setup screen shows the world name")
    await tap(centre(screen.world_field), 2)
    check(main.text_entry_target == "world", "tapping the world name begins its entry: '%s'" % main.text_entry_target)
    await tap(centre(screen.world_field), 2)
    check(main.text_entry_target == "", "tapping it again ends the entry")
    await tap(centre(screen.player_field), 2)
    check(main.text_entry_target == "player", "tapping the trainer name begins its entry: '%s'" % main.text_entry_target)
    check(not focused_line_edit(), "no LineEdit took focus")

    print("SOLO KEYBOARD TEST: %d checks, %d failed" % [checks, failed])
    quit(1 if failed > 0 else 0)
