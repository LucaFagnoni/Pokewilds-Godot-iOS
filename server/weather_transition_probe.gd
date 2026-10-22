# Frame times around weather changes: random weather events (rain, wind, snow,
# sand, fire: random_world_weather.gd) starting, holding and stopping, and the
# route weather overlays (fog, smoke, deep forest: world_environment_system.gd),
# on a new small world (a random one each run). A probe, not a pass/fail test:
# one line per window, then a summary of the windows by kind (no weather,
# transitions, weather held).
#   frame:  time between frames. Uncapped (max_fps 0, vsync off where the driver
#           allows), so in a headless run it is the script cost alone.
#   script: process + draw callbacks, up to the renderer (windowed runs only).
#   process: Performance TIME_PROCESS, as the engine samples it.
# Script cost: godot --headless --path project -s ../server/weather_transition_probe.gd
#              (headless needs project/override.cfg: [physics] 2d/physics_engine="Dummy")
# Render cost: godot --path project --rendering-driver opengl3 --resolution 1280x720 --disable-vsync
#              -s ../server/weather_transition_probe.gd [-- --shots=<dir>]
# Add --only=rain,snow,... for some of: rain wind snow sand fire fog smoke deep_forest.
extends SceneTree

const Paths = preload("res://scripts/game_data_paths.gd")
const Weather = preload("res://scripts/random_world_weather.gd")

var main: Node
var world: Node
var weather: Node
var env: Node
var shots := ""
var only: Array = []  # --only=rain,sand: just these
var window := ""
var samples: Array = []  # [frame usec, script usec (-1 headless), process sec, physics sec, draw calls, nodes]
var last_usec := 0
var script_usec := -1
var results: Array = []  # [name, "clear" / "transition" / "weather", samples]

func _frames(count: int) -> void:
    for i in count: await process_frame

func _seconds(seconds: float) -> void:
    var until := Time.get_ticks_usec() + int(seconds * 1000000.0)
    while Time.get_ticks_usec() < until: await process_frame

func _on_frame() -> void:
    var now := Time.get_ticks_usec()
    if not window.is_empty() and last_usec > 0:
        samples.append([now - last_usec, script_usec, Performance.get_monitor(Performance.TIME_PROCESS),
            Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS),
            Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME), Performance.get_monitor(Performance.OBJECT_NODE_COUNT)])
    last_usec = now
    script_usec = -1

func _on_pre_draw() -> void:
    if last_usec > 0: script_usec = Time.get_ticks_usec() - last_usec

## Runs last every frame: undoes the battery saver's 30/60 FPS cap.
func _uncapper() -> Node:
    var code := GDScript.new()
    code.source_code = "extends Node\nfunc _process(_delta: float) -> void:\n\tEngine.max_fps = 0\n"
    code.reload()
    var node := Node.new()
    node.set_script(code)
    node.process_priority = 1 << 30
    return node

## Records frames for `seconds` under `name`, summed up by `kind`.
func measure(name: String, seconds: float, kind: String) -> void:
    samples = []
    window = name
    await _seconds(seconds)
    window = ""
    results.append([name, kind, samples])
    print(_line(name, samples))

## Milliseconds: column 0 and 1 hold usec, 2 and 3 seconds.
func _stats(list: Array, column := 0) -> Dictionary:
    var ms: Array = list.filter(func(s): return s[column] >= 0).map(func(s): return s[column] / 1000.0 if column < 2 else s[column] * 1000.0)
    ms.sort()
    if ms.is_empty(): return {"n": 0, "mean": 0.0, "p99": 0.0, "max": 0.0}
    var sum := 0.0
    for v in ms: sum += v
    return {"n": ms.size(), "mean": sum / ms.size(), "p99": ms[mini(ms.size() - 1, int(ms.size() * 0.99))], "max": ms[-1]}

