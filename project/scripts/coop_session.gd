extends Node
## Connection admission and routing; world operations are handled by the adapter.
signal admitted(peer: int, actor: String, profile: Dictionary)
signal departed(peer: int, actor: String)
signal session_ready(world_id: String, actor: String)
signal message(peer: int, actor: String, payload: Dictionary)
signal rejected(reason: String)
signal connection_lost
const Transport = preload("res://scripts/coop_transport.gd")
## coop-9b: record fingerprints hash encoded text directly (coop_state.gd
## fingerprint). coop-10: the netcode rewrite. The field moves are commands
## the host decides (rules/, coop_rules_runtime.gd; no patches or rewards
## claimed by a player), an area's built and dug ground and the wild Pokemon's
## motion travel as binary frames (area_state.gd WIRE_TAG), a player record is
## saved by parts with their revisions (coop_state.gd PARTS). coop-10b:
## building, paint and taking built pieces away are rule commands as well
## (rules/build.gd, paint.gd, remove.gd: {"area", "cmd"}, no patches or record
## fingerprint), several of a player's in flight at once.
const PROTOCOL := "pokewilds-godot-coop-10b"
## Most players one game can have, a phone host included (a dedicated server's
## own player does not count). The host relays every position update to each
## other player in the same area, so its upload grows with the square of the
## players. Measured (a walking player's update packs to ~320 bytes, sent 20
## times a second): all 8 moving in one area is 1120 relays a second, ~350 KB/s
## (2.8 Mbit/s) up and ~4% of a desktop core, against ~76 KB/s at 4; Wi-Fi and
## 4G uploads manage it. 16 would be ~1.5 MB/s, more than many home lines can
## send, so a dedicated server has the same limit.
## The lobby directory (lobby-directory/src/directory.js) uses the same number.
const MAX_PLAYERS := 8
var transport: Node
var hosting := false
var world_id := ""
var identity := ""
var actor := ""
var mod_digest := ""
var profile: Dictionary = {}
var players: Dictionary = {}
var trusted := false
var loading := false
## Host: proof guests must present for a PRIVATE lobby. Guest: proof to send.
var access_proof := ""
## Host: the salt of that proof. Guest: a password typed for a direct join,
## turned into the proof once the host's challenge brings the salt.
var access_salt := ""
var access_password := ""
## Host: the one-time value each joining connection was challenged with. The
## proof comes back hashed with it, so one overheard on the way cannot be
## replayed. The bare proof of older builds is still accepted.
var _nonces: Dictionary = {}
## Host: player accounts (coop_accounts.gd) on a dedicated server, or null when
## players are known by the identity their device made. Guest: the ID and
## password to log in with ("" = no account), and what the challenge said.
var accounts = null
var has_character := Callable()
var account_id := ""
var account_password := ""
var _account_salts: Dictionary = {}
var _account_challenge: Dictionary = {}
const Accounts = preload("res://scripts/coop_accounts.gd")
## The commit an official build was made from: CI writes build_id.txt before
## exporting. Builds from different commits can share the protocol and still
## disagree on the world (a world from one, tiles drawn by the other), so a
## host refuses another build unless both carry the same compat_id(). Editor
## and local builds have none and skip it.
static var _build := ""
static var _compat := ""

static func build_id() -> String:
    if not OS.get_environment("POKEWILDS_BUILD_ID").is_empty(): return OS.get_environment("POKEWILDS_BUILD_ID") # tests
    if _build.is_empty() and FileAccess.file_exists("res://build_id.txt"):
        _build = FileAccess.get_file_as_string("res://build_id.txt").strip_edges().left(40)
    return _build

## What two builds must share to play together: CI writes compat_id.txt, a hash
## of the project without the client-only files of tools/client_only_paths.txt
## (tools/compat_id.py), so a build that only changed, say, the HUD still plays
## with the server of an older one. Without the file, the build id.
static func compat_id() -> String:
    if not OS.get_environment("POKEWILDS_COMPAT_ID").is_empty(): return OS.get_environment("POKEWILDS_COMPAT_ID") # tests
    if _compat.is_empty() and FileAccess.file_exists("res://compat_id.txt"):
        _compat = FileAccess.get_file_as_string("res://compat_id.txt").strip_edges().left(40)
    return build_id() if _compat.is_empty() else _compat

## The version players see (build_version.txt, also written by CI), "" in local builds.
static func build_version() -> String:
    if not OS.get_environment("POKEWILDS_BUILD_VERSION").is_empty(): return OS.get_environment("POKEWILDS_BUILD_VERSION") # tests
    return FileAccess.get_file_as_string("res://build_version.txt").strip_edges().left(16) if FileAccess.file_exists("res://build_version.txt") else ""

