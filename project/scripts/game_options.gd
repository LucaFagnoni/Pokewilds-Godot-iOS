extends RefCounted

const DataPaths = preload("res://scripts/game_data_paths.gd")
static var PATH := "user://game.ini"
const LEGACY_PATH := "user://game_options.cfg"
const Files = preload("res://scripts/game_files.gd")
static var settings_error := ""
const DEFAULTS := {"music":100,"sound":100,"world_sound":100,"cries":100,"footsteps":100,"radial":true,"zoom":true,"minimap":true,"diagonal":true,"auto_run":false,"battle_animations":true,"held_emotes":true,"shiny_sparkles":true,"map_waypoint":true,"weather_events":true,"dark_mode":false,"circle_lights":false,"lofi_music":false,"hd_emotes":false,"gen3_overhaul":false,"ball_mechanics":true,"haptics":true,"fps_counter":false,"text_speed":0,"battery_saver":1,"frame":0,"button_layout":0,"game_speed":1.0}
const GAME_SPEEDS := [1.0, 1.5, 2.0, 3.0, 4.0]

static func _valid_type(key: String, value: Variant) -> bool:
    if key == "game_speed": return typeof(value) in [TYPE_INT, TYPE_FLOAT]
    return typeof(value) == typeof(DEFAULTS[key])

static var values: Dictionary = DEFAULTS.duplicate()
static var loaded := false
static var active_game := ""

static func _validated(cfg: ConfigFile) -> Dictionary:
    var next := DEFAULTS.duplicate()
    for key in DEFAULTS:
        var value = cfg.get_value("options", key, DEFAULTS[key])
        if not _valid_type(key, value): return {}
        next[key] = value
    next.music = clampi(int(next.music),0,100)
    next.sound = clampi(int(next.sound),0,100)
    if not cfg.has_section_key("options", "world_sound"): next.world_sound = next.sound
    next.world_sound = clampi(int(next.world_sound),0,100)
    if not cfg.has_section_key("options", "cries"): next.cries = next.sound
    next.cries = clampi(int(next.cries),0,100)
    next.footsteps = clampi(int(next.footsteps),0,100)
    next.text_speed = clampi(int(next.text_speed),0,2)
    next.battery_saver = clampi(int(next.battery_saver),0,2)
    next.game_speed = float(next.game_speed) if float(next.game_speed) in GAME_SPEEDS else 1.0
    next.frame = clampi(int(next.frame),0,123)
    next.button_layout = clampi(int(next.button_layout),0,1)
    return next

static func _read(path: String, cfg: ConfigFile) -> Error:
    var file := FileAccess.open(path, FileAccess.READ)
    if file == null: return FileAccess.get_open_error()
    if file.get_length() > 65536: return ERR_FILE_CORRUPT
    return cfg.parse(file.get_as_text())

static func _write(path: String, cfg: ConfigFile) -> Error:
    var bytes := ("; PokeWilds settings. Switches: true/false. Volumes: 0-100.\n; text_speed: 0=Default 1=Fast 2=Faster. battery_saver: 0=Off (60 FPS) 1=Auto 2=On (30 FPS). frame: 0-123 selects Type 1-124.\n; game_speed: 1, 1.5, 2, 3, or 4, speeds gameplay and all audio together.\n; button_layout: 0=Type 1 Nintendo, 1=Type 2 Xbox.\n" + cfg.encode_to_text()).to_utf8_buffer()
    if FileAccess.file_exists(path):
        var backup := Files.copy_file(path, path + ".bak")
        if backup != OK: return backup
    var err := Files.write_bytes(path, bytes)
    if err == OK and FileAccess.get_file_as_bytes(path) != bytes: return ERR_FILE_CANT_WRITE
    return err

static func load_settings() -> void:
    if loaded: return
    PATH = DataPaths.path("game.ini")
    loaded = true
    settings_error = ""
    var cfg := ConfigFile.new()
    var source := PATH if FileAccess.file_exists(PATH) else LEGACY_PATH
    if FileAccess.file_exists(source) and _read(source, cfg) == OK:
        var restored := _validated(cfg)
        if not restored.is_empty(): values = restored
    if not FileAccess.file_exists(PATH):
        for key in DEFAULTS: cfg.set_value("options", key, values[key])
        _write(PATH, cfg)
    var err := sync_folder()
    if err != OK: settings_error = "Cannot read game.ini. Using last local settings."

static func sync_folder() -> Error:
    var cfg := ConfigFile.new()
    var error := _read(PATH, cfg)
    if error != OK: return error
    var next := _validated(cfg)
    if next.is_empty(): return ERR_INVALID_DATA
    for key in next: cfg.set_value("options", key, next[key])
    error = _write(PATH, cfg)
    if error == OK: values = next
    return error

static func change(key: String, value: Variant) -> Error:
    if not DEFAULTS.has(key) or not _valid_type(key, value): return ERR_INVALID_PARAMETER
    var cfg := ConfigFile.new()
    var err := _read(PATH, cfg)
    if err != OK: return err
    # Preserve unknown sections/keys; an invalid edit is never overwritten.
    if _validated(cfg).is_empty(): return ERR_INVALID_DATA
    for name in values: cfg.set_value("options", name, values[name])
    cfg.set_value("options", key, value)
    var next := _validated(cfg)
    for name in next:
        cfg.set_value("options", name, next[name])
        if not active_game.is_empty():cfg.set_value("game:"+active_game,name,next[name])
    err = _write(PATH, cfg)
    if err != OK: return err
    values = next
    apply_audio()
    return OK

