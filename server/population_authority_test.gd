# A dedicated server as the authority of every area's Pokemon
# (coop_population_authority.gd, area_sim.gd), without a network: two areas
# the server holds without drawing them, each with wild Pokemon, a pair left
# in a habitat and an egg in its records and a player in it. The server runs
# both (within its frame budget); what it sends (binary motion frames and
# commits) laid on each player's copy of its area leaves every Pokemon where
# the server has it, and the server's frames are only those it may send.
# Players' commands with the server the authority: a claim holds a Pokemon
# still and out of what is sent, a battle run from puts it back where the
# server has it, a catch or a friendly one recruited takes it away, a habitat
# Pokemon called back after it walked on (its step not yet sent) is gone and
# not sent back, one left in a habitat is run there, an egg taken angers its
# parents. Authority: the server is every area's (coop_state.gd
# fixed_authority) whoever comes and goes; with players as authorities (a
# phone hosting) an area passes to the next player with a new epoch and the
# one before may no longer send it.
# Run: godot --headless --path project -s ../server/population_authority_test.gd
#      (headless needs project/override.cfg: [physics] 2d/physics_engine="Dummy")
extends SceneTree

const AreaSim = preload("res://scripts/area_sim.gd")
const State = preload("res://scripts/coop_state.gd")
const Areas = preload("res://scripts/coop_areas.gd")
const Delta = preload("res://scripts/coop_world_delta.gd")
const Population = preload("res://scripts/coop_wild_population.gd")
const Records = preload("res://scripts/coop_population_records.gd")
const WildPopulation = preload("res://scripts/wild_population.gd")
const Wire = preload("res://scripts/area_state.gd")
const Authority = preload("res://scripts/coop_population_authority.gd")
const Hordes = preload("res://scripts/coop_horde_runtime.gd")
const AREAS := ["1,0", "0,1"]
const PLAYERS := {"1,0": "alice", "0,1": "bob"}
const SPECIES := ["rattata", "pidgey", "caterpie", "zubat", "oddish", "sentret"]

var failed := 0
var checks := 0
var state: State
var game: FakeGame
var authority: Authority
## area -> the player's copy of it: wild id -> cell, habitat cell -> ecology id, egg cells.
var copies := {}

func check(ok: bool, what: String) -> void:
    checks += 1
    if not ok:
        failed += 1
        printerr("POPULATION AUTHORITY TEST FAIL: ", what)

## The host's side the authority talks to (coop_game.gd), without a network:
## what it sends is kept to be laid on the players' copies.
class FakeGame extends Node:
    var active := true
    var hosting := true
    var main := {"started": true}
    var state
    var rules := FakeRules.new()
    var clock_seconds := 1000.0
    var visuals := {"last_packets": {}}
    var wild := FakeWild.new()
    var service := {"areas": {"epochs": {}}}
    var session := {"actor": "server"}
    var hordes
    var authority
    ## What went out to the players, in order: ["commit", result] and
    ## ["motion", sender, area, motion, frame].
    var sent: Array = []
    var serial := 0
    func _area() -> String: return "0,0"
    func nobody_here() -> bool: return true
    func _id() -> String:
        serial += 1
        return "t%d" % serial
    func _committed(result: Dictionary) -> void:
        sent.append(["commit", result])
        authority.committed(result)
    func record_keys(prefix: String) -> Array:
        return state.records.keys().filter(func(key): return String(key).begins_with(prefix))

class FakeRules extends RefCounted:
    var sims := {}
    func load_area(_area: String) -> void: pass

class FakeWild extends RefCounted:
    var moved := {}
    var sent: Array
    var next_id := 4294967296
    func allocate_id() -> int:
        next_id += 1
        return next_id
    func relay_motion(actor: String, area: String, motion: PackedByteArray, frame: PackedByteArray, _entries: Array = []) -> void:
        sent.append(["motion", actor, area, motion, frame])

