extends Node
## A dedicated server makes the new areas players walk into, so a phone never
## has to. It makes them in this process (in_process): the world generator
## itself (the engine's native one, PokeWildsWorldGen, when present, else the
## GDScript one) runs on a WorkerThreadPool thread, the terrain cache is
## written and the snapshot handed over as if a player had uploaded it. Its
## first Pokemon and roaming Megas are placed here too when the server runs
## every area's Pokemon (population_authority=server: first_population, as a
## world just generated places them); otherwise the first player who goes
## there places them and sends the area back ("population_pending",
## coop_game.gd). Without the native generator, or if
## that fails, a second copy of the game started headless with
## `--generate-area JOB` makes it as before: it reads the seed, size and world
## options from JOB, generates the area, writes its snapshot beside JOB and
## exits. If anything goes wrong the player's device makes the area.
const Snapshot=preload("res://scripts/coop_world_snapshot.gd")
const Cache=preload("res://scripts/source_world_cache.gd")
const Paths=preload("res://scripts/game_data_paths.gd")
const GameOptions=preload("res://scripts/game_options.gd")
const NativeWorldGen=preload("res://scripts/native_world_gen.gd")
const AreaSim=preload("res://scripts/area_sim.gd")
const PopulationRules=preload("res://scripts/rules/population_rules.gd")
const Megas=preload("res://scripts/biome_megas.gd")
const BattleSession=preload("res://scripts/battle_session.gd")
## Under the 10 minutes a player waits for a new area (coop_game.prepare_travel):
## at 15 the player had given up before their device was asked to make it.
const TIMEOUT_MS:=8*60*1000
## Size of new areas, 0-4; -1 picks one at random as the game does.
var area_size:=-1
## Areas made here, on a worker thread, when the engine has the native
## generator ("auto"), always ("on": the GDScript one is slower but still off
## the server's frame), or never ("off": always the second process).
## server.cfg area_generation, --area-generation.
var in_process:="auto"
var _busy:=false
## What placing a new area's first Pokemon gets of a frame (us): twice the
## areas' Pokemon's (coop_population_authority.gd BUDGET_USEC), as the
## player who arrives waits on it, still well under a 16 ms frame.
const PLACE_USEC:=8000
var _slice_started:=0
func _breathe()->void:
    if Time.get_ticks_usec()-_slice_started<PLACE_USEC:return
    await get_tree().process_frame
    _slice_started=Time.get_ticks_usec()

func generate_here()->bool:
    return in_process=="on" or (in_process=="auto" and NativeWorldGen.enabled())

## Server side. False only when the area could not be made here.
func make(main:Node,actor:String,area:String,token:String)->bool:
    while _busy:await get_tree().process_frame
    # Waiting behind another area, this one may have been made or given up.
    if main.coop_game.service.areas.reservations.get(area,{}).get("token","")!=token:return true
    _busy=true
    var made:bool=generate_here() and await _make_here(main,actor,area,token)
    if not made:made=await _make(main,actor,area,token)
    _busy=false
    return made

## The area made in this process, on a worker; false when that failed.
func _make_here(main:Node,actor:String,area:String,token:String)->bool:
    var seed_value:=randi_range(1,2147483646)
    var size_index:=area_size if area_size>=0 else randi_range(1,4)
    var started:=Time.get_ticks_msec()
    print("SERVER making new area ",area," here (",("native" if NativeWorldGen.enabled() else "GDScript")," generator)...")
    var coop:Node=main.coop_game
    var made:Dictionary=await coop._off_thread(func():return area_of(seed_value,size_index))
    if made.is_empty():
        print("SERVER ERROR: area ",area," could not be made in this process; trying a second one")
        return false
    var metadata:={"seed":seed_value,"size":size_index}
    var shared:={}
    if coop.server_population:
        var placing:=Time.get_ticks_msec()
        var packet:Dictionary=coop.visuals.last_packets.get(actor,{})
        shared=await first_population(made.tiles,made.megas,seed_value,int(packet.get("party_level",0)),coop.clock_seconds,_breathe,coop._off_thread)
        print("SERVER placed area ",area,"'s ",shared.wild_pokemon.size()," Pokemon in ",Time.get_ticks_msec()-placing," ms")
    else:metadata["population_pending"]=true
    var bytes:PackedByteArray=await coop._off_thread(func():return Snapshot.encode(seed_value,size_index,made.cache,shared))
    var result:Dictionary=await coop.service.generated(actor,area,token,metadata,bytes)
    print("SERVER made area ",area," in ",(Time.get_ticks_msec()-started)/1000,"s" if result.get("ok",false) else ", but it was no longer wanted (%s)"%result.get("reason",""))
    return true

