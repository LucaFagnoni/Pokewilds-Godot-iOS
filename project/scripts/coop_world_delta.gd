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
        # Both were decoded from encode(), already in its order: the bytes
        # compare as encode() would, without sorting every nested key again.
        if not before.has(key) or not after.has(key) or var_to_bytes(before[key])!=var_to_bytes(after[key]):return false
    return true

## True when two encoded values differ only by a creature having wandered. The
## value is one creature record, or a map of them (the roaming event Pokemon).
static func only_motion(before:String,after:String)->bool:
    var old=decode_shared(before);var next=decode_shared(after)
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

static func _sorted_keys(value:Dictionary)->Array:
    var keys=value.keys()
    # Text keys sort the same natively, without a script call per comparison.
    if keys.all(func(key):return key is String):keys.sort()
    else:keys.sort_custom(func(a,b):return str(a)<str(b))
    return keys

static func canonical(value:Variant)->Variant:
    if value is Dictionary:
        var result:Dictionary={}
        for key in _sorted_keys(value):result[key]=canonical(value[key])
        return result
    if value is Array:
        var result:Array=[]
        for item in value:result.append(canonical(item))
        return result
    return value

static func encode(value:Variant)->String:
    return Marshalls.raw_to_base64(var_to_bytes(canonical(value)))

## encode() of a map most of whose entries stay the same from one call to the
## next: the roaming Megas, 16 KB, which took 0.3 ms to pack each time one of
## them moved. Each entry is packed again only when its bytes have changed; the
## map's bytes are its header and the entries' bytes in key order, as
## var_to_bytes writes them. `memo` is the caller's own, one per map.
static func encode_map(value:Variant,memo:Dictionary)->String:
    if not value is Dictionary:return encode(value)
    var keys:=_sorted_keys(value)
    var bytes:=var_to_bytes({})
    bytes.encode_u32(4,keys.size())
    for key in keys:
        var raw:=var_to_bytes(value[key])
        var held:Array=memo.get(key,[])
        if held.is_empty() or held[0]!=raw:
            held=[raw,var_to_bytes(key)+var_to_bytes(canonical(value[key]))];memo[key]=held
        bytes.append_array(held[1])
    for key in memo.keys():
        if not value.has(key):memo.erase(key)
    var result:=Marshalls.raw_to_base64(bytes)
    _made.append(result)
    if _made.size()>4:_made.pop_front()
    # Whoever publishes it reads it straight back (decode_shared): from the
    # bytes at hand, not the text.
    _remember(result,bytes_to_var(bytes))
    return result

## The last few encode_map() results: already in encode()'s form, so checking
## that one needs no second encode.
static var _made:Array=[]

static func decode(value:String)->Variant:
    # Network data can never instantiate scripts, resources or other objects.
    return bytes_to_var(Marshalls.base64_to_raw(value))

## decode() for readers that never change the result: a record is decoded
## several times on its way through one commit (checked, compared with the
## one before, diffed for the players), 0.2 ms each for the Megas' 16 KB.
## The last few are kept and shared.
const SHARED_DECODES:=16
static var _decoded:Dictionary={}
static var _decoded_order:Array=[]

static func decode_shared(value:String)->Variant:
    if _decoded.has(value):return _decoded[value]
    var result=decode(value)
    _remember(value,result)
    return result

static func _remember(value:String,decoded:Variant)->void:
    if _decoded.has(value):return
    _decoded[value]=decoded;_decoded_order.append(value)
    if _decoded_order.size()>SHARED_DECODES:_decoded.erase(_decoded_order.pop_front())

## A change to a record that is a dictionary, as only the entries that differ:
## {"set":[[path,value],...],"drop":[path,...]}. A path is the list of keys down
## nested dictionaries; paths and values are var_to_bytes in base64. A wild
## Pokemon or a roaming Mega moves by changing a few numbers; the rest (the
## whole Pokemon) used to travel again on every step, about 30 KB a second
## while the Megas roamed. null when the whole record is about as small.
const MAX_DELTA_ENTRIES:=4096
const MAX_DELTA_DEPTH:=8

static func entry_delta(before:Variant,after:String)->Variant:
    if not before is String:return null
    var old=decode_shared(before);var next=decode_shared(after)
    if not old is Dictionary or not next is Dictionary:return null
    var set:Array=[];var drop:Array=[]
    _delta_walk(old,next,[],set,drop)
    var size:=0
    for pair in set:size+=String(pair[0]).length()+String(pair[1]).length()
    for path in drop:size+=String(path).length()
    if size*2>after.length() or set.size()+drop.size()>MAX_DELTA_ENTRIES:return null
    return {"set":set,"drop":drop}

static func _delta_walk(old:Dictionary,next:Dictionary,path:Array,set:Array,drop:Array)->void:
    for key in next:
        var here:Array=path.duplicate();here.append(key)
        if old.has(key):
            # Both sides come from encode(), so equal entries have equal bytes.
            if var_to_bytes(old[key])==var_to_bytes(next[key]):continue
            if old[key] is Dictionary and next[key] is Dictionary and here.size()<MAX_DELTA_DEPTH:
                _delta_walk(old[key],next[key],here,set,drop);continue
        set.append([Marshalls.raw_to_base64(var_to_bytes(here)),Marshalls.raw_to_base64(var_to_bytes(next[key]))])
    for key in old:
        if not next.has(key):
            var gone:Array=path.duplicate();gone.append(key)
            drop.append(Marshalls.raw_to_base64(var_to_bytes(gone)))

