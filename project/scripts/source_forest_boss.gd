class_name SourceForestBoss
extends RefCounted

# User-approved forest placement replaces the inactive GenForest2 fixed point.
# This is an overlay: terrain, generator RNG and source boss mechanics stay intact.
const SAVE_KEY := "mega_gengar_forest"
const ACTION := "SPECIAL:mega_gengar"
const DIRECTIONS := [Vector2i.UP, Vector2i.RIGHT, Vector2i.DOWN, Vector2i.LEFT]

static func _set_pose(sprite: Sprite2D, row: int, step: int) -> void:
    sprite.frame = ([4,0,0,2][row] if sprite.hframes==6 else row*4) + step
    sprite.flip_h = sprite.hframes==6 and row==2

static func forest_tile(tile: SourceTile) -> bool:
    # Unassigned coastline also falls back to FOREST in the general biome
    # lookup. Require an actual forest tag/route for this encounter.
    if not tile.biome.is_empty():
        return tile.biome.to_lower() in ["forest", "deep_forest"]
    return tile.route_belongs_to != null \
        and tile.route_belongs_to.name.to_lower() in ["forest1", "deep_forest"]

static func walkable(world: Node, cell: Vector2i) -> bool:
    # The store's flags where it has the cell: a proxy for each cell looked at
    # made the search for a clearing (select_cell), which runs again at every
    # dusk and dawn while none is found, 10-30 ms on a desktop.
    var store = world.exact_world.tiles
    var index: int = store.index_of(cell * 16) if store is WorldTileStore else -1
    if index >= 0:
        if store.flags[index] & (WorldTileStore.SOLID | WorldTileStore.WATER | WorldTileStore.LAVA | WorldTileStore.TIDAL | WorldTileStore.LEDGE): return false
    else:
        var tile: SourceTile = world.exact_world.tile_at(cell)
        if tile == null or tile.is_solid or tile.is_water or tile.is_lava or tile.is_tidal or tile.is_ledge: return false
    return not world.blocked.has(cell) and not world.interior_interactables.has(cell)

## forest_tile with nothing on it (no upper name, no item). The store's
## arrays rule out most cells first: a proxy for each cell select_cell looked
## at was most of its time.
static func _bare_forest(world: Node, cell: Vector2i) -> bool:
    var store = world.exact_world.tiles
    var index: int = store.index_of(cell * 16) if store is WorldTileStore else -1
    if index >= 0:
        if store.upper_ids[index] != 0 or store.has_item_ids[index] != 0: return false
        var biome: String = store.biome_at(index)
        if not biome.is_empty() and biome.to_lower() not in ["forest", "deep_forest"]: return false
    var tile: SourceTile = world.exact_world.tile_at(cell)
    return forest_tile(tile) and tile.name_upper.is_empty() and tile.has_item.is_empty() and tile.item_snapshot().is_empty()

static func select_cell(world: Node) -> Variant:
    var occupied: Dictionary = {world._player_cell(): true}
    for record in world.wild_pokemon.values():
        occupied[record.get("cell", Vector2i.ZERO)] = true
    for cells in [world.deployed_pokemon, world.wild_eggs]:
        for cell in cells:
            occupied[cell] = true
    var queue: Array[Vector2i] = [world.spawn_cell]
    var visited: Dictionary = {world.spawn_cell: true}
    var index := 0
    while index < queue.size():
        var cell := queue[index]
        index += 1
        if walkable(world, cell):
            if _bare_forest(world, cell) \
                    and cell.distance_squared_to(world.spawn_cell) >= 64 \
                    and not occupied.has(cell) \
                    and not world.source_plant_farms.has(world._cell_key(cell)):
                # A clear ring keeps all four approaches open and prevents a
                # solid boss from cutting off a one-cell path.
                var clear_ring := true
                for y in range(-1, 2):
                    for x in range(-1, 2):
                        if not walkable(world, cell + Vector2i(x, y)):
                            clear_ring = false
                if clear_ring:
                    return cell
        for direction in DIRECTIONS:
            var neighbor: Vector2i = cell + direction
            if not visited.has(neighbor) and walkable(world, neighbor):
                visited[neighbor] = true
                queue.append(neighbor)
    return null

