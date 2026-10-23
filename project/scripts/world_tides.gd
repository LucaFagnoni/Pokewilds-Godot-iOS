extends RefCounted

const World = preload("res://scripts/world.gd")
const SOURCE_PUDDLE_SPLASH := preload("res://assets/source_ui/puddle3.png")
const SOURCE_TIDAL_FRONT_SPLASH = preload("res://assets/source_exact/global/splash_anim4.png")
const SOURCE_TIDAL_WATER := preload("res://assets/source_0_8_11/tiles/water2.png")
const SourceWorldData = preload("res://scripts/source_world_data.gd")

var world: World

func _init(owner_world: World) -> void:
    world = owner_world

func _is_low_tide_time() -> bool:
    var fraction := fmod(world.world_elapsed_seconds, World.WORLD_DAY_SECONDS) / World.WORLD_DAY_SECONDS
    return (
        (fraction >= World.LOW_TIDE_START_1 and fraction < World.LOW_TIDE_END_1)
        or fraction >= World.LOW_TIDE_START_2
    )

func _tide_cell_adjoins_permanent_water(cell: Vector2i) -> bool:
    if world.exact_world == null:
        return false
    # Tide fronts advance from true shoreline contact. Diagonal-only contact
    # seeded isolated inland cells and produced the checkerboard/patchy look.
    var offsets: Array[Vector2i] = [
        Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN
    ]
    for offset in offsets:
        var neighbor: SourceTile = world.exact_world.tile_at(cell + offset)
        if neighbor == null:
            continue
        if neighbor.is_water and not world._is_beach_tidal_tile(neighbor):
            return true
    return false

func _nearest_native_ground_name(cell: Vector2i) -> String:
    if world.exact_world == null:
        return ""
    for radius in range(1, 6):
        for yy in range(cell.y - radius, cell.y + radius + 1):
            for xx in range(cell.x - radius, cell.x + radius + 1):
                if maxi(absi(xx - cell.x), absi(yy - cell.y)) != radius:
                    continue
                var candidate: SourceTile = world.exact_world.tile_at(Vector2i(xx, yy))
                if candidate == null or candidate.is_water or candidate.is_lava:
                    continue
                var candidate_name := candidate.name.to_lower()
                if "_tidalwater" in candidate_name or "_tidaloff" in candidate_name:
                    continue
                if candidate.is_solid or candidate.is_ledge or candidate.name.is_empty():
                    continue
                return candidate.name
    return ""

func _redraw_exact_tide_streams(changed_cells: Array = []) -> void:
    # Tide changes alter visual/source identities, not the player's collision
    # window. Queue one redraw for the current frame instead of force-rebuilding
    # both streamed layers and hundreds of collision shapes for every tide band.
    if changed_cells.is_empty():
        changed_cells = []
        # The start of a tide rewrites a few hundred shore cells at once.
        # Redrawing them all (and their neighbours) in one frame was a 60 ms
        # hitch: send them through the tide queue, nearest first.
        for key in SourceTile.resident_changed_cells:
            if world.exact_world.tiles.has(key): changed_cells.append(Vector2i(key / World.TILE))
        if changed_cells.is_empty(): return
    for node_path in [
            "GroundLayer/ExactBaseTileStream",
            "DecorLayer/ExactUpperTileStream"]:
        var stream := world.get_node_or_null(node_path)
        if stream != null:
            if changed_cells.is_empty(): stream.invalidate_tiles()
            else: stream.queue_tide_refresh(changed_cells)
    for cell in changed_cells:
        SourceTile.resident_changed_cells.erase(cell*World.TILE)
    # Beach tidal suffixes change shallow-water visuals, not solid/water
    # collision flags. Keep the already resident collision cells untouched.
    if is_instance_valid(world.reflection_layer):
        world.reflection_layer.queue_redraw()

