extends Node
## Live scene coordinator. Local gameplay never enters this adapter unless ONLINE is selected.
const Session=preload("res://scripts/coop_session.gd")
const Identity=preload("res://scripts/coop_identity.gd")
const State=preload("res://scripts/coop_state.gd")
const Store=preload("res://scripts/coop_store.gd")
const Saves=preload("res://scripts/coop_game_saves.gd")
const Areas=preload("res://scripts/coop_area_service.gd")
const Snapshot=preload("res://scripts/coop_world_snapshot.gd")
const Players=preload("res://scripts/coop_players.gd")
const Commands=preload("res://scripts/coop_commands.gd")
const Cache=preload("res://scripts/source_world_cache.gd")
const Paths=preload("res://scripts/game_data_paths.gd")
const Network=preload("res://scripts/coop_network.gd")
const Lobby=preload("res://scripts/coop_lobby.gd")
const Patch=preload("res://scripts/coop_patch.gd")
const PrivateBox=preload("res://scripts/coop_private_box.gd")
const WorldDelta=preload("res://scripts/coop_world_delta.gd")
var main:Node
var session:Node
var visuals:Node
var service:Node
var commands:Node
var interaction_ui:Control
var chat:Control
var rest:Node
var storage:Node
var beacons:Node
var building:Node
var state=State.new()
var store=Store.new()
var saves=Saves.new()
var active:=false
var new_setup_pending:=false
var join_setup_code:=""
var lobby:Node
var lobby_private:=false
var lobby_password:=""
var lobby_salt:=""
var lobby_name:=""
## Where hosting listens and how many may play (the host included, 2 to
## Session.MAX_PLAYERS; a dedicated server's own player is not counted). Set
## before hosting; a dedicated server sets both.
var host_port:=preload("res://scripts/coop_join_code.gd").PORT
var max_players:=4
## A dedicated server makes new areas itself: (actor, area, token) -> true once
## handled. Without it, or when it fails, the arriving player's device makes it.
var generate_area:Callable
const Server=preload("res://scripts/dedicated_server.gd")
var join_lobby:Dictionary={}
var join_password:=""
var notice:=""
var hosting:=false
var world_id:=""
var pending_game:Dictionary={}
var _guest_game:Dictionary={}
var _loading:=false
var _publishing:=false
var endpoints:Array[Dictionary]=[]
var endpoint_index:=0
var profile_base:=""
var _replies:Dictionary={}
var _request_busy:=false
var _last_checkpoint:=0
var _last_full_checkpoint:=0
var _saved_stamp:Array=[]
## How often a player who is only walking has their record brought up to date.
## Each one gathers, compares and fingerprints the whole character record
## (party, bag, Pokedex, explored map), on that player's device and again on
## the host: tens of milliseconds, felt as a small stall. Other players see
## movement through the live position updates, not through this, and a changed
## party or bag is still saved on the 0.75 s beat, so this can be unhurried.
const POSITION_CHECKPOINT_MS:=30000
const REST_CHECKPOINT_MS:=6000
## The journal is replayed in full on the next load. Folding it into a world
## save at this size keeps loading quick however long a session lasts.
const JOURNAL_COMPACT_BYTES:=24*1024*1024
var _journal_checked:=0
## Creature movement is not journaled, so a world save also runs this often
## while there is movement to keep; a crash loses at most this much wandering.
const MOTION_SAVE_MS:=10*60*1000
var _world_saved_at:=0
var _choosing:=false
var shared_records:Dictionary={}
var _picking:Dictionary={}
static var ended_reason:=""
var clock_seconds:=0.0
var clock_speed:=1.0
var _clock_received:=0
var _clock_sent:=0
var _clock_sent_speed:=1.0
const CLOCK_SEND_MS:=1000
var _checkpoint_running:=false
var pvp:Node
var wild:Node
var population:Node
var hordes:Control
var raids:Node
var population_battles:Node
var events:Node
var _profile_write_busy:=false
var area_authority:=""
var area_epoch:=0
var _travel_target:=""
var _travel_offer:Dictionary={}
var _travel_token:=""
var _entry_reply:Dictionary={}
var _area_flushes:Dictionary={}

func _flush_area(area:String)->bool:
    var owner=String(state.authority.get(area,""))
    if owner.is_empty():return true
    if owner==session.actor:
        while _publishing:await get_tree().process_frame
        return await publish_current()
    var target=-1
    for peer in session.players:
        if session.players[peer].actor==owner:target=peer
    if target<0:return false
    var id=_id()
    if session.send_to(target,{"kind":"area_flush","id":id,"area":area})!=OK:return false
    var deadline=Time.get_ticks_msec()+120000
    while session.players.has(target) and Time.get_ticks_msec()<deadline:
        if _area_flushes.has(id):
            var result:bool=_area_flushes[id];_area_flushes.erase(id);return result
        await get_tree().process_frame
    return false

func prepare_travel(grid:Vector2i)->Dictionary:
    while building.busy or population.busy or population.motion_busy or wild.motion_busy or _request_busy or _checkpoint_running or not wild.pending_spawns.is_empty():
        await get_tree().process_frame
        if not session.trusted:return {"error":"ONLINE CONNECTION CLOSED"}
    if wild.authority():await wild.publish_motion()
    if population.authority() or population.authority(population.local_scope()):await population.publish_motion()
    if not await checkpoint_player() or not await publish_current():return {"error":"ONLINE SAVE FAILED"}
    _area_discovery[_area()]=Snapshot.packed_discovery(main.world)
    _travel_target="%d,%d"%[grid.x,grid.y];_travel_offer={};_travel_token=""
    if hosting:service.request(session.actor,_travel_target)
    else:session.send_host({"kind":"area_request","area":_travel_target})
    # The area may be one that another player is generating at this moment:
    # the answer then comes only once their game has made it and sent it in,
    # which takes minutes for a large world. Say so, and wait that long. The
    # wait used to end after two minutes with nothing on screen.
    var asked:=Time.get_ticks_msec()
    var deadline=asked+600000
    var told:=false
    while session.trusted and _travel_offer.is_empty() and Time.get_ticks_msec()<deadline:
        if not told and Time.get_ticks_msec()-asked>=3000:
            told=true
            main.generation_status.text="THIS AREA IS BEING\nCREATED.\nPLEASE WAIT..."
            main.generation_panel.show()
        await get_tree().process_frame
    if _travel_offer.is_empty():
        if told:main.generation_panel.hide()
        _travel_target="";return {"error":"ONLINE AREA DID NOT RESPOND"}
    session.set_loading(true)
    await get_tree().process_frame
    return _travel_offer

## What each area's map looked like when this player last left it, for this
## session. A player's record holds one explored map, and it was carried into
## whichever area they went to next: an area someone else had made arrived
## already "explored" in the shape of the area just left.
var _area_discovery:Dictionary={}

## This player's own state on arriving in `area`: as it is now, but with that
## area's explored map, or none if they have not been there this session.
func _arrival_personal(area:String)->Dictionary:
    var personal:Dictionary=Snapshot.capture_personal(main.world)
    if _area_discovery.has(area):personal["discovered_cells"]=_area_discovery[area]
    else:personal["discovered_cells"]={}
    return personal

func finish_travel()->bool:
    if not _travel_token.is_empty():
        main.generation_status.text="Saving new area...";main.generation_panel.show()
        var parts=Snapshot.split(main.world.get_crafting_save_state())
        var bytes=Snapshot.encode(main.world.world_seed,main.world.map_size_index,FileAccess.get_file_as_bytes(Cache.cache_path(main.world.world_seed,main.world.map_size_index)),parts.shared)
        var result:Dictionary
        if hosting:result=await service.generated(session.actor,_travel_target,_travel_token,{"seed":main.world.world_seed,"size":main.world.map_size_index},bytes)
        else:result=await service.upload(_travel_target,_travel_token,0,bytes)
        if not result.get("ok",false):return false
    _entry_reply={}
    if hosting:
        _entry_reply=service.areas.enter(session.actor,_travel_target)
        _broadcast_authority()
    else:session.send_host({"kind":"entered","area":_travel_target})
    var deadline=Time.get_ticks_msec()+15000
    while session.trusted and _entry_reply.is_empty() and Time.get_ticks_msec()<deadline:await get_tree().process_frame
    if not _entry_reply.get("ok",false):return false
    area_authority=String(_entry_reply.authority);area_epoch=int(_entry_reply.epoch)
    visuals.set_area(_travel_target);_travel_target="";_travel_token="";_travel_offer={}
    building.sync_current()
    wild.request_sync()
    population.sync_pending=true
    _refresh_drops()
    rest.apply_on_entry()
    if hosting and not save_checkpoint(main._capture_game_save()):return false
    return await checkpoint_player()

func _generation_requested(actor:String,area:String,token:String)->void:
    if actor==session.actor:
        if area==_travel_target:_travel_token=token;_travel_offer={"new":true}
        return
    if generate_area.is_valid() and await generate_area.call(actor,area,token):return
    for peer in session.players:
        if session.players[peer].actor==actor:session.send_to(peer,{"kind":"area_generate","area":area,"token":token})

func _install_cache(decoded:Dictionary)->bool:
    var path=Cache.cache_path(decoded.seed,decoded["size"])
    if DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))!=OK:return false
    var file=FileAccess.open(path+".pending",FileAccess.WRITE)
    if file==null:return false
    file.store_buffer(decoded.cache);file.flush();var error=file.get_error();file.close()
    return error==OK and DirAccess.rename_absolute(path+".pending",path)==OK

func drop_item(item:String,amount:int,cell:Vector2i,thrown:bool=false)->bool:
    var drops=main.world.dropped_items()
    # A thrown ball may land on a pile of the same ball.
    var same_pile:bool=thrown and drops.records.has(drops.key(cell)) and drops.records[drops.key(cell)].get("item")==item
    if not same_pile and not drops.can_drop(cell):return false
    var request:={"item":item,"amount":amount,"area":scope(),"x":cell.x,"y":cell.y}
    if thrown:request["thrown"]=true
    var result:Dictionary=await command("drop",request)
    if result.get("ok",false):main.world.play_source_sound("seed1");return true
    return false

func pickup_item(record:Dictionary)->void:
    var id=String(record.get("coop_id",""))
    if id.is_empty() or _picking.has(id):return
    _picking[id]=true
    var result:Dictionary=await command("pickup",{"key":id})
    _picking.erase(id)
    if result.get("ok",false):main.world.world_message.emit("Picked up %s x%d!"%[record.item,int(record.amount)])

