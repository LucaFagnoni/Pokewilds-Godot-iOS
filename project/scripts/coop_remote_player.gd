extends Node2D
## Visual-only remote actor. It never reads local input or changes world collision.
const Pokemon=preload("res://scripts/pokemon_data.gd")
const MountLayers=preload("res://scripts/mount_layers.gd")
## Snapshot interpolation. Every packet says when its sender captured it
## ("sent", the sender's clock). The player is drawn as they were at `_clock`,
## a time on that clock which follows (now - _base - delay): _base is the
## shortest time a packet has taken to get here, the delay covers the jitter
## seen since (DELAY_MIN_MS to DELAY_MAX_MS). Packets held up on the way and
## arriving together are played through faster (up to CATCH_UP) instead of
## skipped; with none left, a walking player goes on for EXTRAPOLATE_MS (at
## most EXTRAPOLATE_PX, not into a tile they could not enter) and is then
## held. The clock never runs backwards.
## coop_players.gd SEND_INTERVAL_MS, and a gap that means nothing was sent.
const SEND_INTERVAL_MS:=50
const HOLD_GAP_MS:=200
const DELAY_MIN_MS:=100.0
const DELAY_MAX_MS:=200.0
const EXTRAPOLATE_MS:=150.0
## Half a tile: a guess past a corner they turned at is that far off at most.
const EXTRAPOLATE_PX:=8.0
const CATCH_UP:=1.5
## How far behind (ms) before the clock gives up playing through and jumps.
const RESYNC_MS:=3000.0
## A step faster than twice anyone moves (120 px/s riding or flying), plus a
## ledge hop, is a teleport (recall, warp): drawn there at once, not flown to.
const TELEPORT_PX_PER_MS:=0.24
const TELEPORT_SLACK_PX:=32.0
## Off screen by more than this (a sprite's size and 2 tiles), nothing is drawn.
const CULL_MARGIN_PX:=64.0
## Half the widest light (Flash: 160 px at 1.2x, world_environment_system.gd):
## one giving light is drawn until that far out.
const LIGHT_REACH_PX:=96.0

static func _number(value:Variant)->bool:
    return (value is int or value is float) and is_finite(float(value))
class Rider extends Node2D:
    var sprite:Sprite2D
var player:Rider
var field_helper_sprite:Sprite2D
var follower_sprite:Sprite2D
var active_field_move:=""
var active_field_species:=""
var _facing:=Vector2i.DOWN
var _main:Node
var _parts:Dictionary={}
var _frames:Array=[]
var _shadow:Polygon2D
var _status:Node2D
var _afk:Label
var _in_battle:=false
var _pose_cache:Dictionary={}
var _night=preload("res://scripts/coop_night_visuals.gd").new()
## What advance last drew: [first, second, weight, local z, local y, offset].
var _drawn:Array=[null,null,-1.0,0,0.0,Vector2.ZERO]
var _clock:=-1.0
var _base:=INF
var _jitter:=0.0
var _wrap:=0.0
var _last_now:=-1
var _last_heard:=-1
## What was drawn last frame (INF: nothing, off screen) and the clock then.
var _last_clock:=0.0
var _last_raw:=Vector2.INF
var _heard:=0
var _used:=0
## Drawn this far from the packets for a moment, so a guess past the newest
## one that turned out wrong is eased away instead of jumped back.
var _offset:=Vector2.ZERO
var _lit:=false
## _carries() for the packets as they are (they change only in receive).
var _walking:=false
## The look each part's texture was last set for (_draw_frames).
var _looks:Dictionary={}

func configure(main:Node)->void:
    _main=main
    player=Rider.new();add_child(player)
    player.sprite=Sprite2D.new();player.add_child(player.sprite)
    field_helper_sprite=Sprite2D.new();add_child(field_helper_sprite)
    follower_sprite=Sprite2D.new();add_child(follower_sprite)
    var rest_sprite=Sprite2D.new();add_child(rest_sprite)
    # The Pokemon this player has just thrown out of its ball.
    var thrown_sprite=Sprite2D.new();add_child(thrown_sprite)
    _parts={"player":player.sprite,"helper":field_helper_sprite,"follower":follower_sprite,"rest":rest_sprite,"thrown":thrown_sprite}
    for sprite in _parts.values():
        sprite.texture_filter=CanvasItem.TEXTURE_FILTER_NEAREST
        sprite.z_as_relative=false
        sprite.hide()
    _shadow=Polygon2D.new()
    _shadow.polygon=PackedVector2Array([Vector2(-6,0),Vector2(-5,-2),Vector2(-3,-3),Vector2(3,-3),Vector2(5,-2),Vector2(6,0),Vector2(5,2),Vector2(3,3),Vector2(-3,3),Vector2(-5,2)])
    _shadow.color=Color(0.02,0.02,0.02,0.92)
    _shadow.z_as_relative=false;_shadow.hide();add_child(_shadow)
    _status=Node2D.new();_status.z_as_relative=false;_status.z_index=4095;add_child(_status)
    _status.draw.connect(func():
        if not _in_battle:return
        for direction in [-1,1]:
            _status.draw_line(Vector2(-4*direction,4),Vector2(4*direction,-4),Color.BLACK,3)
            _status.draw_line(Vector2(-4*direction,4),Vector2(4*direction,-4),Color.WHITE,1)
            _status.draw_line(Vector2(-4*direction,0),Vector2(0,4),Color.BLACK,2))
    _afk=Label.new();_afk.text="Zzz";_afk.position=Vector2(-8,-7)
    _afk.add_theme_font_override("font",main.JOHTO_FONT);_afk.add_theme_font_size_override("font_size",8)
    _afk.add_theme_color_override("font_color",Color.WHITE);_afk.add_theme_color_override("font_outline_color",Color.BLACK);_afk.add_theme_constant_override("outline_size",2)
    _status.add_child(_afk);_afk.hide()
    process_mode=Node.PROCESS_MODE_ALWAYS
    physics_interpolation_mode=Node.PHYSICS_INTERPOLATION_MODE_OFF

