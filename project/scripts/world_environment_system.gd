class_name WorldEnvironmentSystem
extends Node

# PokeWilds 0.8.11 uses 18,000 update ticks of daylight followed by 5,000
# update ticks of night. At the source update rate, one complete cycle is
# 23,000 / 60 seconds; the port uses that exact duration and 18:5 ratio.
const SOURCE_DAY_TICKS := 18000.0
const SOURCE_NIGHT_TICKS := 5000.0
const SOURCE_CYCLE_TICKS := SOURCE_DAY_TICKS + SOURCE_NIGHT_TICKS
const NIGHT_START_FRACTION := SOURCE_DAY_TICKS / SOURCE_CYCLE_TICKS
const SOURCE_FADE_SECONDS := 320.0 / 60.0
const CONTEXT_REFRESH_SECONDS := 0.20
const STRUCTURE_FRAME_SECONDS := 1.0 / 12.0
const MUSIC_VOLUME_DB := -9.0
const MUSIC_FADE_DB := -45.0
const SFX_VOLUME_DB := -14.0

const STAR_TEXTURE := preload("res://assets/environment/stars1.png")
const FOG_TEXTURES := [
    preload("res://assets/environment/fog1_alpha.png"),
    preload("res://assets/environment/fog2_alpha.png")
]
const SMOKE_TEXTURES := [
    preload("res://assets/environment/shade3_dithered.png"),
    preload("res://assets/environment/shade4_dithered.png")
]
# 2240x2240 (~19 MB decoded): loaded only when a deep forest is entered.
const DEEP_FOREST_TEXTURE_PATH := "res://assets/environment/source_forest_shade.png"
const FIRE_LIGHT_TEXTURES := [
    preload("res://assets/environment/fire_mask3.png"),
    preload("res://assets/environment/fire_mask4.png")
]
const TORCH_LIGHT_TEXTURES := [
    preload("res://assets/environment/torch_mask1.png"),
    preload("res://assets/environment/torch_mask2.png")
]

const CIRCLE_FIRE_LIGHT_TEXTURES := [
    preload("res://assets/circle_lights/fire_mask3.png"),
    preload("res://assets/circle_lights/fire_mask4.png")]
const CIRCLE_TORCH_LIGHT_TEXTURES := [
    preload("res://assets/circle_lights/torch_mask1.png"),
    preload("res://assets/circle_lights/torch_mask2.png")]

func light_textures(torch: bool) -> Array:
    if preload("res://scripts/game_options.gd").enabled("circle_lights"):
        return CIRCLE_TORCH_LIGHT_TEXTURES if torch else CIRCLE_FIRE_LIGHT_TEXTURES
    return TORCH_LIGHT_TEXTURES if torch else FIRE_LIGHT_TEXTURES

# Night lights. CanvasModulate still darkens the world canvas (ambient A). Every
# light is drawn additively, once, into a small light map (1 texel per world
# pixel, the visible area only), which stores L / LIGHT_MAP_RANGE. One
# full-screen pass at z 1024 (the top of a PointLight2D's default z range) then
# turns the ambient-lit screen a*A into a*(A + L), exactly what CanvasModulate
# plus additive PointLight2Ds gave, for a cost that no longer grows with the
# number of lights or of lit tiles. Nothing of it exists while no light is in
# view (daylight, indoors, most nights).
const LIGHT_MAP_RANGE := 4.0
const FIRE_LIGHT_COLOR := Color(1.0, 0.68, 0.34)
const FIRE_LIGHT_ENERGY := 0.82
const FLASH_LIGHT_COLOR := Color(1.0, 0.82, 0.55)
const FLASH_LIGHT_ENERGY := 1.15
const LIGHT_COMPOSITE_SHADER := """
shader_type canvas_item;
render_mode unshaded, blend_disabled;
uniform sampler2D screen_texture : hint_screen_texture, filter_nearest, repeat_disable;
uniform vec3 gain = vec3(1.0);
uniform vec4 lit_uv = vec4(0.0, 0.0, 1.0, 1.0);
void fragment() {
	vec4 screen = textureLod(screen_texture, SCREEN_UV, 0.0);
	vec3 light = texture(TEXTURE, UV).rgb;
	// Hard edge, like a light texture's own rectangle.
	if (any(lessThan(UV, lit_uv.xy)) || any(greaterThanEqual(UV, lit_uv.zw))) {
		light = vec3(0.0);
	}
	COLOR = vec4(screen.rgb * (1.0 + light * gain), screen.a);
}
"""

var world: Node2D
var canvas_modulate: CanvasModulate
var sky_root: Node2D
var sky_rect: TextureRect
var sky_star_rect: TextureRect
var effect_root: Node2D
var effect_rects: Array[TextureRect] = []
var light_viewport: SubViewport
var light_canvas: Node2D
var light_composite: Sprite2D
var light_draw_list: Array = []
var light_origin := Vector2i(2147483647, 2147483647)
# Other lights (co-op players): holder node -> [position, torch, scale, color].
var extra_lights: Dictionary = {}
var music_players: Array[AudioStreamPlayer] = []
var sfx_player: AudioStreamPlayer
var active_music_player := 0
var current_track := ""
var current_route := ""
var music_stream_cache: Dictionary = {}
var applied_lofi_music := false
var route_track_indices: Dictionary = {}
var current_phase_name := "day"
var current_weather_name := "clear"
var context_accumulator := CONTEXT_REFRESH_SECONDS
var structure_accumulator := 0.0
var animation_tick := 0
var cloud_motion := Vector2.ZERO
var effect_motion := Vector2.ZERO
var battle_suspended := false
var battle_music: AudioStreamPlayer
var battle_intro: AudioStreamOggVorbis
var battle_loop: AudioStreamOggVorbis
var battle_theme := "wild_battle"
var battle_uses_route_music := false
var source_night_alert := ""
var source_unown_active := false
var normal_overworld_track := "nature1_render"
var route_intro_pending: Dictionary = {}
var music_fade: Tween
var music_has_started := false
var music_was_night := false
var dawn_resume_at := -1
var music_world_id := 0
var music_transition_generation := 0
var initialized := false
var structure_frames: Dictionary = {}
# Lit structures and lava in reach: [position, torch] pairs.
var environmental_lights: Array = []
# Built CAMPFIRE/TORCH/chimney entries: [cell, data] pairs, rescanned only when
# a structure is built or removed instead of on every light update.
var animated_structures: Array = []
var animated_structures_dirty := true
var animated_structures_count := -1
var lava_scan_key := []
var lava_scan_cells: Array = []
var lava_name_ids: Dictionary = {}
var lava_name_count := -1
var last_step_sound_msec := -1000