func _refresh_drops()->void:
    if not main.world.generated:return
    var manager=main.world.dropped_items()
    for key in manager.records.keys():
        if manager.records[key].has("coop_id"):manager.records.erase(key)
    for key in shared_records:
        if not String(key).begins_with("drop/"):continue
        var item:Dictionary=shared_records[key]
        if item.get("area")!=scope():continue
        var cell=Vector2i(int(item.x),int(item.y))
        manager.records[manager.key(cell)]={"scope":manager.scope(),"x":cell.x,"y":cell.y,"item":item.item,"amount":int(item.amount),"coop_id":key}
    manager.rebuild()

func join_code()->String:
    if endpoints.is_empty():return "UNAVAILABLE"
    return String(endpoints[endpoint_index].code)

func cycle_endpoint(direction:int)->void:
    if not endpoints.is_empty():endpoint_index=wrapi(endpoint_index+direction,0,endpoints.size())

func cancel_join()->void:
    if hosting or main.started:return
    main._set_join_layout(false)
    join_setup_code="";main.world_edit.editable=true
    preload("res://scripts/crafting_data.gd").online_enabled=false
    active=false;_loading=false;pending_game={};_guest_game={}
    session.stop();Network.join_close();Cache.online_namespace=""
    if is_instance_valid(service):service.queue_free();service=null

func configure(game:Node)->void:
    preload("res://scripts/crafting_data.gd").online_enabled=false
    main=game;process_mode=Node.PROCESS_MODE_ALWAYS
    if not ended_reason.is_empty():main.menu_status.text=ended_reason;notice=ended_reason;ended_reason=""
    lobby=Lobby.new();add_child(lobby)
    session=Session.new();add_child(session)
    session.admitted.connect(_admitted)
    session.has_character=func(actor):return state.records.has("player/"+String(actor))
    session.blocked=func(actor,device):return hosting and (state.records.has("blocked/"+String(actor)) or (String(device)!=session.NO_DEVICE and state.records.has("blocked_device/"+String(device))))
    session.rejected.connect(_failure)
    session.session_ready.connect(_ready_session)
    session.message.connect(_message)
    session.connection_lost.connect(_connection_lost)
    session.departed.connect(func(_peer,_actor):_broadcast_authority.call_deferred())
    session.departed.connect(func(peer,_actor):_player_notice(peer,"","left"))
    session.departed.connect(func(peer,_actor):_join_records_sent.erase(peer))
    session.departed.connect(func(_peer,actor):_travelling.erase(actor))
    visuals=Players.new();add_child(visuals);visuals.configure(main,session,state)
    visuals.presence_received.connect(_presence)
    commands=Commands.new();add_child(commands);commands.bind(session,state)
    commands.interactions.battle_item_rules=main.BATTLE_ITEM_RULES
    commands.changed.connect(_committed)
    commands.reply.connect(_interaction_reply)
    interaction_ui=preload("res://scripts/coop_interaction_ui.gd").new()
    main.get_node("UI").add_child(interaction_ui);interaction_ui.configure(main,self)
    pvp=preload("res://scripts/coop_pvp_runtime.gd").new();add_child(pvp);pvp.configure(self)
    interaction_ui.battle_accepted.connect(pvp.receive)
    chat=preload("res://scripts/coop_chat.gd").new()
    main.get_node("UI").add_child(chat);chat.configure(main,self)
    rest=preload("res://scripts/coop_rest.gd").new();add_child(rest);rest.configure(self)
    storage=preload("res://scripts/coop_storage.gd").new();add_child(storage);storage.configure(self)
    beacons=preload("res://scripts/coop_beacons.gd").new();add_child(beacons);beacons.configure(self)
    building=preload("res://scripts/coop_build_runtime.gd").new();add_child(building);building.configure(self)
    commands.build_action=building.execute
    wild=preload("res://scripts/coop_wild_runtime.gd").new();add_child(wild);wild.configure(self)
    commands.wild_action=wild.execute
    population=preload("res://scripts/coop_population_runtime.gd").new();add_child(population);population.configure(self)
    commands.population_action=population.execute
    hordes=preload("res://scripts/coop_horde_runtime.gd").new()
    main.get_node("UI").add_child(hordes);hordes.configure(self)
    commands.horde_action=hordes.execute
    raids=preload("res://scripts/coop_raid_runtime.gd").new();add_child(raids);raids.configure(self)
    commands.raid_action=raids.execute
    population_battles=preload("res://scripts/coop_population_battles.gd").new();add_child(population_battles);population_battles.configure(self)
    commands.population_battle_action=population_battles.execute
    events=preload("res://scripts/coop_special_events.gd").new();add_child(events);events.configure(self)
    commands.event_action=events.execute

func handle_input(event:InputEvent)->bool:
    if interaction_ui.visible:interaction_ui.handle(event);return true
    if chat.visible:chat.handle(event);return true
    if not active or not session.trusted or not main.started or main.generating or main._field_ui_blocks_gameplay():return false
    # T opens the world chat (coop_chat.gd).
    if event is InputEventKey and event.pressed and not event.echo and event.keycode==KEY_T:chat.open();return true
    if not event.is_action_pressed("confirm"):return false
    if main.world.active_area_id=="OVERWORLD" and main.world.built_structures.get(main.world._player_cell(),{}).get("name")=="BEACON":
        beacons.open();return true
    # Players can now stand shoulder to shoulder, so the one being faced is
    # found by where they stand, not by which tile they are counted in.
    var here:Vector2=main.world.player.position
    var facing:=Vector2(main.world._facing_cell())
    for actor in visuals.last_packets:
        if actor==session.actor:continue
        var packet:Dictionary=visuals.last_packets[actor]
        if packet.get("area")!=_area() or packet.get("layer")!=visuals._layer():continue
        var away:Vector2=Vector2(float(packet.get("body_x",int(packet.get("cell_x",-999999))*16+8)),float(packet.get("body_y",int(packet.get("cell_y",-999999))*16+8)))-here
        var ahead:=away.dot(facing)
        if ahead<4.0 or ahead>24.0 or absf(away.dot(Vector2(facing.y,facing.x)))>10.0:continue
        if packet.get("battle",false):main._show_message("That player is in a battle.")
        else:interaction_ui.open_for(actor)
        return true
    return false

func _interaction_reply(actor:String,_request:String,result:Dictionary)->void:
    if not hosting or not result.get("ok",false):return
    var recipients:Array=[]
    if result.get("session") is Dictionary:
        recipients=[result.session.a,result.session.b]
    elif result.get("kind")=="closed":recipients=[result.a,result.b]
    elif result.get("kind")=="trade_complete":
        for change in result.get("changes",[]):
            if String(change.key).begins_with("player/"):recipients.append(String(change.key).trim_prefix("player/"))
    else:return
    for recipient in recipients:
        var visible=Commands.visible_result(result,String(recipient))
        if recipient==session.actor:interaction_ui.update(visible)
        else:
            for peer in session.players:
                if session.players[peer].actor==recipient:session.send_to(peer,{"kind":"interaction_update","result":visible})

func _presence(actor:String,packet:Dictionary)->void:
    commands.presence[actor]={"area":String(packet.area)+"|"+String(packet.layer),
        "x":int(packet.get("cell_x",0)),"y":int(packet.get("cell_y",0)),
        "fx":int(packet.visual.get("fx",0)),"fy":int(packet.visual.get("fy",1)),
        "battle":bool(packet.get("battle",false)),"helper_slot":int(packet.get("helper_slot",-1)),"population_scope":String(packet.get("population_scope","OVERWORLD"))}
    if actor==session.actor:
        for i in range(main.caught_pokemon.size()):
            if main._storage_is_active(main.caught_pokemon[i]):commands.presence[actor]["helper_slot"]=i;break

func scope()->String:return _area()+"|"+visuals._layer()

func _personal_profile()->Dictionary:
    if is_instance_valid(events) and events.active and not events.finishing:return events.original_profile.duplicate(true)
    if is_instance_valid(population_battles) and not population_battles.claim.is_empty() and not population_battles.finishing:return population_battles.original_profile.duplicate(true)
    if is_instance_valid(raids) and raids.active and not raids.finishing:return raids.original_profile.duplicate(true)
    if is_instance_valid(wild) and not wild.encounter.is_empty() and not wild.finishing:return wild.original_profile.duplicate(true)
    var data:Dictionary=main._capture_game_save(2,true)
    var party:Array=main.caught_pokemon
    var inventory:Dictionary=main.inventory
    if is_instance_valid(pvp) and pvp.active:
        party=pvp.original_party;inventory=pvp.original_inventory
        data["caught_pokemon"]=party.duplicate(true);data["inventory"]=inventory.duplicate(true)
    data.erase("adjacent_worlds");data.erase("pokemon_storage")
    data["coop_respawn"]=rest.record.duplicate(true)
    data["coop_pending_pokemon"]=storage.pending.duplicate(true)
    data["crafting_state"]=Snapshot.split(data.crafting_state).personal
    return {"party":party.duplicate(true),"inventory":inventory.duplicate(true),"save":data}

func checkpoint_player()->bool:
    while _profile_write_busy:
        await get_tree().process_frame
        if not session.trusted:return false
    _profile_write_busy=true
    var success:bool=await _checkpoint_player_now()
    _profile_write_busy=false
    return success

func _checkpoint_player_now()->bool:
    if not active or not session.trusted:return false
    var profile=_personal_profile()
    var sent_pending:Array=profile.save.coop_pending_pokemon.duplicate(true)
    if hosting:
        var key="player/"+session.actor
        var changes=_only_what_changed(storage.profile_changes(session.actor,profile),key)
        changes.append(state.change("clock",{"seconds":clock_seconds}))
        var result=state.transact(session.actor,"profile/"+_id(),changes,"",not _walking_only(changes,key))
        if result.get("ok",false):
            # The stored record is the reference from now on, not this copy.
            profile_base=state.print_of(key,{});storage.settle(sent_pending,profile.save.coop_pending_pokemon)
            storage.broadcast_profile_storage(result)
        else:print("ONLINE host player record not saved: ",result.get("reason","unknown")," ",result.get("key",""))
        return bool(result.get("ok",false))
    var request:=_checkpoint_packet(profile,sent_pending)
    if request.is_empty():return true
    var response:Dictionary=await _rpc(request)
    if _sent_checkpoints.erase(request.id) or not response.get("ok",false):_send_whole_profile=true
    return bool(response.get("ok",false))

## Guest: a save of this player's record, sent as what changed since the record
## the host last confirmed. The whole record goes only the first time, or after
## the host could not use edits. {} when nothing changed. The answer is taken
## in as it arrives (_checkpoint_done), before anything the host sent after it.
var _sent_checkpoints:Dictionary={}

func _checkpoint_packet(profile:Dictionary,sent_pending:Array)->Dictionary:
    var request:={"kind":"profile_checkpoint","id":_id(),"base":profile_base}
    var confirmed:Dictionary=shared_records.get("player/"+session.actor,{})
    if _send_whole_profile or confirmed.is_empty():request["profile"]=profile
    else:
        var edits:=Patch.diff(confirmed,profile)
        if edits.is_empty():return {}
        request["edits"]=edits
    _sent_checkpoints[request.id]={"profile":profile,"sent_pending":sent_pending}
    return request

