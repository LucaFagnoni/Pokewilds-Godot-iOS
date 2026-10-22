extends RefCounted
## World generation by the engine's own module (engine_modules/pokewilds,
## class PokeWildsWorldGen): the same worlds as SourceWorldGenerator's
## GDScript, bit for bit (.github/engine/worldgen_check.gd), in a fraction of
## the time and memory. Engines without the module (the official editor and
## templates) keep using the GDScript generator.
##
## POKEWILDS_NATIVE_WORLDGEN=0 forces the GDScript generator; =1 makes a
## missing native generator an error (CI checks the native one with it).

const CLASS := "PokeWildsWorldGen"

static func enabled() -> bool:
    var choice := OS.get_environment("POKEWILDS_NATIVE_WORLDGEN")
    if choice == "0":
        return false
    var present := ClassDB.class_exists(CLASS)
    if choice == "1" and not present:
        push_error("POKEWILDS_NATIVE_WORLDGEN=1, but this engine has no %s" % CLASS)
    return present

## generate_validated's result, shaped like a v3 world cache's (a packed
## WorldTileStore, already repaired): SourceExactWorldAdapter takes it as is.
## `qa` adds the native stage hashes ("native_qa").
static func generate(seed_value: int, size_index: int, used_dungeons: Array[String] = [], qa := false) -> Dictionary:
    var native: Object = ClassDB.instantiate(CLASS)
    var raw: Dictionary = native.call("generate", seed_value, size_index, used_dungeons, Tables.new(), qa)
    var failures: Array = raw.get("generation_failures", [])
    if raw.has("generation_error"):
        SourceWorldGenerator._log_generation_validation(seed_value, size_index, failures, {})
        return {"generation_error": raw.generation_error, "generation_failures": failures, "native_qa": raw.get("native_qa", [])}
    if not failures.is_empty():
        SourceWorldGenerator._log_generation_validation(seed_value, size_index, failures, raw.generation_validation)
    # One route table: the store's routes first, then the interiors' own.
    var routes: Array = []
    for record: Array in raw.routes:
        var route := SourceRoute.new(record[0], record[1])
        route.stored_pokemon = record[2]
        route.musics_index = record[3]
        route.is_dungeon = record[4]
        route.dont_spawn_overworlds = record[5]
        routes.append(route)
    # Interior tiles: one object per record; a key may share another's tile.
    var tiles: Array = []
    for record: Array in raw.interior_tiles:
        tiles.append(_tile(record, routes))
    var interiors: Array = []
    for layer: Variant in raw.interiors:
        if layer == null:
            interiors.append(null)
            continue
        var keys: PackedInt32Array = layer[0]
        var ids: PackedInt32Array = layer[1]
        var cells := {}
        for index in ids.size():
            cells[Vector2i(keys[index * 2], keys[index * 2 + 1])] = tiles[ids[index]]
        interiors.append(cells)
    return {
        "store": WorldTileStore.from_record(raw.store, routes),
        "pokemon": raw.pokemon,
        "burrowed_pokemon": raw.burrowed_pokemon,
        "interior_pokemon": raw.interior_pokemon,
        "interiors": interiors,
        "edges": raw.edges,
        "bottom_left": raw.bottom_left,
        "top_right": raw.top_right,
        "already_used_dungeons": raw.already_used_dungeons,
        "regi_relocated_cells": raw.regi_relocated_cells,
        "landmark_origins": raw.landmark_origins,
        "generation_validation": raw.generation_validation,
        "native_ms": raw.native_ms,
        "native_warnings": raw.native_warnings,
        "native_qa": raw.native_qa,
    }

static func _tile(record: Array, routes: Array) -> SourceTile:
    var route: SourceRoute = null if int(record[4]) < 0 else routes[record[4]]
    var tile := SourceTile.new(record[0], record[1], record[2], record[3], route, false)
    # The constructor's name rewrites are already in the record.
    tile.name = record[0]
    tile.name_upper = record[2]
    tile.biome = record[5]
    var flags: int = record[6]
    tile.is_solid = flags & 2 != 0
    tile.is_ledge = flags & 4 != 0
    tile.is_water = flags & 8 != 0
    tile.is_grass = flags & 16 != 0
    tile.is_cuttable = flags & 32 != 0
    tile.is_headbuttable = flags & 64 != 0
    tile.is_tidal = flags & 128 != 0
    tile.is_lava = flags & 256 != 0
    tile.is_bottom_mtn_layer = flags & 512 != 0
    tile.ledge_dir = record[7]
    tile.shore_ocean = record[8]
    tile.shore_tidal = record[9]
    tile.has_item = record[10]
    tile.has_item_amount = record[11]
    if record[12] != null:
        tile.items = record[12]
    if record[13] != null:
        var doors: Array[Vector2i] = []
        doors.assign(record[13])
        tile.door_tiles = doors
    return tile

## What the native generator asks the game's own tables, once per key.
class Tables:
    extends RefCounted

    func traits(source_base: String, base: String, upper: String) -> Array:
        return SourceTile._name_traits(source_base, base, upper)

    func species(species_name: String) -> Dictionary:
        return PokemonData.info(species_name)

    func allowed_pokemon(route: String) -> Array:
        return SourceRouteData.allowed_pokemon(route)

    func is_dungeon(route: String) -> bool:
        return SourceRouteData.is_dungeon(route)

    func layout(method: String, ordinal: int) -> Array:
        return SourceLayoutData.rows("GenIsland1", method, ordinal)

    func constants() -> Array:
        return [SourceForestGenerator.MATES, SourceForestGenerator.MATES_2,
            SourceIslandGenerator.SOURCE_SPECIES_ALIASES, SourceIslandGenerator.SOURCE_BASE_SPECIES_OVERRIDES]