## A 40x30 area of grass and ground with a pond, as an exact world's store.
static func area_sim(area: String) -> AreaSim:
    var store := WorldTileStore.with_bounds(Rect2i(0, 0, 40, 30))
    var route := SourceRoute.new("forest1", 12)
    for y in 30:
        for x in 40:
            var cell := Vector2i(x, y)
            var water := x >= 30 and y >= 20
            var tile := SourceTile.new("water2" if water else ("grass1" if (x + y) % 3 == 0 else "green1"), cell * 16, "", false, route)
            tile.biome = "forest"
            store._write(cell * 16, tile)
    var adapter := SourceExactWorldAdapter.new()
    adapter.tiles = store
    adapter.bottom_left_cell = Vector2i.ZERO
    adapter.top_right_cell = Vector2i(39, 29)
    var sim := AreaSim.new()
    sim.state.area = area
    sim.state.tiles = adapter
    sim.state.bounds = adapter.bounds()
    sim.state.rng.seed = area.hash()
    sim.state.tracking = true
    return sim

func _setup() -> void:
    state = State.new()
    state.fixed_authority = "server"
    for actor in ["server", "alice", "bob"]:
        state.enroll(actor, {"name": actor})
        state.records["player/" + actor] = {"party": [{"species": "slowpoke", "level": 20}], "inventory": {}, "save": {}}
    state.enter("server", "0,0")
    var changes: Array = []
    var next_id := 1
    for area in AREAS:
        changes.append(state.change("world_ready/" + area, true))
        changes.append(state.change("area/" + area, {"seed": 1, "size": 0, "sha256": "x"}))
        for index in 12:
            var cell := Vector2i(6 + (index % 6) * 3, 6 + (index / 6) * 4)
            var record := {"id": next_id, "species": SPECIES[index % SPECIES.size()], "level": 5 + index, "x": cell.x, "y": cell.y,
                "home_biome": "FOREST", "source_record": {}, "gender": "male" if index % 2 == 0 else "female", "shiny": false}
            changes.append(state.change(Population.record_key(area, next_id), Delta.encode(record)))
            next_id += 1
        for pair in 2:
            var cell := Vector2i(10 + pair, 18)
            var habitat := {"species": "rattata", "level": 12, "gender": "female" if pair == 0 else "male", "x": cell.x, "y": cell.y,
                "ecology_id": "coop_owned:%s:%d" % [PLAYERS[area], pair], "shiny": false}
            changes.append(state.change(Records.key(area, "deployed_pokemon", cell), Delta.encode(habitat)))
        var egg := {"species": "pidgey", "x": 20, "y": 20, "is_egg": true, "parent_ids": ["wild:1", "wild:2"], "egg_groups": ["EGG_FLYING", "EGG_FLYING"]}
        changes.append(state.change(Records.key(area, "wild_eggs", Vector2i(20, 20)), Delta.encode(egg)))
    check(state.transact("server", "setup", changes).get("ok", false), "the areas' records are written")
    game = FakeGame.new()
    game.state = state
    game.wild.sent = game.sent
    authority = Authority.new()
    authority.configure(game)
    authority.enabled = true
    game.authority = authority
    game.hordes = Hordes.new()
    game.hordes.configure(game)
    root.add_child(game)
    root.add_child(authority)
    for area in AREAS:
        game.rules.sims[area] = area_sim(area)
        copies[area] = _copy_of(area)

## A player's copy of `area` from the records, as a joining game reads it.
func _copy_of(area: String) -> Dictionary:
    var copy := {"wild": {}, "habitat": {}, "eggs": {}}
    var prefix := "world/" + area + "/"
    for key in state.records:
        if not String(key).begins_with(prefix): continue
        _lay(copy, String(key), state.records[key])
    return copy

## One record change laid on a player's copy (coop_wild_runtime.gd and
## coop_population_runtime.gd committed, for where things are).
func _lay(copy: Dictionary, key: String, encoded: Variant) -> void:
    var group := key.get_slice("/", 2)
    var name := key.get_slice("/", 3).uri_decode()
    var value = Delta.decode(String(encoded)) if encoded is String else null
    match group:
        "wild_pokemon":
            if value is Dictionary: copy.wild[int(name)] = Vector2i(int(value.x), int(value.y))
            else: copy.wild.erase(int(name))
        "deployed_pokemon":
            if value is Dictionary: copy.habitat[Wire.key_cell(name)] = String(value.get("ecology_id", ""))
            else: copy.habitat.erase(Wire.key_cell(name))
        "wild_eggs":
            if value is Dictionary: copy.eggs[Wire.key_cell(name)] = true
            else: copy.eggs.erase(Wire.key_cell(name))

