extends Node
## Plays host-resolved PvP through the existing battle UI and animation system.
const BattleSession=preload("res://scripts/battle_session.gd")
var game:Node
var main:Node
var active:=false
var starting:=false
var playing:=false
var id:=""
var actor:=""
var opponent:=""
var revision:=-1
var state:Dictionary={}
var original_party:Array=[]
var original_inventory:Dictionary={}
var original_pending:Dictionary={}
var queue:Array=[]
var trainer:Dictionary={}

func configure(coordinator:Node)->void:
    game=coordinator;main=game.main

func receive(session:Dictionary)->void:
    if not active:
        if String(session.id)==id:return
        start(session)
        return
    if session.id!=id:return
    var version=int(session.get("battle_revision",0))
    if version<=revision:return
    revision=version;queue.append(session.duplicate(true))
    if not starting and not playing:play_queue()

func start(session:Dictionary)->void:
    active=true;starting=true;id=session.id;actor=game.session.actor
    opponent=session.b if session.a==actor else session.a
    revision=int(session.get("battle_revision",0))
    original_party=main.caught_pokemon
    original_inventory=main.inventory
    original_pending=main.world.pending_encounter_record
    trainer=session.get("trainers",{}).get(opponent,{})
    main.caught_pokemon=session.battle_state.parties[actor].duplicate(true)
    main.inventory=session.battle_inventory.get(actor,{}).duplicate(true)
    main.world.pending_encounter_record={}
    game.interaction_ui.hide()
    var context={"id":"pvp/"+id,"kind":"trainer","pvp":true,"fixed_level":true,"can_catch":false,"can_run":false,
        "trainer_visual":trainer.duplicate(true),"trainer_name":String(trainer.get("name","PLAYER")),"intro":String(trainer.get("name","PLAYER"))+" wants to battle!",
        "party":session.battle_state.parties[opponent].duplicate(true),"trainer_heals":0,
        "battle_format":"double" if session.battle_state.slots[actor] is Array else "single"}
    await main._start_battle_context(context)
    if not active:return
    apply_state(session.battle_state)
    main._set_double_battle_layout()
    main.battle_context["_entry_messages"]=[]
    starting=false
    if not queue.is_empty():play_queue()

func apply_state(next:Dictionary)->void:
    state=next.duplicate(true)
    main.caught_pokemon=state.parties[actor].duplicate(true)
    main.battle_enemy_party=state.parties[opponent].duplicate(true)
    # A double battle's slots hold both active Pokemon of each player.
    var mine:Array=state.slots[actor] if state.slots[actor] is Array else [state.slots[actor]]
    var theirs:Array=state.slots[opponent] if state.slots[opponent] is Array else [state.slots[opponent]]
    main.battle_is_double=mine.size()==2
    main.battle_party_index=int(mine[0])
    main.battle_enemy_party_index=int(theirs[0])
    main.battle_player=main.caught_pokemon[main.battle_party_index]
    main.battle_enemy=main.battle_enemy_party[main.battle_enemy_party_index]
    if main.battle_is_double:
        main.battle_partner_party_index=int(mine[1])
        main.battle_enemy_partner_party_index=int(theirs[1])
        main.battle_player_partner=main.caught_pokemon[main.battle_partner_party_index]
        main.battle_enemy_partner=main.battle_enemy_party[main.battle_enemy_partner_party_index]
    main.battle_field=state.field.duplicate(true)
    if actor!=String(game.interaction_ui.interaction.get("a",actor)):
        var player_spikes=int(main.battle_field.get("player_spikes",0))
        main.battle_field.player_spikes=int(main.battle_field.get("enemy_spikes",0))
        main.battle_field.enemy_spikes=player_spikes
    main.battle_turn_count=int(state.turn)

func submit(action:Dictionary)->void:
    if not active or starting or playing:return
    main._close_battle_submenu()
    main.battle_turn_busy=true
    main._show_battle_message_screen()
    main._start_battle_text("WAITING FOR PLAYER...")
    var result:Dictionary=await game.command("battle_action",{"turn":int(state.turn),"action":action})
    if not active:return
    if not result.get("ok",false):
        await main._type_battle_text(String(result.get("reason","COULD NOT COMPLETE ACTION")).replace("_"," "))
        _next_choice()

