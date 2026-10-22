extends RefCounted
## Atomic party-to-habitat transfers. Placement geometry is validated by World.
const Delta=preload("res://scripts/coop_world_delta.gd")
const Items=preload("res://scripts/coop_shared_items.gd")
var state
var presence:Dictionary={}
var rng:=RandomNumberGenerator.new()
var can_publish:Callable
var make_egg:Callable
var can_simulate:Callable

func reserved(record_key:String)->bool:
    for actor in state.members:
        if state.records.get("population_claim/"+String(actor),{}).get("key")==record_key:return true
    return false

static func record_scope(record:Dictionary)->String:
    return "HOUSE/"+String(record.house_door)+"/"+str(int(record.get("house_floor",0))) if record.has("house_door") else "OVERWORLD"

static func batches(patches:Array,before:Dictionary)->Array:
    # Keep both cells of every moving Pokemon in the same transaction, including
    # chains where one Pokemon moves into another Pokemon's previous cell.
    var owners:Dictionary={};var components:Dictionary={};var group_for:Array=[]
    for index in range(patches.size()):
        group_for.append(index);components[index]=[index]
        var patch:Dictionary=patches[index]
        for encoded in [before.get(patch.key,Delta.encode(null)),patch.after]:
            var record=Delta.decode(encoded)
            if not record is Dictionary:continue
            var identity=String(record.get("ecology_id",""))
            if identity.is_empty():continue
            if not owners.has(identity):owners[identity]=index;continue
            var other:int=group_for[int(owners[identity])]
            var current:int=group_for[index]
            if other==current:continue
            for member in components[current]:group_for[member]=other;components[other].append(member)
            components.erase(current)
    var result:Array=[];var batch:Array=[];var bytes=0
    for members in components.values():
        var size=0
        for index in members:size+=String(patches[index].after).length()
        if members.size()>Delta.MAX_PATCHES or size>Delta.MAX_PACKET_BYTES:return []
        if not batch.is_empty() and (batch.size()+members.size()>Delta.MAX_PATCHES or bytes+size>Delta.MAX_PACKET_BYTES):
            result.append(batch);batch=[];bytes=0
        for index in members:batch.append(patches[index])
        bytes+=size
    if not batch.is_empty():result.append(batch)
    return result

func motion(actor:String,id:String,area:String,epoch:int,patches:Array)->Dictionary:
    var args=[area,epoch,patches]
    var previous=_prior(actor,"world/"+id,args)
    if not previous.is_empty():return previous
    for patch in patches:
        if not patch is Dictionary or not patch.get("key") is String or patch.key.get_slice("/",0) not in ["deployed_pokemon","wild_eggs"]:
            return {"ok":false,"reason":"invalid_target"}
        if not patch.get("after") is String:return {"ok":false,"reason":"invalid_changes"}
        if reserved("world/"+area+"/"+patch.key):return {"ok":false,"reason":"already_claimed"}
        for encoded in [state.records.get("world/"+area+"/"+patch.key,Delta.encode(null)),patch.after]:
            var record=Delta.decode(encoded)
            if record==null:continue
            if not record is Dictionary:return {"ok":false,"reason":"invalid_record"}
            var permitted=can_simulate.call(actor,area,epoch,record_scope(record)) if can_simulate.is_valid() else can_publish.is_valid() and can_publish.call(actor,area,epoch)
            if not permitted:return {"ok":false,"reason":"not_authority"}
    var delta=Delta.new();delta.state=state;delta.can_publish=can_publish
    var prepared=delta.prepare_changes(area,patches)
    if not prepared.get("ok",false):return prepared
    return state.transact(actor,"world/"+id,prepared.changes,state.fingerprint(args),not delta.motion_only(area,patches))

func harvest(actor:String,id:String,area:String,cell:Vector2i,expected:String,identity:String="")->Dictionary:
    var args=[area,cell,expected]
    var previous=_prior(actor,"harvestpopulation/"+id,args)
    if not previous.is_empty():return previous
    # The item is what was asked for, not this exact copy of the record: a
    # timer may have ticked, or the Pokemon may have walked on since.
    var found=find(area,"deployed_pokemon",cell,expected,identity)
    if found.is_empty():return {"ok":false,"reason":"too_late"}
    var record_key:String=found[0];var record:Dictionary=found[1]
    if not _reach(actor,area,Vector2i(int(record.get("x",cell.x)),int(record.get("y",cell.y)))):return {"ok":false,"reason":"too_far"}
    var item=String(record.get("held_item",""))
    if item.is_empty():return {"ok":false,"reason":"too_late"}
    var profile:Dictionary=state.records.get("player/"+actor,{}).duplicate(true)
    if not profile.get("inventory") is Dictionary:return {"ok":false,"reason":"missing_profile"}
    var amount=1
    if item=="ANCIENTPOWDER" and preload("res://scripts/rare_biome_legendaries.gd").HABITATS.has(String(record.species)):
        amount=rng.randi_range(3,5)
    profile.inventory[item]=int(profile.inventory.get(item,0))+amount
    record["held_item"]="";record["harvest_progress"]=0.0
    return state.transact(actor,"harvestpopulation/"+id,[state.change(record_key,Delta.encode(record)),state.change("player/"+actor,profile)],state.fingerprint(args))