static func install(world: Node) -> void:
    if world.exact_world == null:
        return
    var saved: Dictionary = world.event_progress.get(SAVE_KEY, {})
    if world.active_area_id != "OVERWORLD":
        return
    if bool(world.event_progress.get("completed", {}).get("mega_gengar", false)):
        if not saved.is_empty():
            var old_cell := Vector2i(int(saved.x), int(saved.y))
            if world.interior_interactables.get(old_cell, "") == ACTION:
                world._hide_event_cell(old_cell)
        return
    var layer := world.get_node_or_null("LandmarkLayer") as Node2D
    var body := world.get_node_or_null("WorldCollision") as CollisionBody
    if layer == null or body == null:
        return
    var chosen: Variant = null
    if not saved.is_empty():
        var saved_cell := Vector2i(int(saved.x), int(saved.y))
        if world.interior_interactables.get(saved_cell, "") == ACTION:
            if not world._is_night_time():
                world._hide_event_cell(saved_cell)
            return
        if walkable(world, saved_cell):
            chosen = saved_cell
    if chosen == null:
        chosen = select_cell(world)
    if chosen == null:
        push_warning("Mega Gengar: no accessible forest clearing; placement deferred.")
        return
    var cell: Vector2i = chosen
    saved.merge({"x":cell.x,"y":cell.y},true)
    if not saved.has("home_x"):
        saved["home_x"] = cell.x
        saved["home_y"] = cell.y
    world.event_progress[SAVE_KEY] = saved
    if not world._is_night_time():
        return
    var sprite := Sprite2D.new()
    var community := preload("res://scripts/divinakra_mega_art.gd").texture("mega_gengar", "overworld")
    sprite.texture = community if community != null else preload("res://assets/community_mega_gengar/princess_phoenix_sheet.png")
    sprite.hframes = 6 if community != null else 4
    sprite.vframes = 1 if community != null else 4
    _set_pose(sprite,0,0)
    sprite.offset = Vector2(0, -8)
    sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
    sprite.position = world._cell_center(cell)
    sprite.z_as_relative = false
    sprite.z_index = world._depth_z(cell, 18)
    layer.add_child(sprite)
    world.source_interior_upper_sprites[cell] = sprite
    world.source_event_collisions[cell] = world._add_landmark_collision(body, cell.x, cell.y)
    world.blocked[cell] = true
    world.interior_interactables[cell] = ACTION
    world.event_progress[SAVE_KEY] = saved

static func update_visibility(world: Node) -> void:
    if world.exact_world == null or world.active_area_id != "OVERWORLD":
        return
    var night: bool = world._is_night_time()
    if not world.has_meta("forest_boss_night") or bool(world.get_meta("forest_boss_night")) != night:
        world.set_meta("forest_boss_night", night)
        install(world)
    var saved: Dictionary = world.event_progress.get(SAVE_KEY, {})
    if night and not saved.is_empty():
        var cell := Vector2i(int(saved.x), int(saved.y))
        if world.interior_interactables.get(cell, "") == ACTION:
            var sprite: Sprite2D = world.source_interior_upper_sprites.get(cell) as Sprite2D
            if is_instance_valid(sprite):
                var row := int(saved.get("facing_row",0))
                _set_pose(sprite,row,int(world.world_elapsed_seconds / 0.30) % 2)
                if world.gameplay_enabled and world.world_elapsed_seconds >= float(saved.get("next_move",0.0)):
                    saved["next_move"] = world.world_elapsed_seconds + world._wild_move_delay("gengar")
                    world.event_progress[SAVE_KEY] = saved
                    var direction: Vector2i = DIRECTIONS[world.rng.randi_range(0,3)]
                    try_step(world,direction)

static func try_step(world: Node, direction: Vector2i) -> bool:
    var coordinator=world.get_parent().get("coop_game")
    if is_instance_valid(coordinator) and coordinator.active and not coordinator.events.may_move("mega_gengar"):return false
    if not world.gameplay_enabled or not world._is_night_time() or world.active_area_id != "OVERWORLD": return false
    if bool(world.event_progress.get("completed",{}).get("mega_gengar",false)): return false
    var saved: Dictionary = world.event_progress.get(SAVE_KEY,{})
    if saved.is_empty(): return false
    var cell := Vector2i(int(saved.x),int(saved.y))
    if world.interior_interactables.get(cell,"") != ACTION: return false
    var target := cell+direction
    var home := Vector2i(int(saved.get("home_x",cell.x)),int(saved.get("home_y",cell.y)))
    if maxi(absi(target.x-home.x),absi(target.y-home.y)) > 8: return false
    if not walkable(world,target) or not forest_tile(world.exact_world.tile_at(target)): return false
    if target == world._player_cell() or target == world.field_helper_cell or target == world.follower_cell \
        or world._wild_id_at_cell(target) >= 0 or world.deployed_pokemon.has(target) \
        or world.wild_eggs.has(target) or world.built_structures.has(target) \
        or world.resource_objects.has(target) or world.landmarks.has(target): return false
    var sprite := world.source_interior_upper_sprites.get(cell) as Sprite2D
    if not is_instance_valid(sprite): return false
    var collision := world.source_event_collisions.get(cell) as CollisionBox
    if is_instance_valid(collision): collision.queue_free()
    world.source_event_collisions.erase(cell)
    world.source_interior_upper_sprites.erase(cell)
    world.interior_interactables.erase(cell)
    world.blocked.erase(cell)
    world.source_interior_upper_sprites[target] = sprite
    world.source_event_collisions[target] = world._add_landmark_collision(world.get_node("WorldCollision"),target.x,target.y)
    world.blocked[target] = true
    world.interior_interactables[target] = ACTION
    saved["x"] = target.x
    saved["y"] = target.y
    saved["home_x"] = home.x
    saved["home_y"] = home.y
    saved["facing_row"] = 3 if direction == Vector2i.UP else 1 if direction == Vector2i.LEFT else 2 if direction == Vector2i.RIGHT else 0
    world.event_progress[SAVE_KEY] = saved
    _set_pose(sprite,int(saved.facing_row),0)
    sprite.z_index = world._depth_z(target,18)
    world.create_tween().tween_property(sprite,"position",world._cell_center(target),0.20)
    return true
