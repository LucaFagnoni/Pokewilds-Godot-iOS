extends RefCounted

# PlantTree, PlayerStanding, Tile.items and CycleDayNight from 0.8.11.
var world: Node2D
var last_checked_day := -1
var indexed_world_id := 0
var indexing := false
var growing := false

func configure(owner_world: Node2D) -> void:
    world = owner_world

func day() -> int:
    # Growth happens after dawn's 320-frame fade, not at midnight.
    return maxi(0, floori((world.world_elapsed_seconds-320.0/60.0)/world.WORLD_DAY_SECONDS))

static func plantable(item: String) -> bool:
    return item in ["BERRY SEED","MIRACLE SEED","MANURE"] or item.ends_with(" APRICORN")

static func berry_for_ground(base: String) -> String:
    if "desert" in base: return "rawst"
    if "sand" in base: return "pecha"
    if "snow" in base: return "aspear"
    if base in ["green9","green10","green11","green12"]: return "chesto"
    if "savanna" in base: return "cheri"
    if "volcano" in base: return "lum"
    return "persim"

func valid(tile: SourceTile, item: String) -> bool:
    if tile == null: return false
    var base := tile.name
    var upper := tile.name_upper
    if not tile.has_item.is_empty(): return false
    # DIG stores a dry hole in the upper layer; its underlying soil still
    # determines the crop. Flooded holes have water/lava bases, not dry soil.
    var dry_hole := upper.begins_with("hole1") and "water" not in base and "lava" not in base
    if dry_hole:
        upper = ""
    if item == "MANURE":
        return "fertilized" not in upper and ("tree_planted" in upper or "bush2_color" in upper)
    if item.ends_with(" APRICORN"):
        return (base=="green1" or "flower" in base or "sand" in base or "snow" in base or "desert" in base) and "tree" not in upper and (not tile.is_solid or dry_hole)
    if not upper.is_empty(): return false
    var soil := base=="green1" or base in ["green9","green10","green11","green12"] or "snow" in base or "sand" in base or "desert" in base or "green_savanna" in base or "flower" in base
    return soil or (item=="BERRY SEED" and ("volcano" in base or "savanna" in base or "graveyard" in base))

func plant(cell: Vector2i, item: String, animate: bool = true) -> bool:
    var coordinator=world.get_parent().get("coop_game")
    if is_instance_valid(coordinator) and coordinator.active and not coordinator.building.collecting:
        return await coordinator.building.plant(cell,item,animate)
    if world.exact_world == null or world.active_area_id!="OVERWORLD": return false
    var tile: SourceTile=world.exact_world.tile_at(cell)
    if not valid(tile,item):
        world.world_message.emit("That plant cannot grow here.")
        return false
    var upper := "tree_planted2"
    if item=="MANURE":
        upper=tile.name_upper+"_fertilized"
        tile.set_names("mountain1",upper)
    else:
        upper="berry_planted" if item=="BERRY SEED" else "grass_planted" if item=="MIRACLE SEED" else "tree_planted2"
        tile.set_names(tile.name,upper)
        # Replace a saved DIG hole too, so it cannot return after harvesting
        # this crop and reloading. Reconnect remaining neighboring holes.
        var key: String = world._cell_key(cell)
        var mutation: Dictionary = world.source_interior_mutations.get(key, {})
        if String(mutation.get("upper", "")).begins_with("hole1"):
            world._save_source_dig_tile(cell)
        world._connect_source_dig_holes(cell)
    store(cell,tile)
    world.play_source_sound("seed1")
    _redraw_around(cell)
    if animate and item not in ["MANURE","MIRACLE SEED"]:
        await animate_planted(cell,tile,upper)
    return true

func animate_planted(cell:Vector2i,tile:SourceTile,upper:String,mutate_tile:bool=true)->void:
    if mutate_tile:tile.set_names(tile.name,"")
    _redraw_around(cell)
    var main=world.get_parent()
    main.field_item_busy=true
    world.set_gameplay_enabled(false)
    var sprite := AnimatedSprite2D.new()
    var frames := SpriteFrames.new()
    frames.set_animation_loop("default",false)
    frames.set_animation_speed("default",60.0)
    for index in range(5):
        var frame := AtlasTexture.new()
        frame.atlas=preload("res://assets/source_exact/global/sprout_sheet2.png")
        frame.region=Rect2(index*16,0,16,16)
        frames.add_frame("default",frame,12.0 if index==0 else 3.0)
    sprite.sprite_frames=frames
    sprite.texture_filter=CanvasItem.TEXTURE_FILTER_NEAREST
    sprite.position=world._cell_center(cell)+Vector2(0,-2)
    sprite.z_index=world.player.z_index+1
    world.add_child(sprite)
    # PlantTree changes frames at ticks 0,12,15,18,21 and ends at 24.
    # Use elapsed deadlines so the preceding frame's load time cannot
    # consume the first frame of a newly created animation.
    var started := preload("res://scripts/game_clock.gd").ticks_usec()
    for index in range(5):
        sprite.frame = index
        var end_tick := 12+index*3
        while preload("res://scripts/game_clock.gd").ticks_usec()-started < int(end_tick*1000000.0/60.0):
            await world.get_tree().process_frame
    sprite.queue_free()
    if mutate_tile:
        tile.set_names(tile.name,upper)
        store(cell,tile)
    _redraw_around(cell)
    main.field_item_busy=false
    world.set_gameplay_enabled(true)