## spread: the first build takes three frames (a load's: ~9, 14 and 21 ms here).
func _build_tide_transition_bands(lowering: bool, spread := false) -> Array:
    if not world.tide_topology_bands.is_empty():
        # Retain the cached cell lists. Resolve and validate cells as each small
        # portion changes, rather than rescanning every beach on one frame.
        var ordered: Array = []
        for i in range(world.tide_topology_bands.size()):
            var at := world.tide_topology_bands.size()-1-i if lowering else i
            if not world.tide_topology_bands[at].is_empty(): ordered.append(world.tide_topology_bands[at])
        return ordered

    # The first build reads the tile store's arrays: a proxy and dictionaries
    # keyed by cell for every tidal cell made this one step ~280 ms of a load.
    var store: WorldTileStore = world.exact_world.tiles
    var width := store.width
    # Per store index: 1 beach tide cell, 2 joined to its component, 3 with a
    # distance from the ocean.
    var state := PackedByteArray()
    state.resize(store.flags.size())
    var beach_cells := PackedInt32Array()
    var changing := {}
    var restored_non_beach_tide := false
    var restored_ground_cells: Array[Vector2i] = []
    var names := store.name_ids
    var biomes := store.biome_ids
    var routes := store.route_ids
    var flags := store.flags
    # _is_beach_tidal_tile reads only these four fields: settled once per kind.
    var beach_kinds := {}
    for index: int in store.with_name_containing("_tidal"):
        var kind := Vector4i(names[index], biomes[index], routes[index], flags[index] & WorldTileStore.WATER)
        if not beach_kinds.has(kind): beach_kinds[kind] = world._is_beach_tidal_tile(store.cursor(index))
        if beach_kinds[kind]:
            state[index] = 1
            beach_cells.append(index)
            var tile_name := store.strings[names[index]]
            if (lowering and "_tidalwater" in tile_name) or (not lowering and "_tidaloff" in tile_name):
                changing[index] = true
            continue
        # *_tidaloff is runtime-only; the 0.8.11 generator emits water-state
        # tidal identities. Older port builds could incorrectly include untagged
        # cells in the ocean tide. sand4_tidal* is specifically the generated
        # ocean-beach family, so an untagged/non-beach sand4 cell is contamination
        # and must become the nearby native ground (this removes the pale inland
        # squares). sand3_tidal* is also used by legitimate mountain/wooded-lake
        # shore systems, so a stale dry sand3 cell is restored to water instead.
        var tile_name_lower := store.strings[names[index]].to_lower()
        var cell := Vector2i(index % width, index / width) + store.origin
        if "sand4_tidal" in tile_name_lower:
            var native_ground := _nearest_native_ground_name(cell)
            if not native_ground.is_empty():
                var tile := store.proxy(index)
                tile.set_names(native_ground, tile.name_upper)
                restored_ground_cells.append(cell)
                restored_non_beach_tide = true
            continue
        if "_tidaloff" in tile_name_lower:
            var tile := store.proxy(index)
            tile.set_names(tile.name.replace("_tidaloff", "_tidalwater"), tile.name_upper)
            restored_non_beach_tide = true
    if not restored_ground_cells.is_empty():
        world._recoastify_exact_cells(restored_ground_cells)
    if restored_non_beach_tide:
        _redraw_exact_tide_streams()
    if spread: await world.get_tree().process_frame

    # The source footage shows every tidal beach beginning its transition at
    # the same time, while each individual beach still advances as a coherent
    # shoreline. Build connected tidal components, normalize each component's
    # ocean distance into the same set of phases, then merge equal phases.
    # This prevents a distant beach with a larger inland depth from delaying
    # the water movement around the player.
    # Connected beach water must stay edge-connected while the tide moves.
    # Cardinal propagation prevents diagonal checkerboard islands.
    var phase_bands: Array = []
    var topology_bands: Array = []
    for _phase_index in range(World.TIDE_TRANSITION_STEPS):
        phase_bands.append([])
        topology_bands.append([])
    var cleanup_cells: Array[Vector2i] = []
    # The store as the cleanup above left it.
    names = store.name_ids
    biomes = store.biome_ids
    routes = store.route_ids
    flags = store.flags
    var last := flags.size() - 1
    var distances := PackedInt32Array()
    distances.resize(flags.size())

    for start_index: int in beach_cells:
        if state[start_index] != 1:
            continue
        # Cells join in the order left, right, up, down, as they always did:
        # band order follows it.
        var component := PackedInt32Array([start_index])
        state[start_index] = 2
        var component_at := 0
        while component_at < component.size():
            var index := component[component_at]
            component_at += 1
            var x := index % width
            if x > 0 and state[index - 1] == 1:
                state[index - 1] = 2
                component.append(index - 1)
            if x < width - 1 and state[index + 1] == 1:
                state[index + 1] = 2
                component.append(index + 1)
            if index >= width and state[index - width] == 1:
                state[index - width] = 2
                component.append(index - width)
            if index + width <= last and state[index + width] == 1:
                state[index + width] = 2
                component.append(index + width)

        # Tide fronts advance from true shoreline contact: a cardinal
        # neighbour that is water but not beach tide
        # (_tide_cell_adjoins_permanent_water, which border cells still use).
        var distance_queue := PackedInt32Array()
        for index: int in component:
            var x := index % width
            var adjoins := false
            if x == 0 or x == width - 1 or index < width or index + width > last:
                adjoins = _tide_cell_adjoins_permanent_water(Vector2i(x, index / width) + store.origin)
            else:
                for neighbor: int in [index - 1, index + 1, index - width, index + width]:
                    if flags[neighbor] & (WorldTileStore.PRESENT | WorldTileStore.WATER) != (WorldTileStore.PRESENT | WorldTileStore.WATER):
                        continue
                    var kind := Vector4i(names[neighbor], biomes[neighbor], routes[neighbor], WorldTileStore.WATER)
                    if not beach_kinds.has(kind): beach_kinds[kind] = world._is_beach_tidal_tile(store.cursor(neighbor))
                    if not beach_kinds[kind]:
                        adjoins = true
                        break
            if adjoins:
                state[index] = 3
                distances[index] = 0
                distance_queue.append(index)
        if distance_queue.is_empty():
            # A tidal beach must be cardinally connected to permanent source
            # water. A stale disconnected *_tidaloff cell is still rendered as
            # pale beach sand, which produced the white checkerboard patches seen
            # inland. Remove the entire orphan tidal component by restoring a
            # nearby native non-tidal ground identity instead of merely drying it.
            for index: int in component:
                var component_cell := Vector2i(index % width, index / width) + store.origin
                var native_ground := _nearest_native_ground_name(component_cell)
                if native_ground.is_empty():
                    continue
                var orphan_tile := store.proxy(index)
                orphan_tile.set_names(native_ground, orphan_tile.name_upper)
                cleanup_cells.append(component_cell)
            continue

        var distance_index: int = 0
        var max_distance: int = 0
        while distance_index < distance_queue.size():
            var index := distance_queue[distance_index]
            distance_index += 1
            var next_distance: int = distances[index] + 1
            var x := index % width
            for neighbor: int in [index - 1 if x > 0 else -1, index + 1 if x < width - 1 else -1, index - width, index + width]:
                if neighbor < 0 or neighbor > last or state[neighbor] != 2:
                    continue
                state[neighbor] = 3
                distances[neighbor] = next_distance
                max_distance = maxi(max_distance, next_distance)
                distance_queue.append(neighbor)

        for index: int in component:
            var normalized: float = (
                0.0 if max_distance <= 0
                else float(distances[index]) / float(max_distance)
            )
            var incoming_band_index: int = clampi(
                roundi(normalized * float(World.TIDE_TRANSITION_STEPS - 1)),
                0, World.TIDE_TRANSITION_STEPS - 1
            )
            var component_cell := Vector2i(index % width, index / width) + store.origin
            (topology_bands[incoming_band_index] as Array).append(component_cell)
            if not changing.has(index):
                continue
            var band_index := (
                World.TIDE_TRANSITION_STEPS - 1 - incoming_band_index
                if lowering else incoming_band_index
            )
            # Cells: _apply_tide_band resolves each as it changes.
            (phase_bands[band_index] as Array).append(component_cell)

    if spread: await world.get_tree().process_frame
    if not cleanup_cells.is_empty():
        world._recoastify_exact_cells(cleanup_cells)
        _redraw_exact_tide_streams()
    world.tide_topology_bands = topology_bands
    var bands: Array = []
    for raw_band in phase_bands:
        var band: Array = raw_band as Array
        if not band.is_empty():
            bands.append(band)
    return bands