static func key(area:String,group:String,cell:Vector2i)->String:
    return "world/"+area+"/"+group+"/"+("%d,%d"%[cell.x,cell.y]).uri_encode()

## How far (in tiles, either way) a player may stand from a habitat Pokemon
## they take, harvest or fight. Wider than the tile in front of them: it walks
## on while the player reads its prompt and while the request travels, and the
## host's copy of the player's position is itself a moment old.
const REACH:=5

## [record key, record] of the Pokemon asked for, wherever it now stands. A
## habitat Pokemon is found by its ecology id: it walks about, and the tile the
## player's game shows it on is often a step or two behind (or ahead of) the
## host's. An egg does not move: the one on that tile.
func find(area:String,group:String,cell:Vector2i,expected:String,identity:String)->Array:
    var record_key=key(area,group,cell)
    var encoded=state.records.get(record_key,Delta.encode(null))
    var record=Delta.decode(encoded)
    if record is Dictionary:
        if group=="wild_eggs":return [record_key,record]
        if identity.is_empty() and (expected.is_empty() or state.fingerprint(encoded)==expected):return [record_key,record]
        if not identity.is_empty() and String(record.get("ecology_id",""))==identity:return [record_key,record]
    if group!="deployed_pokemon" or identity.is_empty():return []
    # ponytail: walks every record; an id-to-tile index if this ever shows as a stall.
    var prefix="world/"+area+"/deployed_pokemon/"
    for candidate_key in state.records:
        if not String(candidate_key).begins_with(prefix):continue
        var candidate=Delta.decode(state.records[candidate_key])
        if candidate is Dictionary and String(candidate.get("ecology_id",""))==identity:return [candidate_key,candidate]
    return []

## A Pokemon a player left in the world is theirs to take back or catch; one
## from before the world went online, or never left by a player, is anyone's.
static func owned_by_other(record:Dictionary,actor:String)->bool:
    var identity=String(record.get("ecology_id",""))
    return identity.begins_with("coop_owned:") and not identity.begins_with("coop_owned:"+actor+":")

func place(actor:String,id:String,area:String,slot:int,record:Dictionary,base:String)->Dictionary:
    var args=[area,slot,record,base]
    var previous=_prior(actor,"deploy/"+id,args)
    if not previous.is_empty():return previous
    var profile:Dictionary=state.records.get("player/"+actor,{}).duplicate(true)
    if state.print_of("player/"+actor,{})!=base:return {"ok":false,"reason":"profile_changed"}
    if slot<0 or slot>=profile.get("party",[]).size():return {"ok":false,"reason":"missing_pokemon"}
    if not record.get("x") is int or not record.get("y") is int:return {"ok":false,"reason":"invalid_cell"}
    var cell=Vector2i(record.x,record.y)
    if not _near(actor,area,cell):return {"ok":false,"reason":"too_far"}
    for group in ["deployed_pokemon","wild_eggs"]:
        if reserved(key(area,group,cell)):return {"ok":false,"reason":"occupied"}
        if Delta.decode(state.records.get(key(area,group,cell),Delta.encode(null)))!=null:return {"ok":false,"reason":"occupied"}
    var pokemon:Dictionary=profile.party[slot]
    if record.get("species")!=pokemon.get("species"):return {"ok":false,"reason":"wrong_pokemon"}
    var stored=record.duplicate(true)
    # Identity, moves, IVs, shiny status and every party property come from the
    # already saved party; the placement contributes source habitat metadata.
    stored.merge(pokemon,true)
    stored.x=cell.x;stored.y=cell.y
    var group="wild_eggs" if pokemon.get("is_egg",false) else "deployed_pokemon"
    if group=="wild_eggs":stored["dropped_party_egg"]=true
    else:stored["ecology_id"]="coop_owned:"+actor+":"+id
    profile.party.remove_at(slot)
    return state.transact(actor,"deploy/"+id,[state.change("player/"+actor,profile),state.change(key(area,group,cell),Delta.encode(stored))],state.fingerprint(args))

