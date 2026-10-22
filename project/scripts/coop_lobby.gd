extends Node
## The JOIN GAME list. On the local network a browsing player asks everyone and
## every host answers directly. Over embedded ZeroTier (which cannot broadcast)
## hosts announce to the lobby directory and browsers read the list from it.
## Either way only the list travels here; play is always player to player.
const Network=preload("res://scripts/coop_network.gd")
const Session=preload("res://scripts/coop_session.gd")
const QUERY:="pw-query"
const LOBBY:="pw-lobby"
const VERSION:=1
const QUERY_INTERVAL_MS:=2000
const EXPIRE_MS:=7000
const MAX_LOBBIES:=64
const ANNOUNCE_INTERVAL_MS:=30000
const LIST_INTERVAL_MS:=5000
## Per request. A phone network's first lookup and TLS handshake can take seconds.
const REQUEST_TIMEOUT:=10.0
## A list request lost on the phone bridge is given up after this.
const NATIVE_LIST_MS:=15000
## Failed tries in a row before the list says it is unavailable; until then it
## says it is still trying, and each try comes sooner (1, 2, 4, then 8 s).
const FAILURES_SHOWN:=3
const LOADING:="LOADING THE LIST..."
const RETRYING:="STILL TRYING TO LOAD THE LIST..."
## Asks the directory to list dedicated servers too (older builds do not).
const SERVERS:="?servers=1"
var describe:Callable
var browsing:=false
## Shown in JOIN GAME while the lobby directory has not answered or cannot be reached.
var list_error:=""
## Failed list requests in a row. The last good list stays shown meanwhile.
var _failures:=0
var _found:Dictionary={}
var _next_query:=0
var _key:=""
var _next_announce:=0
var _announced_players:=-1
var _directory_at:=0
var _announcer:HTTPRequest
var _lister:HTTPRequest
var _remover:HTTPRequest
var _native_list:=0
var _native_announce:=0
var _native_since:=0
var _native_list_since:=0

func _ready()->void:
    process_mode=Node.PROCESS_MODE_ALWAYS
    _announcer=_requester();_lister=_requester();_remover=_requester()
    _lister.request_completed.connect(_listed)

func _headers(url:String,json:bool)->PackedStringArray:
    var headers:=PackedStringArray()
    if json:headers.append("Content-Type: application/json")
    var key:=Network.lobby_key(url)
    if not key.is_empty():headers.append("X-Lobby-Key: "+key)
    return headers

func _requester()->HTTPRequest:
    var request:=HTTPRequest.new();request.timeout=REQUEST_TIMEOUT;request.process_mode=Node.PROCESS_MODE_ALWAYS
    add_child(request);return request

func _endpoint()->String:
    var base:=Network.directory_url()
    return "" if base.is_empty() else base+"/v1/lobbies"

func _idle(request:HTTPRequest)->bool:
    return request.get_http_client_status()==HTTPClient.STATUS_DISCONNECTED

## The callable returns the current lobby record each time someone asks.
func advertise(describer:Callable)->void:
    describe=describer
    if Network.uses_directory():
        _key=preload("res://scripts/coop_random.gd").hex(16);_next_announce=0;_announced_players=-1
    else:Network.beacon_open()

func stop_advertise()->void:
    describe=Callable()
    if not _key.is_empty() and not _endpoint().is_empty():
        # Best effort; a lobby that stops announcing drops off the list anyway.
        var goodbye:=JSON.stringify({"key":_key,"remove":true})
        if Network.embedded():Network.http_start(_endpoint(),goodbye)
        else:
            _announcer.cancel_request()
            _remover.request(_endpoint(),_headers(_endpoint(),true),HTTPClient.METHOD_POST,goodbye)
    _key=""
    _release()

func browse(enabled:bool)->void:
    if browsing==enabled:return
    browsing=enabled;_found.clear();_next_query=0;_failures=0
    list_error=LOADING if enabled and Network.uses_directory() else ""
    if Network.uses_directory():
        if not enabled:_lister.cancel_request()
    elif enabled:Network.beacon_open()
    else:_release()

func _release()->void:
    if not browsing and not describe.is_valid():Network.beacon_close()

static func proof(salt:String,password:String)->String:
    return (salt+"|"+password).sha256_text()

## Newest answers first by name; each entry carries the host's address.
func entries()->Array[Dictionary]:
    var result:Array[Dictionary]=[]
    for value in _found.values():result.append(value)
    result.sort_custom(func(a,b):return String(a.name).naturalnocasecmp_to(String(b.name))<0 if a.name!=b.name else String(a.address)<String(b.address))
    return result

func _process(_delta:float)->void:
    if not browsing and not describe.is_valid():return
    var now:=Time.get_ticks_msec()
    if Network.uses_directory():
        # Announcing and listing work on timers of seconds; asking four times a
        # second is plenty, and every frame cost the host nearly a millisecond.
        if now-_directory_at<250:return
        _directory_at=now
        _directory(now);return
    for packet in Network.beacon_poll():
        var text:=String(packet.data)
        if text.length()>1024:continue
        var decoded=JSON.parse_string(text)
        if not decoded is Dictionary or int(decoded.get("v",0))!=VERSION:continue
        if decoded.get("t")==QUERY and describe.is_valid():
            var record:Dictionary=describe.call()
            if record.is_empty():continue
            record["t"]=LOBBY;record["v"]=VERSION
            Network.beacon_send(JSON.stringify(record),String(packet.from),int(packet.port))
        elif decoded.get("t")==LOBBY and browsing:
            # The host address is the datagram's source, never a payload field.
            var address:=String(packet.from)
            if not _found.has(address) and _found.size()>=MAX_LOBBIES:continue
            _found[address]=_clean(address,decoded,now)
    if not browsing:return
    for address in _found.keys():
        if now-int(_found[address].seen)>EXPIRE_MS:_found.erase(address)
    if now>=_next_query:
        _next_query=now+QUERY_INTERVAL_MS
        Network.beacon_send(JSON.stringify({"t":QUERY,"v":VERSION}))

