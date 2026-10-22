extends RefCounted
## The single-player save files: one <world>.json per world in `directory`,
## with index.cfg naming each world's file and the last one saved. The game's
## own saves (the app going to the background) go to <world>.autosave.json
## next to it, never over the player's SAVE; a SAVE removes the autosave it
## supersedes. A save is replaced atomically and the one before it kept as .bak
## (see write). Online worlds are stored elsewhere (coop_store.gd).
const DataPaths = preload("res://scripts/game_data_paths.gd")

var directory: String
var index_path: String
var cache_cleanup: Thread

func _init(saves_directory: String) -> void:
    directory = saves_directory
    index_path = saves_directory.path_join("index.cfg")

static func safe_world_filename(world_name: String) -> String:
    var clean = world_name.strip_edges().to_lower()
    if clean.is_empty():
        clean = "pokewilds"
    var result = ""
    for ch in clean:
        if ch.is_valid_identifier() or ch.is_valid_int():
            result += ch
        elif ch == " " or ch == "-" or ch == "_":
            result += "_"
    if result.is_empty():
        result = "pokewilds"
    return result

func path_for_world(world_name: String) -> String:
    return "%s/%s.json" % [directory, safe_world_filename(world_name)]

const AUTOSAVE_SUFFIX := ".autosave.json"

## World file names have no dots (safe_world_filename): an autosave is never a world's own save.
static func is_autosave(save_path: String) -> bool:
    return save_path.ends_with(AUTOSAVE_SUFFIX)

## The autosave next to a world's save (either of the two may be given).
static func autosave_path(save_path: String) -> String:
    return save_path if is_autosave(save_path) else save_path.trim_suffix(".json") + AUTOSAVE_SUFFIX

## The world's own save next to an autosave (either of the two may be given).
static func manual_path(save_path: String) -> String:
    return save_path.trim_suffix(AUTOSAVE_SUFFIX) + ".json" if is_autosave(save_path) else save_path

## When the file was last written, 0 if there is none.
static func saved_time(save_path: String) -> int:
    return int(FileAccess.get_modified_time(save_path)) if FileAccess.file_exists(save_path) else 0

## Removes a save with its .bak (it would bring the save back, see read) and .pending.
static func remove_save_files(save_path: String) -> Error:
    if FileAccess.file_exists(save_path):
        var error := DirAccess.remove_absolute(ProjectSettings.globalize_path(save_path))
        if error != OK: return error
    for leftover in [save_path + ".bak", save_path + ".pending"]:
        if FileAccess.file_exists(leftover): DirAccess.remove_absolute(ProjectSettings.globalize_path(leftover))
    return OK

func ensure_directory() -> bool:
    var absolute_dir = ProjectSettings.globalize_path(directory)
    var err = DirAccess.make_dir_recursive_absolute(absolute_dir)
    return err == OK or err == ERR_ALREADY_EXISTS

func indexed_path(stored: String) -> String:
    # Old indexes contain private/device-specific absolute paths. The selected
    # save directory is authoritative after migration or a drag-and-drop copy.
    return "" if stored.is_empty() else directory.path_join(stored.get_file())

func write_index(world_name: String, save_path: String) -> void:
    var cfg = ConfigFile.new()
    cfg.load(index_path)
    var key = safe_world_filename(world_name)
    # "worlds" names the player's own save; "last" may be the autosave (Continue).
    if not is_autosave(save_path):
        cfg.set_value("worlds", key, save_path.get_file())
    # A SAVE removes the autosave: one still there was made after it.
    var last := autosave_path(save_path) if FileAccess.file_exists(autosave_path(save_path)) else save_path
    cfg.set_value("last", "world_name", world_name)
    cfg.set_value("last", "save_path", last.get_file())
    cfg.save(index_path)

