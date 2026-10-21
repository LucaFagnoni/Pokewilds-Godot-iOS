class_name SourceIslandGenerator
extends RefCounted

const GenerationValidator = preload("res://scripts/source_generation_validator.gd")
var validation_records: Array[Dictionary] = []

const SourceLibGDXMath = preload("res://scripts/source_libgdx_math.gd")

const NEIGHBOURS_8: Array[Vector2i] = [
    Vector2i(16, 0), Vector2i(-16, 0), Vector2i(0, 16), Vector2i(0, -16),
    Vector2i(16, 16), Vector2i(-16, 16), Vector2i(-16, -16), Vector2i(16, -16)
]

# Gen 2 source identifiers retained by PokeWilds 0.8.11 for regional/forms.
# The extracted database uses descriptive identifiers instead.
const SOURCE_SPECIES_ALIASES := {
    "darmanitanzen": "darmanitan_zenmode",
    "aexeggutor": "exeggutor_alolan",
    "araichu": "raichu_alolan",
    "amarowak": "marowak_alolan",
    "combee_female": "combee"
}

const SOURCE_BASE_SPECIES_OVERRIDES := {
    "darmanitanzen": "darumaka",
    "aexeggutor": "exeggcute",
    "araichu": "pichu",
    "mantine": "mantyke",
    "combee_female": "combee",
    "azurill": "azurill",
    "marill": "azurill",
    "azumarill": "azurill",
    "amarowak": "cubone"
}

var origin: Vector2i
var radius: int
var random: SourceJavaRandom
var global_random: SourceJavaRandom
var forest_biome_random: SourceJavaRandom
var pokemon_random: SourceJavaRandom
# Counted membership preserves Array.erase's single-occurrence behavior.
# These collections are queried, never traversed, so generation order is unchanged.
var no_ice_here: Dictionary = {}
var bottom_mountain_layer: Dictionary = {}
var mountain_tiles: Dictionary = {}
var trapinch_spawns: Array[Vector2i] = []
var keystone_spawns: Array[Vector2i] = []
var pokemon_to_add: Dictionary = {}
var interior_pokemon: Array = []
var rand_offset := Vector2i.ZERO
var done_desert := 0
var num_sand_pits := 0
var unown_counter := 0
var tiles_to_add: Dictionary = {}
var interior_tiles_to_add: Array = []
var edges: Array[SourceTile] = []
## The ocean filled around the island (most of the map) is not made of tile
## objects: each such cell of tiles_to_add holds an int, an index into these
## read-only templates (bit 0: bottom edge row, bit 1: ocean1 route), until
## code needs that tile. tile_at() then makes it, equal to what the fill used
## to make. Loops over a snapshot of tiles_to_add skip or only read these
## cells: none of them changes an ocean tile in place.
var ocean_tiles: Array[SourceTile] = []

## The tile at `position` (null if none), made real if still an ocean cell.
func tile_at(position: Vector2i) -> SourceTile:
    return _get_tile(tiles_to_add, position)

## Like tiles.get(position) for any tile map (only tiles_to_add holds ocean
## cells), making an ocean cell real.
func _get_tile(tiles: Dictionary, position: Vector2i) -> SourceTile:
    var raw: Variant = tiles.get(position)
    if raw is int:
        raw = ocean_tiles[raw].copy_at(position)
        tiles[position] = raw
    return raw

## Read-only look at a cell: an ocean cell gives its shared template, whose
## position is not the cell's. Never change or keep what this returns.
func peek_tile(position: Vector2i) -> SourceTile:
    var raw: Variant = tiles_to_add.get(position)
    return ocean_tiles[raw] if raw is int else raw

func _name_of(raw: Variant) -> String:
    return ocean_tiles[raw].name if raw is int else (raw as SourceTile).name

## While the island blotches grow (generate_surface), the positions where the
## mountain overlay that follows them puts its own tile whatever is there:
## every mountain tile's, except the bottom layer's (the overlay keeps a
## bottom-layer cell's tile unless it is water2).
var _under_mountain: Dictionary = {}
## Read-only stand-ins for tiles_to_add's tiles at those positions, one per
## distinct (name, upper, solid, ledge). Until the overlay replaces them, later
## blotches only read an older cell's name, is_solid and is_ledge (frontiers
## only ask whether a cell is taken; merges, grass, mazes and ledge repairs
## replace an older cell's tile, never change it). Their position is no map
## cell, so a maze pass never takes one for a cell its own blotch made.
var _stand_ins: Dictionary = {}
const STAND_IN_POSITION := Vector2i(2147483647, 2147483647)

## The map apply_blotch_mountain's biome blotches grow into, and the cells
## where it reads their tiles afterwards (the mountain's). Anywhere else only
## whether a cell is taken matters, so it holds `true`, not a tile: the snow
## blotches near the peak spread far past the mountain (~380k cells on a
## size L map, ten times the mountain).
var _biome_tiles: Dictionary = {}
var _biome_read_cells: Dictionary = {}

## Swaps tiles_to_add's tiles under the mountain for shared stand-ins, so the
## island blotches do not keep tens of thousands of tile objects alive that
## the overlay throws away. Called once a blotch on tiles_to_add is done
## changing its own tiles in place. Maze ledges keep their tile: a later
## maze pass repairs around them from their position.
func _stand_in_under_mountain() -> void:
    for position: Vector2i in _under_mountain:
        var tile: SourceTile = tiles_to_add.get(position)
        if (tile == null or tile.position == STAND_IN_POSITION
                or tile.name == "ledge_grass_down" or tile.name == "ledge_ramp_down"):
            continue
        var key := "%s\n%s\n%d" % [tile.name, tile.name_upper, int(tile.is_solid) + 2 * int(tile.is_ledge)]
        var stand_in: SourceTile = _stand_ins.get(key)
        if stand_in == null:
            stand_in = SourceTile.new(tile.name, STAND_IN_POSITION, tile.name_upper, false, null, false)
            stand_in.name = tile.name
            stand_in.name_upper = tile.name_upper
            stand_in.is_solid = tile.is_solid
            stand_in.is_ledge = tile.is_ledge
            _stand_ins[key] = stand_in
        tiles_to_add[position] = stand_in

var bottom_left := Vector2i.ZERO
var top_right := Vector2i.ZERO
var done_pkmn_mansion := false
var done_pkmn_mansion_key := false
var done_regi_dungeon := false
var done_fossil_building := false
var done_desert_ruins := false
var graveyard_fence_bounds: Array[Rect2i] = []
var already_used_dungeons: Array[String] = []
var _qa_pokemon_sequence := 0
var _qa_trace_frontier := OS.get_environment("POKEWILDS_QA_TRACE_FRONTIER") == "1"
const BLOTCH_EDGE_OFFSETS: Array[Vector2i] = [
    Vector2i(-16, 0), Vector2i(16, 0), Vector2i(0, 16), Vector2i(0, -16)]

func _init(
        world_origin: Vector2i,
        world_radius: int,
        island_random: SourceJavaRandom,
        game_random: SourceJavaRandom,
        injected_forest_biome_random: SourceJavaRandom = null,
        injected_pokemon_random: SourceJavaRandom = null
    ) -> void:
    origin = world_origin
    radius = world_radius
    random = island_random
    global_random = game_random
    forest_biome_random = injected_forest_biome_random if injected_forest_biome_random != null else SourceJavaRandom.new(0)
    pokemon_random = injected_pokemon_random if injected_pokemon_random != null else SourceJavaRandom.new(int(Time.get_unix_time_from_system() * 1000000.0) ^ Time.get_ticks_usec())
    # GenIsland1 draws randOffset from Game.rand before constructing its own
    # java.util.Random. Keep the two streams separate, as in the source.
    rand_offset = Vector2i(global_random.next_int(100) * 16, global_random.next_int(100) * 16)
    interior_tiles_to_add.resize(102)

# Source-order surface portion of the GenIsland1 constructor. Structure and
# interior placement is applied by the dedicated routines that follow it.
func generate_surface() -> Dictionary:
    tiles_to_add.clear()
    pokemon_to_add.clear()
    edges.clear()
    keystone_spawns.clear()
    trapinch_spawns.clear()
    bottom_mountain_layer.clear()
    mountain_tiles.clear()
    done_desert = 0
    num_sand_pits = 0
    var maximum_distance := radius
    var origin_tile := SourceTile.new("sand1", origin)
    tiles_to_add[origin_tile.position] = origin_tile
    var endpoints := apply_blotch_mountain(origin_tile, maximum_distance, mountain_tiles)
    for raw_tile in mountain_tiles.values():
        var position := (raw_tile as SourceTile).position
        if not bottom_mountain_layer.has(position):
            _under_mountain[position] = true
    for tile in endpoints:
        if done_desert == 1:
            apply_blotch("desert", tile, maximum_distance / 18 + maximum_distance / 4, tiles_to_add, 1, true, SourceRoute.new("desert1", 40))
        else:
            done_desert += 1
            apply_blotch("island", tile, maximum_distance / 15, tiles_to_add, 1, true, SourceRoute.new("forest1", 40))
    # The overlay below replaces every stand-in.
    _under_mountain = {}
    _stand_ins = {}
    for raw_tile in SourceJavaHashOrder.values(mountain_tiles):
        var tile := raw_tile as SourceTile
        var existing := tiles_to_add.get(tile.position) as SourceTile
        if existing != null and existing.name != "water2" and bottom_mountain_layer.has(tile.position):
            continue
        tiles_to_add[tile.position] = tile
    for position in SourceJavaHashOrder.keys(mountain_tiles):
        pokemon_to_add.erase(position)
    _qa_surface_stage("mountain_overlay")
    var desert_tiles: Array[SourceTile] = []
    var deep_forest_tiles: Array[SourceTile] = []
    var forest_tiles: Array[SourceTile] = []
    var maximum_position := origin
    var minimum_position := origin
    for raw_tile in SourceJavaHashOrder.values(tiles_to_add):
        var tile := raw_tile as SourceTile
        maximum_position.x = maxi(maximum_position.x, tile.position.x)
        maximum_position.y = maxi(maximum_position.y, tile.position.y)
        minimum_position.x = mini(minimum_position.x, tile.position.x)
        minimum_position.y = mini(minimum_position.y, tile.position.y)
        if "desert" in tile.name:
            desert_tiles.append(tile)
        elif tile.biome == "deep_forest":
            deep_forest_tiles.append(tile)
        elif tile.route_belongs_to != null and tile.route_belongs_to.name == "forest1":
            forest_tiles.append(tile)
    var place_number := random.next_int(2) + 2
    var tries := 20
    while not deep_forest_tiles.is_empty() and not forest_tiles.is_empty():
        var patch_origin := forest_tiles[random.next_int(forest_tiles.size())]
        var is_forest := patch_origin.route_belongs_to != null and patch_origin.route_belongs_to.name == "forest1"
        var near_water := false
        for raw_tile in SourceJavaHashOrder.values(tiles_to_add):
            var candidate := raw_tile as SourceTile
            if "water" in candidate.name and Vector2(candidate.position).distance_squared_to(Vector2(patch_origin.position)) < 57600.0:
                near_water = true
                break
        # forest_tiles retains the pre-overlay Tile objects. Java re-reads the
        # current tilesToAdd value here so a location covered by an earlier
        # savanna blotch is rejected on later placement attempts.
        var current_patch := tiles_to_add.get(patch_origin.position) as SourceTile
        if ((current_patch != null and current_patch.biome == "savanna")
                or not is_forest or near_water):
            tries -= 1
            if tries > 0:
                continue
            break
        var new_tiles: Dictionary = {}
        apply_blotch("savanna1", patch_origin, 800, new_tiles, 0, false, SourceRoute.new("savanna2", 22))
        for position in SourceJavaHashOrder.keys(new_tiles):
            if not mountain_tiles.has(position):
                tiles_to_add[position] = new_tiles[position]
        _qa_surface_stage("savanna")
        place_number -= 1
        if place_number <= 0:
            break
    place_number = random.next_int(2) + 2
    tries = 20
    while not deep_forest_tiles.is_empty():
        var patch_origin := deep_forest_tiles[random.next_int(deep_forest_tiles.size())]
        if OS.get_environment("POKEWILDS_QA_SURFACE_STAGES") == "1":
            print("SOURCE_GRAVEYARD_CHOICE position=%s biome=%s mountain=%d draws=%d" % [
                str(patch_origin.position), patch_origin.biome,
                int(mountain_tiles.has(patch_origin.position)),
                random.trace_count()
            ])
        if patch_origin.biome == "graveyard" or mountain_tiles.has(patch_origin.position):
            tries -= 1
            if tries > 0:
                continue
            break
        var new_tiles: Dictionary = {}
        apply_blotch("graveyard1", patch_origin, 300, new_tiles, 0, false, SourceRoute.new("graveyard1", 22))
        for position in SourceJavaHashOrder.keys(new_tiles):
            if not mountain_tiles.has(position):
                tiles_to_add[position] = new_tiles[position]
        _qa_surface_stage("graveyard")
        place_number -= 1
        if place_number <= 0:
            break
    if not keystone_spawns.is_empty():
        var position := keystone_spawns[random.next_int(keystone_spawns.size())]
        var old_tile := tiles_to_add.get(position) as SourceTile
        var keystone := SourceTile.new("green12", position, "odd_keystone2", true, old_tile.route_belongs_to if old_tile != null else null)
        keystone.biome = "graveyard"
        tiles_to_add[position] = keystone
    _apply_source_rivers(desert_tiles)
    _qa_surface_stage("rivers")
    _fill_source_ocean(minimum_position, maximum_position)
    _qa_surface_stage("ocean")
    ledgify(tiles_to_add, tiles_to_add, "mountain4", "sand4", "beach")
    _qa_surface_stage("before_stalagmites")
    for raw_tile in SourceJavaHashOrder.values(tiles_to_add):
        if raw_tile is int:
            continue
        var tile := raw_tile as SourceTile
        if tile.name_upper != "stalagmite1":
            continue
        tile.set_names("stalagmite1")
        if random.next_int(10) == 0:
            tile.set_names(tile.name, "tree6")
        elif random.next_int(10) == 0:
            tile.set_names(tile.name, "rock1")
        elif random.next_int(10) == 0:
            tile.set_names(tile.name, "rock1_color")
    ledgify(tiles_to_add, tiles_to_add, "stalagmite1", "mountain4", "beach")
    for tile in desert_tiles:
        pokemon_to_add.erase(tile.position)
    # Later river/ledge/coast passes can touch graveyard perimeter cells.
    # Reassert the authored side/corner fence variants only after those passes.
    for fence_rect in graveyard_fence_bounds:
        var fence_bottom_left = fence_rect.position
        var fence_top_right = fence_rect.position + fence_rect.size
        _style_graveyard_fence_group(tiles_to_add, fence_bottom_left, fence_top_right)
    _qa_surface_stage("surface_done")
    return {
        "tiles": tiles_to_add,
        "mountains": mountain_tiles,
        "pokemon": pokemon_to_add,
        "desert_tiles": desert_tiles,
        "deep_forest_tiles": deep_forest_tiles,
        "forest_tiles": forest_tiles,
        "bottom_left": bottom_left,
        "top_right": top_right,
        "endpoints": endpoints
    }

func _qa_surface_stage(stage_name: String) -> void:
    if OS.get_environment("POKEWILDS_QA_SURFACE_STAGES") != "1":
        return
    print("SOURCE_SURFACE_STAGE name=%s tiles=%d pokemon=%d draws=%d sha256=%s" % [
        stage_name, tiles_to_add.size(), pokemon_to_add.size(),
        random.trace_count(), qa_surface_sha256()
    ])
    var dump_draw_matches := (
        OS.get_environment("POKEWILDS_QA_SURFACE_DUMP_DRAW").is_empty()
        or (OS.get_environment("POKEWILDS_QA_SURFACE_DUMP_DRAW").is_valid_int()
            and random.trace_count() == int(OS.get_environment(
                "POKEWILDS_QA_SURFACE_DUMP_DRAW")))
    )
    if (OS.get_environment("POKEWILDS_QA_SURFACE_DUMP_STAGE") == stage_name
            and dump_draw_matches
            and not OS.get_environment("POKEWILDS_QA_SURFACE_DUMP").is_empty()):
        _qa_dump_surface(OS.get_environment("POKEWILDS_QA_SURFACE_DUMP"))

func _qa_dump_surface(path: String) -> void:
    var positions := tiles_to_add.keys()
    positions.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
        return a.x < b.x or (a.x == b.x and a.y < b.y)
    )
    var file := FileAccess.open(path, FileAccess.WRITE)
    for raw_position in positions:
        var position: Vector2i = raw_position
        var tile := peek_tile(position)
        var route_name := ""
        var route_level := 0
        if tile.route_belongs_to != null:
            route_name = tile.route_belongs_to.name
            route_level = tile.route_belongs_to.level
        file.store_line("%d\t%d\t%s\t%s\t%s\t%d\t%s\t%d\t%d\t%d" % [
            position.x, position.y, tile.name, tile.name_upper, route_name,
            route_level, tile.biome, int(tile.is_solid), int(tile.is_water),
            int(tile.is_ledge)
        ])

func qa_surface_sha256() -> String:
    var positions := tiles_to_add.keys()
    positions.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
        return a.x < b.x or (a.x == b.x and a.y < b.y)
    )
    var context := HashingContext.new()
    context.start(HashingContext.HASH_SHA256)
    for raw_position in positions:
        var position: Vector2i = raw_position
        var tile := peek_tile(position)
        var route_name := ""
        var route_level := 0
        if tile.route_belongs_to != null:
            route_name = tile.route_belongs_to.name
            route_level = tile.route_belongs_to.level
        context.update(("%d,%d|%s|%s|%s|%d|%s|%d|%d|%d\n" % [
            position.x, position.y, tile.name, tile.name_upper, route_name,
            route_level, tile.biome, int(tile.is_solid), int(tile.is_water),
            int(tile.is_ledge)
        ]).to_utf8_buffer())
    return context.finish().hex_encode()

# Complete source-order GenIsland1 generation entry point. The list of already
# used dungeons is world-save state in 0.8.11 and must be carried between maps.
func generate_complete(used_dungeons: Array[String] = []) -> Dictionary:
    validation_records.clear()
    graveyard_fence_bounds.clear()
    interior_pokemon.clear()
    interior_tiles_to_add.clear()
    interior_tiles_to_add.resize(102)
    already_used_dungeons = used_dungeons.duplicate()
    var surface := generate_surface()
    if OS.get_environment("POKEWILDS_QA_TRACE_AFTER_SURFACE") == "1":
        random.enable_trace(int(OS.get_environment(
            "POKEWILDS_QA_TRACE_AFTER_SURFACE_LIMIT")) if not OS.get_environment(
            "POKEWILDS_QA_TRACE_AFTER_SURFACE_LIMIT").is_empty() else 400)
    var desert_tiles := surface["desert_tiles"] as Array
    var deep_forest_tiles := surface["deep_forest_tiles"] as Array
    # Nothing else in it is read below; these lists keep tiles alive that were
    # replaced since (forest_tiles), and desert_tiles is done with after the
    # landmarks.
    surface.clear()
    _restore_source_landmark_flags()
    # The source suppresses Regi placement on a first island containing the
    # mansion/mines. Preserve that RNG sequence, then add the user's requested
    # per-world Regi cave after the source world has finished. Drawing the Regi
    # placement RNG before mines/oasis changed every subsequent interior.
    done_regi_dungeon = true
    var landmark_plan := _place_source_landmarks(desert_tiles, deep_forest_tiles)
    desert_tiles = []
    _cleanup_and_place_deep_forest_landmarks(
        deep_forest_tiles,
        landmark_plan["hitboxes"] as Array,
        landmark_plan["mansion_box"] as Rect2i)
    _postprocess_source_shores()
    _postprocess_source_puddles()
    _spawn_source_overworld_pokemon()
    _add_required_regi_after_source_world(deep_forest_tiles)
    _complete_missing_landmarks()
    var burrowed_pokemon: Array[Dictionary] = []
    for position in trapinch_spawns:
        var trap_tile := tile_at(position)
        if trap_tile == null or trap_tile.name != "desert2":
            continue
        trap_tile.items["trapinch"] = 1
        burrowed_pokemon.append({
            "name": "trapinch",
            "level": 22,
            "position": position,
            "generation": "CRYSTAL",
            "is_trapping": true
        })
    return {
        "tiles": tiles_to_add,
        "mountains": mountain_tiles,
        "pokemon": pokemon_to_add,
        "burrowed_pokemon": burrowed_pokemon,
        "interior_pokemon": interior_pokemon,
        "interiors": interior_tiles_to_add,
        "edges": edges,
        "ocean_tiles": ocean_tiles,
        "bottom_left": bottom_left,
        "top_right": top_right,
        "already_used_dungeons": already_used_dungeons,
        "landmark_origins": landmark_plan["origins"]
    }

func _add_required_regi_after_source_world(candidates: Array) -> void:
    for raw_candidate in candidates:
        var candidate := raw_candidate as SourceTile
        if candidate == null or candidate.biome != "deep_forest": continue
        var mountain_overlap := false
        for offset in [Vector2i(0,-368),Vector2i(-224,0),Vector2i(144,-240),
                Vector2i(32,32),Vector2i(-32,32),Vector2i(32,-32),Vector2i(-32,-32)]:
            if mountain_tiles.has(candidate.position + offset):
                mountain_overlap = true
                break
        if mountain_overlap: continue
        var bounds := _centered_rect(candidate.position,Vector2i(208,160))
        var structure_overlap := false
        # The centered 208px box starts at x-104, eight pixels off-grid.
        # Query exactly the non-null source layout cells the cave will replace.
        for position in _regi_exterior_positions(candidate.position):
            var tile := peek_tile(position)
            if tile != null and ("pkmnmansion" in tile.name or "pkmnmansion" in tile.name_upper or "building" in tile.name or "building" in tile.name_upper or "ruins" in tile.name or tile.name_upper == "pokemon_mansion_key"):
                structure_overlap = true
                break
        if structure_overlap: continue
        generate_regi_dungeon(candidate.position)
        for position in pokemon_to_add.keys():
            if bounds.has_point(position):
                var tile := peek_tile(position)
                if tile != null and (tile.is_solid or "door" in tile.name): pokemon_to_add.erase(position)
        if not already_used_dungeons.has("regi1"): already_used_dungeons.append("regi1")
        return

# A failed deep-forest search must not silently omit required dungeons.
# This runs after source generation, so successful worlds retain their RNG/order.
func _complete_missing_landmarks() -> void:
    if not done_pkmn_mansion:
        var site := _required_landmark_site(true)
        if site.is_empty():
            push_error("No safe mansion site exists in generated terrain")
            return
        var at: Vector2i = site.position
        _prepare_landmark_clearing(site.bounds)
        generate_mansion(at)
        done_pkmn_mansion = true
        if not done_pkmn_mansion_key:
            var key_position := at + Vector2i(-16,-352)
            tiles_to_add[key_position] = SourceTile.new("green1",key_position,"pokemon_mansion_key",true)
            done_pkmn_mansion_key = true
        if not already_used_dungeons.has("mansion1"): already_used_dungeons.append("mansion1")
    if interior_tiles_to_add[90] == null or (interior_tiles_to_add[90] as Dictionary).is_empty():
        var site := _required_landmark_site(false)
        if site.is_empty():
            push_error("No safe Regi site exists in generated terrain")
            return
        var at: Vector2i = site.position
        _prepare_landmark_clearing(site.bounds)
        generate_regi_dungeon(at)
        done_regi_dungeon = true
        if not already_used_dungeons.has("regi1"): already_used_dungeons.append("regi1")

func _required_landmark_site(mansion: bool) -> Dictionary:
    var protected: Dictionary = {}
    var candidates: Array[Vector2i] = []
    for pos in tiles_to_add:
        var tile := peek_tile(pos)
        var names := tile.name + " " + tile.name_upper
        if ("pkmnmansion" in names or "building" in names or "ruins" in names
                or "cave" in names or "pokemon_mansion_key" in names
                or "grave" in names or "fence" in names or "fossil" in names):
            protected[pos] = true
        if not tile.is_water and not tile.is_solid and not mountain_tiles.has(pos):
            candidates.append(pos)
    # Shared Java interior planes must not overwrite another dungeon's rooms.
    if mansion:
        for li in range(95, interior_tiles_to_add.size()):
            if interior_tiles_to_add[li] is Dictionary:
                for pos in interior_tiles_to_add[li]: protected[pos] = true
    candidates.sort_custom(func(a: Vector2i,b: Vector2i) -> bool:
        var ad := a.length_squared(); var bd := b.length_squared()
        return ad < bd if ad != bd else (a.y < b.y if a.y != b.y else a.x < b.x))
    var offset := Vector2i(-336,-384) if mansion else Vector2i(-128,-80)
    var extent := Vector2i(672,704) if mansion else Vector2i(272,192)
    # Prefer existing dry, mountain-free land. Only if none fits, prepare a
    # clearing on existing terrain; protected structures are never overwritten.
    for prepare_terrain in [false,true]:
        for at in candidates:
            var rect := Rect2i(at + offset, extent)
            var valid := true
            for y in range(rect.position.y,rect.end.y,16):
                for x in range(rect.position.x,rect.end.x,16):
                    var p := Vector2i(x,y)
                    var tile := peek_tile(p)
                    if protected.has(p) or tile == null:
                        valid = false; break
                    if not prepare_terrain and (mountain_tiles.has(p) or tile.is_water):
                        valid = false; break
                if not valid:break
            if valid and _clearing_has_land_access(rect):
                return {"position":at,"bounds":rect}
    return {}

func _clearing_has_land_access(rect: Rect2i) -> bool:
    for x in range(rect.position.x,rect.end.x,16):
        for y in [rect.position.y-16,rect.end.y]:
            var tile := peek_tile(Vector2i(x,y))
            if tile != null and not tile.is_solid and not tile.is_water and not tile.is_ledge:
                return true
    for y in range(rect.position.y,rect.end.y,16):
        for x in [rect.position.x-16,rect.end.x]:
            var tile := peek_tile(Vector2i(x,y))
            if tile != null and not tile.is_solid and not tile.is_water and not tile.is_ledge:
                return true
    return false

func _prepare_landmark_clearing(rect: Rect2i) -> void:
    var route := SourceRoute.new("forest1",40)
    for i in range(edges.size()-1,-1,-1):
        if rect.has_point(edges[i].position):edges.remove_at(i)
    for y in range(rect.position.y,rect.end.y,16):
        for x in range(rect.position.x,rect.end.x,16):
            var pos := Vector2i(x,y)
            tiles_to_add[pos] = SourceTile.new("green1",pos,"",true,route)
            mountain_tiles.erase(pos)
            pokemon_to_add.erase(pos)
            trapinch_spawns.erase(pos)
            keystone_spawns.erase(pos)

func _restore_source_landmark_flags() -> void:
    # Each generated map must contain the source dungeons requested for this port.
    # used_dungeons remains save metadata, but it no longer suppresses landmarks
    # on a newly generated map.
    done_pkmn_mansion = false
    done_pkmn_mansion_key = false
    done_desert_ruins = false
    done_regi_dungeon = false

