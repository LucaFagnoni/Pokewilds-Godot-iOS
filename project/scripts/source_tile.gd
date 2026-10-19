class_name SourceTile
extends RefCounted

## A tile is either a plain object (generation, interiors) or a proxy for a
## cell of the overworld's WorldTileStore. A proxy loads its fields from the
## store when made and writes every change back (setters); the store hands
## out one proxy per cell while it is in use, so they never disagree. Reads
## are plain member reads either way.
static var resident_changed_cells: Dictionary = {}
## Passed as the name to make a bare proxy (no shared flag: world generation
## builds tiles on another thread at the same time).
const _BIND := "bind"
var _store: WorldTileStore = null
## Set while repoint() loads the store's values: no write-back, no marking.
var _loading := false
var _index := -1

var resident_revision := 0

func _mark_resident_change() -> void:
    if _loading: return
    resident_revision += 1
    if _store != null: _store.bump(_index)
    if OS.get_thread_caller_id() == OS.get_main_thread_id():
        resident_changed_cells[position] = true

static func bound_to(store: WorldTileStore, index: int) -> SourceTile:
    var tile := SourceTile.new(_BIND, Vector2i.ZERO)
    tile._store = store
    tile.repoint(index)
    return tile

## Loads cell `index` of the store into this proxy (cursors move this way).
func repoint(index: int) -> void:
    _index = index
    var store := _store
    _loading = true
    name = store.name_at(index)
    name_upper = store.upper_at(index)
    position = store.key_of(index)
    var bits: int = store.flags[index]
    color = bits & WorldTileStore.COLOR != 0
    is_solid = bits & WorldTileStore.SOLID != 0
    is_ledge = bits & WorldTileStore.LEDGE != 0
    is_water = bits & WorldTileStore.WATER != 0
    is_grass = bits & WorldTileStore.GRASS != 0
    is_cuttable = bits & WorldTileStore.CUTTABLE != 0
    is_headbuttable = bits & WorldTileStore.HEADBUTTABLE != 0
    is_tidal = bits & WorldTileStore.TIDAL != 0
    is_lava = bits & WorldTileStore.LAVA != 0
    is_bottom_mtn_layer = bits & WorldTileStore.BOTTOM_MTN != 0
    route_belongs_to = store.route_at(index)
    biome = store.biome_at(index)
    ledge_dir = store.ledge_dir_at(index)
    shore_ocean = store.shore_ocean_at(index)
    shore_tidal = store.shore_tidal_at(index)
    has_item = store.has_item_at(index)
    has_item_amount = store.amount_at(index)
    _items = store.items_at(index, false)
    _door_tiles = store.doors_at(index, false)
    resident_revision = store.revision_at(index)
    _loading = false

## Makes this a plain object keeping its current values (its cell left the
## store).
func _detach() -> void:
    _store = null
    _index = -1

var name: String:
    set(value):
        if name != value:
            name = value
            if _store != null and not _loading: _store.set_name(_index, value)
            _mark_resident_change()
var name_upper: String:
    set(value):
        if name_upper != value:
            name_upper = value
            if _store != null and not _loading: _store.set_upper(_index, value)
            _mark_resident_change()
## A stored tile stays at its key.
var position: Vector2i:
    set(value):
        if _store != null and not _loading:
            return
        if position != value:
            if OS.get_thread_caller_id() == OS.get_main_thread_id() and not _loading:
                resident_changed_cells[position] = true
            position = value
            _mark_resident_change()
var color: bool:
    set(value):
        if color != value:
            color = value
            if _store != null and not _loading: _store.set_flag(_index, WorldTileStore.COLOR, value)
            _mark_resident_change()
var route_belongs_to: SourceRoute:
    set(value):
        route_belongs_to = value
        if _store != null and not _loading: _store.set_route(_index, value)
var biome := "":
    set(value):
        if biome != value:
            biome = value
            if _store != null and not _loading: _store.set_biome(_index, value)
            _mark_resident_change()
var is_solid := false:
    set(value):
        if is_solid != value:
            is_solid = value
            if _store != null and not _loading: _store.set_flag(_index, WorldTileStore.SOLID, value)
            _mark_resident_change()
var is_ledge := false:
    set(value):
        if is_ledge != value:
            is_ledge = value
            if _store != null and not _loading: _store.set_flag(_index, WorldTileStore.LEDGE, value)
            _mark_resident_change()
