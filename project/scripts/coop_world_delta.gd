extends RefCounted
## Typed, per-record world changes. Personal state and the shared clock stay separate.
const Snapshot=preload("res://scripts/coop_world_snapshot.gd")
const State=preload("res://scripts/coop_state.gd")
const CELLS=["structures","deployed_pokemon","wild_eggs"]
const SETS=["removed_resources","built_house_floor_tiles"]
const MAPS=["terrain_changes","source_plant_farms","source_interior_mutations",
    "mine_pokemon","built_house_paintings","built_house_decorations","built_house_origins","event_progress"]
const SCALARS=["next_deployed_id","ghost_step_countdown","source_interior_layout_version"]
const MAX_ENTRY_BYTES=256*1024
const MAX_PATCHES=256
const MAX_PACKET_BYTES=2*1024*1024
## Fields that change as a creature wanders. A commit that changes nothing else
## is not journaled: after a crash the creature is simply where the last world
## save left it. Anything not listed here (level, HP, held item, a record that
## appears, disappears or changes cell key) is always journaled.
const MOTION_FIELDS=["x","y","move_timer","next_move","anim_phase","facing_pair","facing_row","flip_h",
    "lay_egg_seconds","friend_seconds","harvest_progress","nearby_pokemon","mate_id","friend_id","mate_nearby",
    "can_lay_egg","in_habitat","in_shelter","missing_habitats","charmed","warned","aggro_player","flee_steps"]
var state
var can_publish:Callable

static func _moved_only(before:Dictionary,after:Dictionary)->bool:
    var keys:Dictionary={}
    for key in before:keys[key]=true
    for key in after:keys[key]=true
    for key in keys:
        if key in MOTION_FIELDS:continue
        if not before.has(key) or not after.has(key) or encode(before[key])!=encode(after[key]):return false
    return true

## True when two encoded values differ only by a creature having wandered. The
## value is one creature record, or a map of them (the roaming event Pokemon).
static func only_motion(before:String,after:String)->bool:
    var old=decode(before);var next=decode(after)
    if not old is Dictionary or not next is Dictionary:return false
    if old.has("x") and next.has("x"):return _moved_only(old,next)
    if old.size()!=next.size():return false
    for key in next:
        if not old.get(key) is Dictionary or not next[key] is Dictionary or not _moved_only(old[key],next[key]):return false
    return true

func motion_only(area:String,patches:Array)->bool:
    for patch in patches:
        if not patch is Dictionary or not patch.get("key") is String or not patch.get("after") is String:return false
        var previous=state.records.get("world/"+area+"/"+patch.key)
        if not previous is String or not only_motion(previous,patch.after):return false
    return true

static func canonical(value:Variant)->Variant:
    if value is Dictionary:
        var result:Dictionary={}
        var keys=value.keys();keys.sort_custom(func(a,b):return str(a)<str(b))
        for key in keys:result[key]=canonical(value[key])
        return result
    if value is Array:
        var result:Array=[]
        for item in value:result.append(canonical(item))
        return result
    return value

static func encode(value:Variant)->String:
    return Marshalls.raw_to_base64(var_to_bytes(canonical(value)))

static func decode(value:String)->Variant:
    # Network data can never instantiate scripts, resources or other objects.
    return bytes_to_var(Marshalls.base64_to_raw(value))

static func flatten(shared:Dictionary)->Dictionary:
    var result:Dictionary={}
    for group in CELLS+["wild_pokemon"]:
        for record in shared.get(group,[]):
            var id=str(int(record.id)) if group=="wild_pokemon" else "%d,%d"%[int(record.x),int(record.y)]
            result[group+"/"+id.uri_encode()]=encode(record)
    for group in SETS:
        for key in shared.get(group,[]):result[group+"/"+str(key).uri_encode()]=encode(key)
    for group in MAPS:
        for key in shared.get(group,{}):
            var value=shared[group][key]
            # Hole edge/corner suffixes are derived from neighboring terrain.
            # Replicas reconnect them locally; they are not competing edits.
            if group=="source_interior_mutations" and value is Dictionary and String(value.get("upper","")).begins_with("hole1"):
                value=value.duplicate(true);value["upper"]="hole1"
            result[group+"/"+str(key).uri_encode()]=encode(value)
    for group in SCALARS:
        if shared.has(group):result[group+"/value"]=encode(shared[group])
    return result

static func inflate(flat:Dictionary,base:Dictionary={})->Dictionary:
    var result=base.duplicate(true)
    for group in CELLS+SETS+["wild_pokemon"]:result[group]=[]
    for group in MAPS:result[group]={}
    for group in SCALARS:result.erase(group)
    for key in flat:
        var group=String(key).get_slice("/",0)
        var id=String(key).get_slice("/",1).uri_decode()
        var value=decode(String(flat[key]))
        if value==null:continue
        if group in CELLS+SETS+["wild_pokemon"]:result[group].append(value)
        elif group in MAPS:result[group][id]=value
        elif group in SCALARS:result[group]=value
    return result