func _place_source_landmarks(desert_tiles: Array, deep_forest_tiles: Array) -> Dictionary:
    var hitboxes: Array[Rect2i] = [
        Rect2i(0, 0, 1056, 1056),
        Rect2i(0, 0, 640, 640),
        Rect2i(0, 0, 208, 160)
    ]
    var origins: Array = [null, null, null]
    var mansion_position := Vector2i(0, 224)
    var mansion_box := _centered_rect(mansion_position, Vector2i(528, 496))
    var landmark_index := 0
    var tries := 0
    while landmark_index < hitboxes.size():
        if landmark_index == 0 and done_desert_ruins:
            landmark_index += 1
            continue
        if landmark_index == 2 and done_regi_dungeon:
            landmark_index += 1
            continue
        var candidates := desert_tiles if landmark_index < 2 and not desert_tiles.is_empty() else deep_forest_tiles
        if candidates.is_empty():
            # Source-size maps always have candidates. Returning the zero origin
            # is preferable to inventing a placement rule for malformed input.
            origins[landmark_index] = Vector2i.ZERO
            landmark_index += 1
            continue
        var chosen := candidates[random.next_int(candidates.size())] as SourceTile
        origins[landmark_index] = chosen.position
        if landmark_index == 0:
            var alignment_tries := 0
            while (alignment_tries < 80 and not desert_tiles.is_empty()
                    and (Vector2i(origins[landmark_index]).x % 32 != 0
                    or Vector2i(origins[landmark_index]).y % 32 != 16)):
                chosen = desert_tiles[random.next_int(desert_tiles.size())] as SourceTile
                origins[landmark_index] = chosen.position
                alignment_tries += 1
        hitboxes[landmark_index] = _centered_rect(
            Vector2i(origins[landmark_index]), hitboxes[landmark_index].size)
        if landmark_index == 0 and hitboxes[landmark_index].intersects(mansion_box):
            continue
        if landmark_index > 1 and _rect_contains_mountain(hitboxes[landmark_index]):
            continue
        var worked := true
        for previous_index in range(landmark_index):
            if hitboxes[landmark_index].intersects(hitboxes[previous_index]):
                worked = false
                break
        if worked or tries > 10:
            landmark_index += 1
            tries = 0
            continue
        tries += 1
    if not done_desert_ruins:
        generate_desert_ruins(Vector2i(origins[0]))
        already_used_dungeons.append("desert_ruins1")
        done_desert_ruins = true
    generate_oasis(Vector2i(origins[1]))
    return {"hitboxes": hitboxes, "origins": origins, "mansion_box": mansion_box}

func _centered_rect(center: Vector2i, size: Vector2i) -> Rect2i:
    return Rect2i(center - size / 2, size)

func _rect_contains_mountain(rectangle: Rect2i) -> bool:
    for raw_position in SourceJavaHashOrder.keys(mountain_tiles):
        if rectangle.has_point(Vector2i(raw_position)):
            return true
    return false

func _cleanup_and_place_deep_forest_landmarks(
        _deep_forest_tiles: Array,
        hitboxes: Array,
        initial_mansion_box: Rect2i
    ) -> void:
    var complete := false
    var mansion_box := initial_mansion_box
    var mansion_exterior: Dictionary = {}
    while not complete:
        complete = true
        var restart_pass := false
        for raw_tile in SourceJavaHashOrder.values(tiles_to_add):
            # Untouched ocean: no tree, rock, cactus, pokemon, door or forest.
            if raw_tile is int:
                continue
            var tile := raw_tile as SourceTile
            if "tree_large1" in tile.name:
                _repair_incomplete_large_tree(tile)
            elif tile.name == "rock1":
                _remove_blocking_rock(tile)
            elif tile.name_upper == "cactus10":
                var solid_position := tile.position + Vector2i(16, 0)
                tiles_to_add[solid_position] = SourceTile.new(
                    "desert4", solid_position, "solid", true, tile.route_belongs_to)
            if (pokemon_to_add.has(tile.position)
                    and ((tile.is_solid and "water" not in tile.name)
                    or "ledge" in tile.name or "door" in tile.name
                    or "door" in tile.name_upper)):
                pokemon_to_add.erase(tile.position)

            if (tile.biome == "deep_forest" and not done_pkmn_mansion
                    and not mountain_tiles.has(tile.position + Vector2i(0, -368))
                    and not mountain_tiles.has(tile.position + Vector2i(-224, 0))
                    and not mountain_tiles.has(tile.position + Vector2i(144, -240))):
                var mansion_position := tile.position
                if radius < 40000:
                    mansion_position = Vector2i(0, 224)
                mansion_box = _centered_rect(mansion_position, Vector2i(528, 496))
                if mansion_box.intersects(hitboxes[0]) or mansion_box.intersects(hitboxes[1]):
                    continue
                if not already_used_dungeons.has("mansion1"):
                    already_used_dungeons.append("mansion1")
                done_pkmn_mansion = true
                complete = false
                var mansion_result := generate_mansion(mansion_position)
                mansion_exterior = (mansion_result["exterior"] as Dictionary).duplicate()
                restart_pass = true
                break

            var down_position := tile.position + Vector2i(0, -16)
            var down_tile := peek_tile(down_position)
            if (tile.biome == "deep_forest" and "green" in tile.name
                    and not done_pkmn_mansion_key and down_tile != null
                    and "tree" not in down_tile.name_upper):
                done_pkmn_mansion_key = true
                complete = false
                tiles_to_add[tile.position] = SourceTile.new(
                    tile.name, tile.position, "pokemon_mansion_key", true)
                restart_pass = true
                break

            if (tile.biome != "deep_forest" or done_regi_dungeon
                    or mountain_tiles.has(tile.position + Vector2i(0, -368))
                    or mountain_tiles.has(tile.position + Vector2i(-224, 0))
                    or mountain_tiles.has(tile.position + Vector2i(144, -240))
                    or mountain_tiles.has(tile.position + Vector2i(32, 32))
                    or mountain_tiles.has(tile.position + Vector2i(-32, 32))
                    or mountain_tiles.has(tile.position + Vector2i(32, -32))
                    or mountain_tiles.has(tile.position + Vector2i(-32, -32))
                    or random.next_int(3) != 2):
                continue
            var regi_box := _centered_rect(tile.position, Vector2i(208, 160))
            var collides_with_mansion := false
            for raw_mansion_tile in SourceJavaHashOrder.values(mansion_exterior):
                if regi_box.has_point((raw_mansion_tile as SourceTile).position):
                    collides_with_mansion = true
                    break
            if collides_with_mansion:
                continue
            if not already_used_dungeons.has("regi1"):
                already_used_dungeons.append("regi1")
            done_regi_dungeon = true
            complete = false
            generate_regi_dungeon(tile.position)
            restart_pass = true
            break
        if restart_pass:
            continue
    # Required per-map source dungeons: if the normal scan did not find a legal
    # placement, retry deterministically over the same deep-forest candidates
    # and the same collision/mountain constraints.
    if not done_pkmn_mansion:
        for raw_candidate in _deep_forest_tiles:
            var mansion_candidate = raw_candidate as SourceTile
            if mansion_candidate == null or mansion_candidate.biome != "deep_forest":
                continue
            if (mountain_tiles.has(mansion_candidate.position + Vector2i(0, -368))
                    or mountain_tiles.has(mansion_candidate.position + Vector2i(-224, 0))
                    or mountain_tiles.has(mansion_candidate.position + Vector2i(144, -240))):
                continue
            var candidate_box = _centered_rect(mansion_candidate.position, Vector2i(528, 496))
            if candidate_box.intersects(hitboxes[0]) or candidate_box.intersects(hitboxes[1]):
                continue
            mansion_box = candidate_box
            if not already_used_dungeons.has("mansion1"):
                already_used_dungeons.append("mansion1")
            done_pkmn_mansion = true
            var forced_mansion = generate_mansion(mansion_candidate.position)
            mansion_exterior = (forced_mansion["exterior"] as Dictionary).duplicate()
            break
    if not done_regi_dungeon:
        for raw_candidate in _deep_forest_tiles:
            var candidate = raw_candidate as SourceTile
            if candidate == null or candidate.biome != "deep_forest":
                continue
            if (mountain_tiles.has(candidate.position + Vector2i(0, -368))
                    or mountain_tiles.has(candidate.position + Vector2i(-224, 0))
                    or mountain_tiles.has(candidate.position + Vector2i(144, -240))
                    or mountain_tiles.has(candidate.position + Vector2i(32, 32))
                    or mountain_tiles.has(candidate.position + Vector2i(-32, 32))
                    or mountain_tiles.has(candidate.position + Vector2i(32, -32))
                    or mountain_tiles.has(candidate.position + Vector2i(-32, -32))):
                continue
            var regi_box = _centered_rect(candidate.position, Vector2i(208, 160))
            var collides = false
            for raw_mansion_tile in SourceJavaHashOrder.values(mansion_exterior):
                if regi_box.has_point((raw_mansion_tile as SourceTile).position):
                    collides = true
                    break
            if collides:
                continue
            if not already_used_dungeons.has("regi1"):
                already_used_dungeons.append("regi1")
            done_regi_dungeon = true
            generate_regi_dungeon(candidate.position)
            break


func _repair_incomplete_large_tree(tile: SourceTile) -> void:
    var found := false
    for j in range(2):
        for k in range(2):
            var top_left := tile.position + Vector2i(-16 * j, 16 * k)
            var top_right_position := tile.position + Vector2i(-16 * j + 16, 16 * k)
            var bottom_left_position := tile.position + Vector2i(-16 * j, 16 * k - 16)
            var bottom_right_position := tile.position + Vector2i(-16 * j + 16, 16 * k - 16)
            var top_left_tile := peek_tile(top_left)
            var top_right_tile := peek_tile(top_right_position)
            var bottom_left_tile := peek_tile(bottom_left_position)
            var bottom_right_tile := peek_tile(bottom_right_position)
            if (top_left_tile != null and top_left_tile.name == "tree_large1_noSprite"
                    and top_right_tile != null and top_right_tile.name == "tree_large1_noSprite"
                    and bottom_left_tile != null and bottom_left_tile.name == "tree_large1"
                    and bottom_right_tile != null and bottom_right_tile.name == "tree_large1_noSprite"):
                found = true
                break
        if found:
            break
    if found:
        return
    if random.next_int(3) == 2:
        tile.route_belongs_to = SourceRoute.new("", 22)
        _append_stored(tile.route_belongs_to, [
            "pineco", "aipom", "kakuna", "metapod", "spinarak", "heracross",
            "ledyba", "hoothoot", "zubat", "pidgey", "spearow", "forretress", "applin"
        ], 20, 4)
    # The Java source changes these fields without init(); keep the existing
    # collision flags until the map is serialized/reloaded.
    # Every repairable tree_large1 originates in GenForest2's color=true
    # template path. Preserve that constructor state for the later coastify
    # Tile.init(), which converts bush1 to green1 + bush2_color.
    tile.color = true
    tile.name = "bush1"
    tile.name_upper = ""

func _remove_blocking_rock(tile: SourceTile) -> void:
    var left := _any_solid([
        tile.position + Vector2i(-16, 0), tile.position + Vector2i(-16, 16),
        tile.position + Vector2i(-16, -16)])
    var right := _any_solid([
        tile.position + Vector2i(16, 0), tile.position + Vector2i(16, 16),
        tile.position + Vector2i(16, -16)])
    var up := _any_solid([
        tile.position + Vector2i(0, 16), tile.position + Vector2i(-16, 16),
        tile.position + Vector2i(16, 16)])
    var down := _any_solid([
        tile.position + Vector2i(0, -16), tile.position + Vector2i(-16, -16),
        tile.position + Vector2i(16, -16)])
    if (left and right) or (up and down):
        tiles_to_add[tile.position] = SourceTile.new(
            "sand1", tile.position, "", true, tile.route_belongs_to)

func _any_solid(positions: Array) -> bool:
    for position in positions:
        var tile := peek_tile(position)
        if tile != null and tile.is_solid:
            return true
    return false

func _postprocess_source_shores() -> void:
    var mountain_water_tiles: Array[SourceTile] = []
    var positions: Array[Vector2i] = [
        Vector2i(-16, 0), Vector2i(16, 0), Vector2i(-16, -16),
        Vector2i(16, 16), Vector2i(16, -16), Vector2i(-16, 16),
        Vector2i(0, -16), Vector2i(0, 16)
    ]
    # Walks the map itself, not a values() snapshot: the snapshot (a copy of
    # the whole map, holding on to every tile replaced below) made this the
    # peak of generation. This loop only replaces cells, so a cell replaced
    # before its turn is seen as the snapshot had it: `replaced` keeps that.
    var replaced: Dictionary = {}
    for position: Vector2i in tiles_to_add:
        var raw_tile: Variant = replaced[position] if replaced.has(position) else tiles_to_add[position]
        # Untouched ocean: not lake water, and water2 is skipped below.
        if raw_tile is int or raw_tile == null:
            continue
        var tile := raw_tile as SourceTile
        if tile.route_belongs_to != null and tile.route_belongs_to.name == "wooded_lake_water1":
            for offset in positions:
                var next_tile := peek_tile(tile.position + offset)
                if (next_tile != null and next_tile.name == "water2"
                        and (next_tile.route_belongs_to == null
                        or next_tile.route_belongs_to.name != "wooded_lake_water1")):
                    tile.set_names("sand3_tidalwater", tile.name_upper)
            continue
        if (tile.name == "water2" or tile.name == "water2_edge1" or "mountain4" in tile.name
                or "ice" in tile.name or "waterfall" in tile.name):
            continue
        for offset in positions:
            var next_tile := peek_tile(tile.position + offset)
            if next_tile == null or next_tile.name != "water2":
                continue
            # An ocean cell's template has no position of its own.
            var next_position := next_tile.position
            if tiles_to_add.get(tile.position + offset) is int:
                next_position = tile.position + offset
            if no_ice_here.has(tile.position) and "ledges3" in tile.name_upper:
                tile.set_names("sand3", tile.name_upper)
                if tile.position.x == next_position.x or tile.position.y == next_position.y:
                    mountain_water_tiles.append(tile)
                    break
                continue
            var shore_name := "sand3"
            if "desert" in tile.name:
                shore_name = "sand3_desertEdge"
            elif "_tidal" in tile.name:
                shore_name = "sand3_tidalwater"
            elif tile.biome == "beach_blacksand":
                shore_name = "sand3_black"
            var new_tile := SourceTile.new(
                shore_name, next_position, "", true, tile.route_belongs_to)
            if not replaced.has(new_tile.position):
                # What its turn sees. Only lake water does something there:
                # ocean (an int) and other water2 are skipped. null: a new key,
                # which the snapshot did not have.
                var old: Variant = tiles_to_add.get(new_tile.position)
                var lake: bool = (old is SourceTile and (old as SourceTile).route_belongs_to != null
                    and (old as SourceTile).route_belongs_to.name == "wooded_lake_water1")
                replaced[new_tile.position] = old if lake or old == null else 0
            tiles_to_add[new_tile.position] = new_tile
            var excluded := (
                "beach" in tile.biome or "mountain" in tile.biome
                or "savanna" in tile.biome or "wooded_lake" in tile.biome
                or "desert" in tile.name
                or (tile.route_belongs_to != null
                    and tile.route_belongs_to.name in ["oasis1", "ruins1_outer"])
                or (next_tile.route_belongs_to != null
                    and next_tile.route_belongs_to.name == "wooded_lake_water1"))
            if not excluded:
                edges.append(new_tile)

    for start_tile in mountain_water_tiles:
        var water_positions: Array[Vector2i] = [start_tile.position]
        var new_water_tiles: Array[SourceTile] = []
        while not water_positions.is_empty():
            var position: Vector2i = water_positions.pop_front()
            var next_tile := tile_at(position)
            new_water_tiles.append(next_tile)
            if new_water_tiles.size() > 25:
                new_water_tiles.clear()
                break
            if next_tile != null and "ledge" in next_tile.name_upper:
                if "N" in next_tile.name_upper:
                    water_positions.append(position + Vector2i(0, -16))
                if "S" in next_tile.name_upper:
                    water_positions.append(position + Vector2i(0, 16))
                if "E" in next_tile.name_upper:
                    water_positions.append(position + Vector2i(-16, 0))
                if "W" in next_tile.name_upper:
                    water_positions.append(position + Vector2i(16, 0))
                continue
            if next_tile != null and "water" in next_tile.name:
                break
            new_water_tiles.clear()
            break
        if new_water_tiles.size() > 2:
            var previous_name := ""
            for waterfall_tile in new_water_tiles:
                if "ledges3" in waterfall_tile.name_upper:
                    waterfall_tile.set_names("water2", waterfall_tile.name_upper)
                    _waterfallify(waterfall_tile)
                    previous_name = waterfall_tile.name
                else:
                    waterfall_tile.set_names("sand3", previous_name)

    # coastify changes tiles, never the map: no snapshot needed.
    for position: Vector2i in tiles_to_add:
        var raw_tile: Variant = tiles_to_add[position]
        # Untouched ocean is water: coastify leaves it as it is.
        if not raw_tile is int:
            _coastify(raw_tile as SourceTile)

func _waterfallify(tile: SourceTile) -> void:
    if (("water" in tile.name or "lava" in tile.name)
            and "ledges" in tile.name_upper):
        var tokens := tile.name_upper.split("_", true, 1)
        if tokens.size() < 2:
            return
        var name := "lavafall" if "lava" in tile.name else "waterfall1"
        tile.set_names(name + "_" + String(tokens[1]), tile.name_upper)

const COAST_DIRECTIONS: Array[String] = ["W", "E", "S", "N", "SW", "NE", "SE", "NW"]
const COAST_OFFSETS: Array[Vector2i] = [
    Vector2i(-16, 0), Vector2i(16, 0), Vector2i(0, -16), Vector2i(0, 16),
    Vector2i(-16, -16), Vector2i(16, 16), Vector2i(16, -16), Vector2i(-16, 16)
]

func _coastify(tile: SourceTile) -> bool:
    tile.shore_ocean = ""
    tile.shore_tidal = ""
    if (tile.is_water or "ledges" in tile.name_upper or tile.name == "ice2"
            or "bridge" in tile.name or "waterfall" in tile.name):
        return false
    var ocean_direction := ""
    var tidal_direction := ""
    for index in 8:
        var next_tile := peek_tile(tile.position + COAST_OFFSETS[index])
        if next_tile == null or next_tile.name == "water6":
            continue
        var direction: String = COAST_DIRECTIONS[index]
        if not tile.is_tidal and next_tile.is_tidal:
            if not _diagonal_direction_already_present(tidal_direction, direction):
                tidal_direction += "[" + direction + "]"
            continue
        if not next_tile.is_water:
            continue
        if _diagonal_direction_already_present(ocean_direction, direction):
            continue
        ocean_direction += "[" + direction + "]"
        tidal_direction += "[" + direction + "]"
    tile.shore_ocean = ocean_direction
    tile.shore_tidal = tidal_direction
    # PkmnMap.coastify finishes by calling Tile.init() even when no shore was
    # found. This is observable for tiles whose names were mutated directly
    # during the cleanup pass (notably incomplete tree_large1 -> bush1).
    tile.set_names(tile.name, tile.name_upper)
    return not ocean_direction.is_empty() or not tidal_direction.is_empty()

func _diagonal_direction_already_present(existing: String, direction: String) -> bool:
    if direction.length() < 2:
        return false
    for index in range(direction.length()):
        if ("[" + direction.substr(index, 1) + "]") in existing:
            return true
    return false

func _postprocess_source_puddles() -> void:
    var directions := ["W", "E", "S", "N"]
    var positions: Array[Vector2i] = [
        Vector2i(-16, 0), Vector2i(16, 0), Vector2i(0, -16), Vector2i(0, 16)
    ]
    var puddles: Array[SourceTile] = []
    for position: Vector2i in tiles_to_add:
        var raw_tile: Variant = tiles_to_add[position]
        if raw_tile is int:
            continue
        var tile := raw_tile as SourceTile
        if "_puddle1" in tile.name:
            puddles.append(tile)
    for tile in puddles:
        var direction := ""
        for index in range(positions.size()):
            var next_tile := peek_tile(tile.position + positions[index])
            if next_tile != null and "_puddle1" in next_tile.name:
                direction += "[" + String(directions[index]) + "]"
        tile.set_names(tile.name.replace("_puddle1", "_puddle1" + direction), tile.name_upper)

func _spawn_source_overworld_pokemon() -> void:
    var spawn_order_path := OS.get_environment("POKEWILDS_QA_SPAWN_ORDER")
    if not spawn_order_path.is_empty():
        var order_file := FileAccess.open(spawn_order_path, FileAccess.WRITE)
        for order_position in SourceJavaHashOrder.keys(tiles_to_add):
            var order_tile := tile_at(order_position)
            order_file.store_line("%d\t%d\t%s\t%s\t%s" % [
                order_tile.position.x, order_tile.position.y,
                order_tile.route_belongs_to.name if order_tile.route_belongs_to != null else "",
                order_tile.name, order_tile.name_upper
            ])
        order_file.close()
    # Ocean cells take part (ocean1 spawns): read through their template, at
    # their key. Nothing here changes a tile or the map, so the map is walked
    # as it is (copies of its keys and values made this the generation peak).
    for key: Vector2i in tiles_to_add:
        var raw_tile: Variant = tiles_to_add[key]
        var tile: SourceTile
        var tile_position: Vector2i
        if raw_tile is int:
            tile = ocean_tiles[raw_tile]
            tile_position = key
        else:
            tile = raw_tile as SourceTile
            tile_position = tile.position
        var route := tile.route_belongs_to
        if ((tile.is_solid and "water" not in tile.name) or tile.name_upper != ""
                or route == null or route.name == "" or route.allowed_pokemon().is_empty()
                or route.dont_spawn_overworlds
                or ("water" in tile.name
                    and "beach2" not in route.name
                    and route.name not in [
                        "ocean1", "mountain1_water1", "wooded_lake_water1"])):
            continue
        var allowed := route.allowed_pokemon()
        if route.name == "desert1":
            if random.next_int(512) < 511:
                continue
            var desert_name := String(allowed[random.next_int(allowed.size())]).to_lower()
            var desert_level := route.level + global_random.next_int(3)
            if desert_name in ["numel", "kangaskhan", "cubone"]:
                desert_level = 10
            _spawn(tile_position, desert_name, desert_level, {
                "generation": "CRYSTAL",
                "aggressive": desert_name == "drapion"
            })
            continue

        var base_chance := _source_spawn_base_chance(route.name)
        var spawn_roll := random.next_int(512)
        if (OS.get_environment("POKEWILDS_QA_TRACE_SPAWN") == "1"
                and random.trace_count() >= 58265
                and random.trace_count() <= 58280):
            print("SOURCE_SPAWN_TRACE draw=%d pos=%s route=%s roll=%d allowed=%s" % [
                random.trace_count(), tile_position, route.name, spawn_roll,
                JSON.stringify(allowed)
            ])
        if spawn_roll < base_chance:
            continue
        var pokemon_name := String(allowed[random.next_int(allowed.size())]).to_lower()
        var pokemon_level := route.level + global_random.next_int(3)
        var evolved := _source_random_evolutions(pokemon_name, pokemon_level)
        pokemon_name = String(evolved["name"])
        pokemon_level = int(evolved["level"])
        if _source_is_base_species(pokemon_name):
            if pokemon_level > 10:
                pokemon_level = 10
        elif pokemon_name in [
                "bellossom", "gardevoir", "jumpluff", "marill",
                "chansey", "blissey", "pikachu"] and pokemon_level > 30:
            pokemon_level = 30
        if not _source_spawn_requirements_met(tile, pokemon_name):
            continue
        var extra := {"generation": "CRYSTAL"}
        if pokemon_name in ["froslass", "sharpedo", "primeape"]:
            extra["aggressive"] = true
        if pokemon_name == "froslass":
            extra["gender"] = "female"
        elif pokemon_name == "gallade":
            extra["gender"] = "male"
        _spawn(tile_position, pokemon_name, pokemon_level, extra)

func _source_spawn_base_chance(route_name: String) -> int:
    if "oasis" in route_name:
        return 460
    if "ruins" in route_name:
        return 480
    if route_name == "beach2_water":
        return 506
    if route_name in ["beach2_rocks", "beach2_plateau"]:
        return 500
    if route_name == "beach2":
        return 509
    if "beach" in route_name:
        return 480
    if "graveyard" in route_name:
        return 506
    if route_name == "savanna2":
        return 509
    if route_name == "mountain1_water1":
        return 506
    if route_name == "volcano1":
        return 508
    if route_name == "ocean1":
        return 511
    if route_name == "wooded_lake1":
        return 509
    return 509

func _source_random_evolutions(start_name: String, start_level: int) -> Dictionary:
    var pokemon_name := start_name
    var times_evolved := 0
    while true:
        var selected := ""
        var evolutions := _source_evolutions(pokemon_name)
        for raw_evolution in _source_java_evolution_order(evolutions):
            var evolution := raw_evolution as Dictionary
            var parameter := String(evolution.get("parameter", ""))
            if parameter.is_valid_int():
                if (int(parameter) <= start_level + 10 * (times_evolved + 1)
                        and global_random.next_int(256) >= 128):
                    selected = String(evolution.get("species", pokemon_name)).to_lower()
                    break
            elif global_random.next_int(256) >= 192:
                selected = String(evolution.get("species", pokemon_name)).to_lower()
                break
        if selected.is_empty():
            break
        pokemon_name = selected
        if OS.get_environment("POKEWILDS_QA_TRACE_POKEMON") == "1":
            _qa_pokemon_sequence += 1
            print("SOURCE_POKEMON_EVENT=%d:evolve:%s:%d" % [
                _qa_pokemon_sequence, pokemon_name, start_level
            ])
        times_evolved += 1
    return {"name": pokemon_name, "level": start_level + 10 * times_evolved}

func _source_is_base_species(pokemon_name: String) -> bool:
    var normalized := pokemon_name.to_lower()
    if SOURCE_BASE_SPECIES_OVERRIDES.has(normalized):
        return String(SOURCE_BASE_SPECIES_OVERRIDES[normalized]) == normalized
    var forms: Array = _source_species_info(normalized).get("base_forms", [])
    if forms.is_empty():
        return true
    var first = forms[0]
    if typeof(first) == TYPE_DICTIONARY:
        return String((first as Dictionary).get("species", pokemon_name)).to_lower() == pokemon_name
    return String(first).to_lower() == pokemon_name

func _source_has_evolution(pokemon_name: String) -> bool:
    return not _source_evolutions(pokemon_name).is_empty()

func _source_species_info(pokemon_name: String) -> Dictionary:
    var normalized := pokemon_name.to_lower()
    return PokemonData.info(String(SOURCE_SPECIES_ALIASES.get(normalized, normalized)))

func _source_evolutions(pokemon_name: String) -> Array:
    var normalized := pokemon_name.to_lower()
    # Original Specie.java assigns Combee's map to the female form and leaves
    # the ordinary Combee map empty.
    if normalized == "combee":
        return []
    return _source_species_info(normalized).get("evolutions", []) as Array

func _source_java_evolution_order(evolutions: Array) -> Array:
    # Specie.gen2Evos uses java.util.HashMap. For String keys its iteration is
    # deterministic bucket order (unlike coordinate maps whose tree-bin order
    # needed normalization). Reproduce that order before consuming Game.rand.
    var capacity := 16
    while evolutions.size() > int(float(capacity) * 0.75):
        capacity *= 2
    var decorated: Array[Dictionary] = []
    for index in range(evolutions.size()):
        var evolution := evolutions[index] as Dictionary
        var parameter := String(evolution.get("parameter", ""))
        var key := parameter if parameter.is_valid_int() else parameter.to_lower().replace("_", " ")
        decorated.append({
            "bucket": SourceJavaHashOrder._spread_hash(
                SourceJavaHashOrder._java_hash(key)) & (capacity - 1),
            "index": index,
            "evolution": evolution
        })
    decorated.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
        return (int(a["bucket"]) < int(b["bucket"])
            or (int(a["bucket"]) == int(b["bucket"])
                and int(a["index"]) < int(b["index"])))
    )
    var ordered: Array = []
    for entry in decorated:
        ordered.append((entry as Dictionary)["evolution"])
    return ordered