func _apply_tide_band(band: Array, lowering: bool) -> Array[Vector2i]:
    var changed_cells: Array[Vector2i] = []
    for raw_tile in band:
        var tile: SourceTile = world.exact_world.tile_at(raw_tile) if raw_tile is Vector2i else raw_tile as SourceTile
        if tile == null or not world._is_beach_tidal_tile(tile):
            continue
        var next_name: String = tile.name
        if lowering and "_tidalwater" in next_name:
            next_name = next_name.replace("_tidalwater", "_tidaloff")
        elif not lowering and "_tidaloff" in next_name:
            next_name = next_name.replace("_tidaloff", "_tidalwater")
        else:
            continue
        tile.set_names(next_name, tile.name_upper)
        changed_cells.append(SourceWorldData.pixel_to_cell(tile.position))
    if not changed_cells.is_empty():
        # The suffix swap changes only tidal surface state. Shoreline activity is
        # derived live from neighboring cells, so rebuilding 3x3 coast metadata
        # for every transition band is redundant and caused the tide hitch.
        _redraw_exact_tide_streams(changed_cells)
    return changed_cells

## per-frame
func update_tide_state(force: bool = false, delta: float = 0.0, spread := false) -> void:
    if world.exact_world == null:
        world.tide_initialized = true
        world.low_tide_active = false
        if is_instance_valid(world.tide_wade_base):
            world.tide_wade_base.visible = false
        if is_instance_valid(world.tide_wade_ripple):
            world.tide_wade_ripple.visible = false
        return
    var desired_low_tide: bool = _is_low_tide_time()
    var frontier_seconds := World.TIDE_RETREAT_FRONTIER_SECONDS if desired_low_tide else World.TIDE_FRONTIER_SECONDS
    var was_initialized: bool = world.tide_initialized
    if force or not world.tide_initialized or desired_low_tide != world.tide_target_low:
        world.tide_target_low = desired_low_tide
        world.tide_transition_bands = await _build_tide_transition_bands(desired_low_tide, spread)
        world.tide_transition_band_index = 0
        world.tide_band_cursor = 0
        world.tide_transition_accumulator = frontier_seconds if force else 0.0
    world.low_tide_active = desired_low_tide
    world.tide_initialized = true
    if world.tide_transition_band_index >= world.tide_transition_bands.size():
        return

    world.tide_transition_accumulator += delta
    if not force and world.tide_band_cursor == 0 and world.tide_transition_accumulator < frontier_seconds:
        return

    var first_changed_band: bool = world.tide_transition_band_index == 0
    if force:
        while world.tide_transition_band_index < world.tide_transition_bands.size():
            _apply_tide_band(
                world.tide_transition_bands[world.tide_transition_band_index] as Array,
                desired_low_tide
            )
            world.tide_transition_band_index += 1
        world.tide_transition_accumulator = 0.0
    else:
        if world.tide_band_cursor == 0:
            world.tide_transition_accumulator = maxf(0.0,world.tide_transition_accumulator-frontier_seconds)
        var band: Array = world.tide_transition_bands[world.tide_transition_band_index]
        var deadline := Time.get_ticks_usec()+1200
        while world.tide_band_cursor < band.size():
            var end := mini(world.tide_band_cursor+24,band.size())
            _apply_tide_band(band.slice(world.tide_band_cursor,end),desired_low_tide)
            world.tide_band_cursor=end
            if Time.get_ticks_usec()>=deadline: break
        if world.tide_band_cursor>=band.size():
            world.tide_band_cursor=0
            world.tide_transition_band_index+=1

    if world.gameplay_enabled and not world.restoring_saved_tiles and world.is_visible_in_tree() and bool(world.get_parent().get("started")) and not bool(world.get_parent().get("generating")) and first_changed_band and was_initialized and not force and \
            world.world_elapsed_seconds - world.last_tide_message_seconds >= \
            World.TIDE_MESSAGE_COOLDOWN_SECONDS:
        world.last_tide_message_seconds = world.world_elapsed_seconds
        world.world_message.emit(
            "The tide is receding." if desired_low_tide
            else "The tide is coming in."
        )

