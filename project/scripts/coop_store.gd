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
    sync()
    _close_journal()
    world_id = id
    last_error = DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(directory.path_join(id)))
    return last_error

## The journal stays open between writes. Opening and closing it for every
## commit cost more than the write itself on Android's shared storage.
var _journal: FileAccess

## Group commit. append() only turns a commit into text and queues it; once a
## frame the queued lines are written and flushed together on a worker
## (_write_lines), as one flush. `queued` counts the lines handed in, `written`
## those known to be on disk. The host's transport holds back whatever it sends
## after a commit until written reaches it (coop_transport.gd journal): no
## player hears of a change a crash could still undo. A crash mid-batch leaves
## whole lines and at most one torn last line, which load_state cuts off; none
## of those commits had been answered.
var queued := 0
var written := 0
var _lines := PackedStringArray()
var _task := -1
var _job := {}
var _scheduled := false
## Set when a batch could not be written: no more commits are taken (transact
## answers save_failed) until a retry writes it; the journal is cut back to
## `_good_end` first, so a half-written batch never sits mid-file.
var _failed := false
var _good_end := -1

func _close_journal() -> void:
    _wait()
    if _journal != null:
        _journal.close()
        _journal = null

func _open_journal() -> bool:
    var path := directory.path_join(world_id).path_join("journal.jsonl")
    if _journal != null and _journal.get_path() == path and FileAccess.file_exists(path): return true
    if _journal != null: _journal.close()
    _journal = FileAccess.open(path, FileAccess.READ_WRITE if FileAccess.file_exists(path) else FileAccess.WRITE_READ)
    if _journal == null:
        last_error = FileAccess.get_open_error()
        return false
    if _good_end >= 0 and _good_end < _journal.get_length(): _journal.resize(_good_end)
    _good_end = -1
    _journal.seek_end()
    return true

## `gap` is how many unjournaled movement commits came before this one.
func append(commit: Dictionary, gap: int = 0) -> bool:
    if not valid_id(world_id) or _failed: return false
    var line := commit
    if gap > 0:
        line = commit.duplicate()
        line["gap"] = gap
    # Text now: the commit is the caller's and changes after this returns.
    _lines.append(JSON.stringify(line, "", true, true))
    queued += 1
    if not _scheduled:
        _scheduled = true
        _pump.call_deferred()
    return true

## True once the first `count` commits appended are on disk.
func has_written(count: int) -> bool:
    if written < count: _settle()
    return written >= count

func _pump() -> void:
    _scheduled = false
    _settle()
    _start(false)
    # Again next frame while a batch is on disk or lines wait for it.
    if (_task != -1 or not _lines.is_empty()) and not _scheduled:
        _scheduled = true
        (Engine.get_main_loop() as SceneTree).process_frame.connect(_pump, CONNECT_ONE_SHOT)

func _start(here: bool) -> void:
    if _lines.is_empty() or _task != -1 or not valid_id(world_id) or not _open_journal(): return
    _job = {"file":_journal,"lines":_lines,"end":queued,"start":_journal.get_position(),"error":OK}
    _lines = PackedStringArray()
    if here:
        _write_lines(_job)
        _finish()
    else:
        _task = WorkerThreadPool.add_task(_write_lines.bind(_job), false, "Online journal")

## On a worker: the batch's lines, then one flush. Touches only `job`.
static func _write_lines(job: Dictionary) -> void:
    var file: FileAccess = job.file
    for text in job.lines: file.store_line(JSON.stringify({"payload":text,"sha256":text.sha256_text()}))
    file.flush()
    job.error = file.get_error()

## True while no batch is on its way to disk: prepare() then ends the
## segment without waiting here for a flush.
func idle() -> bool:
    _settle()
    return _task == -1

func _settle() -> void:
    if _task != -1 and WorkerThreadPool.is_task_completed(_task): _wait()

func _wait() -> void:
    if _task == -1: return
    WorkerThreadPool.wait_for_task_completion(_task)
    _task = -1
    _finish()

func _finish() -> void:
    if _job.error == OK:
        written = _job.end
        _failed = false
    else:
        last_error = _job.error
        _failed = true
        _good_end = _job.start
        var lines: PackedStringArray = _job.lines
        lines.append_array(_lines)
        _lines = lines
        _journal.close()
        _journal = null
    _job = {}

## Everything appended so far written and flushed, here and now: before the
## journal is read, rotated or left, and when the app is about to be suspended.
func sync() -> bool:
    _wait()
    _start(true)
    return written == queued