func configure(world_node: Node2D) -> void:
    world = world_node
    _build_visual_nodes()
    _build_audio_nodes()
    if world.has_signal("player_stepped"):
        world.player_stepped.connect(_on_player_stepped)
    # Structure sprites (and a house's chimney) entering the tree mark the
    # animated/lit structure list stale.
    get_tree().node_added.connect(_on_node_added)
    # Battle.java / LinkedMusic: intro once, then the authored looping track.
    battle_intro = (_cached_music_stream("wild_battle_intro") as AudioStreamOggVorbis).duplicate()
    battle_loop = (_cached_music_stream("wild_battle") as AudioStreamOggVorbis).duplicate()
    battle_intro.loop = false
    battle_loop.loop = true
    battle_music = AudioStreamPlayer.new()
    battle_music.name = "SourceBattleMusic"
    preload("res://scripts/game_options.gd").route_audio(battle_music)
    battle_music.volume_db = MUSIC_VOLUME_DB
    battle_music.finished.connect(_on_battle_intro_finished)
    add_child(battle_music)
    var random_weather := preload("res://scripts/random_world_weather.gd").new()
    random_weather.name = "RandomWorldWeather"
    add_child(random_weather)
    random_weather.configure(world)
    initialized = true
    world.visibility_changed.connect(func(): _update_visuals(0.0))
    # Day/night music used to synchronously load its OGG on the exact transition
    # frame, causing a visible hitch. Cache the fixed night track during setup;
    # all later tracks are retained after their first load as well.
    for preload_track in [
            "night1", "nature1_render", "route_111-2", "DP_EternaForest"
        ]:
        _cached_music_stream(preload_track)
    _refresh_context(true)
    _update_visuals(0.0)

func _build_visual_nodes() -> void:
    canvas_modulate = CanvasModulate.new()
    canvas_modulate.name = "EnvironmentCanvasModulate"
    canvas_modulate.color = Color.WHITE
    add_child(canvas_modulate)

    sky_root = Node2D.new()
    sky_root.name = "EnvironmentSky"
    sky_root.visible = false
    sky_root.z_as_relative = false
    sky_root.z_index = -4096
    add_child(sky_root)
    sky_rect = _make_tiled_rect(SourceWorldData.reflected_day_sky_texture())
    sky_root.add_child(sky_rect)
    # Keep the night texture resident from startup. Day/night now cross-switches
    # alpha instead of assigning a different texture on the transition frame.
    sky_star_rect = _make_tiled_rect(STAR_TEXTURE)
    sky_star_rect.modulate = Color(1.0, 1.0, 1.0, 0.001)
    sky_root.add_child(sky_star_rect)

    effect_root = Node2D.new()
    effect_root.name = "EnvironmentWeather"
    effect_root.z_as_relative = false
    effect_root.z_index = 4095
    add_child(effect_root)
    for texture in [FOG_TEXTURES[0], FOG_TEXTURES[1]]:
        var rect := _make_tiled_rect(texture)
        rect.visible = false
        effect_root.add_child(rect)
        effect_rects.append(rect)

    light_viewport = SubViewport.new()
    light_viewport.name = "EnvironmentLightMap"
    light_viewport.transparent_bg = true
    light_viewport.disable_3d = true
    light_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
    light_viewport.size = Vector2i(2, 2)
    add_child(light_viewport)
    light_canvas = Node2D.new()
    var additive := CanvasItemMaterial.new()
    additive.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
    light_canvas.material = additive
    light_canvas.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
    light_canvas.draw.connect(_draw_lights)
    light_viewport.add_child(light_canvas)
    light_composite = Sprite2D.new()
    light_composite.name = "EnvironmentLights"
    light_composite.centered = false
    light_composite.region_enabled = true
    light_composite.texture = light_viewport.get_texture()
    # A PointLight2D lit z -1024..1024 by default; weather above stays unlit.
    light_composite.z_as_relative = false
    light_composite.z_index = 1024
    light_composite.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
    var composite := ShaderMaterial.new()
    composite.shader = Shader.new()
    composite.shader.code = LIGHT_COMPOSITE_SHADER
    light_composite.material = composite
    light_composite.visible = false
    add_child(light_composite)

func _make_tiled_rect(texture: Texture2D) -> TextureRect:
    var rect := TextureRect.new()
    rect.texture = texture
    rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
    rect.stretch_mode = TextureRect.STRETCH_TILE
    rect.texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED
    rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
    return rect

func _build_audio_nodes() -> void:
    for index in range(2):
        var player := AudioStreamPlayer.new()
        player.name = "WorldMusic%d" % (index + 1)
        preload("res://scripts/game_options.gd").route_audio(player)
        player.volume_db = MUSIC_FADE_DB
        player.finished.connect(_on_music_finished.bind(index))
        add_child(player)
        music_players.append(player)
    sfx_player = AudioStreamPlayer.new()
    sfx_player.name = "WorldEnvironmentSfx"
    preload("res://scripts/game_options.gd").route_audio(sfx_player)
    sfx_player.volume_db = SFX_VOLUME_DB
    add_child(sfx_player)

