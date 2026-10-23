# How another player's movement looks on this screen over a phone link: one
# process of remote_motion_test.py, a walker (--role=walker) or an observer
# (--role=observer), both real players joined to a real dedicated server
# through netem_proxy.py. They follow the phase the Python side writes to
# --phase=FILE and log, every frame, to --log=FILE (wall-clock ms):
#   W t x y            the walker's own trainer as drawn on its screen
#   E t name           an event of the walker's (teleport, ...)
#   O t x y vis        where the observer draws the walker (vis 0: culled)
#   M t x y            the walker's minimap marker on the observer's screen
#   C phase us calls   the observer's per-frame cost of the remote (proc:remote)
#   S t name           a contact sheet saved (windowed, --shots=DIR)
# Phases: walk (a loop walking, running, riding), teleport (4 tiles and back),
# away (walks off the observer's screen), far (walks about off it), zoom
# (the observer zooms out and back), back (walks back into view).
# --role=units (no network, no log file): remotes fed by hand on a made-up
# clock, checks printed as "MOTION U ok|FAIL ...".
extends SceneTree

const Transport = preload("res://scripts/coop_transport.gd")
const Remote = preload("res://scripts/coop_remote_player.gd")
var role := ""
var phase_file := ""
var log_file: FileAccess
var phase := ""
var phase_started := 0
var main: Node
var _checked := 0
var _placed := false
var _teleports := 0

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--role="): role = arg.trim_prefix("--role=")
		if arg.begins_with("--phase="): phase_file = arg.trim_prefix("--phase=")
		if arg.begins_with("--shots="): shots = arg.trim_prefix("--shots=")
		if arg.begins_with("--log="): log_file = FileAccess.open(arg.trim_prefix("--log="), FileAccess.WRITE)
	Transport.stats = {}
	change_scene_to_file("res://scenes/main.tscn")
	if role == "units":
		while current_scene == null or not current_scene.get("startup_complete"): await process_frame
		main = current_scene
		await process_frame
		var failed := _units()
		print("MOTION UNITS: %d failed" % failed)
		quit(1 if failed > 0 else 0)

func _now() -> float: return Time.get_unix_time_from_system() * 1000.0

func _line(text: String) -> void:
	if log_file == null: print("MOTION ", text)
	else: log_file.store_line(text)

func _process(_delta: float) -> bool:
	var now := Time.get_ticks_msec()
	if role == "units": return false
	if main == null and current_scene != null and current_scene.get("started"): main = current_scene
	if now - _checked >= 100:
		_checked = now
		var next := FileAccess.get_file_as_string(phase_file).strip_edges() if FileAccess.file_exists(phase_file) else ""
		if next != phase:
			if role == "observer" and phase_started > 0: _cost_report()
			phase = next; phase_started = now
			_line("P %.1f %s" % [_now(), phase])
			if phase == "done": log_file.flush(); quit(0)
	if main == null or not is_instance_valid(main) or not main.started: return false
	if role == "walker": _walk(now - phase_started)
	else: _observe()
	return false

## The walker's trainer is moved by the test, not by input: the same path
## every run whatever the map has there, with the game's own walking frames.
func _step(dir: Vector2, speed: float, running: bool, delta: float) -> void:
	var player: Node2D = main.world.player
	var before: Vector2 = player.position
	player.position += dir * speed * delta
	if dir != Vector2.ZERO: player.facing = dir
	player._advance_source_walk_frame(player.position.distance_to(before))
	player._update_sprite_frame(running)
	player._update_depth()
	player._apply_pixel_render_lock()

