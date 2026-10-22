# PvP battles in the game: player A plays through main.gd's battle menus and
# coop_pvp_runtime.gd against a scripted player B, the host being
# coop_interactions.gd with its BattleSession, as in a co-op game. In the
# double battle A chooses for both Pokemon (moves and their targets, a switch,
# an item) and replaces a fainted one; the single battle covers the single
# battle's menus. Every choice must be taken, every turn shown, and the
# battle must end where the host's did, the player's own party untouched.
# Run: godot --headless --path project -s <this file>
extends SceneTree

const Paths = preload("res://scripts/game_data_paths.gd")
const Clock = preload("res://scripts/game_clock.gd")
const Battle = preload("res://scripts/battle_engine.gd")
const Options = preload("res://scripts/game_options.gd")
const Commands = preload("res://scripts/coop_commands.gd")

class FakeState extends RefCounted:
    var records := {}
    var members := {}

class FakeUI extends Control:
    var interaction := {}

## The co-op game as the PvP runtime sees it: commands go to the host here.
class FakeGame extends Node:
    var main: Node
    var session := {"actor": "A"}
    var interaction_ui := FakeUI.new()
    var host = preload("res://scripts/coop_interactions.gd").new()
    var pvp: Node
    var refused: Array = []
    func command(operation: String, args: Dictionary) -> Dictionary:
        await get_tree().process_frame
        var result: Dictionary = {"ok": false}
        if operation == "battle_action": result = host.battle_action("A", int(args.turn), args.action)
        elif operation == "battle_done": result = host.battle_done("A")
        if not result.get("ok", false): refused.append("%s %s: %s" % [operation, args, result.get("reason", "")])
        push(result)
        return result
    ## The host's answer, as both players get it.
    func push(result: Dictionary) -> void:
        if result.get("session") is Dictionary:
            pvp.receive(preload("res://scripts/coop_commands.gd").visible_result(result, "A").session)

var main: Node
var game: FakeGame
var checks := 0
var failed := 0
var shown: Array[String] = []
var used: Dictionary = {}

func check(ok: bool, what: String) -> void:
    checks += 1
    if not ok:
        failed += 1
        printerr("FAIL: ", what)

func _initialize() -> void:
    var dir := OS.get_temp_dir().path_join("pvp_battle_test_%d" % Time.get_ticks_usec())
    DirAccess.make_dir_recursive_absolute(dir)
    FileAccess.open(dir.path_join(".private-saves-migrated"), FileAccess.WRITE).close()
    Paths.directory = dir
    change_scene_to_file("res://scenes/main.tscn")
    for i in 30: await process_frame
    main = current_scene
    while not main.startup_complete: await process_frame
    main.coop_menu.close()
    main.world_edit.text = "PvP"
    main.selected_mode = "NEW"
    main.selected_world_size = 0
    main._start_game()
    while not main.started: await process_frame
    for i in 30: await process_frame
    main.battle_text_shown.connect(func(message: String) -> void: shown.append(message))
    Clock.virtual_origin = Clock.ticks_usec()
    Clock.real_origin = Time.get_ticks_usec()
    Clock.multiplier = 40.0
    Engine.time_scale = 40.0
    Options.values["battle_animations"] = false
    game = FakeGame.new()
    game.main = main
    root.add_child(game)
    game.pvp = preload("res://scripts/coop_pvp_runtime.gd").new()
    root.add_child(game.pvp)
    game.pvp.configure(game)
    main.coop_game.pvp = game.pvp
    # B's side is the stronger in the double battle: A's Pokemon faint and are replaced.
    await _battle("DOUBLE BATTLE", 46, 8)
    await _battle("BATTLE", 47, 0)
    print("PVP BATTLE TEST: %d checks, %d failed" % [checks, failed])
    quit(1 if failed > 0 else 0)

func _member(species: String, level: int, moves: Array, rng: RandomNumberGenerator) -> Dictionary:
    return Battle.make_pokemon(species, level, rng, {"moves": moves})