## per-frame
func update_tidal_wade_visual() -> void:
    var show_wade = false
    var tile = null
    if world.active_area_id == "OVERWORLD" and world.exact_world != null:
        if world.active_field_move not in ["FLY", "SURF"]:
            # A walking sprite overlaps more than one tile at an edge. Keep
            # the wade visible while its lower edge still touches tide water.
            for foot_x in [-6.0, 0.0, 6.0]:
                var foot_cell := Vector2i(
                    floori((world.player.position.x + foot_x) / World.TILE),
                    floori((world.player.position.y + 6.0) / World.TILE))
                # Name test first, from the store: three tile objects a frame
                # on dry land otherwise, only to find no tide water.
                var foot_names := world._exact_names_at(foot_cell)
                if foot_names.is_empty() or not foot_names[0].to_lower().contains("_tidalwater"):
                    continue
                var foot_tile: SourceTile = world._frame_tile(foot_cell)
                if foot_tile != null and world._is_beach_tidal_tile(foot_tile) and \
                        foot_tile.name.to_lower().contains("_tidalwater"):
                    tile = foot_tile
                    show_wade = true
                    break
    if not show_wade:
        world.tidal_front_splash_phase_known = false
        if is_instance_valid(world.tide_wade_base):
            world.tide_wade_base.visible = false
        if is_instance_valid(world.tide_wade_ripple):
            world.tide_wade_ripple.visible = false
        return

    # The foreground must match the pale composite tide surface behind the
    # actor. Water2 alone painted a dark purple bar over the lower body.
    if not is_instance_valid(world.tide_wade_base):
        world.tide_wade_base = Sprite2D.new()
        world.tide_wade_base.name = "TideWadeGround"
        world.tide_wade_base.centered = false
        world.tide_wade_base.region_enabled = true
        world.tide_wade_base.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
        world.tide_wade_base.z_as_relative = false
        world.add_child(world.tide_wade_base)
    if not is_instance_valid(world.tide_wade_ripple):
        world.tide_wade_ripple = Sprite2D.new()
        world.tide_wade_ripple.name = "TideWadeWater"
        world.tide_wade_ripple.centered = false
        world.tide_wade_ripple.region_enabled = true
        world.tide_wade_ripple.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
        world.tide_wade_ripple.z_as_relative = false
        world.add_child(world.tide_wade_ripple)

    var base_stream = world.get_node_or_null("GroundLayer/ExactBaseTileStream")
    var animation_tick = int(floor(world.world_elapsed_seconds * 60.0))
    if base_stream != null:
        animation_tick = int(base_stream.get("source_animation_tick"))
    # In the recording the surface crosses the lower four sprite pixels.
    # Position it from the pixel-locked sprite, never from the tile origin.
    const WADE_FRONT_HEIGHT = 4
    var wade_source_y = World.TILE - WADE_FRONT_HEIGHT
    var tide_frame = posmod(int(animation_tick / 19), 2)
    var ground_spec: Dictionary = SourceWorldData.render_spec(
        tile, false, 0, animation_tick)
    var ground_texture := ground_spec.get("texture") as Texture2D
    var ground_region: Rect2 = ground_spec.get(
        "region", Rect2(0, 0, World.TILE, World.TILE))
    var sprite_center: Vector2 = world.to_local(world.player.sprite.global_position.round())
    var wade_position := sprite_center + Vector2(-World.TILE * 0.5, World.TILE * 0.5 - WADE_FRONT_HEIGHT)
    if ground_texture != null:
        world.tide_wade_base.texture = ground_texture
        world.tide_wade_base.region_rect = Rect2(
            ground_region.position.x,
            ground_region.position.y + wade_source_y,
            World.TILE, WADE_FRONT_HEIGHT)
        world.tide_wade_base.position = wade_position
        world.tide_wade_base.modulate = Color(1, 1, 1, 0.75)
        world.tide_wade_base.z_index = world.player.z_index + 4
        world.tide_wade_base.visible = true
    else:
        world.tide_wade_base.visible = false
    world.tide_wade_ripple.texture = SOURCE_TIDAL_WATER
    world.tide_wade_ripple.region_rect = Rect2(
        tide_frame * World.TILE, wade_source_y, World.TILE, WADE_FRONT_HEIGHT)
    world.tide_wade_ripple.position = wade_position
    world.tide_wade_ripple.modulate = Color(1, 1, 1, 0.50)
    world.tide_wade_ripple.z_index = world.player.z_index + 5
    world.tide_wade_ripple.visible = true
    world.player.visible = true

