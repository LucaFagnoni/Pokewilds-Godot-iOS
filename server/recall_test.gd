# Calling back a Pokemon left in the world, as the host decides it
# (coop_population_records.gd): it is found by its id wherever it walked to
# while its prompt was open or the request travelled, also when the player's
# game shows it on another tile; someone else's is refused, as are a full
# party, a player too far away and one that is gone; each refusal has words
# for the player (coop_population_runtime.gd). An egg is picked up although
# its timers ticked; produce is harvested from a Pokemon that walked on; a
# battle is started against one that walked on, but not against another's.
# Run: godot --headless --path project -s ../server/recall_test.gd
extends SceneTree

const Records = preload("res://scripts/coop_population_records.gd")
const State = preload("res://scripts/coop_state.gd")
const Delta = preload("res://scripts/coop_world_delta.gd")
const Runtime = preload("res://scripts/coop_population_runtime.gd")
const AREA := "0,0"

var failed := 0
var state: State
var model: Records
var serial := 0

func check(ok: bool, what: String) -> void:
	if not ok:
		failed += 1
		printerr("RECALL TEST FAIL: ", what)

func _id() -> String:
	serial += 1
	return "r%d" % serial

func _init() -> void:
	state = State.new()
	model = Records.new()
	model.state = state
	for actor in ["alice", "bob"]:
		state.enroll(actor, {"name": actor})
		state.enter(actor, AREA)
		state.records["player/" + actor] = {"party": [{"species": "slowpoke", "level": 20}, {"species": "pidgey", "level": 3}], "inventory": {}, "save": {}}
	model.presence = {"alice": {"area": AREA + "|OVERWORLD", "x": 10, "y": 10}, "bob": {"area": AREA + "|OVERWORLD", "x": 10, "y": 12}}

	# Alice leaves SLOWPOKE beside her; it walks four steps while her prompt
	# is open and her request travels (one of them still on its way to her game).
	var left := _leave("alice", Vector2i(11, 10))
	var identity := String(left[1].ecology_id)
	var seen: String = state.records[Records.key(AREA, "deployed_pokemon", Vector2i(11, 10))]
	var at := Vector2i(11, 10)
	for step in 4:
		at = _walk(at, Vector2i(1, 0) if step % 2 == 0 else Vector2i(0, -1))
	check(at != Vector2i(11, 10), "it walked")
	var party_before := _party("alice")
	var result := model.take("alice", _id(), AREA, Vector2i(11, 10), "deployed_pokemon", State.fingerprint(seen), "", identity)
	check(result.get("ok", false), "taken back where it walked to, asked for where it was (%s)" % result.get("reason", ""))
	check(_party("alice") == party_before + 1, "it is in the party again")
	check(Delta.decode(state.records.get(Records.key(AREA, "deployed_pokemon", at), Delta.encode(null))) == null, "and gone from the world")
	check(not _anywhere(identity), "with no copy left anywhere")

	# The same request arriving twice is answered from its receipt, not done twice.
	var again := _leave("alice", Vector2i(11, 10))
	var request := _id()
	var first := model.take("alice", request, AREA, Vector2i(11, 10), "deployed_pokemon", "", "", String(again[1].ecology_id))
	var party_after := _party("alice")
	var repeat := model.take("alice", request, AREA, Vector2i(11, 10), "deployed_pokemon", "", "", String(again[1].ecology_id))
	check(first.get("ok", false) and repeat.get("ok", false) and _party("alice") == party_after, "a retried request is answered once")

	# Bob may not take Alice's.
	var hers := _leave("alice", Vector2i(10, 11))
	result = model.take("bob", _id(), AREA, Vector2i(10, 11), "deployed_pokemon", "", "", String(hers[1].ecology_id))
	check(result.get("reason") == "not_owner", "someone else's is refused (%s)" % result.get("reason", ""))
	check(_anywhere(String(hers[1].ecology_id)), "and stays where it is")
	# Nor start a battle with it to catch it.
	check(Records.owned_by_other(hers[1], "bob") and not Records.owned_by_other(hers[1], "alice"), "only its owner may battle it")
	check(not Records.owned_by_other({"ecology_id": "owned:3"}, "bob"), "one left before the world went online is anyone's")

	# It walked further than a player may reach.
	var far := Vector2i(10, 11)
	for step in 7: far = _walk(far, Vector2i(1, 0))
	result = model.take("alice", _id(), AREA, Vector2i(10, 11), "deployed_pokemon", "", "", String(hers[1].ecology_id))
	check(result.get("reason") == "too_far", "too far away is refused (%s)" % result.get("reason", ""))
	# Alice walks after it.
	model.presence.alice.x = far.x - 1; model.presence.alice.y = far.y
	result = model.take("alice", _id(), AREA, Vector2i(10, 11), "deployed_pokemon", "", "", String(hers[1].ecology_id))
	check(result.get("ok", false), "and taken once she is near (%s)" % result.get("reason", ""))
	model.presence.alice.x = 10; model.presence.alice.y = 10

	# A full party, no box to send it to.
	var full := _leave("alice", Vector2i(11, 10))
	var profile: Dictionary = state.records["player/alice"].duplicate(true)
	while profile.party.size() < 6: profile.party.append({"species": "rattata", "level": 2})
	state.transact("alice", _id(), [state.change("player/alice", profile)])
	result = model.take("alice", _id(), AREA, Vector2i(11, 10), "deployed_pokemon", "", "", String(full[1].ecology_id))
	check(result.get("reason") == "no_room", "a full party is refused (%s)" % result.get("reason", ""))
	profile.party.resize(2)
	state.transact("alice", _id(), [state.change("player/alice", profile)])

	# Gone (taken or fought by someone else meanwhile).
	result = model.take("alice", _id(), AREA, Vector2i(11, 10), "deployed_pokemon", "", "", "coop_owned:alice:nothing")
	check(result.get("reason") == "too_late", "one that is gone is refused (%s)" % result.get("reason", ""))

	# Every refusal has its own words.
	var fallback := Runtime.refusal("something else", "SLOWPOKE")
	for reason in ["too_late", "too_far", "not_owner", "no_room", "busy", "disconnected"]:
		var words := Runtime.refusal(reason, "SLOWPOKE")
		check(not words.is_empty() and words != fallback, "a refusal is explained: " + reason)
	check("full" in Runtime.refusal("no_room", "SLOWPOKE").to_lower(), "a full party says so")

	# Produce from a Pokemon that walked on since the player pressed.
	var record: Dictionary = Delta.decode(state.records[Records.key(AREA, "deployed_pokemon", Vector2i(11, 10))])
	record["held_item"] = "BERRY JUICE"
	state.transact("alice", _id(), [state.change(Records.key(AREA, "deployed_pokemon", Vector2i(11, 10)), Delta.encode(record))])
	var asked := String(state.records[Records.key(AREA, "deployed_pokemon", Vector2i(11, 10))])
	_walk(Vector2i(11, 10), Vector2i(1, 0))
	result = model.harvest("bob", _id(), AREA, Vector2i(11, 10), State.fingerprint(asked), String(record.ecology_id))
	check(result.get("ok", false) and int(state.records["player/bob"].inventory.get("BERRY JUICE", 0)) == 1, "produce is harvested where it walked to (%s)" % result.get("reason", ""))

	# An egg: its timers ticked since the player's game saw it.
	var egg_key := Records.key(AREA, "wild_eggs", Vector2i(9, 10))
	var egg := {"species": "pidgey", "x": 9, "y": 10, "is_egg": true, "dropped_party_egg": true, "hatch_steps": 50}
	state.transact("alice", _id(), [state.change(egg_key, Delta.encode(egg))])
	var egg_seen := String(state.records[egg_key])
	egg.hatch_steps = 49
	state.transact("alice", _id(), [state.change(egg_key, Delta.encode(egg))])
	party_before = _party("alice")
	result = model.take("alice", _id(), AREA, Vector2i(9, 10), "wild_eggs", State.fingerprint(egg_seen), "", "")
	check(result.get("ok", false) and _party("alice") == party_before + 1, "an egg is picked up after its timers ticked (%s)" % result.get("reason", ""))

	print("RECALL TEST: %d failed" % failed)
	quit(1 if failed > 0 else 0)

