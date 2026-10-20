class_name WorldTileStore
extends RefCounted
## The overworld's tiles, packed one field per array over the map rectangle.
##
## A SourceTile object costs about 1.1 KB; a size M map has ~400k of them, so
## keeping them as objects was ~440 MB on a phone. Here a cell costs ~44
## bytes. Code that asks for a tile gets a SourceTile bound to its cell (a
## proxy): it loads the cell's fields and writes every change back, and while
## it is in use the store hands out that same object for the cell. Whole-map
## loops read the arrays directly instead. Keys are pixel positions, as in
## the old Dictionary. Keys outside the rectangle (none in practice) are kept
## as plain objects.

const TILE := 16
const PRESENT := 1
const COLOR := 2
const SOLID := 4
const LEDGE := 8
const WATER := 16
const GRASS := 32
const CUTTABLE := 64
const HEADBUTTABLE := 128
const TIDAL := 256
const LAVA := 512
const BOTTOM_MTN := 1024
## Live proxies, by index (weak references). While a proxy is in use the
## store hands out that same object for its cell, so no two disagree. Dead
## entries are pruned when the table passes this size.
const PROXY_CACHE := 4096

var origin := Vector2i.ZERO
var width := 0
var height := 0
var count := 0
var flags := PackedInt32Array()
var name_ids := PackedInt32Array()
var upper_ids := PackedInt32Array()
var biome_ids := PackedInt32Array()
var shore_ocean_ids := PackedInt32Array()
var shore_tidal_ids := PackedInt32Array()
var ledge_dir_ids := PackedInt32Array()
var has_item_ids := PackedInt32Array()
var amounts := PackedInt32Array()
## 0 = no route, otherwise routes[id - 1].
var route_ids := PackedInt32Array()
var revisions := PackedInt32Array()
## Counts every edit of any cell (put, erase, bump): one number that says
## whether anything in the world's tiles changed since it was last read.
var edit_count := 0
## Sparse: index -> Dictionary / Array[Vector2i].
var items := {}
var doors := {}
var strings := PackedStringArray([""])
var string_ids := {"": 0}
var routes: Array = []
var route_slots := {}
var extra := {}
var _keys: Array = []
var _keys_valid := false
## Weak references only: a proxy holds its store, so strong ones here would
## keep the whole store alive forever (a reference cycle).
var _proxies := {}
var _cursor: WeakRef
var _prune_at := PROXY_CACHE

func _prune_proxies() -> void:
    for index in _proxies.keys():
        if (_proxies[index] as WeakRef).get_ref() == null: _proxies.erase(index)
    _prune_at = maxi(PROXY_CACHE, _proxies.size() * 2)

static func with_bounds(bounds: Rect2i) -> WorldTileStore:
    var store := WorldTileStore.new()
    store.origin = bounds.position
    store.width = bounds.size.x
    store.height = bounds.size.y
    var cells := bounds.size.x * bounds.size.y
    store.flags.resize(cells)
    store.name_ids.resize(cells)
    store.upper_ids.resize(cells)
    store.biome_ids.resize(cells)
    store.shore_ocean_ids.resize(cells)
    store.shore_tidal_ids.resize(cells)
    store.ledge_dir_ids.resize(cells)
    store.has_item_ids.resize(cells)
    store.amounts.resize(cells)
    store.route_ids.resize(cells)
    store.revisions.resize(cells)
    return store

## Packs a Dictionary of SourceTile objects keyed by pixel position. An int
## value stands for `templates[value]` at its key (a fresh world's ocean: see
## SourceIslandGenerator.ocean_tiles).
static func from_dictionary(tiles: Dictionary, templates: Array = []) -> WorldTileStore:
    var first := true
    var bounds := Rect2i()
    for key in tiles:
        var cell: Vector2i = Vector2i(key) / TILE
        if first:
            bounds = Rect2i(cell, Vector2i.ONE)
            first = false
        else:
            bounds = bounds.expand(cell)
    if not first: bounds.size += Vector2i.ONE
    var store := with_bounds(bounds)
    for key in tiles:
        var raw: Variant = tiles[key]
        var tile := (templates[raw] if raw is int else raw) as SourceTile
        if tile != null: store._write(Vector2i(key), tile)
    return store

# --- Dictionary-like access -----------------------------------------------

func index_of(key: Vector2i) -> int:
    var at := key / TILE - origin
    if at.x < 0 or at.y < 0 or at.x >= width or at.y >= height: return -1
    var index := at.y * width + at.x
    return index if flags[index] & PRESENT else -1

func key_of(index: int) -> Vector2i:
    return (Vector2i(index % width, index / width) + origin) * TILE