## A new area: generated, adapted, its terrain cache written (where the server
## keeps its areas' caches) and read back as a player's game reads it:
## {"cache": its bytes, "tiles": the exact world (SourceExactWorldAdapter),
## "megas": where its Megas could stand (biome_megas.gd open_cells_at)}; {}
## when generation failed. Runs on a worker thread: generation, the adapter
## and the cache touch nothing the game holds (world.gd runs them on threads
## as well).
static func area_of(seed_value:int,size_index:int)->Dictionary:
    var result:Dictionary=SourceWorldGenerator.generate_exact_source_world(seed_value,size_index)
    if result.is_empty() or result.has("generation_error"):return {}
    var adapter:=SourceExactWorldAdapter.from_generator_result(result,SourceJavaRandom.new(seed_value^0x535041574E))
    if not Cache.save_world(seed_value,size_index,adapter,result):return {}
    var cache:=FileAccess.get_file_as_bytes(Cache.cache_path(seed_value,size_index))
    var loaded:=Cache.load_result(seed_value,size_index)
    if cache.is_empty() or not loaded.get("store") is WorldTileStore:return {}
    # The same spawn draw as a World's (world.gd), for the same adapter.
    var tiles:=SourceExactWorldAdapter.from_generator_result(loaded,SourceJavaRandom.new(seed_value^0x535041574E))
    # Where its roaming Megas could stand: a pass over the whole map, here
    # rather than on the game thread (first_population picks among them).
    var state=AreaSim.new().state
    state.tiles=tiles
    return {"cache":cache,"tiles":tiles,"megas":Megas.open_cells_at(state)}

## The first Pokemon of an area just made (`tiles`, its exact world) and its
## roaming Megas and Mega Gengar, placed as a player's World places them in a
## world just made (rules/population_rules.gd place_new, source_forest_boss.gd
## select_cell_at, biome_megas.gd choose_at and install_at; `megas`, where
## its Megas could stand, is open_cells_at's) with draws from a generator
## seeded with the area's seed: the same area gets the same ones.
## `party_level` (BattleSession.reference_level of the player who arrives
## first; 0 for none) adapts their species as a World adapts them to its
## party; `clock` is the world's (the Megas' first steps). A shared part for
## the area's snapshot: wild_pokemon and event_progress. The Pokemon go in a
## slice at a time on the game thread (`breathe` awaited between them); the
## Megas' pick among their cells runs on a worker (`off_thread`, coop_game.gd
## _off_thread), on data nothing else holds.
static func first_population(tiles,megas:Dictionary,seed_value:int,party_level:int,clock:float,breathe:Callable,off_thread:Callable)->Dictionary:
    var state=AreaSim.new().state
    state.tiles=tiles;state.bounds=tiles.bounds();state.clock=clock;state.rng.seed=seed_value
    var next:=[1]
    var add:=func(species:String,level:int,cell:Vector2i,home_biome:String,source_record:Dictionary)->int:
        if party_level>0 and not bool(source_record.get("is_trapping",false)):
            species=PopulationRules.adapted_species(state,species,level,cell,BattleSession.wild_level_at(party_level,level),seed_value)
        var wild_id:int=next[0]
        if not PopulationRules.add_wild(state,species,level,cell,home_biome,wild_id,source_record):return -1
        next[0]=wild_id+1
        return wild_id
    await PopulationRules.place_new(state,add,breathe)
    var gengar=SourceForestBoss.select_cell_at(state,tiles.spawn_cell)
    var reserved:={}
    if gengar is Vector2i:
        state.event_progress[SourceForestBoss.SAVE_KEY]={"x":gengar.x,"y":gengar.y,"home_x":gengar.x,"home_y":gengar.y}
        # Its cell kept from the Megas.
        reserved[gengar]=true
    var choices:Dictionary=await off_thread.call(func()->Dictionary:return Megas.choose_at(state,megas,reserved))
    Megas.install_at(state,choices)
    var events:={}
    for key in [Megas.SAVE_KEY,SourceForestBoss.SAVE_KEY]:
        if state.event_progress.has(key):events[key]=state.event_progress[key]
    return {"wild_pokemon":state.wild.to_save(),"event_progress":events}

