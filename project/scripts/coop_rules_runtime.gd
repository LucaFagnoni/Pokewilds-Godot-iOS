extends Node
## The co-op side of the rules (rules/). The host is their authority: a
## player's field command runs on the host's own copy of that player's area
## (its World's AreaState for the area the host plays in, an AreaSim for any
## other), with the host's random numbers, and what changed is committed in
## one transaction with what the player gained and paid. A player predicts
## its own command on its World's AreaState (recorded), shows it at once,
## and keeps it or rolls it back by the answer: no rewards claimed, nothing
## patched back by hand, no session ended for a refusal.
const Rules=preload("res://scripts/rules/rules.gd")
const AreaSim=preload("res://scripts/area_sim.gd")
const AreaState=preload("res://scripts/area_state.gd")
const Crafting=preload("res://scripts/crafting_data.gd")
## How far (cells, each way) a command's cell may be from where the player was
## last seen: the field move's reach and the moves its position lags behind.
const REACH:=4
## An area nobody is in keeps its AreaSim this long (ms) for whoever comes back.
const KEEP_EMPTY_MS:=120000
var game:Node
## Host: area -> AreaSim, and the areas being loaded.
var sims:Dictionary={}
var _loading:Dictionary={}
var rng:=RandomNumberGenerator.new()

func configure(coordinator:Node)->void:
    game=coordinator;rng.randomize()
    process_mode=Node.PROCESS_MODE_ALWAYS

## Host: the AreaState the rules run on for `area`; null while its AreaSim
## loads (a load is started then).
func state_for(area:String):
    if area==game._area() and game.main.world.generated:return game.main.world.area
    var sim=sims.get(area)
    if sim!=null:return sim.state
    load_area(area)
    return null

## Host: loads `area`'s AreaSim on a worker (snapshot and records), unless it
## has one or is the host's own.
func load_area(area:String)->void:
    if not game.hosting or sims.has(area) or _loading.has(area) or area==game._area():return
    var metadata:Dictionary=game.state.records.get("area/"+area,{})
    if not metadata.get("sha256") is String or not is_instance_valid(game.service):return
    _loading[area]=true
    var loaded:Dictionary=await game.service.snapshots.load_bytes(String(metadata.sha256))
    if not loaded.get("ok",false):_loading.erase(area);return
    var records:Dictionary={}
    var prefix:="world/"+area+"/"
    for key in game.state.keys_by_area.get(area,{}):
        if String(key).begins_with(prefix) and String(key).get_slice("/",2) in AreaState.GROUPS:records[key]=game.state.records[key]
    var bytes:PackedByteArray=loaded.bytes
    var sim=await game._off_thread(func():return AreaSim.build(area,bytes,records))
    _loading.erase(area)
    if sim==null:print("ONLINE area ",area," could not be held here for its rules");return
    # Commits made while it loaded are in the records now: lay them again.
    var newer:Dictionary={}
    for key in game.state.keys_by_area.get(area,{}):
        if String(key).begins_with(prefix) and records.get(key)!=game.state.records[key] and String(key).get_slice("/",2) in AreaState.GROUPS:newer[key]=game.state.records[key]
    sim.lay_records({},newer)
    sim.state.take_dirty()
    sims[area]=sim

## Host: every commit's world records reach the AreaSims they belong to.
func committed(changes:Array)->void:
    if sims.is_empty():return
    for change in changes:
        var key:=String(change.get("key",""))
        if not key.begins_with("world/"):continue
        var sim=sims.get(key.get_slice("/",1))
        if sim==null:continue
        var group:=key.get_slice("/",2)
        if group in AreaState.GROUPS and change.get("after") is String:
            sim.apply_record(group,key.get_slice("/",3).uri_decode(),change.after)
    for sim in sims.values():sim.state.take_dirty()

func _process(_delta:float)->void:
    if not game.hosting or sims.is_empty():return
    var now:=Time.get_ticks_msec()
    var occupied:Dictionary={}
    for actor in game.state.members:occupied[String(game.state.members[actor].get("area",""))]=true
    for area in sims.keys():
        var sim=sims[area]
        if occupied.has(area) and area!=game._area():sim.empty_since=0
        elif sim.empty_since==0:sim.empty_since=now
        elif now-sim.empty_since>=KEEP_EMPTY_MS or area==game._area():sims.erase(area)

