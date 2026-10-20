extends Node
## Live transport adapter for source-created wild records and reservations.
const Population=preload("res://scripts/coop_wild_population.gd")
const Delta=preload("res://scripts/coop_world_delta.gd")
var game:Node
var applying:=false
var pending_additions:Dictionary={}
var pending_area:=""
var sync_pending:=false
var namespace_id:=0
var next_sequence:=1
var pending_spawns:Array=[]
var publishing_spawn:=false
var encounter:Dictionary={}
var encounter_pending:=false
var finishing:=false
var original_profile:Dictionary={}
var simulating:=false
var motion_busy:=false
var last_motion:=0
var players:Dictionary={}
var motion_dirty:Dictionary={}
var _whole_motion:=false
const Server=preload("res://scripts/dedicated_server.gd")
## For idle_frame: where the players who can be chased stand, and whether one
## of them could charm a wild Pokemon. Made with `players`.
var _chased_cells:Array=[]
var _charm_near:=false

func mark_motion(wild_id:int)->void:
    motion_dirty[wild_id]=true

static func motion_stamp(data:Dictionary)->Array:
    return [] if data.is_empty() else [data.cell,String(data.get("coop_target","")),bool(data.get("aggro_player",false)),int(data.get("flee_steps",0))]

func authority()->bool:
    return game.active and game.area_authority==game.session.actor

func refresh_players()->void:
    players.clear()
    for actor in game.visuals.last_packets:
        var packet:Dictionary=game.visuals.last_packets[actor]
        if packet.get("area")!=game._area() or packet.get("layer")!="OVERWORLD":continue
        players[actor]={"area":game._area()+"|OVERWORLD","x":int(packet.cell_x),"y":int(packet.cell_y),"battle":bool(packet.get("battle",false)),"move":String(packet.visual.get("move",""))}
        players[actor]["field_level"]=int(packet.get("field_level",1))
        players[actor]["party_level"]=int(packet.get("party_level",1))
    # A dedicated server's own player is not there to be chased or bumped into.
    if game.main.world.active_area_id=="OVERWORLD" and not Server.active:
        var cell:Vector2i=game.main.world._player_cell()
        players[game.session.actor]={"area":game._area()+"|OVERWORLD","x":cell.x,"y":cell.y,"battle":game.main.battle_active or game.main.battle_entry_pending,"move":game.main.world.active_field_move}
    else:players.erase(game.session.actor)
    _chased_cells.clear();_charm_near=false
    for player in players.values():
        if player.battle:continue
        _chased_cells.append(Vector2i(player.x,player.y))
        if player.move=="CHARM":_charm_near=true

## Tests turn idle_frame off to compare with the full update.
static var idle_frames:=true

## Dedicated server: true when a wild Pokemon's update this frame
## (world._update_wild_pokemon) would change nothing but its move timer, which
## is counted down here exactly as there, and the look of the server's own
## sprite for it, which nobody sees. That is a calm one in play near every
## player who could chase it, that nothing can charm, frighten or set on
## anyone, and whose timer does not run out this frame. Every other frame,
## and any other Pokemon, gets the full update, so records, saves and the
## random numbers drawn are the same. Most of a server's frames were these.
func idle_frame(data:Dictionary,delta:float)->bool:
    if not idle_frames or not Server.active or _chased_cells.is_empty() or _charm_near:return false
    if bool(data.get("aggro_player",false)) or not data.has("charmed") or bool(data.charmed) or not data.has("coop_target") or not String(data.coop_target).is_empty():return false
    if not String(data.get("source_record",{}).get("coop_horde","")).is_empty():return false
    var now:float=game.main.world.world_elapsed_seconds
    if now<float(data.get("ball_flee_until",0.0)) or float(data.get("ball_charm_until",0.0))>now:return false
    var cell:Vector2i=data.get("cell",Vector2i.ZERO)
    var reach:int=game.main.world.ECOLOGY_ACTIVE_RADIUS
    for at in _chased_cells:
        if absi(cell.x-at.x)>reach or absi(cell.y-at.y)>reach:return false
    var left:=float(data.get("move_timer",0.0))-delta
    if left<=0.0:return false
    data["move_timer"]=left
    return true

