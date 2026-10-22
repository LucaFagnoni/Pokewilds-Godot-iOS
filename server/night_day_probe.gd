# Frame times at night (night events, roaming ghosts) and across a new day
# (the day's dig sites change), single player. A probe, not a pass/fail test.
# The first run makes and saves a world in --data; later runs load that same
# world, so runs before and after a change compare like for like.
#   frame: the frame's work, from the start of its process step to the end of
#          its last node's _process and the deferred calls, at --fps (60 by
#          default, as on a phone): the sleep up to the next frame is left out.
#          In a headless run this is the script cost alone.
# Script cost: godot --headless --path project -s ../server/night_day_probe.gd -- --data=<dir>
#              (headless needs project/override.cfg: [physics] 2d/physics_engine="Dummy")
# Screenshots: godot --path project --rendering-driver opengl3 --resolution 1280x720 --disable-vsync
#              -s ../server/night_day_probe.gd -- --data=<dir> --shots=<dir>
# --seconds=S sets the night windows' length (30 by default), --fps=N the frame rate.
extends SceneTree

const Paths = preload("res://scripts/game_data_paths.gd")

var main: Node
var world: Node
var shots := ""
var seconds := 30.0
var window := ""
var samples: Array = []
var frame_started := 0
var fps := 60
var detail := 8.0

func _frames(count: int) -> void:
    for i in count: await process_frame

func _seconds(length: float) -> void:
    var until := Time.get_ticks_usec() + int(length * 1000000.0)
    while Time.get_ticks_usec() < until: await process_frame

func _on_frame() -> void:
    frame_started = Time.get_ticks_usec()
    Engine.set_meta("probe_t0", frame_started)
    if Engine.has_meta("probe_frame"): Engine.get_meta("probe_frame").clear()

## A test build's sections (Engine meta "probe_frame": name -> microseconds
## this frame) are printed for frames over --detail=MS (8 by default).
func _frame_ended() -> void:
    if not window.is_empty() and frame_started > 0:
        var ms := (Time.get_ticks_usec() - frame_started) / 1000.0
        samples.append(ms)
        if ms > detail and Engine.has_meta("probe_frame"):
            var sections: Dictionary = Engine.get_meta("probe_frame")
            var parts: Array = []
            for name in sections:
                if name != "_top" and sections[name] >= 300: parts.append("%s %.1f" % [name, sections[name] / 1000.0])
            print("NIGHT PROBE %s frame %.1f ms: %s" % [window, ms, ", ".join(parts)])
    frame_started = 0

## Runs last every frame: holds the frame rate at --fps (the battery saver
## sets a cap of its own), and ends the frame's timing after the deferred calls.
func _last_node() -> Node:
    var code := GDScript.new()
    code.source_code = "extends Node\nvar fps := 60\nvar ended: Callable\nfunc _process(_delta: float) -> void:\n\tEngine.max_fps = fps\n\tended.call_deferred()\n"
    code.reload()
    var node := Node.new()
    node.set_script(code)
    node.set("fps", fps)
    node.set("ended", _frame_ended)
    node.process_priority = 1 << 30
    return node

func measure(name: String, length: float, walk := false) -> Array:
    samples = []
    window = name
    var until := Time.get_ticks_usec() + int(length * 1000000.0)
    var flip := 0
    var direction := 1
    while Time.get_ticks_usec() < until:
        if walk and Time.get_ticks_msec() - flip >= 2000:
            flip = Time.get_ticks_msec()
            direction = -direction
            Input.action_release("move_left"); Input.action_release("move_right")
            Input.action_press("move_right" if direction > 0 else "move_left")
        await process_frame
    Input.action_release("move_left"); Input.action_release("move_right")
    window = ""
    print(line(name, samples))
    return samples

func line(name: String, list: Array) -> String:
    var ms := list.duplicate()
    ms.sort()
    if ms.is_empty(): return "NIGHT PROBE %s: no frames" % name
    var sum := 0.0
    var over := [0, 0]
    for v in ms:
        sum += v
        if v > 16.0: over[0] += 1
        if v > 33.0: over[1] += 1
    return "NIGHT PROBE %-16s frames %5d mean %6.2f p95 %6.2f p99 %6.2f max %7.2f ms, over 16/33 ms: %d/%d, sum over 16 ms %.0f ms" % [
        name, ms.size(), sum / ms.size(), ms[int(ms.size() * 0.95)], ms[mini(ms.size() - 1, int(ms.size() * 0.99))], ms[-1], over[0], over[1],
        list.filter(func(v): return v > 16.0).reduce(func(a, v): return a + v, 0.0)]

func shot(name: String) -> void:
    if shots.is_empty() or DisplayServer.get_name() == "headless": return
    await process_frame
    await RenderingServer.frame_post_draw
    root.get_texture().get_image().save_png(shots.path_join(name + ".png"))

## Microseconds per call, over `count` calls.
func per_call(count: int, call: Callable) -> float:
    var began := Time.get_ticks_usec()
    for i in count: call.call()
    return float(Time.get_ticks_usec() - began) / count

func dig_sites(day: int) -> int:
    var found := 0
    for mutation in world.source_interior_mutations.values():
        if mutation is Dictionary and mutation.get("kind") == "BIOME_DIG_SITE" and int(mutation.get("day", -1)) == day: found += 1
    return found

