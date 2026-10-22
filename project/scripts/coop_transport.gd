extends Node
## Host-routed, bounded TCP transport. Gameplay belongs to the session adapter.
signal connected(peer: int)
signal disconnected(peer: int)
signal received(peer: int, message: Dictionary)
signal failed(reason: String)
const JoinCode = preload("res://scripts/coop_join_code.gd")
## Positions travel as bytes, everything else as JSON.
const Remote = preload("res://scripts/coop_remote_player.gd")
const MAX_FRAME := 256 * 1024
const MAX_QUEUE := 4 * 1024 * 1024
const FRAME_BUDGET := 64 * 1024
const TIMEOUT_MS := 20000
const LOADING_TIMEOUT_MS := 120000
## How long a joining player waits for the host's first word. Two devices that
## have not spoken since their games were opened need time to find a path to
## each other: it has taken 24 seconds, and the join gave up at 20.
const FIRST_CONTACT_MS := 60000
var server := TCPServer.new()
var peers: Dictionary = {}
var hosting := false
var joining := false
var port := JoinCode.PORT
## Connections at once, joining ones included. The host sets it from
## coop_game.gd max_players: one fewer for a hosting player, who is already in.
var max_peers := 3
const FULL := "This game is full."
var _turned_away: Array = []
var _next_peer := 2
var last_disconnect_reason := ""

func host(listen_port: int = JoinCode.PORT, address: String = "*") -> Error:
    stop()
    var error := server.listen(listen_port, address)
    if error != OK: return error
    port = listen_port
    hosting = true
    set_process(true)
    return OK

func join_code(code: String) -> Error:
    var address := JoinCode.decode(code)
    if address.is_empty(): return ERR_INVALID_PARAMETER
    return join_address(address, JoinCode.PORT)

func join_address(address: String, remote_port: int) -> Error:
    stop()
    var socket := StreamPeerTCP.new()
    var error := socket.connect_to_host(address, remote_port)
    if error != OK: return error
    joining = true
    _add(1, socket)
    set_process(true)
    return OK

func _add(peer: int, socket: StreamPeerTCP) -> void:
    socket.set_no_delay(true)
    peers[peer] = {"socket": socket, "rx": PackedByteArray(), "tx": [],
        "offset": 0, "queued": 0, "ready": false,
        "seen": Time.get_ticks_msec(), "ping": Time.get_ticks_msec(), "heard": false,
        "local_loading_until": 0, "remote_loading_until": 0}

func set_loading(peer:int, loading:bool, remote:bool=false)->void:
    if not peers.has(peer):return
    peers[peer]["remote_loading_until" if remote else "local_loading_until"] = Time.get_ticks_msec()+LOADING_TIMEOUT_MS if loading else 0

func receive_expired(state:Dictionary, now:int)->bool:
    var limit:=FIRST_CONTACT_MS if joining and not state.get("heard",false) else TIMEOUT_MS
    return now-int(state.seen)>limit and now>int(state.get("local_loading_until",0)) and now>int(state.get("remote_loading_until",0))

## Traffic counters for benchmarks: null unless a test sets a Dictionary.
## key -> [messages, bytes, microseconds spent encoding or decoding].
static var stats=null

static func count(key:String,bytes:int,started_usec:int)->void:
    if stats==null:return
    var entry:Array=stats.get(key,[0,0,0])
    entry[0]+=1;entry[1]+=bytes;entry[2]+=Time.get_ticks_usec()-started_usec
    stats[key]=entry

func send(peer: int, message: Dictionary) -> Error:
    var started:=Time.get_ticks_usec()
    var bytes:=Remote.pack(message) if message.get("kind")=="player_visual" else PackedByteArray()
    if bytes.is_empty():bytes=JSON.stringify(message).to_utf8_buffer()
    count("enc:"+String(message.get("kind","")),bytes.size(),started)
    return send_encoded(peer,bytes)

func send_encoded(peer:int, bytes:PackedByteArray)->Error:
    if not peers.has(peer): return ERR_DOES_NOT_EXIST
    if bytes.is_empty() or bytes.size() > MAX_FRAME: return ERR_INVALID_DATA
    var state: Dictionary = peers[peer]
    if int(state.queued) + bytes.size() + 4 > MAX_QUEUE: return ERR_BUSY
    var frame := PackedByteArray()
    frame.resize(4)
    frame.encode_u32(0, bytes.size())
    frame.append_array(bytes)
    state.tx.append(frame)
    state.queued += frame.size()
    # Anything sent keeps the connection alive; keepalives fill silences only.
    state.ping = Time.get_ticks_msec()
    return OK

