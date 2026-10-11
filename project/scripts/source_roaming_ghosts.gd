extends RefCounted
# Ordinary night ghosts: CycleDayNight, SpawnGhost and DrawGhost (0.8.11).
var world: Node2D
var actors: Array[Dictionary] = []
var accumulator := 0.0
var countdown := -1
var identity := 0
var serial := 0
var spawning := false

func update(delta: float) -> void:
    if not world.generated or world.exact_world == null: return
    var current: int = world.exact_world.get_instance_id()
    if identity != current:
        clear()
        identity = current
        countdown = world.rng.randi_range(500, 999)
    accumulator += delta
    while accumulator >= 1.0 / 60.0:
        accumulator -= 1.0 / 60.0
        tick()

func clear() -> void:
    for actor in actors:
        if is_instance_valid(actor.sprite): actor.sprite.queue_free()
    actors.clear()
    spawning = false

func tick() -> void:
    if world.get_parent().battle_active: return
    if world.active_area_id != "OVERWORLD" or not world._is_night_time():
        if not actors.is_empty():
            if spawning: world.set_gameplay_enabled(not world.get_parent()._field_ui_blocks_gameplay() and not world.get_parent().field_move_wheel_open)
            clear()
            world.environment_system.set_source_night_alert("")
        return
    if not world.gameplay_enabled and not spawning: return
    if not spawning and not world.source_night_events.protected_at(world.player.position,4,true):
        if world.biome_at(world._player_cell()) in ["DEEP_FOREST", "GRAVEYARD", "WOODED_LAKE"]:
            countdown -= 1
            if countdown <= 0:
                spawn()
                countdown = world.rng.randi_range(1000, 2999)
    for actor in actors.duplicate():
        advance(actor)

func spawn() -> void:
    serial += 1
    var sprite := Sprite2D.new()
    sprite.centered = false
    sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
    sprite.z_index = 114
    world.add_child(sprite)
    var position_value: Vector2 = world.player.position - Vector2(8,8) + Vector2(world.rng.randi_range(0,4)*16-48, world.rng.randi_range(0,4)*16-48)
    actors.append({"id":"roaming_ghost_%d" % serial,"sprite":sprite,"position":position_value,
        "velocity":Vector2.ZERO,"intro":170,"tick":0,"grace":0,
        "species":SourceEventData.GHOST_SPECIES[world.rng.randi_range(0,SourceEventData.GHOST_SPECIES.size()-1)]})
    spawning = true
    world.set_gameplay_enabled(false)
    world.environment_system.set_source_night_alert("night1_alert1")

func advance(actor: Dictionary) -> void:
    var sprite := actor.sprite as Sprite2D
    if actor.has("despawn"):
        var remaining := int(actor.despawn)
        sprite.texture = preload("res://assets/events/ghost_spawn1.png")
        sprite.region_enabled = true
        sprite.region_rect = Rect2(0,0,40,40)
        sprite.flip_h = false
        sprite.position = actor.position - Vector2(4,4)
        sprite.visible = remaining % 4 >= 2
        actor.despawn = remaining - 1
        if remaining <= 0:
            sprite.queue_free()
            actors.erase(actor)
        return
    if int(actor.intro) > 0:
        actor.intro -= 1
        var elapsed := 170 - int(actor.intro)
        sprite.texture = preload("res://assets/events/ghost_spawn1.png") if elapsed <= 80 else preload("res://assets/events/ghost_sheet1.png")
        sprite.region_enabled = true
        sprite.region_rect = Rect2(0,0,40,40) if elapsed <= 80 else Rect2(0 if elapsed % 8 >= 4 else 32,0,32,32)
        sprite.position = actor.position - Vector2(4,4) if elapsed <= 80 else actor.position
        sprite.visible = elapsed > 80 or elapsed % 4 >= 2
        if elapsed in [81,89]: world.play_source_sound("ghost1")
        if actor.intro == 0:
            spawning = false
            world.set_gameplay_enabled(not world.get_parent()._field_ui_blocks_gameplay() and not world.get_parent().field_move_wheel_open)
            world.environment_system.set_source_night_alert("night1_chase1")
        return
    if spawning: return
    if world.source_night_events.protected_at(actor.position,4,false):
        actor["despawn"] = 80
        var chasing := false
        for other in actors:
            if not other.has("despawn"): chasing = true
        if not chasing: world.environment_system.set_source_night_alert("")
        return
    if int(actor.grace) > 0:
        actor.grace -= 1
        sprite.visible = int(actor.grace) % 4 >= 2
        return
    var direction: Vector2 = world.source_night_events.preferred(actor.position)[0]
    var velocity: Vector2 = actor.velocity
    if direction.x != 0:
        velocity.x = clampf(velocity.x + direction.x * 0.1, -1.2, 1.2)
        velocity.y -= velocity.y / 16.0
    else:
        velocity.y = clampf(velocity.y + direction.y * 0.1, -1.2, 1.2)
        velocity.x -= velocity.x / 16.0
    actor.velocity = velocity
    actor.position += velocity
    actor.tick += 1
    var phase: int = (int(actor.tick) / 11) % 8
    var frame: int = [0,1,0,1,0,1,2,3][phase]
    var row := 0 if direction.y > 0 else 8 if direction.y < 0 else 4
    sprite.texture = preload("res://assets/events/ghost_sheet1.png")
    sprite.region_rect = Rect2((row + frame) * 32, 0, 32, 32)
    sprite.flip_h = direction.x > 0
    var sine := fmod(float(actor.tick) * 0.125, 6.28)
    sprite.position = actor.position + Vector2(sin(sine), sin(2 * sine))
    sprite.visible = true
    if world.active_field_move != "FLY" and Rect2(world.player.position - Vector2(8,8),Vector2(16,16)).has_point(Vector2(actor.position) + Vector2(16,16)):
        sprite.hide()
        world.set_gameplay_enabled(false)
        world.battle_requested.emit({"id":actor.id,"kind":"ghost","can_run":true,"can_catch":true,
            "party":[actor.get("pokemon", {"species":actor.species,"level":21})],
            "ghost_revealed":not bool((actor.get("pokemon", {}) as Dictionary).get("is_ghost",true)),
            "requires_silph_scope":true,"_wild_level_scaled":true})

func complete(id: String, outcome: String, pokemon: Dictionary = {}) -> void:
    for actor in actors.duplicate():
        if actor.id != id: continue
        if outcome in ["captured", "defeated", "victory", "lost"]:
            actor.sprite.queue_free()
            actors.erase(actor)
        else:
            if not pokemon.is_empty(): actor["pokemon"] = pokemon.duplicate(true)
            actor.grace = 128
            actor.sprite.show()
    if actors.is_empty(): world.environment_system.set_source_night_alert("")
