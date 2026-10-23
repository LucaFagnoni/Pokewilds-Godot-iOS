extends RefCounted
## What the wild Pokemon, the habitat Pokemon and the eggs of an area may do,
## over its AreaState (area_state.gd): where a Pokemon may step, how long it
## waits, whom it pairs and makes friends with, when and where an egg is laid
## and released, which habitat it is in (the habitat check every
## HABITAT_CHECK_SECONDS), and its records as they are made and saved. Static
## and node-free, so WildPopulation and HabitatPopulation run the same frame
## for a game alone or a phone that simulates its area (the World's AreaState)
## and for a dedicated server that holds any other area (area_sim.gd). Moved
## out of world.gd unchanged; its old names call these.
##
## They draw on state.rng and read state.clock (the World's rng and
## world_elapsed_seconds). What they show (an emote, an egg's sprite in a
## house) goes to state.view, the World drawing the area: null on a server.
## Exact worlds only (state.tiles): the World keeps its own answers for the
## old generator's maps.

const PokemonData = preload("res://scripts/pokemon_data.gd")
const PokemonEcology = preload("res://scripts/pokemon_ecology.gd")
const PokemonState = preload("res://scripts/pokemon_state.gd")
const TileRules = preload("res://scripts/rules/tile_rules.gd")
const NO_CELL := Vector2i(-2147483648, -2147483648)
const TILE := 16
## The world's day (world.gd WORLD_DAY_SECONDS) and where its night begins.
const DAY_SECONDS := (18000.0 + 5000.0) / 60.0
const NIGHT_START := 18000.0 / (18000.0 + 5000.0)
const WILD_MOVE_MIN := 1.0
const WILD_MOVE_MAX := 4.0
const WILD_INITIAL_EGG_SECONDS := 30.0
const MATE_BOND_RADIUS := 6
## How near (cells, a square) a player keeps the habitat check going for wild Pokemon.
const ECOLOGY_ACTIVE_RADIUS := 24
## The fields of a habitat Pokemon the habitat check sets, other than its clocks.
const ECOLOGY_FIELDS: Array[String] = ["mate_id", "friend_id", "can_lay_egg", "mate_nearby", "nearby_pokemon",
    "in_habitat", "in_shelter", "missing_habitats", "held_item"]
## Habitat Pokemon with art of their own when the species has none (world.gd FARM_POKEMON_TEXTURES).
const FARM_SPECIES := ["pidgey", "rattata", "caterpie", "pikachu", "machop"]
## Fields of a wild or habitat record that are never saved.
const RUNTIME_FIELDS := ["sprite", "burrow_whirl_sprite", "burrow_sand_sprite", "behavior", "cell",
    "previous_mate_id", "ball_move_tween", "ball_reserved", "ball_facing"]

# --- Tiles ----------------------------------------------------------------------

## The tile names at a cell, base and upper, read from the tile store (no
## SourceTile proxy, ~10 us each); empty when there is no tile.
static func names_at(state, cell: Vector2i) -> PackedStringArray:
    var store = state.tiles.tiles
    var key := cell * TILE
    var tile: SourceTile = null
    if store is WorldTileStore:
        var index: int = store.index_of(key)
        if index >= 0:
            return PackedStringArray([store.name_at(index), store.upper_at(index)])
        # Off the packed cells: a plain tile object, as tile_at gives.
        tile = store.extra.get(key) as SourceTile
    else:
        tile = store.get(key) as SourceTile
    return PackedStringArray() if tile == null else PackedStringArray([tile.name, tile.name_upper])

static func tile_key(value: String) -> String:
    var key := value.to_lower().strip_edges()
    if key.ends_with(".png"):
        key = key.trim_suffix(".png")
    return key

static func biome_at(state, cell: Vector2i) -> String:
    var tile: SourceTile = state.tiles.tile_at(cell)
    return "OCEAN" if tile == null else TileRules.source_biome(tile)

static func normal_encounter_grass(state, cell: Vector2i) -> bool:
    var tile: SourceTile = state.tiles.tile_at(cell)
    if tile == null:
        return false
    return tile_key(tile.name) == "grass1" or tile_key(tile.name_upper) == "grass1"

## Encounter grass (not CUT's harvest grass).
static func is_tall_grass_cell(state, cell: Vector2i) -> bool:
    if state.tiles == null:
        return false
    # Same tests as below from the store's names and flags, without
    # building a tile object (only a tidal tile needs its biome).
    var store = state.tiles.tiles
    var index: int = store.index_of(cell * TILE) if store is WorldTileStore else -1
    if index >= 0 and store.flags[index] & WorldTileStore.TIDAL == 0:
        if tile_key(store.name_at(index)) == "grass1" or tile_key(store.upper_at(index)) == "grass1":
            return true
        return store.flags[index] & WorldTileStore.GRASS != 0
    var tile: SourceTile = state.tiles.tile_at(cell)
    if tile != null and tile.is_tidal and TileRules.source_biome(tile) != "BEACH":
        return false
    # grass1 is the source's normal encounter grass. Check its authored
    # identity directly as well as the cached flag so a stale/rewritten
    # SourceTile flag can never make a visibly normal grass field inert.
    if normal_encounter_grass(state, cell):
        return true
    # Grass remains encounter habitat until CUT actually replaces the tile.
    return tile != null and tile.is_grass

static func is_beach_tidal_tile(tile: SourceTile) -> bool:
    if tile == null:
        return false
    var route_name := "" if tile.route_belongs_to == null else tile.route_belongs_to.name.to_lower()
    var biome := TileRules.source_biome(tile)
    var beach_identity := biome in ["BEACH", "BEACH_BLACKSAND"] or route_name.begins_with("beach")
    var tile_name := tile.name.to_lower()
    var authored_tide := "_tidalwater" in tile_name or "_tidaloff" in tile_name
    if not authored_tide:
        return false
    # The original generator also uses *_tidalwater for non-ocean systems
    # (mountain-bottom water and wooded-lake shores). Ocean tide must therefore
    # remain tied to an authored beach biome/route.
    return beach_identity

## The way a ledge may be crossed (screen directions), ZERO for none.
static func permitted_ledge_direction(tile: SourceTile) -> Vector2i:
    if tile == null:
        return Vector2i.ZERO
    # The brown horizontal grass ledge is a one-way drop: screen-down is legal
    # and screen-up is blocked.
    var ledge_key: String = (tile.name + " " + tile.name_upper).to_lower()
    if "ledge_grass_down" in ledge_key:
        return Vector2i.DOWN
    # The exact world keeps Java's Y-up cell coordinates on Godot's Y-down
    # canvas: only vertical directions are mirrored.
    return {
        "up":Vector2i.DOWN, "down":Vector2i.UP,
        "left":Vector2i.LEFT, "right":Vector2i.RIGHT
    }.get(tile.ledge_dir, Vector2i.ZERO) as Vector2i

# --- Where a Pokemon may go -------------------------------------------------------

