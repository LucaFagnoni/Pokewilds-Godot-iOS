extends RefCounted
## The iPhone's ZeroTier bridge: the same calls and answers as the Android
## bridge (PokeWildsZeroTier.java), served by the iOS plugin
## ios/plugins/pokewilds_zerotier. GDScript cannot call native code there, so
## each call is a request on a loopback connection the plugin announces in
## POKEWILDS_ZEROTIER ("<port> <token>"); see pokewilds_zerotier.mm.
## Each call waits for its answer, which takes well under a millisecond.
const TIMEOUT_MS:=2000
var _peer:StreamPeerTCP

func start(storage:String,game_port:int)->String:return _call(["start",storage,str(game_port)])
func status()->String:return _call(["status"])
func hostOpen(zt_port:int,local_port:int)->bool:return _call(["hostOpen",str(zt_port),str(local_port)])=="1"
func hostClose()->void:_call(["hostClose"])
func connectOpen(address:String,port:int)->int:return int(_call(["connectOpen",address,str(port)]))
func connectClose()->void:_call(["connectClose"])
func setLobbyKey(key:String)->void:_call(["setLobbyKey",key])
func httpStart(url:String,body:String)->int:return int(_call(["httpStart",url,body]))
func httpTake(id:int)->String:return _call(["httpTake",str(id)])

## The answer, or "" when the plugin did not answer in time.
func _call(fields:Array)->String:
    var announced:=OS.get_environment("POKEWILDS_ZEROTIER").split(" ")
    if announced.size()!=2:return ""
    if _peer!=null:_peer.poll()
    if _peer==null or _peer.get_status()!=StreamPeerTCP.STATUS_CONNECTED:
        # First call, or iOS took the connection while the app slept: the
        # plugin may then announce a new port.
        _peer=StreamPeerTCP.new()
        if _peer.connect_to_host("127.0.0.1",int(announced[0]))!=OK or not _wait(func():return _peer.get_status()!=StreamPeerTCP.STATUS_CONNECTING) or _peer.get_status()!=StreamPeerTCP.STATUS_CONNECTED:
            _peer=null;return ""
        _peer.set_no_delay(true)
    _peer.put_utf8_string("\t".join(PackedStringArray([announced[1]]+fields)))
    if not _wait(func():return _peer.get_available_bytes()>=4):_peer=null;return ""
    var size:=_peer.get_u32()
    if not _wait(func():return _peer.get_available_bytes()>=size):_peer=null;return ""
    var answer:Array=_peer.get_data(size)
    return (answer[1] as PackedByteArray).get_string_from_utf8() if answer[0]==OK else ""

func _wait(done:Callable)->bool:
    var began:=Time.get_ticks_usec()
    while true:
        _peer.poll()
        if done.call():return true
        var waited:=Time.get_ticks_usec()-began
        if waited>TIMEOUT_MS*1000 or _peer.get_status()==StreamPeerTCP.STATUS_ERROR:return false
        # The answer usually comes within microseconds: only sleep after a millisecond.
        if waited>1000:OS.delay_usec(100)
    return false
