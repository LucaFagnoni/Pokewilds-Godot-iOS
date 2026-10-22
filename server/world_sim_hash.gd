# A deterministic run of the overworld: a fixed seed, a fixed frame time and a
# seeded RNG, then a scripted minute of play (walking, DIG, building, CUT, a
# low tide coming in and going out, a new day). Prints one hash of what the
# game would save plus the live tile store, and one hash per part, so a
# refactor of the world can be checked for "no change in behaviour": run it
# before and after, the hashes must match.
# Run: godot --headless --fixed-fps 60 --path project -s ../server/world_sim_hash.gd [-- --seed=N --expect=HASH]
#      (headless needs project/override.cfg: [physics] 2d/physics_engine="Dummy")
# --fixed-fps 60 is required: every frame then advances the game by 1/60 s.
# Work the game spreads over frames by wall time (loading, nightfall's cacti,
# the day's dig sites) runs with the world paused and the RNG is reseeded
# after it, so two runs on any machine give the same hash. Reference hashes
# (81ba4bd3): seed 12345 11d22e98708ecb5877c3ef3790a8626177eeb09d2e60bed586f759087022bde2,
#             seed 987654321 2d0a4685a701676dcf41fc6ee40d22df33c837342674ab795e5c6c501f95ab91
extends SceneTree

const Paths = preload("res://scripts/game_data_paths.gd")

var main: Node
var world: Node
var parts := {}
var frame := 0
var trace := false
var shots := ""

## With --shots=DIR and a window (no --headless), a screenshot per step. The
## field move and map shots change the run: its hash is not the reference.
func _shot(name: String) -> void:
    if shots.is_empty() or DisplayServer.get_name() == "headless": return
    await RenderingServer.frame_post_draw
    root.get_texture().get_image().save_png(shots.path_join(name + ".png"))

## Which wild Pokemon are near enough to act is refreshed every 500 ms of wall
## time; with --fixed-fps that is a varying number of frames. Pin it to every
## 30th frame (500 ms at 60 FPS) so the same Pokemon act on the same frames.
func _pin_wall_clock() -> void:
    frame += 1
    var now := Time.get_ticks_msec()
    var stamp := -100000 if frame % 30 == 0 else now
    for name in ["_watched_wild_at", "_near_wild_at"]:
        if name in world: world.set(name, stamp)
    if trace:
        print("TRACE %d %s %d %.4f %s" % [frame, world.player.position, world.rng.state, world.get("world_elapsed_seconds"), world.get("ecology_accumulator")])

## Pokemon made without the world's RNG (PokemonState._usable_rng) get random
## IVs, natures...: left out of the hash.
func _without_rolls(value: Variant) -> Variant:
    if value is Dictionary:
        var copy := {}
        for key in value:
            if key not in ["ivs", "evs", "personality", "nature", "gender", "shiny"]:
                copy[key] = _without_rolls(value[key])
        return copy
    if value is Array:
        return value.map(_without_rolls)
    return value

func _frames(count: int) -> void:
    for i in count: await process_frame

func _walk(action: String, frames: int) -> void:
    Input.action_press(action)
    await _frames(frames)
    Input.action_release(action)
    await _frames(4)

func _digest(value: Variant) -> String:
    var context := HashingContext.new()
    context.start(HashingContext.HASH_SHA256)
    context.update(JSON.stringify(value, "", true).to_utf8_buffer())
    return context.finish().hex_encode()

func _note(step: String) -> void:
    var state := [world.call("_player_cell"), world.get("world_elapsed_seconds"), world.get("wild_pokemon").size(),
        world.get("low_tide_active"), world.get("built_structures").size(), world.get("terrain_changes").size()]
    print("WORLD SIM step %s: cell %s, time %.2f, %d wild, low tide %s, %d structures, %d terrain changes" % ([step] + state))
    parts["step." + step] = _digest(state)

func _settle(time: float, reseed: int) -> void:
    world.set("world_elapsed_seconds", time)
    world.call("set_gameplay_enabled", false)
    await _frames(3000)
    world.call("set_gameplay_enabled", true)
    seed(reseed)
    world.rng.seed = reseed

