# Co-op actions timed on a real client: joins the server given by --join (the
# DedicatedServerSingleton does the join, as for `--join` players), then
# performs each action the way the game does it and measures, from the call
# to the result being applied here: the time, the bytes up and down (as sent
# on the wire; the "enc:" kinds in the notes are before packing), the
# requests sent (a save sent just in front of its command shares its round
# trip), and the longest frame (a frozen screen). Turned away, an action is
# tried again as a player would, and the time is to the try that worked.
# Before each action the player's step counter moves on, as a walking
# player's would: their record has changed and must be saved first.
# Started by coop_latency_probe.py, which puts netem_proxy.py in between:
#   godot --headless --path project -s ../server/coop_latency_probe.gd --join 127.0.0.1:PORT --data DIR -- --rtt=130
extends SceneTree

const Transport = preload("res://scripts/coop_transport.gd")
const REQUESTS := ["command", "profile_checkpoint", "storage_open", "area_request", "entered", "state_request"]
var main: Node
var coop: Node
var rtt := 0
var rows: Array = []
var over := 0
var _last_frame := 0
var _max_gap := 0

func _process(_delta: float) -> bool:
	var now := Time.get_ticks_msec()
	if _last_frame > 0: _max_gap = maxi(_max_gap, now - _last_frame)
	_last_frame = now
	return false

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--rtt="): rtt = int(arg.trim_prefix("--rtt="))
	create_timer(1500.0).timeout.connect(func(): printerr("PROBE timed out"); _finish())
	Transport.stats = {}
	change_scene_to_file("res://scenes/main.tscn")
	while current_scene == null or not current_scene.get("startup_complete"): await process_frame
	main = current_scene
	coop = main.coop_game
	var started := _begin()
	while not main.started:
		if not is_instance_valid(main): printerr("PROBE join failed"); _finish(); return
		await process_frame
	_end("join (world snapshot)", started, 20000)
	await _veteran()
	await _idle(3.0)
	if not "--skip-spawn" in OS.get_cmdline_user_args(): await _actions("spawn area, host simulates")
	# A new area: the server makes it, and this player alone simulates it.
	started = _begin()
	main.edge_travel_busy = true
	await main._travel_adjacent_world(Vector2i.RIGHT)
	main.edge_travel_busy = false
	_end("travel to a new area (server makes it)", started, 60000)
	await _idle(5.0)
	_background("background while alone in an area (5 s)")
	await _actions("own area, this player simulates")
	started = _begin()
	main.edge_travel_busy = true
	await main._travel_adjacent_world(Vector2i.LEFT)
	main.edge_travel_busy = false
	_end("travel back to a known area", started, 20000)
	_finish()

## A long-played character: the whole area explored, every Pokemon in the
## Pokedex, a full party and a full bag. Its record is what every save and
## battle result carries.
func _veteran() -> void:
	var bounds: Rect2i = main.world.get_map_bounds()
	for x in range(bounds.position.x, bounds.end.x):
		for y in range(bounds.position.y, bounds.end.y): main.world.discovered_cells.add(Vector2i(x, y))
	var species: Array = preload("res://scripts/pokemon_data.gd").all_species()
	for name in species:
		main.pokedex_progress.entries[name] = 2
		if not name in main.caught_species: main.caught_species.append(name)
	while main.caught_pokemon.size() < 5:
		main.caught_pokemon.append(preload("res://scripts/battle_engine.gd").make_pokemon(String(species[main.caught_pokemon.size() * 37 % species.size()]), 40, null, {}))
	for item in ["POKE BALL", "GREAT BALL", "ULTRA BALL", "LOG", "GRASS", "SOFT SAND", "HONEY", "CHARCOAL", "MANURE", "REPEL", "MAX REPEL", "RARE CANDY",
			"CLEAR GLASS", "BINDING BAND", "THIN PAPER", "OLD ROD", "METAL COAT", "MAGNET", "HARD STONE", "LIFE FORCE", "STARDUST", "STAR PIECE",
			"SILKY THREAD", "SOFT FEATHER", "POISON BARB", "BERRY JUICE", "ANCIENTPOWDER", "DRAGON SCALE", "NEVERMELTICE", "SPELL TAG"]:
		main.inventory[item] = 25
	var started := _begin()
	await coop.checkpoint_player()
	_end("veteran record saved once (whole)", started, 20000, "%d cells explored" % main.world.discovered_cells.size())