## 0 water, 1 sand, 2 other ground.
static func terrain_kind_at(state, cell: Vector2i) -> int:
    if String(state.structures.get(cell, {}).get("name", "")) == "BRIDGE":
        return 2
    var tile: SourceTile = state.tiles.tile_at(cell) if state.tiles != null else null
    if tile == null or tile.is_water or SourceWorldData.is_water(tile.name):
        return 0
    if "sand" in tile.name or "desert" in tile.name or "beach" in tile.biome:
        return 1
    return 2

## Open ground: a bridge, or a cell of the world that is not solid or blocked.
static func is_walkable(state, cell: Vector2i) -> bool:
    if String(state.structures.get(cell, {}).get("name", "")) == "BRIDGE":
        return not state.blocked.has(cell)
    return state.tiles != null and state.tiles.contains_cell(cell) and not state.tiles.is_solid(cell) and not state.blocked.has(cell)

## is_walkable, or the World's own (state.walkable: it knows the house its
## player is in).
static func walkable(state, cell: Vector2i) -> bool:
    return state.walkable.call(cell) if state.walkable.is_valid() else is_walkable(state, cell)

static func in_water(state, cell: Vector2i) -> bool:
    if state.tiles == null:
        return false
    var names := names_at(state, cell)
    return not names.is_empty() and "water" in names[0] and not "_tidal" in names[0]

static func can_enter(state, species: String, cell: Vector2i) -> bool:
    if species.to_lower() in ["araichu", "raichu_alolan", "aexeggutor", "exeggutor_alolan"] and \
            state.tiles != null and not state.blocked.has(cell):
        var tile: SourceTile = state.tiles.tile_at(cell)
        if tile != null and tile.is_water and not tile.is_solid:
            var route_name := "" if tile.route_belongs_to == null else tile.route_belongs_to.name.to_lower()
            if (species.to_lower() in ["araichu", "raichu_alolan"] and route_name == "beach2_water") or \
                    (route_name == "beach2" and is_beach_tidal_tile(tile)):
                return true
    if not state.in_bounds(cell) or state.blocked.has(cell):
        return false
    var structure: Dictionary = state.structures.get(cell, {})
    if String(structure.get("name", "")) == "FENCE" or bool(structure.get("gate", false)):
        return false
    if state.tiles != null:
        var tile: SourceTile = state.tiles.tile_at(cell)
        if tile != null and (tile.is_ledge or "fence" in tile.name.to_lower() or "fence" in tile.name_upper.to_lower()):
            return false
    var behavior: Dictionary = PokemonData.info(species).get("overworld_behavior", {})
    if bool(behavior.get("swim_only", false)):
        return terrain_kind_at(state, cell) == 0
    return walkable(state, cell) and terrain_kind_at(state, cell) != 0

## A step of `species` from `origin` to `target` (Pokemon.java Move/Wander).
static func can_move_between(state, species: String, origin: Vector2i, target: Vector2i) -> bool:
    if state.tiles != null:
        var destination: SourceTile = state.tiles.tile_at(target)
        var current: SourceTile = state.tiles.tile_at(origin)
        # Move/Wander reject ledges even when player-passable.
        if destination == null or destination.is_ledge:
            return false
        if current != null and current.is_ledge and permitted_ledge_direction(current) == Vector2i.UP and target.y < origin.y:
            return false
    if not in_water(state, origin):
        return can_enter(state, species, target)
    if not state.in_bounds(target) or state.blocked.has(target):
        return false
    var structure: Dictionary = state.structures.get(target, {})
    if String(structure.get("name", "")) == "FENCE" or bool(structure.get("gate", false)):
        return false
    if state.tiles != null:
        var tile: SourceTile = state.tiles.tile_at(target)
        if tile == null or "fence" in tile.name_upper or "fence" in tile.name:
            return false
        var near_shore := false
        var target_near_shore := false
        for y in range(-1, 2):
            for x in range(-1, 2):
                var direction := Vector2i(x, y)
                var shore: SourceTile = state.tiles.tile_at(origin + direction)
                var target_shore: SourceTile = state.tiles.tile_at(target + direction)
                near_shore = near_shore or (shore != null and not "water" in shore.name)
                target_near_shore = target_near_shore or (target_shore != null and not "water" in target_shore.name)
        if near_shore and (not target_near_shore or not "water" in tile.name):
            return false
        var only_swim := bool(PokemonData.info(species).get("overworld_behavior", {}).get("swim_only", false))
        return tile.is_water if only_swim else (tile.is_water or not tile.is_solid)
    return can_enter(state, species, target)

static func cardinal_direction(delta: Vector2i, away: bool) -> Vector2i:
    var direction := Vector2i.ZERO
    if absi(delta.x) >= absi(delta.y):
        direction = Vector2i(signi(delta.x), 0)
    else:
        direction = Vector2i(0, signi(delta.y))
    return -direction if away else direction

## Seconds until a Pokemon of `species` moves again.
static func wild_move_delay(state, species: String, data: Dictionary = {}) -> float:
    if bool(data.get("burrowed", false)):
        return 999999.0
    var normalized := species.to_lower()
    if normalized in ["diglett", "dugtrio", "sharpedo"]:
        return state.rng.randf_range(0.35, 0.8)
    if bool(PokemonData.info(normalized).get("overworld_behavior", {}).get("lunge", false)):
        return state.rng.randf_range(0.35, 0.8)
    return state.rng.randf_range(WILD_MOVE_MIN, WILD_MOVE_MAX)

# --- Who is who ---------------------------------------------------------------------

## The habitat or wild record with this ecology id, {} if none.
static func ecology_record_by_id(state, ecology_id: String) -> Dictionary:
    if ecology_id.is_empty():
        return {}
    for data in state.habitat.records.values():
        if String((data as Dictionary).get("ecology_id", "")) == ecology_id:
            return data as Dictionary
    return wild_ecology_record(state, ecology_id)

static func ecology_cell_by_id(state, ecology_id: String) -> Vector2i:
    var deployed: Dictionary = state.habitat.records
    for raw_cell in deployed.keys():
        var data: Dictionary = deployed[raw_cell]
        if String(data.get("ecology_id", "")) == ecology_id:
            return Vector2i(raw_cell)
    var record := wild_ecology_record(state, ecology_id)
    if not record.is_empty():
        return Vector2i(record.get("cell", Vector2i.ZERO))
    return NO_CELL

## The wild record with this ecology id, {} if none. A wild Pokemon is named
## "wild:<its key>" (one per key), so that key is looked at first: scanning
## every wild Pokemon in the world for a mate was most of a wandering step.
static func wild_ecology_record(state, ecology_id: String) -> Dictionary:
    var wild: Dictionary = state.wild.records
    if ecology_id.begins_with("wild:"):
        var record = wild.get(int(ecology_id.substr(5)))
        if record != null and String(record.get("ecology_id", "")) == ecology_id:
            return record
    for data in wild.values():
        if String((data as Dictionary).get("ecology_id", "")) == ecology_id:
            return data as Dictionary
    return {}