func _walk(ms: int) -> void:
	var player: Node2D = main.world.player
	# Whole pixels as on a phone; headless the screen is 100 px wide and the
	# game would round to a third of a tile.
	player.frame_locked = false
	player.set_process(false)
	if not _placed and phase == "setup":
		_placed = true
		player.position += Vector2(24, -56)
		_step(Vector2.ZERO, 0, false, 0)
	var at: Vector2 = player.sprite.global_position
	_line("W %.1f %.2f %.2f" % [_now(), at.x, at.y])
	var delta := _frame_delta()
	match phase:
		"walk":
			# Loops of four sides of 0.8 s: walking, running, at riding speed.
			var loop := (ms / 3200) % 3
			var side := (ms % 3200) / 800
			_step([Vector2.RIGHT, Vector2.DOWN, Vector2.LEFT, Vector2.UP][side], [60.0, 96.0, 120.0][loop], loop == 1, delta)
		"teleport":
			_step(Vector2.ZERO, 0, false, delta)
			if (ms > 1000 and _teleports == 0) or (ms > 2500 and _teleports == 1):
				_teleports += 1
				player.position += Vector2(64 if _teleports == 1 else -64, 0)
				_step(Vector2.ZERO, 0, false, 0)
				_line("E %.1f teleport" % _now())
		"away": _step(Vector2.RIGHT if ms < 4000 else Vector2.ZERO, 60.0, false, delta)
		"far": _step(Vector2.UP if (ms / 1000) % 2 == 0 else Vector2.DOWN, 60.0, false, delta)
		"back": _step(Vector2.LEFT if ms < 4000 else Vector2.ZERO, 60.0, false, delta)
		_: _step(Vector2.ZERO, 0, false, delta)

var _last_usec := 0
func _frame_delta() -> float:
	var now := Time.get_ticks_usec()
	var delta := 0.0 if _last_usec == 0 else minf(0.1, (now - _last_usec) / 1000000.0)
	_last_usec = now
	return delta

func _remote() -> Node:
	for actor in main.coop_game.visuals.actors:
		var remote = main.coop_game.visuals.actors[actor]
		if is_instance_valid(remote): return remote
	return null

func _observe() -> void:
	var camera: Camera2D = main.world.player.camera
	if phase == "zoom":
		var zoom := 0.5 if Time.get_ticks_msec() - phase_started < 2000 else 1.0
		if camera.zoom.x != zoom: camera.zoom = Vector2(zoom, zoom); _line("E %.1f zoom %.1f" % [_now(), zoom])
	var remote := _remote()
	if remote == null: return
	var at: Vector2 = remote.player.sprite.global_position
	_line("O %.1f %.2f %.2f %d" % [_now(), at.x, at.y, 1 if remote.visible else 0])
	if shots != "": _shoot(remote)
	for actor in main.minimap_others:
		var marker = main.minimap_others[actor]
		if is_instance_valid(marker): _line("M %.1f %.2f %.2f" % [_now(), marker.position.x, marker.position.y])

## Windowed (--shots=DIR): contact sheets of the screen, a frame per tile,
## from when the link has been quiet for 300 ms while walking (a stall, then
## the burst), from the frame zooming out shows the walker and from when it
## walks back in at the screen's edge.
var shots := ""
var _sheet: Image
var _sheet_frames := 0
var _sheet_name := ""
var _was_visible := true
var _sheets := 0
const CROP := Vector2i(96, 64)
var _crop_at := Vector2i.ZERO
var _seen_back := false

func _shoot(remote: Node) -> void:
	var now := Time.get_ticks_msec()
	var on_screen: Vector2 = main.world.get_viewport().get_canvas_transform() * remote.player.sprite.global_position
	if _sheet == null and _sheets < 6:
		if phase == "walk" and _sheets < 4 and now - int(remote._last_heard) > 300 and now - phase_started > 2000: _sheet_name = "stall_%d" % _sheets
		elif phase == "zoom" and remote.visible and not _was_visible: _sheet_name = "entry_zoom_%d" % _sheets
		# Walking back in: from when it reaches the screen's edge (it is shown
		# before that, in the margin).
		elif phase == "back" and remote.visible and on_screen.x < 330 and not _seen_back: _seen_back = true; _sheet_name = "entry_back_%d" % _sheets
		if _sheet_name != "": _sheet = Image.create(CROP.x * 4, CROP.y * 4, false, Image.FORMAT_RGB8); _sheet_frames = 0
	_was_visible = remote.visible
	if _sheet == null: return
	var frame := root.get_texture().get_image()
	frame.convert(Image.FORMAT_RGB8)
	frame.resize(320, 180, Image.INTERPOLATE_NEAREST)
	# The same piece of the screen in every tile (round the walker in the
	# first, inside the screen), so its moves from tile to tile show.
	if _sheet_frames == 0:
		_crop_at = (Vector2i(on_screen) - CROP / 2).clamp(Vector2i.ZERO, Vector2i(320, 180) - CROP)
	_sheet.blit_rect(frame, Rect2i(_crop_at, CROP), Vector2i((_sheet_frames % 4) * CROP.x, (_sheet_frames / 4) * CROP.y))
	_sheet_frames += 1
	if _sheet_frames >= 16:
		_sheet.resize(_sheet.get_width() * 3, _sheet.get_height() * 3, Image.INTERPOLATE_NEAREST)
		_sheet.save_png(shots.path_join(_sheet_name + ".png"))
		_line("S %.1f %s" % [_now(), _sheet_name])
		_sheet = null; _sheet_name = ""; _sheets += 1

