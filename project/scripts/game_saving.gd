extends RefCounted

## What a single-player save holds and how it is written and read back: the
## capture of the game, the threaded write with the shared storage and index,
## the autosave on pause, and the restore of a loaded save. world_saves.gd
## keeps the files themselves.
## Split out of main.gd; reaches the game through `main`.

const GameOptions = preload("res://scripts/game_options.gd")
const WorldSaves = preload("res://scripts/world_saves.gd")
const PokemonEcology = preload("res://scripts/pokemon_ecology.gd")
const CraftingData = preload("res://scripts/crafting_data.gd")

var main: GameMain

func _init(owner_main: GameMain) -> void:
    main = owner_main

func capture_game_save(version: int = 2, personal_only: bool = false) -> Dictionary:
    var player = main.world.get_node("Player")
    var world_name = main.world_edit.text.strip_edges()
    if world_name.is_empty():
        world_name = "PokeWilds"

    return {
        "version": version,
        "world_seed": int(main.world.get("world_seed")),
        "world_size": int(main.world.get("map_size_index")),
        "world_name": world_name,
        "player_name": main.player_model_name.text,
        "player_name_custom": not main.custom_player_name.is_empty(),
        "player_color": main.player_color_index,
        "player_model": main.player_model_index,
        "player_x": player.position.x,
        "player_y": player.position.y,
        "options": GameOptions.values.duplicate(),
        "waypoints": main.map_waypoints.duplicate(true),
        "pokedex": main.pokedex_progress.entries.duplicate(),
        "pokedex_shiny": main.pokedex_progress.shiny_entries.duplicate(),
        "caught_pokemon": main.caught_pokemon,
        "pokemon_storage": main.pokemon_storage,
        "preferred_storage_box": main.preferred_storage_box,
        "inventory": main.inventory,
        "source_key_items_initialized": true,
        "egg_step_timer": main.egg_step_timer,
        "friendship_step_timer": main.friendship_step_timer,
        "next_party_ecology_id": main.next_party_ecology_id,
        "adjacent_worlds": main.adjacent_worlds,
        "world_grid_x": main.current_world_grid.x,
        "world_grid_y": main.current_world_grid.y,
        "crafting_state": preload("res://scripts/coop_world_snapshot.gd").capture_personal(main.world) if personal_only else main.world.get_crafting_save_state()
    }

func save_current_game() -> void:
    main._sync_pokedex_owned()
    if not main.saves.ensure_directory():
        main.start_menu.close_save_confirmation()
        main.dialogs.show_message("SAVE FAILED.")
        return

    var data = capture_game_save()
    if main.coop_game.active:
        var saved_ok: bool = await main.coop_game.save_game(data)
        main.start_menu.close_save_confirmation()
        if saved_ok:
            main.start_menu.close_game_menu();main.world.call("play_source_sound","save1");main.dialogs.show_message("GAME SAVED.")
        else: main.dialogs.show_message("SAVE FAILED.")
        return

    var error: Error = await write_single_player_save(data)
    if error != OK:
        main.start_menu.close_save_confirmation()
        main.dialogs.show_message("SAVE FAILED.")
        return

    await main.shared_save_folder.export_files(main)
    main.start_menu.close_save_confirmation()
    main.start_menu.close_game_menu()
    main.world.call("play_source_sound", "save1")
    if main.shared_storage_error == OK:
        main.dialogs.show_message("GAME SAVED.")
    else:
        main.dialogs.show_message("GAME SAVED, but the STORAGE BOXES could not be saved.")