func target_for(data:Dictionary,cell:Vector2i)->Dictionary:
    var scope=game._area()+"|OVERWORLD"
    var eligible=players
    if not String(data.get("source_record",{}).get("coop_horde","")).is_empty():
        eligible=players.duplicate()
        for actor in eligible.keys():
            if game.hordes.safe(Vector2i(eligible[actor].x,eligible[actor].y)):eligible.erase(actor)
    var target=""
    if data.get("aggro_player",false):target=Population.chase_target(String(data.get("coop_target","")),cell,eligible,scope)
    if String(data.get("coop_target",""))!=target:mark_motion(int(data.id))
    data["coop_target"]=target
    if target.is_empty():target=Population.chase_target("",cell,eligible,scope,2147483647)
    if target.is_empty():return {}
    players[target]["actor"]=target
    return players[target]

func occupied(cell:Vector2i)->bool:
    for player in players.values():
        if cell==Vector2i(player.x,player.y):return true
    return false

func remote_charm(data:Dictionary,target:Dictionary)->bool:
    if float(data.get("ball_charm_until",0.0))>game.main.world.world_elapsed_seconds:return true
    if target.get("move")!="CHARM":return false
    var reference=int(target.get("party_level",1))
    var level=clampi(maxi(1,int(data.get("level",1))),maxi(2,reference-3),mini(100,reference+1))
    return int(target.get("field_level",1))>=level

func publish_motion()->void:
    var records:Dictionary=game.state.records if game.hosting else game.shared_records
    var world=game.main.world
    var patches:Array=[]
    var sent:Dictionary={}
    for wild_id in motion_dirty.keys():
        var key=Population.record_key(game._area(),wild_id)
        if records.has(Population.claim_key(game._area(),wild_id)):
            motion_dirty.erase(wild_id);continue
        if not records.has(key):
            if not pending_spawns.any(func(entry):return int(entry.id)==int(wild_id)):motion_dirty.erase(wild_id)
            continue
        var data:Dictionary=world.wild_pokemon.get(wild_id,{})
        if data.get("ball_reserved",false):continue
        var next:Variant=null if data.is_empty() else world._serializable_ecology_record(data,data.cell)
        var encoded=Delta.encode(next)
        if encoded==records[key]:motion_dirty.erase(wild_id);continue
        # The host has the stored record's fingerprint already worked out.
        var patch:Dictionary={"key":"wild_pokemon/"+str(wild_id),"before":game.state.print_of(key) if game.hosting else game.state.fingerprint(records[key])}
        # From a guest, only what changed in the record (coop_world_delta.gd).
        var delta:Variant=null if game.hosting or _whole_motion else Delta.entry_delta(records[key],encoded)
        if delta==null:patch["after"]=encoded
        else:patch["delta"]=delta;patch["print"]=game.state.fingerprint(encoded)
        patches.append(patch)
        sent[wild_id]=motion_stamp(data)
        if patches.size()>=64:break
    if patches.is_empty():return
    motion_busy=true
    var result:Dictionary=await game.command("wild_motion",{"area":game._area(),"epoch":game.area_epoch,"patches":patches})
    motion_busy=false
    # After a refusal the next try sends whole records, in case the edits
    # were what did not fit.
    _whole_motion=not result.get("ok",false)
    if result.get("ok",false):
        for wild_id in sent:
            var data:Dictionary=world.wild_pokemon.get(wild_id,{})
            var current=motion_stamp(data)
            if current==sent[wild_id]:motion_dirty.erase(wild_id)
    if result.get("reason")=="save_failed":game.end_session("POKEMON MOVEMENT COULD NOT BE SAVED.")

## The Pokemon near enough to touch this player soon, in the world's order.
## Walking every wild Pokemon each frame to find the one or two beside the
## player cost about 0.1 ms a frame on every device; the short list is made
## again four times a second, or at once when the player or the herd changes.
const CONTACT_REACH:=12
const CONTACT_REFRESH_MS:=250
var _contact_ids:Array=[]
var _contact_at:=-CONTACT_REFRESH_MS
var _contact_cell:=Vector2i(-999999,-999999)
var _contact_herd:Dictionary={}
var _contact_size:=-1

func _contact_candidates(world:Node)->Array:
    var here:Vector2i=world._player_cell()
    var now:=Time.get_ticks_msec()
    if now-_contact_at>=CONTACT_REFRESH_MS or not is_same(_contact_herd,world.wild_pokemon) or _contact_size!=world.wild_pokemon.size() or maxi(absi(here.x-_contact_cell.x),absi(here.y-_contact_cell.y))>2:
        _contact_at=now;_contact_cell=here;_contact_herd=world.wild_pokemon;_contact_size=world.wild_pokemon.size()
        _contact_ids.clear()
        for wild_id in world.wild_pokemon:
            var at:Vector2i=world.wild_pokemon[wild_id].get("cell",_contact_cell+Vector2i(CONTACT_REACH*4,0))
            if maxi(absi(at.x-here.x),absi(at.y-here.y))<=CONTACT_REACH:_contact_ids.append(wild_id)
    return _contact_ids

