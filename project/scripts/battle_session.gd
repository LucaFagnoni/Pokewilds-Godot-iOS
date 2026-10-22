extends RefCounted
## One battle's turn flow, without nodes and deterministic for its RNG state:
## the order actions run in, moves, switches, items, residual damage, faints,
## experience, catching, running and how the battle ends. Single-player
## battles (wild, trainer, events, doubles), PvP (the pvp_ functions) and the
## host's replay of a co-op wild battle (replay()) all play here. The rules
## stay in battle_engine.gd and the enemy's choices in battle_ai.gd.
##
## The battle runs as a coroutine that stops at its events. For the view
## (main.gd sets `stepwise`) it stops after every event until resume(), so
## what the view reads is the state the event shows, and the view also does
## the player's side of a battle (experience screens, routing a caught
## Pokemon). Otherwise it stops only where a side must choose (an event with
## "request"), and submit() returns every event up to there.

signal _resumed(answer)

const Battle = preload("res://scripts/battle_engine.gd")
const PokemonData = preload("res://scripts/pokemon_data.gd")
const PokemonState = preload("res://scripts/pokemon_state.gd")
const AI = preload("res://scripts/battle_ai.gd")

const ITEM_RULES := {
    "POTION":{"kind":"heal", "amount":20},
    "SUPER POTION":{"kind":"heal", "amount":50},
    "HYPER POTION":{"kind":"heal", "amount":200},
    "MAX POTION":{"kind":"heal", "amount":99999},
    "FULL RESTORE":{"kind":"full_restore", "amount":99999},
    "RAGECANDYBAR":{"kind":"heal", "amount":20},
    "FULL HEAL":{"kind":"status", "status":"ANY"},
    "ANTIDOTE":{"kind":"status", "status":"POISON"},
    "BURN HEAL":{"kind":"status", "status":"BURN"},
    "ICE HEAL":{"kind":"status", "status":"FREEZE"},
    "AWAKENING":{"kind":"status", "status":"SLEEP"},
    "PARLYZ HEAL":{"kind":"status", "status":"PARALYSIS"},
    "LUM BERRY":{"kind":"status", "status":"ANY"},
    "PECHA BERRY":{"kind":"status", "status":"POISON"},
    "CHERI BERRY":{"kind":"status", "status":"PARALYSIS"},
    "ASPEAR BERRY":{"kind":"status", "status":"FREEZE"},
    "CHESTO BERRY":{"kind":"status", "status":"SLEEP"},
    "RAWST BERRY":{"kind":"status", "status":"BURN"},
    "PERSIM BERRY":{"kind":"confusion"},
    "BERRY JUICE":{"kind":"heal", "amount":20},
    "MOOMOO MILK":{"kind":"heal", "amount":100},
    "REVIVE":{"kind":"revive", "fraction":0.5},
    "MAX REVIVE":{"kind":"revive", "fraction":1.0}
}
const STATUS_TEXT := {"BURN":"was burned!", "FREEZE":"was frozen solid!",
    "PARALYSIS":"was PARALYZED! It might not be able to attack!",
    "SLEEP":"fell asleep!", "POISON":"was poisoned!",
    "CONFUSION":"became confused!", "ATTRACT":"fell in love!"}
## Moves after which Regigigas's quake is not counted (Battle.java).
const QUAKE_IGNORES := ["AURORA_BEAM", "CLAMP", "SUPERSONIC", "WITHDRAW", "STRUGGLE",
    "PSYCHIC", "NIGHT_SHADE", "SLASH", "SHADOW_CLAW", "LICK"]

var rng := RandomNumberGenerator.new()
## The RNG state the battle began with: with `history`, the whole battle.
var start_state := 0
## The battle context (kind, trainer, flags; the view shares it).
var context: Dictionary = {}
var field: Dictionary = {}
## What the battle reads from the world: time_of_day, night, indoors, surfing.
var world: Dictionary = {}
## The player's party (main.caught_pokemon itself) and bag.
var party: Array = []
var inventory: Dictionary = {}
var enemy_party: Array = []
var player: Dictionary = {}
var partner: Dictionary = {}
var enemy: Dictionary = {}
var enemy_partner: Dictionary = {}
var party_index := 0
var partner_index := -1
var enemy_index := 0
var enemy_partner_index := -1
var double := false
var turn_count := 0
var run_attempts := 0
var enemy_action_count := 0
var boss_action_count := 0
var participants: Array[int] = []
var finished := false
var outcome := ""
## A view plays the events (see the class description).
var stepwise := false
## Every action and answer the player gave, in order.
var history: Array = []
var running := false
## The open request (a side must answer before the battle goes on).
var pending: Dictionary = {}
var _out: Array = []

# --- driving ------------------------------------------------------------------

## The player's action: a new turn, or the answer to the open request.
## Returns the events up to the next stop (see the class description).
func submit(action) -> Array:
    _out = []
    history.append(action.duplicate(true) if action is Dictionary else action)
    if running:
        _resumed.emit(action)
    else:
        _turn(action)
    return _out

## Plays a battle again with no view from what its log kept (see
## replay_log()): the RNG state it began with, its prepared context, the
## party and bag it began with, the world facts and the player's inputs in
## order (the actions, and the answers to the battle's requests: switches,
## moves to forget, evolutions). False when an input does not fit the battle
## (a different game, or a made-up report) or the battle does not end.
func replay(rng_state: int, battle_context: Dictionary, player_party: Array, bag: Dictionary,
        facts: Dictionary, inputs: Array) -> bool:
    rng.state = rng_state
    stepwise = false
    if not begin(battle_context, player_party, bag, facts):
        return inputs.is_empty()
    for input in inputs:
        if finished or not valid_input(input):
            return false
        submit(input)
    return finished

## The battle as a replay needs it (main.gd sends it with a co-op wild
## battle's result): the RNG state as text (it is 64 bits), the context as
## begin() got it, the world facts and the player's inputs; with `start`,
## also the party and bag it began with (the host has its own copy).
func replay_log(start: bool = false) -> Dictionary:
    var out := {"rng":str(start_state), "context":begin_context.duplicate(true),
        "facts":begin_facts.duplicate(true), "inputs":history.duplicate(true)}
    if start:
        out["party"] = begin_party.duplicate(true)
        out["bag"] = begin_bag.duplicate(true)
    return out

var begin_context: Dictionary = {}
var begin_facts: Dictionary = {}
var begin_party: Array = []
var begin_bag: Dictionary = {}

## Whether a replay_log() that came over the network has the shape a replay
## needs (each input is still checked as it plays). Bounded in size.
static func valid_report(report) -> bool:
    if not report is Dictionary or not report.get("rng") is String or not String(report.rng).is_valid_int():
        return false
    var context = report.get("context")
    var facts = report.get("facts")
    var inputs = report.get("inputs")
    if not (context is Dictionary and facts is Dictionary and inputs is Array) or inputs.size() > 4096 \
            or JSON.stringify(report).length() > 256 * 1024:
        return false
    var members = context.get("party")
    if not members is Array or members.is_empty() or members.size() > 6:
        return false
    for member in members:
        if not member is Dictionary or not member.get("species") is String or \
                PokemonData.info(String(member.species)).is_empty() or \
                not (member.get("level") is int or member.get("level") is float):
            return false
    for key in ["time_of_day", "terrain", "requested"]:
        if facts.has(key) and not facts[key] is String:
            return false
    if facts.has("wild_record") and not facts.wild_record is Dictionary:
        return false
    for input in inputs:
        if not (input is Dictionary or input is int or input is float or input is bool):
            return false
    return true

## JSON brings numbers back as floats: whole ones become ints again, as the
## game holds them.
static func whole_numbers(value) -> Variant:
    if value is float and value == floorf(value) and absf(value) < 9.0e15:
        return int(value)
    if value is Array:
        return (value as Array).map(whole_numbers)
    if value is Dictionary:
        var out := {}
        for key in value:
            out[key] = whole_numbers(value[key])
        return out
    return value

## Whether `input` fits what the battle waits for (a replay's check: every
## input of a report is checked before it plays).
func valid_input(input) -> bool:
    if not pending.is_empty():
        match String(pending.kind):
            "switch":
                if not (input is int or input is float): return false
                var index := int(input)
                return index >= 0 and index < party.size() and index not in [party_index, partner_index] \
                    and int((party[index] as Dictionary).get("hp", 0)) > 0 and not bool((party[index] as Dictionary).get("is_egg", false))
            "forget":
                return (input is int or input is float) and int(input) >= -1 and int(input) < 4
            "evolve":
                return input is bool
        return false
    if running or not input is Dictionary:
        return false
    var action: Dictionary = input
    match String(action.get("kind", "")):
        "move":
            return not double and _valid_move(player, action.get("move"))
        "switch":
            var index = action.get("index")
            if double or not (index is int or index is float): return false
            return int(index) >= 0 and int(index) < party.size() and int(index) != party_index \
                and int((party[int(index)] as Dictionary).get("hp", 0)) > 0 and not trapped(player)
        "item":
            var index = action.get("index")
            if not (index is int or index is float) or int(index) < 0 or int(index) >= party.size(): return false
            var item := String(action.get("item", ""))
            return ITEM_RULES.has(item) and int(inventory.get(item, 0)) > 0 and item_refusal(item, int(index)).is_empty()
        "ball":
            var ball := String(action.get("ball", ""))
            return int(inventory.get(ball, 0)) > 0 and refusal(action).is_empty()
        "run":
            return refusal(action).is_empty()
        "silph_scope":
            return int(inventory.get("SILPH SCOPE", 0)) > 0 and bool(enemy.get("is_ghost", false))
        "poke_doll":
            return int(inventory.get("POKE DOLL", 0)) > 0 and refusal(action).is_empty()
        "double":
            return double and action.get("actions") is Array and _valid_double_actions(action.actions)
    return false

static func _valid_move(pokemon: Dictionary, move) -> bool:
    if not move is String: return false
    var forced := Battle.forced_move(pokemon)
    if not forced.is_empty(): return move == forced
    if move == "STRUGGLE": return first_usable_move(pokemon) == "STRUGGLE"
    return (pokemon.get("moves", []) as Array).has(move) and Battle.move_is_usable(pokemon, move)

