extends RefCounted
## The world's wild Pokemon, without nodes: where each one stands and what the
## simulation asks of it every frame in packed arrays, one slot per Pokemon,
## the rest of it in its record.
##
## Slots are given out in the order the Pokemon are added; a removed one leaves
## a hole until the holes are packed away, in the same order. Going through the
## slots in order is going through the records dictionary in order, so whatever
## walks the Pokemon draws its random numbers in the order it did when it walked
## that dictionary.
##
## A grid of BUCKET x BUCKET cell buckets answers "who is within r of these
## cells" by looking only at the buckets those squares touch; at_cell answers
## "who stands on this cell". Both replace scans of every Pokemon in the world.
##
## tick() is a frame of the wild Pokemon near the players and the habitats: a
## timer counted down in a packed array for most of them, the whole wandering,
## pursuing, fleeing and egg-laying step for the one whose timer runs out. Its
## ground, actors and rules are the world's (`world`).

const PokemonEcology = preload("res://scripts/pokemon_ecology.gd")
const BUCKET_SHIFT := 4
const BUCKET := 1 << BUCKET_SHIFT
## flags: hidden in the sand (a trap).
const BURROWED := 1
## How near (cells, a square) a player keeps a wild Pokemon going, and how
## near a habitat Pokemon does.
const ACTIVE_RADIUS := 24
const HABITAT_RADIUS := PokemonEcology.HABITAT_RADIUS
const DIRECTIONS := [Vector2i.ZERO, Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]
## How near the player has to be for a frightened Pokemon to keep running:
## well past the edge of the screen, so it is not found waiting just out of view.
const FLEE_RANGE_TILES := 28
const FLEE_LOOK_AHEAD := 14
const FLEE_SEARCH_TILES := 180
const FLEE_REPLAN_STEPS := 5

## id -> record: what is saved of the Pokemon, and its runtime fields. Its
## "cell" is its slot's cell: change it with move(). Its move timer lives in
## timers while it is here (record_for_save() puts it back). World.wild_pokemon
## is this same dictionary.
var records: Dictionary = {}
## By slot. A hole has id 0 (ids start at 1).
var ids := PackedInt64Array()
var cell_x := PackedInt32Array()
var cell_y := PackedInt32Array()
var flags := PackedInt32Array()
## Seconds until it next moves (the record's "move_timer").
var timers := PackedFloat64Array()
## id -> slot.
var slot_of: Dictionary = {}
## cell -> slot, or an Array of slots in order when several share the cell.
var at_cell: Dictionary = {}
## Vector2i bucket -> Array of slots (in no order).
var buckets: Dictionary = {}
## Live slots (records held).
var live := 0
## species -> how many.
var _species: Dictionary = {}
## Changed since take_dirty(): added, moved, removed, or marked. Kept once
## someone takes them (co-op), so a game alone never collects them.
var dirty: Dictionary = {}
var tracking := false
var _tick_dirty := PackedInt64Array()
var _ticking := false

## The world: its ground, its other actors, its rules and its co-op game.
var world: Node
## The ids tick() looks at: those in a zone (near a player or a habitat),
## worked out every 500 ms of wall time.
var watched: Array = []
var watched_at := -100000
## Pokemon running from a failed catch: the routes planned for them, and the
## ball_flee_until their run began with.
var flee_routes := {}
var flee_started := {}

## Where each Pokemon is drawn, without a sprite. A step is drawn from where
## the one before left it to the new cell's center over its seconds, exactly
## as the linear tween that used to move its sprite: it takes its start at the
## end of the frame it begins in, and every frame's end moves it on by that
## frame's time (advance(), called by PopulationView after everything else
## has run, when tweens ran). Sprites only copy this, and what asks "is a
## Pokemon drawn here" (the Megas, pushing) gets the same answer on a
## dedicated server, which has no sprites.
## id -> [from: Vector2, to: Vector2, elapsed: float, seconds: float].
var motion := {}
## id -> [the step before (a motion Array, or where it rests), seconds]: a step
## begun this frame.
var _starting := {}
## id -> how much lower a sand trap that has risen is drawn from then on.
var trap_offsets := {}
## id -> Vector3i(facing as a DIRECTIONS index, walk phase, changes): the frame
## its sprite shows.
var poses := {}

func _init(owner: Node = null) -> void:
    world = owner

func size() -> int:
    return records.size()

func has(id: int) -> bool:
    return records.has(id)

