extends RefCounted

const World = preload("res://scripts/world.gd")
const InteriorTileBatch = preload("res://scripts/interior_tile_batch.gd")
const PokemonData = preload("res://scripts/pokemon_data.gd")
const SOURCE_HOUSE5_DOOR := preload("res://assets/source_0_8_11/tiles/buildings/house5_door1.png")
const SOURCE_HOUSE5_RUG := preload("res://assets/source_0_8_11/tiles/buildings/house5_floor_rug1.png")
const SOURCE_HOUSE5_WALL := preload("res://assets/source_0_8_11/tiles/buildings/house5_wall1.png")
const SourceMineRuntime = preload("res://scripts/source_mine_runtime.gd")
const SourceWorldData = preload("res://scripts/source_world_data.gd")
const TexturePixels = preload("res://scripts/texture_pixels.gd")
const Build = preload("res://scripts/rules/build.gd")
const Paint = preload("res://scripts/rules/paint.gd")

var world: World

func _init(owner_world: World) -> void:
    world = owner_world

func build_source_interiors(_collision_body: CollisionBody) -> void:
    while PokemonData.loading_in_background(): await world.get_tree().process_frame
    var layer := Node2D.new()
    layer.name = "InteriorLayer"
    layer.z_index = -5
    world.add_child(layer)
    # Player houses share the legacy off-world coordinate range with dungeon
    # planes. Keep generated dungeon collision separate so hidden dungeon walls
    # cannot block movement inside a house (or house walls inside a dungeon).
    var collision_body := CollisionBody.new()
    collision_body.name = "SourceInteriorCollision"
    layer.add_child(collision_body)
    await _build_generated_source_interiors(layer, collision_body, true)

func _build_generated_source_interiors(
        parent: Node2D,
        collision_body: CollisionBody,
        cooperative: bool = false
    ) -> void:
    var slice_started := Time.get_ticks_usec()
    var plans := world.generated_source_interior_plans
    var next_y := 4
    for raw_plan in plans:
        var plan := raw_plan as Dictionary
        var area_id := String(plan.get("id", ""))
        var layer_index := int(plan.get("layer_index", -1))
        var size: Vector2i = plan.get("size", Vector2i.ONE)
        var origin := Vector2i(world.map_w + 8, next_y)
        world.source_area_origins[area_id] = origin
        world.source_layer_area_ids[layer_index] = area_id
        next_y += size.y + 8
    for index in range(plans.size()):
        var plan: Dictionary = plans[index]
        var area_id := String(plan.get("id", "AREA_%d" % index))
        var size: Vector2i = plan.get("size", Vector2i(20, 12))
        var origin: Vector2i = world.source_area_origins[area_id]
        var area_layer := Node2D.new()
        area_layer.name = area_id
        area_layer.visible = false
        parent.add_child(area_layer)
        world.source_area_layers[area_id] = area_layer
        var tiles: InteriorTileStore = plan["tiles"]
        var solids: Dictionary = plan.get("solids", {})
        var batch: InteriorTileBatch = null
        # A cursor of its own: other code may use the store's while this waits.
        var tile := tiles.new_cursor()
        for tile_index in tiles.cells.size():
            # Most of each frame behind the loading screen (4 ms a frame made this ~1.4 s).
            if cooperative and Time.get_ticks_usec() - slice_started >= 13000:
                await world.get_tree().process_frame
                slice_started = Time.get_ticks_usec()
            var local_cell: Vector2i = tiles.cells[tile_index]
            var world_cell := origin + local_cell
            tile.repoint(tile_index)
            for upper in [false, true]:
                var spec := SourceWorldData.interior_render_spec(tile, upper)
                if spec.is_empty():
                    continue
                var region: Rect2 = spec["region"]
                if not upper and region.size == Vector2(World.TILE, World.TILE) and not (tile.name in ["cave1_regi1", "cave1_regi2", "cave1_regi3"] or "__on" in tile.name or "__off" in tile.name):
                    # A plain floor or wall tile nothing changes later: drawn
                    # with the tiles before it instead of by its own sprite.
                    if batch == null or batch.full():
                        batch = InteriorTileBatch.new()
                        area_layer.add_child(batch)
                    batch.add(spec["texture"], Vector2(world_cell * World.TILE), region)
                    continue
                if not upper:
                    batch = null
                var tile_sprite := world._add_source_sprite(area_layer, spec["texture"],
                    world_cell, 16 if upper else -4, region.size)
                tile_sprite.region_enabled = true
                tile_sprite.region_rect = region
                tile_sprite.position = Vector2(world_cell * World.TILE) + Vector2(0, World.TILE - region.size.y)
                if upper or tile.name in ["cave1_regi1", "cave1_regi2", "cave1_regi3"] or "__on" in tile.name or "__off" in tile.name:
                    world.source_interior_upper_sprites[world_cell] = tile_sprite
            if solids.has(local_cell) or "stool" in tile.name_upper:
                world.blocked[world_cell] = true
                var interior_collision := world._add_landmark_collision(
                    collision_body, world_cell.x, world_cell.y
                )
                if (
                        tile.name_upper in ["mewtwo_overworld", "volcarona"]
                        or tile.name_upper.begins_with("REGI")
                        or tile.name in ["cave1_regipedistal1", "cave1_regi1", "cave1_regi2", "cave1_regi3"]
                        or "__on" in tile.name or "__off" in tile.name
                        or (tile.name.begins_with("pkmnmansion") and not tile.has_item.is_empty())
                        or (SourceMineRuntime.is_mine_tile(tile) and not tile.has_item.is_empty())
                    ):
                    world.source_event_collisions[world_cell] = interior_collision
        var entries := plan.get("entries", []) as Array
        var local_entry := Vector2i(size.x / 2, size.y / 2)
        if not entries.is_empty():
            local_entry = Vector2i(plan["source_to_local"][Vector2i(entries[0])])
        var entry := origin + local_entry
        world.source_area_entries[area_id] = entry
        world.source_area_rects[area_id] = Rect2i(origin, size)
        world.area_return_cells["%s_ENTRY" % area_id] = entry
        var transitions := plan.get("transitions", {}) as Dictionary
        for raw_local_cell in transitions:
            var transition_cell := Vector2i(raw_local_cell)
            var transition := transitions[transition_cell] as Dictionary
            var action_cell := origin + transition_cell
            if bool(transition.get("exit_overworld", false)):
                world.interior_interactables[action_cell] = "EXIT_AREA:%s" % area_id
            else:
                var source_cell: Vector2i = transition.get("source_cell", Vector2i.ZERO)
                world.interior_interactables[action_cell] = "GOTO_SOURCE_LAYER:%d:%d:%d" % [
                    int(transition.get("target_layer", -1)),
                    source_cell.x,
                    source_cell.y
                ]
        var interactables := plan.get("interactables", {}) as Dictionary
        for raw_local_cell in interactables:
            world.interior_interactables[origin + Vector2i(raw_local_cell)] = interactables[raw_local_cell]
        var interior_pokemon := plan.get("pokemon", []) as Array
        for raw_spawn in interior_pokemon:
            var spawn := raw_spawn as Dictionary
            var pokemon_cell := origin + Vector2i(spawn.get("cell", Vector2i.ZERO))
            var species := String(spawn.get("name", "")).to_lower()
            if species == "dusclops" and SourceMineRuntime.is_mine_tile(tiles.tile(Vector2i(spawn.get("cell", Vector2i.ZERO)))):
                SourceMineRuntime.add(world, area_layer, collision_body, plan, spawn)
                continue
            var pokemon_texture := PokemonData.texture(species, "overworld")
            if pokemon_texture != null:
                world._add_source_sprite(area_layer, pokemon_texture, pokemon_cell, 18)
            world.interior_interactables[pokemon_cell] = "WILD:%s:%d" % [
                species, int(spawn.get("level", 2))
            ]
            world.blocked[pokemon_cell] = true
            world._add_landmark_collision(collision_body, pokemon_cell.x, pokemon_cell.y)
    _register_source_interior_aliases(plans)
    SourceRegiRuntime.sync(world)