func _checkpoint_done(id:String,response:Dictionary)->void:
    var sent:Dictionary=_sent_checkpoints.get(id,{})
    if not _sent_checkpoints.erase(id):return
    _send_whole_profile=not response.get("ok",false)
    if not response.get("ok",false):return
    var profile:Dictionary=sent.profile
    profile_base=String(response.base)
    profile.save.coop_pending_pokemon=response.get("pending",[]).duplicate(true)
    shared_records["player/"+session.actor]=profile.duplicate(true)
    _berry_profile_base=profile_base
    storage.settle(sent.sent_pending,response.get("pending",[]))

var _berry_profile_base:=""
var _send_whole_profile:=false
var _private_box_synced:=false

## On entering a world, offer the private box this device carries. Until that
## has happened the device copy is not touched: this world may hold an old one.
func _travelling_box_enter()->void:
    _private_box_synced=false
    var key:String="private_box/"+session.actor
    var device:Dictionary=PrivateBox.read()
    if not device.exists:
        # First world since the box began travelling: start from what is here.
        var here:Array=(state.records if hosting else shared_records).get(key,[])
        _private_box_synced=PrivateBox.write(here,[])==OK
        return
    var deadline:=Time.get_ticks_msec()+30000
    while active and session.trusted and Time.get_ticks_msec()<deadline:
        var result:Dictionary=await command("private_sync",{"entries":device.entries,"removed":device.removed})
        if result.get("ok",false):
            _private_box_synced=true
            # Record the box as this world now holds it. If the host's update
            # has not reached this device yet, it is mirrored when it arrives.
            PrivateBox.mirror((state.records if hosting else shared_records).get(key,[]))
            return
        if result.get("reason","")!="busy":
            print("ONLINE private box could not be brought into this world: ",result.get("reason","unknown"));return
        await get_tree().process_frame

## What changes just by walking about. A checkpoint that holds nothing else is
## kept in memory and reaches the disk with the next world save; writing the
## clock and a position to the journal every second was a regular small stall
## on the host. Party, bag, storage and everything else are still written at once.
const WALKING:=[["save","player_x"],["save","player_y"],["save","friendship_step_timer"],["save","egg_step_timer"],
    ["save","crafting_state","active_field_pokemon"],["save","crafting_state","discovered_cells"],
    ["save","crafting_state","follower_pokemon"],["save","crafting_state","source_return_x"],["save","crafting_state","source_return_y"]]

func _walking_only(changes:Array,player_key:String)->bool:
    for change in changes:
        var key:=String(change.get("key",""))
        if key=="clock":continue
        if key!=player_key or not change.has("edits"):return false
        for edit in change.edits:
            var path:Array=edit[1]
            # The countdowns of an egg in the party: ["party", slot, "hatch_steps"], and
            # "hatch_cycles", which drops by one every sixteen steps.
            var walking:bool=path.size()==3 and String(path[0])=="party" and String(path[2]) in ["hatch_steps","hatch_cycles"]
            for known in WALKING:
                if path.size()>=known.size() and path.slice(0,known.size())==known:walking=true;break
            if not walking:return false
    return true

## Replaces a whole-record change with edits to the stored record, and drops
## it when nothing in the record changed.
func _only_what_changed(changes:Array,key:String)->Array:
    var result:Array=[]
    for change in changes:
        if String(change.get("key",""))!=key or not change.has("after") or not state.records.has(key):
            result.append(change);continue
        var slim:Dictionary=state.change_edits(key,change.after)
        if not slim.is_empty():result.append(slim)
    return result

## True when the party and bag are as they were at the last saved checkpoint.
## Compared with a stamp of the live data rather than with the stored record:
## a record read back from a save holds the same numbers in another form, and
## never compared equal, which put a full checkpoint on every beat.
func _party_and_bag_saved()->bool:
    return _saved_stamp==_party_and_bag_stamp()

func _party_and_bag_stamp()->Array:
    # An egg being carried counts down its steps on every step taken. That is
    # walking, not a change to the party: left in, it made a full save run on
    # every beat for as long as the player walked with an egg, a stall of
    # about 40 ms three times every two seconds.
    var party:Array=[]
    for entry in main.caught_pokemon:
        if entry is Dictionary and entry.has("hatch_steps"):
            var steady:Dictionary=entry.duplicate()
            steady.erase("hatch_steps");steady.erase("hatch_cycles")
            party.append(steady.hash())
        else:party.append(hash(entry))
    return [party,main.inventory.hash()]

func _berry_profile_is_current()->bool:
    # A berry grants inventory only. Reuse the last durable profile when its
    # party/inventory still match; movement is saved by the regular checkpoint.
    # Any local party or inventory edit still takes the normal checkpoint path.
    var profile:Dictionary=(state.records if hosting else shared_records).get("player/"+session.actor,{})
    return not profile.is_empty() and profile.get("party",[])==main.caught_pokemon and profile.get("inventory",{})==main.inventory and (state.print_of("player/"+session.actor,{})==profile_base if hosting else _berry_profile_base==profile_base)

## Sent by an area's simulation on its own, several times a second while
## creatures move. They touch no player's record and have their own busy
## flags. They used to take the one-at-a-time slot below as well: a guest
## simulating an area over a phone connection had one in flight nearly all the
## time, and the player's own actions (a battle, a catch, a build, a drop) were
## turned away as busy until a gap came, often for tens of seconds.
const BACKGROUND_COMMANDS:=["wild_motion","population_motion","event_motion","wild_spawn","wild_namespace"]
## Need no fresh player record first: they neither read nor change it, or carry
## all of it themselves. A claim saved the record first, one more round trip
## before every battle and catch.
const NO_CHECKPOINT:=["trade_offer","trade_confirm","battle_action","battle_done","cancel","wild_claim","wild_release","wild_finish","raid_damage","raid_finish","population_finish","event_finish"]

## Waits a few seconds at most for the one-at-a-time slot below. Something the
## player pressed must not be dropped unseen because a save or another action
## happened to be on its way.
func wait_free(limit_ms:int=8000)->bool:
    var until=Time.get_ticks_msec()+limit_ms
    while _request_busy and active and Time.get_ticks_msec()<until:await get_tree().process_frame
    return active and not _request_busy

func command(operation:String,args:Dictionary,berry_pickup:bool=false)->Dictionary:
    var background:bool=operation in BACKGROUND_COMMANDS
    if (_request_busy and not background) or not active or not session.trusted:return {"ok":false,"reason":"busy"}
    if not background:_request_busy=true
    while _checkpoint_running and not background:
        await get_tree().process_frame
        if not session.trusted:_request_busy=false;return {"ok":false,"reason":"disconnected"}
    var reuse_berry_profile:=berry_pickup and operation=="field_dig" and _berry_profile_is_current()
    var save_first:bool=not reuse_berry_profile and not background and operation not in NO_CHECKPOINT
    # A guest's save goes just in front of the command instead of a round trip
    # before it: the host runs the command only if the save worked, and checks
    # it against the record that save made (coop_commands.gd "after").
    var ahead:Dictionary={}
    if save_first and not hosting:
        while _profile_write_busy:
            await get_tree().process_frame
            if not session.trusted:_request_busy=false;return {"ok":false,"reason":"disconnected"}
        var profile:Dictionary=_personal_profile()
        ahead=_checkpoint_packet(profile,profile.save.coop_pending_pokemon.duplicate(true))
        if not ahead.is_empty():
            if session.send_host(ahead)!=OK:
                _sent_checkpoints.erase(ahead.id);_request_busy=false;return {"ok":false,"reason":"connection_busy"}
            _profile_write_busy=true
    elif save_first and not await checkpoint_player():
        print("ONLINE command not sent: ",operation," (player record could not be saved)")
        _request_busy=false;return {"ok":false,"reason":"save_failed"}
    var cell:Vector2i=main.world._player_cell()
    var packet={"kind":"command","id":_id(),"op":operation,"args":args}
    if not ahead.is_empty():packet["after"]=ahead.id
    if operation in ["build","remove_build","paint","field_cut","field_dig"]:args["profile_hash"]=profile_base
    if operation=="deploy":args["base"]=profile_base
    var result:Dictionary
    # A dedicated server's own player is nowhere: no presence to be found by.
    if hosting and Server.active:result=commands.execute(session.actor,packet)
    elif hosting:
        commands.presence[session.actor]={"area":scope(),"x":cell.x,"y":cell.y,"battle":main.battle_active,"fx":int(main.world.player.facing.x),"fy":int(main.world.player.facing.y),"population_scope":population.local_scope()}
        for index in range(main.caught_pokemon.size()):
            if main._storage_is_active(main.caught_pokemon[index]):commands.presence[session.actor]["helper_slot"]=index;break
        result=commands.execute(session.actor,packet)
    else:
        var slim:=_with_profile_edits(packet)
        result=await _rpc(slim)
        if result.get("reason")=="edits_do_not_fit" and slim!=packet:packet.id=_id();result=await _rpc(packet)
    if not ahead.is_empty():
        # Its answer came before the command's; none at all means start over whole.
        _profile_write_busy=false;_replies.erase(ahead.id)
        if _sent_checkpoints.erase(ahead.id):_send_whole_profile=true
    if not background:_request_busy=false
    # Refusals are otherwise silent: the action just visibly undoes itself.
    if not result.get("ok",false):print("ONLINE command refused: ",operation," reason=",result.get("reason","unknown")," key=",result.get("key",""))
    return result

## A battle's result carries the player's whole record: 80 KB and more for a
## long-played one, over a second of a phone's uplink after every battle and
## catch. A guest sends what changed since the copy the host confirmed instead
## (rebuilt by the host, coop_commands.gd); the whole record only if that fails.
const PROFILE_RESULTS:=["wild_finish","raid_finish","population_finish","event_finish"]

func _with_profile_edits(packet:Dictionary)->Dictionary:
    var args:Dictionary=packet.args
    var confirmed=shared_records.get("player/"+session.actor)
    if not packet.op in PROFILE_RESULTS or not args.get("profile") is Dictionary or not confirmed is Dictionary or String(args.get("base",""))!=profile_base:return packet
    var edits:=Patch.diff(confirmed,args.profile)
    if not Patch.valid(edits):return packet
    var slim:=packet.duplicate();slim.args=args.duplicate();slim.args.erase("profile");slim.args["profile_edits"]=edits
    return slim

func _id()->String:return preload("res://scripts/coop_random.gd").hex(16)

## Wakes those waiting in _rpc: once a frame, and as soon as an answer is in
## (at the end of the frame that read it). Waiting for the next frame instead
## added a frame to every request, ~33 ms at 30 FPS, two in a catch.
signal _answered

