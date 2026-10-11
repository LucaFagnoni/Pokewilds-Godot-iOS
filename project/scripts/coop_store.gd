extends RefCounted
## Online files have their own directory and explicit format marker.
const Paths = preload("res://scripts/game_data_paths.gd")
const State = preload("res://scripts/coop_state.gd")
var directory := ""
var world_id := ""
var last_error := OK

func _init(base: String = "") -> void:
    directory = Paths.path("online_worlds") if base.is_empty() else base

static func valid_id(id: String) -> bool:
    if id.length() != 32: return false
    for character in id:
        if not character in "0123456789abcdef": return false
    return true

func open(id: String) -> Error:
    if not valid_id(id): return ERR_INVALID_PARAMETER
    _close_journal()
    world_id = id
    last_error = DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(directory.path_join(id)))
    return last_error

## The journal stays open between writes. Opening and closing it for every
## commit cost more than the write itself on Android's shared storage.
var _journal: FileAccess

func _close_journal() -> void:
    if _journal != null:
        _journal.close()
        _journal = null

## `gap` is how many unjournaled movement commits came before this one.
func append(commit: Dictionary, gap: int = 0) -> bool:
    if not valid_id(world_id): return false
    var path := directory.path_join(world_id).path_join("journal.jsonl")
    if _journal == null or _journal.get_path() != path or not FileAccess.file_exists(path):
        _close_journal()
        _journal = FileAccess.open(path, FileAccess.READ_WRITE if FileAccess.file_exists(path) else FileAccess.WRITE_READ)
        if _journal == null:
            last_error = FileAccess.get_open_error()
            return false
        _journal.seek_end()
    var line := commit
    if gap > 0:
        line = commit.duplicate()
        line["gap"] = gap
    var text := JSON.stringify(line, "", true, true)
    _journal.store_line(JSON.stringify({"payload":text,"sha256":text.sha256_text()}))
    _journal.flush()
    last_error = _journal.get_error()
    if last_error != OK: _close_journal()
    return last_error == OK

func save(state, metadata: Dictionary) -> Error:
    if not valid_id(world_id): return ERR_INVALID_PARAMETER
    var path := directory.path_join(world_id).path_join("world.json")
    var data := {"mode":"online","format":1,"id":world_id,
        "metadata":metadata.duplicate(true),"state":state.snapshot()}
    var text := JSON.stringify(data, "", true, true)
    var file := FileAccess.open(path + ".pending", FileAccess.WRITE)
    if file == null: return FileAccess.get_open_error()
    file.store_string(JSON.stringify({"payload":text,"sha256":text.sha256_text()}))
    file.flush()
    var error := file.get_error()
    file.close()
    if error != OK: return error
    if _read(path + ".pending").is_empty(): return ERR_FILE_CORRUPT
    if FileAccess.file_exists(path):
        error = DirAccess.copy_absolute(path, path + ".bak")
        if error != OK: return error
    error = DirAccess.rename_absolute(path + ".pending", path)
    if error != OK:return error
    # Only rotate after the replacement checkpoint is durable and verified.
    # The previous journal remains available with world.json.bak for recovery.
    _close_journal()
    var journal=path.get_base_dir().path_join("journal.jsonl")
    var previous=path.get_base_dir().path_join("journal.previous.jsonl")
    if FileAccess.file_exists(journal):
        if FileAccess.file_exists(previous):
            error=DirAccess.remove_absolute(previous)
            if error!=OK:return error
        error=DirAccess.rename_absolute(journal,previous)
        if error!=OK:return error
    return OK

const BACKUPS_KEPT := 5