## What the server sent since the last call laid on the players' copies, in
## the order it went out (motion frames and commits).
func _deliver() -> int:
    var moves := 0
    for item in game.sent:
        if item[0] == "motion":
            check(item[1] == "server", "motion is sent as the server's own")
            var read: Dictionary = Wire.decode_motion(item[4])
            check(read.get("area") == item[2] and read.get("motion", []).size() > 0, "a motion frame reads back")
            for entry in read.get("motion", []):
                if copies[item[2]].wild.has(int(entry.id)): copies[item[2]].wild[int(entry.id)] = Vector2i(int(entry.x), int(entry.y))
                moves += 1
            continue
        for change in item[1].get("changes", []):
            var key := String(change.key)
            if key.begins_with("world/") and copies.has(key.get_slice("/", 1)): _lay(copies[key.get_slice("/", 1)], key, change.after)
    game.sent.clear()
    return moves

## `seconds` of the server's frames at 30 a second, every beat allowed to
## send (or, with `send` false, none: what changes waits).
func _run(seconds: float, send := true) -> int:
    var sent := 0
    for frame in int(seconds * 30.0):
        for beat in authority._beats.values():
            beat.motion_at = -1000000 if send else Time.get_ticks_msec() + 1000000
            beat.habitat_at = -1000000 if send else Time.get_ticks_msec() + 1000000
        authority._process(1.0 / 30.0)
        game.clock_seconds += 1.0 / 30.0
        if send: sent += _deliver()
    return sent

func _packets(at: Dictionary) -> void:
    game.visuals.last_packets.clear()
    for area in at:
        var cell: Vector2i = at[area]
        game.visuals.last_packets[PLAYERS[area]] = {"area": area, "layer": "OVERWORLD", "cell_x": cell.x, "cell_y": cell.y,
            "battle": false, "visual": {"move": ""}, "field_level": 1, "party_level": 10}

func _sim(area: String) -> AreaSim:
    return game.rules.sims[area]

## Where the server has the habitat Pokemon with this ecology id.
static func _habitat_cell(sim: AreaSim, identity: String) -> Vector2i:
    for cell in sim.state.habitat.records:
        if String(sim.state.habitat.records[cell].get("ecology_id", "")) == identity: return cell
    return Vector2i(-1, -1)

## Every Pokemon of the area where the server has it, in the player's copy.
func _same(area: String, what: String) -> void:
    var sim := _sim(area)
    var copy: Dictionary = copies[area]
    var wrong := []
    for wild_id in sim.state.wild.records:
        var cell: Vector2i = sim.state.wild.records[wild_id].cell
        if copy.wild.get(wild_id) != cell: wrong.append([wild_id, cell, copy.wild.get(wild_id)])
    for wild_id in copy.wild:
        if not sim.state.wild.has(wild_id): wrong.append([wild_id, "gone", copy.wild[wild_id]])
    var habitat := {}
    for cell in sim.state.habitat.records: habitat[cell] = String(sim.state.habitat.records[cell].get("ecology_id", ""))
    if habitat != copy.habitat: wrong.append(["habitat", habitat, copy.habitat])
    var eggs := {}
    for cell in sim.state.eggs.records: eggs[cell] = true
    if eggs != copy.eggs: wrong.append(["eggs", eggs, copy.eggs])
    check(wrong.is_empty(), "%s: area %s as the server has it on its player's game (%s)" % [what, area, str(wrong).left(400)])