func _finish() -> void:
	print("PROBE %-46s %8s %8s %8s %8s %5s %8s %s" % ["action", "ms", "budget", "up B", "down B", "reqs", "frame ms", "notes"])
	for row in rows: print(row)
	print("PROBE RESULT: %d over budget" % over)
	quit(0)

## A step taken (the record has changed, as it would have) and the clock started.
func _begin() -> int:
	if main != null and main.started: main.friendship_step_timer = int(main.friendship_step_timer) + 1
	Transport.stats = {}
	_max_gap = 0
	return Time.get_ticks_msec()

func _end(action: String, started: int, budget: int = -1, note: String = "") -> void:
	var took := Time.get_ticks_msec() - started
	if budget < 0: budget = 3 * rtt + 300
	var up := 0; var down := 0; var requests := 0; var encoded := 0
	for key in Transport.stats:
		var entry: Array = Transport.stats[key]
		if key == "tx": up += entry[1]
		elif key.begins_with("rx:"): down += entry[1]
		elif key.begins_with("enc:"):
			encoded += entry[1]
			if key.trim_prefix("enc:") in REQUESTS: requests += entry[0]
	if not Transport.stats.has("tx"): up = encoded # a build that does not count frames sent
	var late := took > budget
	if late: over += 1
	# Where the bytes went, when there were many.
	if up + down > 32 * 1024:
		var kinds: Array = Transport.stats.keys()
		kinds.sort_custom(func(a, b): return Transport.stats[a][1] > Transport.stats[b][1])
		for kind in kinds.slice(0, 3): note += " %s=%dx%dB" % [kind, Transport.stats[kind][0], Transport.stats[kind][1]]
	rows.append("PROBE %-46s %8d %8d %8d %8d %5d %8d %s" % [action.left(46), took, budget, up, down, requests, _max_gap, ("OVER BUDGET " if late else "") + note])
	print(rows.back())

func _skip(action: String, why: String) -> void:
	rows.append("PROBE %-46s  skipped: %s" % [action.left(46), why]); print(rows.back())

func _background(label: String) -> void:
	var up := 0; var down := 0; var kinds := []; var encoded := 0
	for key in Transport.stats:
		if key == "tx": up += Transport.stats[key][1]
		elif key.begins_with("rx:"): down += Transport.stats[key][1]
		elif key.begins_with("enc:"): encoded += Transport.stats[key][1]
		kinds.append("%s=%d/%dB" % [key, Transport.stats[key][0], Transport.stats[key][1]])
	if not Transport.stats.has("tx"): up = encoded
	rows.append("PROBE %-46s up %d B, down %d B: %s" % [label, up, down, " ".join(kinds)]); print(rows.back())

func _idle(seconds: float) -> void:
	Transport.stats = {}
	await create_timer(seconds).timeout

func _wild_near(friendly: bool = false) -> int:
	var here: Vector2i = main.world._player_cell()
	var best := -1; var best_distance := 1 << 30
	var records: Dictionary = coop.shared_records
	for wild_id in main.world.wild_pokemon:
		var data: Dictionary = main.world.wild_pokemon[wild_id]
		if data.get("ball_reserved", false) or records.has("wild_claim/" + coop._area() + "/" + str(wild_id)): continue
		if not records.has("world/%s/wild_pokemon/%s" % [coop._area(), wild_id]): continue
		if friendly and preload("res://scripts/pokemon_ecology.gd").wild_interaction_kind(String(data.get("species", ""))) != "FRIENDLY": continue
		var distance: int = Vector2i(data.get("cell", Vector2i.ZERO)).distance_squared_to(here)
		if distance < best_distance: best = wild_id; best_distance = distance
	return best

