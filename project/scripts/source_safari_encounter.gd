extends Control
const GameOptions=preload("res://scripts/game_options.gd")
const Clock=preload("res://scripts/game_clock.gd")
const Rules=preload("res://scripts/source_safari_rules.gd")
var main: Node
var state: Dictionary
var enemy: Dictionary
var trainer_image: TextureRect
var enemy_image: TextureRect
var message: Label
var tick: Label
var choices: Array[Label]=[]
var selection:=0
var busy:=true
var reveal:=false
var adrenaline:=0 # Java initializes this to zero; no source increment path.
func start(owner_main: Node, context: Dictionary, source_alert: bool = false) -> void:
    main=owner_main;z_index=220
    main.battle_entry_pending=true
    main._close_field_move_wheel(false);main.world.set_gameplay_enabled(false)
    while main.progression_active or main.mansion_switch_open:await get_tree().process_frame
    if source_alert:
        main.world._show_ecology_emote(main.world.player.sprite,"!")
        await get_tree().create_timer(1.0).timeout
    main.battle_active=true;main.battle_entry_pending=false;main.battle_turn_busy=false
    main.battle_context=context.duplicate(true);main.battle_result_sent=false
    enemy=main._make_context_enemy(context.party[0])
    enemy=main._apply_pending_wild_record(enemy,int(enemy.level))
    BattleEngine.reset_battle_state(enemy)
    main.current_species=String(enemy.species)
    main.battle_exp_participants.clear()
    main.battle_enemy=enemy;main.battle_player={};main.battle_panel.hide()
    main.world.environment_system.prepare_battle_music(context)
    main.world.set_environment_battle_active(true)
    state=Rules.begin(int(enemy.get("catch_rate",PokemonData.info(enemy.species).get("catch_rate",45))))
    var bg:=ColorRect.new();bg.color=Color.WHITE;bg.size=Vector2(320,180);bg.mouse_filter=Control.MOUSE_FILTER_IGNORE;add_child(bg)
    trainer_image=main._source_texture_rect(self,"Trainer",Vector2(26,12),Vector2(80,78),main._trainer_battle_texture())
    var hidden: bool=bool(context.get("requires_silph_scope",false)) and not bool(context.get("ghost_revealed",false))
    var art:Texture2D=main._ghost_battle_texture() if hidden else PokemonData.record_texture(enemy,"front")
    enemy_image=main._source_texture_rect(self,"Enemy",Vector2(224,8),Vector2(56,56),main._battle_sprite_frame_at(art,0))
    if not hidden:main.pokedex_progress.mark(enemy,false)
    var text_box:=Panel.new();text_box.position=Vector2(2,92);text_box.size=Vector2(316,32);text_box.add_theme_stylebox_override("panel",main._classic_dialogue_style());add_child(text_box)
    message=main._source_ui_label(text_box,"Message",Vector2(10,5),Vector2(296,24),8,"");message.autowrap_mode=TextServer.AUTOWRAP_WORD_SMART
    var box:=Panel.new();box.position=Vector2(2,126);box.size=Vector2(316,52);box.add_theme_stylebox_override("panel",main._classic_dialogue_style());add_child(box)
    for i in range(4):
        choices.append(main._source_ui_label(box,"Choice"+str(i),Vector2(26+155*(i%2),6+20*int(i/2)),Vector2(126,18),8,["SAFARI BALL","BAIT","ROCK","RUN"][i]))
    tick=main._source_ui_label(box,"Tick",Vector2(13,6),Vector2(7,7),8,"")
    refresh()
    var original_panel=main.battle_panel
    main.battle_panel=self
    await main._play_battle_transition()
    main.battle_panel=original_panel
    if not hidden:main._play_pokemon_cry(enemy)
    await say("Wild %s appeared!"%name_text())
    busy=false
func name_text() -> String:
    return "GHOST" if bool(main.battle_context.get("requires_silph_scope",false)) and not bool(main.battle_context.get("ghost_revealed",false)) else BattleEngine.display_name(enemy)
func refresh() -> void:
    if not is_instance_valid(tick):return
    tick.position.x=13+155*(selection%2)
    main._align_menu_tick(tick,choices[selection])
func handle(event: InputEvent) -> void:
    if busy:
        if event.is_action_pressed("confirm"):reveal=true
        return
    var column:=selection%2;var row:=int(selection/2)
    if event.is_action_pressed("move_left"):column=0
    if event.is_action_pressed("move_right"):column=1
    if event.is_action_pressed("move_up"):row=0
    if event.is_action_pressed("move_down"):row=1
    selection=row*2+column;refresh()
    if event.is_action_pressed("confirm"):act(selection)
