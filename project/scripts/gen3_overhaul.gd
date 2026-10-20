extends RefCounted

const PACK := "res://data/gen3_overhaul.pwmod"
const PACK_HASH := "af6d1e66300a3d2081fcc3325007ad1d5a6d0512268ea181cb2072bd848cbd11"
const CACHE := "user://builtin_gen3_overhaul.pwmod"
const TextureSwitch = preload("res://scripts/gen3_texture.gd")
static var enabled := false
static var proxies := {}
static var baseline := {}
static var replacements := {}
static var audio_baseline := {}
static var manifest := {}
static var user_paths := {}
static var user_species := {}
static var user_palettes := {}
static var frame_tables := {}
static var error := ""

static func initialize(overrides: Dictionary) -> void:
    if not manifest.is_empty(): return
    user_paths = overrides.duplicate()
    var reader := ZIPReader.new()
    if reader.open(PACK) != OK:
        error = "Built-in overhaul package is missing."
        return
    var parsed = JSON.parse_string(reader.read_file("mod.json").get_string_from_utf8())
    reader.close()
    if not parsed is Dictionary:
        error = "Built-in overhaul package is invalid."
        return
    manifest = parsed
    for path in manifest.get("resources",{}):
        if user_paths.has(path): continue
        var original: Resource = load(path)
        if original is Texture2D:
            var proxy := TextureSwitch.new()
            proxy.use(original)
            proxy.take_over_path(path)
            baseline[path] = original
            proxies[path] = proxy
        elif original is AudioStreamOggVorbis:
            baseline[path] = original
            audio_baseline[path] = original.packet_sequence
    # Battle animation pages crop the pack's frames in their own layout
    # (tools/convert_pack_battle_sheets.py); a user mod's page keeps the base one.
    var tables: Dictionary = manifest.get("battle_frame_tables",{})
    for key in tables:
        if (tables[key].pages as Array).all(func(page): return proxies.has(page)):
            frame_tables[key] = Marshalls.base64_to_raw(String(tables[key].frame_table))

## The pack's crops of a battle animation while it is on, else empty.
static func frame_table(key: String) -> PackedByteArray:
    return frame_tables.get(key, PackedByteArray()) if enabled else PackedByteArray()

static func apply(next: bool, tree: SceneTree) -> bool:
    # Builds without the pack (iOS) keep the original art instead of failing,
    # so saves and hosts with the option on still load.
    if next and not FileAccess.file_exists(PACK): next = false
    if enabled == next: return true
    if not error.is_empty(): return false
    var native := load("res://scripts/native_mod_pack.gd")
    if replacements.is_empty():
        user_species = native.species_patches.duplicate(true)
        user_palettes = native.palettes.duplicate(true)
        if not await _load_replacements(tree): return false
    var deadline := Time.get_ticks_usec()+6000
    for path in baseline:
        if proxies.has(path):
            proxies[path].use(replacements[path] if next else baseline[path])
        elif baseline[path] is AudioStreamOggVorbis:
            baseline[path].packet_sequence = replacements[path].packet_sequence if next else audio_baseline[path]
        if Time.get_ticks_usec() >= deadline:
            await tree.process_frame
            deadline = Time.get_ticks_usec()+6000
    native.species_patches = manifest.get("species",{}).duplicate(true) if next else {}
    for species in user_species:
        if not native.species_patches.has(species): native.species_patches[species] = {}
        native.species_patches[species].merge(user_species[species],true)
    native.palettes = manifest.get("palettes",{}).duplicate(true) if next else {}
    native.palettes.merge(user_palettes,true)
    enabled = next
    _clear_derived_art()
    # Tiles drawn from the shared sheet must be placed again with the new art.
    load("res://scripts/tile_sheet.gd").generation += 1
    return true

static func _clear_derived_art() -> void:
    var pokemon := load("res://scripts/pokemon_data.gd")
    pokemon._database.clear()
    pokemon._biome_species_cache.clear()
    pokemon._shiny_textures.clear()
    pokemon._shiny_palettes.clear()
    pokemon._overworld_layouts.clear()
    var terrain := load("res://scripts/source_world_data.gd")
    terrain._texture_cache.clear()
    terrain._puddle_texture_cache.clear()
    terrain._puddle_reflection_mask_cache.clear()
    terrain._reflected_day_sky_image = null
    terrain._reflected_day_sky_texture = null
    var dark := load("res://scripts/dark_mode.gd")
    dark.frame_cache.clear()
    dark.overlay_cache.clear()

# The built-in pack is validated when packaged. Decode it in bounded batches so
# first activation keeps the loading screen and Android event loop responsive.
static func _load_replacements(tree: SceneTree) -> bool:
    if not prepare_pack(): return false
    var reader := ZIPReader.new()
    if reader.open(CACHE if OS.get_name() == "Android" else PACK) != OK:
        error = "Cannot read built-in overhaul."
        return false
    var prepared := {}
    var deadline := Time.get_ticks_usec()+6000
    for path in baseline:
        var bytes := reader.read_file(String(manifest.resources[path]))
        var resource: Resource
        if proxies.has(path):
            var image := Image.new()
            if image.load_png_from_buffer(bytes) != OK:
                reader.close()
                error = "Cannot decode overhaul artwork."
                return false
            resource = ImageTexture.create_from_image(image)
        else:
            resource = AudioStreamOggVorbis.load_from_buffer(bytes)
            if resource == null:
                reader.close()
                error = "Cannot decode overhaul audio."
                return false
        prepared[path] = resource
        if Time.get_ticks_usec() >= deadline:
            await tree.process_frame
            deadline = Time.get_ticks_usec()+6000
    reader.close()
    replacements = prepared
    return true

static func prepare_pack() -> bool:
    # Only Android packs res:// in compressed APK assets; elsewhere read it in place.
    if OS.get_name() != "Android": return true
    # A ZIP inside compressed Android assets must not be repeatedly seeked.
    # Materialize one verified private cache, then read entries from that file.
    if FileAccess.file_exists(CACHE) and FileAccess.get_sha256(CACHE) == PACK_HASH:
        return true
    var bytes := FileAccess.get_file_as_bytes(PACK)
    var file := FileAccess.open(CACHE,FileAccess.WRITE)
    if file == null:
        error = "Cannot prepare overhaul cache. Check free storage."
        return false
    file.store_buffer(bytes)
    file.close()
    if FileAccess.get_sha256(CACHE) != PACK_HASH:
        error = "Overhaul cache verification failed. Check free storage."
        return false
    return true
