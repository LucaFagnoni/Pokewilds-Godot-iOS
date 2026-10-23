extends RefCounted

## The game (START) menu: its options, the GUIDE, the SAVE question and the
## quit prompt (with its save before quitting).
## Split out of main.gd; reaches the game through `main`.

const GameOptions = preload("res://scripts/game_options.gd")

var main: GameMain
var pokemon_action_panel: Panel
var pokemon_action_entries: Array[String] = []
var item_menu_active := false
var teleport_destination_index := 0
var quit_prompt_stage := 0 # 0 = quit?, 1 = save before quit?

func _init(owner_main: GameMain) -> void:
    main = owner_main

func open_game_menu() -> void:
    if main.battle_active or main.generating or not main.started or \
            (main.field_item_busy and not main.bag_menu.sleeping_bag_active()):
        return
    main.game_menu_open = true
    main.game_menu_detail_open = false
    main.pokemon_menu_open = false
    main.pokemon_action_open = false
    main.pokemon_switch_selecting = false
    pokemon_action_panel.visible = false
    main.guide_menu_open = false
    main.guide_topic_open = false
    main.pokemon_menu_index = 0
    main.save_confirm_open = false
    main.save_confirm_index = 0
    main.save_confirm.visible = false
    main.game_menu_index = 0
    main.game_menu.visible = true
    main.game_menu_box.visible = true
    main.game_menu_detail.visible = false
    main.game_menu_map_screen.visible = false
    main.item_pocket_menu.visible = false
    main.item_pocket_context = ""
    main.pokemon_menu.visible = false
    main.guide_menu.visible = false
    main.world.set_gameplay_enabled(false)
    main.touch_controls.set_game_active(true)
    main.message_panel.visible = false
    update_game_menu_cursor()

func close_game_menu() -> void:
    main.planting_bag_target = null
    main.bag_notice = ""
    main.game_menu_open = false
    main.game_menu_detail_open = false
    main.pokemon_menu_open = false
    main.pokemon_action_open = false
    main.pokemon_switch_selecting = false
    main.pokemon_switch_source_index = -1
    pokemon_action_panel.visible = false
    main.pokemon_stats_open = false
    main.pokemon_stats_overlay.visible = false
    main.guide_menu_open = false
    main.guide_topic_open = false
    main.save_confirm_open = false
    main.save_confirm.visible = false
    main.game_menu.visible = false
    main.game_menu_detail.visible = false
    item_menu_active = false
    main.item_pocket_context = ""
    main.battle_item_pocket_open = false
    main.item_pocket_menu.visible = false
    main.pokemon_menu.visible = false
    main.guide_menu.visible = false
    main.game_menu_map.visible = false
    main.game_menu_map_screen.visible = false
    main.minimap.clear_map_canvas()
    main.world.set_gameplay_enabled(not main.bag_menu.sleeping_bag_active())
    main.touch_controls.set_game_active(true)