func _register_source_interior_aliases(plans: Array[Dictionary]) -> void:
    var aliases := {
        "RUINS_0": {"layer": 99, "route": "ruins1_inner"},
        "MANSION_0": {"layer": 100, "route": "pkmnmansion1"},
        "FOSSIL_LAB": {"layer": 100, "route": "fossil_lab1"},
        "REGI_CHAMBER": {"layer": 90, "route": "regi_cave1"}
    }
    for alias in aliases:
        var wanted := aliases[alias] as Dictionary
        var area_id := String(world.source_layer_area_ids.get(int(wanted["layer"]), ""))
        if area_id.is_empty():
            continue
        var plan: Dictionary = {}
        for candidate in plans:
            if String(candidate.get("id", "")) == area_id:
                plan = candidate
                break
        var local_entry := _find_route_entry(plan, String(wanted["route"]))
        var origin: Vector2i = world.source_area_origins[area_id]
        world.source_area_entries[alias] = origin + local_entry
        world.source_area_layers[alias] = world.source_area_layers[area_id]
        world.source_area_rects[alias] = world.source_area_rects[area_id]
        world.area_return_cells["%s_ENTRY" % alias] = origin + local_entry

func _find_route_entry(plan: Dictionary, route_name: String) -> Vector2i:
    if route_name == "regi_cave1":
        for cell in plan.get("transitions", {}):
            if bool(plan.transitions[cell].get("exit_overworld", false)):
                return Vector2i(cell)
    var tiles := plan.get("tiles") as InteriorTileStore
    var fallback := Vector2i.ZERO
    if tiles == null:
        return fallback
    # Read from the packed arrays: no tile object per cell.
    for index in tiles.cells.size():
        var route := tiles.route_at(index)
        if route == null or route.name != route_name or tiles.flag(index, WorldTileStore.SOLID):
            continue
        var cell := tiles.cells[index]
        fallback = cell
        if "stairs" in tiles.upper_at(index) or "rug" in tiles.name_at(index) or "entrance" in tiles.name_at(index):
            return cell
    return fallback

func _built_house_floor_tile_key(
        door_cell: Vector2i, floor_index: int, local_cell: Vector2i
    ) -> String:
    return "%d,%d|%d|%d,%d" % [
        door_cell.x, door_cell.y, floor_index, local_cell.x, local_cell.y
    ]

func built_house_floor_origin(floor_index: int) -> Vector2i:
    if world.built_house_floor_origins.has(floor_index):
        return Vector2i(world.built_house_floor_origins[floor_index])
    return world.built_house_interior_origin + Vector2i(maxi(0, floor_index) * World.BUILT_HOUSE_FLOOR_STRIDE, 0)

## Read often (Pokemon and the player's moves ask it): the World's own
## dictionaries straight, as rules/build.gd floor_index_for_cell reads them.
func built_house_floor_index_for_cell(cell: Vector2i) -> int:
    if world.built_house_room_size.x <= 0 or world.built_house_room_size.y <= 0:
        return -1
    for raw_index in world.built_house_floor_origins.keys():
        if Rect2i(Vector2i(world.built_house_floor_origins[raw_index]), world.built_house_room_size).has_point(cell):
            return int(raw_index)
    return -1

func built_house_global_cell(floor_index: int, local_cell: Vector2i) -> Vector2i:
    return built_house_floor_origin(floor_index) + local_cell

## This World's player in its house, for the house helpers of the rules.
func _in_house() -> Dictionary:
    return {"area_id": world.active_area_id, "house": world.buildings.house_context()}

