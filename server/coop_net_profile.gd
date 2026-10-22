# Co-op traffic and CPU profile, one process of coop_net_profile.py: the
# dedicated server (--server) or a joining player (--join). Both follow the
# phase the Python side writes to --phase=FILE ("name"), and when it changes
# print the phase just ended: per message kind the count and bytes per second
# and the time spent encoding, decoding and applying (coop_transport.gd stats),
# and ms per frame (the frame's own work, see _frame_ended; the netcode's own share). A player
# walks in phases named walk*, travels east once in a phase named *split when
# its --index is odd (in *away whatever it is), and records where it draws each other player, every
# frame, for the smoothness numbers (largest step, steps over 8 px).
#   godot --headless --path project -s ../server/coop_net_profile.gd --server ... -- --phase=FILE
#   godot --headless --path project -s ../server/coop_net_profile.gd --join HOST:PORT --data DIR -- --phase=FILE --index=N
extends SceneTree

const Transport = preload("res://scripts/coop_transport.gd")
var phase_file := ""
var index := 0
var phase := ""
var phase_started := 0
var frames := 0
var process_ms := 0.0
var max_frame_ms := 0.0
var main: Node
var travelled := false
var _back := false
var _checked := 0
var _walk_dir := 1
var _walk_flip := 0
var _seen: Dictionary = {}
var _steps: Array = []
var _last_frame := 0
var _frame_ms: Array = []
## What the shared commits a player is sent change: key (up to the record's
## group) -> [changes, bytes as JSON].
var _commits: Dictionary = {}
var _listening := false
## Frames over 16 ms: what took the time, from the sections a test build
## times into Engine meta "probe_frame" (name -> microseconds this frame,
## "_top" the outermost ones summed): name -> [frames it was the largest in,
## its ms in all such frames, its longest ms].
var _spikes: Dictionary = {}
## Every timed section's microseconds this phase, for its cost per frame.
var _sections: Dictionary = {}

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--phase="): phase_file = arg.trim_prefix("--phase=")
		if arg.begins_with("--index="): index = int(arg.trim_prefix("--index="))
	Transport.stats = {}
	# When this frame's resumed coroutines began (a test build's probe times them).
	process_frame.connect(func(): Engine.set_meta("probe_t0", Time.get_ticks_usec()))
	# A frame's work: from its first physics step (or its process step) to the
	# end of its last node's _process and the calls deferred to after it.
	# Performance TIME_PROCESS is no use for this: it is the longest frame of
	# the last second, updated once a second.
	physics_frame.connect(func(): if _frame_started == 0: _frame_started = Time.get_ticks_usec())
	var end := EndOfFrame.new()
	end.process_priority = 2147483647
	end.process_mode = Node.PROCESS_MODE_ALWAYS
	end.ended = _frame_ended
	root.add_child.call_deferred(end)
	change_scene_to_file("res://scenes/main.tscn")

class EndOfFrame extends Node:
	var ended: Callable
	func _process(_delta: float) -> void:
		Engine.set_meta("probe_nodes_end", Time.get_ticks_usec())
		ended.call_deferred()

var _frame_started := 0
var _process_started := 0
var _reported := false
## From one frame's start to the next, sleep included: a frame over the frame
## rate's budget shows here too, with what runs after the deferred calls.
var _last_start := 0
var _intervals: Array = []

func _frame_ended() -> void:
	var ms := (Time.get_ticks_usec() - _frame_started) / 1000.0 if _frame_started > 0 else 0.0
	# A test build's probe: the parts of the frame no script's _process covers.
	if Engine.has_meta("probe_frame") and _frame_started > 0:
		var sections: Dictionary = Engine.get_meta("probe_frame")
		for part in [["(physics, main loop)", _frame_started, _process_started], ["(deferred calls)", int(Engine.get_meta("probe_nodes_end", 0)), Time.get_ticks_usec()]]:
			if part[1] > 0 and part[2] >= part[1]:
				sections[part[0]] = part[2] - part[1]
				sections["_top"] = sections.get("_top", 0) + part[2] - part[1]
	if _last_start > 0 and _frame_started > 0 and phase_started > 0 and not _reported: _intervals.append((_frame_started - _last_start) / 1000.0)
	_last_start = _frame_started
	_frame_started = 0
	# The frame that printed the last phase's report is not the game's.
	if phase_started > 0 and not _reported:
		frames += 1
		process_ms += ms
		max_frame_ms = maxf(max_frame_ms, ms)
		_frame_ms.append(ms)
		if ms > 16.0: _spike(ms)
		var sections: Dictionary = Engine.get_meta("probe_frame", {})
		for name in sections: _sections[name] = _sections.get(name, 0) + sections[name]
	_reported = false
	if Engine.has_meta("probe_frame"): Engine.get_meta("probe_frame").clear()