## A world save, in two steps so the slow one runs off the game thread
## (coop_game.gd save_checkpoint): prepare() takes what to write and starts a
## new journal segment, on the game thread; write() writes and checks it, on
## any thread, while the game goes on adding to the new journal.
## The journal is a chain of segments, replayed in order on load (load_state),
## each commit at most once (by revision):
##   journal.previous.jsonl  the commits between world.json.bak and world.json
##   journal.folding.jsonl   the commits a save in progress is folding in
##   journal.jsonl           the commits since
## Every step below is a rename or a new file, so a crash at any point leaves
## a chain that loads with every commit written (server/world_save_test.gd
## stops after each step; journal_batch_test.gd kills a process saving).
func prepare(state, metadata: Dictionary) -> Dictionary:
    if not valid_id(world_id): return {}
    var home := directory.path_join(world_id)
    # The batch on its way to disk ends this segment. Lines still queued go
    # to the next one: their commits are in the state below too, and a load
    # skips them there.
    _close_journal()
    var journal := home.path_join("journal.jsonl")
    var folding := home.path_join("journal.folding.jsonl")
    # A folding segment left by a save that failed or was cut short stays
    # where it is, and so does the journal after it: the world.json this save
    # writes has both. A batch that could not be written is first cut off
    # (_open_journal), not moved.
    if not _failed and FileAccess.file_exists(journal) and not FileAccess.file_exists(folding):
        DirAccess.rename_absolute(journal, folding)
    return {"id":world_id,"home":home,
        "data":{"mode":"online","format":1,"id":world_id,"metadata":metadata.duplicate(true),"state":state.snapshot()}}

## world.json as a .pending file, read back and checked, the one it replaces
## kept as .bak; then the folding segment, which the new world.json has,
## becomes journal.previous.jsonl, which stays with the .bak for recovery.
## Touches only these files. `job.stop_after` (tests): return after that step,
## as if killed there.
static func write(job: Dictionary) -> Error:
    var stop := int(job.get("stop_after", 4))
    var path := String(job.home).path_join("world.json")
    var text := JSON.stringify(job.data, "", true, true)
    var error := _write_file(path, JSON.stringify({"payload":text,"sha256":text.sha256_text()}).to_utf8_buffer())
    if error != OK: return error
    if _read_file(path + ".pending", String(job.id)).is_empty(): return ERR_FILE_CORRUPT
    if stop < 2: return OK
    if FileAccess.file_exists(path):
        # A damaged world.json (the world was loaded from the .bak) must not
        # replace the good .bak: the new world, already checked, becomes it.
        var good := not _read_file(path, String(job.id)).is_empty()
        error = DirAccess.copy_absolute(path if good else path + ".pending", path + ".bak")
        if error != OK: return error
    if stop < 3: return OK
    error = DirAccess.rename_absolute(path + ".pending", path)
    if error != OK or stop < 4: return error
    var folding := String(job.home).path_join("journal.folding.jsonl")
    if not FileAccess.file_exists(folding): return OK
    return DirAccess.rename_absolute(folding, String(job.home).path_join("journal.previous.jsonl"))

## `bytes` into PATH.pending, flushed.
static func _write_file(path: String, bytes: PackedByteArray) -> Error:
    var file := FileAccess.open(path + ".pending", FileAccess.WRITE)
    if file == null: return FileAccess.get_open_error()
    file.store_buffer(bytes)
    file.flush()
    var error := file.get_error()
    file.close()
    return error

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
    for file_name in ["world.json", "host.save", "journal.folding.jsonl", "journal.jsonl"]:
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

## Bytes waiting to be replayed on the next load (in the current segment),
## without waiting here for a batch on its way to disk: it counts once written.
func journal_size() -> int:
    if not valid_id(world_id): return 0
    _settle()
    if _task != -1: return int(_job.get("start", 0))
    if _journal != null: return _journal.get_length()
    var file := FileAccess.open(directory.path_join(world_id).path_join("journal.jsonl"), FileAccess.READ)
    if file == null: return 0
    var length := file.get_length()
    file.close()
    return length

func _read(path: String) -> Dictionary:
    return _read_file(path, world_id)

static func _read_file(path: String, id: String) -> Dictionary:
    if not FileAccess.file_exists(path): return {}
    var parser := JSON.new()
    if parser.parse(FileAccess.get_file_as_string(path)) != OK: return {}
    var envelope = parser.data
    if not envelope is Dictionary or not envelope.get("payload") is String: return {}
    if envelope.payload.sha256_text() != envelope.get("sha256", ""): return {}
    var data = JSON.parse_string(envelope.payload)
    if not data is Dictionary or data.get("mode") != "online" or data.get("format") != 1 or data.get("id") != id: return {}
    return data

func load_state(state) -> Dictionary:
    sync()
    _close_journal()
    var path := directory.path_join(world_id).path_join("world.json")
    var data := _read(path)
    var backup=data.is_empty()
    if backup: data = _read(path + ".bak")
    if data.is_empty() or not state.restore(data.get("state", {})): return {}
    var journals:Array[String]=[]
    if backup:journals.append(path.get_base_dir().path_join("journal.previous.jsonl"))
    journals.append(path.get_base_dir().path_join("journal.folding.jsonl"))
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
