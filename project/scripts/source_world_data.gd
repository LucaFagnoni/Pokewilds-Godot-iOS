class_name SourceWorldData
extends RefCounted

const TILE_ROOT := "res://assets/source_0_8_11/tiles"
const EXACT_GLOBAL_ROOT := "res://assets/source_exact/global"
const SOURCE_DAY_SKY_TEXTURE := preload("res://assets/environment/cloud5.png")
const EXACT_GLOBAL_TEXTURES := {
    "ledge1_corner_bl_color": "ledge1_corner_bl_color.png",
    "ledge1_corner_br_color": "ledge1_corner_br_color.png"
}
const ASSET_ALIASES := {
    # Same-named sewer/blue-cave variants must not replace overworld colors.
    "water1": "water1.png",
    "water2": "water2.png",
    "rock1": "rock1.png",
    "forest1": "green1.png",
    "grass4": "grass4_over.png",
    "mountain4": "mountain1.png",
    "mountain5": "mountain1.png",
    # Tile.java renders both logical volcano floor variants from volcano1.
    "volcano2": "volcano1.png",
    "ruins1_upper": "ruins1_NSEW.png",
    "building1_fossilreviver1": "fossil1.png",
    # The uncoloured source placeholder is the intermittent grey square seen
    # in the world; the shipped GSC variant is the intended transparent tree.
    "tree_small1": "gsc/tree_small1.png",
    # The grayscale grass-ledge placeholders are palette masks in the Java
    # renderer.  Godot must select the authored color versions directly or the
    # horizontal ledges render as grey bars instead of the brown/green source art.
    "ledge_grass_down": "ledge1_down_color.png",
    "ledge_grass_ramp": "ledge_grass_ramp_color.png",
    "lava1_": "lava_sheet1.png"
}

# These are the Tile.java branches that keep the complete source region rather
# than taking the default 16x16 tile. The exact world retains Java's Y-up cell
# coordinates, so these sprites extend downward from their anchor in Godot.
const FULL_SOURCE_TEXTURES := [
    "tree1", "tree2", "tree4", "tree6", "tree7", "tree8",
    "tree_large1", "tree_large1_color", "tree_large2", "tree_large3",
    "tree_large4", "tree_fairy1", "tree_fairy2", "grass_fairy1",
    "grass_fairy2", "grass_fairy3", "aloe_large1", "tree_savanna1", "cactus2_cacturne",
    "ruins1_pillar1", "ruins1_pillar1_broken"
]

static var _asset_index: Dictionary = {}
static var _texture_cache: Dictionary = {}
static var _puddle_texture_cache: Dictionary = {}
static var _puddle_reflection_mask_cache: Dictionary = {}
static var _reflected_day_sky_image: Image
static var _reflected_day_sky_texture: Texture2D

static func reflected_day_sky_image() -> Image:
    if _reflected_day_sky_image == null:
        var original: Image = SOURCE_DAY_SKY_TEXTURE.get_image()
        if original == null:
            return null
        _reflected_day_sky_image = original.duplicate()
        # Rotate only reflected-pool cloud artwork; keep world-space motion unchanged.
        _reflected_day_sky_image.flip_x()
        _reflected_day_sky_image.flip_y()
    return _reflected_day_sky_image

static func reflected_day_sky_texture() -> Texture2D:
    if _reflected_day_sky_texture == null:
        var image := reflected_day_sky_image()
        if image == null:
            return null
        _reflected_day_sky_texture = ImageTexture.create_from_image(image)
    return _reflected_day_sky_texture

static func shoreline_quads(
        shore_type: String, animation_frame: int = 0
    ) -> Array[Dictionary]:
    if shore_type.is_empty():
        return []
    # Java's map uses Y-up while Godot displays the losslessly ported cells on
    # a Y-down canvas. Mirror only the directional recipe, not world data.
    shore_type = _mirror_vertical_bracket_directions(shore_type)
    var outer := texture_for("shore_sheet4")
    var inner := texture_for("shore1inner_sheet2")
    if outer == null or inner == null:
        return []
    var frame := posmod(animation_frame, 7)
    var quad_ne: Variant = Vector2(24, 24)
    if "[E]" in shore_type:
        quad_ne += Vector2(16, 0)
    if "[N]" in shore_type:
        quad_ne += Vector2(0, 16)
    if "[NE]" in shore_type and "[N]" not in shore_type and "[E]" not in shore_type:
        quad_ne = null
    var quad_nw: Variant = Vector2(16, 24)
    if "[W]" in shore_type:
        quad_nw += Vector2(-16, 0)
    if "[N]" in shore_type:
        quad_nw += Vector2(0, 16)
    if "[NW]" in shore_type and "[N]" not in shore_type and "[W]" not in shore_type:
        quad_nw = null
    var quad_se: Variant = Vector2(24, 16)
    if "[E]" in shore_type:
        quad_se += Vector2(16, 0)
    if "[S]" in shore_type:
        quad_se += Vector2(0, -16)
    if "[SE]" in shore_type and "[S]" not in shore_type and "[E]" not in shore_type:
        quad_se = null
    var quad_sw: Variant = Vector2(16, 16)
    if "[W]" in shore_type:
        quad_sw += Vector2(-16, 0)
    if "[S]" in shore_type:
        quad_sw += Vector2(0, -16)
    if "[SW]" in shore_type and "[S]" not in shore_type and "[W]" not in shore_type:
        quad_sw = null
    var source_quads: Array = [quad_nw, quad_ne, quad_sw, quad_se]
    var inner_offsets := [
        Vector2(0, 0), Vector2(24, 0),
        Vector2(0, 24), Vector2(24, 24)
    ]
    var destinations := [
        Vector2(0, 0), Vector2(8, 0),
        Vector2(0, 8), Vector2(8, 8)
    ]
    var result: Array[Dictionary] = []
    for index in range(4):
        var texture := outer
        var source_position: Vector2
        if source_quads[index] == null:
            texture = inner
            source_position = Vector2(inner_offsets[index]) + Vector2(frame * 32, 0)
        else:
            var source_quad := Vector2(source_quads[index])
            source_position = Vector2(
                source_quad.x + frame * 48,
                40.0 - source_quad.y
            )
        result.append({
            "texture": texture,
            "source": Rect2(source_position, Vector2(8, 8)),
            "offset": Vector2(destinations[index])
        })
    return result