## Adds a Pokemon whose record holds its "cell" (and "move_timer"). One already
## here with this id keeps its place in the order and gets the new record.
func add(id: int, record: Dictionary) -> void:
    sync()
    var slot: int = slot_of.get(id, -1)
    if slot >= 0:
        _species_add(String((records[id] as Dictionary).get("species", "")), -1)
        _unplace(slot)
    else:
        slot = ids.size()
        ids.append(id)
        cell_x.append(0)
        cell_y.append(0)
        flags.append(0)
        timers.append(0.0)
        slot_of[id] = slot
        live += 1
    records[id] = record
    var cell: Vector2i = record.get("cell", Vector2i.ZERO)
    cell_x[slot] = cell.x
    cell_y[slot] = cell.y
    flags[slot] = _flags_of(record)
    if record.has("move_timer"):
        timers[slot] = float(record["move_timer"])
        record.erase("move_timer")
    _place(slot)
    _species_add(String(record.get("species", "")), 1)
    mark(id)

func remove(id: int) -> void:
    sync()
    var slot: int = slot_of.get(id, -1)
    if slot < 0:
        return
    _species_add(String((records[id] as Dictionary).get("species", "")), -1)
    _unplace(slot)
    ids[slot] = 0
    slot_of.erase(id)
    records.erase(id)
    live -= 1
    motion.erase(id)
    _starting.erase(id)
    trap_offsets.erase(id)
    poses.erase(id)
    mark(id)
    if not _ticking:
        _maybe_compact()

## Every Pokemon gone (a new world, a load). A flee route stays with its id, as
## it always has: one loaded again carries on running.
func clear() -> void:
    records.clear()
    _clear_slots()
    dirty.clear()
    motion.clear()
    _starting.clear()
    trap_offsets.clear()
    poses.clear()

## Puts the Pokemon on `cell` (its record's "cell" too).
func move(id: int, cell: Vector2i) -> void:
    sync()
    var slot: int = slot_of.get(id, -1)
    if slot < 0:
        return
    records[id]["cell"] = cell
    if cell_x[slot] == cell.x and cell_y[slot] == cell.y:
        return
    _unplace(slot)
    cell_x[slot] = cell.x
    cell_y[slot] = cell.y
    _place(slot)
    mark(id)

## Reads the record again after something else wrote it (a co-op record merged
## into it): its cell, flags, species and move timer.
func refresh(id: int) -> void:
    if records.has(id):
        add(id, records[id])

## Holds the Pokemon for a ball, a battle claim or a co-op spawn not yet
## confirmed (its record's "ball_reserved"): the simulation leaves it where it
## is. Never saved.
func claim(id: int, reserved: bool) -> void:
    var record: Dictionary = records.get(id, {})
    if record.is_empty():
        return
    if reserved:
        record["ball_reserved"] = true
    else:
        record.erase("ball_reserved")

func timer_of(id: int) -> float:
    var slot: int = slot_of.get(id, -1)
    return timers[slot] if slot >= 0 else 0.0

func set_timer(id: int, seconds: float) -> void:
    var slot: int = slot_of.get(id, -1)
    if slot >= 0:
        timers[slot] = seconds

## Something about the Pokemon others should be told changed.
func mark(id: int) -> void:
    if tracking:
        dirty[id] = true
    if _ticking:
        _tick_dirty.append(id)

## The ids changed since the last call (added, moved, removed or marked), in
## the order they first changed. The first call starts the tracking.
func take_dirty() -> PackedInt64Array:
    tracking = true
    var result := PackedInt64Array(dirty.keys())
    dirty.clear()
    return result

func count_species(species: String) -> int:
    return int(_species.get(species, 0))

## The first Pokemon on the cell in order (not `ignored`), -1 if none.
func id_at(cell: Vector2i, ignored: int = -1) -> int:
    sync()
    var at = at_cell.get(cell)
    if at == null:
        return -1
    if at is int:
        var id := ids[at]
        return -1 if id == ignored else id
    for slot in at:
        if ids[slot] != ignored:
            return ids[slot]
    return -1

## null, the id on the cell, or an Array of ids in order when several share it.
func ids_at(cell: Vector2i) -> Variant:
    sync()
    var at = at_cell.get(cell)
    if at == null:
        return null
    if at is int:
        return ids[at]
    return (at as Array).map(func(slot: int) -> int: return ids[slot])

