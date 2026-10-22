# The online journal's group commit (coop_store.gd): commits are written once a
# frame on a worker and nothing sent after a commit leaves before it is on disk
# (coop_transport.gd journal). A host process committing hundreds of times a
# frame is killed mid-batch, again and again; each time the world loads, has
# every commit it acknowledged, and goes on from there.
# Run: godot --headless --path project -s ../server/journal_batch_test.gd
extends SceneTree

const State = preload("res://scripts/coop_state.gd")
const Store = preload("res://scripts/coop_store.gd")
const Transport = preload("res://scripts/coop_transport.gd")
const ID := "0123456789abcdef0123456789abcdef"
const PER_FRAME := 200
const KILLS := 6

var failed := 0

func check(ok: bool, what: String) -> void:
	if not ok:
		failed += 1
		printerr("JOURNAL BATCH TEST FAIL: ", what)

func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() == 2 and args[0] == "--child":
		_child(args[1])
		return
	_parent.call_deferred()

## Loads the world in `base` (or starts it), then commits PER_FRAME times a
## frame. Whenever more commits are on disk it writes how many to acks.txt:
## that is the moment a player would be answered.
func _child(base: String) -> void:
	var store := Store.new(base)
	store.open(ID)
	var state := State.new()
	if FileAccess.file_exists(base.path_join(ID).path_join("world.json")) and store.load_state(state).is_empty():
		printerr("child could not load"); quit(2); return
	state.enroll("host", {"name": "HOST"})
	state.commit_writer = store.append
	var acks := FileAccess.open(base.path_join("acks.txt"), FileAccess.WRITE)
	var first := state.revision
	var told := 0
	var padding := "x".repeat(300)
	while true:
		for i in PER_FRAME:
			var n := state.revision
			if not state.transact("host", "c%d" % n, [state.change("note/%d" % n, padding + str(n))]).get("ok", false):
				printerr("child commit refused"); quit(2); return
		await process_frame
		if store.written > told:
			told = store.written
			acks.store_line(str(first + told))
			acks.flush()

func _parent() -> void:
	var base := OS.get_temp_dir().path_join("journal_batch_test_%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(base)
	# An empty world save to load from.
	var store := Store.new(base)
	store.open(ID)
	check(Store.write(store.prepare(State.new(), {"world_name": "TEST"})) == OK, "a first world save")
	await _gate(base)
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	var acknowledged := 0
	for round in KILLS:
		var pid := OS.create_process(OS.get_executable_path(), ["--headless", "--path", ProjectSettings.globalize_path("res://"), "-s", ProjectSettings.globalize_path(get_script().resource_path), "--", "--child", base])
		if pid <= 0: check(false, "child started"); break
		var started := Time.get_ticks_msec()
		var wait := rng.randi_range(1500, 3500)
		while Time.get_ticks_msec() - started < wait: await process_frame
		OS.kill(pid)
		while OS.is_process_running(pid): await process_frame
		var lines := FileAccess.get_file_as_string(base.path_join("acks.txt")).strip_edges().split("\n")
		var last := int(lines[-1]) if not lines.is_empty() and not lines[-1].is_empty() else acknowledged
		check(last >= acknowledged, "round %d: acknowledgements go on (%d after %d)" % [round, last, acknowledged])
		acknowledged = last
		var loaded := State.new()
		var reader := Store.new(base)
		reader.open(ID)
		check(not reader.load_state(loaded).is_empty(), "round %d: the world loads after a kill" % round)
		check(loaded.revision >= acknowledged, "round %d: every acknowledged commit is there (%d of %d)" % [round, loaded.revision, acknowledged])
		var missing := 0
		for n in loaded.revision:
			if not String(loaded.records.get("note/%d" % n, "")).ends_with(str(n)): missing += 1
		check(missing == 0, "round %d: %d commits missing below revision %d" % [round, missing, loaded.revision])
		# Folded into a world save, as the host does, so the journal stays short.
		var job := reader.prepare(loaded, {"world_name": "TEST"})
		check(Store.write(job) == OK and reader.rotate(job) == OK, "round %d: saved" % round)
		print("JOURNAL BATCH TEST round %d: killed after %d ms, %d acknowledged, %d on disk" % [round, wait, acknowledged, loaded.revision])
	check(acknowledged > PER_FRAME * KILLS, "the children got some work done (%d)" % acknowledged)
	print("JOURNAL BATCH TEST: %d failed" % failed)
	quit(1 if failed > 0 else 0)

## What a host sends after a commit waits for the commit to be on disk.
func _gate(base: String) -> void:
	var store := Store.new(base.path_join("gate"))
	store.open(ID)
	var state := State.new()
	state.enroll("host", {"name": "HOST"})
	state.commit_writer = store.append
	var transport := Transport.new()
	root.add_child(transport)
	transport.journal = store
	check(transport.host(0, "127.0.0.1") == OK, "listening")
	var client := StreamPeerTCP.new()
	client.connect_to_host("127.0.0.1", transport.server.get_local_port())
	var frames := 0
	while transport.peers.is_empty() or not transport.peers.values()[0].ready:
		client.poll(); await process_frame
		frames += 1
		if frames > 600: check(false, "connected"); return
	var peer: int = transport.peers.keys()[0]
	transport.send(peer, {"kind": "before"})
	transport._write(peer, 1 << 20)
	check(int(transport.peers[peer].queued) == 0, "nothing held without a commit")
	check(state.transact("host", "g1", [state.change("note/x", 1)]).get("ok", false), "a commit")
	transport.send(peer, {"kind": "command_result", "id": "g1"})
	transport._write(peer, 1 << 20)
	check(int(transport.peers[peer].queued) > 0, "its answer waits while the commit is not on disk")
	frames = 0
	while int(transport.peers[peer].queued) > 0 and frames < 600:
		client.poll(); await process_frame
		frames += 1
	check(store.has_written(store.queued), "the commit is on disk")
	check(int(transport.peers[peer].queued) == 0, "then the answer goes out (%d frames)" % frames)
	transport.stop()
	transport.queue_free()