func _make(main:Node,actor:String,area:String,token:String)->bool:
    var folder:=Paths.path("area_maker")
    DirAccess.make_dir_recursive_absolute(folder)
    var job:=folder.path_join("job.json")
    var out:=folder.path_join("area.snapshot")
    DirAccess.remove_absolute(out)
    var file:=FileAccess.open(job,FileAccess.WRITE)
    if file==null:return false
    file.store_string(JSON.stringify({"seed":randi_range(1,2147483646),"size":area_size if area_size>=0 else randi_range(1,4),
        "options":GameOptions.values,"world":String(main.world_edit.text),"out":out}))
    file.close()
    var args:=["--headless","--generate-area",job]
    if OS.has_feature("editor"):args=["--path",ProjectSettings.globalize_path("res://")]+args
    var started:=Time.get_ticks_msec()
    var pid:=OS.create_process(OS.get_executable_path(),args)
    if pid<=0:return false
    print("SERVER making new area ",area,"...")
    while OS.is_process_running(pid):
        if Time.get_ticks_msec()-started>TIMEOUT_MS:OS.kill(pid);break
        await get_tree().process_frame
    var bytes:=FileAccess.get_file_as_bytes(out)
    DirAccess.remove_absolute(out)
    for name in DirAccess.get_files_at(folder.path_join("world_cache")):DirAccess.remove_absolute(folder.path_join("world_cache").path_join(name))
    var decoded:Dictionary=Snapshot.decode(bytes) if not bytes.is_empty() else {}
    if decoded.is_empty():
        print("SERVER ERROR: area ",area," could not be made here; the player's device will make it")
        return false
    var result:Dictionary=await main.coop_game.service.generated(actor,area,token,{"seed":decoded.seed,"size":decoded["size"]},bytes)
    print("SERVER made area ",area," in ",(Time.get_ticks_msec()-started)/1000,"s" if result.get("ok",false) else ", but it was no longer wanted (%s)"%result.get("reason",""))
    return true

## The second copy: generate the area JOB describes, write it, quit.
func generate(main:Node,job_path:String)->void:
    var job=JSON.parse_string(FileAccess.get_file_as_string(job_path))
    if not job is Dictionary:main.get_tree().quit(1);return
    GameOptions.restore_game_options(job.get("options",{}),String(job.get("world","")))
    main.world.visible=true;main.generating=true
    await main.world.generate_world(int(job.seed),int(job.size),false)
    if not main.world.generation_error.is_empty():
        printerr("AREA generation failed: ",main.world.generation_error);main.get_tree().quit(1);return
    var world:Node=main.world
    var parts:Dictionary=Snapshot.split(world.get_crafting_save_state())
    var bytes:PackedByteArray=Snapshot.encode(world.world_seed,world.map_size_index,FileAccess.get_file_as_bytes(Cache.cache_path(world.world_seed,world.map_size_index)),parts.shared)
    var out:=String(job.get("out",""))
    var file:=FileAccess.open(out+".pending",FileAccess.WRITE)
    if bytes.is_empty() or file==null:main.get_tree().quit(1);return
    file.store_buffer(bytes);file.close()
    main.get_tree().quit(0 if DirAccess.rename_absolute(out+".pending",out)==OK else 1)
