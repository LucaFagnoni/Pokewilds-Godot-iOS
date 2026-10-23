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
    if not tile_allows(world.exact_world.tile_at(cell), group) or not cell_free(world, cell): return false
    if not occupied.is_empty(): return not occupied.has(cell)
    if world._wild_id_at_cell(cell) >= 0: return false
    # A Pokemon still walking from a cell next to this one is drawn on it: the
    # ones within two cells, not every one in the world.
    var center: Vector2 = world._cell_center(cell)
    for id in world.wild_population.ids_near(cell, 2):
        if world.wild_population.visual_position(id).distance_to(center) < 15.0: return false
    return true

## What `group` needs of the cell's own tile.
static func tile_allows(tile: SourceTile, group: String) -> bool:
    if not habitat(tile, group) or tile.is_lava or tile.is_ledge: return false
    if tile.is_solid and not (group in ["gyarados", "sharpedo", "blastoise"] and tile.is_water): return false
    if group not in ["blastoise", "gyarados", "sharpedo"] and (tile.is_water or tile.is_tidal): return false
    return tile.name_upper.is_empty() and tile.has_item.is_empty() and tile.item_snapshot().is_empty()

## Nothing of the world's (but its Pokemon) stands on the cell.
static func cell_free(world: Node, cell: Vector2i) -> bool:
    if world.resource_objects.has(cell) or not cell_free_at(world.area, cell): return false
    return cell != world._player_cell() and cell != world.field_helper_cell and cell != world.follower_cell

## cell_free over an area's data (area_state.gd), with or without a World (a
## World adds its own player, helper and follower).
static func cell_free_at(state, cell: Vector2i) -> bool:
    return not (state.blocked.has(cell) or state.interactables.has(cell) or state.structures.has(cell)
        or state.landmarks.has(cell) or state.eggs.records.has(cell) or state.habitat.records.has(cell)
        or state.source_plant_farms.has("%d,%d" % [cell.x, cell.y]))

## available over an area's data, without a World: `taken` are the players' cells.
static func available_at(state, cell: Vector2i, group: String, taken: Array = []) -> bool:
    if not tile_allows(state.tile_at(cell), group) or not cell_free_at(state, cell) or cell in taken: return false
    if state.wild.id_at(cell) >= 0: return false
    # A Pokemon still walking from a cell next to this one is drawn on it.
    var center := Vector2(cell * 16) + Vector2(8.0, 8.0)
    for id in state.wild.ids_near(cell, 2):
        if state.wild.visual_position(id).distance_to(center) < 15.0: return false
    return true

## A Mega of an area held without a World takes a step as try_step moves one
## in a World: within eight cells of its home, onto a cell available to it.
## Its record moves, and the cell it keeps (blocked, its SPECIAL action) with
## it. False when it may not go there.
static func step_at(state, group: String, direction: Vector2i, taken: Array = []) -> bool:
    var saved: Dictionary = state.event_progress.get(SAVE_KEY, {}).get(group, {})
    if not saved.has("x"): return false
    var cell := Vector2i(int(saved.x), int(saved.y))
    var target := cell + direction
    var home := Vector2i(int(saved.get("home_x", cell.x)), int(saved.get("home_y", cell.y)))
    if maxi(absi(target.x - home.x), absi(target.y - home.y)) > 8 or not available_at(state, target, group, taken): return false
    var action := "SPECIAL:" + String(saved.get("species", ""))
    if String(state.interactables.get(cell, "")) == action:
        state.interactables.erase(cell)
        state.blocked.erase(cell)
    state.interactables[target] = action
    state.blocked[target] = true
    saved["x"] = target.x
    saved["y"] = target.y
    saved["facing_pair"] = 2 if direction == Vector2i.UP else 4 if direction == Vector2i.DOWN else 0
    saved["flip_h"] = direction == Vector2i.RIGHT
    return true

## The cells the Megas of an area held without a World stand on, kept as
## install keeps them in a World (blocked, their SPECIAL action): those of
## `before` (their records as they were) let go, those of `states` taken.
static func mark_at(state, before: Dictionary, states: Dictionary) -> void:
    for saved in before.values():
        if saved is Dictionary and saved.has("x"):
            var cell := Vector2i(int(saved.x), int(saved.y))
            if String(state.interactables.get(cell, "")) == "SPECIAL:" + String(saved.get("species", "")):
                state.interactables.erase(cell)
                state.blocked.erase(cell)
    for saved in states.values():
        if saved is Dictionary and saved.has("x"):
            var cell := Vector2i(int(saved.x), int(saved.y))
            state.interactables[cell] = "SPECIAL:" + String(saved.get("species", ""))
            state.blocked[cell] = true

