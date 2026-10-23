extends RefCounted
## One area's world without nodes: its tiles (the exact world's packed store),
## what has been done to them (the overlay groups a save and the co-op records
## hold), what stands on them and its Pokemon. The World node draws one of
## these and plays it: its overlay dictionaries are these (world.gd `area`).
## A host keeps one for each area a player is in (AreaSim, area_sim.gd) to run
## the rules (rules/) there.
##
## Every write to an overlay goes through put()/drop() (or mark() after an
## edit in place): what changed is known where it changes (dirty, by group
## and key), so replication sends only that (encode_changes, binary per group)
## instead of capturing, packing and comparing whole records. While a
## prediction is recorded (begin), each write also keeps what it replaced and
## each tile edited what it was (edit), so rollback() undoes it exactly.

## The overlays, in their wire order (a group's index is its id on the wire:
## append, never reorder). Sets hold `true`; the int groups an int.
const GROUPS := ["terrain_changes", "removed_resources", "source_interior_mutations", "source_plant_farms",
    "built_house_floor_tiles", "built_house_paintings", "built_house_decorations", "built_house_origins",
    "event_progress", "structures"]
const SETS := ["removed_resources", "built_house_floor_tiles"]
const INTS := ["terrain_changes", "built_house_paintings", "built_house_origins"]
## Fields of a structure record that are the World's nodes and runtime state, never data.
const STRUCTURE_RUNTIME := ["sprite", "collision", "solid", "bridged_water"]
## Kept with undo but never replicated: what the World works out from the rest.
const LOCAL := ["blocked", "interactables"]
const TileRules = preload("res://scripts/rules/tile_rules.gd")
## Binary frames (coop_transport.gd): this tag, then the message kind.
const WIRE_TAG := 4
const WIRE_AREA_CHANGES := 1
const WIRE_AREA_RECORDS := 2
const WIRE_WILD_MOTION := 3
const WildPopulation = preload("res://scripts/wild_population.gd")
const MAX_WIRE_CHANGES := 8192
const MAX_KEY_BYTES := 512
const MAX_VALUE_BYTES := 256 * 1024

## "x,y" of the area's grid cell ("" offline).
var area := ""
## The exact world (SourceExactWorldAdapter); null until loaded.
var tiles = null
## The cells the overworld spans (the World's map rectangle).
var bounds := Rect2i()

var terrain_changes := {}
var removed_resources := {}
var source_interior_mutations := {}
var source_plant_farms := {}
var built_house_floor_tiles := {}
var built_house_paintings := {}
var built_house_decorations := {}
var built_house_origins := {}
var event_progress := {"completed": {}, "trainer_defeated": {}, "keystone_life_force": {}, "regis_caught": [],
    "mewtwo_defeated_day": -1, "fossil_machine_powered": false, "biome_first_entries": {}}
## Vector2i -> record: what is built. In the World these are its
## built_structures, and the sprite and collision ride along (STRUCTURE_RUNTIME).
var structures := {}
## Vector2i -> what blocks the cell beside its tile (the World's `blocked`).
var blocked := {}
## Vector2i -> the generated entrances, signs and keys (the World's `landmarks`).
var landmarks := {}
## Vector2i -> "ITEM:..." and other actions on a cell (interior_interactables).
var interactables := {}
## WildPopulation, HabitatPopulation (habitats) and HabitatPopulation (eggs).
var wild = null
var habitat = null
var eggs = null
## What the Pokemon's rules (rules/population_rules.gd) read beside the tiles:
## the world clock in seconds and the random numbers they draw on (the
## World's world_elapsed_seconds and rng), the flowers set down, the habitat
## check's own clock, what the rules keep between calls, whether a Pokemon
## may stand on a cell's ground (invalid: the rules' own is_walkable), and
## the World that draws the area (emotes, sprites; null for an AreaSim).
var clock := 0.0
var rng := RandomNumberGenerator.new()
var flowers := {}
var ecology_accumulator := 0.0
var memo := {}
var walkable := Callable()
var view: Node = null

