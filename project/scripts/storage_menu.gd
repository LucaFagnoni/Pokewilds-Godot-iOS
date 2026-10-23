extends RefCounted

## The Pokemon storage screen of a STORAGE BOX or SHARED chest, and of STORAGE in
## the game menu (every box at once): deposit, withdraw, swap, nickname, release.
## Split out of main.gd; reaches the game through `main`.

const PokemonState = preload("res://scripts/pokemon_state.gd")
const FieldMoveData = preload("res://scripts/field_move_data.gd")
const JOHTO_FONT := preload("res://assets/source_text_font.fnt")

var main: GameMain
var storage_menu: Control
var storage_actions: Panel
var storage_footer_arrow: TextureRect
var storage_choice_panel: Panel
var storage_choice_arrow: TextureRect
var storage_dialog: Panel
var storage_dialog_text: Label
var storage_cursor: TextureRect
var storage_prompt: Label

func _init(owner_main: GameMain) -> void:
    main = owner_main

func build_storage_menu_ui() -> void:
    # Source-style Pokémon storage screen.  It is deliberately created here
    # rather than replacing the existing party menu, so opening a chest cannot
    # perturb unrelated menu geometry.
    storage_menu = Control.new()
    storage_menu.name = "PokemonStorageMenu"
    storage_menu.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    storage_menu.z_index = 345
    storage_menu.visible = false
    main.get_node("UI").add_child(storage_menu)
    var storage_backdrop = ColorRect.new()
    storage_backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    storage_backdrop.color = Color.WHITE
    storage_backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
    storage_menu.add_child(storage_backdrop)
    var storage_footer = Panel.new()
    storage_footer.position = Vector2(0, 144)
    storage_footer.size = Vector2(320, 36)
    storage_footer.add_theme_stylebox_override("panel", main._classic_dialogue_style())
    storage_menu.add_child(storage_footer)
    for index in range(6):
        var row := main.party_menu.create_party_list_row(storage_menu, index)
        var skills := main._source_ui_label(row.root,"FieldMoves",Vector2(30,19),Vector2(132,9),8)
        row["field_moves"] = skills
        row.gender.position.x = 166
        row.level.position.x = 179
        row.root.get_node("HPBadge").position.x = 211
        var track: Control = row.root.get_node("HPTrack")
        track.position.x = 228
        track.size.x = 90
        track.get_node("BottomRule").size.x = 90
        track.get_node("EndCap").position.x = 85
        row.hp_capacity = 85.0
        main.storage_rows.append(row)
    storage_prompt = main._source_ui_label(storage_menu, "Footer",
        Vector2(16, 151), Vector2(288, 18), 11)
    storage_prompt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    storage_actions = Panel.new()
    storage_actions.position = Vector2(96, 48)
    storage_actions.size = Vector2(224, 132)
    storage_actions.add_theme_stylebox_override("panel", main._classic_dialogue_style())
    storage_menu.add_child(storage_actions)
    for index in range(7):
        main.storage_action_labels.append(main._source_ui_label(storage_actions, "Action%d" % index,
            Vector2(24, 9 + index * 20), Vector2(126, 18), 11))
    storage_footer_arrow = main._source_texture_rect(storage_menu, "PageArrow",
        Vector2(292, 153), Vector2(5, 7), main.source_command_cursor.texture)
    storage_cursor = main._source_texture_rect(storage_actions, "Cursor",
        Vector2(10, 9), Vector2(5, 7), main.source_command_cursor.texture)
    storage_dialog = Panel.new()
    storage_dialog.position = Vector2(0, 126)
    storage_dialog.size = Vector2(320, 54)
    storage_dialog.add_theme_stylebox_override("panel", main._classic_dialogue_style())
    storage_menu.add_child(storage_dialog)
    storage_dialog_text = main._source_ui_label(storage_dialog, "Text",
        Vector2(10, 6), Vector2(300, 44), 10)
    storage_dialog_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    storage_choice_panel = Panel.new()
    storage_choice_panel.position = Vector2(240, 74)
    storage_choice_panel.size = Vector2(80, 52)
    storage_choice_panel.add_theme_stylebox_override("panel", main._classic_dialogue_style())
    storage_menu.add_child(storage_choice_panel)
    storage_choice_arrow = main._source_texture_rect(storage_choice_panel, "ChoiceArrow",
        Vector2(10, 12), Vector2(5, 7), main.source_command_cursor.texture)
    main.storage_choice_label = main._source_ui_label(storage_choice_panel, "Choices",
        Vector2(24, 8), Vector2(48, 16), 10, "YES")
    main.storage_no_label = main._source_ui_label(storage_choice_panel, "NoChoice",
        Vector2(24, 30), Vector2(48, 16), 10, "NO")
    main.storage_nickname = LineEdit.new()
    main.storage_nickname.position = Vector2(10, 23)
    main.storage_nickname.size = Vector2(290, 24)
    main.storage_nickname.max_length = 10
    main.storage_nickname.add_theme_font_override("font", JOHTO_FONT)
    main.storage_nickname.add_theme_font_size_override("font_size", 10)
    storage_dialog.add_child(main.storage_nickname)
    main.storage_nickname.text_changed.connect(func(value: String):
        var filtered := ""
        for character in value:
            if character in "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 .?!":
                filtered += character
        if filtered != value:
            var caret := main.storage_nickname.caret_column
            main.storage_nickname.text = filtered
            main.storage_nickname.caret_column = mini(caret, filtered.length()))
    main.storage_nickname.text_submitted.connect(func(_text: String):
        main.storage_nickname.release_focus()
        main.storage_mode = "CONFIRM"
        main.storage_pending = "NICKNAME"
        main.storage_yes = true
        refresh_storage_menu())

