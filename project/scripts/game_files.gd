extends RefCounted

# Shared files are explicit snapshots; private saves remain authoritative.
const CONFIG := "user://game_files.cfg"
const DEFAULT_ROOT := "user://game_files"
const MAGIC := "POKEWILDS_SAVE_1\n"
const MAX_FILE := 268435456
const MAX_TOTAL := 1073741824
const Cache = preload("res://scripts/source_world_cache.gd")
const WorldSaves = preload("res://scripts/world_saves.gd")
static var selected_root := ""
static var last_error := ""

static func root_path() -> String:
    if selected_root.is_empty():
        var cfg := ConfigFile.new()
        cfg.load(CONFIG)
        selected_root = str(cfg.get_value("files", "folder", DEFAULT_ROOT))
    return selected_root

static func path_in(folder: String, relative: String) -> String:
    if folder.begins_with("content://"):
        return folder + ("/" if "#" in folder else "#") + relative
    return folder.path_join(relative)

static func shared_path(relative: String) -> String:
    return path_in(root_path(), relative)

static func write_bytes(path: String, bytes: PackedByteArray) -> Error:
    # Android SAF FileAccess creates the relative directory hierarchy.
    if not path.begins_with("content://"):
        var err := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
        if err != OK: return err
    var file := FileAccess.open(path, FileAccess.WRITE)
    if file == null: return FileAccess.get_open_error()
    file.store_buffer(bytes)
    file.flush()
    var err := file.get_error()
    file.close()
    return err

static func setup_folder(folder: String) -> Error:
    if folder.is_empty(): return ERR_INVALID_PARAMETER
    var notes := {
        "mods/README.txt": "Reserved for future mod support. This folder is not loaded as mods in this release.\n",
        "saves/README.txt": "Use GAME FILES > EXPORT SAVES after saving in-game. Share the complete .pwsave file. On the receiving device choose IMPORT SAVE, then LOAD GAME. Exported files are snapshots, not live saves. Java saves are not compatible.\n",
        "README.txt": "PokeWilds shared game files\n\nsaves/: complete portable .pwsave snapshots, including neighboring world caches.\nmods/: reserved for later; no mod loading from this folder.\ngame.ini: edit while the game is closed, or choose RELOAD SETTINGS afterward. OPTIONS writes these same settings. Use true/false for switches; music/sound 0-100; text_speed 0=Default, 1=Fast, 2=Faster; frame 0=Type 1, 1=Type 2.\n\nChoose this folder again if it is moved or access is revoked. Private saves remain on the device. Export before uninstalling. Imported saves never overwrite existing saves or conflicting world caches.\n"
    }
    for relative in notes:
        var path := path_in(folder, relative)
        if FileAccess.file_exists(path): continue
        var err := write_bytes(path, str(notes[relative]).to_utf8_buffer())
        if err != OK: return err
    if folder.begins_with("content://"):
        if not Engine.has_singleton("AndroidRuntime"): return ERR_UNAVAILABLE
        var runtime = Engine.get_singleton("AndroidRuntime")
        if not runtime.has_method("updatePersistableUriPermission"): return ERR_UNAVAILABLE
        if not runtime.updatePersistableUriPermission(folder, true): return ERR_UNAUTHORIZED
    var cfg := ConfigFile.new()
    cfg.set_value("files", "folder", folder)
    var err := cfg.save(CONFIG)
    if err == OK: selected_root = folder
    return err

static func safe_name(world_name: String) -> String:
    var result := ""
    for ch in world_name.strip_edges().to_lower():
        if ch.is_valid_identifier() or ch.is_valid_int(): result += ch
        elif ch in [" ", "-", "_"]: result += "_"
    return "pokewilds" if result.is_empty() else result

static func save_valid(data: Variant) -> bool:
    if not data is Dictionary: return false
    if data.get("version") != 2 or not data.get("world_name") is String: return false
    if data.world_name.is_empty() or data.world_name.length() > 128: return false
    for key in ["world_seed", "world_size", "player_x", "player_y"]:
        if not (data.get(key) is int or data.get(key) is float): return false
        if not is_finite(float(data[key])): return false
    if int(data.world_size) < 0 or int(data.world_size) > 4: return false
    for key in ["inventory", "crafting_state", "adjacent_worlds", "pokemon_storage"]:
        if not data.get(key, {}) is Dictionary: return false
    if not data.get("caught_pokemon") is Array: return false
    var parties: Array = [data.caught_pokemon]
    parties.append_array(data.get("pokemon_storage", {}).values())
    for party in parties:
        if not party is Array: return false
        for mon in party:
            if not mon is Dictionary: return false
    for neighbor in data.get("adjacent_worlds", {}).values():
        if not neighbor is Dictionary or not neighbor.get("state", {}) is Dictionary: return false
        if not (neighbor.get("seed") is int or neighbor.get("seed") is float): return false
        if not (neighbor.get("size") is int or neighbor.get("size") is float): return false
        if int(neighbor.size) < 0 or int(neighbor.size) > 4: return false
    return true