func has(key: Vector2i) -> bool:
    return index_of(key) >= 0 or extra.has(key)

func size() -> int:
    return count + extra.size()

func is_empty() -> bool:
    return size() == 0

## The tile at a pixel key, or null.
func tile(key: Vector2i) -> SourceTile:
    var index := index_of(key)
    if index < 0: return extra.get(key) as SourceTile
    return proxy(index)

func proxy(index: int) -> SourceTile:
    var cached = _proxies.get(index)
    if cached != null:
        var alive = (cached as WeakRef).get_ref()
        if alive != null: return alive
    if _proxies.size() >= _prune_at: _prune_proxies()
    var made := SourceTile.bound_to(self, index)
    _proxies[index] = weakref(made)
    return made

## A proxy for a loop of its own to re-point (`.repoint(i)`) at each cell:
## no allocation per cell. Never keep it past the loop.
func new_cursor() -> SourceTile:
    return SourceTile.bound_to(self, 0)

## Indices of the cells whose upper name passes `test` (called once per
## distinct name, not per cell).
func with_upper_where(test: Callable) -> PackedInt32Array:
    var ids := {}
    for id in strings.size():
        if test.call(strings[id]): ids[id] = true
    var result := PackedInt32Array()
    if ids.is_empty(): return result
    for index in upper_ids.size():
        if ids.has(upper_ids[index]) and flags[index] & PRESENT: result.append(index)
    return result

## Indices of the cells whose has_item passes `test`.
func with_item_where(test: Callable) -> PackedInt32Array:
    var ids := {}
    for id in strings.size():
        if test.call(strings[id]): ids[id] = true
    var result := PackedInt32Array()
    if ids.is_empty(): return result
    for index in has_item_ids.size():
        if ids.has(has_item_ids[index]) and flags[index] & PRESENT: result.append(index)
    return result

## One reusable proxy for loops over the whole map. It is re-pointed by
## every call: never keep it.
func cursor(index: int) -> SourceTile:
    var current: SourceTile = null if _cursor == null else _cursor.get_ref()
    if current == null:
        current = SourceTile.bound_to(self, index)
        _cursor = weakref(current)
    current.repoint(index)
    return current

## Stores a tile object at a key. The object becomes this cell's proxy.
func put(key: Vector2i, tile: SourceTile) -> void:
    var at := key / TILE - origin
    if at.x < 0 or at.y < 0 or at.x >= width or at.y >= height:
        if not extra.has(key): _keys_valid = false
        extra[key] = tile
        edit_count += 1
        return
    var index := at.y * width + at.x
    var revision := revisions[index]
    _write(key, tile)
    revisions[index] = revision + 1
    edit_count += 1
    var live = _proxies.get(index)
    var held: SourceTile = null if live == null else (live as WeakRef).get_ref()
    if tile._store == null:
        tile._store = self
        tile._index = index
        tile.resident_revision = revisions[index]
        _proxies[index] = weakref(tile)
        # Whoever still holds the cell's previous proxy sees the new tile.
        if held != null and held != tile: held.repoint(index)
    elif held != null:
        held.repoint(index)

func erase(key: Vector2i) -> bool:
    if extra.erase(key):
        _keys_valid = false
        edit_count += 1
        return true
    var index := index_of(key)
    if index < 0: return false
    # Anything still holding this cell's proxy keeps the values it had.
    var held = _proxies.get(index)
    if held != null and (held as WeakRef).get_ref() != null: ((held as WeakRef).get_ref() as SourceTile)._detach()  # keeps its values
    _proxies.erase(index)
    flags[index] = 0
    items.erase(index)
    doors.erase(index)
    revisions[index] += 1
    edit_count += 1
    count -= 1
    _keys_valid = false
    return true

func merge(other: Dictionary, overwrite: bool = false) -> void:
    for key in other:
        if overwrite or not has(key): put(Vector2i(key), other[key] as SourceTile)

func keys() -> Array:
    if not _keys_valid:
        _keys = []
        _keys.resize(count)
        var at := 0
        for index in flags.size():
            if flags[index] & PRESENT:
                _keys[at] = key_of(index)
                at += 1
        _keys.append_array(extra.keys())
        _keys_valid = true
    return _keys

## Every tile as a proxy. Costly on a whole map: prefer indices().
func values() -> Array:
    var result := []
    for key in keys(): result.append(tile(key))
    return result

## Proxies for the cells whose upper name is one of `names`.
func with_upper(names: Array) -> Array:
    var ids := {}
    for text in names:
        if string_ids.has(text): ids[string_ids[text]] = true
    var result := []
    if ids.is_empty(): return result
    for index in upper_ids.size():
        if ids.has(upper_ids[index]) and flags[index] & PRESENT: result.append(proxy(index))
    return result