func _storage_entry_text(pokemon: Dictionary) -> String:
    if bool(pokemon.get("is_egg", false)):
        return "EGG"
    var display := PokemonState.display_name(pokemon).replace("_", " ").to_upper()
    return "%s  L%d" % [display, int(pokemon.get("level", 1))]

func open_storage_menu(box_key: String) -> void:
    if is_instance_valid(main.coop_game) and main.coop_game.active:
        # Preparing has the host pack and save the whole area and send every
        # shared record back, which took seconds and stalled the host. It is
        # only needed for a box the shared world does not know yet.
        if not main.coop_game.storage.known(world_storage_key(box_key,main.current_world_grid)):
            if not await main.coop_game.storage.prepare():main.dialogs.show_message("ONLINE STORAGE COULD NOT LOAD.");return
    var shared_chest: bool = not (is_instance_valid(main.coop_game) and main.coop_game.active) and \
        String(main.world.built_structures.get(main.world._cell_from_key(box_key), {}).get("name", "")) == "PRIVATE CHEST"
    box_key = main.SHARED_STORAGE_KEY if shared_chest else world_storage_key(box_key,main.current_world_grid)
    main.storage_pooled = false
    main.storage_box_key = box_key
    if is_instance_valid(main.coop_game) and main.coop_game.active:main.coop_game.storage.refresh()
    # A Pokemon caught with a full party goes to the last STORAGE BOX used,
    # never to the SHARED chest.
    if not shared_chest: main.preferred_storage_box = box_key
    if not main.pokemon_storage.has(main.storage_box_key):
        main.pokemon_storage[main.storage_box_key] = []
    main.storage_column = 0
    main.storage_index = 0
    main.storage_box_window_start = 0
    main.storage_mode = "LIST"
    main.storage_switch_from = -1
    main.storage_menu_open = true
    storage_menu.visible = true
    main.message_panel.visible = false
    main.world.set_gameplay_enabled(false)
    main.touch_controls.set_game_active(true)
    refresh_storage_menu()

func open_pooled_storage_menu() -> void:
    # Opening the worldwide view must not change the last physical box used.
    main.storage_pooled = true
    main.storage_box_key = ""
    if is_instance_valid(main.coop_game) and main.coop_game.active: main.coop_game.storage.refresh()
    main.storage_column = 1
    main.storage_index = 0
    main.storage_box_window_start = 0
    main.storage_mode = "LIST"
    main.storage_switch_from = -1
    main.storage_menu_open = true
    main.game_menu_box.hide()
    storage_menu.show()
    main.message_panel.hide()
    main.world.set_gameplay_enabled(false)
    refresh_storage_menu()