## A free cell beside the player (actions on the ground are allowed within one step).
func _free_cell(skip: Vector2i = Vector2i(999999, 999999)) -> Vector2i:
	var here: Vector2i = main.world._player_cell()
	for step in [Vector2i.RIGHT, Vector2i.LEFT, Vector2i.DOWN, Vector2i.UP]:
		var cell: Vector2i = here + step
		# Not where an egg or a habitat Pokemon lies: the host turns a build there away until it goes.
		if cell != skip and main.world.dropped_items().can_drop(cell) and not main.world.built_structures.has(cell) 				and not main.world.wild_eggs.has(cell) and not main.world.deployed_pokemon.has(cell): return cell
	return Vector2i(999999, 999999)

## Does `attempt` (a coroutine that returns true once it worked) as a player
## would: again every quarter of a second while it is turned away, for up to
## RETRY_MS. The time is to the try that worked.
const RETRY_MS := 30000
func _try(action: String, attempt: Callable, budget: int = -1) -> bool:
	var started := _begin()
	var tries := 0
	var ok := false
	while true:
		tries += 1
		ok = await attempt.call()
		if ok or Time.get_ticks_msec() - started > RETRY_MS: break
		await create_timer(0.25).timeout
	if not ok: over += 1
	_end(action, started, budget, ("" if tries == 1 else "%d tries " % tries) + ("" if ok else "FAILED"))
	return ok

var _cell := Vector2i.ZERO
var _box := ""
var _hole := Vector2i(999999, 999999)

## Stands the player where the four cells around are open ground, as one
## would before building or dropping something, and lets the host see it.
func _open_ground() -> void:
	var world: Node = main.world
	for centre in [world._player_cell(), world.spawn_cell]:
		for radius in range(0, 40):
			for dx in range(-radius, radius + 1):
				for dy in range(-radius, radius + 1):
					if maxi(absi(dx), absi(dy)) != radius: continue
					var cell: Vector2i = centre + Vector2i(dx, dy)
					var open: bool = world._is_walkable(cell)
					for step in [Vector2i.RIGHT, Vector2i.LEFT, Vector2i.DOWN, Vector2i.UP]:
						open = open and world._is_walkable(cell + step) and world.dropped_items().can_drop(cell + step) and not world.built_structures.has(cell + step)
					if open:
						world.player.position = world._cell_center(cell)
						await create_timer(1.0).timeout
						return
	print("PROBE note: no open ground near ", world._player_cell())