func _process(_delta:float)->void:
    if hosting and server.is_connection_available():
        var socket := server.take_connection()
        if peers.size() >= max_peers:
            # Said, not just closed: "could not reach the host" sends players to check their Wi-Fi.
            var reply := JSON.stringify({"kind": "rejected", "reason": FULL}).to_utf8_buffer()
            var frame := PackedByteArray()
            frame.resize(4)
            frame.encode_u32(0, reply.size())
            frame.append_array(reply)
            socket.put_data(frame)
            # Closed a moment later: closing now could drop the reply unread.
            _turned_away.append([socket, Time.get_ticks_msec() + 2000])
        else:
            var id := _next_peer
            _next_peer += 1
            _add(id, socket)
    # Real time, independent of gameplay/battle speed and menu pauses.
    var now := Time.get_ticks_msec()
    while not _turned_away.is_empty() and now >= int(_turned_away[0][1]):
        _turned_away.pop_front()[0].disconnect_from_host()
    for peer in peers.keys():
        if not peers.has(peer): continue
        var state: Dictionary = peers[peer]
        var socket: StreamPeerTCP = state.socket
        socket.poll()
        var status := socket.get_status()
        if status in [StreamPeerTCP.STATUS_ERROR, StreamPeerTCP.STATUS_NONE]:
            _drop(peer,"socket_closed")
            continue
        if status != StreamPeerTCP.STATUS_CONNECTED:
            if now - int(state.seen) > TIMEOUT_MS:_drop(peer,"connect_timeout")
            continue
        if not state.ready:
            state.ready = true
            connected.emit(peer)
            if not peers.has(peer): continue
        if now - int(state.ping) >= 4000:
            send(peer, {"kind":"keepalive"})
            state.ping = now
        var available := mini(socket.get_available_bytes(), FRAME_BUDGET)
        if available > 0:
            var data := socket.get_data(available)
            if data[0] != OK:
                _drop(peer,"socket_read_failed")
                continue
            state.rx.append_array(data[1])
            state.seen = now
            state.heard = true
        # Check the socket before timing out: world loading may have delayed this
        # process call while keepalives were already waiting in the receive buffer.
        if receive_expired(state,now):
            _drop(peer,"receive_timeout")
            continue
        var read_count := 0
        while peers.has(peer) and state.rx.size() >= 4 and read_count < 32:
            var length := int(state.rx.decode_u32(0))
            if length <= 0 or length > MAX_FRAME:
                _drop(peer,"invalid_frame_size_"+str(length))
                break
            if state.rx.size() < length + 4: break
            var started := Time.get_ticks_usec()
            var frame: PackedByteArray = state.rx.slice(4, length + 4)
            var decoded = Remote.unpack(frame) if frame[0] == Remote.WIRE_TAG else JSON.parse_string(frame.get_string_from_utf8())
            state.rx = state.rx.slice(length + 4)
            read_count += 1
            if not decoded is Dictionary:
                _drop(peer,"invalid_frame_json")
                break
            if stats != null: count("rx:"+str(decoded.get("kind","")), length + 4, started)
            if str(decoded.get("kind", "")) != "keepalive": received.emit(peer, decoded)
        if not peers.has(peer): continue
        _write(peer, FRAME_BUDGET)

func _write(peer: int, budget: int) -> void:
    var state: Dictionary = peers[peer]
    var socket: StreamPeerTCP = state.socket
    while not state.tx.is_empty() and budget > 0:
        var frame: PackedByteArray = state.tx[0]
        var offset := int(state.offset)
        var sent := socket.put_partial_data(frame.slice(offset, mini(frame.size(), offset + budget)))
        if sent[0] != OK:
            _drop(peer,"socket_write_failed")
            break
        var count := int(sent[1])
        if count <= 0: break
        budget -= count
        state.offset += count
        state.queued -= count
        if int(state.offset) == frame.size():
            state.tx.pop_front()
            state.offset = 0

## Hands everything queued to the sockets now: the app is about to be
## suspended and _process will not run again until it comes back.
func flush() -> void:
    for peer in peers.keys():
        if peers.has(peer) and peers[peer].ready: _write(peer, MAX_QUEUE)

func _drop(peer: int, reason: String = "session_closed") -> void:
    if not peers.has(peer): return
    if reason!="status":print("ONLINE transport closed peer=",peer," reason=",reason) # MY SERVERS asks every few seconds
    last_disconnect_reason=reason
    peers[peer].socket.disconnect_from_host()
    peers.erase(peer)
    disconnected.emit(peer)
    if joining:
        joining = false
        failed.emit("Connection to the host closed.")

func stop() -> void:
    server.stop()
    for state in peers.values(): state.socket.disconnect_from_host()
    for pair in _turned_away: pair[0].disconnect_from_host()
    _turned_away.clear()
    peers.clear()
    hosting = false
    joining = false
    _next_peer = 2
    set_process(false)

func _exit_tree() -> void:
    stop()