var is_water := false:
    set(value):
        if is_water != value:
            is_water = value
            if _store != null and not _loading: _store.set_flag(_index, WorldTileStore.WATER, value)
            _mark_resident_change()
var is_grass := false:
    set(value):
        if is_grass != value:
            is_grass = value
            if _store != null and not _loading: _store.set_flag(_index, WorldTileStore.GRASS, value)
            _mark_resident_change()
var is_cuttable := false:
    set(value):
        is_cuttable = value
        if _store != null and not _loading: _store.set_flag(_index, WorldTileStore.CUTTABLE, value)
var is_headbuttable := false:
    set(value):
        is_headbuttable = value
        if _store != null and not _loading: _store.set_flag(_index, WorldTileStore.HEADBUTTABLE, value)
var is_tidal := false:
    set(value):
        is_tidal = value
        if _store != null and not _loading: _store.set_flag(_index, WorldTileStore.TIDAL, value)
var is_lava := false:
    set(value):
        is_lava = value
        if _store != null and not _loading: _store.set_flag(_index, WorldTileStore.LAVA, value)
var ledge_dir := "":
    set(value):
        ledge_dir = value
        if _store != null and not _loading: _store.set_ledge_dir(_index, value)
var is_bottom_mtn_layer := false:
    set(value):
        is_bottom_mtn_layer = value
        if _store != null and not _loading: _store.set_flag(_index, WorldTileStore.BOTTOM_MTN, value)
var shore_ocean := "":
    set(value):
        if shore_ocean != value:
            shore_ocean = value
            if _store != null and not _loading: _store.set_shore_ocean(_index, value)
            _mark_resident_change()
var shore_tidal := "":
    set(value):
        if shore_tidal != value:
            shore_tidal = value
            if _store != null and not _loading: _store.set_shore_tidal(_index, value)
            _mark_resident_change()
var has_item := "":
    set(value):
        if has_item != value:
            has_item = value
            if _store != null and not _loading: _store.set_has_item(_index, value)
            _mark_resident_change()
var has_item_amount := 0:
    set(value):
        has_item_amount = value
        if _store != null and not _loading: _store.set_amount(_index, value)
# Most terrain tiles never own rewards or switch targets. Allocate these
# mutable containers only when a caller actually needs them. A proxy shares
# the store's own container, so edits made through it are stored too.
var _items: Variant = null
var _door_tiles: Variant = null
var items: Variant:
    get:
        if _items == null:
            _items = {}
            if _store != null: _store.set_items(_index, _items)
        return _items
    set(value):
        _items = value
        if _store != null: _store.set_items(_index, value)
var door_tiles: Variant:
    get:
        if _door_tiles == null:
            var empty: Array[Vector2i] = []
            _door_tiles = empty
            if _store != null: _store.set_doors(_index, _door_tiles)
        return _door_tiles
    set(value):
        _door_tiles = value
        if _store != null: _store.set_doors(_index, value)

const EMPTY_ITEMS: Dictionary = {}
const EMPTY_DOORS: Array[Vector2i] = []
func item_snapshot() -> Dictionary:
    return EMPTY_ITEMS if _items == null else _items
func door_snapshot() -> Array[Vector2i]:
    return EMPTY_DOORS if _door_tiles == null else _door_tiles

func _init(
        tile_name: String,
        pixel_position: Vector2i,
        upper_name: String = "",
        use_color: bool = false,
        route: SourceRoute = null,
        refresh_flags: bool = true
    ) -> void:
    if tile_name == _BIND: return
    name = tile_name
    name_upper = upper_name
    position = pixel_position
    color = use_color
    route_belongs_to = route
    _apply_constructor_name_rewrites(tile_name, upper_name)
    if refresh_flags:
        _refresh_flags(tile_name)

func copy_at(pixel_position: Vector2i = Vector2i(2147483647, 2147483647)) -> SourceTile:
    var target := position if pixel_position == Vector2i(2147483647, 2147483647) else pixel_position
    var result := SourceTile.new(name, target, name_upper, color, route_belongs_to)
    result.biome = biome
    result.is_bottom_mtn_layer = is_bottom_mtn_layer
    result.shore_ocean = shore_ocean
    result.shore_tidal = shore_tidal
    result.has_item = has_item
    result.has_item_amount = has_item_amount
    if _items != null: result.items = items.duplicate(true)
    if _door_tiles != null: result.door_tiles = door_tiles.duplicate()
    return result

