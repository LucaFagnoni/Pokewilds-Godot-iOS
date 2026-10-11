extends Node2D

# Cosmetic events only: never edit terrain, collision, actors or battle state.
# Kept inside the existing per-world save dictionary, including travel caches.
const SAVE_KEY := "random_weather_v1"
const MIN_INTERVAL := 300.0
const MAX_INTERVAL := 600.0
const MIN_DURATION := 30.0
const MAX_DURATION := 90.0
const WIND := preload("res://assets/source_exact/global/wind1.png")
const FLAMES := preload("res://assets/source_exact/global/fire_sheet2.png")
const BOLT := preload("res://assets/source_exact/global/lightning1.png")
const SPLASH := preload("res://assets/source_exact/global/splash_anim4.png")
const THUNDER := preload("res://assets/battle_audio/thunder_enemy_gsc.ogg")
const PARTICLES := 240
const AMBIENCE := {
    "rain":preload("res://assets/weather/rain.wav"),
    "wind":preload("res://assets/weather/wind.wav"),
    "sand":preload("res://assets/weather/sand.wav"),
    "snow":preload("res://assets/weather/snow.wav"),
    "fire":preload("res://assets/weather/fire.wav")}
var ambience: Dictionary = {}
var world: Node2D
var rng := RandomNumberGenerator.new()
var seeds: Array[Vector3] = []
var state: Dictionary = {}
var view := Rect2()
var thunder: AudioStreamPlayer
var bolt_position := Vector2.ZERO
var bolt_age := -1.0
var sound_delay := -1.0

func configure(owner_world: Node2D) -> void:
    world = owner_world
    z_as_relative = false
    z_index = 4095
    texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
    var unlit := CanvasItemMaterial.new()
    unlit.light_mode = CanvasItemMaterial.LIGHT_MODE_UNSHADED
    material = unlit
    rng.randomize()
    # Independent random stream: weather cannot change encounters or world seeds.
    var visual_rng := RandomNumberGenerator.new()
    visual_rng.seed = 134
    for index in range(PARTICLES):
        seeds.append(Vector3(visual_rng.randf(), visual_rng.randf(), visual_rng.randf()))
    thunder = AudioStreamPlayer.new()
    thunder.name = "WeatherThunder"
    thunder.stream = THUNDER
    thunder.set_meta("world_sound", true)
    preload("res://scripts/game_options.gd").route_audio(thunder)
    thunder.volume_db = -12.0
    add_child(thunder)
    for kind in AMBIENCE:
        var sound := AudioStreamPlayer.new()
        var loop: AudioStreamWAV = AMBIENCE[kind].duplicate()
        loop.loop_mode = AudioStreamWAV.LOOP_FORWARD
        loop.loop_begin = 0
        loop.loop_end = loop.data.size() / 2
        sound.stream = loop
        sound.set_meta("world_sound",true)
        preload("res://scripts/game_options.gd").route_audio(sound)
        sound.volume_db = -16.0
        add_child(sound)
        ambience[kind] = sound
    hide()

static func tile_biome(tile: SourceTile) -> String:
    if tile == null: return ""
    var route := tile.route_belongs_to.type().to_lower() if tile.route_belongs_to != null else ""
    var biome := tile.biome.to_lower()
    # Coastal replacements can retain the former forest biome tag.
    if tile.is_tidal or "tidal" in tile.name or tile.name.begins_with("sand") or route == "beach": return "beach"
    return biome if not biome.is_empty() else route

static func allows(tile: SourceTile, kind: String) -> bool:
    if tile == null: return false
    var biome := tile_biome(tile)
    match kind:
        "wind": return biome.begins_with("beach")
        "sand": return biome == "desert" and not tile.is_water and not tile.is_lava
        "fire": return biome in ["forest", "deep_forest", "savanna", "savannah", "volcano"] and not tile.is_water and not tile.is_tidal and not tile.is_lava
        "snow": return biome in ["tundra", "winter", "snow"] and not tile.is_lava
        "rain": return true
    return false