## group -> {key: true}: changed since take_dirty(). Collected only while
## tracking (co-op), so a game alone never keeps them.
var dirty := {}
var tracking := false
var _recording := false
## [group, key, had it, the value it had] per write while recording.
var _undo: Array = []
## store index (or Vector2i for a tile outside the store) -> what it was.
var _saved_tiles := {}

func group(name: String) -> Dictionary:
    return get(name)

static func cell_key(cell: Vector2i) -> String:
    return "%d,%d" % [cell.x, cell.y]

static func key_cell(key: String) -> Vector2i:
    var parts := key.split(",")
    if parts.size() != 2: return Vector2i(-2147483648, -2147483648)
    return Vector2i(int(parts[0]), int(parts[1]))

func in_bounds(cell: Vector2i) -> bool:
    return tiles.contains_cell(cell) if tiles != null else bounds.has_point(cell)

# --- Writes ---------------------------------------------------------------

func put(name: String, key: Variant, value: Variant) -> void:
    var held: Dictionary = get(name)
    if _recording: _undo.append([name, key, held.has(key), held.get(key)])
    held[key] = value
    if tracking and not name in LOCAL: _mark(name, key)

func drop(name: String, key: Variant) -> void:
    var held: Dictionary = get(name)
    if not held.has(key): return
    if _recording: _undo.append([name, key, true, held[key]])
    held.erase(key)
    if tracking and not name in LOCAL: _mark(name, key)

## A value changed in place (a nested field): replicated, not undone.
func mark(name: String, key: Variant) -> void:
    if tracking: _mark(name, key)

func _mark(name: String, key: Variant) -> void:
    if not dirty.has(name): dirty[name] = {}
    dirty[name][key] = true

## What changed since the last call: [[group, key, value or null when gone]],
## groups in wire order.
func take_dirty() -> Array:
    var result := []
    for name in GROUPS:
        var keys: Dictionary = dirty.get(name, {})
        var held: Dictionary = get(name)
        for key in keys: result.append([name, key, held.get(key)])
    dirty.clear()
    return result

# --- Tiles ----------------------------------------------------------------

func tile_at(cell: Vector2i) -> SourceTile:
    return tiles.tile_at(cell) if tiles != null else null

## The tile at `cell`, to change: while recording, what it was is kept first.
func edit(cell: Vector2i) -> SourceTile:
    if tiles == null: return null
    if _recording:
        var store = tiles.tiles
        if store is WorldTileStore:
            var index: int = store.index_of(cell * 16)
            if index >= 0:
                if not _saved_tiles.has(index):
                    var items = store.items.get(index)
                    var doors = store.doors.get(index)
                    _saved_tiles[index] = [store.flags[index], store.name_ids[index], store.upper_ids[index], store.biome_ids[index],
                        store.shore_ocean_ids[index], store.shore_tidal_ids[index], store.ledge_dir_ids[index], store.has_item_ids[index],
                        store.amounts[index], store.route_ids[index], items.duplicate(true) if items != null else null,
                        doors.duplicate() if doors != null else null]
            elif store.extra.has(cell * 16) and not _saved_tiles.has(cell):
                _saved_tiles[cell] = (store.extra[cell * 16] as SourceTile).copy_at()
    return tiles.tile_at(cell)

# --- Prediction -------------------------------------------------------------

## Starts keeping what each write replaces, until commit() or rollback().
func begin() -> void:
    _recording = true
    _undo.clear()
    _saved_tiles.clear()

func recording() -> bool:
    return _recording

## Stops recording for a while (changes from the authority are not the
## prediction's): returns whether it was, for resume().
func suspend() -> bool:
    var was := _recording
    _recording = false
    return was

func resume(was: bool) -> void:
    _recording = was

## Keeps every write since begin().
func commit() -> void:
    _recording = false
    _undo.clear()
    _saved_tiles.clear()