## Leaves the first Pokemon of `actor`'s party at `cell`; [key, record].
func _leave(actor: String, cell: Vector2i) -> Array:
	var profile: Dictionary = state.records["player/" + actor]
	var pokemon: Dictionary = profile.party[0].duplicate(true)
	pokemon["x"] = cell.x; pokemon["y"] = cell.y
	var result := model.place(actor, _id(), AREA, 0, pokemon, state.print_of("player/" + actor, {}))
	check(result.get("ok", false), "%s leaves a Pokemon at %s (%s)" % [actor, cell, result.get("reason", "")])
	# Put one back in the party, so there is always one to leave.
	profile = state.records["player/" + actor].duplicate(true)
	profile.party.insert(0, {"species": "slowpoke", "level": 20})
	state.transact(actor, _id(), [state.change("player/" + actor, profile)])
	var key := Records.key(AREA, "deployed_pokemon", cell)
	return [key, Delta.decode(state.records[key])]

## One step, as the area's simulation sends it (coop_population_runtime.gd).
func _walk(from: Vector2i, step: Vector2i) -> Vector2i:
	var to := from + step
	var record: Dictionary = Delta.decode(state.records[Records.key(AREA, "deployed_pokemon", from)])
	record.x = to.x; record.y = to.y
	record["move_timer"] = randf()
	var result := state.transact("bob", _id(), [state.change(Records.key(AREA, "deployed_pokemon", from), Delta.encode(null)),
		state.change(Records.key(AREA, "deployed_pokemon", to), Delta.encode(record))])
	check(result.get("ok", false), "a step from %s to %s" % [from, to])
	return to

func _party(actor: String) -> int:
	return state.records["player/" + actor].party.size()

func _anywhere(identity: String) -> bool:
	for key in state.records:
		if String(key).begins_with("world/" + AREA + "/deployed_pokemon/"):
			var record = Delta.decode(state.records[key])
			if record is Dictionary and String(record.get("ecology_id", "")) == identity: return true
	return false
