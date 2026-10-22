# Battle transcripts: scripted battles played through the real game (main.gd,
# a new S world on a throwaway data folder) with the battle RNG seeded. Every
# line the battle shows is recorded (main.battle_text_shown), with each input
# the script gives, the state at that input and how the battle ends. The PvP
# battles are recorded from the host's PvP battle (two scripted players, no
# scene). Without --check the transcripts are written to fixtures/battles/
# next to this file; with --check every battle is played again and compared
# with its transcript (exit 1 on any difference). Battle animations are off
# unless --animations is given: headless, the moves that copy the screen wait
# for a frame that never comes. The lines and states are the same either way,
# so a windowed run with --animations checks against the same transcripts.
# Run: godot --headless --path project -s <this file> -- [--check] [--only NAME] [--pvp]
extends SceneTree

const Paths = preload("res://scripts/game_data_paths.gd")
const Clock = preload("res://scripts/game_clock.gd")
const Battle = preload("res://scripts/battle_engine.gd")
const Events = preload("res://scripts/source_event_data.gd")
const Session = preload("res://scripts/battle_session.gd")
const Options = preload("res://scripts/game_options.gd")

## Animations and waits run this many times faster (they keep their order).
const SPEED := 40.0
## Mid-morning on the world clock: every battle is fought by day.
const DAY_SECONDS := 60.0
## Mon fields kept in the state snapshots (personality, IVs and stats are fixed
## or follow from species and level).
const MON_KEYS := ["species", "level", "hp", "max_hp", "status", "status_counter",
    "toxic_counter", "exp", "moves", "pp", "stages", "volatile", "types",
    "held_item", "is_ghost", "evs", "friendship", "form", "pokeball"]

var main: Node
var check := false
var verbose := false
var only := ""
var failures: Array[String] = []
var transcript_log: Array = []
var ended := false

func _frames(count: int) -> void:
    for i in count: await process_frame

func _initialize() -> void:
    var args := OS.get_cmdline_user_args()
    check = args.has("--check")
    verbose = args.has("--verbose")
    if args.has("--only"): only = String(args[args.find("--only") + 1])
    for scenario in pvp_scenarios():
        if only.is_empty() or only == scenario.name: _record_pvp(scenario)
    var singles: Array = [] if args.has("--pvp") else scenarios().filter(func(s): return only.is_empty() or only == s.name)
    if not singles.is_empty():
        var dir := OS.get_temp_dir().path_join("battle_transcripts_%d" % Time.get_ticks_usec())
        DirAccess.make_dir_recursive_absolute(dir)
        FileAccess.open(dir.path_join(".private-saves-migrated"), FileAccess.WRITE).close()
        Paths.directory = dir
        change_scene_to_file("res://scenes/main.tscn")
        await _frames(30)
        main = current_scene
        while not main.startup_complete: await process_frame
        main.coop_menu.close()
        main.world_edit.text = "Transcripts"
        main.selected_mode = "NEW"
        main.selected_world_size = 0
        main._start_game()
        var waited := 0
        while not main.started and waited < 60000:
            await process_frame
            waited += 1
        if not main.started:
            printerr("TRANSCRIPTS: the world did not start")
            quit(1)
            return
        await _frames(30)
        main.battle_text_shown.connect(func(message: String) -> void:
            if verbose: print("  TEXT ", message.replace("\n", " / "))
            transcript_log.append({"text": message}))
        main.battle_ended.connect(_on_battle_ended)
        _set_speed(SPEED)
        Options.values["battle_animations"] = args.has("--animations")
        for scenario in singles:
            await _record_single(scenario)
        _set_speed(1.0)
    failures.append_array(replay_failures)
    print("TRANSCRIPTS: %s, %d failed%s" % ["checked" if check else "recorded",
        failures.size(), "" if failures.is_empty() else ": " + ", ".join(failures)])
    quit(1 if not failures.is_empty() else 0)

func _set_speed(speed: float) -> void:
    Clock.virtual_origin = Clock.ticks_usec()
    Clock.real_origin = Time.get_ticks_usec()
    Clock.multiplier = speed
    Engine.time_scale = speed

# --- single-player battles ---------------------------------------------------

func _record_single(scenario: Dictionary) -> void:
    var rng := RandomNumberGenerator.new()
    rng.seed = int(scenario.seed) * 7919
    var party: Array = []
    for spec in scenario.party: party.append(_make_member(spec, rng))
    var inventory: Dictionary = scenario.get("inventory", {}).duplicate(true)
    var context: Dictionary = scenario.context.duplicate(true)
    context["terrain"] = String(context.get("terrain", "GRASSY"))
    var commands: Array = scenario.get("inputs", []).duplicate(true)
    var picks: Array = scenario.get("picks", []).duplicate(true)
    var forgets: Array = scenario.get("forgets", []).duplicate(true)
    var evolves: Array = scenario.get("evolves", []).duplicate(true)
    var transcript := {"name": scenario.name, "kind": "single", "seed": int(scenario.seed),
        "context": _plain(context), "party": _plain(party), "inventory": _plain(inventory),
        "world": {"time_of_day": "day", "night": false, "indoors": false, "surfing": false}}
    main.world.world_elapsed_seconds = DAY_SECONDS
    main.world.pending_encounter_record = {}
    main.ball_mechanics.requested_battler = ""
    main.caught_pokemon = party.duplicate(true)
    main.inventory = inventory.duplicate(true)
    main.last_battle_ball = ""
    main.source_mewtwo_intro_seen = true
    main.battle_rng.seed = int(scenario.seed)
    transcript_log = []
    ended = false
    main._start_battle_context(context)
    var frames := 0
    var command_count := 0
    var evolving := false
    current_name = String(scenario.name)
    if verbose: print("SCENARIO ", scenario.name)
    while frames < 400000:
        await process_frame
        frames += 1
        if verbose and frames % 2000 == 0:
            print("  frame %d active=%s ui=%s busy=%s text=%s entry=%s sub=%s prog=%s/%s effect=%s" % [frames,
                main.battle_active, main.battle_ui_mode, main.battle_turn_busy, main.battle_text_busy,
                main.battle_entry_pending, main.battle_submenu_mode, main.progression_mode,
                main.progression_active, main.source_effect_playing])
        main.world.world_elapsed_seconds = DAY_SECONDS
        if ended and not main.battle_active:
            break
        if main.battle_text_busy:
            main._finish_battle_text()
        if main.progression_mode == "STATS" and main.progression_waiting_input:
            main.progression_waiting_input = false
            main.progression_confirmed.emit()
            continue
        if main.progression_mode in ["YES_NO", "MOVE_GIVEUP"]:
            main.progression_mode = ""
            main.progression_choice_made.emit(1)
            continue
        if main.progression_mode == "MOVE_SELECT":
            var forget := int(forgets.pop_front()) if not forgets.is_empty() else -1
            transcript_log.append({"at": "forget", "input": {"forget": forget}, "state": _state()})
            main.progression_mode = ""
            main.progression_choice_made.emit(forget)
            continue
        if main.progression_mode == "EVOLUTION" and not evolving:
            evolving = true
            var evolve := bool(evolves.pop_front()) if not evolves.is_empty() else true
            transcript_log.append({"at": "evolve", "input": {"evolve": evolve}, "state": _state()})
            if not evolve: main.evolution_cancel_requested = true
            continue
        if main.progression_mode != "EVOLUTION": evolving = false
        if main.battle_submenu.visible and main.battle_submenu_mode in ["FORCED", "BATON_PASS", "DOUBLE_FORCED"]:
            var pick := _valid_pick(int(picks.pop_front()) if not picks.is_empty() else -1)
            transcript_log.append({"at": "pick", "input": {"pick": pick}, "state": _state()})
            _select_party_entry(pick)
            main._confirm_battle_submenu()
            continue
        if not main.battle_active or main.battle_turn_busy or main.battle_text_busy or main.battle_entry_pending:
            continue
        if main.battle_ui_mode == "INTRO" and main.battle_panel.visible and not main.source_effect_playing:
            main._advance_battle_intro()
            continue
        if main.battle_ui_mode != "COMMAND" or not main.battle_submenu_mode.is_empty() or \
                main.battle_item_pocket_open or main.progression_active:
            continue
        command_count += 1
        if command_count > int(scenario.get("max_inputs", 60)):
            failures.append("%s (no end after %d inputs)" % [scenario.name, command_count - 1])
            return
        var input: Dictionary = commands.pop_front() if not commands.is_empty() else scenario.get("default", {"move": 0}).duplicate(true)
        var resolved := _resolve_input(input)
        transcript_log.append({"at": "command", "input": resolved, "state": _state()})
        if verbose: print("  INPUT ", resolved)
        _apply_input(resolved)
        if main.battle_submenu.visible and main.battle_submenu_mode in ["PARTY", "ITEM_TARGET", "DOUBLE_SWITCH"]:
            # A refused switch or item (it would not help) leaves its menu open: back out.
            main._close_battle_submenu()
            main._show_battle_command_screen()
    if frames >= 400000:
        failures.append("%s (timed out)" % scenario.name)
        return
    await _frames(10)
    transcript["log"] = transcript_log
    _finish(transcript)