## Puts back everything written since begin(), the last write first. Returns
## the cells whose tiles were put back (for the view to redraw).
func rollback() -> Array:
    _recording = false
    for index in range(_undo.size() - 1, -1, -1):
        var entry: Array = _undo[index]
        var held: Dictionary = get(entry[0])
        if entry[2]: held[entry[1]] = entry[3]
        else: held.erase(entry[1])
        if tracking and not entry[0] in LOCAL: _mark(entry[0], entry[1])
    _undo.clear()
    var cells := []
    if tiles != null and tiles.tiles is WorldTileStore:
        var store: WorldTileStore = tiles.tiles
        for index in _saved_tiles:
            if index is Vector2i:
                store.extra[index * 16] = _saved_tiles[index]
                cells.append(index)
                continue
            var was: Array = _saved_tiles[index]
            store.flags[index] = was[0]; store.name_ids[index] = was[1]; store.upper_ids[index] = was[2]
            store.biome_ids[index] = was[3]; store.shore_ocean_ids[index] = was[4]; store.shore_tidal_ids[index] = was[5]
            store.ledge_dir_ids[index] = was[6]; store.has_item_ids[index] = was[7]; store.amounts[index] = was[8]
            store.route_ids[index] = was[9]
            store.set_items(index, was[10]); store.set_doors(index, was[11])
            store.bump(index)
            # The proxy handed out for the cell holds the values it read: read them again.
            var cached = store._proxies.get(index)
            var proxy = (cached as WeakRef).get_ref() if cached != null else null
            if proxy != null: proxy.repoint(index)
            var key: Vector2i = store.key_of(index)
            SourceTile.resident_changed_cells[key] = true
            cells.append(key / 16)
    _saved_tiles.clear()
    return cells

## While recording: what the authority has said since about these cells and
## overlay keys stands, so a rollback no longer puts back what they were.
func forget(name: String, key: Variant, cells: Array = []) -> void:
    if not _recording: return
    for index in range(_undo.size() - 1, -1, -1):
        if _undo[index][0] == name and _undo[index][1] == key: _undo.remove_at(index)
    if tiles == null or not tiles.tiles is WorldTileStore: return
    for cell in cells:
        var index: int = tiles.tiles.index_of(cell * 16)
        _saved_tiles.erase(index if index >= 0 else cell)

# --- Changes from elsewhere -------------------------------------------------

## An overlay entry from another copy (a record, a change on the wire) taken
## in: its group set and the tiles changed to match (TileRules.apply_overlay).
## `key` as the wire has it ("x,y" for a structure). Not marked dirty.
func apply_change(name: String, key: String, value: Variant) -> void:
    if not name in GROUPS: return
    var held: Dictionary = get(name)
    var at: Variant = TileRules.key_cell(key) if name == "structures" else key
    if value == null: held.erase(at)
    else: held[at] = value
    TileRules.apply_overlay(self, name, key, value)

# --- Records ----------------------------------------------------------------

## A structure as it is saved and sent: no nodes, its cell in it.
static func structure_record(cell: Vector2i, piece: Dictionary) -> Dictionary:
    var saved := piece.duplicate(true)
    for runtime in STRUCTURE_RUNTIME: saved.erase(runtime)
    saved["name"] = String(piece.get("name", ""))
    saved["x"] = cell.x
    saved["y"] = cell.y
    return saved

## The value of an overlay entry as it goes on the wire and into a record.
func wire_value(name: String, key: Variant) -> Variant:
    var held: Dictionary = get(name)
    if not held.has(key): return null
    if name == "structures": return structure_record(key, held[key])
    return held[key]

# --- Wire -------------------------------------------------------------------