func _valid_double_actions(actions: Array) -> bool:
    if actions.size() > 2: return false
    var slots: Array[int] = []
    for raw in actions:
        if not raw is Dictionary: return false
        var action: Dictionary = raw
        var slot = action.get("slot")
        if action.get("side") != "player" or not (slot is int or slot is float) or int(slot) not in [0, 1] or int(slot) in slots:
            return false
        slots.append(int(slot))
        var actor := double_actor("player", int(slot))
        if actor.is_empty() or int(actor.get("hp", 0)) <= 0: return false
        if String(action.get("kind", "move")) == "switch":
            var index = action.get("switch_index")
            if not (index is int or index is float) or int(index) < 0 or int(index) >= party.size() or \
                    int(index) in [party_index, partner_index] or int((party[int(index)] as Dictionary).get("hp", 0)) <= 0 or trapped(actor):
                return false
        elif not _valid_move(actor, action.get("move")) or not (action.get("target_slot") is int or action.get("target_slot") is float):
            return false
    return true

## Goes on after the event the view has just played.
func resume(answer = null) -> Array:
    _out = []
    if not pending.is_empty():
        history.append(answer.duplicate(true) if answer is Dictionary else answer)
    if running:
        _resumed.emit(answer)
    return _out

## Drops the battle where it stands (it was ended from outside): the turn
## waiting for its next event is let go, not run on.
func abandon() -> void:
    for connection in _resumed.get_connections():
        _resumed.disconnect(connection.callable)
    running = false
    pending = {}

func _emit(event: Dictionary) -> Variant:
    _out.append(event)
    if not stepwise and not event.has("request"):
        return null
    if event.has("request"): pending = event
    var answer = await _resumed
    pending = {}
    return answer

func _say(text: String, wait: float = 0.0) -> void:
    await _emit({"kind":"text", "text":text, "wait":wait})

func _wait(seconds: float) -> void:
    await _emit({"kind":"wait", "seconds":seconds})

func _request(event: Dictionary) -> Variant:
    event["request"] = true
    return await _emit(event)

func _command(slot: int = 0) -> void:
    await _emit({"kind":"command", "slot":slot})

func _end(result: String) -> void:
    finished = true
    outcome = result
    await _emit({"kind":"end", "outcome":result})

func _turn(action: Dictionary) -> void:
    running = true
    match String(action.get("kind", "")):
        "move": await _turn_move(String(action.move))
        "double": await _turn_double(action.actions)
        "switch": await _turn_switch(int(action.index))
        "item": await _turn_item(String(action.item), int(action.index))
        "ball": await _turn_ball(String(action.ball), action)
        "run": await _turn_run()
        "silph_scope": await _turn_silph_scope()
        "poke_doll": await _turn_poke_doll()
    running = false

# --- starting -------------------------------------------------------------------

## A wild battle's levels follow the player's party (fixed for events and trainers).
static func prepare_context(source: Dictionary, player_party: Array) -> Dictionary:
    var prepared := source.duplicate(true)
    if bool(prepared.get("fixed_level",false)) or bool(prepared.get("source_unown", false)) or String(prepared.get("id", "")).begins_with("source_night_"):
        # SpawnGhost/Cacturnt supply authored levels, not scaled wild spawns.
        return prepared
    if String(prepared.get("kind", "wild")) != "wild":
        return prepared
    var raw_party = prepared.get("party", [])
    if typeof(raw_party) != TYPE_ARRAY:
        return prepared
    var scaled_party: Array = []
    var scaled_any := false
    for raw_member in raw_party as Array:
        if typeof(raw_member) != TYPE_DICTIONARY:
            continue
        var member := (raw_member as Dictionary).duplicate(true)
        var source_level := maxi(1, int(member.get("level", 1)))
        var scaled_level := wild_level(player_party, source_level)
        member["level"] = scaled_level
        if scaled_level != source_level:
            # Let the battle engine rebuild a legal move set at the adjusted
            # level rather than importing attacks from the high-level source.
            member.erase("moves")
            member.erase("pp")
            member["met_level"] = scaled_level
            scaled_any = true
        scaled_party.append(member)
    prepared["party"] = scaled_party
    prepared["_wild_level_scaled"] = scaled_any
    return prepared

static func reference_level(player_party: Array) -> int:
    var levels: Array[int] = []
    for raw_pokemon in player_party:
        if typeof(raw_pokemon) != TYPE_DICTIONARY:
            continue
        var pokemon := raw_pokemon as Dictionary
        if bool(pokemon.get("is_egg", false)):
            continue
        levels.append(maxi(1, int(pokemon.get("level", 1))))
    if levels.is_empty():
        return 5
    levels.sort()
    var middle := levels.size() / 2
    if levels.size() % 2 == 1:
        return levels[middle]
    return roundi((levels[middle - 1] + levels[middle]) * 0.5)

static func wild_level(player_party: Array, source_level: int) -> int:
    var reference := reference_level(player_party)
    return clampi(maxi(1, source_level), maxi(2, reference - 3), mini(100, reference + 1))

## Sets up a single-player battle from its (prepared) context: the enemy
## party, the player's first Pokemon able to fight (or the one a thrown ball
## asked for, `facts.requested`), the doubles partners and the entry
## messages (context._entry_messages). `facts` is what the battle reads from
## the world: time_of_day, terrain, night, indoors, surfing, wild_record (the
## overworld Pokemon fought). False when the player has nothing to battle with.
func begin(battle_context: Dictionary, player_party: Array, bag: Dictionary,
        facts: Dictionary) -> bool:
    begin_context = battle_context.duplicate(true)
    begin_facts = facts.duplicate(true)
    begin_party = player_party.duplicate(true)
    begin_bag = bag.duplicate(true)
    context = battle_context
    party = player_party
    inventory = bag
    world = facts
    start_state = rng.state
    participants.clear()
    enemy_party = (context.get("party", []) as Array).duplicate(true)
    enemy_index = 0
    enemy_action_count = 0
    double = String(context.get("battle_format", "single")) == "double" and enemy_party.size() >= 2
    partner = {}
    enemy_partner = {}
    partner_index = -1
    enemy_partner_index = -1
    if bool(context.get("requires_silph_scope", false)):
        var revealed := bool(context.get("ghost_revealed", false))
        context["ghost_revealed"] = revealed
        if not revealed:
            context["can_catch"] = false
    var first_member := enemy_party[0] as Dictionary
    var level := maxi(1, int(first_member.get("level", 1)))
    run_attempts = 0
    turn_count = 0
    field = {
        "weather":"", "weather_turns":0,
        "time_of_day":String(world.get("time_of_day", "day")),
        "terrain":String(context.get("terrain", world.get("terrain", "GRASSY"))),
        "player_spikes":0, "enemy_spikes":0
    }
    enemy = make_enemy(first_member)
    enemy_party[0] = enemy
    enemy = apply_wild_record(enemy, level)
    enemy_party[0] = enemy
    Battle.reset_battle_state(enemy)
    party_index = _first_healthy_party_index()
    var requested := String(world.get("requested", ""))
    if not requested.is_empty():
        for index in range(party.size()):
            if str(party[index].get("party_ecology_id","")) == requested and int(party[index].get("hp",0))>0:
                party_index = index
                break
    if party_index < 0:
        return false
    player = Battle.ensure_pokemon(party[party_index])
    Battle.reset_battle_state(player)
    party[party_index] = player
    participants.append(party_index)
    if double:
        var partner_choices := _healthy_party_indices(true)
        if partner_choices.is_empty():
            double = false
        else:
            partner_index = partner_choices[0]
            participants.append(partner_index)
            partner = Battle.ensure_pokemon(party[partner_index])
            Battle.reset_battle_state(partner)
            party[partner_index] = partner
            enemy_partner_index = 1
            enemy_partner = make_enemy(enemy_party[1] as Dictionary)
            Battle.reset_battle_state(enemy_partner)
            enemy_party[1] = enemy_partner
    var entry_messages: Array[String] = []
    var player_actives: Array = [player]
    var enemy_actives: Array = [enemy]
    if double:
        player_actives.append(partner)
        enemy_actives.append(enemy_partner)
    var enemy_entry := Battle.switch_in_message(enemy, player_actives, field)
    var player_entry := Battle.switch_in_message(player, enemy_actives, field)
    if not enemy_entry.is_empty(): entry_messages.append(enemy_entry)
    if not player_entry.is_empty(): entry_messages.append(player_entry)
    if double:
        var enemy_partner_entry := Battle.switch_in_message(enemy_partner, player_actives, field)
        var player_partner_entry := Battle.switch_in_message(partner, enemy_actives, field)
        if not enemy_partner_entry.is_empty(): entry_messages.append(enemy_partner_entry)
        if not player_partner_entry.is_empty(): entry_messages.append(player_partner_entry)
    context["_entry_messages"] = entry_messages.duplicate()
    return true

func make_enemy(member: Dictionary) -> Dictionary:
    var species := String(member.get("species", "rattata")).to_lower()
    var level := maxi(1, int(member.get("level", 1)))
    var prepared := member.duplicate(true)
    prepared["original_trainer"] = String(prepared.get("original_trainer",
        context.get("trainer_name", "WILD")))
    prepared["met_location"] = String(prepared.get("met_location",
        context.get("id", "WILDERNESS")))
    var made := Battle.make_pokemon(species, level, rng, prepared)
    if bool(context.get("requires_silph_scope", false)):
        made["is_ghost"] = not bool(context.get("ghost_revealed", false))
    return made

## A wild enemy takes the record of the overworld Pokemon fought
## (world.wild_record): its shininess, gender, nature, IVs... and its moves,
## unless the battle scaled its level.
func apply_wild_record(made: Dictionary, level: int) -> Dictionary:
    if String(context.get("kind", "wild")) != "wild":
        return made
    var source_record: Dictionary = world.get("wild_record", {})
    if not source_record.is_empty():
        context["overworld_record"] = source_record.duplicate(true)
    var source_properties = [
            "shiny", "is_shiny", "gender", "generation", "personality",
            "nature", "ability", "ability_slot", "ivs", "evs", "held_item",
            "friendship", "happiness", "nickname",
            "original_trainer", "trainer_id", "met_location",
            "pokeball", "ribbons", "markings", "pokerus"
        ]
    var wild_level_scaled = bool(context.get("_wild_level_scaled", false))
    if not wild_level_scaled:
        source_properties.append_array(["moves", "pp", "met_level"])
    for property in source_properties:
        if source_record.has(property):
            made[property] = source_record[property]
    if source_record.has("is_shiny") and not source_record.has("shiny"):
        made["shiny"] = bool(source_record["is_shiny"])
    if wild_level_scaled:
        made["level"] = level
        made["met_level"] = level
        made.erase("moves")
        made.erase("pp")
    return Battle.ensure_pokemon(made)

