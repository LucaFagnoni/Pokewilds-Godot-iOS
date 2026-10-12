extends Node
const Model=preload("res://scripts/coop_raids.gd")
const Delta=preload("res://scripts/coop_world_delta.gd")
var game:Node
var active:=false
var finishing:=false
var syncing:=false
var boss_id:=""
var original_profile:Dictionary={}
var base_hp:=1
var cleared:Dictionary={}
var cleanup_at:=0
var display_stamp:Array=[]

func configure(coordinator:Node)->void:game=coordinator
func model():
    var value=Model.new();value.state=game.state;value.presence=game.commands.presence;return value

static func eligible(context:Dictionary)->bool:
    var party=context.get("party",[])
    return context.get("kind")=="special" and party is Array and party.size()==1 and party[0] is Dictionary and party[0].get("species") in Model.SPECIES

func records()->Dictionary:return game.state.records if game.hosting else game.shared_records
func current()->Dictionary:return records().get("raid/"+boss_id,{})

func command(operation:String,args:Dictionary)->Dictionary:
    while game._request_busy:
        await get_tree().process_frame
        if not game.active or not game.session.trusted:return {"ok":false,"reason":"disconnected"}
    return await game.command(operation,args)

func execute(actor:String,id:String,operation:String,args:Dictionary)->Dictionary:
    if operation=="raid_join":
        var context=Delta.decode(args.context)
        if not context is Dictionary or not eligible(context):return {"ok":false,"reason":"invalid_boss"}
        var scope=String(game.commands.presence.get(actor,{}).get("area",""))
        if scope.get_slice("|",0)!=args.area:return {"ok":false,"reason":"wrong_area"}
        var key=args.area+"/"+game.state.fingerprint([scope,context.get("id"),context.get("cell_x",0),context.get("cell_y",0)])
        var member:Dictionary=context.party[0]
        var enemy=preload("res://scripts/battle_engine.gd").make_pokemon(String(member.species),int(member.get("level",1)),null,member)
        var boss={"species":member.species,"area":scope,"world_area":args.area,"max_hp":int(enemy.max_hp),"member":enemy,"context":context}
        var result:Dictionary=model().join(actor,id,key,boss)
        if result.get("ok",false):
            result["boss_id"]=key;result["raid"]=game.state.records["raid/"+key];result["boss"]=game.state.records["boss/"+key]
        return result
    if operation=="raid_damage":
        var raid:Dictionary=game.state.records.get("raid/"+args.boss,{})
        if actor not in raid.get("participants",[]):return {"ok":false,"reason":"not_fighting"}
        if raid.get("phase")!="fighting":return {"ok":true}
        if absi(int(args.amount))>int(raid.max_hp):return {"ok":false,"reason":"invalid_damage"}
        return model().damage(actor,id,args.boss,int(args.amount))
    if operation=="raid_finish":
        var raid:Dictionary=game.state.records.get("raid/"+args.boss,{})
        if actor not in raid.get("participants",[]):return {"ok":false,"reason":"not_fighting"}
        var prefix="raidcaught/" if args.outcome=="captured" else "raidexit/"
        var previous:Dictionary=game.state.outcomes.get(actor+"/"+prefix+id,{})
        if not previous.is_empty():
            if previous.get("command_hash")!=game.state.fingerprint([args]):return {"ok":false,"reason":"reused_request_id"}
            return {"ok":true,"base":game.state.print_of("player/"+actor,{})}
        if args.base!=game.state.print_of("player/"+actor,{}):return {"ok":false,"reason":"profile_changed"}
        var profile:Dictionary=args.profile.duplicate(true)
        var changes:Array=game.storage.profile_changes(actor,profile)
        if args.outcome=="captured":
            if not model().can_catch(actor,args.boss):return {"ok":false,"reason":"cannot_catch"}
            var next=raid.duplicate(true);next.caught.append(actor)
            var eligible_players:Array=next.participants if next.mode=="ALL" else [next.finisher]
            if eligible_players.all(func(player):return player in next.caught):next.phase="done"
            changes.append(game.state.change("raid/"+args.boss,next))
        var result=game.state.transact(actor,prefix+id,changes,game.state.fingerprint([args]))
        if result.get("ok",false):result["base"]=game.state.print_of("player/"+actor,{});result["pending"]=profile.save.get("coop_pending_pokemon",[])
        return result
    return {"ok":false,"reason":"invalid_command"}