func _built_house_floor_saved(
        floor_index: int, local_cell: Vector2i
    ) -> bool:
    if floor_index <= 0:
        return true
    if world.active_built_house_door.x <= -2147483648:
        return false
    return world.built_house_floor_tiles.has(_built_house_floor_tile_key(
        world.active_built_house_door, floor_index, local_cell
    ))

func add_built_house_floor_cell(
        floor_index: int, local_cell: Vector2i, persist: bool = true
    ) -> bool:
    var out := {"events": []}
    var added := Build.add_floor_cell(world.area, world.buildings.house_context(), floor_index, local_cell, persist, out)
    world.field_moves.play_rule(out)
    return added

## A floor tile laid in the house (rules "house_floor"): drawn, and no longer a wall of void.
func draw_floor_cell(global_cell: Vector2i) -> void:
    var layer: Node2D = world.source_area_layers.get("HOUSE") as Node2D
    if layer != null:
        world._add_source_sprite(layer, world._structure_display_texture("FLOOR"), global_cell, -5)
    if world.built_house_void_collisions.has(global_cell):
        var collision: CollisionBox = world.built_house_void_collisions[global_cell] as CollisionBox
        if is_instance_valid(collision):
            collision.queue_free()
        world.built_house_void_collisions.erase(global_cell)

func built_house_floor_can_expand(cell: Vector2i) -> bool:
    return Build.floor_can_expand(world.area, _in_house(), cell)

func _draw_built_house_upper_floor(
        parent: Node2D, collision_body: CollisionBody,
        floor_index: int, origin: Vector2i, size: Vector2i
    ) -> void:
    # Source house upper floors start as black void. Stairs carve a clipped
    # 3x3 patch clipped to the exterior footprint; FLOOR fills that footprint.
    for yy in range(size.y):
        for xx in range(size.x):
            var local_cell: Vector2i = Vector2i(xx, yy)
            var cell: Vector2i = origin + local_cell
            if world.built_house_footprint.has(local_cell) and _built_house_floor_saved(floor_index, local_cell):
                world.built_house_interior_cells[cell] = true
                world._add_source_sprite(parent, world._structure_display_texture("FLOOR"), cell, -5)
            else:
                world.built_house_void_collisions[cell] = world._add_landmark_collision(
                    collision_body, cell.x, cell.y
                )
    # Prevent walking off an edge floor tile into the off-map void.
    for xx in range(-1, size.x + 1):
        for yy in [-1, size.y]:
            var edge: Vector2i = origin + Vector2i(xx, yy)
            if not world.built_house_void_collisions.has(edge):
                world.built_house_void_collisions[edge] = world._add_landmark_collision(
                    collision_body, edge.x, edge.y
                )
    for yy in range(size.y):
        for xx in [-1, size.x]:
            var edge: Vector2i = origin + Vector2i(xx, yy)
            if not world.built_house_void_collisions.has(edge):
                world.built_house_void_collisions[edge] = world._add_landmark_collision(
                    collision_body, edge.x, edge.y
                )

func built_house_stair_metadata(cell: Vector2i) -> Dictionary:
    return Build.stair_metadata(world.buildings.house_context(), cell)

func stair_belongs_to_active_house(data: Dictionary) -> bool:
    return Build.belongs_to_house(world.buildings.house_context(), data)

func _remove_generated_house_stair_pairs() -> void:
    var remove_cells: Array[Vector2i] = []
    for raw_cell in world.built_structures.keys():
        var cell: Vector2i = Vector2i(raw_cell)
        var data: Dictionary = world.built_structures[cell]
        if not bool(data.get("generated_stair_pair", false)):
            continue
        var sprite: Sprite2D = data.get("sprite") as Sprite2D
        if is_instance_valid(sprite):
            sprite.queue_free()
        var collision: CollisionBox = data.get("collision") as CollisionBox
        if is_instance_valid(collision):
            collision.queue_free()
        remove_cells.append(cell)
    for cell in remove_cells:
        world.built_structures.erase(cell)
        world.area.mark("structures", cell)
        world.blocked.erase(cell)
        world.grass_exclusion.erase(cell)

func create_generated_house_stair_pair(primary_cell: Vector2i) -> void:
    var out := {"events": []}
    Build.create_stair_pair(world.area, world.buildings.house_context(), primary_cell, out)
    world.field_moves.play_rule(out)

func _normalize_active_house_stairs() -> void:
    # Migrate stairs from earlier port saves by inferring their floor/local cell
    # from the current house coordinate bands, then recreate source-like paired
    # landings. Generated pairs themselves are never saved.
    var primaries: Array[Vector2i] = []
    for raw_cell in world.built_structures.keys():
        var cell: Vector2i = Vector2i(raw_cell)
        var data: Dictionary = world.built_structures[cell]
        if String(data.get("name", "")) != "STAIRS" or bool(
                data.get("generated_stair_pair", false)):
            continue
        var floor_index: int = built_house_floor_index_for_cell(cell)
        if floor_index < 0:
            continue
        if not data.has("house_floor"):
            var metadata: Dictionary = built_house_stair_metadata(cell)
            for key in metadata:
                data[key] = metadata[key]
            world.built_structures[cell] = data
            world.area.mark("structures", cell)
        if stair_belongs_to_active_house(data):
            primaries.append(cell)
    for primary in primaries:
        create_generated_house_stair_pair(primary)

func set_active_built_house_floor(floor_index: int) -> void:
    var clamped: int = clampi(floor_index, 0, maxi(0, world.built_house_floor_capacity - 1))
    var origin: Vector2i = built_house_floor_origin(clamped)
    world.source_area_rects["HOUSE"] = Rect2i(origin, world.built_house_room_size)
    world.source_area_origins["HOUSE"] = origin
    world._configure_camera()

