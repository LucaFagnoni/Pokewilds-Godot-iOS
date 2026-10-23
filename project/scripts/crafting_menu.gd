extends RefCounted

## The crafting menu of a station (campfire, work table, fossil reviver, regi forge)
## and the BUILD menu that goes with the BUILD field move.
## Split out of main.gd; reaches the game through `main`.

const FieldMoveData = preload("res://scripts/field_move_data.gd")
const PokemonData = preload("res://scripts/pokemon_data.gd")
const CraftingData = preload("res://scripts/crafting_data.gd")
const SourceEventData = preload("res://scripts/source_event_data.gd")
const BattleEngine = preload("res://scripts/battle_engine.gd")

var main: GameMain
var craft_station := ""
var craft_index := 0

func _init(owner_main: GameMain) -> void:
    main = owner_main

func open_crafting_menu(station: String) -> void:
    if main.craft_menu_open or main.game_menu_open or main.battle_active:
        return
    craft_station = station
    craft_index = 0
    main.craft_menu_open = true
    main.crafting_panel.visible = true
    main.world.set_gameplay_enabled(false)
    main.touch_controls.set_game_active(true)
    main.world.call("play_source_sound", "menu_open1")
    _refresh_crafting_menu()

func _close_crafting_menu() -> void:
    main.craft_menu_open = false
    main.crafting_panel.visible = false
    main.world.set_gameplay_enabled(true)
    main.touch_controls.set_game_active(true)

func _find_party_builder_index() -> int:
    for index in range(main.caught_pokemon.size()):
        var raw_pokemon = main.caught_pokemon[index]
        if typeof(raw_pokemon) != TYPE_DICTIONARY:
            continue
        var pokemon := raw_pokemon as Dictionary
        if bool(pokemon.get("is_egg", false)) or int(pokemon.get("hp", 1)) <= 0:
            continue
        if FieldMoveData.field_moves_for(String(pokemon.get("species", "")), String(pokemon.get("form", ""))).has("BUILD"):
            return index
    return -1

func open_build_menu() -> void:
    if main.build_menu_open or main.craft_menu_open or main.game_menu_open or main.battle_active or not main.started:
        return
    var builder_index := _find_party_builder_index()
    if builder_index < 0:
        main.dialogs.show_message("A FIGHTING-type Pokemon is needed to BUILD.")
        return

    main._ensure_party_ecology_id(builder_index)
    var builder := main.caught_pokemon[builder_index] as Dictionary
    var active_move := String(main.world.get("active_field_move"))
    var active_builder := String(main.world.get("active_field_species"))
    var helper_missing := (main.world.get("field_helper_pokemon") as Dictionary).is_empty()
    if active_move != "BUILD" or active_builder != String(builder.get("species", "")).to_lower() or helper_missing:
        if not bool(main.world.set_active_field_move(builder, "BUILD")):
            main.dialogs.show_message("There is no room for %s to BUILD here." % PokemonData.battle_display_name(String(builder.get("species", "POKEMON"))))
            return

    main.build_menu_index = int(main.world.call("get_build_selection_index"))
    main.build_menu_open = true
    main.build_panel.visible = true
    main.message_panel.visible = false
    main.world.call("set_build_preview_active", true)
    main.world.set_gameplay_enabled(true)
    main.touch_controls.set_game_active(true)
    _refresh_build_menu()

func close_build_menu(stop_building: bool = true) -> void:
    main.build_menu_open = false
    main.build_panel.visible = false
    main.world.call("set_build_preview_active", false)
    if stop_building and String(main.world.get("active_field_move")) == "BUILD":
        main.world.call("clear_active_field_move", true)
    main.world.set_gameplay_enabled(not main._field_ui_blocks_gameplay())
    main.touch_controls.set_game_active(true)