## A paired Pokemon's step: free about the 7x7 habitat square, pulled back to
## its mate at the edge, the two drawn together when an egg is due.
static func paired_wander_direction(state, data: Dictionary, origin: Vector2i, fallback: Vector2i) -> Vector2i:
    var mate_id := String(data.get("mate_id", ""))
    if mate_id.is_empty():
        return fallback
    var mate_cell := ecology_cell_by_id(state, mate_id)
    if mate_cell.x <= -2147483648:
        return fallback
    var delta := mate_cell - origin
    var distance := maxi(absi(delta.x), absi(delta.y))
    var egg_ready := bool(data.get("can_lay_egg", false)) and \
        float(data.get("lay_egg_seconds", PokemonEcology.LAY_EGG_SECONDS)) <= 0.0
    # Do not glue paired parents together: only pull them back at the edge of
    # the square; converge them when an egg is ready.
    if egg_ready and distance > 1:
        return cardinal_direction(delta, false)
    if distance > PokemonEcology.HABITAT_RADIUS:
        return cardinal_direction(delta, false)
    if distance == PokemonEcology.HABITAT_RADIUS and state.rng.randf() < 0.25:
        return cardinal_direction(delta, false)
    if distance <= 1 and state.rng.randf() < 0.22:
        return cardinal_direction(delta, true)
    return fallback

# --- Eggs ---------------------------------------------------------------------------

## A cell an egg may lie on: free ground, nothing standing or built there.
static func egg_ground_ok(state, cell: Vector2i, ignored_wild_id: int = -1) -> bool:
    if not state.in_bounds(cell):
        return false
    if (
            state.eggs.records.has(cell) or state.habitat.records.has(cell)
            or state.wild.id_at(cell, ignored_wild_id) >= 0
            or state.structures.has(cell) or state.landmarks.has(cell)
            or state.blocked.has(cell)
        ):
        return false
    # The full visible footprint of exact resources, especially the 48x48
    # Savanna tree whose authored anchor is only one tile.
    if TileRules.exact_resource_anchor(state, cell).x > -2147483648:
        return false
    if state.tiles == null:
        return false
    var tile: SourceTile = state.tiles.tile_at(cell)
    return not (tile == null or tile.is_water or tile.is_solid or tile.is_ledge)

## The nearest egg cell to `preferred` (its four neighbours first, then ring
## by ring over the habitat square), drawing no random numbers; NO_CELL if none.
static func resolve_egg_cell(state, preferred: Vector2i, ignored_wild_id: int = -1) -> Vector2i:
    if egg_ground_ok(state, preferred, ignored_wild_id):
        return preferred
    var preferred_offsets: Array[Vector2i] = [Vector2i.DOWN, Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP]
    for offset in preferred_offsets:
        var nearby := preferred + offset
        if egg_ground_ok(state, nearby, ignored_wild_id):
            return nearby
    for radius in range(1, PokemonEcology.HABITAT_RADIUS + 1):
        for y_offset in range(-radius, radius + 1):
            for x_offset in range(-radius, radius + 1):
                if maxi(absi(x_offset), absi(y_offset)) != radius:
                    continue
                var offset := Vector2i(x_offset, y_offset)
                if preferred_offsets.has(offset):
                    continue
                var candidate := preferred + offset
                if egg_ground_ok(state, candidate, ignored_wild_id):
                    return candidate
    return NO_CELL

static func couple_egg_count(state, first_id: String, second_id: String) -> int:
    if first_id.is_empty() or second_id.is_empty():
        return 0
    var count := 0
    for egg in state.eggs.records.values():
        if bool((egg as Dictionary).get("dropped_party_egg", false)):
            continue
        var parents = (egg as Dictionary).get("parent_ids", [])
        if parents is Array and parents.has(first_id) and parents.has(second_id):
            count += 1
    return count

## A parent whose clock ran out lays beside `egg_cell` (its own cell), when its
## mate is near, both are in their habitat and the couple has room for one more.
static func try_create_parent_egg(state, data: Dictionary, egg_cell: Vector2i, ignored_wild_id: int = -1) -> Dictionary:
    if float(data.get("lay_egg_seconds", PokemonEcology.LAY_EGG_SECONDS)) > 0.0 or not bool(data.get("can_lay_egg", false)):
        return data
    var partner := ecology_record_by_id(state, String(data.get("mate_id", "")))
    if partner.is_empty():
        return data
    var partner_cell := ecology_cell_by_id(state, String(data.get("mate_id", "")))
    if (
            partner_cell.x <= -2147483648
            or maxi(absi(partner_cell.x - egg_cell.x), absi(partner_cell.y - egg_cell.y)) > PokemonEcology.HABITAT_RADIUS
            or not bool(data.get("in_habitat", false))
            or not bool(partner.get("in_habitat", false))
            or not PokemonEcology.can_mate(data, partner)
        ):
        return data
    # Nothing removes a habitat egg for days (release_old_eggs): an undisturbed
    # couple waits a full cycle once it has its eggs.
    if couple_egg_count(state, String(data.get("ecology_id", "")), String(partner.get("ecology_id", ""))) >= PokemonEcology.MAX_EGGS_PER_COUPLE:
        data["lay_egg_seconds"] = PokemonEcology.LAY_EGG_SECONDS
        return data
    # The parent stands on egg_cell: the egg goes to the nearest free ground.
    var resolved_cell := resolve_egg_cell(state, egg_cell, ignored_wild_id)
    if resolved_cell.x <= -2147483648:
        return data
    var egg := PokemonEcology.egg_record(data, partner, state.rng)
    add_egg(state, String(egg.get("species", "pidgey")), resolved_cell, egg, ignored_wild_id)
    data["lay_egg_seconds"] = PokemonEcology.LAY_EGG_SECONDS
    _emote(state, data, "heart")
    _emote(state, partner, "heart")
    return data

## An egg set down on (or, unless a player dropped it or `resolve` is false,
## beside) `cell`.
static func add_egg(state, species: String, cell: Vector2i, egg_record: Dictionary = {}, ignored_wild_id: int = -1,
        resolve: bool = true) -> void:
    if resolve and not bool(egg_record.get("dropped_party_egg", false)):
        cell = resolve_egg_cell(state, cell, ignored_wild_id)
    if cell.x <= -2147483648:
        return
    var indoors := egg_record.has("house_door")
    # A World not drawn yet takes no egg outdoors; one in a house has a sprite of its own.
    var sprite = null
    if state.view != null:
        sprite = state.view._egg_sprite(cell, indoors)
        if sprite is bool:
            return
    var stored := egg_record.duplicate(true)
    stored["species"] = species.to_lower()
    stored["egg_species"] = String(stored.get("egg_species", species)).to_lower()
    stored["base_species"] = String(stored.get("base_species", PokemonEcology.base_species_for(species)))
    stored["egg_groups"] = stored.get("egg_groups", PokemonData.info(species).get("egg_groups", ["EGG_NONE", "EGG_NONE"]))
    stored["is_egg"] = true
    stored["hatch_cycles"] = maxi(1, int(stored.get("hatch_cycles", PokemonData.info(species).get("egg_cycles", 20))))
    stored["hatch_steps"] = int(stored.get("hatch_steps", int(stored["hatch_cycles"]) * PokemonEcology.EGG_STEP_INTERVAL))
    stored["cell"] = cell
    stored.erase("sprite")
    if sprite != null:
        stored["sprite"] = sprite
        sprite.visible = state.view._house_pokemon_visible(stored)
    if bool(stored.get("dropped_party_egg", false)) and egg_record.has("hatch_cycles"):
        stored["hatch_cycles"] = int(egg_record["hatch_cycles"])
    state.eggs.place(cell, stored)