# Tile.java builds several logical tiles from a different base image, an
# over-sprite, or a 16x16 region inside a sheet. Returning that render recipe is
# essential: looking up the logical name as a standalone PNG makes those tiles
# invisible while their source collision remains active.
static func render_spec(
        raw_tile: Variant,
        draw_upper: bool,
        animation_frame: int = 0,
        animation_tick: int = 0
    ) -> Dictionary:
    var base_name := ""
    var upper_name := ""
    var use_color := false
    if raw_tile is SourceTile:
        base_name = (raw_tile as SourceTile).name
        upper_name = (raw_tile as SourceTile).name_upper
        use_color = (raw_tile as SourceTile).color
    elif raw_tile is Dictionary:
        base_name = String((raw_tile as Dictionary).get("base", ""))
        upper_name = String((raw_tile as Dictionary).get("upper", ""))
        use_color = bool((raw_tile as Dictionary).get("color", false))
    if not draw_upper and "_puddle1" in base_name and \
            "_tidalwater" not in base_name:
        var puddle := puddle_texture_for(base_name)
        if puddle != null:
            return {
                "texture": puddle,
                "region": Rect2(0, 0, 16, 16),
                "size": Vector2(16, 16),
                "offset": Vector2.ZERO
            }
    var logical_name := upper_name if draw_upper else base_name
    if draw_upper and logical_name.is_empty():
        logical_name = String({
            "grass1": "grass1",
            "grass2": "grass2_over",
            "grass3": "grass3_over",
            "grass4": "grass4_over",
            "grass_sand1": "grass2_over",
            "grass_sand2": "grass2_over",
            "grass_sand3": "grass5_over",
            "grass_graveyard1": "grass6_over",
            # Tile.java renders logical tree5 as green1 plus tree6 without
            # rewriting its stored names.
            "tree5": "tree6",
            "ruins1_pillar1": "ruins1_pillar1",
            "ruins1_pillar1_broken": "ruins1_pillar1_broken"
        }.get(_clean_asset_name(base_name), ""))
    elif not draw_upper:
        logical_name = String({
            "ruins1_pillar1": "desert4",
            "ruins1_pillar1_broken": "desert4",
            "grass1": "blank2",
            "grass2": "grass2_under",
            "grass3": "grass3_under",
            "grass4": "green1",
            "grass_sand1": "sand1",
            "grass_sand2": "desert1",
            "grass_sand3": "desert6",
            "grass_graveyard1": "green11",
            "mountain4": "mountain1",
            "mountain5": "mountain1",
            "sand4": "sand1",
            "sand4_tidal": "sand1",
            "sand3_desertedge": "sand3",
            "tree5": "green1",
            "tree_large1_nosprite": "blank",
            "pedistal1": "blank",
            "building1_fossilreviver1": "blank",
            "interiorwall1": "blank"
        }.get(_clean_asset_name(base_name), logical_name))
        var clean_base := _clean_asset_name(base_name)
        if "_tidal" in clean_base:
            logical_name = clean_base.split("_", false, 1)[0]
            if logical_name == "sand4" or "bridge" in clean_base:
                logical_name = "sand1" if logical_name == "sand4" else "bridge1"
        elif "gravestone" in clean_base or "sign_" in clean_base:
            logical_name = "blank"
        elif clean_base.begins_with("ledges3") and clean_base != "ledges3_none":
            logical_name = "blank"
    # GenForest2 constructs the grass-ledge corner caps with color=true.
    # The uncoloured PNGs are grayscale palette masks; use the source-authored
    # brown/green caps only for those colored source tiles.
    if use_color and logical_name in ["ledge1_corner_bl", "ledge1_corner_br"]:
        logical_name += "_color"
    if logical_name == "tree_large1" and (draw_upper or use_color):
        logical_name = "tree_large1_color"
    # Tile.init shares this visual across all biome-specific buried-item sites.
    # Keep the logical upper name intact for PlayerStanding's reward table.
    if draw_upper and "_cracked" in logical_name:
        logical_name = "desert4_cracked"
    return _render_spec_for_name(
        logical_name, animation_frame, draw_upper, animation_tick
    )

