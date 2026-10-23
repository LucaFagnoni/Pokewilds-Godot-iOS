extends RefCounted
## Coordinates existing source populations; never rolls species, levels or spawns.
const Delta=preload("res://scripts/coop_world_delta.gd")
var state
var presence:Dictionary={}
var can_publish:Callable

func namespace_for(actor:String)->int:
    var key="wild_namespace/"+actor
    if state.records.has(key):return int(state.records[key])
    var next=state.namespace_max()+1
    if next>=2097152:return 0 # Keep all generated IDs exactly representable in JSON.
    var result=state.transact(actor,"wildnamespace",[state.change(key,next)])
    return next if result.get("ok",false) else 0

func register(actor:String,id:String,area:String,record:Dictionary)->Dictionary:
    var prior=_prior(actor,"wildspawn/"+id,[area,record])
    if not prior.is_empty():return prior
    if state.members.get(actor,{}).get("area")!=area:return {"ok":false,"reason":"wrong_area"}
    var namespace_id=int(state.records.get("wild_namespace/"+actor,0))
    if not record.get("id") is int or namespace_id<1 or int(record.id)/4294967296!=namespace_id:return {"ok":false,"reason":"invalid_id"}
    if not record.get("species") is String or not record.get("level") is int or not record.get("x") is int or not record.get("y") is int:return {"ok":false,"reason":"invalid_record"}
    if record.level<1 or record.level>100 or preload("res://scripts/pokemon_data.gd").info(record.species).is_empty():return {"ok":false,"reason":"invalid_record"}
    var key=record_key(area,int(record.id))
    if state.records.has(key):return {"ok":false,"reason":"id_used"}
    # The caller already ran the unchanged source spawn roll. No additional
    # species/level selection happens here; simultaneous unique events arbitrate.
    if not record.get("source_record",{}) is Dictionary:return {"ok":false,"reason":"invalid_record"}
    var source:Dictionary=record.get("source_record",{})
    var unique=String(source.get("rare_legendary",""))
    if not unique.is_empty():
        var history=Delta.decode(state.records.get("world/"+area+"/event_progress/rare_legendaries_captured",Delta.encode({})))
        if history is Dictionary and history.get(unique,false):return {"ok":false,"reason":"already_present"}
    if source.get("rare_forest_mew",false):unique="mew"
    if not unique.is_empty():
        for other_key in state.wild_by_area.get(area,{}):
            var other=Delta.decode(state.records[other_key])
            if other is Dictionary and other.get("species")==record.species:return {"ok":false,"reason":"already_present"}
    var changes:Array=[state.change(key,Delta.encode(record))]
    if not String(source.get("coop_horde","")).is_empty():
        if state.authority.get(area)!=actor:return {"ok":false,"reason":"not_authority"}
        var horde=preload("res://scripts/coop_hordes.gd").new();horde.state=state
        var joined=horde.register_changes(area,int(record.id),record)
        if joined.is_empty():return {"ok":false,"reason":"horde_ended"}
        changes.append_array(joined)
    return state.transact(actor,"wildspawn/"+id,changes,state.fingerprint([area,record]))

static func record_key(area:String,wild_id:int)->String:
    return "world/"+area+"/wild_pokemon/"+str(wild_id)

static func claim_key(area:String,wild_id:int)->String:
    return "wild_claim/"+area+"/"+str(wild_id)

func claim(actor:String,id:String,area:String,wild_id:int)->Dictionary:
    var args=[area,wild_id]
    var prior=_prior(actor,"wildclaim/"+id,args)
    if not prior.is_empty():return prior
    if not preload("res://scripts/coop_areas.gd").valid_area(area) or wild_id<1:return {"ok":false,"reason":"invalid_target"}
    if state.members.get(actor,{}).get("area")!=area:return {"ok":false,"reason":"wrong_area"}
    if presence.get(actor,{}).get("battle",false):return {"ok":false,"reason":"in_battle"}
    var key=claim_key(area,wild_id)
    if state.records.has(key):return {"ok":false,"reason":"already_claimed"}
    if state.claims_by_actor.has(actor):return {"ok":false,"reason":"already_in_encounter"}
    var encoded=state.records.get(record_key(area,wild_id),Delta.encode(null))
    var record=Delta.decode(encoded)
    if not record is Dictionary:return {"ok":false,"reason":"no_pokemon"}
    var reservation={"actor":actor,"area":area,"id":wild_id,"record":encoded}
    return state.transact(actor,"wildclaim/"+id,[state.change(key,reservation)],state.fingerprint(args))

func release(actor:String,id:String,area:String,wild_id:int)->Dictionary:
    var args=[area,wild_id]
    var prior=_prior(actor,"wildrelease/"+id,args)
    if not prior.is_empty():return prior
    var key=claim_key(area,wild_id)
    if state.records.get(key,{}).get("actor")!=actor:return {"ok":false,"reason":"not_claimant"}
    return state.transact(actor,"wildrelease/"+id,[state.change(key,null)],state.fingerprint(args))

func abandon(coordinator:String,id:String,actor:String="")->Dictionary:
    var prior=_prior(coordinator,"wildabandon/"+id,[actor])
    if not prior.is_empty():return prior
    var changes:Array=[]
    for claimant in state.claims_by_actor if actor.is_empty() else [actor]:
        for key in state.claims_by_actor.get(claimant,{}):changes.append(state.change(key,null))
    if changes.is_empty():return {"ok":true}
    return state.transact(coordinator,"wildabandon/"+id,changes,state.fingerprint([actor]))

