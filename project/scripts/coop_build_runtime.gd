extends Node
## The co-op side of the built and dug ground. A player's field moves,
## builds, paint and removals are commands the host decides (rules/,
## coop_rules_runtime.gd), predicted here, several at a time; the host adds
## what such a command changes outside its area (host_records). The host's
## records of an area are laid on this World as they come (apply_records),
## and an area's snapshot seeds them (seed).
const Delta=preload("res://scripts/coop_world_delta.gd")
const Crafting=preload("res://scripts/crafting_data.gd")
const GROUPS=["structures","built_house_floor_tiles","built_house_paintings",
    "built_house_decorations","built_house_origins","source_interior_mutations","source_plant_farms","removed_resources","terrain_changes"]
var game:Node
## This player's field commands in flight (coop_rules_runtime.gd predict).
var in_flight:=0
var busy:bool:
    get:return in_flight>0

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
    _slice_started=Time.get_ticks_usec();_batch_started=_slice_started
    var delta=model()
    if not game.state.records.get("world_ready/"+area,false):return await delta.seed(game.session.actor,area,shared,_breathe)
    if game.state.records.get("area/"+area,{}).get("population_pending",false) and not await seed_population(area,shared):return false
    # Full snapshots can spend time in flight. Only reconcile entries which
    # still match the sender's baseline; never overwrite a newer accepted build.
    if not shared.get("_coop_build_base") is Dictionary:return true
    var baseline:Dictionary=shared._coop_build_base
    var current=known(area,game.state.records,game.state.keys_by_area.get(area,{}))
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
var _batch_started:=0
## The frame goes on once this one has had SLICE_USEC of seeding, or would
## have with another batch like the last (a batch past the slice made frames
## of 12-18 ms).
func _breathe()->void:
    var now:=Time.get_ticks_usec()
    var batch:=now-_batch_started
    _batch_started=now
    if now-_slice_started+batch<SLICE_USEC:return
    await get_tree().process_frame
    _slice_started=Time.get_ticks_usec();_batch_started=_slice_started

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

## `keys`: the area's keys when the records are the host's (coop_state.gd
## keys_by_area), not every record of the world (10 ms at 60,000).
static func known(area:String,records:Dictionary,keys:Variant=null)->Dictionary:
    var result:Dictionary={};var prefix="world/"+area+"/"
    for key in (records if keys==null else keys):
        if is_build_key(String(key)) and String(key).begins_with(prefix):result[String(key).trim_prefix(prefix)]=records[key]
    return result

static func overlay(area:String,shared:Dictionary,records:Dictionary)->Dictionary:
    var flat=Delta.flatten(shared)
    flat.merge(known(area,records),true)
    return Delta.inflate(flat,shared)

## The field moves, builds, paint and removals are commands the host decides
## (coop_rules_runtime.gd): predicted here, kept or undone by its answer.
func _send(op:String,cmd:Dictionary,extra:Dictionary={})->Dictionary:
    in_flight+=1
    var answer:Dictionary=await game.rules.predict(op,cmd,extra)
    in_flight-=1
    return answer

func build(recipe:String,cell:Vector2i)->void:
    if game._request_busy:return
    await _send("build",{"recipe":recipe,"cell":game.main.world._snap_build_cell(recipe,cell)})

func paint(picture:int,cell:Vector2i)->void:
    if game._request_busy:return
    await _send("paint",{"cell":cell,"picture":picture},{"species":String(game.main.world.active_field_species)})

## A built piece cut or smashed; `wipe_public`: the host has agreed to empty
## the world's storage with its last public box (field_actions.gd).
func remove(cell:Vector2i,move:String,wipe_public:bool=false)->void:
    if game._request_busy:return
    var cmd:={"cell":cell,"move":move}
    if wipe_public:cmd["wipe"]=true
    var answer:Dictionary=await _send("remove_build",cmd)
    if game.active and answer.get("reason")=="last_box":
        game.main._show_message("Sorry, a guest cannot cut the last public box in a world." if not game.hosting else "The last STORAGE BOX in this world cannot be cut this way.")

## Takes a window or clock off a house wall; the host refunds its materials.
func remove_decoration(cell:Vector2i)->void:
    if game._request_busy:return
    await _send("remove_build",{"cell":cell,"move":"CUT","decoration":true})

## A built piece changed for everyone (rules/interact.gd: a sign, a beacon's
## name, a torch, a window, a plant's seed).
func interact(cmd:Dictionary)->void:
    if game._request_busy:return
    await _send("interact",cmd)

func cut(cell:Vector2i,move:String="CUT")->void:
    if game._request_busy:return
    await _send("field_cut",{"move":move,"cell":cell,"target":"" if move=="CUT" else "resource"},{"species":String(game.main.world.active_field_species)})

func plant(cell:Vector2i,item:String,animate:bool=true)->bool:
    if game._request_busy:return false
    if int(game.main.inventory.get(item,0))<1:return false
    var world=game.main.world
    if world.exact_world==null:return false
    var tile=world.exact_world.tile_at(cell)
    if not world.plants().valid(tile,item):return false
    var answer:Dictionary=await _send("field_dig",{"action":"plant","cell":cell,"item":item})
    if answer.get("ok",false) and animate and answer.has("planted"):await world.plants().animate_planted(cell,tile,String(answer.planted),false)
    return bool(answer.get("ok",false))

func pick_berry(cell:Vector2i)->void:
    if game._request_busy:return
    await _send("field_dig",{"action":"berry","cell":cell})

func collect_item(action:String,cell:Vector2i)->void:
    if game._request_busy:return
    await _send("field_dig",{"action":"take","cell":cell,"item_action":action})