func receive(snapshot:Dictionary,received_ms:int=-1)->void:
    if _main==null or not snapshot.get("parts") is Dictionary:return
    var now:=float(Time.get_ticks_msec() if received_ms<0 else received_ms)
    # The sender's clock wraps every 1000 s (coop_players.gd); without it
    # (an older game) the time it came is all there is.
    var sent:=now
    if _number(snapshot.get("sent")):
        sent=float(snapshot.sent)+_wrap
        if not _frames.is_empty() and sent<float(_frames[-1].sent)-500000.0:_wrap+=1000000.0;sent+=1000000.0
    if not _frames.is_empty() and sent<=float(_frames[-1].sent):return
    var since:=now-_last_heard if _last_heard>=0 else 0.0
    _last_heard=int(now)
    # The quickest trip so far, let go of slowly (clocks drift, routes change),
    # and how much later than that packets have come lately.
    _base=minf(_base+since*0.01,now-sent)
    _jitter=maxf(now-sent-_base,_jitter-since*0.02)
    # A player standing still sends nothing new (coop_players.gd). When they
    # move again, the last pose is held until one send interval before this,
    # so the first step is not drawn early or slowed down over the pause. A
    # gap while walking is the sender's game held up: walked through.
    if not _frames.is_empty() and not _walking and sent-float(_frames[-1].sent)>HOLD_GAP_MS:
        _frames.append(_frame(sent-SEND_INTERVAL_MS,_frames[-1].data,true))
    _frames.append(_frame(sent,snapshot)) # the caller's own copy (coop_players.gd _show)
    while _frames.size()>64:_frames.pop_front()
    if _clock<0.0:_clock=sent
    _heard+=1
    _walking=_carries()

## A packet as kept: when it was sent, and a box round all it draws (culling).
func _frame(sent:float,data:Dictionary,hold:=false)->Dictionary:
    var points:Array=data.parts.values()
    if data.get("shadow") is Dictionary and not data.shadow.is_empty():points.append(data.shadow)
    if data.get("night") is Array:points.append_array(data.night)
    var box=null
    for point in points:
        var at:=Vector2(float(point.get("x",0)),float(point.get("y",0)))
        box=Rect2(at,Vector2.ZERO) if box==null else box.expand(at)
    return {"sent":sent,"data":data,"hold":hold,"box":box}

func _process(_delta:float)->void:
    var started:=Time.get_ticks_usec()
    advance(Time.get_ticks_msec())
    if _transport==null:_transport=load("res://scripts/coop_transport.gd") # it preloads this script
    if _transport.stats!=null:_transport.count("proc:remote",0,started)

static var _transport:GDScript

