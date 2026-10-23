extends RefCounted

## The field's minimap (top-left compass with the DIG boxes beside it) and the
## full MAP screen of the game menu, with the teleport destination picker.
## Split out of main.gd; reaches the game through `main`.

const HudStyle = preload("res://scripts/hud_style.gd")
const GameOptions = preload("res://scripts/game_options.gd")
const TexturePixels = preload("res://scripts/texture_pixels.gd")
const MINIMAP_MAP_OFFSET := Vector2.ZERO
const MINIMAP_MAP_SIZE := Vector2i(64, 64)
const MAP_SLEEPING_BAG_TEXTURE := preload("res://assets/source_ui/sleeping_bag1.png")
# Idle refresh period. (At 0.0 the 20 Hz moving throttle below never applied
# and the minimap was re-rasterised every frame.)
const MINIMAP_REFRESH_SECONDS := 0.25
const MINIMAP_WINDOW_CELLS := Vector2(24.0, 24.0)
const SOURCE_MAP_TILE_PIXELS := 4
## Size, in tiles, of the picture the minimap samples from. The view plus the 3
## tiles tall art reaches in from every side is 30 or 31 tiles; the rest is slack
## the view can move in before the picture has to follow it.
const MINIMAP_REGION_CELLS := Vector2i(35, 35)
const JOHTO_FONT := preload("res://assets/source_text_font.fnt")
const MAP_MARKER_DISPLAY_SIZE := Vector2(13.0, 9.0)
const MAP_SLEEPING_BAG_DISPLAY_SIZE := Vector2(12.0, 8.0)

var main: GameMain
var map_marker_node: TextureRect
var map_sleeping_bag_node: TextureRect
var dig_panel: Panel
var dig_right_panel: Panel
var dig_left_label: Label
var dig_right_label: Label
var dig_reward_panel: Panel
var minimap_angle := 0.0
var minimap_player: TextureRect
var minimap_respawn: TextureRect
var minimap_last_player_cell := Vector2i(-2147483648, -2147483648)
var minimap_last_player_position := Vector2(-2147483648.0, -2147483648.0)
var minimap_last_bounds := Rect2i()
var minimap_last_respawn := Vector2i(-2147483648, -2147483648)
var minimap_refresh_accumulator := MINIMAP_REFRESH_SECONDS
var minimap_draw_size := Vector2i.ZERO
var minimap_draw_offset := Vector2i.ZERO
var minimap_texture_images := {}
var minimap_tile_previews := {}
var minimap_source_cache := {}
var minimap_cache_world_id := 0
var minimap_cache_discovered := -1
var minimap_cache_until := 0
## What the source picture was drawn from (tile edits, map art, structures),
## and a number bumped whenever the picture itself changes.
var minimap_cache_revision: Array = []
var minimap_source_serial := 0
var minimap_raster_key: Array = []
var minimap_recipes: Dictionary = {}
var teleport_name_label: Label
var built_map_art_cache: Dictionary = {}
var minimap_cache_built := 0
## world.discovered_added when the source picture was last up to date.
var minimap_cache_added := 0
var map_other_markers: Array = []

func _init(owner_main: GameMain) -> void:
    main = owner_main

func build_dig_minimap_ui() -> void:
    # DIG uses the same two-box source UI geometry as BUILD/CRAFTING.
    dig_panel = Panel.new()
    dig_panel.name = "DigPanel"
    dig_panel.position = Vector2(2.0, 2.0)
    dig_panel.size = Vector2(140.0, 48.0)
    dig_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
    dig_panel.add_theme_stylebox_override("panel", main._classic_dialogue_style())
    dig_panel.visible = false
    main.get_node("UI").add_child(dig_panel)

    dig_right_panel = Panel.new()
    dig_right_panel.name = "DigGetPanel"
    dig_right_panel.position = Vector2(176.0, 0.0)
    dig_right_panel.size = dig_panel.size
    dig_right_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
    dig_right_panel.add_theme_stylebox_override("panel", main._classic_dialogue_style())
    dig_panel.add_child(dig_right_panel)

    dig_left_label = main._source_ui_label(
        dig_panel, "DigSoil", Vector2(14.0, 8.0), Vector2(114.0, 34.0), 8, "DIG")
    dig_left_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    dig_right_label = main._source_ui_label(
        dig_right_panel, "DigResult", Vector2(14.0, 8.0), Vector2(114.0, 34.0), 8, "GET")
    dig_right_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    dig_reward_panel = Panel.new()
    dig_reward_panel.name = "DigRewardPanel"
    dig_reward_panel.position = dig_right_panel.position
    dig_reward_panel.size = dig_right_panel.size
    dig_reward_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
    dig_reward_panel.add_theme_stylebox_override("panel", main._classic_dialogue_style())
    dig_reward_panel.hide()
    dig_panel.add_child(dig_reward_panel)
    main.dig_reward_label = main._source_ui_label(dig_reward_panel, "Reward",
        dig_right_label.position, dig_right_label.size, 8)
    main.dig_reward_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART

    # Independent static compass/minimap. It never reuses/reparents the full map.
    main.minimap_root = Control.new()
    main.minimap_root.name = "WorldMiniMap"
    main.minimap_root.position = Vector2(2.0, 2.0)
    main.minimap_root.size = main.MINIMAP_SIZE
    main.minimap_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
    main.minimap_root.z_index = 80
    main.minimap_root.visible = false
    main.get_node("UI").add_child(main.minimap_root)

    main.minimap_map = main._source_texture_rect(
        main.minimap_root, "Map", MINIMAP_MAP_OFFSET,
        Vector2(MINIMAP_MAP_SIZE), null)
    main.minimap_map.stretch_mode = TextureRect.STRETCH_SCALE
    main.minimap_map.z_index = 1

    # The HUD's ring (hud_style.gd) around the map, with the north marker on it.
    var ring := Control.new()
    ring.name = "Ring"
    ring.size = main.MINIMAP_SIZE
    ring.mouse_filter = Control.MOUSE_FILTER_IGNORE
    ring.z_index = 5
    ring.draw.connect(func():
        var centre := main.MINIMAP_SIZE * 0.5
        var outer := main.MINIMAP_SIZE.x * 0.5 - HudStyle.STROKE * 0.5
        ring.draw_arc(centre, (outer + main.MINIMAP_MAP_RADIUS) * 0.5, 0.0, TAU, 64, HudStyle.fill(false, true), outer - main.MINIMAP_MAP_RADIUS + 0.5, true)
        ring.draw_arc(centre, outer, 0.0, TAU, 64, HudStyle.INK, HudStyle.STROKE, true))
    main.minimap_root.add_child(ring)
    main.minimap_north = preload("res://scripts/minimap_north.gd").new()
    main.minimap_north.name="North"
    main.minimap_root.add_child(main.minimap_north)
    minimap_player = main._source_texture_rect(
        main.minimap_root, "Player", Vector2.ZERO, Vector2(7.0, 5.0), null)
    var appearance_texture: Texture2D = main._player_appearance_texture(false)
    if appearance_texture != null and (not minimap_player.texture is AtlasTexture or (minimap_player.texture as AtlasTexture).atlas != appearance_texture):
        var marker_frame: AtlasTexture = AtlasTexture.new()
        marker_frame.atlas = appearance_texture
        marker_frame.region = Rect2(0.0, 0.0, 16.0, 11.0)
        minimap_player.texture = marker_frame
    minimap_player.z_index = 4

    minimap_respawn = main._source_texture_rect(
        main.minimap_root, "Respawn", Vector2.ZERO, Vector2(6.0, 4.0), MAP_SLEEPING_BAG_TEXTURE)
    minimap_respawn.z_index = 3
    minimap_respawn.visible = false

