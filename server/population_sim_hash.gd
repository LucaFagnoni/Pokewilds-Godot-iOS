# A deterministic run of the world's Pokemon: a fixed seed, a fixed frame time
# and a seeded RNG, then a scripted series of phases that put every part of the
# population to work (wild Pokemon wandering, pairing and laying eggs near the
# player; habitat Pokemon left out in pairs, laying and wandering; pursuit,
# fleeing after a failed catch, CHARM, feeding, a provocation warning, a friendly
# one taken, a horde, a push; an egg collected and its parents angered; a sand
# trap stepped on; the roaming Megas; a save and load of the whole population;
# eggs released after nine days). Prints one hash of the population as the
# game saves it (wild Pokemon, habitat Pokemon, eggs, Megas) with the cells,
# the RNG state and the counters, and one hash per phase, so a rewrite of the
# population can be checked for "no change in behaviour": run it before and
# after, the hashes must match.
# Run: godot --headless --fixed-fps 60 --path project -s ../server/population_sim_hash.gd [-- --seed=N --expect=HASH --no-sprites --trace]
#      (headless needs project/override.cfg: [physics] 2d/physics_engine="Dummy")
# --no-sprites runs it (after the start) as the dedicated server does: no sprites
# for wild Pokemon.
# Reference hashes (recorded with the dictionary population, before WildPopulation):
#   seed 12345 d60bd575a137bc966c7eb37c8c5fbd67e7dba8c36692c4e71ab634739865e312,
#     --no-sprites c92cd0f5959daca73e922958153064c40b5bbdb2783ec55263e9f2f48402d648
#   seed 987654321 1d502635a5fa724800d8537edc8e92ea9d8d0f0fd4606af5406221e03d2a73a7,
#     --no-sprites fcfcec6d106e9025191f3a4d82430c947e39ed0452e8eef02d072ed4fe66aae6
extends SceneTree

const Paths = preload("res://scripts/game_data_paths.gd")

var main: Node
var world: Node
var parts := {}
var frame := 0
var trace := false
var seed_value := 12345

func _pin_wall_clock() -> void:
    # Frames the world sits out (a load spread over frames by wall time) are
    # not counted: the count restarts at each reseed.
    if not world.is_processing(): return
    frame += 1
    # The zone scans run every 500 ms of wall time; with --fixed-fps that is a
    # varying number of frames. Every 30th frame, as world_sim_hash does.
    var stamp := -100000 if frame % 30 == 0 else Time.get_ticks_msec()
    for name in ["_watched_wild_at", "_near_wild_at"]:
        if name in world: world.set(name, stamp)
    # Pushing a Pokemon waits 500 ms of wall time between pushes.
    world.set("last_pokemon_push_msec", -1000000)
    if trace and frame % 30 == 0:
        print("TRACE %d %s %d %.4f" % [frame, world.call("_player_cell"), world.rng.state, world.get("world_elapsed_seconds")])

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
    context.update(JSON.stringify(value, "", true, true).to_utf8_buffer())
    return context.finish().hex_encode()

## The population as the game saves it, in a fixed order, round-tripped
## through JSON as a save is, with the cells, RNG and counters.
func _population() -> Dictionary:
    var state: Dictionary = JSON.parse_string(JSON.stringify(world.call("get_crafting_save_state")))
    var wild: Array = state.get("wild_pokemon", [])
    wild.sort_custom(func(a, b): return int(a.id) < int(b.id))
    var farms: Array = state.get("deployed_pokemon", [])
    farms.sort_custom(func(a, b): return [int(a.x), int(a.y)] < [int(b.x), int(b.y)])
    var eggs: Array = state.get("wild_eggs", [])
    eggs.sort_custom(func(a, b): return [int(a.x), int(a.y)] < [int(b.x), int(b.y)])
    var megas = (world.get("event_progress") as Dictionary).get("biome_megas", {})
    return {"wild": wild, "deployed": farms, "eggs": eggs, "megas": JSON.parse_string(JSON.stringify(megas)),
        "player": str(world.call("_player_cell")), "rng": str(world.rng.state),
        "next_wild_id": int(world.get("next_wild_id")), "next_deployed_id": int(world.get("next_deployed_id")),
        "encounters": int(world.get("encounter_count")), "time": snappedf(float(world.get("world_elapsed_seconds")), 0.0001)}

