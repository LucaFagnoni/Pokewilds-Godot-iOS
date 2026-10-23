extends Node
## All players submit their existing placement result to the host's atomic journal.
## Geometry and snapping still come from World.place_structure.
const Delta=preload("res://scripts/coop_world_delta.gd")
const Transaction=preload("res://scripts/coop_build_transaction.gd")
const GROUPS=["structures","built_house_floor_tiles","built_house_paintings",
    "built_house_decorations","built_house_origins","source_interior_mutations","source_plant_farms","removed_resources","terrain_changes"]
var game:Node
var busy:=false

func configure(coordinator:Node)->void:game=coordinator

static func is_build_key(key:String)->bool:
    return key.begins_with("world/") and key.get_slice("/",2) in GROUPS

## Only the built pieces of an area snapshot (GROUPS). Packing every wild
## Pokemon and habitat of a long-played area as well, to be thrown away, made
## each area save stall the host for a quarter of a second.
static func builds(shared:Dictionary)->Dictionary:
    var result:Dictionary={}
    for group in GROUPS:
        if shared.has(group):result[group]=shared[group]
    return result

func capture()->Dictionary:
    var world=game.main.world
    var records:Array=[]
    for cell in world.built_structures:
        var piece:Dictionary=world.built_structures[cell]
        if piece.get("generated_stair_pair",false):continue
        var saved=piece.duplicate(true)
        for key in ["sprite","collision","solid","bridged_water"]:saved.erase(key)
        # Match get_crafting_save_state exactly. Dot assignment introduces
        # StringName keys, whose binary fingerprints differ from String keys.
        saved["name"]=String(piece.get("name",""))
        saved["x"]=cell.x;saved["y"]=cell.y;records.append(saved)
    return {"structures":records,"built_house_floor_tiles":world.built_house_floor_tiles.keys(),
        "built_house_paintings":world.built_house_paintings.duplicate(true),
        "built_house_decorations":world.built_house_decorations.duplicate(true),
        "built_house_origins":world.built_house_origins.duplicate(true),
        "source_interior_mutations":world.source_interior_mutations.duplicate(true),
        "source_plant_farms":world.source_plant_farms.duplicate(true),
        "terrain_changes":world.terrain_changes.duplicate(true),
        "removed_resources":world.removed_resources.keys()}

func model():
    var value=Delta.new();value.state=game.state
    value.can_publish=game.service.areas.can_publish
    return value

## An area's records from its snapshot, a few milliseconds a frame: a whole
## new area written in one frame stalled a server for 30 to 55 ms.
func seed(area:String,shared:Dictionary)->bool:
    _slice_started=Time.get_ticks_usec()
    var delta=model()
    if not game.state.records.get("world_ready/"+area,false):return await delta.seed(game.session.actor,area,shared,_breathe)
    if game.state.records.get("area/"+area,{}).get("population_pending",false) and not await seed_population(area,shared):return false
    # Full snapshots can spend time in flight. Only reconcile entries which
    # still match the sender's baseline; never overwrite a newer accepted build.
    if not shared.get("_coop_build_base") is Dictionary:return true
    var baseline:Dictionary=shared._coop_build_base
    var current=known(area,game.state.records)
    var next=Delta.flatten(builds(shared))
    var keys=current.keys()
    for key in next:
        if String(key).get_slice("/",0) in GROUPS and not current.has(key):keys.append(key)
    var patches:Array=[];var empty=Delta.encode(null)
    for key in keys:
        var old=current.get(key,empty)
        if old!=baseline.get(key,empty):continue
        var value=next.get(key,empty)
        if value!=old:patches.append({"key":key,"before":game.state.fingerprint(old),"after":value})
    while not patches.is_empty():
        var batch=patches.slice(0,Delta.MAX_PATCHES);patches=patches.slice(Delta.MAX_PATCHES)
        var prepared:Dictionary=delta.prepare_changes(area,batch)
        if not prepared.get("ok",false):return false
        var result=game.state.transact(game.session.actor,"buildsync/"+game._id(),prepared.changes)
        if not result.get("ok",false):return false
        game._committed(result)
        await _breathe()
    return true

const SLICE_USEC:=4000
var _slice_started:=0
## The frame goes on once this one has had SLICE_USEC of seeding.
func _breathe()->void:
    if Time.get_ticks_usec()-_slice_started<SLICE_USEC:return
    await get_tree().process_frame
    _slice_started=Time.get_ticks_usec()