## Moves the clock on to `now_ms` and draws the player as they were then;
## off screen only the clock and the packets are kept up.
func advance(now_ms:int)->void:
    if _frames.is_empty():return
    var elapsed:=clampf(now_ms-_last_now,0.0,250.0) if _last_now>=0 else 0.0
    _last_now=now_ms
    # New packets can say the last frame was drawn a little off (carried on
    # past the newest one): kept there, and eased to where the player really was.
    if _heard!=_used and _last_raw.x!=INF:
        _used=_heard
        var miss:=_last_raw-_raw(_sample(_last_clock))
        _offset=_offset+miss if miss.length()<24.0 else Vector2.ZERO
    _offset=_offset*exp(-elapsed/120.0) if _offset.length_squared()>0.01 else Vector2.ZERO
    var target:=now_ms-_base-clampf(_jitter+SEND_INTERVAL_MS,DELAY_MIN_MS,DELAY_MAX_MS)
    # Across a pause (the pose held to the next packet) nothing moves: skipped.
    var index:=_index(_clock)
    if index+1<_frames.size() and _frames[index+1].hold:_clock=maxf(_clock,minf(target,float(_frames[index+1].sent)))
    var behind:=target-_clock
    var was:=_clock
    if behind>RESYNC_MS:_clock=target
    else:_clock+=elapsed*clampf(1.0+behind/400.0,0.75,CATCH_UP)
    _clock=maxf(was,minf(_clock,float(_frames[-1].sent)+(EXTRAPOLATE_MS if _walking else 0.0)))
    while _frames.size()>2 and float(_frames[1].sent)<=_clock:_frames.pop_front()
    # Off screen (with a margin, wider for one giving light), only the clock
    # runs: drawn again where it should be on the frame it comes into view.
    var box=_frames[-1].box if _frames.size()<3 else _frames[1].box
    if box!=null and _frames[0].box!=null:box=box.merge(_frames[0].box)
    var view:=get_viewport().get_canvas_transform().affine_inverse()*get_viewport().get_visible_rect()
    if box!=null and not view.intersects(box.grow(CULL_MARGIN_PX+(LIGHT_REACH_PX if _lit else 0.0))):
        if visible:hide()
        _last_raw=Vector2.INF
        return
    if not visible:show();_drawn[0]=null
    var sample:=_sample(_clock)
    _last_clock=_clock
    var first:Dictionary=sample[0];var second:Dictionary=sample[1];var weight:float=sample[2]
    # Standing still, nothing below changes between packets: drawn again only
    # when a packet, the blend or the local player's depth has moved on.
    var mine=_main.world.player
    if not (is_same(first,_drawn[0]) and is_same(second,_drawn[1]) and weight==_drawn[2] and mine.z_index==_drawn[3] and mine.sprite.global_position.y==_drawn[4] and _offset==_drawn[5]):
        _drawn=[first,second,weight,mine.z_index,mine.sprite.global_position.y,_offset]
        _draw_frames(first,second,weight)
    _update_light(second.data)

## The last packet sent at or before `clock` (the first if none is).
func _index(clock:float)->int:
    var index:=0
    while index+1<_frames.size() and float(_frames[index+1].sent)<=clock:index+=1
    return index

## [first, second, weight]: drawn `weight` of the way from packet `first` to
## `second`; past 1 it is carried on past the newest packet, `second`.
func _sample(clock:float)->Array:
    var index:=_index(clock)
    var first:Dictionary=_frames[index]
    if index+1<_frames.size():
        var second:Dictionary=_frames[index+1]
        return [first,second,clampf((clock-float(first.sent))/maxf(1.0,float(second.sent)-float(first.sent)),0.0,1.0)]
    if index==0:return [first,first,1.0]
    var before:Dictionary=_frames[index-1]
    var ahead:=minf(clock-float(first.sent),EXTRAPOLATE_MS)
    if ahead<=0.0 or not _walking:return [before,first,1.0]
    var span:=float(first.sent)-float(before.sent)
    var a:Dictionary=before.data.parts.player;var b:Dictionary=first.data.parts.player
    var step:=Vector2(float(b.get("x",0)),float(b.get("y",0))).distance_to(Vector2(float(a.get("x",0)),float(a.get("y",0))))
    ahead=minf(ahead,EXTRAPOLATE_PX*span/step)
    return [before,first,1.0+_open_ahead(before.data,first.data,span,ahead)/span]

## Walking when the last packet came: the last two a send interval or so
## apart, and the trainer moved between them (not a teleport). Stopping sends
## the same pose once more (coop_players.gd), which is not walking.
func _carries()->bool:
    if _frames.size()<2:return false
    var before:Dictionary=_frames[-2];var last:Dictionary=_frames[-1]
    var span:=float(last.sent)-float(before.sent)
    var a=before.data.parts.get("player");var b=last.data.parts.get("player")
    if before.hold or span>3.0*SEND_INTERVAL_MS or not a is Dictionary or not b is Dictionary:return false
    var step:=Vector2(float(b.get("x",0)),float(b.get("y",0))).distance_to(Vector2(float(a.get("x",0)),float(a.get("y",0))))
    return step>0.01 and step<=TELEPORT_SLACK_PX+TELEPORT_PX_PER_MS*span

