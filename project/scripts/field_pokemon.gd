extends RefCounted

## The Pokemon the player meets and takes in the field: the wild Pokemon's
## prompt (friendly, frightened, aggressive, provoked) and taking a friendly
## one, the habitat Pokemon's "take it back?" prompt and its recall, the egg
## pickup prompt and the egg received, eggs hatching and friendship growing
## step by step, a party member's ecology id, and where a Pokemon received goes
## (party, storage, released).
## Split out of main.gd; reaches the game through `main`. The simulation of the
## Pokemon themselves is the world's (wild_population.gd, habitat_population.gd).

const BattleEngine = preload("res://scripts/battle_engine.gd")
const PokemonData = preload("res://scripts/pokemon_data.gd")
const PokemonEcology = preload("res://scripts/pokemon_ecology.gd")
const PokemonState = preload("res://scripts/pokemon_state.gd")

var main: GameMain
## The open prompt's Pokemon: wild id (or -1), name shown, kind; for a habitat
## Pokemon, the tile it was asked on and its ecology id.
var wild_prompt_id := -1
var wild_prompt_species := ""
var wild_prompt_kind := ""
var deployed_prompt_cell := Vector2i.ZERO
var deployed_prompt_id := ""
var egg_pickup_cell := Vector2i(-2147483648, -2147483648)
var wild_dialogue_label: Label
var wild_dialogue_arrow: Label
var wild_choice_cursor: Label

func _init(owner_main: GameMain) -> void:
    main = owner_main

## The world's signals about its Pokemon, answered here.
func connect_world(world: Node) -> void:
    world.pokemon_recalled.connect(on_pokemon_recalled)
    world.deployed_recall_requested.connect(on_deployed_recall_requested)
    world.egg_collected.connect(on_egg_collected)
    world.egg_pickup_prompt_requested.connect(on_egg_pickup_prompt_requested)
    world.wild_pokemon_prompt_requested.connect(on_wild_pokemon_prompt_requested)
    world.player_stepped.connect(on_player_stepped)
    world.pokemon_ecology_changed.connect(on_pokemon_ecology_changed)

func create_egg_pickup_ui() -> void:
    # Dedicated source-style egg prompt. It reuses the exact border and fonts
    # used by the rest of this port instead of introducing a second UI theme.
    var panel := Panel.new()
    panel.name = "EggDialogue"
    # Match the compact source dialogue footprint instead of covering half of
    # the 320x180 playfield. Keep the approved border/font and anchor it at the
    # bottom edge exactly like the other source-style message boxes.
    # Keep the compact bar from M74.3.9.1, but give the two-line egg reveal
    # six more pixels of vertical breathing room. Preserve the same 2 px side
    # inset and 2 px bottom inset on the 320x180 source viewport.
    panel.position = Vector2(2, 126)
    panel.size = Vector2(316, 52)
    panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
    panel.add_theme_stylebox_override("panel", main._classic_dialogue_style())
    panel.visible = false
    main.get_node("UI").add_child(panel)
    main.egg_dialogue_panel = panel

    main.egg_dialogue_label = main._source_ui_label(
        panel, "Message", Vector2(14, 6), Vector2(278, 40),
        10, ""
    )
    main.egg_dialogue_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    main.egg_dialogue_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER

    main.egg_dialogue_arrow = main._source_ui_label(
        panel, "Arrow", Vector2(282, 30), Vector2(20, 16),
        10, "▼", true
    )
    main.egg_dialogue_arrow.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER

    var choice := Panel.new()
    choice.name = "EggChoice"
    # Keep the YES/NO box exactly attached to the message bar's top-right
    # corner, but trim the oversized empty padding from the previous pass.
    # Right edge: 318 px. Bottom edge: 126 px, exactly matching the dialogue.
    choice.position = Vector2(234, 56)
    choice.size = Vector2(84, 70)
    choice.mouse_filter = Control.MOUSE_FILTER_IGNORE
    choice.add_theme_stylebox_override("panel", main._classic_dialogue_style())
    choice.visible = false
    main.get_node("UI").add_child(choice)
    main.egg_choice_panel = choice

    main.egg_choice_cursor = main._source_ui_label(
        choice, "Cursor", Vector2(11, 9), Vector2(14, 20),
        10, "▶", true
    )
    main.egg_choice_cursor.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
    _yes_no_labels(choice)