## Host: a field command in the rules' form ({"area", "cmd"}, op one of
## Rules.OPS). Runs the rule on the area, commits the changes and the bag.
func execute(actor:String,id:String,op:String,args:Dictionary)->Dictionary:
    var state=game.state
    var hash_value:String=state.fingerprint([op,args.get("area"),args.get("cmd")])
    var previous:Dictionary=state.outcomes.get(actor+"/"+op+"/"+id,{})
    if not previous.is_empty():
        return previous.duplicate(true) if previous.get("command_hash")==hash_value else {"ok":false,"reason":"reused_request_id"}
    var area:=String(args.get("area",""))
    if not state.members.has(actor) or String(state.members[actor].get("area",""))!=area:return {"ok":false,"reason":"different_area"}
    var cmd=Rules.from_wire(op,args.get("cmd"))
    if cmd==null:return {"ok":false,"reason":"invalid_command"}
    var profile:Dictionary=state.records.get("player/"+actor,{})
    if profile.is_empty():return {"ok":false,"reason":"profile_missing"}
    var area_state=state_for(area)
    if area_state==null:return {"ok":false,"reason":"area_loading"}
    var player:=_player(actor,area,profile,cmd,args)
    if player.has("refused"):return {"ok":false,"reason":player.refused}
    area_state.tracking=true
    area_state.take_dirty()
    area_state.begin()
    var result:Dictionary=Rules.apply(op,area_state,player,cmd,rng)
    var changes:Array=area_state.take_dirty() if result.ok else []
    if not result.ok or (changes.is_empty() and result.grant.is_empty()):
        var cells:Array=area_state.rollback();area_state.take_dirty()
        _redraw(area_state,cells)
        return {"ok":false,"reason":String(result.reason) if not result.ok else "no_change","events":Rules.answered(result.events)}
    var records:Array=[]
    for change in changes:
        var record:=AreaSim.record_of(area,change[0],change[1],change[2])
        records.append(state.change(record[0],record[1]))
    if not result.grant.is_empty() or not result.consume.is_empty():
        var updated:Dictionary=profile.duplicate(true)
        if not Crafting.can_afford(updated.get("inventory",{}),result.consume):
            _redraw(area_state,area_state.rollback());area_state.take_dirty()
            return {"ok":false,"reason":"not_enough_materials"}
        Crafting.consume(updated.inventory,result.consume)
        for item in result.grant:Crafting.grant(updated.inventory,String(item),int(result.grant[item]))
        records.append(state.change("player/"+actor,updated))
    var committed:Dictionary=state.transact(actor,op+"/"+id,records,hash_value,true,{"op":op,"cmd":args.get("cmd")})
    if not committed.get("ok",false):
        _redraw(area_state,area_state.rollback());area_state.take_dirty()
        return committed
    area_state.commit()
    # The host's own World shows it: all of it for the host's own action,
    # only the ground for another player's.
    if area_state==game.main.world.area:
        var shown:Array=COSMETIC if actor==game.session.actor else ["refresh","refresh_cell","refresh_around","farms","house_decoration"]
        game.main.world.field_moves.play_rule({"events":result.events.filter(func(event):return event[0] in shown)})
    committed["events"]=Rules.answered(result.events)
    committed["grant"]=result.grant
    committed["consume"]=result.consume
    return committed

## What the rules are told about `actor`, from what the host holds: the bag of
## its record, the clock, where it stands (refused when the cell is too far),
## the field Pokemon checked against its party.
func _player(actor:String,area:String,profile:Dictionary,cmd:Dictionary,args:Dictionary)->Dictionary:
    var player:={"bag":profile.get("inventory",{}),"now":game.clock_seconds if game.hosting else 0.0,"shared":true,"area_id":"OVERWORLD"}
    var seen:Dictionary=game.commands.presence.get(actor,{})
    if String(seen.get("area","")).begins_with(area+"|"):
        player.area_id=String(seen.area).get_slice("|",1).get_slice("/",0)
        if player.area_id=="OVERWORLD":
            var at:Vector2i=cmd.cell
            if absi(at.x-int(seen.get("x",at.x)))>REACH or absi(at.y-int(seen.get("y",at.y)))>REACH:return {"refused":"too_far"}
    var species:=String(args.get("species",""))
    if not species.is_empty():
        for pokemon in profile.get("party",[]):
            if pokemon is Dictionary and String(pokemon.get("species","")).to_lower()==species.to_lower():player["species"]=species;break
    if player.area_id=="HOUSE":
        player["house_key"]=String(args.get("house_key",""))
        player["house_floor"]=bool(args.get("house_floor",false))
    return player

func _redraw(area_state,cells:Array)->void:
    if area_state==game.main.world.area and not cells.is_empty():game.main.world._refresh_exact_pickup_cells(cells)

# --- The player's side ---------------------------------------------------------