func _source_spawn_requirements_met(tile: SourceTile, pokemon_name: String) -> bool:
    var route_name := tile.route_belongs_to.name
    var has_evolution := _source_has_evolution(pokemon_name)
    var requirements_met := not has_evolution
    if "beach" in route_name:
        requirements_met = has_evolution
    if "ruins" in route_name or "graveyard" in route_name:
        requirements_met = true
    if route_name in ["beach2", "beach2_rocks", "beach2_plateau", "savanna2", "volcano1", "wooded_lake1"]:
        requirements_met = true
    if route_name == "beach2_water":
        requirements_met = tile.is_water
    if route_name == "mountain1_water1":
        requirements_met = tile.is_water
    # In GenIsland1 this final `else if` is attached only to the wooded-lake
    # water check.  Mountain-water candidates are therefore checked once more
    # by the mountain evolution rule; combining the water routes into one
    # branch incorrectly admitted evolving Goldeen/Poliwag candidates.
    if route_name == "wooded_lake_water1":
        requirements_met = tile.is_water
    elif "mountain" in route_name:
        requirements_met = (not has_evolution
            or pokemon_name in ["machoke", "rhydon", "onix"])
    if "snow" in route_name:
        requirements_met = (not has_evolution
            or pokemon_name in ["sneasel", "piloswine"])
    return requirements_met

func _apply_source_rivers(desert_tiles: Array[SourceTile]) -> void:
    # Match the original object-identity test without rescanning every desert
    # tile for each world tile. Do not key this by position: tiles are replaced.
    var desert_members: Dictionary = {}
    for desert_tile in desert_tiles:
        desert_members[desert_tile] = true
    var river_route := SourceRoute.new("wooded_lake_water1", 30)
    for raw_tile in SourceJavaHashOrder.values(tiles_to_add):
        var tile := raw_tile as SourceTile
        if tile.is_tidal:
            continue
        var tile_route := river_route
        var tile_name := "water2"
        var scale := 60.0
        var threshold := 850.0
        if desert_members.has(tile):
            tile_name = "sand1"
            tile_route = tile.route_belongs_to
            threshold = 1250.0
        if mountain_tiles.has(tile.position):
            if no_ice_here.has(tile.position):
                continue
            if tile.biome == "tundra":
                tile_name = "ice2"
                tile_route = tile.route_belongs_to
            if bottom_mountain_layer.has(tile.position):
                tile_name = "sand3_tidalwater"
                if tile.biome == "desert":
                    continue
            scale = 59.0
        var ratio := (
            (-INF if tile.position.x < 0 else INF)
            if tile.position.y == 0
            else SourceLibGDXMath.float32(
                float(tile.position.x) / float(tile.position.y))
        )
        if (_source_river_product(tile.position, scale, ratio) > threshold
                and tile_name != "waterfall1"):
            tile.route_belongs_to = tile_route
            tile.set_names(tile_name)
            pokemon_to_add.erase(tile.position)

func _fill_source_ocean(minimum_position: Vector2i, maximum_position: Vector2i) -> void:
    var boundary_min := minimum_position - Vector2i(672, 672)
    var boundary_max := Vector2i(maximum_position.x + 672, maximum_position.y + 336)
    var fill_maximum := maximum_position + Vector2i(896, 448)
    var fill_minimum := minimum_position - Vector2i(896, 896)
    var ocean_route := SourceRoute.new("ocean1", 40)
    ocean_tiles.clear()
    for kind in 4:
        ocean_tiles.append(SourceTile.new("water2_edge1" if kind & 1 else "water2", Vector2i.ZERO,
            "", true, ocean_route if kind & 2 else null))
    for x in range(fill_minimum.x, fill_maximum.x + 1, 16):
        for y in range(fill_minimum.y, fill_maximum.y + 1, 16):
            var position := Vector2i(x, y)
            if tiles_to_add.has(position):
                continue
            var kind := 1 if y == fill_maximum.y else 0
            if not (position.x >= boundary_min.x and position.x <= boundary_max.x and position.y >= boundary_min.y and position.y <= boundary_max.y):
                kind |= 2
            tiles_to_add[position] = kind
    bottom_left = fill_minimum
    top_right = fill_maximum

func generate_oasis(oasis_origin: Vector2i) -> void:
    var oasis_route := SourceRoute.new("oasis1", 30)
    var origin_tile := tile_at(oasis_origin)
    assert(origin_tile != null)
    origin_tile.biome = "desert"
    var next_size := 250 + random.next_int(50)
    var new_tiles: Dictionary = {}
    apply_blotch("oasis1", origin_tile, next_size, new_tiles, 0, true, oasis_route)
    var pond_tiles: Dictionary = {}
    next_size = int(next_size / 2)
    apply_blotch("pond1", origin_tile, next_size, pond_tiles, 0, true, oasis_route)
    _spawn(origin_tile.position, "milotic", 44)
    new_tiles.merge(pond_tiles, true)
    for raw_tile in SourceJavaHashOrder.values(new_tiles):
        var tile := raw_tile as SourceTile
        if tile.name_upper == "aloe_large1":
            for offset in [Vector2i(16, 0), Vector2i(0, 16), Vector2i(16, 16)]:
                new_tiles[tile.position + offset] = SourceTile.new("green1", tile.position + offset, "solid", true, tile.route_belongs_to)
    var oasis_tiles: Array[SourceTile] = []
    for raw_tile in SourceJavaHashOrder.values(new_tiles):
        var tile := raw_tile as SourceTile
        if mountain_tiles.has(tile.position):
            continue
        if "water" not in tile.name:
            oasis_tiles.append(tile)
        tiles_to_add[tile.position] = tile
    if oasis_tiles.is_empty():
        return
    var building_origin: SourceTile = oasis_tiles.pop_at(
        random.next_int(oasis_tiles.size())
    )
    var lab_layer: Dictionary = {}
    var lab_route := SourceRoute.new("fossil_lab1", 11)
    var rows := SourceLayoutData.rows("GenIsland1", "generateOasis", 0)
    for row_index in range(rows.size()):
        var row: Array = rows[row_index]
        for column in range(row.size()):
            if row[column] == null:
                continue
            var position: Vector2i = building_origin.position + Vector2i(
                -96 + column * 16, 80 - row_index * 16
            )
            lab_layer[position] = SourceTile.new(String(row[column]), position, "", true, lab_route)
    _merge_interior_layer(100, lab_layer)
    var exterior: Dictionary = {}
    rows = SourceLayoutData.rows("GenIsland1", "generateOasis", 1)
    for row_index in range(rows.size()):
        var row: Array = rows[row_index]
        for column in range(row.size()):
            if row[column] == null:
                continue
            var position: Vector2i = building_origin.position + Vector2i(
                -96 + column * 16, 80 - row_index * 16
            )
            exterior[position] = SourceTile.new("sand1", position, String(row[column]), true, building_origin.route_belongs_to)
    _merge_exterior_preserving_mansion_key(exterior)

    validation_records.append(GenerationValidator.capture("fossil_lab", building_origin.position, exterior, {100:lab_layer}))

func _regi_exterior_positions(dungeon_origin: Vector2i) -> Array[Vector2i]:
    var positions: Array[Vector2i] = []
    var rows := SourceLayoutData.rows("GenIsland1", "generateRegiDungeon", 0)
    for row_index in range(rows.size()):
        var row: Array = rows[row_index]
        for column in range(row.size()):
            if row[column] != null:
                positions.append(dungeon_origin + Vector2i(-96 + column * 16, 80 - row_index * 16))
    return positions

func generate_regi_dungeon(dungeon_origin: Vector2i) -> void:
    var exterior: Dictionary = {}
    var route := SourceRoute.new("", 2)
    var rows := SourceLayoutData.rows("GenIsland1", "generateRegiDungeon", 0)
    for row_index in range(rows.size()):
        var row: Array = rows[row_index]
        for column in range(row.size()):
            if row[column] == null:
                continue
            var position := dungeon_origin + Vector2i(-96 + column * 16, 80 - row_index * 16)
            exterior[position] = SourceTile.new(String(row[column]), position, "", true, route)
    var interior_origin := dungeon_origin + Vector2i(-288, 272)
    var interior: Dictionary = {}
    var interior_route := SourceRoute.new("regi_cave1", 44)
    rows = SourceLayoutData.rows("GenIsland1", "generateRegiDungeon", 1)
    for row_index in range(rows.size()):
        var row: Array = rows[row_index]
        for column in range(row.size()):
            if row[column] == null:
                continue
            var position := interior_origin + Vector2i(column * 16, -row_index * 16)
            var tile := SourceTile.new(String(row[column]), position, "", true, interior_route)
            if String(row[column]) == "cave1_regipedistal1":
                tile.items = {
                    "REGISTEEL": 1, "REGICE": 1, "REGIROCK": 1,
                    "REGIELEKI": 1, "REGIDRAGO": 1
                }
            interior[position] = tile
    _merge_exterior_preserving_mansion_key(exterior)
    _merge_interior_layer(90, interior)
    validation_records.append(GenerationValidator.capture("regi", dungeon_origin, exterior, {90:interior}))

func generate_desert_ruins(ruins_origin: Vector2i) -> void:
    var route := SourceRoute.new("ruins1_outer", 25)
    var origin_tile := tile_at(ruins_origin)
    assert(origin_tile != null)
    var ruins_tiles: Dictionary = {}
    var generated: Dictionary = {}
    apply_blotch("ruins1_upper2", origin_tile, 230, generated, 0, false, route)
    ruins_tiles.merge(generated, true)
    generated.clear()
    apply_blotch("ruins1_upper", origin_tile, 240, generated, 0, false, route)
    ruins_tiles.merge(generated, true)
    for raw_tile in SourceJavaHashOrder.values(ruins_tiles):
        var tile := raw_tile as SourceTile
        if "ruins1" in tile.name:
            _adjust_ruins_tile(tile, ruins_tiles)
    for raw_tile in SourceJavaHashOrder.values(ruins_tiles):
        var tile := raw_tile as SourceTile
        if not mountain_tiles.has(tile.position):
            tiles_to_add[tile.position] = tile
    for x_offset in range(-1, 2):
        for y_offset in range(-1, 2):
            var position := origin_tile.position + Vector2i(16 * x_offset, 16 * y_offset)
            var tile := peek_tile(position)
            if tile != null and tile.name != "desert4":
                tiles_to_add[position] = SourceTile.new("ruins_floor2", position, "", true)
    for position in [
            origin_tile.position + Vector2i(-32, 16), origin_tile.position + Vector2i(32, 16),
            origin_tile.position + Vector2i(-32, -16), origin_tile.position + Vector2i(32, -16)]:
        if random.next_int(3) > 0:
            tiles_to_add[position] = SourceTile.new("ruins1_pillar1", position, "", true)
    tiles_to_add[origin_tile.position] = SourceTile.new("ruins1_NSEW", origin_tile.position, "stairs_down2", true, route)
    generate_ruins_interior(origin_tile.position)
    # The mine record is captured by the interior generator; add its surface entry.
    validation_records.back().exterior[origin_tile.position] = GenerationValidator.signature(tiles_to_add[origin_tile.position])

func _adjust_ruins_tile(tile: SourceTile, layer: Dictionary) -> void:
    if "pillar" in tile.name:
        return
    var tokens := tile.name.split("_")
    var base_name := String(tokens[0])
    for index in range(1, tokens.size() - 1):
        base_name += "_" + String(tokens[index])
    var extension := "_"
    var checks := [
        [Vector2i(0, 16), "N"], [Vector2i(0, -16), "S"],
        [Vector2i(16, 0), "E"], [Vector2i(-16, 0), "W"]
    ]
    for check in checks:
        var adjacent := layer.get(tile.position + Vector2i(check[0])) as SourceTile
        if adjacent != null and base_name in adjacent.name:
            extension += String(check[1])
    tile.set_names(base_name + extension, tile.name_upper)

func generate_ruins_interior(ruins_origin: Vector2i) -> void:
    var fixed_rows := SourceLayoutData.rows("GenIsland1", "generateRuinsInterior", 0)
    var interior_tiles: Array[Dictionary] = [{}, {}, {}, {}, {}]
    var start_location := Vector2i(10, 10)
    var layout_origin := ruins_origin - Vector2i(496, 496)
    var start_locations: Array = []
    var endpoints: Array = [start_location]
    var dusclops_positions: Array[Vector2i] = []
    var route := SourceRoute.new("ruins1_inner", 22)
    for level_number in range(interior_tiles.size() - 1, -1, -1):
        var current_layer := interior_tiles[level_number]
        if level_number == 0:
            for row_index in range(fixed_rows.size()):
                var row: Array = fixed_rows[row_index]
                for column in range(row.size()):
                    if row[column] == null:
                        continue
                    var start_position := Vector2i(endpoints[0])
                    var position := layout_origin + Vector2i(
                        (start_position.x * 3 - 3 + column) * 16,
                        (start_position.y * 3 + 17 - row_index) * 16)
                    var source_name := String(row[column])
                    var tile: SourceTile
                    if source_name == "ruins_floor2_stairs":
                        tile = SourceTile.new("blank1", position, "stairs_up1", true, route)
                    elif source_name == "pedistal1":
                        tile = SourceTile.new("ruins_floor2", position, "pedistal1", true, route)
                    else:
                        tile = SourceTile.new(source_name, position, "", true, route)
                    if "pillar" in source_name:
                        tile.items["torch"] = 1
                    if row_index == 2 and column == 4:
                        tile.set_names(tile.name, "volcarona")
                    current_layer[position] = tile
            continue
        var complexity := 15.0
        for raw_position in endpoints:
            var endpoint := Vector2i(raw_position)
            var upper := "stairs_up1_exit" if level_number == interior_tiles.size() - 1 else "stairs_up1"
            var stair_position := layout_origin + Vector2i((endpoint.x * 3 + 1) * 16, (endpoint.y * 3 + 1) * 16)
            current_layer[stair_position] = SourceTile.new("desert4", stair_position, upper, true, route)
            start_locations.append(endpoint)
            start_locations.append(endpoint)
            if random.next_int(2) != 0 and level_number != interior_tiles.size() - 1:
                continue
            start_locations.append(endpoint)
            if level_number != interior_tiles.size() - 1:
                complexity = 10.0
        endpoints.clear()
        var width := 20
        var height := 20
        var maze := SourceMaze.maze_algo3(width, height, complexity, float(start_locations.size()), random, start_locations)
        dusclops_positions.clear()
        for maze_x in range(maze.size()):
            for maze_y in range((maze[maze_x] as Array).size()):
                if not bool(maze[maze_x][maze_y]):
                    continue
                for sub_x in range(3):
                    for sub_y in range(4):
                        var position := layout_origin + Vector2i((maze_x * 3 + sub_x) * 16, (maze_y * 3 + sub_y) * 16)
                        var existing := current_layer.get(position) as SourceTile
                        if existing != null and "wall" not in existing.name:
                            continue
                        if sub_y == 3:
                            var wall := SourceTile.new("ruins2_wall1", position, "", true)
                            if level_number != interior_tiles.size() - 1 and maze_x % 2 == 0 and sub_x == 1 and random.next_int(4) > 0:
                                wall.items["torch"] = 1
                            current_layer[position] = wall
                        else:
                            var tile_name := "desert4"
                            var offset := absi((maze_x * 3 + sub_x) % 12 - 6) + absi((maze_y * 3 + sub_y) % 12 - 6)
                            if level_number == interior_tiles.size() - 1:
                                tile_name = "desert4_isGrass"
                                if random.next_int(offset + 1) + offset > 14:
                                    tile_name = "ruins_floor2"
                            elif level_number == interior_tiles.size() - 2:
                                tile_name = "desert4_isGrass"
                                if random.next_int(offset + 1) + offset > 10:
                                    tile_name = "ruins_floor2"
                            elif level_number == interior_tiles.size() - 3:
                                if random.next_int(offset + 1) + offset > 7:
                                    tile_name = "ruins_floor2"
                            else:
                                tile_name = "ruins_floor2"
                            current_layer[position] = SourceTile.new(tile_name, position, "", true, route)
                        if level_number < 3 and sub_x == 1 and sub_y == 1 and maze_x % 3 == 0 and maze_y % 3 == 0:
                            dusclops_positions.append(position)
                var maze_position := Vector2i(maze_x, maze_y)
                if not start_locations.has(maze_position) and maze_x % 2 == 0 and maze_y % 2 == 0 and random.next_int(3) == 0:
                    var pot_positions: Array[Vector2i] = []
                    if maze_y - 1 >= 0 and not bool(maze[maze_x][maze_y - 1]):
                        for sub_x in range(3):
                            pot_positions.append(layout_origin + Vector2i((maze_x * 3 + sub_x) * 16, maze_y * 3 * 16))
                    if maze_y + 1 < height and not bool(maze[maze_x][maze_y + 1]):
                        for sub_x in range(3):
                            pot_positions.append(layout_origin + Vector2i((maze_x * 3 + sub_x) * 16, (maze_y * 3 + 2) * 16))
                    if maze_x + 1 < width and not bool(maze[maze_x + 1][maze_y]):
                        for sub_y in range(3):
                            pot_positions.append(layout_origin + Vector2i((maze_x * 3 + 2) * 16, (maze_y * 3 + sub_y) * 16))
                    if maze_x - 1 >= 0 and not bool(maze[maze_x - 1][maze_y]):
                        for sub_y in range(3):
                            pot_positions.append(layout_origin + Vector2i(maze_x * 3 * 16, (maze_y * 3 + sub_y) * 16))
                    for position in pot_positions:
                        if random.next_int(7) > 3:
                            var tile := current_layer.get(position) as SourceTile
                            if tile != null:
                                tile.set_names(tile.name, "pot1")
                    continue
                if level_number == 1 and maze_x % 2 == 0 and maze_y % 2 == 0 and random.next_int(2) == 0:
                    var position := layout_origin + Vector2i((maze_x * 3 + 1) * 16, (maze_y * 3 + 1) * 16)
                    var tile := current_layer.get(position) as SourceTile
                    if tile != null and tile.name_upper == "":
                        tile.set_names(tile.name, "ruins_statue1")
        var dusclops_size := dusclops_positions.size()
        var spawn_index := 0
        while spawn_index < 2 + random.next_int(3) and spawn_index < dusclops_size:
            var position: Vector2i = dusclops_positions.pop_at(
                random.next_int(dusclops_positions.size())
            )
            var dusclops := _make_pokemon_record("dusclops", 44, {
                "name": "dusclops", "level": 44, "generation": "CRYSTAL",
                "position": position, "area_index": level_number + 95,
                "aggressive": true
            })
            interior_pokemon.append(dusclops)
            spawn_index += 1
        var start_count := start_locations.size()
        var number_of_stairs := 1 if level_number == 1 else 2
        for stair_index in range(start_count):
            start_location = Vector2i(start_locations.pop_at(random.next_int(start_locations.size())))
            if stair_index < number_of_stairs:
                for sub_x in range(3):
                    for sub_y in range(3):
                        var position := layout_origin + Vector2i((start_location.x * 3 + sub_x) * 16, (start_location.y * 3 + sub_y) * 16)
                        if sub_x == 1 and sub_y == 1:
                            current_layer[position] = SourceTile.new("ruins_floor2", position, "stairs_down2", true, route)
                        elif random.next_int(5) > 1:
                            current_layer[position] = SourceTile.new("ruins_floor2", position, "", true, route)
                        else:
                            current_layer[position] = SourceTile.new("desert4", position, "", true, route)
                endpoints.append(start_location)
            else:
                var number_of_pots := 0
                for sub_x in range(3):
                    for sub_y in range(3):
                        var position := layout_origin + Vector2i((start_location.x * 3 + sub_x) * 16, (start_location.y * 3 + sub_y) * 16)
                        var tile := current_layer.get(position) as SourceTile
                        if sub_x == 1 and sub_y == 1:
                            if tile == null or "stairs" in tile.name_upper:
                                continue
                            tile.set_names(tile.name, "pokeball1")
                            if random.next_int(2) == 0:
                                tile.has_item = "ultra ball"
                                tile.has_item_amount = 2
                            else:
                                tile.has_item = "ancientpowder"
                                tile.has_item_amount = random.next_int(3) + 2
                        elif random.next_int(7) > 3 and number_of_pots < 2 and tile != null:
                            current_layer[position] = SourceTile.new(tile.name, position, "pot1", true, route)
                            number_of_pots += 1
        start_locations.clear()
    interior_tiles.append({})
    for index in range(interior_tiles.size()):
        _merge_interior_layer(index + 95, interior_tiles[index])
    var validation_layers := {}
    for index in range(5): validation_layers[index+95] = interior_tiles[index]
    validation_records.append(GenerationValidator.capture("mine", ruins_origin, {}, validation_layers))

func generate_mansion(mansion_origin: Vector2i) -> Dictionary:
    var height := 28
    var width := 30
    var exterior: Dictionary = {}
    var mansion_interiors: Array = []
    mansion_interiors.resize(95)
    mansion_interiors.append({})
    var layout_origin := mansion_origin - Vector2i(width * 16 / 2, height * 16 / 2)
    var exterior_route := SourceRoute.new("snow1", 40)
    var windows := 0
    for row_index in range(-8, height + 1):
        windows = random.next_int(2) + 1
        for column in range(width + 1):
            if column == width - 1:
                windows = 1
            var position := layout_origin + Vector2i(column * 16, row_index * 16)
            var base := "sand1"
            var upper := ""
            var place := true
            if row_index < 0 and column in [width / 2, width / 2 + 1]:
                base = "sand1" if random.next_int(6) <= 1 else "path1"
            elif row_index == -2:
                base = "flower4" if random.next_int(24) == 0 else "green1"
            elif row_index == -1:
                base = "sand1"
            elif row_index == 0:
                if column == 0: upper = "pkmnmansion_ext_SW"
                elif column == width: upper = "pkmnmansion_ext_SE"
                elif column == width / 2: upper = "pkmnmansion_ext_locked"
                else: upper = "pkmnmansion_ext_S_windows" if windows != 0 else "pkmnmansion_ext_S"
            elif row_index in [1, 2]:
                if column == 0: upper = "pkmnmansion_ext_W"
                elif column == width: upper = "pkmnmansion_ext_E"
                else: upper = "pkmnmansion_ext_windows" if windows != 0 else "pkmnmansion_ext"
            elif row_index == 3:
                if column == 0: upper = "pkmnmansion_roof_SW"
                elif column == width: upper = "pkmnmansion_roof_SE"
                else: upper = "pkmnmansion_roof_S"
            elif row_index == height:
                if column == 0: upper = "pkmnmansion_roof_NW"
                elif column == width: upper = "pkmnmansion_roof_NE"
                else: upper = "pkmnmansion_roof_N"
            elif row_index > 0:
                if column == 0: upper = "pkmnmansion_roof_W"
                elif column == width: upper = "pkmnmansion_roof_E"
                else: upper = "pkmnmansion_roof"
            else:
                place = false
            if place:
                exterior[position] = SourceTile.new(base, position, upper, true, exterior_route)
            if random.next_int(1 + windows) == 0:
                windows = (windows + 1) % 2
    layout_origin -= Vector2i(64, 64)
    for level_number in range(6):
        var route := SourceRoute.new("pkmnmansion1", 40 - level_number * 2)
        var row_is_solid := _mansion_axis_pattern(27 + (4 - level_number) * 2, 26 + (4 - level_number) * 2, level_number)
        var column_is_solid := _mansion_axis_pattern(29 + (4 - level_number) * 2, 28 + (4 - level_number) * 2, level_number)
        var number_of_rows := 0
        for value in row_is_solid:
            if value:
                number_of_rows += 2
        var number_of_columns := 0
        for value in column_is_solid:
            if value:
                number_of_columns += 2
        # The source increments the counters only for generated solid bands;
        # the final sentinel is not part of numRows/numCols.
        number_of_rows -= 2
        number_of_columns -= 2
        var maze := SourceMaze.maze_algo2(number_of_columns, number_of_rows, 0.05, 0.7, random)
        var layer: Dictionary = {}
        mansion_interiors.append(layer)
        var maze_y := 0
        for row_index in range(row_is_solid.size()):
            var maze_x := 0
            for column in range(column_is_solid.size()):
                var position := layout_origin + Vector2i(column * 16, row_index * 16)
                if bool(maze[maze_x][maze_y]):
                    layer[position] = SourceTile.new("pkmnmansion_wall", position, "", true)
                else:
                    layer[position] = SourceTile.new("pkmnmansion_floor1", position, "", true, route)
                if bool(column_is_solid[column]) or (column + 1 < column_is_solid.size() and bool(column_is_solid[column + 1])):
                    maze_x += 1
            if bool(row_is_solid[row_index]) or (row_index + 1 < row_is_solid.size() and bool(row_is_solid[row_index + 1])):
                maze_y += 1
        _replace_small_mansion_wall_islands(layer)
        _style_mansion_walls(layer)
        _damage_mansion_walls(layer)
        _place_mansion_shelves(layer)
        _place_mansion_tables(layer, layout_origin)
        layout_origin += Vector2i(16, 16)
    layout_origin -= Vector2i(32, 32)
    _connect_mansion_floors(mansion_interiors, layout_origin)
    for index in range(mansion_interiors.size()):
        if mansion_interiors[index] != null:
            _merge_interior_layer(index, mansion_interiors[index])
    _merge_exterior_preserving_mansion_key(exterior)
    var validation_layers := {}
    for index in range(95,102): validation_layers[index] = mansion_interiors[index]
    validation_records.append(GenerationValidator.capture("mansion", mansion_origin, exterior, validation_layers))
    return {"exterior": exterior, "interiors": mansion_interiors}

func _mansion_axis_pattern(length: int, forced_gap_index: int, level_number: int) -> Array[bool]:
    var sizes := [1, 2, 4, 5, 2, 4, 5]
    if level_number < 4:
        sizes.append_array([4, 2, 4, 2])
    var result: Array[bool] = []
    var counter := 0
    for index in range(length):
        if index == forced_gap_index:
            result.append(false)
        elif counter == 0:
            result.append(true)
            counter = int(sizes.pop_at(random.next_int(sizes.size())))
        else:
            result.append(false)
            counter -= 1
    result.append(true)
    return result

func _replace_small_mansion_wall_islands(layer: Dictionary) -> void:
    var already_checked: Dictionary = {}
    for raw_position in SourceJavaHashOrder.keys(layer):
        var position := Vector2i(raw_position)
        var tile := layer[position] as SourceTile
        if already_checked.has(position) or not tile.is_solid:
            continue
        already_checked[position] = true
        var size := 0
        var found: Array[Vector2i] = [position]
        var check: Array[Vector2i] = [
            position + Vector2i(-16, 0), position + Vector2i(16, 0),
            position + Vector2i(0, 16), position + Vector2i(0, -16)]
        while not check.is_empty():
            var next: Vector2i = check.pop_front()
            if already_checked.has(next):
                continue
            already_checked[next] = true
            var next_tile := layer.get(next) as SourceTile
            if next_tile == null or not next_tile.is_solid:
                continue
            size += 1
            found.append(next)
            for offset in [Vector2i(-16, 0), Vector2i(16, 0), Vector2i(0, 16), Vector2i(0, -16)]:
                check.append(next + offset)
        if size < 10:
            for found_position in found:
                layer[found_position] = SourceTile.new("tree_plant1", found_position, "", true)

