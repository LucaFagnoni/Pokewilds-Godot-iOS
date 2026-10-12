extends Node2D

# M74.3.5: keep this streaming renderer dynamically typed. Godot's analyzer was
# rejecting the previous renderer while resolving custom script classes even
# though its token/grammar parse succeeded. This file intentionally avoids
# class_name, custom-script type hints, and custom-script casts.

signal shore_frame_changed(frame)

const WORLD_DATA_PATH = "res://scripts/source_world_data.gd"
var _world_data_script = null
const DEFAULT_TILE_SIZE = 16
const REDRAW_MARGIN_CELLS = 4
const STREAM_SHIFT_CELLS = 3
const SHORE_FRAME_TIME = 16.0 / 60.0
const SHORE_FRAME_SEQUENCE = [1, 2, 3, 4, 5, 6, 0, 0]
const FLOWER_FRAME_TIME = 26.0 / 60.0
const SOURCE_ANIMATION_STEP = 3
const SOURCE_ANIMATION_FRAME_TIME = SOURCE_ANIMATION_STEP / 60.0

var source_tiles = {}
var open_gate_cells: Dictionary = {}
var tracked_player = null
var tile_size = DEFAULT_TILE_SIZE
var draw_upper = false
var source_keys_are_pixels = false
var last_view_cell = Vector2i(2147483647, 2147483647)
var visible_cell_rect = Rect2i()
var shore_animation_time = 0.0
var shore_animation_frame = 0
var shore_animation_step = -1
var flower_animation_time = 0.0
var flower_animation_frame = 0
var source_animation_time = 0.0
var source_animation_tick = 0
var source_animation_signature = 0
var last_viewport_size = Vector2.ZERO
var last_zoom = Vector2.ZERO

# Rendering the streamed overworld can redraw hundreds of tiles at once when
# the player crosses a stream boundary or an authored animation advances. Most
# of those tiles share the exact same source identity. Cache the resolved render
# recipe by source identity so those redraws reuse the texture/region recipe
# instead of rebuilding it for every cell. The cache key includes every visual
# input (base, upper, colour, layer and only the animation state needed by
# animated assets), so this changes no rendered result or world state.
var render_spec_cache: Dictionary = {}
var frame_tidal_cells: Dictionary = {}
var shore_recipe_cache: Dictionary = {}
var drawing_tidal_shores := false
var visible_recipes_dirty := true
var visible_recipes: Array = []
var visible_shores: Array = []
var animated_recipe_groups: Array = []
var cell_recipe_cache: Dictionary = {}
var recipe_groups: Dictionary = {}
var visible_tidal_overlay := false

const RENDER_SPEC_CACHE_LIMIT = 4096


func configure(tiles, player_node, upper_layer, source_tile_size = DEFAULT_TILE_SIZE, pixel_keys = false):
    cell_recipe_cache.clear()
    recipe_groups.clear()
    source_tiles = tiles
    tracked_player = player_node
    draw_upper = upper_layer
    tile_size = int(source_tile_size)
    source_keys_are_pixels = bool(pixel_keys)
    source_animation_signature = _animation_signature(source_animation_tick)
    texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
    _refresh_visible_rect(true)


func _process(delta):
    var previous_water_phase = posmod(int(source_animation_tick) / 19, 6)
    source_animation_time += delta
    if source_animation_time >= SOURCE_ANIMATION_FRAME_TIME:
        source_animation_time = fmod(source_animation_time, SOURCE_ANIMATION_FRAME_TIME)
        source_animation_tick = posmod(source_animation_tick + SOURCE_ANIMATION_STEP, 4560)
        source_animation_signature = _animation_signature(source_animation_tick)
    if draw_upper:
        shore_animation_time += delta
        while shore_animation_time >= SHORE_FRAME_TIME:
            shore_animation_time -= SHORE_FRAME_TIME
            shore_animation_step = (shore_animation_step + 1) % SHORE_FRAME_SEQUENCE.size()
            shore_animation_frame = int(SHORE_FRAME_SEQUENCE[shore_animation_step])
            shore_frame_changed.emit(shore_animation_frame)
            if not visible_shores.is_empty(): queue_redraw()
    else:
        flower_animation_time += delta
        if flower_animation_time >= FLOWER_FRAME_TIME:
            flower_animation_time -= FLOWER_FRAME_TIME
            flower_animation_frame = (flower_animation_frame + 1) % 2
    # Retain static canvas commands. Only redraw when artwork present in this
    # viewport actually changes, rather than on unrelated lava/water clocks.
    for group in animated_recipe_groups:
        var next_spec = _cached_render_spec(group[0])
        if next_spec != group[1]:
            group[1] = next_spec
            queue_redraw()
    if visible_tidal_overlay and previous_water_phase != posmod(int(source_animation_tick) / 19, 6):
        queue_redraw()
    _refresh_visible_rect(false)


