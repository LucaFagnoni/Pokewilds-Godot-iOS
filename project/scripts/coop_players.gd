extends Node
const TexturePixels = preload("res://scripts/texture_pixels.gd")
signal presence_received(actor:String,packet:Dictionary)
## Area-scoped visual replication. The host decides which peers share an area.
const Remote=preload("res://scripts/coop_remote_player.gd")
const Transport=preload("res://scripts/coop_transport.gd")
const SEND_INTERVAL_MS:=50
const HEARTBEAT_MS:=1000
const AFK_MS:=180000
## A dedicated server's own player is never seen, and it draws nobody.
const Server=preload("res://scripts/dedicated_server.gd")
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
var _last_sent:Dictionary={}
var _last_sent_at:=0
var _repeated:=false
## Per sender: [positions that may still be relayed at once, when last topped up].
var _relay_budget:Dictionary={}
## A sender may average 40 positions a second (2x what is sent), and after a
## held-up link pass on 2 s of them at once.
const RELAY_EVERY_MS:=25.0
const RELAY_BURST:=40.0

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
    var started:=Time.get_ticks_usec()
    _send_visual()
    if Transport.stats!=null:Transport.count("proc:players",0,started)

func _send_visual()->void:
    if main==null or session==null or not session.trusted or area.is_empty() or not main.started or main.generating or Server.active:return
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
    for actor in actors.keys():
        if now-int(_last_received.get(actor,now))>5000:_remove(actor)
    # Only what changed goes out; standing still, a reminder once a second
    # keeps this player from being dropped by the others (after 5 s, above).
    # The first unchanged one goes too: it tells the others this player has
    # stopped, not that the link is slow (coop_remote_player.gd _carries).
    if packet==_last_sent and _repeated and now-_last_sent_at<HEARTBEAT_MS:return
    _repeated=packet==_last_sent
    _last_sent=packet;_last_sent_at=now
    # When it was sent, by this device's clock: lets the others tell a pause
    # from a late packet (coop_remote_player.gd). Wrapped to stay a small number.
    var outgoing:Dictionary=packet.duplicate();outgoing["t"]=now%1000000
    if session.hosting:_relay(1,session.actor,outgoing)
    else:session.send_host(outgoing)

func _message(peer:int,actor:String,packet:Dictionary)->void:
    if packet.get("kind")=="player_effect":
        if not valid_effect(packet):return
        if session.hosting:
            if state==null or state.members.get(actor,{}).get("area","")!=packet.area:return
            _relay_effect(peer,actor,packet)
        else:
            var from=packet.get("actor")
            if from is String and from!=session.actor:_show_effect(from,packet)
        return
    if packet.get("kind")!="player_visual":return
    if not valid_packet(packet):return
    if session.hosting:
        if state==null or state.members.get(actor,{}).get("area","")!=packet.area:return
        # Held up on a phone's link, positions come in bunches: all of them
        # are passed on (the others play them through), unless a sender
        # sends far more than a game does.
        var now=Time.get_ticks_msec()
        var budget:Array=_relay_budget.get_or_add(actor,[RELAY_BURST,now])
        budget[0]=minf(RELAY_BURST,float(budget[0])+(now-int(budget[1]))/RELAY_EVERY_MS);budget[1]=now
        if budget[0]<1.0:return
        budget[0]-=1.0
        _relay(peer,actor,packet)
    else:
        var remote_actor=packet.get("actor")
        if remote_actor is String and remote_actor!=session.actor:_show(remote_actor,packet)

## Packets as read (coop_remote_player.gd unpack) are new each time and never
## changed after, though one shares the parts that did not change with the
## one before: they are kept and passed on without deep copies.
func _relay(sender_peer:int,actor:String,packet:Dictionary)->void:
    var outgoing=packet.duplicate()
    outgoing["actor"]=actor
    _last_received[actor]=Time.get_ticks_msec()
    last_packets[actor]=outgoing
    presence_received.emit(actor,outgoing)
    var targets:Array=[]
    for peer in session.players:
        if peer==1 or peer==sender_peer:continue
        var other_actor=String(session.players[peer].actor)
        if state!=null and state.members.get(other_actor,{}).get("area","")==packet.area:targets.append(peer)
    # Packed once for all of them (coop_transport.gd send_visual).
    session.transport.send_visual(targets,outgoing)
    if actor!=session.actor and not Server.active:_show(actor,outgoing)