func _first_healthy_party_index() -> int:
    for index in range(party.size()):
        if typeof(party[index]) == TYPE_DICTIONARY and bool((party[index] as Dictionary).get("is_egg", false)):
            continue
        var candidate := Battle.ensure_pokemon(party[index])
        party[index] = candidate
        if int(candidate.hp) > 0:
            return index
    return -1

func _healthy_party_indices(exclude_active: bool) -> Array[int]:
    var result: Array[int] = []
    for index in range(party.size()):
        if exclude_active and index == party_index:
            continue
        var pokemon := Battle.ensure_pokemon(party[index])
        party[index] = pokemon
        if int(pokemon.hp) > 0 and not bool(pokemon.get("is_egg", false)):
            result.append(index)
    return result

## Builds the enemy records that are not built yet (they draw from the RNG).
func prepare_enemy_records() -> void:
    for index in range(enemy_party.size()):
        if typeof(enemy_party[index]) != TYPE_DICTIONARY:
            continue
        var record := enemy_party[index] as Dictionary
        if not record.has("stats") or not record.has("ivs"):
            enemy_party[index] = make_enemy(record)
    if enemy_index >= 0 and enemy_index < enemy_party.size():
        enemy_party[enemy_index] = enemy

func _next_healthy_enemy_index() -> int:
    for index in range(enemy_party.size()):
        if index == enemy_index or typeof(enemy_party[index]) != TYPE_DICTIONARY:
            continue
        var record := enemy_party[index] as Dictionary
        if not record.has("stats"):
            record = make_enemy(record)
            enemy_party[index] = record
        if int(record.get("hp", 0)) > 0:
            return index
    return -1

# --- what the player may do -------------------------------------------------------

## Why the player cannot do `action` now (the line the battle shows instead),
## or "" when it can. Refusals take no turn.
func refusal(action: Dictionary) -> String:
    match String(action.get("kind", "")):
        "run":
            if not bool(context.get("can_run", true)):
                return "There is no running from this battle!"
            if trapped(player):
                return "%s cannot escape!" % PokemonState.display_name(player)
        "ball":
            if not bool(context.get("can_catch", true)):
                return "You cannot throw a POKE BALL here."
        "poke_doll":
            if not bool(context.get("can_run", true)):
                return "The POKE DOLL cannot end this battle."
        "item":
            return item_refusal(String(action.item), int(action.index))
    return ""

static func trapped(pokemon: Dictionary) -> bool:
    return int(pokemon.volatile.get("trap_turns", 0)) > 0 or bool(pokemon.volatile.get("mean_look", false))

## Why `item` would not help party member `index`, or "" when it would.
func item_refusal(item_name: String, index: int) -> String:
    var pokemon := Battle.ensure_pokemon(party[index])
    party[index] = pokemon
    return pokemon_item_refusal(pokemon, item_name)

## Why `item_name` would not help `pokemon`: the line the battle shows, ""
## when it would help, or "-" for an item with no use in battle (refused
## without a word).
static func pokemon_item_refusal(pokemon: Dictionary, item_name: String) -> String:
    if bool(pokemon.get("is_egg", false)):
        return "That item cannot be used on an EGG."
    var rule: Dictionary = ITEM_RULES.get(item_name, {})
    match String(rule.get("kind", "")):
        "heal":
            if int(pokemon.hp) <= 0 or int(pokemon.hp) >= int(pokemon.max_hp):
                return "That Pokemon does not need HP restored."
        "full_restore":
            if int(pokemon.hp) <= 0 or (int(pokemon.hp) >= int(pokemon.max_hp) and String(pokemon.status).is_empty()):
                return "That Pokemon does not need restoring."
        "status":
            var cures := String(rule.get("status", "ANY"))
            if int(pokemon.hp) <= 0 or String(pokemon.status).is_empty() or (cures != "ANY" and String(pokemon.status) != cures):
                return "That item will not help this Pokemon."
        "confusion":
            if not (pokemon.volatile as Dictionary).has("confuse_turns"):
                return "That Pokemon is not confused."
        "revive":
            if int(pokemon.hp) > 0:
                return "That Pokemon has not fainted."
        _:
            return "-"
    return ""

static func first_usable_move(pokemon: Dictionary) -> String:
    var forced := Battle.forced_move(pokemon)
    if not forced.is_empty():
        return forced
    for move_name in pokemon.get("moves", ["TACKLE"]):
        if Battle.move_is_usable(pokemon, String(move_name)):
            return String(move_name)
    return "STRUGGLE"

## The move a menu choice uses: a locked-in move, or the first usable one
## when the chosen one cannot be used.
static func chosen_move(pokemon: Dictionary, index: int) -> String:
    var forced := Battle.forced_move(pokemon)
    if not forced.is_empty():
        return forced
    var moves: Array = pokemon.get("moves", ["TACKLE"])
    if moves.is_empty():
        return "STRUGGLE"
    var selected := String(moves[clampi(index, 0, moves.size() - 1)])
    if not Battle.move_is_usable(pokemon, selected):
        return first_usable_move(pokemon)
    return selected

# --- a single battle's turns ------------------------------------------------------

func _turn_move(player_move: String) -> void:
    var enemy_action := AI.choose(self)
    if String(enemy_action.get("kind", "move")) != "move":
        await _enemy_tactical(enemy_action)
        if finished:
            return
        await _act(true, player_move)
        if finished:
            return
        if await _resolve_faints():
            return
        await _end_turn()
        if await _resolve_faints():
            return
        await _command()
        return
    var enemy_move := String(enemy_action.get("move", first_usable_move(enemy)))
    var player_first := Battle.player_moves_first(
        player, player_move, enemy, enemy_move, rng, field)
    if player_first:
        await _act(true, player_move)
        if finished:
            return
        if await _resolve_faints():
            return
        await _act(false, enemy_move)
        if finished:
            return
        if await _resolve_faints():
            return
    else:
        await _act(false, enemy_move)
        if finished:
            return
        if await _resolve_faints():
            return
        await _act(true, player_move)
        if finished:
            return
        if await _resolve_faints():
            return
    await _end_turn()
    if await _resolve_faints():
        return
    await _command()

## The enemy's action after the player switched, used an item, failed to run
## or revealed a ghost.
func _enemy_after_choice() -> void:
    await _emit({"kind":"message_screen"})
    var action := AI.choose(self)
    if String(action.get("kind", "move")) == "move":
        await _act(false, String(action.get("move", first_usable_move(enemy))))
    else:
        await _enemy_tactical(action)
    if finished:
        return
    if await _resolve_faints():
        return
    await _end_turn()
    if await _resolve_faints():
        return
    await _command()

static func status_snapshot(pokemon: Dictionary) -> Dictionary:
    var volatile: Dictionary = pokemon.get("volatile", {})
    return {"status":String(pokemon.get("status", "")),
        "confused":int(volatile.get("confuse_turns", 0)) > 0,
        "attracted":bool(volatile.get("attract", false))}

## The statuses a move gave its target, in the order the battle reports them.
static func new_statuses(before: Dictionary, after: Dictionary) -> Array[String]:
    var applied: Array[String] = []
    if String(before.status).is_empty() and not String(after.status).is_empty():
        applied.append(String(after.status))
    if not bool(before.confused) and bool(after.confused): applied.append("CONFUSION")
    if not bool(before.attracted) and bool(after.attracted): applied.append("ATTRACT")
    return applied

## A move's message split where its first sentence ends.
static func message_parts(message: String) -> Array[String]:
    var split_at := message.find("!")
    if split_at < 0:
        return [message.strip_edges(), ""]
    return [
        message.left(split_at + 1).strip_edges(),
        message.substr(split_at + 1).strip_edges()
    ]

func _spend_pp(attacker: Dictionary, move_name: String) -> void:
    var repeated_without_pp = not String(attacker.volatile.get("charge_move", "")).is_empty() or \
        int(attacker.volatile.get("bide_turns", 0)) > 0 or \
        int(attacker.volatile.get("locked_turns", 0)) > 0
    if move_name != "STRUGGLE" and not repeated_without_pp:
        var pp: Dictionary = attacker.get("pp", {})
        pp[move_name] = maxi(0, int(pp.get(move_name, 1)) - 1)
        attacker.pp = pp