func _on_battle_ended(outcome: String) -> void:
    ended = true
    var state := _state()
    transcript_log.append({"end": outcome, "state": state})
    _check_replay(outcome, state)

## The battle just fought, replayed from its own log with no view (as the
## co-op host checks a reported wild battle): it must end the same way in the
## same state, the choices made on main.gd's experience screens included.
func _check_replay(outcome: String, state: Dictionary) -> void:
    var session = main.get("battle_session")
    if session == null or not session.finished:
        return
    var report: Dictionary = _plain(session.replay_log(true))
    var replay = Session.new()
    var fitted: bool = Session.valid_report(report) and replay.replay(String(report.rng).to_int(),
        Session.whole_numbers(report.context), Session.whole_numbers(report.party),
        Session.whole_numbers(report.bag), Session.whole_numbers(report.facts),
        Session.whole_numbers(report.inputs))
    var again := digest(full_state(replay.party, replay.enemy_party, [replay.party_index,
        replay.partner_index, replay.enemy_index, replay.enemy_partner_index], replay.field,
        [replay.turn_count, replay.run_attempts, replay.enemy_action_count, replay.boss_action_count],
        replay.participants, replay.context, replay.inventory, replay.rng))
    if not fitted or replay.outcome != outcome or again.sha != state.sha:
        replay_failures.append("%s replay (%s)" % [current_name, "refused" if not fitted else replay.outcome])

var replay_failures: Array[String] = []
var current_name := ""

## Script inputs name moves; the transcript keeps the index the input chose.
func _resolve_input(input: Dictionary) -> Dictionary:
    var resolved := input.duplicate(true)
    if resolved.has("move") and resolved.move is String:
        var moves: Array = main._command_pokemon().get("moves", [])
        resolved.move = maxi(0, moves.find(String(resolved.move)))
    return resolved

func _apply_input(input: Dictionary) -> void:
    if input.has("move"):
        main.battle_move_index = int(input.move)
        main._show_battle_message_screen()
        main._battle_fight()
        if main.battle_submenu_mode == "DOUBLE_TARGET":
            var slot := int(input.get("target", 0))
            var choice := 0
            for index in range(main.battle_submenu_entries.size()):
                if int(main.battle_submenu_entries[index].get("target_slot", -1)) == slot: choice = index
            main.battle_submenu_index = choice
            main._confirm_battle_submenu()
    elif input.has("switch"):
        if main.battle_is_double:
            main.battle_double_replacement_slot = main.battle_double_command_slot
            main._open_battle_party_menu("DOUBLE_SWITCH")
            _select_party_entry(int(input.switch))
            main._confirm_battle_submenu()
        else:
            main._open_battle_party_menu("PARTY")
            _select_party_entry(int(input.switch))
            main._switch_from_battle_party_action(int(input.switch))
    elif input.has("item"):
        main.battle_pending_item = String(input.item)
        main._open_battle_party_menu("ITEM_TARGET")
        _select_party_entry(int(input.get("on", 0)))
        main._confirm_battle_submenu()
    elif input.has("ball"):
        main._battle_throw_ball(String(input.ball))
    elif input.has("run"):
        main._battle_run()
    elif input.has("silph"):
        main._battle_use_silph_scope()
    elif input.has("doll"):
        main._battle_use_poke_doll()

func _select_party_entry(party_index: int) -> void:
    for index in range(main.battle_submenu_entries.size()):
        if int(main.battle_submenu_entries[index].get("index", -1)) == party_index:
            main.battle_submenu_index = index

func _valid_pick(wanted: int) -> int:
    var active := [main.battle_party_index, main.battle_partner_party_index]
    var valid: Array[int] = []
    for index in range(main.caught_pokemon.size()):
        var pokemon: Dictionary = main.caught_pokemon[index]
        if index not in active and int(pokemon.get("hp", 0)) > 0 and not bool(pokemon.get("is_egg", false)):
            valid.append(index)
    return wanted if wanted in valid else (valid[0] if not valid.is_empty() else wanted)