## The Pokemon of an area made without them (server_area_maker.gd), as the
## player who placed them sent the area back: written into its records, once,
## and sent to whoever is there.
func seed_population(area:String,shared:Dictionary)->bool:
    var picked:Dictionary={}
    for group in ["wild_pokemon","deployed_pokemon","wild_eggs"]:picked[group]=shared.get(group,[])
    var batch:Array=[]
    for part in Delta.chunks(picked):
        var flat:Dictionary=Delta.flatten(part)
        for key in flat:
            var full:String="world/"+area+"/"+key
            if not game.state.records.has(full):batch.append(game.state.change(full,flat[key]))
        if batch.size()>=Delta.SEED_BATCH:
            var made=game.state.transact(game.session.actor,"population/"+game._id(),batch)
            if not made.get("ok",false):return false
            game._committed(made);batch=[]
            await _breathe()
    if batch.is_empty():return true
    var result=game.state.transact(game.session.actor,"population/"+game._id(),batch)
    if result.get("ok",false):game._committed(result)
    return bool(result.get("ok",false))

static func known(area:String,records:Dictionary)->Dictionary:
    var result:Dictionary={};var prefix="world/"+area+"/"
    for key in records:
        if is_build_key(String(key)) and String(key).begins_with(prefix):result[String(key).trim_prefix(prefix)]=records[key]
    return result

static func overlay(area:String,shared:Dictionary,records:Dictionary)->Dictionary:
    var flat=Delta.flatten(shared)
    flat.merge(known(area,records),true)
    return Delta.inflate(flat,shared)

func build(recipe:String,cell:Vector2i)->void:
    if busy or game._request_busy:return
    busy=true
    var area=game._area()
    var before=Delta.flatten(capture())
    var world=game.main.world
    var target:Vector2i=world._snap_build_cell(recipe,cell)
    world.area.begin()
    if not world.place_structure(recipe,cell):world.area.rollback();busy=false;return
    var patches=Delta.diff(before,Delta.flatten(capture()))
    var result:Dictionary=await game.command("build",{"area":area,"recipe":recipe,
        "x":target.x,"y":target.y,"patches":patches})
    # The host returns the current records, not the loser's old preview.
    # That keeps a simultaneous winner's construction intact on this client.
    if result.get("ok",false):world.area.commit()
    else:put_back(area,patches,result)
    busy=false

## A refused action put back, whatever the reason it was refused: what it
## changed on this World's ground is undone (its area's recording,
## area_state.gd), and the records it touched are laid again as the host
## holds them (its answer, else this game's copy of them). Nothing is put
## back by hand and the session goes on.
func put_back(area:String,patches:Array,result:Dictionary)->void:
    var world=game.main.world
    var cells:Array=world.area.rollback()
    if not game.active:return
    apply_records(area,result.get("authoritative",known_records(area,patches)))
    if not cells.is_empty():world._refresh_exact_pickup_cells(cells)
    if result.get("reason")!="conflict":game.main._show_message("FIELD ACTION COULD NOT BE SAVED.")

## The patches' records as this game holds them now, ready for apply_records.
func known_records(area:String,patches:Array)->Array:
    var records:Dictionary=game.state.records if game.hosting else game.shared_records
    var result:Array=[]
    for patch in patches:
        if not patch is Dictionary or not patch.get("key") is String or not Delta.valid_key(patch.key):continue
        result.append({"key":patch.key,"value":Delta.decode(records.get("world/"+area+"/"+String(patch.key),Delta.encode(null)))})
    return result

func execute(actor:String,id:String,args:Dictionary)->Dictionary:
    var area=String(args.area)
    var transaction=Transaction.new()
    transaction.state=game.state;transaction.areas=game.service.areas;transaction.world_delta=model()
    var result:Dictionary
    if args.get("paint",false):
        result=transaction.paint(actor,id,area,args.patches,String(args.profile_hash))
    elif args.get("remove",false) and args.get("decoration",false):
        result=transaction.remove_decoration(actor,id,area,args.patches,String(args.profile_hash))
    elif args.get("remove",false):
        # Only the host may cut the last public box and empty the world's storage.
        result=transaction.remove(actor,id,area,Vector2i(int(args.x),int(args.y)),String(args.move),args.patches,String(args.profile_hash),
            args.get("wipe_public",false)==true and actor==game.session.actor)
    else:
        result=transaction.commit(actor,id,String(game.state.authority.get(area,"")),area,
            int(game.service.areas.epochs.get(area,0)),String(args.recipe),Vector2i(int(args.x),int(args.y)),
            args.patches,String(args.profile_hash))
    if not result.get("ok",false):
        var authoritative:Array=[]
        for patch in args.patches:
            if not patch is Dictionary or not patch.get("key") is String:continue
            if String(patch.key).get_slice("/",0) not in GROUPS or not Delta.valid_key(patch.key):continue
            authoritative.append({"key":patch.key,"value":Delta.decode(game.state.records.get("world/"+area+"/"+patch.key,Delta.encode(null)))})
        result["authoritative"]=authoritative
    return result