func _role() -> String:
	return "SERVER" if "--server" in OS.get_cmdline_args() else "CLIENT%d" % index

func _process(_delta: float) -> bool:
	var now := Time.get_ticks_msec()
	if main == null and current_scene != null and current_scene.get("started"): main = current_scene
	if _frame_started == 0: _frame_started = Time.get_ticks_usec()
	_process_started = Time.get_ticks_usec()
	if now - _checked >= 200:
		_checked = now
		var next := FileAccess.get_file_as_string(phase_file).strip_edges() if FileAccess.file_exists(phase_file) else ""
		if next != phase:
			if phase_started > 0: _report(); _reported = true
			phase = next
			phase_started = now
			frames = 0; process_ms = 0.0; max_frame_ms = 0.0
			_steps.clear(); _seen.clear(); _frame_ms.clear(); _commits.clear(); _spikes.clear(); _sections.clear(); _intervals.clear()
			Transport.stats = {}
	if main != null and is_instance_valid(main) and main.started and not "--server" in OS.get_cmdline_args():
		_play(now)
	if phase == "walk-breakdown" and not _breaking and "--server" in OS.get_cmdline_args(): _breakdown()
	return false

## The server's frame by script: each script's nodes stop processing for a
## second, between two seconds with them on; the difference is what they cost.
var _breaking := false
func _breakdown() -> void:
	_breaking = true
	var groups := {}
	var stack: Array = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		stack.append_array(node.get_children())
		var path := String(node.get_script().resource_path) if node.get_script() != null else node.get_class()
		if node.is_processing() or node.is_physics_processing(): groups.get_or_add(path, []).append(node)
		if node.is_processing_internal() or node.is_physics_processing_internal(): groups.get_or_add("internal " + node.get_class(), []).append(node)
	var census := {}
	for path in groups: census[path] = groups[path].size()
	print("PROFILE SERVER census ", census)
	var costs: Array = []
	for path in groups:
		if not "--server" in OS.get_cmdline_args() or phase != "walk-breakdown": break
		var on := await _average(0.75)
		var nodes: Array = groups[path].filter(func(n): return is_instance_valid(n))
		var internal := String(path).begins_with("internal ")
		var physics: Array = nodes.map(func(n): return n.is_physics_processing_internal() if internal else n.is_physics_processing())
		for n in nodes:
			if internal: n.set_process_internal(false); n.set_physics_process_internal(false)
			else: n.set_process(false); n.set_physics_process(false)
		var off := await _average(0.75)
		for i in nodes.size():
			if not is_instance_valid(nodes[i]): continue
			if internal: nodes[i].set_process_internal(true); nodes[i].set_physics_process_internal(physics[i])
			else: nodes[i].set_process(true); nodes[i].set_physics_process(physics[i])
		costs.append([on - off, path, nodes.size()])
	costs.sort_custom(func(a, b): return a[0] > b[0])
	for c in costs: print("PROFILE SERVER breakdown %7.3f ms/frame %4d nodes %s" % [c[0], c[2], c[1]])

func _average(wait: float) -> float:
	var total := 0.0; var n := 0
	var until := Time.get_ticks_msec() + int(wait * 1000)
	await process_frame
	while Time.get_ticks_msec() < until:
		await process_frame
		total += (Performance.get_monitor(Performance.TIME_PROCESS) + Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)) * 1000.0; n += 1
	return total / maxi(1, n)