func create_wild_pokemon_prompt_ui() -> void:
    # Deliberately clone the egg prompt geometry/theme so wild interactions
    # retain the user's approved text, border and aligned YES/NO ticks.
    var panel := Panel.new()
    panel.name = "WildPokemonDialogue"
    panel.position = Vector2(2, 126)
    panel.size = Vector2(316, 52)
    panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
    panel.add_theme_stylebox_override("panel", main._classic_dialogue_style())
    panel.visible = false
    main.get_node("UI").add_child(panel)
    main.wild_dialogue_panel = panel

    wild_dialogue_label = main._source_ui_label(
        panel, "Message", Vector2(14, 6), Vector2(278, 40), 10, ""
    )
    wild_dialogue_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    wild_dialogue_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER

    wild_dialogue_arrow = main._source_ui_label(
        panel, "Arrow", Vector2(282, 30), Vector2(20, 16),
        10, "▼", true
    )
    wild_dialogue_arrow.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER

    var choice := Panel.new()
    choice.name = "WildPokemonChoice"
    choice.position = Vector2(234, 56)
    choice.size = Vector2(84, 70)
    choice.mouse_filter = Control.MOUSE_FILTER_IGNORE
    choice.add_theme_stylebox_override("panel", main._classic_dialogue_style())
    choice.visible = false
    main.get_node("UI").add_child(choice)
    main.wild_choice_panel = choice

    wild_choice_cursor = main._source_ui_label(
        choice, "Cursor", Vector2(11, 9), Vector2(14, 20),
        10, "▶", true
    )
    wild_choice_cursor.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
    _yes_no_labels(choice)

func _yes_no_labels(choice: Panel) -> void:
    var yes: Label = main._source_ui_label(choice, "Yes", Vector2(28, 10), Vector2(46, 22), 10, "YES")
    var no: Label = main._source_ui_label(choice, "No", Vector2(28, 38), Vector2(46, 22), 10, "NO")
    yes.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
    no.vertical_alignment = VERTICAL_ALIGNMENT_CENTER

func route_received_pokemon(pokemon: Dictionary, allow_party: bool = true) -> String:
    # Every acquisition shares this boundary; the visible party has six slots.
    if allow_party and main.caught_pokemon.size() < 6:
        main.caught_pokemon.append(pokemon)
        main.pokedex_progress.mark(pokemon, true)
        return "PARTY"
    if is_instance_valid(main.coop_game) and main.coop_game.active:return main.coop_game.storage.route_received(pokemon)
    for key in main.storage.built_storage_keys():
        var box: Array = main.pokemon_storage.get(key, [])
        if main.POKEMON_STORAGE_CAPACITY > 0 and box.size() >= main.POKEMON_STORAGE_CAPACITY:
            continue
        box.append(pokemon)
        main.pokemon_storage[key] = box
        main.pokedex_progress.mark(pokemon, true)
        return "STORAGE"
    # User-requested fallback uses source SelectedMenu.releasePokemon:
    # released records are removed from ownership, not left in hidden slots.
    return "RELEASED"

func received_pokemon_notice(pokemon: Dictionary, destination: String) -> String:
    var name := "EGG" if bool(pokemon.get("is_egg", false)) else PokemonState.display_name(pokemon).to_upper()
    if destination == "STORAGE":
        return "%s has been sent to storage." % name
    if destination == "RELEASED":
        return "You have no more room in storage! %s was released to the wild." % name
    return ""