func take(actor:String,id:String,area:String,cell:Vector2i,group:String,expected:String,box:String="",identity:String="")->Dictionary:
    var args=[area,cell,group,expected,box,identity]
    var previous=_prior(actor,"takepopulation/"+id,args)
    if not previous.is_empty():return previous
    if group not in ["deployed_pokemon","wild_eggs"]:return {"ok":false,"reason":"invalid_target"}
    # As for harvest: the Pokemon asked for, not this exact copy of its record
    # on that exact tile. It has often walked on, or its timers moved, by the
    # time the request arrives, and more so while its prompt was open.
    var found=find(area,group,cell,expected,identity)
    if found.is_empty():return {"ok":false,"reason":"too_late"}
    var record_key:String=found[0];var record:Dictionary=found[1]
    if group=="deployed_pokemon" and owned_by_other(record,actor):return {"ok":false,"reason":"not_owner"}
    var at=Vector2i(int(record.get("x",cell.x)),int(record.get("y",cell.y)))
    if not (_near(actor,area,cell) if group=="wild_eggs" else _reach(actor,area,at)):return {"ok":false,"reason":"too_far"}
    var profile:Dictionary=state.records.get("player/"+actor,{}).duplicate(true)
    if not profile.get("party") is Array or not profile.get("inventory") is Dictionary:return {"ok":false,"reason":"missing_profile"}
    var pokemon:Dictionary=record.duplicate(true)
    if group=="wild_eggs" and not record.get("dropped_party_egg",false):
        if not make_egg.is_valid():return {"ok":false,"reason":"egg_unavailable"}
        pokemon=make_egg.call(record,profile)
        if pokemon.is_empty():return {"ok":false,"reason":"egg_unavailable"}
    var carried=String(pokemon.get("held_item","")) if group=="deployed_pokemon" else ""
    if not carried.is_empty():pokemon["harvest_progress"]=0.0
    for field in ["x","y","cell","ready_at","ready_at_elapsed","last_harvest_day","sprite","move_timer","anim_phase","behavior","ecology_id","mate_id","friend_id","in_habitat","in_shelter","nearby_pokemon","held_item","can_lay_egg","missing_habitats","manured","house_door","house_floor","laid_at"]:pokemon.erase(field)
    var changes:Array=[]
    pokemon.erase("dropped_party_egg")
    if group=="wild_eggs" and not record.get("dropped_party_egg",false):
        var ecology=preload("res://scripts/pokemon_ecology.gd")
        var prefix="world/"+area+"/wild_pokemon/"
        for wild_key in state.records:
            if not String(wild_key).begins_with(prefix):continue
            var parent=Delta.decode(state.records[wild_key])
            if not parent is Dictionary or parent.get("burrowed",false):continue
            if state.records.has("wild_claim/"+area+"/"+String(wild_key).get_slice("/",3)):continue
            if absi(int(parent.x)-cell.x)>ecology.PARENT_ALERT_RADIUS or absi(int(parent.y)-cell.y)>ecology.PARENT_ALERT_RADIUS or not ecology.is_egg_parent_match(parent,record):continue
            parent["aggro_player"]=true;parent["warned"]=true;parent["coop_target"]=actor
            changes.append(state.change(wild_key,Delta.encode(parent)))
    if profile.party.size()<6:profile.party.append(pokemon)
    else:
        var chest:Dictionary=state.records.get("chest/"+box,{})
        if chest.is_empty():return {"ok":false,"reason":"no_room"}
        var destination=Items.new().box_key(actor,chest)
        var contents:Array=state.records.get(destination,[]).duplicate(true)
        if contents.size()>=4096:return {"ok":false,"reason":"no_room"}
        contents.append({"id":(actor+"/"+id).sha256_text(),"pokemon":pokemon})
        changes.append(state.change(destination,contents))
    if not carried.is_empty():profile.inventory[carried]=int(profile.inventory.get(carried,0))+1
    changes.append(state.change("player/"+actor,profile))
    changes.append(state.change(record_key,Delta.encode(null)))
    return state.transact(actor,"takepopulation/"+id,changes,state.fingerprint(args))

func _near(actor:String,area:String,cell:Vector2i)->bool:
    if state.members.get(actor,{}).get("area")!=area:return false
    var player:Dictionary=presence.get(actor,{})
    return String(player.get("area","")).begins_with(area+"|") and Vector2i(int(player.get("x",-999999)),int(player.get("y",-999999))).distance_squared_to(cell)<=2

func _reach(actor:String,area:String,cell:Vector2i)->bool:
    if state.members.get(actor,{}).get("area")!=area:return false
    var player:Dictionary=presence.get(actor,{})
    if not String(player.get("area","")).begins_with(area+"|"):return false
    var gap=Vector2i(int(player.get("x",-999999)),int(player.get("y",-999999)))-cell
    return maxi(absi(gap.x),absi(gap.y))<=REACH

func _prior(actor:String,id:String,args:Array)->Dictionary:
    if not state.members.has(actor):return {"ok":false,"reason":"not_admitted"}
    var previous:Dictionary=state.outcomes.get(actor+"/"+id,{})
    if previous.is_empty():return {}
    return previous.duplicate(true) if previous.get("command_hash")==state.fingerprint(args) else {"ok":false,"reason":"reused_request_id"}
