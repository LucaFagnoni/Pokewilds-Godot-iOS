extends Node
## Connects area reservations to asynchronous disk snapshots and bounded transfers.
signal area_ready(actor:String, area:String, metadata:Dictionary, bytes:PackedByteArray)
signal generation_requested(actor:String, area:String, token:String)
signal waiting(actor:String, area:String)
signal failed(actor:String, reason:String)
const Areas=preload("res://scripts/coop_areas.gd")
const SnapshotStore=preload("res://scripts/coop_snapshot_store.gd")
const Blob=preload("res://scripts/coop_blob.gd")
const Snapshot=preload("res://scripts/coop_world_snapshot.gd")
var areas=Areas.new()
var snapshots:Node
var blobs=Blob.new()
var state
var session:Node
var _waiters:Dictionary={}
var _saving:Dictionary={}
var _transfers:Dictionary={}
var _received_metadata:Dictionary={}
var _reading:=false
var refresh_area:Callable
var register_objects:Callable
## Runs a Callable on a worker and waits for it (coop_game.gd _off_thread).
var off_thread:Callable
var uploads=Blob.new()
var _upload_headers:Dictionary={}
var _upload_results:Dictionary={}

func upload(area:String,token:String,epoch:int,bytes:PackedByteArray)->Dictionary:
    if session.hosting or not session.trusted:return {"ok":false,"reason":"not_connected"}
    var id=preload("res://scripts/coop_random.gd").hex(16)
    if not uploads.start_send(1,id,bytes):return {"ok":false,"reason":"transfer_busy"}
    if session.send_host({"kind":"area_upload","id":id,"area":area,"token":token,"epoch":epoch})!=OK:
        uploads.drop(1);return {"ok":false,"reason":"transfer_busy"}
    var deadline=Time.get_ticks_msec()+120000
    while session.trusted and Time.get_ticks_msec()<deadline:
        if _upload_results.has(id):
            var result:Dictionary=_upload_results[id];_upload_results.erase(id);return result
        await get_tree().process_frame
    uploads.drop(1)
    return {"ok":false,"reason":"transfer_timeout"}

## `decoded` and `saved`: the snapshot already decoded and saved (_receive_upload).
func publish(actor:String,area:String,epoch:int,bytes:PackedByteArray,decoded:Dictionary={},saved:Dictionary={})->Dictionary:
    if not areas.can_publish(actor,area,epoch):return {"ok":false,"reason":"not_authority"}
    if decoded.is_empty():decoded=await _worker(func():return Snapshot.decode(bytes))
    if decoded.is_empty():return {"ok":false,"reason":"invalid_snapshot"}
    if saved.is_empty():saved=await snapshots.save_bytes(bytes)
    if not saved.get("ok",false):return saved
    if not areas.can_publish(actor,area,epoch):return {"ok":false,"reason":"stale_authority"}
    var previous:Dictionary=state.records.get("area/"+area,{})
    if previous.get("seed")!=decoded.seed or previous.get("size")!=decoded["size"]:return {"ok":false,"reason":"wrong_area"}
    var metadata={"seed":decoded.seed,"size":decoded["size"],"snapshot":saved.snapshot,"sha256":saved.sha256}
    if register_objects.is_valid() and not await register_objects.call(area,decoded.shared):return {"ok":false,"reason":"registry_save_failed"}
    # Its metadata from now on has no "population_pending": its Pokemon are in.
    spawners.erase(area)
    return state.transact(actor,"publish/"+preload("res://scripts/coop_random.gd").hex(16),[state.change("area/"+area,metadata)])

func _upload_fragment(_peer:int,packet:Dictionary)->Error:
    var outgoing=packet.duplicate();outgoing.kind="area_upload_blob"
    return session.send_host(outgoing)

func _receive_upload(peer:int,actor:String,packet:Dictionary)->void:
    var header:Dictionary=_upload_headers.get(peer,{})
    if header.is_empty():return
    var fragment=packet.duplicate();fragment.kind="blob"
    var result:Dictionary=uploads.receive(peer,fragment,true)
    if result.has("error"):
        _upload_headers.erase(peer);session.send_to(peer,{"kind":"area_upload_result","id":header.id,"result":{"ok":false,"reason":result.error}});return
    if not result.has("bytes"):return
    _upload_headers.erase(peer)
    var bytes:PackedByteArray=result.bytes
    var digest:String=result.sha256
    var resave:=String(header.token).is_empty()
    # A re-save comes without the terrain cache: put back the one stored here.
    # Hashed, made whole and decoded on a worker, once: an area is megabytes,
    # and doing it here (and decoding it twice) took the host 20-35 ms a frame.
    var stored:=PackedByteArray()
    if resave:stored=await _stored(String(header.area))
    var made:Array=await _worker(func():
        var whole:=bytes;var hashed:=digest
        if resave and not stored.is_empty() and Blob.digest(bytes)==digest:
            var refilled:=Snapshot.refill(bytes,stored)
            if not refilled.is_empty():whole=refilled;hashed=Blob.digest(refilled)
        return [whole,hashed,Snapshot.decode(whole)])
    bytes=made[0];digest=made[1]
    var verified:Dictionary=await snapshots.save_bytes(bytes)
    var outcome={"ok":false,"reason":"invalid_snapshot"}
    if result.id==header.id and verified.get("ok",false) and verified.get("sha256")==digest:
        var decoded:Dictionary=made[2]
        if not decoded.is_empty():
            if resave:outcome=await publish(actor,header.area,int(header.epoch),bytes,decoded,verified)
            else:outcome=await generated(actor,header.area,header.token,{"seed":decoded.seed,"size":decoded["size"]},bytes,decoded,verified)
    session.send_to(peer,{"kind":"area_upload_result","id":header.id,"result":outcome})