## A Mega caught or beaten in an area held without a World, as captured: the
## other Mega of its group not yet `completed` (event id -> true) takes its
## place, or the group is done.
static func captured_at(state, id: String, completed: Dictionary, rng: RandomNumberGenerator) -> void:
    var states: Dictionary = state.event_progress.get(SAVE_KEY, {})
    var before := states.duplicate(true)
    for group: String in GROUPS:
        if id not in GROUPS[group]: continue
        var saved: Dictionary = states.get(group, {})
        states.erase(group)
        for other: String in GROUPS[group]:
            if other == id or bool(completed.get(other, false)): continue
            saved["species"] = other
            saved["record"] = BattleEngine.make_pokemon(other, 70, rng)
            states[group] = saved
    state.event_progress[SAVE_KEY] = states
    mark_at(state, before, states)

static func choose_cell(world: Node, group: String) -> Variant:
    var prepared: Dictionary = world.get_meta("mega_load_choices", {})
    if prepared.has(group):
        var cell: Variant = prepared[group]
        prepared.erase(group)
        return cell
    var found := {group: []}
    _find_open(world, found, 0, world.exact_world.tiles.flags.size(), {})
    return _pick(world, found[group], {})

## Adds to `found` (group -> cells) the cells of store indices [from, to) where
## that group's Mega could go, Pokemon aside (_pick): its habitat, available()
## and four open neighbours, in map order. This was a pass over the map per
## group with a SourceTile per cell: ~60 s of a new size S world in the editor
## build, most of it the sea Gyarados and Sharpedo share. It now reads the
## store's arrays, and a
## tile holding nothing is judged by its name, biome, route and flags: once
## per such kind (`kinds`), not per cell.
static func _find_open(world: Node, found: Dictionary, from: int, to: int, kinds: Dictionary) -> void:
    var store: WorldTileStore = world.exact_world.tiles
    var groups: Array = found.keys()
    for index in range(from, to):
        var bits := store.flags[index]
        if not bits & WorldTileStore.PRESENT or store.upper_ids[index] != 0 or store.has_item_ids[index] != 0 \
            or (store.items.has(index) and not (store.items[index] as Dictionary).is_empty()): continue
        var kind := Vector4i(store.name_ids[index], store.biome_ids[index], store.route_ids[index], bits)
        var allowed: int = kinds.get(kind, -1)
        if allowed < 0:
            allowed = 0
            var tile := store.cursor(index)
            for bit in groups.size():
                if tile_allows(tile, groups[bit]): allowed |= 1 << bit
            kinds[kind] = allowed
        if allowed == 0: continue
        var cell := Vector2i(index % store.width, index / store.width) + store.origin
        if not cell_free(world, cell): continue
        # -1 not yet asked, else 0/1: walkers and swimmers (Gyarados, Sharpedo).
        var walks := -1
        var swims := -1
        for bit in groups.size():
            if not allowed & (1 << bit): continue
            var group: String = groups[bit]
            if group in ["gyarados", "sharpedo"]:
                if swims < 0: swims = int(_open(world, store, cell, true))
                if swims == 1: found[group].append(cell)
            else:
                if walks < 0: walks = int(_open(world, store, cell, false))
                if walks == 1: found[group].append(cell)

## A Mega at `cell` could step to each of its four neighbours.
static func _open(world: Node, store: WorldTileStore, cell: Vector2i, swimmer: bool) -> bool:
    for direction: Vector2i in DIRECTIONS:
        var next := cell + direction
        if world.blocked.has(next): return false
        var at := next - store.origin
        if at.x < 0 or at.y < 0 or at.x >= store.width or at.y >= store.height:
            # Outside the store's rectangle: a tile kept on its own, if any.
            var tile: SourceTile = world.exact_world.tile_at(next)
            if tile == null or (tile.is_solid and not (swimmer and tile.is_water)) or tile.is_lava or tile.is_ledge: return false
            continue
        var bits := store.flags[at.y * store.width + at.x]
        if not bits & WorldTileStore.PRESENT or bits & (WorldTileStore.LAVA | WorldTileStore.LEDGE) \
            or (bits & WorldTileStore.SOLID and not (swimmer and bits & WorldTileStore.WATER)): return false
    return true