func contact()->void:
    var world=game.main.world
    if not world.gameplay_enabled or game.main.battle_active or game.main.battle_entry_pending or encounter_pending or not encounter.is_empty() or world.active_area_id!="OVERWORLD" or world.active_field_move in ["FLY","SURF"] or world.encounter_grace_active():return
    for wild_id in _contact_candidates(world):
        if not world.wild_pokemon.has(wild_id):continue
        var data:Dictionary=world.wild_pokemon[wild_id]
        if data.get("coop_target")!=game.session.actor or not data.get("aggro_player",false) or data.get("ball_reserved",false):continue
        if world._player_cell().distance_squared_to(data.cell)>1 or world._repel_blocks(int(data.level)) or world._charm_suppresses(data):continue
        begin_encounter(wild_id,false);return

var claiming_id:=-1

func reserve(wild_id:int,field_attack:bool=false)->bool:
    if encounter_pending or not encounter.is_empty() or game.main.battle_active:return false
    var world=game.main.world
    if not world.wild_pokemon.has(wild_id):return false
    var data:Dictionary=world.wild_pokemon[wild_id]
    if data.get("ball_reserved",false):return false
    var was_enabled:bool=world.gameplay_enabled
    world.set_gameplay_enabled(false)
    encounter_pending=true;claiming_id=wild_id
    data["ball_reserved"]=true
    var area=game._area()
    var result:Dictionary=await game.command("wild_claim",{"area":area,"wild_id":wild_id})
    encounter_pending=false;claiming_id=-1
    data.erase("ball_reserved")
    if not result.get("ok",false) or not game.active:
        if game.active:world.set_gameplay_enabled(was_enabled and not game.main._field_ui_blocks_gameplay(game.main.build_menu_open))
        return false
    if game._area()!=area or game.main.battle_active:
        await game.command("wild_release",{"area":area,"wild_id":wild_id});return false
    original_profile=game._personal_profile().duplicate(true)
    encounter={"area":area,"wild_id":wild_id,"field_attack":field_attack}
    return true

func begin_encounter(wild_id:int,field_attack:bool)->void:
    if game.main.world.active_field_move=="FLY":return
    if not await reserve(wild_id,field_attack):return
    applying=true
    game.main.world._begin_wild_encounter(wild_id,field_attack)
    applying=false
    if not game.main.battle_active and not game.main.battle_entry_pending:
        var area=String(encounter.area)
        encounter.clear();original_profile.clear()
        await game.command("wild_release",{"area":area,"wild_id":wild_id})

func finish_encounter(outcome:String,aftermath:Dictionary={})->bool:
    if encounter.is_empty():return true
    while game._request_busy:
        await get_tree().process_frame
        if not game.active:return false
    finishing=true
    var profile:Dictionary=game._personal_profile()
    var sent_pending:Array=profile.save.get("coop_pending_pokemon",[]).duplicate(true)
    var result:Dictionary=await game.command("wild_finish",{"area":encounter.area,"wild_id":encounter.wild_id,"outcome":outcome,"calm":bool(encounter.field_attack),"profile":profile,"base":game.profile_base,"aftermath":aftermath})
    if not result.get("ok",false):
        finishing=false;game.end_session("ENCOUNTER RESULT COULD NOT BE SAVED.");return false
    game.storage.settle(sent_pending,result.get("pending",[]))
    game.profile_base=String(result.get("base",game.profile_base))
    encounter.clear();original_profile.clear();finishing=false
    return true

