extends Node
## Live transport adapter for source-created wild records and reservations.
const Population=preload("res://scripts/coop_wild_population.gd")
const Delta=preload("res://scripts/coop_world_delta.gd")
const BattleSession=preload("res://scripts/battle_session.gd")
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
const Session=preload("res://scripts/coop_session.gd")
## Host: a wild battle's win or catch is taken only when the host's replay of
## its log ends the same way, with no more experience (check_battle); off, the
## replay is only reported. On by default; server.cfg enforce_battles.
var enforce_battles:=true
const Wire=preload("res://scripts/area_state.gd")
const WildPopulation=preload("res://scripts/wild_population.gd")

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

func target_for(data:Dictionary,cell:Vector2i)->Dictionary:
    var before=String(data.get("coop_target",""))
    var target:=Population.target_of(players,game._area()+"|OVERWORLD",data,cell,game.hordes.safe)
    if String(data.get("coop_target",""))!=before:mark_motion(int(data.id))
    return target

## This game's own player, for WildPopulation (its `players`).
func local_actor()->String:
    return game.session.actor

func occupied(cell:Vector2i)->bool:
    return Population.occupied_by(players,cell)

func remote_charm(data:Dictionary,target:Dictionary)->bool:
    return Population.charmed_by(data,target,game.main.world.world_elapsed_seconds)

## The wild Pokemon that changed here, sent to the shared records (wild_motion):
## those WildPopulation marked (moved, added, removed, a new target) and those
## marked here, each once it differs from its record. One that only moved (its
## record otherwise as last sent) goes as 14 bytes of binary motion instead
## (WildPopulation.encode_motion, area_state.gd WIRE_WILD_MOTION): no record
## packed, compared, fingerprinted or journaled for a step.
func publish_motion()->void:
    var records:Dictionary=game.state.records if game.hosting else game.shared_records
    var world=game.main.world
    for wild_id in world.wild_population.take_dirty():motion_dirty[wild_id]=true
    var moved:=PackedInt64Array()
    var patches:Array=[]
    var sent:Dictionary={}
    var signatures:Dictionary={}
    for wild_id in motion_dirty.keys():
        var key=Population.record_key(game._area(),wild_id)
        if records.has(Population.claim_key(game._area(),wild_id)):
            motion_dirty.erase(wild_id);continue
        if not records.has(key):
            if not pending_spawns.any(func(entry):return int(entry.id)==int(wild_id)):motion_dirty.erase(wild_id)
            continue
        var data:Dictionary=world.wild_pokemon.get(wild_id,{})
        if data.get("ball_reserved",false):continue
        if not data.is_empty():
            var signature:=record_signature(data)
            if _sent_signatures.get(wild_id)==signature:
                moved.append(wild_id);motion_dirty.erase(wild_id);continue
            signatures[wild_id]=signature
        var next:Variant=null if data.is_empty() else world._serializable_ecology_record(data,data.cell)
        var encoded=Delta.encode(next)
        if encoded==records[key]:motion_dirty.erase(wild_id);_sent_signatures[wild_id]=signatures.get(wild_id);continue
        # The host has the stored record's fingerprint already worked out.
        var patch:Dictionary={"key":"wild_pokemon/"+str(wild_id),"before":game.state.print_of(key) if game.hosting else game.state.fingerprint(records[key])}
        # From a guest, only what changed in the record (coop_world_delta.gd).
        var delta:Variant=null if game.hosting or _whole_motion else Delta.entry_delta(records[key],encoded)
        if delta==null:patch["after"]=encoded
        else:patch["delta"]=delta;patch["print"]=game.state.fingerprint(encoded)
        patches.append(patch)
        sent[wild_id]=motion_stamp(data)
        if patches.size()>=64:break
    if not moved.is_empty():send_motion(moved)
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
            if signatures.has(wild_id):_sent_signatures[wild_id]=signatures[wild_id]
    if result.get("reason")=="save_failed":game.end_session("POKEMON MOVEMENT COULD NOT BE SAVED.")