func _is_mansion_wall(layer: Dictionary, position: Vector2i) -> bool:
    var tile := layer.get(position) as SourceTile
    return tile != null and "pkmnmansion_wall" in tile.name

func _style_mansion_walls(layer: Dictionary) -> void:
    for raw_position in SourceJavaHashOrder.keys(layer):
        var position := Vector2i(raw_position)
        if not _is_mansion_wall(layer, position):
            continue
        var left := _is_mansion_wall(layer, position + Vector2i(-16, 0))
        var right := _is_mansion_wall(layer, position + Vector2i(16, 0))
        var up := _is_mansion_wall(layer, position + Vector2i(0, 16))
        var down := _is_mansion_wall(layer, position + Vector2i(0, -16))
        var tile_name := "pkmnmansion_wall"
        if down and up:
            tile_name = "pkmnmansion_wall_NS"
        elif down and left:
            tile_name = "pkmnmansion_wall_N" if random.next_int(2) == 0 else "pkmnmansion_wall_NE"
        elif down and right:
            tile_name = "pkmnmansion_wall_N" if random.next_int(2) == 0 else "pkmnmansion_wall_NW"
        elif down:
            tile_name = "pkmnmansion_wall_N"
        elif up and left:
            tile_name = "pkmnmansion_wall_S" if random.next_int(2) == 0 else "pkmnmansion_wall_E"
        elif up and right:
            tile_name = "pkmnmansion_wall_S" if random.next_int(2) == 0 else "pkmnmansion_wall_W"
        elif up:
            tile_name = "pkmnmansion_wall_S"
        elif left and right:
            continue
        elif left:
            tile_name = "pkmnmansion_wall_E"
        elif right:
            tile_name = "pkmnmansion_wall_W"
        else:
            continue
        layer[position] = SourceTile.new(tile_name, position, "", true)

func _solid_at(layer: Dictionary, position: Vector2i) -> bool:
    var tile := layer.get(position) as SourceTile
    return tile != null and tile.is_solid

func _damage_mansion_walls(layer: Dictionary) -> void:
    var already_checked: Dictionary = {}
    for raw_position in SourceJavaHashOrder.keys(layer):
        var position := Vector2i(raw_position)
        if already_checked.has(position):
            continue
        already_checked[position] = true
        var start_tile := layer[position] as SourceTile
        if "pkmnmansion_wall" not in start_tile.name or random.next_int(13) != 0:
            continue
        var size := 0
        var check: Array[Vector2i] = [
            position + Vector2i(-16, 0), position + Vector2i(16, 0),
            position + Vector2i(0, 16), position + Vector2i(0, -16)]
        while not check.is_empty():
            var next: Vector2i = check.pop_front()
            if already_checked.has(next):
                continue
            already_checked[next] = true
            var tile := layer.get(next) as SourceTile
            if tile == null:
                continue
            if not tile.is_solid:
                var left := _solid_at(layer, next + Vector2i(-16, 0))
                var top_left := _solid_at(layer, next + Vector2i(-16, 16))
                var bottom_left := _solid_at(layer, next + Vector2i(-16, -16))
                var right := _solid_at(layer, next + Vector2i(16, 0))
                var top_right := _solid_at(layer, next + Vector2i(16, 16))
                var bottom_right := _solid_at(layer, next + Vector2i(16, -16))
                var up := _solid_at(layer, next + Vector2i(0, 16))
                var down := _solid_at(layer, next + Vector2i(0, -16))
                if (left and ((top_right and not up) or (bottom_right and not down))
                        or up and ((bottom_left and not left) or (bottom_right and not right))
                        or right and ((top_left and not up) or (bottom_left and not down))
                        or down and ((top_left and not left) or (top_right and not right))):
                    continue
            elif "pkmnmansion_wall" not in tile.name:
                continue
            if size > 10 and random.next_int(35) - size <= 0:
                continue
            size += 1
            layer[next] = SourceTile.new("pkmnmansion_floor1", next, "rubble1", true)
            for offset in [Vector2i(-16, 0), Vector2i(16, 0), Vector2i(0, 16), Vector2i(0, -16)]:
                check.append(next + offset)

func _place_mansion_shelves(layer: Dictionary) -> void:
    var already_checked: Dictionary = {}
    for raw_position in SourceJavaHashOrder.keys(layer):
        var position := Vector2i(raw_position)
        if already_checked.has(position):
            continue
        already_checked[position] = true
        var start_tile := layer[position] as SourceTile
        if start_tile.is_solid:
            continue
        var near_wall := (
            _is_mansion_wall(layer, position + Vector2i(0, 16))
            or _is_mansion_wall(layer, position + Vector2i(-16, 0))
            or _is_mansion_wall(layer, position + Vector2i(16, 0)))
        if not near_wall or random.next_int(5) != 0:
            continue
        var current_set: Dictionary = {}
        var size := 0
        var check: Array[Vector2i] = [
            position + Vector2i(-16, 0), position + Vector2i(16, 0),
            position + Vector2i(0, 16), position + Vector2i(0, -16)]
        while not check.is_empty():
            var next: Vector2i = check.pop_front()
            if already_checked.has(next):
                continue
            already_checked[next] = true
            var tile := layer.get(next) as SourceTile
            if tile == null or tile.is_solid:
                continue
            var left_pos := next + Vector2i(-16, 0)
            var right_pos := next + Vector2i(16, 0)
            var up_pos := next + Vector2i(0, 16)
            var down_pos := next + Vector2i(0, -16)
            var left_wall := _is_mansion_wall(layer, left_pos)
            var right_wall := _is_mansion_wall(layer, right_pos)
            var up_wall := _is_mansion_wall(layer, up_pos)
            var down_wall := _is_mansion_wall(layer, down_pos)
            if down_wall or (left_wall and right_wall) or (not left_wall and not right_wall and not up_wall):
                continue
            var left := _solid_at(layer, left_pos)
            var right := _solid_at(layer, right_pos)
            var up := _solid_at(layer, up_pos)
            var down := _solid_at(layer, down_pos)
            var top_left := _solid_at(layer, next + Vector2i(-16, 16))
            var bottom_left := _solid_at(layer, next + Vector2i(-16, -16))
            var top_right := _solid_at(layer, next + Vector2i(16, 16))
            var bottom_right := _solid_at(layer, next + Vector2i(16, -16))
            if (left and ((top_right and not up) or (bottom_right and not down))
                    or up and ((bottom_left and not left) or (bottom_right and not right))
                    or right and ((top_left and not up) or (bottom_left and not down))
                    or down and ((top_left and not left) or (top_right and not right))
                    or (size > 10 and random.next_int(35) - size <= 0)):
                continue
            size += 1
            current_set[next] = SourceTile.new("pkmnmansion_shelf1", next, "", true)
            for offset in [Vector2i(-16, 0), Vector2i(16, 0), Vector2i(0, 16), Vector2i(0, -16)]:
                check.append(next + offset)
        if current_set.size() > 3:
            for shelf_position in current_set:
                layer[shelf_position] = SourceTile.new(
                    "pkmnmansion_shelf1_NS" if current_set.has(shelf_position + Vector2i(0, 16)) else "pkmnmansion_shelf1",
                    shelf_position, "", true)

func _place_mansion_tables(layer: Dictionary, layout_origin: Vector2i) -> void:
    var already_checked: Dictionary = {}
    var possible_spots: Array[Dictionary] = []
    var position := layout_origin
    while position.y < layout_origin.y + 448:
        if position.x > layout_origin.x + 480:
            position.x = layout_origin.x - 16
            position.y += 16
        elif layer.has(position) and not already_checked.has(position) and "pkmnmansion_floor1" in (layer[position] as SourceTile).name:
            var height := 4
            var width := 4
            var last_working := Vector2i.ZERO
            var found_working := false
            var y_direction := false
            while true:
                var works := true
                for x in range(width):
                    for y in range(height):
                        var test := layer.get(position + Vector2i(x * 16, y * 16)) as SourceTile
                        if test == null or test.is_solid:
                            works = false
                            break
                    if not works:
                        break
                if works:
                    last_working = Vector2i(width, height)
                    found_working = true
                    if y_direction:
                        height += 1
                    else:
                        width += 1
                elif y_direction:
                    break
                else:
                    y_direction = true
            if found_working:
                if last_working.x < 7 and last_working.y < 7:
                    var table_tiles: Dictionary = {}
                    for x in range(1, last_working.x - 1):
                        for y in range(1, last_working.y - 1):
                            var table_position := position + Vector2i(x * 16, y * 16)
                            var tile_name := "table"
                            if x == 1 and y == 1: tile_name = "table_SW"
                            elif x == last_working.x - 2 and y == last_working.y - 2: tile_name = "table_NE"
                            elif x == 1 and y == last_working.y - 2: tile_name = "table_NW"
                            elif x == last_working.x - 2 and y == 1: tile_name = "table_SE"
                            elif x == 1: tile_name = "table_W"
                            elif x == last_working.x - 2: tile_name = "table_E"
                            elif y == 1: tile_name = "table_S"
                            elif y == last_working.y - 2: tile_name = "table_N"
                            table_tiles[table_position] = SourceTile.new(tile_name, table_position, "", true)
                    possible_spots.append(table_tiles)
                for x in range(last_working.x):
                    for y in range(last_working.y + 1):
                        already_checked[position + Vector2i(x * 16, y * 16)] = true
        position.x += 16
    for table_tiles in possible_spots:
        var works := true
        for table_position in table_tiles:
            if _solid_at(layer, table_position):
                works = false
                break
        if works:
            layer.merge(table_tiles, true)

func _connect_mansion_floors(mansion_interiors: Array, layout_origin: Vector2i) -> void:
    var next_stairs_up: SourceTile = null
    var current_layer := mansion_interiors[100] as Dictionary
    var layer_above := mansion_interiors[101] as Dictionary
    var route := SourceRoute.new("pkmnmansion1", 30)
    var y_max := random.next_int(4) * 2 + 6
    var probe := layout_origin + Vector2i(240, (y_max - 1) * 16)
    while layer_above.has(probe) and (layer_above[probe] as SourceTile).is_solid:
        y_max += 1
        probe = layout_origin + Vector2i(240, (y_max - 1) * 16)
    var stairs_up: SourceTile = null
    for x in range(10):
        for y in range(y_max):
            var position := layout_origin + Vector2i((x + 10) * 16, y * 16)
            if y == y_max - 1 and x == 5:
                next_stairs_up = SourceTile.new("pkmnmansion_floor2", position, "stairs_up1", true)
                current_layer[position] = next_stairs_up
                stairs_up = SourceTile.new("pkmnmansion_floor2", position, "stairs_down1", true)
                layer_above[position] = stairs_up
            elif y == 0 and x == 5:
                current_layer[position] = SourceTile.new("pkmnmansion_rug", position, "", true, route)
            elif x in [2, 7] and y % 2 == 1 and y != 1:
                current_layer[position] = SourceTile.new("pkmnmansion_block1", position, "", true)
            elif x == 3:
                current_layer[position] = SourceTile.new("pkmnmansion_floor2_W", position, "", true, route)
            elif x == 6:
                current_layer[position] = SourceTile.new("pkmnmansion_floor2_E", position, "", true, route)
            elif x > 3 and x < 6:
                current_layer[position] = SourceTile.new("pkmnmansion_floor2", position, "", true, route)
            elif y != 0:
                current_layer[position] = SourceTile.new("pkmnmansion_floor1", position, "", true, route)
    var previous_statue: SourceTile = null
    for level_number in range(6, 0, -1):
        current_layer = mansion_interiors[95 + level_number] as Dictionary
        var layer_below := mansion_interiors[94 + level_number] as Dictionary
        if stairs_up == null:
            continue
        var endpoints := _mansion_dead_ends(current_layer, [stairs_up.position], false)
        # Original generateMansion also crashes when this list is empty (seed
        # 65535). Keep valid source selection unchanged; use the existing
        # clear-floor fallback only for that otherwise-fatal layout.
        var selected := _mansion_statue_fallback_position(current_layer, [stairs_up.position]) if endpoints.is_empty() else Vector2i(endpoints.back())
        while not endpoints.is_empty():
            selected = Vector2i(endpoints.pop_at(random.next_int(5) + endpoints.size() - 5)) if endpoints.size() > 4 else Vector2i(endpoints.pop_back())
            var below := layer_below.get(selected) as SourceTile
            if below == null or not below.is_solid:
                break
        var stairs_down := SourceTile.new("pkmnmansion_floor2", selected, "stairs_down1", true)
        if level_number != 6:
            current_layer[selected] = stairs_down
            next_stairs_up = SourceTile.new("pkmnmansion_floor1", selected, "stairs_up1", true)
            layer_below[selected] = next_stairs_up
        var maximum_items := random.next_int(3) + 3
        var item_index := 0
        while item_index < maximum_items * 3 and endpoints.size() > 5:
            selected = Vector2i(endpoints.pop_back())
            if item_index % 3 == 0:
                current_layer[selected] = SourceTile.new("pkmnmansion_floor1", selected, "ultraball1", true)
            item_index += 1
        endpoints = _mansion_dead_ends(current_layer, [stairs_up.position, stairs_down.position], true)
        # A strict mansion pass can legitimately produce zero dead ends after
        # item/stair placement. The old one-line selection then called
        # Vector2i(null) from pop_back(), aborting world generation. Keep the
        # normal source-parity selection untouched when candidates exist; only
        # use a deterministic clear-floor fallback for the otherwise-fatal case.
        var place_statue := true
        if endpoints.is_empty():
            selected = _mansion_statue_fallback_position(
                current_layer, [stairs_up.position, stairs_down.position])
            place_statue = (
                selected != stairs_up.position
                and selected != stairs_down.position)
        else:
            selected = (
                Vector2i(endpoints.pop_at(
                    random.next_int(5) + endpoints.size() - 5))
                if endpoints.size() > 4
                else Vector2i(endpoints.pop_back()))
        var statue := SourceTile.new("pkmnmansion_statue1", selected, "", true)
        if level_number != 1 and place_statue:
            current_layer[selected] = statue
        var all_doors := _mansion_door_candidates(current_layer)
        if previous_statue != null:
            _solve_mansion_doors(current_layer, stairs_up, stairs_down, statue, previous_statue, all_doors)
        if level_number == 1:
            _make_mewtwo_room(mansion_interiors, stairs_down.position)
        previous_statue = statue
        stairs_up = next_stairs_up

func _mansion_dead_ends(layer: Dictionary, starts: Array, strict: bool) -> Array:
    var already_checked: Dictionary = {}
    var check: Array[Vector2i] = []
    var endpoints: Array[Vector2i] = []
    for start_index in range(starts.size()):
        var raw_start = starts[start_index]
        var start := Vector2i(raw_start)
        check.append(start)
        # Preserve the source's strict-pass typo: stairsUp is added twice to
        # alreadyChecked and stairsDown is not initially added at all.
        if not strict or start_index == 0:
            already_checked[start] = true
        elif strict:
            already_checked[Vector2i(starts[0])] = true
    while not check.is_empty():
        for raw_position in check.duplicate():
            var position := Vector2i(raw_position)
            check.erase(position)
            var added_another := false
            var touches_table := false
            var touches_endpoint := false
            var number_touching := 0
            var shuffled := [
                position + Vector2i(16, 0), position + Vector2i(-16, 0),
                position + Vector2i(0, 16), position + Vector2i(0, -16)]
            while not shuffled.is_empty():
                var next := Vector2i(shuffled.pop_at(random.next_int(shuffled.size())))
                var next_tile := layer.get(next) as SourceTile
                if strict and next_tile != null and next_tile.is_solid:
                    number_touching += 1
                if not already_checked.has(next) and next_tile != null and not next_tile.is_solid and "stairs" not in next_tile.name_upper:
                    check.append(next)
                    already_checked[next] = true
                    added_another = true
                if next_tile != null and "table" in next_tile.name:
                    touches_table = true
                if endpoints.has(next):
                    touches_endpoint = true
            var tile := layer.get(position) as SourceTile
            if tile == null:
                continue
            if strict:
                var down := _solid_at(layer, position + Vector2i(0, -16))
                var bottom_left := _solid_at(layer, position + Vector2i(-16, -16))
                var bottom_right := _solid_at(layer, position + Vector2i(16, -16))
                var top_left := _solid_at(layer, position + Vector2i(-16, 16))
                var top_right := _solid_at(layer, position + Vector2i(16, 16))
                if (down or (bottom_left and bottom_right) or (top_left and top_right)
                        or number_touching >= 2 or touches_table or touches_endpoint
                        or added_another or "floor2" in tile.name or "rug" in tile.name):
                    continue
            elif touches_table or touches_endpoint or added_another or "floor2" in tile.name or "rug" in tile.name:
                continue
            endpoints.append(position)
    return endpoints

func _mansion_statue_fallback_position(
        layer: Dictionary, blocked_positions: Array
    ) -> Vector2i:
    var blocked: Array[Vector2i] = []
    for raw_blocked in blocked_positions:
        blocked.append(Vector2i(raw_blocked))

    # Prefer an untouched floor1 cell farthest from the stairs. This keeps the
    # statue useful as a remote mansion switch without drawing any additional
    # RNG values, so the post-repair random stream remains stable.
    var best_position := Vector2i.ZERO
    var best_distance := -1
    var found := false
    for raw_position in SourceJavaHashOrder.keys(layer):
        var position := Vector2i(raw_position)
        if blocked.has(position):
            continue
        var tile := layer.get(position) as SourceTile
        if (tile == null or tile.is_solid or not tile.name_upper.is_empty()
                or "floor1" not in tile.name):
            continue
        var nearest_stair := 2147483647
        for stair_position in blocked:
            var distance := (
                absi(position.x - stair_position.x)
                + absi(position.y - stair_position.y))
            nearest_stair = mini(nearest_stair, distance)
        if not found or nearest_stair > best_distance:
            found = true
            best_position = position
            best_distance = nearest_stair
    if found:
        return best_position

    # Degenerate safety net: choose any unoccupied walkable cell before ever
    # falling back to a stair position. The caller will not overwrite stairs.
    for require_empty_upper in [true, false]:
        for raw_position in SourceJavaHashOrder.keys(layer):
            var position := Vector2i(raw_position)
            if blocked.has(position):
                continue
            var tile := layer.get(position) as SourceTile
            if tile == null or tile.is_solid:
                continue
            if require_empty_upper and not tile.name_upper.is_empty():
                continue
            return position
    if not blocked.is_empty():
        return blocked[0]
    return Vector2i.ZERO

func _mansion_door_candidates(layer: Dictionary) -> Array:
    var all_doors: Array = []
    var already_checked: Dictionary = {}
    for raw_position in SourceJavaHashOrder.keys(layer):
        var position := Vector2i(raw_position)
        var current := layer[position] as SourceTile
        if not current.is_solid:
            continue
        var directions: Array[Vector2i] = []
        match current.name:
            "pkmnmansion_wall_S": directions = [Vector2i(-16, 0), Vector2i(0, -16), Vector2i(16, 0)]
            "pkmnmansion_wall_N": directions = [Vector2i(-16, 0), Vector2i(0, 16), Vector2i(16, 0)]
            "pkmnmansion_wall_W": directions = [Vector2i(-16, 0), Vector2i(0, 16), Vector2i(0, -16)]
            "pkmnmansion_wall_NW": directions = [Vector2i(-16, 0), Vector2i(0, 16)]
            "pkmnmansion_wall_E": directions = [Vector2i(16, 0), Vector2i(0, 16), Vector2i(0, -16)]
            "pkmnmansion_wall_NE": directions = [Vector2i(16, 0), Vector2i(0, 16)]
            _: continue
        var length := 0
        for initial_direction in directions:
            var direction := initial_direction
            var door: Array[SourceTile] = []
            var valid_end := false
            while true:
                var next := layer.get(current.position + direction) as SourceTile
                if next == null or "rug" in next.name or "stairs" in next.name or "stairs" in next.name_upper or (next.is_solid and "pokeball" not in next.name_upper):
                    # Java leaves nextTile null at the edge and rejects that
                    # candidate after the scan; only an unvisited wall/rubble
                    # endpoint makes a usable door corridor.
                    if (next != null
                            and ("pkmnmansion_wall" in next.name
                                or "rubble" in next.name_upper)
                            and not already_checked.has(next.position)):
                        valid_end = true
                    break
                var gate_name := "pkmnmansion_gate_NS__on" if direction.x == 0 else "pkmnmansion_gate_EW__on"
                door.append(SourceTile.new(gate_name, next.position, "", true))
                direction += initial_direction
                length += 1
            if valid_end and length < 7:
                all_doors.append(door)
    return all_doors

func _solve_mansion_doors(
        layer: Dictionary,
        stairs_up: SourceTile,
        stairs_down: SourceTile,
        statue: SourceTile,
        previous_statue: SourceTile,
        all_doors: Array
    ) -> void:
    previous_statue.door_tiles.clear()
    for raw_door in all_doors:
        var door := raw_door as Array
        for raw_tile in door:
            var tile := raw_tile as SourceTile
            layer[tile.position] = tile
            if not previous_statue.door_tiles.has(tile.position):
                previous_statue.door_tiles.append(tile.position)

    var stairs_down_doors := all_doors.duplicate()
    var changed_door := true
    while changed_door:
        var path_to_stairs := is_path_between(layer, stairs_up, stairs_down)
        var path_to_statue := is_path_between(layer, stairs_up, statue)
        changed_door = false
        var door_index := 0
        while door_index < stairs_down_doors.size():
            var door := stairs_down_doors[random.next_int(stairs_down_doors.size())] as Array
            _flip_mansion_door(door)
            if not path_to_stairs and is_path_between(layer, stairs_up, stairs_down):
                _flip_mansion_door(door)
                door_index += 1
                continue
            if path_to_statue and not is_path_between(layer, stairs_up, statue):
                # This double flip is present in 0.8.11 and deliberately leaves
                # the door in the once-flipped state.
                _flip_mansion_door(door)
                _flip_mansion_door(door)
                door_index += 1
                continue
            stairs_down_doors.erase(door)
            changed_door = true
            door_index += 1

    stairs_down_doors.clear()
    for raw_door in all_doors:
        var door := raw_door as Array
        if _door_contains_state(door, "__on"):
            stairs_down_doors.append(door)

    for position in previous_statue.door_tiles:
        var tile := layer.get(position) as SourceTile
        if tile != null and "__off" in tile.name:
            tile.flip_door_tile()
    for raw_door in all_doors:
        var door := raw_door as Array
        for raw_tile in door:
            var tile := raw_tile as SourceTile
            if "__off" in tile.name:
                tile.flip_door_tile()

    var statue_doors: Array = []
    for raw_door in all_doors:
        if not stairs_down_doors.has(raw_door):
            statue_doors.append(raw_door)
    changed_door = true
    while changed_door:
        var path_to_stairs := is_path_between(layer, stairs_up, stairs_down)
        var path_to_statue := is_path_between(layer, stairs_up, statue)
        changed_door = false
        var door_index := 0
        while door_index < statue_doors.size():
            var door := statue_doors[random.next_int(statue_doors.size())] as Array
            _flip_mansion_door(door)
            if not path_to_statue and is_path_between(layer, stairs_up, statue):
                _flip_mansion_door(door)
                door_index += 1
                continue
            if path_to_stairs and not is_path_between(layer, stairs_up, stairs_down):
                _flip_mansion_door(door)
                door_index += 1
                continue
            statue_doors.erase(door)
            changed_door = true
            door_index += 1

    statue_doors.clear()
    for raw_door in all_doors:
        var door := raw_door as Array
        if _door_contains_state(door, "__on"):
            statue_doors.append(door)

    for raw_door in all_doors:
        var door := raw_door as Array
        for raw_tile in door:
            var tile := raw_tile as SourceTile
            layer[tile.position] = SourceTile.new("pkmnmansion_floor1", tile.position, "", true)
            previous_statue.door_tiles.erase(tile.position)
    previous_statue.door_tiles.clear()

    for raw_door in statue_doors:
        var door := raw_door as Array
        for raw_tile in door:
            var tile := raw_tile as SourceTile
            layer[tile.position] = tile
            previous_statue.door_tiles.append(tile.position)
            if "__off" in tile.name:
                tile.flip_door_tile()

    if not is_path_between(layer, stairs_up, stairs_down):
        for raw_door in statue_doors:
            var door := raw_door as Array
            for raw_tile in door:
                var tile := raw_tile as SourceTile
                layer[tile.position] = SourceTile.new("pkmnmansion_floor1", tile.position, "", true)
                previous_statue.door_tiles.erase(tile.position)
            if is_path_between(layer, stairs_up, stairs_down):
                break

    for raw_door in stairs_down_doors:
        var door := raw_door as Array
        for raw_tile in door:
            var tile := raw_tile as SourceTile
            layer[tile.position] = tile
            if not previous_statue.door_tiles.has(tile.position):
                previous_statue.door_tiles.append(tile.position)
            if "__on" in tile.name:
                tile.flip_door_tile()

    if random.next_int(2) == 0:
        for position in previous_statue.door_tiles:
            var tile := layer.get(position) as SourceTile
            if tile != null:
                tile.flip_door_tile()

func _flip_mansion_door(door: Array) -> void:
    for raw_tile in door:
        (raw_tile as SourceTile).flip_door_tile()

func _door_contains_state(door: Array, state_name: String) -> bool:
    for raw_tile in door:
        if state_name in (raw_tile as SourceTile).name:
            return true
    return false

func _make_mewtwo_room(mansion_interiors: Array, stairs_down_position: Vector2i) -> void:
    var room_origin := stairs_down_position + Vector2i(-80, -16)
    mansion_interiors[95] = {}
    var layer := mansion_interiors[95] as Dictionary
    var current_tile: SourceTile = null
    for x in range(10):
        for y in range(11):
            var position := room_origin + Vector2i(x * 16, y * 16)
            if y in [2, 6] and x in [2, 3, 6, 7]:
                current_tile = SourceTile.new("tree_plant1", position, "", true)
            elif x == 0 or y == 0 or y == 10 or x == 9:
                current_tile = SourceTile.new("pkmnmansion_wall", position, "", true)
            elif x == 4 and y == 9:
                current_tile = SourceTile.new("pkmnmansion_struct1", position, "", true)
            elif x != 5 or y != 9:
                if x == 5 and y == 8:
                    current_tile = SourceTile.new("pkmnmansion_floor1", position, "mewtwo_overworld", true)
                elif x == 5 and y == 1:
                    current_tile = SourceTile.new("pkmnmansion_floor1", position, "stairs_up1", true)
                else:
                    current_tile = SourceTile.new("pkmnmansion_floor1", position, "", true)
            # At (5, 9), 0.8.11 reuses the previous Tile object. Retaining that
            # quirk keeps dictionary contents and Java output parity exact.
            layer[position] = current_tile
    _style_mansion_walls(layer)

func _merge_exterior_preserving_mansion_key(exterior: Dictionary) -> void:
    for raw_tile in SourceJavaHashOrder.values(exterior):
        var tile := raw_tile as SourceTile
        var existing := tile_at(tile.position)
        if existing != null and existing.name_upper == "pokemon_mansion_key":
            tiles_to_add[tile.position] = SourceTile.new(tile.name, existing.position, existing.name_upper, true, existing.route_belongs_to)
        else:
            tiles_to_add[tile.position] = tile

func _merge_interior_layer(index: int, layer_tiles: Dictionary) -> void:
    while interior_tiles_to_add.size() <= index:
        interior_tiles_to_add.append(null)
    if interior_tiles_to_add[index] == null:
        interior_tiles_to_add[index] = layer_tiles
    else:
        (interior_tiles_to_add[index] as Dictionary).merge(layer_tiles, true)