func _actions(where: String) -> void:
	rows.append("PROBE ---- " + where)
	await _open_ground()
	# Room for the catch and the friendly one.
	while main.caught_pokemon.size() > 4: main.caught_pokemon.pop_back()
	main.caught_pokemon[0]["nickname"] = "PROBE%d" % randi_range(0, 999)
	await _try("party edit saved (evolve, level, nickname)", func() -> bool: return await coop.checkpoint_player())
	await _try("wild battle start", _battle_start)
	if main.battle_active:
		await _try("battle end (ran)", func() -> bool:
			await main._end_battle("ran")
			return not main.battle_active and coop.wild.encounter.is_empty())
	await _idle(1.0)
	await _try("catch (claim + result)", _catch)
	if _wild_near(true) < 0: _skip("friendly Pokemon joins the party", "no friendly one near")
	else: await _try("friendly Pokemon joins the party", _recruit)
	await _idle(1.0)
	if main.caught_pokemon.size() < 2: _skip("release from the party", "one Pokemon")
	else:
		main.caught_pokemon.remove_at(main.caught_pokemon.size() - 1)
		await _try("release from the party", func() -> bool: return await coop.checkpoint_player())

	main.inventory["POKE BALL"] = int(main.inventory.get("POKE BALL", 0)) + 5
	main.inventory["LOG"] = int(main.inventory.get("LOG", 0)) + 8
	_cell = _free_cell()
	if await _try("drop an item", func() -> bool: return await coop.drop_item("POKE BALL", 1, _cell)):
		await _try("pick up an item", func() -> bool:
			var drops: Node = main.world.dropped_items()
			var pile: Dictionary = drops.records.get(drops.key(_cell), {})
			if pile.has("coop_id"): await coop.pickup_item(pile)
			return not drops.records.get(drops.key(_cell), {}).has("coop_id"))

	# The ground, decided by the host (rules/): a hole dug and grass cut, shown
	# at once and kept when the host agrees; the reward is the host's own roll,
	# in the record it sends back.
	await _try("dig a hole (host decides the reward)", _dig)
	if _hole.x == 999999: _skip("fill it with soil the host has not seen", "no hole dug")
	else: await _try("fill it with soil the host has not seen", _fill)
	if _grass_near().x == 999999: _skip("cut grass (host decides the reward)", "no grass near")
	else: await _try("cut grass (host decides the reward)", _cut)
	await _try("refused dig put back (session goes on)", _refused_dig)

	_box = ""
	if await _try("build a storage box", _build_box):
		var box := _box
		await _try("open storage", func() -> bool: return coop.storage.known(box) or await coop.storage.prepare())
		# A long-played box: 200 Pokemon, stored the way catches with a full party are.
		var species: Array = preload("res://scripts/pokemon_data.gd").all_species()
		for i in 200:
			coop.storage.pending.append({"id": preload("res://scripts/coop_random.gd").hex(16), "box": box,
				"pokemon": preload("res://scripts/battle_engine.gd").make_pokemon(String(species[i * 7 % species.size()]), 30, null, {})})
		await _try("store 200 Pokemon in the box (setup)", func() -> bool:
			return await coop.checkpoint_player() and coop.shared_records.get("box/" + box, []).size() >= 200, 30000)
		if main.caught_pokemon.size() >= 2:
			await _try("deposit into the box", func() -> bool:
				return (await coop.command("deposit", {"box": box, "slot": main.caught_pokemon.size() - 1, "pooled": false})).get("ok", false))
		await _try("withdraw from the box", func() -> bool:
			var entries: Array = coop.shared_records.get("box/" + box, [])
			return not entries.is_empty() and (await coop.command("withdraw", {"box": box, "pokemon": String(entries[0].id), "pooled": false})).get("ok", false))
		await _try("release from the box", func() -> bool:
			var entries: Array = coop.shared_records.get("box/" + box, [])
			return not entries.is_empty() and (await coop.command("storage_edit", {"box": box, "pokemon": String(entries[entries.size() / 2].id), "pooled": false, "action": "RELEASE", "value": ""})).get("ok", false))
		# A second box, to take down (the last public box stays).
		_box = ""
		if await _try("build another", _build_box):
			var at: Vector2i = main.world._snap_build_cell("STORAGE BOX", _cell)
			await _try("remove a build", func() -> bool:
				await coop.building.remove(at, "CUT")
				return not main.world.built_structures.has(at))
	# Several of the player's own builds at once (each predicted in its own
	# undo log), the middle one too far for the host to allow.
	# The bag saved first (setup): a command that pays then has nothing to save ahead of it, and all three go at once.
	for item in ["LOG", "GRASS"]: main.inventory[item] = int(main.inventory.get(item, 0)) + 3
	await _try("bag saved (setup)", func() -> bool: return await coop.checkpoint_player(), 20000)
	await _try("three builds in flight, the middle refused", _builds_in_flight)

	if main.caught_pokemon.size() >= 2:
		var left_at: Vector2i = main.world._player_cell() + main.world._facing_cell()
		if await _try("leave a Pokemon here", func() -> bool:
				await coop.population.deploy(main.caught_pokemon.size() - 1, false)
				return coop.population.last_result.get("ok", false)):
			# As a player does: it is asked for on the tile it was seen on, after
			# it has walked about for a while (and while the request travels).
			var identity := ""
			for key in coop.record_keys("world/%s/deployed_pokemon/" % coop._area()):
				var record = preload("res://scripts/coop_world_delta.gd").decode(coop.shared_records.get(key))
				if record is Dictionary and String(record.get("ecology_id", "")).begins_with("coop_owned:" + coop.session.actor + ":"): identity = String(record.ecology_id)
			var steps := 0
			var last := _where(identity)
			for tick in 40:
				await create_timer(0.25).timeout
				if _where(identity) != last: steps += 1; last = _where(identity)
			var before: int = main.caught_pokemon.size()
			if await _try("call it back (%d steps, now %d away)" % [steps, maxi(absi(last.x - left_at.x), absi(last.y - left_at.y))], func() -> bool:
					await coop.population.recall(left_at, "deployed_pokemon", identity)
					return coop.population.last_result.get("ok", false)):
				await _idle(3.0)
				# Gone from the world for good: not left behind, not sent back as a second one.
				if _where(identity).x != 999999 or main.caught_pokemon.size() != before + 1: over += 1; _skip("called back cleanly", "FAILED: still in the world or not in the party")
				else: _skip("called back cleanly", "ok, one try, none left behind")
	await _try("save (menu)", func() -> bool: return await coop.save_game(main._capture_game_save()))

