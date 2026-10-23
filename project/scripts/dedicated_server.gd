extends Node
## Dedicated co-op server: `PokeWilds.console.exe --headless --server [--port N]
## [--world NAME] [--size S|M|L|XL|XXL] [--accounts open|closed|off] [--password P]
## [--data DIR]`. Players log in with an ID and a password (coop_accounts.gd):
## "open" makes an ID on its first login, "closed" only lets in IDs made here
## with `account add`, "off" goes back to device identities and the optional
## shared --password.
## The server is the ordinary online host (see coop_game.gd) whose own player
## never shows: it stands still at the spawn, sends no presence, is not counted
## in the lobby, cannot be met or chased, and never plays. Everything else
## (areas, journal, saves) is the host code players already use, so a phone
## hosting keeps working as before. New areas are made here, not on phones
## (server_area_maker.gd), and the router port is opened by UPnP when it can be.
## Settings come from server.cfg beside the exe (or --config PATH), then the
## command line. Without --server this node does nothing.
## `--join HOST[:PORT] [--id ID] [--password P] [--data DIR] [--quit-after-join]
## [--travel]` instead joins a game at startup, for PCs and for the smoke test.
const Paths=preload("res://scripts/game_data_paths.gd")
const Identity=preload("res://scripts/coop_identity.gd")
const JoinCode=preload("res://scripts/coop_join_code.gd")
const AreaMaker=preload("res://scripts/server_area_maker.gd")
const SIZES:=["S","M","L","XL","XXL"]
const COMMANDS:="stop [SECONDS], restart [SECONDS], cancel, save, players, maxplayers N, list on|off, address, kick NAME, ban NAME, bans, unban NAME, accounts, account add|password|remove ID [PASSWORD]"
const Accounts=preload("res://scripts/coop_accounts.gd")
const Session=preload("res://scripts/coop_session.gd")
const Network=preload("res://scripts/coop_network.gd")
## `restart` ends the process with this code; start_server.bat (server_launcher.ps1)
## then starts it again.
const RESTART_EXIT:=75
## What players still connected are told as the server goes (the title screen shows it).
const RESTARTING:="Server restarting. Try again in a moment."
const STOPPED:="The server was shut down."
## `stop` and `restart` without seconds warn the players for this long first.
const COUNTDOWN_SECONDS:=30
var config_path:=""
static var active:=false
var joining:=""
var _quit_after_join:=false
var _travel:=false
var _area_job:=""
var port:=JoinCode.PORT
var world_name:="PokeWilds"
var size:=1
var password:=""
var accounts_mode:="open"
var account_id:=""
var max_players:=4
var autosave_minutes:=5.0
var open_router_port:=true
## A wild battle's win or catch is taken only when the server's replay of it
## ends the same way (coop_wild_runtime.gd check_battle).
var enforce_battles:=true
## Who runs the wild and habitat Pokemon and eggs of the areas players are in:
## "server" (this server, every area: coop_population_authority.gd) or
## "players" (the first player in each area, as when a phone hosts).
var population_authority:="server"
var main:Node
var maker:Node
var _saving:=false
var _quitting:=false
var _next_save:=0