func _rpc(packet:Dictionary)->Dictionary:
    var id=String(packet.id)
    if not get_tree().process_frame.is_connected(_answered.emit):get_tree().process_frame.connect(_answered.emit)
    var deadline=Time.get_ticks_msec()+15000
    var error:Error=session.send_host(packet)
    if error!=OK:return {"ok":false,"reason":"connection_busy"}
    var retry_at=Time.get_ticks_msec()+3000
    while session.trusted and Time.get_ticks_msec()<deadline:
        if _replies.has(id):
            var response:Dictionary=_replies[id];_replies.erase(id);return response
        if Time.get_ticks_msec()>=retry_at and packet.get("kind") in ["command","profile_checkpoint"]:
            # Reuse the transaction ID: a delayed response must never spend,
            # withdraw or grant the same thing twice.
            session.send_host(packet);retry_at=Time.get_ticks_msec()+3000
        await _answered
    return {"ok":false,"reason":"disconnected"}

func _checkpoint_request(peer:int,actor:String,packet:Dictionary)->void:
    if not packet.get("id") is String or packet.id.length()>48:return
    var whole:=packet.get("profile") is Dictionary
    if not whole and not Patch.valid(packet.get("edits")):return
    var key="player/"+actor
    var result:Dictionary
    var previous:Dictionary=state.outcomes.get(actor+"/profile/"+String(packet.id),{})
    if not previous.is_empty():
        var current:Dictionary=state.records.get(key,{})
        result={"ok":true,"base":state.print_of(key,{}),"pending":current.get("save",{}).get("coop_pending_pokemon",[])}
    elif String(packet.get("base",""))!=state.print_of(key,{}):
        result={"ok":false,"reason":"profile_changed"}
    else:
        # Either the whole record, or edits to the one the player last had confirmed.
        var profile=packet.profile if whole else Patch.apply(state.records.get(key,{}),packet.edits)
        if not _profile_shape_ok(profile):
            if whole:return
            result={"ok":false,"reason":"edits_do_not_fit"}
        else:
            var changes:=_only_what_changed(storage.profile_changes(actor,profile),key)
            result=state.transact(actor,"profile/"+String(packet.id),changes,"",not _walking_only(changes,key)) if not changes.is_empty() else {"ok":true}
            if result.get("ok",false):
                if result.has("changes"):storage.broadcast_profile_storage(result)
                var stored:Dictionary=state.records.get(key,{})
                result={"ok":true,"base":state.print_of(key,{}),"pending":stored.get("save",{}).get("coop_pending_pokemon",[])}
    # For a command sent right behind this save ("after"): the record it made.
    if result.get("ok",false):commands.saved(actor,String(packet.id),String(result.base))
    session.send_to(peer,{"kind":"profile_result","id":packet.id,"result":result})

func _profile_shape_ok(profile:Variant)->bool:
    if not profile is Dictionary:return false
    if not profile.get("party") is Array or profile.party.size()>6 or not profile.get("inventory") is Dictionary or profile.inventory.size()>1024:return false
    return profile.get("save") is Dictionary

func _committed(commit:Dictionary)->void:
    var deltas:Dictionary={}
    # Most commits (Pokemon moving about, builds, drops) read the same for
    # every player who watches the same areas: worked out and encoded once
    # for them all. Only one that touches a player's own records is made for
    # each player.
    var personal:=_personal(commit)
    var encoded:Dictionary={}
    for peer in session.players:
        if peer==1:continue
        var actor=String(session.players[peer].actor)
        var areas:Array=_watched(actor)
        var group:String=(actor if personal else "")+"|"+",".join(areas)
        if not encoded.has(group):encoded[group]=_visible_bytes(commit,actor,areas,personal,deltas)
        if not encoded[group].is_empty():session.send_bytes_to(peer,encoded[group])
    var own:Dictionary=Commands.visible_result(commit,session.actor)
    own["profile_base"]=state.print_of("player/"+session.actor,{})
    _apply_visible(own)

## The shared_commit `actor` is sent: only the records of the areas they are
## in or going to (records of the others are sent when they go there); empty
## when nothing in it is theirs to see.
func _visible_bytes(commit:Dictionary,actor:String,areas:Array,personal:bool,deltas:Dictionary)->PackedByteArray:
    var started:=Time.get_ticks_usec()
    var visible=Commands.visible_result(commit,actor)
    if visible.get("changes") is Array:
        var kept:Array=[]
        for change in visible.changes:
            var area:=_key_area(String(change.get("key","")))
            if area.is_empty() or area in areas:kept.append(change)
        if kept.is_empty() and not visible.changes.is_empty() and not visible.has("session"):return PackedByteArray()
        visible.changes=kept
    # A world record the player holds goes to them as what changed in it
    # (coop_world_delta.gd), checked there against its fingerprint.
    for change in visible.get("changes",[]):
        var key:=String(change.get("key",""))
        var old:Array=state.replaced.get(key,[])
        if not change.get("after") is String or old.is_empty() or old[0]!=change.get("before") or not _shared_key(key,actor):continue
        if not deltas.has(key):deltas[key]=WorldDelta.entry_delta(old[1],change.after)
        if deltas[key]==null:continue
        change.erase("after");change["delta"]=deltas[key];change["print"]=state.print_of(key)
    # A player's own record goes to them as what changed, not whole.
    var own_edits=commit.get("player_edits",{}).get("player/"+actor)
    if own_edits is Array:
        for change in visible.get("changes",[]):
            if String(change.get("key",""))=="player/"+actor and change.has("after"):
                change.erase("after");change["edits"]=own_edits
    # A storage box too (Patch.diff_list), with its list of entries to check by.
    var list_edits:Dictionary=commit.get("list_edits",{})
    for change in visible.get("changes",[]):
        var edits=list_edits.get(String(change.get("key","")))
        if edits is Array and change.get("after") is Array:
            change["entries"]=_entry_ids(change.after);change.erase("after");change["edits"]=edits
    visible.erase("player_edits");visible.erase("list_edits")
    # Kept by the host to check what comes next (the hashes of the request,
    # each record's fingerprint before); read by no player.
    visible.erase("command_hash");visible.erase("request_hash")
    for change in visible.get("changes",[]):change.erase("before")
    # Read only with a change to the player's own record (_apply_visible).
    if personal:visible["profile_base"]=state.print_of("player/"+actor,{})
    var bytes:=JSON.stringify({"kind":"shared_commit","result":visible}).to_utf8_buffer()
    Session.Transport.count("enc:shared_commit",bytes.size(),started)
    return bytes

## True when what a commit shows depends on who looks (Commands.visible_result).
static func _personal(commit:Dictionary)->bool:
    if commit.get("session") is Dictionary and commit.session.has("battle_inventory"):return true
    for change in commit.get("changes",[]):
        var key:=String(change.get("key",""))
        if key.begins_with("player/") or key.begins_with("private_box/") or key.begins_with("horde_reward/"):return true
    return false

## The area a record belongs to; "" for those every player holds.
static func _key_area(key:String)->String:
    return key.get_slice("/",1) if key.begins_with("world/") or key.begins_with("wild_claim/") else ""

## Host: the areas whose records `actor` is kept up to date with: the one
## they are in, and the one they have asked to go to (from its records,
## sent then, until they arrive). actor -> [area, whether it was saved then].
var _travelling:Dictionary={}
func _watched(actor:String)->Array:
    var areas:Array=[]
    var here:=String(state.members.get(actor,{}).get("area",""))
    if not here.is_empty():areas.append(here)
    var going:=String(_travelling.get(actor,[""])[0])
    if not going.is_empty() and going!=here:areas.append(going)
    return areas

## The ids of a box's entries in order, as one number: a box rebuilt from
## edits must come out with the same ones.
static func _entry_ids(list:Array)->int:
    var ids:=PackedStringArray()
    for entry in list:ids.append(str(entry.get("id","")) if entry is Dictionary else "")
    return "\n".join(ids).hash()

## Guest: true until the host's records have arrived (joining, or after asking
## for them again because a world change did not fit the copy here).
var _awaiting_state:=true

func _apply_visible(result:Dictionary)->void:
    if result.get("resync",false) and not hosting:session.send_host({"kind":"state_request"})
    # World records sent as what changed in them, rebuilt on the copy held here.
    # One that does not fit is left out and everything is asked for again;
    # until that arrives (or the first one, while joining) such changes wait.
    var kept:Array=[]
    for change in result.get("changes",[]):
        if change is Dictionary and change.has("delta") and not change.has("after"):
            var rebuilt:=WorldDelta.apply_delta(shared_records.get(String(change.get("key",""))),change.delta)
            if rebuilt.is_empty() or State.fingerprint(rebuilt)!=change.get("print"):
                if not hosting and not _awaiting_state:_awaiting_state=true;session.send_host({"kind":"state_request"})
                continue
            change["after"]=rebuilt
        kept.append(change)
    if result.has("changes"):result["changes"]=kept
    # This player's own record, and a storage box, arrive as edits to the copy held here.
    for change in result.get("changes",[]):
        if change is Dictionary and change.has("edits") and not change.has("after"):
            var held=shared_records.get(String(change.get("key","")))
            var edited=Patch.apply(held,change.edits) if (held is Dictionary or held is Array) and Patch.valid(change.edits) else null
            if edited is Array:
                var entries=change.get("entries")
                if not (entries is int or entries is float) or _entry_ids(edited)!=int(entries):edited=null
            if edited==null:
                # The copies have drifted apart: ask the host for everything again.
                if not hosting:session.send_host({"kind":"state_request"})
                return
            change["after"]=edited
    var drops_changed=false
    var storage_changed=false
    for change in result.get("changes",[]):
        var key=String(change.key)
        if key.begins_with("drop/"):drops_changed=true
        if key.begins_with("box/") or key.begins_with("chest/") or key.begins_with("private_box/"):storage_changed=true
        if change.after==null:
            if shared_records.erase(key):shared_epoch+=1
        else:
            if not shared_records.has(key):shared_epoch+=1
            shared_records[key]=change.after
        if key=="private_box/"+session.actor and _private_box_synced:
            PrivateBox.mirror(change.after if change.after is Array else [])
        if key=="player/"+session.actor and change.after is Dictionary:
            # Keep the saved comparison separate from mutable party records.
            shared_records[key]=change.after.duplicate(true)
            if is_instance_valid(pvp) and pvp.active:
                pvp.original_party=change.after.get("party",[]).duplicate(true)
                pvp.original_inventory=change.after.get("inventory",{}).duplicate(true)
            else:
                main.caught_pokemon.assign(change.after.get("party",[]))
                main.inventory=change.after.get("inventory",{}).duplicate(true)
            profile_base=String(result.get("profile_base",State.fingerprint(change.after)))
            _berry_profile_base=profile_base
    if drops_changed:_refresh_drops()
    if storage_changed:storage.refresh()
    building.committed(result.get("changes",[]))
    wild.committed(result.get("changes",[]),String(result.get("actor","")),String(result.get("id","")))
    population.committed(result.get("changes",[]),String(result.get("actor","")),String(result.get("id","")))
    events.committed(result.get("changes",[]),String(result.get("actor","")),String(result.get("id","")))