## This area's stored snapshot, which a re-save without the terrain cache is
## made whole from (Snapshot.refill); empty when there is none.
func _stored(area:String)->PackedByteArray:
    var record:Dictionary=state.records.get("area/"+area,{})
    if not record.get("sha256") is String:return PackedByteArray()
    var stored:Dictionary=await snapshots.load_bytes(record.sha256)
    return stored.bytes if stored.get("ok",false) else PackedByteArray()

func _worker(work:Callable)->Variant:
    if not off_thread.is_valid():return work.call()
    return await off_thread.call(work)

func configure(model,connection:Node,directory:String)->Error:
    state=model;session=connection;areas.state=state
    snapshots=SnapshotStore.new();add_child(snapshots)
    process_mode=Node.PROCESS_MODE_ALWAYS
    session.message.connect(_message)
    session.departed.connect(_departed)
    return snapshots.configure(directory)

func request(actor:String,area:String)->void:
    if not session.hosting:return
    if Areas.valid_area(area) and refresh_area.is_valid():
        if not await refresh_area.call(area):_fail(actor,"area_save_failed");return
    var reservation:Dictionary=areas.request(actor,area)
    if not reservation.get("ok",false):_fail(actor,reservation.get("reason","invalid_area"));return
    if reservation.kind=="load":
        # Loads reserve the maximum snapshot budget. Serialize simultaneous joins
        # instead of rejecting one guest when another guest is reading an area.
        while _reading:
            await get_tree().process_frame
            if _peer(actor)<0:return
        _reading=true
        var loaded:Dictionary=await snapshots.load_bytes(reservation.metadata.sha256)
        _reading=false
        if not loaded.get("ok",false):_fail(actor,loaded.get("reason","load_failed"));return
        await _deliver(actor,area,reservation.metadata,loaded.bytes)
    elif reservation.kind=="generate":
        generation_requested.emit(actor,area,reservation.token)
    else:
        if not _waiters.has(area):_waiters[area]=[]
        if actor not in _waiters[area]:_waiters[area].append(actor)
        waiting.emit(actor,area)

## `decoded` and `saved` as for publish.
func generated(actor:String,area:String,token:String,metadata:Dictionary,bytes:PackedByteArray,decoded:Dictionary={},saved:Dictionary={})->Dictionary:
    if not session.hosting or _saving.has(area):return {"ok":false,"reason":"busy"}
    var reservation:Dictionary=areas.reservations.get(area,{})
    if reservation.get("actor","")!=actor or reservation.get("token","")!=token:return {"ok":false,"reason":"stale_generation"}
    _saving[area]=token
    if saved.is_empty():saved=await snapshots.save_bytes(bytes)
    _saving.erase(area)
    if not saved.get("ok",false):_fail(actor,saved.get("reason","save_failed"));return saved
    # The large file has already been flushed on the worker. Journal metadata next.
    areas.save_snapshot=func(_area,_bytes):return saved
    var result:Dictionary=areas.generated(actor,area,token,metadata,bytes)
    areas.save_snapshot=Callable()
    if not result.get("ok",false):_fail(actor,result.get("reason","save_failed"));return result
    if register_objects.is_valid():
        if decoded.is_empty():decoded=await _worker(func():return Snapshot.decode(bytes))
        if decoded.is_empty() or not await register_objects.call(area,decoded.shared):return {"ok":false,"reason":"registry_save_failed"}
    await _deliver(actor,area,result.metadata,bytes)
    var queued:Array=_waiters.get(area,[])
    _waiters.erase(area)
    for other in queued:
        if state.members.has(other):await _deliver(other,area,result.metadata,bytes)
    return result

func _peer(actor:String)->int:
    for peer in session.players:
        if session.players[peer].actor==actor:return int(peer)
    return -1

## An area made with its Pokemon still to place ("population_pending", made
## by server_area_maker.gd): the one player who places them, area -> actor.
## The others who arrive meanwhile are sent it without the mark and see its
## Pokemon when that player sends the area back; one who leaves first passes
## the task to whoever comes next.
var spawners:Dictionary={}