## Why this host refuses a player whose hello (or status request) names this
## protocol, mods and build; "" when it would let them in. MY SERVERS shows the
## same answer before joining (coop_server_ping.gd). Compat ids decide when both
## sides send one; a player from before them (no "compat") needs the same build.
func refusal(payload: Dictionary) -> String:
    if str(payload.get("protocol",""))!=PROTOCOL:return "Game versions do not match." # str: any JSON value compares
    if str(payload.get("mods",""))!=mod_digest:return "Enabled mods and their order must match the host."
    var build:=str(payload.get("build",""))
    var compat:=str(payload.get("compat",""))
    var differs:=compat!=compat_id() if not compat.is_empty() and not compat_id().is_empty() \
        else not build.is_empty() and not build_id().is_empty() and build!=build_id()
    if differs:
        var theirs:=str(payload.get("version","")).left(16)
        return "Different game version: host %s, yours %s." % [build_version() if not build_version().is_empty() else build_id().left(8),
            theirs if not theirs.is_empty() else build.left(8)]
    return ""
## Host only: true for a player this world's host has banned. A player is the
## identity their copy of the game made on first run, not a name or appearance.
var blocked := Callable()
const KICKED := "The host removed you from this game."
const BANNED := "The host banned you from this world."

## Tells a connected player why, then closes their connection.
func kick(peer: int, reason: String = KICKED) -> void:
    if hosting and peer != 1 and players.has(peer): _reject(peer, reason)
var _reject_pending: Dictionary = {}
var messages=preload("res://scripts/coop_messages.gd").new()

func _ready() -> void:
    process_mode = Node.PROCESS_MODE_ALWAYS
    transport = Transport.new()
    transport.process_mode = Node.PROCESS_MODE_ALWAYS
    transport.set_process(false)
    set_process(false)
    add_child(transport)
    messages.send_frame=transport.send
    messages.send_encoded=transport.send_encoded
    messages.delivery_failed.connect(func(peer):transport._drop(peer,"reliable_delivery_failed"))
    transport.connected.connect(_connected)
    transport.disconnected.connect(_disconnected)
    transport.received.connect(_received)
    transport.failed.connect(func(reason):rejected.emit(reason))

func configure(token: String, mods: String, player_profile: Dictionary) -> bool:
    if token.length()!=64 or not token.is_valid_hex_number():return false
    identity=token;actor=token.sha256_text();mod_digest=mods
    profile=player_profile.duplicate(true)
    return true

func host(id: String, port: int = 54555, address: String = "*") -> Error:
    if identity.is_empty() or id.is_empty():return ERR_UNCONFIGURED
    var error: Error=transport.host(port,address)
    if error!=OK:return error
    hosting=true;world_id=id;trusted=true;set_process(true)
    players={1:{"actor":actor,"profile":profile.duplicate(true)}}
    session_ready.emit(world_id,actor)
    return OK

func join_code(code: String) -> Error:
    hosting=false;trusted=false;players.clear()
    if identity.is_empty():return ERR_UNCONFIGURED
    var error:Error=transport.join_code(code)
    set_process(error==OK)
    return error

func join_address(address: String, port: int) -> Error:
    hosting=false;trusted=false;players.clear()
    if identity.is_empty():return ERR_UNCONFIGURED
    var error:Error=transport.join_address(address,port)
    set_process(error==OK)
    return error

func _connected(peer: int) -> void:
    if hosting:return
    _hello(peer,"")

## A ban has to outlive an uninstall, which makes a new identity. The device
## keeps an id for this game that only a factory reset changes; the host is
## sent a one-way scramble of it mixed with the world's id, so the raw id never
## leaves the device and no two worlds see the same value.
const NO_DEVICE := "0000000000000000000000000000000000000000000000000000000000000000"

static func device_print(world: String) -> String:
    var device := OS.get_unique_id()
    return NO_DEVICE if device.is_empty() or world.is_empty() else (device + "|pokewilds-ban|" + world).sha256_text()

## The host answers the first hello with the world's id; the second carries
## the device print for that world.
func _hello(peer: int, world: String, nonce: String = "") -> void:
    var access := access_proof if nonce.is_empty() or access_proof.is_empty() else (nonce+"|"+access_proof).sha256_text()
    # A typed address may cross the internet: its proof only ever travels hashed.
    if world.is_empty() and not access_password.is_empty():access = ""
    var hello := {"kind":"hello","protocol":PROTOCOL,"mods":mod_digest,
        "identity":identity,"profile":profile,"access":access,"build":build_id(),"compat":compat_id(),"version":build_version()}
    if not account_id.is_empty():
        hello["account"] = account_id
        if not world.is_empty() and _account_challenge.get("salt") is String:
            var account_verifier := Accounts.verifier(String(_account_challenge.salt), account_id, account_password)
            hello["account_proof"] = (nonce + "|" + account_verifier).sha256_text()
            if bool(_account_challenge.get("new", false)): hello["account_verifier"] = account_verifier
    if not world.is_empty(): hello["device"] = device_print(world)
    transport.send(peer, hello)

