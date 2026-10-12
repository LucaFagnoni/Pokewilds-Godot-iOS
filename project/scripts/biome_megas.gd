extends RefCounted

# Separate encounter slots and capture history belong to each world, never the
# party. Releasing or transferring a captured Mega cannot reset that history.
const SAVE_KEY := "biome_megas"
const GROUPS := {
    "charizard": ["mega_charizard_x", "mega_charizard_y"],
    "venusaur": ["mega_venusaur"],
    "blastoise": ["mega_blastoise"],
    "gyarados": ["mega_gyarados"],
    "sharpedo": ["mega_sharpedo"],
    "kangaskhan": ["mega_kangaskhan"]
}
const DIRECTIONS := [Vector2i.UP, Vector2i.RIGHT, Vector2i.DOWN, Vector2i.LEFT]

static func is_mega(id: String) -> bool:
    return id in ["mega_charizard_x", "mega_charizard_y", "mega_venusaur", "mega_blastoise", "mega_gyarados", "mega_sharpedo", "mega_kangaskhan"]

static func habitat(tile: SourceTile, group: String) -> bool:
    if tile == null: return false
    var biome := tile.biome.to_lower()
    var route := tile.route_belongs_to.name.to_lower() if tile.route_belongs_to != null else ""
    match group:
        "gyarados", "sharpedo": return tile.is_water and not tile.is_tidal and not tile.is_lava
        "kangaskhan": return biome == "desert" or route == "desert"
        "charizard": return biome == "volcano" or route == "volcano"
        "venusaur":
            # Coast tiles can retain the forest tag of the land they replaced.
            # Dry low-tide sand must not become a forest wandering destination.
            var ground := tile.name.to_lower()
            if tile.is_water or tile.is_tidal or ground.begins_with("sand") or "_tidal" in ground or "beach" in route or "tidal" in route:
                return false
            return biome == "forest" or (biome.is_empty() and route == "forest1")
        "blastoise": return tile.is_tidal or "tidal" in tile.name or "tidal" in biome or "tidal" in route
    return false

static func available(world: Node, cell: Vector2i, group: String, occupied: Dictionary = {}) -> bool:
    var tile: SourceTile = world.exact_world.tile_at(cell)
    if not habitat(tile, group) or tile.is_lava or tile.is_ledge: return false
    if tile.is_solid and not (group in ["gyarados", "sharpedo", "blastoise"] and tile.is_water): return false
    if group not in ["blastoise", "gyarados", "sharpedo"] and (tile.is_water or tile.is_tidal): return false
    if not tile.name_upper.is_empty() or not tile.has_item.is_empty() or not tile.items.is_empty(): return false
    if world.blocked.has(cell) or world.interior_interactables.has(cell) or world.built_structures.has(cell) \
        or world.resource_objects.has(cell) or world.landmarks.has(cell) or world.wild_eggs.has(cell) \
        or world.deployed_pokemon.has(cell) or world.source_plant_farms.has(world._cell_key(cell)): return false
    if cell == world._player_cell() or cell == world.field_helper_cell or cell == world.follower_cell: return false
    if not occupied.is_empty(): return not occupied.has(cell)
    for record in world.wild_pokemon.values():
        if record.get("cell", Vector2i(-99999, -99999)) == cell: return false
        var sprite := record.get("sprite") as Sprite2D
        if is_instance_valid(sprite) and sprite.position.distance_to(world._cell_center(cell)) < 15.0: return false
    return true

static func choose_cell(world: Node, group: String) -> Variant:
    var prepared: Dictionary = world.get_meta("mega_load_choices", {})
    if prepared.has(group):
        var cell: Variant = prepared[group]
        prepared.erase(group)
        return cell
    # Reservoir sampling avoids allocating another whole-world tile array.
    var choice: Variant = null
    var count := 0
    var occupied: Dictionary = {world._player_cell(): true}
    for record in world.wild_pokemon.values():
        occupied[record.get("cell", Vector2i.ZERO)] = true
        var sprite := record.get("sprite") as Sprite2D
        if is_instance_valid(sprite):
            var current := Vector2i(floori(sprite.position.x / 16.0), floori(sprite.position.y / 16.0))
            occupied[current] = true
    for tile: SourceTile in world.exact_world.tiles.values():
        if not habitat(tile, group): continue
        var cell := SourceWorldData.pixel_to_cell(tile.position)
        if not available(world, cell, group, occupied): continue
        var open := true
        for direction in DIRECTIONS:
            var neighbor: SourceTile = world.exact_world.tile_at(cell + direction)
            if neighbor == null or (neighbor.is_solid and not (group in ["gyarados", "sharpedo"] and neighbor.is_water)) or neighbor.is_lava or neighbor.is_ledge \
                or world.blocked.has(cell + direction):
                open = false
                break
        if not open: continue
        count += 1
        if world.rng.randi_range(1, count) == 1: choice = cell
    return choice