func handle_build_menu_input(event: InputEvent) -> void:
    var recipe_count := CraftingData.build_recipes().size()
    if event.is_action_pressed("shoulder_left"):
        if recipe_count > 0:
            main.build_menu_index = wrapi(main.build_menu_index - 1, 0, recipe_count)
            _refresh_build_menu()
        main.get_viewport().set_input_as_handled()
    elif event.is_action_pressed("shoulder_right"):
        if recipe_count > 0:
            main.build_menu_index = wrapi(main.build_menu_index + 1, 0, recipe_count)
            _refresh_build_menu()
        main.get_viewport().set_input_as_handled()
    elif event.is_action_pressed("confirm"):
        if recipe_count > 0:
            main.world.call("set_build_selection_index", main.build_menu_index)
            var recipe := CraftingData.build_recipes()[main.build_menu_index] as Dictionary
            var build_name := String(recipe.get("name", ""))
            var target: Vector2i = main.world.call("get_build_execution_cell")
            main._on_build_requested(build_name, target)
            _refresh_build_menu()
        main.get_viewport().set_input_as_handled()
    elif event.is_action_pressed("cancel") or event.is_action_pressed("build_menu"):
        close_build_menu()
        main.get_viewport().set_input_as_handled()

func _refresh_build_menu() -> void:
    var recipes := CraftingData.build_recipes()
    if recipes.is_empty():
        main.build_list.text = "NO BUILD RECIPES"
        main.build_cost.text = ""
        main.build_cursor.visible = false
        return
    main.build_menu_index = clampi(main.build_menu_index, 0, recipes.size() - 1)
    apply_build_hud_selection()
    main.world.call("set_build_selection_index", main.build_menu_index)
    main.world.call("set_build_preview_active", true)

func apply_build_hud_selection() -> void:
    var recipes := CraftingData.build_recipes()
    if recipes.is_empty():
        return
    main.build_menu_index = clampi(main.build_menu_index, 0, recipes.size() - 1)
    var selected := recipes[main.build_menu_index] as Dictionary
    var cost: Dictionary = selected.get("cost", {})
    main.build_title.text = String(selected.get("display_name", selected.get("name", ""))).to_upper()
    main.build_list.text = ""
    main.build_cursor.visible = false
    main.build_cost.text = _format_need_box(cost)
    # Four lines for the three-material recipe still fit the matched 48px box.
    var compact_cost := cost.size() > 2
    main.build_cost.position.y = 6.0 if compact_cost else 8.0
    main.build_cost.size.y = 36.0 if compact_cost else 34.0
    main.build_cost.add_theme_constant_override("line_separation", -3 if compact_cost else 0)

func on_world_build_selection_changed(index: int) -> void:
    if not main.build_menu_open or CraftingData.build_recipes().is_empty():
        return
    var normalized := wrapi(index, 0, CraftingData.build_recipes().size())
    if normalized == main.build_menu_index:
        return
    main.build_menu_index = normalized
    # World input can receive shoulder events first while gameplay stays live
    # in BUILD mode.  Update the two visible boxes from that authoritative
    # selection without sending the value back and causing a signal loop.
    apply_build_hud_selection()

func handle_crafting_input(event: InputEvent) -> void:
    var recipes := CraftingData.recipes_for_station(craft_station)
    if event.is_action_pressed("move_up"):
        if not recipes.is_empty():
            craft_index = wrapi(craft_index - 1, 0, recipes.size())
            main.world.call("play_source_sound", "menu_switch2")
            _refresh_crafting_menu()
        main.get_viewport().set_input_as_handled()
    elif event.is_action_pressed("move_down"):
        if not recipes.is_empty():
            craft_index = wrapi(craft_index + 1, 0, recipes.size())
            main.world.call("play_source_sound", "menu_switch2")
            _refresh_crafting_menu()
        main.get_viewport().set_input_as_handled()
    elif event.is_action_pressed("move_left") or event.is_action_pressed("shoulder_left"):
        if not recipes.is_empty():
            craft_index = wrapi(craft_index - 1, 0, recipes.size())
            main.world.call("play_source_sound", "menu_switch2")
            _refresh_crafting_menu()
        main.get_viewport().set_input_as_handled()
    elif event.is_action_pressed("move_right") or event.is_action_pressed("shoulder_right"):
        if not recipes.is_empty():
            craft_index = wrapi(craft_index + 1, 0, recipes.size())
            main.world.call("play_source_sound", "menu_switch2")
            _refresh_crafting_menu()
        main.get_viewport().set_input_as_handled()
    elif event.is_action_pressed("confirm"):
        _craft_selected_recipe()
        main.get_viewport().set_input_as_handled()
    elif event.is_action_pressed("cancel") or event.is_action_pressed("start"):
        _close_crafting_menu()
        main.get_viewport().set_input_as_handled()