## The slots of the Pokemon within any of the squares (Vector3i: center x, y,
## and the half side), in order. Only the buckets the squares touch are looked at.
func slots_in(squares: Array) -> PackedInt32Array:
    sync()
    var result := PackedInt32Array()
    var seen := {}
    for square: Vector3i in squares:
        var radius := square.z
        for by in range((square.y - radius) >> BUCKET_SHIFT, ((square.y + radius) >> BUCKET_SHIFT) + 1):
            for bx in range((square.x - radius) >> BUCKET_SHIFT, ((square.x + radius) >> BUCKET_SHIFT) + 1):
                var bucket = buckets.get(Vector2i(bx, by))
                if bucket == null:
                    continue
                for slot: int in bucket:
                    if absi(cell_x[slot] - square.x) <= radius and absi(cell_y[slot] - square.y) <= radius and not seen.has(slot):
                        seen[slot] = true
                        result.append(slot)
    result.sort()
    return result

## The ids within `radius` cells (a square) of `center`, in order.
func ids_near(center: Vector2i, radius: int) -> Array:
    var result := []
    for slot in slots_in([Vector3i(center.x, center.y, radius)]):
        result.append(ids[slot])
    return result

## The ids standing in `cells` (a rectangle of cells), in no order.
func ids_in_rect(cells: Rect2i) -> Array:
    sync()
    var result := []
    var end := cells.end - Vector2i.ONE
    for by in range(cells.position.y >> BUCKET_SHIFT, (end.y >> BUCKET_SHIFT) + 1):
        for bx in range(cells.position.x >> BUCKET_SHIFT, (end.x >> BUCKET_SHIFT) + 1):
            var bucket = buckets.get(Vector2i(bx, by))
            if bucket == null:
                continue
            for slot: int in bucket:
                if cells.has_point(Vector2i(cell_x[slot], cell_y[slot])):
                    result.append(ids[slot])
    return result

static func cell_center(cell: Vector2i) -> Vector2:
    return Vector2(cell.x * 16 + 8.0, cell.y * 16 + 8.0)

## Where the Pokemon is drawn when it is not stepping.
func rest_position(id: int) -> Vector2:
    var slot: int = slot_of.get(id, -1)
    if slot < 0:
        return Vector2.ZERO
    return cell_center(Vector2i(cell_x[slot], cell_y[slot])) + Vector2(0.0, float(trap_offsets.get(id, 0.0)))

## Where the Pokemon is drawn now.
func visual_position(id: int) -> Vector2:
    var step = motion.get(id)
    if step != null:
        return _step_at(step)
    var start = _starting.get(id)
    if start != null:
        return _step_at(start[0]) if start[0] is Array else start[0]
    return rest_position(id)

## Whether a step is being drawn (or begins this frame).
func stepping(id: int) -> bool:
    return motion.has(id) or _starting.has(id)

## A step drawn over `seconds` from where the Pokemon is drawn now to the cell
## it is about to be moved to (call before move()).
func begin_step(id: int, seconds: float) -> void:
    if not slot_of.has(id):
        return
    var before = motion.get(id)
    _starting[id] = [(before as Array).duplicate() if before != null else visual_position(id), seconds]
    motion.erase(id)

## Drawn at rest on its cell at once (a push, a placement, a ball taking it).
func snap(id: int) -> void:
    motion.erase(id)
    _starting.erase(id)

## The frame shown: facing `direction`, walk phase `phase`.
func pose(id: int, direction: Vector2i, phase: int) -> void:
    var before: Vector3i = poses.get(id, Vector3i(-1, 0, 0))
    poses[id] = Vector3i(maxi(0, DIRECTIONS.find(direction)), phase, before.z + 1)

## A sand trap that has risen: drawn this much lower from then on.
func set_trap_offset(id: int, offset: float) -> void:
    trap_offsets[id] = offset

## The end of a frame: every step drawn moves on by `delta`.
func advance(delta: float) -> void:
    var begun := {}
    for raw_id in _starting:
        var slot: int = slot_of.get(raw_id, -1)
        if slot < 0:
            continue
        var start: Array = _starting[raw_id]
        var from: Vector2
        if start[0] is Array:
            # The step before is still drawn: it moves on first, as the older
            # tween was stepped first, and the new one starts where it is.
            var before: Array = start[0]
            before[2] += delta
            from = _step_at(before)
        else:
            from = start[0]
        motion[raw_id] = [from, cell_center(Vector2i(cell_x[slot], cell_y[slot])), delta, float(start[1])]
        begun[raw_id] = true
    _starting.clear()
    for raw_id in motion.keys():
        var step: Array = motion[raw_id]
        if not begun.has(raw_id):
            step[2] += delta
        if float(step[2]) >= float(step[3]):
            motion.erase(raw_id)