static func choose_cell_async(world: Node, group: String, reserved: Dictionary = {}) -> Variant:
    # Reservoir sampling avoids allocating another whole-world tile array.
    var choice: Variant = null
    var count := 0
    var occupied: Dictionary = {world._player_cell(): true}
    for record in world.wild_pokemon.values():
        occupied[record.get("cell", Vector2i.ZERO)] = true
        var sprite := record.get("sprite") as Sprite2D
        if is_instance_valid(sprite):
            var current := Vector2i(floori(sprite.position.x / 16.0), floori(sprite.position.y / 16.0))
            occupied[current] = true
    occupied.merge(reserved)
    var deadline := Time.get_ticks_usec() + 6000
    for key in world.exact_world.tiles:
        if Time.get_ticks_usec() >= deadline:
            await world.get_tree().process_frame
            deadline = Time.get_ticks_usec() + 6000
        var tile: SourceTile = world.exact_world.tiles[key]
        if not habitat(tile, group): continue
        var cell := SourceWorldData.pixel_to_cell(tile.position)
        if not available(world, cell, group, occupied): continue
        var open := true
        for direction in DIRECTIONS:
            var neighbor: SourceTile = world.exact_world.tile_at(cell + direction)
            if neighbor == null or (neighbor.is_solid and not (group in ["gyarados", "sharpedo"] and neighbor.is_water)) or neighbor.is_lava or neighbor.is_ledge \
                or world.blocked.has(cell + direction):
                open = false
                break
        if not open: continue
        count += 1
        if world.rng.randi_range(1, count) == 1: choice = cell
    return choice

static func prepare_load(world: Node) -> void:
    if not world.exact_world_mode or world.exact_world == null: return
    var choices := {}
    var reserved := {}
    var completed: Dictionary = world.event_progress.get("completed", {})
    for group: String in GROUPS:
        var remaining := false
        for id in GROUPS[group]:
            if not bool(completed.get(id,false)): remaining = true
        if not remaining: continue
        var saved: Dictionary = world.event_progress.get(SAVE_KEY, {}).get(group, {})
        var cell := Vector2i(int(saved.get("x",-99999)),int(saved.get("y",-99999)))
        if available(world,cell,group) or world.interior_interactables.get(cell, "") == "SPECIAL:" + String(saved.get("species", "")): continue
        choices[group] = await choose_cell_async(world,group,reserved)
        if choices[group] != null: reserved[choices[group]] = true
    world.set_meta("mega_load_choices",choices)

static func install(world: Node) -> void:
    if not world.exact_world_mode or world.exact_world == null: return
    if world.active_area_id != "OVERWORLD":
        world.set_meta("biome_megas_pending", true)
        return
    var states: Dictionary = world.event_progress.get(SAVE_KEY, {})
    var completed: Dictionary = world.event_progress.get("completed", {})
    for group: String in GROUPS:
        var remaining: Array = []
        for id: String in GROUPS[group]:
            if not bool(completed.get(id, false)): remaining.append(id)
        if remaining.is_empty(): continue
        var saved: Dictionary = states.get(group, {})
        var id := String(saved.get("species", ""))
        if id not in remaining:
            id = String(remaining[world.rng.randi_range(0, remaining.size()-1)])
            saved = {"species": id, "record": BattleEngine.make_pokemon(id, 70, world.rng)}
        var cell := Vector2i(int(saved.get("x", -99999)), int(saved.get("y", -99999)))
        if world.interior_interactables.get(cell, "") == "SPECIAL:" + id:
            states[group] = saved
            continue
        if not available(world, cell, group):
            var chosen: Variant = choose_cell(world, group)
            if chosen == null:
                states[group] = saved
                continue
            cell = chosen
            saved["home_x"] = cell.x
            saved["home_y"] = cell.y
        saved["x"] = cell.x
        saved["y"] = cell.y
        saved["next_move"] = world.world_elapsed_seconds + world._wild_move_delay(group)
        var sprite := Sprite2D.new()
        sprite.texture = PokemonData.record_texture(saved.record, "overworld")
        world._configure_overworld_sprite(sprite)
        sprite.offset = Vector2(0, -8)
        sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
        sprite.position = world._cell_center(cell)
        sprite.z_as_relative = false
        sprite.z_index = world._depth_z(cell, 18)
        world.get_node("LandmarkLayer").add_child(sprite)
        preload("res://scripts/shiny_sparkles.gd").attach(sprite, saved.record)
        world.source_interior_upper_sprites[cell] = sprite
        world.source_event_collisions[cell] = world._add_landmark_collision(world.get_node("WorldCollision"), cell.x, cell.y)
        world.blocked[cell] = true
        world.interior_interactables[cell] = "SPECIAL:" + id
        states[group] = saved
    world.event_progress[SAVE_KEY] = states
    world.set_meta("biome_megas_pending", false)