func _process(delta: float) -> void:
    if not initialized or world == null or not is_instance_valid(world):
        return
    context_accumulator += delta
    structure_accumulator += delta
    if context_accumulator >= CONTEXT_REFRESH_SECONDS:
        context_accumulator = fmod(context_accumulator, CONTEXT_REFRESH_SECONDS)
        _refresh_context(false)
    if structure_accumulator >= STRUCTURE_FRAME_SECONDS:
        structure_accumulator = fmod(structure_accumulator, STRUCTURE_FRAME_SECONDS)
        animation_tick = posmod(animation_tick + 5, 2400)
        _update_environment_lights()
    _update_visuals(delta)

func _update_visuals(delta: float) -> void:
    var context := _environment_context()
    var indoors := bool(context.get("indoors", true))
    var fraction := time_fraction()
    current_phase_name = phase_at_fraction(fraction)
    var day_color := color_at_fraction(fraction)
    # A brand-new Java world starts in full daylight; dawn interpolation only
    # happens after the first completed night.
    if float(world.get("world_elapsed_seconds")) < SOURCE_FADE_SECONDS:
        current_phase_name = "day"
        day_color = Color.WHITE
    var biome_color := _biome_tint(context, fraction)
    canvas_modulate.color = Color.WHITE if indoors else _multiply_color(day_color, biome_color)

    var center := _camera_center()
    var view_size := _world_view_size()
    var padding := Vector2(256.0, 256.0)
    sky_root.position = center - view_size * 0.5 - padding
    effect_root.position = sky_root.position
    sky_rect.size = view_size + padding * 2.0
    sky_star_rect.size = view_size + padding * 2.0
    for rect in effect_rects:
        rect.size = view_size + padding * 2.0

    if not indoors:
        var night_sky: bool = current_phase_name in ["sunset", "night"]
        # Hide the unused sky instead of drawing it at alpha 0.001: both are
        # full-screen tiled rects. The textures stay referenced (resident).
        sky_rect.modulate = Color.WHITE
        sky_star_rect.modulate = Color.WHITE
        sky_rect.visible = not night_sky
        sky_star_rect.visible = night_sky
        sky_star_rect.position = Vector2.ZERO
        cloud_motion += Vector2(-2.0, -9.0) * delta
        # Keep the cloud phase fixed in world space when zoom changes the
        # padded sky rectangle's origin and camera center.
        sky_rect.position = Vector2(
            fposmod(cloud_motion.x - sky_root.position.x, 192.0),
            fposmod(cloud_motion.y - sky_root.position.y, 192.0)
        )
    sky_root.visible = world.is_visible_in_tree() and not indoors

    effect_motion += _effect_velocity(current_weather_name) * delta
    for index in range(effect_rects.size()):
        var rect := effect_rects[index]
        if current_weather_name == "deep_forest":
            rect.position = Vector2(-fposmod(effect_root.position.x, 2240.0), -fposmod(effect_root.position.y, 2240.0))
            rect.size = view_size + padding * 2.0 + Vector2(2240, 2240)
            continue
        rect.position = Vector2(
            fmod(effect_motion.x * (1.0 + index * 0.35), 64.0),
            fmod(effect_motion.y * (1.0 + index * 0.20), 64.0)
        )

    var flash_active := (
        not indoors
        and String(world.get("active_field_move")) in ["FLASH", "POWER"]
        and _color_brightness(canvas_modulate.color) < 0.92
        and world.has_method("environment_player_position")
    )
    _update_light_map(center, view_size, Vector2(world.call("environment_player_position")) if flash_active else null)

func set_extra_light(holder: Node, light: Array) -> void:
    ## light: [position, torch, scale, color * energy]; empty removes it.
    if light.is_empty(): extra_lights.erase(holder)
    else: extra_lights[holder] = light

func _update_light_map(center: Vector2, view_size: Vector2, flash: Variant) -> void:
    if environmental_lights.is_empty() and flash == null and extra_lights.is_empty() and not light_composite.visible:
        return  # daylight, indoors: nothing to do
    var view := Rect2(center - view_size * 0.5, view_size).grow(1.0)
    var frame := posmod(animation_tick / 10, 2)
    var textures: Array = [light_textures(false)[frame], light_textures(true)[frame]]
    var draw_list: Array = []
    if world.is_visible_in_tree() and DisplayServer.get_name() != "headless":
        var fire := FIRE_LIGHT_COLOR * (FIRE_LIGHT_ENERGY / LIGHT_MAP_RANGE)
        for light in environmental_lights:
            _add_light(draw_list, view, light[0], textures[int(light[1])], 1.0, fire)
        if flash != null:
            _add_light(draw_list, view, flash, textures[0], 1.2, FLASH_LIGHT_COLOR * (FLASH_LIGHT_ENERGY / LIGHT_MAP_RANGE))
        for holder in extra_lights.keys():
            var light: Array = extra_lights[holder]
            if not is_instance_valid(holder) or not (holder as Node).is_inside_tree():
                extra_lights.erase(holder)
                continue
            if holder is CanvasItem and not (holder as CanvasItem).is_visible_in_tree():
                continue
            _add_light(draw_list, view, light[0], textures[int(light[1])], light[2], (light[3] as Color) / LIGHT_MAP_RANGE)
    var lit := Rect2()
    for entry in draw_list:
        lit = lit.merge(entry[1]) if lit.has_area() else entry[1]
    lit = lit.intersection(view)
    if not lit.has_area():
        if light_composite.visible:
            light_composite.visible = false
            light_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
            light_draw_list = []
        return
    var origin := Vector2i(view.position.floor())
    var size := Vector2i(view.end.ceil()) - origin
    var changed := false
    if light_viewport.size != size:
        light_viewport.size = size
        changed = true
    if origin != light_origin:
        light_origin = origin
        light_viewport.canvas_transform = Transform2D(0.0, -Vector2(origin))
        changed = true
    if draw_list != light_draw_list:
        light_draw_list = draw_list
        light_canvas.queue_redraw()
        changed = true
    if changed:
        light_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
    var ambient := canvas_modulate.color
    var composite := light_composite.material as ShaderMaterial
    composite.set_shader_parameter("gain", Vector3(
        LIGHT_MAP_RANGE / maxf(ambient.r, 0.01), LIGHT_MAP_RANGE / maxf(ambient.g, 0.01), LIGHT_MAP_RANGE / maxf(ambient.b, 0.01)))
    # Only the screen area the lights cover is shaded. Its corners sit on whole
    # screen pixels so vertex snapping cannot shift the lights against the
    # world (a PointLight2D's texture is never snapped).
    var to_screen := light_composite.get_viewport_transform()
    var screen := to_screen * lit
    var quad := to_screen.affine_inverse() * Rect2(screen.position.floor(), screen.end.ceil() - screen.position.floor())
    light_composite.position = quad.position
    light_composite.region_rect = Rect2(quad.position - Vector2(origin), quad.size)
    var map_size := Vector2(size)
    composite.set_shader_parameter("lit_uv", Vector4((lit.position.x - origin.x) / map_size.x, (lit.position.y - origin.y) / map_size.y,
        (lit.end.x - origin.x) / map_size.x, (lit.end.y - origin.y) / map_size.y))
    light_composite.visible = true

