extends Control
const Model=preload("res://scripts/coop_hordes.gd")
const Delta=preload("res://scripts/coop_world_delta.gd")
var game:Node
var last_night:=-1
var last_tick:=0
var spawning:=false
var rewarding:=false
var seen:Dictionary={}
var event:Dictionary={}
var spawn_at:Dictionary={}
var rng:=RandomNumberGenerator.new()

func configure(coordinator:Node)->void:
    game=coordinator;mouse_filter=Control.MOUSE_FILTER_IGNORE
    set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    process_mode=Node.PROCESS_MODE_ALWAYS

func model():
    var value=Model.new();value.state=game.state;value.rng=rng;return value

func settings()->Dictionary:
    return (game.state.records if game.hosting else game.shared_records).get("settings",{"horde":true,"raids":"ALL"})

func execute(actor:String,id:String,operation:String,args:Dictionary)->Dictionary:
    if operation=="world_setting":
        if actor!=game.session.actor or not game.hosting:return {"ok":false,"reason":"host_only"}
        var next=settings().duplicate(true);next[args.key]=args.value
        return game.state.transact(actor,"setting/"+id,[game.state.change("settings",next)])
    if operation=="horde_ready":
        if not game.service.areas.can_publish(actor,args.area,int(args.epoch)):return {"ok":false,"reason":"not_authority"}
        return model().ready(actor,id,args.area,args.event)
    if operation=="horde_reward":return model().claim_reward(actor,id,args.key)
    return {"ok":false,"reason":"invalid_command"}

func commit(result:Dictionary)->void:
    if result.get("ok",false) and result.has("changes"):game._committed(result)
    elif not result.get("ok",false) and result.get("reason")=="save_failed":game.end_session("HORDE EVENT COULD NOT BE SAVED.")

func _process(_delta:float)->void:
    visible=game.active and game.main.started and not game.main.generating and not game.main.edge_travel_busy and not game.main._field_ui_blocks_gameplay()
    if not game.active or not game.session.trusted or not game.main.started or game.main.generating or game.main.edge_travel_busy:return
    if Time.get_ticks_msec()-last_tick<250:return
    last_tick=Time.get_ticks_msec()
    if game.hosting:host_tick()
    var records:Dictionary=game.state.records if game.hosting else game.shared_records
    event=records.get("horde/"+game._area(),{})
    if event.get("phase")=="waiting" and not event.get("spawned",false):
        if not seen.has(event.id):
            seen[event.id]=true;spawn_at[event.id]=game.world_time(0)+10.0
            game.main._show_message("A HORDE is coming tonight! Stay by a campfire or fight together.")
        if game.wild.authority() and not spawning and game.world_time(0)>=float(spawn_at.get(event.id,0)):spawn_event(event.duplicate(true))
    if not rewarding and not game._request_busy and not game.main.battle_active and not game.main.battle_entry_pending and game.wild.encounter.is_empty() and not game.pvp.active and not game.raids.active and not game.events.active and game.population_battles.claim.is_empty():
        for key in game.record_keys("horde_reward/"+game.session.actor+"/"):
            if records.has(key):
                claim_reward(String(key),records[key]);break
    queue_redraw()

func host_tick()->void:
    var night=1 if game.main.world._is_night_time() else 0
    if last_night==0 and night==1 and settings().get("horde",true) and rng.randf()<0.17:
        var areas:Dictionary={}
        for actor in game.commands.presence:
            var presence:Dictionary=game.commands.presence[actor]
            if not String(presence.get("area","")).ends_with("|OVERWORLD"):continue
            var area=String(presence.area).get_slice("|",0)
            if not areas.has(area):areas[area]={}
            var levels:Array=[]
            for pokemon in game.state.records.get("player/"+actor,{}).get("party",[]):
                if not pokemon.get("is_egg",false):levels.append(int(pokemon.get("level",1)))
            levels.sort();levels.reverse();levels=levels.slice(0,3)
            var level=10 if levels.is_empty() else int(round(float(levels.reduce(func(sum,value):return sum+value,0))/levels.size()))
            areas[area][actor]=level
        for area in areas:commit(model().start(game.session.actor,game._id(),area,areas[area]))
    last_night=night
    for key in game.state.records.keys():
        if not String(key).begins_with("horde/"):continue
        var current:Dictionary=game.state.records[key]
        if night==0 or not settings().get("horde",true):commit(model().end(game.session.actor,game._id(),current.area));continue
        if current.get("phase")=="active" and current.get("spawned",false) and current.total>0 and current.defeated.size()>=current.total:
            var recipients:Array=[]
            for actor in game.state.members:
                if game.state.members[actor].get("area")==current.area:recipients.append(actor)
            commit(model().finish(game.session.actor,game._id(),current.area,recipients))

