extends Node
## Uses the existing storage panels; the host commits each transfer once.
var game:Node
var rows:Dictionary={}
var selected:Dictionary={}
var busy:=false
var pending:Array=[]
var sort_mode:=""

func sort_less(a:Dictionary,b:Dictionary)->bool:
    var display=preload("res://scripts/pokemon_state.gd")
    var left=display.display_name(a).to_upper();var right=display.display_name(b).to_upper()
    if sort_mode=="TYPE":
        left=preload("res://scripts/coop_shared_items.gd").primary_type(a)+"/"+left
        right=preload("res://scripts/coop_shared_items.gd").primary_type(b)+"/"+right
    return left.naturalnocasecmp_to(right)<0

func handle_key(event:InputEvent)->bool:
    if busy or game.main.storage_mode!="LIST" or not event is InputEventKey or not event.pressed or event.echo:return false
    if event.keycode in [KEY_1,KEY_2]:
        var chosen="NAME" if event.keycode==KEY_1 else "TYPE"
        sort_mode="" if sort_mode==chosen else chosen
        refresh();return true
    if event.is_action_pressed("confirm") or event.is_action_pressed("cancel"):return false
    if event.unicode<65 or event.unicode>122:return false
    var letter=String.chr(event.unicode).to_upper()
    var entries:Array=game.main._storage_entries()
    for offset in range(1,entries.size()+1):
        var index=(game.main.storage_index+offset)%entries.size()
        if preload("res://scripts/pokemon_state.gd").display_name(entries[index]).to_upper().begins_with(letter):
            game.main.storage_index=index;game.main._refresh_storage_menu();return true
    return false

func route_received(pokemon:Dictionary)->String:
    for box in game.main._built_storage_keys():
        # A newly placed box can exist before its area publication reaches the
        # host. Keep the catch in the personal checkpoint until registration;
        # skipping that box here would permanently release the caught Pokemon.
        var chest:Dictionary=game.shared_records.get("chest/"+box,{})
        var private_pool=bool(chest.get("private",false))
        var count=game.shared_records.get("private_box/"+game.session.actor,[]).size() if private_pool else game.shared_records.get("box/"+box,[]).size()
        for receipt in pending:
            var receipt_chest:Dictionary=game.shared_records.get("chest/"+String(receipt.box),{})
            if receipt.box==box or (private_pool and bool(receipt_chest.get("private",false))):count+=1
        if count>=4096:continue
        pending.append({"id":preload("res://scripts/coop_random.gd").hex(16),"box":box,"pokemon":pokemon.duplicate(true)})
        game.main.pokedex_progress.mark(pokemon,true)
        return "STORAGE"
    return "RELEASED"

func profile_changes(actor:String,profile:Dictionary)->Array:
    var changes:Array=[]
    var boxes:Dictionary={}
    var remaining:Array=[]
    for receipt in profile.get("save",{}).get("coop_pending_pokemon",[]):
        if not receipt is Dictionary or not receipt.get("id") is String or not receipt.get("pokemon") is Dictionary or not receipt.get("box") is String:continue
        var receipt_key="received/"+actor+"/"+receipt.id
        if game.state.records.has(receipt_key):continue
        var chest:Dictionary=game.state.records.get("chest/"+receipt.box,{})
        if chest.is_empty():remaining.append(receipt);continue
        var key=game.commands.items.box_key(actor,chest)
        if not boxes.has(key):boxes[key]=game.state.records.get(key,[]).duplicate(true)
        if boxes[key].size()>=4096:remaining.append(receipt);continue
        boxes[key].append({"id":receipt.id,"pokemon":receipt.pokemon})
        changes.append(game.state.change(receipt_key,true))
    for key in boxes:changes.append(game.state.change(key,boxes[key]))
    profile.save["coop_pending_pokemon"]=remaining
    changes.append(game.state.change("player/"+actor,profile))
    return changes

func settle(sent:Array,remaining:Array)->void:
    var ids:Dictionary={}
    for receipt in sent:ids[receipt.id]=true
    var keep:Array=[]
    for receipt in pending:
        if not ids.has(receipt.id):keep.append(receipt)
    keep.append_array(remaining.duplicate(true));pending=keep

func broadcast_profile_storage(result:Dictionary)->void:
    if not result.get("ok",false):return
    var visible=result.duplicate(true)
    visible.changes=[]
    for change in result.changes:
        if String(change.key).begins_with("box/") or String(change.key).begins_with("private_box/"):visible.changes.append(change)
    if not visible.changes.is_empty():game._committed(visible)

func configure(coordinator:Node)->void:game=coordinator