static func _step_at(step: Array) -> Vector2:
    return (step[0] as Vector2).lerp(step[1], float(minf(step[2], step[3]) / float(step[3])))

## What is saved of the Pokemon (World._serializable_ecology_record), or {}.
func record_for_save(id: int) -> Dictionary:
    var record: Dictionary = records.get(id, {})
    if record.is_empty():
        return {}
    var saved: Dictionary = world._serializable_ecology_record(record, record.get("cell", Vector2i.ZERO))
    saved["id"] = id
    return saved

## Every Pokemon as a save holds it: an Array of dictionaries, in order.
func to_save() -> Array:
    var result := []
    for raw_id in records:
        result.append(record_for_save(int(raw_id)))
    return result

## The saved Pokemon back in the world (the same records to_save() gave).
func from_save(saved: Array) -> void:
    for raw in saved:
        if typeof(raw) != TYPE_DICTIONARY:
            continue
        var entry: Dictionary = raw
        var cell := Vector2i(int(entry.get("x", -1)), int(entry.get("y", -1)))
        world._add_wild_pokemon(String(entry.get("species", "pidgey")), int(entry.get("level", 2)), cell,
            String(entry.get("home_biome", world.biome_at(cell))), int(entry.get("id", 0)),
            entry.get("source_record", {}) as Dictionary, entry)

## Moves of the Pokemon in `changed` packed for the wire: per Pokemon its id
## (u32 of the low bits, u32 of the high), cell x and y (i16), facing (u8, one
## of the DIRECTIONS index), walk phase (u8) and flags (u8: 1 burrowed, 2 held,
## 4 pursuing, 8 removed). 14 bytes each, after a u16 count.
func encode_motion(changed: PackedInt64Array) -> PackedByteArray:
    var bytes := PackedByteArray()
    bytes.resize(2 + changed.size() * 14)
    bytes.encode_u16(0, changed.size())
    var at := 2
    for id in changed:
        bytes.encode_u32(at, id & 0xFFFFFFFF)
        bytes.encode_u32(at + 4, (id >> 32) & 0xFFFFFFFF)
        var slot: int = slot_of.get(id, -1)
        if slot < 0:
            bytes.encode_s16(at + 8, 0)
            bytes.encode_s16(at + 10, 0)
            bytes[at + 12] = 0
            bytes[at + 13] = 8
        else:
            var record: Dictionary = records[id]
            bytes.encode_s16(at + 8, clampi(cell_x[slot], -32768, 32767))
            bytes.encode_s16(at + 10, clampi(cell_y[slot], -32768, 32767))
            var facing: Vector2 = record.get("ball_facing", Vector2.ZERO)
            bytes[at + 12] = maxi(0, DIRECTIONS.find(Vector2i(facing))) | (int(record.get("anim_phase", 0)) & 1) << 4
            bytes[at + 13] = (BURROWED if flags[slot] & BURROWED else 0) | (2 if bool(record.get("ball_reserved", false)) else 0) \
                | (4 if bool(record.get("aggro_player", false)) else 0)
        at += 14
    return bytes

## decode_motion() of encode_motion()'s bytes: [{id, x, y, facing, phase, flags}].
static func decode_motion(bytes: PackedByteArray) -> Array:
    var result := []
    if bytes.size() < 2:
        return result
    var count := bytes.decode_u16(0)
    if bytes.size() < 2 + count * 14:
        return result
    var at := 2
    for i in count:
        result.append({"id": bytes.decode_u32(at) | (bytes.decode_u32(at + 4) << 32),
            "x": bytes.decode_s16(at + 8), "y": bytes.decode_s16(at + 10),
            "facing": DIRECTIONS[mini(bytes[at + 12] & 15, DIRECTIONS.size() - 1)], "phase": (bytes[at + 12] >> 4) & 1,
            "flags": bytes[at + 13]})
        at += 14
    return result

