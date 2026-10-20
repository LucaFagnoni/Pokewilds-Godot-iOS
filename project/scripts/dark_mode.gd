extends Node
const TexturePixels = preload("res://scripts/texture_pixels.gd")

# UI-only palette conversion. Cached once per texture; never affects world art.
const BACKGROUND := Color8(38,40,45)
const INK := Color8(201,176,232)
const STATS_INK := Color8(171,150,197)
static var frame_cache: Dictionary = {}
static var original_frames: Dictionary = {}
static var overlays: Dictionary = {}
static var overlay_cache: Dictionary = {}
static var overlay_originals: Dictionary = {}
static var font_cache: Dictionary = {}
var ui: Node
var active := false
# Until dark mode is first switched on nothing has been recoloured, so the
# per-redraw hook has nothing to restore.
var ever_active := false
var updating := false

static func frame(texture: Texture2D) -> Texture2D:
    if texture == null: return null
    var key := texture.get_rid().get_id()
    if original_frames.has(key): return texture
    if frame_cache.has(key): return frame_cache[key]
    var pixels: Image = TexturePixels.of(texture).duplicate()
    for y in range(pixels.get_height()):
        for x in range(pixels.get_width()):
            var c := pixels.get_pixel(x,y)
            if c.a == 0.0: continue
            var result := c
            if c.v > 0.72 and c.s < 0.27:
                result = BACKGROUND
            elif c.v < 0.24:
                result = INK.darkened(0.3)
            result.a = c.a
            pixels.set_pixel(x,y,result)
    var result := ImageTexture.create_from_image(pixels)
    frame_cache[key] = result
    original_frames[result.get_rid().get_id()] = texture
    return result

static func original(texture: Texture2D) -> Texture2D:
    if texture == null: return null
    return original_frames.get(texture.get_rid().get_id(),texture)

static func light_font(source: FontFile) -> FontFile:
    var key := source.get_instance_id()
    if font_cache.has(key): return font_cache[key]
    var result: FontFile = source.duplicate(true)
    for cache in range(result.get_cache_count()):
        for size in result.get_size_cache_list(cache):
            for index in range(result.get_texture_count(cache,size)):
                var pixels: Image = result.get_texture_image(cache,size,index).duplicate()
                pixels.convert(Image.FORMAT_RGBA8)
                for y in range(pixels.get_height()):
                    for x in range(pixels.get_width()):
                        pixels.set_pixel(x,y,Color(1,1,1,pixels.get_pixel(x,y).a))
                result.set_texture_image(cache,size,index,pixels)
    font_cache[key] = result
    return result

func configure(root: Node) -> void:
    ui = root
    get_tree().node_added.connect(_added)
    _watch(ui)

func set_enabled(value: bool) -> void:
    active = value
    ever_active = ever_active or value
    _walk(ui)

func _added(node: Node) -> void:
    if ui != null and ui.is_ancestor_of(node):
        _watch_id.call_deferred(node.get_instance_id())

func _watch_id(id: int) -> void:
    var node := instance_from_id(id)
    if is_instance_valid(node) and node is Node: _watch(node)

func _watch(node: Node) -> void:
    if not is_instance_valid(node) or not node.is_inside_tree(): return
    if node is Control and not node.draw.is_connected(_apply.bind(node)):
        node.draw.connect(_apply.bind(node))
    _apply(node)
    for child in node.get_children(): _watch(child)

func _walk(node: Node) -> void:
    if not is_instance_valid(node): return
    _apply(node)
    for child in node.get_children(): _walk(child)

func _overlay(texture: Texture2D) -> Texture2D:
    if texture == null: return null
    if overlays.is_empty():
        overlays = JSON.parse_string(FileAccess.get_file_as_string("res://data/dark_mode_assets.json"))
    if texture is AtlasTexture:
        var atlas := _overlay(texture.atlas)
        if atlas == texture.atlas: return texture
        var key := str(texture.get_rid().get_id()) + str(texture.region)
        if not overlay_cache.has(key):
            var replacement: AtlasTexture = texture.duplicate()
            replacement.atlas = atlas
            overlay_cache[key] = replacement
            overlay_originals[replacement.get_rid().get_id()] = texture
        return overlay_cache[key]
    if "arrow" in texture.resource_path:
        return frame(texture)
    if overlays.has(texture.resource_path):
        var replacement := load(String(overlays[texture.resource_path])) as Texture2D
        overlay_originals[replacement.get_rid().get_id()] = texture
        return replacement
    return texture

