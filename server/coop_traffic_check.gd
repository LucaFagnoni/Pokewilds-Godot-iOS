# Co-op wire checks, in seconds: a world record sent as a delta is rebuilt
# byte for byte, a delta that does not fit is refused, and a large transfer
# arrives whole through compression.
# Run: godot --headless --path project -s <this file>
extends SceneTree

const Delta = preload("res://scripts/coop_world_delta.gd")
const Blob = preload("res://scripts/coop_blob.gd")

var failed := 0

func check(ok: bool, what: String) -> void:
	if not ok:
		failed += 1
		printerr("COOP TRAFFIC CHECK FAIL: ", what)

func _init() -> void:
	var before := {"x": 3, "y": 4, "next_move": 12.5, 7: "seven",
		"record": {"species": "pidgey", "level": 5, "moves": ["TACKLE"], "pad": "p".repeat(2000)}}
	var after := before.duplicate(true)
	after.x = 4; after.next_move = 13.25; after.record.level = 6; after.erase(7); after["flee"] = 1.0
	var old := Delta.encode(before)
	var new := Delta.encode(after)
	var delta = Delta.entry_delta(old, new)
	check(delta != null, "a small change makes a delta")
	# It crosses the network as JSON.
	var sent = JSON.parse_string(JSON.stringify(delta))
	check(Delta.apply_delta(old, sent) == new, "the delta rebuilds the record exactly")
	check(Delta.apply_delta(Delta.encode({"x": 1}), sent) != new, "on another record it does not")
	var moved := before.duplicate(true)
	moved.y = 5; moved.record.level = 9
	check(Delta.apply_delta(old, JSON.parse_string(JSON.stringify(Delta.entry_delta(old, Delta.encode(moved))))) == Delta.encode(moved), "a move alone rebuilds exactly")
	check(Delta.entry_delta(old, Delta.encode({"other": "p".repeat(3000)})) == null, "a rewritten record goes whole")
	check(Delta.apply_delta(old, {"set": [[1, 2]], "drop": []}).is_empty(), "a malformed delta is refused")

	var text := JSON.stringify({"records": range(20000)}).to_utf8_buffer()
	var sender := Blob.new()
	var receiver := Blob.new()
	check(sender.start_send(2, "abc", text), "a transfer starts")
	var chunks: Array = []
	while sender.outgoing.has(2) and chunks.size() < 100:
		sender.pump(2, func(_peer: int, packet: Dictionary) -> Error: chunks.append(JSON.parse_string(JSON.stringify(packet))); return OK)
	check(chunks.size() * Blob.CHUNK_BYTES < text.size() / 2, "it travels compressed (%d chunks for %d bytes)" % [chunks.size(), text.size()])
	var result: Dictionary = {}
	for chunk in chunks: result = receiver.receive(5, chunk)
	check(result.get("bytes", PackedByteArray()) == text, "it arrives whole")
	print("COOP TRAFFIC CHECK: %d failed" % failed)
	quit(1 if failed > 0 else 0)