## Redraw the planted tile and the holes beside it that it may have rejoined.
## Redrawing the whole map here froze the game for a moment on every planting.
func _redraw_around(cell: Vector2i) -> void:
    var cells: Array = []
    for y in range(-1,2):
        for x in range(-1,2): cells.append(cell+Vector2i(x,y))
    world._refresh_exact_pickup_cells(cells)

func store(cell: Vector2i, tile: SourceTile, rewards: Dictionary = {}) -> void:
    world.source_plant_farms[world._cell_key(cell)]={"base":tile.name,"upper":tile.name_upper,"day":day(),"rewards":rewards.duplicate(true)}

func update() -> void:
    if not world.generated or world.exact_world==null: return
    if indexed_world_id != world.exact_world.get_instance_id():
        if not indexing: index_existing_plants()
        return
    var current_day:=day()
    if current_day == last_checked_day or growing: return
    last_checked_day = current_day
    var changed:=false
    # Every plant in the world is visited on the morning of a new day. Done in
    # one frame that froze the game for over a second; a few milliseconds of
    # it per frame is not noticed.
    growing = true
    var adapter = world.exact_world
    var started := Time.get_ticks_usec()
    var grown: Array = []
    for key in world.source_plant_farms.keys():
        if Time.get_ticks_usec()-started >= 3000:
            await world.get_tree().process_frame
            if world.exact_world != adapter:
                growing = false
                return
            started = Time.get_ticks_usec()
        if not world.source_plant_farms.has(key): continue
        var record: Dictionary=world.source_plant_farms[key]
        var cell: Vector2i=world._cell_from_key(key)
        var tile: SourceTile=world.exact_world.tile_at(cell)
        if tile==null: continue
        if tile.name_upper != String(record.upper):
            world.source_plant_farms.erase(key)
            continue
        if int(record.day)>=current_day: continue
        var steps:=current_day-int(record.day)
        for step in range(mini(steps,2)):
            grow(cell,tile,record)
        record.day=current_day
        record.base=tile.name
        record.upper=tile.name_upper
        world.source_plant_farms[key]=record
        changed=true
        grown.append(cell)
    growing = false
    # Only the tiles that grew are redrawn. Refreshing the whole map for them
    # was the freeze of over a second at the start of every day.
    if changed: world._refresh_exact_pickup_cells(grown)

func index_existing_plants() -> void:
    indexing = true
    var adapter = world.exact_world
    var identity: int = adapter.get_instance_id()
    var started := Time.get_ticks_usec()
    var planted := func(upper: String) -> bool:
        return "tree_planted" in upper or upper == "bush2_color_fertilized" or upper == "berry_planted" or upper == "grass_planted" or (upper.begins_with("berrytree_") and ("_mid" in upper or "_empty" in upper))
    var store: WorldTileStore = adapter.tiles
    for index in store.with_upper_where(planted):
        var position := store.key_of(index)
        var tile: SourceTile = store.proxy(index)
        var upper := tile.name_upper
        if "tree_planted" in upper or upper == "bush2_color_fertilized" or upper == "berry_planted" or upper == "grass_planted" or (upper.begins_with("berrytree_") and ("_mid" in upper or "_empty" in upper)):
            var cell := SourceWorldData.pixel_to_cell(position)
            if not world.source_plant_farms.has(world._cell_key(cell)):
                store(cell,tile)
        if Time.get_ticks_usec()-started >= 4000:
            await world.get_tree().process_frame
            if world.exact_world != adapter:
                indexing = false
                return
            started = Time.get_ticks_usec()
    indexed_world_id = identity
    indexing = false
    last_checked_day = -1
    update()