func recover_hidden_party_overflow() -> void:
    var stored := 0
    var released := 0
    while main.caught_pokemon.size() > 6:
        var pokemon: Dictionary = main.caught_pokemon.pop_at(6)
        var destination := route_received_pokemon(pokemon, false)
        if destination == "STORAGE": stored += 1
        else: released += 1
    main.overflow_recovery_notice = ""
    if stored > 0:
        main.overflow_recovery_notice = "%d hidden party entries were sent to storage." % stored
    if released > 0:
        main.overflow_recovery_notice = "You have no more room in storage! %d excess party entries were released to the wild." % released + (" %d were sent to storage." % stored if stored > 0 else "")

func can_receive_overworld_pokemon() -> bool:
    if main.caught_pokemon.size() < 6:
        return true
    for key in main.storage.built_storage_keys():
        if main.POKEMON_STORAGE_CAPACITY <= 0 or (main.pokemon_storage.get(key, []) as Array).size() < main.POKEMON_STORAGE_CAPACITY:
            return true
    return false

func on_deployed_recall_requested(cell: Vector2i, species: String, message: String) -> void:
    on_wild_pokemon_prompt_requested(-1, species, "DEPLOYED")
    if not main.wild_pokemon_prompt_open or wild_prompt_kind != "DEPLOYED":
        return
    deployed_prompt_cell = cell
    # Online the Pokemon goes on walking while its prompt is open (the host or
    # another player moves it): the answer is about this Pokemon, not this tile.
    deployed_prompt_id = String(main.world.deployed_pokemon.get(cell, {}).get("ecology_id", ""))
    main.world.recall_hold = deployed_prompt_id
    wild_dialogue_label.text = message

func on_pokemon_recalled(pokemon_data: Dictionary) -> void:
    var destination := route_received_pokemon(pokemon_data)
    var species := String(pokemon_data.get("species", ""))
    if not species.is_empty() and not main.caught_species.has(species):
        main.caught_species.append(species)
    main.world.play_source_sound("seed1")
    var notice := received_pokemon_notice(pokemon_data, destination)
    if not notice.is_empty(): main.dialogs.show_message(notice)

func on_wild_pokemon_prompt_requested(
        wild_id: int, species: String, kind: String
    ) -> void:
    if (
            main.wild_pokemon_prompt_open or main.egg_pickup_open or main.battle_active
            or main.game_menu_open or main.craft_menu_open or main.build_menu_open
            or main.storage_menu_open or main.trainer_tip_open
        ):
        return
    main.wild_pokemon_prompt_open = true
    main.wild_pokemon_prompt_stage = 0
    main.wild_pokemon_prompt_index = 0
    wild_prompt_id = wild_id
    wild_prompt_species = PokemonData.battle_display_name(species).replace("_", " ")
    wild_prompt_kind = kind.to_upper()
    # Friendly, but still shaken by a failed catch: same choice, other words.
    var frightened := wild_prompt_kind == "FRIGHTENED"
    if frightened: wild_prompt_kind = "FRIENDLY"
    main.wild_pokemon_prompt_confirm_armed = false
    main.world.set_gameplay_enabled(false)
    main.message_panel.visible = false
    main.wild_dialogue_panel.visible = true
    main.wild_choice_panel.visible = false
    wild_dialogue_arrow.visible = true
    if wild_prompt_kind == "FRIENDLY":
        wild_dialogue_label.text = ("%s is frightened." if frightened else "%s seems friendly.") % wild_prompt_species
    elif wild_prompt_kind == "PROVOKED":
        wild_dialogue_label.text = "%s was provoked!" % wild_prompt_species
        _schedule_wild_prompt_resolution(wild_id, "PROVOKED", 0.325)
    else:
        # PROVOKE_WARNING (and legacy PROVOKE) is a complete first interaction.
        # The opening A must be released before the warning can be dismissed.
        wild_dialogue_label.text = "%s seems aggressive... it may attack if provoked!" % wild_prompt_species
        # Source DisplayText waits for a fresh confirm before closing.

func _schedule_wild_prompt_resolution(wild_id: int, kind: String, delay: float) -> void:
    main.get_tree().create_timer(delay).timeout.connect(_finish_wild_prompt_resolution.bind(wild_id, kind))