func _initialize() -> void:
    var data := ""
    for arg in OS.get_cmdline_user_args():
        if arg.begins_with("--shots="): shots = arg.trim_prefix("--shots=")
        if arg.begins_with("--data="): data = arg.trim_prefix("--data=")
        if arg.begins_with("--seconds="): seconds = float(arg.trim_prefix("--seconds="))
        if arg.begins_with("--fps="): fps = int(arg.trim_prefix("--fps="))
        if arg.begins_with("--detail="): detail = float(arg.trim_prefix("--detail="))
    if data.is_empty(): data = OS.get_temp_dir().path_join("night_probe_%d" % Time.get_ticks_usec())
    if not shots.is_empty(): DirAccess.make_dir_recursive_absolute(shots)
    DirAccess.make_dir_recursive_absolute(data)
    FileAccess.open(data.path_join(".private-saves-migrated"), FileAccess.WRITE).close()
    Paths.directory = data
    change_scene_to_file("res://scenes/main.tscn")
    await _frames(30)
    main = current_scene
    while not main.startup_complete: await process_frame
    main.coop_menu.close()
    var save: String = main.saves.path_for_world("NightProbe")
    var fresh := not FileAccess.file_exists(save)
    main.world_edit.text = "NightProbe"
    if fresh:
        main.selected_mode = "NEW"
        main.selected_world_size = 1
    else:
        main.selected_mode = "LOAD"
        main.setup_load_path = save
        main.setup_load_committed = true
    main._start_game()
    var waited := 0
    while not main.started and waited < 36000:
        await process_frame
        waited += 1
    world = main.world
    world.encounter_requested.disconnect(main._on_encounter_requested)
    world.disconnect("battle_requested", Callable(main, "_on_battle_requested"))
    if fresh:
        await _seconds(3.0)
        world.world_elapsed_seconds = 60.0
        await main._save_current_game()
        while main.save_thread != null: await process_frame
        print("NIGHT PROBE made and saved the world in ", data)
    DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
    OS.low_processor_usage_mode_sleep_usec = 0
    root.add_child(_last_node())
    process_frame.connect(_on_frame)
    var day_seconds: float = world.WORLD_DAY_SECONDS
    var day: int = world._world_day_index()
    # Daytime first, settled.
    world.world_elapsed_seconds = day * day_seconds + 60.0
    await _seconds(4.0)
    print("NIGHT PROBE renderer=%s seed=%s player cell %s, area %s, biome %s" % [DisplayServer.get_name(), world.world_seed, world._player_cell(), world.active_area_id, world.biome_at(world._player_cell())])
    await measure("day", 10.0)
    # Nightfall: the night's cacti are seeded (seed_cacti) as night begins.
    world.world_elapsed_seconds = day * day_seconds + 306.0
    await measure("nightfall", 6.0)
    await shot("night")
    var night = world.source_night_events
    var player_at: Vector2 = world.player.position
    # What a night tick asks (the first call of a frame, uncached).
    var check := "_protected_at" if night.has_method("_protected_at") else "protected_at"
    var cacti := "has_nearby_cacti" if night.has_method("has_nearby_cacti") else "nearby_cacti"
    print("NIGHT PROBE per call: %s(player) %.1f us, %s(4) %.1f us, protected_at(actor) %.1f us" % [
        check, per_call(2000, func(): night.call(check, player_at, 4, true)),
        cacti, per_call(2000, func(): night.call(cacti, 4)),
        per_call(2000, func(): night.protected_at(player_at + Vector2(32, 0), 5, false))])
    # Mega Gengar's clearing, looked for at dusk and dawn while it has none.
    print("NIGHT PROBE per call: SourceForestBoss.select_cell %.2f ms (found %s)" % [
        per_call(5, func(): SourceForestBoss.select_cell(world)) / 1000.0, SourceForestBoss.select_cell(world)])
    frame_started = 0  # this frame is the calls above
    await measure("night still", seconds)
    await measure("night walking", seconds, true)
    # The new day: the day's dig sites replace the last day's.
    day = world._world_day_index()
    var before := dig_sites(day + 1)
    world.world_elapsed_seconds = (day + 1) * day_seconds - 1.0
    var began := Time.get_ticks_usec()
    var list := await measure("new day", 10.0)
    var top := list.duplicate()
    top.sort()
    top.reverse()
    print("NIGHT PROBE new day: %d dig sites placed (%d before), longest frames %s ms" % [dig_sites(day + 1), before, top.slice(0, 8).map(func(v): return snappedf(v, 0.1))])
    await shot("new_day")
    print("NIGHT PROBE done in %.1f s" % ((Time.get_ticks_usec() - began) / 1000000.0))
    if not shots.is_empty():
        # The new day's dig site nearest the player, on screen.
        var nearest := Vector2i.ZERO
        var best := INF
        for key in world.source_interior_mutations:
            var mutation = world.source_interior_mutations[key]
            if not mutation is Dictionary or mutation.get("kind") != "BIOME_DIG_SITE" or int(mutation.get("day", -1)) != day + 1: continue
            var cell: Vector2i = world._cell_from_key(String(key))
            if Vector2(cell - world._player_cell()).length() < best:
                best = Vector2(cell - world._player_cell()).length()
                nearest = cell
        if best < INF:
            world.player.position = world._cell_center(nearest + Vector2i(0, 2))
            world._sync_follower_to_player()
            await _seconds(3.0)
            print("NIGHT PROBE dig site shot at %s" % nearest)
            await shot("new_day_dig_site")
    quit(0)