static func _render_spec_for_name(
        asset_name: String,
        animation_frame: int = 0,
        draw_upper: bool = false,
        animation_tick: int = 0
    ) -> Dictionary:
    var key := _clean_asset_name(asset_name)
    if "pokedoll1" in key:key="pokedoll1" # Tile.init shares the disguise texture.
    if key.is_empty():
        return {}
    var texture_name := key
    if key.begins_with("hole1_"):
        # Logical holes retain Java's Y-up names; PNG openings are screen-up.
        var tokens := key.substr(6).split("[")[0]
        var mirrored := _mirror_vertical_cardinals(tokens)
        texture_name = "hole1_"
        for direction in ["n","s","e","w"]:
            if direction in mirrored: texture_name += direction
        for corner in ["ne","se","sw","nw"]:
            var original := _mirror_vertical_cardinals(corner)
            if "["+original+"]" in key: texture_name += "["+corner+"]"
    var region := Rect2(Vector2.ZERO, Vector2(16, 16))
    var draw_offset := Vector2.ZERO
    var use_full_texture := key in FULL_SOURCE_TEXTURES
    var animate_flower := key.begins_with("flower")
    var source_water_offsets := [0, 1, 2, 3, 2, 1]
    if key.begins_with("berrytree_"):
        var berry_parts := key.split("_")
        if berry_parts.size() >= 2:
            texture_name = "berrytree_%s" % String(berry_parts[1])
        region.size = Vector2(16, 32)
        if "full" in berry_parts:
            region.position.x = 32.0
        elif "empty" in berry_parts:
            region.position.x = 64.0
    elif key.begins_with("water") and not key.begins_with("waterfall"):
        region.position.x = float(source_water_offsets[
            posmod(animation_tick / 19, source_water_offsets.size())
        ])
    elif key == "lava1" or key.begins_with("lava1_"):
        texture_name = "lava_sheet1"
        var lava_directions := _mirror_vertical_cardinals(
            _direction_tokens(key)
        )
        region.position = Vector2(
            16 + (16 if "e" in lava_directions else 0)
                - (16 if "w" in lava_directions else 0),
            16 - (16 if "n" in lava_directions else 0)
                + (16 if "s" in lava_directions else 0)
        )
        var lava_phase := posmod(animation_tick / 20, 4)
        var lava_subframe := 0 if posmod(animation_tick, 20) < 3 else 1
        region.position.x += float(lava_phase * 96 + lava_subframe * 48)
    elif key.begins_with("waterfall1_") or key.begins_with("lavafall1_"):
        var lavafall := key.begins_with("lavafall")
        var inner := "inner" in key
        texture_name = (
            "lavafall_sheet2_inner" if lavafall and inner
            else "lavafall_sheet2" if lavafall
            else "waterfall_sheet2_inner" if inner
            else "waterfall_sheet2"
        )
        var multiplier := -1 if inner else 1
        var directions := _mirror_vertical_cardinals(_direction_tokens(key))
        region.position = Vector2(
            16 - multiplier * 16 * (1 if "e" in directions else 0)
                + multiplier * 16 * (1 if "w" in directions else 0),
            16 + multiplier * 16 * (1 if "n" in directions else 0)
                - multiplier * 16 * (1 if "s" in directions else 0)
        )
        if posmod(animation_tick, 40) >= 19:
            region.position.x += 48.0
    elif key == "campfire1":
        texture_name = "campfire1"
        region = Rect2(
            Vector2(16.0 if posmod(animation_tick, 80) >= 40 else 0.0, 0.0),
            Vector2(16, 20)
        )
        draw_offset.y = -4.0
    elif key == "torch1":
        texture_name = "torch_sheet1"
        region = Rect2(
            Vector2(16.0 if posmod(animation_tick, 80) >= 40 else 0.0, 60.0),
            Vector2(16, 20)
        )
        draw_offset.y = -4.0
    elif key.begins_with("ruins1_") and key not in [
            "ruins1_pillar1", "ruins1_pillar1_broken"]:
        texture_name = "ruins1_all"
        var ruins_directions := _mirror_vertical_cardinals(
            _direction_tokens(key)
        )
        region.position = Vector2(
            8 - (8 if "e" in ruins_directions else 0)
                + (8 if "w" in ruins_directions else 0),
            8 + (8 if "n" in ruins_directions else 0)
                - (8 if "s" in ruins_directions else 0)
        )
    elif "ledges3" in key:
        texture_name = (
            "ledges3snow" if "ledges3snow" in key
            else "ledges3volcano" if "ledges3volcano" in key
            else "ledges3"
        )
        if "inner" in key:
            texture_name += "_inner"
        elif "none" in key:
            texture_name += "_none"
        var ledge_directions := _mirror_vertical_cardinals(
            _cardinal_suffix(key)
        )
        region.position = Vector2(
            8 - (8 if "e" in ledge_directions else 0)
                + (8 if "w" in ledge_directions else 0),
            8 + (8 if "n" in ledge_directions else 0)
                - (8 if "s" in ledge_directions else 0)
        )
    elif key == "rock1_color":
        # The exact world preserves Java's Y-up coordinates on Godot's Y-down
        # canvas, so Java's +4 position becomes +4 screen pixels here.
        draw_offset.y = 4.0
    if key == "tree_savanna1" and draw_upper:
        draw_offset.x = -16.0
    var texture := texture_for(texture_name)
    if texture == null:
        return {}
    var texture_size := texture.get_size()
    if use_full_texture:
        region = Rect2(Vector2.ZERO, texture_size)
    elif animate_flower and texture_size.x >= 32.0:
        region.position.x = float(posmod(animation_frame, 2) * 16)
    region.position.x = clampf(region.position.x, 0.0, maxf(0.0, texture_size.x - 16.0))
    region.position.y = clampf(region.position.y, 0.0, maxf(0.0, texture_size.y - 16.0))
    if (
            not use_full_texture
            and not key.begins_with("berrytree_")
            and key not in ["campfire1", "torch1"]
        ):
        region.size = Vector2(minf(16.0, texture_size.x), minf(16.0, texture_size.y))
    if draw_upper and (key.begins_with("berrytree_") or key in ["tree1", "tree2", "tree4", "tree6", "tree7", "tree8"]):
        draw_offset.y = 16.0 - region.size.y
    return {
        "texture": texture,
        "region": region,
        "size": region.size,
        "offset": draw_offset
    }

static func _mirror_vertical_cardinals(directions: String) -> String:
    return directions.replace("n", "#").replace("s", "n").replace("#", "s")

static func _mirror_vertical_bracket_directions(directions: String) -> String:
    var mirrored := directions
    mirrored = mirrored.replace("[N]", "[#]")
    mirrored = mirrored.replace("[S]", "[N]")
    mirrored = mirrored.replace("[#]", "[S]")
    mirrored = mirrored.replace("[NE]", "[#E]")
    mirrored = mirrored.replace("[SE]", "[NE]")
    mirrored = mirrored.replace("[#E]", "[SE]")
    mirrored = mirrored.replace("[NW]", "[#W]")
    mirrored = mirrored.replace("[SW]", "[NW]")
    return mirrored.replace("[#W]", "[SW]")