## True once the host has answered a join. A connection that dies before then
## never carried anything from this player to the host, which is what an
## isolated guest Wi-Fi network does: say so instead of blaming the host.
var _host_answered:=false
const UNREACHABLE:="COULD NOT REACH THE HOST.\nTRY AGAIN, OR CHECK THE WI-FI."

## The records whose key starts with `prefix`, without walking all of them
## each time. A long-played world holds thousands of records; several systems
## used to scan every one two to four times a second, which showed as a small
## regular hitch on the host. The list is rebuilt only when a record has been
## added or removed since it was made.
var shared_epoch:=0
var _key_lists:Dictionary={}
var _key_lists_epoch:=-1
var _key_lists_hosting:=false
var _key_lists_state:=0

func record_keys(prefix:String)->Array:
    var epoch:int=state.key_epoch if hosting else shared_epoch
    if epoch!=_key_lists_epoch or hosting!=_key_lists_hosting or state.get_instance_id()!=_key_lists_state:
        _key_lists.clear();_key_lists_epoch=epoch;_key_lists_hosting=hosting;_key_lists_state=state.get_instance_id()
    if not _key_lists.has(prefix):
        var found:Array=[]
        for key in (state.records if hosting else shared_records):
            if String(key).begins_with(prefix):found.append(key)
        _key_lists[prefix]=found
    return _key_lists[prefix]

func _connection_lost()->void:
    if not active or hosting:return
    end_session("HOST DISCONNECTED.\nSESSION ENDED." if _host_answered else UNREACHABLE)

func end_session(reason:String)->void:
    print("ONLINE session ended: ",reason," (transport: ",session.transport.last_disconnect_reason,")")
    preload("res://scripts/crafting_data.gd").online_enabled=false
    main.world.set_gameplay_enabled(false)
    active=false;ended_reason=reason
    lobby.stop_advertise();Network.host_close();Network.join_close()
    session.stop();Cache.online_namespace=""
    get_tree().call_deferred("reload_current_scene")

## A guest's clock follows the host's without ever stepping back. It used to be
## set to each world_clock packet as it arrived; packets come with uneven delay
## over Wi-Fi or the internet, so the time jumped back and forth by tens of ms
## several times a second, and water, tide and daylight twitched with it: felt
## as stutter while walking. Now it runs on its own and is steered towards the
## host's time, at most 20% faster or slower, and only a gap over a second is
## closed at once.
var _smooth_clock:=-1.0
var _smooth_at:=0

func world_time(delta:float)->float:
    if hosting:return clock_seconds
    if _clock_received==0:return main.world.world_elapsed_seconds+delta
    var now:=Time.get_ticks_msec()
    # Updates come once a second (CLOCK_SEND_MS); the cap leaves a late one
    # about the slack it had at four a second (two seconds, was 1.75).
    var target:=clock_seconds+minf(3.0,float(now-_clock_received)/1000.0)*clock_speed
    if delta<=0.0:return _smooth_clock if _smooth_clock>=0.0 else target
    var step:=float(now-_smooth_at)/1000.0*clock_speed
    _smooth_at=now
    if _smooth_clock<0.0 or absf(target-_smooth_clock)>1.0:_smooth_clock=target
    else:_smooth_clock+=step*clampf(1.0+(target-_smooth_clock)*2.0,0.8,1.2)
    return _smooth_clock

var _area_cleanup:Thread

## Removes the area files this world no longer uses; see the snapshot store.
func _clean_up_area_files()->void:
    if _area_cleanup!=null:return
    var in_use:Array=[]
    for key in state.records:
        if not String(key).begins_with("area/"):continue
        var metadata=state.records[key]
        if metadata is Dictionary and metadata.get("sha256") is String:in_use.append(metadata.sha256)
    if in_use.is_empty():return
    var home:=ProjectSettings.globalize_path(Paths.path("online_worlds").path_join(world_id))
    _area_cleanup=Thread.new()
    if _area_cleanup.start(preload("res://scripts/coop_snapshot_store.gd").clean_up.bind(home.path_join("snapshots"),home,in_use))!=OK:_area_cleanup=null

func _process(delta:float)->void:
    if _area_cleanup!=null and not _area_cleanup.is_alive():
        var removed:int=_area_cleanup.wait_to_finish();_area_cleanup=null
        if removed>0:print("ONLINE removed ",removed," area files no longer in use")
    if not active or not session.trusted or not main.started:return
    session.set_loading(main.generating or main.edge_travel_busy)
    var now=Time.get_ticks_msec()
    if hosting:
        clock_seconds+=delta
        # Guests run the clock on their own between updates (world_time), so
        # once a second is enough; a change of speed goes out at once.
        if now-_clock_sent>=CLOCK_SEND_MS or Engine.time_scale!=_clock_sent_speed:
            _clock_sent=now;_clock_sent_speed=Engine.time_scale
            for peer in session.players:
                if peer!=1:session.send_to(peer,{"kind":"world_clock","seconds":clock_seconds,"speed":Engine.time_scale})
    if hosting and now-_journal_checked>=20000 and not _checkpoint_running and not _request_busy and not _publishing and not interaction_ui.visible and not main.generating and not main.edge_travel_busy and not main.battle_active:
        _journal_checked=now
        if _world_saved_at==0:_world_saved_at=now
        var fold:bool=State.journal_enabled and (store.journal_size()>JOURNAL_COMPACT_BYTES or (state.loose>0 and now-_world_saved_at>=MOTION_SAVE_MS))
        var captured:Dictionary=main._capture_game_save() if fold else {}
        if fold and not save_checkpoint(captured):
            print("ONLINE journal could not be folded into a world save")
    if now-_last_checkpoint>=750 and not _checkpoint_running and not _request_busy and not interaction_ui.visible and not main.generating and not main.edge_travel_busy:
        _last_checkpoint=now
        # The full record is large, and position updates share its connection.
        # A changed party or bag is still saved on this 0.75 s beat; when only
        # the player's position moved, every few seconds is enough.
        # Resting in a bed heals the party a little on every beat. Saving each
        # step of that was a small stall every 0.75 s all night; every few
        # seconds is plenty, and the rest is saved in full on waking.
        var resting:bool=bool(main.world.get("bed_rest_active")) and now-_last_full_checkpoint<REST_CHECKPOINT_MS
        if now-_last_full_checkpoint<POSITION_CHECKPOINT_MS and (resting or _party_and_bag_saved()):return
        _last_full_checkpoint=now;_checkpoint_running=true
        var stamp:=_party_and_bag_stamp()
        var saved:bool=await checkpoint_player()
        if saved:_saved_stamp=stamp
        _checkpoint_running=false

func _identity()->bool:
    var token=Identity.token()
    var mods=Identity.mods()
    if token.is_empty() or mods.has("error"):
        _failure(String(mods.get("error","PLAYER ID COULD NOT LOAD")));return false
    return session.configure(token,String(mods.digest),{"name":main.player_model_name.text,
        "model":main.player_model_index,"color":main.player_color_index})

func _restore_latest_host_area()->bool:
    var area="%d,%d"%[int(pending_game.get("world_grid_x",0)),int(pending_game.get("world_grid_y",0))]
    var metadata:Dictionary=state.records.get("area/"+area,{})
    if metadata.is_empty():return false
    var reader=preload("res://scripts/coop_snapshot_store.gd").new();add_child(reader)
    if reader.configure(Paths.path("online_worlds").path_join(world_id).path_join("snapshots"))!=OK:
        reader.queue_free();return false
    var loaded:Dictionary=await reader.load_bytes(String(metadata.get("sha256","")))
    reader.queue_free()
    if not loaded.get("ok",false):return false
    var decoded=Snapshot.decode(loaded.bytes)
    if decoded.is_empty() or decoded.seed!=metadata.get("seed") or decoded["size"]!=metadata.get("size"):return false
    var previous_namespace=Cache.online_namespace
    Cache.online_namespace=world_id
    var installed=_install_cache(decoded)
    Cache.online_namespace=previous_namespace
    if not installed:return false
    var personal:Dictionary=Snapshot.split(pending_game.get("crafting_state",{})).personal
    pending_game["crafting_state"]=Snapshot.merge(wild.overlay(area,population.overlay(area,building.overlay(area,decoded.shared,state.records),state.records),state.records),personal)
    pending_game["world_seed"]=decoded.seed;pending_game["world_size"]=decoded["size"]
    return true

func _mode_label(text:String)->void:
    main.menu_status.text=text

func _lobby_record()->Dictionary:
    if not active or not hosting:return {}
    # A dedicated server's own player is not one of the players.
    var players:int=session.players.size()-(1 if Server.active else 0)
    return {"name":lobby_name,"host":String(session.profile.get("name","PLAYER")),"private":lobby_private,
        "players":players,"max":max_players,"salt":lobby_salt,"protocol":Session.PROTOCOL,"mods":session.mod_digest,"port":host_port,
        "accounts":session.accounts!=null,"kind":"server" if Server.active else "game","version":Session.build_version(),"compat":Session.compat_id()}

## Joins a dedicated server from the JOIN GAME list (a "server" entry of
## coop_lobby.gd) over the internet, straight to its address and port as MY
## SERVERS does, never through ZeroTier. A server with player IDs (entry
## "accounts") takes `player_id` and `password` as the ID's login; otherwise
## `password` is its shared password ("" for none).
func join_listed_server(entry:Dictionary,player_id:String,password:String)->void:
    var account:=bool(entry.get("accounts",false))
    join_lobby={"name":String(entry.get("name","SERVER")),"address":String(entry.get("address","")),"port":int(entry.get("port",Network.GAME_PORT)),
        "direct":true,"private":false,"salt":"","kind":"server","account_id":player_id.strip_edges() if account else "","account_password":password if account else ""}
    join_password="" if account else password
    choose("JOIN_SETUP",String(join_lobby.address))

func choose(action:String,value:String)->void:
    # Starting or joining a world takes time; a second press must not start
    # another one on top of it.
    if action in ["NEW","LOAD","JOIN"]:
        if _choosing:return
        _choosing=true
        if action=="LOAD":
            main.coop_menu.show_loading()
            await get_tree().process_frame
            await get_tree().process_frame
        await _choose(action,value)
        _choosing=false
        main.coop_menu.loading_finished(main.menu_status.text)
        return
    if _choosing:return
    await _choose(action,value)