func register_objects(area:String,shared:Dictionary)->bool:
    if is_instance_valid(game.building) and not await game.building.seed(area,shared):return false
    # Registration follows the accepted journal, including edits committed while
    # this full-area snapshot was travelling from another player. Only the
    # structures are read below, so only they are overlaid: packing and
    # unpacking all of a long-played area again stalled the host each time.
    if is_instance_valid(game.building):
        var placed:Dictionary={}
        var prefix:="world/"+area+"/structures/"
        for key in game.state.records:
            if String(key).begins_with(prefix):placed[key]=game.state.records[key]
        shared=game.building.overlay(area,{"structures":shared.get("structures",[])},placed)
    var changes:Array=[]
    if is_instance_valid(game.beacons):changes.append_array(game.beacons.registry_changes(area,shared))
    for piece in shared.get("structures",[]):
        if piece.get("name") not in ["STORAGE BOX","PRIVATE CHEST"]:continue
        var id=area+"|%d,%d"%[int(piece.x),int(piece.y)]
        var key="chest/"+id
        var record={"id":id,"area":area,"x":int(piece.x),"y":int(piece.y),"private":piece.name=="PRIVATE CHEST","capacity":4096}
        if game.state.records.get(key,{})!=record:changes.append(game.state.change(key,record))
        if not record.private and not game.state.records.has("box/"+id):
            var contents:Array=[]
            for pokemon in game.main.pokemon_storage.get(id,[]):
                contents.append({"id":preload("res://scripts/coop_random.gd").hex(16),"pokemon":pokemon.duplicate(true)})
            changes.append(game.state.change("box/"+id,contents))
    if changes.is_empty():return true
    var result=game.state.transact(game.session.actor,"registry/"+game._id(),changes)
    if result.get("ok",false):game._committed(result);return true
    return false

## True when the shared world already holds this box: its chest record and,
## for a shared box, its contents.
func known(id:String)->bool:
    var records:Dictionary=game.state.records if game.hosting else game.shared_records
    var chest=records.get("chest/"+id)
    if not chest is Dictionary or String(chest.get("id",""))!=id:return false
    return bool(chest.get("private",false)) or records.has("box/"+id)

func prepare()->bool:
    if game.hosting:return await game._flush_area(game._area())
    var result:Dictionary=await game._rpc({"kind":"storage_open","id":game._id(),"area":game._area()})
    return bool(result.get("ok",false))

func refresh()->void:
    if not game.active:return
    var mirrored:Dictionary={}
    rows={}
    var private_id=""
    var wanted=game.main.storage_box_key if not game.main.storage_box_key.is_empty() else game.main.preferred_storage_box
    for key in game.shared_records:
        if not String(key).begins_with("chest/"):continue
        var chest:Dictionary=game.shared_records[key]
        if chest.get("private",false):
            if private_id.is_empty() or chest.id==wanted:private_id=chest.id
            continue
        _mirror(mirrored,chest.id,game.shared_records.get("box/"+chest.id,[]))
    # The private box travels with its owner, so it opens only at a private
    # chest. The menu's STORAGE view would otherwise hand a player their
    # strongest Pokemon the moment they arrive in a world.
    if not private_id.is_empty() and not game.main.storage_pooled:_mirror(mirrored,private_id,game.shared_records.get("private_box/"+game.session.actor,[]))
    game.main.pokemon_storage=mirrored
    if game.main.storage_menu_open:game.main._refresh_storage_menu()

func _mirror(mirrored:Dictionary,id:String,records:Array)->void:
    records=records.duplicate(true)
    if not sort_mode.is_empty():records.sort_custom(func(a,b):return sort_less(a.pokemon,b.pokemon))
    rows[id]=records
    var pokemon:Array=[]
    for entry in records:pokemon.append(entry.pokemon.duplicate(true))
    mirrored[id]=pokemon

func location(index:int)->Dictionary:
    var box=game.main.storage_box_key
    if game.main.storage_pooled:
        var locations=game.main._storage_pool_locations()
        if index<0 or index>=locations.size():return {}
        box=String(locations[index][0]);index=int(locations[index][1])
    var entries:Array=rows.get(box,[])
    if index<0 or index>=entries.size():return {}
    return {"box":box,"pokemon":String(entries[index].id)}

func select()->void:
    selected=location(game.main.storage_index) if game.main.storage_column==1 else {"slot":game.main.storage_index}

func apply()->void:
    if busy:return
    busy=true
    var main=game.main
    var action=String(main.storage_pending)
    var result:Dictionary={"ok":false,"reason":"too_late"}
    if main.storage_column==0:
        var slot=int(selected.get("slot",-1))
        if slot>=0 and slot<main.caught_pokemon.size() and action in ["STORE","RELEASE"] and main._storage_is_active(main.caught_pokemon[slot]):main.world.clear_active_field_move(true)
        if action in ["STORE","STORE TYPE"]:
            result=await game.command("deposit_type" if action=="STORE TYPE" else "deposit",{"box":main._storage_deposit_key(),"slot":slot,"pooled":main.storage_pooled})
        elif slot>=0 and slot<main.caught_pokemon.size():
            if action=="NICKNAME":main.caught_pokemon[slot].nickname=main.storage_nickname.text
            elif action=="RELEASE":main.caught_pokemon.remove_at(slot)
            result={"ok":await game.checkpoint_player()}
    elif not selected.is_empty():
        var args=selected.duplicate();args["pooled"]=main.storage_pooled
        if action=="TAKE":result=await game.command("withdraw",args)
        else:
            args["action"]=action;args["value"]=main.storage_nickname.text if action=="NICKNAME" else ""
            result=await game.command("storage_edit",args)
    busy=false
    if result.get("ok",false):
        main._sync_pokedex_owned();main.world.play_source_sound("ball_switch1")
    else:main._storage_notice("Too late!" if result.get("reason")=="too_late" else "Storage could not complete that action.")

func swap(second:int)->void:
    if busy or selected.is_empty():return
    var target=location(second)
    if target.is_empty():game.main._storage_notice("Too late!");return
    busy=true
    var args=selected.duplicate();args["other_box"]=target.box;args["other_pokemon"]=target.pokemon;args["pooled"]=game.main.storage_pooled
    var result=await game.command("storage_swap",args)
    busy=false
    if not result.get("ok",false):game.main._storage_notice("Too late!")