static func _direction_tokens(asset_name: String) -> String:
    var suffix := asset_name.substr(asset_name.find("_") + 1).to_lower()
    return suffix.replace("inner", "")

static func _cardinal_suffix(asset_name: String) -> String:
    var tokens := asset_name.to_lower().split("_")
    for index in range(tokens.size() - 1, 0, -1):
        var token := String(tokens[index])
        if token in ["n", "s", "e", "w", "ne", "nw", "se", "sw", "nse", "nsw", "new", "sew", "nsew"]:
            return token
    return ""

static func make_tile(
        base_name: String,
        upper_name: String,
        route_name: String,
        level: int,
        biome_name: String
    ) -> Dictionary:
    return {
        "base": base_name,
        "upper": upper_name,
        "route": route_name,
        "level": level,
        "biome": biome_name,
        "water": is_water(base_name) or is_water(upper_name),
        "solid": is_base_solid(base_name) or is_upper_solid(upper_name),
        "ledge_direction": ledge_direction(base_name) if ledge_direction(base_name) != Vector2i.ZERO else ledge_direction(upper_name)
    }

# Lossless generator-facing tile record. GenIsland1 operates in 16-pixel Java
# coordinates; conversion to Godot cells happens only at the render boundary.
static func make_source_tile(
        tile_name: String,
        name_upper: String,
        pixel_position: Vector2i,
        color: bool = false,
        route_name: String = "",
        route_level: int = 0,
        biome_name: String = ""
    ) -> Dictionary:
    var tile := make_tile(tile_name, name_upper, route_name, route_level, biome_name)
    tile["name"] = tile_name
    tile["name_upper"] = name_upper
    tile["pixel_position"] = pixel_position
    tile["color"] = color
    tile["is_grass"] = is_grass(tile_name)
    tile["is_cuttable"] = is_cuttable(tile_name, name_upper)
    tile["is_headbuttable"] = is_headbuttable(tile_name, name_upper)
    tile["is_tidal"] = "_tidalwater" in tile_name
    tile["is_lava"] = tile_name.begins_with("lava")
    return tile

static func source_tile_copy(tile: Dictionary, pixel_position: Vector2i = Vector2i(2147483647, 2147483647)) -> Dictionary:
    var result := tile.duplicate(true)
    if pixel_position != Vector2i(2147483647, 2147483647):
        result["pixel_position"] = pixel_position
    return result

static func pixel_to_cell(pixel_position: Vector2i) -> Vector2i:
    assert(pixel_position.x % 16 == 0 and pixel_position.y % 16 == 0)
    return Vector2i(pixel_position.x / 16, pixel_position.y / 16)

static func texture_for(asset_name: String) -> Texture2D:
    if asset_name.is_empty():
        return null
    var key := _clean_asset_name(asset_name)
    if _texture_cache.has(key):
        return _texture_cache[key]
    if key.begins_with("hole1") and key.contains(String.chr(91)):
        var plain := key
        for corner in ["ne", "se", "sw", "nw"]: plain = plain.replace("[" + corner + "]", "")
        var base := texture_for(plain)
        if base == null: return null
        var image := base.get_image()
        image.convert(Image.FORMAT_RGBA8)
        # DynamicTextures.cacheHole uses these exact quadrants and color.
        for y in range(image.get_height()):
            for x in range(image.get_width()):
                var corner := ("n" if y < 10 else "s") + ("w" if x < 8 else "e")
                if "[" + corner + "]" in key: image.set_pixel(x, y, Color8(160,120,24))
        var composed := ImageTexture.create_from_image(image)
        _texture_cache[key] = composed
        return composed
    var exact_global_name := String(EXACT_GLOBAL_TEXTURES.get(key, ""))
    var direct_path := (
        EXACT_GLOBAL_ROOT.path_join(exact_global_name)
        if not exact_global_name.is_empty()
        else TILE_ROOT.path_join(String(ASSET_ALIASES.get(key, "%s.png" % key)))
    )
    if key.begins_with("hole1_"):
        direct_path = TILE_ROOT.path_join("hole1_" + key.substr(6).to_upper() + ".png")
    # Resolve authored filename case before probing ResourceLoader. Windows
    # accepts fence1_ne.png, but Android only has fence1_NE.png.
    _ensure_asset_index()
    if key.begins_with("fence"):
        var parts := key.split("_")
        var fence_file := String(parts[0]) + ("_" + String(parts[1]).to_upper() if parts.size() > 1 else "")
        direct_path = TILE_ROOT.path_join(fence_file + ".png")
    var rooted_tree := key in ["tree1", "tree2", "tree4", "tree6", "tree7", "tree8"] or key.begins_with("berrytree_")
    if rooted_tree:
        direct_path = TILE_ROOT.path_join(key + ".png")
    if not rooted_tree and not key.begins_with("fence") and exact_global_name.is_empty() and not ASSET_ALIASES.has(key) and _asset_index.has(key):
        direct_path = String(_asset_index[key])
    if ResourceLoader.exists(direct_path):
        var direct_texture := load(direct_path) as Texture2D
        if key in ["tree_large1_color", "tree_large4", "tree_fairy2"]:
            direct_texture = _clear_connected_tree_backdrop(
                direct_texture, key)
        _texture_cache[key] = direct_texture
        return direct_texture
    _ensure_asset_index()
    # Never prefix-match logical names. That made tree5 resolve to the
    # unrelated spooky/tree5 sheet and tree_large1_noSprite resolve to a
    # visible tree quadrant.
    var path := String(_asset_index.get(key, ""))
    var texture: Texture2D = null
    if not path.is_empty() and ResourceLoader.exists(path):
        texture = load(path) as Texture2D
    _texture_cache[key] = texture
    return texture