## `changes` ([[group, key, value or null]], take_dirty's form) for the wire:
## WIRE_TAG, WIRE_AREA_CHANGES, the area, `revision` (u32) and the entries,
## each its group's id, its key and its value in its group's form.
static func encode_changes(area_id: String, revision: int, changes: Array) -> PackedByteArray:
    var out := PackedByteArray([WIRE_TAG, WIRE_AREA_CHANGES])
    _text(out, area_id)
    var head := out.size()
    out.resize(head + 6)
    out.encode_u32(head, revision & 0xFFFFFFFF)
    out.encode_u16(head + 4, mini(changes.size(), MAX_WIRE_CHANGES))
    for index in mini(changes.size(), MAX_WIRE_CHANGES):
        var change: Array = changes[index]
        var name := String(change[0])
        out.append(GROUPS.find(name))
        var key = change[1]
        _text(out, cell_key(key) if key is Vector2i else String(key))
        var value = change[2]
        if value == null:
            out.append(0)
        elif name in SETS:
            out.append(1)
        elif name in INTS and (value is int or value is float):
            out.append(2)
            var at := out.size()
            out.resize(at + 4)
            out.encode_s32(at, int(value))
        else:
            out.append(3)
            var bytes := var_to_bytes(structure_record(key, value) if name == "structures" and key is Vector2i else value)
            var at := out.size()
            out.resize(at + 4)
            out.encode_u32(at, bytes.size())
            out.append_array(bytes)
    return out

## encode_changes' bytes back: {"kind":"area_changes", "area", "revision",
## "changes": [[group, key (String, "x,y" for structures), value or null]]},
## or {} when they do not read as one.
static func decode_changes(bytes: PackedByteArray) -> Dictionary:
    if bytes.size() < 2 or bytes[0] != WIRE_TAG or bytes[1] != WIRE_AREA_CHANGES: return {}
    var at := [2]
    var area_id = _untext(bytes, at)
    if area_id == null or at[0] + 6 > bytes.size(): return {}
    var revision := bytes.decode_u32(at[0])
    var count := bytes.decode_u16(at[0] + 4)
    at[0] += 6
    if count > MAX_WIRE_CHANGES: return {}
    var changes := []
    for index in count:
        if at[0] >= bytes.size(): return {}
        var id: int = bytes[at[0]]
        at[0] += 1
        if id >= GROUPS.size(): return {}
        var key = _untext(bytes, at)
        if key == null or at[0] >= bytes.size(): return {}
        var form: int = bytes[at[0]]
        at[0] += 1
        var value = null
        match form:
            0: value = null
            1: value = true
            2:
                if at[0] + 4 > bytes.size(): return {}
                value = bytes.decode_s32(at[0])
                at[0] += 4
            3:
                if at[0] + 4 > bytes.size(): return {}
                var size := bytes.decode_u32(at[0])
                at[0] += 4
                if size > MAX_VALUE_BYTES or at[0] + size > bytes.size(): return {}
                # Never objects from the wire (bytes_to_var, not _with_objects).
                value = bytes_to_var(bytes.slice(at[0], at[0] + size))
                at[0] += size
                if value == null: return {}
            _: return {}
        changes.append([GROUPS[id], key, value])
    if at[0] != bytes.size(): return {}
    return {"kind": "area_changes", "area": area_id, "revision": revision, "changes": changes}

## An area's world records as the co-op host holds them ("world/<area>/<group>/
## <key>", each an encoded value) for the wire: WIRE_TAG, WIRE_AREA_RECORDS,
## the area, `revision`, then each its group's id, its key and the record's
## bytes. A record is the base64 of exactly those bytes, so the receiver
## rebuilds the very same text (its fingerprint included). `entries`:
## [[group, key, record text]].
static func encode_records(area_id: String, revision: int, entries: Array) -> PackedByteArray:
    var out := PackedByteArray([WIRE_TAG, WIRE_AREA_RECORDS])
    _text(out, area_id)
    var head := out.size()
    out.resize(head + 6)
    out.encode_u32(head, revision & 0xFFFFFFFF)
    out.encode_u16(head + 4, mini(entries.size(), MAX_WIRE_CHANGES))
    for index in mini(entries.size(), MAX_WIRE_CHANGES):
        var entry: Array = entries[index]
        out.append(GROUPS.find(String(entry[0])))
        _text(out, String(entry[1]))
        var bytes := Marshalls.base64_to_raw(String(entry[2]))
        var at := out.size()
        out.resize(at + 4)
        out.encode_u32(at, bytes.size())
        out.append_array(bytes)
    return out

