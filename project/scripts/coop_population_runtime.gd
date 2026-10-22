extends Node
const Records=preload("res://scripts/coop_population_records.gd")
const Delta=preload("res://scripts/coop_world_delta.gd")
const GROUPS=["deployed_pokemon","wild_eggs"]
var game:Node
var busy:=false
var last_result:Dictionary={}
var applying:=false
var motion_busy:=false
var last_motion:=0
var sync_pending:=false
func configure(coordinator:Node)->void:game=coordinator
func model():
    var value=Records.new();value.state=game.state;value.presence=game.commands.presence
    value.can_publish=game.service.areas.can_publish if is_instance_valid(game.service) else Callable()
    value.make_egg=make_egg
    value.can_simulate=can_simulate
    return value

func make_egg(record:Dictionary,profile:Dictionary)->Dictionary:
    var species=String(record.get("egg_species",record.get("species",""))).to_lower()
    var egg:Dictionary=game.main._pokemon_from_egg_record(record,species,maxi(1,int(record.get("level",5))))
    var cycles=maxi(1,int(record.get("hatch_cycles",preload("res://scripts/pokemon_data.gd").info(species).get("egg_cycles",20))))
    egg["is_egg"]=true;egg["egg_species"]=species;egg["hatch_cycles"]=cycles
    egg["hatch_steps"]=maxi(1,cycles*preload("res://scripts/pokemon_ecology.gd").EGG_STEP_INTERVAL-int(profile.get("save",{}).get("egg_step_timer",0)))
    egg["hp"]=0
    return egg

func can_simulate(actor:String,area:String,epoch:int,scope:String)->bool:
    if scope=="OVERWORLD":return game.service.areas.can_publish(actor,area,epoch)
    var candidates:Array=[]
    for candidate in game.commands.presence:
        var presence:Dictionary=game.commands.presence[candidate]
        if game.state.members.get(candidate,{}).get("area")==area and presence.get("population_scope")==scope:candidates.append(candidate)
    candidates.sort()
    return not candidates.is_empty() and candidates[0]==actor

func authority(scope:String="OVERWORLD")->bool:
    if not game.active:return false
    if scope=="OVERWORLD":return game.area_authority==game.session.actor
    var candidates:Array=[]
    for actor in game.visuals.last_packets:
        var packet:Dictionary=game.visuals.last_packets[actor]
        if packet.get("area")==game._area() and packet.get("population_scope")==scope:candidates.append(actor)
    if local_scope()==scope and not game.session.actor in candidates:candidates.append(game.session.actor)
    candidates.sort()
    return not candidates.is_empty() and candidates[0]==game.session.actor

func local_scope()->String:
    var world=game.main.world
    return "HOUSE/"+world._cell_key(world.active_built_house_door)+"/"+str(world._built_house_floor_index_for_cell(world._player_cell())) if world.active_area_id=="HOUSE" else "OVERWORLD"

func _process(delta:float)->void:
    if not is_instance_valid(game) or not game.active or not game.main.started or game.main.generating or game.main.edge_travel_busy:return
    if sync_pending:sync_pending=false;synchronize()
    var world=game.main.world
    if world.is_processing() and (not world.gameplay_enabled or world.active_area_id!="OVERWORLD"):
        world._update_ecology(delta)
        if authority():
            game.wild.simulating=true;world._update_deployed_pokemon(delta);game.wild.simulating=false
        if not world.gameplay_enabled and world.active_area_id=="HOUSE" and authority(local_scope()):
            world.gameplay_enabled=true
            world._update_house_pokemon(delta)
            world.gameplay_enabled=false
    if (not authority() and not authority(local_scope())) or busy or motion_busy or game._request_busy or not game.main.world.is_processing():return
    if Time.get_ticks_msec()-last_motion<750:return
    last_motion=Time.get_ticks_msec()
    publish_motion()

const TIMERS=["move_timer","lay_egg_seconds","friend_seconds","harvest_progress"]
const TIMER_SEND_MS:=30000
var _timers_sent:Dictionary={}
var _scopes:Dictionary={}
const EGGS_PER_BEAT:=12
var _egg_cursor:=0
var _bare:Dictionary={}