func _minimap_top_box_visible(ignore_dig: bool = false) -> bool:
    if not main.started or main.generating or main.battle_active or main.progression_active:
        return true
    if main.setup_panel.visible or main.touch_config.visible or main.game_menu_open or main.quit_prompt_open:
        return true
    if main.craft_menu_open or main.build_menu_open or main.resource_popup.visible:
        return true
    if not ignore_dig and dig_panel != null and dig_panel.visible:
        return true
    # Dynamically-created storage/sign/etc. top panels should also hide it. Keep
    # the explicitly approved bottom egg/wild dialogue and normal message boxes.
    for raw_child in main.get_node("UI").get_children():
        if not (raw_child is Control):
            continue
        var child: Control = raw_child as Control
        if not child.visible or child == main.minimap_root or (ignore_dig and child == dig_panel):
            continue
        if child == main.message_panel or child == main.egg_dialogue_panel or child == main.egg_choice_panel or child == main.wild_dialogue_panel or child == main.wild_choice_panel:
            continue
        if child.name in ["TouchControls", "WorldMiniMap"]:
            continue
        if child is Panel and child.position.y < 86.0 and child.size.y > 12.0:
            return true
    return false

func update_dig_hud_and_minimap(delta: float) -> void:
    if dig_panel == null or main.minimap_root == null:
        return
    var dig_selected := String(main.world.get("active_field_move")) == "DIG"
    var dig_active: bool = main.started and main.world.visible and dig_selected and not _minimap_top_box_visible(true)
    dig_active = dig_active and not main.storage_menu_open and not main.storage.storage_menu.visible and not main.trainer_tip_open and not main.field_move_wheel_open and not main.sign_dialog.visible
    if not dig_selected:
        main.dig_reward_seconds = 0.0
    elif dig_active:
        main.dig_reward_seconds = maxf(0.0, main.dig_reward_seconds - delta)
    dig_reward_panel.visible = main.dig_reward_seconds > 0.0
    dig_right_panel.visible = not dig_reward_panel.visible
    dig_panel.visible = dig_active
    if dig_active and main.world.has_method("get_dig_hud_state"):
        var state: Dictionary = main.world.call("get_dig_hud_state")
        dig_left_label.text = String(state.get("left", "DIG"))
        dig_right_label.text = String(state.get("right", ""))
        fit_compact_dig_label(dig_right_label)
        dig_left_label.modulate = Color.WHITE if bool(state.get("diggable", false)) else Color(0.55, 0.55, 0.55, 1.0)
    var top_free: bool = main.started and main.world.visible and not _minimap_top_box_visible()
    var minimap_should_show: bool = GameOptions.enabled("minimap") and top_free
    main.minimap_root.visible = minimap_should_show
    main.status_hud.refresh(delta, top_free)
    if not minimap_should_show:
        return
    var player_node: Node2D = main.world.get_node_or_null("Player") as Node2D
    if player_node == null:
        return
    var player_position: Vector2 = player_node.position
    var player_cell: Vector2i = Vector2i(
        int(floor(player_position.x / 16.0)), int(floor(player_position.y / 16.0)))
    var bounds: Rect2i = Rect2i(Vector2i.ZERO, Vector2i(int(main.world.get("map_w")), int(main.world.get("map_h"))))
    if main.world.has_method("get_map_bounds"):
        bounds = main.world.call("get_map_bounds")
    var respawn_cell: Vector2i = main.world.get("respawn_cell")
    var bounds_changed: bool = bounds != minimap_last_bounds
    var respawn_changed: bool = respawn_cell != minimap_last_respawn
    var player_position_changed: bool = player_position != minimap_last_player_position
    minimap_refresh_accumulator += delta
    if (
            bounds_changed
            or respawn_changed
            # While moving, 20 times a second is as smooth as the minimap's
            # few pixels can show; every frame cost about 4 ms.
            or (player_position_changed and minimap_refresh_accumulator >= 0.05)
            or main.minimap_map.texture == null
            or minimap_refresh_accumulator >= MINIMAP_REFRESH_SECONDS
        ):
        # Keep the remainder: zeroing it made 20 Hz into 15 Hz at 30 FPS.
        minimap_refresh_accumulator = fmod(minimap_refresh_accumulator, 0.05)
        minimap_last_bounds = bounds
        minimap_last_respawn = respawn_cell
        minimap_last_player_position = player_position
        _refresh_minimap(bounds, player_position)
        # Frame, north marker and waypoints only move with a refresh.
        _apply_minimap_rotation(delta)
    minimap_last_player_cell = player_cell

func _apply_minimap_rotation(delta: float = 1.0) -> void:
    minimap_angle = 0.0
    var angle:=minimap_angle
    main.minimap_map.pivot_offset = main.minimap_map.size * 0.5
    main.minimap_map.rotation = angle
    # On the ring, inside its outer edge.
    main.minimap_north.position = (main.MINIMAP_SIZE * 0.5 + Vector2(0,-27).rotated(angle) - main.minimap_north.size * 0.5).round()
    if minimap_respawn.visible:
        var center := MINIMAP_MAP_OFFSET + Vector2(MINIMAP_MAP_SIZE) * 0.5
        var unrotated: Vector2 = minimap_respawn.get_meta("unrotated_position", minimap_respawn.position)
        minimap_respawn.position = center + (unrotated + minimap_respawn.size * 0.5 - center).rotated(angle) - minimap_respawn.size * 0.5
    if is_instance_valid(main.waypoint_ui):main.waypoint_ui.update_minimap(angle)