## A habitat egg left alone is released into the wild after EGG_RELEASE_DAYS
## (it leaves the overworld); eggs a player set down stay. `may_release`
## (an egg -> bool) leaves out those another simulates.
static func release_old_eggs(state, may_release: Callable = Callable()) -> void:
    var lifetime := PokemonEcology.EGG_RELEASE_DAYS * DAY_SECONDS
    var eggs: Dictionary = state.eggs.records
    for raw_cell in eggs.keys():
        var egg: Dictionary = eggs[raw_cell]
        if bool(egg.get("dropped_party_egg", false)) or (may_release.is_valid() and not may_release.call(egg)):
            continue
        if not egg.has("laid_at") or float(egg["laid_at"]) > state.clock:
            egg["laid_at"] = state.clock
            state.eggs.mark(raw_cell)
            continue
        if state.clock - float(egg["laid_at"]) < lifetime:
            continue
        if state.view != null:
            state.view._drop_record_sprite(egg)
        state.eggs.take(raw_cell)

# --- Habitats -----------------------------------------------------------------------

static func is_night(state) -> bool:
    return fmod(state.clock, DAY_SECONDS) / DAY_SECONDS >= NIGHT_START

## The habitat names of a cell: its tile's, " grass" for encounter grass, and
## what lies on it (placed_names). `house_cells`: the floor of the house the
## World's player is in, named by what is built there.
static func ecology_names_at(state, cell: Vector2i, house_cells: Dictionary = {}) -> String:
    if house_cells.has(cell):
        return "house_floor " + String((state.structures.get(cell, {}) as Dictionary).get("name", "")).to_lower()
    # A packed tile: the same names as below from the tile's, without the
    # lookups, the lowering and the biome (a tile object each) for every cell.
    var tiles = state.tiles.tiles if state.tiles != null else null
    if tiles is WorldTileStore:
        var store: WorldTileStore = tiles
        var index: int = store.index_of(cell * TILE)
        if index >= 0:
            var memo: Dictionary = state.memo
            if not is_same(store, memo.get("names_store")):
                memo["names_store"] = store
                memo["names"] = {}
                memo["biomes"] = {}
            var known: Dictionary = memo["names"]
            var pair: int = store.name_ids[index] << 24 | store.upper_ids[index]
            var own = known.get(pair)
            if own == null:
                var name: String = store.name_at(index)
                var upper: String = store.upper_at(index)
                own = [name.to_lower() + " " + upper.to_lower(), tile_key(name) == "grass1" or tile_key(upper) == "grass1"]
                known[pair] = own
            # is_tall_grass_cell, from the same fields.
            var flags: int = store.flags[index]
            var grass: bool
            if flags & WorldTileStore.TIDAL != 0 and _packed_tile_biome(state, store, index, cell) != "BEACH":
                grass = false
            else:
                grass = own[1] or flags & WorldTileStore.GRASS != 0
            return own[0] + (" grass" if grass else "") + placed_names(state, cell)
    if not state.in_bounds(cell):
        return ""
    var names: Array[String] = []
    if state.tiles != null:
        var tile_names := names_at(state, cell)
        if not tile_names.is_empty():
            names.append(tile_names[0].to_lower())
            names.append(tile_names[1].to_lower())
    if is_tall_grass_cell(state, cell):
        names.append("grass")
    var own := " ".join(names)
    var placed := placed_names(state, cell)
    return placed.substr(1) if own.is_empty() else own + placed

## biome_at for packed tile `index` of `store` (kept in state.memo by kind).
static func _packed_tile_biome(state, store: WorldTileStore, index: int, cell: Vector2i) -> String:
    var kind: int = (store.biome_ids[index] << 32) | (store.route_ids[index] << 1) | int(store.flags[index] & WorldTileStore.WATER != 0)
    var biomes: Dictionary = state.memo["biomes"]
    var biome = biomes.get(kind)
    if biome == null:
        biome = TileRules.source_biome(state.tiles.tile_at(cell))
        biomes[kind] = biome
    return biome

## The habitat names of what lies on `cell` (flowers, buildings, landmarks,
## ice), each after a space.
static func placed_names(state, cell: Vector2i) -> String:
    var names := ""
    if state.flowers.has(cell):
        names += " flower"
    if state.structures.has(cell):
        var built_name := String((state.structures[cell] as Dictionary).get("name", "")).to_lower()
        names += " " + built_name
        if built_name == "flowers":
            names += " flower"
        elif built_name == "plant":
            names += " potted"
        elif built_name == "grave":
            names += " gravestone"
    if state.landmarks.has(cell):
        names += " " + String((state.landmarks[cell] as Dictionary).get("type", "")).to_lower()
    var changes: Dictionary = state.terrain_changes
    if not changes.is_empty() and bool(changes.get("ice:%d,%d" % [cell.x, cell.y], false)):
        names += " snow"
    return names

## Which of its species' habitat needs the square around `cell` meets
## (missing_habitats, in_habitat) and whether it is sheltered (in_shelter).
static func refresh_record_habitat(state, data: Dictionary, cell: Vector2i, ecology_name_cache: Dictionary = {},
        house_cells: Dictionary = {}) -> Dictionary:
    var species := String(data.get("species", ""))
    # The seven-by-seven habitat window, built once.
    var nearby_names := PackedStringArray()
    var fence_count := 0
    var roof_count := 0
    for y in range(cell.y - PokemonEcology.HABITAT_RADIUS, cell.y + PokemonEcology.HABITAT_RADIUS + 1):
        for x in range(cell.x - PokemonEcology.HABITAT_RADIUS, cell.x + PokemonEcology.HABITAT_RADIUS + 1):
            var habitat_cell := Vector2i(x, y)
            var names = ecology_name_cache.get(habitat_cell)
            if names == null:
                names = ecology_names_at(state, habitat_cell, house_cells)
                ecology_name_cache[habitat_cell] = names
            nearby_names.append(names)
            if "fence" in names:
                fence_count += 1
            elif "roof" in names:
                roof_count += 1
    # No habitat option holds a space, so one is in the joined window exactly
    # when it is in one of the cells' names. The species' groups are kept in
    # the same cache by name.
    var window := " ".join(nearby_names)
    var habitat = ecology_name_cache.get(species)
    if habitat == null:
        var groups := []
        for raw_group in PokemonEcology.habitat_groups(species):
            groups.append([String(raw_group), String(raw_group).to_lower().split("|")])
        habitat = [groups, PokemonEcology.requires_night(species)]
        ecology_name_cache[species] = habitat
    var missing: Array[String] = []
    for group in habitat[0]:
        var satisfied := false
        for option in group[1]:
            if option in window:
                satisfied = true
                break
        if not satisfied:
            missing.append(group[0])
    if habitat[1] and not is_night(state):
        missing.append("night")
    data["missing_habitats"] = missing
    data["in_habitat"] = missing.is_empty()
    data["in_shelter"] = roof_count >= 3 and fence_count >= 2
    return data