func _process(delta: float) -> void:
    if world == null or not is_instance_valid(world): return
    var outdoors: bool = bool(preload("res://scripts/game_options.gd").values.get("weather_events",true)) and world.generated and world.exact_world != null and world.active_area_id == "OVERWORLD" and not world.restoring_saved_tiles and world.is_visible_in_tree()
    visible = outdoors
    if not outdoors:
        for sound in ambience.values(): sound.stop()
        if is_instance_valid(thunder): thunder.stop()
        bolt_age = -1.0
        sound_delay = -1.0
        return
    var camera := get_viewport().get_camera_2d()
    var span := get_viewport_rect().size / (camera.zoom if camera != null else Vector2.ONE)
    view = Rect2(world.environment_camera_center() - span * 0.5, span)
    for sound in ambience.values(): sound.stream_paused = not world.gameplay_enabled
    if not world.gameplay_enabled:
        thunder.stream_paused = true
        return
    thunder.stream_paused = false
    var saved: Dictionary = world.event_progress.get(SAVE_KEY, {})
    if not is_same(saved, state):
        state = saved
        bolt_age = -1.0
        sound_delay = -1.0
        thunder.stop()
    if state.is_empty():
        state = {"wait":rng.randf_range(MIN_INTERVAL, MAX_INTERVAL), "remaining":0.0, "age":0.0, "kind":"", "wind":false, "fires":[], "strike_in":5.0}
        world.event_progress[SAVE_KEY] = state
    advance(delta)
    _update_ambience()
    queue_redraw()

func _update_ambience() -> void:
    var tile: SourceTile = world.exact_world.tile_at(world._player_cell())
    var fade := clampf(minf(float(state.age)/3.0,float(state.remaining)/4.0),0.0,1.0)
    for kind in ambience:
        var sound: AudioStreamPlayer = ambience[kind]
        var wanted: bool = float(state.remaining)>0.0 and (state.kind == kind or (kind == "wind" and bool(state.wind))) and allows(tile,kind)
        if wanted:
            sound.volume_db = (-26.0 if kind == "wind" else -16.0) + linear_to_db(maxf(0.001,fade))
            if not sound.playing: sound.play()
        elif sound.playing: sound.stop()

func advance(delta: float) -> void:
    if float(state.remaining) <= 0.0:
        state.wait = maxf(0.0, float(state.wait) - delta)
        if float(state.wait) <= 0.0:
            var tile: SourceTile = world.exact_world.tile_at(world._player_cell())
            var choices := ["rain"]
            for kind in ["wind", "sand", "fire", "snow"]:
                if allows(tile, kind): choices.append(kind)
            begin_event(choices[rng.randi_range(0, choices.size()-1)])
        return
    state.remaining = maxf(0.0, float(state.remaining) - delta)
    state.age = float(state.age) + delta
    if state.kind == "rain":
        state.strike_in = float(state.strike_in) - delta
        if float(state.strike_in) <= 0.0:
            _strike()
            state.strike_in = rng.randf_range(6.0, 15.0)
    if bolt_age >= 0.0:
        bolt_age += delta
        if bolt_age > 0.55: bolt_age = -1.0
    if sound_delay >= 0.0:
        sound_delay -= delta
        if sound_delay < 0.0: thunder.play()
    if float(state.remaining) <= 0.0:
        state.kind = ""
        state.fires = []
        state.wind = false
        state.wait = rng.randf_range(MIN_INTERVAL, MAX_INTERVAL)

func begin_event(kind: String) -> void:
    state.kind = kind
    state.remaining = rng.randf_range(MIN_DURATION, MAX_DURATION)
    state.age = 0.0
    state.wind = kind == "wind" or (kind == "rain" and rng.randf() < 0.5)
    state.strike_in = rng.randf_range(3.0, 8.0)
    state.fires = []
    if kind == "fire": _choose_fires()

func _safe_ground(cell: Vector2i) -> bool:
    var tile: SourceTile = world.exact_world.tile_at(cell)
    return tile != null and not world.built_structures.has(cell) and not tile.is_water and not tile.is_lava and not tile.is_ledge and tile.has_item.is_empty() and not "building" in tile.name and not "building" in tile.name_upper