func _refresh_minimap(bounds: Rect2i, player_position: Vector2) -> void:
    if bounds.size.x <= 0 or bounds.size.y <= 0:
        return
    var appearance_texture: Texture2D = main._player_appearance_texture(false)
    var current_marker := minimap_player.texture as AtlasTexture
    if appearance_texture != null and (current_marker == null or current_marker.atlas != appearance_texture):
        var marker_frame: AtlasTexture = AtlasTexture.new()
        marker_frame.atlas = appearance_texture
        marker_frame.region = Rect2(0.0, 0.0, 16.0, 11.0)
        minimap_player.texture = marker_frame
    var canvas_size: Vector2i = MINIMAP_MAP_SIZE
    var map_center: Vector2 = Vector2(float(canvas_size.x) * 0.5, float(canvas_size.y) * 0.5)
    var map_diameter: float = main.MINIMAP_MAP_RADIUS * 2.0
    var map_left: float = map_center.x - main.MINIMAP_MAP_RADIUS
    var map_top: float = map_center.y - main.MINIMAP_MAP_RADIUS
    var player_cell_position: Vector2 = player_position / 16.0
    var interior_image: Image = main.world.interior_map_image(bounds)
    var indoor := interior_image != null
    # Fit the floor's diagonal in the circular view, preserving centered-player
    # panning and uniform scale. Outdoors retain the approved 24-cell window.
    var centered := indoor
    var window_cells := MINIMAP_WINDOW_CELLS
    if indoor:
        window_cells = Vector2.ONE * maxf(24.0, Vector2(bounds.size).length() + 2.0)
    var half_window: Vector2 = window_cells * 0.5
    var view_origin: Vector2 = player_cell_position - half_window
    var min_origin_x: float = float(bounds.position.x)
    var min_origin_y: float = float(bounds.position.y)
    var max_origin_x: float = float(bounds.position.x + bounds.size.x) - window_cells.x
    var max_origin_y: float = float(bounds.position.y + bounds.size.y) - window_cells.y
    if max_origin_x < min_origin_x:
        max_origin_x = min_origin_x
    if max_origin_y < min_origin_y:
        max_origin_y = min_origin_y
    view_origin.x = clampf(view_origin.x, min_origin_x, max_origin_x)
    view_origin.y = clampf(view_origin.y, min_origin_y, max_origin_y)
    # A shift of one map pixel must move every terrain sample by the same
    # pixel. Fractional origins resample cell edges independently each frame.
    var cells_per_pixel: Vector2 = window_cells / map_diameter
    view_origin.x = clampf(roundf(view_origin.x / cells_per_pixel.x) * cells_per_pixel.x,
        min_origin_x, max_origin_x)
    view_origin.y = clampf(roundf(view_origin.y / cells_per_pixel.y) * cells_per_pixel.y,
        min_origin_y, max_origin_y)
    if centered:
        view_origin = player_cell_position - half_window
        view_origin = (view_origin / cells_per_pixel).round() * cells_per_pixel
    var exact = main.world.get("exact_world")
    main.minimap_map.set_meta("view_origin",view_origin)
    main.minimap_map.set_meta("window_cells",window_cells)
    # The picture is redrawn only when what it samples changed: the view, the
    # source picture (rebuilt on tile edits, patched on discovery) or, without
    # one, the tiles themselves. It used to be redrawn every 2 s regardless.
    var source_region: Dictionary = _minimap_source_region(bounds, view_origin)
    var source_image: Image = source_region.get("image")
    var raster_key: Array = [bounds, view_origin, window_cells, indoor, centered,
        0 if exact == null else exact.get_instance_id(),
        main.world.discovered_cells.size() if Time.get_ticks_msec() - minimap_cache_built >= 400 else minimap_cache_discovered,
        0 if source_image == null else source_image.get_instance_id(), minimap_source_serial,
        _minimap_world_revision() if source_image == null else []]
    if raster_key == minimap_raster_key and main.minimap_map.texture != null:
        _position_minimap_markers(bounds, player_position, view_origin, window_cells)
        return
    minimap_raster_key = raster_key
    var image := Image.create(canvas_size.x, canvas_size.y, false, Image.FORMAT_RGBA8)
    image.fill(Color(0, 0, 0, 0))
    var source_origin: Vector2i = source_region.get("origin", Vector2i.ZERO)
    if source_image != null:
        # Sampling is separable: calculate X/Y indices once, rather than
        # querying world discovery and doing vector/string work per pixel.
        # These are exactly the previous nearest-neighbour sample equations.
        var sample_columns := PackedInt32Array()
        for px in range(canvas_size.x):
            var u := clampf((float(px) + 0.5 - map_left) / map_diameter, 0.0, 1.0)
            var sample_x := view_origin.x + u * window_cells.x
            if centered and (sample_x < bounds.position.x or sample_x >= bounds.end.x):
                sample_columns.append(-1)
                continue
            sample_columns.append(clampi(floori(clampf(sample_x,
                float(bounds.position.x), float(bounds.end.x) - 0.0001) * SOURCE_MAP_TILE_PIXELS)
                - source_origin.x * SOURCE_MAP_TILE_PIXELS, 0, source_image.get_width() - 1))
        for py in range(canvas_size.y):
            var v := clampf((float(py) + 0.5 - map_top) / map_diameter, 0.0, 1.0)
            var sample_y := view_origin.y + v * window_cells.y
            var source_y := clampi(floori(clampf(sample_y,
                float(bounds.position.y), float(bounds.end.y) - 0.0001) * SOURCE_MAP_TILE_PIXELS)
                - source_origin.y * SOURCE_MAP_TILE_PIXELS, 0, source_image.get_height() - 1)
            var dy := float(py) + 0.5 - map_center.y
            for px in range(canvas_size.x):
                var dx := float(px) + 0.5 - map_center.x
                if dx * dx + dy * dy <= main.MINIMAP_MAP_RADIUS * main.MINIMAP_MAP_RADIUS:
                    if centered and (sample_columns[px] < 0 or sample_y < bounds.position.y or sample_y >= bounds.end.y):
                        image.set_pixel(px, py, Color(0.025, 0.035, 0.03, 1.0))
                    else:
                        image.set_pixel(px, py, source_image.get_pixel(sample_columns[px], source_y))
    else:
        for py in range(canvas_size.y):
            for px in range(canvas_size.x):
                var pixel_center: Vector2 = Vector2(float(px) + 0.5, float(py) + 0.5)
                var distance: float = pixel_center.distance_to(map_center)
                if distance > main.MINIMAP_MAP_RADIUS:
                    continue
                var sample_u: float = clampf((float(px) + 0.5 - map_left) / map_diameter, 0.0, 1.0)
                var sample_v: float = clampf((float(py) + 0.5 - map_top) / map_diameter, 0.0, 1.0)
                var sample_x: float = view_origin.x + sample_u * window_cells.x
                var sample_y: float = view_origin.y + sample_v * window_cells.y
                var clamped_x: int = clampi(int(floor(sample_x)), bounds.position.x, bounds.position.x + bounds.size.x - 1)
                var clamped_y: int = clampi(int(floor(sample_y)), bounds.position.y, bounds.position.y + bounds.size.y - 1)
                var cell: Vector2i = Vector2i(clamped_x, clamped_y)
                var discovered: bool = bool(main.world.call("is_cell_discovered", cell))
                var color: Color = Color(0.025, 0.035, 0.03, 1.0)
                if source_image != null:
                    var source_x: int = clampi(floori(clampf(sample_x,
                        float(bounds.position.x), float(bounds.end.x) - 0.0001) * SOURCE_MAP_TILE_PIXELS)
                        - source_origin.x * SOURCE_MAP_TILE_PIXELS, 0, source_image.get_width() - 1)
                    var source_y: int = clampi(floori(clampf(sample_y,
                        float(bounds.position.y), float(bounds.end.y) - 0.0001) * SOURCE_MAP_TILE_PIXELS)
                        - source_origin.y * SOURCE_MAP_TILE_PIXELS, 0, source_image.get_height() - 1)
                    color = source_image.get_pixel(source_x, source_y)
                elif discovered:
                    color = main.world.call("map_color_for_cell", cell)
                elif (px + py) % 2 != 0:
                    color = Color(0.045, 0.055, 0.05, 1.0)
                image.set_pixel(px, py, color)
    if main.minimap_map.texture is ImageTexture and main.minimap_map.texture.get_size() == Vector2(canvas_size):
        (main.minimap_map.texture as ImageTexture).update(image)
    else:
        main.minimap_map.texture = ImageTexture.create_from_image(image)
    minimap_draw_size = canvas_size
    minimap_draw_offset = Vector2i.ZERO
    _position_minimap_markers(bounds, player_position, view_origin, window_cells)