func _act(player_attacks: bool, move_name: String) -> Dictionary:
    if not player_attacks:
        enemy_action_count += 1
        var special_every = int(context.get("special_every", 0))
        if String(context.get("source_boss", "")).is_empty() and not bool(context.get("source_mewtwo", false)) and special_every > 0 and enemy_action_count % special_every == 0:
            var special_move = String(context.get("special_move", "")).to_upper()
            if not special_move.is_empty() and not PokemonData.move_info(special_move).is_empty():
                move_name = special_move
                field["move_power_override"] = int(context.get("special_power", 0))
                var special_pp = enemy.get("pp", {}) as Dictionary
                if not special_pp.has(special_move):
                    special_pp[special_move] = int(PokemonData.move_info(special_move).get("pp", 35))
                    enemy["pp"] = special_pp
                var special_message = String(context.get("special_message", ""))
                if not special_message.is_empty():
                    await _say(special_message, 0.1)
    var attacker := player if player_attacks else enemy
    var defender := enemy if player_attacks else player
    var attacker_hp_before := int(attacker.get("hp", 0))
    var defender_hp_before := int(defender.get("hp", 0))
    var defender_status_before := status_snapshot(defender)
    var raid_hp_before := int(enemy.hp)
    _spend_pp(attacker, move_name)
    field["attacker_is_player"] = player_attacks
    var result := Battle.use_move(attacker, defender, move_name, rng, field)
    field.erase("move_power_override")
    var weather_changed := not String(result.get("weather", "")).is_empty()
    if weather_changed:
        field["weather"] = String(result.weather)
        field["weather_turns"] = 5
    if bool(result.get("heal_party", false)):
        for index in range(party.size()):
            if typeof(party[index]) == TYPE_DICTIONARY:
                party[index]["status"] = ""
                party[index]["status_counter"] = 0
                party[index]["toxic_counter"] = 0
        player["status"] = ""
    if int(result.get("pay_day", 0)) > 0:
        inventory["COINS"] = int(inventory.get("COINS", 0)) + int(result.pay_day)
    party[party_index] = player
    await _emit({"kind":"move", "player_side":player_attacks, "move":move_name, "result":result,
        "attacker":attacker, "defender":defender, "attacker_hp_before":attacker_hp_before,
        "defender_hp_before":defender_hp_before, "status_before":defender_status_before,
        "status_after":status_snapshot(defender), "defender_hp":int(defender.get("hp", 0)),
        "defender_name":Battle.display_name(defender), "raid_hp_before":raid_hp_before,
        "weather":weather_changed})
    var switch_effect := String(result.get("force_switch", ""))
    if switch_effect == "BATON_PASS" and player_attacks:
        await _baton_pass()
    elif switch_effect == "FORCE_SWITCH":
        if player_attacks:
            await _say("%s was blown away!" % Battle.display_name(enemy), 0.1)
            await _end("victory" if String(context.get("kind", "")) == "trainer" else "defeated")
        else:
            await _forced_switch()
    elif switch_effect == "TELEPORT":
        await _say("%s teleported away!" % Battle.display_name(attacker), 0.1)
        await _end("ran")
    if not player_attacks and bool(context.get("source_mewtwo", false)) and not finished and \
            enemy_action_count % 3 == 0 and int(enemy.hp) > 0 and int(player.hp) > 0:
        await _emit({"kind":"boss_special", "boss":"mewtwo"})
        var hp_before := int(player.hp)
        var damage := int(30.0 * Battle.effectiveness("PSYCHIC", player.types))
        player.hp = maxi(0, hp_before - damage)
        party[party_index] = player
        await _emit({"kind":"special_damage", "boss":"mewtwo", "pokemon":player, "hp_before":hp_before})
    if not player_attacks and String(context.get("source_boss", "")) == "regigigas" and not finished and move_name not in QUAKE_IGNORES:
        boss_action_count += 1
        if boss_action_count >= 3 and int(enemy.hp) > 0 and int(player.hp) > 0:
            boss_action_count = 0
            # Battle.java picks the impact cue from the move before, but the
            # special damage itself is Ground.
            await _emit({"kind":"boss_special", "boss":"regigigas",
                "move_type":String(PokemonData.move_info(move_name).get("type","NORMAL"))})
            var hp_before := int(player.hp)
            if not finished and hp_before > 0:
                var damage := int(30.0 * Battle.effectiveness("GROUND", player.types))
                player.hp = maxi(0, hp_before - damage)
                party[party_index] = player
            await _emit({"kind":"special_damage", "boss":"regigigas", "pokemon":player, "hp_before":hp_before})
    if not finished and int(attacker.get("hp", 0)) > 0 and int(defender.get("hp", 0)) > 0:
        await _after_action_residual(attacker, player_attacks)
    return result

func _after_action_residual(pokemon: Dictionary, player_side: bool) -> void:
    var hp_before := int(pokemon.get("hp", 0))
    var was_poisoned := String(pokemon.get("status", "")) == "POISON"
    var message := Battle.after_action_residual(pokemon)
    await _emit({"kind":"residual", "pokemon":pokemon, "player_side":player_side,
        "hp_before":hp_before, "poisoned":was_poisoned, "message":message})

func _baton_pass() -> void:
    if _healthy_party_indices(true).is_empty():
        await _say("But there was nobody to receive the pass!")
        return
    var next_index = await _request({"kind":"switch", "reason":"BATON_PASS"})
    await _switch_player(int(next_index), true, true)

func _forced_switch() -> void:
    if _healthy_party_indices(true).is_empty():
        await _say("But it failed!")
        return
    var next_index = await _request({"kind":"switch", "reason":"FORCED"})
    await _switch_player(int(next_index), false, true)

func _switch_player(next_index: int, preserve_state: bool, show_message: bool) -> void:
    if not participants.has(next_index): participants.append(next_index)
    var passed_stages := (player.get("stages", {}) as Dictionary).duplicate(true)
    var passed_volatile := {}
    if preserve_state:
        for key in ["substitute_hp", "confuse_turns", "focus_energy"]:
            if player.volatile.has(key):
                passed_volatile[key] = player.volatile[key]
    var out_message := Battle.switch_out_message(player)
    Battle.reset_battle_state(player)
    party[party_index] = player
    party_index = next_index
    player = Battle.ensure_pokemon(party[next_index])
    Battle.reset_battle_state(player)
    if preserve_state:
        player.stages = passed_stages
        for key in passed_volatile.keys():
            player.volatile[key] = passed_volatile[key]
    party[next_index] = player
    var spike_layers := int(field.get("player_spikes", 0))
    if spike_layers > 0 and not (player.types as Array).has("FLYING") and \
            String(player.get("ability", "")) != "LEVITATE":
        var spike_damage := maxi(1, int(int(player.max_hp) * spike_layers / 8.0))
        player.hp = maxi(0, int(player.hp) - spike_damage)
    var message := ""
    if show_message:
        message = "Go, %s!" % PokemonState.display_name(player)
        if not out_message.is_empty(): message = out_message + " " + message
        var entry := Battle.switch_in_message(player, [enemy], field)
        if not entry.is_empty(): message += " " + entry
    await _emit({"kind":"player_switch", "pokemon":player, "slot":0, "text":message,
        "wait":0.1, "hud":true, "reset_move":true})

func _enemy_tactical(action: Dictionary) -> void:
    match String(action.get("kind", "move")):
        "item":
            var amount := mini(50, int(enemy.max_hp) - int(enemy.hp))
            enemy.hp = int(enemy.hp) + amount
            context["_trainer_heals_used"] = int(context.get("_trainer_heals_used", 0)) + 1
            await _say("%s used a SUPER POTION. %s restored %d HP!" % [
                String(context.get("trainer_name", "The Trainer")),
                Battle.display_name(enemy), amount], 0.1)
        "switch":
            await _switch_enemy(int(action.get("index", -1)), true)

func _switch_enemy(next_index: int, show_message: bool) -> void:
    if next_index < 0 or next_index >= enemy_party.size() or next_index == enemy_index:
        return
    prepare_enemy_records()
    var out_message := Battle.switch_out_message(enemy)
    Battle.reset_battle_state(enemy)
    enemy_party[enemy_index] = enemy
    enemy_index = next_index
    enemy = Battle.ensure_pokemon(enemy_party[next_index])
    Battle.reset_battle_state(enemy)
    enemy_party[next_index] = enemy
    var spike_layers := int(field.get("enemy_spikes", 0))
    if spike_layers > 0 and not (enemy.types as Array).has("FLYING") and \
            String(enemy.get("ability", "")) != "LEVITATE":
        enemy.hp = maxi(0, int(enemy.hp) - maxi(1, int(int(enemy.max_hp) * spike_layers / 8.0)))
    var message := ""
    if show_message:
        message = "%s withdrew its Pokemon and sent out %s!" % [
            String(context.get("trainer_name", "The opponent")), Battle.display_name(enemy)]
        if not out_message.is_empty(): message = out_message + " " + message
        var entry := Battle.switch_in_message(enemy, [player], field)
        if not entry.is_empty(): message += " " + entry
    await _emit({"kind":"enemy_switch", "pokemon":enemy, "slot":0, "text":message, "wait":0.1, "hud":true})

func _end_turn() -> void:
    turn_count += 1
    field["turn_count"] = turn_count
    var messages: Array[String] = []
    var player_hp_before := int(player.get("hp", 0))
    var enemy_hp_before := int(enemy.get("hp", 0))
    var player_poisoned := String(player.get("status",""))=="POISON" and not bool(player.volatile.get("action_residual_applied", false))
    var enemy_poisoned := String(enemy.get("status",""))=="POISON" and not bool(enemy.volatile.get("action_residual_applied", false))
    var player_message := Battle.end_turn(player, field, enemy, rng)
    var enemy_message := Battle.end_turn(enemy, field, player, rng)
    if not player_message.is_empty():
        messages.append(player_message)
    if not enemy_message.is_empty():
        messages.append(enemy_message)
    var weather_ended := false
    if int(field.get("weather_turns", 0)) > 0:
        field.weather_turns = int(field.weather_turns) - 1
        if int(field.weather_turns) <= 0:
            var old_weather := String(field.get("weather", ""))
            field.weather = ""
            messages.append("The %s subsided." % old_weather.replace("_", " ").to_lower())
            weather_ended = true
    party[party_index] = player
    await _emit({"kind":"end_turn", "text":" ".join(messages), "weather_ended":weather_ended,
        "player_hp_before":player_hp_before, "enemy_hp_before":enemy_hp_before,
        "player_poisoned":player_poisoned, "enemy_poisoned":enemy_poisoned})

func _resolve_faints() -> bool:
    if int(enemy.hp) <= 0:
        await _enemy_fainted()
        return true
    if int(player.hp) <= 0:
        return await _player_fainted()
    return false

func _enemy_fainted() -> void:
    var no_more := _next_healthy_enemy_index() < 0
    var species := String(enemy.get("species", ""))
    if no_more and species != "mewtwo" and "unown" not in species:
        await _emit({"kind":"victory_music"})
    Battle.reset_battle_state(enemy)
    Battle.reset_battle_state(player)
    var effort := PokemonState.grant_evs(player, enemy)
    party[party_index] = player
    var recipients := Battle.experience_recipients(party, participants, party_index)
    var message := "%s fainted!" % Battle.display_name(enemy)
    if int(effort.get("amount", 0)) > 0:
        message += " +%d %s EV." % [int(effort.amount),
            String(effort.stat).replace("_", " ").to_upper()]
    await _emit({"kind":"text", "text":message, "wait":0.175, "hud":true})
    await _award_experience(enemy, recipients)
    enemy_party[enemy_index] = enemy
    var next_enemy_index := _next_healthy_enemy_index()
    if next_enemy_index >= 0:
        enemy_index = next_enemy_index
        var next_member := enemy_party[next_enemy_index] as Dictionary
        enemy = Battle.ensure_pokemon(next_member) if next_member.has("stats") else make_enemy(next_member)
        enemy_party[next_enemy_index] = enemy
        Battle.reset_battle_state(enemy)
        enemy_action_count = 0
        var send_message := "%s sent out %s!" % [
            String(context.get("trainer_name", "The opponent")), Battle.display_name(enemy)]
        var entry_message := Battle.switch_in_message(enemy, [player], field)
        if not entry_message.is_empty(): send_message += " " + entry_message
        await _emit({"kind":"enemy_switch", "pokemon":enemy, "slot":0, "text":send_message, "wait":0.125, "hud":true})
        if int(player.get("hp", 0)) <= 0:
            await _player_fainted()
            return
        await _command()
        return
    await _end("victory" if String(context.get("kind", "wild")) == "trainer" else "defeated")