func _draw_built_house_interior(
        parent: Node2D, collision_body: CollisionBody, origin: Vector2i,
        size: Vector2i, exit_local: Vector2i, exterior_doors: Dictionary = {},
        footprint_only: bool = false
    ) -> void:
    if size.x <= 0 or size.y <= 0:
        return
    var clamped_exit := Vector2i(
        clampi(exit_local.x, 0, size.x - 1),
        clampi(exit_local.y, 0, size.y - 1)
    )

    # Use the source interior floor for the entire connected exterior footprint.
    # The doorway gets the source red entry rug, matching the actual house maps.
    # As in the Java game, a piece cut out of the outside of the house takes
    # its tile of the room with it: that tile is black and cannot be walked on.
    for yy in range(size.y):
        for xx in range(size.x):
            var cell := origin + Vector2i(xx, yy)
            if footprint_only and not world.built_house_footprint.has(Vector2i(xx, yy)):
                world.built_house_void_collisions[cell] = world._add_landmark_collision(
                    collision_body, cell.x, cell.y
                )
                continue
            world.built_house_interior_cells[cell] = true
            world._add_source_sprite(parent, world._structure_display_texture("FLOOR"), cell, -5)

    var exits: Dictionary = {}
    var requested_exits := exterior_doors.duplicate()
    if requested_exits.is_empty():
        requested_exits[clamped_exit] = Vector2i(-2147483648, -2147483648)
    for raw_local in requested_exits:
        var local_exit := Vector2i(raw_local)
        # Map the exterior door to the nearest room edge. Side/back exterior doors
        # therefore remain real side/back exits rather than being forced to the front.
        var edge := "BOTTOM"
        if local_exit.y == 0:
            edge = "TOP"
        elif local_exit.y == size.y - 1:
            edge = "BOTTOM"
        elif local_exit.x == 0:
            edge = "LEFT"
        elif local_exit.x == size.x - 1:
            edge = "RIGHT"

        var door_cell := origin + Vector2i(local_exit.x, size.y)
        var rug_cell := origin + Vector2i(local_exit.x, size.y - 1)
        if edge == "TOP":
            door_cell = origin + Vector2i(local_exit.x, -1)
            rug_cell = origin + Vector2i(local_exit.x, 0)
        elif edge == "LEFT":
            door_cell = origin + Vector2i(-1, local_exit.y)
            rug_cell = origin + Vector2i(0, local_exit.y)
        elif edge == "RIGHT":
            door_cell = origin + Vector2i(size.x, local_exit.y)
            rug_cell = origin + Vector2i(size.x - 1, local_exit.y)

        exits[door_cell] = rug_cell
        world.built_house_interior_cells[door_cell] = true
        var exterior: Vector2i = requested_exits[raw_local]
        if exterior.x > -2147483648:
            world.built_house_exit_doors[door_cell] = exterior
        if local_exit == clamped_exit:
            world.area_return_cells["HOUSE_ENTRY"] = rug_cell

    # Classic source-room presentation: a finished back wall, solid side edges,
    # an open foreground boundary, and a real rug/door pair instead of four rows
    # of repeated crate-looking wall tiles around the entire room.
    for xx in range(size.x):
        var top_wall := origin + Vector2i(xx, -1)
        if not exits.has(top_wall):
            world._add_source_sprite(parent, SOURCE_HOUSE5_WALL, top_wall, 0)
            world._add_landmark_collision(collision_body, top_wall.x, top_wall.y)
            world.built_house_paintable_walls[top_wall] = true

        var bottom_wall := origin + Vector2i(xx, size.y)
        if not exits.has(bottom_wall):
            world._add_landmark_collision(collision_body, bottom_wall.x, bottom_wall.y)

    for yy in range(size.y):
        var left_wall := origin + Vector2i(-1, yy)
        var right_wall := origin + Vector2i(size.x, yy)
        if not exits.has(left_wall):
            # The source player-built interior has one visible back wall only.
            # Keep invisible side-boundary collision so the room size/collision
            # does not change, but do not draw or make the sides paintable.
            world._add_landmark_collision(collision_body, left_wall.x, left_wall.y)
        if not exits.has(right_wall):
            world._add_landmark_collision(collision_body, right_wall.x, right_wall.y)

    # Every connected entrance belongs to this room and has its own outside exit.
    for door_cell in exits:
        world._add_source_sprite(parent, SOURCE_HOUSE5_RUG, exits[door_cell], 2)
        world._add_source_sprite(parent, SOURCE_HOUSE5_DOOR, door_cell, 18)
        world.interior_interactables[door_cell] = "EXIT_HOUSE"
    world.source_area_rects["HOUSE"] = Rect2i(origin, size)
    world.source_area_origins["HOUSE"] = origin

