# OPTIONS > BATTERY and CLOCK in a real game on a throwaway data folder: the HUD
# in the top left, the options and game.ini, a tap on the clock, and the battery
# as the iOS plugin reports it (set here with OS.set_environment).
# Run: godot --headless --path project -s <this file> -- --touch-ui
extends SceneTree

const Paths = preload("res://scripts/game_data_paths.gd")
const Settings = preload("res://scripts/game_options.gd")
const StatusHud = preload("res://scripts/status_hud.gd")

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

    # Desktop: no battery to read, so no battery and no BATTERY option.
    check(hud.root != null and hud.root.visible, "the HUD shows in the field")
    check(hud.clock.visible and not hud.battery.visible, "clock only, without a battery")
    var now := Time.get_time_dict_from_system()
    check(hud.clock.text in ["%02d:%02d" % [now.hour, now.minute], "%02d:%02d" % [now.hour, (now.minute + 59) % 60]], "real time: %s" % hud.clock.text)
    var minimap: Control = main.m3924_minimap_root
    check(minimap.visible and is_equal_approx(hud.root.position.x, minimap.position.x + minimap.size.x + 4), "right of the minimap: %s" % hud.root.position)
    main._open_game_menu()
    main.options_menu.open()
    check(main.options_menu.all_rows.any(func(row): return row[0] == "clock"), "CLOCK is an option")
    check(not main.options_menu.all_rows.any(func(row): return row[0] == "battery_hud"), "no BATTERY option without a battery")
    await _frames(2)
    check(not hud.root.visible, "hidden under the menus")
    main.options_menu.close()
    main._close_game_menu()
    await _frames(5)
    check(hud.root.visible, "back after the menus")

    # A tap on the clock: game time, in gold, saved; a second tap: real time.
    await tap(hud.clock)
    check(int(Settings.values.clock) == StatusHud.CLOCK_GAME and int(saved("clock")) == StatusHud.CLOCK_GAME, "a tap switches to game time and saves it")
    var minutes: int = main.world.clock_minutes()
    check(hud.clock.text == "%02d:%02d" % [minutes / 60, minutes % 60], "game time %s is the world's %d" % [hud.clock.text, minutes])
    check(hud.clock.get_theme_color("font_color") == StatusHud.GAME_CLOCK_COLOR, "game time is gold")
    await tap(hud.clock)
    check(int(Settings.values.clock) == StatusHud.CLOCK_REAL, "a second tap is real time again")

    # The battery as the iOS plugin reports it: 57%, charging.
    OS.set_environment(StatusHud.BATTERY_ENV, "57,2")
    hud.update()
    check(hud.battery.visible and hud.percent.text == "57%", "battery 57%%: %s" % hud.percent.text)
    check(hud.battery_fill.size.x == 6.0 and hud.battery_fill.color == StatusHud.CHARGING_COLOR, "green fill 6 px while charging")
    OS.set_environment(StatusHud.BATTERY_ENV, "15,1")
    hud.update()
    check(hud.battery_fill.color == StatusHud.LOW_BATTERY_COLOR, "red when low")
    OS.set_environment(StatusHud.BATTERY_ENV, "-1,0")
    hud.update()
    check(not hud.battery.visible, "an unknown level shows no battery")
    OS.set_environment(StatusHud.BATTERY_ENV, "80,1")
    main._open_game_menu()
    main.options_menu.open()
    check(main.options_menu.all_rows.any(func(row): return row[0] == "battery_hud"), "BATTERY is an option on a phone")
    main.options_menu.close()
    main._close_game_menu()

    # Both off: nothing shows; the choice survives a restart (game.ini read again).
    check(Settings.change("battery_hud", false) == OK and Settings.change("clock", 0) == OK, "options saved")
    await _frames(3)
    check(not hud.root.visible, "nothing shows with both off")
    Settings.loaded = false
    Settings.values = Settings.DEFAULTS.duplicate()
    Settings.load_settings()
    check(Settings.values.battery_hud == false and int(Settings.values.clock) == 0, "the options persist: %s %s" % [Settings.values.battery_hud, Settings.values.clock])
    Settings.change("clock", StatusHud.CLOCK_GAME)
    await _frames(3)
    check(hud.root.visible and hud.clock.visible and not hud.battery.visible, "game clock alone")

    print("STATUS HUD TEST: %d checks, %d failed" % [checks, failed])
    quit(1 if failed > 0 else 0)