## Deletes a single-player world from the LOAD list's bin: its save, its
## autosave and their lines in the save index; with `autosave_only`, just the
## autosave. World caches no other save needs go after it.
func delete(world_name: String, save_path: String, autosave_only := false) -> Error:
    var removed := [autosave_path(save_path)] if autosave_only else [manual_path(save_path), autosave_path(save_path)]
    if not removed.any(func(path): return FileAccess.file_exists(path) or FileAccess.file_exists(path + ".bak")):
        return ERR_FILE_NOT_FOUND
    for path in removed:
        var error := remove_save_files(path)
        if error != OK: return error
    var names := removed.map(func(path): return String(path).get_file())
    var cfg := ConfigFile.new()
    if cfg.load(index_path) == OK:
        var key = safe_world_filename(world_name)
        if String(cfg.get_value("worlds", key, "")) in names: cfg.erase_section_key("worlds", key)
        if String(cfg.get_value("last", "save_path", "")) in names: cfg.erase_section("last")
        cfg.save(index_path)
    start_cache_cleanup()
    return OK

## Removes, on a thread, the world caches that no single-player save needs.
func start_cache_cleanup() -> void:
    wait_for_cache_cleanup()
    cache_cleanup = Thread.new()
    cache_cleanup.start(remove_unused_caches.bind(
        directory, DataPaths.path("world_cache"), int(Time.get_unix_time_from_system())))

func wait_for_cache_cleanup() -> void:
    if cache_cleanup != null:
        cache_cleanup.wait_to_finish()
        cache_cleanup = null

## A world cache (exact_v<version>_<seed>_<size>.bin, tens of MB) is kept while
## a save in `save_dir` is in that world or next to it. Files changed since
## `before` are kept too: they may be a world being made now.
static func remove_unused_caches(save_dir: String, cache_dir: String, before: int) -> void:
    if not DirAccess.dir_exists_absolute(save_dir):
        return # no list of saves: no way to tell what is unused
    var needed := {}
    for file_name in DirAccess.get_files_at(save_dir):
        if not file_name.to_lower().ends_with(".json"):
            continue
        var data := read(save_dir.path_join(file_name))
        if data.is_empty():
            continue
        needed["%d_%d" % [absi(int(data.get("world_seed", 0))), int(data.get("world_size", 0))]] = true
        var neighbors = data.get("adjacent_worlds", {})
        for neighbor in (neighbors.values() if neighbors is Dictionary else []):
            if neighbor is Dictionary:
                needed["%d_%d" % [absi(int(neighbor.get("seed", 0))), int(neighbor.get("size", 0))]] = true
    var cache_name := RegEx.create_from_string("^exact_v\\d+_(\\d+_\\d+)\\.bin$")
    for file_name in DirAccess.get_files_at(cache_dir):
        var found := cache_name.search(file_name)
        var path := cache_dir.path_join(file_name)
        if found != null and not needed.has(found.get_string(1)) and FileAccess.get_modified_time(path) < before:
            DirAccess.remove_absolute(path)

static func read(save_path: String) -> Dictionary:
    if save_path.is_empty():
        return {}
    # A save left broken (by a game from before saves were written safely)
    # falls back to the one before it.
    for candidate in [save_path, save_path + ".bak"]:
        if not FileAccess.file_exists(candidate):
            continue
        var parsed = JSON.parse_string(FileAccess.get_file_as_string(candidate))
        if parsed is Dictionary:
            return parsed
    return {}

## Writes a world's save so that a kill at any moment leaves the old save or
## the new one, never a cut one: the text goes to .pending and is read back,
## the old save is kept as .bak, then .pending takes its place. Runs on a
## thread for SAVE.
static func write(save_path: String, data: Dictionary) -> Error:
    var text := JSON.stringify(data)
    var pending := save_path + ".pending"
    var file := FileAccess.open(pending, FileAccess.WRITE)
    if file == null:
        return FileAccess.get_open_error()
    file.store_string(text)
    file.flush()
    var error := file.get_error()
    file.close()
    if error != OK:
        return error
    if FileAccess.get_file_as_string(pending) != text:
        return ERR_FILE_CORRUPT
    if FileAccess.file_exists(save_path):
        error = DirAccess.copy_absolute(save_path, save_path + ".bak")
        if error != OK:
            return error
    return DirAccess.rename_absolute(pending, save_path)

## The player's SAVE: written as `write`, then the autosave it supersedes goes.
## On the save's thread, so a background save made after it is never removed.
static func write_manual(save_path: String, data: Dictionary) -> Error:
    var error := write(save_path, data)
    if error == OK:
        remove_save_files(autosave_path(save_path))
    return error

