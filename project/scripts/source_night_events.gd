extends RefCounted

# CycleDayNight, Pokemon.Shadowed, Pokemon.Cacturnt and CactusSpawn, 0.8.11.
var world: Node2D
var main: Node
var accumulator := 0.0
var gengar_countdown := 200
var cacturne_countdown := 200
var last_night := false
var initialized := false
var ghost: Dictionary = {}
var cacturnes: Array[Dictionary] = []
var intro_ticks := 0
var battle_pending := 0
var encounter: Dictionary = {}
var wake_ticks := 0
var world_identity := 0
var seed_generation := 0

func configure(owner_world: Node2D) -> void:
    world = owner_world
    main = world.get_parent()

func update(delta: float) -> void:
    if not world.generated or world.exact_world == null: return
    var identity: int = world.exact_world.get_instance_id()
    if identity != world_identity:
        reset()
        world_identity = identity
    accumulator += delta
    while accumulator >= 1.0/60.0:
        accumulator -= 1.0/60.0
        tick()

func sleeping() -> bool:
    return is_instance_valid(world.sleeping_bag_sprite)

func tick() -> void:
    if wake_ticks > 0:
        wake_ticks -= 1
        if wake_ticks == 0 and sleeping():
            world.end_sleeping_bag()
            main.field_item_busy = false
            if main.battle_active or battle_pending > 0:
                world.set_gameplay_enabled(false)
    if main.battle_active: return
    if battle_pending > 0:
        battle_pending -= 1
        if battle_pending == 0:
            main._start_battle_context(encounter)
        return
    if not sleeping():
        gengar_countdown = 200
        if not ghost.is_empty():
            ghost.sprite.queue_free()
            ghost.clear()
    if world.active_area_id != "OVERWORLD" and not world.bed_rest_active: return
    var night: bool = world.environment_system.current_phase_name == "night"
    if not initialized:
        initialized = true
        last_night = night
    elif night != last_night:
        last_night = night
        if night:
            cacturne_countdown = 200
            seed_cacti()
        else:
            clear_dormant_cacti()
    if intro_ticks > 0:
        intro_ticks -= 1
        for actor in cacturnes:
            actor.sprite.visible = intro_ticks <= 60 or (121-intro_ticks)%4 >= 2
            if intro_ticks == 60:
                world._show_ecology_emote(actor.sprite,"skull")
                main._play_pokemon_cry({"species":"cacturne"})
        if intro_ticks == 0:
            main.field_item_busy = false
            world.set_gameplay_enabled(not sleeping())
            world.environment_system.set_source_night_alert("night1_chase1")
        return
    if not world.gameplay_enabled and not sleeping(): return
    var context: Dictionary = world.environment_context()
    if world.bed_rest_active:
        var exterior_route = world.exact_world.route_at(world.active_built_house_door)
        context = {"route_type": "graveyard" if exterior_route != null and "graveyard" in exterior_route.name.to_lower() else ""}
    if String(context.get("route_type","")) == "graveyard" and sleeping():
        if gengar_countdown == 0:
            gengar_countdown = -1
            var offset: int = world.rng.randi_range(3,4)*16
            var position_value: Vector2 = world.player.position + Vector2(offset*world.rng.randi_range(-1,1),offset*world.rng.randi_range(-1,1))
            ghost = make_actor("gengar",30,position_value,true)
        elif gengar_countdown > 0: gengar_countdown -= 1
    elif not sleeping():
        gengar_countdown = 200
        if not ghost.is_empty():
            ghost.sprite.queue_free()
            ghost.clear()
    if not ghost.is_empty(): update_ghost()
    if world.active_area_id == "OVERWORLD" and night and not protected_at(world.player.position,4,true):
        var near := nearby_cacti(4)
        if not near.is_empty():
            cacturne_countdown -= 1
            if cacturne_countdown <= 0:
                cacturne_countdown = world.rng.randi_range(100,599)
                for tile in nearby_cacti(5):
                    tile.set_names(tile.name,"")
                    cacturnes.append(make_actor("cacturne",world.rng.randi_range(32,35),world._cell_center(SourceWorldData.pixel_to_cell(tile.position)),false))
                world._refresh_exact_tile_streams()
                intro_ticks = 122
                main.field_item_busy = true
                world.set_gameplay_enabled(false)
                world._show_ecology_emote(world.player.sprite,"!")
                world.environment_system.set_source_night_alert("night1_alert1")
                return
    for actor in cacturnes.duplicate(): update_cacturne(actor,night)

func make_actor(species: String, level: int, position_value: Vector2, shadow: bool) -> Dictionary:
    var sprite := Sprite2D.new()
    sprite.texture = preload("res://assets/source_exact/global/shadow1.png") if shadow else PokemonData.texture(species,"overworld")
    sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
    sprite.position = position_value
    if shadow: sprite.position.y += 1.0
    else: world._configure_overworld_sprite(sprite)
    sprite.z_as_relative = false
    sprite.z_index = world.player.z_index
    world.add_child(sprite)
    return {"species":species,"level":level,"sprite":sprite,"position":position_value,
        "timer":0,"moves":0,"aggro":0,"despawn":0,"remaining":0.0,
        "direction":Vector2.DOWN,"walk_pose":0,"check_encounter":false}

