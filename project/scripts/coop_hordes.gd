extends RefCounted
## Durable bookkeeping for the explicitly enabled cooperative night event.
const Delta=preload("res://scripts/coop_world_delta.gd")
var state
var rng:=RandomNumberGenerator.new()

func start(actor:String,id:String,area:String,players:Dictionary)->Dictionary:
    var old=state.records.get("horde/"+area,{})
    if not old.is_empty() and old.get("phase") in ["waiting","active"]:return {"ok":false,"reason":"already_active"}
    var record={"id":id,"area":area,"phase":"waiting","players":players.duplicate(true),"members":[],"target_counts":{},"defeated":[],"total":0,"spawned":false}
    return state.transact(actor,"horde/"+id,[state.change("horde/"+area,record)])

func register_changes(area:String,wild_id:int,record:Dictionary)->Array:
    var event_id=String(record.get("source_record",{}).get("coop_horde",""))
    if event_id.is_empty():return []
    var event:Dictionary=state.records.get("horde/"+area,{}).duplicate(true)
    if event.get("id")!=event_id or event.get("phase") not in ["waiting","active"]:return []
    var target=String(record.get("coop_target",""))
    if event.get("spawned",false) or not event.players.has(target) or int(event.target_counts.get(target,0))>=4 or event.members.size()>=16:return []
    if not wild_id in event.members:
        event.members.append(wild_id)
        event.target_counts[target]=int(event.target_counts.get(target,0))+1
    event.total=event.members.size()
    return [state.change("horde/"+area,event)]

func defeat_changes(area:String,wild_id:int,record:Dictionary)->Array:
    var event:Dictionary=state.records.get("horde/"+area,{}).duplicate(true)
    if event.is_empty() or event.get("id")!=record.get("source_record",{}).get("coop_horde") or event.get("phase") not in ["waiting","active"] or not wild_id in event.members:return []
    if not wild_id in event.defeated:event.defeated.append(wild_id)
    return [state.change("horde/"+area,event)]

func ready(actor:String,id:String,area:String,event_id:String)->Dictionary:
    var event:Dictionary=state.records.get("horde/"+area,{}).duplicate(true)
    if event.get("id")!=event_id:return {"ok":false,"reason":"wrong_event"}
    if event.get("spawned",false):return {"ok":true}
    event.spawned=true;event.phase="active" if event.total>0 else "ended"
    return state.transact(actor,"hordeready/"+id,[state.change("horde/"+area,event)])

func finish(actor:String,id:String,area:String,recipients:Array)->Dictionary:
    var event:Dictionary=state.records.get("horde/"+area,{}).duplicate(true)
    if event.get("phase")!="active" or not event.get("spawned",false) or event.total<1 or event.defeated.size()<event.total:return {"ok":false,"reason":"not_complete"}
    event.phase="complete"
    var changes:Array=[state.change("horde/"+area,event)]
    var loot=["RARE CANDY","RARE CANDY","REVIVE","REVIVE","ULTRA BALL","STONE"]
    var item:String=loot[rng.randi_range(0,loot.size()-1)]
    var amount=1
    if item=="STONE":
        var stones=["WATER STONE","FIRE STONE","LEAF STONE","THUNDERSTONE","MOON STONE","SUN STONE","ICE STONE","DAWN STONE","DUSK STONE","SHINY STONE","SWEET APPLE"]
        item=stones[rng.randi_range(0,stones.size()-1)]
    elif item=="RARE CANDY":amount=rng.randi_range(1,2)
    elif item=="REVIVE":amount=2
    elif item=="ULTRA BALL":amount=4
    var unique:Dictionary={}
    for recipient in recipients:
        if unique.has(recipient) or not state.records.has("player/"+String(recipient)):continue
        unique[recipient]=true
        var key="horde_reward/"+String(recipient)+"/"+String(event.id)
        if not state.records.has(key):changes.append(state.change(key,{"item":item,"amount":amount}))
    return state.transact(actor,"hordefinish/"+id,changes)

func claim_reward(actor:String,id:String,key:String)->Dictionary:
    if not key.begins_with("horde_reward/"+actor+"/"):return {"ok":false,"reason":"not_yours"}
    var previous:Dictionary=state.outcomes.get(actor+"/hordereward/"+id,{})
    if not previous.is_empty():return previous if previous.get("command_hash")==state.fingerprint(key) else {"ok":false,"reason":"reused_request_id"}
    var reward:Dictionary=state.records.get(key,{})
    if reward.is_empty():return {"ok":false,"reason":"already_collected"}
    var profile:Dictionary=state.records.get("player/"+actor,{}).duplicate(true)
    if not profile.get("inventory") is Dictionary:return {"ok":false,"reason":"missing_profile"}
    profile.inventory[reward.item]=int(profile.inventory.get(reward.item,0))+int(reward.amount)
    return state.transact(actor,"hordereward/"+id,[state.change(key,null),state.change("player/"+actor,profile)],state.fingerprint(key))

func end(actor:String,id:String,area:String)->Dictionary:
    var event:Dictionary=state.records.get("horde/"+area,{}).duplicate(true)
    if event.get("phase") not in ["waiting","active"]:return {"ok":true}
    event.phase="ended"
    var changes:Array=[state.change("horde/"+area,event)]
    for wild_id in event.members:
        var key="world/"+area+"/wild_pokemon/"+str(wild_id)
        var record=Delta.decode(state.records.get(key,Delta.encode(null)))
        if not record is Dictionary:continue
        if state.records.has("wild_claim/"+area+"/"+str(wild_id)):
            record["aggro_player"]=false;record["coop_target"]=""
            changes.append(state.change(key,Delta.encode(record)))
        else:changes.append(state.change(key,Delta.encode(null)))
    return state.transact(actor,"hordeend/"+id,changes)