func resolve(actor:String,id:String,args:Dictionary)->Dictionary:
    var expected=game.state.fingerprint([args])
    var previous:Dictionary=game.state.outcomes.get(actor+"/wildcomplete/"+id,{})
    if not previous.is_empty():
        if previous.get("command_hash")!=expected:return {"ok":false,"reason":"reused_request_id"}
        var current:Dictionary=game.state.records.get("player/"+actor,{})
        return {"ok":true,"base":game.state.print_of("player/"+actor,{}),"pending":current.get("save",{}).get("coop_pending_pokemon",[])}
    if args.base!=game.state.print_of("player/"+actor,{}):return {"ok":false,"reason":"profile_changed"}
    var profile:Dictionary=args.profile.duplicate(true)
    var changes:Array=game.storage.profile_changes(actor,profile)
    var claim:Dictionary=game.state.records.get(Population.claim_key(args.area,int(args.wild_id)),{})
    var original=Delta.decode(String(claim.get("record",Delta.encode(null))))
    if args.outcome in ["defeated","captured"] and original is Dictionary:
        changes.append_array(game.hordes.model().defeat_changes(args.area,int(args.wild_id),original))
    if args.outcome=="captured" and original is Dictionary:
        var species=String(original.get("source_record",{}).get("rare_legendary",""))
        if preload("res://scripts/rare_biome_legendaries.gd").HABITATS.has(species):
            var key="world/"+args.area+"/event_progress/rare_legendaries_captured"
            var history=Delta.decode(game.state.records.get(key,Delta.encode({})))
            if not history is Dictionary:history={}
            history[species]=true
            changes.append(game.state.change(key,Delta.encode(history)))
    var restored:Variant=null
    if args.outcome=="ran":
        restored=original
        if restored is Dictionary and args.calm:
            restored["aggro_player"]=false;restored["warned"]=false;restored["charmed"]=false
    if args.outcome=="whiteout" and original is Dictionary and not String(original.get("source_record",{}).get("coop_horde","")).is_empty():restored=original
    if restored is Dictionary:
        for key in args.get("aftermath",{}):restored[key]=args.aftermath[key]
        var horde_id=String(restored.get("source_record",{}).get("coop_horde",""))
        if not horde_id.is_empty():
            var horde:Dictionary=game.state.records.get("horde/"+args.area,{})
            if horde.get("id")!=horde_id or horde.get("phase") not in ["waiting","active"]:restored=null
    var result:Dictionary=model().complete(actor,id,args.area,int(args.wild_id),changes,restored,[args])
    if result.get("ok",false):
        result["base"]=game.state.print_of("player/"+actor,{})
        result["pending"]=profile.save.get("coop_pending_pokemon",[])
    return result

func initialize_ids()->bool:
    # Another request may be in flight at this instant (night events, hordes, a
    # checkpoint). "busy" means wait, not that hosting or joining has failed.
    var result:Dictionary={}
    # A joining player also keeps asking while the link is up and the host has
    # simply not answered yet. A host busy sending a large world could take
    # longer than one request waits, and the join was abandoned at the last
    # step after minutes of loading.
    var deadline:=Time.get_ticks_msec()+(15000 if game.hosting else 60000)
    while true:
        result=await game.command("wild_namespace",{})
        var reason:=String(result.get("reason",""))
        var waiting:bool=reason=="busy" or (reason=="disconnected" and not game.hosting and game.session.trusted)
        if result.get("ok",false) or not waiting or Time.get_ticks_msec()>deadline:break
        await game.get_tree().process_frame
    if not result.get("ok",false):
        print("ONLINE start failed at wild ids: ",result.get("reason","unknown"))
        return false
    namespace_id=int(result.namespace);next_sequence=1
    var records:Dictionary=game.state.records if game.hosting else game.shared_records
    for key in records:
        if String(key).begins_with("world/") and String(key).get_slice("/",2)=="wild_pokemon":
            var used=int(String(key).get_slice("/",3))
            if used/4294967296==namespace_id:next_sequence=maxi(next_sequence,used%4294967296+1)
    return true

func source_spawn_enabled()->bool:
    return game.active and game.main.started and not game.main.generating and not game.main.edge_travel_busy and not applying and not game.main.world.restoring_saved_tiles

func allocate_id()->int:
    if namespace_id<1 or next_sequence>=4294967296:return 0
    var result=namespace_id*4294967296+next_sequence
    next_sequence+=1
    return result

func source_added(wild_id:int)->void:
    var world=game.main.world
    if not world.wild_pokemon.has(wild_id):return
    var data:Dictionary=world.wild_pokemon[wild_id]
    var record:Dictionary=world._serializable_ecology_record(data,data.cell)
    record["id"]=wild_id
    data["ball_reserved"]=true
    pending_spawns.append({"area":game._area(),"record":Delta.encode(record),"id":wild_id})

