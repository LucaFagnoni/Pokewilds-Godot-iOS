extends RefCounted
## Flow-controlled snapshot chunks, with an overall memory limit and digest.
const CHUNK_BYTES := 24 * 1024
const MAX_BYTES := 128 * 1024 * 1024
const TIMEOUT_MS := 60000
var outgoing: Dictionary = {}
var incoming: Dictionary = {}

static func digest(bytes: PackedByteArray) -> String:
    var context := HashingContext.new()
    context.start(HashingContext.HASH_SHA256)
    context.update(bytes)
    return context.finish().hex_encode()

func start_send(peer: int, id: String, bytes: PackedByteArray, trusted_digest: String = "") -> bool:
    if outgoing.has(peer) or id.is_empty() or id.length()>64 or bytes.is_empty() or bytes.size()>MAX_BYTES:return false
    var reserved:=bytes.size()
    for transfer in outgoing.values():reserved+=transfer.bytes.size()
    if reserved>MAX_BYTES:return false
    if not trusted_digest.is_empty() and (trusted_digest.length()!=64 or not trusted_digest.is_valid_hex_number()):return false
    outgoing[peer]={"id":id,"bytes":bytes,"offset":0,"hash":digest(bytes) if trusted_digest.is_empty() else trusted_digest}
    return true

func pump(peer: int, send: Callable) -> Error:
    if not outgoing.has(peer):return OK
    var transfer: Dictionary=outgoing[peer]
    var offset:=int(transfer.offset)
    var data:PackedByteArray=transfer.bytes.slice(offset,mini(offset+CHUNK_BYTES,transfer.bytes.size()))
    var packet:Dictionary={"kind":"blob","id":transfer.id,"offset":offset,
        "length":transfer.bytes.size(),"sha256":transfer.hash,"data":Marshalls.raw_to_base64(data)}
    var error:Error=send.call(peer,packet)
    if error!=OK:return error
    transfer.offset+=data.size()
    if int(transfer.offset)==transfer.bytes.size():outgoing.erase(peer)
    return OK

func receive(peer: int, packet: Dictionary, defer_digest: bool = false) -> Dictionary:
    var id:=String(packet.get("id",""))
    var offset:=int(packet.get("offset",-1))
    var length:=int(packet.get("length",-1))
    var encoded:=String(packet.get("data",""))
    if id.is_empty() or id.length()>64 or length<=0 or length>MAX_BYTES or encoded.length()>CHUNK_BYTES*2:
        incoming.erase(peer);return {"error":"invalid_snapshot"}
    var bytes:=Marshalls.base64_to_raw(encoded)
    if bytes.is_empty() or bytes.size()>CHUNK_BYTES or offset<0 or offset+bytes.size()>length:
        incoming.erase(peer);return {"error":"invalid_snapshot"}
    if not incoming.has(peer):
        if offset!=0:return {"error":"missing_snapshot_start"}
        var reserved:=length
        for transfer in incoming.values():reserved+=int(transfer.length)
        if reserved>MAX_BYTES:return {"error":"snapshot_memory_limit"}
        incoming[peer]={"id":id,"length":length,"hash":String(packet.get("sha256","")),
            "bytes":PackedByteArray(),"seen":Time.get_ticks_msec()}
    var transfer:Dictionary=incoming[peer]
    if transfer.id!=id or int(transfer.length)!=length or transfer.hash!=packet.get("sha256","") or transfer.bytes.size()!=offset:
        incoming.erase(peer);return {"error":"out_of_order_snapshot"}
    transfer.bytes.append_array(bytes)
    transfer.seen=Time.get_ticks_msec()
    if transfer.bytes.size()!=length:return {}
    incoming.erase(peer)
    if not defer_digest and digest(transfer.bytes)!=transfer.hash:return {"error":"snapshot_digest"}
    return {"id":id,"bytes":transfer.bytes,"sha256":transfer.hash}

func expire() -> void:
    for peer in incoming.keys():
        if Time.get_ticks_msec()-int(incoming[peer].seen)>TIMEOUT_MS:incoming.erase(peer)

func drop(peer: int) -> void:
    incoming.erase(peer);outgoing.erase(peer)