static func update(world: Node) -> void:
    if world.active_area_id != "OVERWORLD" or not world.exact_world_mode or world.exact_world == null: return
    if bool(world.get_meta("biome_megas_pending", false)) and world.gameplay_enabled: install(world)
    var states: Dictionary = world.event_progress.get(SAVE_KEY, {})
    for group: String in states:
        var saved: Dictionary = states[group]
        if not saved.has("x"): continue
        var cell := Vector2i(int(saved.x), int(saved.y))
        if world.interior_interactables.get(cell, "") != "SPECIAL:" + String(saved.species): continue
        var sprite := world.source_interior_upper_sprites.get(cell) as Sprite2D
        if not is_instance_valid(sprite): continue
        sprite.frame = int(saved.get("facing_pair", 4)) + int(world.world_elapsed_seconds / 0.30) % 2
        sprite.flip_h = bool(saved.get("flip_h", false))
        world._update_pokemon_water_visual({"sprite": sprite, "species": saved.species})
        if world.gameplay_enabled and world.world_elapsed_seconds >= float(saved.get("next_move", 0.0)):
            saved["next_move"] = world.world_elapsed_seconds + world._wild_move_delay(group)
            try_step(world, group, DIRECTIONS[world.rng.randi_range(0, 3)])

static func try_step(world: Node, group: String, direction: Vector2i) -> bool:
    if not world.gameplay_enabled or world.active_area_id != "OVERWORLD": return false
    var states: Dictionary = world.event_progress.get(SAVE_KEY, {})
    var saved: Dictionary = states.get(group, {})
    var coordinator=world.get_parent().get("coop_game")
    if is_instance_valid(coordinator) and coordinator.active and not coordinator.events.may_move(String(saved.get("species",""))):return false
    if not saved.has("x"): return false
    var cell := Vector2i(int(saved.x), int(saved.y))
    var target := cell + direction
    var home := Vector2i(int(saved.get("home_x", cell.x)), int(saved.get("home_y", cell.y)))
    if maxi(absi(target.x-home.x), absi(target.y-home.y)) > 8 or not available(world, target, group): return false
    var sprite := world.source_interior_upper_sprites.get(cell) as Sprite2D
    if not is_instance_valid(sprite): return false
    var collision := world.source_event_collisions.get(cell) as CollisionShape2D
    if is_instance_valid(collision): collision.queue_free()
    world.source_event_collisions.erase(cell)
    world.source_interior_upper_sprites.erase(cell)
    world.interior_interactables.erase(cell)
    world.blocked.erase(cell)
    world.source_interior_upper_sprites[target] = sprite
    world.source_event_collisions[target] = world._add_landmark_collision(world.get_node("WorldCollision"), target.x, target.y)
    world.blocked[target] = true
    world.interior_interactables[target] = "SPECIAL:" + String(saved.species)
    saved["x"] = target.x
    saved["y"] = target.y
    saved["facing_pair"] = 2 if direction == Vector2i.UP else 4 if direction == Vector2i.DOWN else 0
    saved["flip_h"] = direction == Vector2i.RIGHT
    sprite.z_index = world._depth_z(target, 18)
    world.create_tween().tween_property(sprite, "position", world._cell_center(target), 0.20)
    return true

static func context(world: Node, id: String, fallback: Dictionary) -> Dictionary:
    for saved: Dictionary in world.event_progress.get(SAVE_KEY, {}).values():
        if String(saved.get("species", "")) == id:
            fallback["party"] = [saved.record.duplicate(true)]
            break
    return fallback

static func captured(world: Node, id: String, cell: Vector2i) -> void:
    world._hide_event_cell(cell)
    var states: Dictionary = world.event_progress.get(SAVE_KEY, {})
    for group: String in GROUPS:
        if id not in GROUPS[group]: continue
        var saved: Dictionary = states.get(group, {})
        states.erase(group)
        for other: String in GROUPS[group]:
            if other == id or bool(world.event_progress.get("completed", {}).get(other, false)): continue
            # Reuse the existing home clearing; capture does not need a new
            # whole-world search or permit two active Charizard actors.
            saved["species"] = other
            saved["record"] = BattleEngine.make_pokemon(other, 70, world.rng)
            states[group] = saved
    world.event_progress[SAVE_KEY] = states
    # The second Charizard is installed only once battle closes.
    world.set_meta("biome_megas_pending", true)
