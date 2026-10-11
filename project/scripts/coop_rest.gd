extends Node
## Personal bed/bedroll respawn and Java's campfire group heal.
var game:Node
var record:Dictionary={}
var sleeping:=false
var _last_rest:Dictionary={}

func configure(coordinator:Node)->void:
    game=coordinator;process_mode=Node.PROCESS_MODE_ALWAYS
    game.session.message.connect(_message)

func _process(_delta:float)->void:
    if not game.active or not game.session.trusted or not game.main.started or game.main.generating:return
    var now_sleeping=game.main._sleeping_bag_active()
    if now_sleeping and not sleeping:on_sleep()
    sleeping=now_sleeping

func set_respawn()->void:
    var world=game.main.world
    var cell:Vector2i=world._player_cell()
    var house:Dictionary={}
    var outside=cell
    if world.active_area_id=="HOUSE":
        var floor_index:int=world._built_house_floor_index_for_cell(cell)
        var local:Vector2i=cell-world._built_house_floor_origin(floor_index)
        house={"x":world.active_built_house_door.x,"y":world.active_built_house_door.y,"floor":floor_index,"local_x":local.x,"local_y":local.y}
        outside=world.area_return_cells.get("HOUSE_RETURN",world.active_built_house_door+world._house_door_outward(world.active_built_house_door))
    record={"area":game._area(),"x":outside.x,"y":outside.y,"house":house}
    apply_on_entry()

func apply_on_entry()->void:
    var world=game.main.world
    world.respawn_house={}
    world.respawn_cell=Vector2i(-2147483648,-2147483648)
    if record.get("area")==game._area():
        world.respawn_cell=Vector2i(int(record.x),int(record.y))
        world.respawn_house=record.get("house",{}).duplicate(true)

func on_sleep()->void:
    set_respawn()
    var center:Vector2i=game.main.world._player_cell()
    for x in range(-2,3):
        for y in range(-2,3):
            var cell=center+Vector2i(x,y)
            if not is_campfire(cell):continue
            heal()
            var packet={"kind":"campfire_rest","scope":game.scope(),"x":cell.x,"y":cell.y}
            if game.hosting:_relay(game.session.actor,packet)
            else:game.session.send_host(packet)
            return

func is_campfire(cell:Vector2i)->bool:
    var world=game.main.world
    if String(world.built_structures.get(cell,{}).get("name",""))=="CAMPFIRE":return true
    if world.exact_world!=null:
        var tile=world.exact_world.tile_at(cell)
        return tile!=null and tile.name_upper=="campfire1"
    return false

func heal()->void:
    for index in range(game.main.caught_pokemon.size()):
        var pokemon:Dictionary=game.main.caught_pokemon[index]
        if pokemon.get("is_egg",false):continue
        pokemon=game.main.BattleEngine.ensure_pokemon(pokemon)
        pokemon.hp=int(pokemon.max_hp);pokemon.status="";pokemon.status_counter=0;pokemon.toxic_counter=0
        game.main.caught_pokemon[index]=pokemon
    set_respawn()

func _message(_peer:int,actor:String,packet:Dictionary)->void:
    if packet.get("kind")!="campfire_rest":return
    if game.hosting:_relay(actor,packet)
    else:_friend_rest(packet)

func _relay(actor:String,packet:Dictionary)->void:
    if not packet.get("scope") is String:return
    for key in ["x","y"]:
        if not preload("res://scripts/coop_players.gd")._number(packet.get(key)):return
    var presence:Dictionary=game.commands.presence.get(actor,{})
    if presence.get("area")!=packet.scope or presence.get("battle",false):return
    if absi(int(presence.x)-int(packet.x))>2 or absi(int(presence.y)-int(packet.y))>2:return
    var now=Time.get_ticks_msec()
    if now-int(_last_rest.get(actor,-1000))<1000:return
    _last_rest[actor]=now
    var outgoing={"kind":"campfire_rest","scope":packet.scope,"x":int(packet.x),"y":int(packet.y),"actor":actor}
    if actor!=game.session.actor:_friend_rest(outgoing)
    for peer in game.session.players:
        if peer==1 or game.session.players[peer].actor==actor:continue
        var other=game.session.players[peer].actor
        if game.commands.presence.get(other,{}).get("area")==packet.scope:game.session.send_to(peer,outgoing)

func _friend_rest(packet:Dictionary)->void:
    if game.main.battle_active or packet.get("scope")!=game.scope():return
    var cell=Vector2i(int(packet.x),int(packet.y))
    if not is_campfire(cell):return
    if game.main.world.player.position.distance_to(Vector2(cell)*16.0)>56.0:return
    heal()

func before_whiteout()->bool:
    var main=game.main
    var destination=String(record.get("area","0,0"))
    var parts=destination.split(",")
    var grid=Vector2i(int(parts[0]),int(parts[1]))
    main.edge_travel_busy=true
    main.world.set_gameplay_enabled(false)
    if grid!=main.current_world_grid:
        await main._travel_adjacent_world(grid-main.current_world_grid)
    main.edge_travel_busy=false
    if not game.active or main.current_world_grid!=grid:
        game.end_session("RESPAWN AREA COULD NOT LOAD. PLEASE REJOIN.")
        return false
    # Older versions saved the water edge as a fabricated rest point. Discard
    # those invalid points, preserving real beds and sleeping bags on land.
    var world=main.world
    if not record.is_empty() and record.get("house",{}).is_empty():
        var cell=Vector2i(int(record.x),int(record.y))
        if world.terrain_kind_at(cell)==0:
            record={}
            if grid!=Vector2i.ZERO:return await before_whiteout()
    apply_on_entry()
    return true

static func nearest_edge(bounds:Rect2i,here:Vector2i)->Vector2i:
    var candidates=[Vector2i(bounds.position.x,clampi(here.y,bounds.position.y,bounds.end.y-1)),Vector2i(bounds.end.x-1,clampi(here.y,bounds.position.y,bounds.end.y-1)),Vector2i(clampi(here.x,bounds.position.x,bounds.end.x-1),bounds.position.y),Vector2i(clampi(here.x,bounds.position.x,bounds.end.x-1),bounds.end.y-1)]
    candidates.sort_custom(func(a,b):return here.distance_squared_to(a)<here.distance_squared_to(b))
    return candidates[0]
