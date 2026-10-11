extends Node
signal presence_received(actor:String,packet:Dictionary)
## Area-scoped visual replication. The host decides which peers share an area.
const Remote=preload("res://scripts/coop_remote_player.gd")
const SEND_INTERVAL_MS:=50
const AFK_MS:=180000
var main:Node
var session:Node
var state
var area:=""
var actors:Dictionary={}
var last_packets:Dictionary={}
var _last_send:=0
var _last_input:=0
var _last_received:Dictionary={}
var _last_cells:Dictionary={}

func configure(game:Node,connection:Node,host_state=null)->void:
    main=game;session=connection;state=host_state
    session.message.connect(_message)
    session.departed.connect(func(_peer,actor):_remove(actor))
    _last_input=Time.get_ticks_msec()
    process_mode=Node.PROCESS_MODE_ALWAYS

func set_area(value:String)->void:
    if area==value:return
    area=value
    for actor in actors.keys():_remove(actor)

func _input(event:InputEvent)->void:
    if event is InputEventMouseMotion and event.relative.length_squared()<1:return
    if event is InputEventJoypadMotion and absf(event.axis_value)<0.2:return
    _last_input=Time.get_ticks_msec()

func _process(_delta:float)->void:
    if main==null or session==null or not session.trusted or area.is_empty() or not main.started or main.generating:return
    var now=Time.get_ticks_msec()
    if now-_last_send<SEND_INTERVAL_MS:return
    _last_send=now
    var visual=Remote.capture(main)
    var packet={"kind":"player_visual","area":area,"layer":_layer(),"visual":visual,
        "battle":bool(main.battle_active),"afk":now-_last_input>=AFK_MS,
        "cell_x":main.world._player_cell().x,"cell_y":main.world._player_cell().y,
        "body_x":main.world.player.position.x,"body_y":main.world.player.position.y}
    packet["helper_slot"]=-1
    packet["field_level"]=clampi(int(main.world.active_field_pokemon.get("level",1)),1,100)
    packet["party_level"]=clampi(int(main._party_reference_level()),1,100)
    packet["population_scope"]=main.coop_game.population.local_scope()
    for index in range(main.caught_pokemon.size()):
        if main._storage_is_active(main.caught_pokemon[index]):packet.helper_slot=index;break
    if session.hosting:_relay(1,session.actor,packet)
    else:session.send_host(packet)
    for actor in actors.keys():
        if now-int(_last_received.get(actor,now))>5000:_remove(actor)

func _message(peer:int,actor:String,packet:Dictionary)->void:
    if packet.get("kind")!="player_visual":return
    if not valid_packet(packet):return
    if session.hosting:
        if state==null or state.members.get(actor,{}).get("area","")!=packet.area:return
        var now=Time.get_ticks_msec()
        if now-int(_last_received.get(actor,0))<25:return
        _relay(peer,actor,packet)
    else:
        var remote_actor=packet.get("actor")
        if remote_actor is String and remote_actor!=session.actor:_show(remote_actor,packet)

func _relay(sender_peer:int,actor:String,packet:Dictionary)->void:
    var outgoing=packet.duplicate(true)
    outgoing["actor"]=actor
    _last_received[actor]=Time.get_ticks_msec()
    last_packets[actor]=outgoing
    presence_received.emit(actor,outgoing)
    for peer in session.players:
        if peer==1 or peer==sender_peer:continue
        var other_actor=String(session.players[peer].actor)
        if state!=null and state.members.get(other_actor,{}).get("area","")==packet.area:
            session.send_to(peer,outgoing)
    if actor!=session.actor:_show(actor,outgoing)

func _show(actor:String,packet:Dictionary)->void:
    last_packets[actor]=packet.duplicate(true)
    _last_received[actor]=Time.get_ticks_msec()
    if packet.area!=area or packet.get("layer","")!=_layer():
        if actors.has(actor):
            if is_instance_valid(actors[actor]):actors[actor].queue_free()
            actors.erase(actor)
        return
    if not actors.has(actor):
        var remote=Remote.new()
        main.world.add_child(remote);remote.configure(main)
        actors[actor]=remote
    _last_received[actor]=Time.get_ticks_msec()
    last_packets[actor]=packet.duplicate(true)
    var visual:Dictionary=packet.visual.duplicate(true)
    visual["battle"]=bool(packet.get("battle",false));visual["afk"]=bool(packet.get("afk",false))
    actors[actor].receive(visual)
    # Other players leave the same sand and snow footprints the local player does.
    var cell:=Vector2i(int(packet.get("cell_x",0)),int(packet.get("cell_y",0)))
    if _last_cells.has(actor) and _last_cells[actor]!=cell:
        preload("res://scripts/source_footprints.gd").leave_at(main.world,_last_cells[actor],cell,
            Vector2(float(packet.get("body_x",0.0)),float(packet.get("body_y",0.0))),
            Vector2i(int(visual.get("fx",0)),int(visual.get("fy",1))),String(visual.get("move","")))
    _last_cells[actor]=cell