# Direct port of GenIsland1.AddMtnLayer. level_tiles is the current frontier;
# tile_levels uses SourceTile object identity as Java's HashMap<Tile, Integer>.
func add_mountain_layer(
        level_tiles: Dictionary,
        tile_levels: Dictionary,
        all_mountain_tiles: Dictionary,
        new_level: int,
        tile_name: String,
        route: SourceRoute,
        ice_allowed: bool,
        capacity_state: Dictionary
    ) -> void:
    for tile: SourceTile in SourceJavaHashOrder.values(
            level_tiles, int(capacity_state.get("peak", level_tiles.size()))):
        for offset in NEIGHBOURS_8:
            var position := tile.position + offset
            if all_mountain_tiles.has(position):
                continue
            var next_tile := SourceTile.new(tile_name, position, "", true, route)
            next_tile.biome = "mountain"
            level_tiles[position] = next_tile
            capacity_state["peak"] = maxi(
                int(capacity_state.get("peak", 0)), level_tiles.size()
            )
            tile_levels[next_tile] = new_level
            all_mountain_tiles[position] = next_tile
        level_tiles.erase(tile.position)
        if not ice_allowed:
            no_ice_here[tile.position] = int(no_ice_here.get(tile.position, 0)) + 1

# Exact first phase of GenIsland1.ApplyBlotchMountain: four directional
# walkers, branching, endpoint collection, and stochastic mountain layers.
# Later biome/volcano/ledge phases consume the returned identity-level map.
func grow_mountain_skeleton(origin_tile: SourceTile) -> Dictionary:
    var edge_tiles: Array[SourceTile] = []
    var edge_directions: Dictionary = {}
    var origins: Dictionary = {}
    var origin_distances: Dictionary = {}
    var all_tiles: Dictionary = {}
    var copy_tile := origin_tile.copy_at()
    edge_tiles.append(origin_tile)
    edge_tiles.append(copy_tile)
    var direction_1 := Vector2(float(random.next_int(200) - 100), float(random.next_int(200) - 100))
    # libGDX Vector2.rotate(float) is the deprecated degree-based alias of
    # rotateDeg. Godot's Vector2.rotated expects radians.
    var direction_2 := SourceLibGDXMath.rotate_deg(direction_1, 180.0)
    edge_directions[origin_tile] = direction_1
    edge_directions[copy_tile] = direction_2
    origins[origin_tile] = origin_tile.position
    origins[copy_tile] = origin_tile.position
    origin_distances[origin_tile] = radius
    origin_distances[copy_tile] = radius
    var copy_tile_2 := origin_tile.copy_at()
    var copy_tile_3 := origin_tile.copy_at()
    edge_tiles.append(copy_tile_2)
    edge_tiles.append(copy_tile_3)
    edge_directions[copy_tile_2] = SourceLibGDXMath.rotate_deg(direction_1, 90.0)
    edge_directions[copy_tile_3] = SourceLibGDXMath.rotate_deg(direction_2, 90.0)
    origins[copy_tile_2] = origin_tile.position
    origins[copy_tile_3] = origin_tile.position
    origin_distances[copy_tile_2] = int(2.0 * float(absi(radius)) / 8.0)
    origin_distances[copy_tile_3] = int(2.0 * float(absi(radius)) / 8.0)
    var endpoints: Array[SourceTile] = []
    no_ice_here.clear()
    var current_level := 0
    var new_level := 0
    var number_of_layers := 0
    var possible_levels := [0, 0, -1, -1, -1]
    var level_tiles: Dictionary = {origin_tile.position: origin_tile, copy_tile.position: copy_tile}
    var level_tiles_capacity := {"peak": level_tiles.size()}
    var tile_levels: Dictionary = {origin_tile: current_level, copy_tile: current_level}
    var mountain_route := SourceRoute.new("mountain1", 33)
    var snow_route := SourceRoute.new("snow1", 44)
    while not edge_tiles.is_empty() or float(current_level) > -ceil(float(int(radius / 6000))) or number_of_layers < 13:
        for tile: SourceTile in edge_tiles.duplicate():
            edge_tiles.erase(tile)
            var current_direction: Vector2 = edge_directions[tile]
            edge_directions.erase(tile)
            var tile_origin := Vector2(origins[tile])
            var distance := SourceLibGDXMath.distance(Vector2(tile.position), tile_origin)
            var maximum_distance := int(origin_distances[tile])
            var put_tile := random.next_int(maximum_distance + 1) + int(distance) - int(maximum_distance / 32)
            if put_tile < maximum_distance:
                put_tile = random.next_int(absi(int(current_direction.x)) + 1) + random.next_int(absi(int(current_direction.y)) + 1)
                var new_direction := Vector2.ZERO
                if float(put_tile) < SourceLibGDXMath.float32(absf(current_direction.y) + 2.0):
                    new_direction.y = -1.0 if current_direction.y < 0.0 else 1.0
                else:
                    new_direction.x = -1.0 if current_direction.x < 0.0 else 1.0
                var next_position := tile.position + Vector2i(int(16.0 * new_direction.x), int(16.0 * new_direction.y))
                var next_tile := SourceTile.new("mountain1", next_position, "", true, mountain_route)
                all_tiles[next_position] = next_tile
                edge_tiles.append(next_tile)
                edge_directions[next_tile] = current_direction
                origins[next_tile] = origins[tile]
                origin_distances[next_tile] = maximum_distance
                level_tiles[next_position] = next_tile
                level_tiles_capacity["peak"] = maxi(
                    int(level_tiles_capacity["peak"]), level_tiles.size()
                )
                tile_levels[next_tile] = new_level
                var combined_distance := SourceLibGDXMath.float32(
                    float(radius + maximum_distance))
                var branch_scale := SourceLibGDXMath.float32(
                    combined_distance / 350.0)
                var branch_ratio := SourceLibGDXMath.float32(4.0 / branch_scale)
                var branch_bound := int(ceil(
                    SourceLibGDXMath.float32(1.0 / branch_ratio)))
                if random.next_int(branch_bound) == 1:
                    var degrees := random.next_int(80) + 10
                    var remaining_distance := SourceLibGDXMath.float32(
                        SourceLibGDXMath.float32(float(maximum_distance)) - distance)
                    var branch_distance := int(SourceLibGDXMath.float32(
                        SourceLibGDXMath.float32(absf(remaining_distance)) / 8.0))
                    var branch_direction := SourceLibGDXMath.rotate_deg(
                        current_direction, float(degrees))
                    next_tile = SourceTile.new("mountain1", tile.position, "", true, mountain_route)
                    edge_tiles.append(next_tile)
                    edge_directions[next_tile] = branch_direction
                    origins[next_tile] = tile.position
                    origin_distances[next_tile] = branch_distance
                    branch_direction = SourceLibGDXMath.rotate_deg(
                        current_direction, float(-degrees))
                    next_tile = SourceTile.new("mountain1", tile.position, "", true, mountain_route)
                    edge_tiles.append(next_tile)
                    edge_directions[next_tile] = branch_direction
                    origins[next_tile] = tile.position
                    origin_distances[next_tile] = branch_distance
            elif distance > 100.0:
                endpoints.append(tile)
            origins.erase(tile)
            origin_distances.erase(tile)
        var layer_bound := int(ceil(1.0 / (1.0 / (float(radius) / 1000.0))))
        if random.next_int(layer_bound) != 1:
            continue
        if number_of_layers < 10:
            new_level = current_level + int(possible_levels[random.next_int(possible_levels.size())])
        elif number_of_layers >= int(radius / 1800):
            new_level -= 1
        add_mountain_layer(level_tiles, tile_levels, all_tiles, new_level, "mountain3" if new_level <= -1 else "snow1", mountain_route if new_level <= -1 else snow_route, number_of_layers >= 10 and number_of_layers < int(radius / 1800), level_tiles_capacity)
        current_level = new_level
        number_of_layers += 1
    while number_of_layers <= int(radius / 1800):
        add_mountain_layer(level_tiles, tile_levels, all_tiles, current_level, "mountain3" if current_level <= -1 else "snow1", mountain_route if current_level <= -1 else snow_route, number_of_layers >= 10 and number_of_layers <= int(radius / 1800), level_tiles_capacity)
        number_of_layers += 1
    add_mountain_layer(level_tiles, tile_levels, all_tiles, current_level - 1, "mountain3", mountain_route, false, level_tiles_capacity)
    add_mountain_layer(level_tiles, tile_levels, all_tiles, current_level - 2, "mountain3", mountain_route, false, level_tiles_capacity)
    mountain_tiles = all_tiles
    return {
        "tiles": all_tiles,
        "tile_levels": tile_levels,
        "level_tiles": level_tiles,
        "endpoints": endpoints,
        "current_level": current_level,
        "bottom_level": current_level - 2,
        "number_of_layers": number_of_layers,
        "level_tiles_capacity": level_tiles_capacity
    }

# Complete ApplyBlotchMountain continuation after the directional skeleton.
func apply_blotch_mountain(origin_tile: SourceTile, maximum_distance: int, tiles_to_add: Dictionary) -> Array[SourceTile]:
    var generated := grow_mountain_skeleton(origin_tile)
    var all_mountain_tiles := generated["tiles"] as Dictionary
    var tile_levels := generated["tile_levels"] as Dictionary
    var level_tiles := generated["level_tiles"] as Dictionary
    var level_tiles_capacity := generated["level_tiles_capacity"] as Dictionary
    var endpoints: Array[SourceTile] = generated["endpoints"]
    var bottom_level := int(generated["bottom_level"])
    var volcano_route := SourceRoute.new("volcano1", 22)
    level_tiles.clear()
    var volcano_tiles: Dictionary = {}
    apply_blotch("volcano1", origin_tile, 350, volcano_tiles, 0, false, volcano_route)
    level_tiles.clear()
    apply_blotch("volcano1_lava", origin_tile, 200, level_tiles, 0, false, volcano_route)
    ledgify(level_tiles, level_tiles, "volcano2", "lava1_", "volcano")
    volcano_tiles.merge(level_tiles, true)
    ledgify(volcano_tiles, volcano_tiles, "volcano1", "lava1_", "volcano", "volcano1")
    for raw_tile in SourceJavaHashOrder.values(volcano_tiles):
        var tile := raw_tile as SourceTile
        if tile.name_upper == "soot1":
            tile.set_names(tile.name_upper)
    level_tiles.clear()
    level_tiles.merge(volcano_tiles, true)
    var current_level := -5
    for raw_tile in SourceJavaHashOrder.values(level_tiles):
        tile_levels[raw_tile] = current_level
    for _index in range(5):
        add_mountain_layer(level_tiles, tile_levels, volcano_tiles, current_level, "volcano1", volcano_route, false, level_tiles_capacity)
        current_level += 1
    add_mountain_layer(level_tiles, tile_levels, volcano_tiles, current_level, "mountain3", volcano_route, false, level_tiles_capacity)
    add_mountain_layer(level_tiles, tile_levels, volcano_tiles, current_level, "mountain3", volcano_route, false, level_tiles_capacity)
    all_mountain_tiles.merge(volcano_tiles, true)
    _smooth_mountain_levels(all_mountain_tiles, tile_levels)
    _assign_mountain_ledges(all_mountain_tiles, tile_levels)
    var biome_tiles: Dictionary = {}
    _biome_tiles = biome_tiles
    for raw_tile in all_mountain_tiles.values():
        _biome_read_cells[(raw_tile as SourceTile).position] = true
    var placement_bound := int(ceil(float(maximum_distance) / 500.0))
    for raw_tile in SourceJavaHashOrder.values(all_mountain_tiles):
        var tile := raw_tile as SourceTile
        if random.next_int(placement_bound) != 1:
            continue
        var distance := Vector2(tile.position).distance_to(Vector2(origin_tile.position))
        var level := int(30.0 * (1.0 - Vector2(tile.position).distance_to(Vector2(origin)) / float(int(radius / 12))))
        level = maxi(level, 4)
        if int(tile_levels[tile]) <= current_level:
            level = 10
        elif level > 30:
            level = 30
        if distance < float(maximum_distance / 40):
            # The source divides by zero when the peak itself is drawn (about
            # 1 new world in 60, size S, to 1 in 112): a blotch of size 2^31
            # then grew until memory ran out and the world never came. The
            # peak now counts as one tile away; nothing else changes.
            var snow_size := 7 * int(float(maximum_distance) / maxf(distance, 16.0))
            apply_blotch("mtn_snow1", tile, snow_size, biome_tiles, 0, false, SourceRoute.new("snow1", level))
        else:
            apply_blotch("mtn_green1", tile, maximum_distance / 240, biome_tiles, 0, false, SourceRoute.new("mountain1", level))
    _biome_tiles = {}
    _biome_read_cells = {}
    for raw_tile in SourceJavaHashOrder.values(all_mountain_tiles):
        var tile := raw_tile as SourceTile
        if not no_ice_here.has(tile.position):
            var rotated := SourceLibGDXMath.rotate_deg(Vector2(tile.position), 45.0)
            var offset_y := float(int(absf(rotated.y / 12.0)) % 14 - 7)
            var offset_x := float(int(absf(rotated.x / 12.0 - rotated.y / 12.0)) % 14 - 7)
            var offset_1 := absf(offset_x) + absf(offset_y)
            offset_y = float(absi(int(absf(rotated.y / 12.0)) % 20 - 10))
            offset_x = float(absi(int(absf(rotated.x / 12.0)) % 20 - 10))
            if offset_1 * ((offset_x + offset_y) / 5.0) > 14.0:
                tile.set_names("mountain4", tile.name_upper)
        if random.next_int(24) == 0 and not biome_tiles.has(tile.position):
            var rock_route: SourceRoute = null
            if random.next_int(2) == 0:
                rock_route = SourceRoute.new("", 22)
                _append_stored(rock_route, ["slugma", "geodude", "shuckle"], rock_route.level, 3)
            biome_tiles[tile.position] = SourceTile.new(tile.name, tile.position, "rock1_color", true, rock_route)
        if tile.name == "mountain3":
            var rotated := SourceLibGDXMath.rotate_deg(Vector2(tile.position), -15.0)
            var offset_y := float(int(absf(rotated.y / 8.0)) % 14 - 7)
            var offset_x := fmod(float(int(absf(rotated.x / 8.0))) - offset_y * 2.0, 14.0) - 7.0
            var offset_1 := absf(offset_x) + absf(offset_y)
            offset_y = float(absi(int(absf(rotated.y / 8.0)) % 20 - 10))
            offset_x = float(absi(int(absf(rotated.x / 8.0)) % 20 - 10))
            if offset_1 * ((offset_x + offset_y) / 5.0) > 16.0:
                tile.set_names("mountain6", tile.name_upper)
    biome_tiles.merge(volcano_tiles, true)
    for raw_tile in SourceJavaHashOrder.values(all_mountain_tiles):
        var mountain_tile := raw_tile as SourceTile
        if int(tile_levels[mountain_tile]) <= bottom_level:
            bottom_mountain_layer[mountain_tile.position] = true
            var remaining := int(no_ice_here.get(mountain_tile.position, 0)) - 1
            if remaining > 0:
                no_ice_here[mountain_tile.position] = remaining
            else:
                no_ice_here.erase(mountain_tile.position)
            mountain_tile.is_bottom_mtn_layer = true
            continue
        var biome_tile := biome_tiles.get(mountain_tile.position) as SourceTile
        if biome_tile == null:
            continue
        if mountain_tile.name_upper == "":
            all_mountain_tiles[biome_tile.position] = biome_tile
            continue
        mountain_tile.name = biome_tile.name
        mountain_tile.biome = biome_tile.biome
        if "grass3" in mountain_tile.name:
            mountain_tile.name = "snow1"
        elif "grass2" in mountain_tile.name:
            mountain_tile.name = "green1"
        if "ledges3" in mountain_tile.name_upper and "tundra" in mountain_tile.biome:
            mountain_tile.name_upper = mountain_tile.name_upper.replace("ledges3", "ledges3snow")
        elif "ledges3" in mountain_tile.name_upper and "volcano" in mountain_tile.name:
            mountain_tile.name_upper = mountain_tile.name_upper.replace("ledges3", "ledges3volcano")
        mountain_tile.set_names(mountain_tile.name, mountain_tile.name_upper)
    ledgify(all_mountain_tiles, all_mountain_tiles, "mountain4", "mountain3", "mountain")
    mountain_tiles = all_mountain_tiles
    tiles_to_add.merge(all_mountain_tiles, true)
    return endpoints

func _smooth_mountain_levels(all_tiles: Dictionary, tile_levels: Dictionary) -> void:
    # Same Gauss-Seidel sweeps as the source, on packed data: every tile's
    # level lives in one slot per tile object (a tile object can sit under
    # several keys) and its 8 neighbours are resolved once, not per sweep.
    var graph := _mountain_level_graph(all_tiles, tile_levels)
    var order: PackedInt32Array = graph[0]
    var neighbours: PackedInt32Array = graph[1]
    var levels: PackedInt64Array = graph[2]
    var tiles: Array = graph[3]
    var changed := PackedByteArray()
    changed.resize(levels.size())
    var count := order.size()
    var done := false
    while not done:
        done = true
        for index in count:
            var slot := order[index]
            var level := levels[slot]
            var base := index * 8
            var s_left := neighbours[base]
            var s_right := neighbours[base + 1]
            var s_bottom := neighbours[base + 2]
            var s_top := neighbours[base + 3]
            var s_top_left := neighbours[base + 4]
            var s_top_right := neighbours[base + 5]
            var s_bottom_left := neighbours[base + 6]
            var s_bottom_right := neighbours[base + 7]
            var left: int = INFINITE_LEVEL if s_left < 0 else levels[s_left]
            var right: int = INFINITE_LEVEL if s_right < 0 else levels[s_right]
            var bottom: int = INFINITE_LEVEL if s_bottom < 0 else levels[s_bottom]
            var top: int = INFINITE_LEVEL if s_top < 0 else levels[s_top]
            var top_left: int = INFINITE_LEVEL if s_top_left < 0 else levels[s_top_left]
            var top_right: int = INFINITE_LEVEL if s_top_right < 0 else levels[s_top_right]
            var bottom_left: int = INFINITE_LEVEL if s_bottom_left < 0 else levels[s_bottom_left]
            var bottom_right: int = INFINITE_LEVEL if s_bottom_right < 0 else levels[s_bottom_right]
            var below := level - 1
            var lower := (left < below or right < below or bottom < below or top < below
                or top_right < below or top_left < below or bottom_left < below or bottom_right < below)
            if not lower:
                lower = (
                    (left <= below and right <= below)
                    or (top <= below and bottom <= below)
                    or (top <= below and left <= below and bottom_right <= below)
                    or (top <= below and right <= below and bottom_left <= below)
                    or (bottom <= below and right <= below and top_left <= below)
                    or (bottom <= below and left <= below and top_right <= below)
                    or (bottom == level and left <= below and bottom_right <= below)
                    or (bottom == level and right <= below and bottom_left <= below)
                    or (top == level and left <= below and top_right <= below)
                    or (top == level and right <= below and top_left <= below)
                    or (right == level and top <= below and bottom_right <= below)
                    or (right == level and bottom <= below and top_right <= below)
                    or (left == level and bottom <= below and top_left <= below)
                    or (left == level and top <= below and bottom_left <= below)
                )
            if lower:
                levels[slot] = below
                changed[slot] = 1
                done = false
    for slot in levels.size():
        if changed[slot] != 0:
            tile_levels[tiles[slot]] = levels[slot]

const INFINITE_LEVEL := 2147483647

## [order, neighbours, levels, tiles]: order[i] is the level slot of the i-th
## value of all_tiles; neighbours[i * 8 + k] the slot of its k-th neighbour
## (left, right, bottom, top, top-left, top-right, bottom-left, bottom-right;
## -1 when absent); levels[slot] its level (INFINITE_LEVEL when unset);
## tiles[slot] the tile object.
func _mountain_level_graph(all_tiles: Dictionary, tile_levels: Dictionary) -> Array:
    var values := all_tiles.values()
    var count := values.size()
    var slot_by_id: Dictionary = {}
    var tiles: Array = []
    var levels := PackedInt64Array()
    var order := PackedInt32Array()
    order.resize(count)
    for index in count:
        var tile := values[index] as SourceTile
        var id := tile.get_instance_id()
        var slot: int = slot_by_id.get(id, -1)
        if slot < 0:
            slot = tiles.size()
            slot_by_id[id] = slot
            tiles.append(tile)
            levels.append(int(tile_levels[tile]) if tile_levels.has(tile) else INFINITE_LEVEL)
        order[index] = slot
    var offsets: Array[Vector2i] = [
        Vector2i(-16, 0), Vector2i(16, 0), Vector2i(0, -16), Vector2i(0, 16),
        Vector2i(-16, 16), Vector2i(16, 16), Vector2i(-16, -16), Vector2i(16, -16)]
    var neighbours := PackedInt32Array()
    neighbours.resize(count * 8)
    for index in count:
        var position := (values[index] as SourceTile).position
        for k in 8:
            var neighbour := all_tiles.get(position + offsets[k]) as SourceTile
            neighbours[index * 8 + k] = -1 if neighbour == null else int(slot_by_id[neighbour.get_instance_id()])
    return [order, neighbours, levels, tiles]

func _assign_mountain_ledges(all_tiles: Dictionary, tile_levels: Dictionary) -> void:
    var graph := _mountain_level_graph(all_tiles, tile_levels)
    var order: PackedInt32Array = graph[0]
    var neighbours: PackedInt32Array = graph[1]
    var levels: PackedInt64Array = graph[2]
    var tiles: Array = graph[3]
    for index in order.size():
        var tile := tiles[order[index]] as SourceTile
        var level := int(tile_levels[tile])
        var base := index * 8
        var left: int = INFINITE_LEVEL if neighbours[base] < 0 else levels[neighbours[base]]
        var right: int = INFINITE_LEVEL if neighbours[base + 1] < 0 else levels[neighbours[base + 1]]
        var bottom: int = INFINITE_LEVEL if neighbours[base + 2] < 0 else levels[neighbours[base + 2]]
        var top: int = INFINITE_LEVEL if neighbours[base + 3] < 0 else levels[neighbours[base + 3]]
        var top_left: int = INFINITE_LEVEL if neighbours[base + 4] < 0 else levels[neighbours[base + 4]]
        var top_right: int = INFINITE_LEVEL if neighbours[base + 5] < 0 else levels[neighbours[base + 5]]
        var bottom_left: int = INFINITE_LEVEL if neighbours[base + 6] < 0 else levels[neighbours[base + 6]]
        var bottom_right: int = INFINITE_LEVEL if neighbours[base + 7] < 0 else levels[neighbours[base + 7]]
        var suffix := ""
        if left == level and bottom == level - 1 and right == level:
            suffix = "N"
        elif top == level and right == level and bottom == level - 1 and left == level - 1:
            suffix = "NE"
        elif top == level and left == level - 1 and bottom == level:
            suffix = "E"
        elif top == level - 1 and left == level - 1 and right == level and bottom == level:
            suffix = "SE"
        elif top == level - 1 and left == level and right == level:
            suffix = "S"
        elif top == level - 1 and bottom == level and left == level and right == level - 1:
            suffix = "SW"
        elif top == level and bottom == level and right == level - 1:
            suffix = "W"
        elif top == level and left == level and bottom == level - 1 and right == level - 1:
            suffix = "NW"
        elif bottom_right == level - 1 and bottom == level and right == level:
            suffix = "NW_inner"
        elif bottom_left == level - 1 and bottom == level and left == level:
            suffix = "NE_inner"
        elif top_right == level - 1 and top == level and right == level:
            suffix = "SW_inner"
        elif top_left == level - 1 and top == level and left == level:
            suffix = "SE_inner"
        if suffix != "":
            tile.set_names(tile.name, "ledges3_" + suffix)

func is_path_between(layer: Dictionary, tile_a: SourceTile, tile_b: SourceTile) -> bool:
    var check_tiles: Array = [tile_a]
    var already_checked: Dictionary = {}
    while not check_tiles.is_empty():
        var tile := check_tiles.pop_front() as SourceTile
        if tile != null and tile.position == tile_b.position:
            return true
        if tile != tile_a and (tile == null or (tile.is_solid and "pokeball" not in tile.name_upper) or already_checked.has(tile.position)):
            continue
        already_checked[tile.position] = true
        check_tiles.append(layer.get(tile.position + Vector2i(-16, 0)))
        check_tiles.append(layer.get(tile.position + Vector2i(16, 0)))
        check_tiles.append(layer.get(tile.position + Vector2i(0, -16)))
        check_tiles.append(layer.get(tile.position + Vector2i(0, 16)))
    return false

func river_contains(position: Vector2i) -> bool:
    var scale := 60.0
    var ratio := (
        (-INF if position.x < 0 else INF)
        if position.y == 0
        else SourceLibGDXMath.float32(
            float(position.x) / float(position.y))
    )
    return _source_river_product(position, scale, ratio) > 850.0

func _source_river_product(
        position: Vector2i, scale_value: float, ratio: float
    ) -> float:
    var river_angle := SourceLibGDXMath.float32(
        -rad_to_deg(atan(ratio)))
    var rotated := SourceLibGDXMath.rotate_deg(Vector2(position), river_angle)
    var scale := SourceLibGDXMath.float32(scale_value)
    var wavelength_product := SourceLibGDXMath.float32(
        scale * SourceLibGDXMath.float32(4.0))
    var sine_input := SourceLibGDXMath.float32(
        SourceLibGDXMath.float32(rotated.x) / wavelength_product)
    var offset_3 := SourceLibGDXMath.float32(
        SourceLibGDXMath.float32(sin(sine_input))
        * SourceLibGDXMath.float32(4.0))
    var scaled_y := SourceLibGDXMath.float32(
        SourceLibGDXMath.float32(rotated.y) / scale)
    var shifted_y := SourceLibGDXMath.float32(scaled_y - offset_3)
    var offset_1 := SourceLibGDXMath.float32(
        absf(float(posmod(int(shifted_y), 14) - 7)) * 2.0)
    var offset_2 := SourceLibGDXMath.float32(
        absf(float(posmod(int(shifted_y), 20) - 10)) * 2.0)
    return SourceLibGDXMath.float32(SourceLibGDXMath.float32(
        offset_1 * 5.0) * offset_2)