## A stored record with its timers taken out, worked out once per record.
func _without_timers(key:String,held:String)->String:
    var known:Array=_bare.get(key,[])
    if known.is_empty() or known[0]!=held:
        if _bare.size()>2048:_bare.clear()
        var old=Delta.decode(held)
        if old is Dictionary:
            for field in TIMERS:old.erase(field)
        known=[held,Delta.encode(old)]
        _bare[key]=known
    return known[1]

static func _timers_only(before:String,after:String)->bool:
    var old=Delta.decode(before);var next=Delta.decode(after)
    if not old is Dictionary or not next is Dictionary:return false
    for field in TIMERS:old.erase(field);next.erase(field)
    return Delta.encode(old)==Delta.encode(next)

func publish_motion()->void:
    var records:Dictionary=game.state.records if game.hosting else game.shared_records
    var before:Dictionary={};var after:Dictionary={};var prefix="world/"+game._area()+"/"
    var now:=Time.get_ticks_msec()
    if _timers_sent.size()>512:_timers_sent.clear()
    if _scopes.size()>2048:_scopes.clear()
    var nothing:String=Delta.encode(null)
    # Eggs do not move; only their timers run. Checking every egg on every
    # beat was most of a 28 ms stall three times every two seconds on the
    # host. A dozen take their turn each beat, so each egg is looked at every
    # few seconds; habitat Pokemon, which walk about, are still checked on
    # every beat. An egg that is gone here but still recorded is always
    # included, so a hatched or collected egg is cleared on the next beat.
    var egg_keys:Dictionary={};var egg_turn:Dictionary={}
    var egg_cells:Array=game.main.world.wild_eggs.keys()
    for cell in egg_cells:egg_keys["wild_eggs/"+("%d,%d"%[cell.x,cell.y]).uri_encode()]=true
    for _turn in range(mini(EGGS_PER_BEAT,egg_cells.size())):
        _egg_cursor=(_egg_cursor+1)%egg_cells.size()
        var turn_cell:Vector2i=egg_cells[_egg_cursor]
        egg_turn["wild_eggs/"+("%d,%d"%[turn_cell.x,turn_cell.y]).uri_encode()]=true
    for group in GROUPS:
        for key in game.record_keys(prefix+group+"/"):
            var held=records.get(key)
            # A tile a Pokemon has left keeps an empty record; most are these.
            if held==null or held==nothing:continue
            if group=="wild_eggs":
                var egg_key:=String(key).trim_prefix(prefix)
                if egg_keys.has(egg_key) and not egg_turn.has(egg_key):continue
            # Decoding every stored record on every beat was a regular small
            # stall; a record's scope only changes when the record does.
            var known:Array=_scopes.get(key,[])
            if known.is_empty() or known[0]!=held:
                var record=Delta.decode(held)
                known=[held,Records.record_scope(record) if record is Dictionary else ""]
                _scopes[key]=known
            if known[1]!="" and authority(known[1]):before[String(key).trim_prefix(prefix)]=held
    # A Pokemon saved on two tiles at once is one Pokemon: keep the first and
    # take the others away, here and (as the tiles empty) in the saved world.
    var standing:Dictionary={}
    for cell in game.main.world.deployed_pokemon.keys():
        var identity=String(game.main.world.deployed_pokemon[cell].get("ecology_id",""))
        if identity.is_empty():continue
        if standing.has(identity) and authority(Records.record_scope(game.main.world.deployed_pokemon[cell])):
            remove("deployed_pokemon",cell)
        else:standing[identity]=cell
    for group in GROUPS:
        for cell in game.main.world.get(group):
            var data:Dictionary=game.main.world.get(group)[cell]
            if not authority(Records.record_scope(data)):continue
            var key:String=group+"/"+("%d,%d"%[cell.x,cell.y]).uri_encode()
            if group=="wild_eggs" and not egg_turn.has(key):continue
            var serial:Dictionary=game.main.world._serializable_ecology_record(data,cell)
            var next:String=Delta.encode(serial)
            # A Pokemon standing still only has its timers running. Those are
            # sent now and then, not on every beat.
            var quiet:=false
            if before.has(key) and next!=before[key] and now-int(_timers_sent.get(key,0))<TIMER_SEND_MS:
                var bare:Dictionary=serial.duplicate()
                for field in TIMERS:bare.erase(field)
                quiet=Delta.encode(bare)==_without_timers(key,before[key])
            if quiet:next=before[key]
            elif not before.has(key) or next!=before[key]:_timers_sent[key]=now
            after[key]=next
    var patches=Delta.diff(before,after)
    if patches.is_empty():return
    var batches=Records.batches(patches,before)
    if batches.is_empty():synchronize();return
    motion_busy=true
    var result:Dictionary={"ok":true}
    for batch in batches:
        result=await game.command("population_motion",{"area":game._area(),"epoch":game.area_epoch,"patches":batch})
        if not result.get("ok",false):break
    motion_busy=false
    if result.get("reason")=="save_failed":game.end_session("POKEMON HABITAT COULD NOT BE SAVED.")
    elif not result.get("ok",false) and result.get("reason")!="busy":synchronize()