func _show(actor:String,packet:Dictionary)->void:
    last_packets[actor]=packet
    _last_received[actor]=Time.get_ticks_msec()
    if packet.area!=area or packet.get("layer","")!=_layer():
        if actors.has(actor):
            if is_instance_valid(actors[actor]):actors[actor].queue_free()
            actors.erase(actor)
        return
    if not actors.has(actor):
        # Someone new in sight: they have not seen this player yet either.
        _last_sent_at=0
        var remote=Remote.new()
        main.world.add_child(remote);remote.configure(main)
        actors[actor]=remote
    _last_received[actor]=Time.get_ticks_msec()
    var visual:Dictionary=packet.visual.duplicate()
    visual["battle"]=bool(packet.get("battle",false));visual["afk"]=bool(packet.get("afk",false))
    if packet.has("t"):visual["sent"]=packet.t
    # Where the trainer stands, for not carrying them on into a wall.
    visual["bx"]=float(packet.get("body_x",0.0));visual["by"]=float(packet.get("body_y",0.0))
    actors[actor].receive(visual)
    # Other players leave the same sand and snow footprints the local player does.
    var cell:=Vector2i(int(packet.get("cell_x",0)),int(packet.get("cell_y",0)))
    if _last_cells.has(actor) and _last_cells[actor]!=cell:
        preload("res://scripts/source_footprints.gd").leave_at(main.world,_last_cells[actor],cell,
            Vector2(float(packet.get("body_x",0.0)),float(packet.get("body_y",0.0))),
            Vector2i(int(visual.get("fx",0)),int(visual.get("fy",1))),String(visual.get("move","")))
    _last_cells[actor]=cell

## One-off things the other players should see happen: a thrown ball, a tree
## splitting as it is cut. Sent once, shown, and forgotten.
var _throws:Dictionary={}
var _ball_textures:Dictionary={}

func effect(data:Dictionary)->void:
    if main==null or session==null or not session.trusted or area.is_empty():return
    var packet:=data.duplicate(true)
    packet["kind"]="player_effect";packet["area"]=area;packet["layer"]=_layer()
    if session.hosting:_relay_effect(1,session.actor,packet)
    else:session.send_host(packet)

func _relay_effect(sender_peer:int,actor:String,packet:Dictionary)->void:
    var outgoing=packet.duplicate(true)
    outgoing["actor"]=actor
    for peer in session.players:
        if peer==1 or peer==sender_peer:continue
        var other_actor=String(session.players[peer].actor)
        if state!=null and state.members.get(other_actor,{}).get("area","")==packet.area:
            session.send_to(peer,outgoing)
    if actor!=session.actor and not Server.active:_show_effect(actor,outgoing)

static func valid_effect(packet:Dictionary)->bool:
    if not packet.get("area") is String or packet.area.length()>80:return false
    if not packet.get("layer") is String or packet.layer.length()>100:return false
    match packet.get("fx"):
        "cut":return _number(packet.get("x")) and _number(packet.get("y"))
        "ball_stop":return _number(packet.get("serial")) and _number(packet.get("count"))
        "ball":
            if not packet.get("ball") is String or packet.ball.length()>32:return false
            for key in ["serial","frames","ox","oy"]:
                if not _number(packet.get(key)):return false
            var cells=packet.get("cells")
            if not cells is Array or cells.size()>32 or cells.size()%2!=0:return false
            for value in cells:
                if not _number(value):return false
            return true
    return false

func _show_effect(actor:String,packet:Dictionary)->void:
    if not main.started or main.generating or packet.area!=area or packet.layer!=_layer():return
    match packet.fx:
        "cut":
            if main.world.exact_world!=null and _layer()=="OVERWORLD":main.world._show_cut_halves(Vector2i(int(packet.x),int(packet.y)))
        "ball":_throw(actor,packet)
        "ball_stop":
            if _throws.has(actor) and int(_throws[actor].serial)==int(packet.serial):_throws[actor].limit=int(packet.count)

func _ball_texture(ball:String)->Texture2D:
    var source=SourceWorldData.texture_for("pokeball1")
    if ball=="POKE BALL":return source
    var key=str(source.get_instance_id())+ball
    if not _ball_textures.has(key):
        _ball_textures[key]=ImageTexture.create_from_image(preload("res://scripts/ball_shell_colors.gd").recolor(TexturePixels.of(source),ball))
    return _ball_textures[key]