## One of `cells` at random that no Pokemon, the player or `reserved` takes.
static func _pick(world: Node, cells: Array, reserved: Dictionary) -> Variant:
    var occupied: Dictionary = {world._player_cell(): true}
    for id in world.wild_pokemon:
        occupied[world.wild_pokemon[id].get("cell", Vector2i.ZERO)] = true
        var drawn: Vector2 = world.wild_population.visual_position(id)
        occupied[Vector2i(floori(drawn.x / 16.0), floori(drawn.y / 16.0))] = true
    occupied.merge(reserved)
    # Reservoir sampling avoids allocating another whole-world tile array.
    var choice: Variant = null
    var count := 0
    for cell in cells:
        if occupied.has(cell): continue
        count += 1
        if world.rng.randi_range(1, count) == 1: choice = cell
    return choice

static func prepare_load(world: Node) -> void:
    if world.exact_world == null: return
    var found := {}
    var completed: Dictionary = world.event_progress.get("completed", {})
    for group: String in GROUPS:
        var remaining := false
        for id in GROUPS[group]:
            if not bool(completed.get(id,false)): remaining = true
        if not remaining: continue
        var saved: Dictionary = world.event_progress.get(SAVE_KEY, {}).get(group, {})
        var cell := Vector2i(int(saved.get("x",-99999)),int(saved.get("y",-99999)))
        if available(world,cell,group) or world.interior_interactables.get(cell, "") == "SPECIAL:" + String(saved.get("species", "")): continue
        found[group] = []
    var store: WorldTileStore = world.exact_world.tiles
    var kinds := {}
    var index := 0
    var deadline := Time.get_ticks_usec() + 13000
    while not found.is_empty() and index < store.flags.size():
        if Time.get_ticks_usec() >= deadline:
            await world.get_tree().process_frame
            deadline = Time.get_ticks_usec() + 13000
            if world.exact_world == null or world.exact_world.tiles != store:
                for group in found: found[group] = []
                break
        _find_open(world, found, index, mini(index + 2048, store.flags.size()), kinds)
        index += 2048
    var choices := {}
    var reserved := {}
    for group in found:
        choices[group] = _pick(world, found[group], reserved)
        if choices[group] != null: reserved[choices[group]] = true
    world.set_meta("mega_load_choices",choices)

static func install(world: Node) -> void:
    if world.exact_world == null: return
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

## The argument of _update_pokemon_water_visual (it only reads it), kept and
## refilled instead of making a new Dictionary per Mega per frame.
static var _water_args := {"sprite": null, "species": ""}
## Per Mega sprite (by instance id): [position, tile edit count, material] as
## _update_pokemon_water_visual last left them. Its result only follows those
## (where the sprite stands, the tiles under it, and a material someone else may
## have swapped in), so it is run again only when one of them differs.
static var _water_seen := {}

static func update(world: Node) -> void:
    if world.active_area_id != "OVERWORLD" or world.exact_world == null: return
    if bool(world.get_meta("biome_megas_pending", false)) and world.gameplay_enabled: install(world)
    var states: Dictionary = world.event_progress.get(SAVE_KEY, {})
    var tiles = world.exact_world.tiles
    var edits: int = tiles.edit_count if tiles is WorldTileStore else -1
    for group: String in states:
        var saved: Dictionary = states[group]
        if not saved.has("x"): continue
        var cell := Vector2i(int(saved.x), int(saved.y))
        if world.interior_interactables.get(cell, "") != "SPECIAL:" + String(saved.species): continue
        var sprite := world.source_interior_upper_sprites.get(cell) as Sprite2D
        if not is_instance_valid(sprite): continue
        sprite.frame = int(saved.get("facing_pair", 4)) + int(world.world_elapsed_seconds / 0.30) % 2
        # Setting flip_h queues a redraw even when it does not change.
        var flip := bool(saved.get("flip_h", false))
        if sprite.flip_h != flip: sprite.flip_h = flip
        var seen: Variant = _water_seen.get(sprite.get_instance_id())
        if edits < 0 or seen == null or seen[0] != sprite.position or seen[1] != edits or seen[2] != sprite.material:
            _water_args["sprite"] = sprite
            _water_args["species"] = saved.species
            world._update_pokemon_water_visual(_water_args)
            if _water_seen.size() > 32: _water_seen.clear()
            _water_seen[sprite.get_instance_id()] = [sprite.position, edits, sprite.material]
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
    var collision := world.source_event_collisions.get(cell) as CollisionBox
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