func _cost_report() -> void:
	var entry: Array = Transport.stats.get("proc:remote", [0, 0, 0])
	_line("C %s %d %d" % [phase, entry[2], entry[0]])
	Transport.stats = {}

## Remotes fed by hand on a made-up clock (--role=units, no network): what a
## stall and the burst after it, a stop, a teleport and a remote off screen
## must look like. Returns the number of failed checks.
var _failed := 0
func _unit(ok: bool, text: String) -> void:
	_line("U %s %s" % ["ok" if ok else "FAIL", text])
	if not ok: _failed += 1

func _fresh() -> Node:
	var remote = Remote.new()
	main.world.add_child(remote); remote.configure(main); remote.set_process(false)
	return remote

func _view() -> Rect2:
	return main.world.get_viewport().get_canvas_transform().affine_inverse() * main.world.get_viewport().get_visible_rect()

func _make(sent: int, at: Vector2) -> Dictionary:
	return {"model": 0, "color": 0, "running": false, "move": "", "fx": 1, "fy": 0, "sent": sent, "bx": at.x, "by": at.y + 3,
		"parts": {"player": {"x": at.x, "y": at.y, "z": 0, "frame": 3, "hframes": 8, "vframes": 1, "flip_h": false, "ox": 0, "oy": 0, "centered": true}},
		"shadow": {}, "night": []}

## Feeds [sent, x, arrives] packets and draws a frame every 16 ms from 5000;
## returns the x drawn each frame from the first packet on.
var _drawn_at: Array = []
func _play(remote: Node, packets: Array, base: Vector2, frames: int) -> Array:
	var drawn: Array = []
	_drawn_at = []
	var clock := 5000
	for frame in frames:
		clock += 16
		while not packets.is_empty() and packets[0][2] <= clock:
			var p: Array = packets.pop_front()
			remote.receive(_make(p[0], base + (p[1] if p[1] is Vector2 else Vector2(p[1], 0))), clock)
		remote.advance(clock)
		if remote._frames.size() > 0:
			drawn.append(remote.player.sprite.global_position.x - base.x)
			_drawn_at.append(remote.player.sprite.global_position - base)
	return drawn

