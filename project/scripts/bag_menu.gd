extends RefCounted

## The ITEM bag of the game menu outside battle: its pockets, using an item
## (evolution stones on a chosen Pokemon, the planting bag, the sleeping bag's
## rest), and the item pocket layout the battle's bag shares.
## Split out of main.gd; reaches the game through `main`.

const ItemData = preload("res://scripts/item_data.gd")
const BattleEngine = preload("res://scripts/battle_engine.gd")
const PokemonState = preload("res://scripts/pokemon_state.gd")
const PokemonEcology = preload("res://scripts/pokemon_ecology.gd")

var main: GameMain

func _init(owner_main: GameMain) -> void:
    main = owner_main

func configure_clean_item_pocket_layout() -> void:
    # Draw this menu at the native 320x180 viewport size.  The old 160x144
    # plate was scaled 2x horizontally and 1.25x vertically, which distorted
    # both the Johto glyphs and the selection arrow.
    main.item_pocket_menu.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    main.item_pocket_menu.scale = Vector2.ONE
    main.item_pocket_menu.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
    main.item_pocket_menu.get_node("Background").visible = false

    var backdrop := ColorRect.new()
    backdrop.name = "CleanBackdrop"
    backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    backdrop.color = Color.WHITE
    backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
    main.item_pocket_menu.add_child(backdrop)
    main.item_pocket_menu.move_child(backdrop, 0)

    var pocket_frame := Panel.new()
    pocket_frame.name = "PocketFrame"
    pocket_frame.position = Vector2(4, 2)
    pocket_frame.size = Vector2(82, 123)
    pocket_frame.add_theme_stylebox_override("panel", main._classic_dialogue_style())
    pocket_frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
    main.item_pocket_menu.add_child(pocket_frame)
    main.item_pocket_menu.move_child(pocket_frame, 2)

    var list_frame := Panel.new()
    list_frame.name = "ListFrame"
    list_frame.position = Vector2(84, 2)
    list_frame.size = Vector2(232, 123)
    list_frame.add_theme_stylebox_override("panel", main._classic_dialogue_style())
    list_frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
    main.item_pocket_menu.add_child(list_frame)
    main.item_pocket_menu.move_child(list_frame, 3)

    var description_frame := Panel.new()
    description_frame.name = "DescriptionFrame"
    description_frame.position = Vector2(4, 123)
    description_frame.size = Vector2(312, 55)
    description_frame.add_theme_stylebox_override("panel", main._classic_dialogue_style())
    description_frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
    main.item_pocket_menu.add_child(description_frame)
    main.item_pocket_menu.move_child(description_frame, 4)

    main.item_pocket_label.position = Vector2(24, 14)
    main.item_pocket_label.size = Vector2(41, 24)
    main.item_pocket_label.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
    main.item_pocket_bag.position = Vector2(24, 57)
    main.item_pocket_bag.size = Vector2(41, 26)
    main.item_pocket_bag.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
    main.item_pocket_cursor.position = Vector2(94, 13)
    main.item_pocket_cursor.size = Vector2(4, 7)
    main.item_pocket_list.position = Vector2(105, 9)
    main.item_pocket_list.size = Vector2(154, 88)
    main.item_pocket_list.add_theme_font_size_override("font_size", 9)
    main.item_pocket_list.add_theme_constant_override("line_spacing", 6)
    main.item_pocket_quantities.position = Vector2(260, 9)
    main.item_pocket_quantities.size = Vector2(46, 88)
    main.item_pocket_quantities.add_theme_font_size_override("font_size", 9)
    main.item_pocket_quantities.add_theme_constant_override("line_spacing", 6)
    main.item_pocket_description.position = Vector2(16, 134)
    main.item_pocket_description.size = Vector2(288, 34)
    main.item_pocket_description.add_theme_font_size_override("font_size", 9)
    main.item_pocket_description.add_theme_constant_override("line_spacing", 2)

func show_item_menu() -> void:
    if main.item_pocket_menu.get_parent() != main.game_menu:
        main.item_pocket_menu.reparent(main.game_menu, false)
    main.item_pocket_menu.z_index = 100
    main.item_pocket_context = "OVERWORLD"
    main.battle_item_pocket_open = true
    main.battle_item_pocket_index = ItemData.POCKET_ITEMS
    main.battle_item_menu_index = 0
    main.start_menu.item_menu_active = false
    main.game_menu_box.visible = false
    main.game_menu_detail.visible = false
    main.item_pocket_menu.visible = true
    main._refresh_battle_item_pocket_menu()

