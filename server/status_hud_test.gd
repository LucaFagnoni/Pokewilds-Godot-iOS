# OPTIONS > BATTERY and CLOCK in a real game on a throwaway data folder: the
# clock at the top centre, the battery top right, the options and game.ini, a
# tap on the clock, and the battery as the iOS plugin reports it (set here with
# OS.set_environment).
# Run: godot --headless --path project -s <this file> -- --touch-ui
extends SceneTree

const Paths = preload("res://scripts/game_data_paths.gd")
const Settings = preload("res://scripts/game_options.gd")
const StatusHud = preload("res://scripts/status_hud.gd")
const Hud = preload("res://scripts/hud_style.gd")

var main: Node
var hud
var checks := 0
var failed := 0

func check(ok: bool, what: String) -> void:
    checks += 1
    if not ok:
        failed += 1
        printerr("STATUS HUD TEST FAIL: ", what)

func _frames(count: int) -> void:
    for i in count: await process_frame

func tap(control: Control) -> void:
    var at: Vector2 = root.get_final_transform() * (control.get_global_transform_with_canvas() * (control.size / 2.0))
    for pressed in [true, false]:
        var touch := InputEventScreenTouch.new()
        touch.position = at
        touch.pressed = pressed
        Input.parse_input_event(touch)
        await _frames(2)
    await _frames(3)

func saved(key: String) -> Variant:
    var cfg := ConfigFile.new()
    cfg.load(Settings.PATH)
    return cfg.get_value("options", key)