## The field moves are commands the host decides (coop_rules_runtime.gd):
## predicted here, kept or undone by its answer.
func cut(cell:Vector2i,move:String="CUT")->void:
    if busy or game._request_busy:return
    busy=true
    await game.rules.predict("field_cut",{"move":move,"cell":cell,"target":"" if move=="CUT" else "resource"},{"species":String(game.main.world.active_field_species)})
    busy=false

func plant(cell:Vector2i,item:String,animate:bool=true)->bool:
    if busy or game._request_busy:return false
    if int(game.main.inventory.get(item,0))<1:return false
    var world=game.main.world
    if world.exact_world==null:return false
    var tile=world.exact_world.tile_at(cell)
    if not world.plants().valid(tile,item):return false
    busy=true
    var answer:Dictionary=await game.rules.predict("field_dig",{"action":"plant","cell":cell,"item":item})
    busy=false
    if answer.get("ok",false) and animate and answer.has("planted"):await world.plants().animate_planted(cell,tile,String(answer.planted),false)
    return bool(answer.get("ok",false))

func pick_berry(cell:Vector2i)->void:
    if busy or game._request_busy:return
    busy=true
    await game.rules.predict("field_dig",{"action":"berry","cell":cell})
    busy=false

func collect_item(action:String,cell:Vector2i)->void:
    if busy or game._request_busy:return
    busy=true
    await game.rules.predict("field_dig",{"action":"take","cell":cell,"item_action":action})
    busy=false

func dig(cell:Vector2i,choice:String="")->void:
    if busy or game._request_busy:return
    busy=true
    var cmd:={"action":"dig","cell":cell} if choice.is_empty() else {"action":"fill","cell":cell,"choice":choice}
    await game.rules.predict("field_dig",cmd)
    busy=false

func paint(picture:int,cell:Vector2i)->void:
    if busy or game._request_busy:return
    busy=true
    var area=game._area()
    var before=Delta.flatten(capture())
    game.main.world.area.begin()
    if not game.main.world.apply_paint(picture,cell):game.main.world.area.rollback();busy=false;return
    var patches=Delta.diff(before,Delta.flatten(capture()))
    if patches.is_empty():game.main.world.area.commit();busy=false;return
    var result:Dictionary=await game.command("paint",{"area":area,"patches":patches})
    if result.get("ok",false):game.main.world.area.commit()
    else:put_back(area,patches,result)
    busy=false

func remove(cell:Vector2i,move:String,wipe_public:bool=false)->void:
    if busy or game._request_busy:return
    var world=game.main.world
    var piece:Dictionary=world.built_structures.get(cell,{})
    if piece.is_empty():return
    if piece.get("generated_stair_pair",false):
        cell=Vector2i(int(piece.stair_primary_x),int(piece.stair_primary_y))
        piece=world.built_structures.get(cell,{})
        if piece.is_empty():return
    var name=String(piece.get("name",""))
    if (move=="CUT" and name in ["GRAVE","STATUE"]) or (move=="SMASH" and name not in ["GRAVE","STATUE"]):return
    busy=true
    var area=game._area();var before=Delta.flatten(capture())
    world.area.begin()
    world._remove_structure(cell,false)
    var patches=Delta.diff(before,Delta.flatten(capture()))
    var request:={"area":area,"remove":true,"move":move,"x":cell.x,"y":cell.y,"patches":patches}
    if wipe_public:request["wipe_public"]=true
    var result:Dictionary=await game.command("remove_build",request)
    if result.get("ok",false):
        world.area.commit()
        game.main._on_build_refund_requested(result.get("refund",{}),false)
        if name=="GRAVE" and world.rng.randi_range(0,8)==0:
            var pool=["gastly","misdreavus","duskull","shuppet"]
            var species=pool[world.rng.randi_range(0,3)]
            world.world_message.emit("Something rose from the shattered GRAVE!")
            world.encounter_requested.emit(species,22)
    else:
        if game.active and result.get("reason")=="last_box":
            game.main._show_message("Sorry, a guest cannot cut the last public box in a world." if not game.hosting else "The last STORAGE BOX in this world cannot be cut this way.")
        put_back(area,patches,result)
    busy=false

