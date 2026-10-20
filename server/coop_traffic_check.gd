# Co-op wire checks, in seconds: a world record sent as a delta is rebuilt
# byte for byte, a delta that does not fit is refused, a large transfer
# arrives whole through compression, a position packet sent as bytes reads back
# as JSON would have given it (and a malformed one is refused), and the Megas
# packed piece by piece match a whole encode.
# Run: godot --headless --path project -s <this file>
extends SceneTree

const Delta = preload("res://scripts/coop_world_delta.gd")
const Blob = preload("res://scripts/coop_blob.gd")
const Remote = preload("res://scripts/coop_remote_player.gd")
const Players = preload("res://scripts/coop_players.gd")

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
	_visuals()
	_megas()
	print("COOP TRAFFIC CHECK: %d failed" % failed)
	quit(1 if failed > 0 else 0)

## The same text JSON gives, keys in order: numbers as floats either way.
func _same(a: Variant, b: Variant) -> bool:
	return JSON.stringify(a, "", true) == JSON.stringify(b, "", true)

func _visuals() -> void:
	var part := {"x": 1234.5, "y": -87.25, "z": 4011, "frame": 7, "hframes": 4, "vframes": 2, "flip_h": true,
		"centered": true, "ox": 0.0, "oy": -8.0}
	var packet := {"kind": "player_visual", "area": "0,-1", "layer": "OVERWORLD", "battle": false, "afk": false,
		"cell_x": 77, "cell_y": -5, "body_x": 1240.0, "body_y": -80.0, "helper_slot": -1, "field_level": 12,
		"party_level": 14, "population_scope": "OVERWORLD", "t": 987654, "actor": "ab".repeat(32),
		"visual": {"model": 3, "color": 5, "running": true, "move": "SURF", "fx": 1, "fy": 0,
			"helper_species": "lapras", "helper_shiny": false, "helper_form": "", "follower_species": "pikachu",
			"follower_shiny": true, "follower_form": "", "pose": "sit", "pose_frame": 2, "sleeping": true,
			"thrown_species": "eevee", "thrown_shiny": false, "thrown_form": "x",
			"parts": {"player": part, "helper": part.duplicate(), "thrown": part.merged({"s": 0.75})},
			"shadow": {"x": 1.5, "y": 2.0, "z": 3},
			"night": [{"id": "123456", "texture": "ghost", "x": 10.0, "y": 20.0, "z": 5, "visible": true,
				"centered": false, "flip_h": false, "hframes": 3, "vframes": 1, "frame": 2, "region": true,
				"rx": 0.0, "ry": 16.0, "rw": 32.0, "rh": 32.0}]}}
	var bytes := Remote.pack(packet)
	var text := JSON.stringify(packet).to_utf8_buffer()
	check(not bytes.is_empty() and bytes.size() * 2 < text.size(), "a position goes as bytes, under half the JSON (%d vs %d)" % [bytes.size(), text.size()])
	var read = Remote.unpack(bytes)
	check(read is Dictionary and _same(read, JSON.parse_string(JSON.stringify(packet))), "it reads back as JSON gave it")
	check(read is Dictionary and Players.valid_packet(read), "and passes the same checks")
	var plain := packet.duplicate(true)
	plain.visual.parts = {}; plain.visual.night = []; plain.visual.shadow = {}; plain.erase("actor")
	check(_same(Remote.unpack(Remote.pack(plain)), JSON.parse_string(JSON.stringify(plain))), "an empty one too")
	for odd in [{"extra": 1}, {"t": 0.1}, {"cell_x": 16777217}, {"layer": "x".repeat(300)}, {"t": INF}]:
		check(Remote.pack(packet.merged(odd, true)).is_empty(), "what does not fit goes as JSON: %s" % str(odd).left(40))
	check(Remote.pack(packet.merged({"kind": "world_clock"}, true)).is_empty(), "only positions go as bytes")
	var odd_type := packet.merged({"area": 5, "battle": 1}, true)
	check(_same(Remote.unpack(Remote.pack(odd_type)), JSON.parse_string(JSON.stringify(odd_type))) and not Players.valid_packet(Remote.unpack(Remote.pack(odd_type))), "a wrong type reads back as JSON gave it, and is refused the same")
	for cut in [1, 5, bytes.size() / 2, bytes.size() - 1]:
		check(Remote.unpack(bytes.slice(0, cut)) == null, "a cut packet is refused (%d bytes)" % cut)
	var longer := bytes.duplicate(); longer.append(0)
	check(Remote.unpack(longer) == null, "trailing bytes are refused")
	var bad_mask := bytes.duplicate(); bad_mask.encode_u32(1, 0xFFFFFFFF)
	check(Remote.unpack(bad_mask) == null, "unknown keys are refused")
	var bad_type := bytes.duplicate(); bad_type[5] = 9
	check(Remote.unpack(bad_type) == null, "an unknown value type is refused")
	var too_big := PackedByteArray([Remote.WIRE_TAG]); too_big.resize(Remote.WIRE_MAX_BYTES + 1)
	check(Remote.unpack(too_big) == null, "an oversized packet is refused")
	var crowd := packet.duplicate(true)
	for i in 64: crowd.visual.night.append(crowd.visual.night[0].merged({"id": str(i)}, true))
	check(Remote.pack(crowd).is_empty(), "more than 64 night sprites go as JSON")
	var wordy := packet.duplicate(true)
	wordy.visual.night.clear()
	for i in 64: wordy.visual.night.append(packet.visual.night[0].merged({"id": str(i), "texture": "t".repeat(250)}, true))
	check(Remote.pack(wordy).is_empty(), "a packet over the size limit goes as JSON")
	# Random bytes after the tag: refused or read as some packet, never a crash.
	var noise := RandomNumberGenerator.new(); noise.seed = 7
	for i in 300:
		var junk := PackedByteArray([Remote.WIRE_TAG])
		for j in noise.randi_range(0, 200): junk.append(noise.randi_range(0, 255))
		var any = Remote.unpack(junk)
		check(any == null or any is Dictionary, "random bytes")

func _megas() -> void:
	var megas := {}
	for group in ["forest", "ocean", "cave", "tundra", 7]:
		megas[group] = {"species": "mega_" + str(group), "x": 10, "y": -3, "next_move": 12.75, "flip_h": false,
			"record": {"hp": 140, "moves": ["TACKLE", "SURF"], "ivs": PackedInt32Array([1, 2, 3]), "zz": 1, "aa": {"b": 2, "a": 1}}}
	var memo := {}
	check(Delta.encode_map(megas, memo) == Delta.encode(megas), "the Megas packed piece by piece match")
	megas.ocean.x = 11; megas.ocean.next_move = 13.5
	check(Delta.encode_map(megas, memo) == Delta.encode(megas), "after one moves")
	megas.cave.record.ivs.append(4)
	check(Delta.encode_map(megas, memo) == Delta.encode(megas), "after a change deep inside one")
	megas.erase("tundra"); megas["desert"] = {"species": "mega_desert", "x": 1}
	var packed := Delta.encode_map(megas, memo)
	check(packed == Delta.encode(megas) and not memo.has("tundra"), "after one goes and another comes")
	check(Delta.encode(Delta.decode(packed)) == packed, "the result is in encode's form")
	check(Delta.encode_map({}, {}) == Delta.encode({}) and Delta.encode_map(5, {}) == Delta.encode(5), "an empty map, and a value that is not one")