func _choose_fires() -> void:
    var center: Vector2i = world._player_cell()
    var used := {}
    # One small patch, bounded work regardless of world size.
    var anchor := center + Vector2i(rng.randi_range(-5, 5), rng.randi_range(-4, 4))
    for attempt in range(64):
        var cell := anchor + Vector2i(rng.randi_range(-2, 2), rng.randi_range(-2, 2))
        if used.has(cell) or not _safe_ground(cell) or not allows(world.exact_world.tile_at(cell), "fire"): continue
        if cell.distance_squared_to(center) < 4: continue
        used[cell] = true
        state.fires.append([cell.x, cell.y, rng.randf()])
        if state.fires.size() >= 7: break

func _strike() -> void:
    for attempt in range(20):
        var point := view.position + view.size * Vector2(rng.randf_range(0.15, 0.85), rng.randf_range(0.3, 0.85))
        var cell := Vector2i(floori(point.x / 16.0), floori(point.y / 16.0))
        var tile: SourceTile = world.exact_world.tile_at(cell)
        if tile == null or world.built_structures.has(cell) or "building" in tile.name or "building" in tile.name_upper: continue
        bolt_position = Vector2(cell) * 16.0 + Vector2(8, 14)
        bolt_age = 0.0
        sound_delay = 0.35
        return

func _wrapped(seed: Vector3, motion: Vector2) -> Vector2:
    var span := view.size + Vector2(64, 96)
    var start := view.position - Vector2(32, 48)
    return start + Vector2(fposmod(seed.x * span.x + motion.x - start.x, span.x), fposmod(seed.y * span.y + motion.y - start.y, span.y))

func _tile(point: Vector2) -> SourceTile:
    return world.exact_world.tile_at(Vector2i(floori(point.x / 16.0), floori(point.y / 16.0)))

func _draw() -> void:
    if state.is_empty() or not visible or world == null or world.exact_world == null: return
    var age := float(state.age)
    var fade := clampf(minf(age / 3.0, float(state.remaining) / 4.0), 0.0, 1.0)
    if fade <= 0.0: return
    if state.kind == "rain":
        draw_rect(view, Color(0.14, 0.2, 0.3, 0.1 * fade))
        for seed in seeds:
            var phase := fposmod(age * (1.8 + seed.z * 0.6) + seed.z, 1.0)
            var ground := _wrapped(seed, Vector2.ZERO)
            var drift := -18.0 if bool(state.wind) and allows(_tile(ground), "wind") else -4.0
            if phase < 0.88:
                var drop := ground + Vector2(drift, -80.0) * (1.0 - phase / 0.88)
                draw_line(drop, drop + Vector2(-drift * 0.08, 6), Color(0.7, 0.86, 0.93, 0.65 * fade), 1.0)
            elif _safe_ground(Vector2i(floori(ground.x / 16), floori(ground.y / 16))):
                var frame := mini(2, int((phase - 0.88) / 0.12 * 3.0))
                draw_texture_rect_region(SPLASH, Rect2(ground-Vector2(8, 12), Vector2(16,16)), Rect2(frame*16,0,16,16), Color(1,1,1,0.55*fade))
    if bool(state.wind):
        for index in range(14):
            var seed := seeds[index]
            var point := _wrapped(seed, Vector2(age * (24.0 + seed.z * 8), sin(age + seed.z * 6.0) * 3.0))
            if not allows(_tile(point), "wind"): continue
            var alpha := fade * (0.3 + 0.25 * sin(age * 2.0 + seed.z * TAU))
            for strip in range(4):
                var at := point + Vector2(-8, -32 + strip * 16)
                if allows(_tile(at + Vector2(8,8)), "wind"):
                    draw_texture_rect_region(WIND, Rect2(at,Vector2(16,16)),Rect2(0,strip*16,16,16),Color(1,1,1,alpha))
    if state.kind == "sand":
        _draw_sandstorm(age, fade)
    if state.kind == "snow":
        for seed in seeds:
            var point := _wrapped(seed, Vector2(-age*(22+seed.z*18)+sin(age*1.5+seed.z*TAU)*5,age*(18+seed.z*10)))
            if not allows(_tile(point),"snow"): continue
            draw_circle(point,0.5+seed.z*0.5,Color(0.94,0.97,1.0,fade*(0.45+seed.z*0.4)))
    if state.kind == "fire":
        for record in state.fires:
            var cell := Vector2i(int(record[0]),int(record[1]))
            if not _safe_ground(cell) or not allows(world.exact_world.tile_at(cell),"fire"): continue
            var point := Vector2(cell)*16.0
            if not view.grow(32).has_point(point): continue
            var phase := float(record[2])
            var frame := 2 + posmod(int(age*8.0+phase*4),2)
            draw_texture_rect_region(FLAMES,Rect2(point,Vector2(16,16)),Rect2(frame*16,0,16,16),Color(1,1,1,fade))
            var ember := Vector2(sin(age*2+phase*6)*3,-fposmod(age*9+phase*20,22))
            draw_rect(Rect2(point+Vector2(8,8)+ember,Vector2.ONE),Color(1,0.65,0.2,fade*0.7))
    if bolt_age >= 0.0:
        var frame := mini(3,int(bolt_age*12.0))
        var alpha := clampf((0.55-bolt_age)/0.15,0,1)
        draw_texture_rect_region(BOLT,Rect2(bolt_position-Vector2(11,56),Vector2(22,56)),Rect2(frame*160+131,0,22,56),Color(1,1,1,alpha))
        if bolt_age >= 0.25 and bolt_age < 0.35: draw_rect(view,Color(1,1,0.9,0.13*(1-(bolt_age-0.25)/0.1)))