func _note(step: String) -> void:
    var population := _population()
    var burrowed := 0
    for record in population.wild:
        if bool(record.get("burrowed", false)): burrowed += 1
    print("POPULATION SIM step %s: cell %s, time %.2f, %d wild (%d burrowed), %d habitat, %d eggs, %d encounters, rng %s" % [
        step, population.player, population.time, population.wild.size(), burrowed, population.deployed.size(),
        population.eggs.size(), population.encounters, population.rng])
    parts["step." + step] = _digest(population)

## Wild ids by distance from `center` (then id): a fixed choice of the
## Pokemon near the player.
func _wild_near(center: Vector2i, radius: int, awake := true) -> Array:
    var found := []
    var wild: Dictionary = world.get("wild_pokemon")
    for raw_id in wild:
        var record: Dictionary = wild[raw_id]
        var at: Vector2i = record.get("cell", Vector2i.ZERO)
        if maxi(absi(at.x - center.x), absi(at.y - center.y)) > radius: continue
        if awake and (bool(record.get("burrowed", false)) or bool(record.get("ball_reserved", false))): continue
        found.append([(at - center).length_squared(), int(raw_id)])
    found.sort()
    return found.map(func(entry): return entry[1])

func _free(cell: Vector2i, species: String) -> bool:
    if not world.call("_in_bounds", cell) or not world.call("_pokemon_can_enter", species, cell): return false
    if world.get("deployed_pokemon").has(cell) or world.get("wild_eggs").has(cell) or world.call("_wild_id_at_cell", cell) >= 0: return false
    if world.get("built_structures").has(cell) or world.get("blocked").has(cell): return false
    return cell != world.call("_player_cell")

## The nearest free cell to `center` (ring by ring, in a fixed order) that
## `species` can stand on and, with `habitat`, where its habitat is met.
func _free_near(center: Vector2i, species: String, from: int, to: int, habitat := false) -> Vector2i:
    for radius in range(from, to + 1):
        for y in range(-radius, radius + 1):
            for x in range(-radius, radius + 1):
                if maxi(absi(x), absi(y)) != radius: continue
                var cell := center + Vector2i(x, y)
                if not _free(cell, species): continue
                if habitat and not bool(world.call("_refresh_record_habitat", {"species": species}, cell).get("in_habitat", false)): continue
                return cell
    return Vector2i(-2147483648, -2147483648)

func _teleport(cell: Vector2i) -> void:
    world.player.position = world.call("_cell_center", cell)
    await _frames(2)

## The world's state as a save holds it (JSON), loaded back the way LOAD
## does, with play paused while the load runs (it is spread over frames by
## wall time), then reseeded.
func _save_and_load(reseed: int) -> void:
    var saved: Dictionary = JSON.parse_string(JSON.stringify(world.call("get_crafting_save_state")))
    world.set_process(false)
    await world.call("restore_crafting_save_state", saved)
    world.set_process(true)
    _reseed(reseed)
    await _frames(60)

## The cell of the awake wild Pokemon with the most others within ten cells
## (the lowest id among equals).
func _densest() -> Vector2i:
    var wild: Dictionary = world.get("wild_pokemon")
    var awake := []
    for raw_id in wild:
        if not bool(wild[raw_id].get("burrowed", false)): awake.append([int(raw_id), Vector2i(wild[raw_id].cell)])
    awake.sort()
    var best := Vector2i(-2147483648, -2147483648)
    var best_count := -1
    for entry in awake:
        var count := 0
        for other in awake:
            if maxi(absi(other[1].x - entry[1].x), absi(other[1].y - entry[1].y)) <= 10: count += 1
        if count > best_count:
            best_count = count
            best = entry[1]
    return _free_near(best, "rattata", 1, 4)