func _make_member(spec: Dictionary, rng: RandomNumberGenerator) -> Dictionary:
    var overrides := spec.duplicate(true)
    for key in ["species", "level", "hp", "status", "exp_to_next"]: overrides.erase(key)
    var pokemon := Battle.make_pokemon(String(spec.species), int(spec.level), rng, overrides)
    if spec.has("hp"): pokemon.hp = clampi(int(spec.hp), 0, int(pokemon.max_hp))
    if spec.has("status"): pokemon.status = String(spec.status)
    if spec.has("exp_to_next"):
        pokemon.exp = Battle.exp_for_level(String(pokemon.species), int(pokemon.level) + 1) - int(spec.exp_to_next)
    return pokemon

## The state at an input: a hash of everything below, and a summary to read.
func _state() -> Dictionary:
    var full := full_state(main.caught_pokemon, main.battle_enemy_party,
        [main.battle_party_index, main.battle_partner_party_index,
            main.battle_enemy_party_index, main.battle_enemy_partner_party_index],
        main.battle_field, _counters(),
        main.battle_exp_participants, main.battle_context, main.inventory, main.battle_rng)
    last_full_state = full
    return digest(full)

## Turns, run attempts and the enemy's action counts (main.gd kept these
## itself before its battles ran on the battle session).
func _counters() -> Array:
    var session = main.get("battle_session")
    if session != null:
        return [session.turn_count, session.run_attempts, session.enemy_action_count, session.boss_action_count]
    return [main.battle_turn_count, main.battle_run_attempts,
        main.battle_enemy_action_count, main.source_boss_action_count]

var last_full_state: Dictionary = {}

static func full_state(party: Array, enemy: Array, active: Array, field: Dictionary,
        counters: Array, participants: Array, context: Dictionary, inventory: Dictionary,
        rng: RandomNumberGenerator) -> Dictionary:
    return _plain({
        "party": party.map(_mon), "enemy": enemy.map(_mon), "active": active.duplicate(),
        "field": field.duplicate(true), "counters": counters.duplicate(),
        "participants": participants.duplicate(),
        "context": {"heals": int(context.get("_trainer_heals_used", 0)),
            "revealed": context.get("ghost_revealed", null),
            "can_catch": context.get("can_catch", null)},
        "inventory": inventory.duplicate(true), "rng": str(rng.state)})

static func digest(full: Dictionary) -> Dictionary:
    var mons := func(list: Array) -> Array:
        return list.map(func(mon): return [mon.get("species"), mon.get("level"), mon.get("hp"),
            mon.get("status"), mon.get("exp")] if mon is Dictionary else mon)
    var field: Dictionary = full.field
    return {"sha": JSON.stringify(full).sha256_text().left(20), "party": mons.call(full.party),
        "enemy": mons.call(full.enemy), "field": [field.get("weather"), field.get("weather_turns"),
            field.get("player_spikes"), field.get("enemy_spikes")], "rng": full.rng}

static func _mon(raw) -> Variant:
    if not raw is Dictionary: return raw
    var out := {}
    for key in MON_KEYS:
        if (raw as Dictionary).has(key): out[key] = raw[key]
    return out

static func _plain(value) -> Variant:
    return JSON.parse_string(JSON.stringify(value))

## A PvP reply as the transcript keeps it: what the players read, and a hash
## of the whole reply (every event's state included).
static func reply_digest(reply: Dictionary) -> Dictionary:
    var plain: Dictionary = _plain(reply)
    var events: Array = plain.get("events", []).map(func(event): return [event.get("kind"),
        event.get("actor"), String(event.get("message", event.get("result", {}).get("message", "")))])
    var out := {"ok": plain.get("ok"), "sha": JSON.stringify(plain).sha256_text().left(20), "events": events}
    for key in ["reason", "waiting"]:
        if plain.has(key): out[key] = plain[key]
    if plain.has("state"):
        var state: Dictionary = plain.state
        out["finished"] = state.get("finished")
        out["winner"] = state.get("winner")
    return out

# --- PvP --------------------------------------------------------------------

func _record_pvp(scenario: Dictionary) -> void:
    var rng := RandomNumberGenerator.new()
    rng.seed = int(scenario.seed) * 7919
    var parties := {"A": [], "B": []}
    for actor in ["A", "B"]:
        for spec in scenario[actor]: parties[actor].append(_make_member(spec, rng))
    var inventories: Dictionary = scenario.get("inventories", {"A": {}, "B": {}}).duplicate(true)
    var rules: Dictionary = Session.ITEM_RULES
    var transcript := {"name": scenario.name, "kind": "pvp", "seed": int(scenario.seed),
        "parties": _plain(parties), "inventories": _plain(inventories)}
    var battle_format := String(scenario.get("format", "single"))
    if battle_format != "single": transcript["format"] = battle_format
    var model = Session.new()
    var started: bool = model.pvp_start("A", "B", parties.duplicate(true), int(scenario.seed), inventories.duplicate(true), rules, battle_format)
    var entries: Array = [{"start": started, "reply": reply_digest({"state": model.pvp_snapshot(), "events": model.pvp_events})}]
    var picks: Dictionary = scenario.get("picks", {}).duplicate(true)
    for step in scenario.steps:
        if model.finished: break
        if step.has("raw"):
            var raw: Dictionary = step.raw
            var turn := int(model.pvp_turn) + int(raw.get("turn_offset", 0))
            entries.append({"submit": {"actor": raw.actor, "turn": turn, "action": raw.action},
                "reply": reply_digest(model.pvp_submit(String(raw.actor), turn, raw.action))})
            continue
        while model.double and not model.replacement.is_empty() and not model.finished:
            for actor in ["A", "B"]:
                if not model.replacement.has(actor): continue
                for slot in (model.replacement[actor].slots as Array).duplicate():
                    var queue: Array = picks.get(actor, [])
                    var choice: int = int(queue.pop_front()) if not queue.is_empty() else -1
                    var bench: Array = model.healthy(actor).filter(func(index): return index not in model._active_indices(model._side_of(actor)))
                    if choice not in bench: choice = int(bench[0]) if not bench.is_empty() else 0
                    var action := {"kind": "switch", "slot": slot, "index": choice}
                    entries.append({"submit": {"actor": actor, "turn": model.pvp_turn, "action": action},
                        "reply": reply_digest(model.pvp_submit(actor, model.pvp_turn, action))})
        while not model.double and not model.replacement.is_empty() and not model.finished:
            for actor in ["A", "B"]:
                if not model.replacement.has(actor): continue
                var queue: Array = picks.get(actor, [])
                var choice: int = int(queue.pop_front()) if not queue.is_empty() else -1
                var healthy: Array = model.healthy(actor)
                healthy.erase(model.slots[actor])
                if choice not in healthy: choice = int(healthy[0]) if not healthy.is_empty() else 0
                var action := {"kind": "switch", "index": choice}
                entries.append({"submit": {"actor": actor, "turn": model.pvp_turn, "action": action},
                    "reply": reply_digest(model.pvp_submit(actor, model.pvp_turn, action))})
        for actor in ["A", "B"]:
            if model.finished: break
            var action: Dictionary = step.get(actor, {}).duplicate(true)
            if model.double:
                # A scripted choice the battle refuses (its Pokemon fainted or left) falls back.
                if not action.is_empty():
                    var turn: int = model.pvp_turn
                    var reply: Dictionary = model.pvp_submit(actor, turn, action)
                    entries.append({"submit": {"actor": actor, "turn": turn, "action": action}, "reply": reply_digest(reply)})
                    if reply.get("ok", false): continue
                action = _default_double(model, actor)
            elif action.is_empty() or (action.get("kind") == "move" and not Battle.move_is_usable(model.current(actor), String(action.get("move", "")))):
                action = {"kind": "move", "move": _first_usable(model.current(actor))}
            entries.append({"submit": {"actor": actor, "turn": model.pvp_turn, "action": action},
                "reply": reply_digest(model.pvp_submit(actor, model.pvp_turn, action))})
    transcript["log"] = entries
    _finish(transcript)