func _battle(kind: String, seed_value: int, their_boost: int) -> void:
    var rng := RandomNumberGenerator.new()
    rng.seed = seed_value
    var own: Array = [_member("pikachu", 30, ["THUNDERBOLT", "QUICK_ATTACK", "THUNDER_WAVE", "DOUBLE_TEAM"], rng),
        _member("geodude", 28, ["MAGNITUDE", "ROCK_THROW", "DEFENSE_CURL", "SELFDESTRUCT"], rng),
        _member("wartortle", 30, ["WATER_GUN", "BITE", "PROTECT", "TOXIC"], rng)]
    var theirs: Array = [_member("charmeleon", 30 + their_boost, ["EMBER", "SLASH", "SMOKESCREEN", "RAGE"], rng),
        _member("pidgeotto", 29 + their_boost, ["GUST", "QUICK_ATTACK", "SAND_ATTACK", "WING_ATTACK"], rng),
        _member("ekans", 28 + their_boost, ["WRAP", "POISON_STING", "BITE", "GLARE"], rng)]
    main.caught_pokemon = own.duplicate(true)
    main.inventory = {"POTION": 2}
    var host = game.host
    host.state = FakeState.new()
    host.state.records = {"player/A": {"party": own, "inventory": {"POTION": 2}},
        "player/B": {"party": theirs, "inventory": {"SUPER POTION": 1}}}
    host.state.members = {"A": {"name": "RED"}, "B": {"name": "BLUE", "model": 1}}
    host.battle_item_rules = main.BATTLE_ITEM_RULES
    host.presence = {"A": {"area": "a", "x": 0, "y": 0, "fx": 1, "fy": 0},
        "B": {"area": "a", "x": 1, "y": 0, "fx": -1, "fy": 0}}
    check(host.request("A", "B", kind).get("ok", false), "%s: the request is taken" % kind)
    var answered: Dictionary = host.answer("B", true)
    var double := kind == "DOUBLE BATTLE"
    check(answered.get("ok", false) and (answered.session.battle_state.slots.A is Array) == double,
        "%s: the host starts a %s battle" % [kind, "double" if double else "single"])
    var model = host.battles[answered.session.id]
    model.rng.seed = seed_value # the same battle every run
    game.interaction_ui.interaction = answered.session
    game.refused.clear()
    shown.clear()
    used = {}
    game.push(answered)
    var frames := 0
    var done_sent := false
    while frames < 300000:
        await process_frame
        frames += 1
        if main.battle_text_busy: main._finish_battle_text()
        if model.finished and not main.battle_active and not game.pvp.playing:
            if not done_sent:
                done_sent = true
                check(host.battle_done("B").get("kind") == "closed", "%s: both players done closes the battle" % kind)
            break
        _player_b(model)
        if game.pvp.starting or game.pvp.playing or main.battle_text_busy or main.source_effect_playing: continue
        if main.battle_ui_mode == "INTRO" and main.battle_panel.visible and not main.battle_turn_busy:
            main._advance_battle_intro()
        elif main.battle_submenu_mode in ["FORCED", "DOUBLE_FORCED"]:
            used[main.battle_submenu_mode] = int(used.get(main.battle_submenu_mode, 0)) + 1
            main._confirm_battle_submenu()
        elif main.battle_ui_mode == "COMMAND" and not main.battle_turn_busy and main.battle_submenu_mode.is_empty():
            _player_a(model)
    check(frames < 300000, "%s: the battle ends (frame %d, mode %s, busy %s)" % [kind, frames, main.battle_ui_mode, main.battle_turn_busy])
    check(game.refused.is_empty(), "%s: every choice is taken: %s" % [kind, game.refused])
    check(not main.battle_active and not game.pvp.active, "%s: the battle is over" % kind)
    var final: Dictionary = model.pvp_snapshot()
    check(JSON.stringify(game.pvp.state.parties) == JSON.stringify(final.parties) and game.pvp.state.finished,
        "%s: the game ends on the host's state" % kind)
    var ending := "You won!" if final.winner == "A" else "The other player won!" if final.winner == "B" else "The battle ended in a draw."
    check(shown.has(ending), "%s: %s shown" % [kind, ending])
    check(JSON.stringify(main.caught_pokemon) == JSON.stringify(own) and main.inventory == {"POTION": 2},
        "%s: the player's own party and bag are untouched" % kind)
    if double:
        check(shown.any(func(line): return line.begins_with("Target ")), "double: moves are shown per target")
        for choice in ["target", "switch", "item", "DOUBLE_FORCED"]:
            check(used.has(choice), "double: A chose with %s (%s)" % [choice, used])
    else:
        check(used.has("FORCED"), "single: A sent out a Pokemon after a faint (%s)" % used)
    print("PVP %s: %d turns, %d lines, choices %s" % [kind, final.turn, shown.size(), used])