func handle_overworld_item_pocket_input(event: InputEvent) -> void:
    if main.planting_bag_target != null and main.field_item_busy:
        main.get_viewport().set_input_as_handled()
        return
    if event.is_action_pressed("cancel") or event.is_action_pressed("start"):
        _close_overworld_item_pocket_menu()
    elif (event.is_action_pressed("move_left") or
            event.is_action_pressed("shoulder_left")):
        main._switch_battle_item_pocket(-1)
    elif (event.is_action_pressed("move_right") or
            event.is_action_pressed("shoulder_right")):
        main._switch_battle_item_pocket(1)
    elif event.is_action_pressed("move_up"):
        main.battle_item_menu_index = wrapi(main.battle_item_menu_index - 1, 0,
            main.battle_item_menu_names.size() + 1)
        main._refresh_battle_item_pocket_menu()
    elif event.is_action_pressed("move_down"):
        main.battle_item_menu_index = wrapi(main.battle_item_menu_index + 1, 0,
            main.battle_item_menu_names.size() + 1)
        main._refresh_battle_item_pocket_menu()
    elif event.is_action_pressed("confirm"):
        _confirm_overworld_item_pocket()
    else:
        return
    main.get_viewport().set_input_as_handled()

func _close_overworld_item_pocket_menu() -> void:
    if main.planting_bag_target != null:
        main.planting_bag_target = null
        main.start_menu.close_game_menu()
        return
    main.battle_item_pocket_open = false
    main.item_pocket_context = ""
    main.item_pocket_menu.visible = false
    main.game_menu_box.visible = true

func _confirm_overworld_item_pocket() -> void:
    if main.battle_item_menu_index >= main.battle_item_menu_names.size():
        _close_overworld_item_pocket_menu()
        return
    var selected_item := ItemData.normalize_name(main.battle_item_menu_names[main.battle_item_menu_index])
    if main.planting_bag_target != null:
        if not main.world.is_empty_planting_hole(main.planting_bag_target) or not planting_bag_item_allowed(selected_item):
            main.item_pocket_description.text = "That plant cannot grow here."
            return
        if int(main.inventory.get(selected_item, 0)) <= 0:
            main._refresh_battle_item_pocket_menu()
            return
        main.field_item_busy = true
        main.game_menu.hide()
        var planted: bool = await main.world.plants().plant(main.planting_bag_target, selected_item)
        main.field_item_busy = false
        if planted:
            if not main.coop_game.active:consume_inventory_item(selected_item)
            main.planting_bag_target = null
            main.world.planting_item = selected_item if int(main.inventory.get(selected_item,0)) > 0 else ""
            main.start_menu.close_game_menu()
        else:
            main.game_menu.show()
            main.world.set_gameplay_enabled(false)
        return
    main.bag_action_ui = preload("res://scripts/bag_item_actions.gd").new()
    main.get_node("UI").add_child(main.bag_action_ui)
    main.bag_action_ui.open(main, selected_item)

func use_overworld_item(item: String) -> void:
    if int(main.inventory.get(item, 0)) <= 0:
        main._refresh_battle_item_pocket_menu()
        return
    if ItemData.is_evolution_item(item):
        main.overworld_evolution_item = item
        main.battle_item_pocket_open = false
        main.item_pocket_menu.hide()
        main.party_menu.show_pokemon_menu()
        refresh_evolution_item_target()
        return
    if (preload("res://scripts/source_plant_farming.gd").plantable(item) or item == "SLEEPING BAG") and main.world.active_field_move == "SURF" and main.world.terrain_kind_at(main.world._player_cell()) == 0:
        main._show_message("Reach dry land first.")
        return
    if preload("res://scripts/source_plant_farming.gd").plantable(item):
        main.world.clear_active_field_move(false)
        main.world.planting_item = item
        _leave_game_menu_for_field_action(true)
        main._show_message("Face the soil and press A to plant." if item != "MANURE" else "Face a sapling or small tree and press A to fertilize.")
        return
    if item == "SLEEPING BAG":
        if not String(main.world.get("active_field_move")).is_empty():
            main.world.call("clear_active_field_move", false)
        if not bool(main.world.call("begin_sleeping_bag", main._player_sleeping_texture())):
            return
        for party_index in range(main.caught_pokemon.size()):
            if typeof(main.caught_pokemon[party_index]) != TYPE_DICTIONARY or bool(
                    (main.caught_pokemon[party_index] as Dictionary).get("is_egg", false)):
                continue
            var resting_pokemon: Dictionary = BattleEngine.ensure_pokemon(main.caught_pokemon[party_index])
            BattleEngine.refill_pp(resting_pokemon)
            main.caught_pokemon[party_index] = resting_pokemon
        main.field_item_busy = true
        main.sleeping_bag_heal_accumulator = 0.0
        _leave_game_menu_for_field_action(false)
        return
    if item == "ESCAPE ROPE":
        if bool(main.world.call("use_escape_rope")):
            _leave_game_menu_for_field_action(true)
        return
    if item == "RARE CANDY":
        if main.caught_pokemon.is_empty():
            main.item_pocket_description.text = "There is no POKEMON to use it on."
            return
        var pokemon = BattleEngine.ensure_pokemon(main.caught_pokemon[0])
        if int(pokemon.get("level", 1)) >= 100:
            main.item_pocket_description.text = "It won't have any effect."
            return
        pokemon["level"] = int(pokemon.get("level", 1)) + 1
        PokemonState.apply_stats(pokemon, true)
        BattleEngine.refill_pp(pokemon)
        main.caught_pokemon[0] = pokemon
        consume_inventory_item(item)
        main._play_level_up_sound()
        main._show_message("%s grew to level %d." % [
            PokemonState.display_name(pokemon), int(pokemon.get("level", 1))])
        main._refresh_battle_item_pocket_menu()
        return
    if item in ["REPEL", "MAX REPEL"]:
        main.world.repel_until_elapsed = main.world.world_elapsed_seconds + (
            240.0 if item == "MAX REPEL" else 120.0)
        consume_inventory_item(item)
        _leave_game_menu_for_field_action(true)
        main._show_message("Used %s." % item)
        return
    if item in ["OLD ROD", "GOOD ROD", "SUPER ROD"]:
        _leave_game_menu_for_field_action(true)
        main.world.request_fishing_encounter(item)
        return
    if PokemonEcology.is_food(item):
        if not main.world.feed_pokemon_in_front(item):
            main.item_pocket_description.text = "Face a POKEMON to feed it."
            return
        consume_inventory_item(item)
        main._refresh_battle_item_pocket_menu()
        return
    main.item_pocket_description.text = "It won't have any effect here."