## encode_records' bytes back: {"kind":"world_records", "area", "revision",
## "records": [[group, key, record text]]}, or {} when they do not read as one.
static func decode_records(bytes: PackedByteArray) -> Dictionary:
    if bytes.size() < 2 or bytes[0] != WIRE_TAG or bytes[1] != WIRE_AREA_RECORDS: return {}
    var at := [2]
    var area_id = _untext(bytes, at)
    if area_id == null or at[0] + 6 > bytes.size(): return {}
    var revision := bytes.decode_u32(at[0])
    var count := bytes.decode_u16(at[0] + 4)
    at[0] += 6
    var records := []
    for index in count:
        if at[0] >= bytes.size(): return {}
        var id: int = bytes[at[0]]
        at[0] += 1
        if id >= GROUPS.size(): return {}
        var key = _untext(bytes, at)
        if key == null or at[0] + 4 > bytes.size(): return {}
        var size := bytes.decode_u32(at[0])
        at[0] += 4
        if size > MAX_VALUE_BYTES or at[0] + size > bytes.size(): return {}
        records.append([GROUPS[id], key, Marshalls.raw_to_base64(bytes.slice(at[0], at[0] + size))])
        at[0] += size
    if at[0] != bytes.size(): return {}
    return {"kind": "world_records", "area": area_id, "revision": revision, "records": records}

## The wild Pokemon of an area that moved, as the one simulating it sends them
## (WildPopulation.encode_motion: 14 bytes each), with the area and the epoch
## of its authority: WIRE_TAG, WIRE_WILD_MOTION, the area, epoch (u32), motion.
static func encode_motion(area_id: String, epoch: int, motion: PackedByteArray) -> PackedByteArray:
    var out := PackedByteArray([WIRE_TAG, WIRE_WILD_MOTION])
    _text(out, area_id)
    var at := out.size()
    out.resize(at + 4)
    out.encode_u32(at, epoch & 0xFFFFFFFF)
    out.append_array(motion)
    return out

## encode_motion's bytes back: {"kind":"wild_motion_bin", "area", "epoch",
## "motion": WildPopulation.decode_motion's list, "bytes": the motion as sent
## (passed on as is)}; {} when they do not read as one.
static func decode_motion(bytes: PackedByteArray) -> Dictionary:
    if bytes.size() < 2 or bytes[0] != WIRE_TAG or bytes[1] != WIRE_WILD_MOTION: return {}
    var at := [2]
    var area_id = _untext(bytes, at)
    if area_id == null or at[0] + 6 > bytes.size(): return {}
    var epoch := bytes.decode_u32(at[0])
    var motion := bytes.slice(at[0] + 4)
    var count := motion.decode_u16(0)
    if count > MAX_WIRE_CHANGES or motion.size() != 2 + count * 14: return {}
    return {"kind": "wild_motion_bin", "area": area_id, "epoch": epoch, "motion": WildPopulation.decode_motion(motion), "bytes": motion}

## A binary frame (WIRE_TAG) read by its kind; null when it is no known one.
static func decode_wire(bytes: PackedByteArray) -> Variant:
    if bytes.size() < 2 or bytes[0] != WIRE_TAG: return null
    var read: Dictionary = {}
    match int(bytes[1]):
        WIRE_AREA_CHANGES: read = decode_changes(bytes)
        WIRE_AREA_RECORDS: read = decode_records(bytes)
        WIRE_WILD_MOTION: read = decode_motion(bytes)
    return null if read.is_empty() else read

static func _text(out: PackedByteArray, text: String) -> void:
    var bytes := text.to_utf8_buffer()
    var at := out.size()
    out.resize(at + 2)
    out.encode_u16(at, mini(bytes.size(), MAX_KEY_BYTES))
    out.append_array(bytes.slice(0, MAX_KEY_BYTES))

static func _untext(bytes: PackedByteArray, at: Array) -> Variant:
    if at[0] + 2 > bytes.size(): return null
    var size := bytes.decode_u16(at[0])
    at[0] += 2
    if size > MAX_KEY_BYTES or at[0] + size > bytes.size(): return null
    var text := bytes.slice(at[0], at[0] + size).get_string_from_utf8()
    at[0] += size
    return text