## How far (ms, up to `ahead`) the player can be carried on without going
## into a tile they could not have entered: up to the edge of their own.
func _open_ahead(before:Dictionary,last:Dictionary,span:float,ahead:float)->float:
    var world=_main.world
    if not _main.started or String(last.get("move",""))=="FLY" or not _number(last.get("bx")) or not _number(before.get("bx")):return ahead
    var from:=Vector2(float(last.bx),float(last.by))
    var velocity:=(from-Vector2(float(before.bx),float(before.by)))/span
    var cell:=Vector2i((from/16.0).floor())
    var to:=Vector2i(((from+velocity*ahead)/16.0).floor())
    if to==cell or world._is_walkable(to)==world._is_walkable(cell):return ahead
    for axis in 2:
        if absf(velocity[axis])<0.0001:continue
        var edge:=(cell[axis]+(1 if velocity[axis]>0.0 else 0))*16.0
        ahead=minf(ahead,(edge-from[axis])/velocity[axis]-0.5/absf(velocity[axis]))
    return maxf(0.0,ahead)

## Where the trainer is in a _sample, before rounding and the eased offset.
func _raw(sample:Array)->Vector2:
    var own=(sample[1] if sample[2]>=0.5 else sample[0]).data.parts.get("player")
    if not own is Dictionary:return _last_raw
    return _between(sample[0].data.parts.get("player"),sample[1].data.parts.get("player"),own,sample[2],float(sample[1].sent)-float(sample[0].sent))

## `weight` of the way from part `a` to `b`, or where `own` (the nearer
## packet's) is when they are a teleport apart or one is missing.
static func _between(a:Variant,b:Variant,own:Dictionary,weight:float,span:float)->Vector2:
    var at:=Vector2(float(own.get("x",0)),float(own.get("y",0)))
    if not a is Dictionary or not b is Dictionary or a.is_empty() or b.is_empty():return at
    var from:=Vector2(float(a.get("x",0)),float(a.get("y",0)));var to:=Vector2(float(b.get("x",0)),float(b.get("y",0)))
    return from.lerp(to,weight) if from.distance_to(to)<=TELEPORT_SLACK_PX+TELEPORT_PX_PER_MS*span else at

