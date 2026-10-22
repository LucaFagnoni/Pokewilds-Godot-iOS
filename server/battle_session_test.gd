# BattleSession (scripts/battle_session.gd) against the battle transcripts
# recorded from the game (fixtures/battles/, battle_transcript_record.gd).
# Each battle is played again with no scene: the same inputs where the game
# asked for them, and it must show the same lines, be in the same state at
# every input (RNG included) and end the same way. PvP battles must give the
# host's same replies. A small model of the battle menus stands in for main.gd
# (its prompts and the choices it refuses before a turn starts).
# Run: godot --headless --path project -s <this file> [-- --only NAME]
extends SceneTree

const Session = preload("res://scripts/battle_session.gd")
const Battle = preload("res://scripts/battle_engine.gd")
const PokemonState = preload("res://scripts/pokemon_state.gd")

var Record: Script
var session
var played: Array = []
var inputs: Array = []
var input_at := 0

func _initialize() -> void:
    var here := (get_script() as Script).resource_path.get_base_dir()
    Record = load(here.path_join("battle_transcript_record.gd"))
    var args := OS.get_cmdline_user_args()
    var only := String(args[args.find("--only") + 1]) if args.has("--only") else ""
    var folder := here.path_join("fixtures/battles")
    var files := Array(DirAccess.get_files_at(folder))
    files.sort()
    var failures: Array[String] = []
    var checked := 0
    for file in files:
        if not String(file).ends_with(".json"): continue
        var fixture: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(folder.path_join(file)))
        if not only.is_empty() and only != String(fixture.name): continue
        checked += 1
        var actual := fixture.duplicate()
        actual["log"] = _play_pvp(fixture) if fixture.kind == "pvp" else _play_single(fixture)
        var difference: String = Record.compare(fixture, Record._plain(actual))
        if difference.is_empty() and fixture.kind != "pvp":
            difference = _check_replay()
        if difference.is_empty():
            print("SESSION SAME: %s (%d entries)" % [fixture.name, (fixture.log as Array).size()])
        else:
            failures.append(String(fixture.name))
            printerr("SESSION DIFFERS: %s: %s" % [fixture.name, difference])
    print("BATTLE SESSION TEST: %d battles, %d differ%s" % [checked, failures.size(),
        "" if failures.is_empty() else ": " + ", ".join(failures)])
    quit(1 if not failures.is_empty() or checked == 0 else 0)

## JSON numbers come back as floats: whole ones are ints again, as in the game.
static func _ints(value) -> Variant:
    if value is float and value == floorf(value) and absf(value) < 9.0e15: return int(value)
    if value is Array: return (value as Array).map(_ints)
    if value is Dictionary:
        var out := {}
        for key in value: out[key] = _ints(value[key])
        return out
    return value

# --- PvP -----------------------------------------------------------------------------------

func _play_pvp(fixture: Dictionary) -> Array:
    session = Session.new()
    var started: bool = session.pvp_start("A", "B", _ints(fixture.parties), int(fixture.seed),
        _ints(fixture.inventories), Session.ITEM_RULES)
    var out: Array = [{"start": started, "reply": Record.reply_digest({"state": session.pvp_snapshot(),
        "events": session.pvp_events})}]
    for entry in fixture.log:
        if not entry.has("submit"): continue
        var submit: Dictionary = _ints(entry.submit)
        out.append({"submit": submit, "reply": Record.reply_digest(session.pvp_submit(
            String(submit.actor), int(submit.turn), submit.action))})
    return out

# --- single-player ------------------------------------------------------------------------

func _play_single(fixture: Dictionary) -> Array:
    played = []
    inputs = (fixture.log as Array).filter(func(entry): return entry.has("at"))
    input_at = 0
    session = Session.new()
    session.rng.seed = int(fixture.seed)
    var party: Array = _ints(fixture.party)
    var context: Dictionary = Session.prepare_context(_ints(fixture.context), party)
    if not session.begin(context, party, _ints(fixture.inventory), (fixture.world as Dictionary).duplicate()):
        played.append({"text": "You have no Pokemon able to battle."})
        return played
    _intro()
    _run([{"kind": "command", "slot": 0}])
    return played

## The battle just played, replayed from its log alone (as the co-op host
## checks a reported wild battle) must end the same way in the same state.
func _check_replay() -> String:
    if not session.finished:
        return ""
    var end_state := _state()
    var report: Dictionary = JSON.parse_string(JSON.stringify(session.replay_log(true)))
    var again = Session.new()
    var fitted: bool = again.replay(String(report.rng).to_int(), _ints(report.context), _ints(report.party),
        _ints(report.bag), _ints(report.facts), _ints(report.inputs))
    session = again
    if not fitted:
        return "the replay refused its own inputs"
    if again.outcome != String(played[-1].get("end", "")) or _state().sha != end_state.sha:
        return "the replay ended %s, not %s" % [again.outcome, played[-1].get("end", "")]
    return ""

## The lines the battle opens with (main.gd's intro screens and cinematics).
func _intro() -> void:
    var context: Dictionary = session.context
    var intro: String = Session.intro_text(context, session.enemy)
    var lines: Array = [intro, intro]
    var boss := String(context.get("source_boss", ""))
    if not boss.is_empty():
        lines.append("The battlefield quakes under REGIGIGAS' presence!" if boss == "regigigas" else "MEGA GENGAR attacked!")
        lines.append("Go! %s!" % PokemonState.display_name(session.player))
    elif bool(context.get("source_mewtwo", false)):
        lines.append_array(["An oppressive force surrounds you...", "MEWTWO unleashes its full power!", intro,
            "Go! %s!" % PokemonState.display_name(session.player)])
    else:
        lines.append_array(context.get("_entry_messages", []))
    for line in lines: played.append({"text": line})