func _add_light(draw_list: Array, view: Rect2, position: Vector2, texture: Texture2D, scale: float, color: Color) -> void:
    # A PointLight2D: the texture centred on the light, scaled, times colour x energy.
    var size := texture.get_size() * scale
    var rect := Rect2(position - size * 0.5, size)
    if rect.intersects(view):
        color.a = 1.0
        draw_list.append([texture, rect, color])

func _draw_lights() -> void:
    for light in light_draw_list:
        # One clamped texel more on every side: the map's bilinear filter then
        # keeps a light's edge texels whole up to its hard edge, as the light
        # texture's own filter did (the composite stops at the outer edge).
        var texture: Texture2D = light[0]
        var rect: Rect2 = light[1]
        var texel := rect.size / texture.get_size()
        light_canvas.draw_texture_rect_region(texture, rect.grow_individual(texel.x, texel.y, texel.x, texel.y),
            Rect2(-Vector2.ONE, texture.get_size() + Vector2(2.0, 2.0)), light[2])

func _refresh_context(force: bool) -> void:
    var context := _environment_context()
    var next_weather := weather_for_context(context)
    if (force or next_weather != current_weather_name) and _configure_weather_visuals(next_weather):
        current_weather_name = next_weather
    if not bool(world.get("generated")):
        return
    var next_world_id: int = world.exact_world.get_instance_id() if world.exact_world != null else 0
    if next_world_id != music_world_id:
        music_world_id = next_world_id
        music_has_started = false
        dawn_resume_at = -1
        normal_overworld_track = "nature1_render"
        source_night_alert = ""
        source_unown_active = false
        current_track = ""
        current_route = ""
        route_track_indices.clear()
    if not battle_suspended and bool(world.get("gameplay_enabled")) and not bool(world.get("restoring_saved_tiles")):
        var saved_unown := preload("res://scripts/source_unown_event.gd").active(world)
        if saved_unown and not source_unown_active:
            start_unown_music()
        elif not saved_unown and source_unown_active:
            source_unown_active = false
            current_track = ""
    if battle_suspended or source_unown_active:
        return
    var music_night := _source_music_is_night()
    if not music_has_started:
        music_has_started = true
        music_was_night = music_night
        var tile: SourceTile = world.exact_world.tile_at(world._player_cell()) if world.exact_world != null else null
        if tile != null and ("sand" in tile.name or "beach" in String(context.get("route_name",""))):
            normal_overworld_track = "waves1"
        elif String(context.get("route_type","")) == "volcano":
            normal_overworld_track = "ambient_rumbling"
    if not bool(context.get("dungeon",false)) and music_was_night and not music_night and dawn_resume_at < 0:
        dawn_resume_at = preload("res://scripts/game_clock.gd").ticks_msec() + 6200
        if music_fade != null and music_fade.is_valid(): music_fade.kill()
        music_fade = create_tween()
        music_fade.tween_property(music_players[active_music_player],"volume_db",MUSIC_FADE_DB,0.2)
        music_fade.tween_callback(music_players[active_music_player].stop)
        normal_overworld_track = _route_music_choice(String(context.get("route_name","")),true)
    music_was_night = music_night
    if dawn_resume_at >= 0:
        if preload("res://scripts/game_clock.gd").ticks_msec() < dawn_resume_at and not bool(context.get("dungeon",false)): return
        dawn_resume_at = -1
        force = true
    var route_name := String(context.get("route_name", ""))
    var desired_track := _desired_track(context, force or route_name != current_route)
    current_route = route_name
    if not desired_track.is_empty() and (force or desired_track != current_track):
        _crossfade_to(desired_track)

## False while the weather's texture still loads: the context refresh asks again.
func _configure_weather_visuals(weather_name: String) -> bool:
    var textures: Array = []
    var modulates := [Color.WHITE, Color.WHITE]
    match weather_name:
        "fog":
            textures = FOG_TEXTURES
            modulates = [Color(1, 1, 1, 0.69), Color(1, 1, 1, 0.54)]
        "smoke":
            textures = SMOKE_TEXTURES
            modulates = [Color(0.58, 0.50, 0.48, 0.34), Color(0.68, 0.58, 0.52, 0.24)]
        "deep_forest":
            # Not resident: decoded on a loader thread (a plain load() held up
            # the frame the forest was entered on), shown once it is ready.
            var status := ResourceLoader.load_threaded_get_status(DEEP_FOREST_TEXTURE_PATH)
            if status == ResourceLoader.THREAD_LOAD_LOADED:
                textures = [ResourceLoader.load_threaded_get(DEEP_FOREST_TEXTURE_PATH)]
            elif ResourceLoader.has_cached(DEEP_FOREST_TEXTURE_PATH):
                textures = [load(DEEP_FOREST_TEXTURE_PATH)]
            else:
                if status != ResourceLoader.THREAD_LOAD_IN_PROGRESS:
                    ResourceLoader.load_threaded_request(DEEP_FOREST_TEXTURE_PATH)
                return false
            modulates = [Color(1, 1, 1, 0.4)]
        _:
            pass
    for index in range(effect_rects.size()):
        var rect := effect_rects[index]
        rect.visible = index < textures.size()
        if rect.visible:
            rect.texture = textures[index] as Texture2D
            rect.modulate = modulates[index]
    return true