## Draws the blend `weight` of the way from packet `first` to `second`: where
## things are in between, what they look like as in the nearer of the two.
func _draw_frames(first:Dictionary,second:Dictionary,weight:float)->void:
    var data:Dictionary=second.data if weight>=0.5 else first.data
    var span:=float(second.sent)-float(first.sent)
    var model=clampi(int(data.get("model",0)),0,_main.PLAYER_MODEL_WALK_TEXTURES.size()-1)
    var color=clampi(int(data.get("color",0)),0,_main.PLAYER_COLOR_VALUES.size()-1)
    active_field_move=String(data.get("move",""))
    active_field_species=String(data.get("helper_species",""))
    _facing=Vector2i(int(data.get("fx",0)),int(data.get("fy",1)))
    for key in _parts:
        var sprite:Sprite2D=_parts[key]
        var part:Dictionary=data.parts.get(key,{})
        sprite.visible=not part.is_empty()
        if not sprite.visible:continue
        # Which picture a part shows changes far less often than where it is:
        # it is looked up (recoloured, cropped) only when it does.
        var look:Array=[model,color,data.get("running"),data.get("pose"),data.get("pose_frame"),data.get(key+"_species"),data.get(key+"_form"),data.get(key+"_shiny")]
        if _looks.get(key)==look:pass
        elif key=="player":
            var running=bool(data.get("running",false))
            var base:Texture2D=_main.lazy_texture((_main.PLAYER_MODEL_RUN_TEXTURES if running else _main.PLAYER_MODEL_WALK_TEXTURES)[model])
            var pose=String(data.get("pose","walk"))
            if pose=="sit":base=_main.lazy_texture(_main.PLAYER_MODEL_SITTING_TEXTURES[model])
            elif pose=="sleep":base=_main.lazy_texture(_main.PLAYER_MODEL_SLEEP_TEXTURES[model])
            var pose_key="coop:%d:%d:%s:%s"%[model,color,running,pose]
            sprite.texture=_main._recolor_texture(base,_main.PLAYER_MODEL_REPLACE_COLORS[model],_main.PLAYER_COLOR_VALUES[color],pose_key)
            if pose=="sit":
                var pose_frame=clampi(int(data.get("pose_frame",0)),0,2)
                var cache_key=pose_key+str(pose_frame)
                if not _pose_cache.has(cache_key):_pose_cache[cache_key]=_main._source_texture_region(sprite.texture,Rect2(pose_frame*16,0,16,16))
                sprite.texture=_pose_cache[cache_key]
            elif pose=="bed" or pose=="sleep":
                var cache_key=pose_key+":crop"
                if not _pose_cache.has(cache_key):
                    _pose_cache[cache_key]=_main._source_texture_region(sprite.texture,Rect2(0,0,16,6)) if pose=="bed" else (_main._source_texture_region(sprite.texture,Rect2(0,0,24,16)) if sprite.texture.get_height()>16 else sprite.texture)
                sprite.texture=_pose_cache[cache_key]
        elif key=="rest":
            sprite.texture=_main.world.SOURCE_SLEEPING_BAG
        else:
            var species=String(data.get(key+"_species",""))
            var shiny:=bool(data.get(key+"_shiny",false))
            sprite.texture=Pokemon.record_texture({"species":species,"form":String(data.get(key+"_form","")),"shiny":shiny},"overworld")
            # The same sparkles a shiny follower or helper has on its owner's screen.
            var sparkles:=sprite.get_node_or_null("ShinySparkles")
            if shiny and sparkles==null:preload("res://scripts/shiny_sparkles.gd").attach(sprite,{"species":species,"shiny":true})
            elif not shiny and sparkles!=null:sparkles.name="ShinySparklesGone";sparkles.queue_free()
        _looks[key]=look
        if sprite.texture==null:sprite.hide();continue
        sprite.hframes=clampi(int(part.get("hframes",1)),1,sprite.texture.get_width())
        sprite.vframes=clampi(int(part.get("vframes",1)),1,sprite.texture.get_height())
        sprite.frame=clampi(int(part.get("frame",0)),0,sprite.hframes*sprite.vframes-1)
        sprite.flip_h=bool(part.get("flip_h",false))
        sprite.centered=bool(part.get("centered",true))
        sprite.offset=Vector2(float(part.get("ox",0)),float(part.get("oy",0)))
        if key=="thrown":sprite.scale=Vector2.ONE*clampf(float(part.get("s",1.0)),0.0,2.0)
        var at:=_between(first.data.parts.get(key),second.data.parts.get(key),part,weight,span)
        if key=="player":_last_raw=at
        sprite.global_position=(at+_offset).round()
        sprite.z_index=clampi(int(part.get("z",0)),-4096,4094)
        # Two trainers on the ground: the one standing lower on the screen is
        # nearer the camera and is drawn in front, on both players' screens.
        # Each game used its own fixed layer, so one of the two always showed
        # the far trainer's feet on top of the near trainer's head.
        if key=="player":
            var mine=_main.world.player
            if sprite.z_index<1000 and mine.z_index<1000:
                sprite.z_index=mine.z_index+(1 if sprite.global_position.y>mine.sprite.global_position.y else -1)
    player.z_index=player.sprite.z_index
    var head=field_helper_sprite.get_node_or_null("RiderHead")
    if head!=null:head.hide()
    if field_helper_sprite.visible and player.sprite.visible and active_field_move in ["FLY","SURF","RIDE"]:
        MountLayers.apply(self)
    var shadow:Dictionary=data.get("shadow",{})
    _shadow.visible=not shadow.is_empty()
    if _shadow.visible:
        _shadow.global_position=(_between(first.data.get("shadow"),second.data.get("shadow"),shadow,weight,span)+_offset).round()
        _shadow.z_index=clampi(int(shadow.get("z",0)),-4096,4094)
    _status.global_position=player.sprite.global_position+Vector2(0,-19)
    _night.draw(self,second.data.get("night",[]),first.data.get("night",[]),minf(weight,1.0))
    var battle=bool(data.get("battle",false))
    if battle!=_in_battle:_in_battle=battle;_status.queue_redraw()
    _afk.visible=not battle and (bool(data.get("afk",false)) or bool(data.get("sleeping",false)))

func _update_light(data:Dictionary)->void:
    var environment=_main.world.environment_system
    if is_instance_valid(environment):
        var flash=active_field_move in ["FLASH","POWER"]
        var fire=follower_sprite.visible and "FIRE" in Pokemon.info(String(data.get("follower_species",""))).get("types",[])
        _lit=flash or fire
        var darkness:Color=environment.canvas_modulate.color
        # Drawn into the world's light map with the other lights.
        if (flash or fire) and maxf(darkness.r,maxf(darkness.g,darkness.b))<0.94:
            environment.set_extra_light(self,[player.sprite.global_position if flash else follower_sprite.global_position,not flash,1.2 if flash else 1.0,
                Color(1.0,0.82,0.55)*1.15 if flash else Color(1.0,0.68,0.34)*0.82])
        else:environment.set_extra_light(self,[])

func _facing_cell()->Vector2i:return _facing