## One frame of the wild Pokemon in play. `observers` are the players who keep
## them going (each {"x", "y", "battle", "move"}; one, the player, offline);
## the habitats keep the ones near them going too. A Pokemon's timer counts
## down every frame; when it runs out it acts (wanders, pursues, flees, lays an
## egg), drawing on `rng` in the same order as the world's dictionary loop did.
## Returns the ids that changed (moved, were removed, or whose co-op target
## changed).
func tick(delta: float, observers: Array, rng: RandomNumberGenerator) -> PackedInt64Array:
    sync()
    _ticking = true
    _tick_dirty = PackedInt64Array()
    var coordinator = world.get_parent().get("coop_game")
    var online: bool = is_instance_valid(coordinator) and coordinator.active
    var player_cell: Vector2i = world._player_cell()
    var habitats: Dictionary = world.deployed_pokemon
    # Which Pokemon are inside a zone is worked out twice a second, not every
    # frame. One that wanders in or spawns is picked up within half a second.
    var now_msec := Time.get_ticks_msec()
    if now_msec - watched_at >= 500:
        watched_at = now_msec
        var zones: Array = []
        for observer in observers:
            zones.append(Vector3i(int(observer.x), int(observer.y), ACTIVE_RADIUS + 2))
        for habitat_cell in habitats.keys():
            zones.append(Vector3i(habitat_cell.x, habitat_cell.y, HABITAT_RADIUS + 2))
        watched.clear()
        for slot in slots_in(zones):
            watched.append(ids[slot])
    # Online, a Pokemon is kept going by the players who could chase it (not
    # in a battle); its own target is only worked out when it acts, or every
    # frame while it pursues or someone could charm it.
    var chasers: Array[Vector2i] = []
    var someone_charms := false
    for observer in observers:
        if online and bool(observer.get("battle", false)):
            continue
        chasers.append(Vector2i(int(observer.x), int(observer.y)))
        if online and String(observer.get("move", "")) == "CHARM":
            someone_charms = true
    var now: float = world.world_elapsed_seconds
    var charm_move: bool = world.active_field_move == "CHARM"
    var cover = world.get("habitat_population")
    for raw_id in watched.duplicate():
        var wild_id := int(raw_id)
        var slot: int = slot_of.get(wild_id, -1)
        if slot < 0:
            continue
        var data: Dictionary = records[wild_id]
        if bool(data.get("ball_reserved", false)) or flags[slot] & BURROWED:
            continue
        var old_cell := Vector2i(cell_x[slot], cell_y[slot])
        var local_target := true
        var target_player = null
        var aggro := bool(data.get("aggro_player", false))
        if online:
            if chasers.is_empty():
                continue
            if aggro:
                target_player = _target(coordinator, data, old_cell)
                if target_player.is_empty():
                    continue
                player_cell = Vector2i(target_player.x, target_player.y)
                local_target = target_player.actor == coordinator.session.actor
        # Near a player (online: one who could chase it) or a habitat.
        var active: bool = cover != null and cover.near(old_cell)
        if not active:
            if online and target_player == null:
                for chaser in chasers:
                    if absi(old_cell.x - chaser.x) <= ACTIVE_RADIUS and absi(old_cell.y - chaser.y) <= ACTIVE_RADIUS:
                        active = true
                        break
            else:
                active = absi(old_cell.x - player_cell.x) <= ACTIVE_RADIUS and absi(old_cell.y - player_cell.y) <= ACTIVE_RADIUS
            if not active:
                continue
        var was_charmed = data.get("charmed")
        var is_charmed := false
        if online:
            if float(data.get("ball_charm_until", 0.0)) > now:
                is_charmed = true
            elif someone_charms or charm_move:
                if target_player == null:
                    target_player = _target(coordinator, data, old_cell)
                    if target_player.is_empty():
                        continue
                    player_cell = Vector2i(target_player.x, target_player.y)
                    local_target = target_player.actor == coordinator.session.actor
                is_charmed = world._charm_suppresses(data) if local_target else coordinator.wild.remote_charm(data, target_player)
        elif charm_move or float(data.get("ball_charm_until", 0.0)) > now:
            is_charmed = world._charm_suppresses(data)
        if was_charmed == null or bool(was_charmed) != is_charmed:
            data["charmed"] = is_charmed
        if not online:
            if aggro or data.has("aggro_audio_tick"):
                world._update_source_aggro_audio(data, old_cell, player_cell, delta)
        if is_charmed and not bool(was_charmed):
            world._show_ecology_emote(world._sprite_of(data), "heart")
        if aggro:
            data["source_aggro_emote_seconds"] = float(data.get("source_aggro_emote_seconds", 0.0)) - delta
            if float(data["source_aggro_emote_seconds"]) <= 0.0:
                world._show_ecology_emote(world._sprite_of(data), "skull")
                data["source_aggro_emote_seconds"] = 241.0 / 60.0
        var move_timer := timers[slot] - delta
        timers[slot] = move_timer
        # One that has just broken out of a ball bolts at once; it does not
        # first wait out whatever pause its wandering had left.
        var flee_until := float(data.get("ball_flee_until", 0.0))
        if now < flee_until and float(flee_started.get(wild_id, -1.0)) != flee_until:
            flee_started[wild_id] = flee_until
        elif move_timer > 0.0:
            continue
        if online and target_player == null:
            target_player = _target(coordinator, data, old_cell)
            if target_player.is_empty():
                continue
            player_cell = Vector2i(target_player.x, target_player.y)
            local_target = target_player.actor == coordinator.session.actor
        if not _act(wild_id, slot, data, old_cell, player_cell, local_target, is_charmed, online, coordinator, rng):
            break
    _ticking = false
    _maybe_compact()
    return _tick_dirty