## The habitat check every HABITAT_CHECK_SECONDS (state.ecology_accumulator):
## who pairs and makes friends, habitats, produce, and the breeding and
## friendship clocks of the habitat Pokemon and of the wild ones near
## `centers` (the players who keep them going) or a habitat. `simulated` (a
## record -> bool) picks the habitat Pokemon moved on here (all when
## invalid); with_wild false leaves the wild ones to another. `may_release`:
## release_old_eggs.
static func run_ecology_step(state, delta: float, centers: Array, simulated: Callable = Callable(), with_wild: bool = true,
        house_cells: Dictionary = {}, may_release: Callable = Callable()) -> void:
    state.ecology_accumulator += delta
    if state.ecology_accumulator < PokemonEcology.HABITAT_CHECK_SECONDS:
        return
    var ecology_delta: float = state.ecology_accumulator
    state.ecology_accumulator = fmod(state.ecology_accumulator, PokemonEcology.HABITAT_CHECK_SECONDS)
    var deployed: Dictionary = state.habitat.records
    # What the pass sets of each habitat Pokemon besides its clocks, as it was:
    # one whose changes is marked for co-op (habitat dirty).
    var before := {}
    for raw_cell in deployed:
        var record: Dictionary = deployed[raw_cell]
        before[raw_cell] = ECOLOGY_FIELDS.map(func(field: String) -> Variant: return record.get(field))
    var active_wild := refresh_relationships(state, centers, simulated, with_wild, house_cells)
    release_old_eggs(state, may_release)
    for raw_cell in deployed.keys():
        var cell: Vector2i = raw_cell
        if not deployed.has(cell):
            continue
        var data: Dictionary = deployed[cell]
        if simulated.is_valid() and not simulated.call(data):
            continue
        if bool(data.get("in_habitat", false)) and String(data.get("held_item", "")).is_empty():
            var shelter_multiplier := 2.0 if bool(data.get("in_shelter", false)) else 1.0
            data["harvest_progress"] = float(data.get("harvest_progress", 0.0)) + ecology_delta * shelter_multiplier
            var harvest_max := PokemonEcology.harvest_seconds(String(data.get("species", "")))
            if float(data["harvest_progress"]) >= harvest_max:
                var choices := PokemonEcology.harvest_items(String(data.get("species", "")))
                if not choices.is_empty():
                    data["held_item"] = choices[state.rng.randi_range(0, choices.size() - 1)]
        data = advance_breeding_clock(data, ecology_delta)
        deployed[cell] = data
        if before.get(cell) != ECOLOGY_FIELDS.map(func(field: String) -> Variant: return data.get(field)):
            state.habitat.mark(cell)
    # The wild Pokemon in play are the ones the relationship pass just took;
    # nothing since has moved one, and each clock is its own record's.
    for data in active_wild:
        advance_breeding_clock(data, ecology_delta, true)

static func advance_breeding_clock(data: Dictionary, delta: float, allow_wild_crowding: bool = false) -> Dictionary:
    var population_ok := allow_wild_crowding or int(data.get("nearby_pokemon", 0)) < 3
    if (
            bool(data.get("can_lay_egg", false))
            and bool(data.get("in_habitat", false))
            and bool(data.get("mate_nearby", false))
            and population_ok
            and float(data.get("lay_egg_seconds", PokemonEcology.LAY_EGG_SECONDS)) > 0.0
        ):
        data["lay_egg_seconds"] = maxf(0.0, float(data.get("lay_egg_seconds", PokemonEcology.LAY_EGG_SECONDS)) - delta)
    if (
            not String(data.get("friend_id", "")).is_empty()
            and float(data.get("friend_seconds", PokemonEcology.FRIEND_SECONDS)) > 0.0
        ):
        data["friend_seconds"] = maxf(0.0, float(data.get("friend_seconds", PokemonEcology.FRIEND_SECONDS)) - delta)
    return data