## Indices of the cells whose name is one of `names`, in order.
func with_name(names: Array) -> PackedInt32Array:
    var ids := {}
    for text in names:
        if string_ids.has(text): ids[string_ids[text]] = true
    return _with_name_ids(ids.keys())

## Indices of the cells whose name contains `text` (any case), in order.
func with_name_containing(text: String) -> PackedInt32Array:
    var ids := []
    for id in strings.size():
        if strings[id].containsn(text): ids.append(id)
    return _with_name_ids(ids)

## Native searches per name: a script loop over every cell took ~10 ms on a
## size M map.
func _with_name_ids(ids: Array) -> PackedInt32Array:
    var result := PackedInt32Array()
    for id in ids:
        var index := name_ids.find(id)
        while index >= 0:
            if flags[index] & PRESENT: result.append(index)
            index = name_ids.find(id, index + 1)
    result.sort()
    return result

## Indices of every present cell.
func indices() -> PackedInt32Array:
    var result := PackedInt32Array()
    result.resize(count)
    var at := 0
    for index in flags.size():
        if flags[index] & PRESENT:
            result[at] = index
            at += 1
    return result

func _iter_init(state: Array) -> bool:
    state[0] = 0
    return keys().size() > 0

func _iter_next(state: Array) -> bool:
    state[0] += 1
    return state[0] < _keys.size()

func _iter_get(state: Variant) -> Variant:
    return _keys[state]

# --- Fields ----------------------------------------------------------------

func sid(text: String) -> int:
    var id = string_ids.get(text)
    if id == null:
        id = strings.size()
        strings.append(text)
        string_ids[text] = id
    return id

func route_slot(route: SourceRoute) -> int:
    if route == null: return 0
    var id := route.get_instance_id()
    var slot = route_slots.get(id)
    if slot == null:
        routes.append(route)
        slot = routes.size()
        route_slots[id] = slot
    return slot

func route_at(index: int) -> SourceRoute:
    var slot := route_ids[index]
    return null if slot == 0 else routes[slot - 1]

func flag(index: int, bit: int) -> bool:
    return flags[index] & bit != 0

func set_flag(index: int, bit: int, on: bool) -> void:
    flags[index] = (flags[index] | bit) if on else (flags[index] & ~bit)

# Reads and writes go through these methods: writing an element of a packed
# array held by another object makes GDScript copy the whole array first.
func name_at(index: int) -> String: return strings[name_ids[index]]
func upper_at(index: int) -> String: return strings[upper_ids[index]]
func biome_at(index: int) -> String: return strings[biome_ids[index]]
func shore_ocean_at(index: int) -> String: return strings[shore_ocean_ids[index]]
func shore_tidal_at(index: int) -> String: return strings[shore_tidal_ids[index]]
func ledge_dir_at(index: int) -> String: return strings[ledge_dir_ids[index]]
func has_item_at(index: int) -> String: return strings[has_item_ids[index]]
func amount_at(index: int) -> int: return amounts[index]
func revision_at(index: int) -> int: return revisions[index]
func set_name(index: int, text: String) -> void: name_ids[index] = sid(text)
func set_upper(index: int, text: String) -> void: upper_ids[index] = sid(text)
func set_biome(index: int, text: String) -> void: biome_ids[index] = sid(text)
func set_shore_ocean(index: int, text: String) -> void: shore_ocean_ids[index] = sid(text)
func set_shore_tidal(index: int, text: String) -> void: shore_tidal_ids[index] = sid(text)
func set_ledge_dir(index: int, text: String) -> void: ledge_dir_ids[index] = sid(text)
func set_has_item(index: int, text: String) -> void: has_item_ids[index] = sid(text)
func set_amount(index: int, value: int) -> void: amounts[index] = value
func set_route(index: int, route: SourceRoute) -> void: route_ids[index] = route_slot(route)
func bump(index: int) -> void:
    revisions[index] += 1
    edit_count += 1
func set_items(index: int, value: Variant) -> void:
    if value == null: items.erase(index)
    else: items[index] = value
func set_doors(index: int, value: Variant) -> void:
    if value == null: doors.erase(index)
    else: doors[index] = value

func items_at(index: int, create: bool) -> Variant:
    var found = items.get(index)
    if found == null and create:
        found = {}
        items[index] = found
    return found

func doors_at(index: int, create: bool) -> Variant:
    var found = doors.get(index)
    if found == null and create:
        var empty: Array[Vector2i] = []
        found = empty
        doors[index] = found
    return found