func _init()->void:
    var args:=OS.get_cmdline_args()+OS.get_cmdline_user_args()
    active="--server" in args
    joining="" if active else _arg(args,"--join","")
    _quit_after_join="--quit-after-join" in args
    _travel="--travel" in args
    _area_job="" if active else _arg(args,"--generate-area","")
    if not _area_job.is_empty():_use_data(_area_job.get_base_dir());return
    if not active and joining.is_empty():return
    var base:=OS.get_executable_path().get_base_dir() if not OS.has_feature("editor") else ProjectSettings.globalize_path("user://")
    var data:=_arg(args,"--data",base.path_join("server_data") if active else "")
    if data.is_relative_path():data=base.path_join(data)
    password=_arg(args,"--password","").strip_edges().left(32)
    account_id=_arg(args,"--id","").strip_edges()
    if not active:
        if not data.is_empty():_use_data(data)
        return
    var config:=ConfigFile.new()
    config_path=_arg(args,"--config",base.path_join("server.cfg"))
    if config.load(config_path)==OK:print("SERVER config ",config_path)
    port=int(_arg(args,"--port",str(config.get_value("server","port",port))))
    world_name=_arg(args,"--world",String(config.get_value("server","world",world_name))).strip_edges().left(24)
    var size_text:=_arg(args,"--size",str(config.get_value("server","size",SIZES[size]))).to_upper()
    size=SIZES.find(size_text) if size_text in SIZES else clampi(int(size_text),0,SIZES.size()-1)
    if password.is_empty():password=String(config.get_value("server","password","")).strip_edges().left(16)
    accounts_mode=_arg(args,"--accounts",String(config.get_value("server","accounts",accounts_mode))).strip_edges().to_lower()
    if not accounts_mode in ["open","closed","off"]:accounts_mode="open"
    max_players=clampi(int(config.get_value("server","max_players",max_players)),1,Session.MAX_PLAYERS)
    listed=bool(config.get_value("server","listed",false))
    autosave_minutes=maxf(1.0,float(config.get_value("server","autosave_minutes",autosave_minutes)))
    open_router_port=bool(config.get_value("server","open_router_port",true)) and not "--no-upnp" in args
    enforce_battles=bool(config.get_value("server","enforce_battles",enforce_battles))
    population_authority=_arg(args,"--population-authority",String(config.get_value("server","population_authority",population_authority))).strip_edges().to_lower()
    if not population_authority in ["server","players"]:population_authority="server"
    maker=AreaMaker.new()
    var area_size:=_arg(args,"--area-size","").to_upper()
    if area_size in SIZES:maker.area_size=SIZES.find(area_size)
    # New areas made in this process on a worker (server_area_maker.gd): "auto"
    # (with the native generator), "on" (with either generator) or "off".
    var generation:=_arg(args,"--area-generation",String(config.get_value("server","area_generation","auto"))).strip_edges().to_lower()
    maker.in_process=generation if generation in ["auto","on","off"] else "auto"
    # Everything the server writes (identity, world, area caches) lives here.
    _use_data(data)

## The folder is new, not a phone's external storage: nothing to migrate.
static func _use_data(folder:String)->void:
    DirAccess.make_dir_recursive_absolute(folder)
    Paths.directory=folder
    if not FileAccess.file_exists(Paths.path(".private-saves-migrated")):
        var marker:=FileAccess.open(Paths.path(".private-saves-migrated"),FileAccess.WRITE)
        if marker!=null:marker.store_string("Dedicated server data.\n")

static func _arg(args:PackedStringArray,name:String,fallback:String)->String:
    for i in range(args.size()-1):
        if args[i]==name:return args[i+1]
    for value in args:
        if value.begins_with(name+"="):return value.trim_prefix(name+"=")
    return fallback