## Mates, friends, crowding and habitats of the habitat Pokemon and of the
## wild ones near `centers` or a habitat. Returns the wild records it covered,
## in the population's order. `simulated`, with_wild: run_ecology_step.
static func refresh_relationships(state, centers: Array, simulated: Callable = Callable(), with_wild: bool = true,
        house_cells: Dictionary = {}) -> Array[Dictionary]:
    var records: Array[Dictionary] = []
    var active_wild: Array[Dictionary] = []
    # Habitat windows heavily overlap: each cell's names are worked out once a pass.
    var ecology_name_cache: Dictionary = {}
    # The wild Pokemon near a center or a habitat (as WildPopulation.tick keeps
    # going), from the buckets of the wild population's grid those squares touch.
    var squares: Array = []
    for center: Vector2i in centers:
        squares.append(Vector3i(center.x, center.y, ECOLOGY_ACTIVE_RADIUS))
    var deployed: Dictionary = state.habitat.records
    var eggs: Dictionary = state.eggs.records
    var wild = state.wild
    for raw_cell in deployed.keys():
        var cell: Vector2i = raw_cell
        if simulated.is_valid() and not simulated.call(deployed[cell]):
            continue
        records.append({"kind": "deployed", "key": cell, "cell": cell, "data": deployed[cell]})
        squares.append(Vector3i(cell.x, cell.y, PokemonEcology.HABITAT_RADIUS))
    for slot in (wild.slots_in(squares) if with_wild else PackedInt32Array()):
        var raw_id = wild.ids[slot]
        var wild_data: Dictionary = wild.records[raw_id]
        if bool(wild_data.get("burrowed", false)):
            continue
        var wild_cell: Vector2i = wild_data.get("cell", Vector2i.ZERO)
        active_wild.append(wild_data)
        records.append({"kind": "wild", "key": raw_id, "cell": wild_cell, "data": wild_data})

    var index_by_id: Dictionary = {}
    var cell_indices: Dictionary = {}
    for index in range(records.size()):
        var descriptor: Dictionary = records[index]
        var data: Dictionary = descriptor["data"]
        data["previous_mate_id"] = String(data.get("mate_id", ""))
        data["mate_id"] = ""
        data["friend_id"] = ""
        data["can_lay_egg"] = false
        data["mate_nearby"] = false
        data["nearby_pokemon"] = 0
        data = refresh_record_habitat(state, data, descriptor["cell"], ecology_name_cache, house_cells)
        descriptor["data"] = data
        records[index] = descriptor
        var ecology_id := String(data.get("ecology_id", ""))
        if not ecology_id.is_empty():
            index_by_id[ecology_id] = index
        var record_cell: Vector2i = descriptor["cell"]
        if not cell_indices.has(record_cell):
            cell_indices[record_cell] = []
        (cell_indices[record_cell] as Array).append(index)

    # An established compatible pair stays bonded while it wanders a few tiles apart.
    for index in range(records.size()):
        var first_descriptor: Dictionary = records[index]
        var first: Dictionary = first_descriptor["data"]
        var former_mate_id := String(first.get("previous_mate_id", ""))
        if former_mate_id.is_empty() or not index_by_id.has(former_mate_id):
            continue
        var mate_index := int(index_by_id[former_mate_id])
        if mate_index <= index:
            continue
        var second_descriptor: Dictionary = records[mate_index]
        var second: Dictionary = second_descriptor["data"]
        if String(second.get("previous_mate_id", "")) != String(first.get("ecology_id", "")):
            continue
        var first_cell: Vector2i = first_descriptor["cell"]
        var second_cell: Vector2i = second_descriptor["cell"]
        var separation := maxi(absi(first_cell.x - second_cell.x), absi(first_cell.y - second_cell.y))
        if separation > MATE_BOND_RADIUS or not PokemonEcology.can_mate(first, second):
            continue
        first["mate_id"] = String(second.get("ecology_id", ""))
        second["mate_id"] = String(first.get("ecology_id", ""))
        first_descriptor["data"] = first
        second_descriptor["data"] = second
        records[index] = first_descriptor
        records[mate_index] = second_descriptor
    var nearby_indices: Array = []
    for index in range(records.size()):
        var descriptor: Dictionary = records[index]
        var center: Vector2i = descriptor["cell"]
        var nearby := 0
        var candidates: Array[int] = []
        for y in range(center.y - PokemonEcology.HABITAT_RADIUS, center.y + PokemonEcology.HABITAT_RADIUS + 1):
            for x in range(center.x - PokemonEcology.HABITAT_RADIUS, center.x + PokemonEcology.HABITAT_RADIUS + 1):
                var test := Vector2i(x, y)
                if cell_indices.has(test):
                    for raw_candidate_index in cell_indices[test]:
                        var candidate_index := int(raw_candidate_index)
                        if candidate_index != index:
                            nearby += 1
                            candidates.append(candidate_index)
                if eggs.has(test):
                    nearby += 1
        # The former record-order choice when more than one mate or friend is near.
        candidates.sort()
        nearby_indices.append(candidates)
        var data: Dictionary = descriptor["data"]
        data["nearby_pokemon"] = nearby
        descriptor["data"] = data
        records[index] = descriptor

    for index in range(records.size()):
        var first_descriptor: Dictionary = records[index]
        var first: Dictionary = first_descriptor["data"]
        if not String(first.get("mate_id", "")).is_empty():
            continue
        for raw_candidate_index in nearby_indices[index]:
            var candidate_index := int(raw_candidate_index)
            if candidate_index <= index:
                continue
            var second_descriptor: Dictionary = records[candidate_index]
            var second: Dictionary = second_descriptor["data"]
            if not String(second.get("mate_id", "")).is_empty():
                continue
            if not PokemonEcology.can_mate(first, second):
                continue
            first["mate_id"] = String(second.get("ecology_id", ""))
            second["mate_id"] = String(first.get("ecology_id", ""))
            first["friend_id"] = ""
            second["friend_id"] = ""
            first_descriptor["data"] = first
            second_descriptor["data"] = second
            records[index] = first_descriptor
            records[candidate_index] = second_descriptor
            break

    for index in range(records.size()):
        var first_descriptor: Dictionary = records[index]
        var first: Dictionary = first_descriptor["data"]
        if not String(first.get("mate_id", "")).is_empty() or not String(first.get("friend_id", "")).is_empty():
            continue
        for raw_candidate_index in nearby_indices[index]:
            var candidate_index := int(raw_candidate_index)
            if candidate_index <= index:
                continue
            var second_descriptor: Dictionary = records[candidate_index]
            var second: Dictionary = second_descriptor["data"]
            if (
                    not String(second.get("mate_id", "")).is_empty()
                    or not String(second.get("friend_id", "")).is_empty()
                    or not PokemonEcology.can_be_friends(first, second)
                ):
                continue
            first["friend_id"] = String(second.get("ecology_id", ""))
            second["friend_id"] = String(first.get("ecology_id", ""))
            first_descriptor["data"] = first
            second_descriptor["data"] = second
            records[index] = first_descriptor
            records[candidate_index] = second_descriptor
            break

    for index in range(records.size()):
        var descriptor: Dictionary = records[index]
        var data: Dictionary = descriptor["data"]
        var mate_id := String(data.get("mate_id", ""))
        if not mate_id.is_empty() and index_by_id.has(mate_id):
            var mate_descriptor: Dictionary = records[int(index_by_id[mate_id])]
            var mate: Dictionary = mate_descriptor["data"]
            var groups: Array = data.get("egg_groups", [])
            data["can_lay_egg"] = (
                String(data.get("gender", "")) == "female"
                or (groups.has("EGG_DITTO") and String(mate.get("gender", "")) == "male")
            )
            var own_cell: Vector2i = descriptor["cell"]
            var mate_cell: Vector2i = mate_descriptor["cell"]
            data["mate_nearby"] = maxi(absi(own_cell.x - mate_cell.x), absi(own_cell.y - mate_cell.y)) <= PokemonEcology.HABITAT_RADIUS
        if not mate_id.is_empty() and mate_id != String(data.get("previous_mate_id", "")):
            _emote(state, data, "heart")
        data.erase("previous_mate_id")
        descriptor["data"] = data
        records[index] = descriptor
        if String(descriptor.get("kind", "")) == "deployed":
            if deployed.has(descriptor["key"]):
                deployed[descriptor["key"]] = data
        elif wild.records.has(descriptor["key"]):
            wild.records[descriptor["key"]] = data
    return active_wild

# --- Records ------------------------------------------------------------------------

## A new wild Pokemon's record before it is made (its saved state, or what its
## source says), with its shiny roll: the first draw it takes.
static func wild_source(state, species: String, level: int, source_record: Dictionary, saved_state: Dictionary) -> Dictionary:
    var ecology_source := saved_state.duplicate(true) if not saved_state.is_empty() else source_record.duplicate(true)
    ecology_source["species"] = species.to_lower()
    ecology_source["level"] = level
    PokemonState.ensure_shiny(ecology_source, state.rng)
    return ecology_source

## The record of a new wild Pokemon `wild_id` on `cell` from wild_source's
## `ecology_source` (its ecology, clocks and behaviour; its egg clock staggered
## when it is new).
static func wild_record(state, ecology_source: Dictionary, wild_id: int, cell: Vector2i, home_biome: String,
        source_record: Dictionary, saved_state: Dictionary) -> Dictionary:
    var species := String(ecology_source["species"])
    var is_burrowed := bool(source_record.get("is_trapping", false))
    var stored := PokemonEcology.ensure_record(ecology_source, state.rng, "wild:%d" % wild_id)
    if saved_state.is_empty():
        # Keep the two-minute repeat cycle, but stagger a new world's first egg.
        stored["lay_egg_seconds"] = state.rng.randf_range(0.0, WILD_INITIAL_EGG_SECONDS)
    stored["id"] = wild_id
    stored["cell"] = cell
    stored["home_biome"] = home_biome
    stored["burrowed"] = is_burrowed
    stored["burrow_active"] = false
    stored["burrow_tick"] = 0
    stored["burrow_time"] = 0.0
    stored["burrow_whirl_tick"] = 0
    stored["move_timer"] = float(stored.get("move_timer", wild_move_delay(state, species, stored)))
    stored["anim_phase"] = 0
    stored["behavior"] = PokemonData.info(species).get("overworld_behavior", {})
    stored["source_record"] = source_record.duplicate(true)
    # Source aggression affects how quickly a Pokemon becomes provoked; it is
    # not permission to force a battle on the first click or spawn frame.
    stored["aggro_player"] = bool(stored.get("aggro_player", source_record.get("aggressive", false)))
    stored["fed_until"] = float(stored.get("fed_until", 0.0))
    stored["flee_steps"] = int(stored.get("flee_steps", 0))
    return stored