func ledgify(
        tiles: Dictionary,
        next_island_tiles: Dictionary,
        tile_type: String,
        replace_with: String,
        biome_name: String,
        null_type := "black1"
    ) -> void:
    var ledge_type := "ledges3volcano" if "volcano" in tile_type else "ledges3"
    # A missing neighbour reads as a fresh tile of null_type.
    var null_name := SourceTile.new(null_type, Vector2i.ZERO).name
    # First of the source's sweeps; it repeats them until one replaces nothing.
    var changed: Array[Vector2i] = []
    # Ocean cells are never tile_type and never become it here: skipped.
    for raw_tile in next_island_tiles.values():
        if raw_tile is int:
            continue
        var tile := raw_tile as SourceTile
        if tile.name == tile_type and _ledgify_replaces(tiles, tile.position, tile_type, null_name):
            _ledgify_replace(tiles, next_island_tiles, tile.position, replace_with, biome_name)
            changed.append(tile.position)
    if not changed.is_empty():
        _ledgify_later_sweeps(tiles, next_island_tiles, changed, tile_type, replace_with, biome_name, null_name)
    for raw_tile in next_island_tiles.values():
        if raw_tile is int:
            continue
        var candidate := raw_tile as SourceTile
        var current: Variant = tiles.get(candidate.position)
        if current == null or current is int or (current as SourceTile).name != tile_type:
            continue
        var tile := current as SourceTile
        var names := _neighbour_names(tiles, tile.position, null_name)
        var left := names[0] == tile_type
        var right := names[1] == tile_type
        var up := names[2] == tile_type
        var down := names[3] == tile_type
        var top_left := names[4] == tile_type
        var top_right := names[5] == tile_type
        var bottom_left := names[6] == tile_type
        var bottom_right := names[7] == tile_type
        var suffix := ""
        if left and not down and right: suffix = "_N"
        elif up and right and not down and not left: suffix = "_NE"
        elif up and not left and down: suffix = "_E"
        elif not up and not left and right and down: suffix = "_SE"
        elif not up and left and right: suffix = "_S"
        elif not up and down and left and not right: suffix = "_SW"
        elif up and down and not right: suffix = "_W"
        elif up and left and not down and not right: suffix = "_NW"
        elif not bottom_right and down and right: suffix = "_NW_inner"
        elif not bottom_left and down and left: suffix = "_NE_inner"
        elif not top_right and up and right: suffix = "_SW_inner"
        elif not top_left and up and left: suffix = "_SE_inner"
        if suffix != "":
            var ledge := SourceTile.new(tile_type, tile.position, ledge_type + suffix)
            ledge.biome = biome_name
            tiles[tile.position] = ledge

## The source's verdict for the tile at `position` in one ledgify sweep.
func _ledgify_replaces(tiles: Dictionary, position: Vector2i, tile_type: String, null_name: String) -> bool:
    var current: Variant = tiles.get(position)
    if current != null and _name_of(current) != tile_type:
        return false
    var names := _neighbour_names(tiles, position, null_name)
    var left_same := names[0] == tile_type
    var right_same := names[1] == tile_type
    var up_same := names[2] == tile_type
    var down_same := names[3] == tile_type
    var top_left_same := names[4] == tile_type
    var top_right_same := names[5] == tile_type
    var bottom_left_same := names[6] == tile_type
    var bottom_right_same := names[7] == tile_type
    return (
        (not left_same and not right_same)
        or (not up_same and not down_same)
        or not (up_same or left_same or bottom_right_same)
        or not (up_same or right_same or bottom_left_same)
        or not (down_same or right_same or top_left_same)
        or not (down_same or left_same or top_right_same)
        or (down_same and not left_same and not bottom_right_same)
        or (down_same and not right_same and not bottom_left_same)
        or (up_same and not left_same and not top_right_same)
        or (up_same and not right_same and not top_left_same)
        or (right_same and not up_same and not bottom_right_same)
        or (right_same and not down_same and not top_right_same)
        or (left_same and not down_same and not top_left_same)
        or (left_same and not up_same and not bottom_left_same)
    )

func _ledgify_replace(tiles: Dictionary, next_island_tiles: Dictionary, position: Vector2i,
        replace_with: String, biome_name: String) -> void:
    var replacement := SourceTile.new(replace_with, position)
    replacement.biome = biome_name
    tiles[position] = replacement
    next_island_tiles[position] = replacement

## The source's later full sweeps, visiting only what can change. A verdict
## depends only on the names around a tile, so a tile whose 3x3 block did not
## change since its last visit keeps its "no" and is skipped. Each sweep still
## visits tiles in entry order, so the order-dependent result is the same.
func _ledgify_later_sweeps(tiles: Dictionary, next_island_tiles: Dictionary, changed: Array[Vector2i],
        tile_type: String, replace_with: String, biome_name: String, null_name: String) -> void:
    var keys := next_island_tiles.keys()
    # Where each key sits in `keys`: a packed grid over the keys' 16-pixel
    # cells (a Dictionary of every key held ~35 MB at once on a size M map),
    # any key off that grid in `off_grid`.
    var low := Vector2i(2147483647, 2147483647)
    var high := -low
    for index in keys.size():
        var key: Variant = keys[index]
        var entry: Variant = next_island_tiles[key]
        if not key is Vector2i or (not entry is int and (entry as SourceTile).position != key):
            # Entries away from their own key: run the plain full sweeps.
            var done := false
            while not done:
                done = true
                for raw_tile in next_island_tiles.values():
                    if raw_tile is int:
                        continue
                    var tile := raw_tile as SourceTile
                    if tile.name == tile_type and _ledgify_replaces(tiles, tile.position, tile_type, null_name):
                        _ledgify_replace(tiles, next_island_tiles, tile.position, replace_with, biome_name)
                        done = false
            return
        var cell := Vector2i((key as Vector2i).x >> 4, (key as Vector2i).y >> 4)
        low = low.min(cell)
        high = high.max(cell)
    var bounds := Rect2i(low, high - low + Vector2i.ONE) if low.x <= high.x else Rect2i()
    var grid := PackedInt32Array()
    grid.resize(bounds.size.x * bounds.size.y)
    grid.fill(-1)
    var off_grid: Dictionary = {}
    for index in keys.size():
        var key: Vector2i = keys[index]
        if (key.x & 15) != 0 or (key.y & 15) != 0:
            off_grid[key] = index
        else:
            grid[((key.y >> 4) - bounds.position.y) * bounds.size.x + (key.x >> 4) - bounds.position.x] = index
    var queued := PackedByteArray()
    queued.resize(keys.size())
    var heap: Array[int] = []
    for position in changed:
        for offset in BLOCK_OFFSETS_9:
            var index := _key_index(grid, bounds, off_grid, position + offset)
            if index >= 0 and queued[index] == 0:
                queued[index] = 1
                _heap_push(heap, index)
    while not heap.is_empty():
        var next_sweep: Array[int] = []
        while not heap.is_empty():
            var index := _heap_pop(heap)
            queued[index] = 0
            var position: Vector2i = keys[index]
            if _name_of(next_island_tiles[position]) != tile_type or not _ledgify_replaces(tiles, position, tile_type, null_name):
                continue
            _ledgify_replace(tiles, next_island_tiles, position, replace_with, biome_name)
            for offset in BLOCK_OFFSETS_9:
                var other := _key_index(grid, bounds, off_grid, position + offset)
                if other < 0:
                    continue
                if other > index:
                    if queued[other] == 0:
                        queued[other] = 1
                        _heap_push(heap, other)
                else:
                    next_sweep.append(other)
        for index in next_sweep:
            if queued[index] == 0:
                queued[index] = 1
                _heap_push(heap, index)

## The index of `position` among _ledgify_later_sweeps' keys, -1 if none.
static func _key_index(grid: PackedInt32Array, bounds: Rect2i, off_grid: Dictionary, position: Vector2i) -> int:
    if (position.x & 15) != 0 or (position.y & 15) != 0:
        return off_grid.get(position, -1)
    var cell := Vector2i(position.x >> 4, position.y >> 4)
    if not bounds.has_point(cell):
        return -1
    return grid[(cell.y - bounds.position.y) * bounds.size.x + cell.x - bounds.position.x]

const BLOCK_OFFSETS_9: Array[Vector2i] = [
    Vector2i(0, 0), Vector2i(16, 0), Vector2i(-16, 0), Vector2i(0, 16), Vector2i(0, -16),
    Vector2i(16, 16), Vector2i(-16, 16), Vector2i(-16, -16), Vector2i(16, -16)]

static func _heap_push(heap: Array[int], value: int) -> void:
    heap.append(value)
    var child := heap.size() - 1
    while child > 0:
        var parent := (child - 1) >> 1
        if heap[parent] <= value:
            break
        heap[child] = heap[parent]
        child = parent
    heap[child] = value

static func _heap_pop(heap: Array[int]) -> int:
    var top := heap[0]
    var last: int = heap.pop_back()
    var count := heap.size()
    if count == 0:
        return top
    var parent := 0
    while true:
        var child := parent * 2 + 1
        if child >= count:
            break
        if child + 1 < count and heap[child + 1] < heap[child]:
            child += 1
        if heap[child] >= last:
            break
        heap[parent] = heap[child]
        parent = child
    heap[parent] = last
    return top

## Names of the 8 neighbours: left, right, up, down, top-left, top-right,
## bottom-left, bottom-right (up is +y); null_name where there is no tile.
func _neighbour_names(tiles: Dictionary, position: Vector2i, null_name: String) -> PackedStringArray:
    var names := PackedStringArray()
    names.resize(8)
    for index in 8:
        var tile: Variant = tiles.get(position + LEDGIFY_OFFSETS[index])
        if tile == null: names[index] = null_name
        elif tile is int: names[index] = ocean_tiles[tile].name
        else: names[index] = tile.name
    return names

const LEDGIFY_OFFSETS: Array[Vector2i] = [
    Vector2i(-16, 0), Vector2i(16, 0), Vector2i(0, 16), Vector2i(0, -16),
    Vector2i(-16, 16), Vector2i(16, 16), Vector2i(-16, -16), Vector2i(16, -16)]

# Exact recursive-growth dispatcher for the leaf blotch types. Keeping these
# in the same four-neighbour loop preserves the source random-call order.
func apply_leaf_blotch(
        blotch_type: String,
        origin_tile: SourceTile,
        maximum_distance: int,
        tiles_to_add: Dictionary,
        current_route: SourceRoute = null
    ) -> void:
    var supported := [
        "grass", "grass_sand", "grass_desert1", "sand_pit1",
        "ruins1_upper2", "pond1", "desert_cacti1", "desert_cacti2",
        "desert_cacti3", "desert_cacti4"
    ]
    assert(blotch_type in supported or blotch_type.begins_with("grass_"))
    var edge_tiles: Dictionary = {origin_tile.position: origin_tile}
    var edge_capacity_high_water := edge_tiles.size()
    # ApplyBlotch consumes this draw for every type, even where newSize is not
    # subsequently used. sand_pit1 then overwrites the value.
    var new_size := maximum_distance - random.next_int(int(ceil(float(maximum_distance) / 4.0))) - int(maximum_distance / 4)
    if blotch_type == "sand_pit1":
        new_size = maximum_distance
    while not edge_tiles.is_empty():
        for tile: SourceTile in SourceJavaHashOrder.values(
                edge_tiles, edge_capacity_high_water):
            for offset: Vector2i in [
                    Vector2i(-16, 0), Vector2i(16, 0),
                    Vector2i(0, 16), Vector2i(0, -16)]:
                var position: Vector2i = tile.position + offset
                if tiles_to_add.has(position):
                    continue
                var distance := Vector2(position).distance_to(Vector2(origin_tile.position))
                var put_tile := random.next_int(maximum_distance) + int(distance)
                var forced := int(distance) < 7 * maximum_distance / 16
                if blotch_type in ["sand_pit1"]:
                    forced = int(distance) < 10 * maximum_distance / 16
                if put_tile >= maximum_distance and not forced:
                    continue
                var new_tile := _leaf_blotch_tile(blotch_type, position, distance, maximum_distance, origin_tile, current_route)
                tiles_to_add[position] = new_tile
                edge_tiles[position] = new_tile
                edge_capacity_high_water = maxi(
                    edge_capacity_high_water, edge_tiles.size()
                )
            edge_tiles.erase(tile.position)

func _leaf_blotch_tile(
        blotch_type: String,
        position: Vector2i,
        distance: float,
        maximum_distance: int,
        origin_tile: SourceTile,
        current_route: SourceRoute
    ) -> SourceTile:
    if blotch_type == "grass":
        var tile_name := "grass4" if current_route != null and ("savanna" in current_route.name or "oasis" in current_route.name) else "grass2"
        var tile := SourceTile.new(tile_name, position, "", false, current_route)
        if int(distance) < 3 * maximum_distance / 8 and maximum_distance > 300:
            tile.biome = "deep_forest"
        return tile
    if blotch_type == "grass_sand":
        var tile := SourceTile.new("grass_sand1", position, "", false, current_route)
        tile.biome = origin_tile.biome
        return tile
    if blotch_type == "grass_desert1":
        if distance < float(2 * maximum_distance / 3):
            return SourceTile.new("grass_sand3", position, "", true, current_route)
        return SourceTile.new("desert4", position)
    if blotch_type.begins_with("grass_"):
        return SourceTile.new(blotch_type, position, "", false, current_route)
    if blotch_type == "sand_pit1":
        if distance < float(2 * maximum_distance / 3):
            if random.next_int(256) < 8:
                trapinch_spawns.append(position)
            return SourceTile.new("desert2", position, "", true, current_route)
        return SourceTile.new("desert4", position)
    if blotch_type == "ruins1_upper2":
        if random.next_int(3) > 0:
            return SourceTile.new("ruins1_NSEW", position, "", true, current_route)
        return SourceTile.new("desert4", position)
    if blotch_type == "pond1":
        return SourceTile.new("water2", position, "", true, current_route)
    if blotch_type == "desert_cacti1":
        var new_tile := SourceTile.new("desert4", position)
        var do_cactus := true
        if distance > 0.0:
            do_cactus = random.next_int(int(distance)) < maximum_distance / 8
        if do_cactus:
            var temporary_route: SourceRoute = null
            if random.next_int(2) == 0:
                temporary_route = SourceRoute.new("", 22)
                # The one-element source array still consumes nextInt(1).
                var pokemon := ["maractus"]
                var pokemon_index := random.next_int(pokemon.size())
                temporary_route.stored_pokemon.append(_make_pokemon_record(
                    String(pokemon[pokemon_index]), temporary_route.level,
                    {"generation": "CRYSTAL"}
                ))
            if distance < float(maximum_distance / 4):
                new_tile = SourceTile.new("cactus2", position, "", true, temporary_route)
            elif position.x != origin_tile.position.x or position.y != origin_tile.position.y + 16:
                new_tile = SourceTile.new("cactus1", position, "", true, temporary_route)
        return new_tile
    if blotch_type == "desert_cacti3":
        var new_tile := SourceTile.new("desert4", position, "", true, current_route)
        var do_cactus := true
        if distance > 0.0:
            do_cactus = random.next_int(int(distance)) < maximum_distance / 8
        if do_cactus:
            if distance < float(maximum_distance / 4):
                new_tile = SourceTile.new("desert6", position, "cactus9", true)
            else:
                new_tile = SourceTile.new("desert6", position, "cactus8", true)
        return new_tile
    if blotch_type == "desert_cacti4":
        var new_tile := SourceTile.new("desert4", position, "", true, current_route)
        if random.next_int(int(float(maximum_distance) - distance)) < maximum_distance:
            if distance < float(maximum_distance / 4):
                if random.next_int(2) == 1:
                    new_tile = SourceTile.new("desert6", position, "cactus7", true)
            else:
                new_tile = SourceTile.new("desert6", position, "cactus7", true)
        return new_tile
    # desert_cacti2's source branch intentionally contains an empty if block.
    return SourceTile.new("desert4", position, "", true, current_route)

# Ordered port of GenIsland1.ApplyBlotch. The original routine uses one
# breadth-first frontier for every biome. This entry point deliberately keeps
# that common traversal instead of composing independently seeded noise passes.
func apply_blotch(
        blotch_type: String,
        origin_tile: SourceTile,
        maximum_distance: int,
        tiles_to_add: Dictionary,
        is_maze := 0,
        do_next := true,
        current_route: SourceRoute = null
    ) -> void:
    var edge_tiles: Dictionary = {origin_tile.position: origin_tile}
    var edge_capacity_high_water := edge_tiles.size()
    # An island blotch straight on tiles_to_add, before the mountain overlay.
    var stand_in := not _under_mountain.is_empty() and is_same(tiles_to_add, self.tiles_to_add)
    var size_before := tiles_to_add.size()
    var mountain_biome := is_same(tiles_to_add, _biome_tiles)
    var previous_tiles: Array[SourceTile] = []
    var previous_tile := origin_tile
    var grass_tiles: Dictionary = {}
    if blotch_type != "beach1":
        is_maze = 1
    var forest_maze_tiles: Dictionary = {}
    var deep_forest_maze_tiles: Array[Vector2i] = []
    var fence_spawns: Array[Vector2i] = []
    var new_size := maximum_distance - random.next_int(int(ceil(float(maximum_distance) / 4.0))) - int(maximum_distance / 4)
    if blotch_type == "sand_pit1":
        new_size = maximum_distance
    var state := {
        "done_oasis": maximum_distance,
        "num_darms": 10,
        "grass_tiles": grass_tiles,
        "forest_maze_tiles": forest_maze_tiles,
        "deep_forest_maze_tiles": deep_forest_maze_tiles,
        "fence_spawns": fence_spawns,
        "beach_route": null,
        "beach_plateau_route": null,
        "beach_water_route": null,
        "deep_forest_route": null,
        "is_maze": is_maze
    }
    if blotch_type == "island":
        state["beach_route"] = SourceRoute.new("", 2)
        state["deep_forest_route"] = SourceRoute.new("deep_forest", 33)
    elif blotch_type == "beach1":
        state["beach_route"] = SourceRoute.new("beach2_rocks", 22)
        state["beach_plateau_route"] = SourceRoute.new("beach2_plateau", 22)
        state["beach_water_route"] = SourceRoute.new("beach2_water", 22)
    elif blotch_type == "mtn_green1":
        state["beach_route"] = SourceRoute.new("mountain1_water1", 30)
    elif blotch_type == "wooded_lake1":
        state["beach_route"] = SourceRoute.new("wooded_lake_water1", 30)

    # Same thresholds as the source's per-edge chain, decided once per blotch.
    var put_sixteenths := 7
    if blotch_type in ["desert", "sand_pit1", "graveyard1"]:
        put_sixteenths = 10
    elif blotch_type == "beach1":
        put_sixteenths = 12
    elif "volcano" in blotch_type:
        put_sixteenths = 10
    elif "island" in blotch_type:
        put_sixteenths = 8
    elif blotch_type == "wooded_lake1":
        put_sixteenths = 12
    var put_limit := put_sixteenths * maximum_distance / 16
    var leaf_blotch := blotch_type in [
            "grass", "grass_sand", "grass_desert1", "sand_pit1",
            "ruins1_upper2", "pond1", "desert_cacti1", "desert_cacti2",
            "desert_cacti3", "desert_cacti4"] or blotch_type.begins_with("grass_")
    var origin_vector := Vector2(origin_tile.position)
    var previous_distance := Vector2(previous_tile.position).distance_to(origin_vector)
    while not edge_tiles.is_empty():
        for raw_tile in edge_tiles.values():
            var tile := raw_tile as SourceTile
            var tile_position := tile.position
            for edge_offset in BLOTCH_EDGE_OFFSETS:
                var edge := tile_position + edge_offset
                if tiles_to_add.has(edge):
                    continue
                var distance := SourceLibGDXMath.distance(Vector2(edge), origin_vector)
                if (_qa_trace_frontier
                        and random.trace_count() >= 3118
                        and random.trace_count() <= 3140):
                    var frontier_positions: Array[String] = []
                    for frontier_tile: SourceTile in SourceJavaHashOrder.values(
                            edge_tiles, edge_capacity_high_water):
                        frontier_positions.append("%d,%d" % [
                            frontier_tile.position.x, frontier_tile.position.y])
                    print("GODOT_FRONTIER beforeDraw=%d tile=%s edge=%s size=%d peak=%d values=%s" % [
                        random.trace_count(), str(tile.position), str(edge),
                        edge_tiles.size(), edge_capacity_high_water,
                        ";".join(frontier_positions)
                    ])
                var put_tile := random.next_int(maximum_distance) + int(distance)
                if put_tile >= maximum_distance and int(distance) >= put_limit:
                    continue
                var new_tile: SourceTile
                if leaf_blotch:
                    new_tile = _leaf_blotch_tile(blotch_type, edge, distance, maximum_distance, origin_tile, current_route)
                else:
                    new_tile = _make_blotch_tile(
                        blotch_type, tile, edge, distance, maximum_distance,
                        origin_tile, current_route, tiles_to_add, state)
                if new_tile == null:
                    continue
                if mountain_biome and not _biome_read_cells.has(new_tile.position):
                    tiles_to_add[new_tile.position] = true
                else:
                    tiles_to_add[new_tile.position] = new_tile
                edge_tiles[new_tile.position] = new_tile
                edge_capacity_high_water = maxi(
                    edge_capacity_high_water, edge_tiles.size()
                )
            var tile_distance := Vector2(tile_position).distance_to(origin_vector)
            if (tile_distance > previous_distance
                    and tile.name not in ["sand1", "rock1", "tree5"]):
                previous_tile = tile
                previous_distance = tile_distance
                # Newest first, as the source's push_front (reversed below).
                previous_tiles.append(tile)
            edge_tiles.erase(tile_position)
    previous_tiles.reverse()

    for raw_grass in SourceJavaHashOrder.values(grass_tiles):
        var grass := raw_grass as SourceTile
        var existing := tiles_to_add.get(grass.position) as SourceTile
        if existing != null and not existing.is_solid:
            tiles_to_add[grass.position] = grass
    # The recursion below (_continue_blotch) can be deep: the grass tiles not
    # placed would live through it.
    grass_tiles.clear()
    if is_maze != 0 and not forest_maze_tiles.is_empty():
        _apply_forest_maze(tiles_to_add, forest_maze_tiles, deep_forest_maze_tiles, state)
    if blotch_type == "graveyard1":
        _place_graveyard_fences(tiles_to_add, fence_spawns, current_route)
    stand_in = stand_in and tiles_to_add.size() != size_before
    if stand_in:
        _stand_in_under_mountain()
    _continue_blotch(
        blotch_type, maximum_distance, new_size, previous_tiles,
        tiles_to_add, is_maze, do_next, current_route, forest_maze_tiles)
    if stand_in:
        _stand_in_under_mountain()

func _make_blotch_tile(
        blotch_type: String,
        frontier_tile: SourceTile,
        edge: Vector2i,
        distance: float,
        maximum_distance: int,
        origin_tile: SourceTile,
        current_route: SourceRoute,
        tiles_to_add: Dictionary,
        state: Dictionary
    ) -> SourceTile:
    # Leaf blotch types are dispatched by apply_blotch directly.
    match blotch_type:
        "desert":
            return _make_desert_tile(edge, distance, maximum_distance, current_route, state)
        "island":
            return _make_island_tile(edge, distance, maximum_distance, current_route, state)
        "ruins1_upper":
            return _make_ruins_upper_tile(edge, distance, maximum_distance, current_route, state)
        "oasis1":
            return _make_oasis_tile(edge, distance, maximum_distance, current_route, state)
        "beach1":
            return _make_beach_tile(edge, distance, maximum_distance, current_route, state)
        "savanna1":
            return _make_savanna_tile(edge, current_route)
        "graveyard1":
            if river_contains(frontier_tile.position):
                return null
            return _make_graveyard_tile(edge, distance, maximum_distance, current_route, state)
        "mtn_snow1":
            return _make_snow_tile(edge, current_route, tiles_to_add)
        "volcano1_lava":
            return _make_volcano_lava_tile(
                frontier_tile, edge, current_route, tiles_to_add)
        "volcano1":
            return _make_volcano_tile(edge, current_route)
        "wooded_lake1":
            return _make_wooded_lake_tile(edge, current_route, state)
        "mtn_green1":
            return _make_green_mountain_tile(edge, current_route, state)
    assert(false, "Unsupported GenIsland1 blotch type: " + blotch_type)
    return null

func _append_stored(route: SourceRoute, names: Array, base_level: int, jitter := 0) -> void:
    var selected := String(names[random.next_int(names.size())])
    route.stored_pokemon.append(_make_pokemon_record(
        selected,
        base_level + (random.next_int(jitter) if jitter > 0 else 0),
        {"generation": "CRYSTAL"}
    ))

func _spawn(position: Vector2i, name: String, level: int, extra := {}) -> void:
    var record := _make_pokemon_record(name, level, extra)
    record["position"] = position
    pokemon_to_add[position] = record

func _make_pokemon_record(name: String, level: int, extra := {}) -> Dictionary:
    if OS.get_environment("POKEWILDS_QA_TRACE_POKEMON") == "1":
        _qa_pokemon_sequence += 1
        print("SOURCE_POKEMON_EVENT=%d:new:%s:%d" % [
            _qa_pokemon_sequence, name.to_lower(), level
        ])
    var record := {
        "name": name,
        "level": level,
        "shiny": pokemon_random.next_int(256) == 0
    }
    var gender_ratio := String(
        PokemonData.info(name).get("gender_ratio", "GENDER_UNKNOWN")
    )
    if gender_ratio == "GENDER_UNKNOWN":
        record["gender"] = "unknown"
    else:
        var female_threshold: int = int({
            "GENDER_F0": 0,
            "GENDER_F12_5": 125,
            "GENDER_F25": 250,
            "GENDER_F50": 500,
            "GENDER_F75": 750,
            "GENDER_F100": 1000
        }.get(gender_ratio, 0))
        record["gender"] = (
            "female" if pokemon_random.next_int(1000) < female_threshold
            else "male"
        )
    record.merge(extra, true)
    return record

func _make_desert_tile(
        edge: Vector2i,
        _distance: float,
        maximum_distance: int,
        current_route: SourceRoute,
        state: Dictionary
    ) -> SourceTile:
    var new_tile := SourceTile.new("desert4", edge, "", true, current_route)
    new_tile.biome = "desert"
    var grass_tiles := state["grass_tiles"] as Dictionary
    if random.next_int(maximum_distance) < 6:
        apply_blotch("desert_cacti2", new_tile, 200, grass_tiles, 0, false, current_route)
        var next_size := random.next_int(40) + 20
        var new_tiles: Dictionary = {}
        apply_blotch("desert_cacti1", new_tile, next_size, new_tiles, 0, false, current_route)
        grass_tiles.merge(new_tiles, true)
    elif random.next_int(maximum_distance) < 3:
        var next_size := 30 + random.next_int(20)
        var new_tiles: Dictionary = {}
        apply_blotch("desert_cacti3", new_tile, next_size, new_tiles, 0, false, current_route)
        grass_tiles.merge(new_tiles, true)
    elif random.next_int(maximum_distance) < 3:
        new_tile = SourceTile.new("desert4", edge, "cactus10", true, current_route)
    elif random.next_int(maximum_distance) < 3:
        new_tile = SourceTile.new("desert4", edge, "desert4_cracked", true, current_route)
    elif random.next_int(maximum_distance) < 3:
        num_sand_pits = 0
        new_tile = SourceTile.new("desert2_trapinch_spawn", edge, "", true, current_route)
        var new_tiles: Dictionary = {}
        apply_blotch("sand_pit1", new_tile, 45, new_tiles, 0, true, SourceRoute.new("sand_pit1", 44))
        grass_tiles.merge(new_tiles, true)
    else:
        var rotated := SourceLibGDXMath.rotate_deg(Vector2(edge), 45.0)
        var offset_y := float(posmod(int(rotated.y / 30.0), 14) - 7)
        var offset_x := float(posmod(int(rotated.x / 30.0 - rotated.y / 30.0), 14) - 7)
        var offset_1 := absf(offset_x) + absf(offset_y)
        offset_y = float(posmod(int(rotated.y / 30.0), 20) - 10)
        offset_x = float(posmod(int(rotated.x / 30.0), 20) - 10)
        var offset_2 := (absf(offset_x) + absf(offset_y)) / 5.0
        if offset_1 * offset_2 > 45.0:
            var upper := "berrytree_rawst_full" if random.next_int(10) < 5 else ""
            new_tile = SourceTile.new("desert4", edge, upper, true, current_route)
    if done_desert < 2:
        done_desert = 2
    state["done_oasis"] = int(state["done_oasis"]) - 1
    return new_tile