## Where the habitat Pokemon with this id stands, in this game or the records.
func _where(identity: String) -> Vector2i:
	for cell in main.world.deployed_pokemon:
		if String(main.world.deployed_pokemon[cell].get("ecology_id", "")) == identity: return cell
	for key in coop.record_keys("world/%s/deployed_pokemon/" % coop._area()):
		var record = preload("res://scripts/coop_world_delta.gd").decode(coop.shared_records.get(key))
		if record is Dictionary and String(record.get("ecology_id", "")) == identity: return Vector2i(int(record.x), int(record.y))
	return Vector2i(999999, 999999)

func _battle_start() -> bool:
	var wild_id := _wild_near()
	if wild_id < 0: return false
	var started := Time.get_ticks_msec()
	await coop.wild.begin_encounter(wild_id, false)
	while not main.battle_active and (main.battle_entry_pending or coop.wild.encounter_pending) and Time.get_ticks_msec() - started < 30000: await process_frame
	return main.battle_active

func _catch() -> bool:
	var wild_id := _wild_near()
	if wild_id < 0: return false
	var species := String(main.world.wild_pokemon[wild_id].get("species", "pidgey"))
	if not await coop.wild.reserve(wild_id): return false
	main.world.wild_pokemon.erase(wild_id)
	main._route_received_pokemon(preload("res://scripts/battle_engine.gd").make_pokemon(species.to_lower(), 5, null, {}))
	return await coop.wild.finish_encounter("captured")

func _recruit() -> bool:
	var wild_id := _wild_near(true)
	if wild_id < 0: return false
	var before: int = main.caught_pokemon.size()
	var record: Dictionary = main.world.wild_pokemon[wild_id].duplicate()
	await main._recruit_friendly_wild(wild_id, String(main.world.wild_pokemon[wild_id].get("species", "")))
	if main.caught_pokemon.size() <= before:
		print("PROBE note: recruit of ", wild_id, " ", record.get("species"), " at ", record.get("cell"), " from ", main.world._player_cell(), " failed: refused=", coop.wild.refused, " still there=", main.world.wild_pokemon.has(wild_id), " burrowed=", record.get("burrowed", false))
	return main.caught_pokemon.size() > before

const TileRules = preload("res://scripts/rules/tile_rules.gd")