## Changes whenever anything the minimap draws from changed: a tile edit
## (tide, digging, building, pickups...), the map art, or the structures.
func _minimap_world_revision() -> Array:
    var exact = main.world.get("exact_world")
    var store = null if exact == null else exact.get("tiles")
    return [store.edit_count if store is WorldTileStore else 0,
        int(main.world.get("map_art_revision")), (main.world.get("built_structures") as Dictionary).size()]

func _minimap_source_region(bounds: Rect2i, view_origin: Vector2) -> Dictionary:
    var interior: Image = main.world.interior_map_image(bounds)
    if interior != null:
        return {"image": interior, "origin": bounds.position, "bounds": bounds, "region": bounds}
    var exact_world = main.world.get("exact_world")
    if exact_world == null:
        return {}
    # Use the full MAP screen's source tile recipes in a small window around
    # the player. The margin preserves tall art crossing the window edge.
    var origin := Vector2i(floori(view_origin.x), floori(view_origin.y)) - Vector2i(3, 3)
    var end := Vector2i(ceili(view_origin.x + MINIMAP_WINDOW_CELLS.x),
        ceili(view_origin.y + MINIMAP_WINDOW_CELLS.y)) + Vector2i(3, 3)
    var needed := Rect2i(origin, end - origin)
    var world_id: int = exact_world.get_instance_id()
    var discovered_count: int = main.world.discovered_cells.size()
    var now: int = Time.get_ticks_msec()
    if world_id != minimap_cache_world_id:
        minimap_texture_images.clear()
        minimap_tile_previews.clear()
        minimap_recipes.clear()
    # The picture covers a little more than the view and is kept while the view
    # stays inside it. When the view runs out of it the picture slides along
    # (the part it still has is moved and only the new cells are drawn), and
    # newly discovered ground is painted in at once, but only the patch that
    # changed. Other changes (tide, digs, builds) rebuild it, at most every
    # 2 s, as the 2 s refresh it replaces did.
    var revision := _minimap_world_revision()
    var cache := minimap_source_cache
    var cache_ok: bool = not cache.is_empty() and \
            world_id == minimap_cache_world_id and \
            (revision == minimap_cache_revision or now < minimap_cache_until) and \
            cache["bounds"] == bounds
    if cache_ok and not (cache["region"] as Rect2i).encloses(needed):
        cache_ok = _minimap_slide(needed, bounds, exact_world)
    if cache_ok:
        cache_ok = _minimap_paint_discovered(discovered_count, bounds, exact_world)
    if cache_ok:
        return cache
    var region := Rect2i(needed.position - (MINIMAP_REGION_CELLS - needed.size) / 2, MINIMAP_REGION_CELLS)
    var image := minimap_render(region, bounds, exact_world)
    minimap_cache_discovered = discovered_count
    minimap_cache_added = main.world.discovered_added
    main.world.discovered_dirty = Rect2i()
    minimap_cache_world_id = world_id
    minimap_cache_until = now + 2000
    minimap_cache_revision = revision
    minimap_source_serial += 1
    minimap_source_cache = {
        "image": image, "origin": region.position, "region": region, "bounds": bounds, "spare": null
    }
    return minimap_source_cache

## Moves the picture's region along so that it holds `needed` again, keeping
## what is drawn of the part both regions cover. The cells that came into it
## are drawn fresh (with the 3 tiles inside the old edge that tall art from
## those cells reaches). False if the move is too far to be worth it.
func _minimap_slide(needed: Rect2i, bounds: Rect2i, exact_world) -> bool:
    var cache := minimap_source_cache
    var old_region: Rect2i = cache["region"]
    var target := old_region.position
    # Leave the slack ahead of the view, and one tile behind it.
    if needed.position.x < old_region.position.x: target.x = needed.end.x + 1 - old_region.size.x
    elif needed.end.x > old_region.end.x: target.x = needed.position.x - 1
    if needed.position.y < old_region.position.y: target.y = needed.end.y + 1 - old_region.size.y
    elif needed.end.y > old_region.end.y: target.y = needed.position.y - 1
    var region := Rect2i(target, old_region.size)
    var kept := old_region.intersection(region)
    if not region.encloses(needed) or kept.size.x * 2 < region.size.x or kept.size.y * 2 < region.size.y:
        return false
    var image: Image = cache["image"]
    var moved: Image = cache.get("spare")
    if moved == null or moved.get_size() != image.get_size():
        moved = Image.create(image.get_width(), image.get_height(), false, Image.FORMAT_RGBA8)
    moved.blit_rect(image, Rect2i((kept.position - old_region.position) * SOURCE_MAP_TILE_PIXELS,
        kept.size * SOURCE_MAP_TILE_PIXELS), (kept.position - region.position) * SOURCE_MAP_TILE_PIXELS)
    cache["spare"] = image
    cache["image"] = moved
    cache["region"] = region
    cache["origin"] = region.position
    if region.position.x < old_region.position.x:
        minimap_paint(Rect2i(region.position, Vector2i(old_region.position.x - region.position.x, region.size.y)), bounds, exact_world)
    elif region.end.x > old_region.end.x:
        minimap_paint(Rect2i(Vector2i(old_region.end.x, region.position.y), Vector2i(region.end.x - old_region.end.x, region.size.y)), bounds, exact_world)
    if region.position.y < old_region.position.y:
        minimap_paint(Rect2i(region.position, Vector2i(region.size.x, old_region.position.y - region.position.y)), bounds, exact_world)
    elif region.end.y > old_region.end.y:
        minimap_paint(Rect2i(Vector2i(region.position.x, old_region.end.y), Vector2i(region.size.x, region.end.y - old_region.end.y)), bounds, exact_world)
    return true

## Paints in the ground discovered since the picture was last up to date. The
## world records a box around the cells it added; if its count of them does not
## explain the change in discovered_cells, or the box is most of the picture,
## this returns false and the picture is redrawn whole.
func _minimap_paint_discovered(discovered_count: int, bounds: Rect2i, exact_world) -> bool:
    var added: int = main.world.discovered_added
    if discovered_count == minimap_cache_discovered and added == minimap_cache_added:
        return true
    var known := discovered_count - minimap_cache_discovered == added - minimap_cache_added
    var dirty: Rect2i = main.world.discovered_dirty
    minimap_cache_discovered = discovered_count
    minimap_cache_added = added
    main.world.discovered_dirty = Rect2i()
    if not known:
        return false
    var kept: Rect2i = minimap_source_cache["region"]
    var changed := dirty.intersection(kept)
    if changed.size.x <= 0 or changed.size.y <= 0:
        return true
    if changed.grow(3).intersection(kept).get_area() * 2 >= kept.get_area():
        return false
    minimap_paint(changed, bounds, exact_world)
    return true