func _make_ruins_upper_tile(
        edge: Vector2i,
        distance: float,
        maximum_distance: int,
        current_route: SourceRoute,
        state: Dictionary
    ) -> SourceTile:
    var new_tile := SourceTile.new("desert4", edge)
    if distance < float(2 * maximum_distance / 5):
        var put_tile := random.next_int(maximum_distance) + int(distance)
        if put_tile < maximum_distance:
            new_tile = SourceTile.new("ruins1", edge, "", true, current_route)
        elif edge.y % 32 == 0 and edge.x % 64 == 0:
            new_tile = SourceTile.new("ruins1_pillar1", edge, "", true, current_route)
    elif distance < float(3 * maximum_distance / 5):
        if random.next_int(20) > 10 and edge.y % 32 == 0 and edge.x % 64 == 0:
            new_tile = SourceTile.new(
                "ruins1_pillar1_broken" if random.next_int(20) > 9 else "ruins1_pillar1",
                edge, "", true, current_route)
        elif random.next_int(20) > int(state["num_darms"]) and edge.y % 32 == 0 and edge.x % 32 == 0:
            _spawn(new_tile.position, "darmanitanzen", 35, {"generation": "CRYSTAL"})
            state["num_darms"] = int(state["num_darms"]) + 1
    elif random.next_int(10) > 4:
        new_tile = SourceTile.new("grass_sand3", edge, "", true, current_route)
        var new_tiles: Dictionary = {}
        apply_blotch("grass_desert1", new_tile, 95, new_tiles, 0, true, current_route)
        (state["grass_tiles"] as Dictionary).merge(new_tiles, true)
        if random.next_int(2) > 0:
            new_tile = SourceTile.new("grass_sand3", edge, "", true, current_route)
            new_tiles = {}
            if random.next_int(2) > 0:
                apply_blotch("desert_cacti1", new_tile, random.next_int(40) + 20, new_tiles, 0, true, current_route)
            else:
                apply_blotch("desert_cacti3", new_tile, 30 + random.next_int(20), new_tiles, 0, false, current_route)
            (state["grass_tiles"] as Dictionary).merge(new_tiles, true)
    return new_tile

func _make_oasis_tile(
        edge: Vector2i,
        distance: float,
        maximum_distance: int,
        current_route: SourceRoute,
        state: Dictionary
    ) -> SourceTile:
    var new_tile := SourceTile.new("sand1", edge, "", true, current_route)
    var is_grass := random.next_int(int(maximum_distance / 8)) + int(distance)
    if is_grass < maximum_distance / 2:
        if int(distance) < 3 * maximum_distance / 8:
            new_tile = SourceTile.new("flower4" if random.next_int(24) == 0 else "green1", edge, "", true, current_route)
        else:
            new_tile = SourceTile.new("green1", edge, "", true, current_route)
    var put_grass := random.next_int(90) < 1
    if distance < float(maximum_distance / 2):
        put_grass = random.next_int(40) < 1
    var put_rock := false
    if distance > float(maximum_distance / 2):
        put_rock = random.next_int(10) < 1
    if put_grass:
        apply_blotch("grass", new_tile, 40, state["grass_tiles"], 0, false, SourceRoute.new("oasis1", 30))
    elif random.next_int(10) < 1:
        var route := SourceRoute.new("oasis1", 22)
        if random.next_int(2) == 0:
            _append_stored(route, ["aexeggutor"], route.level)
        new_tile = SourceTile.new("tree5", edge, "", true, route)
    elif random.next_int(110) < 1:
        new_tile = SourceTile.new("green1", edge, "aloe_large1", true, current_route)
    elif put_rock:
        var route := SourceRoute.new("oasis1", 22)
        if random.next_int(2) == 0:
            _append_stored(route, ["shellder", "krabby", "staryu", "dwebble"], route.level)
        new_tile = SourceTile.new(new_tile.name, edge, "rock1_color", true, route)
    return new_tile

func _make_island_tile(
        edge: Vector2i,
        distance: float,
        maximum_distance: int,
        current_route: SourceRoute,
        state: Dictionary
    ) -> SourceTile:
    var beach_route := state["beach_route"] as SourceRoute
    # The default sand tile is usually replaced: made only when read.
    var new_tile: SourceTile = null
    var is_rock := random.next_int(maximum_distance) + int(distance)
    if is_rock > maximum_distance + maximum_distance / 2:
        var rock_route: SourceRoute = null
        var random_value := random.next_int(3)
        if random_value == 2:
            rock_route = SourceRoute.new("", 11)
            _append_stored(rock_route, ["shellder", "krabby", "staryu", "dwebble"], 11, 3)
        new_tile = SourceTile.new("rock1", edge, "", true, rock_route)
    var is_grass := random.next_int(int(maximum_distance / 8)) + int(distance)
    if distance < float(8 * maximum_distance / 16):
        if int(distance) < 3 * maximum_distance / 8:
            new_tile = SourceTile.new("flower4" if random.next_int(24) == 0 else "green1", edge, "", true, current_route)
        elif distance > float(15 * maximum_distance / 32):
            var rotated := SourceLibGDXMath.rotate_deg(Vector2(edge), -15.0)
            var offset_y := int(absf(rotated.y / 8.0)) % 14 - 7
            var offset_x := (int(absf(rotated.x / 8.0)) - offset_y * 2) % 14 - 7
            var offset_1 := absi(offset_x) + absi(offset_y)
            offset_y = absi(int(absf(rotated.y / 8.0)) % 20 - 10)
            offset_x = absi(int(absf(rotated.x / 8.0)) % 20 - 10)
            var offset_2 := int((offset_x + offset_y) / 5)
            if offset_1 * offset_2 > 6:
                new_tile = SourceTile.new("green1", edge, "", true, current_route)
        else:
            new_tile = SourceTile.new("green1", edge, "", true, current_route)
        var pattern := _diagonal_pattern(edge, 30.0)
        if float(pattern.x) * (float(pattern.y) / 5.0) > 42.0:
            var upper := ""
            var tree_route := current_route
            if random.next_int(10) < 5:
                upper = "berrytree_persim_full"
                if random.next_int(6) == 0:
                    tree_route = SourceRoute.new("", 22)
                    _append_stored(tree_route, ["sudowoodo"], 20, 4)
            if new_tile == null:
                new_tile = SourceTile.new("sand1", edge, "", true, beach_route)
            new_tile = SourceTile.new(new_tile.name, edge, upper, true, tree_route)
    elif is_rock <= maximum_distance + maximum_distance / 2 and is_grass < maximum_distance - maximum_distance / 4 and random.next_int(40) == 0:
        var tree_route := SourceRoute.new("", 11)
        var random_value := random.next_int(5)
        if random_value == 4:
            tree_route.stored_pokemon.append(_make_pokemon_record(
                "Exeggutor", 10 + random.next_int(4),
                {"generation": "CRYSTAL"}))
        elif random_value > 1:
            tree_route.stored_pokemon.append(_make_pokemon_record(
                "Exeggcute", 10 + random.next_int(4),
                {"generation": "CRYSTAL"}))
        if random.next_int(2) == 0:
            if new_tile == null:
                new_tile = SourceTile.new("sand1", edge, "", true, beach_route)
            apply_blotch("grass_sand", new_tile, 35, state["grass_tiles"], 0, false, SourceRoute.new("beach1", 3))
        if random.next_int(10) == 0:
            var is_unown := unown_counter % 64 == 0
            unown_counter += 1
            new_tile = SourceTile.new("sand1", edge, "sign1", true, tree_route)
            new_tile.has_item = "trainer_tips_unown" if is_unown else "trainer_tips"
        else:
            new_tile = SourceTile.new("tree5", edge, "", true, tree_route)
    elif is_rock <= maximum_distance + maximum_distance / 2 and is_grass < maximum_distance - maximum_distance / 4 and random.next_int(200) == 0:
        if new_tile == null:
            new_tile = SourceTile.new("sand1", edge, "", true, beach_route)
        new_tile = SourceTile.new(new_tile.name, edge, "pokeball1", true, current_route)
    elif is_rock <= maximum_distance + maximum_distance / 2 and is_grass < maximum_distance - maximum_distance / 4 and random.next_int(450) == 0:
        var level := _source_scaled_level(
            30 if maximum_distance > 300 else 15, distance, maximum_distance)
        level = maxi(level, 4)
        var spawn_route: SourceRoute
        if int(distance) < 2 * maximum_distance / 8 and maximum_distance > 600:
            spawn_route = SourceRoute.new("deep_forest", level)
        elif int(distance) < 3 * maximum_distance / 8:
            spawn_route = SourceRoute.new("forest1", level)
        else:
            spawn_route = SourceRoute.new("savanna1", level)
        var allowed := spawn_route.allowed_pokemon()
        if not allowed.is_empty():
            var pokemon_name := String(allowed[random.next_int(allowed.size())])
            _spawn(edge, pokemon_name, spawn_route.level + random.next_int(3), {
                "generation": "CRYSTAL",
                "happiness": 0 if pokemon_name.to_lower() in ["ekans", "pidgey", "spearow", "rattata"] else 70
            })
            if SourceForestGenerator.MATES_2.has(pokemon_name.to_lower()):
                _spawn(edge + Vector2i(16, 0), String(SourceForestGenerator.MATES_2[pokemon_name.to_lower()]), spawn_route.level)
    else:
        var pattern := _diagonal_pattern(edge, 30.0)
        if float(pattern.x) * (float(pattern.y) / 5.0) > 39.0:
            var upper := ""
            var tree_route := current_route
            if random.next_int(10) < 5:
                upper = "berrytree_pecha_full"
                if random.next_int(6) == 0:
                    tree_route = SourceRoute.new("", 22)
                    _append_stored(tree_route, ["sudowoodo"], 20, 4)
            if new_tile == null:
                new_tile = SourceTile.new("sand1", edge, "", true, beach_route)
            new_tile = SourceTile.new(new_tile.name, edge, upper, true, tree_route)
    if distance < float(maximum_distance / 4) and maximum_distance > 300 and random.next_int(750) == 0:
        var level := _source_scaled_level(
            50 if maximum_distance > 300 else 15, distance, maximum_distance)
        level = maxi(level, 4)
        var names := SourceForestGenerator.MATES.keys()
        var parent_name := String(names[global_random.next_int(names.size())])
        _spawn(edge, parent_name, level)
        _spawn(edge + Vector2i(16, 0), String(SourceForestGenerator.MATES[parent_name]), level)
    if int(state["is_maze"]) == 0:
        var is_tree := random.next_int(int(maximum_distance / 4)) + int(distance)
        if is_tree < maximum_distance / 3 and edge.y % 32 == 0:
            new_tile = SourceTile.new("tree2", edge)
    elif int(distance) + random.next_int(int(maximum_distance / 14) + 1) < 8 * maximum_distance / 16:
        if new_tile == null:
            new_tile = SourceTile.new("sand1", edge, "", true, beach_route)
        # Positions only: a tile here would outlive its replacement.
        (state["forest_maze_tiles"] as Dictionary)[new_tile.position] = true
    if new_tile == null:
        new_tile = SourceTile.new("sand1", edge, "", true, beach_route)
    var grass_here := random.next_int(int(maximum_distance / 4)) + int(distance)
    var grass_here_2 := random.next_int(maximum_distance)
    var grass_here_3 := random.next_int(maximum_distance)
    if (int(distance) < maximum_distance - maximum_distance / 5
            and grass_here < 3 * maximum_distance / 7
            and grass_here_2 < maximum_distance / 4
            and (maximum_distance < 300 or grass_here_3 < maximum_distance / 8)):
        var next_size := int(ceil(float(maximum_distance) / 6.0))
        if maximum_distance > 300:
            next_size = int(ceil(float(maximum_distance) / 12.0))
        if maximum_distance > 1000:
            next_size = int(ceil(float(maximum_distance) / 32.0))
        var level := _source_scaled_level(
            30 if maximum_distance > 300 else 15, distance, maximum_distance)
        level = maxi(level, 4)
        var grass_route: SourceRoute
        if int(distance) < 2 * maximum_distance / 8 and maximum_distance > 600:
            grass_route = state["deep_forest_route"] as SourceRoute
        elif int(distance) < 4 * maximum_distance / 8:
            grass_route = SourceRoute.new("forest1", level)
        else:
            grass_route = SourceRoute.new("savanna1", level)
        apply_blotch("grass", new_tile, next_size, state["grass_tiles"], 0, false, grass_route)
    if int(distance) < 2 * maximum_distance / 8 and maximum_distance > 300:
        new_tile.biome = "deep_forest"
        (state["deep_forest_maze_tiles"] as Array).append(new_tile.position)
    return new_tile

func _source_scaled_level(
        center_level: int, distance: float, maximum_distance: int
    ) -> int:
    var denominator := SourceLibGDXMath.float32(
        float(2 * maximum_distance / 5))
    var ratio := SourceLibGDXMath.float32(
        SourceLibGDXMath.float32(distance) / denominator)
    var factor := SourceLibGDXMath.float32(
        SourceLibGDXMath.float32(1.0) - ratio)
    return int(SourceLibGDXMath.float32(
        SourceLibGDXMath.float32(float(center_level)) * factor))

func _diagonal_pattern(position: Vector2i, scale: float) -> Vector2i:
    var rotated := SourceLibGDXMath.rotate_deg(Vector2(position), 45.0)
    var source_scale := SourceLibGDXMath.float32(scale)
    # Vector2 components are floats: built from these quotients they are the
    # float-rounded values the source computes.
    var scaled := Vector2(rotated.x / source_scale, rotated.y / source_scale)
    var scaled_y := scaled.y
    var scaled_x := scaled.x
    var diagonal := SourceLibGDXMath.float32(scaled_x - scaled_y)
    var offset_y := int(absf(scaled_y)) % 14 - 7
    var offset_x := int(absf(diagonal)) % 14 - 7
    var offset_1 := absi(offset_x) + absi(offset_y)
    offset_y = absi(int(absf(scaled_y)) % 20 - 10)
    offset_x = absi(int(absf(scaled_x)) % 20 - 10)
    return Vector2i(offset_1, offset_x + offset_y)

func _make_beach_tile(
        edge: Vector2i,
        distance: float,
        maximum_distance: int,
        current_route: SourceRoute,
        state: Dictionary
    ) -> SourceTile:
    var tile_name := "sand4_tidalwater"
    var upper := ""
    var tile_route := current_route
    if distance > float(5 * maximum_distance / 9):
        tile_name = "water2"
        tile_route = state["beach_water_route"] as SourceRoute
    var rotated := SourceLibGDXMath.rotate_deg(Vector2(edge), 45.0)
    var offset_y := int(absf(rotated.y / 16.0)) % 14 - 7
    var offset_x := int(absf(rotated.x / 16.0)) % 14 - 7
    var offset_1 := absi(offset_x) + absi(offset_y)
    offset_y = absi(int(absf(rotated.y / 16.0)) % 20 - 10)
    offset_x = absi(int(absf(rotated.x / 16.0)) % 20 - 10)
    var offset_2 := offset_x + offset_y
    offset_y = absi(int(absf(rotated.y / 16.0)) % 60 - 30)
    offset_x = absi(int(absf(rotated.x / 16.0)) % 60 - 30)
    var offset_3 := (offset_x + offset_y) * 2
    if offset_1 * int(offset_2 / 5) * offset_3 <= 320:
        tile_name = "mountain4"
        if offset_1 < 2:
            tile_name = "water2"
        elif offset_2 < 7:
            upper = "stalagmite1"
        tile_route = state["beach_route"] if offset_3 >= 30 else state["beach_plateau_route"]
    offset_y = int(absf(rotated.y / 16.0)) % 14 - 7
    offset_x = int(absf(rotated.x / 16.0)) % 14 - 7
    offset_1 = absi(offset_x) + absi(offset_y)
    offset_y = absi(int(absf(rotated.y / 16.0)) % 20 - 10)
    offset_x = absi(int(absf(rotated.x / 16.0)) % 20 - 10)
    offset_2 = int((offset_x + offset_y) / 5)
    if offset_1 * offset_2 > 16:
        tile_name = "water2"
    elif tile_name not in ["water2", "mountain4"] and offset_1 * offset_2 < 13 and offset_1 * offset_2 > 9:
        tile_name += "_puddle1"
    if "sand4" in tile_name and upper == "":
        if random.next_int(50) == 0:
            upper = "tree6"
        elif random.next_int(50) == 0:
            tile_name = "rock1"
    elif tile_name == "mountain4" and upper == "":
        var rate := 20 if offset_3 < 30 else 5
        if random.next_int(rate) == 0:
            upper = "rock5"
        elif random.next_int(rate) == 0:
            upper = "rock1_color"
    var new_tile := SourceTile.new(tile_name, edge, upper, true, tile_route)
    new_tile.biome = "beach"
    if random.next_int(70) < 1:
        apply_blotch("grass_sand", new_tile, 40, state["grass_tiles"], 0, false, current_route)
    return new_tile

func _make_savanna_tile(edge: Vector2i, current_route: SourceRoute) -> SourceTile:
    var tile_name := "green_savanna1"
    var upper := ""
    var tile_route := current_route
    var rotated := SourceLibGDXMath.rotate_deg(Vector2(edge), -15.0)
    var offset_y := int(absf(rotated.y / 8.0)) % 14 - 7
    var offset_x := (int(absf(rotated.x / 8.0)) - offset_y * 2) % 14 - 7
    var offset_1 := absi(offset_x) + absi(offset_y)
    offset_y = absi(int(absf(rotated.y / 8.0)) % 20 - 10)
    offset_x = absi(int(absf(rotated.x / 8.0)) % 20 - 10)
    var offset_2 := offset_x + offset_y
    if offset_1 * int(offset_2 / 5) > 6:
        tile_name = "green_savanna3"
        if random.next_int(5) == 0:
            tile_name = "green_savanna4" if edge.x % 32 == 0 else "green_savanna5"
    elif offset_1 * offset_2 < 8:
        tile_name = "sand1"
    rotated = Vector2(edge)
    offset_y = absi(int(absf(rotated.y / 12.0)) % 60 - 30)
    offset_x = absi(int(absf(rotated.y / 12.0)) % 34 - 12)
    var offset_3 := int((offset_x + offset_y) / 2)
    offset_y = int(absf(rotated.y / 12.0)) % 14 - 7
    offset_x = int(absf(rotated.x / 12.0 - float(offset_3))) % 14 - 7
    offset_1 = absi(offset_x) + absi(offset_y)
    offset_y = absi(int(absf(rotated.y / 12.0)) % 20 - 10)
    offset_x = absi(int(absf(rotated.x / 12.0 - float(offset_3))) % 20 - 10)
    offset_2 = offset_x + offset_y
    if offset_1 * int(offset_2 / 5) > 16:
        upper = "grass_savanna1"
    elif offset_1 * int(offset_2 / 5) > 14:
        upper = "grass_savanna2"
    elif offset_1 * offset_2 < 1:
        upper = "tree_savanna1"
    elif random.next_int(50) == 0:
        upper = "bush_savanna1"
    else:
        var pattern := _diagonal_pattern(edge, 16.0)
        if pattern.x * int(pattern.y / 5) > 36 and random.next_int(10) < 4:
            upper = "berrytree_cheri_full"
            if random.next_int(6) == 0:
                tile_route = SourceRoute.new("", 22)
                _append_stored(tile_route, ["sudowoodo"], 20, 4)
    var new_tile := SourceTile.new(tile_name, edge, upper, true, tile_route)
    new_tile.biome = "savanna"
    return new_tile

func _make_graveyard_tile(
        edge: Vector2i,
        distance: float,
        maximum_distance: int,
        current_route: SourceRoute,
        state: Dictionary
    ) -> SourceTile:
    var tile_name := "green12"
    var upper := ""
    var tile_route := current_route
    var rotated := SourceLibGDXMath.rotate_deg(Vector2(edge), -15.0)
    var offset_y := int(absf(rotated.y / 8.0)) % 14 - 7
    var offset_x := (int(absf(rotated.x / 8.0)) - offset_y * 2) % 14 - 7
    var offset_1 := absi(offset_x) + absi(offset_y)
    offset_y = absi(int(absf(rotated.y / 8.0)) % 20 - 10)
    offset_x = absi(int(absf(rotated.x / 8.0)) % 20 - 10)
    var offset_2 := int((offset_x + offset_y) / 5)
    if offset_1 * offset_2 > 6:
        tile_name = "green11"
        if random.next_int(5) == 0:
            tile_name = "green10" if random.next_boolean() else "green9"
    elif offset_1 < 2:
        if random.next_int(256) < 80:
            tile_name = "flower5"
    elif random.next_int(15) == 0:
        tile_name = "flower5"
    if tile_name != "flower5" and random.next_int(110) == 0:
        var random_value := random.next_int(3)
        if random_value == 0:
            upper = "tree8"
            if random.next_int(3) == 2:
                tile_route = SourceRoute.new("", 30)
                _append_stored(tile_route, ["trevenant"], tile_route.level, 4)
        elif random_value == 1:
            upper = "berrytree_chesto_full"
            if random.next_int(6) == 0:
                tile_route = SourceRoute.new("", 22)
                _append_stored(tile_route, ["sudowoodo"], 20, 4)
        else:
            upper = "tree9"
            if random.next_int(3) == 2:
                tile_route = SourceRoute.new("", 30)
                _append_stored(tile_route, ["phantump"], 10, 4)
    if (fmod(float(edge.y) / 16.0, 2.0)
            == float(int(fmod(float(edge.y) / 32.0, 11.0) / 5.0))
            and fmod(float(edge.x) / 16.0, 2.0)
            == float(int(fmod(
                float(edge.x) / 16.0 + float(edge.y) / 2.0, 13.0
            ) / 5.0))):
        rotated = Vector2(edge)
        offset_y = int(absf(rotated.y / 16.0)) % 14 - 7
        offset_x = int(absf(rotated.x / 16.0 - rotated.y / 16.0)) % 14 - 7
        offset_1 = absi(offset_x) + absi(offset_y)
        offset_y = absi(int(absf(rotated.y / 16.0)) % 20 - 10)
        offset_x = absi(int(absf(rotated.x / 16.0)) % 20 - 10)
        offset_2 = int((offset_x + offset_y) / 5)
        if offset_1 * offset_2 > 9:
            tile_name = "green12"
            upper = "gravestone2"
    var new_tile := SourceTile.new(tile_name, edge, upper, true, tile_route)
    var put_grass := random.next_int(90) < 1
    if distance > float(maximum_distance / 2):
        put_grass = random.next_int(40) < 1
    if put_grass:
        apply_blotch("grass_graveyard1", new_tile, 40, state["grass_tiles"], 0, false, current_route)
    new_tile.biome = "graveyard"
    if offset_1 < 1:
        (state["fence_spawns"] as Array).append(edge)
    return new_tile

func _make_snow_tile(edge: Vector2i, current_route: SourceRoute, tiles_to_add: Dictionary) -> SourceTile:
    var tile_name := "snow5" if edge.x % 32 == edge.y % 32 else "snow6"
    var upper := ""
    var tile_route := current_route
    # libGDX Vector2.rotate(-15) is degree-based; Godot uses radians.
    var rotated := SourceLibGDXMath.rotate_deg(Vector2(edge), -15.0)
    var offset_y := float(int(absf(rotated.y / 8.0)) % 14 - 7)
    var offset_x := fmod(float(int(absf(rotated.x / 8.0))) - offset_y * 2.0, 14.0) - 7.0
    var offset_1 := absf(offset_x) + absf(offset_y)
    offset_y = float(absi(int(absf(rotated.y / 8.0)) % 20 - 10))
    offset_x = float(absi(int(absf(rotated.x / 8.0)) % 20 - 10))
    var offset_2 := offset_x + offset_y
    if offset_1 * (offset_2 / 5.0) > 16.0:
        tile_name = "snow2"
    rotated = Vector2(edge)
    offset_y = float(absi(int(absf(rotated.y / 12.0)) % 60 - 30))
    offset_x = float(absi(int(absf(rotated.y / 12.0)) % 34 - 12))
    var offset_3 := (offset_x + offset_y) / 2.0
    offset_y = float(int(absf(rotated.y / 12.0)) % 14 - 7)
    offset_x = float(int(absf(rotated.x / 12.0 - offset_3)) % 14 - 7)
    offset_1 = absf(offset_x) + absf(offset_y)
    offset_y = float(absi(int(absf(rotated.y / 12.0)) % 20 - 10))
    offset_x = float(absi(int(absf(rotated.x / 12.0 - offset_3)) % 20 - 10))
    offset_2 = offset_x + offset_y
    if offset_1 * (offset_2 / 5.0) > 16.0:
        tile_name = "snow3"
    if not no_ice_here.has(edge):
        rotated = Vector2(edge + Vector2i(256, 256))
        offset_3 = sin(rotated.y / 80.0) * 3.0
        offset_y = absf(fmod(absf(rotated.y / 40.0), 14.0) - 7.0)
        offset_x = absf(fmod(absf(rotated.x / 40.0 - offset_3), 14.0) - 7.0)
        offset_1 = offset_x + offset_y
        offset_y = absf(fmod(absf(rotated.y / 40.0), 20.0) - 10.0)
        offset_x = absf(fmod(absf(rotated.x / 40.0 - offset_3), 20.0) - 10.0)
        offset_2 = offset_x + offset_y
        if offset_1 * 5.0 * offset_2 > 500.0:
            tile_name = "ice2"
    if tile_name == "ice2":
        if random.next_int(18) == 0:
            upper = "rock_ice2"
        elif random.next_int(56) == 0:
            tile_name = "water6"
            upper = "ice2_pit1"
            if edge.x % 32 == 0 and random.next_int(4) == 0:
                upper = "ice2_pit2"
                for offset in [Vector2i(16, 0), Vector2i(0, 16), Vector2i(16, 16)]:
                    var solid_tile := SourceTile.new(tile_name, edge + offset, "solid", true, current_route)
                    solid_tile.biome = "tundra"
                    tiles_to_add[solid_tile.position] = solid_tile
    else:
        var pattern := _diagonal_pattern(edge, 12.0)
        if float(pattern.x) * (float(pattern.y) / 5.0) > 14.0:
            if random.next_int(5) < 3:
                tile_name = "snow2"
                upper = "tree4"
                if random.next_int(3) == 2:
                    tile_route = SourceRoute.new("", 22)
                    _append_stored(tile_route, ["snover"], 20, 4)
            tile_route.dont_spawn_overworlds = true
        else:
            pattern = _diagonal_pattern(edge, 30.0)
            if float(pattern.x) * (float(pattern.y) / 5.0) < 1.0 and random.next_int(10) < 4:
                upper = "berrytree_aspear_full"
                if random.next_int(6) == 0:
                    tile_route = SourceRoute.new("", 22)
                    _append_stored(tile_route, ["sudowoodo"], 20, 4)
    var new_tile := SourceTile.new(tile_name, edge, upper, true, tile_route)
    new_tile.biome = "tundra"
    return new_tile