## A hole dug beside the player: true once the host kept it and its reward
## (the ground's material) is in the bag the host sent back.
func _dig() -> bool:
	var world: Node = main.world
	var here: Vector2i = world._player_cell()
	# Corners first: the cells straight ahead are where later actions put things.
	for step in [Vector2i(1, 1), Vector2i(-1, 1), Vector2i(1, -1), Vector2i(-1, -1), Vector2i(2, 2), Vector2i(-2, 2)]:
		var cell: Vector2i = here + step
		var tile: SourceTile = world.area.tile_at(cell)
		if tile == null or not TileRules.dig_surface_ok(tile) or TileRules.accepts_soil(world.area, cell) or TileRules.is_mountain(tile): continue
		if world.built_structures.has(cell) or world.landmarks.has(cell) or TileRules.exact_resource_anchor(world.area, cell).x > -2147483648: continue
		if not world.dropped_items().can_drop(cell) or not String(tile.has_item).is_empty(): continue
		var material := TileRules.dig_material_at(world.area, cell)
		var before := int(main.inventory.get(material, 0))
		await coop.building.dig(cell)
		var key := "world/%s/source_interior_mutations/%s" % [coop._area(), ("%d,%d" % [cell.x, cell.y]).uri_encode()]
		var dug: bool = world.area.tile_at(cell).name_upper.begins_with("hole1") and coop.shared_records.has(key) and int(main.inventory.get(material, 0)) == before + 1
		if dug: _hole = cell
		return dug
	return false

## The hole filled with FOREST ground, paid with GRASS this game has and the
## host's copy of its record does not yet (the bag is saved just ahead of a
## command that pays): true once the host kept it, one GRASS gone and the bag
## the record's.
func _fill() -> bool:
	if not main.world.area.tile_at(_hole).name_upper.begins_with("hole1"): return false
	main.inventory["GRASS"] = int(main.inventory.get("GRASS", 0)) + 2
	var grass := int(main.inventory["GRASS"])
	await coop.building.dig(_hole, "FOREST")
	var tile: SourceTile = main.world.area.tile_at(_hole)
	var record: Dictionary = coop.shared_records.get("player/" + coop.session.actor, {})
	var same := _same_bag(record.get("inventory", {}), main.inventory)
	if not same: print("PROBE note: after the fill the bag is not the record's: ", main.inventory.get("GRASS"), " / ", record.get("inventory", {}).get("GRASS"))
	return tile.name == "green1" and not tile.name_upper.begins_with("hole1") and int(main.inventory.get("GRASS", 0)) == grass - 1 and same

## Two bags alike item by item (one that came as JSON counts in floats).
static func _same_bag(a: Dictionary, b: Dictionary) -> bool:
	for item in a.keys() + b.keys():
		if int(a.get(item, 0)) != int(b.get(item, 0)): return false
	return true

## A DIG the host turns away (the cell is too far from the player to reach):
## shown here at once, then undone exactly, and the game plays on.
func _refused_dig() -> bool:
	var world: Node = main.world
	var here: Vector2i = world._player_cell()
	var far: Array = []
	for distance in range(9, 24):
		for direction in [Vector2i.RIGHT, Vector2i.LEFT, Vector2i.DOWN, Vector2i.UP]: far.append(here + direction * distance)
	for cell in far:
		var tile: SourceTile = world.area.tile_at(cell)
		if tile == null or not TileRules.dig_surface_ok(tile) or TileRules.accepts_soil(world.area, cell) or TileRules.is_mountain(tile): continue
		if world.built_structures.has(cell) or world.landmarks.has(cell) or TileRules.exact_resource_anchor(world.area, cell).x > -2147483648: continue
		var upper: String = tile.name_upper
		var answer: Dictionary = await coop.rules.predict("field_dig", {"action":"dig", "cell":cell})
		var put_back: bool = not answer.get("ok", true) and answer.get("reason") == "too_far" and world.area.tile_at(cell).name_upper == upper and coop.active
		if not put_back: print("PROBE note: refused dig at ", cell, " from ", here, ": ", answer.get("ok"), " ", answer.get("reason", ""), " ", world.area.tile_at(cell).name_upper, " / ", upper)
		return put_back
	print("PROBE note: no ground far enough to dig from ", here)
	return false

