# The record indexes of the co-op state (coop_state.gd claims_by_actor,
# wild_by_area, namespace_max) match a walk over every record after commits,
# edits, removals, a restore from a world save and a replay of the journal; and
# the wild rules that read them (coop_wild_population.gd) still refuse a second
# claim, hand out fresh namespaces and refuse a second unique Pokemon.
# Run: godot --headless --path project -s ../server/coop_state_index_test.gd
extends SceneTree

const State = preload("res://scripts/coop_state.gd")
const Store = preload("res://scripts/coop_store.gd")
const Wild = preload("res://scripts/coop_wild_population.gd")
const Delta = preload("res://scripts/coop_world_delta.gd")
const ID := "0123456789abcdef0123456789abcdef"
const ACTORS := ["ash", "misty", "brock"]

var failed := 0
var serial := 0

func check(ok: bool, what: String) -> void:
	if not ok:
		failed += 1
		printerr("STATE INDEX TEST FAIL: ", what)

## The indexes worked out the slow way, from every record.
static func walked(state) -> Array:
	var claims := {}
	var wild := {}
	var top := 0
	for key: String in state.records:
		var value = state.records[key]
		if key.begins_with("wild_claim/"):
			var actor := String(value.actor)
			if not claims.has(actor): claims[actor] = {}
			claims[actor][key] = true
		elif key.begins_with("wild_namespace/"): top = maxi(top, int(value))
		elif key.begins_with("world/") and key.get_slice("/", 2) == "wild_pokemon":
			var area := key.get_slice("/", 1)
			if not wild.has(area): wild[area] = {}
			wild[area][key] = true
	return [claims, wild, top]

func same_indexes(state, what: String) -> void:
	var expected := walked(state)
	check(state.claims_by_actor == expected[0], what + ": claims by actor")
	check(state.wild_by_area == expected[1], what + ": wild Pokemon by area")
	check(state.namespace_max() == expected[2], what + ": highest namespace %d, not %d" % [state.namespace_max(), expected[2]])

func commit(state, actor: String, changes: Array) -> void:
	serial += 1
	var result: Dictionary = state.transact(actor, "i%d" % serial, changes)
	check(result.get("ok", false), "commit %d %s %s" % [serial, result, changes])

func _init() -> void:
	var base := OS.get_temp_dir().path_join("state_index_test_%d" % Time.get_ticks_usec())
	var store := Store.new(base)
	store.open(ID)
	var state := State.new()
	state.commit_writer = store.append
	for actor in ACTORS:
		state.enroll(actor, {"name": actor})
		state.enter(actor, "0,0")
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for step in 400:
		var actor: String = ACTORS[rng.randi() % ACTORS.size()]
		var area := "%d,0" % (rng.randi() % 3)
		var id := rng.randi() % 12 + 1
		match rng.randi() % 5:
			0: commit(state, actor, [state.change("wild_claim/%s/%d" % [area, id], null if rng.randf() < 0.4 else {"actor": actor, "area": area, "id": id})])
			1: commit(state, actor, [state.change("world/%s/wild_pokemon/%d" % [area, id], null if rng.randf() < 0.4 else Delta.encode({"id": id, "species": "pidgey"}))])
			2: commit(state, actor, [state.change("wild_namespace/" + actor, null if rng.randf() < 0.2 else rng.randi() % 50 + 1)])
			3:
				var key := "wild_claim/%s/%d" % [area, id]
				var edits: Dictionary = state.change_edits(key, {"actor": ACTORS[(ACTORS.find(actor) + 1) % 3], "area": area, "id": id}) if state.records.get(key) is Dictionary else {}
				if not edits.is_empty(): commit(state, actor, [edits])
			4: commit(state, actor, [state.change("world/%s/terrain_changes/%d" % [area, id], step)])
	same_indexes(state, "after commits")
	var restored := State.new()
	restored.restore(state.snapshot())
	same_indexes(restored, "after a restore")
	check(store.sync(), "the journal written")
	# No world save yet: replay the journal onto an empty world.
	var empty := State.new()
	var journal := Store.new(base)
	journal.open(ID)
	var job := journal.prepare(State.new(), {"world_name": "T"})
	check(Store.write(job) == OK, "an empty world save")
	check(not journal.load_state(empty).is_empty(), "the journal replays")
	check(empty.revision == state.revision, "every commit replayed (%d of %d)" % [empty.revision, state.revision])
	same_indexes(empty, "after a journal replay")

	# The rules on top: one encounter per player, fresh namespaces, one Mew.
	var wild := Wild.new()
	wild.state = empty
	for actor in ACTORS:
		empty.enroll(actor, {"name": actor})
		empty.enter(actor, "5,0")
	for actor in ACTORS: wild.abandon(actor, "clear-" + actor, actor)
	check(empty.claims_by_actor.is_empty(), "abandon clears every claim")
	commit(empty, "ash", [empty.change(Wild.record_key("5,0", 3), Delta.encode({"id": 3, "species": "pidgey"}))])
	commit(empty, "ash", [empty.change(Wild.record_key("5,0", 4), Delta.encode({"id": 4, "species": "pidgey"}))])
	check(wild.claim("ash", "c1", "5,0", 3).get("ok", false), "a first claim")
	check(wild.claim("ash", "c2", "5,0", 4).get("reason", "") == "already_in_encounter", "a second claim is refused")
	check(wild.claim("misty", "c3", "5,0", 4).get("ok", false), "another player's claim")
	check(wild.abandon("ash", "a1", "ash").get("ok", false) and not empty.claims_by_actor.has("ash") and empty.claims_by_actor.has("misty"), "abandon drops only that player's claim")
	var top := empty.namespace_max()
	empty.enroll("gary", {"name": "gary"})
	check(wild.namespace_for("gary") == top + 1, "a new namespace is above every other")
	var mine := wild.namespace_for("ash")
	var mew := {"id": mine * 4294967296 + 9, "species": "mew", "level": 30, "x": 1, "y": 1, "source_record": {"rare_forest_mew": true}}
	check(wild.register("ash", "m1", "5,0", mew).get("ok", false), "a first Mew")
	mew = mew.duplicate(true); mew.id = mine * 4294967296 + 10
	check(wild.register("ash", "m2", "5,0", mew).get("reason", "") == "already_present", "a second Mew is refused")
	same_indexes(empty, "after the rules")
	print("STATE INDEX TEST: %d failed" % failed)
	quit(1 if failed > 0 else 0)