## Player A at the command menu: for the double battle's first turns a move
## on a chosen target and a spread move, then a switch and an item.
func _player_a(model) -> void:
    if not main.battle_is_double:
        main.battle_move_index = 0
        main._battle_fight()
        return
    var slot: int = main.battle_double_command_slot
    var pokemon: Dictionary = main._command_pokemon()
    if model.pvp_turn == 1 and slot == 0:
        main.battle_command_index = 1
        main._activate_battle_command()
        for index in range(main.battle_submenu_entries.size()):
            if int(main.battle_submenu_entries[index].index) not in [main.battle_party_index, main.battle_partner_party_index] \
                    and int(main.battle_submenu_entries[index].pokemon.hp) > 0:
                main.battle_submenu_index = index
                used["switch"] = true
                main._confirm_battle_submenu()
                return
        main._close_battle_submenu()
    if model.pvp_turn >= 1 and not used.has("item"):
        for index in range(main.caught_pokemon.size()):
            var member: Dictionary = main.caught_pokemon[index]
            if int(member.hp) > 0 and int(member.hp) < int(member.max_hp):
                used["item"] = true
                main._use_battle_item_on("POTION", index)
                return
    main.battle_command_index = 0
    main._activate_battle_command()
    main.battle_move_index = 0
    main._battle_fight()
    if main.battle_submenu_mode == "DOUBLE_TARGET":
        used["target"] = true
        main.battle_submenu_index = main.battle_submenu_entries.size() - 1
        main._confirm_battle_submenu()

## Player B, scripted: the first move of each Pokemon at A's first one, and
## the first Pokemon able to come in after a faint.
func _player_b(model) -> void:
    if model.finished: return
    if model.replacement.has("B"):
        var action := {"kind": "switch"}
        if model.double:
            var bench: Array = model.healthy("B").filter(func(index): return index not in model._active_indices("enemy"))
            action.merge({"slot": int(model.replacement.B.slots[0]), "index": int(bench[0])})
        else:
            var bench: Array = model.healthy("B")
            bench.erase(model.slots.B)
            action["index"] = int(bench[0])
        game.push(game.host.battle_action("B", model.pvp_turn, action))
    elif model.pvp_actions.has("A") and not model.pvp_actions.has("B") and model.replacement.is_empty():
        var action := {"kind": "move", "move": ""}
        if model.double:
            var choices: Array = []
            for entry in model.living("enemy"):
                choices.append({"slot": int(entry.slot), "move": _usable(entry.pokemon), "target_side": "enemy", "target_slot": 0})
            action = {"kind": "double", "actions": choices}
        else:
            action.move = _usable(model.current("B"))
        game.push(game.host.battle_action("B", model.pvp_turn, action))

static func _usable(pokemon: Dictionary) -> String:
    for move in pokemon.moves:
        if Battle.move_is_usable(pokemon, String(move)): return String(move)
    return "STRUGGLE"