func prepare_built_house_interior(door_cell: Vector2i, house_state: Dictionary) -> void:
    # Clear the previous house runtime while preserving persistent floor expansion
    # records and player-built structures. Generated stair-pair mirrors are rebuilt.
    restore_displaced_house_blocks()
    world.built_house_blocks_stale = true
    _remove_generated_house_stair_pairs()
    world.built_house_exit_doors.clear()
    for raw_cell in world.built_house_interior_cells.keys():
        world.interior_interactables.erase(Vector2i(raw_cell))
    world.built_house_interior_cells.clear()
    world.built_house_paintable_walls.clear()
    world.built_house_paint_sprites.clear()
    world.built_house_decoration_sprites.clear()
    world.built_house_floor_origins.clear()
    world.built_house_void_collisions.clear()
    var old_layer := world.get_node_or_null("BuiltHouseInterior")
    if old_layer != null:
        world.remove_child(old_layer)
        old_layer.queue_free()
    var old_body := world.get_node_or_null("BuiltHouseCollision")
    if old_body != null:
        world.remove_child(old_body)
        old_body.queue_free()

    var exterior_cells: Array = house_state.get("cells", [])
    if exterior_cells.is_empty():
        return

    var min_cell := Vector2i(2147483647, 2147483647)
    var max_cell := Vector2i(-2147483648, -2147483648)
    for raw_cell in exterior_cells:
        var exterior_cell := Vector2i(raw_cell)
        min_cell.x = mini(min_cell.x, exterior_cell.x)
        min_cell.y = mini(min_cell.y, exterior_cell.y)
        max_cell.x = maxi(max_cell.x, exterior_cell.x)
        max_cell.y = maxi(max_cell.y, exterior_cell.y)
    var room_size := max_cell - min_cell + Vector2i.ONE
    room_size.x = maxi(room_size.x, 1)
    room_size.y = maxi(room_size.y, 1)

    world.built_house_footprint.clear()
    for raw_cell in exterior_cells:
        world.built_house_footprint[Vector2i(raw_cell) - min_cell] = true
    world.active_built_house_door = _canonical_house_door(door_cell)
    world.built_house_interior_origin = _house_origin_for(door_cell)
    world.built_house_room_size = room_size
    world.built_house_rooms_seen[world.built_house_interior_origin.y] = [min_cell, room_size]
    world.built_house_floor_capacity = maxi(1, int(house_state.get("floor_count", 1)))
    for floor_index in range(world.built_house_floor_capacity):
        world.built_house_floor_origins[floor_index] = (
            world.built_house_interior_origin
            + Vector2i(floor_index * World.BUILT_HOUSE_FLOOR_STRIDE, 0)
        )
    var exit_local := door_cell - min_cell
    var exterior_doors: Dictionary = {}
    for raw_cell in exterior_cells:
        var exterior := Vector2i(raw_cell)
        var piece: Dictionary = world.built_structures.get(exterior, {})
        if String(piece.get("name", "")) == "DOOR" and not bool(piece.get("gate", false)):
            exterior_doors[exterior - min_cell] = exterior

    var layer := Node2D.new()
    layer.name = "BuiltHouseInterior"
    layer.visible = false
    world.add_child(layer)
    var collision := CollisionBody.new()
    collision.name = "BuiltHouseCollision"
    world.add_child(collision)
    world.source_area_layers["HOUSE"] = layer

    _draw_built_house_interior(
        layer, collision, world.built_house_interior_origin, room_size, exit_local, exterior_doors, true
    )
    for floor_index in range(1, world.built_house_floor_capacity):
        _draw_built_house_upper_floor(
            layer, collision, floor_index,
            built_house_floor_origin(floor_index), room_size
        )
    _normalize_active_house_stairs()
    world._restore_house_rear_walls()
    _restore_built_house_paintings()
    world._restore_house_decorations()
    for furniture_cell in world.built_house_interior_cells:
        if world.built_structures.has(furniture_cell): world._refresh_shell_attachment(furniture_cell)
    set_active_built_house_floor(0)

func restore_displaced_house_blocks() -> void:
    for cell in world.built_house_displaced_blocks:
        world.blocked[cell] = true
    world.built_house_displaced_blocks.clear()

## Sets aside every blocked mark on this house's floors, and on the wall row
## above each, that does not come from something built in the house.
func displace_foreign_house_blocks() -> void:
    world.built_house_blocks_stale = false
    for raw_index in world.built_house_floor_origins:
        var origin := built_house_floor_origin(int(raw_index))
        for yy in range(-1, world.built_house_room_size.y):
            for xx in range(world.built_house_room_size.x):
                var cell := origin + Vector2i(xx, yy)
                if not world.blocked.has(cell) or world.built_structures.has(cell): continue
                if world._couch_anchor_at(cell) != Vector2i(2147483647,2147483647): continue
                world.built_house_displaced_blocks[cell] = true
                world.blocked.erase(cell)

func built_house_paint_key(cell: Vector2i) -> String:
    return Build.paint_key(world.buildings.house_context(), cell)

func _set_built_house_paint_sprite(cell: Vector2i, index: int) -> bool:
    var path := "res://assets/source_0_8_11/tiles/buildings/house_picture%d.png" % index
    if not ResourceLoader.exists(path):
        return false
    if world.built_house_paint_sprites.has(cell):
        var old_sprite := world.built_house_paint_sprites[cell] as Sprite2D
        if is_instance_valid(old_sprite):
            old_sprite.queue_free()
    var layer := world.source_area_layers.get("HOUSE") as Node2D
    if layer == null:
        return false
    var sprite := Sprite2D.new()
    sprite.texture = load(path) as Texture2D
    sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
    sprite.centered = false
    sprite.position = Vector2(cell.x * World.TILE, cell.y * World.TILE)
    sprite.z_as_relative = false
    sprite.z_index = world._depth_z(cell, World.HOUSE_FURNITURE_Z)
    layer.add_child(sprite)
    world.built_house_paint_sprites[cell] = sprite
    return true

func _restore_built_house_paintings() -> void:
    if world.active_built_house_door.x <= -2147483648:
        return
    for raw_cell in world.built_house_paintable_walls.keys():
        var cell := Vector2i(raw_cell)
        var key := built_house_paint_key(cell)
        if key.is_empty() or not world.built_house_paintings.has(key):
            continue
        _set_built_house_paint_sprite(cell, clampi(int(world.built_house_paintings[key]), 1, 20))

func apply_paint(picture_index: int, cell: Vector2i) -> bool:
    var result := Paint.apply(world.area, world.field_moves.rule_player(cell), {"cell": cell, "picture": picture_index}, world.rng)
    world.field_moves.play_rule(result)
    return result.ok

func is_built_house_floor_cell(cell: Vector2i) -> bool:
    return world.active_area_id == "HOUSE" and world.built_house_interior_cells.has(cell) and not world.interior_interactables.has(cell)

