extends RefCounted

# GenIsland1.generateRuinsInterior and Pokemon.Standing/Moving (Java 0.8.11).
# Only authored mine Dusclops use this runtime; surface ecology is unchanged.
const Battle = preload("res://scripts/battle_engine.gd")

static func is_mine_tile(tile) -> bool:
    return tile != null and tile.route_belongs_to != null and tile.route_belongs_to.name == "ruins1_inner"

static func clear_collected_item(world, cell: Vector2i) -> void:
    var tile = world._source_interior_tile_at_world_cell(cell)
    if not is_mine_tile(tile): return
    tile.has_item = ""
    tile.has_item_amount = 0
    tile.set_names(tile.name, "")
    # Keep a solid underlying floor solid; remove only the pickup's obstacle.
    var shape = world.source_event_collisions.get(cell)
    if not tile.is_solid:
        world.blocked.erase(cell)
        if is_instance_valid(shape): shape.set_deferred("disabled", true)
    world.interior_map_cache_key = []

static func add(world, layer, body, plan: Dictionary, spawn: Dictionary) -> void:
    var cell: Vector2i = world.source_area_origins[plan.id] + Vector2i(spawn.cell)
    var source: Vector2i = spawn.source_cell
    var id := "%d:%d:%d" % [int(plan.layer_index), source.x, source.y]
    var sprite := Sprite2D.new()
    var mon: Dictionary = Battle.make_pokemon("dusclops", int(spawn.get("level",44)))
    sprite.texture = PokemonData.texture("dusclops", "overworld", bool(mon.get("shiny",false)))
    sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
    sprite.position = world._cell_center(cell)
    sprite.z_as_relative = false
    sprite.z_index = clampi(100 + roundi(sprite.position.y), -4096, 4095)
    world._configure_overworld_sprite(sprite)
    layer.add_child(sprite)
    var shape = world._add_landmark_collision(body, cell.x, cell.y)
    var actor := {"id":id,"area":String(plan.id),"spawn":cell,"cell":cell,
        "sprite":sprite,"shape":shape,"mon":mon,"initial_mon":mon.duplicate(true),
        "removed":false,"pending":false,"direction":Vector2i.DOWN,
        "moving":false,"distance":0.0,"speed":1.5,"ticks":0.0,"step_timer":1,"step_delay":1,
        "aggro_timer":0,"just_aggroed":true,"los_timer":0,"charm_timer":0,
        "charmed":false,"move_timer":world.rng.randi_range(60,239)}
    world.source_mine_pokemon[id] = actor
    _occupy(world, actor)

static func _vacate(world, actor: Dictionary) -> void:
    var cell: Vector2i = actor.cell
    if world.interior_interactables.get(cell, "") == "MINE_POKEMON:" + String(actor.id):
        world.interior_interactables.erase(cell)
        if not String(actor.get("under_action", "")).is_empty():
            world.interior_interactables[cell] = actor.under_action
        world.blocked.erase(cell)
    actor.shape.set_deferred("disabled", true)

static func _occupy(world, actor: Dictionary) -> void:
    if actor.removed: return
    var previous: String = world.interior_interactables.get(actor.cell, "")
    if previous != "MINE_POKEMON:" + String(actor.id):
        actor.under_action = previous
    world.interior_interactables[actor.cell] = "MINE_POKEMON:" + String(actor.id)
    world.blocked[actor.cell] = true
    actor.shape.position = world._cell_center(actor.cell)
    actor.shape.set_deferred("disabled", actor.cell == world._player_cell())

static func _frame(world, actor: Dictionary, phase: int) -> void:
    # Interiors use the player's absolute-foot depth, not streamed overworld Z.
    actor.sprite.z_index = clampi(100 + roundi(actor.sprite.global_position.y), -4096, 4095)
    world._set_overworld_motion_frame(actor.sprite, actor.direction, phase)