## Redraws the part of the picture that the tiles in `changed` can touch: art
## reaches up to 3 tiles past its own tile, so `changed` and 3 tiles around it
## are replaced, from a drawing that has 3 more tiles around that for the art
## reaching in from outside.
func minimap_paint(changed: Rect2i, bounds: Rect2i, exact_world) -> void:
    var cache := minimap_source_cache
    var kept: Rect2i = cache["region"]
    var patch := changed.grow(3).intersection(kept)
    if patch.size.x <= 0 or patch.size.y <= 0:
        return
    var drawn := patch.grow(3).intersection(kept)
    var fresh := minimap_render(drawn, bounds, exact_world)
    (cache["image"] as Image).blit_rect(fresh,
        Rect2i((patch.position - drawn.position) * SOURCE_MAP_TILE_PIXELS, patch.size * SOURCE_MAP_TILE_PIXELS),
        (patch.position - kept.position) * SOURCE_MAP_TILE_PIXELS)
    minimap_source_serial += 1

## What to draw for a tile, found by its name, upper name and colour: the
## lower and the upper drawing, each [image, rect, offset x, offset y] or null
## if the tile draws nothing there. `sig` is the key it is kept under.
func _minimap_recipe_pair(sig: Variant, base_name: String, upper_name: String, color: bool) -> Array:
    var known: Variant = minimap_recipes.get(sig)
    if known != null:
        return known
    if minimap_recipes.size() >= 4096:
        minimap_recipes.clear()
    var tile := {"base": base_name, "upper": upper_name, "color": color}
    var pair: Array = []
    for upper_pass in [false, true]:
        var spec: Dictionary = SourceWorldData.render_spec(tile, upper_pass)
        var recipe: Variant = null
        var texture := spec.get("texture") as Texture2D
        if texture != null:
            var source: Image = TexturePixels.of(texture)
            var rect: Rect2 = spec.get("region", Rect2(0,0,16,16))
            var preview := source.get_region(Rect2i(rect))
            preview.resize(maxi(1,roundi(rect.size.x / 4.0)), maxi(1,roundi(rect.size.y / 4.0)), Image.INTERPOLATE_NEAREST)
            var offset := Vector2i((Vector2(spec.get("offset",Vector2.ZERO)) / 4.0).round())
            recipe = [preview, Rect2i(Vector2i.ZERO, preview.get_size()), offset.x, offset.y]
        pair.append(recipe)
    minimap_recipes[sig] = pair
    return pair

## Draws the minimap's source picture for `region` (in tiles): every
## discovered tile, the buildings on them, and the checker over the rest.
func minimap_render(region: Rect2i, bounds: Rect2i, exact_world) -> Image:
    var image := Image.create(region.size.x * SOURCE_MAP_TILE_PIXELS,
        region.size.y * SOURCE_MAP_TILE_PIXELS, false, Image.FORMAT_RGBA8)
    image.fill(Color(0.025, 0.035, 0.03, 1.0))
    # Tiles are read straight from the store's arrays, not one SourceTile
    # object per cell, and discovery is looked up in the world's bitset.
    var store = exact_world.tiles
    var packed: bool = store is WorldTileStore
    var flags := PackedInt32Array()
    var name_ids := PackedInt32Array()
    var upper_ids := PackedInt32Array()
    var strings := PackedStringArray()
    var store_origin := Vector2i.ZERO
    var store_width := 0
    var store_height := 0
    var store_extra := false
    if packed:
        flags = store.flags
        name_ids = store.name_ids
        upper_ids = store.upper_ids
        strings = store.strings
        store_origin = store.origin
        store_width = store.width
        store_height = store.height
        store_extra = not (store.extra as Dictionary).is_empty()
    var discovered = main.world.discovered_cells
    var overworld: bool = String(main.world.active_area_id) == "OVERWORLD"
    var draw_x := PackedInt32Array()
    var draw_y := PackedInt32Array()
    var lower: Array = []
    var upper: Array = []
    var hidden_x := PackedInt32Array()
    var hidden_y := PackedInt32Array()
    var bounds_left := bounds.position.x
    var bounds_right := bounds.end.x
    for y in range(region.size.y):
        var cy := region.position.y + y
        var row_inside := cy >= bounds.position.y and cy < bounds.end.y
        for x in range(region.size.x):
            var cx := region.position.x + x
            if not row_inside or cx < bounds_left or cx >= bounds_right \
                    or not (discovered.has(Vector2i(cx, cy)) if overworld else main.world.is_cell_discovered(Vector2i(cx, cy))):
                hidden_x.append(x)
                hidden_y.append(y)
                continue
            var pair: Variant = null
            var in_store := false
            if packed:
                var at_x := cx - store_origin.x
                var at_y := cy - store_origin.y
                if at_x >= 0 and at_y >= 0 and at_x < store_width and at_y < store_height:
                    var index := at_y * store_width + at_x
                    var bits := flags[index]
                    if bits & WorldTileStore.PRESENT != 0:
                        in_store = true
                        var name_id := name_ids[index]
                        var upper_id := upper_ids[index]
                        var sig := name_id | (upper_id << 24) | ((bits & WorldTileStore.COLOR) << 47)
                        pair = minimap_recipes.get(sig)
                        if pair == null:
                            pair = _minimap_recipe_pair(sig, strings[name_id], strings[upper_id],
                                bits & WorldTileStore.COLOR != 0)
            if not in_store and (store_extra or not packed):
                var tile: SourceTile = exact_world.tile_at(Vector2i(cx, cy))
                if tile != null:
                    pair = _minimap_recipe_pair("%s|%s|%s" % [tile.name, tile.name_upper, tile.color],
                        tile.name, tile.name_upper, tile.color)
            if pair != null:
                draw_x.append(x)
                draw_y.append(y)
                lower.append(pair[0])
                upper.append(pair[1])
    for recipes in [lower, upper]:
        for index in range(draw_x.size()):
            var recipe: Variant = recipes[index]
            if recipe != null:
                image.blend_rect(recipe[0], recipe[1], Vector2i(
                    draw_x[index] * SOURCE_MAP_TILE_PIXELS + recipe[2],
                    draw_y[index] * SOURCE_MAP_TILE_PIXELS + recipe[3]))
    _paint_built_structures_on_map(image, region.position)
    # Mask after both passes, preserving tall-art overlap and checker positions.
    var dark := Color(0.025, 0.035, 0.03, 1.0)
    var light := Color(0.045, 0.055, 0.05, 1.0)
    for index in range(hidden_x.size()):
        var cell := region.position + Vector2i(hidden_x[index], hidden_y[index]) - bounds.position
        image.fill_rect(Rect2i(hidden_x[index] * SOURCE_MAP_TILE_PIXELS, hidden_y[index] * SOURCE_MAP_TILE_PIXELS,
            SOURCE_MAP_TILE_PIXELS, SOURCE_MAP_TILE_PIXELS), light if (cell.x + cell.y) % 2 != 0 else dark)
    return image