func _grass_near() -> Vector2i:
	var world: Node = main.world
	var here: Vector2i = world._player_cell()
	for radius in range(1, 4):
		for dx in range(-radius, radius + 1):
			for dy in range(-radius, radius + 1):
				var cell: Vector2i = here + Vector2i(dx, dy)
				if maxi(absi(dx), absi(dy)) == radius and world._is_cuttable_grass_cell(cell) and not world.built_structures.has(cell): return cell
	return Vector2i(999999, 999999)

## Grass cut near the player: true once the host kept it and the GRASS is in the bag.
func _cut() -> bool:
	var cell := _grass_near()
	if cell.x == 999999: return false
	var before := int(main.inventory.get("GRASS", 0))
	await coop.building.cut(cell)
	return not main.world._is_cuttable_grass_cell(cell) and int(main.inventory.get("GRASS", 0)) > before

## Three FENCEs sent one after another without waiting for an answer, the
## middle one out of reach: the first and last kept, the middle one undone
## (the last played again over it), two paid for and the bag the record's;
## then both cut, two at once. True when all of it holds.
func _builds_in_flight() -> bool:
	var world: Node = main.world
	var here: Vector2i = world._player_cell()
	var near: Array = []
	for step in [Vector2i.RIGHT, Vector2i.LEFT, Vector2i.DOWN, Vector2i.UP]:
		var cell: Vector2i = here + step
		if world.can_place_structure("FENCE", cell) and not world.wild_eggs.has(cell) and not world.deployed_pokemon.has(cell): near.append(cell)
	var far := Vector2i(999999, 999999)
	for distance in range(9, 24):
		for direction in [Vector2i.RIGHT, Vector2i.LEFT, Vector2i.DOWN, Vector2i.UP]:
			if far.x == 999999 and world.can_place_structure("FENCE", here + direction * distance): far = here + direction * distance
	if near.size() < 2 or far.x == 999999:
		print("PROBE note: no room for three FENCEs near ", here)
		return false
	var logs := int(main.inventory.get("LOG", 0))
	coop.building.build("FENCE", near[0])
	coop.building.build("FENCE", far)
	coop.building.build("FENCE", near[1])
	var at_once: int = coop.building.in_flight
	while coop.building.busy: await process_frame
	var record: Dictionary = coop.shared_records.get("player/" + coop.session.actor, {})
	var kept: bool = world.built_structures.has(near[0]) and world.built_structures.has(near[1]) and not world.built_structures.has(far)
	var paid := int(main.inventory.get("LOG", 0)) == logs - 2 and _same_bag(record.get("inventory", {}), main.inventory)
	if not (kept and paid and at_once == 3): print("PROBE note: in flight ", at_once, ", kept ", kept, ", LOG ", logs, " -> ", main.inventory.get("LOG"), " / ", record.get("inventory", {}).get("LOG"))
	coop.building.remove(near[0], "CUT")
	coop.building.remove(near[1], "CUT")
	while coop.building.busy: await process_frame
	var cut: bool = not world.built_structures.has(near[0]) and not world.built_structures.has(near[1]) and int(main.inventory.get("LOG", 0)) == logs
	return kept and paid and at_once == 3 and cut and not world.area.recording()

func _build_box() -> bool:
	_cell = _free_cell(_cell)
	var known: Array = main._built_storage_keys()
	await coop.building.build("STORAGE BOX", _cell)
	for key in main._built_storage_keys():
		if not key in known and coop.shared_records.has("chest/" + key): _box = key
	return not _box.is_empty()
