extends Node
## A dedicated server as the authority of the Pokemon of every area its
## players are in (server.cfg population_authority=server, the default on a
## dedicated server: coop_state.gd fixed_authority makes it the authority of
## every area). Its own area is its World's, which runs it as before; any other
## is an AreaSim of the rules runtime (coop_rules_runtime.gd sims): its wild and
## habitat Pokemon and eggs read from the records (area_sim.gd) and run there by
## the code a World runs them with (wild_population.gd, habitat_population.gd,
## rules/population_rules.gd), every such area in turn within BUDGET_USEC of a
## frame. What changes goes out as it does from a player who simulates an
## area: a wild Pokemon that only moved as binary motion to the area's players
## (coop_wild_runtime.gd relay_motion, kept and folded into the records when
## they are read whole), any other change as a commit of its records (not
## journaled when it is only wandering). What others' commands change (a claim,
## a battle's end, a spawn, a Pokemon left in, taken from or harvested in a
## habitat, an egg taken) reaches the AreaSim with their commit (committed).
## Players then neither run nor send any area's Pokemon.
const Delta=preload("res://scripts/coop_world_delta.gd")
const Population=preload("res://scripts/coop_wild_population.gd")
const Records=preload("res://scripts/coop_population_records.gd")
const WildRuntime=preload("res://scripts/coop_wild_runtime.gd")
const PopulationRules=preload("res://scripts/rules/population_rules.gd")
const Wire=preload("res://scripts/area_state.gd")
const AreaSim=preload("res://scripts/area_sim.gd")
## What the areas' Pokemon get of a frame, all together (us); an area left out
## gets its time on a later frame (at most MAX_TICK at once).
const BUDGET_USEC:=4000
const MAX_TICK:=0.25
## How often an area's wild motion, and its habitat Pokemon and eggs, go out.
const MOTION_MS:=100
const HABITAT_MS:=500
## A habitat Pokemon or egg whose only change is its running timers goes out
## this often (as coop_population_runtime.gd TIMER_SEND_MS).
const TIMER_SEND_MS:=30000
const TIMERS:=["move_timer","lay_egg_seconds","friend_seconds","harvest_progress"]
const HABITAT_GROUPS:=["deployed_pokemon","wild_eggs"]
## The ids of this authority's own commits: not laid on its AreaSims again.
const OWN:="popsim/"
var game:Node
var enabled:=false
## area -> Beat.
var _beats:Dictionary={}
var _turn:=0
## A horde's id -> the clock it comes at (ten seconds after it is called, as
## the players are warned: coop_horde_runtime.gd).
var _horde_at:Dictionary={}

## An area's sending: what of its Pokemon is to go out, and what went.
class Beat extends RefCounted:
    var sim
    ## Seconds of play the area has not been run for yet.
    var delta:=0.0
    ## Wild ids to look at (moved, changed, a new target, to be told again).
    var dirty:Dictionary={}
    ## Wild id -> WildRuntime.record_signature of its record as the host holds
    ## it: one whose record still has it only moved.
    var signatures:Dictionary={}
    var motion_at:=0
    var habitat_at:=0
    ## Record key -> when its timers last went out; group -> cell -> when looked at.
    var timers_sent:Dictionary={}
    var checked:Dictionary={}

func configure(coordinator:Node)->void:
    game=coordinator
    process_mode=Node.PROCESS_MODE_ALWAYS

## The areas whose Pokemon this authority runs in AreaSims now: those players
## are in, but the host's own.
func areas()->Array:
    var found:Array=[]
    for actor in game.state.members:
        var area:=String(game.state.members[actor].get("area",""))
        if not area.is_empty() and area!=game._area() and not area in found:found.append(area)
    found.sort()
    return found

func _process(delta:float)->void:
    if not enabled or not is_instance_valid(game) or not game.active or not game.hosting or not game.main.started:return
    var started:=Time.get_ticks_usec()
    var occupied:=areas()
    for area in _beats.keys():
        if not area in occupied or game.rules.sims.get(area)!=_beats[area].sim:_beats.erase(area)
    if occupied.is_empty():return
    _turn=(_turn+1)%occupied.size()
    for index in occupied.size():
        var area:String=occupied[(index+_turn)%occupied.size()]
        var sim=game.rules.sims.get(area)
        if sim==null:
            game.rules.load_area(area)
            continue
        var beat:Beat=_beats.get(area)
        if beat==null:beat=_begin(area,sim)
        beat.delta=minf(beat.delta+delta,MAX_TICK)
        if Time.get_ticks_usec()-started>=BUDGET_USEC:continue
        if not sim.populated:
            if sim.load_population(game.state.records,started+BUDGET_USEC,game.wild.moved.get(area,{})):_loaded(sim,beat)
            continue
        sim.state.clock=game.clock_seconds
        sim.tick(beat.delta,sim.players.refresh(game.visuals.last_packets,area))
        beat.delta=0.0
        var now:=Time.get_ticks_msec()
        if now-beat.motion_at>=MOTION_MS:
            beat.motion_at=now
            _publish_wild(area,sim,beat)
        if now-beat.habitat_at>=HABITAT_MS:
            beat.habitat_at=now
            _publish_habitats(area,sim,beat)
        _horde(area,sim)
    # How long the areas took (the net profile's SPIKES name it).
    if Engine.has_meta("probe_frame"):
        var sections:Dictionary=Engine.get_meta("probe_frame")
        sections["@areas' Pokemon"]=int(sections.get("@areas' Pokemon",0))+Time.get_ticks_usec()-started