func _refresh_crafting_menu() -> void:
    var recipes := CraftingData.recipes_for_station(craft_station)
    if recipes.is_empty():
        main.crafting_title.text = "No recipes"
        main.crafting_list.text = "NO RECIPES"
        main.crafting_cost.text = ""
        main.crafting_cursor.visible = false
        return

    craft_index = clampi(craft_index, 0, recipes.size() - 1)
    var selected: Dictionary = recipes[craft_index]
    main.crafting_title.text = String(selected.get("name", "")).capitalize()
    main.crafting_list.text = ""
    main.crafting_cursor.visible = false
    var crafting_cost_data: Dictionary = selected.get("cost", {})
    main.crafting_cost.text = _format_need_box(crafting_cost_data)

func _format_need_box(cost: Dictionary) -> String:
    var lines: Array[String] = ["NEED"]
    for raw_name in cost.keys():
        var item_name := String(raw_name).to_upper()
        var required := int(cost[raw_name])
        var enough := int(main.inventory.get(raw_name, 0)) >= required
        if enough:
            lines.append("%s x%d" % [item_name, required])
        else:
            lines.append("[font=res://assets/source_text_font_gray.fnt]%s x%d[/font]" % [
                item_name, required])
    return "\n".join(lines)

func _craft_selected_recipe() -> void:
    var recipes := CraftingData.recipes_for_station(craft_station)
    if recipes.is_empty():
        return
    var recipe: Dictionary = recipes[craft_index]
    var cost: Dictionary = recipe.get("cost", {})
    var output := String(recipe.get("name", ""))
    if not CraftingData.can_afford(main.inventory, cost):
        main.world.call("play_source_sound", "error1")
        main.dialogs.show_message("Not enough materials for %s." % output)
        return
    if (
            bool(recipe.get("event", false))
            and craft_station == "REGI FORGE"
            and main.world.has_method("can_awaken_regi")
            and not bool(main.world.call("can_awaken_regi", output))
        ):
        main.dialogs.show_message("That Regi has already answered the pedestal.")
        return
    CraftingData.consume(main.inventory, cost)
    main.world.call("play_source_sound", "click1")
    if bool(recipe.get("event", false)):
        if craft_station == "REGI FORGE":
            if main.world.complete_regi_forge(output):
                _close_crafting_menu()
            else:
                main.dialogs.show_message("The pedestal did not respond.")
        elif craft_station == "FOSSIL REVIVER":
            _close_crafting_menu()
            _revive_fossil(output)
        else:
            main.dialogs.show_message("%s awakened!" % output)
    else:
        CraftingData.grant(main.inventory, output, 1)
        main.dialogs.show_message("Crafted %s." % output)
    if main.craft_menu_open:
        _refresh_crafting_menu()

func _revive_fossil(fossil_name: String) -> void:
    var species := String(SourceEventData.FOSSIL_SPECIES.get(fossil_name, ""))
    if species.is_empty():
        main.dialogs.show_message("The machine could not read that fossil.")
        return
    var level_total := 0
    var level_count := 0
    for raw_pokemon in main.caught_pokemon:
        if typeof(raw_pokemon) != TYPE_DICTIONARY:
            continue
        var pokemon := raw_pokemon as Dictionary
        if bool(pokemon.get("is_egg", false)):
            continue
        level_total += maxi(1, int(pokemon.get("level", 1)))
        level_count += 1
    var average_level := 5 if level_count == 0 else int(floor(float(level_total) / float(level_count)))
    var revived_level := clampi(average_level - 3 + main.battle_rng.randi_range(0, 2), 1, 50)
    var revived := BattleEngine.make_pokemon(species, revived_level)
    if String(main.world.get("active_field_move")) == "CHARM":
        var destination := main._route_received_pokemon(revived)
        if not main.caught_species.has(species):
            main.caught_species.append(species)
        var notice := main._received_pokemon_notice(revived, destination)
        main.dialogs.show_message("%s was revived from the %s!" % [PokemonData.battle_display_name(species), fossil_name] if notice.is_empty() else notice)
        return
    main.dialogs.show_message("%s was revived... and attacked!" % PokemonData.battle_display_name(species))
    main._start_battle_context({
        "id": "fossil_%s" % species,
        "kind": "fossil",
        "intro": "%s was revived... and attacked!" % PokemonData.battle_display_name(species),
        "can_run": true,
        "can_catch": true,
        "clear_on_capture": false,
        "clear_on_defeat": false,
        "party": [{"species": species, "level": revived_level}]
    })
