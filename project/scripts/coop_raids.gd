extends RefCounted
## Existing bosses only. This module never creates or changes a spawn.
const SPECIES=["mewtwo","regigigas","regirock","regice","registeel","regieleki","regidrago","volcarona","spiritomb"]
var state
var presence:Dictionary={}

func join(actor:String,id:String,boss_id:String,new_boss:Dictionary={})->Dictionary:
    var old=_prior(actor,"raidjoin/"+id,[boss_id])
    if not old.is_empty():return old
    var boss:Dictionary=state.records.get("boss/"+boss_id,new_boss)
    if boss.is_empty() or boss.get("species","") not in SPECIES:return {"ok":false,"reason":"not_raid_boss"}
    if presence.get(actor,{}).get("area","")!=boss.get("area","?"):return {"ok":false,"reason":"wrong_area"}
    var raid:Dictionary=state.records.get("raid/"+boss_id,{}).duplicate(true)
    if raid.is_empty():
        var hp=maxi(1,int(boss.get("max_hp",1)))
        raid={"species":boss.species,"area":boss.area,"base":hp,"max_hp":hp,"hp":hp,
            "phase":"fighting","participants":[],"caught":[],"finisher":"",
            "mode":String(state.records.get("settings",{}).get("raids","ALL"))}
    if raid.phase!="fighting":
        return {"ok":true} if can_catch(actor,boss_id) else {"ok":false,"reason":"raid_already_defeated"}
    if not actor in raid.participants:
        if raid.participants.size()>=4:return {"ok":false,"reason":"raid_full"}
        raid.participants.append(actor)
        if raid.participants.size()>1:
            var extra=int(floor(float(raid.base)*0.75+0.5))
            raid.max_hp+=extra;raid.hp+=extra
    var changes:Array=[state.change("raid/"+boss_id,raid)]
    if not state.records.has("boss/"+boss_id):changes.append(state.change("boss/"+boss_id,boss))
    return _commit(actor,"raidjoin/"+id,[boss_id],changes)

# Called with damage resolved by the battle adapter, not arbitrary network HP.
func damage(actor:String,id:String,boss_id:String,amount:int)->Dictionary:
    var old=_prior(actor,"raiddamage/"+id,[boss_id,amount])
    if not old.is_empty():return old
    var raid:Dictionary=state.records.get("raid/"+boss_id,{}).duplicate(true)
    if raid.is_empty() or raid.phase!="fighting" or actor not in raid.participants:
        return {"ok":false,"reason":"not_fighting"}
    raid.hp=clampi(int(raid.hp)-amount,0,int(raid.max_hp))
    if int(raid.hp)==0:raid.phase="catching";raid.finisher=actor
    return _commit(actor,"raiddamage/"+id,[boss_id,amount],[state.change("raid/"+boss_id,raid)])

func can_catch(actor:String,boss_id:String)->bool:
    var raid:Dictionary=state.records.get("raid/"+boss_id,{})
    if raid.is_empty() or raid.phase!="catching" or actor in raid.caught:return false
    return actor in raid.participants if raid.mode=="ALL" else actor==raid.finisher

# Capture reward changes must come from the host's existing capture/storage adapter.
# They commit together with the claim so a disconnect cannot lose or duplicate it.
func caught(actor:String,id:String,boss_id:String,reward_changes:Array)->Dictionary:
    var old=_prior(actor,"raidcaught/"+id,[boss_id,reward_changes])
    if not old.is_empty():return old
    if not can_catch(actor,boss_id):return {"ok":false,"reason":"cannot_catch"}
    if reward_changes.is_empty():return {"ok":false,"reason":"missing_reward"}
    var raid:Dictionary=state.records["raid/"+boss_id].duplicate(true)
    raid.caught.append(actor)
    var complete=true
    var eligible:Array=raid.participants if raid.mode=="ALL" else [raid.finisher]
    for participant in eligible:
        if participant not in raid.caught:complete=false
    if complete:raid.phase="done"
    var changes=reward_changes.duplicate(true)
    changes.append(state.change("raid/"+boss_id,raid))
    return _commit(actor,"raidcaught/"+id,[boss_id,reward_changes],changes)

func _prior(actor:String,id:String,args:Array)->Dictionary:
    if not state.members.has(actor) or id.length()>80:return {"ok":false,"reason":"invalid_request"}
    var result:Dictionary=state.outcomes.get(actor+"/"+id,{})
    if result.is_empty():return {}
    if result.get("command_hash","")!=state.fingerprint(args):return {"ok":false,"reason":"reused_request_id"}
    return result.duplicate(true)

func _commit(actor:String,id:String,args:Array,changes:Array)->Dictionary:
    return state.transact(actor,id,changes,state.fingerprint(args))