static func capture(main:Node)->Dictionary:
    var world=main.world
    var result={"model":main.player_model_index,"color":main.player_color_index,
        "running":world.player.using_run_texture,"move":world.active_field_move,
        "fx":int(world.player.facing.x),"fy":int(world.player.facing.y),"parts":{},"shadow":{},
        "helper_species":String(world.field_helper_pokemon.get("species","")),
        "helper_shiny":bool(world.field_helper_pokemon.get("shiny",false)),
        "helper_form":String(world.field_helper_pokemon.get("form","")),
        "follower_species":String(world.follower_pokemon.get("species","")),
        "follower_shiny":bool(world.follower_pokemon.get("shiny",false)),"follower_form":String(world.follower_pokemon.get("form",""))}
    var sprites={"player":world.player.sprite,"helper":world.field_helper_sprite,"follower":world.follower_sprite}
    if is_instance_valid(world.work_trainer_sprite) and world.work_trainer_sprite.visible:sprites.player=world.work_trainer_sprite
    if is_instance_valid(world.stool_seated_sprite) and world.stool_seated_sprite.visible:
        sprites.player=world.stool_seated_sprite;result["pose"]="sit"
        result["pose_frame"]=int(world.stool_seated_sprite.texture.region.position.x/16) if world.stool_seated_sprite.texture is AtlasTexture else 0
    if is_instance_valid(world.sleeping_bag_sprite) and world.sleeping_bag_sprite.visible:
        result["sleeping"]=true
        if world.bed_rest_active or not world.player.visible:
            sprites.player=world.sleeping_bag_sprite
            result["pose"]="bed" if world.bed_rest_active else "sleep"
            result["running"]=false
        else:sprites["rest"]=world.sleeping_bag_sprite
    # A Pokemon thrown out of its ball stands on the ground for a moment before
    # its trainer hops on. Without it the others saw a leap onto nothing.
    var balls=main.get("ball_mechanics")
    if is_instance_valid(balls) and is_instance_valid(balls.actor) and balls.actor.visible and not balls.actor_member.is_empty():
        sprites["thrown"]=balls.actor
        result["thrown_species"]=String(balls.actor_member.get("species",""))
        result["thrown_shiny"]=Pokemon.is_shiny(balls.actor_member)
        result["thrown_form"]=String(balls.actor_member.get("form",""))
    for key in sprites:
        var sprite=sprites[key]
        if not is_instance_valid(sprite) or not sprite.visible:continue
        result.parts[key]={"x":sprite.global_position.x,"y":sprite.global_position.y,"z":sprite.z_index,
            "frame":sprite.frame,"hframes":sprite.hframes,"vframes":sprite.vframes,"flip_h":sprite.flip_h,
            "ox":sprite.offset.x,"oy":sprite.offset.y,"centered":sprite.centered}
        if sprite==world.player.sprite:result.parts[key].z=world.player.z_index
        if key=="thrown":result.parts[key]["s"]=sprite.scale.x
    if is_instance_valid(world.fly_shadow) and world.fly_shadow.visible:
        result.shadow={"x":world.fly_shadow.global_position.x,"y":world.fly_shadow.global_position.y,"z":world.fly_shadow.z_index}
    result["night"]=preload("res://scripts/coop_night_visuals.gd").capture(world)
    return result

## player_visual on the wire (coop_transport.gd): bytes instead of JSON. A
## frame is WIRE_TAG and the whole packet, or WIRE_DELTA and only what changed
## since the last one on the same connection from the same player. That player
## (the "stream": the relayed player's id, "" for one's own) is given whole
## as a value (below) and a slot byte, the sender's number for it; a delta
## names only the slot (255: none, always whole). Then the groups of keys: the
## packet, its visual, its parts (a group of groups), its shadow and its night sprites.
## Whole, a group is a 32-bit mask of the keys present, then their values in
## this order: a type byte (0 false, 1 true, 2 float32, 3 UTF-8 text under 256
## bytes, 4 lowercase hex text as its bytes, 5 int8, 6 int16) and the value.
## In a delta each group starts with a byte: 0 as in the last packet, 1 whole,
## 2 the same keys with only the changed ones sent (mask, values; a changed part
## is itself a group). The night sprites go whole (1) or not at all (0).
## A walking player's update is ~40 bytes instead of ~170 whole.
## A packet that does not fit (any other key or type, a number a float32 does
## not hold exactly) goes as JSON. Read back, numbers are floats as JSON gave
## them, and the packet still goes through coop_players.valid_packet before use.
## TCP keeps the frames in order, so both ends hold the same last packet: the
## sender's (coop_transport.gd `sent`) only once its frame is queued, the
## receiver's once read; both go with the connection. A delta with nothing to
## apply to is a broken connection.
const WIRE_TAG:=1
const WIRE_DELTA:=3
const WIRE_MAX_BYTES:=16384
const WIRE_TOP:=["area","layer","population_scope","battle","afk","cell_x","cell_y","body_x","body_y","helper_slot","field_level","party_level","t"]
const WIRE_VISUAL:=["model","color","running","move","fx","fy","helper_species","helper_shiny","helper_form","follower_species","follower_shiny","follower_form","pose","pose_frame","sleeping","thrown_species","thrown_shiny","thrown_form"]
const WIRE_PARTS:=["player","helper","follower","rest","thrown"]
const WIRE_PART:=["x","y","z","frame","hframes","vframes","flip_h","centered","ox","oy","s"]
const WIRE_SHADOW:=["x","y","z"]
const WIRE_NIGHT:=["id","texture","x","y","z","visible","centered","flip_h","hframes","vframes","frame","region","rx","ry","rw","rh"]