func invalidate_tiles():
    cell_recipe_cache.clear()
    recipe_groups.clear()
    visible_recipes_dirty = true
    queue_redraw()

func refresh_now():
    cell_recipe_cache.clear()
    recipe_groups.clear()
    visible_recipes_dirty = true
    _refresh_visible_rect(true)


func _refresh_visible_rect(force):
    if tracked_player == null or not is_instance_valid(tracked_player):
        return

    var view_cell = Vector2i(
        floori(tracked_player.global_position.x / float(tile_size)),
        floori(tracked_player.global_position.y / float(tile_size))
    )
    var viewport_size = get_viewport_rect().size
    var camera = get_viewport().get_camera_2d()
    var zoom = Vector2.ONE
    if camera != null:
        zoom = camera.zoom

    var view_changed = viewport_size != last_viewport_size or zoom != last_zoom
    if not force and not view_changed:
        if absi(view_cell.x - last_view_cell.x) < STREAM_SHIFT_CELLS:
            if absi(view_cell.y - last_view_cell.y) < STREAM_SHIFT_CELLS:
                return

    visible_recipes_dirty = true
    last_view_cell = view_cell
    last_viewport_size = viewport_size
    last_zoom = zoom

    var half_cells = Vector2i(
        ceili(viewport_size.x / maxf(zoom.x, 0.01) / float(tile_size) / 2.0),
        ceili(viewport_size.y / maxf(zoom.y, 0.01) / float(tile_size) / 2.0)
    ) + Vector2i.ONE * REDRAW_MARGIN_CELLS

    visible_cell_rect = Rect2i(
        view_cell - half_cells,
        half_cells * 2 + Vector2i.ONE
    )
    queue_redraw()


func _animation_signature(tick):
    var water_phase = posmod(int(tick) / 19, 6)
    var lava_phase = posmod(int(tick) / 20, 4)
    var lava_subframe = 0 if posmod(int(tick), 20) < 3 else 1
    var fall_phase = 1 if posmod(int(tick), 40) >= 19 else 0
    var fire_phase = 1 if posmod(int(tick), 80) >= 40 else 0
    return (
        water_phase
        | (lava_phase << 3)
        | (lava_subframe << 5)
        | (fall_phase << 6)
        | (fire_phase << 7)
    )


func _cached_render_spec(raw_tile):
    var base_name = str(raw_tile.get("name", raw_tile.get("base", ""))) if raw_tile is Dictionary else raw_tile.name
    var upper_name = str(raw_tile.get("name_upper", raw_tile.get("upper", ""))) if raw_tile is Dictionary else raw_tile.name_upper
    var use_color = bool(raw_tile.get("color", false)) if raw_tile is Dictionary else raw_tile.color
    var identity = (upper_name if draw_upper else base_name).to_lower()

    # Only authored animated source tiles need an animation-dependent cache key.
    # Static terrain/object recipes persist across animation ticks and are the
    # overwhelming majority of a running viewport.
    var animation_key = 0
    if (
            identity.begins_with("water")
            or identity.begins_with("lava")
            or identity.begins_with("waterfall")
            or identity.begins_with("lavafall")
            or identity == "campfire1"
            or identity == "torch1"
        ):
        animation_key = source_animation_signature + 1
    elif identity.begins_with("flower"):
        animation_key = 1000 + flower_animation_frame

    var cache_key = "%d|%s|%s|%d|%d" % [
        1 if draw_upper else 0,
        base_name,
        upper_name,
        1 if use_color else 0,
        animation_key
    ]
    if render_spec_cache.has(cache_key):
        return render_spec_cache[cache_key]

    var spec = _world_data().render_spec(
        raw_tile,
        draw_upper,
        flower_animation_frame,
        source_animation_tick
    )
    # Bound the cache so a very long session that sees many mutated source
    # identities cannot grow it indefinitely. Clearing affects performance only;
    # the next draw simply rebuilds the same deterministic recipes.
    if render_spec_cache.size() >= RENDER_SPEC_CACHE_LIMIT:
        render_spec_cache.clear()
    render_spec_cache[cache_key] = spec
    return spec


