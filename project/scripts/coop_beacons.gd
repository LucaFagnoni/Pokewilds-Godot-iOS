extends Node
## Catalog entries refer to host-saved areas; travel never generates a replacement.
var game:Node
var destinations:Array=[]
var busy:=false

func configure(coordinator:Node)->void:game=coordinator

func registry_changes(area:String,shared:Dictionary)->Array:
    var wanted:Dictionary={}
    for piece in shared.get("structures",[]):
        if piece.get("name")!="BEACON":continue
        # An outdoor beacon uses ordinary map coordinates. Interior TELEPORT
        # remains the existing field move and is not a cross-island exit.
        if piece.has("house_door"):continue
        var key="beacon/"+area+"|%d,%d"%[int(piece.x),int(piece.y)]
        wanted[key]={"area":area,"x":int(piece.x),"y":int(piece.y),"name":String(piece.get("label","BEACON")).strip_edges().left(32)}
        if wanted[key].name.is_empty():wanted[key].name="BEACON"
    var changes:Array=[]
    # Only the keys of no area, as "beacon/" ones are (coop_state.gd keys_by_area):
    # a walk over every record of the world was 17 ms of an area's save at 60,000.
    for key in game.state.keys_by_area.get("",{}):
        if String(key).begins_with("beacon/"+area+"|") and not wanted.has(key):changes.append(game.state.change(key,null))
    for key in wanted:
        if game.state.records.get(key)!=wanted[key]:changes.append(game.state.change(key,wanted[key]))
    return changes

func open()->void:
    if busy:return
    busy=true
    var ui=game.interaction_ui
    ui.phase="beacons";ui.selection=0;destinations=[];ui.show();ui.refresh()
    if not await game.storage.prepare():
        busy=false;ui.hide();game.main._show_message("BEACONS COULD NOT LOAD.");return
    for key in game.shared_records:
        if String(key).begins_with("beacon/"):
            var record:Dictionary=game.shared_records[key].duplicate(true)
            record["key"]=key;destinations.append(record)
    destinations.sort_custom(func(a,b):
        var left=String(a.name)+" "+String(a.area);var right=String(b.name)+" "+String(b.area)
        return left.naturalnocasecmp_to(right)<0)
    busy=false
    if ui.visible and ui.phase=="beacons":ui.refresh()

func names()->Array:
    var result:Array=[]
    for entry in destinations:result.append("%s (%s)"%[entry.name,entry.area])
    return result

func travel(index:int)->void:
    if busy or index<0 or index>=destinations.size():return
    var destination:Dictionary=destinations[index]
    if not game.shared_records.has(destination.key):game.interaction_ui.hide();return
    busy=true;game.interaction_ui.hide()
    var main=game.main;var world=main.world
    world.set_gameplay_enabled(false)
    main.edge_travel_busy=true
    var parts=String(destination.area).split(",")
    var grid=Vector2i(int(parts[0]),int(parts[1]))
    world.clear_active_field_move(false)
    if grid!=main.current_world_grid:await main._travel_adjacent_world(grid-main.current_world_grid)
    if game.active and main.current_world_grid==grid:
        var cell=Vector2i(int(destination.x),int(destination.y))
        if world.built_structures.get(cell,{}).get("name")=="BEACON":
            world.player.position=world._cell_center(cell)
            world.player.velocity=Vector2.ZERO
            world._sync_follower_to_player()
            world.begin_encounter_grace();world.reveal_player_area()
            world.player.camera.reset_smoothing()
            await game.checkpoint_player()
        else:main._show_message("THAT BEACON IS NO LONGER THERE.")
    main.edge_travel_busy=false;busy=false
    world.set_gameplay_enabled(not main._field_ui_blocks_gameplay())
