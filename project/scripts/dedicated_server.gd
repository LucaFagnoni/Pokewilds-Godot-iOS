extends Node
## Dedicated co-op server: `PokeWilds.console.exe --headless --server [--port N]
## [--world NAME] [--size S|M|L|XL|XXL] [--password P] [--data DIR]`.
## The server is the ordinary online host (see coop_game.gd) whose own player
## never shows: it stands still at the spawn, sends no presence, is not counted
## in the lobby and cannot be met. Everything else (areas, journal, saves) is
## the host code players already use, so a phone hosting keeps working as before.
## Settings come from server.cfg beside the exe (or --config PATH), then the
## command line. Without --server this node does nothing.
## `--join HOST[:PORT] [--password P] [--data DIR] [--quit-after-join]` instead
## joins a game at startup, for PCs and for the server smoke test.
const Paths=preload("res://scripts/game_data_paths.gd")
const Identity=preload("res://scripts/coop_identity.gd")
const JoinCode=preload("res://scripts/coop_join_code.gd")
const SIZES:=["S","M","L","XL","XXL"]
static var active:=false
var joining:=""
var _quit_after_join:=false
var port:=JoinCode.PORT
var world_name:="PokeWilds"
var size:=1
var password:=""
var max_players:=4
var autosave_minutes:=5.0
var main:Node
var _saving:=false
var _quitting:=false
var _next_save:=0

func _init()->void:
    var args:=OS.get_cmdline_args()+OS.get_cmdline_user_args()
    active="--server" in args
    joining="" if active else _arg(args,"--join","")
    _quit_after_join="--quit-after-join" in args
    if not active and joining.is_empty():return
    var base:=OS.get_executable_path().get_base_dir() if not OS.has_feature("editor") else ProjectSettings.globalize_path("user://")
    var data:=_arg(args,"--data",base.path_join("server_data") if active else "")
    if data.is_relative_path():data=base.path_join(data)
    password=_arg(args,"--password","").strip_edges().left(16)
    if not active:
        if not data.is_empty():DirAccess.make_dir_recursive_absolute(data);Paths.directory=data
        return
    var config:=ConfigFile.new()
    var config_path:=_arg(args,"--config",base.path_join("server.cfg"))
    if config.load(config_path)==OK:print("SERVER config ",config_path)
    port=int(_arg(args,"--port",str(config.get_value("server","port",port))))
    world_name=_arg(args,"--world",String(config.get_value("server","world",world_name))).strip_edges().left(24)
    var size_text:=_arg(args,"--size",str(config.get_value("server","size",SIZES[size]))).to_upper()
    size=SIZES.find(size_text) if size_text in SIZES else clampi(int(size_text),0,SIZES.size()-1)
    if password.is_empty():password=String(config.get_value("server","password","")).strip_edges().left(16)
    max_players=clampi(int(config.get_value("server","max_players",max_players)),1,4)
    autosave_minutes=maxf(1.0,float(config.get_value("server","autosave_minutes",autosave_minutes)))
    # Everything the server writes (identity, world, area caches) lives here.
    DirAccess.make_dir_recursive_absolute(data)
    Paths.directory=data
    # The folder is new, not a phone's external storage: nothing to migrate.
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
    if not active and joining.is_empty():queue_free();return
    process_mode=Node.PROCESS_MODE_ALWAYS
    if active:
        get_tree().auto_accept_quit=false
        print("SERVER PokeWilds dedicated server, data in ",ProjectSettings.globalize_path(Paths.root_path()))
    while not (get_tree().current_scene!=null and get_tree().current_scene.get("startup_complete")):
        await get_tree().process_frame
    main=get_tree().current_scene
    if not active:_join();return
    var coop:Node=main.coop_game
    coop.host_port=port;coop.max_players=max_players
    coop.lobby_private=not password.is_empty();coop.lobby_password=password
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
    # The server's own player never plays: nothing may start a battle for it.
    for pair in [["encounter_requested","_on_encounter_requested"],["battle_requested","_on_battle_requested"]]:
        if main.world.has_signal(pair[0]) and main.world.is_connected(pair[0],Callable(main,pair[1])):main.world.disconnect(pair[0],Callable(main,pair[1]))
    coop.session.transport.max_peers=max_players
    coop.session.admitted.connect(func(peer,_actor,profile):print("SERVER join: ",profile.get("name","PLAYER")," from ",_address(peer)," (",coop.session.players.size()-1,"/",max_players,")"))
    coop.session.departed.connect(func(_peer,_actor):print("SERVER leave (",coop.session.players.size()-1,"/",max_players,")"))
    print("SERVER world ready, listening on TCP port ",port,(" with a password" if coop.lobby_private else ""))
    for endpoint in JoinCode.local_endpoints():
        print("SERVER   LAN ",endpoint.address,":",port,"  join code ",endpoint.code,"" if port==JoinCode.PORT else " (code works only on port %d)"%JoinCode.PORT)
    print("SERVER commands: stop, save, players")
    _next_save=Time.get_ticks_msec()+int(autosave_minutes*60000)
    _stdin=Thread.new();_stdin.start(_read_stdin)