func handle_game_menu_input(event: InputEvent) -> void:
    if not main.overworld_evolution_item.is_empty():
        main.bag_menu.handle_evolution_item_input(event)
        return
    if main.item_pocket_context == "OVERWORLD" and main.battle_item_pocket_open:
        main.bag_menu.handle_overworld_item_pocket_input(event)
        return

    if main.guide_topic_open:
        if event.is_action_pressed("confirm") or event.is_action_pressed("cancel") or event.is_action_pressed("start"):
            main.guide_topic_open = false
            main.game_menu_detail_open = false
            main.game_menu_detail.visible = false
            main.guide_menu.visible = true
            main.get_viewport().set_input_as_handled()
        return

    if main.guide_menu_open:
        if event.is_action_pressed("move_up"):
            main.guide_menu_index = wrapi(main.guide_menu_index - 1, 0, main.GUIDE_TOPICS.size())
            _refresh_guide_menu()
            main.get_viewport().set_input_as_handled()
        elif event.is_action_pressed("move_down"):
            main.guide_menu_index = wrapi(main.guide_menu_index + 1, 0, main.GUIDE_TOPICS.size())
            _refresh_guide_menu()
            main.get_viewport().set_input_as_handled()
        elif event.is_action_pressed("confirm"):
            _show_selected_guide_topic()
            main.get_viewport().set_input_as_handled()
        elif event.is_action_pressed("cancel") or event.is_action_pressed("start"):
            main.guide_menu_open = false
            main.guide_menu.visible = false
            main.game_menu_box.visible = true
            main.get_viewport().set_input_as_handled()
        return

    if main.pokemon_menu_open:
        if main.pokemon_action_open:
            if event.is_action_pressed("move_up"):
                main.pokemon_action_index = wrapi(main.pokemon_action_index - 1, 0,
                    pokemon_action_entries.size())
                main.party_menu.refresh_pokemon_action_menu()
            elif event.is_action_pressed("move_down"):
                main.pokemon_action_index = wrapi(main.pokemon_action_index + 1, 0,
                    pokemon_action_entries.size())
                main.party_menu.refresh_pokemon_action_menu()
            elif event.is_action_pressed("confirm"):
                main.party_menu.activate_pokemon_action()
            elif event.is_action_pressed("cancel") or event.is_action_pressed("start"):
                main.party_menu.close_pokemon_action_menu()
            else:
                return
            main.get_viewport().set_input_as_handled()
            return
        if event.is_action_pressed("move_up"):
            if not main.caught_pokemon.is_empty():
                main.pokemon_menu_index = wrapi(main.pokemon_menu_index - 1, 0,
                    mini(6, main.caught_pokemon.size()))
                main.party_menu.refresh_pokemon_category_menu()
            main.get_viewport().set_input_as_handled()
        elif event.is_action_pressed("move_down"):
            if not main.caught_pokemon.is_empty():
                main.pokemon_menu_index = wrapi(main.pokemon_menu_index + 1, 0,
                    mini(6, main.caught_pokemon.size()))
                main.party_menu.refresh_pokemon_category_menu()
            main.get_viewport().set_input_as_handled()
        elif main.pokemon_switch_selecting and event.is_action_pressed("confirm"):
            main.party_menu.finish_pokemon_switch()
            main.get_viewport().set_input_as_handled()
        elif event.is_action_pressed("cancel") or event.is_action_pressed("start"):
            if main.pokemon_switch_selecting:
                main.pokemon_switch_selecting = false
                main.pokemon_switch_source_index = -1
                main.pokemon_menu_prompt.text = "Choose a POKEMON."
            else:
                main.pokemon_menu_open = false
                main.pokemon_menu.visible = false
                main.game_menu_box.visible = true
            main.get_viewport().set_input_as_handled()
        elif event.is_action_pressed("confirm"):
            main.party_menu.open_pokemon_action_menu()
            main.get_viewport().set_input_as_handled()
        return

    if main.save_confirm_open:
        if event.is_action_pressed("move_left") or event.is_action_pressed("move_right"):
            main.save_confirm_index = 1 - main.save_confirm_index
            update_save_confirm_cursor()
            main.get_viewport().set_input_as_handled()
        elif event.is_action_pressed("confirm"):
            if main.save_confirm_index == 0:
                main._save_current_game()
            else:
                close_save_confirmation()
            main.get_viewport().set_input_as_handled()
        elif event.is_action_pressed("cancel") or event.is_action_pressed("start"):
            close_save_confirmation()
            main.get_viewport().set_input_as_handled()
        return

    if event.is_action_pressed("start") or event.is_action_pressed("cancel"):
        if main.game_menu_detail_open:
            item_menu_active = false
            main.game_menu_detail_open = false
            main.game_menu_detail.visible = false
            main.game_menu_box.visible = true
            main.game_menu_map.visible = false
            main.game_menu_map_screen.visible = false
            main.teleport_map_mode = false
            main.teleport_destinations.clear()
            main.minimap.clear_map_canvas()
        else:
            close_game_menu()
        main.get_viewport().set_input_as_handled()
        return

    if main.game_menu_detail_open:
        if main.game_menu_map_screen.visible:
            if main.teleport_map_mode:
                if event.is_action_pressed("move_left") or event.is_action_pressed("move_up") or event.is_action_pressed("shoulder_left"):
                    main.minimap.cycle_teleport_destination(-1)
                    main.get_viewport().set_input_as_handled()
                elif event.is_action_pressed("move_right") or event.is_action_pressed("move_down") or event.is_action_pressed("shoulder_right"):
                    main.minimap.cycle_teleport_destination(1)
                    main.get_viewport().set_input_as_handled()
                elif event.is_action_pressed("confirm"):
                    if main.world.has_method("teleport_to_destination"):
                        main.world.call("teleport_to_destination", teleport_destination_index)
                    main.teleport_map_mode = false
                    close_game_menu()
                    main.get_viewport().set_input_as_handled()
                return
            if event.is_action_pressed("confirm") and is_instance_valid(main.waypoint_ui):
                main.waypoint_ui.begin_name()
                main.get_viewport().set_input_as_handled()
                return
            if GameOptions.enabled("zoom") and (event.is_action_pressed("zoom_in") or event.is_action_pressed("shoulder_right")):
                main.minimap.set_map_zoom(main.map_zoom * 1.25)
                main.get_viewport().set_input_as_handled()
            elif GameOptions.enabled("zoom") and (event.is_action_pressed("zoom_out") or event.is_action_pressed("shoulder_left")):
                main.minimap.set_map_zoom(main.map_zoom / 1.25)
                main.get_viewport().set_input_as_handled()
            return
        if event.is_action_pressed("confirm"):
            main.game_menu_detail_open = false
            main.game_menu_detail.visible = false
            main.game_menu_box.visible = true
            main.game_menu_map.visible = false
            main.game_menu_map_screen.visible = false
            main.minimap.clear_map_canvas()
            main.get_viewport().set_input_as_handled()
        return

    if event.is_action_pressed("move_up"):
        main.game_menu_index = wrapi(main.game_menu_index - 1, 0, main.GAME_MENU_OPTIONS.size())
        update_game_menu_cursor()
        main.get_viewport().set_input_as_handled()
    elif event.is_action_pressed("move_down"):
        main.game_menu_index = wrapi(main.game_menu_index + 1, 0, main.GAME_MENU_OPTIONS.size())
        update_game_menu_cursor()
        main.get_viewport().set_input_as_handled()
    elif event.is_action_pressed("confirm"):
        activate_game_menu_option()
        main.get_viewport().set_input_as_handled()