## The other player's ball, flown along the same cells at the same speed.
func _throw(actor:String,packet:Dictionary)->void:
    var world=main.world
    var ball:=Sprite2D.new()
    ball.texture=_ball_texture(String(packet.ball))
    ball.texture_filter=CanvasItem.TEXTURE_FILTER_NEAREST
    ball.z_as_relative=false
    world.add_child(ball)
    var entry:={"serial":int(packet.serial),"limit":9999}
    _throws[actor]=entry
    var at:Vector2=world._cell_center(Vector2i(int(packet.ox),int(packet.oy)))
    ball.position=at
    var seconds:=clampi(int(packet.frames),1,10)/60.0
    var cells:Array=packet.cells
    for index in range(0,cells.size(),2):
        # The thrower says where the ball stopped if it hit something on the way.
        if index/2>=int(entry.limit):break
        var cell:=Vector2i(int(cells[index]),int(cells[index+1]))
        var end:Vector2=world._cell_center(cell)
        var elapsed:=0.0
        while elapsed<seconds:
            await get_tree().process_frame
            if not is_instance_valid(ball):return
            elapsed+=get_process_delta_time()
            var ratio:=minf(1.0,elapsed/seconds)
            ball.position=at.lerp(end,ratio)+Vector2(0,-sin(ratio*PI)*3)
            ball.z_index=world._depth_z(cell,22)
        at=end
    await get_tree().create_timer(0.25).timeout
    if is_instance_valid(ball):ball.queue_free()
    if _throws.get(actor) is Dictionary and int(_throws[actor].serial)==int(entry.serial):_throws.erase(actor)

func _remove(actor:String)->void:
    if actors.has(actor):
        if is_instance_valid(actors[actor]):actors[actor].queue_free()
        actors.erase(actor)
    last_packets.erase(actor);_last_received.erase(actor);_last_cells.erase(actor);_relay_budget.erase(actor)

static func valid_packet(packet:Dictionary)->bool:
    if not _number(packet.get("field_level",1)) or float(packet.get("field_level",1))<1 or float(packet.get("field_level",1))>100:return false
    if not _number(packet.get("party_level",1)) or float(packet.get("party_level",1))<1 or float(packet.get("party_level",1))>100:return false
    if not packet.get("area") is String or packet.area.length()>80:return false
    if not packet.get("layer") is String or packet.layer.length()>100:return false
    if not packet.get("population_scope","OVERWORLD") is String or packet.get("population_scope","OVERWORLD").length()>100:return false
    if not _number(packet.get("cell_x",0)) or not _number(packet.get("cell_y",0)):return false
    if not _number(packet.get("helper_slot",-1)) or int(packet.get("helper_slot",-1)) not in [-1,0,1,2,3,4,5]:return false
    for key in ["body_x","body_y","t"]:
        if packet.has(key) and not _number(packet[key]):return false
    var visual=packet.get("visual")
    if not visual is Dictionary or not visual.get("parts") is Dictionary:return false
    if not preload("res://scripts/coop_night_visuals.gd").valid(visual.get("night",[])):return false
    if visual.parts.size()>5:return false
    for key in ["model","color","fx","fy"]:
        if not _number(visual.get(key)):return false
    for key in ["move","helper_species","follower_species","helper_form","follower_form","thrown_species","thrown_form","pose"]:
        if not visual.get(key,"") is String or String(visual.get(key,"")).length()>48:return false
    for key in visual.parts:
        if key not in ["player","helper","follower","rest","thrown"]:return false
        var part=visual.parts[key]
        if not part is Dictionary:return false
        for coordinate in ["x","y","z","frame","hframes","vframes","ox","oy","s"]:
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

## How close two players' feet may come: an oval about the size of a
## trainer's body. It was a 32x32 square, whose corners stopped a player well
## short of the other one's head or shoulder.
const BODY_REACH:=Vector2(11.0,10.0)

static func _clip_player_step(before:Vector2,after:Vector2,center:Vector2)->Vector2:
    var to:=(after-center)/BODY_REACH
    if to.length_squared()>=1.0:return after
    var from:=(before-center)/BODY_REACH
    if from.length_squared()<1.0:
        # Shared spawn/late packets must allow a player to walk out of overlap.
        return after if to.length_squared()>from.length_squared() else before
    # The step would end inside the other player, so it follows the edge of
    # the oval instead: the same length of step, taken along the curve. Walking
    # into a shoulder carries on round it in one smooth line at walking speed.
    # The earlier version stepped sideways and forwards in turn, which shook
    # the screen. Square on to the other player there is no side to take, and
    # the step eases to a stop.
    var step:=after-before
    var out:=from.normalized()
    var along:=Vector2(-out.y,out.x)
    var heading:=along.dot((step/BODY_REACH).normalized())
    if heading<0.0:
        along=-along
        heading=-heading
    var pace:=clampf((heading-0.1)/0.3,0.0,1.0)
    var reached:=before+(along*BODY_REACH).normalized()*step.length()*pace
    var placed:=(reached-center)/BODY_REACH
    if placed.length_squared()<0.0001:return before
    return center+placed.normalized()*maxf(1.0,from.length())*BODY_REACH