func _choose(action:String,value:String)->void:
    if action=="SOLO":
        cancel_join()
        new_setup_pending=false;join_setup_code="";join_lobby={};main.world_edit.editable=true
        main.coop_menu.close();_mode_label("SOLO")
        main.menu_row=main.MENU_ROW_MODE;main.menu_col=0 if main.selected_mode=="NEW" else 1
        main.menu_status.text="SOLO"
        main._update_classic_menu_labels();main._update_menu_cursor()
        return
    if action=="JOIN_SETUP":
        _mode_label("JOIN GAME")
        join_setup_code=value
        new_setup_pending=false
        main.world_edit.editable=false
        main.coop_menu.close()
        main.menu_row=main.MENU_ROW_COLOR;main.menu_col=0
        main._set_join_layout(true)
        main.menu_status.text="CHOOSE YOUR PLAYER, THEN GO"
        main._update_classic_menu_labels();main._update_menu_cursor()
        return
    if action=="SETUP":
        _mode_label("CO-OP")
        join_setup_code=""
        main.world_edit.editable=true
        new_setup_pending=true
        main.coop_menu.close()
        main.selected_mode="NEW"
        main.menu_row=main.MENU_ROW_WORLD_NAME;main.menu_col=0
        main._update_classic_menu_labels();main._update_menu_cursor()
        return
    if action=="LIST":
        var token=Identity.token()
        if token.is_empty():_failure("PLAYER ID COULD NOT LOAD");return
        main.coop_menu.show_saves(saves.entries(token.sha256_text()));return
    if not _identity():return
    if action=="JOIN":
        main.coop_menu.show_connecting("CONNECTING...")
        preload("res://scripts/crafting_data.gd").online_enabled=true
        active=true;hosting=false;_loading=true
        # A typed address is reached directly, never through the lobby network.
        # A dedicated server from the list is on the internet, not on ZeroTier.
        var direct:bool=bool(join_lobby.get("direct",false)) or join_lobby.get("kind")=="server"
        if not direct:Network.start()
        var deadline=Time.get_ticks_msec()+120000
        while active and not direct and Network.status().state!="ready":
            var current:Dictionary=Network.status()
            if current.state=="error" or Time.get_ticks_msec()>deadline:
                _failure("MULTIPLAYER NETWORK UNAVAILABLE" if String(current.message).is_empty() else String(current.message));return
            main.coop_menu.connecting_text(Network.status_text())
            await get_tree().process_frame
        if not active:return
        main.coop_menu.connecting_text("CONNECTING TO\n%s..."%String(join_lobby.get("name","HOST")).to_upper())
        var port:=int(join_lobby.get("port",Network.GAME_PORT))
        var endpoint:Dictionary={"address":value,"port":port} if direct or (port!=Network.GAME_PORT and not Network.embedded()) else Network.join_endpoint(value)
        if endpoint.is_empty():_failure("COULD NOT OPEN A CONNECTION");return
        session.access_proof=Lobby.proof(String(join_lobby.get("salt","")),join_password) if bool(join_lobby.get("private",false)) else ""
        session.access_password=join_password if direct else ""
        # A saved server with a player ID logs in as that ID (see coop_accounts.gd).
        session.account_id=String(join_lobby.get("account_id","")).strip_edges()
        session.account_password=String(join_lobby.get("account_password",""))
        _host_answered=false
        var error:Error=session.join_address(String(endpoint.address),int(endpoint.port))
        if error!=OK:_failure(error_string(error))
        return
    if action not in ["NEW","LOAD"]:return
    new_setup_pending=false
    join_setup_code="";main.world_edit.editable=true
    world_id=preload("res://scripts/coop_random.gd").hex(16) if action=="NEW" else value
    if not Store.valid_id(world_id):_failure("INVALID ONLINE WORLD");return
    pending_game={} if action=="NEW" else saves.load_host(world_id,session.actor)
    if action=="LOAD" and pending_game.is_empty():_failure("ONLINE SAVE COULD NOT LOAD");return
    if store.open(world_id)!=OK:_failure("ONLINE SAVE COULD NOT OPEN");return
    if action=="LOAD":store.backup()
    state=State.new();commands.state=state;commands.items.state=state;commands.interactions.state=state;visuals.state=state
    if action=="LOAD" and store.load_state(state).is_empty():_failure("ONLINE WORLD STATE COULD NOT LOAD");return
    if action=="LOAD":_clean_up_area_files()
    if action=="LOAD":
        var latest:Dictionary=state.records.get("player/"+session.actor,{})
        var personal:Dictionary=latest.get("save",{})
        if not personal.is_empty():
            var old_shared:Dictionary=Snapshot.split(pending_game.get("crafting_state",{})).shared
            var storage:Dictionary=pending_game.get("pokemon_storage",{})
            pending_game.merge(personal,true)
            pending_game["caught_pokemon"]=latest.get("party",pending_game.get("caught_pokemon",[])).duplicate(true)
            pending_game["inventory"]=latest.get("inventory",pending_game.get("inventory",{})).duplicate(true)
            pending_game["pokemon_storage"]=storage
            pending_game["crafting_state"]=Snapshot.merge(old_shared,personal.get("crafting_state",{}))
        if not await _restore_latest_host_area():_failure("ONLINE AREA COULD NOT LOAD");return
        if state.records.has("clock"):
            pending_game.crafting_state["world_elapsed_seconds"]=float(state.records.clock.seconds)
    state.commit_writer=store.append
    state.enroll(session.actor,session.profile)
    if not wild.recover() or not population_battles.recover() or not events.recover():_failure("ONLINE ENCOUNTERS COULD NOT BE RECOVERED");return
    active=true;hosting=true;Cache.online_namespace=world_id
    preload("res://scripts/crafting_data.gd").online_enabled=true
    main.coop_menu.close();main.selected_mode=action;main.setup_load_committed=true
    await main._start_game()

func _create_service()->bool:
    if is_instance_valid(service):service.queue_free()
    service=Areas.new();add_child(service)
    service.refresh_area=_flush_area
    service.register_objects=storage.register_objects
    service.area_ready.connect(_area_ready)
    service.generation_requested.connect(_generation_requested)
    service.failed.connect(func(failed_actor,reason):
        if failed_actor==session.actor:
            if not _travel_target.is_empty():_travel_offer={"error":String(reason)}
            else:_failure(reason))
    return service.configure(state,session,Paths.path("online_worlds").path_join(world_id).path_join("snapshots"))==OK

func game_started()->bool:
    if not active:return true
    wild.request_sync()
    population.sync_pending=true
    rest.record=pending_game.get("coop_respawn",{}).duplicate(true)
    storage.pending=pending_game.get("coop_pending_pokemon",[]).duplicate(true)
    rest.apply_on_entry()
    if not hosting:
        visuals.set_area(_area());session.send_host({"kind":"entered","area":_area()});_loading=false;_refresh_drops();building.sync_current()
        # Loading the game emptied the storage mirror; the host's records came
        # on being let in (not again on entering, see _message).
        storage.refresh()
        var joined:bool=await wild.initialize_ids()
        if joined:_travelling_box_enter.call_deferred()
        return joined
    shared_records={}
    for key in state.records:
        if _shared_key(String(key),session.actor):shared_records[key]=state.records[key].duplicate(true) if state.records[key] is Dictionary or state.records[key] is Array else state.records[key]
    storage.refresh();_refresh_drops()
    clock_seconds=float(state.records.get("clock",{}).get("seconds",main.world.world_elapsed_seconds))
    if not _create_service():_failure("ONLINE CACHE COULD NOT OPEN");return false
    if not await publish_current():return false
    var checkpoint:Dictionary=main._capture_game_save()
    if not save_checkpoint(checkpoint):_failure("ONLINE SAVE FAILED");return false
    var error:Error=session.host(world_id,host_port)
    if error!=OK:_failure("HOST COULD NOT START: "+error_string(error));return false
    # Connections at once: everyone but a hosting player, who is already in.
    max_players=clampi(max_players,1 if Server.active else 2,Session.MAX_PLAYERS)
    session.transport.max_peers=max_players-(0 if Server.active else 1)
    # The world name is the lobby name other players see in JOIN GAME.
    lobby_name=String(checkpoint.get("world_name","WORLD")).strip_edges().left(24)
    lobby_salt=_id()
    session.access_proof=Lobby.proof(lobby_salt,lobby_password) if lobby_private else ""
    session.access_salt=lobby_salt
    Network.start();Network.host_open();lobby.advertise(_lobby_record)
    # A phone stops hosting when the screen locks or the player switches apps.
    if OS.has_feature("mobile"):show_notice("","hosting")
    endpoints=preload("res://scripts/coop_join_code.gd").local_endpoints()
    var entry=service.areas.enter(session.actor,_area());area_authority=String(entry.get("authority",""));area_epoch=int(entry.get("epoch",0));visuals.set_area(_area())
    if not await wild.initialize_ids():return false
    await checkpoint_player()
    _travelling_box_enter.call_deferred()
    return true

## Dedicated server: true while no player is in the server's own area. Its
## wild and habitat Pokemon then wait where they are, as they do in any area
## no player is in, instead of being moved (and every move sent to every
## player) for no one to see.
func nobody_here()->bool:
    if not Server.active or not hosting:return false
    var area:=_area()
    for actor in state.members:
        if actor!=session.actor and String(state.members[actor].get("area",""))==area:return false
    return true

func _area()->String:
    return "%d,%d"%[main.current_world_grid.x,main.current_world_grid.y]

func publish_current()->bool:
    if not area_authority.is_empty() and area_authority!=session.actor:return true
    # Do not put an optimistic, not-yet-paid placement into an area snapshot.
    # This waits only for this player's action, never for other players to stop.
    while building.busy or population.busy:
        await get_tree().process_frame
        if not session.trusted:return false
    if _publishing:return false
    _publishing=true
    var seed_value=int(main.world.world_seed)
    var size_index=int(main.world.map_size_index)
    var parts=Snapshot.split(main.world.get_crafting_save_state())
    var registry:Dictionary=state.records if hosting else shared_records
    if not area_authority.is_empty() or (hosting and state.records.has("area/"+_area())):
        parts.shared=Snapshot.committed_population(_area(),parts.shared,registry)
    parts.shared["_coop_build_base"]=building.known(_area(),state.records if hosting else shared_records)
    # A guest leaves out the terrain cache: the host has it (Snapshot.refill).
    var bytes=Snapshot.encode_without_cache(seed_value,size_index,parts.shared) if not hosting else \
        Snapshot.encode(seed_value,size_index,FileAccess.get_file_as_bytes(Cache.cache_path(seed_value,size_index)),parts.shared)
    if bytes.is_empty():_publishing=false;_failure("ONLINE AREA CACHE IS MISSING");return false
    if not hosting:
        var uploaded:Dictionary=await service.upload(_area(),"",area_epoch,bytes)
        _publishing=false
        return bool(uploaded.get("ok",false))
    var saved:Dictionary=await service.snapshots.save_bytes(bytes)
    if not saved.get("ok",false):_publishing=false;_failure("ONLINE AREA SAVE FAILED");return false
    var metadata={"seed":seed_value,"size":size_index,"snapshot":saved.snapshot,"sha256":saved.sha256}
    var result=state.transact(session.actor,"snapshot/"+preload("res://scripts/coop_random.gd").hex(16),[state.change("area/"+_area(),metadata)])
    _publishing=false
    var registered:bool=bool(result.get("ok",false)) and storage.register_objects(_area(),parts.shared)
    return registered