func synchronize()->void:
    var records:Dictionary=game.state.records if game.hosting else game.shared_records
    var changes:Array=[]
    for key in records:
        if shared_key(String(key)):changes.append({"key":key,"after":records[key]})
    # Roll back any provisional source movement that lost a race with pickup.
    for group in GROUPS:
        for cell in game.main.world.get(group).keys():
            var key=Records.key(game._area(),group,cell)
            if not records.has(key):changes.append({"key":key,"after":Delta.encode(null)})
    committed(changes)
static func shared_key(key:String)->bool:
    return key.begins_with("world/") and key.get_slice("/",2) in GROUPS
static func overlay(area:String,shared:Dictionary,records:Dictionary)->Dictionary:
    var flat=Delta.flatten(shared)
    # Once an area is in the shared records they are the whole truth. An egg or
    # habitat Pokemon the area file still holds but the records do not was
    # taken after that file was written and must not come back.
    if records.get("world_ready/"+area,false):
        for key in flat.keys():
            if String(key).get_slice("/",0) in GROUPS:flat.erase(key)
    for key in records:
        if shared_key(String(key)) and String(key).begins_with("world/"+area+"/"):flat[String(key).trim_prefix("world/"+area+"/")]=records[key]
    return Delta.inflate(flat,shared)
func execute(actor:String,id:String,operation:String,args:Dictionary)->Dictionary:
    if operation=="population_motion":return model().motion(actor,id,args.area,int(args.epoch),args.patches)
    if operation=="deploy":
        var record=Delta.decode(args.record)
        if not record is Dictionary:return {"ok":false,"reason":"invalid_record"}
        return model().place(actor,id,args.area,int(args.slot),record,args.base)
    if operation=="recall_population":return model().take(actor,id,args.area,Vector2i(int(args.x),int(args.y)),args.group,args.expected,args.box,str(args.get("identity","")))
    if operation=="harvest_population":return model().harvest(actor,id,args.area,Vector2i(int(args.x),int(args.y)),args.expected,String(args.get("identity","")))
    return {"ok":false,"reason":"invalid_command"}
func remove(group:String,cell:Vector2i)->void:
    var values:Dictionary=game.main.world.get(group)
    var record:Dictionary=values.get(cell,{})
    var sprite=record.get("sprite")
    if is_instance_valid(sprite):sprite.queue_free()
    var tween=record.get("ball_move_tween")
    if tween is Tween and tween.is_valid():tween.kill()
    values.erase(cell)
func apply(group:String,cell:Vector2i,record:Variant)->void:
    remove(group,cell)
    if not record is Dictionary:return
    var world=game.main.world
    if group=="deployed_pokemon":world._restore_deployed_pokemon(record,cell)
    else:world._add_wild_egg(String(record.species),cell,record)