func _finish_wild_prompt_resolution(wild_id: int, kind: String) -> void:
    # Timers are identity-checked so a stale timeout can never close or resolve
    # a later Pokemon prompt. This also gives the first box a real closed gap
    # before a second A is accepted by normal overworld interaction again.
    if (
            not main.wild_pokemon_prompt_open
            or wild_prompt_id != wild_id
            or wild_prompt_kind != kind
        ):
        return
    if kind in ["PROVOKE", "PROVOKE_WARNING"]:
        main.world.mark_wild_provocation_warning(wild_id)
        close_wild_pokemon_prompt()
        return
    if kind == "PROVOKED":
        close_wild_pokemon_prompt()
        main.world.confirm_wild_provocation(wild_id)

func _show_friendly_party_choice() -> void:
    main.wild_pokemon_prompt_stage = 1
    main.wild_pokemon_prompt_index = 0
    wild_dialogue_label.text = "Add %s to your party?" % wild_prompt_species
    wild_dialogue_arrow.visible = false
    main.wild_choice_panel.visible = true
    update_wild_pokemon_prompt_cursor()

func update_wild_pokemon_prompt_cursor() -> void:
    if wild_choice_cursor == null:
        return
    main._align_menu_tick(wild_choice_cursor, main.wild_choice_panel.get_node("Yes" if main.wild_pokemon_prompt_index == 0 else "No"))

func close_wild_pokemon_prompt(restore_gameplay: bool = true) -> void:
    main.wild_pokemon_prompt_open = false
    main.wild_pokemon_prompt_stage = 0
    main.wild_pokemon_prompt_index = 0
    wild_prompt_id = -1
    wild_prompt_species = ""
    wild_prompt_kind = ""
    main.wild_pokemon_prompt_confirm_armed = false
    if main.world != null and main.world.recall_hold == deployed_prompt_id:
        main.world.recall_hold = ""
    if main.wild_dialogue_panel != null:
        main.wild_dialogue_panel.visible = false
    if main.wild_choice_panel != null:
        main.wild_choice_panel.visible = false
    if (
            restore_gameplay and main.started and not main.battle_active
            and not main.game_menu_open and not main.craft_menu_open
            and not main.build_menu_open and not main.storage_menu_open
            and not main.trainer_tip_open and not main.egg_pickup_open
        ):
        main.world.set_gameplay_enabled(true)