## Whether `record` has overworld art (PokemonData.record_texture is not
## null), worked out once per species, form and shininess: the texture is
## loaded for the answer and let go, so asking for every Pokemon read in
## loaded it from disk again each time (most of an area's read on a server).
static var _art := {}
static func has_art(record: Dictionary) -> bool:
    var key := "%s|%s|%s" % [record.get("species", record.get("name", "")), String(record.get("form", "")).to_lower(), PokemonData.is_shiny(record)]
    var known = _art.get(key)
    if known == null:
        known = PokemonData.record_texture(record, "overworld") != null
        _art[key] = known
    return known

## A wild Pokemon added to the area's population as world.gd
## _create_wild_pokemon adds one (its sprite and sand trap aside): false when
## the cell is out of the world or taken, or its species has no overworld art.
static func add_wild(state, species: String, level: int, cell: Vector2i, home_biome: String, wild_id: int,
        source_record: Dictionary = {}, saved_state: Dictionary = {}) -> bool:
    if not state.in_bounds(cell) or state.wild.id_at(cell) >= 0:
        return false
    var ecology_source := wild_source(state, species, level, source_record, saved_state)
    if not bool(source_record.get("is_trapping", false)) and not has_art(ecology_source):
        return false
    # No world drawn yet, no wild Pokemon (its sprite is the WildPokemonLayer's).
    if state.view != null and state.view.get_node_or_null("WildPokemonLayer") == null:
        return false
    state.wild.add(wild_id, wild_record(state, ecology_source, wild_id, cell, home_biome, source_record, saved_state))
    return true

# --- A new area's first Pokemon ---------------------------------------------------

## The species of a new wild Pokemon of `level` on `cell` that meets a
## stronger party (`adaptive_level`, BattleSession.wild_level): the source's
## evolution checks run again at that level, with draws of their own from the
## world's seed and the cell (never state.rng), kept to its route's species
## and to those with overworld art. `species` itself otherwise.
static func adapted_species(state, species: String, level: int, cell: Vector2i, adaptive_level: int, world_seed: int) -> String:
    if adaptive_level <= level:
        return species
    var evolution_rng := RandomNumberGenerator.new()
    evolution_rng.seed = (
        int(world_seed) * 1000003
        + cell.x * 73856093
        + cell.y * 19349663
        + adaptive_level * 83492791
        + species.hash()
    )
    var evolved_species := PokemonData.adaptive_source_evolution(species, adaptive_level, evolution_rng)
    var source_tile: SourceTile = state.tiles.tile_at(cell)
    var source_route_name := ""
    var source_is_water := false
    if source_tile != null:
        source_is_water = source_tile.is_water
        if source_tile.route_belongs_to != null:
            source_route_name = source_tile.route_belongs_to.name
    var route_allows_evolution := (
        source_route_name.is_empty()
        or PokemonData.source_route_species_allowed(evolved_species, source_route_name, source_is_water)
    )
    if route_allows_evolution and PokemonData.texture(evolved_species, "overworld") != null:
        return evolved_species
    return species

## The wild Pokemon of an area just made, as a World places them (world.gd
## _ensure_overworld_pokemon_population): its source records' Pokemon, a mate
## for each that can have one, the burrowed Trapinch, then any authored Alolan
## one still missing. `add` (species, level, cell, home biome, source record)
## puts one in and returns its wild id, -1 when it was not put in; `breathe`,
## when valid, is awaited between Pokemon (an area takes many frames' worth).
static func place_new(state, add: Callable, breathe: Callable = Callable()) -> void:
    var records: Array = state.tiles.pokemon_cell_records()
    await place_source(state, records, add, breathe)
    await place_mates(state, add, breathe)
    place_burrowed(state, state.tiles.burrowed_cell_records(), add)
    restore_alolan(state, add)

## The Pokemon of the source's spawn `records` (pokemon_cell_records).
static func place_source(state, records: Array, add: Callable, breathe: Callable = Callable()) -> void:
    for record in records:
        if breathe.is_valid():
            await breathe.call()
        var species := String(record.get("name", "")).to_lower()
        var cell: Vector2i = record.get("cell", Vector2i.ZERO)
        if species.is_empty() or not state.tiles.contains_cell(cell):
            continue
        var tile: SourceTile = state.tiles.tile_at(cell)
        var home_biome := "OCEAN" if tile == null else TileRules.source_biome(tile)
        add.call(species, int(record.get("level", 2)), cell, home_biome, record)