static func _can_enter(world, actor: Dictionary, cell: Vector2i) -> bool:
    var tile = world._source_interior_tile_at_world_cell(cell)
    var current = world._source_interior_tile_at_world_cell(actor.cell)
    return is_mine_tile(tile) and not tile.is_solid and not tile.is_ledge \
        and not (current != null and current.is_ledge and current.ledge_dir == "up" and cell.y < actor.cell.y) \
        and not "door" in tile.name and not "door" in tile.name_upper \
        and not "gate" in tile.name_upper and not world.blocked.has(cell)

static func _has_los(world, actor: Dictionary) -> bool:
    var start: Vector2 = actor.sprite.position
    var end: Vector2 = world.player.position
    var step := start.direction_to(end) * 16.0
    var distance := start.distance_squared_to(end)
    var probe := start
    while start.distance_squared_to(probe) < distance:
        probe += step
        if world._source_interior_tile_at_world_cell(Vector2i((probe / 16.0).floor())) == null:
            return false
    return true

static func update(world, delta: float) -> void:
    if not world.gameplay_enabled: return
    for actor in world.source_mine_pokemon.values():
        if actor.removed or actor.pending or not actor.sprite.is_visible_in_tree(): continue
        actor.ticks += delta * 60.0
        while actor.ticks >= 1.0:
            actor.ticks -= 1.0
            _tick(world, actor)
            if actor.pending or not world.gameplay_enabled: return

static func _tick(world, actor: Dictionary) -> void:
    if actor.moving:
        actor.step_timer -= 1
        if actor.step_timer <= 0:
            actor.step_timer = actor.step_delay
            actor.distance = minf(16.0, float(actor.distance) + float(actor.speed))
        actor.sprite.position = actor.start_position + Vector2(actor.direction) * float(actor.distance)
        _frame(world, actor, 1 if actor.distance > 2.0 and actor.distance < 13.0 else 0)
        if actor.distance >= 16.0:
            actor.moving = false
            _occupy(world, actor)
        return
    _frame(world, actor, 0)
    actor.charm_timer += 1
    if actor.charm_timer > 240:
        actor.charm_timer = 0
        actor.charmed = world.active_field_move == "CHARM" and int(world.active_field_pokemon.get("level",0)) >= int(actor.mon.level)
        if actor.charmed: world._show_ecology_emote(actor.sprite, "heart")
    if actor.aggro_timer > 240: actor.aggro_timer = 0
    actor.aggro_timer += 1
    if actor.aggro_timer == 1: world._show_ecology_emote(actor.sprite, "skull")
    var distance: float = actor.sprite.position.distance_squared_to(world.player.position)
    var los := true
    if distance < 16384.0 and actor.los_timer <= 0:
        los = _has_los(world, actor)
        if los: actor.los_timer = 60
    if actor.los_timer > 0: actor.los_timer -= 1
    if distance < 14400.0 and los and not actor.charmed:
        if actor.just_aggroed:
            actor.just_aggroed = false
            actor.aggro_timer = 1
            world._show_ecology_emote(actor.sprite, "skull")
        if actor.aggro_timer == 1:
            var cry := AudioStreamPlayer.new()
            cry.stream = load(PokemonData.cry_path("dusclops"))
            actor.sprite.add_child(cry)
            AudioBalance.apply(cry)
            cry.volume_db += linear_to_db(0.2)
            cry.finished.connect(cry.queue_free)
            cry.play()
        # Source's 32-tick warning before its 1.5-pixel-per-tick pursuit.
        if actor.aggro_timer < 32:
            _frame(world, actor, 1 if int(actor.aggro_timer) % 8 < 4 else 0)
            return
        if distance < 64.0 and actor.aggro_timer > 32 and world.active_field_move != "FLY" and not world.encounter_grace_active():
            begin_battle(world, actor.id)
            return
        var toward: Vector2i = world._player_cell() - Vector2i(actor.cell)
        var choices: Array[Vector2i] = []
        if toward.x != 0: choices.append(Vector2i(signi(toward.x),0))
        if toward.y != 0: choices.append(Vector2i(0,signi(toward.y)))
        if choices.size() == 2 and world.rng.randi_range(0,255) < 128: choices.reverse()
        for direction in choices:
            if _can_enter(world, actor, actor.cell + direction):
                _move(world, actor, direction, 1.5)
                return
        return
    actor.just_aggroed = true
    actor.move_timer -= 1
    if actor.move_timer <= 0:
        actor.move_timer = world.rng.randi_range(60,239)
        var direction: Vector2i = [Vector2i.UP,Vector2i.DOWN,Vector2i.LEFT,Vector2i.RIGHT][world.rng.randi_range(0,3)]
        if actor.cell + direction != world._player_cell() and _can_enter(world, actor, actor.cell + direction):
            _move(world, actor, direction, 1.0, 2)