func _spawn_tidal_front_splash(high_tide: bool = true) -> void:
    # The source has a separate three-frame splash_anim4 effect. puddle3 is
    # the oval ground ripple and is intentionally kept on its existing path.
    if world.tidal_front_splash_frames == null:
        world.tidal_front_splash_frames = SpriteFrames.new()
        world.tidal_front_splash_frames.add_animation("splash")
        world.tidal_front_splash_frames.set_animation_loop("splash", false)
        world.tidal_front_splash_frames.set_animation_speed("splash", 60.0)
        for frame_index in range(3):
            var frame := AtlasTexture.new()
            frame.atlas = SOURCE_TIDAL_FRONT_SPLASH
            frame.region = Rect2(frame_index * World.TILE, 0, World.TILE, World.TILE)
            world.tidal_front_splash_frames.add_frame("splash", frame, [4.0, 1.0, 5.0][frame_index])
    var splash := AnimatedSprite2D.new()
    splash.name = "TidalFrontSplash"
    splash.sprite_frames = world.tidal_front_splash_frames
    splash.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
    splash.z_as_relative = true
    splash.z_index = 7
    # Java player art is at y+4; WaterSplash is at y+3 (+4 in tides).
    # Convert the difference to Godot's downward-positive screen coordinates.
    splash.position = Vector2(0.0, -3.0 if high_tide else 1.0)
    world.player.sprite.add_child(splash)
    splash.frame_changed.connect(_update_tidal_front_splash_frame.bind(splash))
    splash.animation_finished.connect(splash.queue_free)
    splash.play("splash")
    _update_tidal_front_splash_frame(splash)

