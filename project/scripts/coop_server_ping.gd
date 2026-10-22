extends RefCounted
## One status check of a server for MY SERVERS: connect to its game port, send {"kind":"status"}
## with this copy's protocol, mods and build, and read the one reply. The host answers before any
## hello and closes (coop_session.gd), saying whether it would let this player in. Call poll()
## every frame until it returns true; nothing blocks, host names are resolved in the background.
## result: {"state":"ok","ms","version","build","compatible"} or {"state":"old|unknown|busy|offline"}
## (old = a host from before status requests: it refuses with "Join handshake required.";
## busy = it closed without a word, as a full host does).
const Session=preload("res://scripts/coop_session.gd")
const TIMEOUT_MS:=2500
const MAX_REPLY:=1024
var result:Dictionary={}
var _request:PackedByteArray
var _socket:StreamPeerTCP
var _resolve:=-1
var _port:=0
var _started:=0
var _sent:=0
var _rx:=PackedByteArray()

func _init(address:String,port:int,mods:String)->void:
    _port=port;_started=Time.get_ticks_msec()
    _request=JSON.stringify({"kind":"status","protocol":Session.PROTOCOL,"mods":mods,"build":Session.build_id()}).to_utf8_buffer()
    if address.is_valid_ip_address():_connect(address)
    else:_resolve=IP.resolve_hostname_queue_item(address)

func _notification(what:int)->void:
    if what==NOTIFICATION_PREDELETE and _resolve>=0:IP.erase_resolve_item(_resolve)

func _connect(ip:String)->void:
    _socket=StreamPeerTCP.new()
    if ip.is_empty() or _socket.connect_to_host(ip,_port)!=OK:result={"state":"offline"}

## True once `result` is set. Late polls still read a reply that came in time.
func poll()->bool:
    if result.is_empty():_step()
    if result.is_empty() and Time.get_ticks_msec()-_started>TIMEOUT_MS:result={"state":"offline"};_socket=null
    return not result.is_empty()

func _step()->void:
    if _resolve>=0:
        var resolving:=IP.get_resolve_item_status(_resolve)
        if resolving==IP.RESOLVER_STATUS_WAITING:return
        var ip:=IP.get_resolve_item_address(_resolve) if resolving==IP.RESOLVER_STATUS_DONE else ""
        IP.erase_resolve_item(_resolve);_resolve=-1
        _connect(ip)
    if _socket==null or not result.is_empty():return
    _socket.poll()
    var status:=_socket.get_status()
    if status==StreamPeerTCP.STATUS_CONNECTING:return
    if status!=StreamPeerTCP.STATUS_CONNECTED:result={"state":"offline" if _sent==0 else "busy"};return
    if _sent==0:
        var frame:=PackedByteArray();frame.resize(4);frame.encode_u32(0,_request.size());frame.append_array(_request)
        _socket.put_data(frame);_sent=Time.get_ticks_msec()
    var wanted:=mini(_socket.get_available_bytes(),MAX_REPLY+4-_rx.size())
    if wanted>0:
        var data:=_socket.get_data(wanted)
        if data[0]==OK:_rx.append_array(data[1])
    if _rx.size()<4:return
    var length:=int(_rx.decode_u32(0))
    if length<=0 or length>MAX_REPLY:result={"state":"unknown"}
    elif _rx.size()>=length+4:result=read(JSON.parse_string(_rx.slice(4,length+4).get_string_from_utf8()),Time.get_ticks_msec()-_sent)
    if not result.is_empty():_socket.disconnect_from_host()

## What a host's reply says, every field bounded.
static func read(reply:Variant,ms:int)->Dictionary:
    if not reply is Dictionary:return {"state":"unknown"}
    if reply.get("kind")=="rejected":return {"state":"old"}
    if reply.get("kind")!="status":return {"state":"unknown"}
    return {"state":"ok","ms":ms,"version":String(reply.get("version","")).left(16),"build":String(reply.get("build","")).left(40),
        "compatible":reply.get("compatible")==true}