func preferred(position_value: Vector2) -> Array[Vector2]:
    var delta: Vector2 = position_value-world.player.position
    if delta.x < delta.y:
        return [Vector2.UP,Vector2.RIGHT] if world.player.position.y<position_value.y else [Vector2.RIGHT,Vector2.DOWN]
    return [Vector2.LEFT,Vector2.UP] if world.player.position.x<position_value.x else [Vector2.DOWN,Vector2.LEFT]

func advance(actor: Dictionary) -> bool:
    if float(actor.remaining)<=0.0: return false
    var distance := minf(1.5,float(actor.remaining))
    actor.position += actor.direction*distance
    actor.remaining -= distance
    actor.sprite.position = actor.position.round()+Vector2(0,1 if actor.species=="gengar" else 0)
    if actor.species=="cacturne":
        var travelled := 16.0 - float(actor.remaining)
        var pose := int(actor.walk_pose) if travelled > 2.0 and travelled < 13.0 else 0
        world._set_overworld_motion_frame(actor.sprite,Vector2i(actor.direction),pose)
    return true

func update_ghost() -> void:
    if advance(ghost): return
    if ghost.check_encounter and ghost.position.distance_squared_to(world.player.position)<64.0 and world.active_field_move!="FLY":
        start_encounter(ghost)
        return
    ghost.timer -= 1
    if ghost.timer>0: return
    ghost.timer = world.rng.randi_range(3,4)*60
    if ghost.moves<3: ghost.moves+=1
    else: ghost.timer=30
    if protected_at(ghost.position,5,false): return
    ghost.direction=preferred(ghost.position)[0]
    ghost.remaining=16.0
    ghost.check_encounter=true

func update_cacturne(actor: Dictionary, night: bool) -> void:
    if int(actor.despawn)>0:
        actor.despawn-=1
        if actor.despawn==60: world._set_overworld_motion_frame(actor.sprite,Vector2i.DOWN,0)
        if actor.despawn<40:
            actor.sprite.texture=preload("res://assets/source_exact/global/tornado_sheet1.png")
            actor.sprite.hframes=2
            actor.sprite.frame=(int(actor.despawn)/2)%2
            actor.sprite.position=actor.position+Vector2(-2,-2)
        actor.sprite.visible=actor.despawn<60 or int(actor.despawn)%4>=2
        if actor.despawn==0:
            actor.sprite.queue_free()
            cacturnes.erase(actor)
            if cacturnes.is_empty(): world.environment_system.set_source_night_alert("")
        return
    if not night:
        actor.despawn=60
        return
    if advance(actor): return
    actor.aggro = 1 if int(actor.aggro)>240 else int(actor.aggro)+1
    if actor.aggro==1:
        world._show_ecology_emote(actor.sprite,"skull")
        main._play_pokemon_cry({"species":"cacturne"})
    if actor.aggro<=32:
        world._set_overworld_motion_frame(actor.sprite,Vector2i(actor.direction),0 if int(actor.aggro/4)%2 else 1)
        if actor.aggro in [8,16,24]: world.play_source_sound("ride1")
        return
    if actor.position.distance_squared_to(world.player.position)<64.0 and world.active_field_move!="FLY":
        start_encounter(actor)
        return
    for direction in preferred(actor.position):
        var cell := Vector2i(floori((actor.position.x+direction.x*16)/16),floori((actor.position.y+direction.y*16)/16))
        var tile: SourceTile = world.exact_world.tile_at(cell)
        if tile==null or tile.is_solid or tile.is_ledge or "door" in tile.name_upper or "gate" in tile.name_upper or world._wild_id_at_cell(cell)>=0: continue
        if protected_at(actor.position,5,false):
            actor.despawn=200
            return
        var occupied: bool = world.deployed_pokemon.has(cell)
        for other in cacturnes:
            if is_same(other, actor): continue
            var other_target: Vector2 = other.position + other.direction * float(other.remaining)
            if Vector2i(floori(other_target.x/16),floori(other_target.y/16)) == cell:
                occupied = true
                break
        if occupied: continue
        actor.direction=direction
        actor.walk_pose=1-int(actor.walk_pose)
        actor.remaining=16.0
        break