## The single-player save and what goes with it, for the SAVE menu and the save
## before quitting. The save grows with play, so it is encoded and written on
## save_thread from a copy of `data` (_save_snapshot); one save at a time.
func write_single_player_save(data: Dictionary) -> Error:
    while main.save_thread != null:
        await main.get_tree().process_frame
    var save_path := _prepare_single_player_save(data)
    if save_path.is_empty():
        return ERR_CANT_CREATE
    main.save_thread = Thread.new()
    main.save_thread.start(WorldSaves.write_manual.bind(save_path, _save_snapshot(data)))
    while main.save_thread.is_alive():
        await main.get_tree().process_frame
    var error: Error = main.save_thread.wait_to_finish()
    main.save_thread = null
    return _finish_single_player_save(data, save_path, error)

## `data` (_capture_game_save) as the save thread may read it while the game
## goes on. Copying all of it held the game ~35 ms on a long-played save, and
## var_to_bytes was slower still; only what the game keeps changing is copied.
## crafting_state is made for this save, and a neighbouring world's state is
## replaced, never changed, when travelling: only the world played now may
## share records with the game (restore_crafting_save_state keeps them).
func _save_snapshot(data: Dictionary) -> Dictionary:
    var snapshot := {}
    var here := main._world_grid_key(main.current_world_grid)
    for key in data:
        var value = data[key]
        if key == "adjacent_worlds":
            value = (value as Dictionary).duplicate()
            if value.has(here): value[here] = value[here].duplicate(true)
        elif key != "crafting_state" and (value is Dictionary or value is Array):
            value = value.duplicate(true)
        snapshot[key] = value
    return snapshot

## The save's path, once the folder is there and `data` carries the storage serial.
func _prepare_single_player_save(data: Dictionary) -> String:
    if not main.saves.ensure_directory():
        return ""
    data["storage_shared"] = true
    data["storage_serial"] = main.shared_storage_serial + 1
    return main.saves.path_for_world(String(data.world_name))

func _finish_single_player_save(data: Dictionary, save_path: String, error: Error) -> Error:
    if error != OK:
        push_error("%s could not be saved (%d)." % [save_path, error])
        return error
    _write_shared_storage()
    main.saves.write_index(String(data.world_name), save_path)
    main.world_edit.text = String(data.world_name)
    main._save_setup()
    return OK

## iOS may end a suspended app without warning: autosave when it goes to the
## background, whenever the SAVE menu could be opened, before returning (no
## thread). Online worlds keep their own journal.
func save_on_pause() -> void:
    if not main.started or main.generating or main.battle_active or main.edge_travel_busy or main.coop_game.active or \
            (main.field_item_busy and not main.bag_menu.sleeping_bag_active()):
        return
    _wait_for_save_thread()
    main._sync_pokedex_owned()
    var data := capture_game_save()
    # The game's own save: the autosave, never the player's SAVE.
    var save_path := _prepare_single_player_save(data)
    if not save_path.is_empty():
        save_path = WorldSaves.autosave_path(save_path)
        _finish_single_player_save(data, save_path, WorldSaves.write(save_path, data))

## A save being written lands before another starts or the game goes away.
## The coroutine that started it still joins the thread.
func _wait_for_save_thread() -> void:
    while main.save_thread != null and main.save_thread.is_alive():
        OS.delay_msec(1)

## Writes the SHARED chest's contents after the save that goes with them, so
## that what is stored always matches a saved party. If this write is lost,
## that save's own copy is the newer one and is used when it is next loaded.
func _write_shared_storage() -> void:
    main.shared_storage_serial += 1
    var held = main.pokemon_storage.get(main.SHARED_STORAGE_KEY, [])
    main.shared_storage_error = preload("res://scripts/shared_storage.gd").write(
        {main.SHARED_STORAGE_KEY: held if held is Array else []}, main.shared_storage_serial)
    if main.shared_storage_error != OK:
        push_error("Shared storage could not be written (%d)." % main.shared_storage_error)

func read_game_save(world_name: String):
    return main.saves.find(world_name).get("data", {})

