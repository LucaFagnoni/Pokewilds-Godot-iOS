extends RefCounted
## Ordered, bounded delivery for large storage/party records over the small TCP frames.
signal delivery_failed(peer:int)
const Blob=preload("res://scripts/coop_blob.gd")
const Transport=preload("res://scripts/coop_transport.gd")
const MAX_MESSAGE:=8*1024*1024
const MAX_QUEUED:=16*1024*1024
const DIRECT_LIMIT:=192*1024
var blobs=Blob.new()
var queues:Dictionary={}
var queued_bytes:=0
## Players who have said they are loading. While a player generates a new
## area their game reads almost nothing for minutes, and the updates for them
## pile up here. At the usual limit of 128 waiting messages the host dropped
## them just as a large world finished generating. They are given far more
## room; the limit on total bytes still applies. true while loading, false
## once it is over and the pile is being worked off.
const PATIENT_QUEUE:=8192
var patient:Dictionary={}
var send_frame:Callable
var send_encoded:Callable

func _send_bytes(peer:int,bytes:PackedByteArray,payload:Dictionary)->Error:
    return send_encoded.call(peer,bytes) if send_encoded.is_valid() else send_frame.call(peer,payload)

func send(peer:int,payload:Dictionary)->Error:
    # Positions and the world clock are replaceable observations, not transactions.
    # Do not put them behind a multi-megabyte snapshot or retain stale positions.
    if payload.get("kind") in ["player_visual","world_clock"]:
        var error:Error=send_frame.call(peer,payload)
        return OK if error==ERR_BUSY else error
    var started:=Time.get_ticks_usec()
    var bytes=JSON.stringify(payload).to_utf8_buffer()
    Transport.count("enc:"+String(payload.get("kind","")),bytes.size(),started)
    return send_bytes(peer,bytes,payload)

## A message already encoded (JSON text), in order with the others: the same
## bytes can go to several players without encoding them for each.
func send_bytes(peer:int,bytes:PackedByteArray,payload:Dictionary={})->Error:
    if bytes.is_empty() or bytes.size()>MAX_MESSAGE:return ERR_INVALID_DATA
    if bytes.size()<=DIRECT_LIMIT and not blobs.outgoing.has(peer) and queues.get(peer,[]).is_empty():
        var error:Error=_send_bytes(peer,bytes,payload)
        if error!=ERR_BUSY:return error
        # A full socket queue is temporary. Retain this transaction and everything
        # following it in order instead of relying on every caller to retry.
    var waiting:int=queues.get(peer,[]).size()
    if patient.has(peer) and not patient[peer] and waiting<64:patient.erase(peer)
    if queued_bytes+bytes.size()>MAX_QUEUED or waiting>=(PATIENT_QUEUE if patient.has(peer) else 128):return ERR_BUSY
    if not queues.has(peer):queues[peer]=[]
    queues[peer].append({"bytes":bytes,"payload":payload.duplicate(true) if bytes.size()<=DIRECT_LIMIT and not send_encoded.is_valid() else {}})
    queued_bytes+=bytes.size()
    return OK

func pump()->void:
    blobs.expire()
    for peer in queues.keys():
        if blobs.outgoing.has(peer):
            var error:Error=blobs.pump(peer,_fragment)
            if error not in [OK,ERR_BUSY]:
                drop(peer);delivery_failed.emit(peer)
            continue
        var queue:Array=queues[peer]
        if queue.is_empty():queues.erase(peer);continue
        var entry:Dictionary=queue[0]
        var error:Error
        if entry.bytes.size()<=DIRECT_LIMIT:error=_send_bytes(peer,entry.bytes,entry.payload)
        else:error=OK if blobs.start_send(peer,preload("res://scripts/coop_random.gd").hex(16),entry.bytes) else ERR_BUSY
        if error==OK:queued_bytes-=entry.bytes.size();queue.pop_front()
        elif error!=ERR_BUSY:
            drop(peer);delivery_failed.emit(peer)

func _fragment(peer:int,packet:Dictionary)->Error:
    var outgoing=packet.duplicate();outgoing.kind="session_blob"
    return send_frame.call(peer,outgoing)

func receive(peer:int,packet:Dictionary)->Dictionary:
    var length=packet.get("length",null)
    var raw=packet.get("raw",0)
    if typeof(raw) not in [TYPE_INT,TYPE_FLOAT] or not is_finite(float(raw)) or raw<0 or raw>MAX_MESSAGE:
        blobs.drop(peer)
        return {"error":"message_too_large"}
    if typeof(length) not in [TYPE_INT,TYPE_FLOAT] or not is_finite(float(length)) or float(length)!=floor(float(length)) or length<=0 or length>MAX_MESSAGE:
        blobs.drop(peer)
        return {"error":"message_too_large"}
    var part=packet.duplicate();part.kind="blob"
    var result:Dictionary=blobs.receive(peer,part)
    if result.has("error"):return result
    if not result.has("bytes"):return {}
    var parser=JSON.new()
    var started:=Time.get_ticks_usec()
    if parser.parse(result.bytes.get_string_from_utf8())!=OK or not parser.data is Dictionary:return {"error":"invalid_message"}
    Transport.count("rx_blob:"+String(parser.data.get("kind","")),result.bytes.size(),started)
    if parser.data.get("kind")=="session_blob":return {"error":"nested_message"}
    return {"packet":parser.data}

func drop(peer:int)->void:
    for entry in queues.get(peer,[]):queued_bytes-=entry.bytes.size()
    queues.erase(peer);blobs.drop(peer);patient.erase(peer)

func clear()->void:
    for peer in queues.keys():drop(peer)
    for peer in blobs.incoming.keys():blobs.drop(peer)