## Binary motion: wild Pokemon id -> the signature (record_signature) of the
## record last sent for it. One whose record is still that only moved.
var _sent_signatures:Dictionary={}
## The record fields that change as a Pokemon wanders (Delta.MOTION_FIELDS),
## and what is never sent: left out of record_signature.
const UNSENT:=["cell","sprite","burrow_whirl_sprite","burrow_sand_sprite","behavior","previous_mate_id","ball_move_tween",
    "ball_reserved","ball_facing","source_aggro_emote_seconds","aggro_audio_tick"]

## What of a wild Pokemon's record others must be sent whole when it changes:
## everything but where it is and what it is doing this moment.
static func record_signature(data:Dictionary)->int:
    var plain:=data.duplicate()
    for field in Delta.MOTION_FIELDS:plain.erase(field)
    for field in UNSENT:plain.erase(field)
    return plain.hash()

## The motion of `ids` sent: a host relays it, a player sends it to the host.
func send_motion(ids:PackedInt64Array)->void:
    var started:=Time.get_ticks_usec()
    var motion:PackedByteArray=game.main.world.wild_population.encode_motion(ids)
    var frame:=Wire.encode_motion(game._area(),game.area_epoch,motion)
    Session.Transport.count("enc:wild_motion_bin",frame.size(),started)
    if game.hosting:relay_motion(game.session.actor,game._area(),motion,frame)
    else:game.session.send_host_bytes(frame)

## Host: wild motion from the one who simulates `area` (checked: its
## authority, this epoch). Kept (`moved`, folded into the records when they
## are read whole: fold_motion) and passed on to the players watching the
## area, as it came.
var moved:Dictionary={}
func motion_frame(actor:String,packet:Dictionary)->void:
    if not game.hosting:
        if packet.get("area")==game._area() and not authority():apply_motion(packet.get("motion",[]))
        return
    var area:=String(packet.get("area",""))
    if not game.service.areas.can_publish(actor,area,int(packet.get("epoch",-1))):return
    var motion:PackedByteArray=packet.get("bytes",PackedByteArray())
    relay_motion(actor,area,motion,Wire.encode_motion(area,int(packet.epoch),motion),packet.get("motion",[]))

func relay_motion(actor:String,area:String,motion:PackedByteArray,frame:PackedByteArray,entries:Array=[])->void:
    if entries.is_empty():entries=WildPopulation.decode_motion(motion)
    var kept:Dictionary=moved.get_or_add(area,{})
    var claimed:Dictionary={}
    for entry in entries:
        if game.state.records.has(Population.claim_key(area,int(entry.id))) or not game.state.records.has(Population.record_key(area,int(entry.id))):claimed[entry.id]=true;continue
        kept[entry.id]=entry
    # Unsaved wandering: the world is saved for it every MOTION_SAVE_MS (coop_game.gd).
    if not kept.is_empty():game.state.loose+=1
    for peer in game.session.players:
        if peer==1 or String(game.session.players[peer].actor)==actor:continue
        if area in game._watched(String(game.session.players[peer].actor)):game.session.send_bytes_to(peer,frame)
    # The host's own game, when it is there but does not simulate it.
    if area==game._area() and actor!=game.session.actor:apply_motion(entries.filter(func(entry):return not claimed.has(entry.id)))

## Host: what is kept of `area`'s motion, to `peer` as one frame (after the
## records that say where its Pokemon were).
func send_moved(peer:int,area:String)->void:
    var kept:Dictionary=moved.get(area,{})
    if kept.is_empty():return
    game.session.send_bytes_to(peer,Wire.encode_motion(area,int(game.service.areas.epochs.get(area,0)),encode_entries(kept.values())))