func _apply(node: Node) -> void:
    if not ever_active or updating or not is_instance_valid(node): return
    updating = true
    if node is LineEdit or node is Button:
        if not node.has_meta("dark_original_font"):
            node.set_meta("dark_original_font",node.get_theme_font("font"))
            var colors := {}
            for key in ["font_color","font_hover_color","font_pressed_color","font_focus_color","font_hover_pressed_color","font_disabled_color","font_placeholder_color","caret_color"]:
                colors[key] = node.get_theme_color(key)
            node.set_meta("dark_original_control_colors",colors)
        var source_font: Font = node.get_meta("dark_original_font")
        var desired_font: Font = light_font(source_font) if active and source_font is FontFile else source_font
        if node.get_theme_font("font") != desired_font: node.add_theme_font_override("font",desired_font)
        var original_colors: Dictionary = node.get_meta("dark_original_control_colors")
        for key in original_colors:
            var desired_color: Color = INK if active else original_colors[key]
            if node.get_theme_color(key) != desired_color: node.add_theme_color_override(key,desired_color)
    elif node is Label:
        if not node.has_meta("dark_original_font"):
            node.set_meta("dark_original_font",node.get_theme_font("font"))
        var source_font: Font = node.get_meta("dark_original_font")
        var desired_font: Font = light_font(source_font) if active and source_font is FontFile else source_font
        if node.get_theme_font("font") != desired_font: node.add_theme_font_override("font",desired_font)
        if not node.has_meta("dark_original_ink"):
            node.set_meta("dark_original_ink",node.get_theme_color("font_color"))
        var original_ink: Color = node.get_meta("dark_original_ink")
        var loading_sky := "GenerationPanel" in String(node.get_path()) and node.name != "Status"
        var desired := (Color(0.27,0.20,0.36) if loading_sky else INK) if active else original_ink
        if active and "/PokemonStatsOverlay/" in String(node.get_path()):desired=STATS_INK
        # The three stat pages keep their bright pink, green and blue panels in
        # dark mode, so text on them stays black; light ink was unreadable there.
        if active and "/StatsPage" in String(node.get_path()):desired=Color.BLACK
        if node.get_theme_color("font_color") != desired:
            node.add_theme_color_override("font_color",desired)
        # Some labels are inked by a near-black modulate instead of a font
        # colour (the battle text). That tint would turn the light text black.
        if not node.has_meta("dark_original_modulate"):
            node.set_meta("dark_original_modulate",node.modulate)
        var original_tint: Color = node.get_meta("dark_original_modulate")
        if original_tint.v < 0.3:
            var tint := Color(1,1,1,node.modulate.a) if active else Color(original_tint.r,original_tint.g,original_tint.b,node.modulate.a)
            if node.modulate != tint: node.modulate = tint
    elif node is RichTextLabel:
        # The NEED box and other rich text: same treatment as a plain label.
        if not node.has_meta("dark_original_font"):
            node.set_meta("dark_original_font",node.get_theme_font("normal_font"))
            node.set_meta("dark_original_ink",node.get_theme_color("default_color"))
        var rich_font: Font = node.get_meta("dark_original_font")
        var wanted_font: Font = light_font(rich_font) if active and rich_font is FontFile else rich_font
        if node.get_theme_font("normal_font") != wanted_font: node.add_theme_font_override("normal_font",wanted_font)
        var wanted_ink: Color = INK if active else node.get_meta("dark_original_ink")
        if node.get_theme_color("default_color") != wanted_ink: node.add_theme_color_override("default_color",wanted_ink)
    elif node is ColorRect:
        var node_path := String(node.get_path()).to_lower()
        # Battle entry/commands own the theme color; attack effects temporarily
        # own it during playback. Do not overwrite their color on draw.
        if node_path.ends_with("/battlepanel/background"):
            updating = false
            return
        # Animation overlays retain their own colors and changing opacity.
        if "transition" in node_path or "flash" in node_path or "fade" in node_path or "weatheroverlay" in node_path or ("progressionoverlay" in node_path and not node_path.ends_with("/progressionoverlay/backdrop")):
            updating = false
            return
        if not node.has_meta("dark_original_color"): node.set_meta("dark_original_color",node.color)
        var original_color: Color = node.get_meta("dark_original_color")
        if original_color.r > 0.9 and original_color.g > 0.9 and original_color.b > 0.9:
            var desired := BACKGROUND if active else original_color
            desired.a = original_color.a
            if node.color != desired: node.color = desired
        elif node.size.y <= 2 and original_color == Color.BLACK:
            var desired := INK if active else original_color
            if node.color != desired: node.color = desired
    elif node is TextureButton:
        for key in ["texture_normal","texture_hover","texture_pressed","texture_disabled","texture_focused"]:
            var source: Texture2D = node.get(key)
            if source == null or source.get_width()>16 or source.get_height()>16: continue
            if not node.has_meta("dark_"+key): node.set_meta("dark_"+key,source)
            source = node.get_meta("dark_"+key)
            var desired: Texture2D = preload("res://scripts/menu_symbol_palette.gd").recolor(source,INK) if active else source
            if node.get(key) != desired: node.set(key,desired)
    elif node is TextureRect:
        var tick := "cursor" in String(node.name).to_lower() or "arrow" in String(node.name).to_lower() or "tick" in String(node.name).to_lower()
        if tick:
            if node.texture == null:
                updating = false
                return
            var source: Texture2D = node.get_meta("tick_source",node.texture)
            if node.texture != source and node.texture != node.get_meta("tick_dark",null): source = node.texture
            source = overlay_originals.get(source.get_rid().get_id(),original(source))
            node.set_meta("tick_source",source)
            var desired: Texture2D = preload("res://scripts/menu_symbol_palette.gd").recolor(source,INK) if active else source
            if active: node.set_meta("tick_dark",desired)
            if node.texture != desired: node.texture = desired
            updating = false
            return
        if node.texture != null and not node.has_meta("dark_overlay"):
            var source: Texture2D = overlay_originals.get(node.texture.get_rid().get_id(),original(node.texture))
            if source != node.texture:
                node.set_meta("dark_original_texture",source)
                node.set_meta("dark_overlay",node.texture)
        if node.has_meta("dark_overlay") and node.texture == node.get_meta("dark_overlay"):
            if not active: node.texture = node.get_meta("dark_original_texture")
        elif active:
            var replacement := _overlay(node.texture)
            if replacement != node.texture:
                node.set_meta("dark_original_texture",node.texture)
                node.set_meta("dark_overlay",replacement)
                node.texture = replacement
    updating = false