func say(text: String) -> void:
    message.text=text;message.visible_characters=0;reveal=false
    var previous_tick:=Clock.ticks_usec()
    var elapsed:=0.0
    while message.visible_characters<text.length() and not reveal:
        await get_tree().process_frame
        var now:=Clock.ticks_usec()
        elapsed+=(now-previous_tick)/1000000.0*GameOptions.text_multiplier()/main.BATTLE_TEXT_CHAR_DELAY
        previous_tick=now
        message.visible_characters=int(elapsed)
    message.visible_characters=-1
    await get_tree().create_timer(main.MESSAGE_HOLD_SECONDS, true, false, false).timeout
func act(index: int) -> void:
    if busy:return
    busy=true
    if index==3:
        await say("Got away safely!");main._play_source_battle_sound("run1.ogg");finish("ran");return
    if index==0:
        if not bool(main.battle_context.get("can_catch",true)) or name_text()=="GHOST":
            await say("This POKEMON cannot be caught yet.");busy=false;return
        # Java draws the unused 0..150 value before the deciding 0..255 roll.
        main.battle_rng.randi_range(0,150)
        var result:=Rules.catch_outcome(int(state.rate),adrenaline,main.battle_rng.randi_range(0,255))
        await say("%s used SAFARI BALL!"%String(main.player_model_name.text).to_upper())
        main._play_source_battle_sound("throw_pokeball1.ogg")
        await throw_ball(result)
        if result==-1:
            var caught:=enemy.duplicate(true);BattleEngine.reset_battle_state(caught)
            caught["pokeball"]="SAFARI BALL"
            main._route_received_pokemon(caught);main.pokedex_progress.mark(caught,true)
            if not main.caught_species.has(String(caught.species)):main.caught_species.append(String(caught.species))
            main._play_source_battle_sound("catch_fanfare.ogg")
            await say("Caught %s!"%name_text());finish("captured");return
        await say("%s broke free!"%name_text())
    else:
        var bait:=index==1
        await say("%s threw %s!"%[String(main.player_model_name.text).to_upper(),"some BAIT" if bait else "a ROCK"])
        await throw_object(bait)
        var duration:int=main.battle_rng.randi_range(1,5)
        if bait:Rules.bait(state,duration)
        else:Rules.rock(state,duration)
    var mood:=Rules.mood(state)
    if not mood.is_empty():await say("Wild %s is %s!"%[name_text(),mood])
    var threshold:=Rules.flee_threshold(int(enemy.stats.speed),state)
    if threshold>255 or main.battle_rng.randi_range(0,255)<threshold:
        adrenaline=0;main._play_source_battle_sound("run1.ogg")
        await say("Wild %s ran!"%name_text());finish("ran");return
    busy=false
func throw_object(bait: bool) -> void:
    if not GameOptions.enabled("battle_animations"):return
    var art:Texture2D=preload("res://assets/source_exact/global/bait_small1.png") if bait else preload("res://assets/source_exact/global/rock_small1.png")
    var sprite: TextureRect=main._source_texture_rect(self,"Thrown",Vector2.ZERO,Vector2(8,8),art)
    main._play_source_battle_sound("throw_rock1.ogg")
    # Java coordinates, translated into this wider battle viewport.
    var pos:=Vector2(32,64)
    var source_end:=Vector2(112,100)
    var origin:=Vector2(trainer_image.position.x+32,80)
    var target:=enemy_image.position+Vector2(24,36)
    var scale_x:float=(target.x-origin.x)/(source_end.x-32.0)
    for i in range(11):
        sprite.position=origin+Vector2((pos.x-32.0)*scale_x,64.0-pos.y)
        await get_tree().create_timer(4.0/60.0).timeout
        var dy:int=[12,12,8,8,8,8,2,-2,-9,-9,0 if bait else -12][i]
        pos+=Vector2(8 if i<10 else 0 if bait else -4,dy)
    sprite.hide()
    if not bait:
        sprite.texture=preload("res://assets/source_exact/global/hit1.png");sprite.size=Vector2(24,24);sprite.position=enemy_image.position+Vector2(16,16);sprite.show()
        await get_tree().create_timer(4.0/60.0).timeout;sprite.hide()
    await get_tree().create_timer((73.0 if bait else 72.0)/60.0).timeout
    await get_tree().create_timer(2.0/60.0).timeout
    sprite.queue_free()
func throw_ball(outcome: int) -> void:
    if not GameOptions.enabled("battle_animations"):
        enemy_image.visible=outcome!=-1;return
    # Reuse the game's source throw/wobble sequence, targeting this viewport.
    var old_enemy=main.enemy_sprite;var old_panel=main.battle_panel;var old_trainer=main.player_battle_sprite
    main.enemy_sprite=enemy_image;main.battle_panel=self;main.player_battle_sprite=trainer_image
    await main._play_source_throw_animation(outcome==-1,3 if outcome==-1 else outcome)
    main._clear_battle_capture_ball()
    main.enemy_sprite=old_enemy;main.battle_panel=old_panel;main.player_battle_sprite=old_trainer
func finish(outcome: String) -> void:
    main.safari_ui=null
    main._end_battle(outcome)
    queue_free()
