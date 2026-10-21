extends Node
## Durable area-owner updates over the authenticated connection.
signal changed(area:String,changes:Array)
const Delta=preload("res://scripts/coop_world_delta.gd")
var session:Node
var model=Delta.new()
var cache:Dictionary={}
var _replies:Dictionary={}
var _pending:Array=[]
var _waiting:Dictionary={}
var _receipts:Dictionary={}

func configure(connection:Node,state,authority:Callable)->void:
    session=connection;model.state=state;model.can_publish=authority
    session.message.connect(_message)
    session.departed.connect(func(peer,_actor):
        _pending=_pending.filter(func(entry):return int(entry.peer)!=peer))
    process_mode=Node.PROCESS_MODE_ALWAYS

func prime(area:String,shared:Dictionary)->void:
    cache[area]=Delta.flatten(shared)

func publish(area:String,epoch:int,patches:Array)->Dictionary:
    if not session.trusted:return {"ok":false,"reason":"disconnected"}
    var id=preload("res://scripts/coop_random.gd").hex(16)
    if session.hosting:return _commit(session.actor,id,area,epoch,patches)
    if _waiting.has(area):return {"ok":false,"reason":"busy"}
    _waiting[area]=id
    var packet={"kind":"world_delta","id":id,"area":area,"epoch":epoch,"patches":patches}
    var error:Error=session.send_host(packet)
    if error!=OK:_waiting.erase(area);return {"ok":false,"reason":"connection_busy"}
    var deadline=Time.get_ticks_msec()+15000;var retry=Time.get_ticks_msec()+3000
    while session.trusted and Time.get_ticks_msec()<deadline:
        if _replies.has(id):
            var result:Dictionary=_replies[id];_replies.erase(id);_waiting.erase(area);return result
        if Time.get_ticks_msec()>=retry:session.send_host(packet);retry=Time.get_ticks_msec()+3000
        await get_tree().process_frame
    _waiting.erase(area)
    return {"ok":false,"reason":"disconnected"}

func _commit(actor:String,id:String,area:String,epoch:int,patches:Array)->Dictionary:
    var revision:int=model.state.revision
    var result:Dictionary=model.commit(actor,id,area,epoch,patches)
    if result.get("ok",false) and model.state.revision>revision:
        var packet={"kind":"world_committed","area":area,"actor":actor,"id":id,"changes":result.changes}
        _apply(packet)
        for peer in session.players:
            if peer==1:continue
            var recipient=String(session.players[peer].actor)
            if model.state.members.get(recipient,{}).get("area")==area:_send(peer,packet)
    return result

func _send(peer:int,packet:Dictionary)->void:
    if _pending.any(func(entry):return int(entry.peer)==peer):
        if _pending.size()>=128:session.transport._drop(peer)
        else:_pending.append({"peer":peer,"packet":packet})
        return
    var error:Error=session.send_to(peer,packet)
    if error==ERR_BUSY:
        if _pending.size()>=128:session.transport._drop(peer)
        else:_pending.append({"peer":peer,"packet":packet})
    elif error!=OK:session.transport._drop(peer)

func _process(_delta:float)->void:
    if _pending.is_empty():return
    var blocked:Dictionary={}
    for entry in _pending.duplicate():
        if blocked.has(entry.peer):continue
        var error:Error=session.send_to(entry.peer,entry.packet)
        if error==ERR_BUSY:blocked[entry.peer]=true;continue
        _pending.erase(entry)
        if error!=OK:session.transport._drop(entry.peer)

func _message(peer:int,actor:String,packet:Dictionary)->void:
    if session.hosting:
        if packet.get("kind")!="world_delta":return
        if not packet.get("id") is String or packet.id.length()!=32 or not packet.id.is_valid_hex_number():return
        if not packet.get("area") is String or not preload("res://scripts/coop_areas.gd").valid_area(packet.area):return
        var epoch=packet.get("epoch")
        if typeof(epoch) not in [TYPE_FLOAT,TYPE_INT] or not is_finite(float(epoch)) or float(epoch)!=floor(float(epoch)):return
        if not packet.get("patches") is Array:return
        var result=_commit(actor,packet.id,packet.area,int(epoch),packet.patches)
        # The full commit is broadcast once. The acknowledgment carries no duplicate
        # world payload, which keeps retries small even for large changes.
        var reply=result.duplicate(true);reply.erase("changes")
        _send(peer,{"kind":"world_delta_result","id":packet.id,"result":reply})
    elif packet.get("kind")=="world_delta_result" and packet.get("id") is String and packet.get("result") is Dictionary:
        if packet.id in _waiting.values():_replies[packet.id]=packet.result
    elif packet.get("kind")=="world_committed":_apply(packet)

func _apply(packet:Dictionary)->void:
    if not packet.get("area") is String or not packet.get("changes") is Array:return
    var area=String(packet.area);var receipt=String(packet.get("actor",""))+"/"+String(packet.get("id",""))
    if _receipts.has(receipt):return
    if _receipts.size()>=256:_receipts.erase(_receipts.keys()[0])
    _receipts[receipt]=true
    if not cache.has(area):cache[area]={}
    var prefix="world/"+area+"/"
    var applied:Array=[]
    for change in packet.changes:
        if not change is Dictionary or not change.get("key") is String or not change.get("after") is String:continue
        if not String(change.key).begins_with(prefix):continue
        var key=String(change.key).trim_prefix(prefix)
        if not Delta.valid_key(key):continue
        cache[area][key]=change.after
        applied.append({"key":key,"value":Delta.decode(change.after)})
    changed.emit(area,applied)