func _player_fainted() -> bool:
    party[party_index] = player
    await _say("%s fainted!" % PokemonState.display_name(player), 0.15)
    if _healthy_party_indices(true).is_empty():
        await _say("You are out of usable Pokemon.", 0.175)
        await _end("whiteout")
        return true
    var next_index = await _request({"kind":"switch", "reason":"FORCED"})
    await _switch_player(int(next_index), false, true)
    if int(player.hp) <= 0:
        return await _player_fainted()
    await _wait(0.5)
    await _command()
    return true

func _turn_switch(index: int) -> void:
    await _switch_player(index, false, true)
    if await _resolve_faints():
        return
    await _enemy_after_choice()

func _turn_item(item_name: String, index: int) -> void:
    var pokemon := Battle.ensure_pokemon(party[index])
    var rule: Dictionary = ITEM_RULES[item_name]
    var detail := ""
    match String(rule.kind):
        "heal":
            var healed := mini(int(rule.amount), int(pokemon.max_hp) - int(pokemon.hp))
            pokemon.hp = int(pokemon.hp) + healed
            detail = "Restored %d HP!" % healed
        "full_restore":
            var healed := int(pokemon.max_hp) - int(pokemon.hp)
            pokemon.hp = pokemon.max_hp
            pokemon.status = ""
            pokemon.status_counter = 0
            pokemon.toxic_counter = 0
            detail = "Restored %d HP and cured status!" % healed
        "status":
            pokemon.status = ""
            pokemon.status_counter = 0
            pokemon.toxic_counter = 0
            detail = "Its status was cured!"
        "confusion":
            pokemon.volatile.erase("confuse_turns")
            detail = "Its confusion was cured!"
        "revive":
            pokemon.hp = maxi(1, int(int(pokemon.max_hp) * float(rule.fraction)))
            detail = "It returned with %d HP!" % int(pokemon.hp)
    inventory[item_name] = maxi(0, int(inventory.get(item_name, 0)) - 1)
    party[index] = pokemon
    if index == party_index:
        player = pokemon
    elif index == partner_index:
        partner = pokemon
    await _emit({"kind":"text", "text":"Used %s on %s. %s" % [item_name,
        PokemonState.display_name(pokemon), detail], "wait":0.1, "hud":true})
    if double:
        return
    await _enemy_after_choice()

func _turn_run() -> void:
    run_attempts += 1
    var player_speed := Battle.effective_stat(player, "speed")
    var enemy_speed := Battle.effective_stat(enemy, "speed")
    var escaped := player_speed >= enemy_speed
    if not escaped:
        var threshold := int(float(player_speed) * 128.0 / maxf(1.0, float(enemy_speed)))
        threshold += 30 * run_attempts
        escaped = rng.randi_range(0, 255) < threshold
    if escaped:
        await _say("Got away safely.", 0.1)
        await _end("ran")
        return
    await _say("Couldn't get away!", 0.1)
    await _enemy_after_choice()

## A ball throw. The action may carry what the world was like at the throw
## (night, indoors, surfing); otherwise the battle's world facts count.
func _turn_ball(ball: String, action: Dictionary) -> void:
    inventory[ball] = int(inventory.get(ball, 0)) - 1
    await _say("Threw %s!" % ball)
    var capture_outcome := Battle.capture_result(enemy, player, ball, {
        "turn":turn_count + 1, "night":bool(action.get("night", world.get("night", false))),
        "indoors":bool(action.get("indoors", world.get("indoors", false))),
        "surfing":bool(action.get("surfing", world.get("surfing", false))),
        "fishing":bool(context.get("fishing", false))}, rng)
    var captured_successfully := capture_outcome == -1
    await _emit({"kind":"throw", "ball":ball, "captured":captured_successfully,
        "shakes":3 if captured_successfully else capture_outcome})
    if not captured_successfully:
        await _say("%s broke free!" % Battle.display_name(enemy), 0.125)
        var retaliation := AI.choose(self)
        await _act(false, String(retaliation.get("move", first_usable_move(enemy))))
        if finished:
            return
        if await _resolve_faints():
            return
        await _end_turn()
        if await _resolve_faints():
            return
        await _command()
        return
    # Snapshot before routing the caught Pokemon: source excludes the new catch.
    var capture_recipients := Battle.experience_recipients(party, participants, party_index, true)
    Battle.reset_battle_state(enemy)
    var captured := enemy.duplicate(true)
    captured["pokeball"] = ball
    if ball == "HEAL BALL":
        captured.hp = captured.max_hp
        captured.status = ""
        captured.status_counter = 0
        captured.toxic_counter = 0
        Battle.refill_pp(captured)
    elif ball == "FRIEND BALL":
        captured.friendship = 200
    if stepwise:
        await _emit({"kind":"caught", "pokemon":captured, "name":Battle.display_name(enemy)})
    else:
        # Without a view the catch joins the party, or else goes to storage.
        await _say("Caught %s!" % Battle.display_name(enemy))
        if party.size() < 6:
            party.append(captured)
        else:
            await _say("%s has been sent to storage." % PokemonState.display_name(captured).to_upper())
    await _award_experience(enemy, capture_recipients)
    await _wait(0.35)
    await _end("captured")

func _turn_silph_scope() -> void:
    await _say("Used SILPH SCOPE!")
    # Battle.java: the 96-tick reveal runs alongside a 144-tick fade.
    await _emit({"kind":"silph_scope_fade"})
    enemy["is_ghost"] = false
    context["ghost_revealed"] = true
    context["can_catch"] = true
    await _emit({"kind":"silph_scope_reveal"})
    await _say("Enemy %s was revealed!" % Battle.display_name(enemy))
    await _enemy_after_choice()

func _turn_poke_doll() -> void:
    inventory["POKE DOLL"] = int(inventory.get("POKE DOLL", 0)) - 1
    await _say("Used POKE DOLL! Got away safely.", 0.1)
    await _end("ran")

# --- experience, levels, moves and evolution ------------------------------------------

func _award_experience(defeated: Dictionary, recipients: Array[int]) -> void:
    var reward := Battle.experience_reward(defeated, recipients.size())
    for index in recipients:
        var pokemon: Dictionary = party[index]
        await _say("%s gained %d EXP. Points!" % [
            PokemonState.display_name(pokemon).to_upper(), reward])
        await _gain_experience(pokemon, reward, index, true)
    # Source queues every recipient's CheckEvo after all EXP animations.
    for index in recipients:
        await _evolution_check(party[index], index)

## Experience, levels and new moves (the view shows them itself).
func _gain_experience(pokemon: Dictionary, amount: int, index: int, defer_evolution: bool) -> void:
    if stepwise:
        await _emit({"kind":"experience", "pokemon":pokemon, "amount":amount,
            "index":index, "defer_evolution":defer_evolution})
        return
    var current_exp := int(pokemon.get("exp", Battle.exp_for_level(
        String(pokemon.get("species", "machop")), int(pokemon.get("level", 1)))))
    var target_exp := current_exp + maxi(0, amount)
    var gained_level := false
    while int(pokemon.get("level", 1)) < 100:
        var next_level_exp := Battle.exp_for_level(
            String(pokemon.get("species", "machop")), int(pokemon.get("level", 1)) + 1)
        if target_exp < next_level_exp:
            break
        pokemon["exp"] = next_level_exp
        var level_result := Battle.gain_level(pokemon)
        gained_level = true
        current_exp = next_level_exp
        if index >= 0 and index < party.size():
            party[index] = pokemon
        await _say("%s grew to level %d!" % [
            PokemonState.display_name(pokemon).to_upper(), int(pokemon.level)])
        await _learn_moves(pokemon, level_result.get("moves", []))
    pokemon["exp"] = target_exp
    if index >= 0 and index < party.size():
        party[index] = pokemon
    if gained_level and not defer_evolution:
        await _evolution_check(pokemon, index)

func _learn_moves(pokemon: Dictionary, moves_to_learn: Array) -> void:
    var display_name := PokemonState.display_name(pokemon).to_upper()
    for raw_move in moves_to_learn:
        var move_name := String(raw_move).to_upper().replace(" ", "_")
        if (pokemon.get("moves", []) as Array).has(move_name):
            continue
        if (pokemon.get("moves", []) as Array).size() < 4:
            if Battle.learn_move(pokemon, move_name):
                await _say("%s learned %s!" % [display_name, move_name.replace("_", " ")])
            continue
        await _say("%s is trying to learn %s." % [display_name, move_name.replace("_", " ")])
        await _say("Which move should be forgotten?")
        var replace_index := int(await _request({"kind":"forget", "pokemon":pokemon, "move":move_name}))
        if replace_index < 0 or replace_index >= (pokemon.get("moves", []) as Array).size():
            await _say("%s did not learn %s." % [display_name, move_name.replace("_", " ")])
            continue
        var old_move := String((pokemon.get("moves", []) as Array)[replace_index])
        await _say("And one... two... three... POOF!")
        await _say("%s forgot %s and..." % [display_name, old_move.replace("_", " ")])
        if Battle.learn_move(pokemon, move_name, replace_index):
            await _say("%s learned %s!" % [display_name, move_name.replace("_", " ")])