func _spike(ms: float) -> void:
	var sections: Dictionary = Engine.get_meta("probe_frame", {})
	var top := 0.0
	var largest := ""; var largest_ms := 0.0
	for name in sections:
		var section_ms: float = sections[name] / 1000.0
		if name == "_top": top = section_ms; continue
		if section_ms > largest_ms: largest = name; largest_ms = section_ms
	# What no timed section accounts for (engine work, coroutines resumed).
	if ms - top > largest_ms: largest = "(untimed)"; largest_ms = ms - top
	# A section timed inside another ("@name") names it when it is most of it.
	for name in sections:
		if String(name).begins_with("@") and sections[name] / 1000.0 >= largest_ms * 0.5 and (not largest.begins_with("@") or sections[name] / 1000.0 > largest_ms):
			largest = name; largest_ms = sections[name] / 1000.0
	var entry: Array = _spikes.get_or_add(largest, [0, 0.0, 0.0])
	entry[0] += 1; entry[1] += ms; entry[2] = maxf(entry[2], ms)
	if ms > 33.0 and "--server" in OS.get_cmdline_args():
		var parts: Array = []
		for name in sections:
			if name != "_top" and sections[name] >= 1000: parts.append("%s %.1f" % [name, sections[name] / 1000.0])
		print("PROFILE %s %s spike %.1f ms: %s" % [_role(), phase, ms, ", ".join(parts)])

func _play(now: int) -> void:
	if not _listening:
		_listening = true
		main.coop_game.session.message.connect(func(_peer, _actor, packet):
			if packet.get("kind") != "shared_commit" or not packet.get("result") is Dictionary: return
			for change in packet.result.get("changes", []):
				var parts := String(change.get("key", "")).split("/")
				var group := "/".join(parts.slice(0, 3 if parts[0] == "world" else 1))
				var entry: Array = _commits.get_or_add(group, [0, 0])
				entry[0] += 1; entry[1] += JSON.stringify(change).length())
	var walking := phase.begins_with("walk")
	if walking and (("split" in phase and index % 2 == 1) or "away" in phase) and not travelled:
		travelled = true
		_walk(false)
		main.edge_travel_busy = true
		await main._travel_adjacent_world(Vector2i.RIGHT)
		main.edge_travel_busy = false
		print("PROFILE %s travelled to %s" % [_role(), main.coop_game._area()])
	if walking and "long" in phase and travelled and not _back:
		_back = true
		_walk(false)
		main.edge_travel_busy = true
		await main._travel_adjacent_world(Vector2i.LEFT)
		main.edge_travel_busy = false
		print("PROFILE %s travelled back to %s" % [_role(), main.coop_game._area()])
	if main.edge_travel_busy: return
	if walking:
		# Back and forth along a row, as a player looking around would.
		if now - _walk_flip >= 2000: _walk_flip = now; _walk_dir = -_walk_dir
		_walk(true)
	else: _walk(false)
	# Where each other player is drawn this frame.
	for actor in main.coop_game.visuals.actors:
		var remote = main.coop_game.visuals.actors[actor]
		if not is_instance_valid(remote) or not is_instance_valid(remote.player) or not remote.player.sprite.visible: continue
		var at: Vector2 = remote.player.sprite.global_position
		if _seen.has(actor): _steps.append(at.distance_to(_seen[actor]))
		_seen[actor] = at

func _walk(on: bool) -> void:
	Input.action_release("move_left"); Input.action_release("move_right")
	if on: Input.action_press("move_right" if _walk_dir > 0 else "move_left")