func _ready()->void:
    if not active and joining.is_empty() and _area_job.is_empty():queue_free();return
    process_mode=Node.PROCESS_MODE_ALWAYS
    if active:
        get_tree().auto_accept_quit=false
        add_child(maker)
        # The exact build, and the compat id that decides who may join (coop_session.gd refusal).
        var build:String=preload("res://scripts/coop_session.gd").build_id()
        var compat:String=preload("res://scripts/coop_session.gd").compat_id()
        print("SERVER PokeWilds dedicated server",(" build "+build.left(8)) if not build.is_empty() else "",(" compat "+compat.left(8)) if compat!=build else "",", data in ",ProjectSettings.globalize_path(Paths.root_path()))
    while not (get_tree().current_scene!=null and get_tree().current_scene.get("startup_complete")):
        await get_tree().process_frame
    main=get_tree().current_scene
    if not _area_job.is_empty():
        var area_maker:=AreaMaker.new();add_child(area_maker);area_maker.generate(main,_area_job);return
    if not active:_join();return
    var coop:Node=main.coop_game
    coop.host_port=port;coop.max_players=max_players
    coop.wild.enforce_battles=enforce_battles
    coop.server_population=population_authority=="server"
    if accounts_mode!="off":
        # Before the world starts: no one may get in without an ID meanwhile.
        coop.session.accounts=Accounts.new()
        if coop.session.accounts.load_file(Paths.path("accounts.json"))!=OK:_fail("accounts.json is damaged");return
        coop.session.accounts.open=accounts_mode=="open"
        if not password.is_empty():print("SERVER note: with player IDs the shared password is not used (use accounts=closed to choose who plays)")
    else:coop.lobby_private=not password.is_empty();coop.lobby_password=password
    main.world_edit.text=world_name;main.selected_world_size=size
    main.player_model_name.text="SERVER"
    var token:=Identity.token()
    if token.is_empty():_fail("player identity could not load");return
    var saved:=""
    for entry in coop.saves.entries(token.sha256_text()):
        if String(entry.data.get("world_name",""))==world_name:saved=String(entry.id);break
    print("SERVER ",("loading world \"%s\" (%s)"%[world_name,saved]) if not saved.is_empty() else ("creating world \"%s\" size %s"%[world_name,SIZES[size]]))
    await coop.choose("LOAD" if not saved.is_empty() else "NEW",saved)
    if not main.started or not coop.active:_fail(String(main.menu_status.text));return
    # The server's own player never plays: nothing may start a battle for it,
    # and with gameplay off the area is simulated the way it is for a host
    # who has a menu open.
    for pair in [["encounter_requested","_on_encounter_requested"],["battle_requested","_on_battle_requested"]]:
        if main.world.has_signal(pair[0]) and main.world.is_connected(pair[0],Callable(main,pair[1])):main.world.disconnect(pair[0],Callable(main,pair[1]))
    main.world.set_gameplay_enabled(false)
    coop.commands.presence.erase(coop.session.actor)
    coop.generate_area=func(actor,area,area_token):return await maker.make(main,actor,area,area_token)
    coop.session.admitted.connect(func(peer,_actor,profile):print("SERVER join: ",profile.get("name","PLAYER"),_account(peer)," from ",_address(peer)," (",coop.session.players.size()-1,"/",max_players,")"))
    coop.session.departed.connect(func(_peer,_actor):print("SERVER leave (",coop.session.players.size()-1,"/",max_players,")"))
    print("SERVER world ready, listening on TCP port ",port,(" with a password" if coop.lobby_private else ""),
        {"open":", player IDs: a new ID is made on its first login","closed":", player IDs: only those made with `account add`","off":""}[accounts_mode])
    print("SERVER commands: ",COMMANDS)
    _list_request=HTTPRequest.new();_list_request.timeout=main.coop_game.lobby.REQUEST_TIMEOUT;add_child(_list_request)
    _list_request.request_completed.connect(_list_reply)
    print("SERVER online games list: ",_list_state())
    _next_save=Time.get_ticks_msec()+int(autosave_minutes*60000)
    _stdin=Thread.new();_stdin.start(_read_stdin)
    show_addresses()

# --- Reaching the server from outside -----------------------------------------
## Opens the port on the router (UPnP), finds the address players outside use
## and says plainly when a line cannot be reached from outside at all (CGNAT).
## UPNP is created by name: the iOS engine is built without that module, and
## this script is loaded there too.
var _upnp:Object
const UPNP_OK:=0
var _router_thread:Thread
var _lease_renew_at:=0
var _ip_request:HTTPRequest
const LEASE_SECONDS:=24*3600