## What this player does next: send out a Pokemon, wait for the other player,
## or choose (a double battle's choices start again from its first slot).
func _next_choice()->void:
    main.battle_turn_busy=false
    if state.replacement.has(actor):
        if main.battle_is_double:
            main.battle_double_replacement_slot=int(state.replacement[actor].slots[0])
            main._open_battle_party_menu("DOUBLE_FORCED")
        else:main._open_battle_party_menu("FORCED")
    elif not state.replacement.is_empty():
        main.battle_turn_busy=true;main._start_battle_text("WAITING FOR PLAYER...")
    else:
        if main.battle_is_double:
            main.battle_double_actions.clear()
            main.battle_double_command_slot=0 if int(main.battle_player.get("hp",0))>0 else 1
            main.battle_move_index=0
        main._show_battle_command_screen()

func play_queue()->void:
    playing=true
    while active and not queue.is_empty():
        var update:Dictionary=queue.pop_front()
        main.inventory=update.battle_inventory.get(actor,main.inventory).duplicate(true)
        var events:Array=update.get("battle_events",[])
        if events.is_empty():continue
        main.battle_turn_busy=true;main._close_battle_submenu();main._show_battle_message_screen()
        for event in events:
            if not active:break
            var player_side=event.actor==actor
            if main.battle_is_double:
                await _play_double_event(event,player_side)
                continue
            var player_hp=int(main.battle_player.hp);var enemy_hp=int(main.battle_enemy.hp)
            apply_state(event.state)
            var message=String(event.get("message",""))
            if event.kind=="move":
                var result:Dictionary=event.result.duplicate(true)
                message=String(result.get("message",""))
                if not message.is_empty():await main._type_battle_text(message)
                if not active:break
                if result.get("executed",false):
                    await main._play_battle_feedback(String(result.get("animation_move",event.move)),player_side,result,main.battle_enemy if player_side else main.battle_player)
                else:await main._play_blocked_status_feedback(main.battle_player if player_side else main.battle_enemy,player_side,message)
            elif not message.strip_edges().is_empty():await main._type_battle_text(message)
            if not active:break
            main._refresh_battle_sprites()
            await main._animate_visible_battle_hp(main.battle_player,player_hp,int(main.battle_player.hp))
            await main._animate_visible_battle_hp(main.battle_enemy,enemy_hp,int(main.battle_enemy.hp))
            main._update_battle_hud()
        if not active:break
        apply_state(update.battle_state)
        if state.finished:
            await main._type_battle_text("The battle ended in a draw." if String(state.winner).is_empty() else "You won!" if state.winner==actor else "The other player won!")
            main._end_battle("")
            await game.command("battle_done",{})
            break
        _next_choice()
    playing=false

## A double battle's event: a move as a single-player double battle shows it
## (main._play_double_move_event), anything else as its line; then the bars.
func _play_double_event(event:Dictionary,player_side:bool)->void:
    var shown:Array=[main.battle_player,main.battle_player_partner,main.battle_enemy,main.battle_enemy_partner]
    var hp_before:Array=shown.map(func(pokemon):return int(pokemon.get("hp",0)))
    if event.kind=="move":
        var side:="player" if player_side else "enemy"
        var target_side:="player" if event.target_actor==actor else "enemy"
        var defender:Dictionary=main._double_actor(target_side,int(event.target_slot))
        var move:={"result":event.result.duplicate(true),"move":event.move,"player_side":player_side,
            "target_player_side":target_side=="player","status_before":BattleSession.status_snapshot(defender),
            "attacker_hp_before":int(main._double_actor(side,int(event.slot)).get("hp",0)),"defender_hp_before":int(defender.get("hp",0))}
        apply_state(event.state)
        move["attacker"]=main._double_actor(side,int(event.slot))
        move["defender"]=main._double_actor(target_side,int(event.target_slot))
        await main._play_double_move_event(move)
        return
    apply_state(event.state)
    var message=String(event.get("message",""))
    if not message.strip_edges().is_empty():await main._type_battle_text(message)
    if not active:return
    main._refresh_battle_sprites()
    var now:Array=[main.battle_player,main.battle_player_partner,main.battle_enemy,main.battle_enemy_partner]
    for i in range(now.size()):await main._animate_visible_battle_hp(now[i],hp_before[i],int(now[i].get("hp",0)))
    main._update_battle_hud()

func restore()->void:
    if not active:return
    main.caught_pokemon=original_party
    main.inventory=original_inventory
    main.world.pending_encounter_record=original_pending
    original_party=[];original_inventory={};original_pending={}
    active=false;starting=false;queue.clear()

func closed()->void:
    if active:main._end_battle("")