func _evolution_check(pokemon: Dictionary, index: int) -> void:
    if stepwise:
        await _emit({"kind":"evolution_check", "pokemon":pokemon, "index":index})
        return
    var target := Battle.evolution_target(pokemon, party, String(world.get("time_of_day", "day")))
    if target.is_empty():
        return
    target = Battle.resolved_evolution_species(pokemon, target)
    var old_display_name := PokemonState.display_name(pokemon).to_upper()
    await _say("What? %s is evolving!" % old_display_name)
    if not bool(await _request({"kind":"evolve", "pokemon":pokemon, "species":target})):
        await _say("Huh? %s stopped evolving!" % old_display_name)
        return
    if not Battle.apply_evolution(pokemon, target):
        return
    if index >= 0 and index < party.size():
        party[index] = pokemon
    await _say("Congratulations! Your %s evolved into %s!" % [
        old_display_name, target.to_upper().replace("_", " ")])
    await _learn_moves(pokemon, Battle.moves_learned_at_level(target, int(pokemon.get("level", 1))))

# --- double battles ---------------------------------------------------------------------

func double_actor(side: String, slot: int) -> Dictionary:
    if side == "player":
        return player if slot == 0 else partner
    return enemy if slot == 0 else enemy_partner

func living(side: String) -> Array[Dictionary]:
    var result: Array[Dictionary] = []
    for slot in range(2):
        var pokemon := double_actor(side, slot)
        if not pokemon.is_empty() and int(pokemon.get("hp", 0)) > 0:
            result.append({"slot":slot, "pokemon":pokemon})
    return result

## The double battle's records as the battle sees them, back in both parties.
func sync_double_records() -> void:
    if party_index >= 0 and party_index < party.size():
        party[party_index] = player
    if partner_index >= 0 and partner_index < party.size():
        party[partner_index] = partner
    if enemy_index >= 0 and enemy_index < enemy_party.size():
        enemy_party[enemy_index] = enemy
    if enemy_partner_index >= 0 and enemy_partner_index < enemy_party.size():
        enemy_party[enemy_partner_index] = enemy_partner

## A double turn: `player_actions` are the player's choices for both slots
## ({"side","slot","move","target_slot","target_side","spread"} or a switch).
func _turn_double(player_actions: Array) -> void:
    var actions: Array[Dictionary] = []
    for action in player_actions:
        actions.append((action as Dictionary).duplicate(true))
    AI.add_double_actions(self, actions)
    for action in actions:
        var actor := double_actor(String(action.side), int(action.slot))
        action["priority"] = 6 if String(action.get("kind", "move")) in [
            "switch", "enemy_switch", "enemy_item"] else \
            Battle.pokemon_move_priority(actor, String(action.get("move", "")))
        action["speed"] = Battle.effective_stat(actor, "speed", field)
        action["tie"] = rng.randf()
    actions.sort_custom(func(first: Dictionary, second: Dictionary) -> bool:
        if int(first.priority) != int(second.priority):
            return int(first.priority) > int(second.priority)
        if int(first.speed) != int(second.speed):
            return int(first.speed) > int(second.speed)
        return float(first.tie) < float(second.tie)
    )
    for action in actions:
        if finished:
            return
        var attacker := double_actor(String(action.side), int(action.slot))
        if attacker.is_empty() or int(attacker.get("hp", 0)) <= 0:
            continue
        match String(action.get("kind", "move")):
            "switch":
                await _double_player_switch(int(action.slot), int(action.switch_index))
            "enemy_switch":
                await _double_enemy_switch(int(action.slot), int(action.switch_index))
            "enemy_item":
                await _double_enemy_item(int(action.slot))
            _:
                await _double_move(action)
    if finished:
        return
    await _double_end_turn()
    if await _resolve_double_faints():
        return
    await _command(0 if int(player.get("hp", 0)) > 0 else 1)

func _double_move(action: Dictionary) -> void:
    var side = String(action.side)
    var attacker = double_actor(side, int(action.slot))
    var move_name = String(action.move)
    var repeated_without_pp = not String(attacker.volatile.get("charge_move", "")).is_empty() or \
        int(attacker.volatile.get("bide_turns", 0)) > 0 or \
        int(attacker.volatile.get("locked_turns", 0)) > 0
    if move_name != "STRUGGLE" and not repeated_without_pp:
        attacker.pp[move_name] = maxi(0, int(attacker.pp.get(move_name, 1)) - 1)
    var opposing_side = "enemy" if side == "player" else "player"
    var targets: Array[Dictionary] = []
    if bool(action.get("spread", false)):
        for slot in range(2):
            var spread_target = double_actor(opposing_side, slot)
            if not spread_target.is_empty() and int(spread_target.get("hp", 0)) > 0:
                targets.append({"side":opposing_side, "slot":slot})
        if Battle.move_hits_all_adjacent(move_name):
            var ally_slot = 1 - int(action.slot)
            var ally_target = double_actor(side, ally_slot)
            if not ally_target.is_empty() and int(ally_target.get("hp", 0)) > 0:
                targets.append({"side":side, "slot":ally_slot})
    else:
        var requested_slot = int(action.get("target_slot", 0))
        var requested_side = String(action.get("target_side", opposing_side))
        var requested = double_actor(requested_side, requested_slot)
        if not requested.is_empty() and int(requested.get("hp", 0)) > 0:
            targets.append({"side":requested_side, "slot":requested_slot})
        else:
            var alive = living(opposing_side)
            if not alive.is_empty(): targets.append({"side":opposing_side,
                "slot":int(alive[0].slot)})
    if targets.is_empty():
        return
    var first_result: Dictionary = {}
    var self_fainting_spread = "SELFDESTRUCT" in String(
        PokemonData.move_info(move_name).get("effect", ""))
    for target_index in range(targets.size()):
        if int(attacker.get("hp", 0)) <= 0 and not self_fainting_spread:
            break
        var target_spec: Dictionary = targets[target_index]
        var defender = double_actor(String(target_spec.side), int(target_spec.slot))
        var attacker_hp_before = int(attacker.get("hp", 0))
        var defender_hp_before = int(defender.get("hp", 0))
        var defender_status_before := status_snapshot(defender)
        field.attacker_is_player = side == "player"
        field.attacker_slot = int(action.slot)
        if bool(action.get("spread", false)):
            field["spread_modifier"] = 0.75
        if target_index > 0:
            if not bool(first_result.get("executed", false)):
                break
            field["skip_can_act"] = true
        var result = Battle.use_move(attacker, defender, move_name, rng, field)
        var action_log: Array = field.get("action_log", [])
        action_log.append(String(result.get("message", "")))
        if action_log.size() > 40:
            action_log.pop_front()
        field["action_log"] = action_log
        if target_index == 0: first_result = result
        field.erase("skip_can_act")
        field.erase("attacker_slot")
        field.erase("spread_modifier")
        if not String(result.get("weather", "")).is_empty():
            field.weather = String(result.weather)
            field.weather_turns = 5
        if bool(result.get("heal_party", false)) and side == "player":
            for party_member in range(party.size()):
                if typeof(party[party_member]) == TYPE_DICTIONARY:
                    party[party_member]["status"] = ""
        if int(result.get("pay_day", 0)) > 0:
            inventory["COINS"] = int(inventory.get("COINS", 0)) + int(result.pay_day)
        sync_double_records()
        await _emit({"kind":"double_move", "player_side":side == "player", "move":move_name,
            "result":result, "attacker":attacker, "defender":defender,
            "target_player_side":String(target_spec.side) == "player",
            "attacker_hp_before":attacker_hp_before, "defender_hp_before":defender_hp_before,
            "status_before":defender_status_before, "status_after":status_snapshot(defender),
            "defender_hp":int(defender.get("hp", 0)), "defender_name":Battle.display_name(defender)})
    if int(attacker.get("hp", 0)) > 0:
        await _after_action_residual(attacker, side == "player")

func _double_end_turn() -> void:
    turn_count += 1
    field["turn_count"] = turn_count
    var messages: Array[String] = []
    for side in ["player", "enemy"]:
        for entry in living(side):
            var pokemon: Dictionary = entry.pokemon
            var hp_before := int(pokemon.get("hp",0))
            var poisoned_before := String(pokemon.get("status",""))=="POISON" and not bool(pokemon.volatile.get("action_residual_applied", false))
            var trap_side := "player" if bool(pokemon.volatile.get("trap_source_player", side != "player")) else "enemy"
            var trap_source := double_actor(trap_side, int(pokemon.volatile.get("trap_source_slot", 0)))
            var message := Battle.end_turn(pokemon, field, trap_source, rng)
            await _emit({"kind":"poison_check", "pokemon":pokemon, "player_side":side=="player",
                "hp_before":hp_before, "poisoned":poisoned_before})
            if not message.is_empty(): messages.append(message)
    if int(field.get("weather_turns", 0)) > 0:
        field.weather_turns = int(field.weather_turns) - 1
        if int(field.weather_turns) <= 0:
            var old_weather := String(field.get("weather", ""))
            field.weather = ""
            messages.append("The %s subsided." % old_weather.replace("_", " ").to_lower())
    sync_double_records()
    await _emit({"kind":"double_end_turn", "text":" ".join(messages)})