func _reject(peer: int, reason: String) -> void:
    transport.send(peer,{"kind":"rejected","reason":reason})
    _reject_pending[peer]=Time.get_ticks_msec()+1000

func _process(_delta:float)->void:
    # One pump per 60th of a second, so a 30 FPS cap keeps the same throughput.
    for _step in range(maxi(1, roundi(_delta * 60.0))): messages.pump()
    for peer in _reject_pending.keys():
        if Time.get_ticks_msec()>=int(_reject_pending[peer]):
            transport._drop(peer)
            _reject_pending.erase(peer)

func _received(peer: int, payload: Dictionary) -> void:
    var kind:=str(payload.get("kind",""))
    if kind=="loading" and payload.get("active") is bool:
        if (hosting and players.has(peer)) or (not hosting and trusted):
            transport.set_loading(peer,payload.active,true)
            if payload.active:messages.patient[peer]=true
            elif messages.patient.has(peer):messages.patient[peer]=false
        return
    if kind=="session_blob":
        if (hosting and not players.has(peer)) or (not hosting and not trusted):transport._drop(peer,"fragment_before_handshake");return
        var assembled:Dictionary=messages.receive(peer,payload)
        if assembled.has("error"):transport._drop(peer,"fragment_"+String(assembled.error));return
        if assembled.has("packet"):_received(peer,assembled.packet)
        return
    if hosting:
        if _reject_pending.has(peer):return
        if not players.has(peer):
            # A status request comes before any hello: the version and whether this
            # player would be let in, then the connection closes. Nothing about accounts.
            if kind=="status":
                transport.send(peer,{"kind":"status","protocol":PROTOCOL,"version":build_version(),"build":build_id(),"compatible":refusal(payload).is_empty()})
                transport._write(peer,Transport.MAX_QUEUE);transport._drop(peer,"status");return
            if kind!="hello":_reject(peer,"Join handshake required.");return
            var refused:=refusal(payload)
            if not refused.is_empty():_reject(peer,refused);return
            var token:=String(payload.get("identity",""))
            if token.length()!=64 or not token.is_valid_hex_number():_reject(peer,"Invalid player identity.");return
            var id:=token.sha256_text()
            var account:=String(payload.get("account","")).strip_edges().to_lower()
            if accounts!=null:
                if account.is_empty():_reject(peer,"This server needs a player ID and password.");return
                if not Accounts.valid_id(account):_reject(peer,"Invalid player ID.");return
                if not accounts.exists(account) and not accounts.open:_reject(peer,"Unknown player ID.");return
            else:
                for player in players.values():
                    if player.actor==id:_reject(peer,"This player is already connected.");return
            var device:=String(payload.get("device",""))
            # The salt rides on the challenge so a player who typed the address
            # (and so never saw the lobby entry) can still prove the password.
            if device.length()!=64 or not device.is_valid_hex_number():
                _nonces[peer]=preload("res://scripts/coop_random.gd").hex(16)
                var challenge:={"kind":"challenge","world":world_id,"salt":access_salt,"nonce":_nonces[peer]}
                if accounts!=null:
                    var known:bool=accounts.exists(account)
                    if not known:_account_salts[peer]=preload("res://scripts/coop_random.gd").hex(16)
                    challenge["account_salt"]=accounts.salt(account) if known else _account_salts[peer]
                    challenge["account_new"]=not known
                transport.send(peer,challenge);return
            var access:=String(payload.get("access",""))
            if not access_proof.is_empty() and access!=access_proof and access!=(String(_nonces.get(peer,""))+"|"+access_proof).sha256_text():_reject(peer,"Wrong password.");return
            if accounts!=null:
                id=_log_in(peer,account,payload,id)
                if id.is_empty():return
                for player in players.values():
                    if player.actor==id:_reject(peer,"This player is already connected.");return
            _nonces.erase(peer);_account_salts.erase(peer)
            if blocked.is_valid() and blocked.call(id,device):_reject(peer,BANNED);return
            var details=payload.get("profile",{})
            if not details is Dictionary:_reject(peer,"Invalid player profile.");return
            var clean:Dictionary={"name":String(details.get("name","PLAYER")).strip_edges().substr(0,24),
                "model":int(details.get("model",0)),"color":int(details.get("color",0))}
            players[peer]={"actor":id,"profile":clean,"device":device,"account":account if accounts!=null else ""}
            transport.send(peer,{"kind":"welcome","world":world_id,"actor":id,"peer":peer,"protocol":PROTOCOL})
            admitted.emit(peer,id,clean)
            return
        if kind in ["hello","welcome","rejected","challenge"]:return
        # Sender identity always comes from the accepted socket, never a payload field.
        message.emit(peer,String(players[peer].actor),payload)
    else:
        if kind=="rejected":
            rejected.emit(String(payload.get("reason","Join refused.")))
            transport.stop();trusted=false
            return
        if kind=="challenge" and not trusted:
            _account_challenge={"salt":payload.get("account_salt"),"new":payload.get("account_new",false)}
            if not access_password.is_empty() and payload.get("salt") is String:
                access_proof=preload("res://scripts/coop_lobby.gd").proof(String(payload.salt),access_password)
            if payload.get("world") is String and String(payload.world).length()<=64:_hello(peer,String(payload.world),String(payload.get("nonce","")).left(64))
            return
        if kind=="welcome" and not trusted:
            # Logged in with an ID, this player plays the ID's character, not the device's.
            var assigned:=String(payload.get("actor",""))
            if not account_id.is_empty() and assigned.length()==64 and assigned.is_valid_hex_number():actor=assigned
            if payload.get("protocol")!=PROTOCOL or payload.get("actor")!=actor:
                transport.stop();rejected.emit("Invalid host handshake.");return
            world_id=String(payload.get("world",""));trusted=true
            session_ready.emit(world_id,actor)
            return
        if trusted:message.emit(1,"host",payload)

