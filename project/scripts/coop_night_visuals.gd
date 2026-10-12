extends RefCounted
## Replicate the existing personal night encounters without rolling new spawns.
const TEXTURES={
    "spawn":preload("res://assets/events/ghost_spawn1.png"),
    "ghost":preload("res://assets/events/ghost_sheet1.png"),
    "shadow":preload("res://assets/source_exact/global/shadow1.png")}
var sprites:Dictionary={}

static func capture(world:Node)->Array:
    var actors:Array=[]
    var roaming=world.get("roaming_ghosts")
    if roaming!=null:actors.append_array(roaming.actors)
    var night=world.get("source_night_events")
    if night!=null:
        actors.append_array(night.cacturnes)
        if not night.ghost.is_empty():actors.append(night.ghost)
    var result:Array=[]
    for actor in actors:
        var sprite=actor.get("sprite") as Sprite2D
        if not is_instance_valid(sprite) or sprite.texture==null:continue
        var texture="cacturne"
        for key in TEXTURES:
            if sprite.texture==TEXTURES[key]:texture=key;break
        if texture=="cacturne" and actor.get("species")!="cacturne":continue
        result.append({"id":str(sprite.get_instance_id()),"texture":texture,"x":sprite.global_position.x,"y":sprite.global_position.y,
            "z":sprite.z_index,"visible":sprite.visible,"centered":sprite.centered,"flip_h":sprite.flip_h,
            "hframes":sprite.hframes,"vframes":sprite.vframes,"frame":sprite.frame,
            "region":sprite.region_enabled,"rx":sprite.region_rect.position.x,"ry":sprite.region_rect.position.y,
            "rw":sprite.region_rect.size.x,"rh":sprite.region_rect.size.y})
        if result.size()>=64:break
    return result

static func valid(value:Variant)->bool:
    if not value is Array or value.size()>64:return false
    var ids:Dictionary={}
    for entry in value:
        if not entry is Dictionary or not entry.get("id") is String or entry.id.length()>32 or ids.has(entry.id):return false
        ids[entry.id]=true
        if entry.get("texture") not in ["spawn","ghost","shadow","cacturne"]:return false
        for key in ["x","y","z","hframes","vframes","frame","rx","ry","rw","rh"]:
            var number=entry.get(key)
            if not (number is int or number is float) or not is_finite(float(number)) or absf(float(number))>10000000:return false
        if entry.hframes<1 or entry.hframes>32 or entry.vframes<1 or entry.vframes>32:return false
        if entry.rw<0 or entry.rw>256 or entry.rh<0 or entry.rh>256:return false
        for key in ["visible","centered","flip_h","region"]:
            if not entry.get(key) is bool:return false
    return true

func draw(owner:Node2D,current:Array,previous:Array,weight:float)->void:
    var old:Dictionary={};var present:Dictionary={}
    for entry in previous:old[entry.id]=entry
    for entry in current:
        present[entry.id]=true
        if not sprites.has(entry.id):
            var sprite=Sprite2D.new();sprite.texture_filter=CanvasItem.TEXTURE_FILTER_NEAREST
            sprite.z_as_relative=false;owner.add_child(sprite);sprites[entry.id]=sprite
        var sprite:Sprite2D=sprites[entry.id]
        sprite.texture=TEXTURES.get(entry.texture) if entry.texture!="cacturne" else preload("res://scripts/pokemon_data.gd").texture("cacturne","overworld")
        if sprite.texture==null:sprite.hide();continue
        sprite.visible=entry.visible;sprite.centered=entry.centered;sprite.flip_h=entry.flip_h
        sprite.hframes=int(entry.hframes);sprite.vframes=int(entry.vframes)
        sprite.frame=clampi(int(entry.frame),0,sprite.hframes*sprite.vframes-1)
        sprite.region_enabled=entry.region;sprite.region_rect=Rect2(entry.rx,entry.ry,entry.rw,entry.rh)
        sprite.z_index=clampi(int(entry.z),-4096,4094)
        var target=Vector2(entry.x,entry.y);var before:Dictionary=old.get(entry.id,entry)
        var start=Vector2(before.x,before.y)
        sprite.global_position=(start.lerp(target,weight) if start.distance_to(target)<128 else target).round()
    for id in sprites.keys():
        if not present.has(id):sprites[id].queue_free();sprites.erase(id)