static func required_caches(data: Dictionary) -> Dictionary:
    var result := {}
    var worlds: Array = [{"seed": data.world_seed, "size": data.world_size}]
    worlds.append_array(data.get("adjacent_worlds", {}).values())
    for entry in worlds:
        var path := Cache.cache_path(int(entry.seed), int(entry.size))
        result["world_cache/" + path.get_file()] = [int(entry.seed), int(entry.size)]
    return result

static func _copy_count(source: FileAccess, target: FileAccess, count: int) -> bool:
    while count > 0:
        var amount := mini(count, 1048576)
        var bytes := source.get_buffer(amount)
        if bytes.size() != amount: return false
        target.store_buffer(bytes)
        if target.get_error() != OK: return false
        count -= amount
    target.flush()
    return target.get_error() == OK

static func copy_file(source: String, target: String) -> Error:
    var input := FileAccess.open(source, FileAccess.READ)
    if input == null: return FileAccess.get_open_error()
    if not target.begins_with("content://"):
        var err := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(target.get_base_dir()))
        if err != OK: return err
    var output := FileAccess.open(target, FileAccess.WRITE)
    if output == null: return FileAccess.get_open_error()
    var success := _copy_count(input, output, input.get_length())
    input.close(); output.close()
    return OK if success else ERR_FILE_CANT_WRITE

static func export_save(save_path: String, destination: String) -> String:
    var data := WorldSaves.read_file(save_path)
    if not save_valid(data): return "Invalid save: " + save_path.get_file()
    var sources := {"save.json": save_path}
    for cache in required_caches(data): sources[cache] = "user://" + cache
    var entries: Array = []
    var total := 0
    for name in sources:
        var file := FileAccess.open(sources[name], FileAccess.READ)
        if file == null: return "Missing world data. Save was not exported: " + str(data.world_name)
        var length := file.get_length(); file.close()
        total += length
        if length <= 0 or length > MAX_FILE or total > MAX_TOTAL: return "Save exceeds transfer size limit."
        entries.append({"name": name, "size": length, "sha256": FileAccess.get_sha256(sources[name])})
    # Build completely on private storage before touching the chosen destination.
    var temporary := "user://export_" + str(Time.get_ticks_usec()) + ".tmp"
    var output := FileAccess.open(temporary, FileAccess.WRITE)
    if output == null: return "Cannot create transfer file."
    var header := JSON.stringify({"format": 1, "files": entries}).to_utf8_buffer()
    output.store_buffer(MAGIC.to_utf8_buffer()); output.store_32(header.size()); output.store_buffer(header)
    var success := true
    for entry in entries:
        var input := FileAccess.open(sources[entry.name], FileAccess.READ)
        if input == null or not _copy_count(input, output, int(entry.size)):
            success = false; break
        input.close()
    output.close()
    if success: success = copy_file(temporary, destination) == OK
    if success: success = FileAccess.get_sha256(temporary) == FileAccess.get_sha256(destination)
    DirAccess.remove_absolute(temporary)
    return "" if success else "Export failed. Check folder access and free storage."

static func export_all() -> String:
    if not DirAccess.dir_exists_absolute("user://saves"): return "No saved games yet. Save in-game first."
    var count := 0
    var stamp := str(int(Time.get_unix_time_from_system())) + "-" + str(Time.get_ticks_usec())
    for name in DirAccess.get_files_at("user://saves"):
        if not name.ends_with(".json"): continue
        var error := export_save("user://saves/" + name, shared_path("saves/" + name.get_basename() + "-" + stamp + ".pwsave"))
        if not error.is_empty(): return "%d exported. %s" % [count, error]
        count += 1
    return "%d saves exported. Share the .pwsave files." % count if count else "No saved games yet. Save in-game first."