static func _clear_connected_tree_backdrop(
        texture: Texture2D, asset_name: String
    ) -> Texture2D:
    # Keep the source ground opaque so the moving map can never show through
    # a large tree.  Only replace tiny isolated grass-stipple components that
    # become blue under the night tint; outlined object pixels remain intact.
    var palettes := {
        "tree_large1_color": {
            "ground": [Color8(176, 248, 80), Color8(96, 200, 8)],
            "stipple": Color8(56, 56, 56)
        },
        "tree_large4": {
            "ground": [Color8(176, 248, 80), Color8(96, 200, 8)],
            "stipple": Color8(56, 56, 56)
        },
        "tree_fairy2": {
            "ground": [Color8(80, 184, 104), Color8(48, 136, 64)],
            "stipple": Color8(48, 56, 40)
        }
    }
    var image := texture.get_image()
    if image == null or image.is_empty() or not palettes.has(asset_name):
        return texture
    image.convert(Image.FORMAT_RGBA8)
    var palette := palettes[asset_name] as Dictionary
    var accepted := palette.ground as Array
    var width := image.get_width()
    var height := image.get_height()
    var stipple := palette.stipple as Color
    var component_visited: Dictionary = {}
    for y in range(height):
        for x in range(width):
            var start := Vector2i(x, y)
            if component_visited.has(start):
                continue
            var start_color := image.get_pixelv(start)
            if start_color.r8 != stipple.r8 or start_color.g8 != stipple.g8 or \
                    start_color.b8 != stipple.b8:
                continue
            var component: Array[Vector2i] = []
            var component_pending: Array[Vector2i] = [start]
            var touches_ground := false
            while not component_pending.is_empty():
                var component_cell: Vector2i = component_pending.pop_back()
                if component_cell.x < 0 or component_cell.y < 0 or \
                        component_cell.x >= width or component_cell.y >= height or \
                        component_visited.has(component_cell):
                    continue
                var component_color := image.get_pixelv(component_cell)
                if component_color.r8 != stipple.r8 or \
                        component_color.g8 != stipple.g8 or \
                        component_color.b8 != stipple.b8:
                    continue
                component_visited[component_cell] = true
                component.append(component_cell)
                for neighbor in [
                    component_cell + Vector2i.LEFT,
                    component_cell + Vector2i.RIGHT,
                    component_cell + Vector2i.UP,
                    component_cell + Vector2i.DOWN
                ]:
                    if neighbor.x < 0 or neighbor.y < 0 or \
                            neighbor.x >= width or neighbor.y >= height:
                        continue
                    var neighbor_color := image.get_pixelv(neighbor)
                    for ground_color in accepted:
                        var expected := ground_color as Color
                        if neighbor_color.r8 == expected.r8 and \
                                neighbor_color.g8 == expected.g8 and \
                                neighbor_color.b8 == expected.b8:
                            touches_ground = true
                            break
                    if not component_visited.has(neighbor):
                        component_pending.append(neighbor)
            if touches_ground and component.size() <= 12:
                for component_cell in component:
                    image.set_pixelv(component_cell, accepted[0] as Color)
    # The four pale footer pixels on the two green large-tree sheets are
    # background stipple, not trunk/canopy detail. They become bright blue
    # points under the night tint, so clear only those bottom-edge pixels.
    if asset_name in ["tree_large1_color", "tree_large4"]:
        var footer_glint := Color8(216, 248, 216)
        for y in range(maxi(0, height - 2), height):
            for x in range(width):
                var footer_pixel := image.get_pixel(x, y)
                if (
                        footer_pixel.r8 == footer_glint.r8
                        and footer_pixel.g8 == footer_glint.g8
                        and footer_pixel.b8 == footer_glint.b8
                    ):
                    image.set_pixel(x, y, accepted[0] as Color)
    return ImageTexture.create_from_image(image)

static func asset_path(asset_name: String) -> String:
    _ensure_asset_index()
    return String(_asset_index.get(_clean_asset_name(asset_name), ""))

static func is_water(asset_name: String) -> bool:
    var key := _clean_asset_name(asset_name)
    return (
        (key.begins_with("water") and not key.begins_with("waterfall"))
        or "_water" in key
    )

static func is_solid(asset_name: String) -> bool:
    return is_base_solid(asset_name)