func _line(name: String, list: Array) -> String:
    var st := _stats(list)
    var sc := _stats(list, 1)
    var worst: Array = [0, -1, 0.0, 0.0, 0, 0]
    for s in list:
        if s[0] > worst[0]: worst = s
    var scripted := "" if sc.n == 0 else " | script mean %5.2f p99 %5.2f max %5.2f" % [sc.mean, sc.p99, sc.max]
    return "WEATHER PROBE %-19s frames=%5d frame mean %6.2f p99 %6.2f max %6.2f%s ms | worst frame: process %.2f, physics %.2f ms, %d draw calls, %d nodes" % [
        name, st.n, st.mean, st.p99, st.max, scripted, worst[2] * 1000.0, worst[3] * 1000.0, worst[4], worst[5]]

func shot(name: String) -> void:
    if shots.is_empty() or DisplayServer.get_name() == "headless": return
    await process_frame
    await RenderingServer.frame_post_draw
    root.get_texture().get_image().save_png(shots.path_join(name + ".png"))
    last_usec = 0  # the readback is not a game frame

## Cells whose surroundings all allow `kind`, a few screens apart.
func find_cells(kind: String) -> Array:
    var found: Array = []
    var bounds: Rect2i = world.exact_world.bounds()
    for y in range(bounds.position.y + 12, bounds.end.y - 12, 5):
        for x in range(bounds.position.x + 12, bounds.end.x - 12, 5):
            if not Weather.allows(world.exact_world.tile_at(Vector2i(x, y)), kind): continue
            var all := true
            for dy in range(-6, 7, 3):
                for dx in range(-9, 10, 3):
                    if not Weather.allows(world.exact_world.tile_at(Vector2i(x + dx, y + dy)), kind): all = false
            if all and found.all(func(c): return (c as Vector2i).distance_to(Vector2i(x, y)) > 30.0): found.append(Vector2i(x, y))
            if found.size() >= 6: return found
    return found

## Stands the player on the first of `cells` that shows weather.
func go_to(cells: Array) -> bool:
    for cell in cells:
        world.player.position = world._cell_center(cell)
        world._sync_follower_to_player()
        await _seconds(3.0)  # let the streamed chunks around it settle
        if weather.visible: return true
        print("WEATHER PROBE no weather at %s (area %s, route %s), next" % [cell, world.active_area_id, env._environment_context().get("route_type")])
    return false

## One random weather event: start (fade in), hold, stop (fade out), after.
func event(kind: String, wind: bool) -> void:
    var label := kind + ("+wind" if wind and kind != "wind" else "")
    await measure(label + " before", 2.0, "clear")
    weather.begin_event(kind)
    weather.state.wind = wind
    weather.state.remaining = 3600.0
    weather.state.strike_in = 1.5
    await measure(label + " START", 1.0, "transition")
    if not weather.visible or not world.gameplay_enabled:
        print("WEATHER PROBE %s not shown: battle %s, area %s, world visible %s, gameplay %s" % [label, main.battle_active, world.active_area_id, world.is_visible_in_tree(), world.gameplay_enabled])
    await measure(label + " fade in", 2.5, "transition")
    await measure(label + " hold", 2.0, "weather")
    weather.state.age = 10.0
    await shot(label.replace("+", "_"))
    weather.state.remaining = 4.0  # stops: fades out over 4 s, then ends
    await measure(label + " STOP", 5.0, "transition")
    await measure(label + " after", 2.0, "clear")

## A route weather overlay (fog, smoke, deep forest) switched on and back off.
func overlay(kind: String) -> void:
    var context: Dictionary = env._environment_context()
    if env.weather_for_context(context) != "clear": return
    samples = []
    window = kind + " overlay"
    env.context_accumulator = -1.0e9  # no context refresh switching it back meanwhile
    var started := Time.get_ticks_usec()
    var longest := 0
    var frames := 0
    while true:  # (a texture may load on a thread first)
        var call := Time.get_ticks_usec()
        var shown = env._configure_weather_visuals(kind)
        longest = maxi(longest, Time.get_ticks_usec() - call)
        if shown != false: break
        frames += 1
        await process_frame
    env.current_weather_name = kind
    print("WEATHER PROBE %s overlay shown after %d frames, %.2f ms; longest call %.2f ms" % [
        kind, frames, (Time.get_ticks_usec() - started) / 1000.0, longest / 1000.0])
    env.context_accumulator = -1.0  # hold it for a second
    await _seconds(1.0)
    await shot(kind)
    env.context_accumulator = env.CONTEXT_REFRESH_SECONDS  # back to clear next frame
    await _seconds(1.0)
    window = ""
    results.append([kind + " overlay", "transition", samples])
    print(_line(kind + " overlay", samples))

