extends Node
const Delta=preload("res://scripts/coop_world_delta.gd")
const Records=preload("res://scripts/coop_population_records.gd")
var game:Node
var claim:Dictionary={}
var original_profile:Dictionary={}
var finishing:=false
var begun:=false
func configure(coordinator:Node)->void:
    game=coordinator
    game.session.departed.connect(func(_peer,actor):
        if game.active and game.hosting:recover(actor))
func recover(actor:String="")->bool:
    var changes:Array=[]
    for key in game.state.records:
        if not String(key).begins_with("population_claim/"):continue
        var record:Dictionary=game.state.records[key]
        if not actor.is_empty() and record.actor!=actor:continue
        changes.append(game.state.change(record.key,record.record))
        changes.append(game.state.change(key,null))
    if changes.is_empty():return true
    var result=game.state.transact(game.session.actor,"populationrecover/"+game._id(),changes)
    if result.get("ok",false):game._committed(result)
    else:game.end_session("POKEMON BATTLE COULD NOT BE RESTORED.")
    return bool(result.get("ok",false))
func execute(actor:String,id:String,operation:String,args:Dictionary)->Dictionary:
    var prefix="population_claim/"+actor
    var old:Dictionary=game.state.outcomes.get(actor+"/"+operation+"/"+id,{})
    if not old.is_empty():
        if old.get("command_hash")!=game.state.fingerprint(args):return {"ok":false,"reason":"reused_request_id"}
        return {"ok":true,"claim":game.state.records.get(prefix,{}),"base":game.state.print_of("player/"+actor,{})}
    var changes:Array=[]
    if operation=="population_battle":
        var cell=Vector2i(int(args.x),int(args.y))
        if game.state.records.has(prefix):return {"ok":false,"reason":"already_fighting"}
        # The Pokemon attacked, by its id, wherever it has walked to since.
        var model=game.population.model()
        var found:Array=model.find(args.area,args.group,cell,"",String(args.get("identity","")))
        if found.is_empty():return {"ok":false,"reason":"too_late"}
        var key:String=found[0];var target:Dictionary=found[1]
        if args.group=="deployed_pokemon" and Records.owned_by_other(target,actor):return {"ok":false,"reason":"not_owner"}
        cell=Vector2i(int(target.get("x",cell.x)),int(target.get("y",cell.y)))
        if not (model._near(actor,args.area,cell) if args.group=="wild_eggs" else model._reach(actor,args.area,cell)):return {"ok":false,"reason":"too_far"}
        var encoded=game.state.records.get(key)
        var record={"actor":actor,"key":key,"record":encoded,"area":args.area,"group":args.group,"x":cell.x,"y":cell.y}
        changes=[game.state.change(key,Delta.encode(null)),game.state.change(prefix,record)]
    else:
        var record:Dictionary=game.state.records.get(prefix,{})
        if record.is_empty():return {"ok":false,"reason":"not_fighting"}
        if args.base!=game.state.print_of("player/"+actor,{}):return {"ok":false,"reason":"profile_changed"}
        if record.group=="wild_eggs" and args.outcome=="captured":return {"ok":false,"reason":"cannot_catch"}
        changes=game.storage.profile_changes(actor,args.profile)
        changes.append(game.state.change(prefix,null))
        if args.outcome not in ["defeated","captured"]:changes.append(game.state.change(record.key,record.record))
    var result=game.state.transact(actor,operation+"/"+id,changes,game.state.fingerprint(args))
    if result.get("ok",false):
        result["claim"]=game.state.records.get(prefix,{})
        result["base"]=game.state.print_of("player/"+actor,{})
        result["pending"]=game.state.records.get("player/"+actor,{}).get("save",{}).get("coop_pending_pokemon",[])
    return result
func begin(cell:Vector2i,group:String)->void:
    if not claim.is_empty() or begun:return
    var shown:Dictionary=game.main.world.get(group).get(cell,{})
    var identity=String(shown.get("ecology_id",""))
    var name="The EGG" if group=="wild_eggs" else preload("res://scripts/pokemon_state.gd").display_name(shown).to_upper() if not shown.is_empty() else "It"
    begun=true
    var result:Dictionary={"ok":false,"reason":"busy"}
    if await game.wait_free():result=await game.command("population_battle",{"area":game._area(),"group":group,"x":cell.x,"y":cell.y,"identity":identity})
    begun=false
    if not result.get("ok",false):game.main._show_message(game.population.refusal(String(result.get("reason","")),name));return
    original_profile=game._personal_profile().duplicate(true);claim=result.claim
    var member:Dictionary=Delta.decode(claim.record)
    for key in ["x","y","cell","sprite","move_timer","anim_phase","behavior"]:member.erase(key)
    var egg=group=="wild_eggs"
    var context={"id":"coop_population_"+game._id(),"kind":"attack_egg" if egg else "attack_deployed","can_run":true,"can_catch":not egg,"party":[member],"cell_x":cell.x,"cell_y":cell.y}
    await game.main._start_battle_context(context)
func finish(outcome:String)->bool:
    if claim.is_empty():return true
    finishing=true
    var profile=game._personal_profile()
    var pending:Array=profile.save.get("coop_pending_pokemon",[]).duplicate(true)
    while game._request_busy:
        await get_tree().process_frame
        if not game.active:return false
    var result:Dictionary=await game.command("population_finish",{"outcome":outcome,"profile":profile,"base":game.profile_base})
    if not result.get("ok",false):game.end_session("POKEMON BATTLE COULD NOT BE SAVED.");return false
    game.storage.settle(pending,result.get("pending",[]));game.profile_base=result.base
    var egg=claim.group=="wild_eggs"
    claim={};original_profile={};finishing=false
    if egg and outcome=="defeated":game.main._show_message("The EGG was destroyed.")
    return true