## The packet as bytes, or empty when it has to go as JSON. With `base` (the
## last packet sent to this connection for this player) only what changed.
static func pack(packet:Dictionary,base:Variant=null,slot:int=255)->PackedByteArray:
    var visual=packet.get("visual")
    if packet.get("kind")!="player_visual" or not visual is Dictionary or not visual.get("parts") is Dictionary or not visual.get("shadow") is Dictionary \
            or not visual.get("night") is Array or visual.night.size()>64 or not packet.get("actor","") is String:return PackedByteArray()
    if slot<0 or slot>=255:base=null
    var old=base.visual if base is Dictionary else null
    var out:=PackedByteArray([WIRE_DELTA if old!=null else WIRE_TAG])
    if old==null and not _value(out,packet.get("actor","")):return PackedByteArray()
    out.append(clampi(slot,0,255))
    if not (_group(out,packet,base,WIRE_TOP,["kind","visual","actor"]) and _group(out,visual,old,WIRE_VISUAL,["parts","shadow","night"]) \
            and _group(out,visual.parts,old.parts if old!=null else null,WIRE_PARTS,[],WIRE_PART) and _group(out,visual.shadow,old.shadow if old!=null else null,WIRE_SHADOW)):return PackedByteArray()
    if old!=null:
        if visual.night==old.night:out.append(0);return out if out.size()<=WIRE_MAX_BYTES else PackedByteArray()
        out.append(1)
    out.append(visual.night.size())
    for entry in visual.night:
        if not entry is Dictionary or not _pack(out,entry,WIRE_NIGHT):return PackedByteArray()
    return out if out.size()<=WIRE_MAX_BYTES else PackedByteArray()

## One group: whole without a base, else as one of the delta forms.
static func _group(out:PackedByteArray,data:Dictionary,base:Variant,keys:Array,skip:Array=[],inner:Array=[])->bool:
    if base==null:return _pack(out,data,keys,skip,inner)
    if not base is Dictionary or not _same_keys(data,base,skip):out.append(1);return _pack(out,data,keys,skip,inner)
    var mask:=0
    for index in keys.size():
        if data.has(keys[index]) and not _equal(data[keys[index]],base[keys[index]]):mask|=1<<index
    if mask==0:out.append(0);return true
    out.append(2);out.resize(out.size()+4);out.encode_u32(out.size()-4,mask)
    for index in keys.size():
        if mask&(1<<index)==0:continue
        var value=data[keys[index]]
        if not inner.is_empty():
            if not value is Dictionary or not _group(out,value,base[keys[index]],inner):return false
        elif not _value(out,value):return false
    return true

static func _same_keys(data:Dictionary,base:Dictionary,skip:Array)->bool:
    for key in data:
        if not key in skip and not base.has(key):return false
    for key in base:
        if not key in skip and not data.has(key):return false
    return true

## Same value as sent: 1 and 1.0 are, true and 1 are not.
static func _equal(a:Variant,b:Variant)->bool:
    if (a is int or a is float) and (b is int or b is float):return float(a)==float(b)
    return typeof(a)==typeof(b) and a==b

static func _pack(out:PackedByteArray,data:Dictionary,keys:Array,skip:Array=[],inner:Array=[])->bool:
    var mask:=0
    for key in data:
        var index:=keys.find(key)
        if index>=0:mask|=1<<index
        elif not key in skip:return false
    out.resize(out.size()+4);out.encode_u32(out.size()-4,mask)
    for key in keys:
        if not data.has(key):continue
        var value=data[key]
        if not inner.is_empty():
            if not value is Dictionary or not _pack(out,value,inner):return false
        elif not _value(out,value):return false
    return true

static func _value(out:PackedByteArray,value:Variant)->bool:
    if value is bool:out.append(1 if value else 0);return true
    if (value is int or value is float) and is_finite(float(value)):
        var number:=float(value)
        if number==floorf(number) and absf(number)<=32767:
            if absf(number)<=127:out.append(5);out.append(int(number)&0xFF)
            else:out.append(6);out.resize(out.size()+2);out.encode_s16(out.size()-2,int(number))
            return true
        out.append(2);out.resize(out.size()+4);out.encode_float(out.size()-4,number)
        return out.decode_float(out.size()-4)==number
    if not value is String:return false
    var text:String=value
    if text.length()>=2 and text.length()%2==0 and text.length()<512 and text==text.to_lower() and text.is_valid_hex_number():
        var raw:=text.hex_decode()
        if raw.hex_encode()==text:out.append(4);out.append(raw.size());out.append_array(raw);return true
    var utf8:=text.to_utf8_buffer()
    if utf8.size()>=256:return false
    out.append(3);out.append(utf8.size());out.append_array(utf8)
    return true