func publish_spawn()->void:
    publishing_spawn=true
    var pending:Dictionary=pending_spawns[0]
    var result:Dictionary=await game.command("wild_spawn",{"area":pending.area,"record":pending.record})
    publishing_spawn=false
    if result.get("reason")=="busy":return
    pending_spawns.pop_front()
    if not game.active:return
    if result.get("ok",false):
        var data:Dictionary=game.main.world.wild_pokemon.get(pending.id,{})
        data.erase("ball_reserved")
    elif result.get("reason") in ["already_present","wrong_area","horde_ended"]:
        if game._area()==pending.area:remove_record(pending.id)
    else:game.end_session("NEW ENCOUNTER COULD NOT BE SAVED.")

func request_sync()->void:
    motion_dirty.clear()
    sync_pending=true

func configure(coordinator:Node)->void:
    game=coordinator
    game.session.departed.connect(_departed)

func _departed(_peer:int,actor:String)->void:
    if not game.hosting or not game.active:return
    var result:Dictionary=model().abandon(game.session.actor,game._id(),actor)
    if not result.get("ok",false):game.end_session("ENCOUNTER STATE COULD NOT BE SAVED.")
    elif result.has("changes"):game._committed(result)

func recover()->bool:
    # A newly opened host session cannot still have a player in an old battle.
    return bool(model().abandon(game.session.actor,game._id()).get("ok",false))

static func overlay(area:String,shared:Dictionary,records:Dictionary)->Dictionary:
    var flat=Delta.flatten(shared)
    var prefix="world/"+area+"/wild_pokemon/"
    for key in records:
        if String(key).begins_with(prefix) or (String(key).begins_with("world/"+area+"/event_progress/") and String(key).get_slice("/",3) in ["rare_legendaries_captured","biome_megas","mega_gengar_forest"]):flat[String(key).trim_prefix("world/"+area+"/")]=records[key]
    return Delta.inflate(flat,shared)

func _process(_delta:float)->void:
    if not game.active or not game.main.started:return
    if not pending_spawns.is_empty() and not publishing_spawn:publish_spawn()
    if game.main.generating or game.main.edge_travel_busy:return
    if sync_pending:
        sync_pending=false
        synchronize()
    var world=game.main.world
    var simulate:bool=authority() and world.is_processing() and (not world.gameplay_enabled or world.active_area_id!="OVERWORLD")
    # world._update_wild_pokemon makes the list itself first.
    if not simulate:refresh_players()
    if authority() and world.is_processing():
        if simulate:
            simulating=true;world._update_wild_pokemon(_delta);simulating=false
        if not motion_busy and Time.get_ticks_msec()-last_motion>=100:
            last_motion=Time.get_ticks_msec();publish_motion()
    if world.gameplay_enabled and world.active_area_id=="OVERWORLD" and world.is_processing():
        var listener:Vector2i=world._player_cell()
        # Pursuit sounds carry 7.5 tiles; only Pokemon near this player are asked.
        for near_id in world.nearby_wild_ids():
            var data=world.wild_pokemon.get(near_id)
            if data!=null and not data.get("ball_reserved",false):world._update_source_aggro_audio(data,data.cell,listener,_delta)
    contact()
    if pending_additions.is_empty():return
    if pending_area!=game._area():pending_additions.clear();return
    applying=true;retry_additions();applying=false

func model():
    var value=Population.new();value.state=game.state
    value.presence=game.commands.presence
    value.can_publish=game.service.areas.can_publish if is_instance_valid(game.service) else Callable()
    return value

static func shared_key(key:String)->bool:
    return key.begins_with("wild_claim/") or key.begins_with("wild_namespace/") or (key.begins_with("world/") and (key.get_slice("/",2)=="wild_pokemon" or key.ends_with("/event_progress/rare_legendaries_captured")))

func execute(actor:String,id:String,operation:String,args:Dictionary)->Dictionary:
    var value=model()
    match operation:
        "wild_namespace":
            var namespace_id:int=value.namespace_for(actor)
            return {"ok":namespace_id>0,"namespace":namespace_id}
        "wild_spawn":
            var record=Delta.decode(args.record)
            if not record is Dictionary:return {"ok":false,"reason":"invalid_record"}
            return value.register(actor,id,args.area,record)
        "wild_motion":return value.motion(actor,id,args.area,int(args.epoch),args.patches)
        "wild_claim":return value.claim(actor,id,args.area,int(args.wild_id))
        "wild_release":return value.release(actor,id,args.area,int(args.wild_id))
        "wild_finish":return resolve(actor,id,args)
    return {"ok":false,"reason":"invalid_command"}