static func _move(world, actor: Dictionary, direction: Vector2i, speed: float, delay: int = 1) -> void:
    _vacate(world, actor)
    actor.start_position = actor.sprite.position
    actor.cell += direction
    actor.direction = direction
    actor.speed = speed
    actor.step_timer = 1
    actor.step_delay = delay
    actor.distance = 0.0
    actor.moving = true
    _occupy(world, actor)
    # The Java actor can reach the trainer's square to initiate battle.
    # Do not push the trainer away with a physics shape during that approach.
    if actor.cell == world._player_cell(): actor.shape.set_deferred("disabled", true)

static func begin_battle(world, id: String) -> void:
    var actor: Dictionary = world.source_mine_pokemon.get(id, {})
    if actor.is_empty() or actor.removed or actor.pending or world.active_field_move == "FLY": return
    actor.pending = true
    world.battle_requested.emit({"id":"mine_dusclops_"+id,"kind":"wild",
        "fixed_level":true,"mine_pokemon_id":id,"can_run":true,"can_catch":true,
        "party":[actor.mon.duplicate(true)]})

static func complete(world, id: String, result: Dictionary) -> void:
    var actor: Dictionary = world.source_mine_pokemon.get(id,{})
    if actor.is_empty(): return
    actor.pending = false
    actor.aggro_timer = 0
    actor.just_aggroed = true
    var mon = result.get("mine_pokemon",{})
    if mon is Dictionary and not mon.is_empty():
        actor.mon = mon.duplicate(true)
        Battle.reset_battle_state(actor.mon)
    if String(result.get("outcome","")) in ["captured","defeated"]:
        _vacate(world, actor)
        actor.removed = true
        actor.sprite.hide()

static func snapshot(world) -> Dictionary:
    var saved := {}
    for id in world.source_mine_pokemon:
        var a: Dictionary = world.source_mine_pokemon[id]
        var offset: Vector2i = Vector2i(a.cell) - Vector2i(a.spawn)
        saved[id] = {"dx":offset.x,"dy":offset.y,"removed":a.removed,"pokemon":a.mon.duplicate(true)}
    return saved

static func restore(world, saved) -> void:
    if not saved is Dictionary: saved = {}
    # Clear all occupancy first, then restore; actors may have exchanged cells.
    for a in world.source_mine_pokemon.values(): _vacate(world,a)
    for id in world.source_mine_pokemon:
        var a: Dictionary = world.source_mine_pokemon[id]
        var record: Dictionary = saved.get(id,{})
        a.cell = Vector2i(a.spawn) + Vector2i(int(record.get("dx",0)),int(record.get("dy",0)))
        var tile = world._source_interior_tile_at_world_cell(a.cell)
        if not is_mine_tile(tile) or tile.is_solid: a.cell = a.spawn
        a.mon = record.get("pokemon",a.initial_mon).duplicate(true)
        a.removed = bool(record.get("removed",false))
        a.pending = false
        a.moving = false
        a.ticks = 0.0
        a.aggro_timer = 0
        a.just_aggroed = true
        a.sprite.position = world._cell_center(a.cell)
        a.sprite.texture = PokemonData.texture("dusclops","overworld",bool(a.mon.get("shiny",false)))
        a.sprite.visible = not a.removed
        _occupy(world,a)