func storage_pool_locations() -> Array:
    var locations: Array = []
    var keys: Array = main.pokemon_storage.keys()
    keys.sort()
    for key in keys:
        # The SHARED chest is opened only at a SHARED chest.
        if String(key) == main.SHARED_STORAGE_KEY and not (is_instance_valid(main.coop_game) and main.coop_game.active): continue
        for index in range(main.pokemon_storage[key].size()):
            locations.append([key, index])
    if is_instance_valid(main.coop_game) and main.coop_game.active and not main.coop_game.storage.sort_mode.is_empty():
        locations.sort_custom(func(a,b):return main.coop_game.storage.sort_less(main.pokemon_storage[a[0]][a[1]],main.pokemon_storage[b[0]][b[1]]))
    return locations

func storage_deposit_key() -> String:
    if not main.storage_pooled:
        return main.storage_box_key
    if not main.preferred_storage_box.is_empty() and main.pokemon_storage.has(main.preferred_storage_box):
        return main.preferred_storage_box
    var keys := built_storage_keys()
    if not keys.is_empty():
        return keys[0]
    var saved: Array = main.pokemon_storage.keys()
    saved.sort()
    return String(saved[0]) if not saved.is_empty() else ""

func storage_entries() -> Array:
    if main.storage_column == 0:
        return main.caught_pokemon
    if not main.storage_pooled:
        return main.pokemon_storage.get(main.storage_box_key, [])
    var entries: Array = []
    for location in storage_pool_locations():
        entries.append(main.pokemon_storage[location[0]][location[1]])
    return entries

func _storage_swap(first: int, second: int) -> void:
    if is_instance_valid(main.coop_game) and main.coop_game.active and main.storage_column==1:
        await main.coop_game.storage.swap(second)
        return
    if main.storage_pooled and main.storage_column == 1:
        var locations := storage_pool_locations()
        var a: Array = locations[first]
        var b: Array = locations[second]
        var previous = main.pokemon_storage[a[0]][a[1]]
        main.pokemon_storage[a[0]][a[1]] = main.pokemon_storage[b[0]][b[1]]
        main.pokemon_storage[b[0]][b[1]] = previous
    else:
        var entries := storage_entries()
        var previous = entries[first]
        entries[first] = entries[second]
        entries[second] = previous

func refresh_storage_menu() -> void:
    if not main.storage_menu_open:
        return
    var entries := storage_entries()
    main.storage_index = clampi(main.storage_index, 0, maxi(0, entries.size() - 1))
    main.storage_box_window_start = clampi(main.storage_box_window_start,
        maxi(0, main.storage_index - 5), main.storage_index)
    main.party_menu.refresh_party_list_rows(main.storage_rows,
        entries.slice(main.storage_box_window_start, main.storage_box_window_start + 6),
        main.storage_index - main.storage_box_window_start)
    for row_index in range(main.storage_rows.size()):
        var row: Dictionary = main.storage_rows[row_index]
        var skill_label: Label = row.field_moves
        var entry_index := main.storage_box_window_start + row_index
        skill_label.text = ""
        if entry_index == main.storage_index and entry_index < entries.size() and not entries[entry_index].get("is_egg",false):
            var pokemon: Dictionary = entries[entry_index]
            skill_label.text = " / ".join(FieldMoveData.field_moves_for(String(pokemon.species),String(pokemon.get("form",""))))
            var width := skill_label.get_theme_font("font").get_string_size(skill_label.text,HORIZONTAL_ALIGNMENT_LEFT,-1,8).x
            skill_label.scale.x = minf(1.0,132.0/maxf(1.0,width))
        row.status.visible = skill_label.text.is_empty()
    storage_prompt.text = "Your POKéMON" if main.storage_column == 0 else "Stored POKéMON"
    storage_footer_arrow.position.x = 292 if main.storage_column == 0 else 18
    storage_footer_arrow.flip_h = main.storage_column == 1
    if main.storage_mode == "SWITCH":
        storage_prompt.text = "Switch with which POKéMON?"
    storage_actions.visible = main.storage_mode == "ACTION"
    var actions := _storage_actions_list()
    main.storage_action_index=clampi(main.storage_action_index,0,actions.size()-1)
    for index in range(main.storage_action_labels.size()):
        main.storage_action_labels[index].visible=index<actions.size()
        if index>=actions.size():continue
        main.storage_action_labels[index].position.y=9+index*(17 if actions.size()==7 else 20)
        main.storage_action_labels[index].text = actions[index]
    storage_choice_panel.visible = main.storage_mode == "CONFIRM"
    storage_choice_arrow.visible = main.storage_mode == "CONFIRM"
    main.storage_choice_label.visible = main.storage_mode == "CONFIRM"
    main._align_menu_tick(storage_choice_arrow, main.storage_choice_label if main.storage_yes else main.storage_no_label)
    main._align_menu_tick(storage_cursor, main.storage_action_labels[main.storage_action_index])
    storage_dialog.visible = main.storage_mode in ["CONFIRM", "NOTICE", "NICKNAME"]
    main.storage_nickname.visible = main.storage_mode == "NICKNAME"
    if main.storage_mode == "NICKNAME":
        storage_dialog_text.text = "Press enter to set"
    elif main.storage_mode == "CONFIRM":
        var question := "Store POKéMON of this type?" if main.storage_pending=="STORE TYPE" else "Move to storage?" if main.storage_pending == "STORE" else "Add to your party?"
        if main.storage_pending == "RELEASE":
            question = "Release %s to the wild? This can't be undone!" % (PokemonState.display_name(entries[main.storage_index]) if main.storage_index<entries.size() else "this POKéMON")
        elif main.storage_pending == "NICKNAME":
            question = "Keep changes?"
        storage_dialog_text.text = question
        main.storage_choice_label.text = "YES"