func refresh_evolution_item_target() -> void:
    main.party_menu.refresh_pokemon_category_menu()
    if main.caught_pokemon.is_empty():
        return
    var target := BattleEngine.item_evolution_target(main.caught_pokemon[main.pokemon_menu_index], main.overworld_evolution_item)
    main.pokemon_menu_prompt.text = "%s: %s" % [main.overworld_evolution_item, ("ABLE." if main.touch_on() else "ABLE. A: USE") if not target.is_empty() else "NOT ABLE"]

func handle_evolution_item_input(event: InputEvent) -> void:
    if event.is_action_pressed("cancel") or event.is_action_pressed("start"):
        main.overworld_evolution_item = ""
        main.pokemon_menu_open = false
        main.pokemon_menu.hide()
        var pocket := main.battle_item_pocket_index
        var selection := main.battle_item_menu_index
        show_item_menu()
        main.battle_item_pocket_index = pocket
        main.battle_item_menu_index = selection
        main._refresh_battle_item_pocket_menu()
    elif event.is_action_pressed("move_up") or event.is_action_pressed("move_down"):
        if not main.caught_pokemon.is_empty():
            main.pokemon_menu_index = wrapi(main.pokemon_menu_index + (-1 if event.is_action_pressed("move_up") else 1), 0, mini(6, main.caught_pokemon.size()))
            refresh_evolution_item_target()
    elif event.is_action_pressed("confirm"):
        _use_evolution_item_on(main.pokemon_menu_index)
    else:
        return
    main.get_viewport().set_input_as_handled()

func _use_evolution_item_on(index: int) -> void:
    if main.overworld_evolution_running or index < 0 or index >= main.caught_pokemon.size():
        return
    var item := main.overworld_evolution_item
    if item.is_empty() or int(main.inventory.get(item, 0)) <= 0:
        return
    var pokemon: Dictionary = main.caught_pokemon[index]
    var target := BattleEngine.item_evolution_target(pokemon, item)
    if target.is_empty():
        main.pokemon_menu_prompt.text = "It won't have any effect."
        return
    var identity := main._ensure_party_ecology_id(index)
    var field_move := String(main.world.active_field_move) if String(main.world.active_field_pokemon.get("party_ecology_id", "")) == identity else ""
    var following := String(main.world.follower_pokemon.get("party_ecology_id", "")) == identity
    main.overworld_evolution_item = ""
    main.overworld_evolution_running = true
    main.progression_active = true
    main.field_item_busy = true
    main.pokemon_menu_open = false
    main.pokemon_menu.hide()
    _leave_game_menu_for_field_action(false)
    main.world.set_gameplay_enabled(false)
    consume_inventory_item(item)
    var previous_actor := main.battle_player
    main.battle_player = pokemon
    main._reset_progression_overlay()
    var evolved := await main._run_evolution_sequence(pokemon, target, index)
    if not evolved:
        main.inventory[item] = int(main.inventory.get(item, 0)) + 1
    elif not field_move.is_empty():
        main.world.set_active_field_move(pokemon, field_move)
    if evolved and following:
        main.world.set_follower(pokemon, false)
    main.battle_player = previous_actor
    main._hide_progression_overlay()
    main.overworld_evolution_running = false
    main.progression_active = false
    main.field_item_busy = false
    main.world.set_gameplay_enabled(not main._field_ui_blocks_gameplay())