func _reseed(value: int) -> void:
    seed(value)
    world.rng.seed = value
    frame = -1

func _initialize() -> void:
    var expect := ""
    var server := false
    for arg in OS.get_cmdline_user_args():
        if arg.begins_with("--seed="): seed_value = int(arg.trim_prefix("--seed="))
        if arg.begins_with("--expect="): expect = arg.trim_prefix("--expect=")
        if arg == "--trace": trace = true
        if arg == "--no-sprites": server = true
    var give_up_at := Time.get_ticks_msec() + 600000
    process_frame.connect(func():
        if Time.get_ticks_msec() > give_up_at:
            printerr("POPULATION SIM FAIL: timed out")
            quit(2))
    var data := OS.get_temp_dir().path_join("population_sim_hash_%d" % Time.get_ticks_usec())
    DirAccess.make_dir_recursive_absolute(data)
    FileAccess.open(data.path_join(".private-saves-migrated"), FileAccess.WRITE).close()
    Paths.directory = data
    change_scene_to_file("res://scenes/main.tscn")
    await _frames(30)
    main = current_scene
    if main == null:
        printerr("POPULATION SIM: main.tscn did not load")
        quit(1)
        return
    while not main.startup_complete: await process_frame
    main.coop_menu.close()
    var save: String = main.saves.path_for_world("PopHash")
    DirAccess.make_dir_recursive_absolute(save.get_base_dir())
    var file := FileAccess.open(save, FileAccess.WRITE)
    file.store_string(JSON.stringify({"version": 2, "world_seed": seed_value, "world_size": 0,
        "world_name": "PopHash", "source_key_items_initialized": true}))
    file.close()
    main.world_edit.text = "PopHash"
    main.selected_mode = "LOAD"
    main.setup_load_path = save
    main.setup_load_committed = true
    seed(seed_value)
    main.world.rng.seed = seed_value
    main.world.set_process(false)
    main._start_game()
    var give_up := Time.get_ticks_msec() + 900000
    while not main.started and Time.get_ticks_msec() < give_up:
        await process_frame
    if not main.started:
        printerr("POPULATION SIM: the world did not start")
        quit(1)
        return
    world = main.world
    world.encounter_requested.disconnect(main._on_encounter_requested)
    world.disconnect("battle_requested", Callable(main, "_on_battle_requested"))
    await _frames(600)
    world.set_process(true)
    _reseed(seed_value)
    var weather = world.get("environment_system").get_node_or_null("RandomWorldWeather")
    if weather != null: weather.rng.seed = seed_value
    world.get("event_progress").erase("random_weather_v1")
    process_frame.connect(_pin_wall_clock)
    world.set("world_elapsed_seconds", 120.0)
    await _frames(60)
    _note("start")
    var home: Vector2i = world.call("_player_cell")
    # As a dedicated server runs it from here on: the load below makes the
    # wild Pokemon again, without sprites.
    preload("res://scripts/dedicated_server.gd").active = server
    # A save and load first: a new world gets its roaming Megas there.
    await _save_and_load(seed_value + 1)
    _note("loaded")

    # Wandering, pairing and laying near a player walking about.
    for step in [["move_right", 120], ["move_down", 120], ["move_left", 240], ["move_up", 240], ["move_right", 120], ["move_down", 120]]:
        await _walk(step[0], step[1])
    await _frames(600)
    _note("wander")

    # Habitat Pokemon: a pair ready to lay, two that can be friends, one more
    # left out the way the party menu does it.
    var here: Vector2i = world.call("_player_cell")
    var placed := []
    for species in ["rattata", "pidgey", "oddish", "caterpie", "zubat", "nidoran_f", "machop"]:
        var first := _free_near(here, species, 2, 9, true)
        if first.x == -2147483648: continue
        var second := _free_near(first, species, 1, 2, true)
        if second.x == -2147483648: continue
        world.call("_restore_deployed_pokemon", {"species": species, "level": 12, "gender": "female", "lay_egg_seconds": 3.0,
            "ecology_id": "owned:%d" % (900 + placed.size() * 2)}, first)
        world.call("_restore_deployed_pokemon", {"species": species, "level": 12, "gender": "male", "lay_egg_seconds": 3.0,
            "ecology_id": "owned:%d" % (901 + placed.size() * 2)}, second)
        placed.append([species, first, second])
        if placed.size() >= 2: break
    for species in ["sentret", "meowth"]:
        var cell := _free_near(here + Vector2i(4, 0), species, 1, 8)
        if cell.x != -2147483648:
            world.call("_restore_deployed_pokemon", {"species": species, "level": 9, "gender": "male"}, cell)
            placed.append([species, cell])
    for facing in [Vector2.RIGHT, Vector2.DOWN, Vector2.LEFT, Vector2.UP]:
        world.player.set("facing", facing)
        if world.call("deploy_pokemon", {"species": "machop", "level": 14, "gender": "female"}):
            placed.append(["deploy", facing])
            break
    parts["habitats"] = _digest(str(placed))
    print("POPULATION SIM habitats: %s" % [placed])
    await _frames(1800)
    await _walk("move_left", 60)
    await _frames(600)
    _note("habitats")

    # Pursuit, fleeing, CHARM, feeding, a warning, a friendly one taken, a
    # horde: where the wild Pokemon are thickest.
    await _teleport(_densest())
    await _frames(120)
    here = world.call("_player_cell")
    var near := _wild_near(here, 14)
    var wild: Dictionary = world.get("wild_pokemon")
    var now: float = world.get("world_elapsed_seconds")
    var roles := []
    if near.size() > 0:
        wild[near[0]]["aggro_player"] = true
        roles.append(["aggro", near[0]])
    if near.size() > 1:
        wild[near[1]]["ball_flee_until"] = now + 30.0
        roles.append(["flee", near[1]])
    if near.size() > 2:
        wild[near[2]]["ball_charm_until"] = now + 20.0
        roles.append(["charm", near[2]])
    if near.size() > 3:
        wild[near[3]]["fed_until"] = now + 8.0
        roles.append(["fed", near[3]])
    if near.size() > 4:
        world.call("mark_wild_provocation_warning", near[4])
        roles.append(["warned", near[4]])
    for id in near.slice(5):
        var kind := preload("res://scripts/pokemon_ecology.gd").wild_interaction_kind(String(wild[id].get("species", "")))
        if kind == "FRIENDLY":
            var taken: Dictionary = world.call("take_friendly_wild", id)
            roles.append(["taken", id, String(taken.get("species", ""))])
            break
    for index in 3:
        var cell := _free_near(here + Vector2i(0, 5), "poochyena", 1 + index, 8)
        if cell.x == -2147483648: continue
        world.call("_add_wild_pokemon", "poochyena", 8, cell, String(world.call("biome_at", cell)), 0,
            {"coop_horde": "harness"}, {"aggro_player": true, "coop_target": ""})
        roles.append(["horde", cell])
    parts["roles"] = _digest(str(roles))
    print("POPULATION SIM roles: %s" % [roles])
    await _frames(300)
    var charm_helper := {"species": "clefairy", "level": 60, "hp": 50}
    roles.append(["charm_move", world.call("set_active_field_move", charm_helper, "CHARM")])
    await _walk("move_up", 60)
    await _frames(240)
    world.call("clear_active_field_move", false)
    await _frames(300)
    # A push: the nearest wild Pokemon, from beside it.
    here = world.call("_player_cell")
    near = _wild_near(here, 10)
    var pushed := []
    for id in near:
        if not wild.has(id): continue
        var at: Vector2i = wild[id].cell
        var beside := at + Vector2i.LEFT
        if not _free(beside, "rattata"): continue
        await _teleport(beside)
        await _frames(20)
        if wild.has(id) and wild[id].cell == at:
            pushed = [id, at, world.call("_try_push_fenced_pokemon", at, Vector2i.RIGHT, false)]
            break
    parts["push"] = _digest(str(pushed))
    print("POPULATION SIM push: %s" % [pushed])
    await _frames(900)
    _note("interactions")

    # An egg taken from the wild: its parents nearby turn on the player.
    var eggs: Dictionary = world.get("wild_eggs")
    var egg_cells := []
    for cell in eggs:
        if not bool(eggs[cell].get("dropped_party_egg", false)) and not eggs[cell].has("house_door"): egg_cells.append(cell)
    egg_cells.sort()
    var collected := []
    if not egg_cells.is_empty():
        var egg_cell: Vector2i = egg_cells[0]
        await _teleport(_free_near(egg_cell, "rattata", 1, 3))
        world.call("_collect_wild_egg", egg_cell)
        collected = [egg_cell, eggs.has(egg_cell)]
    parts["egg"] = _digest(str(collected))
    print("POPULATION SIM egg collected: %s" % [collected])
    await _frames(600)
    _note("eggs")

    # A sand trap stepped on.
    var traps: Array = world.get("sand_trap_ids").keys()
    traps.sort()
    var trap := []
    if not traps.is_empty():
        var trap_cell: Vector2i = wild[traps[0]].cell
        await _teleport(trap_cell + Vector2i(-2, 0))
        await _walk("move_right", 40)
        trap = [traps[0], trap_cell, world.call("_player_cell")]
        await _frames(240)
        trap.append(wild.has(traps[0]))
    parts["trap"] = _digest(str(trap))
    print("POPULATION SIM trap: %s" % [trap])
    await _frames(300)
    _note("traps")

    # The roaming Megas, with the player beside one.
    var megas: Dictionary = (world.get("event_progress") as Dictionary).get("biome_megas", {})
    var groups := megas.keys()
    groups.sort()
    for group in groups:
        if megas[group].has("x"):
            await _teleport(_free_near(Vector2i(int(megas[group].x), int(megas[group].y)), "rattata", 2, 6))
            break
    await _frames(1200)
    _note("megas")

    # The whole population saved and loaded again, then played on.
    await _teleport(home)
    await _save_and_load(seed_value + 3)
    _note("reloaded")
    for step in [["move_up", 120], ["move_right", 120], ["move_down", 120]]:
        await _walk(step[0], step[1])
    await _frames(900)
    _note("after_load")

    # Nine days on: eggs nobody took are released (play paused while the new
    # day's work, spread over frames by wall time, runs; then reseeded).
    var day_seconds: float = world.get("WORLD_DAY_SECONDS")
    world.set("world_elapsed_seconds", float(world.get("world_elapsed_seconds")) + day_seconds * 10.0)
    world.call("set_gameplay_enabled", false)
    await _frames(3000)
    world.call("set_gameplay_enabled", true)
    _reseed(seed_value + 4)
    await _frames(600)
    _note("days_later")

    var keys := parts.keys()
    keys.sort()
    var all := PackedStringArray()
    for key in keys: all.append("%s %s" % [key, parts[key]])
    var digest := _digest(all)
    for line in all: print("  ", line)
    print("POPULATION SIM seed=%d%s %s" % [seed_value, " no-sprites" if server else "", digest])
    if not expect.is_empty() and expect != digest:
        printerr("POPULATION SIM FAIL: expected ", expect)
        quit(1)
        return
    quit(0)