func _desired_track(context: Dictionary, _route_changed: bool) -> String:
    if source_unown_active: return "unown1"
    var dungeon := bool(context.get("dungeon", false))
    var route_name := String(context.get("route_name", ""))
    var route_type := String(context.get("route_type", ""))
    if dungeon:
        return _route_music_choice(route_name, false)
    if _source_music_is_night():
        return source_night_alert if not source_night_alert.is_empty() else "night1"
    # MusicController.isBiome: these four routes override the outdoor playlist.
    if route_type in ["desert", "graveyard", "volcano", "deep_forest"]:
        return _route_music_choice(route_name, false)
    return normal_overworld_track

func _advance_route_track() -> String:
    if source_unown_active: return "unown1"
    var context := _environment_context()
    if bool(context.get("dungeon", false)) or String(context.get("route_type", "")) in ["desert", "graveyard", "volcano", "deep_forest"]:
        return _desired_track(context, false)
    if _source_music_is_night():
        return source_night_alert if not source_night_alert.is_empty() else "night1"
    normal_overworld_track = _route_music_choice(String(context.get("route_name", "")), true)
    return normal_overworld_track

func _route_music_choice(route_name: String, advance: bool) -> String:
    var choices := SourceRouteData.music(route_name)
    if choices.is_empty():
        return "nature1_render"
    var index := int(route_track_indices.get(route_name, 0))
    if advance:
        index += 1
        route_track_indices[route_name] = index
    return String(choices[posmod(index, choices.size())])

func _normal_music_choice(advance: bool) -> String:
    var choices := SourceRouteData.DEFAULT_MUSIC
    if choices.is_empty():
        return "nature1_render"
    var key := "__normal_outdoors__"
    var index := int(route_track_indices.get(key, 0))
    if advance:
        index += 1
        route_track_indices[key] = index
    return String(choices[posmod(index, choices.size())])

func _cached_music_stream(track_name: String) -> AudioStream:
    var path := "res://assets/environment/music/%s.ogg" % track_name
    if preload("res://scripts/game_options.gd").enabled("lofi_music"):
        # The supplied pack omits the 'n' in the source mansion filename.
        var pack_name := "pkmmansion" if track_name == "pkmnmansion" else track_name
        var alternate := "res://assets/lofi/music/%s.ogg" % pack_name
        if ResourceLoader.exists(alternate): path = alternate
    if music_stream_cache.has(path):
        return music_stream_cache[path] as AudioStream
    if not ResourceLoader.exists(path):
        return null
    var stream := load(path) as AudioStream
    if stream != null:
        stream.set_meta("music_track", track_name)
        stream.set_meta("music_asset", path)
        stream.set_meta("balanced_db", AudioBalance.level_db(stream))
        # The last few tracks only: players keep the ones in use alive.
        if music_stream_cache.size() >= 4: music_stream_cache.erase(music_stream_cache.keys()[0])
        music_stream_cache[path] = stream
    return stream

func _pack_replacement(old: AudioStream) -> AudioStream:
    if old == null: return old
    var track := String(old.get_meta("music_track", ""))
    if track.is_empty(): return old
    var next := _cached_music_stream(track)
    if next == null or String(next.get_meta("music_asset",next.resource_path)) == String(old.get_meta("music_asset",old.resource_path)): return old
    var replacement := next.duplicate() as AudioStreamOggVorbis
    if replacement != null and old is AudioStreamOggVorbis:
        replacement.loop = (old as AudioStreamOggVorbis).loop
        replacement.loop_offset = (old as AudioStreamOggVorbis).loop_offset
        return replacement
    return next

func apply_music_pack() -> void:
    var enabled := preload("res://scripts/game_options.gd").enabled("lofi_music")
    if not initialized or enabled == applied_lofi_music: return
    applied_lofi_music = enabled
    # Retain each cue's role (route intro, battle intro, loop or victory).
    # Arrangements have different lengths, so start the matching cue from its
    # beginning instead of seeking to an unrelated timestamp in the new track.
    if music_fade != null and music_fade.is_valid(): music_fade.kill()
    for i in range(music_players.size()):
        if i != active_music_player: music_players[i].stop()
    battle_intro = _pack_replacement(battle_intro) as AudioStreamOggVorbis
    battle_loop = _pack_replacement(battle_loop) as AudioStreamOggVorbis
    for player in music_players + [battle_music]:
        var old: AudioStream = player.stream
        var replacement := _pack_replacement(old)
        var was_paused: bool = player.stream_paused
        # Godot reports playing=false for a paused active stream.
        var was_playing: bool = player.playing or was_paused
        if replacement != old:
            player.stream = replacement
            if was_playing: player.play()
            player.stream_paused = was_paused
        if player.stream != null: AudioBalance.apply(player)

func _crossfade_to(track_name: String) -> void:
    var next_stream := _cached_music_stream(track_name)
    if next_stream == null:
        return
    music_transition_generation += 1
    var next_index := 1 - active_music_player
    var old_player := music_players[active_music_player]
    var next_player := music_players[next_index]
    next_player.stop()
    route_intro_pending.erase(next_index)
    if track_name == "route_111-2":
        var intro := _cached_music_stream("route_111-2_intro")
        next_player.stream = intro
        route_intro_pending[next_index] = track_name
    else:
        next_player.stream = next_stream
    next_player.volume_db = MUSIC_FADE_DB
    next_player.stream_paused = battle_suspended
    var first_nature := current_track.is_empty() and track_name == "nature1_render"
    next_player.play(130.0 if first_nature else 0.0)
    if music_fade != null and music_fade.is_valid():
        music_fade.kill()
    var tween := create_tween().set_parallel(true)
    music_fade = tween
    tween.tween_property(next_player, "volume_db", AudioBalance.level_db(next_player.stream), 0.8)
    if old_player.playing:
        tween.tween_property(old_player, "volume_db", MUSIC_FADE_DB, 0.8)
        tween.chain().tween_callback(old_player.stop)
    active_music_player = next_index
    current_track = track_name