## Host with accounts: the actor an ID plays, after checking the proof of its
## password, or creating the ID on its first login. "" after refusing.
func _log_in(peer: int, account: String, payload: Dictionary, device_actor: String) -> String:
    var nonce := String(_nonces.get(peer, ""))
    var proof := String(payload.get("account_proof", ""))
    if accounts.exists(account):
        if not accounts.check(account, nonce, proof): _reject(peer, "Wrong player ID or password."); return ""
        return accounts.actor(account)
    var account_verifier := String(payload.get("account_verifier", ""))
    if not accounts.open or not _account_salts.has(peer) or account_verifier.length() != 64 or not account_verifier.is_valid_hex_number() \
            or nonce.is_empty() or proof != (nonce + "|" + account_verifier).sha256_text():
        _reject(peer, "Wrong player ID or password."); return ""
    var value: String = accounts.register(account, String(_account_salts[peer]), account_verifier, device_actor, has_character)
    if value.is_empty(): _reject(peer, "The server could not save the new player ID."); return ""
    print("SERVER new player ID: ", account)
    return value

func send_host(payload: Dictionary) -> Error:
    if hosting or not trusted:return ERR_UNAVAILABLE
    return _send_reliable(1,payload)

## send_host for a message already encoded (a binary frame), in order with the rest.
func send_host_bytes(bytes: PackedByteArray) -> Error:
    if hosting or not trusted:return ERR_UNAVAILABLE
    var error:Error=messages.send_bytes(1,bytes)
    if error!=OK:transport._drop(1,"message_send_"+error_string(error))
    return error

func set_loading(value:bool)->void:
    if loading==value:return
    loading=value
    for peer in transport.peers:
        transport.set_loading(peer,value)
        # Announce before expensive area work, without waiting behind snapshots.
        transport.send(peer,{"kind":"loading","active":value})

func send_to(peer: int, payload: Dictionary) -> Error:
    if not hosting or not players.has(peer) or peer==1:return ERR_UNAVAILABLE
    return _send_reliable(peer,payload)

## send_to for a message already encoded (coop_messages.gd send_bytes).
func send_bytes_to(peer: int, bytes: PackedByteArray) -> Error:
    if not hosting or not players.has(peer) or peer==1:return ERR_UNAVAILABLE
    var error:Error=messages.send_bytes(peer,bytes)
    if error!=OK:transport._drop(peer,"message_send_"+error_string(error))
    return error

func _send_reliable(peer:int,payload:Dictionary)->Error:
    var error:Error=messages.send(peer,payload)
    # Once the bounded reliable queue cannot accept an update, continuing would
    # leave the peer playing a different world. End its connection; its durable
    # profile and world remain available when it rejoins.
    if error!=OK:transport._drop(peer,"message_send_"+error_string(error))
    return error


func _disconnected(peer: int) -> void:
    messages.drop(peer)
    _nonces.erase(peer);_account_salts.erase(peer)
    if not hosting:
        trusted=false
        connection_lost.emit()
    if players.has(peer):
        var id:=String(players[peer].actor)
        players.erase(peer)
        departed.emit(peer,id)

func stop() -> void:
    set_process(false);transport.stop();messages.clear();players.clear();_reject_pending.clear();trusted=false;hosting=false;loading=false;access_proof="";access_salt="";access_password="";_nonces.clear();_account_salts.clear();_account_challenge={}
