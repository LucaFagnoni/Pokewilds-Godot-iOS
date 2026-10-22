# Co-op traffic and CPU profile, one process of coop_net_profile.py: the
# dedicated server (--server) or a joining player (--join). Both follow the
# phase the Python side writes to --phase=FILE ("name"), and when it changes
# print the phase just ended: per message kind the count and bytes per second
# and the time spent encoding, decoding and applying (coop_transport.gd stats),
# and ms per frame (Performance TIME_PROCESS, the netcode's own share). A player
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

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--phase="): phase_file = arg.trim_prefix("--phase=")
		if arg.begins_with("--index="): index = int(arg.trim_prefix("--index="))
	Transport.stats = {}
	change_scene_to_file("res://scenes/main.tscn")

func _role() -> String:
	return "SERVER" if "--server" in OS.get_cmdline_args() else "CLIENT%d" % index

func _process(_delta: float) -> bool:
	var now := Time.get_ticks_msec()
	if main == null and current_scene != null and current_scene.get("started"): main = current_scene
	if phase_started > 0:
		frames += 1
		var ms := Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
		process_ms += ms
		max_frame_ms = maxf(max_frame_ms, ms)
		_frame_ms.append(ms)
	if now - _checked >= 200:
		_checked = now
		var next := FileAccess.get_file_as_string(phase_file).strip_edges() if FileAccess.file_exists(phase_file) else ""
		if next != phase:
			if phase_started > 0: _report()
			phase = next
			phase_started = now
			frames = 0; process_ms = 0.0; max_frame_ms = 0.0
			_steps.clear(); _seen.clear(); _frame_ms.clear(); _commits.clear()
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
	if main.edge_travel_busy: return
	if walking:
		# Back and forth along a row, as a player looking around would.
		if now - _walk_flip >= 2000: _walk_flip = now; _walk_dir = -_walk_dir
		_walk(true)
	else: _walk(false)
	# Where each other player is drawn this frame.
	for actor in main.coop_game.visuals.actors:
		var remote = main.coop_game.visuals.actors[actor]
		# Culled off screen (coop_remote_player.gd), not drawn: no step to count.
		if not is_instance_valid(remote) or not is_instance_valid(remote.player) or not remote.player.sprite.visible or not remote.visible: _seen.erase(actor); continue
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
	print("PROFILE %s %s SUMMARY %.1f s, up %.0f B/s, down %.0f B/s, frames %.1f/s, process %.3f ms/frame (median %.2f, max %.1f), netcode %.3f ms/frame%s" % [
		_role(), phase, seconds, up / seconds, down / seconds, frames / seconds, process_ms / frames_n, median, max_frame_ms, net_us / 1000.0 / frames_n, smooth])