## A horde called in an area run here comes when it is due: its Pokemon placed
## around its players there (coop_horde_runtime.gd spawn_in).
func _horde(area:String,sim)->void:
    var event:Dictionary=game.state.records.get("horde/"+area,{})
    if event.get("phase")!="waiting" or event.get("spawned",false) or game.hordes.spawning:return
    var id:=String(event.get("id",""))
    if not _horde_at.has(id):
        _horde_at[id]=game.clock_seconds+10.0
        return
    if game.clock_seconds<float(_horde_at[id]):return
    _horde_at.erase(id)
    game.hordes.spawn_in(area,sim,event.duplicate(true))

func _begin(area:String,sim)->Beat:
    var beat:=Beat.new()
    beat.sim=sim
    _beats[area]=beat
    var keys:Array=[]
    for group in AreaSim.POPULATION:keys.append_array(game.record_keys("world/"+area+"/"+group+"/"))
    sim.begin_population(keys)
    return beat

## The area's Pokemon are in: the host's records are what they are, so only
## what changes from now on goes out.
func _loaded(sim,beat:Beat)->void:
    for wild_id in sim.state.wild.records:
        beat.signatures[wild_id]=WildRuntime.record_signature(sim.state.wild.records[wild_id])
    sim.state.wild.take_dirty()
    sim.players.marked.clear()
    var now:=Time.get_ticks_msec()
    for group in HABITAT_GROUPS:
        var population=sim.state.habitat if group=="deployed_pokemon" else sim.state.eggs
        population.take_dirty()
        var looked:Dictionary=beat.checked.get_or_add(group,{})
        for cell in population.records:
            looked[cell]=now
            beat.timers_sent[Records.key(sim.state.area,group,cell)]=now

## Wild Pokemon that only moved go out as one binary frame; one whose record
## changed otherwise (or went) as a commit of it.
func _publish_wild(area:String,sim,beat:Beat)->void:
    var records:Dictionary=game.state.records
    for wild_id in sim.state.wild.take_dirty():beat.dirty[wild_id]=true
    for wild_id in sim.players.marked:beat.dirty[wild_id]=true
    sim.players.marked.clear()
    var moved:=PackedInt64Array()
    var changes:Array=[]
    var durable:=false
    var kept:Dictionary=game.wild.moved.get(area,{})
    for wild_id in beat.dirty.keys():
        var key:=Population.record_key(area,wild_id)
        if records.has(Population.claim_key(area,wild_id)) or not records.has(key):
            beat.dirty.erase(wild_id);continue
        var data:Dictionary=sim.state.wild.records.get(wild_id,{})
        beat.dirty.erase(wild_id)
        var signature:=WildRuntime.record_signature(data) if not data.is_empty() else 0
        if not data.is_empty() and beat.signatures.get(wild_id)==signature:
            moved.append(wild_id);continue
        if data.is_empty():beat.signatures.erase(wild_id)
        else:beat.signatures[wild_id]=signature
        var encoded:=Delta.encode(null if data.is_empty() else PopulationRules.serializable_record(sim.state,data,data.cell))
        if encoded==records[key]:continue
        durable=durable or not Delta.only_motion(String(records[key]),encoded)
        changes.append(game.state.change(key,encoded))
        # The record has its place now: older motion kept for it is not folded in.
        kept.erase(wild_id)
        if changes.size()>=Delta.MAX_PATCHES:break
    if not moved.is_empty():
        var motion:PackedByteArray=sim.state.wild.encode_motion(moved)
        game.wild.relay_motion(game.session.actor,area,motion,Wire.encode_motion(area,int(game.service.areas.epochs.get(area,0)),motion))
    _commit(changes,durable)

