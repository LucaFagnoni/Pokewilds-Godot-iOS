extends RefCounted

## What the world asks of the game while playing the field: materials and DIG
## rewards collected, building, painting and removing structures, using a
## structure (storage, sign, bed, switches), the shore's SURF question and resting
## in a bed.
## Split out of main.gd; reaches the game through `main`.

const ItemData = preload("res://scripts/item_data.gd")
const CraftingData = preload("res://scripts/crafting_data.gd")
const PlayerLooks = preload("res://scripts/player_looks.gd")
const PokemonData = preload("res://scripts/pokemon_data.gd")

var main: GameMain

func _init(owner_main: GameMain) -> void:
    main = owner_main

func on_dig_reward_collected(items: Dictionary, grant_items: bool = true) -> void:
    if is_instance_valid(main.coop_game) and main.coop_game.active and main.coop_game.building.collect(items):return
    if main.world.get_meta("ball_action_reward", false) or main.world.active_field_move != "DIG":
        on_material_bundle_collected(items,grant_items)
        return
    var lines: Array[String] = []
    for raw_name in items:
        var item := ItemData.normalize_name(String(raw_name))
        var amount := int(items[raw_name])
        if grant_items:CraftingData.grant(main.inventory, item, amount)
        lines.append("Got x%d %s" % [amount, item])
    main.dig_reward_label.text = "\n".join(lines)
    main.minimap.fit_compact_dig_label(main.dig_reward_label)
    main.dig_reward_seconds = 1.8
    main.minimap.update_dig_hud_and_minimap(0.0)

func on_material_collected(item_name: String, amount: int) -> void:
    if is_instance_valid(main.coop_game) and main.coop_game.active and main.coop_game.building.collect({ItemData.normalize_name(item_name):amount}):return
    var normalized := ItemData.normalize_name(item_name)
    CraftingData.grant(main.inventory, normalized, amount)
    main.dialogs.show_acquired_resource(normalized, amount)

func on_material_bundle_collected(items: Dictionary, grant_items: bool = true) -> void:
    if is_instance_valid(main.coop_game) and main.coop_game.active and main.coop_game.building.collect(items):return
    var lines: Array[String] = ["GOT"]
    for raw_name in items.keys():
        var normalized := ItemData.normalize_name(String(raw_name))
        var amount := maxi(1, int(items[raw_name]))
        if grant_items:CraftingData.grant(main.inventory, normalized, amount)
        lines.append("x%d %s" % [amount, normalized])
    main.resource_popup_name = ""
    main.resource_popup_amount = 0
    main.resource_popup_text.text = "\n".join(lines)
    main.resource_popup.visible = true
    main.resource_popup_timer = 0.9

func on_paint_requested(picture_index: int, cell: Vector2i) -> void:
    if int(main.inventory.get("THIN PAPER", 0)) <= 0:
        main.dialogs.show_message("PAINT needs 1 THIN PAPER.")
        return
    if is_instance_valid(main.coop_game) and main.coop_game.active:
        main.coop_game.building.paint(picture_index,cell)
        return
    if main.world.has_method("apply_paint") and bool(main.world.call("apply_paint", picture_index, cell)):
        main.inventory["THIN PAPER"] = int(main.inventory.get("THIN PAPER", 0)) - 1

func on_build_requested(build_name: String, cell: Vector2i) -> void:
    var recipe := CraftingData.build_recipe(build_name)
    if recipe.is_empty():
        return
    var cost: Dictionary = recipe.get("cost", {})
    if not CraftingData.can_afford(main.inventory, cost):
        main.dialogs.show_message("Not enough materials for %s." % build_name)
        return
    if is_instance_valid(main.coop_game) and main.coop_game.active:
        main.coop_game.building.build(build_name,cell)
        return
    if main.world.place_structure(build_name, cell):
        CraftingData.consume(main.inventory, cost)

func on_dig_requested(choice: String, cell: Vector2i, material: String) -> void:
    if int(main.inventory.get(material, 0)) <= 0:
        main.dialogs.show_message("DIG needs %s to place %s." % [material, choice])
        return
    if is_instance_valid(main.coop_game) and main.coop_game.active and not main.coop_game.building.collecting:
        main.coop_game.building.dig(cell,choice)
        return
    if main.world.has_method("apply_dig_choice"):
        if bool(main.world.call("apply_dig_choice", cell, choice)):
            if is_instance_valid(main.coop_game) and main.coop_game.active and main.coop_game.building.collecting:main.coop_game.building.field_choice=choice
            else:main.inventory[material] = int(main.inventory.get(material, 0)) - 1