func dig(cell:Vector2i,choice:String="")->void:
    if game._request_busy:return
    await _send("field_dig",{"action":"dig","cell":cell} if choice.is_empty() else {"action":"fill","cell":cell,"choice":choice})

# --- The host ---------------------------------------------------------------------

## Host: a pre-check of a build the host's copy of the area cannot make
## itself: a Pokemon or egg on the cell of a solid piece, from the records
## (an area held without a World has no Pokemon in it). "" when there is none.
func occupied(area:String,op:String,cmd:Dictionary)->String:
    if op!="build" or not bool(Crafting.build_recipe(String(cmd.recipe)).get("solid",false)):return ""
    var spot:=("%d,%d"%[cmd.cell.x,cmd.cell.y]).uri_encode()
    for group in ["deployed_pokemon","wild_eggs"]:
        if Delta.decode(game.state.records.get("world/"+area+"/"+group+"/"+spot,Delta.encode(null))) is Dictionary:return "occupied"
    return ""

## Host: what a build or removal by `actor` changes outside its area, in the
## same commit: a box or chest registered with its construction (a catch just
## after must find it), a beacon; a box or beacon taken away with its piece.
## The last public STORAGE BOX in the world goes only when the host itself
## cuts it and empties the world's storage with it: {"reason": "last_box"}
## otherwise. {"changes": [...]} for the commit.
func host_records(actor:String,op:String,area:String,cmd:Dictionary,result:Dictionary,area_state)->Dictionary:
    var state=game.state
    var changes:Array=[]
    if op=="build":
        var cell:Vector2i=cmd.cell
        var recipe:=String(cmd.recipe)
        var placed:Dictionary=area_state.structures.get(cell,{})
        var box:=area+"|%d,%d"%[cell.x,cell.y]
        if recipe in ["STORAGE BOX","PRIVATE CHEST"] and placed.get("name")==recipe:
            changes.append(state.change("chest/"+box,{"id":box,"area":area,"x":cell.x,"y":cell.y,"private":recipe=="PRIVATE CHEST","capacity":4096}))
            if recipe=="STORAGE BOX" and not state.records.has("box/"+box):changes.append(state.change("box/"+box,[]))
        elif recipe=="BEACON" and placed.get("name")=="BEACON" and not placed.has("house_door"):
            changes.append(state.change("beacon/"+box,{"area":area,"x":cell.x,"y":cell.y,"name":"BEACON"}))
        return {"changes":changes}
    if op=="interact" and cmd.action=="beacon":
        # Its name, as the BEACONS menu lists it (coop_beacons.gd).
        var key:="beacon/"+area+"|%d,%d"%[cmd.cell.x,cmd.cell.y]
        if state.records.get(key) is Dictionary:
            var named:Dictionary=state.records[key].duplicate(true)
            named["name"]=String(cmd.get("text","")).strip_edges().left(32)
            if String(named.name).is_empty():named["name"]="BEACON"
            changes.append(state.change(key,named))
    if op!="remove_build":return {"changes":changes}
    var going:Array=[]
    var boxes_going:Array=[]
    for event in result.events:
        if event[0]!="unbuilt" or bool(event[2].get("generated_stair_pair",false)):continue
        var gone:=area+"|%d,%d"%[event[1].x,event[1].y]
        going.append(gone)
        if event[2].get("name")=="STORAGE BOX":boxes_going.append(gone)
    # A public box may be cut with Pokemon in it while another stands in this
    # world; they stay reachable from the others.
    var losing_last:=false
    # Looked up only when a box is involved; it reads every built piece.
    if not boxes_going.is_empty():
        var standing:Array=_public_boxes()
        losing_last=not standing.is_empty() and standing.all(func(box):return box in boxes_going)
    if losing_last and not (cmd.get("wipe",false)==true and actor==game.session.actor):return {"reason":"last_box"}
    for gone in going:
        if state.records.has("chest/"+gone):
            var chest:Dictionary=state.records["chest/"+gone].duplicate(true);chest["retired"]=true
            changes.append(state.change("chest/"+gone,chest))
        if state.records.has("beacon/"+gone):changes.append(state.change("beacon/"+gone,null))
    if losing_last:
        # The world goes back to having no storage: every public box is emptied.
        for record_key in state.records.keys():
            if String(record_key).begins_with("box/") and not (state.records[record_key] as Array).is_empty():
                changes.append(state.change(String(record_key),[]))
    return {"changes":changes}

## Every public STORAGE BOX standing in this world, as "area|x,y". Counted
## from the boxes that are actually built, in every area. The list of box
## records is not a safe count: a box that has been cut stays in it, and it
## let a guest cut the last box standing.
func _public_boxes()->Array:
    var result:Array=[]
    for record_key in game.state.records:
        var key:=String(record_key)
        if not key.begins_with("world/"):continue
        var parts:=key.split("/")
        if parts.size()!=4 or parts[2]!="structures":continue
        var built=Delta.decode(game.state.records[record_key])
        if built is Dictionary and built.get("name")=="STORAGE BOX":result.append(parts[1]+"|"+parts[3].uri_decode())
    return result

## The inside of the house this player is in, drawn again from the World's data.
func redraw_house()->void:
    var world=game.main.world
    if world.active_area_id!="HOUSE":return
    var floor_index:int=world._built_house_floor_index_for_cell(world._player_cell())
    var house:Dictionary=world._built_house_state(world.active_built_house_door)
    if not house.get("ready",false):return
    world._prepare_built_house_interior(world.active_built_house_door,house)
    world._set_active_built_house_floor(maxi(0,floor_index))
    var layer=world.get_node_or_null("BuiltHouseInterior")
    if layer!=null:layer.visible=true

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
    if house_changed:redraw_house()
    world.map_art_revision+=1
    world.area.resume(was_recording)
