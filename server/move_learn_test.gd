# The screen for a fifth move, in a real game on a throwaway data folder: a tap
# or the cursor only shows a move, a second tap or A asks "Replace X?", NO goes
# back to the same move, B gives up. Reached here from a field catch's EXP.
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
        printerr("MOVE LEARN TEST FAIL: ", what)

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

func key(action: String) -> void:
    for pressed in [true, false]:
        var event := InputEventAction.new()
        event.action = StringName(action)
        event.pressed = pressed
        Input.parse_input_event(event)
        await _frames(2)
    await _frames(2)

func choice(index: int) -> Control:
    return main.progression_choice_frame.get_node("Choice%d" % index)

func _initialize() -> void:
    var dir := OS.get_temp_dir().path_join("move_learn_test_%d" % Time.get_ticks_usec())
    DirAccess.make_dir_recursive_absolute(dir)
    FileAccess.open(dir.path_join(".private-saves-migrated"), FileAccess.WRITE).close()
    Paths.directory = dir
    change_scene_to_file("res://scenes/main.tscn")
    await _frames(30)
    main = current_scene
    while not main.startup_complete: await process_frame
    # The SOLO / CO-OP menu would take the first A.
    main.coop_menu.close()
    main.world_edit.text = "MoveTest"
    main.selected_mode = "NEW"
    main._start_game()
    var waited := 0
    while not main.started and waited < 36000:
        await process_frame
        waited += 1
    check(main.started, "the world started")
    await _frames(30)

    var old := ["DEFENSE_CURL", "TACKLE", "WATER_GUN", "BUBBLEBEAM"]
    var member: Dictionary = BattleEngine.make_pokemon("jigglypuff", 20)
    member.moves = old.duplicate()
    main.caught_pokemon.insert(0, member)
    # As after a field catch: the world takes no buttons meanwhile.
    main.field_item_busy = true
    main.world.set_gameplay_enabled(false)
    var done := [false]
    var run := func():
        await main.ball_mechanics.choose_move(0, "CHARM")
        done[0] = true
    run.call()
    await _frames(5)
    check(main.progression_mode == "MOVE_SELECT", "the move screen opens: %s" % main.progression_mode)
    check(main.progression_level_message.text.begins_with("NEW: CHARM  (JIGGLYPUFF)"), "the new move and who learns it: %s" % main.progression_level_message.text)

    # Touch: a tap on another move only shows it.
    await tap(main.progression_move_rows[2])
    check(main.progression_mode == "MOVE_SELECT" and main.progression_choice_index == 2, "a tap selects WATER GUN: %s %d" % [main.progression_mode, main.progression_choice_index])
    check(main.progression_type_label.text.contains("WATER"), "its details show: %s" % main.progression_type_label.text)
    check(main.progression_level_message.text.begins_with("NEW: CHARM"), "the new move stays in view")
    check(member.moves == old, "nothing replaced by one tap")
    # A second tap asks; NO comes back to the same move.
    await tap(main.progression_move_rows[2])
    check(main.progression_mode == "YES_NO" and main.progression_level_message.text == "Replace WATER GUN?", "a second tap asks: %s" % main.progression_level_message.text)
    check(member.moves == old, "nothing replaced before YES")
    await tap(choice(1))
    check(main.progression_mode == "MOVE_SELECT" and main.progression_choice_index == 2, "NO goes back to WATER GUN: %d" % main.progression_choice_index)
    check(member.moves == old, "NO keeps the moves")

    # Keys: the cursor only shows a move; A asks; B gives up, NO comes back.
    await key("move_down")
    check(main.progression_mode == "MOVE_SELECT" and main.progression_choice_index == 3 and main.progression_type_label.text.contains("WATER"), "the cursor shows BUBBLEBEAM")
    await key("cancel")
    check(main.progression_mode == "MOVE_GIVEUP", "B asks to give up: %s" % main.progression_mode)
    await key("move_down")
    await key("confirm")
    check(main.progression_mode == "MOVE_SELECT" and main.progression_choice_index == 3, "NO to giving up comes back to BUBBLEBEAM")
    await key("confirm")
    check(main.progression_mode == "YES_NO" and main.progression_level_message.text == "Replace BUBBLEBEAM?", "A asks: %s" % main.progression_level_message.text)
    check(member.moves == old, "nothing replaced before YES")
    await key("confirm")
    await _frames(5)
    check(done[0], "YES closes the screen")
    check(member.moves == ["DEFENSE_CURL", "TACKLE", "WATER_GUN", "CHARM"], "YES replaces BUBBLEBEAM: %s" % [member.moves])
    check(not main.progression_active and not main.progression_overlay.visible, "back to the world")

    # Giving up: the moves stay.
    var kept: Array = member.moves.duplicate()
    done[0] = false
    var run2 := func():
        await main.ball_mechanics.choose_move(0, "SING")
        done[0] = true
    run2.call()
    await _frames(5)
    await key("cancel")
    await tap(choice(0))
    await _frames(5)
    check(done[0] and member.moves == kept, "giving up keeps the moves: %s" % [member.moves])
    check(not main.progression_active, "and returns to the world")

    print("MOVE LEARN TEST: %d checks, %d failed" % [checks, failed])
    quit(1 if failed > 0 else 0)
