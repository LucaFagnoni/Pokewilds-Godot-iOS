extends Control
## Java's temporary tile marker, scoped to the island and interior.
const HOLD_MS:=500
const LIFETIME:=30.0 # Java retains a ping for 1800 frames at 60 Hz.
## The yellow tile marker and its edge-of-screen pointer are switched off: other
## players are shown on the minimap and map instead. Set true to bring it back.
const ENABLED:=false
var game:Node
var held_since:=-1
var sent:=false
var markers:Dictionary={}
var last_sent:Dictionary={}

func configure(coordinator:Node)->void:
    game=coordinator;mouse_filter=Control.MOUSE_FILTER_IGNORE
    set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    game.session.message.connect(_message)
    game.session.departed.connect(func(_peer,actor):markers.erase(actor);last_sent.erase(actor))
    process_mode=Node.PROCESS_MODE_ALWAYS

func _input(event:InputEvent)->void:
    if not ENABLED:return
    if event is InputEventJoypadButton and event.button_index==JOY_BUTTON_DPAD_UP:
        held_since=Time.get_ticks_msec() if event.pressed else -1
        sent=false

func _process(_delta:float)->void:
    if not ENABLED:
        visible=false;held_since=-1;markers.clear();return
    visible=game.active and game.session.trusted and game.main.started and not game.main.generating and not game.main._field_ui_blocks_gameplay()
    if not visible:held_since=-1;return
    if held_since>=0 and not sent and Time.get_ticks_msec()-held_since>=HOLD_MS:
        sent=true
        var cell:Vector2i=game.main.world._player_cell()+game.main.world._facing_cell()
        var packet={"kind":"tile_ping","area":game._area(),"layer":game.visuals._layer(),"x":cell.x,"y":cell.y}
        if game.hosting:_relay(game.session.actor,packet)
        else:game.session.send_host(packet)
    var now=game.world_time(0)
    for actor in markers.keys():
        if now>=float(markers[actor].until):markers.erase(actor)
    queue_redraw()

func _message(_peer:int,actor:String,packet:Dictionary)->void:
    if not ENABLED or packet.get("kind")!="tile_ping":return
    if game.hosting:_relay(actor,packet)
    elif packet.get("actor") is String and typeof(packet.get("until")) in [TYPE_INT,TYPE_FLOAT]:
        markers[packet.actor]=packet

func _relay(actor:String,packet:Dictionary)->void:
    if not packet.get("area") is String or not packet.get("layer") is String:return
    for key in ["x","y"]:
        var value=packet.get(key)
        if not preload("res://scripts/coop_players.gd")._number(value) or float(value)!=floor(float(value)):return
    var presence:Dictionary=game.commands.presence.get(actor,{})
    if presence.get("area")!=packet.area+"|"+packet.layer:return
    if absi(int(presence.x)-int(packet.x))+absi(int(presence.y)-int(packet.y))>2:return
    var now=Time.get_ticks_msec()
    if now-int(last_sent.get(actor,-1000))<500:return
    last_sent[actor]=now
    var outgoing={"kind":"tile_ping","actor":actor,"area":packet.area,"layer":packet.layer,
        "x":int(packet.x),"y":int(packet.y),"until":game.clock_seconds+LIFETIME,
        "name":String(game.state.members.get(actor,{}).get("name","PLAYER")).substr(0,24)}
    markers[actor]=outgoing
    for peer in game.session.players:
        if peer==1:continue
        var recipient=game.session.players[peer].actor
        if game.state.members.get(recipient,{}).get("area")==packet.area:game.session.send_to(peer,outgoing)

static func edge_position(point:Vector2,rect:Rect2)->Vector2:
    var center=rect.get_center()
    var ray=point-center
    var half=rect.size*0.5
    var scale_value=minf(half.x/maxf(absf(ray.x),0.001),half.y/maxf(absf(ray.y),0.001))
    return center+ray*minf(1.0,scale_value)

func _draw()->void:
    if not visible or game==null:return
    var rect=Rect2(Vector2(12,12),size-Vector2(24,24))
    for marker in markers.values():
        if marker.area!=game._area() or marker.layer!=game.visuals._layer():continue
        var cell=Vector2i(int(marker.x),int(marker.y))
        var point:Vector2=game.main.world.get_global_transform_with_canvas()*game.main.world._cell_center(cell)
        var color=Color.YELLOW if int(game.world_time(0)*4)%2==0 else Color.WHITE
        if rect.has_point(point):
            draw_rect(Rect2(point-Vector2(6,6),Vector2(12,12)),Color(0,0,0,0.6))
            draw_rect(Rect2(point-Vector2(4,4),Vector2(8,8)),color)
            draw_string(game.main.JOHTO_FONT,point+Vector2(-12,-9),String(marker.name),HORIZONTAL_ALIGNMENT_LEFT,-1,8,color)
        else:
            var edge=edge_position(point,rect)
            var direction=(point-rect.get_center()).normalized()
            var normal=direction.orthogonal()
            draw_colored_polygon(PackedVector2Array([edge+direction*5,edge-direction*4+normal*4,edge-direction*4-normal*4]),color)