func update_game_menu_cursor() -> void:
    var row := main.game_menu_box.get_node_or_null("Option%d" % main.game_menu_index) as Label
    if row != null: main._align_menu_tick(main.game_menu_cursor, row)

func activate_game_menu_option() -> void:
    var option = String(main.GAME_MENU_OPTIONS[main.game_menu_index])
    match option:
        "STORAGE":
            main.storage.open_pooled_storage_menu()
        "POKEMON":
            main.party_menu.show_pokemon_menu()
        "ITEM":
            main.bag_menu.show_item_menu()
        "MAP":
            main.minimap.show_map_menu()
        "POKEDEX":
            main.pokedex_menu.open(true)
        "GUIDE":
            _show_guide_menu()
        "OPTIONS":
            main.options_menu.open()
        "SAVE":
            _open_save_confirmation()
        "EXIT":
            close_game_menu()
            open_quit_prompt()

func _open_detail(title: String, body: String) -> void:
    main.game_menu_detail_open = true
    main.game_menu_box.visible = false
    main.game_menu_detail.visible = true
    main.game_menu_detail_title.text = title
    main.game_menu_detail_body.text = body
    main.game_menu_map.visible = false
    main.game_menu_map_screen.visible = false

func _show_guide_menu() -> void:
    main.guide_menu_open = true
    main.guide_topic_open = false
    main.guide_menu_index = 0
    main.game_menu_box.visible = false
    main.game_menu_detail.visible = false
    main.guide_menu.visible = true
    _refresh_guide_menu()

func _refresh_guide_menu() -> void:
    var window_start := maxi(0, main.guide_menu_index - 3)
    window_start = mini(
        window_start, maxi(0, main.GUIDE_TOPICS.size() - main.guide_menu_rows.size())
    )
    for row in range(main.guide_menu_rows.size()):
        var topic_index := window_start + row
        main.guide_menu_rows[row].text = (
            String((main.GUIDE_TOPICS[topic_index] as Dictionary).get("name", ""))
            if topic_index < main.GUIDE_TOPICS.size()
            else ""
        )
    var visible_row := main.guide_menu_index - window_start
    main._align_menu_tick(main.guide_menu_cursor, main.guide_menu_rows[visible_row])
    main.guide_menu_up_arrow.visible = window_start > 0
    main.guide_menu_down_arrow.visible = (
        window_start + main.guide_menu_rows.size() < main.GUIDE_TOPICS.size()
    )

func _show_selected_guide_topic() -> void:
    var topic: Dictionary = main.GUIDE_TOPICS[main.guide_menu_index]
    main.guide_menu.visible = false
    main.guide_topic_open = true
    main.game_menu_detail_open = true
    main.game_menu_detail.visible = true
    main.game_menu_detail_title.text = String(topic.get("name", "GUIDE"))
    main.game_menu_detail_body.text = String(topic.get("body", ""))
    main.game_menu_map.visible = false
    main.game_menu_map_screen.visible = false

func _open_save_confirmation() -> void:
    main.save_confirm_open = true
    main.save_confirm_index = 0
    main.game_menu_box.visible = false
    main.game_menu_detail.visible = false
    main.save_confirm.visible = true
    update_save_confirm_cursor()

func close_save_confirmation() -> void:
    main.save_confirm_open = false
    main.save_confirm.visible = false
    main.game_menu_box.visible = true

func update_save_confirm_cursor() -> void:
    # Reference layout: YES on the left, NO on the right.
    if main.save_confirm_index == 0:
        main.save_confirm_cursor.position = Vector2(22.0, 57.0)
    else:
        main.save_confirm_cursor.position = Vector2(134.0, 57.0)
    main._align_menu_tick(main.save_confirm_cursor, main.save_confirm.get_node("Yes" if main.save_confirm_index == 0 else "No"))