func show_addresses()->void:
    if _router_thread!=null:return
    _router_thread=Thread.new()
    _router_thread.start(_router_work)
    while _router_thread.is_alive():await get_tree().process_frame
    var router:Dictionary=_router_thread.wait_to_finish();_router_thread=null
    var outside:=String(router.get("external",""))
    if outside.is_empty() or not outside.is_valid_ip_address():outside=await _public_address()
    var lan:=JoinCode.local_endpoints()
    var line:="SERVER ------------------------------------------------------------"
    print(line)
    for endpoint in lan:
        # Tailscale (and other carrier-grade ranges) are a VPN here, not the Wi-Fi.
        var label:="Tailscale/VPN:  " if address_kind(endpoint.address)=="cgnat" else "Same Wi-Fi:     "
        print("SERVER  ",label,endpoint.address,":",port,_code(JoinCode.encode(endpoint.address)))
    var kind:=address_kind(outside)
    _outside=outside if kind.is_empty() else ""
    if outside.is_empty():
        print("SERVER  From outside:   could not find this line's public address (no internet?)")
    elif kind=="private":
        print("SERVER  From outside:   not yet: this router is behind another router (its internet")
        print("SERVER    address is ",outside,"). Open TCP port ",port," on the first router too, towards")
        print("SERVER    this router, or set the first one to bridge mode (README_SERVER.md).")
    elif kind=="cgnat":
        print("SERVER  From outside:   NOT POSSIBLE on this internet line.")
        print("SERVER    The provider shares one public address among many homes (CGNAT,")
        print("SERVER    router address ",outside,"), so nobody outside can reach this PC.")
        print("SERVER    Ask the provider for a public IPv4 address, or use Tailscale on this")
        print("SERVER    PC and on the phones (see README_SERVER.md).")
        for address in IP.get_local_addresses():
            if ":" in address and (address.begins_with("2") or address.begins_with("3")):
                print("SERVER    Phones with IPv6 may still try [",address,"]:",port," if the router lets it in.");break
    else:
        print("SERVER  From outside:   ",outside,":",port,_code(JoinCode.encode_internet(outside)))
        if router.get("mapped",false):print("SERVER    Router port opened automatically (UPnP).")
        elif not open_router_port:print("SERVER    Automatic router setup is off: forward TCP port ",port," to this PC by hand.")
        else:
            print("SERVER    The router did not open the port by itself (UPnP off?). Turn UPnP on in the")
            print("SERVER    router, or forward TCP port ",port," to ",lan[0].address if not lan.is_empty() else "this PC"," by hand (README_SERVER.md).")
    print(line)

func _code(code:String)->String:
    return "   code "+code if port==JoinCode.PORT and not code.is_empty() else ""

## Router work blocks for seconds, so it runs on a thread.
func _router_work()->Dictionary:
    if _upnp==null:
        if not ClassDB.class_exists("UPNP"):return {}
        _upnp=ClassDB.instantiate("UPNP")
        if _upnp.discover(2000,2,"InternetGatewayDevice")!=UPNP_OK or _upnp.get_gateway()==null or not _upnp.get_gateway().is_valid_gateway():
            _upnp=null;return {}
    var result:={"external":_upnp.query_external_address()}
    if not open_router_port:return result
    # Some routers only take permanent mappings, others only ones that expire.
    if _upnp.add_port_mapping(port,port,"PokeWilds server","TCP",0)==UPNP_OK:
        _lease_renew_at=0;result["mapped"]=true
    elif _upnp.add_port_mapping(port,port,"PokeWilds server","TCP",LEASE_SECONDS)==UPNP_OK:
        _lease_renew_at=Time.get_ticks_msec()+LEASE_SECONDS*500;result["mapped"]=true
    return result

func _public_address()->String:
    if _ip_request==null:_ip_request=HTTPRequest.new();_ip_request.timeout=8.0;add_child(_ip_request)
    if _ip_request.request("https://api.ipify.org")!=OK:return ""
    var answer:Array=await _ip_request.request_completed
    var text:=PackedByteArray(answer[3]).get_string_from_utf8().strip_edges()
    return text if answer[0]==HTTPRequest.RESULT_SUCCESS and int(answer[1])==200 and text.is_valid_ip_address() else ""