func committed(changes:Array,source_actor:String="",request_id:String="")->void:
    if not game.main.started or game.main.generating or game.main.edge_travel_busy:return
    if source_actor==game.session.actor and request_id.begins_with("world/"):return
    var prefix="world/"+game._area()+"/"
    applying=true
    var reusable:Dictionary={}
    var world=game.main.world
    # Retain sprites across a cell move; a move is one atomic old/new pair.
    for change in changes:
        var key=String(change.key)
        if not key.begins_with(prefix+"deployed_pokemon/"):continue
        var coords=key.get_slice("/",3).uri_decode().split(",")
        if coords.size()!=2:continue
        var cell=Vector2i(int(coords[0]),int(coords[1]))
        var old:Dictionary=world.deployed_pokemon.get(cell,{})
        if old.is_empty():continue
        var identity=String(old.get("ecology_id",""))
        if identity.is_empty():continue
        reusable[identity]=old
        world.deployed_pokemon.erase(cell)
    # One Pokemon stands on one tile. A record can arrive for a tile other than
    # the one this game shows it on (an item taken from it a step away); the
    # copy shown elsewhere is the same Pokemon and must not stay behind as a
    # second one, which the host would then save as a real duplicate.
    var arriving:Dictionary={}
    for change in changes:
        var key=String(change.key)
        if not key.begins_with(prefix+"deployed_pokemon/"):continue
        var record=Delta.decode(change.after)
        if record is Dictionary and not String(record.get("ecology_id","")).is_empty():arriving[String(record.ecology_id)]=true
    if not arriving.is_empty():
        for cell in world.deployed_pokemon.keys():
            var shown:Dictionary=world.deployed_pokemon[cell]
            var identity=String(shown.get("ecology_id",""))
            if not arriving.has(identity):continue
            world.deployed_pokemon.erase(cell)
            if not reusable.has(identity):reusable[identity]=shown
            else:
                var spare=shown.get("ball_move_tween") as Tween
                if spare!=null and spare.is_valid():spare.kill()
                if is_instance_valid(shown.get("sprite")):shown.sprite.queue_free()
    var placed:Dictionary={}
    for change in changes:
        var key=String(change.key)
        if not shared_key(key) or not key.begins_with(prefix):continue
        var coords=key.get_slice("/",3).uri_decode().split(",")
        if coords.size()!=2:continue
        var cell=Vector2i(int(coords[0]),int(coords[1]))
        var record=Delta.decode(change.after)
        var identity=String(record.get("ecology_id","")) if record is Dictionary else ""
        if key.get_slice("/",2)=="deployed_pokemon" and not identity.is_empty():
            # A second record of a Pokemon already placed is a saved duplicate.
            if placed.has(identity):continue
            placed[identity]=true
        if key.get_slice("/",2)=="deployed_pokemon" and reusable.has(identity):
            var data:Dictionary=reusable[identity];reusable.erase(identity)
            var old_cell:Vector2i=data.cell
            data.merge(record,true);data["cell"]=cell
            world.deployed_pokemon[cell]=data
            var sprite=data.get("sprite") as Sprite2D
            if is_instance_valid(sprite):
                sprite.visible=world._house_pokemon_visible(data) if data.has("house_door") else world.active_area_id=="OVERWORLD"
                sprite.z_index=world._depth_z(cell)
                if old_cell!=cell:
                    var previous=data.get("ball_move_tween") as Tween
                    if previous!=null and previous.is_valid():previous.kill()
                    world._set_overworld_motion_frame(sprite,world._cardinal_direction(cell-old_cell,false),int(data.get("anim_phase",0)))
                    var tween=world.create_tween();tween.set_speed_scale(1.0/maxf(Engine.time_scale,0.01))
                    tween.tween_property(sprite,"position",world._cell_center(cell),0.2)
                    data["ball_move_tween"]=tween
            world._update_pokemon_water_visual(data)
        else:apply(key.get_slice("/",2),cell,record)
    for data in reusable.values():
        var tween=data.get("ball_move_tween") as Tween
        if tween!=null and tween.is_valid():tween.kill()
        if is_instance_valid(data.get("sprite")):data.sprite.queue_free()
    applying=false