func flip_door_tile() -> void:
    var tokens := name.split("__")
    if tokens.size() < 2:
        return
    if tokens[1] == "on":
        name = String(tokens[0]) + "__off"
        is_solid = false
    else:
        name = String(tokens[0]) + "__on"
        is_solid = true

func set_names(tile_name: String, upper_name: String = "") -> void:
    name = tile_name
    name_upper = upper_name
    _apply_constructor_name_rewrites(tile_name, upper_name)
    _refresh_flags(tile_name)

func to_world_dictionary() -> Dictionary:
    return SourceWorldData.make_tile(
        name,
        name_upper,
        route_belongs_to.name if route_belongs_to != null else "",
        route_belongs_to.level if route_belongs_to != null else 0,
        biome
    )

func _apply_constructor_name_rewrites(
        tile_name: String,
        upper_name: String
    ) -> void:
    if not upper_name.is_empty():
        return
    if tile_name == "rock1":
        name = "sand1"
        name_upper = "rock1"
    elif tile_name == "rock5":
        name = "sand1"
        name_upper = "rock5"
    elif tile_name == "tree2":
        name = "green1"
        name_upper = "tree2"
    elif tile_name == "tree4":
        name = "snow1"
        name_upper = "tree4"
    elif tile_name == "bush1":
        name = "green1"
        if color:
            name_upper = "bush2_color"
    elif tile_name.begins_with("cactus") and tile_name not in [
            "cactus7", "cactus8", "cactus9", "cactus10"]:
        name = "desert6"
        name_upper = tile_name
    elif tile_name in [
            "pedistal1", "building1_fossilreviver1",
            "interiorwall1"] or "gravestone" in tile_name or "sign_" in tile_name:
        name_upper = tile_name

func _refresh_flags(source_base_name: String = "") -> void:
    if source_base_name.is_empty():
        source_base_name = name
    # A non-color bush1 is rewritten to plain green ground with no visible
    # upper sprite.  Its collision must follow that visible ground, otherwise
    # the player hits an invisible bush in walkable grass.
    if source_base_name == "bush1" and name == "green1" and \
            name_upper.is_empty():
        source_base_name = name
    is_water = SourceWorldData.is_water(name) or SourceWorldData.is_water(name_upper)
    is_solid = (
        SourceWorldData.is_base_solid(source_base_name)
        or SourceWorldData.is_upper_solid(name_upper)
    )
    # Savanna and several authored habitat grasses live in name_upper rather
    # than the base tile. Encounter habitat must follow either visible layer.
    is_grass = (
        SourceWorldData.is_grass(source_base_name)
        or SourceWorldData.is_grass(name_upper)
    )
    is_cuttable = SourceWorldData.is_cuttable(source_base_name, name_upper)
    is_headbuttable = SourceWorldData.is_headbuttable(source_base_name, name_upper)
    is_tidal = "_tidalwater" in source_base_name
    is_lava = source_base_name.begins_with("lava")
    var ledge := SourceWorldData.ledge_direction(source_base_name)
    if ledge == Vector2i.ZERO:
        ledge = SourceWorldData.ledge_direction(name_upper)
    is_ledge = ledge != Vector2i.ZERO or "ledges3" in name_upper
    if name_upper in ["fence1", "fence2"]:
        is_ledge = true
        ledge_dir = "down"
    elif name_upper in ["fence1_NS", "fence2_NS"]:
        is_ledge = true
        ledge_dir = "left"
    if name_upper in ["fence1", "fence2", "fence1_NS", "fence2_NS"]:
        pass
    elif ledge == Vector2i.UP:
        ledge_dir = "up"
    elif ledge == Vector2i.DOWN:
        ledge_dir = "down"
    elif ledge == Vector2i.LEFT:
        ledge_dir = "left"
    elif ledge == Vector2i.RIGHT:
        ledge_dir = "right"
    else:
        ledge_dir = ""
    if name_upper == "pokeball1" and has_item.is_empty():
        has_item = "POKE BALL"
        has_item_amount = 1
    elif name_upper == "ultraball1" and has_item.is_empty():
        has_item = "ultra ball"
        has_item_amount = 1
    elif name_upper == "pokemon_mansion_key" and has_item.is_empty():
        has_item = "secret key"
        has_item_amount = 1