func _exit_tree()->void:
    describe=Callable();browsing=false
    Network.beacon_close()

func _directory(now:int)->void:
    var url:=_endpoint()
    if url.is_empty():list_error="NO LOBBY LIST IS SET UP IN THIS BUILD.";return
    if Network.embedded():
        _directory_native(now,url);return
    if describe.is_valid() and _idle(_announcer):
        var record:Dictionary=describe.call()
        var online:Dictionary=Network.status()
        # Announce at once when the player count changes so the list stays true.
        if not record.is_empty() and online.state=="ready" and (now>=_next_announce or int(record.get("players",1))!=_announced_players):
            record["key"]=_key;record["address"]=String(online.address)
            _next_announce=now+ANNOUNCE_INTERVAL_MS;_announced_players=int(record.get("players",1))
            _announcer.request(url,_headers(url,true),HTTPClient.METHOD_POST,JSON.stringify(record))
    if browsing and now>=_next_query and _idle(_lister):
        _next_query=now+LIST_INTERVAL_MS
        if _lister.request(url+SERVERS,_headers(url,false))!=OK:_listed(HTTPRequest.RESULT_CANT_CONNECT,0,PackedStringArray(),PackedByteArray())

## Same schedule as above, through the Android bridge instead of HTTPRequest.
func _directory_native(now:int,url:String)->void:
    if _native_announce>0 and (not Network.http_take(_native_announce).is_empty() or now-_native_since>12000):_native_announce=0
    if describe.is_valid() and _native_announce==0:
        var record:Dictionary=describe.call()
        var online:Dictionary=Network.status()
        if not record.is_empty() and online.state=="ready" and (now>=_next_announce or int(record.get("players",1))!=_announced_players):
            record["key"]=_key;record["address"]=String(online.address)
            _next_announce=now+ANNOUNCE_INTERVAL_MS;_announced_players=int(record.get("players",1))
            _native_announce=Network.http_start(url,JSON.stringify(record));_native_since=now
    if _native_list>0:
        var answer:Dictionary=Network.http_take(_native_list)
        if answer.is_empty() and now-_native_list_since>NATIVE_LIST_MS:answer={"code":0,"body":""} # its answer was lost
        if not answer.is_empty():
            _native_list=0
            _listed(HTTPRequest.RESULT_SUCCESS if int(answer.code)>0 else HTTPRequest.RESULT_CANT_CONNECT,int(answer.code),PackedStringArray(),String(answer.body).to_utf8_buffer())
    if browsing and now>=_next_query and _native_list==0:
        _next_query=now+LIST_INTERVAL_MS
        _native_list=Network.http_start(url+SERVERS);_native_list_since=now

func _listed(result:int,code:int,_headers:PackedStringArray,body:PackedByteArray)->void:
    if not browsing:return
    # The list refused this build's password, or it was built without one.
    if code==401:list_error="THIS BUILD HAS NO ONLINE LOBBY LIST.";return
    var decoded=JSON.parse_string(body.get_string_from_utf8()) if result==HTTPRequest.RESULT_SUCCESS and code==200 else null
    if not decoded is Dictionary or not decoded.get("lobbies") is Array:
        # Try again soon, keeping what was listed: one lost request on a phone
        # network is common and says little.
        _failures+=1
        _next_query=Time.get_ticks_msec()+(1000<<mini(_failures-1,3))
        list_error="LOBBY LIST UNAVAILABLE. CHECK YOUR INTERNET." if _failures>=FAILURES_SHOWN else RETRYING
        return
    list_error="";_failures=0;_found.clear()
    var own:=String(Network.status().address) if Network.embedded() else "" # LAN test copies share an address.
    for entry in decoded.lobbies:
        if not entry is Dictionary or _found.size()>=MAX_LOBBIES:continue
        var address:=String(entry.get("address","")).left(45)
        if address.is_empty() or address==own:continue
        _found[String(entry.get("id",address))]=_clean(address,entry,Time.get_ticks_msec())

static func _clean(address:String,source:Dictionary,now:int)->Dictionary:
    return {"address":address,"seen":now,
        "name":String(source.get("name","WORLD")).strip_edges().left(24),
        "host":String(source.get("host","PLAYER")).strip_edges().left(24),
        "private":bool(source.get("private",false)),
        "players":clampi(int(source.get("players",1)),0,Session.MAX_PLAYERS),
        "max":clampi(int(source.get("max",4)),1,Session.MAX_PLAYERS),
        # "game": a player hosting; "server": a dedicated server, joined directly
        # (coop_game.gd join_listed_server). Version and compat id as the host's
        # build sees them (coop_session.gd), "" when unknown.
        "kind":"server" if source.get("kind")=="server" else "game",
        "version":String(source.get("version","")).left(24),
        "compat":String(source.get("compat","")).left(64),
        "salt":String(source.get("salt","")).left(64),
        "protocol":String(source.get("protocol","")).left(48),
        "mods":String(source.get("mods","")).left(64),
        "port":clampi(int(source.get("port",Network.GAME_PORT)),1,65535),
        "accounts":bool(source.get("accounts",false))}
