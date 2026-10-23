extends RefCounted

const HABITATS := {"articuno":"SNOW", "moltres":"VOLCANO", "zapdos":"OASIS",
    "entei":"MOUNTAIN", "suicune":"SNOW", "raikou":"OASIS",
    "arceus":"ANYWHERE", "celebi":"DEEP_FOREST"}
const SAVE_KEY := "rare_legendaries_captured"

static func odds(species: String) -> int:
    return 10000 if species == "arceus" else 12500

static func habitat(world: Node, species: String, cell: Vector2i) -> bool:
    if world.exact_world == null or not world._in_bounds(cell): return false
    if not HABITATS.has(species): return false
    return HABITATS[species] == "ANYWHERE" or world.biome_at(cell) == HABITATS[species]

static func captured(world: Node, species: String) -> void:
    if not HABITATS.has(species): return
    var history: Dictionary = world.event_progress.get(SAVE_KEY, {})
    history[species] = true
    world.event_progress[SAVE_KEY] = history

static func eligible(world: Node, species: String, cell: Vector2i) -> bool:
    if not world.generated or not world.gameplay_enabled or world.active_area_id != "OVERWORLD" or world.active_field_move == "FLY": return false
    if world.event_progress.get(SAVE_KEY, {}).get(species, false) or not habitat(world, species, cell): return false
    return world.wild_population.count_species(species) == 0

static func on_step(world: Node, cell: Vector2i) -> void:
    for species: String in HABITATS:
        if eligible(world, species, cell) and world.rng.randi_range(1, odds(species)) == 1:
            spawn_near(world, species, cell)

static func spawn_near(world: Node, species: String, cell: Vector2i) -> bool:
    if not eligible(world, species, cell): return false
    var candidates: Array[Vector2i] = []
    for y in range(-8, 9):
        for x in range(-8, 9):
            if maxi(absi(x), absi(y)) < 3: continue
            var target := cell + Vector2i(x, y)
            if not habitat(world, species, target) or not world._pokemon_can_enter(species, target): continue
            if world.built_structures.has(target) or world.resource_objects.has(target) or world.interior_interactables.has(target) or world.wild_eggs.has(target) or world.deployed_pokemon.has(target) or world._wild_id_at_cell(target) >= 0 or target == world.field_helper_cell or target == world.follower_cell: continue
            candidates.append(target)
    if candidates.is_empty(): return false
    var target := candidates[world.rng.randi_range(0, candidates.size() - 1)]
    world._add_wild_pokemon(species, 70, target, HABITATS[species], 0, {"rare_legendary":species})
    return world._wild_id_at_cell(target) >= 0

static func context(species: String, record: Dictionary) -> Dictionary:
    return {"id":"rare_" + species, "rare_legendary":species, "kind":"wild",
        "fixed_level":true, "can_run":true, "can_catch":true,
        "overworld_record":record.duplicate(true), "party":[{"species":species, "level":70}]}