static func enabled(key: String) -> bool:
    return bool(values.get(key,true))

static func text_multiplier() -> float:
    return [1.0,2.0,4.0][int(values.text_speed)]

static func apply_audio() -> void:
    preload("res://scripts/game_clock.gd").set_speed(float(values.game_speed))
    for spec in [["Music","music"],["SFX","sound"],["WorldSFX","world_sound"],["Cries","cries"],["Footsteps","footsteps"]]:
        var index := AudioServer.get_bus_index(spec[0])
        if index < 0:
            AudioServer.add_bus()
            index = AudioServer.bus_count - 1
            AudioServer.set_bus_name(index,spec[0])
        var volume := int(values[spec[1]])
        AudioServer.set_bus_mute(index,volume==0)
        AudioServer.set_bus_volume_db(index,linear_to_db(maxf(0.001,volume/100.0)))

static func route_audio(player: AudioStreamPlayer) -> void:
    if AudioServer.get_bus_index("Cries") < 0: apply_audio()
    if player.get_meta("footstep", false):
        player.bus = "Footsteps"
        return
    var path := player.stream.resource_path.to_lower() if player.stream != null else ""
    if "/cries/" in path:
        player.bus = "Cries"
        return
    player.bus = "Music" if "music" in player.name.to_lower() or "/music/" in path else ("WorldSFX" if player.get_meta("world_sound", false) else "SFX")

const DarkMode = preload("res://scripts/dark_mode.gd")
static var base_frames: Dictionary = {}

static func frame_texture() -> Texture2D:
    var index := int(values.frame)
    if not base_frames.has(index): base_frames[index] = _original_frame_texture()
    var source: Texture2D = base_frames[index]
    return DarkMode.frame(source) if bool(values.get("dark_mode",false)) else source

static func _original_frame_texture() -> Texture2D:
    if int(values.frame) >= 2:
        return load("res://assets/menu_frames/type_%03d.png" % (int(values.frame)+1)) as Texture2D
    var atlas := AtlasTexture.new()
    if int(values.frame)==0:
        atlas.atlas = preload("res://assets/pokewilds_dialogue_border.png")
        atlas.region = Rect2(2,2,44,44)
    else:
        atlas.atlas = preload("res://assets/source_exact/global/textbox_bg1.png")
        atlas.region = Rect2(0,96,160,48)
    return atlas

static func style() -> StyleBoxTexture:
    var result := StyleBoxTexture.new()
    result.texture = frame_texture()
    result.texture_margin_left=8;result.texture_margin_right=8
    result.texture_margin_top=8;result.texture_margin_bottom=8
    result.axis_stretch_horizontal=1;result.axis_stretch_vertical=1
    return result

static func refresh_frames(node: Node) -> void:
    if node is Panel or node is PanelContainer:
        var old: StyleBox = node.get_theme_stylebox("panel")
        if old is StyleBoxTexture:
            var texture: Texture2D = DarkMode.original(old.texture)
            var base: Texture2D = texture.atlas if texture is AtlasTexture else texture
            if base != null and (base.resource_path.ends_with("pokewilds_dialogue_border.png") or base.resource_path.ends_with("textbox_bg1.png") or base.resource_path.begins_with("res://assets/menu_frames/")):
                var replacement: StyleBoxTexture = old.duplicate()
                replacement.texture = frame_texture()
                node.add_theme_stylebox_override("panel",replacement)
    elif node is NinePatchRect:
        var texture: Texture2D = DarkMode.original(node.texture)
        var base: Texture2D = texture.atlas if texture is AtlasTexture else texture
        if base != null and (base.resource_path.ends_with("pokewilds_dialogue_border.png") or base.resource_path.ends_with("textbox_bg1.png") or base.resource_path.begins_with("res://assets/menu_frames/")):
            node.texture = frame_texture()
            var margin := 8 if int(values.frame) >= 2 else 10
            node.patch_margin_left=margin;node.patch_margin_top=margin
            node.patch_margin_right=margin;node.patch_margin_bottom=margin
    for child in node.get_children(): refresh_frames(child)

static func restore_game_options(raw: Variant, game_name: String = "", fresh: bool = false) -> void:
    var cfg:=ConfigFile.new()
    _read(PATH,cfg)
    active_game=game_name.sha256_text() if not game_name.is_empty() else ""
    var section:="game:"+active_game
    var previous:=String(cfg.get_value("active_game","id",""))
    var selected:=ConfigFile.new()
    for key in DEFAULTS:
        var value=raw.get(key,DEFAULTS[key]) if raw is Dictionary else DEFAULTS[key]
        if not fresh and not active_game.is_empty():
            if previous==active_game:value=cfg.get_value("options",key,value)
            elif cfg.has_section(section):value=cfg.get_value(section,key,value)
        if not _valid_type(key,value):value=DEFAULTS[key]
        selected.set_value("options",key,value)
    values=_validated(selected)
    for key in values:
        cfg.set_value("options",key,values[key])
        if not active_game.is_empty():cfg.set_value(section,key,values[key])
    cfg.set_value("active_game","id",active_game)
    _write(PATH,cfg)
    apply_audio()

static func reset_launch_options() -> void:
    # Reset only the live title-screen state; keep saved game.ini sections intact.
    values = DEFAULTS.duplicate()
    for key in values:
        if typeof(values[key]) == TYPE_BOOL: values[key] = false
    active_game = ""