static func diff(before:Dictionary,after:Dictionary)->Array:
    var changes:Array=[]
    var keys=before.keys()
    for key in after:
        if not before.has(key):keys.append(key)
    var empty=encode(null)
    for key in keys:
        var old=before.get(key,empty);var next=after.get(key,empty)
        if old!=next:changes.append({"key":key,"before":State.fingerprint(old),"after":next})
    return changes

static func valid_key(key:String)->bool:
    if key.length()>160 or key.count("/")!=1:return false
    var group=key.get_slice("/",0)
    var id=key.get_slice("/",1).uri_decode()
    if id.is_empty() or id.uri_encode()!=key.get_slice("/",1):return false
    if group in CELLS:
        var coordinates=id.split(",")
        return coordinates.size()==2 and coordinates[0].is_valid_int() and coordinates[1].is_valid_int()
    if group=="wild_pokemon":return id.is_valid_int()
    return group in MAPS+SETS or (group in SCALARS and id=="value")

func records(area:String)->Dictionary:
    var result:Dictionary={};var prefix="world/"+area+"/"
    for key in state.records:
        if String(key).begins_with(prefix):result[String(key).trim_prefix(prefix)]=state.records[key]
    return result

func seed(actor:String,area:String,shared:Dictionary)->bool:
    if not preload("res://scripts/coop_areas.gd").valid_area(area):return false
    if state.records.get("world_ready/"+area,false):return true
    var flat=flatten(shared);var batch:Array=[]
    for key in flat:
        batch.append(state.change("world/"+area+"/"+key,flat[key]))
        if batch.size()==MAX_PATCHES:
            if not state.transact(actor,"worldseed/"+preload("res://scripts/coop_random.gd").hex(16),batch).get("ok",false):return false
            batch=[]
    batch.append(state.change("world_ready/"+area,true))
    return bool(state.transact(actor,"worldseed/"+preload("res://scripts/coop_random.gd").hex(16),batch).get("ok",false))

func commit(actor:String,id:String,area:String,epoch:int,patches:Array,motion:bool=false)->Dictionary:
    var hash_value=State.fingerprint([area,epoch,patches])
    var prior:Dictionary=state.outcomes.get(actor+"/world/"+id,{})
    if not prior.is_empty():
        return prior.duplicate(true) if prior.get("command_hash")==hash_value else {"ok":false,"reason":"reused_request_id"}
    if not can_publish.is_valid() or not can_publish.call(actor,area,epoch):return {"ok":false,"reason":"not_authority"}
    var prepared=prepare_changes(area,patches)
    if not prepared.get("ok",false):return prepared
    return state.transact(actor,"world/"+id,prepared.changes,hash_value,not (motion and motion_only(area,patches)))

func prepare_changes(area:String,patches:Array)->Dictionary:
    # Shared validation is also used by actions whose material cost must commit
    # in the same journal entry as the resulting world records.
    if not state.records.get("world_ready/"+area,false):return {"ok":false,"reason":"area_not_ready"}
    if patches.is_empty() or patches.size()>MAX_PATCHES:return {"ok":false,"reason":"invalid_changes"}
    var changes:Array=[];var used:Dictionary={};var bytes=0
    for patch in patches:
        if not patch is Dictionary or not patch.get("key") is String or not patch.get("before") is String or not patch.get("after") is String:
            return {"ok":false,"reason":"invalid_changes"}
        var key=String(patch.key)
        if not valid_key(key) or used.has(key):return {"ok":false,"reason":"invalid_key"}
        used[key]=true;bytes+=patch.after.length()
        if patch.after.length()>MAX_ENTRY_BYTES or bytes>MAX_PACKET_BYTES:return {"ok":false,"reason":"too_large"}
        var value=decode(patch.after)
        if encode(value)!=patch.after:return {"ok":false,"reason":"invalid_value"}
        var group=key.get_slice("/",0)
        if value!=null:
            if group in CELLS+["wild_pokemon"] and not value is Dictionary:return {"ok":false,"reason":"invalid_record"}
            if group in SCALARS and not value is int:return {"ok":false,"reason":"invalid_scalar"}
            if group in CELLS:
                if not value.get("x") is int or not value.get("y") is int or "%d,%d"%[value.x,value.y]!=key.get_slice("/",1).uri_decode():return {"ok":false,"reason":"wrong_cell"}
            if group=="wild_pokemon" and (not value.get("id") is int or str(value.id)!=key.get_slice("/",1).uri_decode()):return {"ok":false,"reason":"wrong_actor"}
            if group in SETS and str(value)!=key.get_slice("/",1).uri_decode():return {"ok":false,"reason":"wrong_set_entry"}
        var full="world/"+area+"/"+key
        var previous=state.records.get(full,encode(null))
        if State.fingerprint(previous)!=patch.before:return {"ok":false,"reason":"conflict","key":key,"current":previous}
        changes.append(state.change(full,patch.after))
    return {"ok":true,"changes":changes}