## Copies the world's save files into a dated folder before a session starts
## and keeps the newest few. One bad save must never be able to cost a world
## or a character; the copies are small now that receipts are bounded.
func backup() -> void:
    if not valid_id(world_id): return
    var home := directory.path_join(world_id)
    if not FileAccess.file_exists(home.path_join("world.json")): return
    var root := home.path_join("backups")
    var target := root.path_join(Time.get_datetime_string_from_system().replace(":", "-"))
    if DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(target)) != OK: return
    for file_name in ["world.json", "host.save", "journal.jsonl"]:
        var source := home.path_join(file_name)
        if FileAccess.file_exists(source): DirAccess.copy_absolute(source, target.path_join(file_name))
    var listing := DirAccess.open(root)
    if listing == null: return
    var folders := listing.get_directories()
    folders.sort()
    while folders.size() > BACKUPS_KEPT:
        var oldest: String = folders[0]
        folders.remove_at(0)
        var old := DirAccess.open(root.path_join(oldest))
        if old != null:
            for file_name in old.get_files(): old.remove(file_name)
        listing.remove(oldest)

## Bytes waiting to be replayed on the next load.
func journal_size() -> int:
    if not valid_id(world_id): return 0
    if _journal != null: return _journal.get_length()
    var file := FileAccess.open(directory.path_join(world_id).path_join("journal.jsonl"), FileAccess.READ)
    if file == null: return 0
    var length := file.get_length()
    file.close()
    return length

func _read(path: String) -> Dictionary:
    if not FileAccess.file_exists(path): return {}
    var parser := JSON.new()
    if parser.parse(FileAccess.get_file_as_string(path)) != OK: return {}
    var envelope = parser.data
    if not envelope is Dictionary or not envelope.get("payload") is String: return {}
    if envelope.payload.sha256_text() != envelope.get("sha256", ""): return {}
    var data = JSON.parse_string(envelope.payload)
    if not data is Dictionary or data.get("mode") != "online" or data.get("format") != 1 or data.get("id") != world_id: return {}
    return data

func load_state(state) -> Dictionary:
    _close_journal()
    var path := directory.path_join(world_id).path_join("world.json")
    var data := _read(path)
    var backup=data.is_empty()
    if backup: data = _read(path + ".bak")
    if data.is_empty() or not state.restore(data.get("state", {})): return {}
    var journals:Array[String]=[]
    if backup:journals.append(path.get_base_dir().path_join("journal.previous.jsonl"))
    journals.append(path.get_base_dir().path_join("journal.jsonl"))
    for journal in journals:
        if not FileAccess.file_exists(journal):continue
        var file := FileAccess.open(journal, FileAccess.READ)
        if file == null: return {}
        var valid_end: int = 0
        var torn_tail := false
        while file.get_position() < file.get_length():
            var parser := JSON.new()
            var parse_error := parser.parse(file.get_line())
            var envelope = parser.data if parse_error == OK else null
            # A partial final write is not an acknowledged transaction.
            if not envelope is Dictionary or not envelope.get("payload") is String or envelope.payload.sha256_text() != envelope.get("sha256", ""):
                if file.get_position() < file.get_length():
                    last_error = ERR_FILE_CORRUPT
                    file.close()
                    return {}
                torn_tail = true
                break
            var commit = JSON.parse_string(envelope.payload)
            if not commit is Dictionary:
                last_error = ERR_FILE_CORRUPT
                file.close()
                return {}
            valid_end = file.get_position()
            if int(commit.get("revision", -1)) <= state.revision: continue
            # Movement commits are not journaled; the commit after them says
            # how many were skipped. Any other gap is a missing line.
            var skipped: int = int(commit.get("revision", -1)) - 1 - state.revision
            if skipped > 0 and skipped <= int(commit.get("gap", 0)): state.revision += skipped
            commit.erase("gap")
            if not state.apply_committed(commit):
                last_error = ERR_FILE_CORRUPT
                file.close()
                return {}
        file.close()
        if torn_tail:
            var repair := FileAccess.open(journal, FileAccess.READ_WRITE)
            if repair == null:
                last_error = FileAccess.get_open_error()
                return {}
            last_error = repair.resize(valid_end)
            repair.close()
            if last_error != OK: return {}
    return data.metadata