## "private" for a home network address, "cgnat" for the range providers (and
## Tailscale) share, "" for an address the internet can reach.
static func address_kind(address:String)->String:
    var parts:=address.split(".")
    if parts.size()!=4:return ""
    var a:=int(parts[0]);var b:=int(parts[1])
    if a==100 and b>=64 and b<128:return "cgnat"
    return "private" if a==10 or a==127 or (a==172 and b>=16 and b<32) or (a==192 and b==168) or (a==169 and b==254) else ""

# --- Console ------------------------------------------------------------------
## Release builds stop at once on Ctrl+C or when their console closes, so the
## clean way out is a command, or start_server.bat: it owns the console, turns
## Ctrl+C into "stop 0", and closing it closes this pipe, which also means stop.
## It also starts the server again when it ends with RESTART_EXIT.
var _stdin:Thread

func _read_stdin()->void:
    while true:
        var line:=OS.read_string_from_stdin()
        if line.is_empty():
            if OS.get_stdin_type()==OS.STD_HANDLE_PIPE:_shutdown.call_deferred()
            return
        _command.call_deferred(line.strip_edges())

func _command(line:String)->void:
    var word:=line.get_slice(" ",0).to_lower()
    var rest:=line.substr(word.length()).strip_edges()
    var coop:Node=main.coop_game
    match word:
        "stop","quit","exit","restart":
            if not rest.is_empty() and (not rest.is_valid_int() or int(rest)<0 or int(rest)>3600):print("SERVER usage: ",word," [SECONDS, 0-3600]");return
            # Nobody to warn: at once.
            var seconds:=int(rest) if not rest.is_empty() else (COUNTDOWN_SECONDS if coop.session.players.size()>1 else 0)
            _countdown="restart" if word=="restart" else "stop";_countdown_left=seconds;_countdown_at=Time.get_ticks_msec()
        "cancel":
            if _countdown.is_empty():print("SERVER nothing to cancel");return
            _broadcast({"kind":"server_countdown","action":_countdown,"cancel":true})
            print("SERVER ",_countdown," cancelled");_countdown=""
        "maxplayers":
            if not rest.is_valid_int() or int(rest)<1 or int(rest)>Session.MAX_PLAYERS:print("SERVER usage: maxplayers 1-",Session.MAX_PLAYERS," (now ",max_players,")");return
            # Nobody is removed: only new players are turned away until there is room.
            max_players=int(rest);coop.max_players=max_players;coop.session.transport.max_peers=max_players
            print("SERVER max players ",max_players," (",coop.session.players.size()-1," playing)",_save_setting("max_players",max_players))
        "list","publish","unpublish":
            var value:=rest.to_lower()
            if word=="list" and not value in ["on","off"]:print("SERVER online games list: ",_list_state()," (list on|off)");return
            listed=word=="publish" or value=="on";_list_next=0
            if not listed:_unlist()
            print("SERVER online games list: ",_list_state(),_save_setting("listed",listed))
        "save":save()
        "address":show_addresses()
        "players":
            var listed:Array=coop.kick_candidates()
            print("SERVER ",listed.size(),"/",max_players," players")
            for player in listed:print("SERVER   ",player.order,"  ",player.name,_account(int(player.peer)),"  from ",_address(int(player.peer)))
        "accounts":
            if coop.session.accounts==null:print("SERVER player IDs are off (accounts=off)");return
            print("SERVER ",coop.session.accounts.records.size()," player IDs (",accounts_mode,")")
            for record in coop.session.accounts.records.values():print("SERVER   ",record.get("id",""),"  since ",String(record.get("created","")).left(10))
        "account":
            _account_command(rest)
        "kick","ban":
            var peer:=_player(rest)
            if peer<0:print("SERVER no player \"",rest,"\" (see: players)");return
            print("SERVER ",("banned " if word=="ban" else "kicked ") if coop.kick(peer,word=="ban") else "could not remove ",rest)
        "bans":
            for key in coop.record_keys("blocked/"):print("SERVER   banned: ",coop.state.records[key].get("name","PLAYER"))
        "unban":
            var changes:Array=[]
            for key in coop.state.records.keys():
                if (String(key).begins_with("blocked/") or String(key).begins_with("blocked_device/")) and String(coop.state.records[key].get("name","")).to_lower()==rest.to_lower():
                    changes.append(coop.state.change(key,null))
            if changes.is_empty():print("SERVER nobody called \"",rest,"\" is banned (see: bans)");return
            var result:Dictionary=coop.state.transact(coop.session.actor,"unblock/"+coop._id(),changes)
            print("SERVER unbanned ",rest if result.get("ok",false) else "failed: "+String(result.get("reason","")))
        "":pass
        _:print("SERVER unknown command \"",word,"\" (",COMMANDS,")")