func _resolve_double_faints() -> bool:
    var faint_messages: Array[String] = []
    var progression_rewards: Array[Dictionary] = []
    for slot in range(2):
        var defeated := double_actor("enemy", slot)
        if defeated.is_empty() or int(defeated.get("hp", 0)) > 0 or \
                bool(defeated.get("_double_faint_processed", false)):
            continue
        defeated["_double_faint_processed"] = true
        faint_messages.append("%s fainted!" % Battle.display_name(defeated))
        sync_double_records()
        var recipients := Battle.experience_recipients(party, participants, party_index)
        var reward := Battle.experience_reward(defeated, recipients.size())
        for index in recipients:
            var recipient: Dictionary = party[index]
            PokemonState.grant_evs(recipient, defeated)
            progression_rewards.append({"pokemon": recipient, "party_index": index, "reward": reward})
        faint_messages.append("Participating Pokemon gained %d EXP." % reward)
    if not faint_messages.is_empty():
        sync_double_records()
        await _emit({"kind":"text", "text":" ".join(faint_messages), "wait":0.125, "hud":true})
        for progression_reward in progression_rewards:
            await _gain_experience(progression_reward.pokemon, int(progression_reward.reward),
                int(progression_reward.party_index), false)
        sync_double_records()
        await _emit({"kind":"refresh"})
    for slot in range(2):
        var defeated := double_actor("enemy", slot)
        if defeated.is_empty() or int(defeated.get("hp", 0)) > 0:
            continue
        var replacement_index := _next_double_enemy_bench_index()
        if replacement_index >= 0:
            await _replace_double_enemy(slot, replacement_index)
    if living("enemy").is_empty():
        await _end("victory" if String(context.get("kind", "")) == "trainer" else "defeated")
        return true
    var player_faints: Array[String] = []
    for slot in range(2):
        var fallen := double_actor("player", slot)
        if fallen.is_empty() or int(fallen.get("hp", 0)) > 0 or \
                bool(fallen.get("_double_faint_announced", false)):
            continue
        fallen["_double_faint_announced"] = true
        player_faints.append("%s fainted!" % PokemonState.display_name(fallen))
    if not player_faints.is_empty():
        await _say(" ".join(player_faints), 0.1)
    for slot in range(2):
        var defeated_player := double_actor("player", slot)
        if defeated_player.is_empty() or int(defeated_player.get("hp", 0)) > 0:
            continue
        if _healthy_double_player_bench_indices().is_empty():
            continue
        var next_index = await _request({"kind":"switch", "reason":"DOUBLE_FORCED", "slot":slot})
        await _replace_double_player(slot, int(next_index))
    if living("player").is_empty():
        await _say("You are out of usable Pokemon.", 0.125)
        await _end("whiteout")
        return true
    await _emit({"kind":"refresh"})
    return false

func _next_double_enemy_bench_index() -> int:
    prepare_enemy_records()
    for index in range(enemy_party.size()):
        if index in [enemy_index, enemy_partner_index]:
            continue
        var record := enemy_party[index] as Dictionary
        if int(record.get("hp", 0)) > 0:
            return index
    return -1

func _healthy_double_player_bench_indices() -> Array[int]:
    var result: Array[int] = []
    for index in range(party.size()):
        if index in [party_index, partner_index] or \
                typeof(party[index]) != TYPE_DICTIONARY:
            continue
        var pokemon := Battle.ensure_pokemon(party[index])
        party[index] = pokemon
        if int(pokemon.hp) > 0 and not bool(pokemon.get("is_egg", false)):
            result.append(index)
    return result

func _replace_double_enemy(slot: int, next_index: int) -> void:
    var next_record := enemy_party[next_index] as Dictionary
    var replacement := Battle.ensure_pokemon(next_record)
    Battle.reset_battle_state(replacement)
    replacement.erase("_double_faint_processed")
    var enemy_spikes := int(field.get("enemy_spikes", 0))
    if enemy_spikes > 0 and not (replacement.types as Array).has("FLYING") and \
            String(replacement.get("ability", "")) != "LEVITATE":
        replacement.hp = maxi(0, int(replacement.hp) -
            maxi(1, int(int(replacement.max_hp) * enemy_spikes / 8.0)))
    if slot == 0:
        enemy_index = next_index
        enemy = replacement
    else:
        enemy_partner_index = next_index
        enemy_partner = replacement
    enemy_party[next_index] = replacement
    var opponents: Array = []
    for entry in living("player"): opponents.append(entry.pokemon)
    var entry_message := Battle.switch_in_message(replacement, opponents, field)
    var message := "%s sent out %s!" % [String(context.get(
        "trainer_name", "The opponent")), Battle.display_name(replacement)]
    if not entry_message.is_empty(): message += " " + entry_message
    await _emit({"kind":"enemy_switch", "pokemon":replacement, "slot":slot, "text":message, "wait":0.1, "hud":false})

func _replace_double_player(slot: int, next_index: int) -> void:
    if not participants.has(next_index): participants.append(next_index)
    var replacement := Battle.ensure_pokemon(party[next_index])
    Battle.reset_battle_state(replacement)
    var player_spikes := int(field.get("player_spikes", 0))
    if player_spikes > 0 and not (replacement.types as Array).has("FLYING") and \
            String(replacement.get("ability", "")) != "LEVITATE":
        replacement.hp = maxi(0, int(replacement.hp) -
            maxi(1, int(int(replacement.max_hp) * player_spikes / 8.0)))
    if slot == 0:
        party_index = next_index
        player = replacement
    else:
        partner_index = next_index
        partner = replacement
    party[next_index] = replacement
    var opponents: Array = []
    for entry in living("enemy"): opponents.append(entry.pokemon)
    var entry_message := Battle.switch_in_message(replacement, opponents, field)
    var message := "Go, %s!" % Battle.display_name(replacement)
    if not entry_message.is_empty(): message += " " + entry_message
    await _emit({"kind":"player_switch", "pokemon":replacement, "slot":slot, "text":message,
        "wait":0.1, "hud":false, "reset_move":false})

func _double_player_switch(slot: int, next_index: int) -> void:
    var outgoing := double_actor("player", slot)
    var outgoing_index := party_index if slot == 0 else partner_index
    var out_message := Battle.switch_out_message(outgoing)
    Battle.reset_battle_state(outgoing)
    if outgoing_index >= 0 and outgoing_index < party.size():
        party[outgoing_index] = outgoing
    await _replace_double_player(slot, next_index)
    if not out_message.is_empty():
        await _say(out_message, 0.075)

func _double_enemy_switch(slot: int, next_index: int) -> void:
    var outgoing := double_actor("enemy", slot)
    var outgoing_index := enemy_index if slot == 0 else enemy_partner_index
    var out_message := Battle.switch_out_message(outgoing)
    Battle.reset_battle_state(outgoing)
    if outgoing_index >= 0 and outgoing_index < enemy_party.size():
        enemy_party[outgoing_index] = outgoing
    await _replace_double_enemy(slot, next_index)
    if not out_message.is_empty():
        await _say(out_message, 0.075)

func _double_enemy_item(slot: int) -> void:
    var target := double_actor("enemy", slot)
    var restored := mini(50, int(target.max_hp) - int(target.hp))
    target.hp = int(target.hp) + restored
    context["_trainer_heals_used"] = int(context.get("_trainer_heals_used", 0)) + 1
    await _say("%s used a SUPER POTION on %s. Restored %d HP!" % [
        String(context.get("trainer_name", "The Trainer")),
        Battle.display_name(target), restored], 0.09)

# --- the lines a battle shows ----------------------------------------------------------

## The line a battle opens with.
static func intro_text(battle_context: Dictionary, opponent: Dictionary) -> String:
    var intro = String(battle_context.get("intro", ""))
    if bool(opponent.get("is_ghost", false)):
        intro = "Wild GHOST\nappeared!"
    elif intro.is_empty():
        intro = "Wild %s\nappeared!" % Battle.display_name(opponent)
    return intro

## The line that asks for the player's choice.
static func command_text(actor: Dictionary) -> String:
    return "What will\n%s do?" % PokemonState.display_name(actor)

## The lines an event puts in the battle's text box, in order (what the view
## types for it; used by tests and replays, which have no view).
static func event_lines(event: Dictionary) -> Array[String]:
    var lines: Array[String] = []
    match String(event.get("kind", "")):
        "text", "player_switch", "enemy_switch":
            if not String(event.get("text", "")).is_empty(): lines.append(String(event.text))
        "residual":
            if not String(event.get("message", "")).is_empty(): lines.append(String(event.message))
        "end_turn", "double_end_turn":
            if not String(event.get("text", "")).is_empty(): lines.append(String(event.text))
        "move", "double_move":
            var result: Dictionary = event.result
            var parts := message_parts(String(result.message))
            lines.append(("Target %s: %s" % [String(event.defender_name), parts[0]]) if event.kind == "double_move" else parts[0])
            if bool(result.get("executed", false)):
                var hits := maxi(1, int(result.get("hits", 1)))
                var criticals: Array = result.get("hit_criticals", [])
                for hit in range(hits - 1):
                    if hit < criticals.size() and bool(criticals[hit]):
                        lines.append("Critical hit!")
            if not parts[1].is_empty():
                lines.append(parts[1])
            if int(event.defender_hp) > 0 and bool(result.get("executed", false)):
                for status in new_statuses(event.status_before, event.status_after):
                    var description := String(STATUS_TEXT.get(status, ""))
                    if not description.is_empty():
                        lines.append("%s %s" % [String(event.defender_name), description])
        "boss_special":
            lines.append("A wave of psychic power unleashes!" if event.boss == "mewtwo" else "The ground is shaking violently!")
    return lines

# --- PvP ----------------------------------------------------------------------------------
# Two players' singles, resolved by the host: both choose, then the turn runs.
# The state and events keep the shape coop_pvp_runtime.gd plays (actors,
# parties by actor, slots, replacement...).

var actors: Array = []
var pvp_parties: Dictionary = {}
var pvp_inventories: Dictionary = {}
var pvp_item_rules: Dictionary = {}
var slots: Dictionary = {}
var pvp_actions: Dictionary = {}
var pvp_events: Array = []
var pvp_pending: Array = []
var replacement: Dictionary = {}
var pvp_turn := 0
var winner := ""
var resolving := false

func pvp_start(first: String, second: String, source: Dictionary, seed_value: int,
        items: Dictionary = {}, rules: Dictionary = {}) -> bool:
    actors = [first, second]
    rng.seed = seed_value
    start_state = rng.state
    pvp_inventories = items.duplicate(true)
    pvp_item_rules = rules.duplicate(true)
    for actor in actors:
        pvp_parties[actor] = []
        for record in source.get(actor, []):
            if not record is Dictionary or record.get("is_egg", false): continue
            var pokemon := Battle.ensure_pokemon(record.duplicate(true))
            Battle.reset_battle_state(pokemon)
            pvp_parties[actor].append(pokemon)
        slots[actor] = healthy(actor).front() if not healthy(actor).is_empty() else -1
        if slots[actor] < 0: return false
    for actor in actors:
        var message := Battle.switch_in_message(current(actor), [current(other(actor))], field)
        if not message.is_empty(): _pvp_event("message", actor, {"message":message})
    return true

func other(actor: String) -> String:
    return String(actors[1]) if actor == actors[0] else String(actors[0])

func current(actor: String) -> Dictionary:
    return pvp_parties[actor][slots[actor]]

func healthy(actor: String) -> Array:
    var result: Array = []
    for index in range(pvp_parties[actor].size()):
        if int(pvp_parties[actor][index].hp) > 0: result.append(index)
    return result