func consume_inventory_item(item: String) -> void:
    main.inventory[item] = maxi(0, int(main.inventory.get(item, 0)) - 1)

func _leave_game_menu_for_field_action(enable_world: bool) -> void:
    main.battle_item_pocket_open = false
    main.item_pocket_context = ""
    main.item_pocket_menu.visible = false
    main.game_menu_detail_open = false
    main.game_menu_open = false
    main.game_menu.visible = false
    if enable_world:
        main.world.set_gameplay_enabled(true)
        main.touch_controls.set_game_active(true)

func sleeping_bag_active() -> bool:
    var sprite = main.world.get("sleeping_bag_sprite")
    return sprite is Sprite2D and is_instance_valid(sprite)

func update_sleeping_bag_rest(delta: float) -> void:
    if main.battle_active:
        return
    if not main.field_item_busy or not sleeping_bag_active():
        main.sleeping_bag_heal_accumulator = 0.0
        return
    main.sleeping_bag_heal_accumulator += delta
    var interval := 128.0 / 60.0 if main.world.bed_rest_active else 1.0
    while main.sleeping_bag_heal_accumulator >= interval:
        main.sleeping_bag_heal_accumulator -= interval
        var party_changed := false
        for party_index in range(main.caught_pokemon.size()):
            if typeof(main.caught_pokemon[party_index]) != TYPE_DICTIONARY or bool(
                    (main.caught_pokemon[party_index] as Dictionary).get(
                        "is_egg", false)):
                continue
            var pokemon := BattleEngine.ensure_pokemon(
                main.caught_pokemon[party_index])
            var old_hp := int(pokemon.get("hp", 0))
            var max_hp := maxi(1, int(pokemon.get("max_hp", 1)))
            if old_hp < max_hp:
                var recovery := (ceili(float(max_hp) / 25.0) + ceili(float(max_hp) / 15.0)) if main.world.bed_rest_active else (4 if main.world.active_area_id == "HOUSE" else 2)
                pokemon["hp"] = mini(max_hp, old_hp + recovery)
                party_changed = true
            # Source bed recovery clears status at full HP. Apply that same
            # completion rule to sleeping-bag rest, including full-HP status.
            if int(pokemon["hp"]) >= max_hp and not String(pokemon.get("status", "")).is_empty():
                pokemon["status"] = ""
                pokemon["status_counter"] = 0
                pokemon["toxic_counter"] = 0
                party_changed = true
            main.caught_pokemon[party_index] = pokemon
        if party_changed and main.pokemon_menu_open and main.pokemon_menu != null and \
                main.pokemon_menu.visible:
            main.party_menu.refresh_party_list_rows(
                main.pokemon_party_rows, main.caught_pokemon, main.pokemon_menu_index)

func end_sleeping_bag_rest() -> void:
    if not sleeping_bag_active():
        return
    var was_bed: bool = main.world.bed_rest_active
    main.world.call("end_sleeping_bag")
    main.field_item_busy = false
    main.sleeping_bag_heal_accumulator = 0.0
    main.world.set_gameplay_enabled(true)
    main.touch_controls.set_game_active(true)
    main._show_message("You got out of bed." if was_bed else "Your POKEMON rested. This is now your return point.")

func planting_bag_item_allowed(item: String) -> bool:
    if main.planting_bag_target == null or item == "MANURE": return false
    if not preload("res://scripts/source_plant_farming.gd").plantable(item): return false
    return main.world.plants().valid(main.world.exact_world.tile_at(main.planting_bag_target), item)

func open_planting_bag(cell: Vector2i) -> void:
    if not main.world.is_empty_planting_hole(cell): return
    main.start_menu.open_game_menu()
    if not main.game_menu_open: return
    main.planting_bag_target = cell
    show_item_menu()
    for pocket in range(ItemData.POCKET_COUNT):
        var found := false
        for item in ItemData.items_for_pocket(pocket):
            if int(main.inventory.get(item,0)) > 0 and planting_bag_item_allowed(item):
                found = true
                break
        if found:
            main.battle_item_pocket_index = pocket
            main._refresh_battle_item_pocket_menu()
            return
    main.item_pocket_description.text = "No seeds or apricorns in your bag can grow here."