## Each living Pokemon's first usable move, at the other side's first slot.
static func _default_double(model, actor: String) -> Dictionary:
    var actions: Array = []
    for entry in model.living(model._side_of(actor)):
        actions.append({"slot": int(entry.slot), "move": _first_usable(entry.pokemon), "target_slot": 0, "target_side": "enemy"})
    return {"kind": "double", "actions": actions}

static func _first_usable(pokemon: Dictionary) -> String:
    for move in pokemon.get("moves", []):
        if Battle.move_is_usable(pokemon, String(move)): return String(move)
    return "STRUGGLE"

# --- fixtures ---------------------------------------------------------------

func _fixture_path(name: String) -> String:
    return (get_script() as Script).resource_path.get_base_dir().path_join("fixtures/battles/%s.json" % name)

func _finish(transcript: Dictionary) -> void:
    var path := _fixture_path(String(transcript.name))
    if check:
        var saved = JSON.parse_string(FileAccess.get_file_as_string(path)) if FileAccess.file_exists(path) else null
        if not saved is Dictionary:
            failures.append("%s (no transcript)" % transcript.name)
            return
        var difference := compare(saved, _plain(transcript))
        if not difference.is_empty():
            failures.append(String(transcript.name))
            printerr("TRANSCRIPT DIFFERS: %s: %s" % [transcript.name, difference])
        else:
            print("TRANSCRIPT SAME: %s (%d entries)" % [transcript.name, (saved.log as Array).size()])
        return
    DirAccess.make_dir_recursive_absolute(path.get_base_dir())
    var lines: Array[String] = ["{"]
    for key in transcript.keys():
        if key != "log": lines.append("%s: %s," % [JSON.stringify(key), JSON.stringify(transcript[key])])
    lines.append("\"log\": [")
    var entries: Array = transcript.log
    for index in range(entries.size()):
        lines.append(JSON.stringify(entries[index]) + ("," if index < entries.size() - 1 else ""))
    lines.append("]}")
    var file := FileAccess.open(path, FileAccess.WRITE)
    file.store_string("\n".join(lines) + "\n")
    file.close()
    print("TRANSCRIPT RECORDED: %s (%d entries)" % [transcript.name, entries.size()])

## The first difference between two transcripts, or "" when they are the same.
static func compare(expected: Dictionary, actual: Dictionary) -> String:
    for key in expected.keys():
        if key == "log": continue
        if JSON.stringify(expected[key]) != JSON.stringify(actual.get(key)):
            return "%s: %s != %s" % [key, JSON.stringify(expected[key]).left(300), JSON.stringify(actual.get(key)).left(300)]
    var a: Array = expected.log
    var b: Array = actual.log
    for index in range(mini(a.size(), b.size())):
        var left := JSON.stringify(a[index])
        var right := JSON.stringify(b[index])
        if left != right:
            return "entry %d:\n  expected %s\n  actual   %s" % [index, left.left(1200), right.left(1200)]
    if a.size() != b.size():
        return "%d entries expected, %d played (next: %s)" % [a.size(), b.size(),
            JSON.stringify(a[b.size()] if a.size() > b.size() else b[a.size()]).left(600)]
    return ""

# --- scripts ----------------------------------------------------------------

static func _wild(species: String, level: int, extra: Dictionary = {}) -> Dictionary:
    var context := {"id": "wild", "kind": "wild", "can_run": true, "can_catch": true,
        "fixed_level": true, "terrain": "GRASSY", "party": [{"species": species, "level": level}]}
    context.merge(extra, true)
    return context