func on_build_refund_requested(refund: Dictionary, grant_items: bool = true) -> void:
    if refund.is_empty():
        return
    if refund.size() == 1:
        var raw_name = refund.keys()[0]
        var normalized := ItemData.normalize_name(String(raw_name))
        var amount := maxi(1, int(refund[raw_name]))
        if grant_items:CraftingData.grant(main.inventory, normalized, amount)
        main.dialogs.show_acquired_resource(normalized, amount)
        return
    var lines: Array[String] = ["GOT"]
    for raw_name in refund.keys():
        var normalized := ItemData.normalize_name(String(raw_name))
        var amount := maxi(1, int(refund[raw_name]))
        if grant_items:CraftingData.grant(main.inventory, normalized, amount)
        lines.append("x%d %s" % [amount, normalized])
    main.resource_popup_name = ""
    main.resource_popup_amount = 0
    main.resource_popup_text.text = "\n".join(lines)
    main.resource_popup.visible = true
    main.resource_popup_timer = 0.9

func on_structure_removal_requested(cell: Vector2i, move: String) -> void:
    if move == "CUT" and not String(main.world.house_wall_decoration_at(cell)).is_empty():
        if is_instance_valid(main.coop_game) and main.coop_game.active:
            main.coop_game.building.remove_decoration(cell)
        else:
            main.world.remove_house_wall_decoration(cell, true)
        return
    var online: bool = is_instance_valid(main.coop_game) and main.coop_game.active
    var wipe_public := false
    if main.world.built_structures.has(cell):
        var build_name := String((main.world.built_structures[cell] as Dictionary).get("name", ""))
        # A STORAGE BOX can be cut with Pokemon in it while another one stands
        # in this world: its Pokemon stay reachable from the others. The last
        # one takes every stored Pokemon with it, so only the host may cut it,
        # and only after saying yes twice to prompts that start on NO.
        # The box itself, or boxes inside a house that go with the piece of its
        # outside being cut: the same questions either way.
        var boxes_going := 1 if build_name == "STORAGE BOX" else 0
        for inside_cell in main.world.house_interior_cells_behind(cell):
            if String(main.world.built_structures.get(inside_cell, {}).get("name", "")) == "STORAGE BOX":
                boxes_going += 1
        if boxes_going > 0 and main.storage.public_box_count() - boxes_going < 1:
            if online and not main.coop_game.hosting:
                main.dialogs.show_message("Sorry, a guest cannot cut the last public box in a world.")
                return
            if not await main.dialogs.ask_yes_no_starting_on_no("Last STORAGE BOX in this world!\nCut it and lose stored POKEMON?"):
                return
            if not await main.dialogs.ask_yes_no_starting_on_no("Are you sure? Stored POKEMON\ncannot be brought back."):
                return
            if not main.world.built_structures.has(cell):
                return
            wipe_public = true
    if online:
        main.coop_game.building.remove(cell,move,wipe_public)
        return
    if wipe_public:
        # PRIVATE CHEST contents belong to the player, not to this world.
        var private_keys: Array[String] = []
        for built_cell in main.world.built_structures:
            if String(main.world.built_structures[built_cell].get("name", "")) == "PRIVATE CHEST":
                private_keys.append(main.storage.world_storage_key(main.world._cell_key(built_cell),main.current_world_grid))
        for key in main.pokemon_storage.keys():
            if not String(key) in private_keys and String(key) != main.SHARED_STORAGE_KEY: main.pokemon_storage.erase(key)
    if main.world.has_method("remove_structure_with_field_move"):
        main.world.call("remove_structure_with_field_move", cell, move)

