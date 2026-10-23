extends RefCounted
## Separates shared area mutations from each player's camera, helper and respawn.
const MAX_BYTES:=128*1024*1024
const PERSONAL_KEYS=["follower_pokemon","active_field_move","active_field_pokemon",
    "build_selection_index","discovered_cells","repel_until_elapsed","active_area_id",
    "source_return_x","source_return_y","active_built_house_door_x","active_built_house_door_y",
    "active_built_house_floor","camera_zoom_level","respawn_house","respawn_x","respawn_y"]

## The part of the map a player has uncovered, in a small form: the map cut
## into squares of 32x32 cells, each square one short string with a bit for
## every cell seen (DiscoveredCells.to_squares, which re-encodes only the
## squares changed since). A square that has not changed costs nothing to
## copy or compare.
static func packed_discovery(world:Node)->Dictionary:
    return world.discovered_cells.to_squares()

static func capture_personal(world:Node)->Dictionary:
    # Frequent player checkpoints must not serialize every tree, wild Pokemon,
    # furniture item and area mutation just to extract the personal fields.
    var follower:Dictionary=world.follower_pokemon.duplicate(true);follower.erase("sprite")
    var return_cell:Vector2i=world.area_return_cells.get("%s_RETURN"%world.active_area_id,world.spawn_cell)
    return {"follower_pokemon":follower,"active_field_move":world.active_field_move,
        "active_field_pokemon":world.active_field_pokemon.duplicate(true),"build_selection_index":world.build_selection_index,
        "discovered_cells":packed_discovery(world),"repel_until_elapsed":world.repel_until_elapsed,
        "active_area_id":world.active_area_id,"source_return_x":return_cell.x,"source_return_y":return_cell.y,
        "active_built_house_door_x":world.active_built_house_door.x if world.active_area_id=="HOUSE" else -2147483648,
        "active_built_house_door_y":world.active_built_house_door.y if world.active_area_id=="HOUSE" else -2147483648,
        "active_built_house_floor":world._built_house_floor_index_for_cell(world._player_cell()) if world.active_area_id=="HOUSE" else 0,
        "camera_zoom_level":world.camera_zoom_level,"respawn_house":world.respawn_house.duplicate(true),
        "respawn_x":world.respawn_cell.x,"respawn_y":world.respawn_cell.y}

## copy false for a crafting state made just for this (get_crafting_save_state):
## nothing else holds it, so it is not copied again.
static func split(crafting:Dictionary,copy:bool=true)->Dictionary:
    var shared=crafting.duplicate(true) if copy else crafting.duplicate()
    var personal:Dictionary={}
    for key in PERSONAL_KEYS:
        if shared.has(key):personal[key]=shared[key];shared.erase(key)
    return {"shared":shared,"personal":personal}

## An in-flight spawn or habitat move must not enter a join/travel snapshot
## before its transaction has been saved. Initial world seeding is separate.
## committed_population(shared, population_records(area, records)): the
## records are picked on the game thread, still packed; unpacking them, a
## thousand wild Pokemon in a long-played area, can then run on a worker.
## `keys`: the area's keys when the caller has them (coop_state.gd
## keys_by_area), not every record of the world to walk.
static func population_records(area:String,records:Dictionary,keys:Variant=null)->Array:
    var picked:Array=[]
    var prefix="world/"+area+"/"
    for key in (records if keys==null else keys):
        if not String(key).begins_with(prefix):continue
        var group=String(key).get_slice("/",2)
        if group in ["wild_pokemon","deployed_pokemon","wild_eggs"]:picked.append([group,records[key]])
    return picked

## Only these groups are replaced; the rest is the caller's own, not copied.
static func committed_population(shared:Dictionary,picked:Array)->Dictionary:
    var result=shared.duplicate()
    for group in ["wild_pokemon","deployed_pokemon","wild_eggs"]:result[group]=[]
    for entry in picked:
        var record=preload("res://scripts/coop_world_delta.gd").decode(entry[1])
        if record is Dictionary:result[entry[0]].append(record)
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

## An area the host already holds, saved again by the guest who runs it: the
## same, but without the terrain cache. The cache never changes after the area
## is made and was most of the upload (about 420 of 460 KB packed, over a minute
## of a weak phone uplink); the host puts back the one it has (refill).
static func encode_without_cache(seed_value:int,size_index:int,shared:Dictionary)->PackedByteArray:
    if seed_value==0 or size_index<0 or size_index>4:return PackedByteArray()
    for key in PERSONAL_KEYS:
        if shared.has(key):return PackedByteArray()
    var bytes=var_to_bytes({"format":"POKEWILDS_ONLINE_AREA_1","seed":seed_value,"size":size_index,"cache":PackedByteArray(),"shared":shared})
    return bytes if bytes.size()<=MAX_BYTES else PackedByteArray()

## `bytes` from encode_without_cache made whole with the cache of `stored`, the
## area's snapshot as the host has it; empty when they are not the same area.
static func refill(bytes:PackedByteArray,stored:PackedByteArray)->PackedByteArray:
    if bytes.is_empty() or bytes.size()>MAX_BYTES:return PackedByteArray()
    var value=bytes_to_var(bytes)
    var old:=decode(stored)
    if old.is_empty() or not value is Dictionary or value.get("format","")!="POKEWILDS_ONLINE_AREA_1" or not value.get("shared") is Dictionary:return PackedByteArray()
    if not value.get("cache") is PackedByteArray or not value.cache.is_empty() or value.get("seed")!=old.seed or value.get("size")!=old["size"]:return PackedByteArray()
    return encode(old.seed,old["size"],old.cache,value.shared)

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