func _units() -> int:
	var camera: Camera2D = main.world.player.camera
	camera.make_current(); camera.force_update_scroll()
	var base: Vector2 = (_view().position + Vector2(16, _view().size.y / 2)).round()
	# Walking right at 60 px/s, a packet every 50 ms, 80 ms on the way; then
	# nothing for 600 ms, then all that was held back at once (TCP keeps order).
	var packets: Array = []
	for i in 100:
		var s := 100000 + i * 50
		packets.append([s, i * 3.0, maxi(s - 94920, 7180) if s >= 101500 else s - 94920])
	packets.append([105000, 297.0, 10080]) # stopped: the same pose once more
	var remote := _fresh()
	var drawn := _play(remote, packets, base, 400)
	var steps: Array = []
	for i in range(1, drawn.size()): steps.append(drawn[i] - drawn[i - 1])
	var backward := steps.filter(func(s): return s < -0.5).size()
	# Walking is 1 px a frame here; caught up at up to 1.5x, never a jump.
	_unit(steps.max() <= 2.0 and backward == 0 and drawn[-1] == 297.0, "stall+burst: biggest step %.1f px, backward %d, ends at %.1f of 297" % [steps.max(), backward, drawn[-1]])
	remote.free()
	# Stopping: the same pose sent once more; not carried on past it and back.
	packets.clear()
	for i in 22: packets.append([100000 + i * 50, minf(i, 20) * 3.0, 5080 + i * 50])
	remote = _fresh()
	drawn = _play(remote, packets, base, 120)
	_unit(drawn.max() <= 60.0 and drawn[-1] == 60.0, "stop: drawn up to %.1f px, stopped at 60, ends at %.1f" % [drawn.max(), drawn[-1]])
	remote.free()
	# Turning a corner while the link is held up: carried on past it by half a
	# tile at most, and eased back, not jumped.
	packets.clear()
	for i in 60:
		var s := 100000 + i * 50
		var at := Vector2(minf(i, 20) * 3.0, maxf(0, i - 20) * 3.0)
		packets.append([s, at, maxi(s - 94920, 6730) if s >= 101050 else s - 94920])
	packets.append([103000, Vector2(60, 117), 8080]) # stopped
	remote = _fresh()
	_play(remote, packets, base, 250)
	var past := 0.0
	var back := 0.0
	for i in range(1, _drawn_at.size()):
		past = maxf(past, _drawn_at[i].x - 60.0)
		back = minf(back, _drawn_at[i].x - _drawn_at[i - 1].x)
	_unit(past <= 8.0 and back >= -3.0 and _drawn_at[-1] == Vector2(60, 117), "corner in a stall: %.1f px past it, back %.1f px a frame at most, ends at %s" % [past, -back, _drawn_at[-1]])
	remote.free()
	# A teleport: 10 tiles in one packet is drawn there at once, not flown to.
	packets = [[100000, 0.0, 5080], [100050, 0.0, 5130], [100100, 160.0, 5180], [100150, 160.0, 5230]]
	remote = _fresh()
	drawn = _play(remote, packets, base, 40)
	var between := drawn.filter(func(v): return v > 0.0 and v < 160.0).size()
	_unit(between == 0 and drawn[-1] == 160.0, "teleport: %d frames between the two places, ends at %.1f" % [between, drawn[-1]])
	remote.free()
	# Off screen: hidden, cheaper, and back in the right place on coming into view.
	packets.clear()
	var far := _view().size.x
	for i in 400: packets.append([100000 + i * 50, far + i * 1.0, 5080 + i * 50])
	remote = _fresh()
	var clock := 5000
	var costs := [0, 0, 0, 0]
	for frame in 1000:
		clock += 16
		while not packets.is_empty() and packets[0][2] <= clock:
			var p: Array = packets.pop_front()
			remote.receive(_make(p[0], base + Vector2(p[1], 0)), clock)
		if frame == 300: camera.zoom = Vector2(0.25, 0.25); camera.force_update_scroll()
		var started := Time.get_ticks_usec()
		remote.advance(clock)
		var took := Time.get_ticks_usec() - started
		var shown := 1 if remote.visible else 0
		if frame > 20 and frame != 300: costs[shown * 2] += took; costs[shown * 2 + 1] += 1
		if frame == 299: _unit(not remote.visible, "far off screen it is hidden")
		if frame == 301:
			_unit(remote.visible, "zoomed out it is shown at once")
			var x: float = remote.player.sprite.global_position.x - base.x
			# Where the clock says, not where it was last drawn (never, off screen).
			var truth: float = far + (remote._clock - 100000.0) / 50.0
			_unit(absf(x - truth) <= 1.0, "and where it should be (%.1f, the clock says %.1f)" % [x, truth])
	camera.zoom = Vector2.ONE
	var off: float = costs[0] / maxf(1, costs[1]); var on: float = costs[2] / maxf(1, costs[3])
	_unit(off < on, "cost per frame off screen %.1f us, on screen %.1f us" % [off, on])
	remote.free()
	return _failed