# Sand stays anchored to the world when the camera moves or zooms. The haze
# mask is rebuilt only on entering another visible tile rectangle.
var sand_bounds := Rect2i()
var sand_world_id := 0
var sand_haze: Array[Rect2] = []
func _draw_sandstorm(age: float, fade: float) -> void:
    var first := Vector2i(floori(view.position.x / 16.0), floori(view.position.y / 16.0))
    var last := Vector2i(ceili(view.end.x / 16.0), ceili(view.end.y / 16.0))
    var bounds := Rect2i(first, last - first)
    var identity: int = world.exact_world.get_instance_id()
    if bounds != sand_bounds or identity != sand_world_id:
        sand_bounds = bounds
        sand_world_id = identity
        sand_haze.clear()
        for y in range(first.y, last.y):
            var run := -2147483648
            for x in range(first.x, last.x + 1):
                var desert := x < last.x and allows(world.exact_world.tile_at(Vector2i(x,y)), "sand")
                if desert and run == -2147483648: run = x
                if not desert and run != -2147483648:
                    sand_haze.append(Rect2(run*16, y*16, (x-run)*16, 16))
                    run = -2147483648
    for patch in sand_haze:
        draw_rect(patch, Color(0.79, 0.61, 0.35, 0.20 * fade))
    # Small grains and soft clusters, not diagonal rain streaks. Fixed-size
    # repeating world regions retain density at every zoom level.
    var drift := Vector2(-age * 35.0, age * 10.0)
    var start := Vector2i(floori((view.position.x-drift.x)/128.0)-1, floori((view.position.y-drift.y)/128.0)-1)
    var finish := Vector2i(ceili((view.end.x-drift.x)/128.0), ceili((view.end.y-drift.y)/128.0))
    for y in range(start.y, finish.y+1):
        for x in range(start.x, finish.x+1):
            for index in range(128):
                var seed := seeds[index]
                var point := Vector2(x,y)*128.0 + Vector2(seed.x,seed.y)*128.0 + drift
                point.y += sin(age*1.4 + seed.z*TAU)*2.0
                if not view.grow(5).has_point(point) or not allows(_tile(point), "sand"): continue
                if index % 8 == 0:
                    draw_circle(point, 4.0, Color(0.74,0.53,0.28,0.025*fade))
                    draw_circle(point, 2.5, Color(0.74,0.53,0.28,0.045*fade))
                draw_rect(Rect2(point,Vector2(0.6+seed.z*0.6,0.6)),Color(0.46,0.32,0.16,fade*(0.18+seed.z*0.3)))