func _on_music_finished(index: int) -> void:
    if (battle_suspended and not battle_uses_route_music) or index != active_music_player:
        return
    if route_intro_pending.has(index):
        music_players[index].stream = _cached_music_stream(String(route_intro_pending[index]))
        route_intro_pending.erase(index)
        AudioBalance.apply(music_players[index])
        music_players[index].play()
        return
    var next_track := _advance_route_track()
    var context := _environment_context()
    if not bool(context.get("dungeon",false)) and not _source_music_is_night() and String(context.get("route_type","")) not in ["desert","graveyard","volcano","deep_forest"]:
        # MusicController's outdoor completion chain waits 360 source ticks.
        # A route/day change cancels the pending track; a battle defers it.
        var generation := music_transition_generation
        var deadline := preload("res://scripts/game_clock.gd").ticks_usec()+6000000
        while preload("res://scripts/game_clock.gd").ticks_usec()<deadline:
            await get_tree().process_frame
        while battle_suspended and generation == music_transition_generation:
            await get_tree().process_frame
        if generation != music_transition_generation or index != active_music_player:
            return
    if next_track == current_track:
        var player := music_players[active_music_player]
        player.play()
    else:
        _crossfade_to(next_track)

func set_battle_suspended(value: bool) -> void:
    if value == battle_suspended:
        return
    battle_suspended = value
    if not value and source_unown_active:
        source_unown_active = false
        current_track = ""
    if value:
        var context := _environment_context()
        battle_uses_route_music = battle_theme != "pokemon_mansion_remix_eq" and (_source_music_is_night() or source_unown_active) and not bool(context.get("dungeon", false))
    for player in music_players:
        player.stream_paused = value and not battle_uses_route_music
    if sfx_player != null:
        sfx_player.stream_paused = value
    if value and battle_theme == "pokemon_mansion_remix_eq":
        battle_loop = (_cached_music_stream(battle_theme) as AudioStreamOggVorbis).duplicate()
        battle_loop.loop = true
        battle_music.volume_db = linear_to_db(0.7)
        battle_music.stream = battle_loop
        AudioBalance.apply(battle_music)
        battle_music.play()
        return
    if value and not battle_uses_route_music:
        battle_intro = (_cached_music_stream(battle_theme + "_intro") as AudioStreamOggVorbis).duplicate()
        battle_loop = (_cached_music_stream(battle_theme) as AudioStreamOggVorbis).duplicate()
        battle_intro.loop = false
        battle_loop.loop = true
        battle_music.volume_db = linear_to_db(0.3 if "regi" in battle_theme else (0.6 if battle_theme == "bw_legendary_theme3" else 0.4))
        battle_music.stream = battle_intro
        AudioBalance.apply(battle_music)
        battle_music.play()
    else:
        battle_music.stop()
        context_accumulator = CONTEXT_REFRESH_SECONDS

func _on_battle_intro_finished() -> void:
    if battle_suspended:
        battle_music.stream = battle_loop
        AudioBalance.apply(battle_music)
        battle_music.play()

func _play_footstep(sound_name: String, volume: float) -> void:
    var path:="res://assets/source_audio/sounds/%s.ogg" % sound_name
    if not ResourceLoader.exists(path):path="res://assets/environment/sounds/%s.ogg" % sound_name
    if not ResourceLoader.exists(path):return
    var audio:=AudioStreamPlayer.new();audio.set_meta("footstep",true);audio.stream=load(path);add_child(audio)
    AudioBalance.apply(audio);audio.volume_db=linear_to_db(volume)
    audio.finished.connect(audio.queue_free);audio.play()

func _on_player_stepped() -> void:
    if battle_suspended or world == null or String(world.get("active_field_move"))=="FLY":return
    var now:=preload("res://scripts/game_clock.gd").ticks_msec()
    if now-last_step_sound_msec<130:return
    var flags:Dictionary=world.environment_tile_flags()
    # PlayerMoving/PlayerRunning: tidal sounds overlap; puddles use puddle8.
    if bool(flags.get("puddle",false)) and String(world.get("active_field_species"))!="probopass":_play_footstep("puddle8",0.2)
    if bool(flags.get("tidal",false)):
        _play_footstep("puddle11",0.2);_play_footstep("puddle9",0.2)
    elif bool(flags.get("dry_tidal",false)) and String(world.get("active_field_move")) != "SURF":
        _play_footstep("sand1",0.1)
    if String(world.get("active_field_move"))=="SURF":
        if not world.player.source_alternate_step:_play_footstep("swim1",0.2)
        _play_footstep("sand1",0.1)
    last_step_sound_msec=now

func play_source_sound(sound_name: String) -> void:
    if sound_name.to_lower().ends_with(".ogg"):
        sound_name = sound_name.left(-4)
    _play_environment_sound(sound_name)

func _play_environment_sound(sound_name: String, gain_db: float = 0.0) -> void:
    var paths := [
        "res://assets/source_audio/sounds/%s.ogg" % sound_name,
        "res://assets/environment/sounds/%s.ogg" % sound_name,
    ]
    for path in paths:
        if not ResourceLoader.exists(path):
            continue
        sfx_player.stream = load(path) as AudioStream
        # UI confirmations retain the general effects slider. World actions use their own bus.
        sfx_player.set_meta("world_sound", not sound_name.to_lower() in ["save1", "menu_open1", "menu_switch2", "error1", "click1", "ball_switch1", "enter1"])
        AudioBalance.apply(sfx_player)
        sfx_player.volume_db += gain_db
        sfx_player.play()
        return

func _on_node_added(node: Node) -> void:
    if node is Sprite2D and (node.name == &"CHIMNEY" or node.get_parent().name == &"LandmarkLayer"):
        animated_structures_dirty = true

