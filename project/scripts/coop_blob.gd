extends RefCounted
## Flow-controlled snapshot chunks, with an overall memory limit and digest.
## The bytes travel compressed (zstd) when that is smaller: a world's records
## are text that shrinks about 14 times, an area about 3 times. "raw" is then
## the size they unpack to; the digest is always of the unpacked bytes.
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
    # Packed and hashed on a worker: an area or a world's records are
    # megabytes, which took the host tens of ms. pump() waits for it.
    var done:Array=[]
    var task:=WorkerThreadPool.add_task(func():
        var packed:=bytes.compress(FileAccess.COMPRESSION_ZSTD)
        var raw:=bytes.size() if not packed.is_empty() and packed.size()<bytes.size() else 0
        done.append_array([packed if raw>0 else bytes,raw,digest(bytes) if trusted_digest.is_empty() else trusted_digest]))
    outgoing[peer]={"id":id,"bytes":bytes,"raw":0,"offset":0,"hash":"","task":task,"done":done}
    return true

func pump(peer: int, send: Callable) -> Error:
    if not outgoing.has(peer):return OK
    var transfer: Dictionary=outgoing[peer]
    if transfer.has("task"):
        if not WorkerThreadPool.is_task_completed(transfer.task):return ERR_BUSY
        _packed(transfer)
    var offset:=int(transfer.offset)
    var data:PackedByteArray=transfer.bytes.slice(offset,mini(offset+CHUNK_BYTES,transfer.bytes.size()))
    var packet:Dictionary={"kind":"blob","id":transfer.id,"offset":offset,
        "length":transfer.bytes.size(),"sha256":transfer.hash,"data":Marshalls.raw_to_base64(data)}
    if int(transfer.raw)>0:packet["raw"]=transfer.raw
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
    var raw:=int(packet.get("raw",0)) if typeof(packet.get("raw",0)) in [TYPE_INT,TYPE_FLOAT] else -1
    if id.is_empty() or id.length()>64 or length<=0 or length>MAX_BYTES or encoded.length()>CHUNK_BYTES*2 or raw<0 or raw>MAX_BYTES:
        incoming.erase(peer);return {"error":"invalid_snapshot"}
    var bytes:=Marshalls.base64_to_raw(encoded)
    if bytes.is_empty() or bytes.size()>CHUNK_BYTES or offset<0 or offset+bytes.size()>length:
        incoming.erase(peer);return {"error":"invalid_snapshot"}
    if not incoming.has(peer):
        if offset!=0:return {"error":"missing_snapshot_start"}
        var reserved:=length
        for transfer in incoming.values():reserved+=int(transfer.length)
        if reserved>MAX_BYTES:return {"error":"snapshot_memory_limit"}
        incoming[peer]={"id":id,"length":length,"raw":raw,"hash":String(packet.get("sha256","")),
            "bytes":PackedByteArray(),"seen":Time.get_ticks_msec()}
    var transfer:Dictionary=incoming[peer]
    if transfer.id!=id or int(transfer.length)!=length or int(transfer.raw)!=raw or transfer.hash!=packet.get("sha256","") or transfer.bytes.size()!=offset:
        incoming.erase(peer);return {"error":"out_of_order_snapshot"}
    transfer.bytes.append_array(bytes)
    transfer.seen=Time.get_ticks_msec()
    if transfer.bytes.size()!=length:return {}
    incoming.erase(peer)
    if raw>0:
        transfer.bytes=transfer.bytes.decompress(raw,FileAccess.COMPRESSION_ZSTD)
        if transfer.bytes.size()!=raw:return {"error":"snapshot_unpack"}
    if not defer_digest and digest(transfer.bytes)!=transfer.hash:return {"error":"snapshot_digest"}
    return {"id":id,"bytes":transfer.bytes,"sha256":transfer.hash}

func expire() -> void:
    for peer in incoming.keys():
        if Time.get_ticks_msec()-int(incoming[peer].seen)>TIMEOUT_MS:incoming.erase(peer)

func drop(peer: int) -> void:
    if outgoing.has(peer) and outgoing[peer].has("task"):_packed(outgoing[peer])
    incoming.erase(peer);outgoing.erase(peer)

## A transfer's packing done on the worker, taken over.
static func _packed(transfer: Dictionary) -> void:
    WorkerThreadPool.wait_for_task_completion(transfer.task)
    transfer.bytes=transfer.done[0];transfer.raw=transfer.done[1];transfer.hash=transfer.done[2]
    transfer.erase("task");transfer.erase("done")