## account add ID PASSWORD | account password ID PASSWORD | account remove ID
func _account_command(text:String)->void:
    var accounts=main.coop_game.session.accounts
    var parts:=text.split(" ",false)
    if accounts==null:print("SERVER player IDs are off (accounts=off)");return
    if parts.size()<2 or not parts[0].to_lower() in ["add","password","remove"]:print("SERVER usage: account add|password|remove ID [PASSWORD]");return
    var id:=parts[1].to_lower()
    if not Accounts.valid_id(id):print("SERVER an ID is 3-16 letters, digits, _ or -");return
    match parts[0].to_lower():
        "remove":print("SERVER removed ",id," (the character stays in the world)" if accounts.remove(id)==OK else "SERVER no ID "+id)
        _:
            if parts.size()<3 or parts[2].length()<4 or parts[2].length()>32:print("SERVER the password needs 4-32 characters");return
            if parts[0].to_lower()=="add" and accounts.exists(id):print("SERVER ",id," already exists (account password ",id," NEW to change it)");return
            if parts[0].to_lower()=="password" and not accounts.exists(id):print("SERVER no ID ",id);return
            print("SERVER ",id,(" can now log in" if parts[0].to_lower()=="add" else " has a new password") if accounts.set_password(id,parts[2])==OK else " could not be saved")

func _account(peer:int)->String:
    var account:=String(main.coop_game.session.players.get(peer,{}).get("account",""))
    return "" if account.is_empty() else " (ID "+account+")"

## A player by name or by their place in the `players` list (1ST, 2, ...).
func _player(text:String)->int:
    for player in main.coop_game.kick_candidates():
        if String(player.name)==text.to_upper() or String(player.order)==text.to_upper() or str(int(player.order.to_int()))==text:return int(player.peer)
    return -1

func _address(peer:int)->String:
    var peers:Dictionary=main.coop_game.session.transport.peers
    return String(peers[peer].socket.get_connected_host()) if peers.has(peer) else "?"

func _process(_delta:float)->void:
    if _next_save==0 or _quitting:return
    if not _countdown.is_empty() and Time.get_ticks_msec()>=_countdown_at:_count_down()
    if listed:_announce()
    # Keep the server's player out of play whatever re-enabled it.
    if main.world.gameplay_enabled:main.world.set_gameplay_enabled(false)
    if _lease_renew_at>0 and Time.get_ticks_msec()>=_lease_renew_at and _router_thread==null:
        _lease_renew_at=0;show_addresses()
    if Time.get_ticks_msec()<_next_save:return
    _next_save=Time.get_ticks_msec()+int(autosave_minutes*60000)
    save()

func save()->bool:
    if _saving or main==null or not main.coop_game.active:return false
    _saving=true
    var saved:bool=await main.coop_game.save_game(main._capture_game_save())
    _saving=false
    print("SERVER world saved" if saved else "SERVER ERROR: world save failed")
    # Each save of an area is a new 2.4 MB file; those nothing needs any more
    # went only when the world was next loaded (coop_snapshot_store.gd clean_up).
    if saved:main.coop_game._clean_up_area_files()
    return saved

func _notification(what:int)->void:
    if what==NOTIFICATION_WM_CLOSE_REQUEST and active:_shutdown()