func _initialize() -> void:
    var seed_value := 12345
    var expect := ""
    var dump := ""
    for arg in OS.get_cmdline_user_args():
        if arg.begins_with("--seed="): seed_value = int(arg.trim_prefix("--seed="))
        if arg.begins_with("--expect="): expect = arg.trim_prefix("--expect=")
        if arg.begins_with("--dump="): dump = arg.trim_prefix("--dump=")
        if arg == "--trace": trace = true
        if arg.begins_with("--shots="): shots = arg.trim_prefix("--shots=")
    # A script error would leave the run waiting forever.
    # Wall time: a game-time timer runs out in seconds at an uncapped --fixed-fps.
    var give_up_at := Time.get_ticks_msec() + 900000
    process_frame.connect(func():
        if Time.get_ticks_msec() > give_up_at:
            printerr("WORLD SIM FAIL: timed out")
            quit(2))
    var data := OS.get_temp_dir().path_join("world_sim_hash_%d" % Time.get_ticks_usec())
    DirAccess.make_dir_recursive_absolute(data)
    FileAccess.open(data.path_join(".private-saves-migrated"), FileAccess.WRITE).close()
    Paths.directory = data
    change_scene_to_file("res://scenes/main.tscn")
    await _frames(30)
    main = current_scene
    if main == null:
        printerr("WORLD SIM: main.tscn did not load")
        quit(1)
        return
    while not main.startup_complete: await process_frame
    main.coop_menu.close()
    # A save holding only the seed: LOAD generates that world and spawns there.
    var save: String = main.saves.path_for_world("SimHash")
    DirAccess.make_dir_recursive_absolute(save.get_base_dir())
    var inventory := {}
    for item in ["WOOD", "STONE", "GRASS", "SOFT SAND", "HARD STONE", "CLAY"]: inventory[item] = 99
    var file := FileAccess.open(save, FileAccess.WRITE)
    file.store_string(JSON.stringify({"version": 2, "world_seed": seed_value, "world_size": 0,
        "world_name": "SimHash", "inventory": inventory, "source_key_items_initialized": true}))
    file.close()
    main.world_edit.text = "SimHash"
    main.selected_mode = "LOAD"
    main.setup_load_path = save
    main.setup_load_committed = true
    seed(seed_value)
    main.world.rng.seed = seed_value
    # The world's own clock stands still while it loads: how many frames the
    # load takes depends on the machine, and every timer would start off by that.
    main.world.set_process(false)
    main._start_game()
    # Wall time: with --fixed-fps frames run as fast as they can.
    var give_up := Time.get_ticks_msec() + 900000
    while not main.started and Time.get_ticks_msec() < give_up:
        await process_frame
    if not main.started:
        printerr("WORLD SIM: the world did not start")
        quit(1)
        return
    world = main.world
    world.encounter_requested.disconnect(main._on_encounter_requested)
    world.disconnect("battle_requested", Callable(main, "_on_battle_requested"))
    # Work the load left running (spread over frames by wall time) finishes.
    await _frames(600)
    # From here on every random draw and frame time is fixed.
    world.set_process(true)
    seed(seed_value)
    world.rng.seed = seed_value
    var weather = world.get("environment_system").get_node_or_null("RandomWorldWeather")
    if weather != null: weather.rng.seed = seed_value
    # Its first wait was rolled during the load, unseeded: roll it again.
    world.get("event_progress").erase("random_weather_v1")
    process_frame.connect(_pin_wall_clock)
    world.set("world_elapsed_seconds", 120.0)
    await _frames(60)
    _note("start")
    for step in [["move_right", 90], ["move_down", 90], ["move_left", 60], ["move_up", 120], ["move_right", 45]]:
        await _walk(step[0], step[1])
    _note("walked")
    # DIG on the cells round the player: holes, then each kind of ground.
    var at: Vector2i = world.call("_player_cell")
    var ring: Array[Vector2i] = []
    for y in range(-3, 4):
        for x in range(-3, 4):
            if Vector2i(x, y) != Vector2i.ZERO: ring.append(at + Vector2i(x, y))
    var choices: Array = world.get("DIG_CHOICES")
    for i in ring.size():
        if i % 3 == 0: world.call("_dig_surface", ring[i])
    for i in ring.size():
        if i % 3 == 1: world.call("apply_dig_choice", ring[i], String(choices[(i / 3) % choices.size()]))
    await _frames(30)
    _note("dug")
    # Building, on whichever of those cells allow it.
    var builds := ["FENCE", "TORCH", "WALL", "ROOF", "DOOR", "SIGN", "BRIDGE", "STORAGE BOX"]
    for i in ring.size():
        world.call("place_structure", builds[i % builds.size()], ring[i] + Vector2i(0, 4))
    await _frames(30)
    _note("built")
    await _shot("built")
    # CUT whatever is round the player (grass, trees).
    for cell in ring: world.call("_try_cut_target", cell)
    await _frames(30)
    await _walk("move_down", 60)
    _note("cut")
    if not shots.is_empty():
        var helper: Dictionary = main.caught_pokemon[0] if not main.caught_pokemon.is_empty() else main._make_starter_machop()
        world.call("set_active_field_move", helper, "BUILD")
        await _frames(60)
        await _shot("field_move_build")
        world.call("clear_active_field_move", false)
        await _frames(30)
    # Tides: low tide comes in, then goes out.
    var day_seconds: float = world.get("WORLD_DAY_SECONDS")
    var day: int = world.call("_world_day_index")
    world.set("world_elapsed_seconds", day * day_seconds + day_seconds * 0.25)
    await _frames(600)
    _note("low_tide")
    await _shot("low_tide")
    world.set("world_elapsed_seconds", day * day_seconds + day_seconds * 0.60)
    await _frames(600)
    _note("high_tide")
    await _shot("high_tide")
    # Night, then the next day. Both start work spread over frames by wall
    # time that draws on the world's RNG (cacti at nightfall, the day's sand
    # traps and dig sites): it runs with play paused, then the RNG is reseeded.
    await _settle(day * day_seconds + day_seconds * 0.85, seed_value + 1)
    await _frames(300)
    await _walk("move_left", 60)
    _note("night")
    await _shot("night")
    # Dawn clears the night's cacti while the day's dig sites are chosen,
    # each spread over frames by wall time, and a desert cell under a cactus
    # cannot be a dig site: which ends first changes the sites. Clear them first.
    world.call("set_gameplay_enabled", false)
    await world.get("source_night_events").clear_dormant_cacti()
    await _settle((day + 1) * day_seconds - 1.0, seed_value + 2)
    await _frames(300)
    await _walk("move_right", 60)
    _note("new_day")
    await _shot("new_day")
    if not shots.is_empty():
        main._show_map_menu()
        await _frames(30)
        await _shot("map")
    var save_data: Dictionary = main._capture_game_save()
    # Round-trip through JSON as a save does, so numbers compare as saved.
    save_data = JSON.parse_string(JSON.stringify(save_data))
    if not dump.is_empty():
        FileAccess.open(dump, FileAccess.WRITE).store_string(JSON.stringify(save_data, " ", true))
    var state: Dictionary = save_data.get("crafting_state", {})
    state["mine_pokemon"] = _without_rolls(state.get("mine_pokemon", {}))
    # Discovery as the sorted cells, whatever form the save keeps it in.
    var discovered = world.get("discovered_cells")
    var cells: Array = discovered.keys() if discovered is Dictionary else \
        discovered.cells().map(func(cell: Vector2i) -> String: return "%d,%d" % [cell.x, cell.y])
    cells.sort()
    state["discovered_cells"] = cells
    for key in state: parts["save.crafting_state." + key] = _digest(state[key])
    for key in save_data:
        if key != "crafting_state": parts["save." + key] = _digest(save_data[key])
    var exact = world.get("exact_world")
    if exact != null:
        var record: Dictionary = exact.tiles.to_record()
        for key in record: parts["tiles." + key] = _digest(var_to_str(record[key]).sha256_text())
    var keys := parts.keys()
    keys.sort()
    var all := PackedStringArray()
    for key in keys: all.append("%s %s" % [key, parts[key]])
    var digest := _digest(all)
    for line in all: print("  ", line)
    print("WORLD SIM seed=%d %s" % [seed_value, digest])
    if not expect.is_empty() and expect != digest:
        printerr("WORLD SIM FAIL: expected ", expect)
        quit(1)
        return
    quit(0)
