# An online world save written off the game thread (coop_store.gd prepare,
# write) loses nothing, wherever it is cut short: prepare() starts a new
# journal segment for the commits made while the save is written; a crash
# after any step of a save (the new segment, the .pending file, the .bak copy,
# the rename, the folding segment kept as journal.previous.jsonl) reloads with
# every commit once, from world.json or, with world.json damaged, from the
# .bak and the journal before it; and the next save after such a crash folds
# in whatever segment it left. journal_batch_test.gd kills a real process.
# Run: godot --headless --path project -s ../server/world_save_test.gd
extends SceneTree

const State = preload("res://scripts/coop_state.gd")
const Store = preload("res://scripts/coop_store.gd")
const ID := "0123456789abcdef0123456789abcdef"

var failed := 0
var serial := 0

func check(ok: bool, what: String) -> void:
	if not ok:
		failed += 1
		printerr("WORLD SAVE TEST FAIL: ", what)

func _commit(state, value: int) -> void:
	serial += 1
	check(state.transact("host", "c%d" % serial, [state.change("note/%d" % value, value)]).get("ok", false), "commit %d" % value)

func _loaded(base: String, damage_world := false) -> State:
	var store := Store.new(base)
	store.open(ID)
	if damage_world:
		var file := FileAccess.open(base.path_join(ID).path_join("world.json"), FileAccess.WRITE)
		file.store_string("{")
		file.close()
	var state := State.new()
	check(not store.load_state(state).is_empty(), "loads")
	return state

func _has_all(state, count: int, what: String) -> void:
	for value in count: check(state.records.get("note/%d" % value) == value, "%s: commit %d" % [what, value])
	check(state.revision == count, "%s: revision %d, not %d" % [what, state.revision, count])

func _lines(base: String, file_name: String) -> int:
	return FileAccess.get_file_as_string(base.path_join(ID).path_join(file_name)).count("\n")

## Two whole saves, then a third cut short after `step` (0: only prepare()),
## with commits before, between and while it is written.
func _world(base: String, step: int) -> void:
	var store := Store.new(base)
	store.open(ID)
	var state := State.new()
	state.enroll("host", {"name": "HOST"})
	state.commit_writer = store.append
	for value in 3: _commit(state, value)
	store.sync()
	check(Store.write(store.prepare(state, {"world_name": "TEST"})) == OK, "first save")
	for value in range(3, 6): _commit(state, value)
	store.sync()
	check(Store.write(store.prepare(state, {"world_name": "TEST"})) == OK, "second save")
	for value in range(6, 9): _commit(state, value)
	store.sync()
	var job: Dictionary = store.prepare(state, {"world_name": "TEST"})
	for value in range(9, 11): _commit(state, value)
	# Answered only once on disk (coop_store.gd group commit).
	check(not store.has_written(store.queued) and store.sync() and store.has_written(store.queued), "written as one batch")
	if step > 0:
		job["stop_after"] = step
		check(Store.write(job) == OK, "third save to step %d" % step)
	store._close_journal()

func _init() -> void:
	var root := OS.get_temp_dir().path_join("world_save_test_%d" % Time.get_ticks_usec())
	for step in range(5):
		for damaged in [false, true]:
			var what := "killed after step %d%s" % [step, ", world.json damaged" if damaged else ""]
			var base := root.path_join("%d_%s" % [step, damaged])
			_world(base, step)
			var state := _loaded(base, damaged)
			_has_all(state, 11, what)
			# Played on from there: the next save folds in what the cut one left.
			var store := Store.new(base)
			store.open(ID)
			state.enroll("host", {"name": "HOST"})
			state.commit_writer = store.append
			_commit(state, 11)
			store.sync()
			check(Store.write(store.prepare(state, {"world_name": "TEST"})) == OK, "%s: the next save" % what)
			_commit(state, 12)
			store.sync()
			store._close_journal()
			_has_all(_loaded(base), 13, what + ", saved again")
			# A damaged world.json never replaces the .bak: the next save makes the .bak good again.
			_has_all(_loaded(base, true), 13, what + ", saved again, from the .bak")
	# A whole save leaves in the journal only what came after it began.
	var base := root.path_join("whole")
	_world(base, 4)
	check(_lines(base, "journal.jsonl") == 2, "the journal keeps only the two commits made while writing")
	check(_lines(base, "journal.previous.jsonl") == 3, "the segment folded in is kept for the .bak")
	check(not FileAccess.file_exists(base.path_join(ID).path_join("journal.folding.jsonl")), "no folding segment after a whole save")
	print("WORLD SAVE TEST: %d failed" % failed)
	quit(1 if failed > 0 else 0)