func save_checkpoint(data:Dictionary)->bool:
    if not active or not hosting:return false
    if store.save(state,{"world_name":String(data.get("world_name","WORLD")),"owner":session.actor})!=OK:return false
    state.loose=0;_world_saved_at=Time.get_ticks_msec()
    var saved:bool=saves.save_host(world_id,session.actor,data)==OK
    return saved

func save_game(data:Dictionary)->bool:
    while building.busy or _request_busy or _checkpoint_running:
        await get_tree().process_frame
        if not session.trusted:return false
    if not await checkpoint_player():return false
    if not hosting:return true # Host's journal has durably acknowledged this player.
    if not await publish_current():return false
    return save_checkpoint(data)

func _ready_session(id:String,_actor:String)->void:
    if hosting:return
    _host_answered=true
    if not Store.valid_id(id):_failure("INVALID HOST WORLD");return
    world_id=id;Cache.online_namespace=id
    if not _create_service():_failure("ONLINE CACHE COULD NOT OPEN")

## Players the host can remove, for OPTIONS > KICK and KICK AND BAN.
## Listed in the order they joined, each marked 1ST, 2ND, 3RD among the
## players here now: two players can share a name and a look.
var _join_sequence:=0
var _joined_at:Dictionary={}

func kick_candidates()->Array:
    var result:Array=[]
    if not hosting:return result
    for peer in _joined_at.keys():
        if not session.players.has(peer):_joined_at.erase(peer)
    for peer in session.players:
        if peer!=1:
            var profile:Dictionary=session.players[peer].profile
            result.append({"peer":peer,"name":String(profile.get("name","PLAYER")).to_upper(),"model":int(profile.get("model",0)),"color":int(profile.get("color",0)),"at":int(_joined_at.get(peer,peer))})
    result.sort_custom(func(a,b):return int(a.at)<int(b.at))
    for index in range(result.size()):result[index]["order"]=["1ST","2ND","3RD"][index] if index<3 else "%dTH"%(index+1)
    return result

## Removes a player from the game. A plain kick lets them join again. A ban is
## saved with the world and follows their identity, so a new look or name does
## not undo it.
func kick(peer:int,ban:bool=false)->bool:
    if not hosting or peer==1 or not session.players.has(peer):return false
    if ban:
        var actor:=String(session.players[peer].actor)
        var device:=String(session.players[peer].get("device",session.NO_DEVICE))
        var banned:={"name":String(session.players[peer].profile.get("name","PLAYER"))}
        var changes:Array=[state.change("blocked/"+actor,banned)]
        # Also the device, so reinstalling the game does not lift the ban.
        if device!=session.NO_DEVICE and not state.records.has("blocked_device/"+device):changes.append(state.change("blocked_device/"+device,banned))
        var result:Dictionary=state.transact(session.actor,"block/"+_id(),changes)
        if not result.get("ok",false):return false
    session.kick(peer,session.BANNED if ban else session.KICKED)
    return true

## "ASH joined the game." / "ASH left the game." for everyone already playing.
## Without it a player can arrive in a public game and nobody would know.
var _notice_names:Dictionary={}
var _notice_label:Label
## A HUD chip (hud_style.gd) centred under the clock: the same glass, ring and
## white pixel font as the clock above it, the text wrapped to the room the minimap leaves.
var _notice_box:Control
const HudStyle=preload("res://scripts/hud_style.gd")
## Line pitch: the capitals' 6 px of ink and a 4 px gap.
const NOTICE_LINE:=10
var _notice_fade:Tween

## "loading" when a player connects, "joined" once their world has loaded and
## they are standing in it, "left" when they go.
## "away"/"back" when the host leaves the app and returns, "hosting" to the
## host itself on a phone. "restart"/"stop" (seconds left) and their "_cancel"
## come from a dedicated server's countdown.
const NOTICE_TEXT:={"loading":"%s is loading in...","joined":"%s joined the game.","left":"%s left the game.",
    "away":"%s left the app. Waiting...","back":"%s is back.",
    "hosting":"Keep the app open while you host.\nPlug in the charger.",
    "restart":"Server restarting in %s s","stop":"Server shutting down in %s s",
    "restart_cancel":"Server restart cancelled.","stop_cancel":"Server shutdown cancelled."}
var _notice_loading:Dictionary={}

func _player_notice(peer:int,player:String,event:String)->void:
    if not hosting:return
    if event=="loading":_notice_names[peer]=player;_notice_loading[peer]=true
    elif event=="joined":
        if not _notice_loading.has(peer):return
        _notice_loading.erase(peer);player=String(_notice_names.get(peer,""))
    else:
        player=String(_notice_names.get(peer,""));_notice_names.erase(peer);_notice_loading.erase(peer)
    if player.is_empty():return
    for other in session.players:
        if other!=1 and other!=peer:session.send_to(other,{"kind":"player_notice","name":player,"event":event})
    show_notice(player,event)

func show_notice(player:String,event:String)->void:
    if not NOTICE_TEXT.has(event):return
    if not is_instance_valid(_notice_label):
        _notice_box=HudStyle.chip(chat.hud,"OnlineNotice");_notice_box.z_index=340
        _notice_label=_notice_box.get_node("Text")
        _notice_label.add_theme_constant_override("line_spacing",NOTICE_LINE-roundi(HudStyle.FONT.get_height(HudStyle.FONT_SIZE)))
    var text:=String(NOTICE_TEXT[event]).replace("%s",player.strip_edges().left(24).to_upper())
    if not Server.active:print("ONLINE notice: ",text.replace("\n"," ")) # the server says it its own way
    # Wrapped and centred as the newest chat message (coop_chat.gd), which goes under it.
    chat.fit(_notice_box,text,chat.room(),NOTICE_LINE)
    _notice_box.position=Vector2(roundf(chat.centre()-_notice_box.size.x/2.0),main.touch_controls.usable_rect.position.y+HudStyle.MARGIN+float(main.status_hud.row_height())+HudStyle.GAP)
    _notice_box.modulate.a=1.0;_notice_box.visible=true
    if _notice_fade!=null and _notice_fade.is_valid():_notice_fade.kill()
    _notice_fade=create_tween();_notice_fade.set_speed_scale(1.0/maxf(Engine.time_scale,0.01))
    _notice_fade.tween_interval(4.0)
    _notice_fade.tween_property(_notice_box,"modulate:a",0.0,1.0)

## Host: players sent the records on being let in who have not entered yet.
var _join_records_sent:Dictionary={}

func _admitted(peer:int,actor:String,profile:Dictionary)->void:
    state.enroll(actor,profile)
    _join_sequence+=1;_joined_at[peer]=_join_sequence
    _player_notice(peer,String(profile.get("name","PLAYER")),"loading")
    while _publishing:
        await get_tree().process_frame
        if not session.players.has(peer):return
    if not await publish_current():session.transport._drop(peer);return
    var data:Dictionary=main._capture_game_save()
    # A new guest starts with their own party and inventory, never the host's.
    var personal:Dictionary=state.records.get("player/"+actor,{})
    var saved_personal:Dictionary=personal.get("save",{})
    var destination=_area()
    if not saved_personal.is_empty():
        var saved_area="%d,%d"%[int(saved_personal.get("world_grid_x",0)),int(saved_personal.get("world_grid_y",0))]
        if state.records.has("area/"+saved_area):
            data=saved_personal.duplicate(true);destination=saved_area
    data["caught_pokemon"]=personal.get("party",[main._make_starter_machop()])
    data["inventory"]=personal.get("inventory",main.STARTING_INVENTORY.duplicate(true))
    data["pokemon_storage"]={}
    data["preferred_storage_box"]=String(saved_personal.get("preferred_storage_box",""))
    data["coop_respawn"]=saved_personal.get("coop_respawn",{}).duplicate(true)
    if saved_personal.is_empty():
        data["pokedex"]={};data["pokedex_shiny"]={};data["waypoints"]={}
    data["adjacent_worlds"]={};data["crafting_state"]={}
    data["player_name"]=profile.get("name","PLAYER");data["player_name_custom"]=true
    data["player_model"]=profile.get("model",0);data["player_color"]=profile.get("color",0)
    # Spawn beside the host in the same scene; shared crafting arrives separately.
    data["coop_personal"]=saved_personal.get("crafting_state",Snapshot.split(main.world.get_crafting_save_state()).personal).duplicate(true)
    data.coop_personal.erase("follower_pokemon");data.coop_personal.erase("active_field_move");data.coop_personal.erase("active_field_pokemon")
    if personal.is_empty():
        personal={"party":data.caught_pokemon,"inventory":data.inventory,"save":{}}
        var enrolled=state.transact(actor,"enroll/"+_id(),[state.change("player/"+actor,personal)])
        if not enrolled.get("ok",false):session.transport._drop(peer);return
    await _send_state(peer,actor)
    _join_records_sent[peer]=true
    var error:Error=session.send_to(peer,{"kind":"game_begin","area":destination,"game":data,"profile_base":state.print_of("player/"+actor,{})})
    if error!=OK:session.transport._drop(peer)