static func scenarios() -> Array:
    var savanna := Events.trainer_spec("SAVANNA", 14, "transcript_savanna")
    var twins := Events.trainer_spec("FOREST", 12, "transcript_twins")
    var regigigas := Events.event_spec("regigigas")
    var mewtwo := Events.event_spec("mewtwo")
    var gengar := Events.event_spec("mega_gengar")
    return [
        {"name": "wild_basic", "seed": 11,
            "party": [{"species": "squirtle", "level": 12, "moves": ["TACKLE", "TAIL_WHIP", "WATER_GUN", "WITHDRAW"]}],
            "inventory": {"POKE BALL": 5, "POTION": 2},
            "context": _wild("rattata", 10, {"fixed_level": false}),
            "inputs": [{"move": "TAIL_WHIP"}], "default": {"move": "WATER_GUN"}},
        {"name": "wild_run", "seed": 12,
            "party": [{"species": "slowpoke", "level": 14, "moves": ["TACKLE", "CURSE", "GROWL", "WATER_GUN"]}],
            "context": _wild("pikachu", 14),
            "inputs": [{"run": true}, {"run": true}, {"run": true}, {"run": true}, {"run": true}, {"run": true}],
            "default": {"run": true}},
        {"name": "wild_catch", "seed": 13,
            "party": [{"species": "pikachu", "level": 18, "moves": ["THUNDER_WAVE", "QUICK_ATTACK", "THUNDERSHOCK", "GROWL"]}],
            "inventory": {"POKE BALL": 3, "HEAL BALL": 2, "FRIEND BALL": 2, "GREAT BALL": 3},
            "context": _wild("scyther", 14),
            "inputs": [{"move": "THUNDER_WAVE"}, {"ball": "POKE BALL"}, {"ball": "POKE BALL"}, {"ball": "HEAL BALL"},
                {"ball": "FRIEND BALL"}, {"ball": "GREAT BALL"}, {"ball": "GREAT BALL"}, {"ball": "GREAT BALL"}],
            "default": {"move": "THUNDERSHOCK"}},
        {"name": "wild_switch_items", "seed": 14,
            "party": [{"species": "machop", "level": 14, "moves": ["LOW_KICK", "LEER", "FOCUS_ENERGY", "KARATE_CHOP"]},
                {"species": "geodude", "level": 14, "moves": ["TACKLE", "DEFENSE_CURL", "ROLLOUT", "MAGNITUDE"]},
                {"species": "bulbasaur", "level": 12, "hp": 0},
                {"species": "charmander", "level": 12, "hp": 14, "status": "POISON"}],
            "inventory": {"POTION": 3, "ANTIDOTE": 1, "REVIVE": 1, "FULL HEAL": 1, "SUPER POTION": 1},
            "context": {"id": "wild", "kind": "wild", "can_run": true, "can_catch": true, "fixed_level": true, "terrain": "GRASSY",
                "party": [{"species": "sandshrew", "level": 14, "moves": ["SCRATCH", "POISON_STING"]}]},
            "inputs": [{"switch": 1}, {"item": "REVIVE", "on": 2}, {"item": "ANTIDOTE", "on": 3},
                {"item": "POTION", "on": 0}, {"move": "TACKLE"}, {"switch": 0}, {"move": "LOW_KICK"}],
            "default": {"move": "LOW_KICK"}},
        {"name": "wild_status_weather", "seed": 15,
            "party": [{"species": "poliwrath", "level": 30, "moves": ["TOXIC", "RAIN_DANCE", "CONFUSE_RAY", "HYPNOSIS"]},
                {"species": "tyranitar", "level": 30, "moves": ["SANDSTORM", "LEECH_SEED", "SUNNY_DAY", "CRUNCH"]}],
            "context": _wild("snorlax", 35),
            "inputs": [{"move": "TOXIC"}, {"move": "RAIN_DANCE"}, {"move": "CONFUSE_RAY"}, {"move": "HYPNOSIS"},
                {"switch": 1}, {"move": "LEECH_SEED"}, {"move": "SANDSTORM"}, {"move": "SUNNY_DAY"}],
            "default": {"move": "CRUNCH"}, "picks": [0]},
        {"name": "trainer_single", "seed": 16,
            "party": [{"species": "wartortle", "level": 18, "moves": ["TACKLE", "WATER_GUN", "BITE", "WITHDRAW"], "exp_to_next": 40},
                {"species": "pidgeotto", "level": 17, "moves": ["GUST", "QUICK_ATTACK", "SAND_ATTACK", "WHIRLWIND"]}],
            "context": savanna,
            "inputs": [{"move": "WATER_GUN"}, {"move": "BITE"}, {"switch": 1}, {"move": "GUST"}, {"switch": 0}],
            "default": {"move": "WATER_GUN"}, "forgets": [3], "picks": [1, 0]},
        {"name": "trainer_ai_switch", "seed": 17,
            "party": [{"species": "pikachu", "level": 22, "moves": ["THUNDERSHOCK", "QUICK_ATTACK", "THUNDER_WAVE", "GROWL"]}],
            "context": {"id": "transcript_ai", "kind": "trainer", "trainer_name": "SWIMMER", "intro": "SWIMMER wants to battle!",
                "can_run": false, "can_catch": false, "ai_level": 2, "trainer_heals": 1, "terrain": "AQUATIC",
                "party": [{"species": "magikarp", "level": 20, "moves": ["SPLASH"]}, {"species": "onix", "level": 18},
                    {"species": "golbat", "level": 19}]},
            "inputs": [{"move": "THUNDER_WAVE"}], "default": {"move": "THUNDERSHOCK"}},
        {"name": "whiteout", "seed": 18,
            "party": [{"species": "magikarp", "level": 5, "moves": ["SPLASH"]}, {"species": "caterpie", "level": 3, "moves": ["TACKLE", "STRING_SHOT"]}],
            "context": {"id": "wild", "kind": "wild", "can_run": true, "can_catch": true, "fixed_level": true, "terrain": "GRASSY",
                "party": [{"species": "golem", "level": 40, "moves": ["ROCK_THROW"]}]},
            "inputs": [{"move": "SPLASH"}], "default": {"move": 0}, "picks": [1]},
        {"name": "level_up_evolution", "seed": 19,
            "party": [{"species": "charmander", "level": 15, "moves": ["SCRATCH", "GROWL", "EMBER", "SMOKESCREEN"]},
                {"species": "machamp", "level": 30, "moves": ["KARATE_CHOP", "LOW_KICK", "LEER", "FOCUS_ENERGY"]},
                {"species": "pidgey", "level": 17, "moves": ["TACKLE", "GUST", "SAND_ATTACK", "QUICK_ATTACK"], "exp_to_next": 50}],
            "context": {"id": "wild", "kind": "wild", "can_run": true, "can_catch": true, "fixed_level": true, "terrain": "GRASSY",
                "party": [{"species": "chansey", "level": 40, "moves": ["SPLASH"]}]},
            "inputs": [{"switch": 2}, {"switch": 1}, {"move": "KARATE_CHOP"}], "default": {"move": "KARATE_CHOP"},
            "forgets": [-1, 1], "evolves": [true, false]},
        {"name": "special_move", "seed": 20,
            "party": [{"species": "geodude", "level": 24, "moves": ["TACKLE", "DEFENSE_CURL", "ROCK_THROW", "MAGNITUDE"]}],
            "context": {"id": "transcript_special", "kind": "special", "can_run": false, "can_catch": true, "terrain": "SANDY",
                "special_every": 2, "special_move": "HYPER_BEAM", "special_power": 40,
                "special_message": "It is enraged!", "party": [{"species": "rhyhorn", "level": 20}]},
            "default": {"move": "ROCK_THROW"}},
        {"name": "roar_ends", "seed": 21,
            "party": [{"species": "arcanine", "level": 30, "moves": ["ROAR", "EMBER", "BITE", "LEER"]}],
            "context": _wild("rattata", 28), "inputs": [{"move": "ROAR"}], "default": {"move": "EMBER"}},
        {"name": "enemy_whirlwind", "seed": 22,
            "party": [{"species": "rattata", "level": 22, "moves": ["BITE", "QUICK_ATTACK", "TACKLE", "HYPER_FANG"]},
                {"species": "pidgey", "level": 20, "moves": ["GUST", "TACKLE", "QUICK_ATTACK"]},
                {"species": "sandshrew", "level": 20, "moves": ["SCRATCH", "SAND_ATTACK", "POISON_STING", "RAPID_SPIN"]}],
            "context": {"id": "wild", "kind": "wild", "can_run": true, "can_catch": true, "fixed_level": true, "terrain": "GRASSY",
                "party": [{"species": "pidgeot", "level": 22, "moves": ["WHIRLWIND"]}]},
            "default": {"move": 0}, "picks": [2, 0, 1, 2, 0, 1]},
        {"name": "baton_pass", "seed": 23,
            "party": [{"species": "eevee", "level": 35, "moves": ["BATON_PASS", "SWORDS_DANCE", "QUICK_ATTACK", "BITE"]},
                {"species": "jolteon", "level": 35, "moves": ["THUNDERBOLT", "DOUBLE_KICK", "PIN_MISSILE", "AGILITY"]}],
            "context": {"id": "wild", "kind": "wild", "can_run": true, "can_catch": true, "fixed_level": true, "terrain": "GRASSY",
                "party": [{"species": "snorlax", "level": 33, "moves": ["TACKLE"]}]},
            "inputs": [{"move": "SWORDS_DANCE"}, {"move": "BATON_PASS"}, {"move": "DOUBLE_KICK"}],
            "default": {"move": "DOUBLE_KICK"}, "picks": [1, 0]},
        {"name": "enemy_teleport", "seed": 24,
            "party": [{"species": "growlithe", "level": 10, "moves": ["EMBER", "LEER", "BITE"]}],
            "context": _wild("abra", 10), "default": {"move": "LEER"}},
        {"name": "ghost_silph_scope", "seed": 25,
            "party": [{"species": "snorlax", "level": 30, "moves": ["BODY_SLAM", "REST", "CRUNCH", "DEFENSE_CURL"]}],
            "inventory": {"SILPH SCOPE": 1, "POKE BALL": 5},
            "context": {"id": "ghost_transcript", "kind": "ghost", "can_run": true, "can_catch": true,
                "intro": "A ghost appeared from the darkness!", "requires_silph_scope": true, "ghost_revealed": false,
                "_wild_level_scaled": true, "fixed_level": true, "terrain": "GRASSY",
                "party": [{"species": "haunter", "level": 21}]},
            "inputs": [{"ball": "POKE BALL"}, {"silph": true}, {"move": "CRUNCH"}, {"ball": "POKE BALL"}],
            "default": {"move": "CRUNCH"}},
        {"name": "poke_doll", "seed": 26,
            "party": [{"species": "psyduck", "level": 25, "moves": ["SCRATCH", "WATER_GUN", "CONFUSION", "DISABLE"]}],
            "inventory": {"POKE DOLL": 1},
            "context": {"id": "wild", "kind": "wild", "can_run": true, "can_catch": true, "fixed_level": true, "terrain": "GRASSY",
                "party": [{"species": "tauros", "level": 15, "moves": ["TACKLE", "TAIL_WHIP"]}]}, "inputs": [{"move": "DISABLE"}, {"doll": true}], "default": {"move": "WATER_GUN"}},
        {"name": "pay_day_heal_bell", "seed": 27,
            "party": [{"species": "meowth", "level": 20, "moves": ["PAY_DAY", "SCRATCH", "BITE", "GROWL"], "status": "PARALYSIS"},
                {"species": "chansey", "level": 30, "moves": ["HEAL_BELL", "SOFTBOILED", "POUND", "SING"], "status": "BURN"}],
            "inventory": {"COINS": 10},
            "context": _wild("ekans", 20),
            "inputs": [{"move": "PAY_DAY"}, {"move": "PAY_DAY"}, {"switch": 1}, {"move": "HEAL_BELL"}, {"move": "SING"}],
            "default": {"move": "POUND"}},
        {"name": "move_variety", "seed": 28,
            "party": [{"species": "nidoking", "level": 40, "moves": ["DOUBLE_KICK", "THRASH", "FURY_ATTACK", "EARTHQUAKE"]},
                {"species": "pidgeot", "level": 40, "moves": ["FLY", "MIRROR_MOVE", "QUICK_ATTACK", "WHIRLWIND"]}],
            "context": _wild("snorlax", 45),
            "inputs": [{"move": "DOUBLE_KICK"}, {"move": "THRASH"}, {"move": "THRASH"}, {"move": "THRASH"},
                {"move": "FURY_ATTACK"}, {"switch": 1}, {"move": "FLY"}, {"move": "FLY"}, {"move": "MIRROR_MOVE"}],
            "default": {"move": "EARTHQUAKE"}, "picks": [0, 1]},
        {"name": "spikes_trainer", "seed": 29,
            "party": [{"species": "cloyster", "level": 32, "moves": ["SPIKES", "AURORA_BEAM", "PROTECT", "CLAMP"]}],
            "context": {"id": "transcript_spikes", "kind": "trainer", "trainer_name": "HIKER", "intro": "HIKER wants to battle!",
                "can_run": false, "can_catch": false, "ai_level": 2, "trainer_heals": 1, "terrain": "SANDY",
                "party": [{"species": "geodude", "level": 26}, {"species": "magikarp", "level": 26, "moves": ["SPLASH"]},
                    {"species": "sandshrew", "level": 27}]},
            "inputs": [{"move": "SPIKES"}, {"move": "SPIKES"}, {"move": "SPIKES"}], "default": {"move": "AURORA_BEAM"}},
        {"name": "double_wild", "seed": 30,
            "party": [{"species": "geodude", "level": 15, "moves": ["TACKLE", "DEFENSE_CURL", "ROCK_THROW", "EARTHQUAKE"]},
                {"species": "squirtle", "level": 11, "moves": ["TACKLE", "TAIL_WHIP", "WATER_GUN", "SURF"]},
                {"species": "charmander", "level": 14, "moves": ["SCRATCH", "GROWL", "EMBER", "SMOKESCREEN"]},
                {"species": "pidgey", "level": 12, "moves": ["TACKLE", "GUST"]}],
            "context": {"id": "wild_double", "kind": "wild", "battle_format": "double", "can_run": true, "can_catch": true,
                "fixed_level": true, "terrain": "GRASSY",
                "party": [{"species": "rattata", "level": 17}, {"species": "spearow", "level": 17}]},
            "inputs": [{"move": "ROCK_THROW", "target": 1}, {"switch": 2}, {"move": "EARTHQUAKE"},
                {"move": "EMBER", "target": 0}, {"move": "TACKLE", "target": 1}, {"move": "SMOKESCREEN", "target": 1},
                {"move": "ROCK_THROW", "target": 0}, {"move": "SCRATCH", "target": 0}],
            "default": {"move": 0, "target": 0}, "picks": [3, 1]},
        {"name": "double_trainer", "seed": 31,
            "party": [{"species": "geodude", "level": 17, "moves": ["TACKLE", "DEFENSE_CURL", "ROCK_THROW", "MAGNITUDE"], "exp_to_next": 30},
                {"species": "charmander", "level": 16, "moves": ["SCRATCH", "GROWL", "EMBER", "SMOKESCREEN"]},
                {"species": "squirtle", "level": 15, "moves": ["TACKLE", "TAIL_WHIP", "WATER_GUN", "BITE"], "exp_to_next": 20}],
            "context": twins,
            "inputs": [{"move": "ROCK_THROW", "target": 1}, {"move": "EMBER", "target": 0},
                {"move": "ROCK_THROW", "target": 0}, {"item": "POTION", "on": 1}],
            "inventory": {"POTION": 2},
            "default": {"move": 2, "target": 0}, "forgets": [1], "evolves": [true], "picks": [2]},
        {"name": "struggle", "seed": 35,
            "party": [{"species": "rattata", "level": 12, "moves": ["TACKLE"], "pp": {"TACKLE": 1}}],
            "context": {"id": "wild", "kind": "wild", "can_run": true, "can_catch": true, "fixed_level": true, "terrain": "SANDY",
                "party": [{"species": "metapod", "level": 14, "moves": ["HARDEN"]}]},
            "default": {"move": "TACKLE"}},
        {"name": "boss_regigigas", "seed": 32,
            "party": [{"species": "steelix", "level": 100, "moves": ["IRON_TAIL", "HARDEN", "ROCK_THROW", "SCREECH"]}],
            "inventory": {"MASTER BALL": 1},
            "context": regigigas.merged({"terrain": "SANDY"}, true),
            "inputs": [{"move": "HARDEN"}, {"move": "HARDEN"}, {"move": "SCREECH"}, {"move": "IRON_TAIL"},
                {"move": "IRON_TAIL"}, {"ball": "MASTER BALL"}], "default": {"move": "IRON_TAIL"}},
        {"name": "boss_mega_gengar", "seed": 33,
            "party": [{"species": "snorlax", "level": 100, "moves": ["BODY_SLAM", "REST", "CRUNCH", "DEFENSE_CURL"]}],
            "inventory": {"MASTER BALL": 1},
            "context": gengar.merged({"terrain": "GRASSY"}, true),
            "inputs": [{"move": "CRUNCH"}, {"move": "DEFENSE_CURL"}, {"ball": "MASTER BALL"}], "default": {"move": "CRUNCH"}},
        {"name": "boss_mewtwo", "seed": 34,
            "party": [{"species": "snorlax", "level": 100, "moves": ["BODY_SLAM", "REST", "CRUNCH", "DEFENSE_CURL"]}],
            "inventory": {"MASTER BALL": 1},
            "context": mewtwo.merged({"terrain": "GRASSY"}, true),
            "inputs": [{"move": "DEFENSE_CURL"}, {"move": "DEFENSE_CURL"}, {"move": "DEFENSE_CURL"}, {"move": "CRUNCH"},
                {"ball": "MASTER BALL"}], "default": {"move": "CRUNCH"}},
    ]