## decode_motion's entries packed again (WildPopulation.encode_motion's form).
static func encode_entries(entries:Array)->PackedByteArray:
    var bytes:=PackedByteArray()
    bytes.resize(2+entries.size()*14)
    bytes.encode_u16(0,entries.size())
    var at:=2
    for entry in entries:
        var id:int=int(entry.id)
        bytes.encode_u32(at,id&0xFFFFFFFF);bytes.encode_u32(at+4,(id>>32)&0xFFFFFFFF)
        bytes.encode_s16(at+8,clampi(int(entry.x),-32768,32767));bytes.encode_s16(at+10,clampi(int(entry.y),-32768,32767))
        bytes[at+12]=maxi(0,WildPopulation.DIRECTIONS.find(entry.facing))|(int(entry.phase)&1)<<4
        bytes[at+13]=int(entry.flags)&255
        at+=14
    return bytes

## Player: motion that came while the area was still loading, by id; laid on
## once its Pokemon are there (synchronize).
var _motion_waiting:Dictionary={}
var _motion_waiting_area:=""

## A player: the wild Pokemon of its area where the one simulating it put them.
func apply_motion(entries:Array)->void:
    var world=game.main.world
    if not world.generated or game.main.generating or game.main.edge_travel_busy or sync_pending:
        if _motion_waiting_area!=game._area():_motion_waiting.clear();_motion_waiting_area=game._area()
        for entry in entries:_motion_waiting[entry.id]=entry
        return
    applying=true
    for entry in entries:
        var wild_id:=int(entry.id)
        var data=world.wild_pokemon.get(wild_id)
        # One still waiting to be added is added where it is now.
        if data==null and pending_additions.has(wild_id):
            pending_additions[wild_id]["x"]=int(entry.x);pending_additions[wild_id]["y"]=int(entry.y)
            continue
        if data==null or data.get("ball_reserved",false):continue
        var before:Vector2i=data.cell
        var target:=Vector2i(int(entry.x),int(entry.y))
        if before!=target:
            world.wild_population.begin_step(wild_id,0.1*Engine.time_scale)
            world.wild_population.move(wild_id,target)
        var facing:Vector2i=entry.facing
        data["anim_phase"]=int(entry.phase)
        data["aggro_player"]=int(entry.flags)&4!=0
        if facing!=Vector2i.ZERO:data["ball_facing"]=Vector2(facing)
        if before!=target or facing!=Vector2i.ZERO:
            world.wild_population.pose(wild_id,facing if facing!=Vector2i.ZERO else world._cardinal_direction(target-before,false),int(entry.phase))
    applying=false

## Host: the motion kept for `area` (every area with "") written into the
## records, as commits (not journaled: motion never is) sent to the players
## like any other, a few milliseconds of it a frame. Done when the records are
## read whole: a world or area save, the host going to an area.
func fold_motion(area:String="")->void:
    if not game.hosting or moved.is_empty():return
    var changes:Array=[]
    var started:=Time.get_ticks_usec()
    for each in (moved.keys() if area.is_empty() else [area]):
        var kept:Dictionary=moved.get(each,{})
        moved.erase(each)
        for wild_id in kept:
            var key:=Population.record_key(each,int(wild_id))
            var held=game.state.records.get(key)
            if not held is String or game.state.records.has(Population.claim_key(each,int(wild_id))):continue
            var record=Delta.decode(held)
            if not record is Dictionary:continue
            var entry:Dictionary=kept[wild_id]
            record["x"]=int(entry.x);record["y"]=int(entry.y);record["anim_phase"]=int(entry.phase)
            record["aggro_player"]=int(entry.flags)&4!=0
            var encoded:=Delta.encode(record)
            if encoded!=held:changes.append(game.state.change(key,encoded))
            if changes.size()>=64 or Time.get_ticks_usec()-started>=FOLD_SLICE_USEC:
                if not changes.is_empty():_commit_fold(changes);changes=[]
                if Time.get_ticks_usec()-started>=FOLD_SLICE_USEC:
                    await get_tree().process_frame
                    started=Time.get_ticks_usec()
    if not changes.is_empty():_commit_fold(changes)

## The time a frame gives fold_motion.
const FOLD_SLICE_USEC:=3000