func storage_notice(text: String) -> void:
    main.storage_mode = "NOTICE"
    storage_dialog_text.text = text
    main.world.call("play_source_sound", "error1")
    refresh_storage_menu()

func storage_is_active(pokemon: Dictionary) -> bool:
    var active: Dictionary = main.world.get("active_field_pokemon")
    if active.is_empty():
        return false
    var identity := String(active.get("party_ecology_id", ""))
    if not identity.is_empty():
        return identity == String(pokemon.get("party_ecology_id", ""))
    if int(active.get("ecology_id", -1)) >= 0:
        return int(active.ecology_id) == int(pokemon.get("ecology_id", -2))
    return is_same(active, pokemon)

func _storage_actions_list()->Array:
    var actions=["STORE" if main.storage_column==0 else "TAKE","RELEASE","NICKNAME","STATS","SWITCH","CANCEL"]
    if is_instance_valid(main.coop_game) and main.coop_game.active and main.storage_column==0:actions.insert(1,"STORE TYPE")
    return actions

func _storage_choose_action() -> void:
    var entries := storage_entries()
    if entries.is_empty():
        return
    var pokemon: Dictionary = entries[main.storage_index]
    if is_instance_valid(main.coop_game) and main.coop_game.active:main.coop_game.storage.select()
    main.storage_pending = _storage_actions_list()[main.storage_action_index]
    if main.storage_pending == "CANCEL":
        main.storage_mode = "LIST"
    elif main.storage_pending == "STATS":
        main.party_menu.open_pokemon_stats(pokemon, "STORAGE")
    elif main.storage_pending == "SWITCH":
        main.storage_switch_from = main.storage_index
        main.storage_mode = "SWITCH"
    elif main.storage_pending == "NICKNAME":
        main.storage_mode = "NICKNAME"
        main.storage_nickname.text = PokemonState.display_name(pokemon)
        main.storage_nickname.call_deferred("grab_focus")
    else:
        if main.storage_column == 0 and main.storage_pending in ["STORE", "RELEASE"] and storage_is_active(pokemon) and String(main.world.active_field_move) in ["SURF", "FLY"]:
            storage_notice("Stop the field move before moving this POKéMON.")
            return
        if main.storage_pending in ["STORE","STORE TYPE"]:
            if storage_deposit_key().is_empty():
                storage_notice("Build a STORAGE BOX first.")
                return
            var healthy := false
            for index in range(entries.size()):
                if index != main.storage_index and not bool(entries[index].get("is_egg", false)) and int(entries[index].get("hp", 0)) > 0:
                    healthy = true
            if not healthy:
                storage_notice("You need at least 1 healthy POKéMON in your party.")
                return
            if storage_is_active(pokemon) and String(main.world.get("active_field_move")) == "SURF":
                storage_notice("Can't store a POKéMON that's using SURF.")
                return
        elif main.storage_pending == "TAKE" and main.caught_pokemon.size() >= 6:
            storage_notice("Your party is full!")
            return
        elif main.storage_pending == "RELEASE" and main.storage_column == 0 and entries.size() <= 1:
            storage_notice("You need at least 1 POKéMON in your party.")
            return
        main.storage_yes = main.storage_pending != "RELEASE"
        main.storage_mode = "CONFIRM"
    refresh_storage_menu()

