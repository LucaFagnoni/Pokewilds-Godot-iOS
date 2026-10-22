# An online world save written off the game thread (coop_store.gd prepare,
# write, rotate) loses nothing: commits made while it is written stay in the
# journal; a crash before rotate() reloads with every commit once; and the
# .bak with the previous journal still holds everything.
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

func _init() -> void:
	var base := OS.get_temp_dir().path_join("world_save_test_%d" % Time.get_ticks_usec())
	var store := Store.new(base)
	store.open(ID)
	var state := State.new()
	state.enroll("host", {"name": "HOST"})
	state.commit_writer = store.append
	for value in 3: _commit(state, value)
	# A first save, then more commits, then one written while the game goes on.
	var job: Dictionary = store.prepare(state, {"world_name": "TEST"})
	check(Store.write(job) == OK and store.rotate(job) == OK, "first save")
	for value in range(3, 6): _commit(state, value)
	job = store.prepare(state, {"world_name": "TEST"})
	for value in range(6, 8): _commit(state, value)
	# Answered only once on disk (coop_store.gd group commit).
	check(not store.has_written(store.queued) and store.sync() and store.has_written(store.queued), "written as one batch")
	check(Store.write(job) == OK, "second save written")
	# Killed here, before rotate(): the journal still starts with commits the world has.
	_has_all(_loaded(base), 8, "killed before rotate")
	check(store.rotate(job) == OK, "rotated")
	var journal := FileAccess.get_file_as_string(base.path_join(ID).path_join("journal.jsonl"))
	check(journal.count("\n") == 2, "the journal keeps only the two commits made while writing")
	_has_all(_loaded(base), 8, "after rotate")
	# A damaged world.json: world.json.bak with the previous journal and the journal.
	_has_all(_loaded(base, true), 8, "from the .bak")
	print("WORLD SAVE TEST: %d failed" % failed)
	quit(1 if failed > 0 else 0)