## A world's save and its autosave (either may be given), the newer first. A
## SAVE removes the autosave: one still there is newer, in the same second too.
static func newer_first(save_path: String) -> Array:
    var both := [autosave_path(save_path), manual_path(save_path)]
    if saved_time(both[1]) > saved_time(both[0]):
        both.reverse()
    return both

## {"path", "data"} of the newest save that can be read, or {}.
func find_newest() -> Dictionary:
    if not ensure_directory():
        return {}

    var cfg := ConfigFile.new()
    if cfg.load(index_path) == OK:
        # The world played last, from its save or its autosave if that is newer.
        var last := indexed_path(String(cfg.get_value("last", "save_path", "")))
        for indexed in ([] if last.is_empty() else newer_first(last)):
            var indexed_data := read(indexed)
            if not indexed_data.is_empty():
                return {"path": indexed, "data": indexed_data}

    # Newest first: only saves that cannot be read are parsed before the answer.
    var candidates := []
    for file_name in DirAccess.get_files_at(directory):
        if file_name.to_lower().ends_with(".json"):
            var candidate := "%s/%s" % [directory, file_name]
            candidates.append([int(FileAccess.get_modified_time(candidate)), candidate])
    candidates.sort_custom(func(first: Array, second: Array) -> bool: return first[0] > second[0])
    for candidate in candidates:
        var data := read(candidate[1])
        if not data.is_empty():
            return {"path": candidate[1], "data": data}
    return {}

## {"path", "data"} of the save of `world_name`, or {}.
func find(world_name: String) -> Dictionary:
    if not ensure_directory():
        return {}

    # The world's save or its autosave, whichever is newer.
    var data := {}
    for direct_file in newer_first(path_for_world(world_name)):
        data = read(direct_file)
        if not data.is_empty():
            return {"path": direct_file, "data": data}

    var cfg := ConfigFile.new()
    if cfg.load(index_path) == OK:
        var key := safe_world_filename(world_name)
        var indexed := indexed_path(String(cfg.get_value("worlds", key, "")))
        data = read(indexed)
        if not data.is_empty():
            return {"path": indexed, "data": data}

        var last_name := String(cfg.get_value("last", "world_name", ""))
        var last_path := indexed_path(String(cfg.get_value("last", "save_path", "")))
        if world_name.strip_edges().is_empty() or last_name == world_name:
            data = read(last_path)
            if not data.is_empty():
                return {"path": last_path, "data": data}

    return find_newest()

## Every save that can be read, {"path", "data", "autosave"}: the LOAD list.
## Worlds come newest first, each world's own save followed by its autosave
## (a world only ever autosaved has just that one).
func entries() -> Array[Dictionary]:
    var result: Array[Dictionary] = []
    if not ensure_directory():
        return result
    var paths := {}
    var cfg := ConfigFile.new()
    if cfg.load(index_path) == OK and cfg.has_section("worlds"):
        for raw_key in cfg.get_section_keys("worlds"):
            var indexed := indexed_path(String(cfg.get_value("worlds", String(raw_key), "")))
            if not indexed.is_empty():
                paths[indexed] = true
                paths[autosave_path(indexed)] = true
    for file_name in DirAccess.get_files_at(directory):
        if file_name.to_lower().ends_with(".json"):
            paths["%s/%s" % [directory, file_name]] = true
    var worlds := {}
    for path in paths:
        var data := read(path)
        if data.is_empty():
            continue
        var world: Array = worlds.get_or_add(manual_path(path), [])
        var entry := {"path": path, "data": data, "autosave": is_autosave(path)}
        # The world's own save first, its autosave under it.
        if entry.autosave: world.append(entry)
        else: world.push_front(entry)
    var newest := func(world: Array) -> int:
        return world.map(func(entry): return saved_time(entry.path)).max()
    var ordered := worlds.values()
    ordered.sort_custom(func(first: Array, second: Array) -> bool: return newest.call(first) > newest.call(second))
    for world in ordered:
        result.append_array(world)
    return result