func _storage_apply_action() -> void:
    if is_instance_valid(main.coop_game) and main.coop_game.active:
        await main.coop_game.storage.apply()
        return
    var entries := storage_entries()
    if entries.is_empty():
        return
    var pokemon: Dictionary = entries[main.storage_index]
    if main.storage_pending == "NICKNAME":
        pokemon["nickname"] = main.storage_nickname.text
        main.world.call("play_source_sound", "coin1")
        return
    if main.storage_column == 0 and storage_is_active(pokemon):
        main.world.call("clear_active_field_move", true)
    if main.storage_pooled and main.storage_column == 1:
        var location: Array = storage_pool_locations()[main.storage_index]
        main.pokemon_storage[location[0]].remove_at(location[1])
    else:
        entries.remove_at(main.storage_index)
    if main.storage_pending == "STORE":
        var destination := storage_deposit_key()
        var box: Array = main.pokemon_storage.get(destination, [])
        box.append(pokemon)
        main.pokemon_storage[destination] = box
    elif main.storage_pending == "TAKE":
        main.caught_pokemon.append(pokemon)
    if main.storage_pending != "RELEASE":
        main.world.call("play_source_sound", "ball_switch1")
    else:
        main._play_pokemon_cry(pokemon)

func handle_storage_menu_input(event: InputEvent) -> void:
    if is_instance_valid(main.coop_game) and main.coop_game.active and main.coop_game.storage.handle_key(event):
        main.get_viewport().set_input_as_handled();return
    if is_instance_valid(main.coop_game) and main.coop_game.active and main.coop_game.storage.busy:
        main.get_viewport().set_input_as_handled();return
    if main.pokemon_stats_open:
        main.party_menu.handle_pokemon_stats_input(event)
        return
    if main.storage_mode == "NICKNAME":
        if event.is_action_pressed("cancel") and not (event is InputEventKey and event.unicode > 0):
            main.storage_nickname.release_focus()
            main.storage_mode = "LIST"
            refresh_storage_menu()
        return
    if event.is_action_pressed("cancel") or event.is_action_pressed("start"):
        if main.storage_mode == "LIST":
            _close_storage_menu()
        else:
            main.storage_mode = "LIST"
            main.storage_switch_from = -1
            refresh_storage_menu()
    elif main.storage_mode == "NOTICE":
        if event.is_action_pressed("confirm"):
            main.storage_mode = "LIST"
            refresh_storage_menu()
    elif main.storage_mode == "CONFIRM":
        if event.is_action_pressed("move_up") or event.is_action_pressed("move_left"):
            main.storage_yes = true
        elif event.is_action_pressed("move_down") or event.is_action_pressed("move_right"):
            main.storage_yes = false
        elif event.is_action_pressed("confirm"):
            if main.storage_yes:
                await _storage_apply_action()
            if main.storage_mode!="NOTICE":main.storage_mode = "LIST"
        refresh_storage_menu()
    elif main.storage_mode == "ACTION":
        if event.is_action_pressed("move_up"):
            main.storage_action_index = maxi(0, main.storage_action_index - 1)
        elif event.is_action_pressed("move_down"):
            main.storage_action_index = mini(_storage_actions_list().size()-1, main.storage_action_index + 1)
        elif event.is_action_pressed("confirm"):
            _storage_choose_action()
        refresh_storage_menu()
    else:
        var entries := storage_entries()
        if main.storage_mode == "LIST" and (event.is_action_pressed("move_left") or event.is_action_pressed("move_right")):
            main.storage_column = 0 if event.is_action_pressed("move_left") else 1
            main.storage_index = 0
            main.storage_box_window_start = 0
            main.world.call("play_source_sound", "menu_switch2")
        elif event.is_action_pressed("move_up"):
            main.storage_index = maxi(0, main.storage_index - 1)
        elif event.is_action_pressed("move_down"):
            main.storage_index = mini(maxi(0, entries.size() - 1), main.storage_index + 1)
        elif event.is_action_pressed("confirm") and not entries.is_empty():
            if main.storage_mode == "SWITCH":
                await _storage_swap(main.storage_switch_from, main.storage_index)
                main.storage_switch_from = -1
                if main.storage_mode!="NOTICE":main.storage_mode = "LIST"
            else:
                main.storage_mode = "ACTION"
                main.storage_action_index = 0
        refresh_storage_menu()
    main.get_viewport().set_input_as_handled()

