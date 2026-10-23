extends RefCounted
## Area generation is reserved once; nobody enters until its snapshot is durable.
var state
var reservations:Dictionary={}
var occupants:Dictionary={}
var epochs:Dictionary={}
var save_snapshot:=Callable()
var load_snapshot:=Callable()

static func valid_area(area:String)->bool:
    var parts=area.split(",")
    if parts.size()!=2:return false
    for part in parts:
        if not String(part).is_valid_int() or str(int(part))!=part or absi(int(part))>100000:return false
    return true

func request(actor:String,area:String)->Dictionary:
    if not state.members.has(actor) or not valid_area(area):return {"ok":false,"reason":"invalid_area"}
    var saved:Dictionary=state.records.get("area/"+area,{})
    if not saved.is_empty():
        return {"ok":true,"kind":"load","area":area,"metadata":saved.duplicate(true)}
    if reservations.has(area):
        var reserved:Dictionary=reservations[area]
        if actor==reserved.actor:return reserved.duplicate(true)
        return {"ok":true,"kind":"waiting","area":area}
    var token=preload("res://scripts/coop_random.gd").hex(16)
    var reservation={"ok":true,"kind":"generate","area":area,"actor":actor,"token":token}
    reservations[area]=reservation
    return reservation.duplicate(true)

func generated(actor:String,area:String,token:String,metadata:Dictionary,bytes:PackedByteArray)->Dictionary:
    var reservation:Dictionary=reservations.get(area,{})
    if reservation.is_empty() or reservation.actor!=actor or reservation.token!=token:
        return {"ok":false,"reason":"stale_generation"}
    if bytes.is_empty() or not save_snapshot.is_valid():return {"ok":false,"reason":"missing_snapshot"}
    if not metadata.get("seed") is int or not metadata.get("size") is int or int(metadata["size"])<0 or int(metadata["size"])>4:
        return {"ok":false,"reason":"invalid_metadata"}
    # The callback persists exact generated content, preserving existing spawn rules.
    # A caller performing disk work on a worker must call this after durable completion.
    var saved:Dictionary=save_snapshot.call(area,bytes)
    if not saved.get("ok",false):return {"ok":false,"reason":"save_failed"}
    var record=metadata.duplicate(true)
    record["snapshot"]=saved.get("snapshot","")
    record["sha256"]=saved.get("sha256","")
    var committed:Dictionary=state.transact(actor,"area/"+token,[state.change("area/"+area,record)])
    if not committed.get("ok",false):return committed
    reservations.erase(area)
    return {"ok":true,"kind":"saved","area":area,"metadata":record,"commit":committed}

func enter(actor:String,area:String)->Dictionary:
    if not state.members.has(actor) or not state.records.has("area/"+area):
        return {"ok":false,"reason":"area_not_saved"}
    if occupants.get(actor,area)!=area:leave(actor)
    var owner:String=state.enter(actor,area)
    occupants[actor]=area
    return {"ok":true,"area":area,"authority":owner,"epoch":int(epochs.get(area,0))}

func leave(actor:String)->void:
    var previous=String(occupants.get(actor,""))
    var old_owner=String(state.authority.get(previous,""))
    state.leave(actor);occupants.erase(actor)
    if old_owner==actor and not previous.is_empty():epochs[previous]=int(epochs.get(previous,0))+1
    for area in reservations.keys():
        if reservations[area].actor==actor:reservations.erase(area)

## The area's authority, in the area, at this epoch. A server that is every
## area's authority (coop_state.gd fixed_authority) holds those it is not in too.
func can_publish(actor:String,area:String,epoch:int)->bool:
    var present:bool=occupants.get(actor,"")==area or (not state.fixed_authority.is_empty() and actor==state.fixed_authority)
    return present and state.authority.get(area,"")==actor and int(epochs.get(area,0))==epoch

func snapshot(area:String)->Dictionary:
    var record:Dictionary=state.records.get("area/"+area,{})
    if record.is_empty() or not load_snapshot.is_valid():return {}
    return load_snapshot.call(area,record)