func recruit_friendly_wild(wild_id: int, species: String) -> void:
    if not can_receive_overworld_pokemon():
        close_wild_pokemon_prompt()
        main.dialogs.show_message("Your party and storage are full.")
        return
    # Online the host keeps the record of every wild Pokemon. It is claimed and
    # then reported as taken, exactly as a capture in battle is. Taking it from
    # this game alone left it on the host: it came back in the field and could
    # be taken again and again.
    var coop_game = main.coop_game
    var online: bool = is_instance_valid(coop_game) and coop_game.active
    if online:
        close_wild_pokemon_prompt(false)
        # A save or another action on its way must not swallow the answer.
        await coop_game.wait_free()
        coop_game.wild.refused = ""
        if not await coop_game.wild.reserve(wild_id):
            if coop_game.active and not main.battle_active:
                main.world.set_gameplay_enabled(not main._field_ui_blocks_gameplay(main.build_menu_open))
                main.dialogs.show_message(coop_game.population.refusal(
                    coop_game.wild.refused if not coop_game.wild.refused.is_empty() else "too_late", species.to_upper()))
            return
        coop_game.wild.applying = true
    var record = main.world.take_friendly_wild(wild_id)
    if online:
        coop_game.wild.applying = false
    if typeof(record) != TYPE_DICTIONARY or (record as Dictionary).is_empty():
        if online:
            var claimed_area := String(coop_game.wild.encounter.get("area", ""))
            coop_game.wild.encounter.clear()
            coop_game.wild.original_profile.clear()
            await coop_game.command("wild_release", {"area":claimed_area, "wild_id":wild_id})
            if coop_game.active:
                main.world.set_gameplay_enabled(not main._field_ui_blocks_gameplay(main.build_menu_open))
        close_wild_pokemon_prompt()
        main.dialogs.show_message("Too late! %s is no longer here." % species.to_upper())
        return
    var source := (record as Dictionary).duplicate(true)
    var nested_source = source.get("source_record", {})
    if typeof(nested_source) == TYPE_DICTIONARY:
        for raw_key in (nested_source as Dictionary).keys():
            var key := String(raw_key)
            if not source.has(key):
                source[key] = (nested_source as Dictionary)[raw_key]
    for ecology_key in [
            "source_record", "x", "y", "id", "home_biome", "burrowed",
            "move_timer", "anim_phase", "warned", "aggro_player",
            "provocation_count", "provocation_limit", "fed_until",
            "flee_steps", "charmed", "lay_egg_seconds"
        ]:
        source.erase(ecology_key)
    var normalized_species := String(
        source.get("species", species.to_lower())
    ).to_lower()
    var pokemon := BattleEngine.make_pokemon(
        normalized_species, maxi(1, int(source.get("level", 2))), null, source
    )
    var destination := route_received_pokemon(pokemon)
    if not main.caught_species.has(normalized_species):
        main.caught_species.append(normalized_species)
    if online and not await coop_game.wild.finish_encounter("captured"):
        return
    close_wild_pokemon_prompt()
    main.world.play_source_sound("seed1")
    var notice := received_pokemon_notice(pokemon, destination)
    if not notice.is_empty(): main.dialogs.show_message(notice)

func handle_wild_pokemon_prompt_input(event: InputEvent) -> void:
    if wild_prompt_kind in ["PROVOKE", "PROVOKE_WARNING", "PROVOKED"]:
        if not main.wild_pokemon_prompt_confirm_armed:
            if event.is_action_released("confirm") or event.is_action_released("start"):
                main.wild_pokemon_prompt_confirm_armed = true
                main.get_viewport().set_input_as_handled()
            return
        if event.is_action_pressed("confirm") or event.is_action_pressed("start"):
            _finish_wild_prompt_resolution(wild_prompt_id, wild_prompt_kind)
            main.get_viewport().set_input_as_handled()
        return

    # Friendly recruitment keeps its normal explicit A-driven dialogue flow,
    # but still requires release of the opening interaction first.
    if not main.wild_pokemon_prompt_confirm_armed:
        if event.is_action_released("confirm") or event.is_action_released("start"):
            main.wild_pokemon_prompt_confirm_armed = true
            main.get_viewport().set_input_as_handled()
        return

    if main.wild_pokemon_prompt_stage == 0:
        if event.is_action_pressed("confirm") or event.is_action_pressed("start"):
            _show_friendly_party_choice()
            main.get_viewport().set_input_as_handled()
        elif event.is_action_pressed("cancel"):
            close_wild_pokemon_prompt()
            main.get_viewport().set_input_as_handled()
        return

    if event.is_action_pressed("move_up") or event.is_action_pressed("move_down"):
        main.wild_pokemon_prompt_index = 1 - main.wild_pokemon_prompt_index
        update_wild_pokemon_prompt_cursor()
        main.get_viewport().set_input_as_handled()
    elif event.is_action_pressed("cancel"):
        close_wild_pokemon_prompt()
        main.get_viewport().set_input_as_handled()
    elif event.is_action_pressed("confirm") or event.is_action_pressed("start"):
        var chosen_id := wild_prompt_id
        var chosen_species := wild_prompt_species
        if main.wild_pokemon_prompt_index == 0:
            if wild_prompt_kind == "DEPLOYED":
                var cell := deployed_prompt_cell
                var identity := deployed_prompt_id
                close_wild_pokemon_prompt()
                # Where that Pokemon stands now: it may have walked on, and
                # another may have stepped onto the tile it was asked on.
                if not identity.is_empty():
                    for shown in main.world.deployed_pokemon:
                        if String(main.world.deployed_pokemon[shown].get("ecology_id", "")) == identity:
                            cell = shown
                            break
                var data: Dictionary = main.world.deployed_pokemon.get(cell, {})
                if not identity.is_empty() and String(data.get("ecology_id", "")) != identity:
                    data = {"ecology_id": identity}
                # Online the host finds it by its id even when this game no longer shows it.
                if data.has("species") or (is_instance_valid(main.coop_game) and main.coop_game.active):
                    main.world._recall_deployed_pokemon(cell, data)
                else:
                    main.dialogs.show_message("It went away.")
            else:
                recruit_friendly_wild(chosen_id, chosen_species)
        else:
            close_wild_pokemon_prompt()
        main.get_viewport().set_input_as_handled()