func _refresh_animated_structures(structures: Dictionary) -> void:
    if not animated_structures_dirty and structures.size() == animated_structures_count:
        return
    animated_structures_dirty = false
    animated_structures_count = structures.size()
    animated_structures.clear()
    for raw_cell in structures.keys():
        var data := structures[raw_cell] as Dictionary
        if String(data.get("name", "")) in ["CAMPFIRE", "TORCH"] or bool(data.get("chimney", false)):
            animated_structures.append([Vector2i(raw_cell), data])

func _update_environment_lights() -> void:
    if world == null or not bool(world.get("generated")):
        return
    environmental_lights.clear()
    var dark_enough := _color_brightness(canvas_modulate.color) < 0.94
    var structures := world.get("built_structures") as Dictionary
    _refresh_animated_structures(structures)
    for entry in animated_structures:
        var cell: Vector2i = entry[0]
        var data: Dictionary = entry[1]
        if not is_same(structures.get(cell), data):
            # Removed or replaced since the last scan: rescan next update.
            animated_structures_dirty = true
            continue
        var name := String(data.get("name", ""))
        var sprite := data.get("sprite") as Sprite2D
        if bool(data.get("chimney", false)) and is_instance_valid(sprite):
            sprite = sprite.get_node_or_null("CHIMNEY") as Sprite2D
            name = "CHIMNEY"
        var frame := 0
        if name in ["CAMPFIRE", "TORCH"]:
            frame = posmod(animation_tick / 40, 2)
        elif name == "CHIMNEY":
            frame = posmod(animation_tick / 20, 4)
        if name in ["CAMPFIRE", "TORCH", "CHIMNEY"] and is_instance_valid(sprite):
            var sprite_key := sprite.get_instance_id()
            if int(structure_frames.get(sprite_key, -1)) != frame:
                structure_frames[sprite_key] = frame
                if world.has_method("environment_structure_texture"):
                    var frame_texture := world.call(
                        "environment_structure_texture", name, frame
                    ) as Texture2D
                    if frame_texture != null:
                        if name == "CHIMNEY" and sprite.has_meta("chimney_atlas"):
                            frame_texture = frame_texture.duplicate()
                            (frame_texture as AtlasTexture).atlas = sprite.get_meta("chimney_atlas")
                        sprite.texture = frame_texture
                        sprite.position.y = (16 if bool(data.get("chimney", false)) else (cell.y + 1) * 16) - frame_texture.get_height()
        var lit := name == "CAMPFIRE" or (
            name == "TORCH" and bool(data.get("lit", true))
        )
        if lit and dark_enough:
            environmental_lights.append([Vector2(cell * 16) + Vector2(8, 8), name == "TORCH"])

    if dark_enough and world.has_method("environment_nearby_lava_cells"):
        # The 25x25 lava scan only reruns when the player changes cell or area.
        # ponytail: lava painted or removed under a standing player shows on the next step.
        var key := [world.call("_player_cell"), world.get("active_area_id"), world.get("exact_world")]
        if key != lava_scan_key:
            lava_scan_key = key
            lava_scan_cells = _nearby_lava_cells(Vector2i(key[0]), 12)
        for raw_cell in lava_scan_cells.slice(0, mini(24, lava_scan_cells.size())):
            var cell := Vector2i(raw_cell)
            environmental_lights.append([Vector2(cell * 16) + Vector2(8, 8), true])

# world.environment_nearby_lava_cells() (same cells, same order) read straight
# from the packed overworld store: tile_at() builds a full tile proxy per cell,
# ~6 ms for the 625 cells around the player.
func _nearby_lava_cells(center: Vector2i, radius: int) -> Array:
    var store := world.exact_world.tiles as WorldTileStore if world.get("exact_world") != null else null
    if store == null or not store.extra.is_empty() or world.get("active_area_id") != "OVERWORLD" or not bool(world.get("exact_world_mode")):
        return world.call("environment_nearby_lava_cells", radius) as Array
    if lava_name_count != store.strings.size():
        lava_name_count = store.strings.size()
        lava_name_ids.clear()
        for id in store.strings.size():
            if "lava" in store.strings[id]: lava_name_ids[id] = true
    var result: Array = []
    for y in range(center.y - radius, center.y + radius + 1):
        var row := y - store.origin.y
        if row < 0 or row >= store.height: continue
        for x in range(center.x - radius, center.x + radius + 1):
            var column := x - store.origin.x
            if column < 0 or column >= store.width: continue
            var index := row * store.width + column
            var bits := store.flags[index]
            if bits & WorldTileStore.PRESENT and (bits & WorldTileStore.LAVA
                    or lava_name_ids.has(store.name_ids[index]) or lava_name_ids.has(store.upper_ids[index])):
                result.append(Vector2i(x, y))
    return result

func _environment_context() -> Dictionary:
    if world != null and world.has_method("environment_context"):
        return world.call("environment_context") as Dictionary
    return {"indoors": true, "dungeon": false, "route_name": "", "route_type": "", "biome": ""}

func _camera_center() -> Vector2:
    if world != null and world.has_method("environment_camera_center"):
        return Vector2(world.call("environment_camera_center"))
    return Vector2.ZERO

func _world_view_size() -> Vector2:
    var size := get_viewport().get_visible_rect().size
    var camera := get_viewport().get_camera_2d()
    if camera != null:
        size /= Vector2(maxf(camera.zoom.x, 0.01), maxf(camera.zoom.y, 0.01))
    return size

func time_fraction() -> float:
    if world == null:
        return 0.0
    var day_seconds := _world_day_seconds()
    return fmod(float(world.get("world_elapsed_seconds")), day_seconds) / day_seconds

func is_night_time() -> bool:
    return time_fraction() >= NIGHT_START_FRACTION

func phase_at_fraction(fraction: float) -> String:
    var fade_fraction := SOURCE_FADE_SECONDS / _world_day_seconds()
    if fraction < fade_fraction:
        return "dawn"
    if fraction < NIGHT_START_FRACTION:
        return "day"
    if fraction < NIGHT_START_FRACTION + fade_fraction:
        return "sunset"
    return "night"