func _paint_built_structures_on_map(image: Image, origin: Vector2i) -> void:
    var structures: Dictionary = main.world.get("built_structures")
    var visible_rect := Rect2i(origin, image.get_size() / SOURCE_MAP_TILE_PIXELS)
    var ordered: Array = structures.keys()
    ordered.sort_custom(func(a, b): return a.y < b.y if a.y != b.y else a.x < b.x)
    var near := visible_rect.grow(4)
    for cell in ordered:
        if not near.has_point(cell): continue
        var actor := structures[cell].get("sprite") as Sprite2D
        if not is_instance_valid(actor) or actor.texture == null: continue
        var cache_key := str([actor.texture.get_instance_id(), actor.region_enabled, actor.region_rect, actor.hframes, actor.vframes, actor.frame])
        if not built_map_art_cache.has(cache_key):
            if built_map_art_cache.size() >= 512: built_map_art_cache.clear()
            var pixels := TexturePixels.of(actor.texture)
            if actor.region_enabled: pixels = pixels.get_region(Rect2i(actor.region_rect))
            elif actor.hframes > 1 or actor.vframes > 1:
                var frame_size := pixels.get_size() / Vector2i(actor.hframes, actor.vframes)
                pixels = pixels.get_region(Rect2i(actor.frame_coords * frame_size, frame_size))
            var full_size := pixels.get_size()
            pixels.resize(maxi(1, roundi(full_size.x / 4.0)), maxi(1, roundi(full_size.y / 4.0)), Image.INTERPOLATE_NEAREST)
            built_map_art_cache[cache_key] = {"image":pixels,"size":full_size}
        var recipe: Dictionary = built_map_art_cache[cache_key]
        var pixels: Image = recipe.image
        var at := actor.position + actor.offset
        if actor.centered: at -= Vector2(recipe.size) * 0.5
        image.blend_rect(pixels, Rect2i(Vector2i.ZERO, pixels.get_size()), Vector2i((at / 4.0).round()) - origin * SOURCE_MAP_TILE_PIXELS)

func _position_minimap_markers(
        bounds: Rect2i, player_position: Vector2, view_origin: Vector2,
        window_cells: Vector2 = MINIMAP_WINDOW_CELLS) -> void:
    if bounds.size.x <= 0 or bounds.size.y <= 0:
        return
    var canvas_size: Vector2 = Vector2(MINIMAP_MAP_SIZE)
    var map_center: Vector2 = MINIMAP_MAP_OFFSET + canvas_size * 0.5
    var map_diameter: float = main.MINIMAP_MAP_RADIUS * 2.0
    var map_left: float = map_center.x - main.MINIMAP_MAP_RADIUS
    var map_top: float = map_center.y - main.MINIMAP_MAP_RADIUS
    minimap_player.position = map_center - minimap_player.size * 0.5
    var respawn: Vector2i = main.world.get("respawn_cell")
    minimap_respawn.visible = false
    if respawn.x > -2147483648 and bounds.has_point(respawn):
        var respawn_center: Vector2 = Vector2(
            map_left + ((float(respawn.x) + 0.5 - view_origin.x) / window_cells.x) * map_diameter,
            map_top + ((float(respawn.y) + 0.5 - view_origin.y) / window_cells.y) * map_diameter)
        var inside_circle: bool = respawn_center.distance_to(map_center) <= main.MINIMAP_MAP_RADIUS
        minimap_respawn.visible = inside_circle
        if minimap_respawn.visible:
            minimap_respawn.position = respawn_center - minimap_respawn.size * 0.5
            minimap_respawn.set_meta("unrotated_position", minimap_respawn.position)
    _position_minimap_other_players(map_left, map_top, map_diameter, map_center, view_origin, window_cells)

func _coop_players_here() -> Dictionary:
    var result := {}
    if not is_instance_valid(main.coop_game) or not main.coop_game.active or not main.coop_game.session.trusted:
        return result
    var packets: Dictionary = main.coop_game.visuals.last_packets
    for actor in packets:
        var packet: Dictionary = packets[actor]
        if actor == main.coop_game.session.actor or packet.get("area") != main.coop_game._area():
            continue
        if not packet.get("visual") is Dictionary:
            continue
        result[actor] = packet
    return result

func _coop_marker_texture(visual: Dictionary) -> AtlasTexture:
    var model := clampi(int(visual.get("model", 0)), 0, main.PLAYER_MODEL_WALK_TEXTURES.size() - 1)
    var color := clampi(int(visual.get("color", 0)), 0, main.PLAYER_COLOR_VALUES.size() - 1)
    var marker_frame := AtlasTexture.new()
    marker_frame.atlas = main._recolor_texture(main.lazy_texture(main.PLAYER_MODEL_WALK_TEXTURES[model]),
        main.PLAYER_MODEL_REPLACE_COLORS[model], main.PLAYER_COLOR_VALUES[color],
        "coop:%d:%d:%s:%s" % [model, color, false, "walk"])
    marker_frame.region = Rect2(0.0, 0.0, 16.0, 11.0)
    marker_frame.set_meta("look", "%d:%d" % [model, color])
    return marker_frame

func _position_minimap_other_players(map_left: float, map_top: float, map_diameter: float,
        map_center: Vector2, view_origin: Vector2, window_cells: Vector2) -> void:
    var here := _coop_players_here()
    for actor in here:
        var packet: Dictionary = here[actor]
        var marker: TextureRect = main.minimap_others.get(actor)
        if not is_instance_valid(marker):
            marker = main._source_texture_rect(main.minimap_root, "OtherPlayer", Vector2.ZERO, Vector2(7.0, 5.0), null)
            marker.z_index = 4
            main.minimap_others[actor] = marker
        var visual: Dictionary = packet.visual
        var look := "%d:%d" % [int(visual.get("model", 0)), int(visual.get("color", 0))]
        if marker.texture == null or marker.texture.get_meta("look", "") != look:
            marker.texture = _coop_marker_texture(visual)
        var cell: Vector2 = main.world.outdoor_map_position(Vector2(float(packet.get("body_x", 0.0)), float(packet.get("body_y", 0.0))) / 16.0)
        var center := Vector2(
            map_left + ((cell.x - view_origin.x) / window_cells.x) * map_diameter,
            map_top + ((cell.y - view_origin.y) / window_cells.y) * map_diameter)
        marker.visible = center.distance_to(map_center) <= main.MINIMAP_MAP_RADIUS
        marker.position = center - marker.size * 0.5
    for actor in main.minimap_others.keys():
        if not here.has(actor):
            if is_instance_valid(main.minimap_others[actor]):
                main.minimap_others[actor].queue_free()
            main.minimap_others.erase(actor)