func on_egg_pickup_prompt_requested(cell: Vector2i) -> void:
    if main.egg_pickup_open or main.battle_active or main.game_menu_open or main.craft_menu_open or main.build_menu_open:
        return
    main.egg_pickup_open = true
    main.egg_pickup_stage = 0
    main.egg_pickup_index = 0
    egg_pickup_cell = cell
    main.world.set_gameplay_enabled(false)
    main.message_panel.visible = false
    main.egg_dialogue_panel.visible = true
    main.egg_choice_panel.visible = false
    main.egg_dialogue_label.text = "Hey!  A POKéMON\negg!"
    main.egg_dialogue_arrow.visible = true

func _show_egg_pickup_choice() -> void:
    main.egg_pickup_stage = 1
    main.egg_pickup_index = 0
    main.egg_dialogue_label.text = "Pick it up?"
    main.egg_dialogue_arrow.visible = false
    main.egg_choice_panel.visible = true
    update_egg_pickup_cursor()

func update_egg_pickup_cursor() -> void:
    if main.egg_choice_cursor == null:
        return
    # User-requested one-pixel upward adjustment to both egg choice ticks.
    main._align_menu_tick(main.egg_choice_cursor, main.egg_choice_panel.get_node("Yes" if main.egg_pickup_index == 0 else "No"))

func close_egg_pickup_prompt() -> void:
    main.egg_pickup_open = false
    main.egg_pickup_stage = 0
    main.egg_pickup_index = 0
    egg_pickup_cell = Vector2i(-2147483648, -2147483648)
    if main.egg_dialogue_panel != null:
        main.egg_dialogue_panel.visible = false
    if main.egg_choice_panel != null:
        main.egg_choice_panel.visible = false
    if (
            main.started and not main.battle_active and not main.game_menu_open
            and not main.craft_menu_open and not main.build_menu_open
            and not main.storage_menu_open and not main.trainer_tip_open
        ):
        main.world.set_gameplay_enabled(true)

func handle_egg_pickup_input(event: InputEvent) -> void:
    if main.egg_pickup_stage == 0:
        if event.is_action_pressed("confirm") or event.is_action_pressed("start"):
            _show_egg_pickup_choice()
            main.get_viewport().set_input_as_handled()
        elif event.is_action_pressed("cancel"):
            close_egg_pickup_prompt()
            main.get_viewport().set_input_as_handled()
        return

    if event.is_action_pressed("move_up") or event.is_action_pressed("move_down"):
        main.egg_pickup_index = 1 - main.egg_pickup_index
        update_egg_pickup_cursor()
        main.get_viewport().set_input_as_handled()
    elif event.is_action_pressed("cancel"):
        close_egg_pickup_prompt()
        main.get_viewport().set_input_as_handled()
    elif event.is_action_pressed("confirm") or event.is_action_pressed("start"):
        var chosen_cell := egg_pickup_cell
        var take_egg: bool = main.egg_pickup_index == 0
        close_egg_pickup_prompt()
        if take_egg:
            main.world.confirm_wild_egg_pickup(chosen_cell)
        main.get_viewport().set_input_as_handled()