func on_structure_action(action: String) -> void:
    if action.begins_with("PLANT_HOLE:"):
        main.bag_menu.open_planting_bag(Vector2i(int(action.get_slice(":",1)), int(action.get_slice(":",2))))
    elif action == "SHORE_SURF":
        await _prompt_shore_surf()
    elif action == "DRESSER":
        main.appearance.next_color()
        main.appearance.apply_world_player_textures()
        main.dialogs.show_message("Changed outfit color to %s." % main.PLAYER_COLOR_NAMES[main.player_color_index])
    elif action == "VANITY":
        main.appearance.next_color()
        main.appearance.apply_world_player_textures()
        main.dialogs.show_message("The VANITY changed your appearance to %s." % main.PLAYER_COLOR_NAMES[main.player_color_index])
    elif action.begins_with("BED:"):
        await _prompt_bed_rest(Vector2i(int(action.get_slice(":",1)),int(action.get_slice(":",2))))
    elif action.begins_with("STORAGE:"):
        main.storage.open_storage_menu(action.trim_prefix("STORAGE:"))
    elif action.begins_with("SIGN_EDIT:"):
        var parts := action.split(":", true, 3)
        if parts.size() >= 4:
            main.sign_edit_mode = "SIGN"
            main.sign_dialog.title = "Write on the sign"
            main.sign_edit.placeholder_text = "Sign text"
            main.sign_edit_cell = Vector2i(int(parts[1]), int(parts[2]))
            main.sign_edit.text = String(parts[3])
            main.sign_dialog.popup_centered(Vector2i(260, 104))
            main.sign_edit.grab_focus()
    elif action.begins_with("BEACON_EDIT:"):
        var beacon_parts := action.split(":", true, 3)
        if beacon_parts.size() >= 4:
            main.sign_edit_mode = "BEACON"
            main.sign_dialog.title = "Name the BEACON"
            main.sign_edit.placeholder_text = "Beacon name"
            main.sign_edit_cell = Vector2i(int(beacon_parts[1]), int(beacon_parts[2]))
            main.sign_edit.text = String(beacon_parts[3])
            main.sign_dialog.popup_centered(Vector2i(260, 104))
            main.sign_edit.grab_focus()
    elif action.begins_with("MANSION_SWITCH:"):
        var parts := action.split(":")
        if parts.size() != 3 or main.mansion_switch_open or main._field_ui_blocks_gameplay():
            return
        main.mansion_switch_open = true
        main.mansion_switch_stage = 0
        main.mansion_switch_index = 0
        main.world.set_gameplay_enabled(false)
        main.message_panel.hide()
        main.egg_dialogue_label.text = "A hidden switch! Press it?"
        main.egg_dialogue_arrow.show()
        main.egg_dialogue_panel.show()
        main.egg_choice_panel.hide()
        var pressed: bool = await main.mansion_switch_answered
        main.egg_dialogue_panel.hide()
        main.egg_choice_panel.hide()
        await main.get_tree().create_timer((20.0 if pressed else 3.0) / 60.0).timeout
        if pressed:
            main.world.play_source_sound("enter1")
            SourceMansionRuntime.press_switch(main.world, Vector2i(int(parts[1]), int(parts[2])))
        main.mansion_switch_open = false
        main.world.set_gameplay_enabled(not main._field_ui_blocks_gameplay())
    elif action.begins_with("MANSION_LOCK:"):
        if int(main.inventory.get("SECRET KEY", 0)) <= 0:
            main.dialogs.show_message("It's locked...")
            return
        var parts := action.split(":")
        if parts.size() != 3:
            return
        var cell := Vector2i(int(parts[1]), int(parts[2]))
        if main.world.unlock_mansion_door(cell):
            main.inventory["SECRET KEY"] = int(main.inventory.get("SECRET KEY", 0)) - 1
            main.dialogs.show_message("The SECRET KEY opened the door!")
    elif action.begins_with("ODD_KEYSTONE:"):
        var parts := action.split(":")
        if parts.size() != 4:
            return
        var cell := Vector2i(int(parts[1]), int(parts[2]))
        var remaining := maxi(0, int(parts[3]))
        var available := int(main.inventory.get("LIFE FORCE", 0))
        if available <= 0:
            main.dialogs.show_message("A voice whispers from within... bring %d..." % remaining)
            return
        var used := int(main.world.call("add_keystone_life_force", cell, mini(available, remaining)))
        main.inventory["LIFE FORCE"] = maxi(0, available - used)

func on_item_collected(item_name: String) -> void:
    if is_instance_valid(main.coop_game) and main.coop_game.active and main.coop_game.building.collect({ItemData.normalize_name(item_name):1}):return
    if String(main.world.get("active_field_move")) == "DIG":
        on_dig_reward_collected({item_name:1})
        return
    CraftingData.grant(main.inventory, ItemData.normalize_name(item_name), 1)
    var normalized := ItemData.normalize_name(item_name)
    main.dialogs.show_acquired_resource(normalized, 1)