func _report() -> void:
	var seconds := maxf(0.001, (Time.get_ticks_msec() - phase_started) / 1000.0)
	var stats: Dictionary = Transport.stats
	var lines: Array = []
	var keys: Array = stats.keys()
	keys.sort()
	var up := 0; var down := 0; var net_us := 0
	for key in keys:
		var e: Array = stats[key]
		if key == "tx": up += e[1]
		elif key.begins_with("rx:"): down += e[1]
		if key in ["proc:transport", "proc:players", "proc:remote"]: net_us += e[2]
		lines.append("PROFILE %s %s %-28s %8.1f/s %10.0f B/s %8.3f ms/s" % [_role(), phase, key, e[0] / seconds, e[1] / seconds, e[2] / 1000.0 / seconds])
	for line in lines: print(line)
	for group in _commits:
		print("PROFILE %s %s commits %-28s %8.1f/s %10.0f B/s" % [_role(), phase, group, _commits[group][0] / seconds, _commits[group][1] / seconds])
	var frames_n := maxi(1, frames)
	var smooth := ""
	if not _steps.is_empty():
		var sorted := _steps.duplicate(); sorted.sort()
		var big := 0
		for s in _steps: if s > 8.0: big += 1
		smooth = " remote steps %d, max %.1f px, p99 %.1f px, over 8 px %d" % [_steps.size(), sorted[-1], sorted[int(sorted.size() * 0.99)], big]
	# Timings a test build adds with Engine.set_meta("t_NAME", microseconds summed)
	# and "tmax_NAME" (the longest).
	for meta in Engine.get_meta_list():
		if String(meta).begins_with("tmax_"):
			print("PROFILE %s %s time %-24s %8.3f ms longest" % [_role(), phase, meta, int(Engine.get_meta(meta)) / 1000.0])
			Engine.set_meta(meta, 0)
		if String(meta).begins_with("t_"):
			print("PROFILE %s %s time %-24s %8.3f ms/frame" % [_role(), phase, meta, int(Engine.get_meta(meta)) / 1000.0 / frames_n])
			Engine.set_meta(meta, 0)
	var sorted_ms := _frame_ms.duplicate(); sorted_ms.sort()
	var median: float = sorted_ms[sorted_ms.size() / 2] if not sorted_ms.is_empty() else 0.0
	if not sorted_ms.is_empty():
		var over := [0, 0, 0]
		for ms in sorted_ms:
			for i in 3: if ms > [16.0, 33.0, 100.0][i]: over[i] += 1
		print("PROFILE %s %s FRAMES n %d mean %.2f p50 %.2f p95 %.2f p99 %.2f max %.1f ms, over 16/33/100 ms: %d/%d/%d" % [_role(), phase, sorted_ms.size(),
			process_ms / frames_n, median, sorted_ms[int(sorted_ms.size() * 0.95)], sorted_ms[int(sorted_ms.size() * 0.99)], sorted_ms[-1], over[0], over[1], over[2]])
	var costly: Array = _sections.keys().filter(func(name): return _sections[name] / 1000.0 / frames_n >= 0.05 and name != "_top")
	costly.sort_custom(func(a, b): return _sections[a] > _sections[b])
	for name in costly.slice(0, 15):
		print("PROFILE %s %s SECTION %-40s %8.3f ms/frame" % [_role(), phase, name, _sections[name] / 1000.0 / frames_n])
	if not _intervals.is_empty():
		var gaps := _intervals.duplicate(); gaps.sort()
		var long := [0, 0]
		for gap in gaps:
			if gap > 50.0: long[0] += 1
			if gap > 100.0: long[1] += 1
		print("PROFILE %s %s INTERVALS p50 %.1f p99 %.1f max %.1f ms, over 50/100 ms: %d/%d" % [_role(), phase, gaps[gaps.size() / 2], gaps[int(gaps.size() * 0.99)], gaps[-1], long[0], long[1]])
	for name in _spikes:
		print("PROFILE %s %s SPIKES %-40s %4d frames, %8.1f ms, longest %.1f ms" % [_role(), phase, name, _spikes[name][0], _spikes[name][1], _spikes[name][2]])
	print("PROFILE %s %s SUMMARY %.1f s, up %.0f B/s, down %.0f B/s, frames %.1f/s, process %.3f ms/frame (median %.2f, max %.1f), netcode %.3f ms/frame%s" % [
		_role(), phase, seconds, up / seconds, down / seconds, frames / seconds, process_ms / frames_n, median, max_frame_ms, net_us / 1000.0 / frames_n, smooth])