func _rebuild_visible_recipes():
    visible_recipes_dirty = false
    visible_recipes.clear()
    visible_tidal_overlay = false
    visible_shores.clear()
    animated_recipe_groups.clear()
    # Retain the overlapping viewport when walking. Resolve only newly exposed
    # cells; terrain edits explicitly invalidate both caches before redraw.
    var retained = {}
    var active_groups = {}
    drawing_tidal_shores = false
    for y in range(visible_cell_rect.position.y, visible_cell_rect.end.y):
        for x in range(visible_cell_rect.position.x, visible_cell_rect.end.x):
            var cell = Vector2i(x, y)
            var cached = cell_recipe_cache.get(cell)
            if cached == null:
                var tile = source_tiles.get(cell * tile_size if source_keys_are_pixels else cell)
                if tile == null: continue
                var shores = []
                if draw_upper:
                    var ocean = str(_field(tile, "shore_ocean", ""))
                    var tidal = _active_beach_tidal_shore(cell, tile)
                    if not ocean.is_empty(): shores.append([cell, ocean, Color.WHITE])
                    if not tidal.is_empty(): shores.append([cell, tidal, Color(1, 1, 1, 0.50)])
                var base = str(tile.get("name", tile.get("base", ""))) if tile is Dictionary else tile.name
                var upper = str(tile.get("name_upper", tile.get("upper", ""))) if tile is Dictionary else tile.name_upper
                var identity = (upper if draw_upper else base).to_lower()
                var key = str([base, upper, bool(_field(tile, "color", false))])
                if not recipe_groups.has(key):
                    var animated = identity.begins_with("water") or identity.begins_with("lava") or identity.begins_with("flower") or identity in ["campfire1", "torch1"]
                    recipe_groups[key] = [tile, _cached_render_spec(tile), animated]
                var group = recipe_groups[key]
                var tidal = not draw_upper and _is_beach_high_tide(tile)
                var reward = draw_upper and upper.begins_with("hole1") and not str(_field(tile, "has_item", "")).is_empty()
                var front = draw_upper and not group[1].is_empty() and _mountain_tree_needs_front_redraw(cell, tile, group[1])
                cached = [[cell, group, "gate" in identity, tidal, front, reward], shores, key]
            retained[cell] = cached
            var record = cached[0]
            visible_tidal_overlay = visible_tidal_overlay or record[3]
            var group = record[1]
            active_groups[cached[2]] = group
            if not group[1].is_empty() or record[5]: visible_recipes.append(record)
            visible_shores.append_array(cached[1])
    cell_recipe_cache = retained
    recipe_groups = active_groups
    for group in active_groups.values():
        if group[2]: animated_recipe_groups.append(group)

func _draw():
    if source_tiles.is_empty(): return
    if visible_recipes_dirty: _rebuild_visible_recipes()
    # Resolve each animated source identity once, not once per visible tile.
    for group in animated_recipe_groups:
        group[1] = _cached_render_spec(group[0])
    for shore in visible_shores:
        _draw_shoreline(shore[0], shore[1], shore[2])
    var mountain_tree_redraws = []
    var tide_spec = {
        "texture": _world_data().texture_for("water2"),
        "region": Rect2(posmod(int(source_animation_tick / 19), 2) * tile_size, 0, 16, 16),
        "size": Vector2(16, 16), "offset": Vector2.ZERO
    }
    var reward_spec = {
        "texture": _world_data().texture_for("pokeball1"),
        "region": Rect2(0, 0, 16, 16), "size": Vector2(16, 16), "offset": Vector2.ZERO
    }
    for record in visible_recipes:
        var cell = record[0]
        if record[2] and open_gate_cells.has(cell): continue
        var spec = record[1][1]
        if not spec.is_empty():
            _draw_render_spec(cell, spec, Color.WHITE)
            if record[3]: _draw_render_spec(cell, tide_spec, Color(1, 1, 1, 0.50))
            if record[4]: mountain_tree_redraws.append([cell, spec])
        if record[5]: _draw_render_spec(cell, reward_spec, Color.WHITE)
    for redraw in mountain_tree_redraws:
        _draw_render_spec(redraw[0], redraw[1], Color.WHITE)


func _draw_render_spec(cell, spec, modulate = Color.WHITE):
    if spec == null or spec.is_empty():
        return
    var texture = spec.get("texture")
    if texture == null:
        return
    var source_region = spec.get(
        "region",
        Rect2(Vector2.ZERO, Vector2(tile_size, tile_size))
    )
    var draw_offset = spec.get("offset", Vector2.ZERO)
    var draw_size = spec.get("size", source_region.size)
    draw_texture_rect_region(
        texture,
        Rect2(Vector2(cell * tile_size) + draw_offset, draw_size),
        source_region,
        modulate
    )