static func import_save(path: String) -> String:
    var input := FileAccess.open(path, FileAccess.READ)
    if input == null: return "Cannot open selected save."
    if input.get_length() > MAX_TOTAL + 1048600: return "Save exceeds transfer size limit."
    if input.get_buffer(MAGIC.length()).get_string_from_utf8() != MAGIC: return "Choose a PokeWilds .pwsave export."
    var header_length := input.get_32()
    if header_length < 2 or header_length > 1048576 or header_length > input.get_length() - input.get_position(): return "Invalid save header."
    var manifest = JSON.parse_string(input.get_buffer(header_length).get_string_from_utf8())
    if not manifest is Dictionary or manifest.get("format") != 1 or not manifest.get("files") is Array: return "Unsupported save format."
    var entries: Array = manifest.files
    if entries.is_empty() or entries.size() > 1024: return "Invalid save file list."
    var names := {}; var total := 0
    for entry in entries:
        if not entry is Dictionary or not entry.get("name") is String or not entry.get("sha256") is String: return "Invalid save entry."
        if not (entry.get("size") is int or entry.get("size") is float): return "Invalid save length."
        var name: String = entry.name
        if names.has(name) or ".." in name or "\\" in name or ":" in name: return "Invalid or duplicate save path."
        if name != "save.json" and (not (name.begins_with("world_cache/exact_v2_") or name.begins_with("world_cache/exact_v3_")) or not name.ends_with(".bin") or name.count("/") != 1): return "Unexpected file in save."
        if int(entry.size) <= 0 or int(entry.size) > MAX_FILE or float(entry.size) != int(entry.size): return "Invalid save length."
        total += int(entry.size); names[name] = true
    if total > MAX_TOTAL or total != input.get_length() - input.get_position() or not names.has("save.json"): return "Incomplete save file."
    var staging := "user://transfer_" + str(Time.get_ticks_usec())
    var staged: Array[String] = []
    var failure := ""
    for entry in entries:
        var target := staging.path_join(entry.name)
        DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(target.get_base_dir()))
        var output := FileAccess.open(target, FileAccess.WRITE)
        if output == null: failure = "Cannot stage save. Check storage."; break
        staged.append(target)
        var success := _copy_count(input, output, int(entry.size)); output.close()
        if not success or FileAccess.get_sha256(target) != entry.sha256:
            failure = "Save is damaged or incomplete."; break
    input.close()
    if failure.is_empty(): failure = _install_staged(staging, names)
    for file in staged: DirAccess.remove_absolute(file)
    DirAccess.remove_absolute(staging.path_join("world_cache"))
    DirAccess.remove_absolute(staging)
    return "Save imported. Choose it in LOAD GAME." if failure.is_empty() else failure

static func _install_staged(staging: String, names: Dictionary) -> String:
    var save_path := staging.path_join("save.json")
    var data := WorldSaves.read_file(save_path)
    if not save_valid(data): return "Unsupported or invalid saved game."
    var required := required_caches(data)
    if names.size() != required.size() + 1: return "Save contains unexpected world data."
    var destination := "user://saves/" + safe_name(data.world_name) + ".json"
    if FileAccess.file_exists(destination):
        if FileAccess.get_sha256(destination) == FileAccess.get_sha256(save_path):
            return "This save already exists. Nothing was replaced."
        var original_name: String = data.world_name
        var suffix := 1
        while FileAccess.file_exists(destination):
            data.world_name = original_name + " Imported " + str(suffix)
            destination = "user://saves/" + safe_name(data.world_name) + ".json"
            suffix += 1
        if write_bytes(save_path, WorldSaves.encode(data)) != OK:
            return "Cannot prepare imported save name."
    for cache in required:
        if not names.has(cache): return "Save is missing a neighboring world."
        var cached := staging.path_join(cache)
        var file := FileAccess.open_compressed(cached, FileAccess.READ, FileAccess.COMPRESSION_ZSTD)
        if file == null: return "Invalid world cache."
        var valid: bool = file.get_32() == Cache.CACHE_MAGIC.length() and file.get_buffer(Cache.CACHE_MAGIC.length()).get_string_from_utf8() == Cache.CACHE_MAGIC and file.get_32() in [Cache.CACHE_VERSION, Cache.PACKED_VERSION] and file.get_64() == absi(required[cache][0]) and file.get_32() == required[cache][1]
        file.close()
        if not valid: return "World cache does not match its saved world."
        if FileAccess.file_exists("user://" + cache) and FileAccess.get_sha256(cached) != FileAccess.get_sha256("user://" + cache):
            return "Conflicting world cache. Nothing was replaced."
    var installed: Array[String] = []
    var failure := ""
    DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://world_cache"))
    DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://saves"))
    for cache in required:
        var target: String = "user://" + cache
        if FileAccess.file_exists(target): continue
        if DirAccess.rename_absolute(staging.path_join(cache), target) != OK:
            failure = "Cannot install world data."; break
        installed.append(target)
    # The save becomes visible to LOAD GAME only after every cache is present.
    if failure.is_empty() and DirAccess.rename_absolute(save_path, destination) != OK:
        failure = "Cannot install saved game."
    if not failure.is_empty():
        for target in installed: DirAccess.remove_absolute(target)
    return failure