func _commit_fold(changes:Array)->void:
    var result:Dictionary=game.state.transact(game.session.actor,"fold/"+game._id(),changes,"",false)
    if result.get("ok",false):game._committed(result)

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
        _contact_ids=world.wild_population.ids_near(here,CONTACT_REACH)
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
## Why the last claim was turned away, for words the player is shown
## (coop_population_runtime.gd refusal).
var refused:=""

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
    refused=String(result.get("reason",""))
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
    var result:Dictionary=await game.command("wild_finish",{"area":encounter.area,"wild_id":encounter.wild_id,"outcome":outcome,"calm":bool(encounter.field_attack),"profile":profile,"base":game.profile_base,"aftermath":aftermath,"battle":game.main.battle_report()})
    if not result.get("ok",false):
        if not game.active:finishing=false;return false
        # Turned away (a battle the host's replay does not end this way, or a
        # record that moved on): the party and bag go back to what the host
        # holds, the Pokemon is let go, and the game goes on.
        print("ONLINE encounter result not kept: ",result.get("reason","unknown")," ",result.get("check",""))
        var confirmed=game.shared_records.get("player/"+game.session.actor)
        if game.hosting:confirmed=game.state.records.get("player/"+game.session.actor)
        if confirmed is Dictionary:
            game.main.caught_pokemon.assign(confirmed.get("party",[]).duplicate(true))
            game.main.inventory=confirmed.get("inventory",{}).duplicate(true)
        await game.command("wild_release",{"area":encounter.area,"wild_id":encounter.wild_id})
        game.main._show_message("THE HOST DID NOT ACCEPT THAT RESULT.")
        encounter.clear();original_profile.clear();finishing=false
        return true
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
    var battle_check:=check_battle(actor,args)
    # A win or a catch the host's replay does not confirm is not taken.
    if enforce_battles and String(args.outcome) in ["captured","defeated"] and not battle_check in ["ok","unreported"]:
        return {"ok":false,"reason":"battle_rejected","check":battle_check}
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
        result["battle_check"]=battle_check
    return result

## The reported battle played again on the host (battle_session.gd replay())
## from the battle's own log, with the party and bag the host holds for the
## player (or those the log began with, when they are the same Pokemon) and the
## wild Pokemon as the host's claim holds it: "ok", or why it does not end as
## reported ("wrong_enemy", "inputs_do_not_fit", "replay_<outcome>",
## "rewards": more experience than the replay gives). With enforce_battles a
## win or a catch that is not "ok" is refused (resolve); otherwise it is only
## reported. Battles without a log (a ball thrown in the field, a friendly
## Pokemon joining) are "unreported".
func check_battle(actor:String,args:Dictionary)->String:
    var report=args.get("battle")
    if not report is Dictionary or report.is_empty():return "unreported"
    if not BattleSession.valid_report(report):return "malformed"
    var profile:Dictionary=game.state.records.get("player/"+actor,{})
    var party=profile.get("party",[])
    var bag=profile.get("inventory",{})
    if not party is Array or not bag is Dictionary:return "no_profile"
    var context:Dictionary=BattleSession.whole_numbers(report.context)
    var facts:Dictionary=BattleSession.whole_numbers(report.facts)
    # The wild Pokemon is the one the host gave this player (the claim), not
    # one the report describes.
    var claim:Dictionary=game.state.records.get(Population.claim_key(String(args.get("area","")),int(args.get("wild_id",0))),{})
    var claimed=Delta.decode(String(claim.get("record",Delta.encode(null))))
    if claimed is Dictionary:
        facts["wild_record"]=wild_facts(claimed,bool(args.get("calm",false)))
        var enemy:Dictionary=(context.get("party",[{}]) as Array)[0] if not context.get("party",[]).is_empty() else {}
        if String(enemy.get("species","")).to_lower()!=String(claimed.get("species","")).to_lower():return _verdict(actor,args,"wrong_enemy")
    # The log's own starting party when it is the host's, Pokemon for Pokemon
    # (walking since the last save changes their steps and HP, not who they are).
    var started=BattleSession.whole_numbers(report.get("party",party))
    if started is Array and same_pokemon(started,party):party=started
    var started_bag=BattleSession.whole_numbers(report.get("bag",bag))
    if started_bag is Dictionary and started_bag.size()<=1024:bag=started_bag
    var replay=BattleSession.new()
    var fitted:bool=replay.replay(String(report.rng).to_int(),context,party.duplicate(true),bag.duplicate(true),facts,BattleSession.whole_numbers(report.inputs))
    var verdict:="ok"
    if not fitted:verdict="inputs_do_not_fit"
    elif replay.outcome!=String(args.get("outcome","")):verdict="replay_"+replay.outcome
    elif args.get("profile") is Dictionary and not rewards_fit(args.profile.get("party",[]),replay.party):verdict="rewards"
    return _verdict(actor,args,verdict)