func _make_volcano_lava_tile(
        frontier_tile: SourceTile,
        edge: Vector2i,
        current_route: SourceRoute,
        tiles_to_add: Dictionary
    ) -> SourceTile:
    var tile_name := "lava1"
    var rotated := SourceLibGDXMath.rotate_deg(
        Vector2(frontier_tile.position + rand_offset), 45.0)
    var offset_y := float(int(absf(rotated.y / 12.0)) % 14 - 7)
    var offset_x := float(int(absf(rotated.x / 12.0 - rotated.y / 12.0)) % 14 - 7)
    var offset_1 := absf(offset_x) + absf(offset_y)
    offset_y = float(absi(int(absf(rotated.y / 12.0)) % 20 - 10))
    offset_x = float(absi(int(absf(rotated.x / 12.0)) % 20 - 10))
    if offset_1 * ((offset_x + offset_y) / 5.0) > 22.0:
        tile_name = "volcano2"
    var new_tile := SourceTile.new(tile_name, edge, "", true, current_route)
    new_tile.biome = "volcano"
    # The source calls adjustSurroundingTiles before inserting newTile. The
    # call therefore normalizes already-present neighbouring lava, not this
    # newly constructed tile. Preserve both that timing and its Game.rand use.
    for x_offset in range(-16, 17, 16):
        for y_offset in range(-16, 17, 16):
            var existing := tiles_to_add.get(
                edge + Vector2i(x_offset, y_offset)) as SourceTile
            if existing != null:
                _normalize_bare_lava(existing)
    return new_tile

func _normalize_bare_lava(tile: SourceTile) -> void:
    if "lava" not in tile.name or not tile.name_upper.is_empty():
        return
    var extension := "_"
    var columns := ["S", "", "N"]
    var rows := ["W", "", "E"]
    if global_random.next_int(3) != 0:
        if global_random.next_boolean():
            extension += String(columns[global_random.next_int(3)])
            extension += String(rows[int(posmod(tile.position.x, 48) / 16)])
        else:
            extension += String(columns[int(posmod(tile.position.y, 48) / 16)])
            extension += String(rows[global_random.next_int(3)])
    tile.set_names("lava1" + extension, tile.name_upper)

func _make_volcano_tile(edge: Vector2i, current_route: SourceRoute) -> SourceTile:
    var upper := ""
    var tile_route := current_route
    var shifted := edge + rand_offset
    var rotated := Vector2(shifted)
    var offset_y := float(absi(int(absf(rotated.y / 12.0)) % 60 - 30))
    var offset_x := float(absi(int(absf(rotated.y / 12.0)) % 34 - 12))
    var offset_3 := (offset_x + offset_y) / 2.0
    offset_y = float(int(absf(rotated.y / 12.0)) % 14 - 7)
    offset_x = float(int(absf(rotated.x / 12.0 - offset_3)) % 14 - 7)
    var offset_1 := absf(offset_x) + absf(offset_y)
    offset_y = float(absi(int(absf(rotated.y / 12.0)) % 20 - 10))
    offset_x = float(absi(int(absf(rotated.x / 12.0 - offset_3)) % 20 - 10))
    if offset_1 * ((offset_x + offset_y) / 5.0) > 16.0:
        upper = "soot1"
    var pattern := _diagonal_pattern(shifted, 12.0)
    if (OS.get_environment("POKEWILDS_QA_TRACE_VOLCANO") == "1"
            and random.trace_count() >= 3120 and random.trace_count() <= 3140):
        var source_rotated := SourceLibGDXMath.rotate_deg(Vector2(shifted), 45.0)
        print("GODOT_VOLCANO_BRANCH draw=%d edge=%s shifted=%s rotated=%s pattern=%s product=%.9f" % [
            random.trace_count(), str(edge), str(shifted), str(source_rotated),
            str(pattern), float(pattern.x) * (float(pattern.y) / 5.0)
        ])
    if float(pattern.x) * (float(pattern.y) / 5.0) > 14.0 and random.next_int(5) == 0:
        upper = "rock_volcano1"
    if random.next_int(50) == 0:
        upper = "rock1_color"
        if random.next_int(2) == 0:
            tile_route = SourceRoute.new("", 22)
            _append_stored(tile_route, ["slugma", "geodude"], tile_route.level, 3)
    var new_tile := SourceTile.new("volcano1", edge, upper, true, tile_route)
    new_tile.biome = "volcano"
    return new_tile

func _make_wooded_lake_tile(edge: Vector2i, current_route: SourceRoute, state: Dictionary) -> SourceTile:
    var tile_name := "green1"
    var upper := ""
    var tile_route := current_route
    if random.next_int(8) == 0:
        if random.next_boolean():
            tile_name = "flower4"
        else:
            tile_name = "flower2" if edge.x % 32 == 0 else "flower3"
    var wavy := _wavy_pattern(edge, 12.0)
    if wavy.x * (wavy.y / 5.0) > 16.0:
        tile_name = "grass4"
    var pattern := _diagonal_pattern(edge, 30.0)
    if float(pattern.x) * (float(pattern.y) / 5.0) > 8.0:
        if random.next_int(5) < 4:
            tile_name = "green1"
            upper = "tree2"
            if random.next_int(3) == 2:
                tile_route = SourceRoute.new("", 22)
                _append_stored(tile_route, [
                    "pineco", "aipom", "kakuna", "metapod", "spinarak",
                    "heracross", "ledyba", "hoothoot", "zubat", "pidgey",
                    "spearow", "forretress", "applin"
                ], 20, 4)
        tile_route.dont_spawn_overworlds = true
    pattern = _diagonal_pattern(edge, 16.0)
    if float(pattern.x) * (float(pattern.y) / 5.0) > 36.0 and random.next_int(10) < 4:
        upper = "berrytree_persim_full"
        if random.next_int(6) == 0:
            tile_route = SourceRoute.new("", 22)
            _append_stored(tile_route, ["sudowoodo"], 20, 4)
    pattern = _diagonal_pattern(edge, 60.0)
    if float(pattern.x) * (float(pattern.y) / 5.0) < 5.0:
        tile_name = "water2"
        upper = ""
        tile_route = state["beach_route"] as SourceRoute
    var new_tile := SourceTile.new(tile_name, edge, upper, true, tile_route)
    new_tile.biome = "wooded_lake"
    return new_tile

func _make_green_mountain_tile(edge: Vector2i, current_route: SourceRoute, state: Dictionary) -> SourceTile:
    var tile_name := "green1"
    var upper := ""
    var tile_route := current_route
    if random.next_int(8) == 0:
        if random.next_boolean():
            tile_name = "flower4"
        else:
            tile_name = "flower2" if edge.x % 32 == 0 else "flower3"
    # The source computes an 8-pixel pattern here and then overwrites every
    # value before testing it. It consumes no RNG and has no observable output.
    var wavy := _wavy_pattern(edge, 12.0)
    if wavy.x * (wavy.y / 5.0) > 16.0:
        tile_name = "grass2"
    var pattern := _diagonal_pattern(edge, 12.0)
    if float(pattern.x) * (float(pattern.y) / 5.0) > 14.0 and random.next_int(5) < 3:
        tile_name = "green1"
        upper = "tree2"
        if random.next_int(3) == 2:
            tile_route = SourceRoute.new("", 22)
            _append_stored(tile_route, [
                "pineco", "aipom", "kakuna", "metapod", "spinarak",
                "heracross", "ledyba", "hoothoot", "zubat", "pidgey",
                "spearow", "forretress", "applin"
            ], 20, 4)
    if not no_ice_here.has(edge):
        var shifted := Vector2(edge + Vector2i(256, 256))
        var sine_offset := sin(shifted.y / 80.0) * 3.0
        var offset_y := absf(fmod(absf(shifted.y / 40.0), 14.0) - 7.0)
        var offset_x := absf(fmod(absf(shifted.x / 40.0 - sine_offset), 14.0) - 7.0)
        var offset_1 := offset_x + offset_y
        offset_y = absf(fmod(absf(shifted.y / 40.0), 20.0) - 10.0)
        offset_x = absf(fmod(absf(shifted.x / 40.0 - sine_offset), 20.0) - 10.0)
        if offset_1 * 5.0 * (offset_x + offset_y) > 500.0:
            tile_name = "water2"
            upper = ""
            tile_route = state["beach_route"] as SourceRoute
    var new_tile := SourceTile.new(tile_name, edge, upper, true, tile_route)
    new_tile.biome = "mountain"
    return new_tile

func _wavy_pattern(position: Vector2i, scale: float) -> Vector2:
    var rotated := Vector2(position)
    var offset_y := float(absi(int(absf(rotated.y / scale)) % 60 - 30))
    var offset_x := float(absi(int(absf(rotated.y / scale)) % 34 - 12))
    var offset_3 := (offset_x + offset_y) / 2.0
    offset_y = float(int(absf(rotated.y / scale)) % 14 - 7)
    offset_x = float(int(absf(rotated.x / scale - offset_3)) % 14 - 7)
    var offset_1 := absf(offset_x) + absf(offset_y)
    offset_y = float(absi(int(absf(rotated.y / scale)) % 20 - 10))
    offset_x = float(absi(int(absf(rotated.x / scale - offset_3)) % 20 - 10))
    return Vector2(offset_1, offset_x + offset_y)

func _apply_forest_maze(
        tiles_to_add: Dictionary,
        forest_maze_tiles: Dictionary,
        deep_forest_positions: Array,
        state: Dictionary
    ) -> void:
    var bottom_left: Vector2i
    var top_right: Vector2i
    var first := true
    for position: Vector2i in forest_maze_tiles:
        if first:
            bottom_left = position
            top_right = position
            first = false
        else:
            bottom_left.x = mini(bottom_left.x, position.x)
            bottom_left.y = mini(bottom_left.y, position.y)
            top_right.x = maxi(top_right.x, position.x)
            top_right.y = maxi(top_right.y, position.y)
    top_right.x -= posmod(top_right.x, 96)
    bottom_left.x -= posmod(bottom_left.x, 96)
    top_right.y += 96 - posmod(top_right.y, 96)
    bottom_left.y += 96 - posmod(bottom_left.y, 96)
    var nodes := SourceMaze.maze_algo1(
        int((top_right.x - bottom_left.x) * 2 / 96),
        int((top_right.y - bottom_left.y) * 2 / 96),
        0.1, 0.9, 96, random)
    for node in SourceJavaHashOrder.values(nodes):
        # Only the maze cells inside the blotch become tiles.
        var square: Array
        var color := false
        if String(node.get("type", "")) == "platform1":
            square = SourceForestGenerator.get_tile_square_platform_specs(node, bottom_left, random)
        else:
            square = SourceForestGenerator.get_tile_square_specs(node, bottom_left, random)
            color = true
        var names: PackedStringArray = square[0]
        var positions: PackedVector2Array = square[1]
        for index in names.size():
            var position := Vector2i(positions[index])
            if forest_maze_tiles.has(position):
                var tile := SourceTile.new(names[index], position, "", color)
                tiles_to_add[tile.position] = tile
    if not tiles_to_add.is_empty():
        # GenForest2.ApplyForestBiome constructs a new java.util.Random for
        # every maze application. Derive a deterministic seed for each of
        # those independent streams instead of incorrectly sharing one Random
        # state across every biome pass.
        var forest_pass_random := SourceJavaRandom.new(
            forest_biome_random.next_int()
        )
        # ApplyForestBiome attaches encounters to each bush tile's Route.
        # It does not add those stored encounters to GenIsland1.pokemonToAdd;
        # that collection is reserved for actual overworld PokÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â©mon entities.
        SourceForestGenerator.apply_forest_biome(
            tiles_to_add, bottom_left, top_right, forest_pass_random, true)
    var deep_forest_set: Dictionary = {}
    for position in deep_forest_positions:
        deep_forest_set[position] = true
    for raw_tile in SourceJavaHashOrder.values(tiles_to_add):
        var tile := raw_tile as SourceTile
        var tile_name := tile.name
        if tile_name == "ledge_grass_down" or tile_name == "ledge_ramp_down":
            _repair_maze_ledge(tiles_to_add, tile, 16)
            _repair_maze_ledge(tiles_to_add, tile, -16)
        if deep_forest_set.has(tile.position):
            tile.route_belongs_to = state["deep_forest_route"] as SourceRoute
            tile.biome = "deep_forest"
            if tile.name == "grass2":
                tile.set_names("grass4", tile.name_upper)

func _repair_maze_ledge(tiles: Dictionary, tile: SourceTile, side: int) -> void:
    var adjacent_position := tile.position + Vector2i(side, 0)
    var adjacent := tiles.get(adjacent_position) as SourceTile
    if adjacent == null or adjacent.is_solid or adjacent.is_ledge:
        return
    var vertical_tiles: Dictionary = {}
    var horizontal_tiles: Dictionary = {}
    vertical_tiles[adjacent_position] = SourceTile.new("ledge1_corner_br" if side > 0 else "ledge1_corner_bl", adjacent_position, "", true)
    horizontal_tiles[adjacent_position] = SourceTile.new("ledge_grass_down", adjacent_position, "", true)
    for distance in range(16, 80, 16):
        var vertical_position := tile.position + Vector2i(side, distance)
        var vertical := tiles.get(vertical_position) as SourceTile
        if vertical != null and (vertical.is_solid or vertical.is_ledge):
            tiles.merge(vertical_tiles, true)
            break
        var horizontal_position := tile.position + Vector2i(side + signi(side) * distance, 0)
        var horizontal := tiles.get(horizontal_position) as SourceTile
        if horizontal != null and (horizontal.is_solid or horizontal.is_ledge):
            tiles.merge(horizontal_tiles, true)
            break
        vertical_tiles[vertical_position] = SourceTile.new("ledge1_right" if side > 0 else "ledge1_left", vertical_position, "", true)
        horizontal_tiles[horizontal_position] = SourceTile.new("ledge_grass_down", horizontal_position, "", true)

func _place_graveyard_fences(
        tiles_to_add: Dictionary,
        fence_spawns: Array,
        current_route: SourceRoute
    ) -> void:
    var number_of_fences := random.next_int(4) + 1
    while number_of_fences > 0 and not fence_spawns.is_empty():
        number_of_fences -= 1
        var done_doll := false
        var edge := Vector2i(fence_spawns.pop_at(random.next_int(fence_spawns.size())))
        var size := 4 + random.next_int(3)
        var left := random.next_int(size)
        var door_offset := random.next_int(2) * 16
        var number_of_doors := random.next_int(4) + 1
        var bottom_left := edge + Vector2i(-16 * left, -16 * left)
        bottom_left.x += bottom_left.x % 32
        bottom_left.y += int(
            fmod(float(bottom_left.y) / 16.0, 2.0)
            + float(int(fmod(float(bottom_left.y) / 32.0, 11.0) / 5.0))
        ) * 16
        var top_right := bottom_left + Vector2i(16 * size, 16 * size)
        top_right.x += top_right.x % 32
        top_right.y += int(
            fmod(float(top_right.y) / 16.0, 2.0)
            + float(int(fmod(float(top_right.y) / 32.0, 11.0) / 5.0))
        ) * 16
        var current := bottom_left
        while current.y <= top_right.y:
            var tile_name := "flower5"
            var upper := ""
            var replace := true
            if current == bottom_left:
                tile_name = "green12"
                upper = "fence1_NE"
            elif current == top_right:
                tile_name = "green12"
                upper = "fence1_SW"
            elif current == Vector2i(bottom_left.x, top_right.y):
                tile_name = "green12"
                upper = "fence1_SE"
            elif current == Vector2i(top_right.x, bottom_left.y):
                tile_name = "green12"
                upper = "fence1_NW"
            elif current.y == bottom_left.y or current.y == top_right.y:
                tile_name = "green12"
                upper = "fence1"
                if number_of_doors > 0 and current.x == bottom_left.x + int(size / 2) * 16 + door_offset:
                    upper = "house5_door1"
                    number_of_doors -= 1
            elif current.x == bottom_left.x or current.x == top_right.x:
                tile_name = "green12"
                upper = "fence1_NS"
                if random.next_boolean() and number_of_doors > 0 and current.y == bottom_left.y + int(size / 2) * 16 + door_offset:
                    upper = "house5_door1"
                    number_of_doors -= 1
            else:
                var existing := tiles_to_add.get(current) as SourceTile
                if existing != null:
                    if existing.name_upper != "" and current.y != bottom_left.y + 16:
                        replace = false
                    if "fence" in existing.name_upper:
                        replace = true
                if (replace and current.y % 32 == 0 and current.x != bottom_left.x + 16
                        and current.x != top_right.x - 16 and current.y != bottom_left.y + 16):
                    keystone_spawns.append(current)
                    if random.next_int(3) == 0:
                        tile_name = "green12"
                        upper = "gravestone2"
                    if not done_doll and not (size > 5 and random.next_int(3) != 0):
                        done_doll = true
                        var random_value := random.next_int(3)
                        upper = "pokedoll1_mimikyu" if random_value == 0 else ("pokedoll1_banette" if random_value == 1 else "pokedoll1")
            if replace:
                var new_tile := SourceTile.new(tile_name, current, upper, true, current_route)
                new_tile.biome = "graveyard"
                tiles_to_add[current] = new_tile
            current.x += 16
            if current.x > top_right.x:
                current.x = bottom_left.x
                current.y += 16
        graveyard_fence_bounds.append(Rect2i(bottom_left, top_right - bottom_left))
        _style_graveyard_fence_group(tiles_to_add, bottom_left, top_right)

func _style_graveyard_fence_group(
        tiles: Dictionary,
        rectangle_bottom_left: Vector2i,
        rectangle_top_right: Vector2i
    ) -> void:
    for y in range(rectangle_bottom_left.y - 16, rectangle_top_right.y + 32, 16):
        for x in range(rectangle_bottom_left.x - 16, rectangle_top_right.x + 32, 16):
            var tile := _get_tile(tiles, Vector2i(x, y))
            if (tile == null or "fence" not in tile.name_upper
                    or "house" in tile.name_upper or "gate" in tile.name_upper):
                continue
            _adjust_fence_tile(tile, tiles)
    # The grave enclosure always has visible left/right side rails. Neighbor
    # styling may run at the edge of a sparse generated group, so reassert the
    # authored vertical fence variant after styling without touching corners or
    # gate/door cells.
    for y in range(rectangle_bottom_left.y + 16, rectangle_top_right.y, 16):
        for x in [rectangle_bottom_left.x, rectangle_top_right.x]:
            var side_tile := _get_tile(tiles, Vector2i(x, y))
            if side_tile == null or "fence" not in side_tile.name_upper or \
                    "gate" in side_tile.name_upper or "door" in side_tile.name_upper:
                continue
            var fence_base := "fence2" if "fence2" in side_tile.name_upper else "fence1"
            side_tile.set_names(side_tile.name, fence_base + "_NS")

    # Auto-styling can also rewrite sparse boundary corners. Reassert the four
    # authored corner pieces so neither cemetery side is visually cut off.
    var authored_corners := {
        rectangle_bottom_left: "fence1_NE",
        rectangle_top_right: "fence1_SW",
        Vector2i(rectangle_bottom_left.x, rectangle_top_right.y): "fence1_SE",
        Vector2i(rectangle_top_right.x, rectangle_bottom_left.y): "fence1_NW"
    }
    for raw_corner in authored_corners.keys():
        var corner: Vector2i = raw_corner
        var corner_tile := _get_tile(tiles, corner)
        if corner_tile != null and "door" not in corner_tile.name_upper and \
                "gate" not in corner_tile.name_upper:
            corner_tile.set_names(corner_tile.name, String(authored_corners[corner]))

    for y in range(rectangle_bottom_left.y, rectangle_top_right.y + 16, 16):
        for x in range(rectangle_bottom_left.x, rectangle_top_right.x + 16, 16):
            var tile := _get_tile(tiles, Vector2i(x, y))
            if tile == null or "door" not in tile.name_upper:
                continue
            var left := _get_tile(tiles, tile.position + Vector2i(-16, 0))
            var right := _get_tile(tiles, tile.position + Vector2i(16, 0))
            var up := _get_tile(tiles, tile.position + Vector2i(0, 16))
            var down := _get_tile(tiles, tile.position + Vector2i(0, -16))
            if (left != null and right != null
                    and ("fence" in left.name_upper or "gate" in left.name_upper)
                    and ("fence" in right.name_upper or "gate" in right.name_upper)):
                tile.set_names(tile.name, "fence1gate1")
            elif (up != null and down != null
                    and ("fence" in up.name_upper or "gate" in up.name_upper)
                    and ("fence" in down.name_upper or "gate" in down.name_upper)):
                tile.set_names(tile.name, "fence1gate1_NS")


    # Final perimeter integrity pass. Preserve gates, but every other boundary
    # location must remain an authored visible fence even when sparse neighbor
    # styling could not infer a connection.
    for y in range(rectangle_bottom_left.y, rectangle_top_right.y + 16, 16):
        for x in range(rectangle_bottom_left.x, rectangle_top_right.x + 16, 16):
            var position: Vector2i = Vector2i(x, y)
            var on_left: bool = x == rectangle_bottom_left.x
            var on_right: bool = x == rectangle_top_right.x
            var on_bottom: bool = y == rectangle_bottom_left.y
            var on_top: bool = y == rectangle_top_right.y
            if not (on_left or on_right or on_bottom or on_top):
                continue
            var perimeter_tile: SourceTile = _get_tile(tiles, position)
            if perimeter_tile == null:
                continue
            var current_upper: String = perimeter_tile.name_upper.to_lower()
            if "gate" in current_upper or "door" in current_upper:
                continue
            var visible_fence: String = "fence1"
            if on_left and on_bottom:
                visible_fence = "fence1_NE"
            elif on_right and on_bottom:
                visible_fence = "fence1_NW"
            elif on_left and on_top:
                visible_fence = "fence1_SE"
            elif on_right and on_top:
                visible_fence = "fence1_SW"
            elif on_left or on_right:
                visible_fence = "fence1_NS"
            perimeter_tile.set_names(perimeter_tile.name, visible_fence)

func _adjust_fence_tile(tile: SourceTile, tiles: Dictionary) -> void:
    var up := _get_tile(tiles, tile.position + Vector2i(0, 16))
    var down := _get_tile(tiles, tile.position + Vector2i(0, -16))
    var right := _get_tile(tiles, tile.position + Vector2i(16, 0))
    var left := _get_tile(tiles, tile.position + Vector2i(-16, 0))
    var tokens := tile.name_upper.split("_")
    var base_name := String(tokens[0])
    for index in range(1, tokens.size() - 1):
        base_name += "_" + String(tokens[index])
    var touch_up := up != null and base_name in up.name_upper
    var touch_down := down != null and base_name in down.name_upper
    var touch_right := right != null and base_name in right.name_upper
    var touch_left := left != null and base_name in left.name_upper
    if down != null and "house" in down.name_upper:
        touch_down = true
    if left != null and "house" in left.name_upper and "roof" not in left.name_upper:
        touch_left = true
    if right != null and "house" in right.name_upper and "roof" not in right.name_upper:
        touch_right = true
    if up != null and "fence2" not in tile.name_upper and "house" in up.name_upper:
        touch_up = true
    if not (touch_up or touch_down or touch_left or touch_right):
        return
    var extension := "_"
    if touch_up: extension += "N"
    if touch_down: extension += "S"
    if touch_right: extension += "E"
    if touch_left: extension += "W"
    if touch_left and touch_right and not touch_up and not touch_down:
        extension = ""
    if (touch_up or touch_down) and not touch_left and not touch_right:
        extension = "_NS"
    if extension.length() == 2:
        extension = ""
    tile.set_names(tile.name, base_name + extension)

func _continue_blotch(
        blotch_type: String,
        maximum_distance: int,
        new_size_value: int,
        previous_tiles: Array[SourceTile],
        tiles_to_add: Dictionary,
        is_maze: int,
        do_next: bool,
        current_route: SourceRoute,
        forest_maze_tiles: Dictionary
    ) -> void:
    if new_size_value <= 0:
        return
    var new_size := new_size_value
    var values := [1, 1, 2, 3]
    var number_to_continue := int(values[random.next_int(values.size())])
    number_to_continue = mini(number_to_continue, previous_tiles.size())
    var next_island_tiles: Dictionary = {}
    var next := 0
    if blotch_type == "oasis1":
        values = [3, 3, 4, 4, 5, 5]
        number_to_continue = int(values[random.next_int(values.size())])
        number_to_continue = mini(number_to_continue, previous_tiles.size())
        new_size += maximum_distance / 10
    elif blotch_type == "sand_pit1":
        if number_to_continue > 1:
            number_to_continue = 1
        if num_sand_pits >= 20:
            new_size = 1
        else:
            num_sand_pits += 1
    elif blotch_type == "beach1":
        new_size = maximum_distance
        is_maze -= 1
        if not previous_tiles.is_empty() and is_maze > 0:
            var recursive_origin := previous_tiles[next]
            tiles_to_add[recursive_origin.position] = recursive_origin
            apply_blotch(blotch_type, recursive_origin, new_size, next_island_tiles, is_maze, true, current_route)
    if blotch_type in ["island", "desert", "oasis1", "sand_pit1", "wooded_lake1"] and do_next:
        for _index in range(number_to_continue):
            if previous_tiles.is_empty() or next >= previous_tiles.size():
                break
            var recursive_origin := previous_tiles[next]
            if done_desert == 1:
                tiles_to_add[recursive_origin.position] = recursive_origin
                apply_blotch("desert", recursive_origin, new_size + maximum_distance / 4, next_island_tiles, 1, true, SourceRoute.new("desert1", 40))
                continue
            tiles_to_add[recursive_origin.position] = recursive_origin
            var new_type := blotch_type
            if blotch_type == "desert":
                new_type = "island"
                current_route = SourceRoute.new("forest1", 40)
            elif (blotch_type != "wooded_lake1" and done_desert > 1
                    and new_type not in ["sand_pit1", "oasis1"] and random.next_int(5) == 0):
                current_route = SourceRoute.new("wooded_lake1", 40)
                new_type = "wooded_lake1"
                if new_size < 400:
                    new_size = 400
            apply_blotch(new_type, recursive_origin, new_size, next_island_tiles, 1, true, current_route)
            # Preserve the source's compound assignment exactly:
            # next += rand.nextInt(size-next) + next.
            next += random.next_int(previous_tiles.size() - next) + next
            if next >= previous_tiles.size():
                break
    if previous_tiles.size() > 1 and blotch_type in ["island", "wooded_lake1"]:
        var beach_origin: SourceTile = previous_tiles.pop_at(1)
        apply_blotch("beach1", beach_origin, 400, next_island_tiles, 6, false, SourceRoute.new("beach2", 12))
    for raw_tile in SourceJavaHashOrder.values(next_island_tiles):
        var tile := raw_tile as SourceTile
        if tiles_to_add.has(tile.position):
            var existing := tiles_to_add[tile.position] as SourceTile
            if blotch_type == "beach1":
                if "sand4" in tile.name or tile.name == "mountain4":
                    tiles_to_add[tile.position] = tile
                continue
            if blotch_type == "sand_pit1":
                if tile.name == "desert2":
                    tiles_to_add[tile.position] = tile
                continue
            if "desert" in tile.name:
                tiles_to_add[tile.position] = tile
                continue
            if "desert" in existing.name:
                continue
            if tile.route_belongs_to != null and tile.route_belongs_to.name == "wooded_lake1":
                tiles_to_add[tile.position] = tile
                continue
            if blotch_type == "wooded_lake1" or blotch_type != "island":
                continue
            if existing.name in ["sand1", "rock1", "tree5", "grass_sand1"] and tile.name != "sand1":
                tiles_to_add[tile.position] = tile
            if tile.name == "tree_large1" and not forest_maze_tiles.has(tile.position):
                tiles_to_add[tile.position] = tile
                for offset in [Vector2i(16, 0), Vector2i(0, 16), Vector2i(16, 16)]:
                    tiles_to_add[tile.position + offset] = SourceTile.new("tree_large1_noSprite", tile.position + offset)
            if tile.name_upper == "tree2" and not forest_maze_tiles.has(tile.position):
                tiles_to_add[tile.position] = tile
        else:
            tiles_to_add[tile.position] = tile