func restore_game_save(data) -> void:
    GameOptions.restore_game_options(data.get("options", {}),String(data.get("world_name","")))
    main._apply_game_options()
    main.map_waypoints = (data.get("waypoints", {}) as Dictionary).duplicate(true)
    if not is_instance_valid(main.waypoint_ui):
        main.waypoint_ui=preload("res://scripts/map_waypoints.gd").new();main.add_child(main.waypoint_ui);main.waypoint_ui.configure(main)
    main.pokedex_progress.restore(data.get("pokedex", {}))
    main.pokedex_progress.restore_shiny(data.get("pokedex_shiny", {}))
    main.adjacent_worlds = (data.get("adjacent_worlds", {}) as Dictionary).duplicate(true)
    main.current_world_grid = Vector2i(int(data.get("world_grid_x", 0)), int(data.get("world_grid_y", 0)))
    main.world_edit.text = String(data.get("world_name", main.world_edit.text))
    main.player_color_index = clampi(
        int(data.get("player_color", main.player_color_index)),
        0,
        main.PLAYER_TEXTURES.size() - 1
    )
    main.player_model_index = clampi(
        int(data.get("player_model", main.player_model_index)),
        0,
        main._player_model_count() - 1
    )
    var saved_player_name := String(data.get("player_name", "")).strip_edges().left(24)
    var was_custom := bool(data.get("player_name_custom", not saved_player_name.is_empty() and saved_player_name.to_upper() != main.PLAYER_MODEL_NAMES[main.player_model_index].to_upper()))
    main.custom_player_name = saved_player_name if was_custom else ""
    main._apply_player_appearance()
    main._apply_world_player_textures()
    main.egg_step_timer = clampi(
        int(data.get("egg_step_timer", 0)),
        0,
        PokemonEcology.EGG_STEP_INTERVAL - 1
    )
    main.friendship_step_timer = clampi(
        int(data.get("friendship_step_timer", 0)),
        0,
        PokemonEcology.FRIENDSHIP_STEP_INTERVAL - 1
    )
    main.next_party_ecology_id = maxi(
        1, int(data.get("next_party_ecology_id", 1))
    )

    main.caught_pokemon.clear()
    main.caught_species.clear()
    var saved_party = data.get("caught_pokemon", [])
    if typeof(saved_party) == TYPE_ARRAY:
        for entry in saved_party:
            if typeof(entry) == TYPE_DICTIONARY:
                main.caught_pokemon.append(entry)
                var species = String(entry.get("species", ""))
                if not species.is_empty() and not main.caught_species.has(species):
                    main.caught_species.append(species)

    var saved_inventory = data.get("inventory", {})
    if typeof(saved_inventory) == TYPE_DICTIONARY:
        main.inventory = CraftingData.ensure_inventory(saved_inventory)
    else:
        main.inventory = CraftingData.ensure_inventory(main.STARTING_INVENTORY)
    if not bool(data.get("source_key_items_initialized", false)):
        main.inventory["SLEEPING BAG"] = maxi(1, int(main.inventory.get("SLEEPING BAG", 0)))
        main.inventory["ESCAPE ROPE"] = maxi(1, int(main.inventory.get("ESCAPE ROPE", 0)))

    main.preferred_storage_box = String(data.get("preferred_storage_box", ""))
    var saved_storage = data.get("pokemon_storage", {})
    main.pokemon_storage = saved_storage.duplicate(true) if typeof(saved_storage) == TYPE_DICTIONARY else {}

    var crafting_state = data.get("crafting_state", {})
    if typeof(crafting_state) == TYPE_DICTIONARY:
        await main.world.restore_crafting_save_state(crafting_state)

    var player = main.world.get_node("Player")
    player.position = Vector2(
        float(data.get("player_x", player.position.x)),
        float(data.get("player_y", player.position.y))
    )
    if typeof(crafting_state) == TYPE_DICTIONARY:
        player.position = main.world.migrate_source_interior_position(player.position, crafting_state)
    if main.world.has_method("reveal_player_area"):
        main.world.call("reveal_player_area")
    main._recover_hidden_party_overflow()
    main._sync_pokedex_owned()