func on_egg_collected(species: String) -> void:
    var egg_record: Dictionary = main.world.take_pending_egg_record()
    if bool(egg_record.get("dropped_party_egg", false)):
        for key in ["dropped_party_egg", "house_door", "house_floor", "x", "y"]: egg_record.erase(key)
        var destination := route_received_pokemon(egg_record)
        main.world.play_source_sound("Berry_Get")
        main.dialogs.show_message("You picked up the EGG." if destination == "PARTY" else "The EGG was sent to storage.")
        return
    if egg_record.is_empty():
        egg_record = {
            "species": species.to_lower(),
            "egg_species": species.to_lower(),
            "level": 5,
            "hatch_cycles": maxi(
                1, int(PokemonData.info(species).get("egg_cycles", 20))
            ),
            "inherited_moves": []
        }
    species = String(egg_record.get(
        "egg_species", egg_record.get("species", species)
    )).to_lower()
    var level := maxi(1, int(egg_record.get("level", 5)))
    var cycles := maxi(1, int(egg_record.get(
        "hatch_cycles", PokemonData.info(species).get("egg_cycles", 20)
    )))
    var egg := pokemon_from_egg_record(egg_record, species, level)
    egg["is_egg"] = true
    egg["egg_species"] = species
    egg["hatch_cycles"] = cycles
    egg["hatch_steps"] = maxi(
        1, cycles * PokemonEcology.EGG_STEP_INTERVAL - main.egg_step_timer
    )
    egg["hp"] = 0
    var destination := route_received_pokemon(egg)
    main.world.play_source_sound("Berry_Get")
    var notice := received_pokemon_notice(egg, destination)
    main.dialogs.show_message("%s received an EGG." % main.player_model_name.text.strip_edges() if notice.is_empty() else notice)

func on_player_stepped() -> void:
    main.egg_step_timer = wrapi(
        main.egg_step_timer + 1, 0, PokemonEcology.EGG_STEP_INTERVAL
    )
    var advance_cycle: bool = main.egg_step_timer == 0
    main.friendship_step_timer = wrapi(
        main.friendship_step_timer + 1,
        0,
        PokemonEcology.FRIENDSHIP_STEP_INTERVAL
    )
    var party: Array = main.caught_pokemon
    if main.friendship_step_timer == 0:
        for party_index in range(party.size()):
            var raw_party_record = party[party_index]
            if typeof(raw_party_record) != TYPE_DICTIONARY:
                continue
            var party_record := raw_party_record as Dictionary
            if bool(party_record.get("is_egg", false)):
                continue
            var happiness := mini(
                PokemonEcology.MAX_HAPPINESS,
                int(party_record.get(
                    "happiness", party_record.get("friendship", 70)
                )) + 1
            )
            party_record["happiness"] = happiness
            party_record["friendship"] = happiness
            party[party_index] = party_record
    for index in range(party.size()):
        if typeof(party[index]) != TYPE_DICTIONARY:
            continue
        var entry: Dictionary = party[index]
        if not bool(entry.get("is_egg", false)):
            continue
        var cycles := int(entry.get("hatch_cycles", -1))
        if cycles < 0:
            cycles = maxi(1, ceili(
                float(entry.get("hatch_steps", main.EGG_HATCH_STEPS))
                / float(PokemonEcology.EGG_STEP_INTERVAL)
            ))
        if advance_cycle:
            cycles = maxi(0, cycles - 1)
        entry["hatch_cycles"] = cycles
        entry["hatch_steps"] = maxi(
            0, cycles * PokemonEcology.EGG_STEP_INTERVAL - main.egg_step_timer
        )
        if cycles > 0:
            party[index] = entry
            continue
        var species := String(entry.get(
            "egg_species", entry.get("species", "pidgey")
        )).to_lower()
        var level := maxi(1, int(entry.get("level", 5)))
        var hatched := pokemon_from_egg_record(entry, species, level)
        hatched["happiness"] = 100
        hatched["friendship"] = 100
        await main.progression.run_egg_hatch_sequence(index, hatched)
        # PlayerStanding returns after the first ready egg; another ready egg
        # is handled on a later step instead of merging hatch sequences.
        return