static func is_base_solid(asset_name: String) -> bool:
    var key := _clean_asset_name(asset_name)
    if key.is_empty():
        return false
    if "__off" in key:
        return false
    if "__on" in key:
        return true
    if key in ["solid", "block1", "black1", "water1", "water2", "water2_edge1", "water3", "water5"]:
        return true
    # Tile.java's water6 branch marks water but deliberately leaves collision
    # false; pits/"solid" overlays can still make individual water6 tiles solid.
    if (((key.begins_with("water") and key != "water6")
            and not key.begins_with("waterfall"))
            or key.begins_with("lava")):
        return true
    if key in ["tree_large1", "tree_large2", "tree_large3", "tree_large4", "tree_large1_nosprite", "tree_fairy1", "tree_fairy2", "grass_fairy1", "grass_fairy2", "grass_fairy3"]:
        return true
    if key in ["bush1", "bush2", "tree_small1", "tree1", "tree2", "tree4", "tree5", "tree6", "tree7", "aloe_large1"]:
        return true
    if key in ["rock1", "rock2", "rock3", "rock5"] or key.begins_with("cactus"):
        return true
    if key.begins_with("ruins"):
        return "pillar" in key or "picture" in key or "wall" in key
    if key.begins_with("cave"):
        return not ("floor" in key or "ramp" in key or "door" in key)
    if key.begins_with("mountain"):
        if (
                "left" in key or "right" in key
                or "top" in key or "bottom" in key
            ):
            return false
        return not (key in ["mountain1", "mountain2", "mountain3", "mountain4", "mountain5", "mountain6"] or "inner" in key)
    if key in ["ledge1_corner_bl", "ledge1_corner_br", "ledge2_corner_tl", "ledge2_corner_tr", "ledge_grass_inside_tl", "ledge_grass_inside_tr"]:
        return true
    if "ledge" in key:
        return false
    if (key.begins_with("table")
            or key in ["tree_plant1", "pkmnmansion_statue1", "pkmnmansion_struct1", "pkmnmansion_shelf1", "pkmnmansion_shelf1_ns", "campfire1", "fence1", "fence2"]):
        return true
    if key.begins_with("building1_pokecenter") or key in ["building1_machine2", "statue1"]:
        return true
    for passable in ["door", "stairs", "ramp", "floor", "rug", "carpet", "cables", "path", "grass", "flower", "sand", "green", "snow", "ice", "desert", "soot", "bridge", "gate", "puddle", "stalagmite"]:
        if passable in key:
            return false
    for marker in [
        "tree", "rock", "cactus", "wall", "pillar", "statue", "shelf",
        "block", "machine", "pokecenter", "fossilreviver", "gravestone",
        "fence", "plant", "aloe", "rubble", "struct", "bush"
    ]:
        if marker in key:
            return true
    return false

static func is_upper_solid(asset_name: String) -> bool:
    var key := _clean_asset_name(asset_name)
    if key.is_empty():
        return false
    if "ledges3" in key:
        # Tile.java leaves one-direction and inner ledges passable, while
        # multi-direction outer corners are solid.
        var directions := _cardinal_suffix(key)
        return "inner" not in key and directions.length() != 1
    var passable := (
        "door" in key or "floor" in key or "tree_planted" in key
        or key == "berry_planted" or "gate" in key
        or key == "grass_planted" or "_cracked" in key
        or "ledges3" in key or "warp_tile" in key
        or "waterfall" in key or "grass" in key or "flower" in key
    )
    var result := not passable
    if "stairs" in key or key == "mewtwo_overworld_hidden":
        result = false
    if key in ["pokeball1", "ultraball1", "pokemon_mansion_key"]:
        result = true
    if key == "volcarona":
        result = false
    return result

static func is_grass(asset_name: String) -> bool:
    var key := _clean_asset_name(asset_name)
    return (
        key in [
            "grass1", "grass2", "grass3", "grass4", "grass_sand1",
            "grass_sand2", "grass_sand3", "desert2", "snow3", "soot1",
            "grass_savanna1", "grass_savanna2", "desert4_isgrass"
        ]
        or "_tidalwater" in key
        or "pkmnmansion_floor" in key
    )

static func is_cuttable(base_name: String, upper_name: String) -> bool:
    var base := _clean_asset_name(base_name)
    var upper := _clean_asset_name(upper_name)
    # M74.3.9.13 scoped rule: every logical grass* tile is both encounter
    # habitat and a CUT harvest target. Do not use is_grass() here because that
    # source flag intentionally also covers tidal water, soot, snow and mansion
    # floors for encounter routing; those are not literal cuttable grasses.
    var base_grass := base.begins_with("grass") and not base.begins_with("ledge_grass")
    var upper_grass := upper.begins_with("grass") and not upper.begins_with("ledge_grass")
    if base_grass or upper_grass:
        return true
    return (
        base in [
            "tree_large1", "tree_large1_nosprite", "bush1",
            "tree2", "tree5", "aloe_large1"
        ]
        or upper in [
            "bush2_color", "bush_savanna1", "tree2", "tree4", "tree6",
            "tree7", "tree8", "tree9", "tree_savanna1", "aloe_large1"
        ]
    )

static func is_headbuttable(base_name: String, upper_name: String) -> bool:
    var base := _clean_asset_name(base_name)
    var upper := _clean_asset_name(upper_name)
    return (
        base in ["bush1", "tree2", "tree4", "tree5", "tree6", "tree7"]
        or base.begins_with("cactus")
        or upper in [
            "bush2_color", "tree2", "tree4", "tree6", "tree7",
            "tree8", "tree9", "cactus1", "cactus2"
        ]
    )