## The habitat Pokemon and eggs that changed (placed, taken, moved, their
## fields), and those whose timers ran for TIMER_SEND_MS, as one commit.
func _publish_habitats(area:String,sim,beat:Beat)->void:
    var records:Dictionary=game.state.records
    var now:=Time.get_ticks_msec()
    var nothing:=Delta.encode(null)
    var check:Dictionary={}
    for group in HABITAT_GROUPS:
        var population=sim.state.habitat if group=="deployed_pokemon" else sim.state.eggs
        for cell in population.take_dirty():check[Records.key(area,group,cell)]=[group,cell]
        var looked:Dictionary=beat.checked.get_or_add(group,{})
        if looked.size()>4096:looked.clear()
        for cell in population.records:
            if now-int(looked.get(cell,-TIMER_SEND_MS))>=TIMER_SEND_MS:check[Records.key(area,group,cell)]=[group,cell]
    var changes:Array=[]
    var durable:=false
    for key in check:
        var group:String=check[key][0]
        var cell:Vector2i=check[key][1]
        var population=sim.state.habitat if group=="deployed_pokemon" else sim.state.eggs
        beat.checked[group][cell]=now
        var data=population.records.get(cell)
        var held=records.get(key)
        var before:String=held if held is String else nothing
        # A built house's Pokemon are its players' to run (coop_population_records.gd record_scope).
        if data is Dictionary and data.has("house_door"):continue
        if data==null and before!=nothing:
            var old=Delta.decode_shared(before)
            if old is Dictionary and old.has("house_door"):continue
        var serial:Variant=null
        if data is Dictionary:serial=PopulationRules.serializable_egg(data,cell) if group=="wild_eggs" else PopulationRules.serializable_record(sim.state,data,cell)
        var next:=Delta.encode(serial)
        if next==before:continue
        # A Pokemon standing still only has its timers running: those go now and then.
        if serial!=null and before!=nothing and now-int(beat.timers_sent.get(key,0))<TIMER_SEND_MS and _bare(serial)==_bare(Delta.decode_shared(before)):continue
        beat.timers_sent[key]=now
        if group=="deployed_pokemon":
            if serial==null:sim.habitat_ids.erase(cell)
            else:sim.habitat_ids[cell]=String(data.get("ecology_id",""))
        durable=durable or not Delta.only_motion(before,next)
        changes.append(game.state.change(key,next))
        if changes.size()>=Delta.MAX_PATCHES:break
    if beat.timers_sent.size()>4096:beat.timers_sent.clear()
    _commit(changes,durable)

## A record without its running timers, to tell a move from a tick.
static func _bare(record:Variant)->Variant:
    if not record is Dictionary:return record
    var plain:Dictionary=record.duplicate()
    for field in TIMERS:plain.erase(field)
    return Delta.encode(plain)

func _commit(changes:Array,durable:bool)->void:
    if changes.is_empty():return
    var result:Dictionary=game.state.transact(game.session.actor,OWN+game._id(),changes,"",durable)
    if result.get("ok",false):game._committed(result)
    else:print("SERVER ERROR: an area's Pokemon could not be saved: ",result.get("reason",""))

## Every commit on the host: what someone else's command changed of the
## Pokemon of an area run here reaches its AreaSim (this authority's own
## commits and the motion folded into the records are its already).
func committed(commit:Dictionary)->void:
    if not enabled or _beats.is_empty():return
    var id:=String(commit.get("id",""))
    if id.begins_with(OWN) or id.begins_with("fold/"):return
    for change in commit.get("changes",[]):
        var key:=String(change.get("key",""))
        var claim:=key.begins_with("wild_claim/")
        if not claim and not key.begins_with("world/"):continue
        var beat:Beat=_beats.get(key.get_slice("/",1))
        if beat==null:continue
        if claim:
            var claimed_id:=int(key.get_slice("/",2))
            if beat.sim.apply_claim(claimed_id,change.get("after") is Dictionary):beat.dirty[claimed_id]=true
            continue
        var group:=key.get_slice("/",2)
        if not group in AreaSim.POPULATION:continue
        var name:=key.get_slice("/",3).uri_decode()
        var value=Delta.decode(String(change.after)) if change.get("after") is String else null
        var told:bool=beat.sim.apply_population(group,name,value)
        if group=="wild_pokemon":
            var wild_id:=int(name)
            var data:Dictionary=beat.sim.state.wild.records.get(wild_id,{})
            if data.is_empty():
                beat.signatures.erase(wild_id);beat.dirty.erase(wild_id)
            else:
                beat.signatures[wild_id]=WildRuntime.record_signature(data)
                if told:beat.dirty[wild_id]=true
        elif group=="deployed_pokemon" and value is Dictionary:
            beat.timers_sent[key]=Time.get_ticks_msec()