func _add_map_other_players(map_view: Control, bounds: Rect2i, image_size: Vector2i, marker_size: Vector2) -> void:
    map_other_markers.clear()
    var here := _coop_players_here()
    for actor in here:
        var packet: Dictionary = here[actor]
        var other := TextureRect.new()
        other.mouse_filter = Control.MOUSE_FILTER_IGNORE
        other.texture = _coop_marker_texture(packet.visual)
        other.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
        other.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
        other.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
        other.z_index = 19
        var cell: Vector2i = Vector2i(main.world.outdoor_map_position(Vector2(floorf(float(packet.get("body_x", 0.0)) / 16.0), floorf(float(packet.get("body_y", 0.0)) / 16.0))).floor())
        var center := Vector2(float(cell.x - bounds.position.x) * SOURCE_MAP_TILE_PIXELS,
            float(cell.y - bounds.position.y) * SOURCE_MAP_TILE_PIXELS)
        other.position = Vector2(
            clampf(center.x - marker_size.x * 0.5, 0.0, maxf(0.0, float(image_size.x) - marker_size.x)),
            clampf(center.y - marker_size.y * 0.5, 0.0, maxf(0.0, float(image_size.y) - marker_size.y)))
        other.size = marker_size
        other.pivot_offset = marker_size * 0.5
        map_view.add_child(other)
        map_other_markers.append(other)

func fit_compact_dig_label(label: Label) -> void:
    var compact := label.get_line_count() > 3
    label.add_theme_constant_override("line_spacing", -3 if compact else 0)
    label.position.y = 6.0 if compact else 8.0
    label.size.y = 36.0 if compact else 34.0

func show_map_menu() -> void:
    main.game_menu_open = true
    main.game_menu.show()
    main.world.set_gameplay_enabled(false)
    main.get_node("UI/GameMenu/MapScreen/Hint").text = "DPAD/STICK: CURSOR  R STICK: PAN\nL/R: ZOOM  " + ("Waypoint: A  " if GameOptions.enabled("map_waypoint") else "") + "B: BACK"
    main.get_node("UI/GameMenu/MapScreen/Hint").add_theme_constant_override("line_spacing", 0)
    if not is_instance_valid(main.waypoint_ui):
        main.waypoint_ui=preload("res://scripts/map_waypoints.gd").new()
        main.add_child(main.waypoint_ui)
        main.waypoint_ui.configure(main)
    main.teleport_map_mode = false
    main.teleport_destinations.clear()
    main.game_menu_detail_open = true
    main.game_menu_box.visible = false
    main.game_menu_detail.visible = false
    main.game_menu_map_screen.visible = true
    main.game_menu_map.visible = true
    main.map_zoom = main.DEFAULT_MAP_ZOOM
    main.map_pan = Vector2.ZERO
    _draw_world_map()
    if is_instance_valid(main.map_view_node): main.waypoint_ui.setup_map()

func open_teleport_map(destinations: Array) -> void:
    if destinations.is_empty():
        main._show_message("There are no BEACONS to TELEPORT to.")
        return
    main.teleport_map_mode = true
    main.teleport_destinations = destinations.duplicate(true)
    main.teleport_destination_index = 0
    main.game_menu_open = true
    main.game_menu_detail_open = true
    main.game_menu.visible = true
    main.game_menu_box.visible = false
    main.game_menu_detail.visible = false
    main.game_menu_map_screen.visible = true
    main.game_menu_map.visible = true
    main.world.set_gameplay_enabled(false)
    main.touch_controls.set_game_active(true)
    main.map_zoom = main.DEFAULT_MAP_ZOOM
    main.map_pan = Vector2.ZERO
    _draw_world_map()
    _refresh_teleport_map_selection()

func cycle_teleport_destination(direction: int) -> void:
    if main.teleport_destinations.is_empty():
        return
    main.teleport_destination_index = wrapi(main.teleport_destination_index + direction, 0, main.teleport_destinations.size())
    _refresh_teleport_map_selection()

func _refresh_teleport_map_selection() -> void:
    if main.teleport_destinations.is_empty() or main.map_view_node == null:
        return
    var destination: Dictionary = main.teleport_destinations[main.teleport_destination_index]
    var cell: Vector2i = destination.get("cell", Vector2i.ZERO)
    # The tile streams draw the view there while the map is up, so the jump finds it drawn.
    if main.world.has_method("prepare_view_at"): main.world.call("prepare_view_at", cell)
    var bounds: Rect2i = main.world.call("get_map_bounds") if main.world.has_method("get_map_bounds") else Rect2i(Vector2i.ZERO, Vector2i(int(main.world.get("map_w")), int(main.world.get("map_h"))))
    var local_center := Vector2(
        float(cell.x - bounds.position.x) / maxf(1.0, float(bounds.size.x)) * main.map_view_node.size.x,
        float(cell.y - bounds.position.y) / maxf(1.0, float(bounds.size.y)) * main.map_view_node.size.y
    )
    main.map_pan = (main.map_view_node.size * 0.5 - local_center) * main.map_zoom
    update_map_transform()
    if teleport_name_label == null or not is_instance_valid(teleport_name_label):
        teleport_name_label = Label.new()
        teleport_name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
        teleport_name_label.add_theme_font_override("font", JOHTO_FONT)
        teleport_name_label.add_theme_font_size_override("font_size", 8)
        teleport_name_label.position = Vector2(8, 134)
        teleport_name_label.size = Vector2(304, 18)
        teleport_name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
        teleport_name_label.z_index = 100
        main.game_menu_map.add_child(teleport_name_label)
    teleport_name_label.text = "%s   %d/%d" % [
        String(destination.get("name", "BEACON")),
        main.teleport_destination_index + 1, main.teleport_destinations.size()]