static func puddle_texture_for(tile_name: String) -> Texture2D:
    if _puddle_texture_cache.has(tile_name):
        return _puddle_texture_cache[tile_name] as Texture2D
    var base_key := _clean_asset_name(tile_name).split(
        "_puddle1", false, 1)[0]
    base_key = base_key.replace("_tidaloff", "").replace("_tidalwater", "")
    base_key = String({
        "sand4": "sand1", "mountain4": "mountain1"
    }.get(base_key, base_key))
    var base_texture := texture_for(base_key)
    var sheet := texture_for("puddle_sheet1")
    if base_texture == null or sheet == null:
        return null
    var base_image := base_texture.get_image()
    var sheet_image := sheet.get_image()
    if base_image == null or sheet_image == null:
        return null
    var sky_image: Image = reflected_day_sky_image()
    if sky_image == null:
        return null

    var output := Image.create(16, 16, false, Image.FORMAT_RGBA8)
    var reflection_mask := PackedByteArray()
    reflection_mask.resize(256)
    var directions := _mirror_vertical_bracket_directions(tile_name)
    var north := "[N]" in directions
    var south := "[S]" in directions
    var east := "[E]" in directions
    var west := "[W]" in directions
    var quad_ne := Vector2i(40, 8)
    if east: quad_ne = Vector2i(8, 8)
    if north: quad_ne = Vector2i(24, 8)
    if north and east: quad_ne = Vector2i(56, 8)
    var quad_nw := Vector2i(32, 8)
    if west: quad_nw = Vector2i(0, 8)
    if north: quad_nw = Vector2i(16, 8)
    if north and west: quad_nw = Vector2i(48, 8)
    var quad_se := Vector2i(40, 0)
    if east: quad_se = Vector2i(8, 0)
    if south: quad_se = Vector2i(24, 0)
    if south and east: quad_se = Vector2i(56, 0)
    var quad_sw := Vector2i(32, 0)
    if west: quad_sw = Vector2i(0, 0)
    if south: quad_sw = Vector2i(16, 0)
    if south and west: quad_sw = Vector2i(48, 0)
    var sources := [quad_nw, quad_ne, quad_sw, quad_se]
    var offsets := [
        Vector2i(0, 0), Vector2i(8, 0),
        Vector2i(0, 8), Vector2i(8, 8)
    ]
    for quadrant in range(4):
        var source_origin: Vector2i = sources[quadrant]
        var source_y := 8 - source_origin.y
        for y in range(8):
            for x in range(8):
                var source := sheet_image.get_pixel(
                    source_origin.x + x, source_y + y)
                var destination: Vector2i = Vector2i(offsets[quadrant]) + \
                    Vector2i(x, y)
                var base := base_image.get_pixel(
                    destination.x % base_image.get_width(),
                    destination.y % base_image.get_height())
                var rgba := source.to_rgba32()
                if source.a <= 0.0 or rgba in [
                        0x383838ff, 0x70c0a000, 0x9098f800]:
                    output.set_pixelv(destination, base)
                elif rgba == 0x9b9b9bff:
                    # The puddle sheet marks reflected-sky pixels with this source
                    # swatch. Use the authored daytime sky texture itself rather than
                    # an invented replacement color. Sampling the complete 192x192
                    # source across the 16x16 puddle keeps the reflection visibly day.
                    var sky_x = clampi(
                        int(float(destination.x) / 15.0 * float(sky_image.get_width() - 1)),
                        0, sky_image.get_width() - 1)
                    var sky_y = clampi(
                        int(float(destination.y) / 15.0 * float(sky_image.get_height() - 1)),
                        0, sky_image.get_height() - 1)
                    output.set_pixelv(destination, sky_image.get_pixel(sky_x, sky_y))
                elif rgba == 0x9098f8ff:
                    base.a = 0.25
                    output.set_pixelv(destination, base)
                    reflection_mask[destination.y * 16 + destination.x] = 1
                else:
                    output.set_pixelv(destination, source)
    var texture := ImageTexture.create_from_image(output)
    _puddle_texture_cache[tile_name] = texture
    _puddle_reflection_mask_cache[tile_name] = reflection_mask
    return texture

static func puddle_reflection_mask(tile_name: String) -> PackedByteArray:
    if not _puddle_reflection_mask_cache.has(tile_name):
        puddle_texture_for(tile_name)
    return _puddle_reflection_mask_cache.get(tile_name, PackedByteArray())

static func puddle_reflects_at(tile_name: String, local_pixel: Vector2i) -> bool:
    if local_pixel.x < 0 or local_pixel.y < 0 or \
            local_pixel.x >= 16 or local_pixel.y >= 16:
        return false
    if not _puddle_reflection_mask_cache.has(tile_name):
        puddle_texture_for(tile_name)
    var mask = _puddle_reflection_mask_cache.get(tile_name)
    if not mask is PackedByteArray or (mask as PackedByteArray).size() < 256:
        return false
    return (mask as PackedByteArray)[local_pixel.y * 16 + local_pixel.x] != 0

static func ledge_direction(asset_name: String) -> Vector2i:
    var key := _clean_asset_name(asset_name)
    if "ledge" not in key and not key.begins_with("mountain"):
        return Vector2i.ZERO
    if "ledges3" in key:
        var directions := _cardinal_suffix(key)
        if directions.length() != 1:
            return Vector2i.ZERO
        # GenIsland1's suffix names the exposed side. Tile.java assigns the
        # permitted movement direction to the opposite cardinal direction.
        if directions == "n":
            return Vector2i.DOWN
        if directions == "s":
            return Vector2i.UP
        if directions == "w":
            return Vector2i.RIGHT
        if directions == "e":
            return Vector2i.LEFT
    if key.begins_with("mountain"):
        if "left" in key:
            return Vector2i.LEFT
        if "right" in key:
            return Vector2i.RIGHT
        if "top" in key:
            return Vector2i.UP
        if "bottom" in key:
            return Vector2i.DOWN
    if key.ends_with("_up"):
        return Vector2i.UP
    if key.ends_with("_down"):
        return Vector2i.DOWN
    if key.ends_with("_left"):
        return Vector2i.LEFT
    if key.ends_with("_right"):
        return Vector2i.RIGHT
    return Vector2i.ZERO

static func _ensure_asset_index() -> void:
    if not _asset_index.is_empty():
        return
    _index_directory(TILE_ROOT)

static func _index_directory(directory_path: String) -> void:
    var directory := DirAccess.open(directory_path)
    if directory == null:
        return
    directory.list_dir_begin()
    var entry := directory.get_next()
    while not entry.is_empty():
        if entry == "." or entry == "..":
            entry = directory.get_next()
            continue
        var path := directory_path.path_join(entry)
        if directory.current_is_dir():
            _index_directory(path)
        else:
            # Exported packs retain the import/remap sidecar, not the source PNG.
            # Keep the authored filename case when resolving the logical resource.
            var resource_path := path
            if entry.ends_with(".png.import") or entry.ends_with(".png.remap"):
                resource_path = path.get_basename()
            if resource_path.get_extension().to_lower() == "png":
                var key := _clean_asset_name(resource_path.get_file().get_basename())
                # Root tiles are the default source artwork. Biome/dungeon variants
                # with the same basename must never override them by enumeration order.
                if not _asset_index.has(key) or directory_path == TILE_ROOT:
                    _asset_index[key] = resource_path
        entry = directory.get_next()
    directory.list_dir_end()