func open_quit_prompt() -> void:
    if main.generating or main.field_item_busy:
        return
    if main.field_move_wheel_open:
        main.move_wheel.close_field_move_wheel(false)
    main.quit_prompt_open = true
    quit_prompt_stage = 0
    main.quit_prompt_index = 0
    main.quit_prompt_title.text = "QUIT GAME?" if _app_can_quit() else "EXIT TO TITLE?"
    main.quit_prompt.visible = true
    if main.started:
        main.world.set_gameplay_enabled(false)
        main.touch_controls.set_game_active(true)
    update_quit_prompt_cursor()

func _close_quit_prompt() -> void:
    main.quit_prompt_open = false
    main.quit_prompt.visible = false
    if main.started:
        main.world.set_gameplay_enabled(true)
        main.touch_controls.set_game_active(true)

func update_quit_prompt_cursor() -> void:
    if main.quit_prompt_index == 0:
        main.quit_prompt_cursor.position = Vector2(32.0, 52.0)
    else:
        main.quit_prompt_cursor.position = Vector2(134.0, 52.0)
    main._align_menu_tick(main.quit_prompt_cursor, main.quit_prompt.get_node("Yes" if main.quit_prompt_index == 0 else "No"))

func handle_quit_prompt_input(event: InputEvent) -> void:
    if event.is_action_pressed("move_left") or event.is_action_pressed("move_right"):
        main.quit_prompt_index = 1 - main.quit_prompt_index
        update_quit_prompt_cursor()
        main.get_viewport().set_input_as_handled()
        return

    if event.is_action_pressed("cancel"):
        _close_quit_prompt()
        main.get_viewport().set_input_as_handled()
        return

    if event.is_action_pressed("confirm"):
        if quit_prompt_stage == 0:
            if main.quit_prompt_index == 1:
                _close_quit_prompt()
            else:
                # User confirmed quit. Ask whether to save before leaving.
                quit_prompt_stage = 1
                main.quit_prompt_index = 0
                main.quit_prompt_title.text = "SAVE BEFORE QUIT?" if _app_can_quit() else "SAVE BEFORE EXIT?"
                update_quit_prompt_cursor()
        else:
            if main.quit_prompt_index == 0:
                var saved_ok = await _save_current_game_for_quit()
                if not saved_ok:
                    main.quit_prompt_title.text = "SAVE FAILED"
                    quit_prompt_stage = 0
                    main.quit_prompt_index = 1
                    update_quit_prompt_cursor()
                    return
            if not _app_can_quit():
                # iOS apps may not close themselves: go back to the title screen.
                main.get_tree().reload_current_scene()
                return
            main.set_process_input(false)
            await main.shared_save_folder.export_files(main)
            main.get_tree().quit()
        main.get_viewport().set_input_as_handled()

func _app_can_quit() -> bool:
    return OS.get_name() != "iOS" and not OS.get_cmdline_user_args().has("--no-app-quit")

func _save_current_game_for_quit() -> bool:
    main._sync_pokedex_owned()
    if not main.started:
        return true
    if main.coop_game.active:
        return await main.coop_game.save_game(main._capture_game_save(3))

    # Same record as the SAVE menu (the old hand-built one dropped egg/friendship
    # timers and ecology ids).
    var error: Error = await main._write_single_player_save(main._capture_game_save())
    if error != OK:
        return false
    main.world.call("play_source_sound", "save1")
    return true

func _start_menu_context_available() -> bool:
    return main.started and not main.generating and not main.battle_active and not main.battle_entry_pending and not main.game_menu_open \
        and not main.wild_pokemon_prompt_open and not main.egg_pickup_open and not main.storage_menu_open \
        and not main.trainer_tip_open and not main.setup_load_open and not main.pokemon_stats_open \
        and not main.touch_config.visible and not main.touch_controls.edit_mode and not main.progression_active \
        and not main.field_move_wheel_open and not main.quit_prompt_open and not main.build_menu_open \
        and not main.craft_menu_open and (not main.field_item_busy or main.bag_menu.sleeping_bag_active()) \
        and not (is_instance_valid(main.game_files_menu) and main.game_files_menu.visible) \
        and not (is_instance_valid(main.mod_menu_panel) and main.mod_menu_panel.visible)

func queue_start_menu(event: InputEvent) -> void:
    # Start opens the ordinary menu immediately on physical and touch controls.
    if event is InputEventJoypadButton and event.button_index == JOY_BUTTON_START:
        if main.start_menu_held:
            return
        main.start_menu_held = true
    if _start_menu_context_available():
        open_game_menu()