func _draw_world_map() -> void:
    clear_map_canvas()
    var bounds: Rect2i = main.world.get_map_bounds()
    if bounds.size.x <= 0 or bounds.size.y <= 0:
        return
    var image_size := bounds.size * SOURCE_MAP_TILE_PIXELS
    # Interiors are one small image; the overworld's picture is kept (map_raster).
    var interior: Image = main.world.interior_map_image(bounds)
    var map_view: TextureRect = main.map_raster.make_view() if interior == null else TextureRect.new()
    if interior != null:
        map_view.texture = ImageTexture.create_from_image(interior)
        map_view.stretch_mode = TextureRect.STRETCH_SCALE
    map_view.mouse_filter = Control.MOUSE_FILTER_IGNORE
    map_view.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
    map_view.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
    map_view.size = Vector2(image_size)
    main.map_view_node = map_view
    main.game_menu_map.add_child(map_view)

    var marker := TextureRect.new()
    marker.mouse_filter = Control.MOUSE_FILTER_IGNORE
    var player = main.world.get_node("Player")
    var appearance_texture := main._player_appearance_texture(false)
    if appearance_texture != null:
        var marker_frame := AtlasTexture.new()
        marker_frame.atlas = appearance_texture
        # The Java minimap draws the full 16x11 head/upper-body region. The
        # old 8-pixel crop removed most hats and made the marker easy to hide.
        marker_frame.region = Rect2(0.0, 0.0, 16.0, 11.0)
        marker.texture = marker_frame
    marker.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
    marker.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
    marker.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
    marker.z_index = 20
    var player_cell: Vector2i = Vector2i(
        int(floor(player.position.x / 16.0)),
        int(floor(player.position.y / 16.0))
    )
    var marker_size := MAP_MARKER_DISPLAY_SIZE
    var marker_center := Vector2(
        float(player_cell.x - bounds.position.x) * SOURCE_MAP_TILE_PIXELS,
        float(player_cell.y - bounds.position.y) * SOURCE_MAP_TILE_PIXELS
    )
    marker.position = Vector2(
        clampf(
            marker_center.x - marker_size.x * 0.5,
            0.0,
            maxf(0.0, float(image_size.x) - marker_size.x)
        ),
        clampf(
            marker_center.y - marker_size.y * 0.5,
            0.0,
            maxf(0.0, float(image_size.y) - marker_size.y)
        )
    )
    marker.size = marker_size
    marker.pivot_offset = marker_size * 0.5
    map_marker_node = marker
    map_view.add_child(marker)
    _add_map_other_players(map_view, bounds, image_size, marker_size)

    # Separate respawn marker using the authored sleeping-bag sprite. Only show
    # it after the player has actually set a respawn point.
    var respawn: Vector2i = main.world.get("respawn_cell")
    if respawn.x > -2147483648 and bounds.has_point(respawn):
        var bag_marker := TextureRect.new()
        bag_marker.mouse_filter = Control.MOUSE_FILTER_IGNORE
        bag_marker.texture = MAP_SLEEPING_BAG_TEXTURE
        bag_marker.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
        bag_marker.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
        bag_marker.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
        bag_marker.z_index = 19
        var bag_center := Vector2(
            float(respawn.x - bounds.position.x) * SOURCE_MAP_TILE_PIXELS,
            float(respawn.y - bounds.position.y) * SOURCE_MAP_TILE_PIXELS
        )
        bag_marker.size = MAP_SLEEPING_BAG_DISPLAY_SIZE
        bag_marker.position = bag_center - bag_marker.size * 0.5
        bag_marker.pivot_offset = bag_marker.size * 0.5
        map_sleeping_bag_node = bag_marker
        map_view.add_child(bag_marker)

    # Open on the player's discovered area instead of the center of the full
    # generated landmass, where the explored patch looked tiny.
    var marker_local_center := marker.position + marker.size * 0.5
    main.map_pan = (map_view.size * 0.5 - marker_local_center) * main.map_zoom
    update_map_transform()

func _paint_source_map_tile(image: Image, destination: Vector2i,
        spec: Dictionary, texture_images: Dictionary,
        map_tile_previews: Dictionary) -> void:
    if spec.is_empty():
        return
    var texture := spec.get("texture") as Texture2D
    if texture == null:
        return
    var texture_id := texture.get_instance_id()
    if not texture_images.has(texture_id):
        texture_images[texture_id] = TexturePixels.of(texture)
    var source: Image = texture_images[texture_id]
    if source == null:
        return
    var region: Rect2 = spec.get("region", Rect2(0, 0, 16, 16))
    var offset: Vector2 = spec.get("offset", Vector2.ZERO)
    var preview_key := "%d|%s" % [texture_id, region]
    if not map_tile_previews.has(preview_key):
        var preview := source.get_region(Rect2i(region))
        preview.resize(
            maxi(1, roundi(region.size.x * SOURCE_MAP_TILE_PIXELS / 16.0)),
            maxi(1, roundi(region.size.y * SOURCE_MAP_TILE_PIXELS / 16.0)),
            Image.INTERPOLATE_NEAREST)
        map_tile_previews[preview_key] = preview
    var tile_image: Image = map_tile_previews[preview_key]
    var map_offset := Vector2i((offset * SOURCE_MAP_TILE_PIXELS / 16.0).round())
    image.blend_rect(tile_image,
        Rect2i(Vector2i.ZERO, tile_image.get_size()),
        destination + map_offset)

func update_map_transform() -> void:
    if main.map_view_node == null or not is_instance_valid(main.map_view_node):
        return
    _clamp_map_pan()
    main.map_view_node.scale = Vector2(main.map_zoom, main.map_zoom)
    main.map_view_node.position = main.MAP_VIEWPORT_CENTER + main.map_pan - \
        main.map_view_node.size * main.map_zoom * 0.5
    if is_instance_valid(main.waypoint_ui):main.waypoint_ui.update_markers()
    var inverse_zoom := 1.0 / maxf(main.map_zoom, 0.01)
    if map_marker_node != null and is_instance_valid(map_marker_node):
        # Terrain zoom must not turn the locator into a giant head.
        map_marker_node.scale = Vector2(inverse_zoom, inverse_zoom)
    for other in map_other_markers:
        if is_instance_valid(other):
            other.scale = Vector2(inverse_zoom, inverse_zoom)
    if map_sleeping_bag_node != null and is_instance_valid(map_sleeping_bag_node):
        map_sleeping_bag_node.scale = Vector2(inverse_zoom, inverse_zoom)

func set_map_zoom(value: float) -> void:
    var old_zoom := maxf(main.map_zoom, 0.01)
    main.map_zoom = clampf(value, 0.75 / SOURCE_MAP_TILE_PIXELS, 1.0)
    # Preserve the local point currently under the screen center.
    main.map_pan *= main.map_zoom / old_zoom
    update_map_transform()

func _clamp_map_pan() -> void:
    if main.map_view_node == null or not is_instance_valid(main.map_view_node):
        return
    var scaled_size := main.map_view_node.size * main.map_zoom
    var limit := Vector2(
        maxf(0.0, (scaled_size.x - main.MAP_VIEWPORT_SIZE.x) * 0.5),
        maxf(0.0, (scaled_size.y - main.MAP_VIEWPORT_SIZE.y) * 0.5)
    )
    main.map_pan.x = clampf(main.map_pan.x, -limit.x, limit.x)
    main.map_pan.y = clampf(main.map_pan.y, -limit.y, limit.y)

func clear_map_canvas() -> void:
    teleport_name_label = null
    for child in main.game_menu_map.get_children():
        child.queue_free()
    main.map_view_node = null
    map_marker_node = null
    map_sleeping_bag_node = null

func invalidate_travel_maps() -> void:
    main.map_raster.forget()
    minimap_raster_key.clear()
    minimap_source_cache.clear()
    minimap_cache_world_id = 0
    minimap_cache_until = 0
    minimap_texture_images.clear()
    minimap_tile_previews.clear()
    minimap_recipes.clear()
    clear_map_canvas()
    _refresh_minimap(main.world.get_map_bounds(), main.world.player.position)

func warm_map_cache() -> void:
    if not is_instance_valid(main.waypoint_ui):
        main.waypoint_ui = preload("res://scripts/map_waypoints.gd").new()
        main.add_child(main.waypoint_ui)
        main.waypoint_ui.configure(main)
    # The map's picture of the ground discovered so far, under the loading screen.
    if main.map_raster.refresh():
        while main.map_raster.draw_dirty(12000): await main.get_tree().process_frame