## Takes a window or clock off a house wall; the host refunds its materials.
func remove_decoration(cell:Vector2i)->void:
    if busy or game._request_busy:return
    var world=game.main.world
    if String(world.house_wall_decoration_at(cell)).is_empty():return
    busy=true
    var area=game._area();var before=Delta.flatten(capture())
    world.area.begin()
    world.remove_house_wall_decoration(cell,false)
    var patches=Delta.diff(before,Delta.flatten(capture()))
    var result:Dictionary=await game.command("remove_build",{"area":area,"remove":true,"decoration":true,"move":"CUT",
        "x":cell.x,"y":cell.y,"patches":patches})
    if result.get("ok",false):
        world.area.commit()
        game.main._on_build_refund_requested(result.get("refund",{}),false)
    else:put_back(area,patches,result)
    busy=false

func committed(changes:Array)->void:
    var area=game._area();var prefix="world/"+area+"/"
    var records:Array=[]
    for change in changes:
        if is_build_key(String(change.key)) and String(change.key).begins_with(prefix):
            records.append({"key":String(change.key).trim_prefix(prefix),"value":Delta.decode(String(change.after))})
    if not records.is_empty():apply_records(area,records)

func sync_current()->void:
    var area=game._area()
    var current=Delta.flatten(capture())
    var authoritative=known(area,game.state.records if game.hosting else game.shared_records)
    var changes:Array=[]
    for key in authoritative:
        if current.get(key,Delta.encode(null))!=authoritative[key]:changes.append({"key":key,"value":Delta.decode(authoritative[key])})
    if not changes.is_empty():apply_records(area,changes,true)

## A day's dig site record, or none: a dig site added, renewed or taken away.
static func _dig_site(value)->bool:
    return value==null or value is Dictionary and value.get("kind")=="BIOME_DIG_SITE"