func _initialize() -> void:
    create_timer(300.0).timeout.connect(func(): printerr("POPULATION AUTHORITY TEST FAIL: timed out"); quit(2))
    await process_frame
    _setup()
    state.enter("alice", "1,0")
    state.enter("bob", "0,1")
    check(state.authority.get("1,0") == "server" and state.authority.get("0,1") == "server", "the server is the authority of the players' areas")
    _packets({"1,0": Vector2i(12, 10), "0,1": Vector2i(15, 12)})

    # The areas' Pokemon are read in a few at a time, then run.
    var sim := _sim("1,0")
    sim.begin_population(game.record_keys("world/1,0/"))
    check(not sim.load_population(state.records, Time.get_ticks_usec()), "with no time left, nothing is read")
    sim.begin_population([])
    _run(1.0)
    for area in AREAS:
        check(_sim(area).populated, "area %s's Pokemon are in" % area)
        check(_sim(area).state.wild.size() == 12 and _sim(area).state.habitat.size() == 2 and _sim(area).state.eggs.size() == 1,
            "area %s: 12 wild, 2 in the habitat, 1 egg (%d, %d, %d)" % [area, _sim(area).state.wild.size(), _sim(area).state.habitat.size(), _sim(area).state.eggs.size()])
    var start := {}
    var homes := {}
    for area in AREAS:
        start[area] = {}
        for wild_id in _sim(area).state.wild.records: start[area][wild_id] = _sim(area).state.wild.records[wild_id].cell
        homes[area] = _sim(area).state.habitat.records.keys()

    # Both areas run; what is sent keeps each player's copy equal to the server's.
    var sent := _run(30.0)
    check(sent > 0, "wild motion was sent (%d moves)" % sent)
    for area in AREAS:
        var walked := 0
        for wild_id in start[area]:
            if _sim(area).state.wild.has(wild_id) and _sim(area).state.wild.records[wild_id].cell != start[area][wild_id]: walked += 1
        check(walked >= 4, "area %s: its wild Pokemon wander (%d moved)" % [area, walked])
        check(_sim(area).state.habitat.records.keys() != homes[area], "area %s: its habitat Pokemon walk about" % area)
        _same(area, "after 30 s")
    check(game.visuals.last_packets.size() == 2, "two players in two areas")

    # A claim: the Pokemon is held still and nothing more is sent of it.
    var model := Population.new()
    model.state = state
    model.presence = {"alice": {"area": "1,0|OVERWORLD", "x": 12, "y": 10}, "bob": {"area": "0,1|OVERWORLD", "x": 15, "y": 12}}
    sim = _sim("1,0")
    var claimed: int = sim.state.wild.ids_near(Vector2i(12, 10), 24)[0]
    var claim := model.claim("alice", "c1", "1,0", claimed)
    check(claim.get("ok", false), "alice claims a wild Pokemon (%s)" % claim.get("reason", ""))
    game._committed(claim)
    var held: Vector2i = sim.state.wild.records[claimed].cell
    _run(10.0)
    check(sim.state.wild.has(claimed) and sim.state.wild.records[claimed].cell == held, "a claimed Pokemon stays where it is on the server")
    # She runs from the battle: it is back, where the server has it.
    var ran := model.complete("alice", "f1", "1,0", claimed, [state.change("player/alice", state.records["player/alice"])],
        Delta.decode(String(state.records[Population.claim_key("1,0", claimed)].record)))
    check(ran.get("ok", false), "the battle run from is taken (%s)" % ran.get("reason", ""))
    game._committed(ran)
    _run(2.0)
    check(sim.state.wild.has(claimed) and not bool(sim.state.wild.records[claimed].get("ball_reserved", false)), "it is let go on the server")
    _same("1,0", "after a battle run from")

    # A catch (or a friendly one recruited): gone, on the server and for the player.
    var caught: int = sim.state.wild.ids_near(Vector2i(12, 10), 24)[0]
    var catch := model.claim("alice", "c2", "1,0", caught)
    game._committed(catch)
    var done := model.complete("alice", "f2", "1,0", caught, [state.change("player/alice", state.records["player/alice"])], null)
    check(done.get("ok", false), "the catch is taken (%s)" % done.get("reason", ""))
    game._committed(done)
    _run(2.0)
    check(not sim.state.wild.has(caught), "a caught Pokemon is gone from the server's area")
    _same("1,0", "after a catch")

    # A habitat Pokemon walks on (its step not sent yet) and is called back from
    # the tile the records have it on: gone, and never sent back.
    var records := Records.new()
    records.state = state
    records.presence = model.presence
    records.make_egg = func(record: Dictionary, _profile: Dictionary) -> Dictionary: return {"species": String(record.species), "is_egg": true}
    var identity := "coop_owned:alice:0"
    var recorded: Vector2i = copies["1,0"].habitat.find_key(identity)
    check(_habitat_cell(sim, identity) == recorded, "the habitat Pokemon is where the records have it")
    for frame in 600:
        _run(1.0 / 30.0, false)
        if _habitat_cell(sim, identity) != recorded: break
    check(_habitat_cell(sim, identity) != recorded, "it walked on, its step not sent")
    records.presence.alice.x = recorded.x
    records.presence.alice.y = recorded.y + 1
    var taken := records.take("alice", "r1", "1,0", recorded, "deployed_pokemon", "", "", identity)
    check(taken.get("ok", false), "the habitat Pokemon is called back (%s)" % taken.get("reason", ""))
    game._committed(taken)
    _run(3.0)
    var anywhere := false
    for cell in sim.state.habitat.records:
        if String(sim.state.habitat.records[cell].get("ecology_id", "")) == identity: anywhere = true
    for key in game.record_keys("world/1,0/deployed_pokemon/"):
        var record = Delta.decode(String(state.records[key]))
        if record is Dictionary and String(record.get("ecology_id", "")) == identity: anywhere = true
    check(not anywhere, "called back after it walked on: no copy left on the server or in the records")
    _same("1,0", "after a habitat Pokemon is called back")

    # One left in a habitat is run there.
    var left := {"species": "pidgey", "level": 9, "gender": "male", "x": 25, "y": 8, "ecology_id": "coop_owned:alice:9", "shiny": false}
    game._committed(state.transact("alice", "deploy1", [state.change(Records.key("1,0", "deployed_pokemon", Vector2i(25, 8)), Delta.encode(left))]))
    _run(20.0)
    var placed := false
    for cell in sim.state.habitat.records:
        if String(sim.state.habitat.records[cell].get("ecology_id", "")) == "coop_owned:alice:9": placed = true
    check(placed, "a Pokemon left in a habitat is the server's to run")
    _same("1,0", "after a Pokemon is left in a habitat")

    # The records a step behind the server: a habitat Pokemon steps (not sent
    # yet), then its record is changed where the records still have it (an
    # item taken from it): it keeps its place and takes the change; the
    # records follow, one record of it.
    var walker := "coop_owned:alice:9"
    var recorded_at: Vector2i = copies["1,0"].habitat.find_key(walker)
    var free_beside := Vector2i(-1, -1)
    for step in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
        if not sim.state.habitat.records.has(recorded_at + step) and sim.state.wild.id_at(recorded_at + step) < 0: free_beside = recorded_at + step; break
    check(free_beside.x >= 0, "a free cell beside it")
    var walker_record: Dictionary = sim.state.habitat.records[_habitat_cell(sim, walker)]
    sim.state.habitat.move(_habitat_cell(sim, walker), free_beside)
    walker_record["cell"] = free_beside
    walker_record["x"] = free_beside.x
    walker_record["y"] = free_beside.y
    var changed_record: Dictionary = Delta.decode(String(state.records[Records.key("1,0", "deployed_pokemon", recorded_at)]))
    changed_record["held_item"] = "ORAN BERRY"
    game._committed(state.transact("alice", "harvest1", [state.change(Records.key("1,0", "deployed_pokemon", recorded_at), Delta.encode(changed_record))]))
    check(_habitat_cell(sim, walker) == free_beside and String(sim.state.habitat.records[free_beside].get("held_item", "")) == "ORAN BERRY",
        "a record changed a step behind: it keeps its place and takes the change")
    _run(1.0)
    var copies_of := 0
    for key in game.record_keys("world/1,0/deployed_pokemon/"):
        var record = Delta.decode(String(state.records[key]))
        if record is Dictionary and String(record.get("ecology_id", "")) == walker:
            copies_of += 1
            check(Vector2i(int(record.x), int(record.y)) == _habitat_cell(sim, walker) and String(record.get("held_item", "")) == "ORAN BERRY", "the records follow it, item and all")
    check(copies_of == 1, "one record of it (%d)" % copies_of)
    _same("1,0", "after a change a step behind")

    # A Pokemon left on a cell another has just stepped onto (not sent yet):
    # that one goes back to where the records have it, and both stay.
    var stepper := _habitat_cell(sim, walker)
    var target := Vector2i(-1, -1)
    for step in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
        if not sim.state.habitat.records.has(stepper + step) and sim.state.wild.id_at(stepper + step) < 0 and not sim.state.eggs.records.has(stepper + step): target = stepper + step; break
    var stepper_record: Dictionary = sim.state.habitat.records[stepper]
    sim.state.habitat.move(stepper, target)
    stepper_record["cell"] = target
    stepper_record["x"] = target.x
    stepper_record["y"] = target.y
    var newcomer := {"species": "rattata", "level": 7, "gender": "female", "x": target.x, "y": target.y, "ecology_id": "coop_owned:alice:10", "shiny": false}
    game._committed(state.transact("alice", "deploy2", [state.change(Records.key("1,0", "deployed_pokemon", target), Delta.encode(newcomer))]))
    check(_habitat_cell(sim, "coop_owned:alice:10") == target and _habitat_cell(sim, walker) == stepper, "the one there steps back, the new one takes the cell")
    _run(2.0)
    var both := {}
    for key in game.record_keys("world/1,0/deployed_pokemon/"):
        var record = Delta.decode(String(state.records[key]))
        if record is Dictionary: both[String(record.get("ecology_id", ""))] = both.get(String(record.get("ecology_id", "")), 0) + 1
    check(both.get(walker, 0) == 1 and both.get("coop_owned:alice:10", 0) == 1, "both are in the records, once each (%s)" % both)
    _same("1,0", "after a Pokemon is left on a cell just stepped onto")

    # Bob takes the egg in his area: its parents nearby are angered.
    records.presence.bob.x = 20
    records.presence.bob.y = 21
    var egg := records.take("bob", "e1", "0,1", Vector2i(20, 20), "wild_eggs", "", "", "")
    check(egg.get("ok", false), "bob takes the egg (%s)" % egg.get("reason", ""))
    game._committed(egg)
    _run(2.0)
    check(_sim("0,1").state.eggs.size() == 0, "the egg is gone from the server's area")
    _same("0,1", "after an egg is taken")

    # The roaming Megas, and Mega Gengar at night, step on the server; one in
    # a battle waits; one caught leaves for good.
    var megas_key := "world/1,0/event_progress/biome_megas"
    var gengar_key := "world/1,0/event_progress/mega_gengar_forest"
    var mega := {"venusaur": {"species": "mega_venusaur", "record": {"species": "mega_venusaur", "level": 70}, "x": 32, "y": 6,
        "home_x": 32, "home_y": 6, "next_move": 0.0}}
    var gengar := {"x": 34, "y": 12, "home_x": 34, "home_y": 12, "next_move": 0.0}
    game._committed(state.transact("server", "events1", [state.change(megas_key, Delta.encode(mega)), state.change(gengar_key, Delta.encode(gengar))]))
    for key in [megas_key, gengar_key]: sim.apply_record("event_progress", key.get_slice("/", 3), state.records[key])
    check(sim.state.interactables.get(Vector2i(32, 6)) == "SPECIAL:mega_venusaur" and sim.state.blocked.has(Vector2i(32, 6)), "a Mega keeps its cell on the server")
    # Night: 4.5/5.75 of the way into a day.
    game.clock_seconds = ceilf(game.clock_seconds / 383.333) * 383.333 + 320.0
    var mega_cells := {}
    var gengar_cells := {}
    for second in 20:
        _run(1.0)
        var seen: Dictionary = Delta.decode(String(state.records[megas_key])).venusaur
        mega_cells[Vector2i(int(seen.x), int(seen.y))] = true
        var night_seen: Dictionary = Delta.decode(String(state.records[gengar_key]))
        gengar_cells[Vector2i(int(night_seen.x), int(night_seen.y))] = true
    var roamed: Dictionary = Delta.decode(String(state.records[megas_key])).venusaur
    var mega_cell := Vector2i(int(roamed.x), int(roamed.y))
    check(mega_cells.size() > 1, "the Mega roams (%s)" % mega_cells.keys())
    check(mega_cells.keys().all(func(cell): return maxi(absi(cell.x - 32), absi(cell.y - 6)) <= 8), "within eight cells of its home")
    check(sim.state.interactables.get(mega_cell) == "SPECIAL:mega_venusaur" and (mega_cell == Vector2i(32, 6) or not sim.state.interactables.has(Vector2i(32, 6))), "its cell goes with it")
    check(gengar_cells.size() > 1, "Mega Gengar roams at night (%s)" % gengar_cells.keys())
    game._committed(state.transact("alice", "eventclaim1", [state.change("event_claim/1,0/mega_venusaur", {"actor": "alice", "context": {"id": "mega_venusaur"}})]))
    _run(10.0)
    roamed = Delta.decode(String(state.records[megas_key])).venusaur
    check(Vector2i(int(roamed.x), int(roamed.y)) == mega_cell, "a Mega in a battle waits")
    game._committed(state.transact("alice", "eventend1", [state.change("event_claim/1,0/mega_venusaur", null),
        state.change("event_result/1,0/mega_venusaur", {"id": "x", "context": {"id": "mega_venusaur"}, "outcome": "captured", "cleared": true})]))
    _run(2.0)
    var left_megas = Delta.decode(String(state.records[megas_key]))
    check(left_megas is Dictionary and not left_megas.has("venusaur"), "a Mega caught leaves for good")
    check(not sim.state.interactables.has(mega_cell), "and its cell is free")

    # A horde called in alice's area comes there, made by the server, ten
    # seconds after it is called, around her.
    game._committed(state.transact("server", "horde1", [state.change("horde/1,0", {"id": "h1", "area": "1,0", "phase": "waiting",
        "players": {"alice": 12}, "members": [], "target_counts": {}, "defeated": [], "total": 0, "spawned": false})]))
    _run(5.0)
    check(not bool(state.records["horde/1,0"].spawned), "a horde waits before it comes")
    _run(8.0)
    var horde: Dictionary = state.records["horde/1,0"]
    check(bool(horde.spawned) and horde.phase == "active" and int(horde.total) >= 1, "the horde came (%s)" % [horde])
    var members: Array = horde.get("members", [])
    check(members.all(func(id): return sim.state.wild.has(int(id)) and String(sim.state.wild.records[int(id)].get("source_record", {}).get("coop_horde", "")) == "h1"),
        "its Pokemon are the server's to run")
    check(members.all(func(id): return state.records.has(Population.record_key("1,0", int(id)))), "and in the records")
    _run(2.0)
    _same("1,0", "after a horde came")

    # The server stays the authority whoever comes and goes.
    state.enroll("carol", {"name": "carol"})
    check(state.enter("carol", "1,0") == "server", "a player arriving: the server's")
    state.leave("alice")
    check(state.authority.get("1,0") == "server", "the first player leaving: still the server's")

    # With players as authorities (a phone hosting), an area passes on with a
    # new epoch, and the player who had it may no longer send it.
    var phone := State.new()
    for actor in ["host", "dan", "eve"]: phone.enroll(actor, {"name": actor})
    var areas := Areas.new()
    areas.state = phone
    phone.records["area/2,2"] = {"seed": 1, "size": 0}
    var first := areas.enter("dan", "2,2")
    areas.enter("eve", "2,2")
    check(first.authority == "dan", "the first player in an area runs it")
    check(areas.can_publish("dan", "2,2", int(first.epoch)), "and may send it")
    areas.leave("dan")
    check(phone.authority.get("2,2") == "eve", "when they leave it passes to the next")
    var epoch := int(areas.epochs.get("2,2", 0))
    check(epoch == int(first.epoch) + 1, "with a new epoch")
    check(not areas.can_publish("dan", "2,2", int(first.epoch)) and areas.can_publish("eve", "2,2", epoch), "the one before may no longer send it")

    print("POPULATION AUTHORITY TEST: %d checks, %d failed" % [checks, failed])
    game.hordes.free()
    quit(1 if failed else 0)