func _shutdown(restart:=false)->void:
    if _quitting:return
    _quitting=true;_countdown=""
    print("SERVER restarting..." if restart else "SERVER stopping...")
    await _unlist()
    while _saving:await get_tree().process_frame
    if main!=null and main.coop_game.active:
        await save()
        # Everyone still playing is told why, rather than "host disconnected".
        var session:Node=main.coop_game.session
        for peer in session.players.keys():
            if peer!=1:session.kick(peer,RESTARTING if restart else STOPPED)
        var deadline:=Time.get_ticks_msec()+3000
        while not session._reject_pending.is_empty() and Time.get_ticks_msec()<deadline:await get_tree().process_frame
    while _router_thread!=null:await get_tree().process_frame
    # The port is closed again while the server is off.
    if _upnp!=null and open_router_port:_upnp.delete_port_mapping(port,"TCP")
    get_tree().quit(RESTART_EXIT if restart else 0)

# --- Restart and stop countdown -------------------------------------------------
## `restart N` / `stop N`: players see "Server restarting in N s" each second
## (coop_game.gd NOTICE_TEXT) until the server saves and goes; `cancel` stops it.
var _countdown:=""
var _countdown_left:=0
var _countdown_at:=0

func _count_down()->void:
    if _countdown_left<=0:_shutdown(_countdown=="restart");return
    _broadcast({"kind":"server_countdown","action":_countdown,"seconds":_countdown_left})
    if _countdown_left%10==0 or _countdown_left<=5:print("SERVER ","restarting" if _countdown=="restart" else "stopping"," in ",_countdown_left," s (cancel to stop it)")
    _countdown_left-=1;_countdown_at+=1000

func _broadcast(packet:Dictionary)->void:
    var session:Node=main.coop_game.session
    for peer in session.players:
        if peer!=1:session.send_to(peer,packet)

## Changes one [server] setting in server.cfg, keeping its comments; "" when
## saved, else why not, for the end of the command's answer.
func _save_setting(key:String,value:Variant)->String:
    var text:=FileAccess.get_file_as_string(config_path) if FileAccess.file_exists(config_path) else ""
    var line:=key+"="+var_to_str(value)
    var found:=RegEx.create_from_string("(?m)^[ \\t]*"+key+"[ \\t]*=[^\\r\\n]*").search(text)
    if found!=null:text=text.substr(0,found.get_start())+line+text.substr(found.get_end())
    elif "[server]" in text:text=text.replace("[server]","[server]\n"+line)
    else:text+="[server]\n"+line+"\n"
    var file:=FileAccess.open(config_path,FileAccess.WRITE)
    if file==null:return ", not saved: cannot write "+config_path
    file.store_string(text)
    return ", saved in "+config_path.get_file()

# --- The online games list ------------------------------------------------------
## With listed=true (server.cfg, or `list on`) the server is in the phones' JOIN
## GAME list, as a phone hosting is: it tells the lobby directory
## (lobby-directory/) about itself now and then, and leaves on `list off` and
## when it stops. Phones then connect straight to its outside address, so the
## port must be reachable from outside (see show_addresses).
const LIST_MS:=30000
const LIST_RETRY_MS:=5000
var listed:=false
var _outside:=""
var _list_request:HTTPRequest
var _list_key:=""
var _list_next:=0
var _list_sent:={}
var _list_ok:=-1

static func _list_url()->String:
    var base:=Network.directory_url()
    return "" if base.is_empty() else base+"/v1/lobbies"

func _list_state()->String:
    if _list_url().is_empty():return "not available: this build has no lobby_server.txt"
    return "on" if listed else "off"