func deploy(slot:int,keep_surf:bool)->void:
    if busy or slot<0 or slot>=game.main.caught_pokemon.size():return
    busy=true
    var main=game.main;var world=main.world
    var entry:Dictionary=main.caught_pokemon[slot].duplicate(true)
    if not world.deploy_pokemon(entry):last_result={"ok":false,"reason":"source_placement_rejected"};busy=false;return
    var cell:Vector2i=world._player_cell()+world._facing_cell()
    var group="wild_eggs" if entry.get("is_egg",false) else "deployed_pokemon"
    var record:Dictionary=world._serializable_ecology_record(world.get(group)[cell],cell)
    remove(group,cell)
    var result:Dictionary=await game.command("deploy",{"area":game._area(),"slot":slot,"record":Delta.encode(record),"base":game.profile_base})
    last_result=result
    busy=false
    if not result.get("ok",false):main._show_message("There is no room to leave that Pokemon here.");return
    if not keep_surf:world.clear_active_field_move(false)
    main.pokemon_menu_open=false;main.pokemon_menu.hide();main.game_menu_open=false;main.game_menu.hide()
    world.set_gameplay_enabled(true);main.touch_controls.set_game_active(true)
    main._show_message("The EGG was placed here." if entry.get("is_egg",false) else "%s was left in the habitat."%preload("res://scripts/pokemon_data.gd").battle_display_name(String(entry.species)))
func recall(cell:Vector2i,group:String="deployed_pokemon")->void:
    if busy:return
    var records:Dictionary=game.state.records if game.hosting else game.shared_records
    var key=Records.key(game._area(),group,cell)
    var encoded=String(records.get(key,Delta.encode(null)))
    var held=Delta.decode(encoded)
    if held==null:return
    var box=""
    for candidate in game.main._built_storage_keys():
        var chest:Dictionary=records.get("chest/"+candidate,{})
        if chest.is_empty():continue
        var destination=preload("res://scripts/coop_shared_items.gd").new().box_key(game.session.actor,chest)
        if records.get(destination,[]).size()<4096:box=candidate;break
    busy=true
    var result:Dictionary=await game.command("recall_population",{"area":game._area(),"x":cell.x,"y":cell.y,"group":group,"expected":game.state.fingerprint(encoded),"box":box,"identity":String(held.get("ecology_id","")) if held is Dictionary else ""})
    last_result=result
    busy=false
    if result.get("ok",false):
        game.main.world.play_source_sound("Berry_Get" if group=="wild_eggs" else "seed1")
        if group=="wild_eggs":game.main._show_message("You picked up the EGG.")
        else:
            var pokemon:Dictionary=Delta.decode(encoded)
            game.main.pokedex_progress.mark(pokemon,true)
            if not String(pokemon.species) in game.main.caught_species:game.main.caught_species.append(String(pokemon.species))
    else:game.main._show_message("Too late!" if result.get("reason")=="too_late" else "Your party and storage are full.")

func harvest(cell:Vector2i)->void:
    if busy:return
    var world=game.main.world
    var data:Dictionary=world.deployed_pokemon.get(cell,{})
    if String(data.get("held_item","")).is_empty():return
    var records:Dictionary=game.state.records if game.hosting else game.shared_records
    var encoded=records.get(Records.key(game._area(),"deployed_pokemon",cell),Delta.encode(null))
    var item=String(data.held_item)
    busy=true
    var result:Dictionary=await game.command("harvest_population",{"area":game._area(),"x":cell.x,"y":cell.y,"expected":game.state.fingerprint(encoded),"identity":String(data.get("ecology_id",""))})
    busy=false
    if not result.get("ok",false):
        if result.get("reason")=="too_late":
            game.main._show_message("Too late!")
            # What this player sees no longer matches the host; show the truth.
            synchronize()
        return
    var current:Dictionary=world.deployed_pokemon.get(cell,{})
    world._show_ecology_emote(current.get("sprite") as Sprite2D,"uncomfortable" if not current.get("in_habitat",false) else "heart" if not String(current.get("mate_id","")).is_empty() else "happy")
    world.world_message.emit("%s produced %s!"%[preload("res://scripts/pokemon_state.gd").display_name(data).to_upper(),item])
