# The touch surfaces are cached (touch_surfaces.gd, touch_setup_screen.gd): every
# frame, in every screen below, the cached surface must equal a fresh one, and the
# idle-field shortcut of refresh_visuals must leave what a full refresh leaves.
# Run: godot --headless --path project -s ../server/touch_surface_cache_test.gd -- --touch-ui
extends SceneTree

const Paths = preload("res://scripts/game_data_paths.gd")

var main: Node
var checks := 0
var failed := 0

func check(ok: bool, what: String) -> void:
    checks += 1
    if not ok:
        failed += 1
        printerr("TOUCH CACHE TEST FAIL: ", what)

func _frames(count: int) -> void:
    for i in count: await process_frame

## Everything a surface offers, minus the Callables themselves (their presence counts).
func shape(surface: Dictionary) -> Dictionary:
    var out := {}
    for key in surface:
        var value = surface[key]
        if value is Callable:
            out[key] = true
        elif value is Array and key in ["buttons", "hotspots"]:
            out[key] = (value as Array).map(func(entry): return [entry[0], entry[2], entry[1] is Callable])
        else:
            out[key] = value
    return out

func visuals() -> Array:
    var s = main.touch_ui.surfaces
    var tabs: Control = s.bag_tabs
    return [s.backdrop.visible, s.backdrop.color, s.start_menu.visible, s.setup_screen.visible,
        s.move_cards.visible, tabs.visible if is_instance_valid(tabs) else null,
        main.setup_panel.modulate.a, main.game_menu_box.modulate.a, main.battle_move_box.modulate.a,
        main.battle_move_type_box.modulate.a, main.item_pocket_label.modulate.a, main.build_panel.get_node("Hint").visible]

## One frame in `where`: cached == fresh, and the shortcut == a full refresh.
func compare(where: String) -> void:
    var s = main.touch_ui.surfaces
    var cached := shape(s.build())
    s.use_cache = false
    s.setup_screen.use_cache = false
    var fresh := shape(s.build())
    s.use_cache = true
    s.setup_screen.use_cache = true
    check(cached == fresh, "%s: cached %s != fresh %s" % [where, cached, fresh])
    # With the shortcut in effect, a full refresh must leave everything as it is.
    if s.idle_passes >= 2:
        var before := visuals()
        s.idle_passes = 0
        s.refresh_visuals(0.0)
        s.refresh_visuals(0.0)
        check(before == visuals(), "%s: shortcut visuals %s != full %s" % [where, before, visuals()])

func run(where: String, frames: int = 3) -> void:
    for i in frames:
        await process_frame
        compare(where)

func _initialize() -> void:
    var dir := OS.get_temp_dir().path_join("touch_cache_test_%d" % Time.get_ticks_usec())
    DirAccess.make_dir_recursive_absolute(dir)
    FileAccess.open(dir.path_join(".private-saves-migrated"), FileAccess.WRITE).close()
    Paths.directory = dir
    change_scene_to_file("res://scenes/main.tscn")
    await _frames(30)
    main = current_scene
    while not main.startup_complete: await process_frame
    main.coop_menu.close()
    await _frames(5)
    var setup = main.touch_ui.surfaces.setup_screen
    await run("setup NEW")
    check(main.touch_ui.surfaces.setup_screen.visible, "the setup screen shows")
    main.selected_mode = "LOAD"
    main._update_classic_menu_labels()
    await run("setup LOAD, no saves")
    var entry := {"data": {"world_name": "A", "player_name": "x", "world_size": 1, "caught_pokemon": []}, "path": "user://none"}
    setup.saves.assign([entry, entry, entry, entry, entry])
    setup.saves_loaded = true
    setup.saves_signature = []
    await run("setup LOAD, five saves")
    setup.load_scroll = 2
    setup.saves_signature = []
    await run("setup LOAD, scrolled")
    setup._trash(2)
    await run("setup LOAD, bin armed")
    main.selected_mode = "NEW"
    main._update_classic_menu_labels()
    await run("setup NEW again")
    main._begin_text_entry("world")
    await run("setup, typing")
    main._finish_text_entry(true)
    await run("setup, typed")
    root.size = Vector2i(900, 400)
    await run("setup, resized", 4)
    root.size = Vector2i(640, 360)

    main.world_edit.text = "CacheTest"
    main._start_game()
    var waited := 0
    while not main.started and waited < 36000:
        await process_frame
        waited += 1
    check(main.started, "the world started")
    await _frames(60)
    var s = main.touch_ui.surfaces
    await run("field")
    check(not s.build().is_empty(), "the field has a surface")
    var clock: Control = main.status_hud.clock_chip
    var map: Control = main.m3924_minimap_root
    map.hide()
    await run("field, minimap hidden")
    map.show()
    await run("field, minimap back")
    if is_instance_valid(clock):
        clock.position += Vector2(7, 3)
        await run("field, clock moved")
        clock.hide()
        await run("field, clock hidden")
        clock.show()
    root.size = Vector2i(900, 400)
    await run("field, resized", 4)
    root.size = Vector2i(640, 360)
    await run("field, resized back", 3)
    var helper: Dictionary = BattleEngine.make_pokemon("smeargle", 20)
    for move in ["DIG", "CUT", "BUILD", "PAINT"]:
        main.world.clear_active_field_move()
        main.world.active_field_pokemon = helper
        main.world.active_field_species = "smeargle"
        main.world.active_field_move = move
        # The world drops a move that has no helper out on the next frame: look at once.
        compare("field, %s" % move)
        var chips: Array = s.build().get("buttons", [])
        check(chips.size() >= 1 and String(chips[0][0]) == "STOP " + move, "%s: STOP chip %s" % [move, chips])
        if move in ["BUILD", "PAINT", "DIG"]:
            check(chips.size() == 4, "%s: value chips %s" % [move, chips])
    main.world.active_field_move = "DIG"
    for index in 3:
        main.world.dig_selection_index = index
        compare("field, DIG choice %d" % index)
    main.world.dig_selection_index = 0
    main.world.clear_active_field_move()
    await run("field, move done")
    check(s.idle_passes >= 2, "the idle field is applied")

    main._open_game_menu()
    await run("start menu", 5)
    check(s.idle_passes == 0 and s.start_menu.visible, "the start menu leaves the idle shortcut")
    main._close_game_menu()
    await run("field after the menu", 5)
    check(s.idle_passes >= 2 and not s.start_menu.visible and not s.backdrop.visible, "back to the idle field")

    main._start_battle_context({"id": "wild", "kind": "wild", "can_run": true, "can_catch": true,
        "party": [{"species": "rattata", "level": 3}]})
    var guard := 0
    while not main.battle_active and guard < 600:
        await process_frame
        guard += 1
    await run("battle intro", 20)
    guard = 0
    while String(main.battle_ui_mode) != "COMMAND" and guard < 1500:
        if main.battle_text_busy: main._finish_battle_text()
        else: main.touch_ui.press("confirm")
        await _frames(3)
        guard += 1
    await run("battle commands", 5)
    check(String(main.battle_ui_mode) == "COMMAND", "battle reached COMMAND: %s" % main.battle_ui_mode)

    print("TOUCH CACHE TEST: %d checks, %d failed" % [checks, failed])
    quit(1 if failed > 0 else 0)