## Again every LIST_MS, or at once when players, the limit or the address change.
func _announce()->void:
    if _list_url().is_empty() or _list_request.get_http_client_status()!=HTTPClient.STATUS_DISCONNECTED:return
    var record:Dictionary=main.coop_game._lobby_record()
    if record.is_empty():return
    # The address phones reach it by: the public one found at startup, else
    # the one the directory sees the request come from.
    record["address"]=_outside if not _outside.is_empty() else "auto"
    if Time.get_ticks_msec()<_list_next and record==_list_sent:return
    _list_sent=record;_list_next=Time.get_ticks_msec()+LIST_MS
    if _list_key.is_empty():_list_key=preload("res://scripts/coop_random.gd").hex(16)
    var body:=record.duplicate();body["key"]=_list_key
    _list_request.request(_list_url(),main.coop_game.lobby._headers(_list_url(),true),HTTPClient.METHOD_POST,JSON.stringify(body))

func _list_reply(result:int,code:int,_headers:PackedStringArray,_body:PackedByteArray)->void:
    if _list_key.is_empty():return # the goodbye of _unlist
    var ok:=int(result==HTTPRequest.RESULT_SUCCESS and code==200)
    # Not listed yet, or about to drop off: try again soon, not in LIST_MS.
    if not ok:_list_next=Time.get_ticks_msec()+LIST_RETRY_MS
    if ok==_list_ok:return
    _list_ok=ok
    if ok:print("SERVER listed in the online games list",(" as "+String(_list_sent.address)+":"+str(port)) if _list_sent.get("address")!="auto" else ", at the address it sees this PC by")
    else:print("SERVER could not reach the online games list (",code if code>0 else result,"), trying again")

func _unlist()->void:
    if _list_key.is_empty():return
    var goodbye:=JSON.stringify({"key":_list_key,"remove":true})
    _list_key="";_list_sent={};_list_ok=-1
    _list_request.cancel_request()
    if _list_request.request(_list_url(),main.coop_game.lobby._headers(_list_url(),true),HTTPClient.METHOD_POST,goodbye)!=OK:return
    var answer:Array=await _list_request.request_completed
    print("SERVER removed from the online games list" if answer[0]==HTTPRequest.RESULT_SUCCESS and int(answer[1])==200 else "SERVER could not reach the online games list: the entry goes by itself in a minute")

func _join()->void:
    var target:Dictionary=preload("res://scripts/coop_menu.gd").parse_address(joining)
    if target.is_empty():_fail("bad address "+joining);return
    var coop:Node=main.coop_game
    coop.join_lobby={"name":joining,"address":target.address,"port":target.port,"direct":true,"private":false,"salt":"","account_id":account_id,"account_password":password if not account_id.is_empty() else ""}
    coop.join_password=password if account_id.is_empty() else ""
    print("CLIENT joining ",target.address,":",target.port)
    await coop.choose("JOIN_SETUP",String(target.address))
    main._start_game()
    var deadline:=Time.get_ticks_msec()+600000
    while not (is_instance_valid(main) and main.started):
        # A join that fails after connecting reloads the scene.
        if not is_instance_valid(main):_fail(String(preload("res://scripts/coop_game.gd").ended_reason));return
        if Time.get_ticks_msec()>deadline or (not coop.active and not coop._choosing):_fail(String(main.menu_status.text));return
        await get_tree().process_frame
    print("CLIENT joined world ",coop.world_id," in area ",coop._area()," with ",main.caught_pokemon.size()," pokemon as ",coop.session.actor.left(12))
    if _travel:
        # Walk off the east edge into an area nobody has been to yet.
        main.edge_travel_busy=true
        await main._travel_adjacent_world(Vector2i.RIGHT)
        main.edge_travel_busy=false
        if not is_instance_valid(main) or main.current_world_grid!=Vector2i(1,0):_fail("travel to the next area failed");return
        print("CLIENT travelled to area ",coop._area())
    if not _quit_after_join:return
    # Let this player's first checkpoint reach the host before leaving.
    await coop.checkpoint_player()
    get_tree().quit(0)

func _fail(reason:String)->void:
    printerr("SERVER ERROR: could not start: " if active else "CLIENT ERROR: ",reason.replace("\n"," "))
    get_tree().quit(1)