## The player `data` pursues or (calm) the nearest one it could, and its
## co-op target noted (World coop_wild_runtime.target_for); {} if none.
func _target(coordinator, data: Dictionary, old_cell: Vector2i) -> Dictionary:
    var before := String(data.get("coop_target", ""))
    var target: Dictionary = coordinator.wild.target_for(data, old_cell)
    if String(data.get("coop_target", "")) != before:
        mark(int(data.get("id", -1)))
    return target

## The Pokemon's timer ran out: it acts. False when a battle began (the frame's
## wild updates stop there, as they always have).
func _act(wild_id: int, slot: int, data: Dictionary, old_cell: Vector2i, player_cell: Vector2i,
        local_target: bool, is_charmed: bool, online: bool, coordinator, rng: RandomNumberGenerator) -> bool:
    timers[slot] = world._wild_move_delay(String(data.get("species", "")), data)
    world._try_create_parent_egg(data, old_cell, wild_id)
    var behavior: Dictionary = data.get("behavior", {})
    if bool(behavior.get("stationary", false)):
        return true
    var player_delta := player_cell - old_cell
    var pursuing := bool(data.get("aggro_player", false)) and not is_charmed
    var now: float = world.world_elapsed_seconds
    if now < float(data.get("fed_until", 0.0)):
        data["anim_phase"] = 1 - int(data.get("anim_phase", 0))
        pose(wild_id, Vector2i.DOWN, int(data["anim_phase"]))
        return true
    if (
            pursuing
            and local_target
            and world.active_field_move not in ["SURF", "FLY"]
            and player_delta.length_squared() <= 1
            and not world.encounter_grace_active()
            and not world._repel_blocks(int(data.get("level", 1)))
        ):
        world._begin_wild_encounter(wild_id)
        return false
    var direction: Vector2i = DIRECTIONS[rng.randi_range(0, DIRECTIONS.size() - 1)]
    # Timid species keep their distance; one that just broke out of a ball
    # runs from the player for a while, from further off.
    var scared := now < float(data.get("ball_flee_until", 0.0))
    var fleeing := (bool(behavior.get("flee", false)) and player_delta.length_squared() <= 16) or \
        (scared and player_delta.length_squared() <= FLEE_RANGE_TILES * FLEE_RANGE_TILES)
    if fleeing:
        direction = cardinal_direction(player_delta, true)
    elif pursuing and player_delta.length_squared() <= 64:
        direction = cardinal_direction(player_delta, false)
    else:
        var friend_id := String(data.get("friend_id", ""))
        var friend_reunion := (
            not friend_id.is_empty()
            and float(data.get("friend_seconds", PokemonEcology.FRIEND_SECONDS)) <= 0.0
        )
        var companion_id := friend_id
        if friend_reunion:
            data["friend_seconds"] = PokemonEcology.FRIEND_SECONDS
            world._show_friend_reunion(data, friend_id)
        elif companion_id.is_empty() or rng.randf() < 0.18:
            companion_id = String(data.get("mate_id", companion_id))
        if not companion_id.is_empty() and (friend_reunion or rng.randf() < 0.20):
            var companion_cell: Vector2i = world._ecology_cell_by_id(companion_id)
            if companion_cell.x > -2147483648:
                direction = cardinal_direction(companion_cell - old_cell, false)
        elif rng.randf() < 0.12:
            var same_species_cell := nearby_same_base_species_cell(data, old_cell)
            if same_species_cell.x > -2147483648:
                direction = cardinal_direction(same_species_cell - old_cell, false)
    if not pursuing and not fleeing:
        direction = world._paired_wander_direction(data, old_cell, direction)
    if not scared:
        flee_routes.erase(wild_id)
        flee_started.erase(wild_id)
    elif fleeing:
        # Running from a failed catch: follow a route planned several steps
        # ahead (flee_direction), so walls, water and dead ends are gone
        # around rather than paced in front of.
        var free_step := func(step: Vector2i) -> bool:
            return not (
                step == player_cell or step == world.follower_cell or step == world.field_helper_cell
                or (online and coordinator.wild.occupied(step))
                or id_at(step, wild_id) >= 0
                or world.wild_eggs.has(step) or world.deployed_pokemon.has(step)
            )
        direction = flee_direction(wild_id, String(data.get("species", "")), old_cell, player_cell, free_step)
    var target := old_cell + direction
    var source_record: Dictionary = data.get("source_record", {})
    if bool(source_record.get("rare_forest_mew", false)) and not preload("res://scripts/rare_forest_mew.gd").deep_forest(world, target):
        return true
    var rare_species := String(source_record.get("rare_legendary", ""))
    if not rare_species.is_empty() and not preload("res://scripts/rare_biome_legendaries.gd").habitat(world, rare_species, target):
        return true
    if (
            direction == Vector2i.ZERO
            or not world._pokemon_can_move_between(String(data.get("species", "")), old_cell, target)
            or target == player_cell
            or target == world.follower_cell
            or target == world.field_helper_cell
            or (online and coordinator.wild.occupied(target))
            or id_at(target, wild_id) >= 0
            or world.wild_eggs.has(target)
            or world.deployed_pokemon.has(target)
        ):
        return true
    var phase := 1 - int(data.get("anim_phase", 0))
    data["anim_phase"] = phase
    # The step's pace and facing are the Pokemon's own, sprite or not (a
    # dedicated server has none).
    var move_seconds := 0.20
    if bool(behavior.get("flee", false)) or (scared and fleeing):
        move_seconds = 16.0 / (2.0 * 60.0)
    elif pursuing:
        move_seconds = 16.0 / (1.5 * 60.0)
    begin_step(wild_id, move_seconds)
    move(wild_id, target)
    if online:
        coordinator.wild.mark_motion(wild_id)
    data["ball_facing"] = Vector2(direction)
    pose(wild_id, direction, phase)
    if pursuing or fleeing:
        timers[slot] = move_seconds
    if bool(behavior.get("flee", false)):
        data["flee_steps"] = int(data.get("flee_steps", 0)) + 1
        if int(data["flee_steps"]) >= 3 and world._is_tall_grass_cell(target):
            world._remove_wild_pokemon(wild_id)
    return true