func _remove(actor:String)->void:
    if actors.has(actor):
        if is_instance_valid(actors[actor]):actors[actor].queue_free()
        actors.erase(actor)
    last_packets.erase(actor);_last_received.erase(actor);_last_cells.erase(actor)

static func valid_packet(packet:Dictionary)->bool:
    if not _number(packet.get("field_level",1)) or float(packet.get("field_level",1))<1 or float(packet.get("field_level",1))>100:return false
    if not _number(packet.get("party_level",1)) or float(packet.get("party_level",1))<1 or float(packet.get("party_level",1))>100:return false
    if not packet.get("area") is String or packet.area.length()>80:return false
    if not packet.get("layer") is String or packet.layer.length()>100:return false
    if not packet.get("population_scope","OVERWORLD") is String or packet.get("population_scope","OVERWORLD").length()>100:return false
    if not _number(packet.get("cell_x",0)) or not _number(packet.get("cell_y",0)):return false
    if not _number(packet.get("helper_slot",-1)) or int(packet.get("helper_slot",-1)) not in [-1,0,1,2,3,4,5]:return false
    for key in ["body_x","body_y"]:
        if packet.has(key) and not _number(packet[key]):return false
    var visual=packet.get("visual")
    if not visual is Dictionary or not visual.get("parts") is Dictionary:return false
    if not preload("res://scripts/coop_night_visuals.gd").valid(visual.get("night",[])):return false
    if visual.parts.size()>4:return false
    for key in ["model","color","fx","fy"]:
        if not _number(visual.get(key)):return false
    for key in ["move","helper_species","follower_species","helper_form","follower_form","pose"]:
        if not visual.get(key,"") is String or String(visual.get(key,"")).length()>48:return false
    for key in visual.parts:
        if key not in ["player","helper","follower","rest"]:return false
        var part=visual.parts[key]
        if not part is Dictionary:return false
        for coordinate in ["x","y","z","frame","hframes","vframes","ox","oy"]:
            if not _number(part.get(coordinate,0)):return false
        if int(part.get("hframes",1))<1 or int(part.get("hframes",1))>32:return false
        if int(part.get("vframes",1))<1 or int(part.get("vframes",1))>32:return false
    var shadow=visual.get("shadow",{})
    if not shadow is Dictionary:return false
    for key in ["x","y","z"]:
        if not _number(shadow.get(key,0)):return false
    return true

static func _number(value:Variant)->bool:
    return (value is int or value is float) and is_finite(float(value)) and absf(float(value))<=10000000

func _layer()->String:
    var value=String(main.world.active_area_id)
    if value=="HOUSE":value+="/"+str(main.world.built_house_interior_origin)
    return value

func _exit_tree()->void:
    for actor in actors.keys():_remove(actor)

func constrain_motion(before:Vector2,after:Vector2)->Vector2:
    if main==null or session==null or not session.trusted:return after
    var result=after
    var now=Time.get_ticks_msec()
    for actor in last_packets:
        if actor==session.actor:continue
        var packet:Dictionary=last_packets[actor]
        if packet.get("area")!=area or packet.get("layer")!=_layer():continue
        if now-int(_last_received.get(actor,0))>5000:continue
        var center=Vector2(float(packet.get("body_x",int(packet.get("cell_x",0))*16+8)),float(packet.get("body_y",int(packet.get("cell_y",0))*16+8)))
        result=clip_player_motion(before,result,center)
    return result

static func clip_player_motion(before:Vector2,after:Vector2,center:Vector2)->Vector2:
    var count=maxi(1,ceili(before.distance_to(after)/4.0))
    var step=(after-before)/count
    var result=before
    for i in range(count):result=_clip_player_step(result,result+step,center)
    return result

static func _clip_player_step(before:Vector2,after:Vector2,center:Vector2)->Vector2:
    # One tile of separation keeps adjacent players available for A interactions.
    # Swept axes prevent running or high game speeds from crossing another body.
    var result=before
    var relative=before-center
    if absf(relative.x)<16.0 and absf(relative.y)<16.0:
        # Shared spawn/late packets must allow a player to walk out of overlap.
        return after if after.distance_squared_to(center)>before.distance_squared_to(center) else before
    var dx=after.x-before.x
    var dy=after.y-before.y
    result.x=after.x
    if absf(before.y-center.y)<16.0:
        if dx>0 and before.x<=center.x-16 and result.x>center.x-16:result.x=center.x-16
        elif dx<0 and before.x>=center.x+16 and result.x<center.x+16:result.x=center.x+16
    result.y=after.y
    if absf(result.x-center.x)<16.0:
        if dy>0 and before.y<=center.y-16 and result.y>center.y-16:result.y=center.y-16
        elif dy<0 and before.y>=center.y+16 and result.y<center.y+16:result.y=center.y+16
    return result