func _initialize() -> void:
    for arg in OS.get_cmdline_user_args():
        if arg.begins_with("--shots="): shots = arg.trim_prefix("--shots=")
        if arg.begins_with("--only="): only = Array(arg.trim_prefix("--only=").split(","))
    if not shots.is_empty(): DirAccess.make_dir_recursive_absolute(shots)
    var dir := OS.get_temp_dir().path_join("weather_probe_%d" % Time.get_ticks_usec())
    DirAccess.make_dir_recursive_absolute(dir)
    FileAccess.open(dir.path_join(".private-saves-migrated"), FileAccess.WRITE).close()
    Paths.directory = dir
    change_scene_to_file("res://scenes/main.tscn")
    await _frames(30)
    main = current_scene
    while not main.startup_complete: await process_frame
    main.coop_menu.close()
    main.world_edit.text = "WeatherProbe"
    main.selected_mode = "NEW"
    main.selected_world_size = 0
    main._start_game()
    var waited := 0
    while not main.started and waited < 36000:
        await process_frame
        waited += 1
    world = main.world
    env = world.environment_system
    weather = env.get_node("RandomWorldWeather")
    # No battles: one hides the world, and its weather, mid-measurement.
    world.encounter_requested.disconnect(main._on_encounter_requested)
    world.disconnect("battle_requested", Callable(main, "_on_battle_requested"))
    DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
    OS.low_processor_usage_mode_sleep_usec = 0  # headless sleeps 6.9 ms a frame otherwise
    root.add_child(_uncapper())
    process_frame.connect(_on_frame)
    RenderingServer.frame_pre_draw.connect(_on_pre_draw)
    # Daylight for the whole run, and no random event of its own.
    world.world_elapsed_seconds = 60.0
    await _seconds(4.0)
    weather.state.wait = 1.0e9
    print("WEATHER PROBE renderer=%s gameplay=%s view=%s" % [DisplayServer.get_name(), world.gameplay_enabled, root.get_visible_rect().size])
    await measure("clear steady", 3.0, "clear")
    # The first rain of a session first: anything warmed on first use shows here.
    if only.is_empty() or "rain" in only:
        await event("rain", false)
        await event("rain", true)
        await event("rain", false)
    for kind in ["fog", "smoke", "deep_forest"]:
        if only.is_empty() or kind in only: await overlay(kind)
    for kind in ["wind", "snow", "sand", "fire"]:
        if not only.is_empty() and kind not in only: continue
        if not await go_to(find_cells(kind)):
            print("WEATHER PROBE %s: no such biome in this world, skipped" % kind)
            continue
        await event(kind, kind == "wind")
    var by_kind := {"clear": [], "transition": [], "weather": []}
    for entry in results: (by_kind[entry[1]] as Array).append_array(entry[2])
    var parts := PackedStringArray()
    for kind in by_kind:
        var f := _stats(by_kind[kind])
        var c := _stats(by_kind[kind], 1)
        parts.append("%s: frame max %.2f p99 %.2f mean %.2f%s ms (%d frames)" % [kind, f.max, f.p99, f.mean,
            "" if c.n == 0 else ", script max %.2f p99 %.2f mean %.2f" % [c.max, c.p99, c.mean], f.n])
    print("WEATHER PROBE SUMMARY " + " | ".join(parts))
    quit(0)