static func cardinal_direction(delta: Vector2i, away: bool) -> Vector2i:
    var direction := Vector2i.ZERO
    if absi(delta.x) >= absi(delta.y):
        direction = Vector2i(signi(delta.x), 0)
    else:
        direction = Vector2i(0, signi(delta.y))
    return -direction if away else direction

## The cell of the first other Pokemon in order with the same base species
## within the habitat radius of `center`.
func nearby_same_base_species_cell(data: Dictionary, center: Vector2i) -> Vector2i:
    var base_species := String(data.get("base_species", ""))
    var own_id := int(data.get("id", -1))
    for raw_id in ids_near(center, HABITAT_RADIUS):
        if int(raw_id) == own_id:
            continue
        var candidate: Dictionary = records[raw_id]
        if String(candidate.get("base_species", "")) == base_species:
            return candidate.get("cell", Vector2i.ZERO)
    return Vector2i(-2147483648, -2147483648)

## The next step for a Pokemon running from `threat`. It searches every tile it
## could walk to within FLEE_LOOK_AHEAD steps and heads for the one furthest
## from the player, keeping to that route for a few steps before looking again.
## One step at a time (always the tile furthest away) left it pacing back and
## forth in front of any wall or pond, which made it easy to catch.
func flee_direction(wild_id: int, species: String, origin: Vector2i, threat: Vector2i, free_step: Callable) -> Vector2i:
    var route: Array = flee_routes.get(wild_id, [])
    if not route.is_empty():
        var planned: Vector2i = route[0]
        if (
                (planned - origin).length_squared() == 1
                and (threat - planned).length_squared() > 2
                and world._pokemon_can_move_between(species, origin, planned)
                and free_step.call(planned)
            ):
            route.pop_front()
            flee_routes[wild_id] = route
            return planned - origin
    var came := {origin: origin}
    var depth := {origin: 0}
    var queue: Array[Vector2i] = [origin]
    var head := 0
    var goal := origin
    var goal_score := float((threat - origin).length_squared())
    while head < queue.size() and queue.size() < FLEE_SEARCH_TILES:
        var cell := queue[head]
        head += 1
        if int(depth[cell]) >= FLEE_LOOK_AHEAD:
            continue
        for option in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
            var step: Vector2i = cell + option
            # Never plan a way that brushes past the player.
            if came.has(step) or (threat - step).length_squared() <= 2:
                continue
            if not world._pokemon_can_move_between(species, cell, step):
                continue
            if cell == origin and not free_step.call(step):
                continue
            came[step] = cell
            depth[step] = int(depth[cell]) + 1
            queue.append(step)
            # Further from the player is better; between equals, the nearer one.
            var score := float((threat - step).length_squared()) - 0.05 * float(depth[step])
            if score > goal_score:
                goal = step
                goal_score = score
    route = []
    while goal != origin:
        route.push_front(goal)
        goal = came[goal]
    if route.is_empty():
        flee_routes.erase(wild_id)
        return Vector2i.ZERO
    var first: Vector2i = route.pop_front()
    flee_routes[wild_id] = route.slice(0, FLEE_REPLAN_STEPS)
    return first - origin