func ensure_party_ecology_id(index: int) -> String:
    var party: Array = main.caught_pokemon
    if index < 0 or index >= party.size():
        return ""
    var entry = party[index]
    if typeof(entry) != TYPE_DICTIONARY:
        return ""
    var record := entry as Dictionary
    var ecology_id := String(record.get("party_ecology_id", ""))
    var occupied := {}
    var duplicate := false
    for other_index in range(party.size()):
        var other = party[other_index]
        if typeof(other) != TYPE_DICTIONARY: continue
        var other_id := String(other.get("party_ecology_id", ""))
        if not other_id.is_empty(): occupied[other_id] = true
        if other_index < index and not ecology_id.is_empty() and other_id == ecology_id:
            duplicate = true
    if ecology_id.is_empty() or duplicate:
        ecology_id = "party:%d" % main.next_party_ecology_id
        while occupied.has(ecology_id):
            main.next_party_ecology_id += 1
            ecology_id = "party:%d" % main.next_party_ecology_id
        main.next_party_ecology_id += 1
        record["party_ecology_id"] = ecology_id
        party[index] = record
    return ecology_id

func on_pokemon_ecology_changed(pokemon_data: Dictionary) -> void:
    var ecology_id := String(pokemon_data.get("party_ecology_id", ""))
    if ecology_id.is_empty():
        return
    var party: Array = main.caught_pokemon
    for index in range(party.size()):
        var raw_record = party[index]
        if typeof(raw_record) != TYPE_DICTIONARY:
            continue
        var record := raw_record as Dictionary
        if String(record.get("party_ecology_id", "")) != ecology_id:
            continue
        for property in ["happiness", "friendship"]:
            if pokemon_data.has(property):
                record[property] = pokemon_data[property]
        party[index] = record
        return

func pokemon_from_egg_record(
        egg_record: Dictionary, species: String, level: int
    ) -> Dictionary:
    var pokemon := BattleEngine.make_pokemon(species, level, main.battle_rng, egg_record)
    # This helper produces the hatched Pokemon. Egg collection adds its egg
    # markers again afterward, while actual hatching must not retain them.
    for egg_property in ["is_egg", "egg_species", "hatch_cycles", "hatch_steps"]:
        pokemon.erase(egg_property)
    for property in [
            "gender", "shiny", "is_shiny", "generation",
            "parent_ids", "inherited_moves", "personality", "nature",
            "ability_slot", "ivs", "evs", "original_trainer", "trainer_id",
            "met_level", "met_location", "pokeball", "ribbons", "markings", "pokerus"
        ]:
        if egg_record.has(property):
            pokemon[property] = egg_record[property]
    if egg_record.has("shiny") or egg_record.has("is_shiny") or egg_record.has("isShiny"):
        pokemon["shiny"] = PokemonData.is_shiny(egg_record)
        pokemon["is_shiny"] = bool(pokemon["shiny"])

    var moves: Array[String] = []
    for raw_move in pokemon.get("moves", []):
        moves.append(String(raw_move).to_upper().replace(" ", "_"))
    var inherited_index := moves.size() if moves.size() < 4 else 0
    var inherited = egg_record.get("inherited_moves", [])
    if typeof(inherited) == TYPE_ARRAY:
        for raw_move in inherited:
            var move := String(raw_move).to_upper().replace(" ", "_")
            if PokemonData.move_info(move).is_empty() or moves.has(move):
                continue
            if moves.size() < 4:
                moves.append(move)
            else:
                moves[inherited_index] = move
            inherited_index = (inherited_index + 1) % 4
    pokemon["moves"] = moves
    var pp := {}
    for move in moves:
        pp[move] = int(PokemonData.move_info(move).get("pp", 35))
    pokemon["pp"] = pp
    pokemon["hp"] = maxi(1, int(pokemon.get("max_hp", 1)))
    pokemon["status"] = ""
    pokemon["status_counter"] = 0
    pokemon["toxic_counter"] = 0
    return pokemon