## The packet pack() made, or null for anything malformed. `bases` holds the
## last packet read from this connection for each slot; it is updated.
static func unpack(bytes:PackedByteArray,bases:Dictionary={})->Variant:
    if bytes.is_empty() or bytes.size()>WIRE_MAX_BYTES or not bytes[0] in [WIRE_TAG,WIRE_DELTA]:return null
    var at:=[1]
    var stream=_read(bytes,at) if bytes[0]==WIRE_TAG else null
    if (bytes[0]==WIRE_TAG and not stream is String) or int(at[0])>=bytes.size():return null
    var slot:int=bytes[at[0]];at[0]+=1
    var base=bases.get(slot) if bytes[0]==WIRE_DELTA and slot<255 else null
    if bytes[0]==WIRE_DELTA:
        if base==null:return null
        stream=String(base.get("actor",""))
    var old=base.visual if base!=null else null
    var packet=_unread(bytes,at,WIRE_TOP,base)
    var visual=_unread(bytes,at,WIRE_VISUAL,old) if packet!=null else null
    var parts=_unread(bytes,at,WIRE_PARTS,old.parts if old!=null else null,WIRE_PART) if visual!=null else null
    var shadow=_unread(bytes,at,WIRE_SHADOW,old.shadow if old!=null else null) if parts!=null else null
    if shadow==null or int(at[0])>=bytes.size():return null
    var night=null
    if old!=null:
        var flag:=bytes[at[0]];at[0]+=1
        if flag==0:night=old.night
        elif flag!=1 or int(at[0])>=bytes.size():return null
    if night==null:
        if bytes[at[0]]>64:return null
        night=[]
        var count:int=bytes[at[0]];at[0]+=1
        for _entry in count:
            var entry=_unpack(bytes,at,WIRE_NIGHT)
            if entry==null:return null
            night.append(entry)
    if int(at[0])!=bytes.size():return null
    visual["parts"]=parts;visual["shadow"]=shadow;visual["night"]=night
    packet["kind"]="player_visual";packet["visual"]=visual
    if not String(stream).is_empty():packet["actor"]=stream
    if slot<255:bases[slot]=packet
    return packet

## One group read back: whole without a base, else in one of the delta forms.
static func _unread(bytes:PackedByteArray,at:Array,keys:Array,base:Variant,inner:Array=[])->Variant:
    if base==null:return _unpack(bytes,at,keys,inner)
    if not base is Dictionary or int(at[0])>=bytes.size():return null
    var flag:=bytes[at[0]];at[0]+=1
    if flag==0:return _kept(base,keys)
    if flag==1:return _unpack(bytes,at,keys,inner)
    if flag!=2 or int(at[0])+4>bytes.size():return null
    var mask:=bytes.decode_u32(at[0]);at[0]+=4
    if mask>>keys.size()!=0:return null
    var data:=_kept(base,keys)
    for index in keys.size():
        if mask&(1<<index)==0:continue
        if not data.has(keys[index]):return null
        var value=_unread(bytes,at,inner,data[keys[index]]) if not inner.is_empty() else _read(bytes,at)
        if value==null:return null
        data[keys[index]]=value
    return data

## The keys of this group from the last packet (not those of the groups inside it).
static func _kept(base:Dictionary,keys:Array)->Dictionary:
    var data:={}
    for key in keys:
        if base.has(key):data[key]=base[key]
    return data

static func _unpack(bytes:PackedByteArray,at:Array,keys:Array,inner:Array=[])->Variant:
    var i:int=at[0]
    if i+4>bytes.size():return null
    var mask:=bytes.decode_u32(i);at[0]=i+4
    if mask>>keys.size()!=0:return null
    var data:={}
    for index in keys.size():
        if mask&(1<<index)==0:continue
        var value=_unpack(bytes,at,inner) if not inner.is_empty() else _read(bytes,at)
        if value==null:return null
        data[keys[index]]=value
    return data

## One value, or null (no value is null).
static func _read(bytes:PackedByteArray,at:Array)->Variant:
    var i:int=at[0]
    if i>=bytes.size():return null
    var type:=bytes[i];i+=1
    var value=null
    if type<=1:value=type==1
    elif type==2 and i+4<=bytes.size():value=bytes.decode_float(i);i+=4
    elif type==5 and i<bytes.size():value=float(bytes.decode_s8(i));i+=1
    elif type==6 and i+2<=bytes.size():value=float(bytes.decode_s16(i));i+=2
    elif (type==3 or type==4) and i<bytes.size() and i+1+bytes[i]<=bytes.size():
        var raw:=bytes.slice(i+1,i+1+bytes[i])
        value=raw.get_string_from_utf8() if type==3 else raw.hex_encode();i+=1+bytes[i]
    at[0]=i
    return value