func _deliver(actor:String,area:String,metadata:Dictionary,bytes:PackedByteArray)->void:
    var peer:=_peer(actor)
    if peer<0:return
    if metadata.get("population_pending",false):
        if String(spawners.get(area,actor))!=actor:
            metadata=metadata.duplicate();metadata.erase("population_pending")
        else:spawners[area]=actor
    if peer==1:area_ready.emit(actor,area,metadata,bytes);return
    var id:=preload("res://scripts/coop_random.gd").hex(16)
    if not blobs.start_send(peer,id,bytes,String(metadata.sha256)):_fail(actor,"transfer_busy");return
    var packet={"kind":"area_metadata","id":id,"area":area,"metadata":metadata}
    var error:Error=session.send_to(peer,packet)
    if error!=OK:blobs.drop(peer);_fail(actor,"transfer_busy");return
    _transfers[peer]={"id":id,"actor":actor,"area":area}

func _process(_delta:float)->void:
    if session==null:return
    blobs.expire()
    uploads.expire()
    if not session.hosting:
        if uploads.outgoing.has(1):
            var upload_error:Error=uploads.pump(1,_upload_fragment)
            if upload_error not in [OK,ERR_BUSY]:uploads.drop(1)
        return
    for peer in blobs.outgoing.keys():
        var error:Error=blobs.pump(peer,session.send_to)
        if error not in [OK,ERR_BUSY]:
            blobs.drop(peer);_transfers.erase(peer)

func _message(peer:int,actor:String,packet:Dictionary)->void:
    var kind=packet.get("kind","")
    if session.hosting:
        if kind=="area_request" and packet.get("area") is String:request(actor,packet.area)
        elif kind=="area_upload":
            if not packet.get("area") is String or not packet.get("id") is String or not packet.get("token") is String:return
            if not Areas.valid_area(packet.area) or packet.id.length()!=32 or not packet.id.is_valid_hex_number() or _upload_headers.has(peer):return
            var epoch=packet.get("epoch")
            if typeof(epoch) not in [TYPE_INT,TYPE_FLOAT] or not is_finite(float(epoch)) or float(epoch)!=floor(float(epoch)):return
            var reservation:Dictionary=areas.reservations.get(packet.area,{})
            var allowed=areas.can_publish(actor,packet.area,int(epoch)) if packet.token.is_empty() else reservation.get("actor")==actor and reservation.get("token")==packet.token
            if allowed:_upload_headers[peer]=packet
            else:session.send_to(peer,{"kind":"area_upload_result","id":packet.id,"result":{"ok":false,"reason":"not_authority"}})
        elif kind=="area_upload_blob":_receive_upload(peer,actor,packet)
        return
    if kind=="area_error" and packet.get("reason") is String:
        failed.emit(session.actor,packet.reason);return
    if kind=="area_upload_result" and packet.get("id") is String and packet.get("result") is Dictionary:
        _upload_results[packet.id]=packet.result;return
    if kind=="area_metadata":
        if not packet.get("id") is String or not packet.get("area") is String or not packet.get("metadata") is Dictionary:return
        if not Areas.valid_area(packet.area) or _received_metadata.size()>=4:return
        _received_metadata[packet.id]=packet
    elif kind=="blob":
        var result=blobs.receive(peer,packet,true)
        if result.has("error"):_fail(session.actor,result.error);return
        if not result.has("bytes"):return
        var metadata:Dictionary=_received_metadata.get(result.id,{})
        _received_metadata.erase(result.id)
        if metadata.is_empty():_fail(session.actor,"missing_area_metadata");return
        var verified:Dictionary=await snapshots.save_bytes(result.bytes)
        if not verified.get("ok",false) or verified.get("sha256","")!=metadata.metadata.get("sha256","") or verified.get("sha256","")!=result.sha256:
            _fail(session.actor,"area_digest");return
        area_ready.emit(session.actor,metadata.area,metadata.metadata,result.bytes)

func _departed(peer:int,actor:String)->void:
    blobs.drop(peer);_transfers.erase(peer)
    for area in spawners.keys():
        if spawners[area]==actor:spawners.erase(area)
    uploads.drop(peer);_upload_headers.erase(peer)
    var abandoned:Array=[]
    for area in areas.reservations:
        if areas.reservations[area].actor==actor:abandoned.append(area)
    areas.leave(actor)
    for area in _waiters:
        _waiters[area].erase(actor)
    for area in abandoned:
        var queued:Array=_waiters.get(area,[])
        while not queued.is_empty():
            var next_actor:String=queued.pop_front()
            if _peer(next_actor)>0:
                request.call_deferred(next_actor,area)
                break

func _fail(actor:String,reason:String)->void:
    if session.hosting and actor!=session.actor:
        var peer=_peer(actor)
        if peer>1:session.send_to(peer,{"kind":"area_error","reason":reason})
    failed.emit(actor,reason)