func active_source_interior_route() -> Dictionary:
    var tile := source_interior_tile_at_world_cell(world._player_cell())
    if tile == null or tile.route_belongs_to == null:
        return {}
    return {"name": tile.route_belongs_to.name, "level": tile.route_belongs_to.level}

func enter_source_area(area_id: String, return_cell: Vector2i) -> void:
    if world.house_transition_active: return
    if area_id == "HOUSE" and world.generated and world.gameplay_enabled and (world.source_area_entries.has(area_id) or world.area_return_cells.has("HOUSE_ENTRY")):
        house_door_transition("enter", func(): enter_source_area_now(area_id, return_cell))
    else:
        enter_source_area_now(area_id, return_cell)

func enter_source_area_now(area_id: String, return_cell: Vector2i) -> void:
    if area_id.is_empty() or not world.source_area_entries.has(area_id) and not world.area_return_cells.has("%s_ENTRY" % area_id):
        world.world_message.emit("That entrance is not ready.")
        return
    world.active_area_id = area_id
    world._set_exact_overworld_streaming(false)
    if world.source_area_layers.has(area_id):
        (world.source_area_layers[area_id] as CanvasItem).visible = true
    world.area_return_cells["%s_RETURN" % area_id] = return_cell
    var entry_key := "%s_ENTRY" % area_id
    var entry: Vector2i = world.area_return_cells.get(entry_key, world.spawn_cell)
    world.player.position = world._cell_center(entry)
    world.last_player_cell = entry
    world._sync_follower_to_player()
    world._configure_camera()

func leave_source_area() -> void:
    if world.house_transition_active: return
    if world.active_area_id == "HOUSE" and world.generated and world.gameplay_enabled:
        house_door_transition("exit", _leave_source_area_now)
    else:
        _leave_source_area_now()

func _leave_source_area_now() -> void:
    var old_area := world.active_area_id
    if world.source_area_layers.has(old_area):
        (world.source_area_layers[old_area] as CanvasItem).visible = false
    var fallback := world.spawn_cell
    if old_area == "HOUSE" and world.source_landmarks.has("house_door"):
        fallback = Vector2i(world.source_landmarks["house_door"]) + Vector2i.DOWN
    elif old_area == "CAVE" and world.source_landmarks.has("cave_door"):
        fallback = Vector2i(world.source_landmarks["cave_door"]) + Vector2i.DOWN
    var return_cell: Vector2i = world.area_return_cells.get(
        "%s_RETURN" % old_area, fallback
    )
    if old_area == "HOUSE" and not world._house_exit_clear(return_cell):
        # Older saves stored door+DOWN even for side/back entrances.
        for door in [return_cell + Vector2i.UP, world.active_built_house_door]:
            if String(world.built_structures.get(door, {}).get("name", "")) != "DOOR": continue
            var outward := world._house_door_outward(door)
            if outward != Vector2i.ZERO and world._house_exit_clear(door + outward):
                return_cell = door + outward
                break
        if not world._house_exit_clear(return_cell):
            if world.source_area_layers.has(old_area):
                (world.source_area_layers[old_area] as CanvasItem).show()
            world.world_message.emit("The outside entrance is blocked.")
            return
    world.active_area_id = "OVERWORLD"
    world._set_exact_overworld_streaming(true)
    world.player.position = world._cell_center(return_cell)
    world.last_player_cell = return_cell
    world._sync_follower_to_player()
    world._discover_around(return_cell, World.DISCOVERY_RADIUS)
    world._configure_camera()
    # Interior travel moves the shared player far outside the overworld stream
    # window. Force both exact tile streams back onto the exterior immediately
    # so the mansion cannot appear to vanish after exiting it.
    world._refresh_exact_tile_streams()

func source_area_layer_at(cell: Vector2i) -> Node2D:
    for raw_area_id in world.source_area_rects:
        var area_id := String(raw_area_id)
        var rect: Rect2i = world.source_area_rects[raw_area_id]
        if rect.has_point(cell):
            return world.source_area_layers.get(area_id) as Node2D
    return null

func legacy_source_interior_cell(cell: Vector2i) -> Vector2i:
    for area_id in world.source_area_rects:
        if not String(area_id).begins_with("INTERIOR_"): continue
        var rect: Rect2i = world.source_area_rects[area_id]
        if rect.has_point(cell):
            return Vector2i(cell.x, rect.position.y + rect.end.y - 1 - cell.y)
    return cell

func migrate_source_interior_position(position_value: Vector2, state: Dictionary) -> Vector2:
    if world.exact_world != null and not world.exact_world.regi_relocated_cells.is_empty():
        var return_key := "%s_RETURN" % world.active_area_id
        var old_return: Vector2i = world.area_return_cells.get(return_key, world.spawn_cell)
        if world.exact_world.regi_relocated_cells.has(old_return):
            world.area_return_cells[return_key] = world.exact_world.regi_relocated_cells[old_return]
        if world.active_area_id == "OVERWORLD":
            var old_cell := Vector2i((position_value / float(World.TILE)).floor())
            if world.exact_world.regi_relocated_cells.has(old_cell):
                return position_value + Vector2(Vector2i(world.exact_world.regi_relocated_cells[old_cell]) - old_cell) * World.TILE
    if world.active_area_id == "HOUSE" and not state.has("built_house_origins"):
        return position_value + Vector2(world.built_house_interior_origin - Vector2i(world.map_w + 9, 5)) * World.TILE
    if int(state.get("source_interior_layout_version", 0)) > 0 or world.active_area_id in ["OVERWORLD", "HOUSE", "CAVE"]:
        return position_value
    var cell := Vector2i(floori(position_value.x / World.TILE), floori(position_value.y / World.TILE))
    var converted := legacy_source_interior_cell(cell)
    if not state.has("source_return_x"):
        world.area_return_cells["%s_RETURN" % world.active_area_id] = recover_source_dungeon_return(world.active_area_id, converted)
    return position_value + Vector2((converted - cell) * World.TILE)