func _initialize() -> void:
    var dir := OS.get_temp_dir().path_join("status_hud_test_%d" % Time.get_ticks_usec())
    DirAccess.make_dir_recursive_absolute(dir)
    FileAccess.open(dir.path_join(".private-saves-migrated"), FileAccess.WRITE).close()
    Paths.directory = dir

    var bad := ConfigFile.new()
    bad.set_value("options", "clock", 7)
    check(int(Settings._validated(bad).clock) == 2, "a clock past GAME is clamped")
    check(Settings.DEFAULTS.battery_hud == true and Settings.DEFAULTS.clock == StatusHud.CLOCK_REAL, "on by default, real time")

    change_scene_to_file("res://scenes/main.tscn")
    await _frames(30)
    main = current_scene
    while not main.startup_complete: await process_frame
    hud = main.status_hud
    main.world_edit.text = "HudTest"
    main.selected_mode = "NEW"
    main._start_game()
    var waited := 0
    while not main.started and waited < 36000:
        await process_frame
        waited += 1
    check(main.started, "the world started")
    await _frames(30)

    var safe: Rect2 = main.touch_controls.usable_rect
    var top: float = safe.position.y + Hud.MARGIN
    var screen: Vector2 = main.get_viewport().get_visible_rect().size

    # Desktop: no battery to read, so no battery and no BATTERY option.
    check(hud.clock_chip.visible and not hud.battery_chip.visible, "clock only, without a battery")
    var now := Time.get_time_dict_from_system()
    var shown: String = hud.clock_chip.get_node("Text").text
    check(shown in ["%02d:%02d" % [now.hour, now.minute], "%02d:%02d" % [now.hour, (now.minute + 59) % 60]], "real time: %s" % shown)
    # One top line, MARGIN under the safe area: minimap at the left, clock at the centre.
    var chip: Rect2 = hud.clock_chip.get_global_rect()
    check(absf(chip.get_center().x - screen.x / 2.0) <= 0.5 and chip.position.y == top and chip.size.y == Hud.ROW, "the clock is at the top centre: %s on %s" % [chip, screen])
    var minimap: Rect2 = main.minimap_root.get_global_rect()
    check(minimap.position == Vector2(safe.position.x + Hud.MARGIN, top), "the minimap in the top left corner: %s" % minimap)
    check(Settings.change("fps_counter", true) == OK, "FPS counter on")
    await _frames(3)
    var fps: Rect2 = hud.fps_chip.get_global_rect()
    check(hud.fps_chip.visible and fps.position.y == top and is_equal_approx(fps.end.x, safe.end.x - Hud.MARGIN), "the FPS counter at the top right: %s" % fps)
    main._open_game_menu()
    main.options_menu.open()
    check(main.options_menu.all_rows.any(func(row): return row[0] == "clock"), "CLOCK is an option")
    check(not main.options_menu.all_rows.any(func(row): return row[0] == "battery_hud"), "no BATTERY option without a battery")
    await _frames(2)
    check(not hud.clock_chip.visible and not hud.fps_chip.visible, "the menus hide the top row")
    main.options_menu.close()
    main._close_game_menu()
    await _frames(5)
    check(hud.clock_chip.visible, "back after the menus")

    # A tap on the clock: game time, with a sun or moon, saved; a second tap: real time.
    await tap(hud.clock_chip)
    check(int(Settings.values.clock) == StatusHud.CLOCK_GAME and int(saved("clock")) == StatusHud.CLOCK_GAME, "a tap switches to game time and saves it")
    # The chip ticks once a second and a game minute lasts a quarter of one, so it
    # may be up to four game minutes behind the world when read a few frames on.
    var minutes: int = main.world.clock_minutes()
    shown = hud.clock_chip.get_node("Text").text
    var shown_minutes := int(shown.get_slice(":", 0)) * 60 + int(shown.get_slice(":", 1).strip_edges())
    check(posmod(minutes - shown_minutes, 1440) <= 4, "game time %s is the world's %d" % [shown, minutes])
    check(hud.clock_chip.get_node("Sun").visible, "game time shows a sun or moon")
    await tap(hud.clock_chip)
    check(int(Settings.values.clock) == StatusHud.CLOCK_REAL and not hud.clock_chip.get_node("Sun").visible, "a second tap is real time again")

    # The battery as the iOS plugin reports it: 57%, charging.
    OS.set_environment(StatusHud.BATTERY_ENV, "57,2")
    hud.update()
    await _frames(2)
    var percent: Label = hud.battery_chip.get_node("Text")
    check(hud.battery_chip.visible and percent.text == "57%", "battery 57%%: %s" % percent.text)
    # The icon and the digits' ink share the chip's middle line, PAD from both ends.
    var icon: Control = hud.battery_fill.get_parent()
    check(is_equal_approx(icon.position.y + StatusHud.BATTERY.y / 2.0, Hud.ROW / 2.0) and is_equal_approx(percent.position.y + Hud.INK_CENTRE, Hud.ROW / 2.0), "icon and percentage on one line")
    check(is_equal_approx(icon.position.x, Hud.PAD) and is_equal_approx(hud.battery_chip.size.x - Hud.PAD, percent.position.x + Hud.FONT.get_string_size("57%", HORIZONTAL_ALIGNMENT_LEFT, -1, Hud.FONT_SIZE).x), "the same padding on both sides")
    # The right end of the line, right to left: (menu,) battery, FPS, GAP apart.
    var battery: Rect2 = hud.battery_chip.get_global_rect()
    fps = hud.fps_chip.get_global_rect()
    check(battery.position.y == top and is_equal_approx(battery.end.x, safe.end.x - Hud.MARGIN), "battery at the top right: %s" % battery)
    check(fps.position.y == top and is_equal_approx(fps.end.x, battery.position.x - Hud.GAP), "FPS left of the battery: %s" % fps)
    check(not battery.intersects(chip) and not fps.intersects(chip), "the right end clear of the clock")
    check(hud.battery_fill.size.x == 6.0 and hud.battery_fill.color == StatusHud.CHARGING_COLOR, "green fill 6 px while charging")
    OS.set_environment(StatusHud.BATTERY_ENV, "15,1")
    hud.update()
    check(hud.battery_fill.color == StatusHud.LOW_BATTERY_COLOR, "red when low")
    OS.set_environment(StatusHud.BATTERY_ENV, "-1,0")
    hud.update()
    check(not hud.battery_chip.visible, "an unknown level shows no battery")
    OS.set_environment(StatusHud.BATTERY_ENV, "80,1")
    main._open_game_menu()
    main.options_menu.open()
    check(main.options_menu.all_rows.any(func(row): return row[0] == "battery_hud"), "BATTERY is an option on a phone")
    main.options_menu.close()
    main._close_game_menu()

    # The on-screen buttons' default layout on the same grid, in a notched safe area.
    var pad = main.touch_controls
    pad._apply_safe_rect(Rect2(Vector2(27, 0), pad.size - Vector2(54, 10)))
    pad._apply_default_layout()
    safe = pad.usable_rect
    var at := func(control_name: String) -> Rect2: return pad.get_node(control_name).get_global_rect()
    check(at.call("A").end == safe.end - Vector2(Hud.MARGIN, Hud.MARGIN), "A in the bottom right corner: %s in %s" % [at.call("A"), safe])
    check(is_equal_approx(at.call("B").end.x, at.call("A").position.x - Hud.GAP) and at.call("B").end.y == at.call("A").end.y, "B beside A on the bottom line")
    check(is_equal_approx(at.call("R2").end.y, at.call("A").position.y - Hud.GAP) and is_equal_approx(at.call("R2").get_center().x, at.call("A").get_center().x), "LANCIO over A")
    check(is_equal_approx(at.call("L2").end.y, at.call("B").position.y - Hud.GAP) and is_equal_approx(at.call("L2").get_center().x, at.call("B").get_center().x), "MOSSE over B")
    check(at.call("LeftStick").position.x == safe.position.x + Hud.MARGIN and at.call("LeftStick").end.y == at.call("A").end.y, "the stick in the bottom left corner, on A's line")
    check(at.call("Start").position.y == safe.position.y + Hud.MARGIN and at.call("Start").end.x == safe.end.x - Hud.MARGIN and at.call("Start").size == Vector2(Hud.ROW, Hud.ROW), "the menu button ends the top row")
    # Another safe area (the phone turned round, another model) keeps every margin.
    pad._apply_safe_rect(Rect2(Vector2(20, 0), pad.size - Vector2(40, 9)))
    safe = pad.usable_rect
    check(at.call("A").end == safe.end - Vector2(Hud.MARGIN, Hud.MARGIN) and at.call("LeftStick").position.x == safe.position.x + Hud.MARGIN, "margins hold when the safe area changes")

    # Both off: nothing shows; the choice survives a restart (game.ini read again).
    check(Settings.change("battery_hud", false) == OK and Settings.change("clock", 0) == OK, "options saved")
    await _frames(3)
    check(not hud.clock_chip.visible and not hud.battery_chip.visible, "nothing shows with both off")
    Settings.loaded = false
    Settings.values = Settings.DEFAULTS.duplicate()
    Settings.load_settings()
    check(Settings.values.battery_hud == false and int(Settings.values.clock) == 0, "the options persist: %s %s" % [Settings.values.battery_hud, Settings.values.clock])
    Settings.change("clock", StatusHud.CLOCK_GAME)
    await _frames(3)
    check(hud.clock_chip.visible and not hud.battery_chip.visible, "game clock alone")

    print("STATUS HUD TEST: %d checks, %d failed" % [checks, failed])
    quit(1 if failed > 0 else 0)