func complete(actor:String,id:String,area:String,wild_id:int,profile_changes:Array,restored:Variant=null,request_args:Array=[])->Dictionary:
    # Only the trusted battle/storage adapter supplies reward changes. They are
    # durable in the same write that removes the claimed overworld Pokemon.
    var args=request_args if not request_args.is_empty() else [area,wild_id,profile_changes,restored]
    var prior=_prior(actor,"wildcomplete/"+id,args)
    if not prior.is_empty():return prior
    var key=claim_key(area,wild_id)
    if state.records.get(key,{}).get("actor")!=actor:return {"ok":false,"reason":"not_claimant"}
    if profile_changes.is_empty():return {"ok":false,"reason":"missing_profile"}
    var changes=profile_changes.duplicate(true)
    changes.append(state.change(record_key(area,wild_id),Delta.encode(restored)))
    changes.append(state.change(key,null))
    return state.transact(actor,"wildcomplete/"+id,changes,state.fingerprint(args))

func motion(actor:String,id:String,area:String,epoch:int,patches:Array)->Dictionary:
    var prior=_prior(actor,"world/"+id,[area,epoch,patches])
    if not prior.is_empty():return prior
    for patch in patches:
        if not patch is Dictionary or not patch.get("key") is String:return {"ok":false,"reason":"invalid_changes"}
        var key:String=patch.key
        if not key.begins_with("wild_pokemon/") or not key.get_slice("/",1).is_valid_int():return {"ok":false,"reason":"invalid_target"}
        if state.records.has(claim_key(area,int(key.get_slice("/",1)))):return {"ok":false,"reason":"already_claimed"}
    var delta=Delta.new();delta.state=state;delta.can_publish=can_publish
    return delta.commit(actor,id,area,epoch,patches,true)

func _prior(actor:String,id:String,args:Array)->Dictionary:
    if not state.members.has(actor) or id.length()>80:return {"ok":false,"reason":"invalid_request"}
    var result:Dictionary=state.outcomes.get(actor+"/"+id,{})
    if result.is_empty():return {}
    return result.duplicate(true) if result.get("command_hash")==state.fingerprint(args) else {"ok":false,"reason":"reused_request_id"}

## The player a wild Pokemon on `cell` goes for: the one it pursues (its
## "coop_target", set here; kept while that player stays eligible and near),
## else the nearest who could; {} if none. `players`: actor -> {"area", "x",
## "y", "battle", ...} as last seen ("actor" is added to the one returned);
## `scope`: "<area>|OVERWORLD"; `safe` (a cell -> bool) leaves out the players
## a horde does not chase (by a lit campfire). For a World's area
## (coop_wild_runtime.gd) and one a server holds without one (area_sim.gd).
static func target_of(players:Dictionary,scope:String,data:Dictionary,cell:Vector2i,safe:Callable)->Dictionary:
    var eligible=players
    if not String(data.get("source_record",{}).get("coop_horde","")).is_empty():
        eligible=players.duplicate()
        for actor in eligible.keys():
            if safe.call(Vector2i(eligible[actor].x,eligible[actor].y)):eligible.erase(actor)
    var target=""
    if data.get("aggro_player",false):target=chase_target(String(data.get("coop_target","")),cell,eligible,scope)
    data["coop_target"]=target
    if target.is_empty():target=chase_target("",cell,eligible,scope,2147483647)
    if target.is_empty():return {}
    players[target]["actor"]=target
    return players[target]

static func occupied_by(players:Dictionary,cell:Vector2i)->bool:
    for player in players.values():
        if cell==Vector2i(player.x,player.y):return true
    return false

## Whether `target` (a player as target_of gives one) keeps the Pokemon calm
## with CHARM (its field Pokemon's level against the Pokemon's), or a ball's
## charm still holds at `clock`.
static func charmed_by(data:Dictionary,target:Dictionary,clock:float)->bool:
    if float(data.get("ball_charm_until",0.0))>clock:return true
    if target.get("move")!="CHARM":return false
    var reference=int(target.get("party_level",1))
    var level=clampi(maxi(1,int(data.get("level",1))),maxi(2,reference-3),mini(100,reference+1))
    return int(target.get("field_level",1))>=level

static func chase_target(previous:String,origin:Vector2i,players:Dictionary,scope:String,radius_squared:int=64)->String:
    # Retain first sighting until it is no longer eligible; moving closer cannot
    # steal another player's pursuer. Flight affects contact, not target choice.
    if _eligible(previous,origin,players,scope,radius_squared):return previous
    var selected="";var distance=radius_squared+1
    var actors=players.keys();actors.sort()
    for actor in actors:
        if not _eligible(actor,origin,players,scope,radius_squared):continue
        var player:Dictionary=players[actor]
        var next=origin.distance_squared_to(Vector2i(int(player.x),int(player.y)))
        if next<distance:selected=actor;distance=next
    return selected

static func _eligible(actor:String,origin:Vector2i,players:Dictionary,scope:String,radius_squared:int)->bool:
    var player:Dictionary=players.get(actor,{})
    if player.is_empty() or player.get("area")!=scope or player.get("battle",false):return false
    return origin.distance_squared_to(Vector2i(int(player.x),int(player.y)))<=radius_squared