static func _clean_asset_name(asset_name: String) -> String:
    return asset_name.get_file().get_basename().strip_edges().to_lower()

# Generated dungeon recipes from Tile.init; kept separate from overworld
# recipes because these plans convert the source Y-up layout to screen Y-down.
static func interior_render_spec(tile: SourceTile, upper: bool) -> Dictionary:
    # Tile.java: the right half is collision-only; the left machine is 32x32.
    if not upper and tile.name == "building1_pokecenter1_right":
        return _render_spec_for_name("blank")
    if not upper and tile.name == "building1_pokecenter1":
        return {"texture": texture_for("building1_pokecenter1"),
            "region": Rect2(0, 0, 32, 32), "offset": Vector2.ZERO}
    if upper and tile.name_upper == "building1_fossilreviver1":
        return {"texture": texture_for("building1_pc1"),
            "region": Rect2(0, 0, 16, 24), "offset": Vector2.ZERO}
    var base := tile.name
    var name := tile.name_upper if upper else base
    if upper and "pokedoll1" in name:name="pokedoll1"
    var region := Rect2(0, 0, 16, 16)
    if base == "mega_gengar_overworld1":
        return {"texture":load("res://assets/source_bosses/mgengar_overworld1.png") if upper else texture_for("blank"), "region":Rect2(0,0,16,16)}
    if base == "desert4_isGrass" and not upper:
        name = "desert4"
    elif base == "blank1" and not upper:
        name = "blank"
    elif base == "tree_plant1":
        name = "plant1" if upper else "green1"
        if upper: region.size.y = 32
    elif base in ["pkmnmansion_statue1", "pkmnmansion_struct1",
            "pkmnmansion_shelf1", "pkmnmansion_shelf1_NS"]:
        name = base if upper else "pkmnmansion_floor1"
    elif base == "cave1_regipedistal1":
        name = base if upper else "cave1_up1"
    elif base in ["cave1_regi1", "cave1_regi2", "cave1_regi3"] and not upper:
        name = "cave1_regi1"
        region = Rect2(0 if base == "cave1_regi1" else 128, 0, 32, 32)
    elif "ruins" in base and "pillar" in base:
        name = base if upper else "desert4"
    if name.is_empty():
        return {}
    var texture := texture_for(name)
    if name == "volcarona":
        texture = PokemonData.texture("volcarona", "overworld")
    if texture == null:
        return {}
    # TextureCache.getTileSprite uses the authored sprite height for furniture.
    # Source TextureCache.getTileSprite retains the full authored region.
    # The two blank1 cells beside the path are occupied by this 48px sprite.
    if name in ["ruins2_path1", "ruins2_volcarona_picture1"]:
        region.size = texture.get_size()
    if name in ["plant1", "pkmnmansion_statue1", "pkmnmansion_shelf1",
            "pkmnmansion_shelf1_NS", "ruins1_pillar1", "ruins1_pillar1_broken"]:
        region.size.y = texture.get_height()
    return {"texture": texture, "region": region}

# The 48x48 savanna sprite extends down from its stored anchor. Its trunk is
# the middle cell of the bottom row, not the canopy cell at the anchor.
# Return -1 for cells whose existing collision rules should be used unchanged.
## The tile at a key in either the overworld's WorldTileStore or a Dictionary.
static func tile_in(tiles, key: Vector2i) -> SourceTile:
    if tiles is WorldTileStore: return (tiles as WorldTileStore).tile(key)
    return (tiles as Dictionary).get(key) as SourceTile

static func savanna_trunk_collision(tiles, cell: Vector2i, pixel_keys: bool = true) -> int:
    var scale := 16 if pixel_keys else 1
    if tiles is WorldTileStore:
        # Hot (every cell of the collision build): read the arrays, no proxy.
        var store := tiles as WorldTileStore
        var savanna_id: int = store.string_ids.get("tree_savanna1", -1)
        if savanna_id < 0: return -1
        var anchor_index := store.index_of((cell + Vector2i(0, -2)) * scale)
        if anchor_index >= 0 and store.upper_ids[anchor_index] == savanna_id: return 1
        var own_index := store.index_of(cell * scale)
        if own_index >= 0 and store.upper_ids[own_index] == savanna_id:
            return 1 if is_base_solid(store.name_at(own_index)) else 0
        return -1
    var trunk_anchor := tile_in(tiles, (cell + Vector2i(0, -2)) * scale)
    if trunk_anchor != null and trunk_anchor.name_upper == "tree_savanna1":
        return 1
    var tile := tile_in(tiles, cell * scale)
    if tile != null and tile.name_upper == "tree_savanna1":
        return 1 if is_base_solid(tile.name) else 0
    return -1

# Like the big savanna tree, every berry tree has one solid trunk tile.
# Its canopy draws in front of grounded actors behind the trunk.
static func berry_tree_collision(tiles, cell: Vector2i, pixel_keys: bool = true) -> bool:
    if persim_crown_collision(tiles, cell, pixel_keys):
        return true
    var scale := 16 if pixel_keys else 1
    if tiles is WorldTileStore:
        var store := tiles as WorldTileStore
        var index := store.index_of(cell * scale)
        return index >= 0 and store.upper_ids[index] != 0 and store.upper_at(index).to_lower().begins_with("berrytree_")
    var tile := tile_in(tiles, cell * scale)
    return tile != null and not tile.name_upper.is_empty() and tile.name_upper.to_lower().begins_with("berrytree_")

# Retain the shared collision interface without a special Persim footprint.
static func persim_crown_collision(tiles, cell: Vector2i, pixel_keys: bool = true) -> bool:
    return false