func apply_records(area:String,records:Array,arriving:bool=false)->void:
    if area!=game._area() or not game.main.world.generated:return
    if not arriving and (game.main.generating or game.main.edge_travel_busy):return
    var world=game.main.world
    var house_changed=false
    var structures:Array=[]
    var was_restoring:bool=world.restoring_saved_tiles
    var refresh_pending:bool=world.restored_tiles_need_refresh
    var changed_cells:Dictionary={}
    var dug_cells:Array=[]
    var decorated:Dictionary={}
    world.restoring_saved_tiles=true
    # The host's changes are not this player's prediction: they are not undone with it.
    var was_recording:bool=world.area.suspend()
    for record in records:
        var group=String(record.key).get_slice("/",0)
        var key=String(record.key).get_slice("/",1).uri_decode()
        game.rules.supersede(group,key)
        if group=="structures":structures.append(record);continue
        if group not in GROUPS:continue
        var dictionary:Dictionary=world.get(group)
        # A dig site changes its own cell only (the layers redraw around it
        # themselves), and a new day brings ~200 of them: 25 cells each, all in
        # one frame, was ~90 ms on a desktop. The world hands them to the
        # layers a few at a time instead.
        if group=="source_interior_mutations" and _dig_site(record.value) and _dig_site(dictionary.get(key)):
            dug_cells.append(world._cell_from_key(key))
        elif group in ["source_interior_mutations","source_plant_farms","terrain_changes","removed_resources"]:
            var center:Vector2i=world._cell_from_key(key)
            for y in range(-2,3):
                for x in range(-2,3):changed_cells[center+Vector2i(x,y)]=true
        if record.value==null:dictionary.erase(key)
        else:dictionary[key]=true if group in ["built_house_floor_tiles","removed_resources"] else record.value
        if group=="removed_resources":
            if record.value!=null:world._remove_resource(world._cell_from_key(key),false)
            continue
        if group=="terrain_changes":
            if record.value!=null:
                var at:Vector2i=world._cell_from_key(key)
                world._set_exact_tile_names(at,"sand1" if int(record.value)==1 else "green1","")
            continue
        if group=="source_plant_farms":
            if record.value is Dictionary and world.exact_world!=null:
                world._set_exact_tile_names(world._cell_from_key(key),String(record.value.base),String(record.value.upper))
            continue
        if group=="source_interior_mutations":
            if record.value is Dictionary:world._apply_source_interior_mutation(world._cell_from_key(key),record.value)
            continue
        # A floor tile added upstairs is laid on its own. Rebuilding the whole
        # inside of the house for each one made every floor blink black.
        if group=="built_house_floor_tiles" and record.value!=null:
            var parts=key.split("|")
            if parts.size()==3 and world.active_area_id=="HOUSE":
                var door=parts[0].split(",");var local=parts[2].split(",")
                if door.size()==2 and local.size()==2 and Vector2i(int(door[0]),int(door[1]))==world.active_built_house_door:
                    if world._add_built_house_floor_cell(int(parts[1]),Vector2i(int(local[0]),int(local[1])),false):continue
                else:continue
            elif world.active_area_id!="HOUSE":continue
        # A carpet, clock or window is drawn or taken away on its own as well.
        if group=="built_house_decorations":
            if world.active_area_id!="HOUSE":continue
            var pieces=key.split("|")
            var door_at=pieces[0].split(",");var local_at=pieces[pieces.size()-1].split(",")
            if pieces.size() not in [2,3] or door_at.size()!=2 or local_at.size()!=2:house_changed=true;continue
            if Vector2i(int(door_at[0]),int(door_at[1]))!=world.active_built_house_door:continue
            var storey:int=int(String(pieces[1]).trim_prefix("F")) if pieces.size()==3 else 0
            decorated[world._built_house_global_cell(storey,Vector2i(int(local_at[0]),int(local_at[1])))]=record.value!=null
            continue
        house_changed=true
    world.restoring_saved_tiles=was_restoring
    if not was_restoring:
        world.restored_tiles_need_refresh=refresh_pending
        if not changed_cells.is_empty():world._refresh_exact_pickup_cells(changed_cells.keys())
        if not dug_cells.is_empty():world._queue_exact_refresh(dug_cells)
    for record in structures:
        var parts=String(record.key).get_slice("/",1).uri_decode().split(",")
        var cell=Vector2i(int(parts[0]),int(parts[1]))
        var existing:Dictionary=world.built_structures.get(cell,{})
        if record.value==null:
            if not existing.is_empty():world._remove_structure(cell,false)
            continue
        var value:Dictionary=record.value
        if existing.is_empty():
            if not world.place_structure(String(value.get("recipe_name",value.name)),cell,true,value,true):
                # An outside piece recorded somewhere that is not on the open map
                # (built inside a house by an older version) can never be placed.
                # It is passed over; it used to end the session for everyone.
                if String(value.get("name","")) in ["FENCE","WALL","ROOF","DOOR"] and not world._in_bounds(cell):continue
                world.area.resume(was_recording);game.end_session("SHARED BUILD COULD NOT LOAD. REJOIN THE WORLD.");return
        else:
            for key in value:
                if key not in ["sprite","collision","solid","bridged_water","x","y"]:existing[key]=value[key]
            if is_instance_valid(existing.get("sprite")):
                var texture=world._structure_display_texture(String(value.get("recipe_name",value.name)),int(value.get("variant",0)))
                if value.name=="BED" and int(value.get("bed_carpet",0))>0:texture=world._colored_bed_texture(int(value.bed_carpet))
                existing.sprite.texture=texture
            world._refresh_connected_structures_around(cell)
            world._refresh_shell_attachment(cell)
        if value.name=="STAIRS":house_changed=true
    if not house_changed and world.active_area_id=="HOUSE":
        for at in decorated:
            if decorated[at]:world._draw_house_decoration(at)
            else:
                var hung=world.built_house_decoration_sprites.get(at)
                if is_instance_valid(hung):hung.queue_free()
                world.built_house_decoration_sprites.erase(at)
    if house_changed and world.active_area_id=="HOUSE":
        var floor_index:int=world._built_house_floor_index_for_cell(world._player_cell())
        var house:Dictionary=world._built_house_state(world.active_built_house_door)
        if house.get("ready",false):
            world._prepare_built_house_interior(world.active_built_house_door,house)
            world._set_active_built_house_floor(maxi(0,floor_index))
            var layer=world.get_node_or_null("BuiltHouseInterior")
            if layer!=null:layer.visible=true
    world.map_art_revision+=1
    world.area.resume(was_recording)
