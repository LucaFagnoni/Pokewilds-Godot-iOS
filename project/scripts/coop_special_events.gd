extends Node
const Delta=preload("res://scripts/coop_world_delta.gd")
const Megas=preload("res://scripts/biome_megas.gd")
const Forest=preload("res://scripts/source_forest_boss.gd")
const KEYS=["biome_megas","mega_gengar_forest"]
var game:Node
var active:=false
var finishing:=false
var original_profile:Dictionary={}
var encounter_key:=""
var applied:Dictionary={}
var motion_at:=0
var motion_busy:=false
var results_dirty:=true
var results_scope:=""
var pending_results:Array=[]
func configure(value:Node)->void:
    game=value
    game.session.departed.connect(func(_peer,actor):
        if game.active and game.hosting:recover(actor))
static func eligible(context:Dictionary)->bool:
    return context.get("kind")=="special" and not preload("res://scripts/coop_raid_runtime.gd").eligible(context)
static func shared_key(key:String)->bool:
    return key.begins_with("event_result/") or key.begins_with("event_claim/") or (key.begins_with("world/") and key.get_slice("/",2)=="event_progress" and key.get_slice("/",3) in KEYS)
func records()->Dictionary:return game.state.records if game.hosting else game.shared_records
func recover(actor:String="")->bool:
    var changes:Array=[]
    for key in game.state.records:
        if String(key).begins_with("event_claim/") and (actor.is_empty() or game.state.records[key].actor==actor):changes.append(game.state.change(key,null))
    if changes.is_empty():return true
    var result=game.state.transact(game.session.actor,"eventrecover/"+game._id(),changes)
    if result.get("ok",false):game._committed(result)
    return bool(result.get("ok",false))
func execute(actor:String,id:String,op:String,args:Dictionary)->Dictionary:
    if op=="event_motion":
        for patch in args.patches:
            if not patch is Dictionary or patch.get("key") not in ["event_progress/biome_megas","event_progress/mega_gengar_forest"]:return {"ok":false,"reason":"invalid_target"}
        var delta=Delta.new();delta.state=game.state;delta.can_publish=game.service.areas.can_publish
        return delta.commit(actor,id,args.area,int(args.epoch),args.patches,true)
    var prior:Dictionary=game.state.outcomes.get(actor+"/"+op+"/"+id,{})
    if not prior.is_empty():
        if prior.get("command_hash")!=game.state.fingerprint(args):return {"ok":false,"reason":"reused_request_id"}
        return {"ok":true,"base":game.state.fingerprint(game.state.records.get("player/"+actor,{})),"pending":game.state.records.get("player/"+actor,{}).get("save",{}).get("coop_pending_pokemon",[])}
    var key:String=args.key
    var claim_key="event_claim/"+key
    var changes:Array=[]
    if op=="event_begin":
        var context=Delta.decode(args.context)
        if not context is Dictionary or not eligible(context):return {"ok":false,"reason":"invalid_event"}
        var scope=String(game.commands.presence.get(actor,{}).get("area",""))
        if key!=scope.get_slice("|",0)+"/"+String(context.get("id","")) or preload("res://scripts/source_event_data.gd").event_spec(String(context.get("id",""))).is_empty():return {"ok":false,"reason":"wrong_event"}
        if game.state.records.has(claim_key):return {"ok":false,"reason":"already_fighting"}
        var old:Dictionary=game.state.records.get("event_result/"+key,{})
        if old.get("cleared",false):return {"ok":false,"reason":"already_complete"}
        changes=[game.state.change(claim_key,{"actor":actor,"context":context})]
    else:
        var claim:Dictionary=game.state.records.get(claim_key,{})
        if claim.get("actor")!=actor:return {"ok":false,"reason":"not_fighting"}
        if args.base!=game.state.fingerprint(game.state.records.get("player/"+actor,{})):return {"ok":false,"reason":"profile_changed"}
        changes=game.storage.profile_changes(actor,args.profile)
        changes.append(game.state.change(claim_key,null))
        if args.outcome in ["captured","defeated"]:
            var clear=bool(claim.context.get("clear_on_capture",true)) if args.outcome=="captured" else bool(claim.context.get("clear_on_defeat",true))
            changes.append(game.state.change("event_result/"+key,{"id":id,"context":claim.context,"outcome":args.outcome,"cleared":clear}))
    var result=game.state.transact(actor,op+"/"+id,changes,game.state.fingerprint(args))
    if result.get("ok",false):
        result["base"]=game.state.fingerprint(game.state.records.get("player/"+actor,{}))
        result["pending"]=game.state.records.get("player/"+actor,{}).get("save",{}).get("coop_pending_pokemon",[])
    return result
func begin(context:Dictionary)->bool:
    var key=game._area()+"/"+String(context.id)
    var result:Dictionary=await game.raids.command("event_begin",{"key":key,"context":Delta.encode(context)})
    if not result.get("ok",false):game.main._show_message("That Pokemon is already in battle or has been caught.");return false
    original_profile=game._personal_profile();active=true;encounter_key=key
    return true
