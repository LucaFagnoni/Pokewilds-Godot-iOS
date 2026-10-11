extends RefCounted
## Separates shared area mutations from each player's camera, helper and respawn.
const MAX_BYTES:=128*1024*1024
const PERSONAL_KEYS=["follower_pokemon","active_field_move","active_field_pokemon",
    "build_selection_index","discovered_cells","repel_until_elapsed","active_area_id",
    "source_return_x","source_return_y","active_built_house_door_x","active_built_house_door_y",
    "active_built_house_floor","camera_zoom_level","respawn_house","respawn_x","respawn_y"]

static func capture_personal(world:Node)->Dictionary:
    # Frequent player checkpoints must not serialize every tree, wild Pokemon,
    # furniture item and area mutation just to extract the personal fields.
    var follower:Dictionary=world.follower_pokemon.duplicate(true);follower.erase("sprite")
    var return_cell:Vector2i=world.area_return_cells.get("%s_RETURN"%world.active_area_id,world.spawn_cell)
    return {"follower_pokemon":follower,"active_field_move":world.active_field_move,
        "active_field_pokemon":world.active_field_pokemon.duplicate(true),"build_selection_index":world.build_selection_index,
        "discovered_cells":world.discovered_cells.keys(),"repel_until_elapsed":world.repel_until_elapsed,
        "active_area_id":world.active_area_id,"source_return_x":return_cell.x,"source_return_y":return_cell.y,
        "active_built_house_door_x":world.active_built_house_door.x if world.active_area_id=="HOUSE" else -2147483648,
        "active_built_house_door_y":world.active_built_house_door.y if world.active_area_id=="HOUSE" else -2147483648,
        "active_built_house_floor":world._built_house_floor_index_for_cell(world._player_cell()) if world.active_area_id=="HOUSE" else 0,
        "camera_zoom_level":world.camera_zoom_level,"respawn_house":world.respawn_house.duplicate(true),
        "respawn_x":world.respawn_cell.x,"respawn_y":world.respawn_cell.y}

static func split(crafting:Dictionary)->Dictionary:
    var shared=crafting.duplicate(true)
    var personal:Dictionary={}
    for key in PERSONAL_KEYS:
        if shared.has(key):personal[key]=shared[key];shared.erase(key)
    return {"shared":shared,"personal":personal}

static func committed_population(area:String,shared:Dictionary,records:Dictionary)->Dictionary:
    # An in-flight spawn or habitat move must not enter a join/travel snapshot
    # before its transaction has been saved. Initial world seeding is separate.
    var result=shared.duplicate(true)
    for group in ["wild_pokemon","deployed_pokemon","wild_eggs"]:result[group]=[]
    var prefix="world/"+area+"/"
    for key in records:
        if not String(key).begins_with(prefix):continue
        var group=String(key).get_slice("/",2)
        if group not in ["wild_pokemon","deployed_pokemon","wild_eggs"]:continue
        var record=preload("res://scripts/coop_world_delta.gd").decode(records[key])
        if record is Dictionary:result[group].append(record)
    return result

static func merge(shared:Dictionary,personal:Dictionary)->Dictionary:
    var result=shared.duplicate(true)
    # An online area snapshot is the exact current population, including a
    # deliberately empty one. It is not an old local save needing migration.
    result["coop_authoritative_population"]=true
    for key in PERSONAL_KEYS:
        result.erase(key)
        if personal.has(key):result[key]=personal[key]
    return result

static func encode(seed_value:int,size_index:int,cache:PackedByteArray,shared:Dictionary)->PackedByteArray:
    if seed_value==0 or size_index<0 or size_index>4 or cache.is_empty() or cache.size()>MAX_BYTES:return PackedByteArray()
    for key in PERSONAL_KEYS:
        if shared.has(key):return PackedByteArray()
    var bytes=var_to_bytes({"format":"POKEWILDS_ONLINE_AREA_1","seed":seed_value,"size":size_index,"cache":cache,"shared":shared})
    return bytes if bytes.size()<=MAX_BYTES else PackedByteArray()

static func decode(bytes:PackedByteArray)->Dictionary:
    if bytes.is_empty() or bytes.size()>MAX_BYTES:return {}
    # bytes_to_var does not permit object deserialization (unlike _with_objects).
    var value=bytes_to_var(bytes)
    if not value is Dictionary or value.get("format","")!="POKEWILDS_ONLINE_AREA_1":return {}
    if not value.get("seed") is int or int(value.seed)==0:return {}
    if not value.get("size") is int or int(value["size"])<0 or int(value["size"])>4:return {}
    if not value.get("cache") is PackedByteArray or value.cache.is_empty():return {}
    if not value.get("shared") is Dictionary:return {}
    for key in PERSONAL_KEYS:
        if value.shared.has(key):return {}
    return value