func grow(_cell: Vector2i, tile: SourceTile, record: Dictionary) -> void:
    var upper:=tile.name_upper
    var base:=tile.name
    if "tree_planted" in upper or upper=="bush2_color_fertilized":
        var tree: String="tree7" if "desert" in base else "tree6" if "sand" in base else "tree4" if "snow" in base else "tree2" if upper=="bush2_color_fertilized" else "bush2_color"
        var rewards: Dictionary={} if tree=="tree7" else {"LOG":1 if tree=="bush2_color" else 2}
        var apricorns: Array=world.CraftingData.APRICORNS
        var found: String=""
        if tree in ["bush2_color","tree2","tree4"] and world.rng.randi_range(0,1)==0:
            found=String(apricorns[world.rng.randi_range(0,apricorns.size()-1)])
            rewards[found]=1 if tree=="bush2_color" else 2
        if found.is_empty():
            rewards[String(apricorns[world.rng.randi_range(0,apricorns.size()-1)])]=2
        else:
            rewards[found]+=2 if "fertilized" in upper else 1
        tile.set_names("green1" if tree in ["bush2_color","tree2"] else base,tree)
        record.rewards=rewards
    elif upper=="berry_planted":
        tile.set_names(base,"berrytree_"+berry_for_ground(base)+"_mid")
    elif upper.begins_with("berrytree_") and ("_mid" in upper or "_empty" in upper):
        tile.set_names(base,upper.replace("_mid","_full").replace("_empty","_full"))
    elif upper=="grass_planted":
        if "green_savanna" in base: tile.set_names(base,"grass_savanna1")
        else:
            tile.set_names("grass_sand3" if "desert" in base else "grass_sand1" if "sand" in base else "grass3" if "snow" in base else "grass_graveyard1" if base in ["flower5","green9","green10","green11","green12"] else "grass2","")

func restore() -> void:
    if world.exact_world==null: return
    last_checked_day = -1
    for key in world.source_plant_farms:
        var record: Dictionary=world.source_plant_farms[key]
        var tile: SourceTile=world.exact_world.tile_at(world._cell_from_key(key))
        if tile!=null: tile.set_names(String(record.base),String(record.upper))
    # Upgrade harvested trees saved before crop timers were introduced.
    for key in world.source_interior_mutations:
        var mutation: Dictionary = world.source_interior_mutations[key]
        if mutation.get("kind","") != "BERRY_EMPTY" or world.source_plant_farms.has(key): continue
        var cell: Vector2i = world._cell_from_key(key)
        var tile: SourceTile = world.exact_world.tile_at(cell)
        if tile != null and "_empty" in tile.name_upper: store(cell,tile)
    update()
    world._refresh_exact_streams()

func snapshot() -> Dictionary:
    # CUT, DIG, or building may replace a crop between growth checks.
    for key in world.source_plant_farms.keys():
        var record: Dictionary=world.source_plant_farms[key]
        var tile: SourceTile=world.exact_world.tile_at(world._cell_from_key(key)) if world.exact_world!=null else null
        if tile==null or tile.name!=String(record.base) or tile.name_upper!=String(record.upper):
            world.source_plant_farms.erase(key)
    return world.source_plant_farms.duplicate(true)

func harvest(cell: Vector2i) -> bool:
    var key: String=world._cell_key(cell)
    if not world.source_plant_farms.has(key): return false
    var record: Dictionary=world.source_plant_farms[key]
    var rewards: Dictionary=record.get("rewards",{})
    var tile: SourceTile=world.exact_world.tile_at(cell)
    var is_grass := tile.name.begins_with("grass") or tile.name_upper.begins_with("grass")
    if is_grass:
        if tile.name_upper=="grass_planted":
            rewards={"MIRACLE SEED":1}
        else:
            var amount := 4 if tile.name_upper=="grass_savanna1" else 2 if tile.name in ["grass4","grass_sand3","grass_graveyard1"] or tile.name_upper=="grass_savanna2" else 1
            rewards={"GRASS":amount}
            if tile.name=="grass2" and world.rng.randi_range(0,255)<64:
                rewards["MIRACLE SEED"]=1
    if rewards.is_empty(): return false
    world.material_bundle_collected.emit(rewards.duplicate(true))
    if is_grass:
        var replacement: Dictionary=world._cuttable_grass_replacement(tile,cell)
        tile.set_names(String(replacement.base),String(replacement.upper))
    else:
        tile.set_names(tile.name,"")
    world.source_interior_mutations[key]={"kind":"TILE_NAMES","base":tile.name,"upper":""}
    world.source_plant_farms.erase(key)
    world.play_source_sound("cut1")
    world._refresh_exact_tile_streams()
    return true