func finish(outcome:String)->bool:
    if not active:return true
    finishing=true
    var profile=game._personal_profile()
    var pending:Array=profile.save.get("coop_pending_pokemon",[]).duplicate(true)
    var result:Dictionary=await game.raids.command("event_finish",{"key":encounter_key,"outcome":outcome,"base":game.profile_base,"profile":profile})
    if not result.get("ok",false):game.end_session("EVENT RESULT COULD NOT BE SAVED.");return false
    game.storage.settle(pending,result.get("pending",[]));game.profile_base=result.base
    active=false;finishing=false;original_profile={};encounter_key=""
    return true
func may_move(event_id:String)->bool:
    return game.wild.authority() and not records().has("event_claim/"+game._area()+"/"+event_id)
func _process(_delta:float)->void:
    if not game.active or not game.main.started or game.main.generating or game.main.edge_travel_busy:return
    if not game.main.battle_active and not game.main.battle_entry_pending:
        apply_results()
    if not game.wild.authority() or motion_busy or game._request_busy or Time.get_ticks_msec()-motion_at<500:return
    motion_at=Time.get_ticks_msec();publish_motion()

func apply_results()->void:
    var world=game.main.world
    var world_id=str(world.exact_world.get_instance_id())
    var scope=game._area()+"/"+world_id
    if results_dirty or results_scope!=scope:
        results_dirty=false;results_scope=scope;pending_results.clear()
        var current=records();var prefix="event_result/"+game._area()+"/"
        for key in current:
            if String(key).begins_with(prefix) and not applied.has(String(current[key].id)+"/"+world_id):pending_results.append(current[key])
    for result in pending_results:
        applied[String(result.id)+"/"+world_id]=true
        world.complete_battle_event(result)
    pending_results.clear()
var _published_stamps:Dictionary={}

func publish_motion()->void:
    var world=game.main.world;var patches:Array=[]
    for name in KEYS:
        var key="event_progress/"+name
        # Packing the roaming Megas is the costly part; skip it while nothing
        # about them has changed since the last look.
        var stamp:int=hash(world.event_progress.get(name,{}))
        if _published_stamps.get(game._area()+"/"+name)==stamp:continue
        _published_stamps[game._area()+"/"+name]=stamp
        var before=records().get("world/"+game._area()+"/"+key,Delta.encode(null))
        var after=Delta.encode(world.event_progress.get(name,{}))
        if after!=before:patches.append({"key":key,"before":game.state.fingerprint(before),"after":after})
    if patches.is_empty():return
    motion_busy=true
    var result:Dictionary=await game.command("event_motion",{"area":game._area(),"epoch":game.area_epoch,"patches":patches})
    motion_busy=false
    if not result.get("ok",false):_published_stamps.clear()
    if result.get("reason")=="save_failed":game.end_session("EVENT MOVEMENT COULD NOT BE SAVED.")
func committed(changes:Array,actor:String,request_id:String)->void:
    for change in changes:
        if String(change.key).begins_with("event_result/"):results_dirty=true;break
    if not game.main.started or game.main.generating or game.main.edge_travel_busy:return
    if actor==game.session.actor and request_id.begins_with("world/"):return
    var world=game.main.world
    for change in changes:
        var key=String(change.key)
        if not key.begins_with("world/"+game._area()+"/event_progress/") or key.get_slice("/",3) not in KEYS:continue
        var name=key.get_slice("/",3)
        var next=Delta.decode(change.after)
        if not next is Dictionary:continue
        var old:Dictionary=world.event_progress.get(name,{})
        var previous:Array=old.values() if name==Megas.SAVE_KEY else [old]
        var following:Array=next.values() if name==Megas.SAVE_KEY else [next]
        for entry in previous:
            if not entry is Dictionary or not entry.has("x"):continue
            var cell=Vector2i(int(entry.x),int(entry.y))
            var destination:Dictionary={}
            for candidate in following:
                if candidate is Dictionary and candidate.has("x") and candidate.get("species","mega_gengar")==entry.get("species","mega_gengar"):destination=candidate;break
            if destination.is_empty():world._hide_event_cell(cell);continue
            var target=Vector2i(int(destination.x),int(destination.y))
            if target==cell:continue
            var sprite=world.source_interior_upper_sprites.get(cell)
            if not is_instance_valid(sprite):continue
            var collision=world.source_event_collisions.get(cell)
            var action=world.interior_interactables.get(cell,"")
            world.source_interior_upper_sprites.erase(cell);world.source_event_collisions.erase(cell)
            world.interior_interactables.erase(cell);world.blocked.erase(cell)
            world.source_interior_upper_sprites[target]=sprite
            world.interior_interactables[target]=action;world.blocked[target]=true
            if is_instance_valid(collision):
                world.source_event_collisions[target]=collision;collision.position=world._cell_center(target)
            var old_tween=sprite.get_meta("coop_event_motion") if sprite.has_meta("coop_event_motion") else null
            if old_tween is Tween and old_tween.is_valid():old_tween.kill()
            var tween=world.create_tween();tween.set_speed_scale(1.0/maxf(Engine.time_scale,0.01))
            tween.tween_property(sprite,"position",world._cell_center(target),0.12)
            sprite.set_meta("coop_event_motion",tween);sprite.z_index=world._depth_z(target,18)
        world.event_progress[name]=next
        if name==Megas.SAVE_KEY:Megas.install(world)
        else:Forest.install(world)
