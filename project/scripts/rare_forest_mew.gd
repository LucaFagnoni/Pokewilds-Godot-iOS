extends RefCounted

# User-requested addition; Mew is not added to Java's ordinary route lists.
const STEP_ODDS := 10000

static func deep_forest(world: Node, cell: Vector2i) -> bool:
    if world.exact_world == null: return false
    var tile: SourceTile = world.exact_world.tile_at(cell)
    return tile != null and (tile.biome.to_lower() == "deep_forest" or (
        tile.route_belongs_to != null and tile.route_belongs_to.name.to_lower() == "deep_forest"))

static func present(world: Node) -> bool:
    for record in world.wild_pokemon.values():
        if String(record.get("species", "")).to_lower() == "mew": return true
    return false

static func eligible(world: Node, cell: Vector2i) -> bool:
    return world.generated and world.gameplay_enabled and world.active_area_id == "OVERWORLD" \
        and world.active_field_move != "FLY" and deep_forest(world, cell) and not present(world)

static func on_step(world: Node, cell: Vector2i) -> void:
    if not eligible(world, cell): return
    if world.rng.randi_range(1, STEP_ODDS) != 1: return
    spawn_near(world, cell)

static func spawn_near(world: Node, cell: Vector2i) -> bool:
    if not eligible(world, cell): return false
    var candidates: Array[Vector2i] = []
    for y in range(-8,9):
        for x in range(-8,9):
            if maxi(absi(x),absi(y)) < 3: continue
            var target := cell + Vector2i(x,y)
            if not deep_forest(world,target) or not world._pokemon_can_enter("mew",target): continue
            if world.built_structures.has(target) or world.resource_objects.has(target) \
                or world.interior_interactables.has(target) or world.wild_eggs.has(target) \
                or world.deployed_pokemon.has(target) or world._wild_id_at_cell(target) >= 0 \
                or target == world.field_helper_cell or target == world.follower_cell: continue
            candidates.append(target)
    if candidates.is_empty(): return false
    var target := candidates[world.rng.randi_range(0,candidates.size()-1)]
    world._add_wild_pokemon("mew",70,target,"DEEP_FOREST",0,
        {"rare_forest_mew":true})
    return present(world)