func safe(cell:Vector2i)->bool:
    return Model.safe_at(game.main.world.built_structures,cell)

func spawn_event(current:Dictionary)->void:
    spawning=true
    var world=game.main.world;var targets:Dictionary={}
    game.wild.refresh_players()
    for actor in game.wild.players:
        var player:Dictionary=game.wild.players[actor]
        var cell=Vector2i(player.x,player.y)
        if current.players.has(actor) and not safe(cell):targets[actor]=cell
    var pool:Array=[]
    var excluded=["mew","mewtwo","articuno","moltres","zapdos","entei","suicune","raikou","celebi","lugia","hooh","ho-oh","arceus","regirock","regice","registeel","regigigas","volcarona","spiritomb","unownking"]
    for data in world.wild_pokemon.values():
        var species=String(data.species)
        if data.get("aggro_player",false) or data.get("is_egg",false) or "mega" in species or species in excluded:continue
        for target in targets.values():
            if Vector2i(data.cell).distance_squared_to(target)<625:pool.append(species);break
    if pool.size()<3:pool.append_array(["rattata","zubat","geodude","pidgey"])
    for actor in targets:
        for _index in range(maxi(0,4-int(current.get("target_counts",{}).get(actor,0)))):
            var species:String=pool[rng.randi_range(0,pool.size()-1)]
            var level=clampi(int(current.players[actor])-3+rng.randi_range(0,4),2,100)
            for _attempt in range(40):
                var angle=rng.randf()*TAU;var radius=96+rng.randi_range(0,32)
                var pixel=world._cell_center(targets[actor])+Vector2(cos(angle),sin(angle))*radius
                var cell=Vector2i(floori(pixel.x/world.TILE),floori(pixel.y/world.TILE))
                if not world._in_bounds(cell) or not world._is_walkable(cell) or world._source_pokemon_in_water(cell) or world._wild_id_at_cell(cell)>=0 or world.deployed_pokemon.has(cell) or world.wild_eggs.has(cell) or safe(cell):continue
                var close=false
                for target in targets.values():
                    if cell.distance_squared_to(target)<25:close=true;break
                if close:continue
                var wild_id=game.wild.allocate_id()
                if wild_id<1:break
                world._add_wild_pokemon(species,level,cell,world.biome_at(cell),wild_id,{"coop_horde":current.id},{"aggro_player":true,"coop_target":actor})
                if world.wild_pokemon.has(wild_id):game.wild.source_added(wild_id)
                break
    while not game.wild.pending_spawns.is_empty() or game.wild.publishing_spawn:
        await get_tree().process_frame
        if not game.active:spawning=false;return
    var result:Dictionary=await game.command("horde_ready",{"area":current.area,"epoch":game.area_epoch,"event":current.id})
    spawning=false
    if result.get("reason")=="save_failed":game.end_session("HORDE EVENT COULD NOT BE SAVED.")

func claim_reward(key:String,reward:Dictionary)->void:
    rewarding=true
    var result:Dictionary=await game.command("horde_reward",{"key":key})
    rewarding=false
    if result.get("ok",false):game.main._show_message("Horde defeated! Received %d %s."%[int(reward.amount),String(reward.item)])

func _draw()->void:
    if event.get("phase")!="active" or int(event.get("total",0))<1:return
    var total=int(event.total);var defeated=event.defeated.size();var fraction=float(defeated)/total
    var box=Rect2(80,155,160,24)
    draw_style_box(preload("res://scripts/game_options.gd").style(),box)
    var color=Color(0.95,0.55,0.15) if fraction>=0.5 else Color(0.85,0.2,0.2)
    draw_rect(Rect2(87,170,112,3),Color(0.2,0.2,0.25));draw_rect(Rect2(87,170,112*fraction,3),color)
    var font=game.main.JOHTO_FONT
    var ink=Color(0.75,0.65,0.9) if preload("res://scripts/game_options.gd").enabled("dark_mode") else Color.BLACK
    draw_string(font,Vector2(92,169),"Horde: %d/%d"%[total-defeated,total],HORIZONTAL_ALIGNMENT_LEFT,-1,8,ink)
    draw_string(font,Vector2(204,173),"%d%%"%int(round(fraction*100)),HORIZONTAL_ALIGNMENT_LEFT,-1,7,ink)