func _state() -> Dictionary:
    var s = session
    return Record.digest(Record.full_state(s.party, s.enemy_party,
        [s.party_index, s.partner_index, s.enemy_index, s.enemy_partner_index], s.field,
        [s.turn_count, s.run_attempts, s.enemy_action_count, s.boss_action_count],
        s.participants, s.context, s.inventory, s.rng))

## The transcript's next input when it is of `kind` (null otherwise: the
## comparison then shows where the battles part).
func _next_input(kind: String) -> Variant:
    if input_at >= inputs.size() or String(inputs[input_at].at) != kind: return null
    var input: Dictionary = _ints(inputs[input_at].input)
    input_at += 1
    played.append({"at": kind, "input": input, "state": _state()})
    return input

func _run(events: Array) -> void:
    var queue := events
    while not queue.is_empty():
        var event: Dictionary = queue.pop_front()
        for line in Session.event_lines(event): played.append({"text": line})
        var answer = null
        match String(event.kind):
            "end":
                played.append({"end": event.outcome, "state": _state()})
                return
            "command":
                var next = _command(int(event.get("slot", 0)))
                if next == null: return
                queue.append_array(next)
                continue
            "switch":
                answer = _next_input("pick")
                if answer == null: return
                answer = int(answer.pick)
            "forget":
                answer = _next_input("forget")
                if answer == null: return
                answer = int(answer.forget)
            "evolve":
                answer = _next_input("evolve")
                if answer == null: return
                answer = bool(answer.evolve)
            _:
                continue
        queue.append_array(session.submit(answer))

## A turn chosen at the command screen, as main.gd's menus take it; null when
## the transcript has no more inputs.
func _command(slot: int) -> Variant:
    if session.double:
        return _double_command(slot)
    var prompt := true
    while true:
        if prompt: played.append({"text": Session.command_text(session.player)})
        prompt = true
        var input = _next_input("command")
        if input == null: return null
        if input.has("move"):
            return session.submit({"kind": "move", "move": Session.chosen_move(session.player, int(input.move))})
        if input.has("switch"):
            var index := int(input.switch)
            # The party menu refuses (its prompt says why) and the battle asks again.
            if index == session.party_index or int(session.party[index].get("hp", 0)) <= 0 or Session.trapped(session.player):
                continue
            return session.submit({"kind": "switch", "index": index})
        if input.has("item"):
            var refusal: String = session.item_refusal(String(input.item), int(input.on))
            if not refusal.is_empty():
                played.append({"text": refusal})
                continue
            return session.submit({"kind": "item", "item": String(input.item), "index": int(input.on)})
        var action := {}
        if input.has("ball"):
            if int(session.inventory.get(String(input.ball), 0)) <= 0:
                prompt = false
                continue
            action = {"kind": "ball", "ball": String(input.ball)}
        elif input.has("run"):
            action = {"kind": "run"}
        elif input.has("silph"):
            if int(session.inventory.get("SILPH SCOPE", 0)) <= 0 or not bool(session.enemy.get("is_ghost", false)):
                prompt = false
                continue
            action = {"kind": "silph_scope"}
        elif input.has("doll"):
            if int(session.inventory.get("POKE DOLL", 0)) <= 0:
                prompt = false
                continue
            action = {"kind": "poke_doll"}
        var said: String = session.refusal(action)
        if not said.is_empty():
            played.append({"text": said})
            prompt = false
            continue
        return session.submit(action)
    return null

func _double_command(slot: int) -> Variant:
    var actions: Array = []
    var prompt := true
    while true:
        var actor: Dictionary = session.partner if slot == 1 else session.player
        if prompt: played.append({"text": Session.command_text(actor)})
        prompt = true
        var input = _next_input("command")
        if input == null: return null
        if input.has("move"):
            if not actor.is_empty() and int(actor.get("hp", 0)) > 0:
                var move := Session.chosen_move(actor, int(input.move))
                if Battle.move_targets_self(move):
                    actions.append(_double_action(slot, move, slot, "player"))
                elif Battle.move_targets_all(move):
                    actions.append(_double_action(slot, move, -1))
                else:
                    var targets: Array = session.living("enemy")
                    var target := -1
                    if not targets.is_empty():
                        target = int(targets[0].slot)
                        for entry in targets:
                            if int(entry.slot) == int(input.get("target", 0)): target = int(entry.slot)
                    actions.append(_double_action(slot, move, target))
        elif input.has("switch"):
            var index := int(input.switch)
            if index in [session.party_index, session.partner_index] or int(session.party[index].get("hp", 0)) <= 0:
                continue
            if Session.trapped(actor):
                played.append({"text": "%s cannot switch out!" % PokemonState.display_name(actor)})
                continue
            actions.append({"kind": "switch", "side": "player", "slot": slot, "switch_index": index,
                "move": "", "target_slot": -1, "spread": false})
        elif input.has("item"):
            var refusal: String = session.item_refusal(String(input.item), int(input.on))
            if not refusal.is_empty():
                played.append({"text": refusal})
                continue
            for event in session.submit({"kind": "item", "item": String(input.item), "index": int(input.on)}):
                for line in Session.event_lines(event): played.append({"text": line})
        else:
            continue
        if slot == 0 and not session.partner.is_empty() and int(session.partner.get("hp", 0)) > 0:
            slot = 1
            continue
        return session.submit({"kind": "double", "actions": actions})
    return null

static func _double_action(slot: int, move: String, target_slot: int, target_side := "enemy") -> Dictionary:
    return {"side": "player", "slot": slot, "move": move, "target_slot": target_slot,
        "target_side": target_side, "spread": Battle.move_targets_all(move)}