func color_at_fraction(fraction: float) -> Color:
    var day_seconds := _world_day_seconds()
    var fade_fraction := SOURCE_FADE_SECONDS / day_seconds
    var night_color := Color(0.30, 0.30, 0.70, 1.0)
    if fraction < fade_fraction:
        return _sample_color_keys([
            night_color,
            Color(0.50, 0.50, 0.60, 1.0),
            Color(0.80, 0.80, 0.80, 1.0),
            Color.WHITE
        ], fraction / fade_fraction)
    if fraction < NIGHT_START_FRACTION:
        return Color.WHITE
    if fraction < NIGHT_START_FRACTION + fade_fraction:
        return _sample_color_keys([
            Color(1.00, 0.90, 0.50, 1.0),
            Color(0.90, 0.55, 0.20, 1.0),
            Color(0.40, 0.30, 0.30, 1.0),
            night_color
        ], (fraction - NIGHT_START_FRACTION) / fade_fraction)
    return night_color

func _sample_color_keys(keys: Array, progress: float) -> Color:
    var scaled := clampf(progress, 0.0, 1.0) * float(keys.size() - 1)
    var from_index := mini(int(floor(scaled)), keys.size() - 1)
    var to_index := mini(from_index + 1, keys.size() - 1)
    return (keys[from_index] as Color).lerp(keys[to_index] as Color, scaled - floor(scaled))

func weather_for_context(context: Dictionary) -> String:
    if bool(context.get("indoors", true)):
        return "clear"
    var route_type := String(context.get("route_type", ""))
    if route_type == "volcano":
        return "smoke"
    if route_type == "deep_forest" and not is_night_time():
        return "deep_forest"
    if is_night_time():
        return "clear"
    if route_type == "graveyard":
        return "fog"
    return "clear"

func _biome_tint(context: Dictionary, fraction: float) -> Color:
    if fraction >= NIGHT_START_FRACTION:
        return Color.WHITE
    match String(context.get("route_type", "")):
        "graveyard":
            return Color(0.90, 0.90, 1.00, 1.0)
        "volcano":
            return Color(1.00, 0.70, 0.70, 1.0)
        "deep_forest":
            return Color(0.70, 0.70, 1.00, 1.0)
        _:
            return Color.WHITE

func _effect_velocity(weather_name: String) -> Vector2:
    match weather_name:
        "fog":
            return Vector2(7.0, 1.5)
        "smoke":
            return Vector2(-3.0, -5.0)
        "deep_forest":
            return Vector2(1.5, 0.8)
        _:
            return Vector2.ZERO

func _multiply_color(left: Color, right: Color) -> Color:
    return Color(left.r * right.r, left.g * right.g, left.b * right.b, 1.0)

func _color_brightness(color: Color) -> float:
    return (color.r + color.g + color.b) / 3.0

func _world_day_seconds() -> float:
    if world != null and world.has_method("environment_day_seconds"):
        return maxf(1.0, float(world.call("environment_day_seconds")))
    return 600.0

func debug_snapshot() -> Dictionary:
    return {
        "phase": current_phase_name,
        "weather": current_weather_name,
        "track": current_track,
        "route": current_route,
        "night": is_night_time(),
        "fraction": time_fraction(),
        "battle_suspended": battle_suspended,
        "light_count": environmental_lights.size()
    }

func prepare_battle_music(context: Dictionary) -> void:
    battle_theme = "wild_battle"
    var party: Array = context.get("party", [])
    if party.is_empty(): return
    var species := String(party[0].get("species", "")).to_lower()
    if String(context.get("kind", "wild")) in ["special", "legendary", "event", "boss"] or String(context.get("id", "")).contains(species):
        if species in ["regirock", "regice", "registeel", "regieleki", "regidrago"]:
            battle_theme = "regi_battle1"
        elif species == "regigigas":
            battle_theme = "gigas_battle1"
        elif species == "mewtwo" and bool(context.get("source_mewtwo", false)):
            battle_theme = "pokemon_mansion_remix_eq"
        elif species == "volcarona":
            battle_theme = "bw_legendary_theme3"

func start_unown_music() -> void:
    # TrainerTipsTile: immediately restart the source looping Unown track.
    source_unown_active = true
    music_transition_generation += 1
    if music_fade != null and music_fade.is_valid(): music_fade.kill()
    for player in music_players: player.stop()
    route_intro_pending.clear()
    var stream := (_cached_music_stream("unown1") as AudioStreamOggVorbis).duplicate()
    stream.loop = true
    var player := music_players[active_music_player]
    player.stream = stream
    player.stream_paused = false
    AudioBalance.apply(player)
    player.play()
    current_track = "unown1"

func set_source_night_alert(track: String) -> void:
    source_night_alert = track
    if not battle_suspended:
        _refresh_context(false)

func play_victory_music() -> void:
    if source_unown_active: return
    if not battle_suspended:
        return
    for player in music_players:
        player.stream_paused = true
    battle_uses_route_music = false
    battle_intro = (_cached_music_stream("victory_fanfare1_intro") as AudioStreamOggVorbis).duplicate()
    battle_loop = (_cached_music_stream("victory_fanfare1") as AudioStreamOggVorbis).duplicate()
    battle_intro.loop = false
    battle_loop.loop = true
    battle_music.stream = battle_intro
    AudioBalance.apply(battle_music)
    battle_music.play()

func pause_music_for_evolution() -> Array[bool]:
    var states: Array[bool] = []
    for player in music_players + [battle_music]:
        states.append(player.stream_paused)
        player.stream_paused = true
    return states

func resume_music_after_evolution(states: Array[bool]) -> void:
    var players := music_players + [battle_music]
    for index in range(mini(states.size(), players.size())):
        players[index].stream_paused = states[index]

func _source_music_is_night() -> bool:
    var phase := phase_at_fraction(time_fraction())
    return phase == "night" or (phase == "dawn" and float(world.world_elapsed_seconds) >= _world_day_seconds())
