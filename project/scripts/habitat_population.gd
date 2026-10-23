extends RefCounted
## The Pokemon the players left out in habitats (World.deployed_pokemon): their
## records by cell, without nodes, and which cells are near one of them (within
## the habitat square, HABITAT_RADIUS) without asking each one.
##
## tick() is their frame: each walks about its habitat when its timer runs out,
## pairs and lays eggs, drawing on the RNG in the order of the records
## dictionary, as the world's loop did.
##
## The eggs lying in the world are another (World.egg_population, group
## "wild_eggs"): records by cell, the cells changed for co-op, and the save,
## without a tick.

const PokemonEcology = preload("res://scripts/pokemon_ecology.gd")
const RADIUS := PokemonEcology.HABITAT_RADIUS
const DIRECTIONS := [Vector2i.ZERO, Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]

## cell -> record. World.deployed_pokemon is this same dictionary: place, take
## and move records through here.
var records: Dictionary = {}
## Changed since take_dirty(): cell -> true (a record placed, taken, moved or
## marked there). Kept once someone takes them (co-op), so a game alone never
## collects them.
var dirty: Dictionary = {}
var tracking := false
## Counts the records placed and taken (and clear()), for the views.
var version := 0
## cell -> how many records stand within RADIUS of it.
var _cover: Dictionary = {}
## How many records _cover was counted for.
var _covered := 0
var world: Node
## Which of the save's lists these records are: "deployed_pokemon" (the
## habitat Pokemon) or "wild_eggs".
var group: String

func _init(owner: Node = null, kind := "deployed_pokemon") -> void:
    world = owner
    group = kind

func size() -> int:
    return records.size()

## Puts `record` on `cell` (replacing what stood there, in its place in the
## order; a new cell goes last).
func place(cell: Vector2i, record: Dictionary) -> void:
    sync()
    if not records.has(cell):
        _cover_add(cell, 1)
        _covered += 1
    records[cell] = record
    version += 1
    mark(cell)

## Takes the record off `cell` ({} if none).
func take(cell: Vector2i) -> Dictionary:
    sync()
    if not records.has(cell):
        return {}
    var record: Dictionary = records[cell]
    records.erase(cell)
    _cover_add(cell, -1)
    _covered -= 1
    version += 1
    mark(cell)
    return record

## The record on `from` steps to `to` (it goes last in the order, as an erase
## and an add always did).
func move(from: Vector2i, to: Vector2i) -> void:
    var record := take(from)
    if not record.is_empty():
        place(to, record)

func clear() -> void:
    records.clear()
    version += 1
    _cover.clear()
    _covered = 0
    dirty.clear()

## Something about the record on `cell` others should be told changed.
func mark(cell: Vector2i) -> void:
    if tracking:
        dirty[cell] = true

## The cells changed since the last call. The first call starts the tracking.
func take_dirty() -> Array:
    tracking = true
    var result := dirty.keys()
    dirty.clear()
    return result

## What a save holds of the record on `cell` (with its x and y), or {}.
func record_for_save(cell: Vector2i) -> Dictionary:
    if not records.has(cell):
        return {}
    if group == "wild_eggs":
        return world._serializable_egg_record(records[cell], cell)
    return world._serializable_ecology_record(records[cell], cell)

## Every record as a save holds it: an Array of dictionaries, in order.
func to_save() -> Array:
    var result := []
    for raw_cell in records:
        result.append(record_for_save(raw_cell))
    return result

## The saved records back in the world (the same entries to_save() gave).
func from_save(saved: Array) -> void:
    for raw in saved:
        if typeof(raw) != TYPE_DICTIONARY:
            continue
        var entry: Dictionary = raw
        var cell := Vector2i(int(entry.get("x", -1)), int(entry.get("y", -1)))
        if group == "wild_eggs":
            world._add_wild_egg(String(entry.get("species", "pidgey")), cell, entry)
        else:
            world._restore_deployed_pokemon(entry, cell)

## A record stands within RADIUS (a square) of `cell`.
func near(cell: Vector2i) -> bool:
    sync()
    return _cover.has(cell)

## Records placed or taken behind this one's back (written to the dictionary
## directly) are counted again.
func sync() -> void:
    if records.size() == _covered:
        return
    _cover.clear()
    _covered = 0
    for cell in records:
        _cover_add(cell, 1)
        _covered += 1

func _cover_add(center: Vector2i, change: int) -> void:
    for y in range(center.y - RADIUS, center.y + RADIUS + 1):
        for x in range(center.x - RADIUS, center.x + RADIUS + 1):
            var cell := Vector2i(x, y)
            var count := int(_cover.get(cell, 0)) + change
            if count > 0:
                _cover[cell] = count
            else:
                _cover.erase(cell)

## One frame of the habitat Pokemon outdoors. One whose timer runs out pairs
## up and lays, or steps about its habitat; the one the player is calling back
## (World.recall_hold) waits. `rng` is drawn in the records' order.
func tick(delta: float, rng: RandomNumberGenerator) -> void:
    for raw_cell in records.keys():
        var old_cell: Vector2i = raw_cell
        if not records.has(old_cell):
            continue
        var data: Dictionary = records[old_cell]
        if data.has("house_door"):
            continue
        # The Pokemon the player is calling back waits for them.
        if not world.recall_hold.is_empty() and String(data.get("ecology_id", "")) == world.recall_hold:
            continue
        world._update_pokemon_water_visual(data)
        data["move_timer"] = float(data.get("move_timer", 0.0)) - delta
        if float(data["move_timer"]) > 0.0:
            continue
        data["move_timer"] = world._wild_move_delay(String(data.get("species", "")))
        world._try_create_parent_egg(data, old_cell)
        var behavior: Dictionary = data.get("behavior", {})
        if bool(behavior.get("stationary", false)):
            continue
        if not String(data.get("held_item", "")).is_empty():
            data["anim_phase"] = 1 - int(data.get("anim_phase", 0))
            world._habitat_pose(data, Vector2i.DOWN)
            mark(old_cell)
            continue
        var direction: Vector2i = DIRECTIONS[rng.randi_range(0, DIRECTIONS.size() - 1)]
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
                direction = world._cardinal_direction(companion_cell - old_cell, false)
        direction = world._paired_wander_direction(data, old_cell, direction)
        var target := old_cell + direction
        if (
                direction == Vector2i.ZERO
                or not world._pokemon_can_move_between(String(data.get("species", "")), old_cell, target)
                or target == world._player_cell()
                or target == world.follower_cell
                or target == world.field_helper_cell
                or records.has(target)
                or world._wild_id_at_cell(target) >= 0
                or world.wild_eggs.has(target)
            ):
            continue
        move(old_cell, target)
        data["cell"] = target
        data["x"] = target.x
        data["y"] = target.y
        data["anim_phase"] = 1 - int(data.get("anim_phase", 0))
        var move_seconds := 0.20
        if bool(behavior.get("flee", false)):
            move_seconds = 16.0 / (2.0 * 60.0)
        world._habitat_step_visuals(data, direction, target, move_seconds)