var _predicting:=false
const COSMETIC:=["sound","refresh","refresh_cell","refresh_around","farms","collected","house_decoration","cut_halves"]
## Player: `cmd` predicted on this World's area and sent; the answer keeps or
## undoes it (a host runs it at once: it is the authority). Shows it all:
## what the prediction shows at once (sounds, redraws), then what the answer
## says (words, what was gained, a Pokemon). Returns the answer; "planted"
## in it is the planted crop's tile when that is to be shown growing.
func predict(op:String,cmd:Dictionary,extra:Dictionary={})->Dictionary:
    var world=game.main.world
    var player:Dictionary=world.field_moves.rule_player(cmd.cell)
    var args:={"area":game._area(),"cmd":Rules.to_wire(cmd)}
    args.merge(extra)
    if player.has("house_key"):args["house_key"]=player.house_key;args["house_floor"]=player.house_floor
    if game.hosting:
        var direct:Dictionary=await game.command(op,args)
        _show_answer(direct)
        return direct
    var prediction_rng:=RandomNumberGenerator.new();prediction_rng.randomize()
    world.area.begin()
    var guess:Dictionary=Rules.apply(op,world.area,player,cmd,prediction_rng)
    var asks_soil:bool=guess.events.any(func(event):return event[0]=="soil")
    if not guess.ok or asks_soil:
        # Nothing to send: say why here (or ask for the soil), as alone.
        world.area.rollback()
        world.field_moves.play_rule({"events":guess.events.filter(func(event):return event[0] in ["message","soil"])})
        return guess
    world.field_moves.play_rule({"events":guess.events.filter(func(event):return event[0] in COSMETIC)})
    _predicting=true
    var answer:Dictionary=await game.command(op,args)
    _predicting=false
    if answer.get("ok",false):world.area.commit()
    else:
        var cells:Array=world.area.rollback()
        if not cells.is_empty():world._refresh_exact_pickup_cells(cells)
        if not answer.get("reason") in ["conflict","busy","area_loading","disconnected"]:print("ONLINE ",op," not kept: ",answer.get("reason",""))
    _show_answer(answer)
    if answer.get("ok",false):
        for event in guess.events:
            if event[0]=="planted":answer["planted"]=String(event[2])
    return answer

## The answer's own events (rules.gd ANSWERED): its words; what was gained, as
## the game shows rewards (the bag itself changes with the commit: apply_bag);
## a Pokemon met.
func _show_answer(answer:Dictionary)->void:
    var world=game.main.world
    var events:Array=answer.get("events",[]) if answer.get("events") is Array else []
    var grant:Dictionary=answer.get("grant",{}) if answer.get("grant") is Dictionary else {}
    if answer.get("ok",false) and not grant.is_empty():
        if events.any(func(event):return event is Array and not event.is_empty() and event[0] in ["dig_reward","item"]):game.main._on_dig_reward_collected(grant,false)
        else:game.main._on_build_refund_requested(grant,false)
    for event in events:
        if not event is Array or event.is_empty():continue
        if event[0]=="message" and event.size()>1:world.world_message.emit(String(event[1]))
        elif event[0]=="encounter" and event.size()>4 and answer.get("ok",false):
            if bool(event[4]) and event.size()>5 and event[5] is Array:
                var tile=world.exact_world.tile_at(Vector2i(int(event[5][0]),int(event[5][1])))
                if tile!=null and tile.route_belongs_to!=null and not tile.route_belongs_to.stored_pokemon.is_empty():tile.route_belongs_to.stored_pokemon.pop_front()
            if event[3] is Dictionary:world.pending_encounter_record=event[3].duplicate(true)
            world.encounter_requested.emit(String(event[1]),int(event[2]))

## This player's own command, as committed: what it paid and gained taken
## from and added to the bag here as a change (the host's copy of the bag is
## not taken whole for these: it may lack what is not saved yet). Applied with
## the commit itself, before anything else reads the bag.
func apply_bag(commit:Dictionary)->void:
    var consume=commit.get("consume",{})
    var grant=commit.get("grant",{})
    if consume is Dictionary and not consume.is_empty():Crafting.consume(game.main.inventory,consume)
    if grant is Dictionary:
        for item in grant:Crafting.grant(game.main.inventory,String(item),int(grant[item]))

## Player: the host's changes for this area arrived while a prediction is
## kept: theirs stand (a rollback leaves them alone).
func supersede(group:String,key:String)->void:
    if not _predicting:return
    var world=game.main.world
    var cell:=AreaState.key_cell(key)
    var cells:Array=[]
    for y in range(-1,2):
        for x in range(-1,2):cells.append(cell+Vector2i(x,y))
    world.area.forget(group,cell if group=="structures" else key,cells)
    # Ground changed under a cell rejoins the holes and shores around it.
    if group in ["source_interior_mutations","terrain_changes","source_plant_farms"]:
        for at in cells:world.area.forget("source_interior_mutations",AreaState.cell_key(at))