func source_interior_tile_at_world_cell(cell: Vector2i) -> SourceTile:
    for plan in world.generated_source_interior_plans:
        var area_id := String(plan["id"])
        if not world.source_area_origins.has(area_id): continue
        var local_cell: Vector2i = cell - Vector2i(world.source_area_origins[area_id])
        var tile := (plan["tiles"] as InteriorTileStore).tile(local_cell)
        if tile != null:
            return tile
    return null

func recover_source_dungeon_return(area_id: String, interior_cell: Vector2i = Vector2i(-2147483648, -2147483648)) -> Vector2i:
    var tile := source_interior_tile_at_world_cell(interior_cell)
    var route_name := ""
    if tile != null and tile.route_belongs_to != null:
        route_name = tile.route_belongs_to.name
    var wanted: Array[String] = []
    if route_name == "regi_cave1" or area_id == "REGI_CHAMBER":
        wanted = ["GOTO_SOURCE_LAYER:90:"]
    elif route_name == "fossil_lab1" or area_id == "FOSSIL_LAB":
        wanted = ["GOTO_AREA:FOSSIL_LAB"]
    elif route_name == "ruins1_inner" or area_id == "RUINS_0":
        wanted = ["GOTO_SOURCE_LAYER:99:"]
    elif route_name == "pkmnmansion1" or area_id == "MANSION_0":
        wanted = ["MANSION_LOCK:", "GOTO_AREA:MANSION_0"]
    for cell in world.interior_interactables:
        if world.exact_world == null or not world.exact_world.contains_cell(cell): continue
        var action := String(world.interior_interactables[cell])
        var matches := false
        for prefix in wanted:
            if action.begins_with(prefix): matches = true
        if not matches: continue
        for offset in [Vector2i.DOWN, Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP]:
            var outside: Vector2i = cell + offset
            if not world.exact_world.is_solid(outside) and not world.interior_interactables.has(outside):
                return outside
    return world.spawn_cell

func interior_map_bounds() -> Rect2i:
    var plane: Rect2i = world.source_area_rects[world.active_area_id]
    if world.active_area_id == "HOUSE":
        return plane.grow(1)
    var here := source_interior_tile_at_world_cell(world._player_cell())
    var route: SourceRoute = here.route_belongs_to if here != null else null
    # Authored pickup/door cells can have no route. Keep the current floor's
    # map bounds while crossing them, rather than showing the shared plane.
    if route == null and world.interior_map_bounds_key.size() == 3 and world.interior_map_bounds_key[0] == world.active_area_id and world.interior_map_bounds_key[1] == plane:
        return world.interior_map_bounds_cache
    if route == null:
        var nearest_distance := INF
        for plan in world.generated_source_interior_plans:
            var origin: Vector2i = world.source_area_origins.get(String(plan.id), Vector2i.ZERO)
            if origin != plane.position: continue
            var tiles: InteriorTileStore = plan.tiles
            for index in tiles.cells.size():
                var candidate_route := tiles.route_at(index)
                if candidate_route == null: continue
                var distance := Vector2(origin+tiles.cells[index]-world._player_cell()).length_squared()
                if distance < nearest_distance:
                    nearest_distance = distance
                    route = candidate_route
    var key: Array = [world.active_area_id, plane, route.name if route != null else ""]
    if key == world.interior_map_bounds_key:
        return world.interior_map_bounds_cache
    var result := Rect2i()
    for plan in world.generated_source_interior_plans:
        var origin: Vector2i = world.source_area_origins.get(String(plan.id), Vector2i.ZERO)
        if origin != plane.position:
            continue
        var tiles: InteriorTileStore = plan.tiles
        for index in tiles.cells.size():
            var tile_route := tiles.route_at(index)
            if route != null and (tile_route == null or tile_route.name != route.name):
                continue
            var cell: Vector2i = origin + tiles.cells[index]
            result = Rect2i(cell, Vector2i.ONE) if result.size == Vector2i.ZERO else result.merge(Rect2i(cell, Vector2i.ONE))
    world.interior_map_bounds_key = key
    world.interior_map_bounds_cache = result if result.size != Vector2i.ZERO else plane
    return world.interior_map_bounds_cache

func interior_map_image(bounds: Rect2i) -> Image:
    if world.active_area_id == "OVERWORLD" or not world.source_area_layers.has(world.active_area_id):
        return null
    var key: Array = [world.active_area_id, bounds, world.built_structures.hash(),
        world.built_house_floor_tiles.size(), world.source_interior_mutations.hash()]
    if key == world.interior_map_cache_key and world.interior_map_cache != null:
        return world.interior_map_cache
    var image := Image.create(bounds.size.x * 4, bounds.size.y * 4, false, Image.FORMAT_RGBA8)
    image.fill(Color(0.025, 0.035, 0.03, 1.0))
    var layer: Node2D = world.source_area_layers[world.active_area_id]
    var sprites := layer.find_children("*", "Sprite2D", true, false)
    for cell in world.built_structures:
        if bounds.has_point(Vector2i(cell)):
            var structure_sprite = world.built_structures[cell].get("sprite")
            if is_instance_valid(structure_sprite) and structure_sprite is Sprite2D and not sprites.has(structure_sprite):
                sprites.append(structure_sprite)
    sprites.sort_custom(func(a: Node, b: Node) -> bool: return a.z_index < b.z_index)
    var previews: Dictionary = {}
    for child in layer.get_children():
        if child is InteriorTileBatch:
            (child as InteriorTileBatch).add_to_map(image, previews,
                Vector2(bounds.position * World.TILE) - world.to_local((child as Node2D).global_position))
    for raw_sprite in sprites:
        var sprite := raw_sprite as Sprite2D
        if not sprite.visible or sprite.texture == null:
            continue
        var rect := sprite.region_rect if sprite.region_enabled else Rect2(Vector2.ZERO, sprite.texture.get_size())
        var position_value := world.to_local(sprite.global_position) + sprite.offset
        if sprite.centered:
            position_value -= rect.size * sprite.scale * 0.5
        var destination := Vector2i(((position_value - Vector2(bounds.position * World.TILE)) / 4.0).round())
        var size := Vector2i((rect.size * sprite.scale.abs() / 4.0).round())
        if size.x <= 0 or size.y <= 0 or not Rect2i(Vector2i.ZERO, image.get_size()).intersects(Rect2i(destination, size)):
            continue
        var preview_key: Array = [sprite.texture, rect, size, sprite.flip_h, sprite.flip_v]
        if not previews.has(preview_key):
            if not previews.has(sprite.texture): previews[sprite.texture] = TexturePixels.of(sprite.texture)
            var preview := (previews[sprite.texture] as Image).get_region(Rect2i(rect))
            if sprite.flip_h: preview.flip_x()
            if sprite.flip_v: preview.flip_y()
            preview.resize(size.x, size.y, Image.INTERPOLATE_NEAREST)
            previews[preview_key] = preview
        image.blend_rect(previews[preview_key], Rect2i(Vector2i.ZERO, size), destination)
    world.interior_map_cache_key = key
    world.interior_map_cache = image
    return image