## Release builds stop at once on Ctrl+C or when their console closes, so the
## clean way out is a command, or start_server.bat: it owns the console, turns
## Ctrl+C into "stop", and closing it closes this pipe, which also means stop.
var _stdin:Thread

func _read_stdin()->void:
    while true:
        var line:=OS.read_string_from_stdin()
        if line.is_empty():
            if OS.get_stdin_type()==OS.STD_HANDLE_PIPE:_shutdown.call_deferred()
            return
        _command.call_deferred(line.strip_edges().to_lower())

func _command(line:String)->void:
    match line:
        "stop","quit","exit":_shutdown()
        "save":save()
        "players":
            var session:Node=main.coop_game.session
            print("SERVER ",session.players.size()-1,"/",max_players," players")
            for peer in session.players:
                if peer!=1:print("SERVER   ",session.players[peer].profile.get("name","PLAYER")," from ",_address(peer))
        "":pass
        _:print("SERVER unknown command \"",line,"\" (stop, save, players)")

func _address(peer:int)->String:
    var peers:Dictionary=main.coop_game.session.transport.peers
    return String(peers[peer].socket.get_connected_host()) if peers.has(peer) else "?"

func _process(_delta:float)->void:
    if _next_save==0 or _quitting or Time.get_ticks_msec()<_next_save:return
    _next_save=Time.get_ticks_msec()+int(autosave_minutes*60000)
    save()

func save()->bool:
    if _saving or main==null or not main.coop_game.active:return false
    _saving=true
    var saved:bool=await main.coop_game.save_game(main._capture_game_save())
    _saving=false
    print("SERVER world saved" if saved else "SERVER ERROR: world save failed")
    return saved

func _notification(what:int)->void:
    if what==NOTIFICATION_WM_CLOSE_REQUEST and active:_shutdown()

func _shutdown()->void:
    if _quitting:return
    _quitting=true
    print("SERVER stopping...")
    while _saving:await get_tree().process_frame
    if main!=null and main.coop_game.active:await save()
    get_tree().quit()

func _join()->void:
    var target:Dictionary=preload("res://scripts/coop_menu.gd").parse_address(joining)
    if target.is_empty():_fail("bad address "+joining);return
    var coop:Node=main.coop_game
    coop.join_lobby={"name":joining,"address":target.address,"port":target.port,"direct":true,"private":false,"salt":""}
    coop.join_password=password
    print("CLIENT joining ",target.address,":",target.port)
    await coop.choose("JOIN_SETUP",String(target.address))
    main._start_game()
    var deadline:=Time.get_ticks_msec()+600000
    while not main.started:
        # A join that fails after connecting reloads the scene.
        if not is_instance_valid(main):_fail(String(preload("res://scripts/coop_game.gd").ended_reason));return
        if Time.get_ticks_msec()>deadline or (not coop.active and not coop._choosing):_fail(String(main.menu_status.text));return
        await get_tree().process_frame
    print("CLIENT joined world ",coop.world_id," in area ",coop._area()," with ",main.caught_pokemon.size()," pokemon")
    if not _quit_after_join:return
    # Let this player's first checkpoint reach the host before leaving.
    await coop.checkpoint_player()
    get_tree().quit(0)

func _fail(reason:String)->void:
    printerr("SERVER ERROR: could not start: " if active else "CLIENT ERROR: could not join: ",reason.replace("\n"," "))
    get_tree().quit(1)
