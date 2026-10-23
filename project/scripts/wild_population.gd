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

const BUCKET_SHIFT := 4
const BUCKET := 1 << BUCKET_SHIFT
## flags: hidden in the sand (a trap).
const BURROWED := 1

## id -> record: what is saved of the Pokemon, and its runtime fields. Its
## "cell" is its slot's cell: change it with move(). World.wild_pokemon is this
## same dictionary.
var records: Dictionary = {}
## By slot. A hole has id 0 (ids start at 1).
var ids := PackedInt64Array()
var cell_x := PackedInt32Array()
var cell_y := PackedInt32Array()
var flags := PackedInt32Array()
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

func size() -> int:
    return records.size()

func has(id: int) -> bool:
    return records.has(id)

## Adds a Pokemon whose record holds its "cell". One already here with this id
## keeps its place in the order and gets the new record.
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
        slot_of[id] = slot
        live += 1
    records[id] = record
    var cell: Vector2i = record.get("cell", Vector2i.ZERO)
    cell_x[slot] = cell.x
    cell_y[slot] = cell.y
    flags[slot] = _flags_of(record)
    _place(slot)
    _species_add(String(record.get("species", "")), 1)

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
    if ids.size() - live > maxi(64, live):
        _compact()

func clear() -> void:
    records.clear()
    ids.clear()
    cell_x.clear()
    cell_y.clear()
    flags.clear()
    slot_of.clear()
    at_cell.clear()
    buckets.clear()
    live = 0
    _species.clear()

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

## Reads the record again after something else wrote it (a co-op record merged
## into it): its cell, flags and species.
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

func cell_of_slot(slot: int) -> Vector2i:
    return Vector2i(cell_x[slot], cell_y[slot])

## Whatever changed the records dictionary behind this one's back (erased or
## added a Pokemon directly) is caught up with here: the slots are made again
## from it, in its order.
func sync() -> void:
    if records.size() == live:
        return
    var kept := records
    records = {}
    clear()
    records = kept
    for raw_id in kept:
        _append(int(raw_id), kept[raw_id])

func _append(id: int, record: Dictionary) -> void:
    var slot := ids.size()
    var cell: Vector2i = record.get("cell", Vector2i.ZERO)
    ids.append(id)
    cell_x.append(cell.x)
    cell_y.append(cell.y)
    flags.append(_flags_of(record))
    slot_of[id] = slot
    live += 1
    _place(slot)
    _species_add(String(record.get("species", "")), 1)

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
        var index := (at as Array).bsearch(slot)
        (at as Array).insert(index, slot)
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

## Packs the holes away, keeping the order.
func _compact() -> void:
    var kept := records
    records = {}
    clear()
    records = kept
    for raw_id in kept:
        _append(int(raw_id), kept[raw_id])