func _write(key: Vector2i, tile: SourceTile) -> void:
    var at := key / TILE - origin
    var index := at.y * width + at.x
    if not flags[index] & PRESENT:
        count += 1
        _keys_valid = false
    var bits := PRESENT
    if tile.color: bits |= COLOR
    if tile.is_solid: bits |= SOLID
    if tile.is_ledge: bits |= LEDGE
    if tile.is_water: bits |= WATER
    if tile.is_grass: bits |= GRASS
    if tile.is_cuttable: bits |= CUTTABLE
    if tile.is_headbuttable: bits |= HEADBUTTABLE
    if tile.is_tidal: bits |= TIDAL
    if tile.is_lava: bits |= LAVA
    if tile.is_bottom_mtn_layer: bits |= BOTTOM_MTN
    flags[index] = bits
    name_ids[index] = sid(tile.name)
    upper_ids[index] = sid(tile.name_upper)
    biome_ids[index] = sid(tile.biome)
    shore_ocean_ids[index] = sid(tile.shore_ocean)
    shore_tidal_ids[index] = sid(tile.shore_tidal)
    ledge_dir_ids[index] = sid(tile.ledge_dir)
    has_item_ids[index] = sid(tile.has_item)
    amounts[index] = tile.has_item_amount
    route_ids[index] = route_slot(tile.route_belongs_to)
    var tile_items: Dictionary = tile.item_snapshot()
    if tile_items.is_empty(): items.erase(index)
    else: items[index] = tile_items if tile._store != null else tile_items.duplicate(true)
    var tile_doors: Array[Vector2i] = tile.door_snapshot()
    if tile_doors.is_empty(): doors.erase(index)
    else: doors[index] = tile_doors.duplicate()

# --- Cache -----------------------------------------------------------------

## Everything but the routes, which the world cache stores in its own table
## (shared with the interiors); route_ids index this store's `routes`.
func to_record() -> Dictionary:
    var extra_records := {}
    for key in extra: extra_records[key] = (extra[key] as SourceTile).copy_at()
    return {"origin": origin, "width": width, "height": height, "count": count, "flags": flags,
        "name": name_ids, "upper": upper_ids, "biome": biome_ids, "shore_ocean": shore_ocean_ids,
        "shore_tidal": shore_tidal_ids, "ledge_dir": ledge_dir_ids, "has_item": has_item_ids,
        "amount": amounts, "route": route_ids, "items": items, "doors": doors, "strings": strings,
        "route_count": routes.size()}

static func from_record(record: Dictionary, all_routes: Array) -> WorldTileStore:
    var store := WorldTileStore.new()
    store.origin = record.origin
    store.width = record.width
    store.height = record.height
    store.count = record.count
    store.flags = record.flags
    store.name_ids = record.name
    store.upper_ids = record.upper
    store.biome_ids = record.biome
    store.shore_ocean_ids = record.shore_ocean
    store.shore_tidal_ids = record.shore_tidal
    store.ledge_dir_ids = record.ledge_dir
    store.has_item_ids = record.has_item
    store.amounts = record.amount
    store.route_ids = record.route
    store.revisions.resize(store.flags.size())
    store.items = record.items
    for index in record.doors:
        var typed: Array[Vector2i] = []
        typed.assign(record.doors[index])
        store.doors[index] = typed
    store.strings = record.strings
    for id in store.strings.size(): store.string_ids[store.strings[id]] = id
    store.routes = all_routes.slice(0, int(record.route_count))
    for slot in store.routes.size():
        store.route_slots[(store.routes[slot] as SourceRoute).get_instance_id()] = slot + 1
    return store

## A cache file (possibly sent by another player) must not index outside
## the tables. Array(...).min()/max() run natively, fast on 400k cells.
func is_valid_record() -> bool:
    var cells := width * height
    if width <= 0 or height <= 0 or count < 0 or count > cells: return false
    for array in [flags, name_ids, upper_ids, biome_ids, shore_ocean_ids, shore_tidal_ids, ledge_dir_ids,
            has_item_ids, amounts, route_ids]:
        if (array as PackedInt32Array).size() != cells: return false
    for array in [name_ids, upper_ids, biome_ids, shore_ocean_ids, shore_tidal_ids, ledge_dir_ids, has_item_ids]:
        var values := Array(array as PackedInt32Array)
        if values.min() < 0 or values.max() >= strings.size(): return false
    var slots := Array(route_ids)
    if slots.min() < 0 or slots.max() > routes.size(): return false
    for index in items:
        if typeof(index) != TYPE_INT or not items[index] is Dictionary: return false
    for index in doors:
        if typeof(index) != TYPE_INT: return false
    return true