## The record `before` with `delta` applied, encoded; "" when it does not fit.
## Whoever applies one checks the result against the sender's fingerprint.
static func apply_delta(before:Variant,delta:Variant)->String:
    if not before is String or not delta is Dictionary or not delta.get("set") is Array or not delta.get("drop") is Array:return ""
    if delta.set.size()+delta.drop.size()>MAX_DELTA_ENTRIES:return ""
    var record=decode(before)
    if not record is Dictionary:return ""
    # The record and the values come from encode(), already in its order; only
    # a new key needs the whole record put in order again.
    var added:=false
    for pair in delta.set:
        if not pair is Array or pair.size()!=2 or not pair[0] is String or not pair[1] is String or pair[0].length()>4096 or pair[1].length()>MAX_ENTRY_BYTES*2:return ""
        var parent=_delta_parent(record,decode(pair[0]))
        if parent==null:return ""
        if not parent[0].has(parent[1]):added=true
        parent[0][parent[1]]=decode(pair[1])
    for encoded in delta.drop:
        if not encoded is String or encoded.length()>4096:return ""
        var parent=_delta_parent(record,decode(encoded))
        if parent==null:return ""
        parent[0].erase(parent[1])
    return encode(record) if added else Marshalls.raw_to_base64(var_to_bytes(record))

## [dictionary, key] that a path ends at, or null when it leads nowhere.
static func _delta_parent(record:Dictionary,path:Variant)->Variant:
    if not path is Array or path.is_empty() or path.size()>MAX_DELTA_DEPTH:return null
    var at:Dictionary=record
    for index in range(path.size()-1):
        var step=at.get(path[index])
        if not step is Dictionary:return null
        at=step
    return [at,path[-1]]

## Patches whose record is sent as a delta, with "print" (the fingerprint of
## the record it makes) in place of "after", turned back into whole ones.
## null, with the key in `failed`, when one does not fit the stored record.
func expand(area:String,patches:Array,failed:Array=[])->Variant:
    var result:Array=[]
    for patch in patches:
        if patch is Dictionary and not patch.has("after") and patch.has("delta") and patch.get("key") is String and patch.get("print") is String:
            var whole:Dictionary=patch.duplicate();whole.erase("delta");whole.erase("print")
            whole["after"]=apply_delta(state.records.get("world/"+area+"/"+String(patch.key)),patch.delta)
            if String(whole.after).is_empty() or State.fingerprint(whole.after)!=patch.print:failed.append(patch.key);return null
            result.append(whole)
        else:result.append(patch)
    return result

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

## A new area's records, written in batches; `breathe` (awaited after each
## batch and group) lets the host's frame go on between them.
func seed(actor:String,area:String,shared:Dictionary,breathe:Callable=Callable())->bool:
    if not preload("res://scripts/coop_areas.gd").valid_area(area):return false
    if state.records.get("world_ready/"+area,false):return true
    var batch:Array=[]
    for group in CELLS+["wild_pokemon"]+SETS+MAPS+SCALARS:
        if not shared.has(group):continue
        var flat=flatten({group:shared[group]})
        for key in flat:
            batch.append(state.change("world/"+area+"/"+key,flat[key]))
            if batch.size()==MAX_PATCHES:
                if not state.transact(actor,"worldseed/"+preload("res://scripts/coop_random.gd").hex(16),batch).get("ok",false):return false
                batch=[]
                if breathe.is_valid():await breathe.call()
        if breathe.is_valid():await breathe.call()
    batch.append(state.change("world_ready/"+area,true))
    return bool(state.transact(actor,"worldseed/"+preload("res://scripts/coop_random.gd").hex(16),batch).get("ok",false))

func commit(actor:String,id:String,area:String,epoch:int,patches:Array,motion:bool=false)->Dictionary:
    var hash_value=State.fingerprint([area,epoch,patches])
    var prior:Dictionary=state.outcomes.get(actor+"/world/"+id,{})
    if not prior.is_empty():
        return prior.duplicate(true) if prior.get("command_hash")==hash_value else {"ok":false,"reason":"reused_request_id"}
    if not can_publish.is_valid() or not can_publish.call(actor,area,epoch):return {"ok":false,"reason":"not_authority"}
    var failed:Array=[]
    var expanded=expand(area,patches,failed)
    if expanded==null:return {"ok":false,"reason":"conflict","key":failed[0],"current":state.records.get("world/"+area+"/"+String(failed[0]),encode(null))}
    patches=expanded
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
        var value=decode_shared(patch.after)
        if not patch.after in _made and encode(value)!=patch.after:return {"ok":false,"reason":"invalid_value"}
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
        # The stored record's fingerprint, worked out once per change to it.
        if state.print_of(full,encode(null))!=patch.before:return {"ok":false,"reason":"conflict","key":key,"current":previous}
        changes.append(state.change(full,patch.after))
    return {"ok":true,"changes":changes}