func _prompt_shore_surf() -> void:
    var party_index := main.move_wheel.find_field_move_pokemon_index("SURF")
    if party_index < 0 or main._field_ui_blocks_gameplay():
        return
    var target: Vector2i = main.world._player_cell() + main.world._facing_cell()
    if not main.world._can_prompt_shore_surf(target):
        return
    # Reuse the tested two-stage egg/switch dialogue and its exact tick offsets.
    main.mansion_switch_open = true
    main.mansion_switch_stage = 0
    main.mansion_switch_index = 0
    main.world.set_gameplay_enabled(false)
    main.message_panel.hide()
    main.egg_dialogue_label.text = "Want to SURF?"
    main.egg_dialogue_arrow.show()
    main.egg_dialogue_panel.show()
    main.egg_choice_panel.hide()
    var accepted: bool = await main.mansion_switch_answered
    main.egg_choice_panel.hide()
    main.egg_dialogue_arrow.hide()
    if accepted and main.world._can_prompt_shore_surf(target):
        main._ensure_party_ecology_id(party_index)
        var pokemon: Dictionary = main.caught_pokemon[party_index]
        var name := String(pokemon.get("nickname", "")).strip_edges()
        if name.is_empty(): name = PokemonData.battle_display_name(String(pokemon.get("species", "POKEMON")))
        main.egg_dialogue_label.text = "%s is using SURF!" % name.to_upper()
        await main.get_tree().create_timer(3.0 / 60.0).timeout
        main._play_pokemon_cry(pokemon)
        main.mansion_switch_stage = 3
        main.egg_dialogue_arrow.show()
        await main.mansion_switch_answered
        main.egg_dialogue_arrow.hide()
        if main.world.set_active_field_move(pokemon, "SURF"):
            main.world.present_field_move_pokemon()
            var entry := main.create_tween()
            entry.tween_property(main.world.player, "position", main.world._cell_center(target), 16.0 / 120.0)
            await entry.finished
    else:
        await main.get_tree().create_timer(10.0 / 60.0).timeout
    main.egg_dialogue_panel.hide()
    main.mansion_switch_open = false
    main.world.set_gameplay_enabled(not main._field_ui_blocks_gameplay())

func _prompt_bed_rest(cell: Vector2i) -> void:
    if main._field_ui_blocks_gameplay(): return
    main.mansion_switch_open = true
    main.mansion_switch_stage = 0
    main.mansion_switch_index = 0
    main.world.set_gameplay_enabled(false)
    main.message_panel.hide()
    main.egg_dialogue_label.text = "Do you want to sleep?"
    main.egg_dialogue_arrow.show()
    main.egg_dialogue_panel.show()
    main.egg_choice_panel.hide()
    var accepted: bool = await main.mansion_switch_answered
    main.egg_choice_panel.hide()
    main.egg_dialogue_panel.hide()
    main.egg_dialogue_arrow.hide()
    main.mansion_switch_open = false
    if accepted:
        main.field_item_busy = true
        await main.get_tree().create_timer(20.0/60.0).timeout
        if main.world.begin_bed_rest(cell):
            main.sleeping_bag_heal_accumulator = 0.0
            return
        main.field_item_busy = false
    main.world.set_gameplay_enabled(not main._field_ui_blocks_gameplay())

## The answer to a structure switch's YES/NO (opened above).
func handle_mansion_switch_input(event: InputEvent) -> void:
    if main.mansion_switch_stage == 3:
        if event.is_action_pressed("confirm") or event.is_action_pressed("start"):
            main.mansion_switch_stage = 2
            main.mansion_switch_answered.emit(true)
            main.get_viewport().set_input_as_handled()
        return
    if main.mansion_switch_stage == 2:
        return
    if event.is_action_pressed("cancel"):
        main.mansion_switch_stage = 2
        main.mansion_switch_answered.emit(false)
    elif main.mansion_switch_stage == 0 and (event.is_action_pressed("confirm") or event.is_action_pressed("start")):
        main.mansion_switch_stage = 1
        main.egg_dialogue_arrow.hide()
        main.egg_choice_panel.show()
        main._align_menu_tick(main.egg_choice_cursor, main.egg_choice_panel.get_node("Yes"))
    elif main.mansion_switch_stage == 1:
        if event.is_action_pressed("move_up") or event.is_action_pressed("move_down"):
            main.mansion_switch_index = 1 - main.mansion_switch_index
            main._align_menu_tick(main.egg_choice_cursor, main.egg_choice_panel.get_node("Yes" if main.mansion_switch_index == 0 else "No"))
        elif event.is_action_pressed("confirm") or event.is_action_pressed("start"):
            main.mansion_switch_stage = 2
            main.mansion_switch_answered.emit(main.mansion_switch_index == 0)
        else:
            return
    else:
        return
    main.get_viewport().set_input_as_handled()