func _message(_peer:int,actor:String,packet:Dictionary)->void:
    if chat.message(_peer,actor,packet):return
    if hosting:
        if packet.get("kind")=="area_flush_result" and packet.get("id") is String and packet.get("ok") is bool:
            _area_flushes[packet.id]=packet.ok;return
        if packet.get("kind")=="storage_open" and packet.get("id") is String:
            var area=String(state.members.get(actor,{}).get("area",""))
            var success=not area.is_empty() and await _flush_area(area)
            if success:await _send_state(_peer,actor)
            session.send_to(_peer,{"kind":"command_result","id":packet.id,"result":{"ok":success}});return
        if packet.get("kind")=="profile_checkpoint":_checkpoint_request(_peer,actor,packet);return
        if packet.get("kind")=="state_request":_send_state(_peer,actor);return
        # Going to another area: its records first (area_service.gd then sends the area).
        if packet.get("kind")=="area_request" and packet.get("area") is String:
            if preload("res://scripts/coop_areas.gd").valid_area(packet.area) and not packet.area in _watched(actor):_send_state(_peer,actor,packet.area)
            return
        if packet.get("kind")=="entered" and packet.get("area") is String:
            _player_notice(_peer,"","joined")
            var entry=service.areas.enter(actor,packet.area)
            # A player arriving from another area is sent the records again
            # (theirs and this area's: some, like those made with the area,
            # are not sent as changes). One who is joining had them on being
            # let in: sending them twice was a second ~60 KB on every join.
            # An area that was already made when they asked to go there is up
            # to date with them since: it is not sent a second time.
            var joining:bool=_join_records_sent.erase(_peer)
            var going:Array=_travelling.get(actor,["",false])
            _travelling.erase(actor)
            if entry.get("ok",false) and not joining:await _send_state(_peer,actor,"",String(going[0]) if going[0]==packet.area and going[1] else "")
            session.send_to(_peer,{"kind":"entered_reply","entry":entry})
            _broadcast_authority()
        return
    if packet.get("kind")=="area_authorities" and packet.get("owners") is Dictionary and packet.get("epochs") is Dictionary:
        area_authority=String(packet.owners.get(_area(),""));area_epoch=int(packet.epochs.get(_area(),0));return
    if packet.get("kind")=="area_flush" and packet.get("id") is String:
        while _publishing:await get_tree().process_frame
        var saved=packet.get("area")==_area() and await publish_current()
        session.send_host({"kind":"area_flush_result","id":packet.id,"ok":saved});return
    if packet.get("kind")=="entered_reply" and packet.get("entry") is Dictionary:
        _entry_reply=packet.entry
        if _entry_reply.get("ok",false):area_authority=String(_entry_reply.authority);area_epoch=int(_entry_reply.epoch)
        return
    if packet.get("kind")=="area_generate" and packet.get("area")==_travel_target and packet.get("token") is String:
        _travel_token=packet.token;_travel_offer={"new":true};return
    if packet.get("kind") in ["command_result","profile_result"] and packet.get("id") is String and packet.get("result") is Dictionary:
        if packet.kind=="profile_result":_checkpoint_done(packet.id,packet.result)
        _replies[packet.id]=packet.result
        _answered.emit.call_deferred()
        return
    if packet.get("kind")=="player_notice":
        if packet.get("name") is String and packet.get("event") is String and main.started:show_notice(packet.name,packet.event)
        return
    # A dedicated server about to restart or stop (dedicated_server.gd), once a second.
    if packet.get("kind")=="server_countdown":
        if packet.get("action") in ["restart","stop"] and main.started:
            if packet.get("cancel")==true:show_notice("",String(packet.action)+"_cancel")
            elif packet.get("seconds") is float or packet.get("seconds") is int:show_notice(str(clampi(int(packet.seconds),0,3600)),String(packet.action))
        return
    if packet.get("kind")=="world_clock":
        var seconds=packet.get("seconds");var speed=packet.get("speed")
        if (seconds is float or seconds is int) and (speed is float or speed is int) and is_finite(float(seconds)) and float(seconds)>=0 and float(speed)>0 and float(speed)<=4:
            clock_seconds=float(seconds);clock_speed=float(speed);_clock_received=Time.get_ticks_msec()
        return
    if packet.get("kind")=="shared_commit" and packet.get("result") is Dictionary:
        _apply_visible(packet.result);return
    if packet.get("kind")=="interaction_update" and packet.get("result") is Dictionary:
        interaction_ui.update(packet.result);return
    # The area this player is going to, as it is now (_send_state `going`).
    if packet.get("kind")=="area_records" and packet.get("area") is String and packet.get("records") is Dictionary:
        for key in shared_records.keys():
            if _key_area(String(key))==packet.area and _shared_key(String(key),session.actor):shared_records.erase(key)
        for key in packet.records:
            if _key_area(String(key))==packet.area and _shared_key(String(key),session.actor):shared_records[key]=packet.records[key]
        shared_epoch+=1
        return
    if packet.get("kind")=="state_snapshot" and packet.get("records") is Dictionary:
        _awaiting_state=false
        events.results_dirty=true
        # The area this player was just sent (area_records) and kept up to date with stays.
        var kept:=String(packet.get("kept","")) if packet.get("kept") is String else ""
        for key in shared_records.keys():
            if _shared_key(String(key),session.actor) and (kept.is_empty() or _key_area(String(key))!=kept):shared_records.erase(key)
        for key in packet.records:
            if _shared_key(String(key),session.actor):shared_records[key]=packet.records[key]
        shared_epoch+=1
        _refresh_drops();storage.refresh();return
    if packet.get("kind")!="game_begin" or not packet.get("game") is Dictionary or not packet.get("area") is String:return
    if main.started or not _loading:return
    _guest_game=packet.game
    profile_base=String(packet.get("profile_base",""))
    session.send_host({"kind":"area_request","area":packet.area})

func _broadcast_authority()->void:
    if not hosting or not is_instance_valid(service):return
    area_authority=String(state.authority.get(_area(),""));area_epoch=int(service.areas.epochs.get(_area(),0))
    for peer in session.players:
        if peer!=1:session.send_to(peer,{"kind":"area_authorities","owners":state.authority,"epochs":service.areas.epochs})

func _shared_key(key:String,actor:String)->bool:
    return events.shared_key(key) or key=="settings" or key.begins_with("boss/") or key.begins_with("raid/") or key.begins_with("horde/") or key.begins_with("horde_reward/"+actor+"/") or wild.shared_key(key) or population.shared_key(key) or building.is_build_key(key) or key.begins_with("beacon/") or key.begins_with("drop/") or key.begins_with("box/") or key.begins_with("chest/") or key=="private_box/"+actor

## The records `actor` holds: those every player holds and those of the areas
## they watch (_watched), but for those of `kept`, which they hold already.
## With `going` (an area they have asked to go to) only that area's, which
## they then watch too, so it arrives as it is now.
func _send_state(peer:int,actor:String,going:String="",kept:String="")->void:
    var deadline=Time.get_ticks_msec()+10000
    while session.players.has(peer) and Time.get_ticks_msec()<deadline:
        # Rebuild after backpressure: no await between capture and enqueue, so later
        # commits always follow this complete snapshot in the ordered connection.
        var areas:=_watched(actor) if going.is_empty() else [going]
        var records:Dictionary={}
        for key in state.records:
            if _shared_key(String(key),actor):
                var area:=_key_area(String(key))
                if ((area.is_empty() and going.is_empty()) or area in areas) and (kept.is_empty() or area!=kept):records[key]=state.records[key]
        var packet:={"kind":"state_snapshot","records":records,"kept":kept}
        if not going.is_empty():packet={"kind":"area_records","area":going,"records":records}
        var error:Error=session.send_to(peer,packet)
        if error==OK:
            if not going.is_empty():_travelling[actor]=[going,state.records.has("area/"+going)]
            return
        if error!=ERR_BUSY:session.transport._drop(peer);return
        await get_tree().process_frame
    if session.players.has(peer):session.transport._drop(peer)

func _area_ready(actor:String,_area_name:String,_metadata:Dictionary,bytes:PackedByteArray)->void:
    if actor==session.actor and not _travel_target.is_empty() and _area_name==_travel_target:
        var arrived=Snapshot.decode(bytes)
        if arrived.is_empty() or not _install_cache(arrived):_travel_offer={"error":"ONLINE AREA COULD NOT LOAD"};return
        _travel_offer={"seed":arrived.seed,"size":arrived["size"],"state":Snapshot.merge(wild.overlay(_area_name,population.overlay(_area_name,building.overlay(_area_name,arrived.shared,state.records if hosting else shared_records),state.records if hosting else shared_records),state.records if hosting else shared_records),_arrival_personal(_area_name))}
        return
    if hosting or actor!=session.actor or _guest_game.is_empty():return
    var decoded=Snapshot.decode(bytes)
    if decoded.is_empty():_failure("ONLINE AREA COULD NOT LOAD");return
    var path=Cache.cache_path(decoded.seed,decoded["size"])
    if DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))!=OK:_failure("ONLINE CACHE COULD NOT SAVE");return
    var file=FileAccess.open(path+".pending",FileAccess.WRITE)
    if file==null:_failure("ONLINE CACHE COULD NOT SAVE");return
    file.store_buffer(decoded.cache);file.flush();var error=file.get_error();file.close()
    if error!=OK or DirAccess.rename_absolute(path+".pending",path)!=OK:_failure("ONLINE CACHE COULD NOT SAVE");return
    pending_game=_guest_game;_guest_game={}
    pending_game["crafting_state"]=Snapshot.merge(wild.overlay(_area_name,population.overlay(_area_name,building.overlay(_area_name,decoded.shared,shared_records),shared_records),shared_records),pending_game.get("coop_personal",{}))
    pending_game.erase("coop_personal")
    main.coop_menu.close();main.selected_mode="LOAD";main.setup_load_committed=true
    session.set_loading(true)
    await get_tree().process_frame
    await main._start_game()

func _failure(reason:String)->void:
    main.menu_status.text=reason.to_upper()
    # Refused after being let in, whether still loading or already playing:
    # the host removed this player. Leave the world and say why.
    if active and not hosting and session.trusted:end_session(reason.to_upper());return
    if is_instance_valid(main.coop_menu) and main.coop_menu.visible:
        if main.coop_menu.page=="connecting":main.coop_menu.connecting_failed(reason.to_upper())
        else:main.coop_menu.status.text=reason.to_upper()
    if not main.started:
        preload("res://scripts/crafting_data.gd").online_enabled=false
        session.transport.stop();active=false;hosting=false;_loading=false;Cache.online_namespace=""
        lobby.stop_advertise();Network.host_close();Network.join_close()

## Phones suspend a game in the background (iOS as soon as the player leaves
## the app). The others then wait for it as for a player loading an area
## (LOADING_TIMEOUT_MS in coop_transport.gd) instead of dropping it after 20 s
## of silence; everything queued goes out first, as _process stops here.
func _notification(what:int)->void:
    if not active or session==null or not session.trusted:return
    if what not in [NOTIFICATION_APPLICATION_PAUSED,NOTIFICATION_APPLICATION_RESUMED]:return
    var away:=what==NOTIFICATION_APPLICATION_PAUSED
    # Coming back, _process clears it once no area is loading.
    if away:session.set_loading(true)
    if hosting:
        for peer in session.players:
            if peer!=1:session.send_to(peer,{"kind":"player_notice","name":String(session.profile.get("name","HOST")),"event":"away" if away else "back"})
        if not away and OS.has_feature("mobile"):show_notice("","hosting")
    if away:session.transport.flush()

func _exit_tree()->void:
    if _area_cleanup!=null:_area_cleanup.wait_to_finish();_area_cleanup=null
    Network.host_close();Network.join_close()