static func pvp_scenarios() -> Array:
    return [
        {"name": "pvp_singles", "seed": 41,
            "A": [{"species": "wartortle", "level": 30, "moves": ["WATER_GUN", "BITE", "TOXIC", "PROTECT"]},
                {"species": "pikachu", "level": 28, "moves": ["THUNDERBOLT", "QUICK_ATTACK", "THUNDER_WAVE", "DOUBLE_TEAM"]}],
            "B": [{"species": "charmeleon", "level": 30, "moves": ["EMBER", "SLASH", "SMOKESCREEN", "RAGE"]},
                {"species": "sandslash", "level": 29, "moves": ["DIG", "SLASH", "SAND_ATTACK", "SWIFT"]}],
            "steps": [{"A": {"kind": "move", "move": "TOXIC"}, "B": {"kind": "move", "move": "SMOKESCREEN"}},
                {"A": {"kind": "move", "move": "PROTECT"}, "B": {"kind": "move", "move": "EMBER"}},
                {"A": {"kind": "move", "move": "WATER_GUN"}, "B": {"kind": "move", "move": "SLASH"}},
                {"A": {"kind": "move", "move": "WATER_GUN"}, "B": {"kind": "move", "move": "SLASH"}},
                {}, {}, {}, {}, {}, {}, {}, {}, {}, {}, {}, {}, {}, {}],
            "picks": {"A": [1], "B": [1]}},
        {"name": "pvp_items_switch_run", "seed": 42,
            "A": [{"species": "machop", "level": 25, "moves": ["KARATE_CHOP", "LEER", "FOCUS_ENERGY", "SEISMIC_TOSS"]},
                {"species": "geodude", "level": 25, "moves": ["ROCK_THROW", "MAGNITUDE", "DEFENSE_CURL", "SELFDESTRUCT"], "hp": 0}],
            "B": [{"species": "gloom", "level": 25, "moves": ["ABSORB", "SLEEP_POWDER", "ACID", "STUN_SPORE"]},
                {"species": "ekans", "level": 24, "moves": ["WRAP", "POISON_STING", "BITE", "GLARE"]}],
            "inventories": {"A": {"REVIVE": 1, "POTION": 2, "AWAKENING": 1}, "B": {"SUPER POTION": 1, "FULL HEAL": 1}},
            "steps": [{"A": {"kind": "move", "move": "KARATE_CHOP"}, "B": {"kind": "move", "move": "SLEEP_POWDER"}},
                {"A": {"kind": "item", "item": "AWAKENING", "index": 0}, "B": {"kind": "switch", "index": 1}},
                {"A": {"kind": "item", "item": "REVIVE", "index": 1}, "B": {"kind": "move", "move": "WRAP"}},
                {"raw": {"actor": "A", "action": {"kind": "switch", "index": 1}}},
                {"raw": {"actor": "A", "turn_offset": -1, "action": {"kind": "move", "move": "LEER"}}},
                {"raw": {"actor": "A", "action": {"kind": "move", "move": "HYPER_BEAM"}}},
                {"raw": {"actor": "A", "action": {"kind": "item", "item": "POTION", "index": 5}}},
                {"raw": {"actor": "B", "action": {"kind": "jump"}}},
                {"A": {"kind": "move", "move": "SEISMIC_TOSS"}, "B": {"kind": "item", "item": "SUPER POTION", "index": 1}},
                {"A": {"kind": "move", "move": "SEISMIC_TOSS"}, "B": {"kind": "move", "move": "BITE"}},
                {"A": {"kind": "run"}}]},
        {"name": "pvp_baton_roar_teleport", "seed": 43,
            "A": [{"species": "eevee", "level": 35, "moves": ["BATON_PASS", "SWORDS_DANCE", "QUICK_ATTACK", "BITE"]},
                {"species": "arcanine", "level": 35, "moves": ["ROAR", "FLAMETHROWER", "BITE", "AGILITY"]},
                {"species": "abra", "level": 30, "moves": ["TELEPORT"]}],
            "B": [{"species": "pidgeot", "level": 35, "moves": ["WHIRLWIND", "WING_ATTACK", "QUICK_ATTACK", "SAND_ATTACK"]},
                {"species": "golem", "level": 34, "moves": ["ROCK_THROW", "EARTHQUAKE", "DEFENSE_CURL", "SELFDESTRUCT"]}],
            "steps": [{"A": {"kind": "move", "move": "SWORDS_DANCE"}, "B": {"kind": "move", "move": "SAND_ATTACK"}},
                {"A": {"kind": "move", "move": "BATON_PASS"}, "B": {"kind": "move", "move": "WING_ATTACK"}},
                {"A": {"kind": "move", "move": "ROAR"}, "B": {"kind": "move", "move": "WHIRLWIND"}},
                {"A": {"kind": "move", "move": "FLAMETHROWER"}, "B": {"kind": "move", "move": "EARTHQUAKE"}},
                {"A": {"kind": "switch", "index": 2}, "B": {"kind": "move", "move": "QUICK_ATTACK"}},
                {"A": {"kind": "move", "move": "TELEPORT"}, "B": {"kind": "move", "move": "QUICK_ATTACK"}}],
            "picks": {"A": [1, 2], "B": [1]}},
        {"name": "pvp_selfdestruct_draw", "seed": 44,
            "A": [{"species": "golem", "level": 30, "moves": ["SELFDESTRUCT"]}],
            "B": [{"species": "weezing", "level": 30, "moves": ["SELFDESTRUCT"]}],
            "steps": [{"A": {"kind": "move", "move": "SELFDESTRUCT"}, "B": {"kind": "move", "move": "SELFDESTRUCT"}}, {}, {}]},
        {"name": "pvp_doubles", "seed": 45, "format": "double",
            "A": [{"species": "pikachu", "level": 30, "moves": ["THUNDERBOLT", "QUICK_ATTACK", "THUNDER_WAVE", "DOUBLE_TEAM"]},
                {"species": "geodude", "level": 28, "moves": ["MAGNITUDE", "ROCK_THROW", "DEFENSE_CURL", "SELFDESTRUCT"]},
                {"species": "wartortle", "level": 30, "moves": ["WATER_GUN", "BITE", "PROTECT", "TOXIC"]}],
            "B": [{"species": "charmeleon", "level": 30, "moves": ["EMBER", "SLASH", "SMOKESCREEN", "RAGE"]},
                {"species": "pidgeotto", "level": 29, "moves": ["GUST", "QUICK_ATTACK", "SAND_ATTACK", "WING_ATTACK"]},
                {"species": "ekans", "level": 28, "moves": ["WRAP", "POISON_STING", "BITE", "GLARE"]}],
            "inventories": {"A": {"POTION": 2, "REVIVE": 1}, "B": {"SUPER POTION": 1}},
            "steps": [
                # Refused: a single battle's move, one slot short, a target that is not there, a stale turn.
                {"raw": {"actor": "A", "action": {"kind": "move", "move": "THUNDERBOLT"}}},
                {"raw": {"actor": "A", "action": {"kind": "double", "actions": [{"slot": 0, "move": "THUNDERBOLT", "target_slot": 0}]}}},
                {"raw": {"actor": "B", "action": {"kind": "double", "actions": [{"slot": 0, "move": "EMBER", "target_slot": 3},
                    {"slot": 1, "move": "GUST", "target_slot": 0}]}}},
                {"raw": {"actor": "B", "turn_offset": -1, "action": {"kind": "double", "actions": [{"slot": 0, "move": "EMBER", "target_slot": 0},
                    {"slot": 1, "move": "GUST", "target_slot": 0}]}}},
                # Refused: numbers that are not whole numbers in range, a party index that is not a number.
                {"raw": {"actor": "A", "action": {"kind": "double", "actions": [{"slot": "0", "move": "THUNDERBOLT", "target_slot": 0},
                    {"slot": 1, "move": "MAGNITUDE", "target_slot": 0}]}}},
                {"raw": {"actor": "B", "action": {"kind": "double", "actions": [{"slot": 0, "move": "EMBER", "target_slot": 0.5},
                    {"slot": 1, "move": "GUST", "target_slot": 0}]}}},
                {"raw": {"actor": "A", "action": {"kind": "double", "actions": [{"slot": 0, "kind": "use_item", "item": "POTION", "index": {"x": 1}},
                    {"slot": 1, "move": "MAGNITUDE", "target_slot": 0}]}}},
                {"A": {"kind": "double", "actions": [{"slot": 0, "move": "QUICK_ATTACK", "target_side": "enemy", "target_slot": 1},
                        {"slot": 1, "move": "DEFENSE_CURL", "target_side": "player", "target_slot": 1}]},
                    "B": {"kind": "double", "actions": [{"slot": 0, "move": "EMBER", "target_side": "enemy", "target_slot": 0},
                        {"slot": 1, "move": "GUST", "target_side": "enemy", "target_slot": 1}]}},
                {"A": {"kind": "double", "actions": [{"slot": 0, "kind": "switch", "switch_index": 2},
                        {"slot": 1, "kind": "use_item", "item": "POTION", "index": 1}]},
                    "B": {"kind": "double", "actions": [{"slot": 0, "move": "SLASH", "target_side": "enemy", "target_slot": 1},
                        {"slot": 1, "move": "SAND_ATTACK", "target_side": "enemy", "target_slot": 0}]}},
                {"A": {"kind": "double", "actions": [{"slot": 0, "move": "TOXIC", "target_side": "enemy", "target_slot": 0},
                        {"slot": 1, "move": "ROCK_THROW", "target_side": "enemy", "target_slot": 1}]},
                    "B": {"kind": "double", "actions": [{"slot": 0, "move": "EMBER", "target_side": "enemy", "target_slot": 0},
                        {"slot": 1, "kind": "use_item", "item": "SUPER POTION", "index": 1}]}},
                {"A": {"kind": "double", "actions": [{"slot": 0, "move": "WATER_GUN", "target_side": "enemy", "target_slot": 0},
                        {"slot": 1, "move": "SELFDESTRUCT", "target_side": "enemy", "target_slot": -1}]}},
                {"A": {"kind": "double", "actions": [{"slot": 0, "kind": "use_item", "item": "REVIVE", "index": 1},
                        {"slot": 1, "move": "THUNDERBOLT", "target_side": "enemy", "target_slot": 0}]}},
                {}, {}, {}, {}, {}, {}, {}, {}, {}, {}, {}, {}, {}, {}, {}, {}],
            "picks": {"A": [0], "B": [2]}},
    ]