func pvp_snapshot() -> Dictionary:
    return {"parties":pvp_parties.duplicate(true), "slots":slots.duplicate(), "field":field.duplicate(true),
        "turn":pvp_turn, "finished":finished, "winner":winner, "replacement":replacement.duplicate(true)}

func pvp_submit(actor: String, expected_turn: int, action: Dictionary) -> Dictionary:
    if actor not in actors or finished: return {"ok":false, "reason":"not_battling"}
    if expected_turn != pvp_turn: return {"ok":false, "reason":"stale_turn"}
    if not pvp_valid_action(action): return {"ok":false, "reason":"invalid_action"}
    history.append({"actor":actor, "turn":expected_turn, "action":action.duplicate(true)})
    var kind := String(action.kind)
    if kind == "run":
        pvp_events.clear()
        finished = true
        winner = other(actor)
        _pvp_event("finished", actor, {"message":"The battle ended."})
        return _pvp_reply()
    if not replacement.is_empty():
        if not replacement.has(actor) or kind != "switch": return {"ok":false, "reason":"replacement_required"}
        var index := int(action.get("index", -1))
        if index not in healthy(actor) or index == slots[actor]: return {"ok":false, "reason":"invalid_switch"}
        pvp_events.clear()
        _pvp_switch(actor, index, bool(replacement[actor].get("baton", false)))
        replacement.erase(actor)
        _pvp_faints()
        if replacement.is_empty() and not finished: _pvp_advance()
        return _pvp_reply()
    if pvp_actions.has(actor): return {"ok":false, "reason":"already_selected"}
    var pokemon := current(actor)
    if kind == "switch":
        var index := int(action.get("index", -1))
        if index not in healthy(actor) or index == slots[actor]: return {"ok":false, "reason":"invalid_switch"}
        if trapped(pokemon): return {"ok":false, "reason":"trapped"}
    elif kind == "item":
        if not pvp_can_use_item(actor, String(action.get("item", "")), int(action.get("index", -1))): return {"ok":false, "reason":"unusable_item"}
    elif kind == "move":
        var move := String(action.get("move", ""))
        var forced := Battle.forced_move(pokemon)
        if not forced.is_empty(): move = forced
        elif move == "STRUGGLE":
            for option in pokemon.moves:
                if Battle.move_is_usable(pokemon, option): return {"ok":false, "reason":"move_available"}
        elif move not in pokemon.moves or not Battle.move_is_usable(pokemon, move): return {"ok":false, "reason":"unusable_move"}
        action = action.duplicate(true)
        action.move = move
    else: return {"ok":false, "reason":"invalid_action"}
    pvp_actions[actor] = action.duplicate(true)
    pvp_actions[actor]["slot"] = slots[actor]
    if pvp_actions.size() < 2: return {"ok":true, "waiting":true, "state":pvp_snapshot(), "events":[]}
    pvp_events.clear()
    var a: String = actors[0]
    var b: String = actors[1]
    var a_first: bool = pvp_actions[a].kind != "move"
    if (pvp_actions[a].kind == "move") == (pvp_actions[b].kind == "move"):
        a_first = Battle.player_moves_first(current(a), String(pvp_actions[a].get("move", "")),
            current(b), String(pvp_actions[b].get("move", "")), rng, field)
    pvp_pending = [a, b] if a_first else [b, a]
    resolving = true
    _pvp_advance()
    return _pvp_reply()

static func pvp_valid_action(action: Dictionary) -> bool:
    if not action.get("kind") is String: return false
    var kind: String = action.kind
    if kind not in ["run", "move", "switch", "item"]: return false
    if kind in ["switch", "item"]:
        var index = action.get("index")
        if not (index is int or index is float): return false
        if not is_finite(float(index)) or float(index) != floor(float(index)) or float(index) < 0 or float(index) > 5: return false
    if kind in ["move", "item"]:
        var value = action.get("move" if kind == "move" else "item")
        if not value is String or value.is_empty() or value.length() > 80: return false
    return true

func _pvp_advance() -> void:
    if not resolving: return
    while not pvp_pending.is_empty() and not finished:
        var actor: String = pvp_pending.pop_front()
        var action: Dictionary = pvp_actions[actor]
        if int(action.slot) != int(slots[actor]) or int(current(actor).hp) <= 0: continue
        if action.kind == "switch": _pvp_switch(actor, int(action.index))
        elif action.kind == "item": _pvp_item(actor, String(action.item), int(action.index))
        else: _pvp_move(actor, String(action.move))
        _pvp_faints()
        if not replacement.is_empty() or finished: return
    if finished: return
    for actor in actors:
        var message := Battle.end_turn(current(actor), field, current(other(actor)), rng)
        _pvp_event("residual", actor, {"message":message})
    if int(field.get("weather_turns", 0)) > 0:
        field.weather_turns -= 1
        if field.weather_turns <= 0: field.weather = ""
    pvp_turn += 1
    field.turn_count = pvp_turn
    pvp_actions.clear()
    resolving = false
    _pvp_faints()

func _pvp_move(actor: String, move: String) -> void:
    var attacker := current(actor)
    var defender := current(other(actor))
    var repeated := not String(attacker.volatile.get("charge_move", "")).is_empty() or int(attacker.volatile.get("bide_turns", 0)) > 0 or int(attacker.volatile.get("locked_turns", 0)) > 0
    if move != "STRUGGLE" and not repeated: attacker.pp[move] = maxi(0, int(attacker.pp.get(move, 1)) - 1)
    field.attacker_is_player = actor == actors[0]
    var result := Battle.use_move(attacker, defender, move, rng, field)
    if not String(result.get("weather", "")).is_empty():
        field.weather = result.weather
        field.weather_turns = 5
    if result.get("heal_party", false):
        for member in pvp_parties[actor]:
            member.status = ""
            member.status_counter = 0
            member.toxic_counter = 0
    _pvp_event("move", actor, {"move":move, "result":result})
    var effect := String(result.get("force_switch", ""))
    if effect == "TELEPORT":
        finished = true
        winner = ""
        return
    if effect == "BATON_PASS" and healthy(actor).size() > 1:
        replacement[actor] = {"baton":true}
    elif effect == "FORCE_SWITCH":
        var target := other(actor)
        var candidates := healthy(target)
        candidates.erase(slots[target])
        if not candidates.is_empty(): _pvp_switch(target, int(candidates[rng.randi_range(0, candidates.size() - 1)]))

func pvp_can_use_item(actor: String, item: String, index: int) -> bool:
    if index < 0 or index >= pvp_parties[actor].size() or int(pvp_inventories.get(actor, {}).get(item, 0)) < 1: return false
    var pokemon: Dictionary = pvp_parties[actor][index]
    var rule: Dictionary = pvp_item_rules.get(item, {})
    match String(rule.get("kind", "")):
        "heal": return int(pokemon.hp) > 0 and int(pokemon.hp) < int(pokemon.max_hp)
        "full_restore": return int(pokemon.hp) > 0 and (int(pokemon.hp) < int(pokemon.max_hp) or not String(pokemon.status).is_empty())
        "status": return int(pokemon.hp) > 0 and not String(pokemon.status).is_empty() and (rule.get("status", "ANY") == "ANY" or rule.status == pokemon.status)
        "confusion": return pokemon.volatile.has("confuse_turns")
        "revive": return int(pokemon.hp) <= 0
    return false

func _pvp_item(actor: String, item: String, index: int) -> void:
    var pokemon: Dictionary = pvp_parties[actor][index]
    var rule: Dictionary = pvp_item_rules[item]
    match String(rule.kind):
        "heal": pokemon.hp = mini(int(pokemon.max_hp), int(pokemon.hp) + int(rule.amount))
        "full_restore":
            pokemon.hp = pokemon.max_hp
            pokemon.status = ""
            pokemon.status_counter = 0
            pokemon.toxic_counter = 0
        "status":
            pokemon.status = ""
            pokemon.status_counter = 0
            pokemon.toxic_counter = 0
        "confusion": pokemon.volatile.erase("confuse_turns")
        "revive": pokemon.hp = maxi(1, int(int(pokemon.max_hp) * float(rule.fraction)))
    pvp_inventories[actor][item] -= 1
    _pvp_event("item", actor, {"message":"Used %s on %s." % [item, Battle.display_name(pokemon)]})

func _pvp_switch(actor: String, index: int, baton: bool = false) -> void:
    var previous := current(actor)
    var stages: Dictionary = previous.stages.duplicate(true)
    var volatile: Dictionary = previous.volatile.duplicate(true)
    var message := Battle.switch_out_message(previous)
    Battle.reset_battle_state(previous)
    slots[actor] = index
    Battle.reset_battle_state(current(actor))
    if baton:
        current(actor).stages = stages
        # Transfer only passable effects, not charge/disable/encore bookkeeping.
        for key in ["substitute_hp", "confuse_turns", "focus_energy"]:
            if volatile.has(key): current(actor).volatile[key] = volatile[key]
    var incoming := current(actor)
    var spikes := int(field.get("player_spikes" if actor == actors[0] else "enemy_spikes", 0))
    if spikes > 0 and "FLYING" not in incoming.types and incoming.get("ability", "") != "LEVITATE":
        incoming.hp = maxi(0, int(incoming.hp) - maxi(1, int(int(incoming.max_hp) * spikes / 8.0)))
    var arrival := Battle.switch_in_message(current(actor), [current(other(actor))], field)
    _pvp_event("switch", actor, {"message":message + " " + arrival})

func _pvp_faints() -> void:
    var alive: Array = []
    for actor in actors:
        if not healthy(actor).is_empty(): alive.append(actor)
    if alive.size() < 2:
        finished = true
        winner = String(alive[0]) if alive.size() == 1 else ""
        replacement.clear()
        return
    for actor in actors:
        if int(current(actor).hp) <= 0: replacement[actor] = {"baton":false}

func _pvp_event(kind: String, actor: String, data: Dictionary) -> void:
    data = data.duplicate(true)
    data["kind"] = kind
    data["actor"] = actor
    data["state"] = pvp_snapshot()
    pvp_events.append(data)

func _pvp_reply() -> Dictionary:
    return {"ok":true, "state":pvp_snapshot(), "events":pvp_events.duplicate(true)}