## A mate for each wild Pokemon that can have one (a new world's companions
## replace the old partial 50% density pass): one already near, else a new one
## of a species its route allows on a free cell near it in the same route,
## else the two moved to two free cells side by side in that route.
static func place_mates(state, add: Callable, breathe: Callable = Callable()) -> void:
    var wild: Dictionary = state.wild.records
    var occupied: Dictionary = {}
    for id in wild:
        occupied[wild[id].cell] = id
    var initial_ids := wild.keys()
    var paired: Dictionary = {}
    var offsets: Array[Vector2i] = []
    for radius in range(1, MATE_BOND_RADIUS + 1):
        for y in range(-radius, radius + 1):
            for x in range(-radius, radius + 1):
                if maxi(absi(x), absi(y)) == radius:
                    offsets.append(Vector2i(x, y))
    for id in initial_ids:
        if breathe.is_valid():
            await breathe.call()
        if paired.has(id): continue
        var original: Dictionary = wild[id]
        var species := String(original.species)
        var groups: Array = original.get("egg_groups", [])
        var gender := String(original.get("gender", "unknown"))
        if groups.has("EGG_NONE") or groups.has("EGG_DITTO") or gender == "unknown" or bool(original.get("burrowed", false)) or bool(original.get("behavior", {}).get("stationary", false)):
            continue
        var origin: Vector2i = original.cell
        # Use an existing adjacent compatible animal before adding another.
        var partner_id := -1
        for offset in offsets:
            var nearby_id := int(occupied.get(origin + offset, -1))
            if nearby_id >= 0 and not paired.has(nearby_id) and PokemonEcology.can_mate(original, wild[nearby_id]):
                partner_id = nearby_id
                break
        if partner_id < 0:
            var origin_tile: SourceTile = state.tiles.tile_at(origin)
            var route := "" if origin_tile == null or origin_tile.route_belongs_to == null else origin_tile.route_belongs_to.name
            var partner_gender := "male" if gender == "female" else "female"
            var partner_species := ""
            var candidates: Array[String] = [species]
            for candidate_species in SourceRouteData.allowed_pokemon(route):
                if not candidates.has(String(candidate_species)): candidates.append(String(candidate_species))
            for candidate_species in candidates:
                var info := PokemonData.info(candidate_species)
                var ratio := String(info.get("gender_ratio", "GENDER_UNKNOWN"))
                if ratio == "GENDER_UNKNOWN" or (ratio == "GENDER_F0" and partner_gender == "female") or (ratio == "GENDER_F100" and partner_gender == "male"): continue
                if PokemonData.texture(candidate_species, "overworld") == null: continue
                var test_partner := PokemonEcology.ensure_record({"species":candidate_species,"gender":partner_gender}, state.rng)
                if PokemonEcology.can_mate(original, test_partner):
                    partner_species = candidate_species
                    break
            if partner_species.is_empty(): continue
            for offset in offsets:
                var candidate := origin + offset
                if occupied.has(candidate) or state.eggs.records.has(candidate) or state.habitat.records.has(candidate) or not can_move_between(state, partner_species, origin, candidate): continue
                var tile: SourceTile = state.tiles.tile_at(candidate)
                if tile == null or tile.route_belongs_to == null or tile.route_belongs_to.name != route: continue
                var new_id: int = add.call(partner_species, int(original.level), candidate, String(original.home_biome), {"gender":partner_gender, "generation":original.get("source_record", {}).get("generation", "")})
                if new_id < 0 or not wild.has(new_id): continue
                occupied[candidate] = new_id
                partner_id = new_id
                break
            if partner_id < 0:
                # An isolated authored cell may have no room for two actors.
                # Find two adjacent cells in the SAME source route, keeping
                # both the terrain and the encounter species list intact.
                for radius in range(1, 17):
                    if partner_id >= 0: break
                    # A search that finds nothing took ~220 ms: a ring per slice.
                    if breathe.is_valid():
                        await breathe.call()
                    for y in range(-radius, radius + 1):
                        if partner_id >= 0: break
                        for x in range(-radius, radius + 1):
                            if maxi(absi(x), absi(y)) != radius: continue
                            var first := origin + Vector2i(x, y)
                            if occupied.has(first) or state.eggs.records.has(first) or state.habitat.records.has(first) or not can_move_between(state, species, origin, first): continue
                            var first_tile: SourceTile = state.tiles.tile_at(first)
                            if first_tile == null or first_tile.route_belongs_to == null or first_tile.route_belongs_to.name != route: continue
                            for direction in [Vector2i.LEFT,Vector2i.RIGHT,Vector2i.UP,Vector2i.DOWN]:
                                var second: Vector2i = first + direction
                                if occupied.has(second) or state.eggs.records.has(second) or state.habitat.records.has(second) or not can_move_between(state, partner_species, origin, second): continue
                                var second_tile: SourceTile = state.tiles.tile_at(second)
                                if second_tile == null or second_tile.route_belongs_to == null or second_tile.route_belongs_to.name != route: continue
                                var new_id: int = add.call(partner_species, int(original.level), second, String(original.home_biome), {"gender":partner_gender, "generation":original.get("source_record", {}).get("generation", "")})
                                if new_id < 0 or not wild.has(new_id): continue
                                occupied.erase(origin)
                                occupied[first] = id
                                occupied[second] = new_id
                                state.wild.move(id, first)
                                state.wild.snap(id)
                                partner_id = new_id
                                break
                            if partner_id >= 0: break
        if partner_id >= 0:
            var partner: Dictionary = wild[partner_id]
            original["mate_id"] = partner.ecology_id
            partner["mate_id"] = original.ecology_id
            wild[id] = original
            wild[partner_id] = partner
            paired[id] = true
            paired[partner_id] = true

## The burrowed Trapinch of the source's `records` (burrowed_cell_records).
static func place_burrowed(state, records: Array, add: Callable) -> void:
    for record in records:
        var cell: Vector2i = record.get("cell", Vector2i.ZERO)
        if not state.tiles.contains_cell(cell):
            continue
        var tile: SourceTile = state.tiles.tile_at(cell)
        var home_biome := "DESERT" if tile == null else TileRules.source_biome(tile)
        add.call("trapinch", int(record.get("level", 22)), cell, home_biome, record)

## The authored Alolan Raichu and Exeggutor, when the population has none
## (older saves kept theirs from before these had art): never another species.
static func restore_alolan(state, add: Callable) -> void:
    var present := {"araichu": false, "aexeggutor": false}
    for raw_data in state.wild.records.values():
        var species := String((raw_data as Dictionary).get("species", "")).to_lower()
        if species == "raichu_alolan":
            species = "araichu"
        elif species == "exeggutor_alolan":
            species = "aexeggutor"
        if present.has(species):
            present[species] = true
    for record in state.tiles.pokemon_cell_records():
        var species := String(record.get("name", "")).to_lower()
        if not present.has(species) or bool(present[species]):
            continue
        var cell: Vector2i = record.get("cell", Vector2i.ZERO)
        if state.wild.id_at(cell) >= 0:
            continue
        var tile: SourceTile = state.tiles.tile_at(cell)
        if tile == null:
            continue
        add.call(species, int(record.get("level", 2)), cell, TileRules.source_biome(tile), record)
        present[species] = true

## The record of a Pokemon left in a habitat (`entry`, as saved) on `cell`,
## with its ecology id.
static func habitat_record(state, entry: Dictionary, cell: Vector2i, ecology_id: String) -> Dictionary:
    var species := String(entry.get("species", "")).to_lower()
    var stored := PokemonEcology.ensure_record(entry, state.rng, ecology_id)
    stored["cell"] = cell
    stored["x"] = cell.x
    stored["y"] = cell.y
    stored["behavior"] = PokemonData.info(species).get("overworld_behavior", {})
    stored["move_timer"] = float(stored.get("move_timer", wild_move_delay(state, species)))
    stored.erase("sprite")
    return stored

## What a save holds of a wild or habitat Pokemon standing on `cell`: its
## record without what only runs (sprites, behaviour, the cell itself), its
## move timer and a sand trap's clock as they are now.
static func serializable_record(state, data: Dictionary, cell: Vector2i) -> Dictionary:
    var saved := data.duplicate(true)
    var wild_id := int(data.get("id", -1))
    if state.wild != null and is_same(state.wild.records.get(wild_id), data):
        # A wild Pokemon's move timer lives in its population's slot.
        saved["move_timer"] = state.wild.timer_of(wild_id)
        # A hidden sand trap's clock values live on the World's shared clock.
        if state.view != null and state.view.sand_trap_clock_of.has(wild_id):
            state.view._sand_trap_write(state.view.sand_trap_clock_of[wild_id], saved)
    for runtime_key in RUNTIME_FIELDS:
        saved.erase(runtime_key)
    var source_record = saved.get("source_record", {})
    if typeof(source_record) == TYPE_DICTIONARY:
        var serializable_source := (source_record as Dictionary).duplicate(true)
        serializable_source.erase("position")
        saved["source_record"] = serializable_source
    saved["x"] = cell.x
    saved["y"] = cell.y
    return saved

## What a save holds of an egg lying on `cell`.
static func serializable_egg(data: Dictionary, cell: Vector2i) -> Dictionary:
    var saved_egg := data.duplicate(true)
    saved_egg.erase("sprite")
    saved_egg.erase("cell")
    saved_egg["x"] = cell.x
    saved_egg["y"] = cell.y
    return saved_egg

static func _emote(state, data: Dictionary, emote: String) -> void:
    if state.view != null:
        state.view._show_ecology_emote(state.view._sprite_of(data), emote)