func _mountain_tree_needs_front_redraw(cell, tile, spec):
    var key = (str(_field(tile, "name", "")) + " " + str(_field(tile, "name_upper", ""))).to_lower()
    var size = spec.get("size", Vector2.ZERO)
    if "tree" not in key or size.y <= float(tile_size):
        return false

    var directions = [
        Vector2i.ZERO,
        Vector2i.UP,
        Vector2i.DOWN,
        Vector2i.LEFT,
        Vector2i.RIGHT
    ]
    for direction in directions:
        var lookup_cell = cell + direction
        var lookup_key = lookup_cell
        if source_keys_are_pixels:
            lookup_key = lookup_cell * tile_size
        var nearby = source_tiles.get(lookup_key)
        if nearby == null:
            continue
        var nearby_key = (
            str(_field(nearby, "name", ""))
            + " "
            + str(_field(nearby, "name_upper", ""))
        ).to_lower()
        if "mountain" in nearby_key or "ledges3" in nearby_key:
            return true
    return false


func _draw_shoreline(cell, shore_type, modulate):
    if shore_type == null or str(shore_type).is_empty():
        return
    var recipe_key = "%s|%d" % [shore_type, shore_animation_frame]
    if not shore_recipe_cache.has(recipe_key):
        if shore_recipe_cache.size() >= 1024:
            shore_recipe_cache.clear()
        shore_recipe_cache[recipe_key] = _world_data().shoreline_quads(str(shore_type), shore_animation_frame)
    var quads = shore_recipe_cache[recipe_key]
    for quad in quads:
        var texture = quad.get("texture")
        if texture == null:
            continue
        var offset = quad.get("offset", Vector2.ZERO)
        var source_rect = quad.get("source", Rect2())
        draw_texture_rect_region(
            texture,
            Rect2(Vector2(cell * tile_size) + offset, Vector2(8, 8)),
            source_rect,
            modulate
        )


func _is_beach_high_tide(tile):
    var tile_name = str(tile.get("name", "")) if tile is Dictionary else tile.name
    tile_name = tile_name.to_lower()
    if "_tidalwater" not in tile_name:
        return false
    var biome = str(_field(tile, "biome", "")).strip_edges().to_upper().replace("-", "_")
    var route = _field(tile, "route_belongs_to", null)
    var route_name = "" if route == null else str(_field(route, "name", "")).to_lower()
    # Ocean tide belongs only to the authored beach families.  Other source
    # systems also use *_tidalwater (mountain bottoms / wooded-lake shores);
    # treating an untagged suffix as beach tide is what produced the inland
    # pale squares and overextended tide patches.
    return biome in ["BEACH", "BEACH_BLACKSAND"] or route_name.begins_with("beach")

func _is_authored_beach_surface(tile):
    if tile == null:
        return false
    var biome = str(_field(tile, "biome", "")).strip_edges().to_upper().replace("-", "_")
    var route = _field(tile, "route_belongs_to", null)
    var route_name = "" if route == null else str(_field(route, "name", "")).to_lower()
    return biome in ["BEACH", "BEACH_BLACKSAND"] or route_name.begins_with("beach")


func _active_beach_tidal_shore(cell: Vector2i, tile) -> String:
    # Read the live water state. The authored shore_tidal value was calculated
    # before the tide moved, so using it after a transition left square patches.
    if tile == null or bool(_field(tile, "is_water", false)) or \
            _is_beach_high_tide(tile):
        return ""
    var names := ["W", "E", "S", "N", "SW", "NE", "SE", "NW"]
    var offsets := [
        Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN,
        Vector2i(-1, -1), Vector2i(1, 1),
        Vector2i(1, -1), Vector2i(-1, 1)
    ]
    var shore := ""
    for index in range(offsets.size()):
        var neighbor_cell: Vector2i = cell + Vector2i(offsets[index])
        var lookup: Vector2i = neighbor_cell * tile_size if source_keys_are_pixels else neighbor_cell
        if drawing_tidal_shores:
            if not frame_tidal_cells.has(neighbor_cell):
                continue
        else:
            var neighbor = source_tiles.get(lookup)
            if neighbor == null or not _is_beach_high_tide(neighbor):
                continue
        var direction := String(names[index])
        if direction.length() == 2 and ("[" + direction[0] + "]") in shore:
            continue
        if direction.length() == 2 and ("[" + direction[1] + "]") in shore:
            continue
        shore += "[" + direction + "]"
    return shore


func _world_data():
    if _world_data_script == null:
        _world_data_script = load(WORLD_DATA_PATH)
    return _world_data_script


func _field(value, key, default_value):
    if typeof(value) == TYPE_DICTIONARY:
        return value.get(key, default_value)
    if typeof(value) == TYPE_OBJECT and value != null:
        var result = value.get(key)
        if result != null:
            return result
    return default_value