func _close_storage_menu() -> void:
    if main.storage_pooled and main.game_menu_open:
        main.game_menu_box.show()
        main.start_menu.update_game_menu_cursor()
    var was_pooled := main.storage_pooled
    main.storage_pooled = false
    main.storage_menu_open = false
    storage_menu.visible = false
    if was_pooled and is_instance_valid(main.coop_game) and main.coop_game.active: main.coop_game.storage.refresh()
    main.storage_box_key = ""
    main.storage_column = 0
    main.storage_index = 0
    main.storage_box_window_start = 0
    if (
            main.started
            and not main.battle_active
            and not main.game_menu_open
            and not main.craft_menu_open
            and not main.build_menu_open
            and not main.trainer_tip_open
        ):
        main.world.set_gameplay_enabled(true)

## How many public STORAGE BOXES stand in this world.
func public_box_count() -> int:
    # Counted from the boxes that are actually built. Online the host makes
    # the same count over the whole world and has the last word.
    var count := 0
    for cell in main.world.built_structures:
        if String(main.world.built_structures[cell].get("name", "")) == "STORAGE BOX": count += 1
    # Neighbouring sections belong to a single-player world. Online the host
    # counts the whole world itself.
    if is_instance_valid(main.coop_game) and main.coop_game.active: return count
    for grid_key in main.adjacent_worlds:
        if grid_key == main._world_grid_key(main.current_world_grid): continue
        for piece in main.adjacent_worlds[grid_key].get("state",{}).get("structures",[]):
            if piece.get("name","") == "STORAGE BOX": count += 1
    return count

func world_storage_key(cell_key: String, grid: Vector2i) -> String:
    var qualified := main._world_grid_key(grid) + "|" + cell_key
    # Preserve legacy boxes and their contents; never discard unqualified saves.
    if not main.pokemon_storage.has(qualified) and main.pokemon_storage.has(cell_key): return cell_key
    return qualified

func built_storage_keys() -> Array[String]:
    var keys: Array[String] = []
    for cell in main.world.built_structures:
        if String(main.world.built_structures[cell].get("name", "")) == "STORAGE BOX":
            var key := world_storage_key(main.world._cell_key(cell),main.current_world_grid)
            if not key in keys: keys.append(key)
    for grid_key in main.adjacent_worlds:
        if grid_key == main._world_grid_key(main.current_world_grid): continue
        var pieces = String(grid_key).split(",")
        if pieces.size()!=2: continue
        var grid := Vector2i(int(pieces[0]),int(pieces[1]))
        for piece in main.adjacent_worlds[grid_key].get("state",{}).get("structures",[]):
            if piece.get("name","")!="STORAGE BOX": continue
            var key := world_storage_key(main.world._cell_key(Vector2i(int(piece.x),int(piece.y))),grid)
            if not key in keys: keys.append(key)
    # Previously saved contents stay reachable even if the physical box was cut.
    for key in main.pokemon_storage:
        if String(key) != main.SHARED_STORAGE_KEY and not String(key) in keys: keys.append(String(key))
    keys.sort()
    if main.preferred_storage_box in keys:
        keys.erase(main.preferred_storage_box)
        keys.push_front(main.preferred_storage_box)
    return keys