func protected_at(position_value: Vector2, radius: int, player_check: bool) -> bool:
    if world._flash_is_active() and (player_check or position_value.distance_squared_to(world.player.position)<4096): return true
    var cell := Vector2i(floori(position_value.x/16),floori(position_value.y/16))
    for y in range(-radius,radius):
        for x in range(-radius,radius+1):
            var at := cell+Vector2i(x,y)
            var built: Dictionary=world.built_structures.get(at,{})
            if String(built.get("name",""))=="CAMPFIRE": return true
            if String(built.get("name",""))=="TORCH" and (player_check or position_value.distance_squared_to(world._cell_center(at))<1024): return true
            var tile: SourceTile = world.exact_world.tile_at(at)
            if tile==null: continue
            if "campfire" in tile.name_upper: return true
            if tile.items.has("torch") and (player_check or position_value.distance_squared_to(world._cell_center(at))<1024): return true
            if not player_check and world.deployed_pokemon.has(at) and world._pokemon_has_field_move(world.deployed_pokemon[at],"FLASH"): return true
    return false

func nearby_cacti(radius: int) -> Array[SourceTile]:
    var found: Array[SourceTile]=[]
    var cell: Vector2i=world._player_cell()
    for y in range(-radius,radius):
        for x in range(-radius,radius+1):
            var tile: SourceTile=world.exact_world.tile_at(cell+Vector2i(x,y))
            if tile!=null and tile.name_upper=="cactus2_cacturne": found.append(tile)
    return found

func seed_cacti() -> void:
    seed_generation += 1
    var generation := seed_generation
    var slice_started := Time.get_ticks_usec()
    var camera: Camera2D=world.player.camera
    var half_view: Vector2=world.get_viewport_rect().size/camera.zoom*0.5
    var view:=Rect2(camera.get_screen_center_position()-half_view,half_view*2)
    for tile: SourceTile in world.exact_world.tile_list():
        if Time.get_ticks_usec()-slice_started>=1000:
            if not SourceTile.resident_changed_cells.is_empty(): world._refresh_exact_tile_streams()
            await world.get_tree().process_frame
            if generation!=seed_generation or not is_instance_valid(world): return
            slice_started=Time.get_ticks_usec()
        if tile.name!="desert4" or tile.name_upper!="" or world.rng.randi_range(0,511)>=2: continue
        var at:=Vector2(tile.position)
        if view.has_point(at+Vector2(0,-32)) or view.has_point(at+Vector2(16,80)) or view.has_point(at+Vector2(16,-32)) or view.has_point(at+Vector2(0,80)): continue
        var placed:=0
        for y in range(-4,4):
            for x in range(-4,5):
                if placed>=5: break
                var other: SourceTile=world.exact_world.tiles.get(tile.position+Vector2i(x,y)*16)
                if other==null or other.name!="desert4" or other.name_upper!="" or other.is_solid or other.is_ledge or world.rng.randi_range(0,255)>=32: continue
                other.set_names(other.name,"cactus2_cacturne")
                placed+=1
    world._refresh_exact_tile_streams()

func clear_dormant_cacti() -> void:
    seed_generation+=1
    var generation:=seed_generation
    var slice_started:=Time.get_ticks_usec()
    for tile: SourceTile in world.exact_world.tile_list():
        if Time.get_ticks_usec()-slice_started>=1000:
            if not SourceTile.resident_changed_cells.is_empty(): world._refresh_exact_tile_streams()
            await world.get_tree().process_frame
            if generation!=seed_generation or not is_instance_valid(world): return
            slice_started=Time.get_ticks_usec()
        if tile.name_upper=="cactus2_cacturne": tile.set_names(tile.name,"")
    world._refresh_exact_tile_streams()

func start_encounter(actor: Dictionary) -> void:
    if battle_pending>0: return
    encounter={"id":"source_night_"+String(actor.species),"kind":"wild","can_run":true,"can_catch":true,
        "party":[{"species":actor.species,"level":actor.level}],"_wild_level_scaled":true}
    actor.sprite.hide()
    actor.aggro=0
    if sleeping():
        if actor.species == "gengar":
            wake_ticks = 500
        else:
            world.end_sleeping_bag()
    world.set_gameplay_enabled(false)
    main.field_item_busy=false
    battle_pending=16 if actor.species=="gengar" else 1

func complete(outcome: String) -> void:
    if encounter.is_empty(): return
    if not ghost.is_empty() and encounter.id=="source_night_gengar":
        ghost.sprite.queue_free()
        ghost.clear()
    for actor in cacturnes.duplicate():
        if not actor.sprite.visible:
            if outcome in ["captured","defeated","victory"]:
                actor.sprite.queue_free()
                cacturnes.erase(actor)
            else: actor.sprite.show()
    if cacturnes.is_empty(): world.environment_system.set_source_night_alert("")
    encounter.clear()

func reset() -> void:
    seed_generation += 1
    for actor in cacturnes + ([ghost] if not ghost.is_empty() else []):
        if is_instance_valid(actor.get("sprite")):
            actor.sprite.queue_free()
    cacturnes.clear()
    ghost.clear()
    encounter.clear()
    accumulator = 0.0
    gengar_countdown = 200
    cacturne_countdown = 200
    intro_ticks = 0
    battle_pending = 0
    wake_ticks = 0
    initialized = false
