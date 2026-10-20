extends Node2D
## Visual-only remote actor. It never reads local input or changes world collision.
const Pokemon=preload("res://scripts/pokemon_data.gd")
const MountLayers=preload("res://scripts/mount_layers.gd")
const INTERPOLATION_MS:=100
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
    var now=Time.get_ticks_msec() if received_ms<0 else received_ms
    _frames.append({"time":now,"data":snapshot.duplicate(true)})
    while _frames.size()>8:_frames.pop_front()

func _process(_delta:float)->void:
    render_at(Time.get_ticks_msec()-INTERPOLATION_MS)

func render_at(time_ms:int)->void:
    if _frames.is_empty():return
    while _frames.size()>2 and int(_frames[1].time)<=time_ms:_frames.pop_front()
    var first:Dictionary=_frames[0]
    var second:Dictionary=_frames[1] if _frames.size()>1 else first
    var weight=clampf(float(time_ms-int(first.time))/maxi(1,int(second.time)-int(first.time)),0.0,1.0)
    var data:Dictionary=second.data
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
        if key=="player":
            var running=bool(data.get("running",false))
            var base:Texture2D=(_main.PLAYER_MODEL_RUN_TEXTURES if running else _main.PLAYER_MODEL_WALK_TEXTURES)[model]
            var pose=String(data.get("pose","walk"))
            if pose=="sit":base=_main.PLAYER_MODEL_SITTING_TEXTURES[model]
            elif pose=="sleep":base=_main.PLAYER_MODEL_SLEEP_TEXTURES[model]
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
        if sprite.texture==null:sprite.hide();continue
        sprite.hframes=clampi(int(part.get("hframes",1)),1,sprite.texture.get_width())
        sprite.vframes=clampi(int(part.get("vframes",1)),1,sprite.texture.get_height())
        sprite.frame=clampi(int(part.get("frame",0)),0,sprite.hframes*sprite.vframes-1)
        sprite.flip_h=bool(part.get("flip_h",false))
        sprite.centered=bool(part.get("centered",true))
        sprite.offset=Vector2(float(part.get("ox",0)),float(part.get("oy",0)))
        if key=="thrown":sprite.scale=Vector2.ONE*clampf(float(part.get("s",1.0)),0.0,2.0)
        var destination=Vector2(float(part.get("x",0)),float(part.get("y",0)))
        var previous:Dictionary=first.data.parts.get(key,part)
        var origin=Vector2(float(previous.get("x",destination.x)),float(previous.get("y",destination.y)))
        # Area jumps/teleports snap instead of flying across the screen.
        sprite.global_position=(origin.lerp(destination,weight) if origin.distance_to(destination)<128 else destination).round()
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
        var destination=Vector2(float(shadow.get("x",0)),float(shadow.get("y",0)))
        var previous:Dictionary=first.data.get("shadow",shadow)
        var origin=Vector2(float(previous.get("x",destination.x)),float(previous.get("y",destination.y)))
        _shadow.global_position=(origin.lerp(destination,weight) if origin.distance_to(destination)<128 else destination).round()
        _shadow.z_index=clampi(int(shadow.get("z",0)),-4096,4094)
    _status.global_position=player.sprite.global_position+Vector2(0,-19)
    _night.draw(self,data.get("night",[]),first.data.get("night",[]),weight)
    var battle=bool(data.get("battle",false))
    if battle!=_in_battle:_in_battle=battle;_status.queue_redraw()
    _afk.visible=not battle and (bool(data.get("afk",false)) or bool(data.get("sleeping",false)))
    var environment=_main.world.environment_system
    if is_instance_valid(environment):
        var flash=active_field_move in ["FLASH","POWER"]
        var fire=follower_sprite.visible and "FIRE" in Pokemon.info(String(data.get("follower_species",""))).get("types",[])
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