func _update_tidal_front_splash_frame(splash: AnimatedSprite2D) -> void:
    splash.offset = Vector2.ZERO

func spawn_puddle_step_effect(cell: Vector2i) -> void:
    if world.active_field_move == "FLY":
        return
    if world.active_area_id != "OVERWORLD" or world.exact_world == null:
        return
    var tile = world.exact_world.tile_at(cell)
    if tile == null or world._source_biome_for_tile(tile) != "BEACH":
        return
    var high_tide = "_tidalwater" in tile.name.to_lower()
    var puddle_name = tile.name if "_puddle1" in tile.name else tile.name_upper
    if not high_tide:
        if "_puddle1" not in puddle_name or "_tidaloff" not in puddle_name:
            return
        # Low-tide puddle physics follows the same authored per-pixel water
        # mask as the locked reflection system. Stepping on the dry portion of
        # a puddle tile must not create a water splash.
        var local_feet = Vector2i(8, 10)
        if not SourceWorldData.puddle_reflects_at(puddle_name, local_feet):
            return

    var frames = SpriteFrames.new()
    frames.add_animation("splash")
    frames.set_animation_loop("splash", false)
    frames.set_animation_speed("splash", 60.0)
    for frame_index in range(3):
        var frame = AtlasTexture.new()
        frame.atlas = SOURCE_PUDDLE_SPLASH
        frame.region = Rect2(frame_index * World.TILE, 0, World.TILE, World.TILE)
        frames.add_frame("splash", frame, 13.0 if frame_index == 2 else 12.0)

    var splash = AnimatedSprite2D.new()
    splash.sprite_frames = frames
    splash.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
    splash.name = "PuddleStepSplash"
    splash.position = world.to_local(world.player.sprite.global_position.round()) + Vector2(0.0, 0.0 if high_tide else 4.0)
    splash.z_as_relative = false
    splash.z_index = world.player.z_index - 1
    if high_tide:
        _apply_tidal_puddle_surface(splash)
    world.add_child(splash)
    splash.animation_finished.connect(splash.queue_free)
    splash.play("splash")
    _spawn_tidal_front_splash(high_tide)

func _apply_tidal_puddle_surface(splash: AnimatedSprite2D) -> void:
    splash.material = tidal_puddle_material()
    world.tidal_puddle_splashes.append(splash)

func tidal_puddle_material() -> ShaderMaterial:
    if world.tidal_puddle_shader == null:
        world.tidal_puddle_shader = Shader.new()
        world.tidal_puddle_shader.code = """
shader_type canvas_item;
uniform sampler2D water_texture : filter_nearest, repeat_enable;
uniform int water_frame = 0;
varying vec2 world_pixel;
void vertex() { world_pixel = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy; }
void fragment() {
    vec4 ripple = texture(TEXTURE, UV);
    vec2 p = mod(floor(world_pixel), vec2(16.0));
    vec4 water = texture(water_texture, (p + vec2(float(water_frame) * 16.0, 0.0) + 0.5) / vec2(32.0, 16.0));
    COLOR = vec4(mix(ripple.rgb, water.rgb, water.a * 0.5), ripple.a);
}
"""
    var material := ShaderMaterial.new()
    material.shader = world.tidal_puddle_shader
    material.set_shader_parameter("water_texture", SOURCE_TIDAL_WATER)
    return material