## Whatever changed the records dictionary behind this one's back (erased or
## added a Pokemon directly) is caught up with here: the slots are made again
## from it, in its order. A Pokemon added that way keeps the timer its record
## holds.
func sync() -> void:
    if records.size() == live:
        return
    var kept_timers := {}
    for raw_id in slot_of:
        kept_timers[raw_id] = timers[slot_of[raw_id]]
    _rebuild()
    for raw_id in kept_timers:
        if slot_of.has(raw_id):
            timers[slot_of[raw_id]] = kept_timers[raw_id]

func _rebuild() -> void:
    _clear_slots()
    for raw_id in records:
        var id := int(raw_id)
        var record: Dictionary = records[raw_id]
        var slot := ids.size()
        var cell: Vector2i = record.get("cell", Vector2i.ZERO)
        ids.append(id)
        cell_x.append(cell.x)
        cell_y.append(cell.y)
        flags.append(_flags_of(record))
        timers.append(float(record.get("move_timer", 0.0)))
        record.erase("move_timer")
        slot_of[id] = slot
        live += 1
        _place(slot)
        _species_add(String(record.get("species", "")), 1)

func _clear_slots() -> void:
    ids.clear()
    cell_x.clear()
    cell_y.clear()
    flags.clear()
    timers.clear()
    slot_of.clear()
    at_cell.clear()
    buckets.clear()
    live = 0
    _species.clear()

static func _flags_of(record: Dictionary) -> int:
    return BURROWED if bool(record.get("burrowed", false)) else 0

func _species_add(species: String, change: int) -> void:
    var count := int(_species.get(species, 0)) + change
    if count > 0:
        _species[species] = count
    else:
        _species.erase(species)

func _place(slot: int) -> void:
    var cell := Vector2i(cell_x[slot], cell_y[slot])
    var at = at_cell.get(cell)
    if at == null:
        at_cell[cell] = slot
    elif at is int:
        at_cell[cell] = [at, slot] if at < slot else [slot, at]
    else:
        (at as Array).insert((at as Array).bsearch(slot), slot)
    var key := Vector2i(cell.x >> BUCKET_SHIFT, cell.y >> BUCKET_SHIFT)
    var bucket = buckets.get(key)
    if bucket == null:
        buckets[key] = [slot]
    else:
        (bucket as Array).append(slot)

func _unplace(slot: int) -> void:
    var cell := Vector2i(cell_x[slot], cell_y[slot])
    var at = at_cell.get(cell)
    if at is int:
        if at == slot:
            at_cell.erase(cell)
    elif at is Array:
        (at as Array).erase(slot)
        if (at as Array).size() == 1:
            at_cell[cell] = at[0]
    var key := Vector2i(cell.x >> BUCKET_SHIFT, cell.y >> BUCKET_SHIFT)
    var bucket = buckets.get(key)
    if bucket != null:
        (bucket as Array).erase(slot)
        if (bucket as Array).is_empty():
            buckets.erase(key)

## Packs the holes away when they outnumber the Pokemon, keeping the order.
func _maybe_compact() -> void:
    if ids.size() - live <= maxi(64, live):
        return
    var kept_timers := {}
    for raw_id in slot_of:
        kept_timers[raw_id] = timers[slot_of[raw_id]]
    _rebuild()
    for raw_id in kept_timers:
        timers[slot_of[raw_id]] = kept_timers[raw_id]