func begin(context:Dictionary)->bool:
    var result:Dictionary=await command("raid_join",{"area":game._area(),"context":Delta.encode(context)})
    if not result.get("ok",false):
        game.main._show_message("This raid is already complete." if result.get("reason")=="raid_already_defeated" else "Could not join the raid.")
        return false
    boss_id=result.boss_id;base_hp=int(result.boss.max_hp)
    original_profile=game._personal_profile().duplicate(true)
    active=true;display_stamp.clear()
    context.party=[result.boss.member.duplicate(true)]
    return true

func apply_hp(preserve_zero:bool=false)->void:
    if not active or not game.main.battle_active or game.main.battle_enemy.is_empty():return
    var raid=current()
    if raid.is_empty():return
    game.main.battle_enemy.max_hp=int(raid.max_hp)
    if not preserve_zero:
        game.main.battle_enemy.hp=maxi(1,int(raid.hp))

func sync_damage(before:int)->void:
    if not active:return
    var after=int(game.main.battle_enemy.hp)
    if current().get("phase")=="fighting" and before!=after:
        syncing=true
        var result:Dictionary=await command("raid_damage",{"boss":boss_id,"amount":before-after})
        syncing=false
        if not result.get("ok",false):game.end_session("RAID DAMAGE COULD NOT BE SAVED.");return
    apply_hp(after<=0)

func block_ball(ball:String)->bool:
    if not active:return false
    var raid=current()
    var can_catch=raid.get("phase")=="catching" and game.session.actor not in raid.get("caught",[]) and (game.session.actor in raid.get("participants",[]) if raid.get("mode")=="ALL" else game.session.actor==raid.get("finisher"))
    if can_catch:return false
    var main=game.main
    main._close_battle_submenu();main.battle_turn_busy=true;main.last_battle_ball=ball
    main._show_battle_message_screen()
    await main._play_source_throw_animation(false,0)
    await main._type_battle_text("It is too strong to catch! Weaken it together first." if raid.get("phase")=="fighting" else "Only the eligible raid participants can catch it.")
    main.battle_turn_busy=false;main._show_battle_command_screen()
    return true

func normalize_capture(pokemon:Dictionary)->void:
    if not active:return
    pokemon.max_hp=base_hp;pokemon.hp=clampi(int(pokemon.hp),1,base_hp)

func finish(outcome:String)->bool:
    if not active:return true
    finishing=true
    var profile=game._personal_profile()
    var pending:Array=profile.save.get("coop_pending_pokemon",[]).duplicate(true)
    var result:Dictionary=await command("raid_finish",{"boss":boss_id,"outcome":outcome,"profile":profile,"base":game.profile_base})
    if not result.get("ok",false):finishing=false;game.end_session("RAID RESULT COULD NOT BE SAVED.");return false
    game.storage.settle(pending,result.get("pending",[]));game.profile_base=String(result.base)
    active=false;finishing=false;original_profile.clear();boss_id=""
    return true

func _process(_delta:float)->void:
    if not game.active or not game.main.started or game.main.generating or game.main.edge_travel_busy:return
    if active and not syncing and not game.main.battle_turn_busy and not game.main.battle_enemy.is_empty():
        var raid=current();var stamp=[raid.get("hp"),raid.get("max_hp"),raid.get("phase")]
        if stamp!=display_stamp:
            display_stamp=stamp;apply_hp();game.main._update_battle_hud()
    if game.main.battle_active:return
    if Time.get_ticks_msec()-cleanup_at<500:return
    cleanup_at=Time.get_ticks_msec()
    for key in game.record_keys("raid/"+game._area()+"/"):
        if not records().has(key) or records()[key].get("phase")!="done":continue
        var id=String(key).trim_prefix("raid/")
        var signature=id+"/"+str(game.main.world.exact_world.get_instance_id())
        if cleared.has(signature):continue
        var boss:Dictionary=records().get("boss/"+id,{})
        if boss.is_empty():continue
        cleared[signature]=true
        game.main.world.complete_battle_event({"outcome":"captured","context":boss.context})