func committed(changes:Array,source_actor:String="",request_id:String="")->void:
    if not game.main.started or game.main.generating or game.main.edge_travel_busy:return
    var area=game._area();var prefix="world/"+area+"/wild_pokemon/"
    if pending_area!=area:pending_additions.clear();pending_area=area
    applying=true
    for change in changes:
        var key=String(change.get("key",""))
        if key.begins_with(prefix):
            var wild_id=int(key.trim_prefix(prefix))
            var record=Delta.decode(String(change.after)) if change.after is String else null
            if source_actor==game.session.actor and (request_id.begins_with("world/") or request_id.begins_with("wildspawn/")) and record is Dictionary and game.main.world.wild_pokemon.has(wild_id):continue
            apply_record(wild_id,record)
        elif key.begins_with("wild_claim/"+area+"/"):
            var wild_id=int(key.get_slice("/",2))
            set_claim(wild_id,change.after is Dictionary,String(change.after.get("actor","")) if change.after is Dictionary else "")
        elif key=="world/"+area+"/event_progress/rare_legendaries_captured":
            var history=Delta.decode(change.after)
            if history is Dictionary:game.main.world.event_progress["rare_legendaries_captured"]=history
    retry_additions()
    applying=false

func apply_record(wild_id:int,record:Variant)->void:
    var world=game.main.world
    if not record is Dictionary:
        pending_additions.erase(wild_id)
        remove_record(wild_id)
        return
    if not world.wild_pokemon.has(wild_id):
        pending_additions[wild_id]=record.duplicate(true)
        return
    var data:Dictionary=world.wild_pokemon[wild_id]
    var before:Vector2i=data.cell
    var target=Vector2i(int(record.x),int(record.y))
    var audio_tick=data.get("aggro_audio_tick",-1.0)
    data.merge(record,true);data["cell"]=target;world._wild_cell_moved(wild_id,target);world._sand_trap_merged(wild_id)
    data["aggro_audio_tick"]=audio_tick
    var sprite=data.get("sprite") as Sprite2D
    if is_instance_valid(sprite) and before!=target:
        var movement=data.get("ball_move_tween") as Tween
        if movement!=null and movement.is_valid():movement.kill()
        if before!=target:world._set_overworld_motion_frame(sprite,world._cardinal_direction(target-before,false),int(data.get("anim_phase",0)))
        sprite.z_index=world._depth_z(target)
        var next=world.create_tween()
        next.set_speed_scale(1.0/maxf(0.01,Engine.time_scale))
        next.tween_property(sprite,"position",world._cell_center(target),0.1).set_trans(Tween.TRANS_LINEAR)
        data["ball_move_tween"]=next
    world._update_pokemon_water_visual(data)

func retry_additions()->void:
    var world=game.main.world
    var deadline=Time.get_ticks_usec()+1500
    for wild_id in pending_additions.keys():
        if Time.get_ticks_usec()>=deadline:break
        var record:Dictionary=pending_additions[wild_id]
        var records:Dictionary=game.state.records if game.hosting else game.shared_records
        if records.has(Population.claim_key(game._area(),wild_id)):
            pending_additions.erase(wild_id);continue
        var cell=Vector2i(int(record.x),int(record.y))
        if world._wild_id_at_cell(cell)>=0:continue
        world._add_wild_pokemon(record.species,int(record.level),cell,String(record.get("home_biome","")),int(wild_id),record.get("source_record",{}),record)
        if world.wild_pokemon.has(wild_id):
            pending_additions.erase(wild_id)

func set_claim(wild_id:int,claimed:bool,owner:String="")->void:
    if claimed and owner==game.session.actor and claiming_id==wild_id:return
    if claimed:
        pending_additions.erase(wild_id)
        remove_record(wild_id)
    else:
        var records:Dictionary=game.state.records if game.hosting else game.shared_records
        apply_record(wild_id,Delta.decode(records.get(Population.record_key(game._area(),wild_id),Delta.encode(null))))

func remove_record(wild_id:int)->void:
    var world=game.main.world
    var data:Dictionary=world.wild_pokemon.get(wild_id,{})
    var movement=data.get("ball_move_tween") as Tween
    if movement!=null and movement.is_valid():movement.kill()
    world._remove_wild_pokemon(wild_id)

func synchronize()->void:
    pending_additions.clear()
    var records:Dictionary=game.state.records if game.hosting else game.shared_records
    var changes:Array=[]
    for key in records:
        if shared_key(String(key)):changes.append({"key":key,"after":records[key]})
    committed(changes)