func _canonical_house_door(door: Vector2i) -> Vector2i:
    var cells: Array = world._built_house_state(door).get("cells", [])
    # Origin records retain creation order even when a door is cut/rebuilt.
    # Looking through structure order instead can rename the saved house.
    for saved_door: Vector2i in world.built_house_origins:
        if saved_door in cells and String(world.built_structures.get(saved_door, {}).get("name", "")) == "DOOR":
            return saved_door
    for raw_cell in world.built_structures:
        var cell := Vector2i(raw_cell)
        if cell in cells and String(world.built_structures[cell].get("name", "")) == "DOOR":
            return cell
    return door

## Where to mark, on the map of the open world, someone standing at `at`
## (in tiles). The inside of a built house is kept far off to the east of the
## map, so a player indoors was marked at the map's edge; they are marked at
## that house's door instead. Anywhere else is returned unchanged.
func outdoor_map_position(at: Vector2) -> Vector2:
    if world.active_area_id != "OVERWORLD" or at.x < float(world.map_w + 8) or world.built_house_origins.is_empty():
        return at
    var door := Vector2i.ZERO
    var nearest := -2147483648
    for key: Vector2i in world.built_house_origins:
        var origin_y := int(world.built_house_origins[key])
        if float(origin_y - 2) <= at.y and origin_y > nearest:
            nearest = origin_y
            door = key
    if nearest == -2147483648:
        return at
    return Vector2(door) + Vector2(0.5, 0.5)

func _house_origin_for(door: Vector2i) -> Vector2i:
    var canonical := _canonical_house_door(door)
    var key := canonical
    if not world.built_house_origins.has(key):
        var next_y := 5
        for existing in world.built_house_origins.values():
            next_y = maxi(next_y, int(existing) + world.map_h + World.BUILT_HOUSE_FLOOR_STRIDE)
        world.area.put("built_house_origins", key, next_y)
    var origin_y := int(world.built_house_origins[key])
    for raw_cell in world._built_house_state(door).get("cells", []):
        var cell := Vector2i(raw_cell)
        if String(world.built_structures.get(cell, {}).get("name", "")) == "DOOR":
            world.area.put("built_house_origins", cell, origin_y)
    return Vector2i(world.map_w + 9, origin_y)

func house_door_transition(action: String, change_area: Callable) -> void:
    # EnterBuilding.java: 18 frames, area change at frame 6 under opaque white.
    world.house_transition_active = true
    world.set_gameplay_enabled(false)
    world.player.velocity = Vector2.ZERO
    var overlay := CanvasLayer.new()
    overlay.layer = 90
    world.add_child(overlay)
    var flash := ColorRect.new()
    flash.name = "HouseDoorFlash"
    flash.color = Color(1, 1, 1, 0)
    flash.mouse_filter = Control.MOUSE_FILTER_IGNORE
    flash.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    overlay.add_child(flash)
    world.play_source_sound(action + "1")
    var elapsed := 0.0
    var changed := false
    while elapsed < 18.0 / 60.0:
        var frame := int(elapsed * 60.0)
        flash.color.a = _house_flash_alpha(frame)
        if frame >= 6 and not changed:
            # Always cover the actual room swap, including a slow rendering frame.
            flash.color.a = 1.0
            change_area.call()
            changed = true
        await world.get_tree().process_frame
        elapsed += world.get_process_delta_time()
    if not changed: change_area.call()
    overlay.queue_free()
    world.house_transition_active = false
    world.set_gameplay_enabled(true)

func _house_flash_alpha(frame: int) -> float:
    if frame < 2: return 0.0
    if frame < 4: return 0.25
    if frame < 6: return 0.5
    if frame < 12: return 1.0
    if frame < 14: return 0.75
    if frame < 16: return 0.5
    if frame < 18: return 0.25
    return 0.0

func is_cell_indoors(cell: Vector2i) -> bool:
    if world.active_area_id != "OVERWORLD":
        return true
    var directions := [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]
    for direction in directions:
        var boundary_found := false
        for step in range(1, 13):
            var test: Vector2i = cell + Vector2i(direction) * step
            if not world._in_bounds(test):
                break
            if world.built_structures.has(test):
                var data: Dictionary = world.built_structures[test]
                var name := String(data.get("name", ""))
                if name in ["WALL", "INTERIOR WALL", "DOOR"]:
                    boundary_found = true
                break
        if not boundary_found:
            return false
    return true