func _verdict(actor:String,args:Dictionary,verdict:String)->String:
    if verdict!="ok":print("ONLINE wild battle check: %s reported %s, the replay says %s"%[actor,args.get("outcome",""),verdict])
    return verdict

## The wild Pokemon a battle reads (world.gd _begin_wild_encounter): its saved
## record with what its source added.
static func wild_facts(record:Dictionary,calm:bool)->Dictionary:
    var facts:=record.duplicate(true)
    if calm:facts["field_attack"]=true
    var source=record.get("source_record",{})
    if source is Dictionary:
        for property in source:
            if not facts.has(property):facts[property]=source[property]
    return facts

## True when two parties are the same Pokemon in the same order (species,
## level, experience, moves).
static func same_pokemon(first:Array,second:Array)->bool:
    if first.size()!=second.size():return false
    for index in first.size():
        var a=first[index];var b=second[index]
        if not a is Dictionary or not b is Dictionary:return false
        for field in ["species","level","exp","moves","is_egg"]:
            if a.get(field)!=b.get(field):return false
    return true

## True when no Pokemon of the reported party has more level or experience
## than the replay gave it (matched by its party id, else its slot).
static func rewards_fit(reported:Array,replayed:Array)->bool:
    var by_id:={}
    for pokemon in replayed:
        if pokemon is Dictionary and not str(pokemon.get("party_ecology_id","")).is_empty():by_id[str(pokemon.party_ecology_id)]=pokemon
    for index in reported.size():
        var mine=reported[index]
        if not mine is Dictionary:continue
        var theirs=by_id.get(str(mine.get("party_ecology_id","")),replayed[index] if index<replayed.size() else null)
        if not theirs is Dictionary or String(theirs.get("species",""))!=String(mine.get("species","")):continue
        if int(mine.get("level",0))>int(theirs.get("level",0)) or int(mine.get("exp",0))>int(theirs.get("exp",0)):return false
    return true

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
    game.main.world.wild_population.dirty.clear()
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
    if game.nobody_here():return
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
    # Where the one simulating this area put its Pokemon, written into the
    # records by the host (fold_motion): that one knows it already, and better.
    var folded:bool=request_id.begins_with("fold/") and authority()
    applying=true
    for change in changes:
        var key=String(change.get("key",""))
        if key.begins_with(prefix):
            if folded:continue
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
    # Drawn walking there over 0.1 s of real time, from where it is drawn now.
    if before!=target:world.wild_population.begin_step(wild_id,0.1*Engine.time_scale)
    data.merge(record,true);data["cell"]=target;world.wild_population.refresh(wild_id);world._sand_trap_merged(wild_id)
    data["aggro_audio_tick"]=audio_tick
    if before!=target:world.wild_population.pose(wild_id,world._cardinal_direction(target-before,false),int(data.get("anim_phase",0)))

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
    game.main.world._remove_wild_pokemon(wild_id)

func synchronize()->void:
    pending_additions.clear()
    var records:Dictionary=game.state.records if game.hosting else game.shared_records
    var changes:Array=[]
    for key in records:
        if shared_key(String(key)):changes.append({"key":key,"after":records[key]})
    committed(changes)
    # Then where they have moved since their records were written.
    if _motion_waiting_area==game._area() and not _motion_waiting.is_empty() and not authority():apply_motion(_motion_waiting.values())
    _motion_waiting.clear()
