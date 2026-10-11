class_name BattleEngine
extends RefCounted

const PokemonData = preload("res://scripts/pokemon_data.gd")
const PokemonState = preload("res://scripts/pokemon_state.gd")
const ItemData = preload("res://scripts/item_data.gd")
const SourceBattleRules = preload("res://scripts/source_battle_rules.gd")
const SPECIAL_TYPES := ["FIRE", "WATER", "GRASS", "ELECTRIC", "ICE", "PSYCHIC", "DRAGON", "DARK"]
const TYPE_EFFECT := {
    "NORMAL": {"ROCK":0.5, "GHOST":0.0, "STEEL":0.5},
    "FIRE": {"FIRE":0.5, "WATER":0.5, "GRASS":2.0, "ICE":2.0, "BUG":2.0, "ROCK":0.5, "DRAGON":0.5, "STEEL":2.0},
    "WATER": {"FIRE":2.0, "WATER":0.5, "GRASS":0.5, "GROUND":2.0, "ROCK":2.0, "DRAGON":0.5},
    "ELECTRIC": {"WATER":2.0, "ELECTRIC":0.5, "GRASS":0.5, "GROUND":0.0, "FLYING":2.0, "DRAGON":0.5},
    "GRASS": {"FIRE":0.5, "WATER":2.0, "GRASS":0.5, "POISON":0.5, "GROUND":2.0, "FLYING":0.5, "BUG":0.5, "ROCK":2.0, "DRAGON":0.5, "STEEL":0.5},
    "ICE": {"FIRE":0.5, "WATER":0.5, "GRASS":2.0, "ICE":0.5, "GROUND":2.0, "FLYING":2.0, "DRAGON":2.0, "STEEL":0.5},
    "FIGHTING": {"NORMAL":2.0, "ICE":2.0, "POISON":0.5, "FLYING":0.5, "PSYCHIC":0.5, "BUG":0.5, "ROCK":2.0, "GHOST":0.0, "DARK":2.0, "STEEL":2.0, "FAIRY":0.5},
    "POISON": {"GRASS":2.0, "POISON":0.5, "GROUND":0.5, "ROCK":0.5, "GHOST":0.5, "STEEL":0.0, "FAIRY":2.0},
    "GROUND": {"FIRE":2.0, "ELECTRIC":2.0, "GRASS":0.5, "POISON":2.0, "FLYING":0.0, "BUG":0.5, "ROCK":2.0, "STEEL":2.0},
    "FLYING": {"ELECTRIC":0.5, "GRASS":2.0, "FIGHTING":2.0, "BUG":2.0, "ROCK":0.5, "STEEL":0.5},
    "PSYCHIC": {"FIGHTING":2.0, "POISON":2.0, "PSYCHIC":0.5, "DARK":0.0, "STEEL":0.5},
    "BUG": {"FIRE":0.5, "GRASS":2.0, "FIGHTING":0.5, "POISON":0.5, "FLYING":0.5, "PSYCHIC":2.0, "GHOST":0.5, "DARK":2.0, "STEEL":0.5, "FAIRY":0.5},
    "ROCK": {"FIRE":2.0, "ICE":2.0, "FIGHTING":0.5, "GROUND":0.5, "FLYING":2.0, "BUG":2.0, "STEEL":0.5},
    "GHOST": {"NORMAL":0.0, "PSYCHIC":2.0, "GHOST":2.0, "DARK":0.5},
    "DRAGON": {"DRAGON":2.0, "STEEL":0.5, "FAIRY":0.0},
    "DARK": {"FIGHTING":0.5, "PSYCHIC":2.0, "GHOST":2.0, "DARK":0.5, "FAIRY":0.5},
    "STEEL": {"FIRE":0.5, "WATER":0.5, "ELECTRIC":0.5, "ICE":2.0, "ROCK":2.0, "STEEL":0.5, "FAIRY":2.0},
    "FAIRY": {"FIRE":0.5, "FIGHTING":2.0, "POISON":0.5, "DRAGON":2.0, "DARK":2.0, "STEEL":0.5}
}

static func make_pokemon(species: String, level: int,
        rng: RandomNumberGenerator = null, overrides: Dictionary = {}) -> Dictionary:
    var seed_record := overrides.duplicate(true)
    seed_record["species"] = species.to_lower()
    seed_record["level"] = clampi(level, 1, 100)
    var result := PokemonState.ensure_core(seed_record, rng)
    var data := PokemonData.info(species)
    var moves: Array[String] = []
    var removed_moves: Array = result.get("unsupported_moves_removed", []).duplicate()
    var supplied_moves = result.get("moves", [])
    if typeof(supplied_moves) == TYPE_ARRAY and not (supplied_moves as Array).is_empty():
        for raw_move in supplied_moves:
            var normalized := String(raw_move).to_upper().replace(" ", "_")
            if not PokemonData.move_info(normalized).is_empty():
                moves.append(normalized)
            elif not removed_moves.has(normalized):
                removed_moves.append(normalized)
    if not removed_moves.is_empty():
        result["unsupported_moves_removed"] = removed_moves
    if moves.is_empty():
        for learned in data.get("learnset", []):
            if int(learned.get("level", 1)) <= level:
                moves.append(String(learned.get("move", "TACKLE")))
    if moves.is_empty():
        moves.append("TACKLE")
    if moves.size() > 4:
        moves = moves.slice(moves.size() - 4)
    var pp := {}
    var supplied_pp: Dictionary = result.get("pp", {}) if typeof(result.get("pp", {})) == TYPE_DICTIONARY else {}
    for move_name in moves:
        pp[move_name] = clampi(int(supplied_pp.get(move_name,
            PokemonData.move_info(move_name).get("pp", 35))), 0,
            int(PokemonData.move_info(move_name).get("pp", 35)))
    result["exp"] = int(result.get("exp", exp_for_level(species, level)))
    result["types"] = (data.get("types", ["NORMAL"]) as Array).duplicate()
    result["moves"] = moves
    result["pp"] = pp
    result["status"] = String(result.get("status", ""))
    result["status_counter"] = int(result.get("status_counter", 0))
    result["toxic_counter"] = int(result.get("toxic_counter", 0))
    result["stages"] = (overrides.get("stages", {}) as Dictionary).duplicate(true) \
        if typeof(overrides.get("stages", {})) == TYPE_DICTIONARY else default_stages()
    if (result["stages"] as Dictionary).is_empty():
        result["stages"] = default_stages()
    result["volatile"] = (overrides.get("volatile", {}) as Dictionary).duplicate(true) \
        if typeof(overrides.get("volatile", {})) == TYPE_DICTIONARY else {}
    var custom_base: Array = result.get("base_stats", []) if typeof(result.get("base_stats", [])) == TYPE_ARRAY else []
    PokemonState.apply_stats(result, overrides.has("max_hp"), custom_base)
    return result

static func ensure_pokemon(source: Dictionary) -> Dictionary:
    var fresh := make_pokemon(String(source.get("species", "rattata")),
        int(source.get("level", 1)), null, source)
    fresh["hp"] = clampi(int(fresh.get("hp", fresh.max_hp)), 0, int(fresh.max_hp))
    if typeof(fresh.get("stages", {})) != TYPE_DICTIONARY:
        fresh.stages = default_stages()
    else:
        for key in default_stages().keys():
            if not fresh.stages.has(key):
                fresh.stages[key] = 0
    if typeof(fresh.get("volatile", {})) != TYPE_DICTIONARY:
        fresh.volatile = {}
    return fresh

static func default_stages() -> Dictionary:
    return {"attack":0, "defense":0, "speed":0, "sp_attack":0,
        "sp_defense":0, "accuracy":0, "evasion":0}

static func reset_battle_state(pokemon: Dictionary) -> void:
    var original = (pokemon.get("volatile", {}) as Dictionary).get("original_form", {})
    if typeof(original) == TYPE_DICTIONARY and not (original as Dictionary).is_empty():
        for key in (original as Dictionary).keys():
            pokemon[key] = (original as Dictionary)[key]
    var mimic_moves = (pokemon.get("volatile", {}) as Dictionary).get("mimic_original_moves", [])
    if typeof(mimic_moves) == TYPE_ARRAY and not (mimic_moves as Array).is_empty():
        pokemon.moves = (mimic_moves as Array).duplicate()
        var mimic_pp = (pokemon.get("volatile", {}) as Dictionary).get("mimic_original_pp", {})
        if typeof(mimic_pp) == TYPE_DICTIONARY and not (mimic_pp as Dictionary).is_empty():
            pokemon.pp = (mimic_pp as Dictionary).duplicate(true)
    pokemon.stages = default_stages()
    pokemon.volatile = {}

static func stage_multiplier(stage: int) -> float:
    stage = clampi(stage, -6, 6)
    return (2.0 + stage) / 2.0 if stage >= 0 else 2.0 / (2.0 - stage)

static func effective_stat(pokemon: Dictionary, stat_name: String,
        field: Dictionary = {}) -> int:
    var value := float((pokemon.get("stats", {}) as Dictionary).get(stat_name, 1))
    var ability := String(pokemon.get("ability", ""))
    var status := String(pokemon.get("status", ""))
    if stat_name == "attack" and status == "BURN" and ability != "GUTS":
        value *= 0.25
    if stat_name == "attack" and ability in ["HUGE POWER", "PURE POWER"]:
        value *= 2.0
    if stat_name == "attack" and ability == "GUTS" and not status.is_empty():
        value *= 1.5
    if stat_name == "defense" and ability == "MARVEL SCALE" and not status.is_empty():
        value *= 1.5
    if stat_name == "speed" and status == "PARALYSIS" and ability != "QUICK FEET":
        value *= 0.25
    if stat_name == "speed" and ability == "QUICK FEET" and not status.is_empty():
        value *= 1.5
    if stat_name == "speed":
        match String(field.get("weather", "")):
            "RAIN":
                if ability == "SWIFT SWIM": value *= 2.0
            "SUN":
                if ability == "CHLOROPHYLL": value *= 2.0
            "SANDSTORM":
                if ability == "SAND RUSH": value *= 2.0
            "HAIL", "SNOW":
                if ability == "SLUSH RUSH": value *= 2.0
    value = floor(value) * stage_multiplier(int((pokemon.get("stages", {}) as Dictionary).get(stat_name, 0)))
    value *= PokemonState.held_stat_multiplier(pokemon, stat_name)
    return clampi(int(floor(value)), 1, 999)

static func move_priority(move_name: String) -> int:
    var effect := String(PokemonData.move_info(move_name).get("effect", ""))
    if move_name in ["ENDURE","PROTECT","DETECT"]: return 2
    if effect == "EFFECT_PRIORITY_HIT" or move_name in ["QUICK_ATTACK","MACH_PUNCH","EXTREMESPEED"]: return 1
    if move_name in ["COUNTER","MIRROR_COAT","WHIRLWIND","ROAR","VITAL_THROW"]: return -1
    return 0

static func pokemon_move_priority(pokemon: Dictionary, move_name: String) -> int:
    var priority := move_priority(move_name)
    var move := PokemonData.move_info(move_name)
    if String(pokemon.get("ability", "")) == "PRANKSTER" and int(move.get("power", 0)) <= 0:
        priority += 1
    return priority

static func forced_move(pokemon: Dictionary) -> String:
    var volatile: Dictionary = pokemon.get("volatile", {})
    var charge_move := String(volatile.get("charge_move", ""))
    if not charge_move.is_empty():
        return charge_move
    if int(volatile.get("bide_turns", 0)) > 0:
        return "BIDE"
    var locked_move := String(volatile.get("locked_move", ""))
    if int(volatile.get("locked_turns", 0)) > 0 and not locked_move.is_empty():
        return locked_move
    var encore_move := String(volatile.get("encore_move", ""))
    if int(volatile.get("encore_turns", 0)) > 0 and not encore_move.is_empty():
        if int((pokemon.get("pp", {}) as Dictionary).get(encore_move, 0)) > 0:
            return encore_move
    return ""

static func move_is_usable(pokemon: Dictionary, move_name: String) -> bool:
    if String((pokemon.get("volatile", {}) as Dictionary).get("disabled_move", "")) == move_name:
        return false
    return int((pokemon.get("pp", {}) as Dictionary).get(move_name, 0)) > 0

static func player_moves_first(player: Dictionary, player_move: String,
        enemy: Dictionary, enemy_move: String, rng: RandomNumberGenerator,
        field: Dictionary = {}) -> bool:
    var player_priority := pokemon_move_priority(player, player_move)
    var enemy_priority := pokemon_move_priority(enemy, enemy_move)
    if player_priority != enemy_priority:
        return player_priority > enemy_priority
    var player_speed := effective_stat(player, "speed", field)
    var enemy_speed := effective_stat(enemy, "speed", field)
    return player_speed > enemy_speed or (player_speed == enemy_speed and rng.randf() < 0.5)

static func effectiveness(move_type: String, defender_types: Array) -> float:
    var result := 1.0
    var chart: Dictionary = TYPE_EFFECT.get(move_type, {})
    for defender_type in defender_types:
        result *= float(chart.get(String(defender_type), 1.0))
    return result

static func _ability_immunity(defender: Dictionary, move_type: String) -> String:
    var ability := String(defender.get("ability", ""))
    if move_type == "GROUND" and ability == "LEVITATE":
        return "%s's LEVITATE made it immune!" % display_name(defender)
    if move_type == "FIRE" and ability == "FLASH FIRE":
        return "%s absorbed the fire with FLASH FIRE!" % display_name(defender)
    if move_type == "WATER" and ability in ["WATER ABSORB", "STORM DRAIN"]:
        return "%s absorbed the water with %s!" % [display_name(defender), ability]
    if move_type == "ELECTRIC" and ability in ["VOLT ABSORB", "LIGHTNING ROD", "MOTOR DRIVE"]:
        return "%s absorbed the electricity with %s!" % [display_name(defender), ability]
    if move_type == "GRASS" and ability == "SAP SIPPER":
        return "%s absorbed the move with SAP SIPPER!" % display_name(defender)
    return ""

static func _apply_ability_immunity(defender: Dictionary, move_type: String) -> void:
    var ability := String(defender.get("ability", ""))
    if ability in ["WATER ABSORB", "VOLT ABSORB"]:
        defender.hp = mini(int(defender.max_hp), int(defender.hp) +
            maxi(1, int(int(defender.max_hp) / 4.0)))
    elif ability in ["STORM DRAIN", "LIGHTNING ROD"]:
        defender.stages.sp_attack = clampi(int(defender.stages.get("sp_attack", 0)) + 1, -6, 6)
    elif ability == "MOTOR DRIVE":
        defender.stages.speed = clampi(int(defender.stages.get("speed", 0)) + 1, -6, 6)
    elif ability == "SAP SIPPER":
        defender.stages.attack = clampi(int(defender.stages.get("attack", 0)) + 1, -6, 6)
    elif ability == "FLASH FIRE":
        defender.volatile.flash_fire = true

static func _ability_damage_multiplier(attacker: Dictionary, defender: Dictionary,
        move_key: String, move_type: String, power: int, category: String,
        type_scale: float) -> float:
    var multiplier := 1.0
    var attacker_ability := String(attacker.get("ability", ""))
    var defender_ability := String(defender.get("ability", ""))
    var hp_ratio := float(attacker.get("hp", 1)) / maxf(1.0, float(attacker.get("max_hp", 1)))
    if hp_ratio <= 1.0 / 3.0 and (
            (attacker_ability == "BLAZE" and move_type == "FIRE") or
            (attacker_ability == "TORRENT" and move_type == "WATER") or
            (attacker_ability == "OVERGROW" and move_type == "GRASS") or
            (attacker_ability == "SWARM" and move_type == "BUG")):
        multiplier *= 1.5
    if attacker_ability == "TECHNICIAN" and power <= 60:
        multiplier *= 1.5
    if attacker_ability == "IRON FIST" and "PUNCH" in move_key:
        multiplier *= 1.2
    if attacker_ability == "STRONG JAW" and (
            "BITE" in move_key or "FANG" in move_key or move_key == "CRUNCH"):
        multiplier *= 1.5
    if attacker_ability == "RECKLESS" and "RECOIL" in String(
            PokemonData.move_info(move_key).get("effect", "")):
        multiplier *= 1.2
    if attacker_ability == "TINTED LENS" and type_scale < 1.0 and type_scale > 0.0:
        multiplier *= 2.0
    if attacker_ability == "FLASH FIRE" and bool(attacker.volatile.get("flash_fire", false)) and move_type == "FIRE":
        multiplier *= 1.5
    if defender_ability in ["FILTER", "SOLID ROCK"] and type_scale > 1.0:
        multiplier *= 0.75
    if defender_ability == "THICK FAT" and move_type in ["FIRE", "ICE"]:
        multiplier *= 0.5
    if defender_ability == "HEATPROOF" and move_type == "FIRE":
        multiplier *= 0.5
    if defender_ability == "MULTISCALE" and int(defender.hp) == int(defender.max_hp):
        multiplier *= 0.5
    if defender_ability == "MARVEL SCALE" and category == "physical" and not String(defender.get("status", "")).is_empty():
        multiplier *= 2.0 / 3.0
    return multiplier

static func _apply_contact_effects(attacker: Dictionary, defender: Dictionary,
        rng: RandomNumberGenerator, result: Dictionary) -> void:
    var ability := String(defender.get("ability", ""))
    if ability in ["ROUGH SKIN", "IRON BARBS"]:
        var recoil := maxi(1, int(int(attacker.max_hp) / 8.0))
        attacker.hp = maxi(0, int(attacker.hp) - recoil)
        result.message += " %s was hurt by %s!" % [display_name(attacker), ability]
    elif ability == "STATIC" and rng.randi_range(1, 100) <= 30:
        _set_status(attacker, "PARALYSIS", rng)
    elif ability == "FLAME BODY" and rng.randi_range(1, 100) <= 30:
        _set_status(attacker, "BURN", rng)
    elif ability == "POISON POINT" and rng.randi_range(1, 100) <= 30:
        _set_status(attacker, "POISON", rng)
    elif ability == "EFFECT SPORE" and rng.randi_range(1, 100) <= 30:
        _set_status(attacker, ["PARALYSIS", "POISON", "SLEEP"][rng.randi_range(0, 2)], rng)
    if String(defender.get("held_item", "")) == "HARD SHELL":
        var chip := maxi(1, int(int(attacker.max_hp) / 16.0))
        attacker.hp = maxi(0, int(attacker.hp) - chip)
        result.message += " The HARD SHELL hurt its attacker!"

static func display_name(pokemon: Dictionary) -> String:
    return "GHOST" if bool(pokemon.get("is_ghost", false)) else PokemonState.battle_display_name(pokemon)

static func use_move(attacker: Dictionary, defender: Dictionary, move_name: String,
        rng: RandomNumberGenerator, field: Dictionary = {}, recursion_depth: int = 0) -> Dictionary:
    var requested_key := move_name.to_upper().replace(" ", "_")
    var move := PokemonData.move_info(requested_key)
    if move.is_empty():
        return {"message":"That move is not supported.", "damage":0,
            "effectiveness":1.0, "hits":1, "move":requested_key,
            "animation_move":"", "category":"status", "force_switch":"",
            "weather":"", "executed":false}
    var original_effect := String(move.get("effect", ""))
    var display := String(move.get("name", requested_key)).replace("_", " ")
    var result := {
        "message":"%s used %s!" % [display_name(attacker), display],
        "damage":0, "effectiveness":1.0, "hits":1,
        "move":requested_key, "animation_move":requested_key,
        "category":"status", "force_switch":"", "weather":"", "executed":false
    }
    if recursion_depth > 4:
        result.message += " But it failed!"
        return result

    if recursion_depth == 0 and int(attacker.volatile.get("disabled_turns",0)) > 0:
        attacker.volatile.disabled_turns=int(attacker.volatile.disabled_turns)-1
        if int(attacker.volatile.disabled_turns)<=0:
            attacker.volatile.erase("disabled_move")
            attacker.volatile.erase("disabled_turns")

    if not bool(field.get("skip_can_act", false)):
        var was_asleep := String(attacker.get("status", "")) == "SLEEP"
        var unable_message := can_act(attacker, rng, original_effect, requested_key)
        var wake_message := ""
        if was_asleep and String(attacker.get("status", "")) == "":
            wake_message = "%s woke up! " % display_name(attacker)
        if not unable_message.is_empty():
            result.message = wake_message + unable_message
            return result
        result.message = wake_message + result.message
    result.executed = true
    if original_effect == "EFFECT_SNORE" and String(attacker.get("status", "")) != "SLEEP":
        result.message += " But it failed!"
        result.animation_move = ""
        return result

    var called_key := _resolve_called_move(attacker, defender, requested_key,
        original_effect, rng)
    if called_key == "__FAIL__":
        result.message += " But it failed!"
        return result
    if not called_key.is_empty() and called_key != requested_key:
        var called_move := PokemonData.move_info(called_key)
        if called_move.is_empty():
            result.message += " But it failed!"
            return result
        move = called_move
        result.animation_move = called_key
        result.message += " It called %s!" % String(move.get("name", called_key))

    var actual_key := String(result.animation_move)
    var effect := String(move.get("effect", ""))
    if String(attacker.volatile.get("disabled_move", "")) == actual_key:
        result.message += " That move is disabled!"
        result.animation_move = ""
        return result

    var charge_effects := ["EFFECT_FLY", "EFFECT_RAZOR_WIND", "EFFECT_SKY_ATTACK",
        "EFFECT_SKULL_BASH", "EFFECT_SOLARBEAM"]
    var skips_charge := effect == "EFFECT_SOLARBEAM" and String(field.get("weather", "")) == "SUN"
    if effect in charge_effects and not skips_charge:
        if String(attacker.volatile.get("charge_move", "")) != actual_key:
            attacker.volatile.charge_move = actual_key
            if effect == "EFFECT_FLY":
                attacker.volatile.semi_invulnerable = true
            if effect == "EFFECT_SKULL_BASH":
                attacker.stages.defense = clampi(int(attacker.stages.get("defense", 0)) + 1, -6, 6)
            attacker.volatile.last_move = actual_key
            result.animation_move = actual_key + "_SETUP"
            result.message += " It is charging!"
            return result
        attacker.volatile.erase("charge_move")
        attacker.volatile.erase("semi_invulnerable")

    var field_effect := effect in ["EFFECT_REFLECT", "EFFECT_LIGHT_SCREEN", "EFFECT_SAFEGUARD",
        "EFFECT_SPIKES", "EFFECT_RAIN_DANCE", "EFFECT_SUNNY_DAY", "EFFECT_SANDSTORM"]
    # Source self boosts and healing do not test the opponent's evasion or
    # airborne state. Hostile status/stat effects still use the accuracy result.
    field_effect = field_effect or (int(move.get("power", 0)) == 0 and (
        "_UP" in effect or effect in ["EFFECT_DEFENSE_CURL", "EFFECT_HEAL",
            "EFFECT_MORNING_SUN", "EFFECT_SYNTHESIS", "EFFECT_MOONLIGHT", "EFFECT_CURSE"]))
    var defender_charge := String(defender.volatile.get("charge_move", ""))
    var can_reach_hidden := actual_key in ["EARTHQUAKE","MAGNITUDE","FISSURE"] if defender_charge == "DIG" else \
        actual_key in ["GUST","THUNDER","TWISTER","WHIRLWIND"]
    if bool(defender.volatile.get("semi_invulnerable", false)) and not can_reach_hidden and not field_effect:
        result.message += " It missed!"
        result.animation_move = ""
        _break_move_chain(attacker, effect)
        return result
    if bool(defender.volatile.get("protect", false)) and (
            int(move.get("power", 0)) > 0 or _targets_opponent(effect)):
        result.message += " %s protected itself!" % display_name(defender)
        result.animation_move = ""
        _break_move_chain(attacker, effect)
        return result

    var accuracy := SourceBattleRules.accuracy_threshold(int(move.get("accuracy",100)),
        int(attacker.stages.get("accuracy",0)), int(defender.stages.get("evasion",0)))
    var always_hits := "ALWAYS_HIT" in effect or bool(attacker.volatile.get("lock_on", false))
    if effect == "EFFECT_THUNDER" and String(field.get("weather", "")) == "RAIN":
        always_hits = true
    attacker.volatile.erase("lock_on")
    var accuracy_missed := not always_hits and accuracy < 255 and rng.randi_range(0,255) >= accuracy
    # Java still draws the accuracy roll, but these field effects do not use it.
    if accuracy_missed and not field_effect:
        result.message += " It missed!"
        result.animation_move = ""
        _break_move_chain(attacker, effect)
        if "JUMP_KICK" in effect:
            var crash := maxi(1, int(int(attacker.max_hp) / 2.0))
            attacker.hp = maxi(0, int(attacker.hp) - crash)
            result.message += " It crashed!"
        return result

    attacker.volatile.last_move = actual_key
    if _apply_one_off_status_move(attacker, defender, actual_key,
            effect, rng, field, result):
        if "failed!" in String(result.message): result.animation_move = ""
        return result
    if effect == "EFFECT_DREAM_EATER" and String(defender.get("status", "")) != "SLEEP":
        result.message += " It failed!"
        result.animation_move = ""
        return result

    var move_type := String(move.get("type", "NORMAL"))
    if effect == "EFFECT_HIDDEN_POWER":
        move_type = _hidden_power_type(attacker)
        result.message += " It became %s-type!" % move_type
    var power := _dynamic_power(attacker, defender, effect,
        int(move.get("power", 0)), rng, result)
    result.move_type = move_type
    var power_override := int(field.get("move_power_override", 0))
    if power_override > 0:
        power = power_override
        field.erase("move_power_override")
    var hit_count := 1
    result.defender_hp_before = int(defender.hp)

    if power > 0:
        var immunity := _ability_immunity(defender, move_type)
        if not immunity.is_empty():
            _apply_ability_immunity(defender, move_type)
            result.message += " %s" % immunity
            result.effectiveness = 0.0
            return result

    if effect == "EFFECT_PRESENT":
        var present_roll := rng.randi_range(0, 99)
        if present_roll >= 80:
            var gift := mini(int(defender.max_hp) - int(defender.hp),
                maxi(1, int(int(defender.max_hp) / 4.0)))
            defender.hp = int(defender.hp) + gift
            result.message += " It restored %d HP!" % gift
            return result
        power = 40 if present_roll < 40 else 80 if present_roll < 70 else 120

    if effect == "EFFECT_BIDE":
        var stored := int(attacker.volatile.get("bide_damage", 0))
        var turns := int(attacker.volatile.get("bide_turns", 0))
        if turns <= 0:
            attacker.volatile.bide_turns = 2
            attacker.volatile.bide_damage = 0
            result.message += " It is storing energy!"
            return result
        attacker.volatile.bide_turns = turns - 1
        if int(attacker.volatile.bide_turns) > 0:
            result.message += " It is storing energy!"
            return result
        attacker.volatile.erase("bide_turns")
        attacker.volatile.erase("bide_damage")
        result.damage = stored * 2
        if int(result.damage) <= 0:
            result.message += " But it failed!"
            return result
        result.message += " It unleashed energy!"
    elif effect in ["EFFECT_COUNTER", "EFFECT_MIRROR_COAT"]:
        var needed := "special" if effect == "EFFECT_MIRROR_COAT" else "physical"
        if String(attacker.volatile.get("last_damage_category", "")) != needed:
            result.message += " But it failed!"
            return result
        result.damage = int(attacker.volatile.get("last_damage_taken", 0)) * 2
        result.category = needed
        attacker.volatile.erase("last_damage_taken")
        attacker.volatile.erase("last_damage_category")
    elif effect == "EFFECT_OHKO":
        result.damage = int(defender.hp) if int(attacker.level) >= int(defender.level) else 0
        if int(result.damage) == 0:
            result.message += " It failed!"
    elif effect == "EFFECT_SUPER_FANG":
        result.damage = maxi(1, int(int(defender.hp) / 2.0))
    elif effect == "EFFECT_PSYWAVE":
        result.damage = maxi(1, rng.randi_range(0, maxi(1, int(float(attacker.level) * 1.5)) - 1))
    elif effect == "EFFECT_STATIC_DAMAGE":
        result.damage = power
    elif effect == "EFFECT_LEVEL_DAMAGE":
        result.damage = int(attacker.level)
    elif power > 0:
        var special := SourceBattleRules.move_category(actual_key) != "PHYSICAL"
        result.category = "special" if special else "physical"
        var attack_stat := effective_stat(attacker, "sp_attack" if special else "attack", field)
        var defense_stat := effective_stat(defender, "sp_defense" if special else "defense", field)
        var type_scale := effectiveness(move_type, defender.types)
        # STRUGGLE has no type: a Pokemon with nothing left can still hurt a
        # Ghost, so a battle between two that cannot touch each other ends.
        if actual_key == "STRUGGLE":
            type_scale = 1.0
        if bool(defender.volatile.get("foresight", false)) and move_type in ["NORMAL", "FIGHTING"]:
            type_scale = maxf(type_scale, 1.0)
        result.effectiveness = type_scale
        if type_scale == 0.0:
            result.message += " It had no effect."
            result.animation_move = ""
            _break_move_chain(attacker, effect)
            return result
        var hit_damages: Array[int] = []
        var hit_criticals: Array[bool] = []
        var total_damage := 0
        var planned_hits := 1
        var hit_index := 0
        while hit_index < planned_hits:
            var hit_critical := rng.randi_range(0, 255) < SourceBattleRules.critical_threshold(actual_key)
            attack_stat = effective_stat(attacker, "sp_attack" if special else "attack", field)
            defense_stat = effective_stat(defender, "sp_defense" if special else "defense", field)
            # Preserve the source's actual critical-stage comparison, including its
            # use of the target attack stage rather than the target defense stage.
            var stat_key := "sp_attack" if special else "attack"
            if hit_critical and int(attacker.stages.get(stat_key, 0)) >= int(defender.stages.get(stat_key, 0)):
                attack_stat = int(attacker.stats.get(stat_key, 1))
                defense_stat = int(defender.stats.get("sp_defense" if special else "defense", 1))
            if effect == "EFFECT_SELFDESTRUCT":
                defense_stat = maxi(1, int(defense_stat / 2))
            var double_hit := ((effect == "EFFECT_TWISTER" or actual_key == "GUST") and String(defender.volatile.get("charge_move", "")) == "FLY") or ((effect in ["EFFECT_EARTHQUAKE", "EFFECT_MAGNITUDE"]) and String(defender.volatile.get("charge_move", "")) == "DIG")
            var one_hit := SourceBattleRules.damage(int(attacker.level), power,
                attack_stat, defense_stat, bool(hit_critical), double_hit,
                (attacker.types as Array).has(move_type), type_scale, rng.randi_range(217, 255))
            # Existing optional ability/item/field systems stay intact; the source
            # integer damage core above replaces only the approved calculation.
            var extra := _field_type_modifier(move_type, field)
            extra *= _ability_damage_multiplier(attacker, defender, actual_key,
                move_type, power, String(result.category), type_scale)
            extra *= PokemonState.held_damage_multiplier(attacker, move_type)
            extra *= float(field.get("spread_modifier", 1.0))
            if (attacker.types as Array).has(move_type) and String(attacker.get("ability", "")) == "ADAPTABILITY":
                extra *= 2.0 / 1.5
            if hit_critical and String(attacker.get("ability", "")) == "SNIPER":
                extra *= 1.5
            one_hit = int(one_hit * extra)
            if special and int(defender.volatile.get("light_screen_turns", 0)) > 0:
                one_hit = maxi(1, int(one_hit / 2.0))
            elif not special and int(defender.volatile.get("reflect_turns", 0)) > 0:
                one_hit = maxi(1, int(one_hit / 2.0))
            if hit_index == 0:
                planned_hits = _hit_count(effect, rng) if type_scale > 0.0 else 1
            hit_damages.append(one_hit)
            hit_criticals.append(hit_critical)
            total_damage += one_hit
            hit_index += 1
            # Faint detection in the original action chain ends subsequent hits.
            if total_damage >= int(defender.hp):
                break
        hit_count = hit_damages.size()
        result.hits = hit_count
        result.hit_damages = hit_damages
        result.hit_criticals = hit_criticals
        result.critical = hit_criticals.has(true)
        result.damage = total_damage

    if effect in ["EFFECT_LEVEL_DAMAGE", "EFFECT_STATIC_DAMAGE", "EFFECT_PSYWAVE",
            "EFFECT_OHKO", "EFFECT_SUPER_FANG", "EFFECT_COUNTER", "EFFECT_MIRROR_COAT"]:
        var identified_ghost := bool(defender.volatile.get("foresight", false)) and move_type in ["NORMAL", "FIGHTING"]
        if effectiveness(move_type, defender.types) == 0.0 and not identified_ghost:
            result.damage = 0
            result.effectiveness = 0.0

    if effect == "EFFECT_FUTURE_SIGHT":
        if int(defender.volatile.get("future_sight_turns", 0)) > 0:
            result.message += " But it failed!"
            return result
        defender.volatile.future_sight_turns = 3
        defender.volatile.future_sight_damage = maxi(1, int(result.damage))
        defender.volatile.future_sight_source = String(attacker.species)
        result.damage = 0
        result.message += " It foresaw an attack!"
        return result

    if "FALSE_SWIPE" in effect:
        result.damage = mini(int(result.damage), maxi(0, int(defender.hp) - 1))
    if bool(defender.volatile.get("endure", false)):
        result.damage = mini(int(result.damage), maxi(0, int(defender.hp) - 1))
    if int(result.damage) >= int(defender.hp) and int(defender.hp) == int(defender.max_hp) and \
            String(defender.get("ability", "")) == "STURDY":
        result.damage = maxi(0, int(defender.hp) - 1)
        result.message += " %s endured with STURDY!" % display_name(defender)
    if int(result.damage) > 0 and String(defender.get("ability", "")) == "DISGUISE" and \
            not bool(defender.volatile.get("disguise_broken", false)):
        defender.volatile.disguise_broken = true
        result.damage = 0
        result.message += " Its DISGUISE took the hit!"

    var hit_substitute := false
    if int(result.damage) > 0 and int(defender.volatile.get("substitute_hp", 0)) > 0:
        hit_substitute = true
        defender.volatile.substitute_hp = maxi(0,
            int(defender.volatile.substitute_hp) - int(result.damage))
        result.message += " The substitute took the hit!"
        if int(defender.volatile.substitute_hp) <= 0:
            defender.volatile.erase("substitute_hp")
            result.message += " The substitute broke!"
    else:
        defender.hp = maxi(0, int(defender.hp) - int(result.damage))
        if int(result.damage) > 0:
            defender.volatile.last_damage_taken = int(result.damage)
            defender.volatile.last_damage_category = String(result.category)
            if int(defender.volatile.get("bide_turns", 0)) > 0:
                defender.volatile.bide_damage = int(defender.volatile.get("bide_damage", 0)) + int(result.damage)
            if bool(defender.volatile.get("rage", false)):
                defender.stages.attack = clampi(int(defender.stages.get("attack", 0)) + 1, -6, 6)

    result.hit_substitute = hit_substitute
    if hit_count > 1:
        result.message += " Hit %d times!" % hit_count
    var critical_hits: Array = result.get("hit_criticals", [])
    if bool(result.get("critical", false)) and (hit_count <= 1 or (not critical_hits.is_empty() and bool(critical_hits[-1]))):
        result.message += " A critical hit!"
    if float(result.effectiveness) > 1.0:
        result.message += " It's super effective!"
    elif float(result.effectiveness) == 0.0:
        result.message += " It had no effect."
    elif float(result.effectiveness) < 1.0:
        result.message += " It's not very effective!"

    _apply_move_effects(attacker, defender, effect, int(move.get("effect_chance", 0)),
        int(result.damage), rng, result, field, hit_substitute)
    if int(result.damage) > 0 and not hit_substitute and String(result.category) == "physical":
        _apply_contact_effects(attacker, defender, rng, result)
    _advance_move_chain(attacker, actual_key, effect, rng, result)
    if "SELFDESTRUCT" in effect:
        attacker.hp = 0
    if int(defender.hp) <= 0 and int(defender.volatile.get("destiny_bond_turns", 0)) > 0:
        attacker.hp = 0
        result.message += " Destiny Bond took its attacker down!"
    return result

static func _resolve_called_move(attacker: Dictionary, defender: Dictionary,
        requested_key: String, effect: String, rng: RandomNumberGenerator) -> String:
    if effect == "EFFECT_MIRROR_MOVE":
        var mirrored := String(defender.volatile.get("last_move", ""))
        return "__FAIL__" if mirrored.is_empty() or mirrored in ["MIRROR_MOVE", "STRUGGLE"] else mirrored
    if effect == "EFFECT_METRONOME":
        var choices := PokemonData.all_moves()
        for banned in ["METRONOME", "MIRROR_MOVE", "MIMIC", "SKETCH", "STRUGGLE"]:
            choices.erase(banned)
        return choices[rng.randi_range(0, choices.size() - 1)] if not choices.is_empty() else "__FAIL__"
    if effect == "EFFECT_SLEEP_TALK":
        if String(attacker.get("status", "")) != "SLEEP":
            return "__FAIL__"
        var choices: Array[String] = []
        for candidate in attacker.get("moves", []):
            var candidate_key := String(candidate)
            if candidate_key not in ["SLEEP_TALK", "BIDE", "METRONOME", "MIRROR_MOVE"]:
                choices.append(candidate_key)
        return choices[rng.randi_range(0, choices.size() - 1)] if not choices.is_empty() else "__FAIL__"
    return requested_key

static func _apply_one_off_status_move(attacker: Dictionary, defender: Dictionary,
        move_key: String, effect: String, rng: RandomNumberGenerator,
        field: Dictionary, result: Dictionary) -> bool:
    match effect:
        "EFFECT_TRANSFORM":
            if not attacker.volatile.has("original_form"):
                attacker.volatile.original_form = {
                    "species":attacker.species, "types":attacker.types.duplicate(),
                    "stats":attacker.stats.duplicate(true), "moves":attacker.moves.duplicate(),
                    "pp":attacker.pp.duplicate(true)
                }
            var original_form = attacker.volatile.original_form
            attacker.species = defender.species
            attacker.types = (defender.types as Array).duplicate()
            for stat in ["attack", "defense", "speed", "sp_attack", "sp_defense"]:
                attacker.stats[stat] = defender.stats.get(stat, attacker.stats.get(stat, 1))
            attacker.moves = (defender.moves as Array).duplicate()
            attacker.pp = {}
            for copied_move in attacker.moves:
                attacker.pp[String(copied_move)] = 5
            attacker.stages = (defender.stages as Dictionary).duplicate(true)
            attacker.volatile.original_form = original_form
            result.message += " It transformed into %s!" % display_name(defender)
            return true
        "EFFECT_MIMIC", "EFFECT_SKETCH":
            var copied := String(defender.volatile.get("last_move", ""))
            if copied.is_empty() or copied in ["MIMIC", "SKETCH", "STRUGGLE"]:
                result.message += " But it failed!"
                return true
            if not attacker.volatile.has("mimic_original_moves"):
                attacker.volatile.mimic_original_moves = (attacker.moves as Array).duplicate()
                attacker.volatile.mimic_original_pp = (attacker.pp as Dictionary).duplicate(true)
            var slot := (attacker.moves as Array).find(move_key)
            if slot >= 0:
                attacker.moves[slot] = copied
            elif not (attacker.moves as Array).has(copied):
                attacker.moves.append(copied)
            attacker.pp[copied] = 5
            result.message += " It copied %s!" % copied.replace("_", " ")
            return true
        "EFFECT_DISABLE":
            var disabled := String(defender.volatile.get("last_move", ""))
            if disabled.is_empty() or not String(defender.volatile.get("disabled_move","")).is_empty():
                result.message += " But it failed!"
            else:
                defender.volatile.disabled_move = disabled
                defender.volatile.disabled_turns = rng.randi_range(2,8)
                result.message += " %s was disabled!" % disabled.replace("_", " ")
            return true
        "EFFECT_ENCORE":
            var encored := String(defender.volatile.get("last_move", ""))
            if encored.is_empty():
                result.message += " But it failed!"
            else:
                defender.volatile.encore_move = encored
                defender.volatile.encore_turns = 3
                result.message += " %s received an encore!" % display_name(defender)
            return true
        "EFFECT_SUBSTITUTE":
            var cost := maxi(1, int(int(attacker.max_hp) / 4.0))
            if int(attacker.hp) <= cost or int(attacker.volatile.get("substitute_hp", 0)) > 0:
                result.message += " But it failed!"
            else:
                attacker.hp = int(attacker.hp) - cost
                attacker.volatile.substitute_hp = cost
                result.message += " It made a substitute!"
            return true
        "EFFECT_PERISH_SONG":
            attacker.volatile.perish_count = 4
            defender.volatile.perish_count = 4
            result.message += " Both Pokemon heard the perish song!"
            return true
        "EFFECT_DESTINY_BOND":
            attacker.volatile.destiny_bond_turns = 2
            result.message += " It is trying to take its foe down with it!"
            return true
        "EFFECT_PAIN_SPLIT":
            var shared_hp := int((int(attacker.hp) + int(defender.hp)) / 2.0)
            attacker.hp = mini(int(attacker.max_hp), shared_hp)
            defender.hp = mini(int(defender.max_hp), shared_hp)
            result.message += " The battlers shared their pain!"
            return true
        "EFFECT_BELLY_DRUM":
            var cost := int(int(attacker.max_hp) / 2.0)
            if int(attacker.hp) <= cost:
                result.message += " But it failed!"
            else:
                attacker.hp = int(attacker.hp) - cost
                attacker.stages.attack = 6
                result.message += " Its ATTACK was maximized!"
            return true
        "EFFECT_SPITE":
            var target_move := String(defender.volatile.get("last_move", ""))
            if target_move.is_empty() or not (defender.pp as Dictionary).has(target_move):
                result.message += " But it failed!"
            else:
                var lost := mini(int(defender.pp[target_move]), rng.randi_range(2, 5))
                defender.pp[target_move] = maxi(0, int(defender.pp[target_move]) - lost)
                result.message += " %s lost %d PP!" % [target_move.replace("_", " "), lost]
            return true
        "EFFECT_BATON_PASS":
            result.force_switch = "BATON_PASS"
            return true
        "EFFECT_FORCE_SWITCH":
            if _source_escape_move_fails(attacker,defender,rng):
                result.message += " But it failed!"
                return true
            result.force_switch = "FORCE_SWITCH"
            return true
        "EFFECT_TELEPORT":
            if _source_escape_move_fails(attacker,defender,rng) or bool(attacker.volatile.get("mean_look",false)):
                result.message += " But it failed!"
                return true
            result.force_switch = "TELEPORT"
            return true
        "EFFECT_RAIN_DANCE":
            result.weather = "RAIN"
            result.message += " Rain began to fall!"
            return true
        "EFFECT_SUNNY_DAY":
            result.weather = "SUN"
            result.message += " The sunlight turned harsh!"
            return true
        "EFFECT_SANDSTORM":
            # Java rejects an already active sandstorm; rain/sun may refresh.
            if String(field.get("weather", "")) == "SANDSTORM":
                result.message += " But it failed!"
                return true
            result.weather = "SANDSTORM"
            result.message += " A sandstorm brewed!"
            return true
        "EFFECT_CONVERSION":
            for candidate in attacker.get("moves", []):
                if String(candidate) == move_key:
                    continue
                var new_type := String(PokemonData.move_info(String(candidate)).get("type", "NORMAL"))
                attacker.types = [new_type]
                result.message += " It became %s-type!" % new_type
                return true
            result.message += " But it failed!"
            return true
        "EFFECT_CONVERSION2":
            var previous := PokemonData.move_info(String(defender.volatile.get("last_move", "")))
            if previous.is_empty():
                result.message += " But it failed!"
            else:
                attacker.types = [_resistant_type(String(previous.get("type", "NORMAL")), rng)]
                result.message += " Its type changed!"
            return true
        "EFFECT_DEFENSE_CURL":
            attacker.stages.defense = clampi(int(attacker.stages.get("defense", 0)) + 1, -6, 6)
            attacker.volatile.defense_curl = true
            result.message += " Its DEFENSE rose!"
            return true
        "EFFECT_FOCUS_ENERGY":
            attacker.volatile.focus_energy = true
            result.message += " It is getting pumped!"
            return true
        "EFFECT_MIST":
            attacker.volatile.mist_turns = 5
            result.message += " It became shrouded in mist!"
            return true
        "EFFECT_REFLECT", "EFFECT_LIGHT_SCREEN", "EFFECT_SAFEGUARD":
            var timer_key := "reflect_turns" if effect == "EFFECT_REFLECT" else \
                "light_screen_turns" if effect == "EFFECT_LIGHT_SCREEN" else "safeguard_turns"
            # Battle.getAttackAction leaves the existing counter unchanged.
            if int(attacker.volatile.get(timer_key, 0)) > 0:
                result.message += " But it failed!"
                return true
            attacker.volatile[timer_key] = 5
            if effect != "EFFECT_SAFEGUARD":
                result.message += " Its %s rose!" % ("DEFENSE" if effect == "EFFECT_REFLECT" else "SPCL.DEF")
                return true
            result.message += " It is protected by Safeguard!"
            return true
        "EFFECT_PSYCH_UP":
            attacker.stages = (defender.stages as Dictionary).duplicate(true)
            result.message += " It copied the foe's stat changes!"
            return true
        "EFFECT_SPIKES":
            var side := "enemy_spikes" if bool(field.get("attacker_is_player", false)) else "player_spikes"
            # The Java field stores a single boolean, not three layers.
            if int(field.get(side, 0)) > 0:
                result.message += " But it failed!"
                return true
            field[side] = 1
            result.message += " Spikes were scattered!"
            return true
        "EFFECT_CURSE":
            if (attacker.types as Array).has("GHOST"):
                attacker.hp = maxi(0, int(attacker.hp) - maxi(1, int(int(attacker.max_hp) / 2.0)))
                defender.volatile.cursed = true
                result.message += " It laid a curse!"
            else:
                attacker.stages.attack = clampi(int(attacker.stages.get("attack", 0)) + 1, -6, 6)
                attacker.stages.defense = clampi(int(attacker.stages.get("defense", 0)) + 1, -6, 6)
                attacker.stages.speed = clampi(int(attacker.stages.get("speed", 0)) - 1, -6, 6)
                result.message += " Its ATTACK and DEFENSE rose!"
            return true
        "EFFECT_SPLASH":
            result.message += " But nothing happened!"
            return true
    return false

static func _targets_opponent(effect: String) -> bool:
    return effect in ["EFFECT_DISABLE", "EFFECT_ENCORE", "EFFECT_LEECH_SEED",
        "EFFECT_MEAN_LOOK", "EFFECT_SLEEP", "EFFECT_POISON", "EFFECT_TOXIC",
        "EFFECT_PARALYZE", "EFFECT_CONFUSE", "EFFECT_ATTRACT", "EFFECT_NIGHTMARE",
        "EFFECT_FORCE_SWITCH", "EFFECT_SPIKES"]

static func _source_escape_move_fails(attacker: Dictionary, defender: Dictionary, rng: RandomNumberGenerator) -> bool:
    if int(attacker.level)>=int(defender.level): return false
    var threshold := int(ceil(float(int(int(defender.level)/4))/float(int(defender.level)+int(attacker.level)+1)*100.0))
    return rng.randi_range(0,99)<=threshold

static func _hit_count(effect: String, rng: RandomNumberGenerator) -> int:
    if effect == "EFFECT_BEAT_UP":
        return 3
    if "DOUBLE_HIT" in effect:
        return 2
    if "TRIPLE" in effect:
        return 3
    if "MULTI_HIT" in effect:
        var roll := rng.randi_range(0, 255)
        return 2 if roll < 96 else 3 if roll < 192 else 4 if roll < 224 else 5
    return 1

static func _dynamic_power(attacker: Dictionary, defender: Dictionary,
        effect: String, base_power: int, rng: RandomNumberGenerator,
        result: Dictionary) -> int:
    match effect:
        "EFFECT_RETURN":
            return maxi(1, int(int(attacker.get("friendship", 128)) * 10.0 / 25.0))
        "EFFECT_FRUSTRATION":
            return maxi(1, int((255 - int(attacker.get("friendship", 128))) * 10.0 / 25.0))
        "EFFECT_REVERSAL":
            var ratio := float(attacker.hp) / maxf(1.0, float(attacker.max_hp))
            if ratio <= 0.0417: return 200
            if ratio <= 0.1042: return 150
            if ratio <= 0.2083: return 100
            if ratio <= 0.3542: return 80
            if ratio <= 0.6875: return 40
            return 20
        "EFFECT_MAGNITUDE":
            var roll := rng.randi_range(1, 100)
            var magnitude := 4
            var power := 10
            if roll > 95:
                magnitude = 10
                power = 150
            elif roll > 85:
                magnitude = 9
                power = 110
            elif roll > 65:
                magnitude = 8
                power = 90
            elif roll > 35:
                magnitude = 7
                power = 70
            elif roll > 15:
                magnitude = 6
                power = 50
            elif roll > 5:
                magnitude = 5
                power = 30
            result.message += " Magnitude %d!" % magnitude
            return power
        "EFFECT_ROLLOUT":
            var rollout_count := clampi(int(attacker.volatile.get("rollout_count", 0)), 0, 4)
            var curl_bonus := 2 if bool(attacker.volatile.get("defense_curl", false)) else 1
            return base_power * int(pow(2.0, rollout_count)) * curl_bonus
        "EFFECT_FURY_CUTTER":
            return mini(160, base_power * int(pow(2.0,
                clampi(int(attacker.volatile.get("fury_cutter_count", 0)), 0, 3))))
        "EFFECT_CRUSH_GRIP":
            return 1 + int(120 * int(defender.hp) / maxi(1, int(defender.max_hp)))
        "EFFECT_DRAGON_ENERGY":
            return maxi(1, int(base_power * int(attacker.hp) / maxi(1, int(attacker.max_hp))))
        "EFFECT_STOMP":
            return base_power * 2 if bool(defender.volatile.get("minimized", false)) else base_power
    return base_power

static func _hidden_power_type(pokemon: Dictionary) -> String:
    var types := ["FIGHTING", "FLYING", "POISON", "GROUND", "ROCK", "BUG",
        "GHOST", "STEEL", "FIRE", "WATER", "GRASS", "ELECTRIC", "PSYCHIC",
        "ICE", "DRAGON", "DARK"]
    return types[absi(String(pokemon.species).hash()) % types.size()]

static func _resistant_type(incoming_type: String, rng: RandomNumberGenerator) -> String:
    var choices: Array[String] = []
    for candidate in TYPE_EFFECT.keys():
        if float((TYPE_EFFECT.get(incoming_type, {}) as Dictionary).get(String(candidate), 1.0)) < 1.0:
            choices.append(String(candidate))
    return choices[rng.randi_range(0, choices.size() - 1)] if not choices.is_empty() else "NORMAL"

static func _field_type_modifier(move_type: String, field: Dictionary) -> float:
    var modifier := 1.0
    match String(field.get("weather", "")):
        "RAIN":
            if move_type == "WATER": modifier *= 1.5
            elif move_type == "FIRE": modifier *= 0.5
        "SUN":
            if move_type == "FIRE": modifier *= 1.5
            elif move_type == "WATER": modifier *= 0.5
    match String(field.get("terrain", "")):
        "GRASSY":
            if move_type == "GRASS": modifier *= 1.2
        "AQUATIC":
            if move_type in ["WATER", "ELECTRIC"]: modifier *= 1.2
        "SANDY":
            if move_type in ["GROUND", "ROCK"]: modifier *= 1.1
    return modifier

static func _break_move_chain(attacker: Dictionary, effect: String) -> void:
    if effect == "EFFECT_ROLLOUT":
        attacker.volatile.erase("rollout_count")
        attacker.volatile.erase("locked_move")
        attacker.volatile.erase("locked_turns")
    elif effect == "EFFECT_FURY_CUTTER":
        attacker.volatile.erase("fury_cutter_count")
    elif effect == "EFFECT_RAMPAGE":
        attacker.volatile.erase("locked_move")
        attacker.volatile.erase("locked_turns")

static func _advance_move_chain(attacker: Dictionary, move_key: String,
        effect: String, rng: RandomNumberGenerator, result: Dictionary) -> void:
    if effect == "EFFECT_ROLLOUT":
        var count := int(attacker.volatile.get("rollout_count", 0)) + 1
        if count >= 5:
            attacker.volatile.erase("rollout_count")
            attacker.volatile.erase("locked_move")
            attacker.volatile.erase("locked_turns")
        else:
            attacker.volatile.rollout_count = count
            attacker.volatile.locked_move = move_key
            attacker.volatile.locked_turns = 1
    elif effect == "EFFECT_FURY_CUTTER":
        attacker.volatile.fury_cutter_count = mini(3,
            int(attacker.volatile.get("fury_cutter_count", 0)) + 1)
    elif effect == "EFFECT_RAMPAGE":
        if int(attacker.volatile.get("locked_turns", 0)) <= 0:
            attacker.volatile.locked_move = move_key
            attacker.volatile.locked_turns = rng.randi_range(2, 3)
        attacker.volatile.locked_turns = int(attacker.volatile.locked_turns) - 1
        if int(attacker.volatile.locked_turns) <= 0:
            attacker.volatile.erase("locked_move")
            attacker.volatile.erase("locked_turns")
            attacker.volatile.confuse_turns = rng.randi_range(2, 5)
            result.message += " It became confused!"

static func can_act(pokemon: Dictionary, rng: RandomNumberGenerator,
        _move_effect: String = "", move_key: String = "") -> String:
    var name := display_name(pokemon)
    if bool(pokemon.volatile.get("flinch", false)):
        pokemon.volatile.erase("flinch")
        return "%s flinched!" % name
    if bool(pokemon.volatile.get("recharge", false)):
        pokemon.volatile.erase("recharge")
        return "%s must recharge!" % name
    # Java checks Disable before major status and releases a disabled charge/lock.
    if not move_key.is_empty() and String(pokemon.volatile.get("disabled_move", "")) == move_key:
        for key in ["charge_move", "semi_invulnerable", "locked_move", "locked_turns", "rollout_count"]:
            pokemon.volatile.erase(key)
        return "%s's %s is disabled!" % [name, move_key.replace("_", " ")]
    # Battle.getAttackAction checks major status before confusion/attraction.
    if String(pokemon.get("status", "")) == "SLEEP":
        pokemon.status_counter = int(pokemon.get("status_counter", 1)) - 1
        if int(pokemon.status_counter) > 0:
            if _move_effect not in ["EFFECT_SLEEP_TALK", "EFFECT_SNORE"]:
                return "%s is fast asleep." % name
        else:
            pokemon.status = ""
    elif String(pokemon.get("status", "")) == "PARALYSIS":
        if rng.randi_range(0, 255) < 128:
            return "%s is fully paralyzed!" % name
    elif String(pokemon.get("status", "")) == "FREEZE":
        if _move_effect not in ["EFFECT_FLAME_WHEEL", "EFFECT_SACRED_FIRE"] and rng.randi_range(0,255) >= 51:
            return "%s is frozen solid!" % name
        pokemon.status = ""
    # Java sorts volatile statuses alphabetically: attraction precedes confusion.
    if bool(pokemon.volatile.get("attract", false)) and rng.randi_range(0,255) < 128:
        return "%s is immobilized by love!" % name
    var confuse_turns := int(pokemon.volatile.get("confuse_turns", 0))
    if confuse_turns > 0:
        pokemon.volatile.confuse_turns = confuse_turns - 1
        if confuse_turns > 1 and rng.randi_range(0,255) < 128:
            # confusion_hit is constructed outside the split lookup in 0.8.11:
            # category is subsequently assigned, but isPhysical stays false.
            var damage := SourceBattleRules.damage(int(pokemon.level),40,
                effective_stat(pokemon,"sp_attack"),effective_stat(pokemon,"sp_defense"),
                false,false,(pokemon.types as Array).has("NORMAL"),
                effectiveness("NORMAL",pokemon.types),rng.randi_range(217,255))
            pokemon.hp = maxi(0, int(pokemon.hp) - damage)
            return "%s hurt itself in confusion!" % name
    return ""

static func _apply_move_effects(attacker: Dictionary, defender: Dictionary,
        effect: String, chance: int, damage: int, rng: RandomNumberGenerator,
        result: Dictionary, field: Dictionary, target_blocked: bool) -> void:
    if not target_blocked:
        _apply_status_effect(defender, effect, chance, rng, String(result.get("move_type","")))
        _apply_stat_effect(attacker, defender, effect, chance, rng, result)
    if "RESET_STATS" in effect:
        attacker.stages = default_stages()
        defender.stages = default_stages()
        result.message += " All stat changes were eliminated!"
    if ("LEECH_HIT" in effect or effect == "EFFECT_DRAINING_KISS") and damage > 0:
        var healed := mini(int(attacker.max_hp) - int(attacker.hp), mini(int(result.get("defender_hp_before", defender.hp)), maxi(1, int(3 * damage / 4) if effect == "EFFECT_DRAINING_KISS" else int(damage / 2))))
        attacker.hp = int(attacker.hp) + healed
        result.message += " Health was restored!"
    elif effect == "EFFECT_HEAL" or effect in ["EFFECT_MORNING_SUN", "EFFECT_SYNTHESIS", "EFFECT_MOONLIGHT"]:
        var amount := int(int(attacker.max_hp) / 2)
        if effect in ["EFFECT_MORNING_SUN", "EFFECT_SYNTHESIS", "EFFECT_MOONLIGHT"]:
            amount = int(int(attacker.max_hp) / 4)
            var matching_time := String(field.get("time_of_day","day")) == ("night" if effect == "EFFECT_MOONLIGHT" else "day")
            if matching_time: amount *= 2
        var healed := mini(int(attacker.max_hp) - int(attacker.hp), amount)
        attacker.hp = int(attacker.hp) + healed
        result.message += " Health was restored!"
    if ("RECOIL" in effect or String(result.get("animation_move","")) == "FLARE_BLITZ") and damage > 0:
        var move_key := String(result.get("animation_move",""))
        var divisor := 3 if move_key in ["BRAVE_BIRD","FLARE_BLITZ","VOLT_TACKLE","WOOD_HAMMER"] else 2 if move_key in ["HEAD_SMASH","LIGHT_OF_RUIN"] else 4
        attacker.hp = maxi(0, int(attacker.hp) - int(damage / divisor))
        result.message += " It was hurt by recoil!"
    if not target_blocked and "CONFUSE" in effect and (chance == 0 or SourceBattleRules.effect_roll(chance,rng)):
        if int(defender.volatile.get("confuse_turns", 0)) <= 0:
            defender.volatile.confuse_turns = rng.randi_range(1, 5)
        elif not "HIT" in effect:
            result.message += " But it failed!"
    if not target_blocked and "FLINCH" in effect and SourceBattleRules.effect_roll(maxi(1,chance),rng):
        defender.volatile.flinch = true
    if not target_blocked and "TRAP_TARGET" in effect and int(defender.volatile.get("trap_turns", 0)) <= 0:
        defender.volatile.trap_turns = rng.randi_range(2, 5)
        defender.volatile.trap_binding = String(attacker.get("held_item", "")) == "BINDING BAND"
        defender.volatile.trap_move = String(result.get("animation_move", ""))
        defender.volatile.trap_source_slot = int(field.get("attacker_slot", 0))
        defender.volatile.trap_source_player = bool(field.get("attacker_is_player", false))
        var trap_criticals: Array = result.get("hit_criticals", [])
        defender.volatile.trap_critical = bool(trap_criticals[-1]) if not trap_criticals.is_empty() else false
    if effect == "EFFECT_MEAN_LOOK" and not target_blocked:
        defender.volatile.mean_look = true
    if effect == "EFFECT_PROTECT":
        attacker.volatile.protect = true
    elif effect == "EFFECT_ENDURE":
        attacker.volatile.endure = true
    elif effect == "EFFECT_LIGHT_SCREEN":
        attacker.volatile.light_screen_turns = 5
    elif effect == "EFFECT_REFLECT":
        attacker.volatile.reflect_turns = 5
    elif effect == "EFFECT_LOCK_ON":
        attacker.volatile.lock_on = true
    elif effect == "EFFECT_LEECH_SEED" and not target_blocked:
        defender.volatile.leech_seed = true
    elif effect == "EFFECT_HEAL_BELL":
        attacker.status = ""
        result.heal_party = true
        result.message += " It was cured!"
    elif effect == "EFFECT_RAPID_SPIN":
        var own_side := "player_spikes" if bool(field.get("attacker_is_player", false)) else "enemy_spikes"
        if int(field.get(own_side, 0)) > 0:
            field[own_side] = 0
            result.message += " It blew away SPIKES!"
        # Java clears trappedBy/trapCounter; Mean Look is a separate escape lock.
        if int(attacker.volatile.get("trap_turns", 0)) > 0:
            attacker.volatile.erase("trap_turns")
            attacker.volatile.erase("trap_binding")
            attacker.volatile.erase("trap_move")
            attacker.volatile.erase("trap_critical")
            attacker.volatile.erase("trap_source_slot")
            attacker.volatile.erase("trap_source_player")
            result.message += " It broke free of traps!"
    elif effect == "EFFECT_ATTRACT" and not target_blocked:
        var attacker_gender := String(attacker.get("gender", "genderless"))
        var defender_gender := String(defender.get("gender", "genderless"))
        if attacker_gender in ["male", "female"] and defender_gender in ["male", "female"] and \
                attacker_gender != defender_gender and String(defender.get("ability", "")) != "OBLIVIOUS":
            defender.volatile.attract = true
        else:
            result.message += " But it failed!"
    elif effect == "EFFECT_NIGHTMARE" and not target_blocked:
        if String(defender.get("status", "")) == "SLEEP":
            defender.volatile.nightmare = true
        else:
            result.message += " But it failed!"
    elif effect == "EFFECT_SWAGGER" and not target_blocked:
        defender.stages.attack = clampi(int(defender.stages.get("attack", 0)) + 2, -6, 6)
        defender.volatile.confuse_turns = rng.randi_range(1, 5)
    elif effect == "EFFECT_RAGE":
        attacker.volatile.rage = true
    elif effect == "EFFECT_HYPER_BEAM":
        attacker.volatile.recharge = true
    elif effect == "EFFECT_FLAME_WHEEL":
        if String(attacker.get("status", "")) == "FREEZE":
            attacker.status = ""
        if not target_blocked and rng.randi_range(1, 100) <= 10:
            _set_status(defender, "BURN", rng)
    elif effect == "EFFECT_SACRED_FIRE" and not target_blocked:
        if rng.randi_range(1, 100) <= 50:
            _set_status(defender, "BURN", rng)
    elif effect == "EFFECT_TRI_ATTACK" and not target_blocked and rng.randi_range(1, 100) <= 20:
        _set_status(defender,
            ["BURN", "FREEZE", "PARALYSIS"][rng.randi_range(0, 2)], rng)
    elif effect == "EFFECT_THIEF" and not target_blocked:
        var held_item := String(defender.get("held_item", ""))
        if String(attacker.get("held_item", "")).is_empty() and not held_item.is_empty():
            attacker.held_item = held_item
            defender.held_item = ""
            result.message += " It stole %s!" % held_item
    elif effect == "EFFECT_PAY_DAY":
        result.pay_day = maxi(1, int(attacker.level) * 5)
        result.message += " Coins scattered everywhere!"
    elif effect == "EFFECT_FORESIGHT" and not target_blocked:
        defender.volatile.foresight = true
        defender.stages.evasion = 0
        result.message += " It was identified!"
    elif effect == "EFFECT_THUNDER" and not target_blocked:
        if SourceBattleRules.effect_roll(maxi(30,chance),rng):
            _set_status(defender, "PARALYSIS", rng)

static func _apply_status_effect(target: Dictionary, effect: String, chance: int,
        rng: RandomNumberGenerator, move_type: String = "") -> void:
    if not String(target.get("status", "")).is_empty():
        return
    if int(target.volatile.get("safeguard_turns", 0)) > 0:
        return
    var status := ""
    if "BURN" in effect: status = "BURN"
    elif "FREEZE" in effect: status = "FREEZE"
    elif "PARALYZE" in effect: status = "PARALYSIS"
    elif "TOXIC" in effect or "POISON" in effect: status = "POISON"
    elif "SLEEP" in effect: status = "SLEEP"
    if not status.is_empty() and (not "HIT" in effect or SourceBattleRules.effect_roll(chance,rng)):
        var target_types: Array = target.get("types", [])
        if status == "BURN" and move_type == "FIRE" and target_types.has("FIRE"):
            return
        if status == "FREEZE" and move_type == "ICE" and target_types.has("ICE"):
            return
        if status == "POISON" and move_type == "POISON" and (target_types.has("POISON") or target_types.has("STEEL")):
            return
        if move_type == "ELECTRIC" and target_types.has("ELECTRIC"):
            return
        _set_status(target, status, rng, true)
        if "TOXIC" in effect:
            target.toxic_counter = 1

static func _set_status(target: Dictionary, status: String,
        rng: RandomNumberGenerator, source_type_checked: bool = false) -> void:
    if not String(target.get("status", "")).is_empty():
        return
    var target_types: Array = target.get("types", [])
    var ability := String(target.get("ability", ""))
    if (status == "BURN" and ability == "WATER VEIL") or \
            (status == "FREEZE" and ability == "MAGMA ARMOR") or \
            (status == "PARALYSIS" and ability == "LIMBER") or \
            (status == "POISON" and ability == "IMMUNITY") or \
            (status == "SLEEP" and ability in ["INSOMNIA", "VITAL SPIRIT"]):
        return
    if not source_type_checked and status == "BURN" and target_types.has("FIRE"):
        return
    if not source_type_checked and status == "FREEZE" and target_types.has("ICE"):
        return
    if not source_type_checked and status == "POISON" and (target_types.has("POISON") or target_types.has("STEEL")):
        return
    target.status = status
    if status == "SLEEP":
        target.status_counter = rng.randi_range(1, 5)

static func _apply_stat_effect(attacker: Dictionary, defender: Dictionary,
        effect: String, chance: int, rng: RandomNumberGenerator,
        result: Dictionary) -> void:
    var target := attacker if "_UP" in effect else defender
    var amount := 2 if "_UP_2" in effect or "_DOWN_2" in effect else 1
    if "_DOWN" in effect:
        amount = -amount
    var stat := ""
    if "SP_ATK" in effect: stat = "sp_attack"
    elif "SP_DEF" in effect: stat = "sp_defense"
    elif "ATTACK" in effect: stat = "attack"
    elif "DEFENSE" in effect: stat = "defense"
    elif "SPEED" in effect: stat = "speed"
    elif "ACCURACY" in effect: stat = "accuracy"
    elif "EVASION" in effect: stat = "evasion"
    elif "ALL" in effect: stat = "all"
    if stat.is_empty() or (not "_UP" in effect and not "_DOWN" in effect):
        return
    if "HIT" in effect:
        var succeeds := SourceBattleRules.effect_roll(chance,rng)
        if not succeeds and (target == defender or String(result.get("move","")) == "ANCIENTPOWER"):
            return
    if stat == "all":
        # Original gen2ApplyStatStage uses short-circuit OR: only the first
        # stat that can change is updated, in this exact order.
        for candidate in ["attack","defense","sp_attack","sp_defense","speed"]:
            var next_stage := int(target.stages.get(candidate,0))+amount
            if next_stage >= -6 and next_stage <= 6:
                target.stages[candidate]=next_stage
                result.message += " Its stats went up!"
                break
        return
    if target == defender and amount < 0 and int(defender.volatile.get("mist_turns", 0)) > 0:
        result.message += " Mist prevented the stat loss!"
        return
    var old_stage := int(target.stages.get(stat, 0))
    target.stages[stat] = old_stage + amount if old_stage + amount >= -6 and old_stage + amount <= 6 else old_stage
    if int(target.stages[stat]) != old_stage:
        result.message += " %s's %s %s!" % [display_name(target),
            stat.replace("_", " ").to_upper(), "rose" if amount > 0 else "fell"]

static func source_trap_damage(source: Dictionary, target: Dictionary,
        move_key: String, critical: bool, rng: RandomNumberGenerator) -> int:
    # Java CheckTrapped reruns gen2CalcDamage; Thunder Cage is the sole flat-HP exception.
    if move_key == "THUNDER_CAGE":
        return int(int(target.max_hp) / 8)
    var move := PokemonData.move_info(move_key)
    if move.is_empty(): return 0
    var special := SourceBattleRules.move_category(move_key) != "PHYSICAL"
    var attack_key := "sp_attack" if special else "attack"
    var defense_key := "sp_defense" if special else "defense"
    var attack_stat := effective_stat(source, attack_key)
    var defense_stat := effective_stat(target, defense_key)
    if critical and int(source.stages.get(attack_key, 0)) >= int(target.stages.get(attack_key, 0)):
        attack_stat = int(source.stats.get(attack_key, 1))
        defense_stat = int(target.stats.get(defense_key, 1))
    var move_type := String(move.get("type", "NORMAL"))
    return SourceBattleRules.damage(int(source.level), int(move.get("power", 0)),
        attack_stat, defense_stat, critical, false, (source.types as Array).has(move_type),
        effectiveness(move_type, target.types), rng.randi_range(217, 255))

static func after_action_residual(pokemon: Dictionary) -> String:
    pokemon.volatile.action_residual_applied = true
    if int(pokemon.hp) <= 0: return ""
    var status := String(pokemon.get("status", ""))
    var ability := String(pokemon.get("ability", ""))
    var damage := 0
    var healing := 0
    if status == "BURN":
        damage = maxi(1, int(int(pokemon.max_hp) / 8))
    elif status == "POISON":
        if ability == "POISON HEAL":
            healing = maxi(1, int(int(pokemon.max_hp) / 8))
        elif int(pokemon.get("toxic_counter", 0)) > 0:
            damage = maxi(1, int(int(pokemon.max_hp) * int(pokemon.toxic_counter) / 16))
            pokemon.toxic_counter = int(pokemon.toxic_counter) + 1
        else:
            damage = maxi(1, int(int(pokemon.max_hp) / 8))
    if bool(pokemon.volatile.get("cursed", false)):
        damage += maxi(1, int(int(pokemon.max_hp) / 4))
    if ability == "MAGIC GUARD": damage = 0
    if damage > 0:
        pokemon.hp = maxi(0, int(pokemon.hp) - damage)
        return "%s was hurt for %d HP!" % [display_name(pokemon), damage]
    if healing > 0:
        pokemon.hp = mini(int(pokemon.max_hp), int(pokemon.hp) + healing)
        return "%s restored HP with POISON HEAL!" % display_name(pokemon)
    return ""

static func end_turn(pokemon: Dictionary, field: Dictionary = {},
        opponent: Dictionary = {}, rng: RandomNumberGenerator = null) -> String:
    var messages: Array[String] = []
    var damage := 0
    var healing := 0
    var status := String(pokemon.get("status", ""))
    var ability := String(pokemon.get("ability", ""))
    var residual_applied := bool(pokemon.volatile.get("action_residual_applied", false))
    pokemon.volatile.erase("action_residual_applied")
    if not residual_applied and status == "BURN":
        damage = maxi(1, int(int(pokemon.max_hp) / 8.0))
    elif not residual_applied and status == "POISON":
        if ability == "POISON HEAL":
            healing += mini(int(pokemon.max_hp) - int(pokemon.hp),
                maxi(1, int(int(pokemon.max_hp) / 8.0)))
        elif int(pokemon.get("toxic_counter", 0)) > 0:
            damage = maxi(1, int(int(pokemon.max_hp) * int(pokemon.toxic_counter) / 16.0))
            pokemon.toxic_counter = int(pokemon.toxic_counter) + 1
        else:
            damage = maxi(1, int(int(pokemon.max_hp) / 8.0))
    var trap_turns := int(pokemon.volatile.get("trap_turns", 0))
    if trap_turns > 0:
        var trap_divisor := 6.0 if bool(pokemon.volatile.get("trap_binding", false)) else 8.0
        var trap_move := String(pokemon.volatile.get("trap_move", ""))
        if not opponent.is_empty() and rng != null and not trap_move.is_empty() and not bool(pokemon.volatile.get("trap_binding", false)):
            damage += source_trap_damage(opponent, pokemon, trap_move,
                bool(pokemon.volatile.get("trap_critical", false)), rng)
        else:
            damage += maxi(1, int(int(pokemon.max_hp) / trap_divisor))
        pokemon.volatile.trap_turns = trap_turns - 1
        if int(pokemon.volatile.trap_turns) <= 0:
            pokemon.volatile.erase("trap_binding")
            pokemon.volatile.erase("trap_move")
            pokemon.volatile.erase("trap_critical")
            pokemon.volatile.erase("trap_source_slot")
            pokemon.volatile.erase("trap_source_player")
    if bool(pokemon.volatile.get("leech_seed", false)):
        damage += maxi(1, int(int(pokemon.max_hp) / 8.0))
    if bool(pokemon.volatile.get("nightmare", false)) and status == "SLEEP":
        damage += maxi(1, int(int(pokemon.max_hp) / 4.0))
    if not residual_applied and bool(pokemon.volatile.get("cursed", false)):
        damage += maxi(1, int(int(pokemon.max_hp) / 4.0))
    if String(field.get("weather", "")) == "SANDSTORM":
        var types: Array = pokemon.get("types", [])
        # Java CheckWeather expires the weather before applying its damage.
        if int(field.get("weather_turns", 2)) > 1 and not types.has("ROCK") and not types.has("GROUND") and not types.has("STEEL"):
            damage += int(int(pokemon.max_hp) / 8.0)
    if String(field.get("terrain", "")) == "GRASSY" and int(pokemon.hp) > 0:
        healing = mini(int(pokemon.max_hp) - int(pokemon.hp),
            maxi(1, int(int(pokemon.max_hp) / 16.0)))

    var future_turns := int(pokemon.volatile.get("future_sight_turns", 0))
    if future_turns > 0:
        pokemon.volatile.future_sight_turns = future_turns - 1
        if int(pokemon.volatile.future_sight_turns) <= 0:
            var future_damage := maxi(1, int(pokemon.volatile.get("future_sight_damage", 1)))
            damage += future_damage
            messages.append("The future attack struck %s!" % display_name(pokemon))
            for key in ["future_sight_turns", "future_sight_damage", "future_sight_source"]:
                pokemon.volatile.erase(key)

    var perish_count := int(pokemon.volatile.get("perish_count", 0))
    if perish_count > 0:
        perish_count -= 1
        pokemon.volatile.perish_count = perish_count
        if perish_count <= 0:
            pokemon.hp = 0
            messages.append("%s's perish count fell to zero!" % display_name(pokemon))
        else:
            messages.append("%s's perish count is %d!" % [display_name(pokemon), perish_count])
    pokemon.volatile.erase("protect")
    pokemon.volatile.erase("endure")
    pokemon.volatile.erase("flinch")
    for timed_key in ["light_screen_turns", "reflect_turns", "mist_turns",
            "safeguard_turns", "encore_turns", "destiny_bond_turns"]:
        if int(pokemon.volatile.get(timed_key, 0)) > 0:
            pokemon.volatile[timed_key] = int(pokemon.volatile[timed_key]) - 1
            if int(pokemon.volatile[timed_key]) <= 0:
                pokemon.volatile.erase(timed_key)
                if timed_key == "disabled_turns":
                    pokemon.volatile.erase("disabled_move")
                elif timed_key == "encore_turns":
                    pokemon.volatile.erase("encore_move")
    if ability == "MAGIC GUARD":
        damage = 0
    if ability == "ICE BODY" and String(field.get("weather", "")) in ["HAIL", "SNOW"]:
        healing += mini(int(pokemon.max_hp) - int(pokemon.hp),
            maxi(1, int(int(pokemon.max_hp) / 16.0)))
    if ability == "SHED SKIN" and not status.is_empty() and posmod(
            int(pokemon.get("personality", 0)) + int(field.get("turn_count", 0)), 3) == 0:
        pokemon.status = ""
        pokemon.status_counter = 0
        pokemon.toxic_counter = 0
        messages.append("%s's SHED SKIN cured its status!" % display_name(pokemon))
    var held_message := _apply_held_item_end_turn(pokemon)
    if not held_message.is_empty():
        messages.append(held_message)
    pokemon.volatile.erase("last_damage_taken")
    pokemon.volatile.erase("last_damage_category")
    if damage > 0 and int(pokemon.hp) > 0:
        pokemon.hp = maxi(0, int(pokemon.hp) - damage)
        messages.append("%s was hurt for %d HP!" % [display_name(pokemon), damage])
    if healing > 0 and int(pokemon.hp) > 0:
        pokemon.hp = mini(int(pokemon.max_hp), int(pokemon.hp) + healing)
        messages.append("%s recovered %d HP from the terrain!" % [display_name(pokemon), healing])
    return " ".join(messages)

static func _apply_held_item_end_turn(pokemon: Dictionary) -> String:
    var item := String(pokemon.get("held_item", ""))
    if item.is_empty() or int(pokemon.get("hp", 0)) <= 0:
        return ""
    var status := String(pokemon.get("status", ""))
    var cured := false
    if item == "LUM BERRY" and (not status.is_empty() or int(pokemon.volatile.get("confuse_turns", 0)) > 0):
        pokemon.status = ""
        pokemon.status_counter = 0
        pokemon.toxic_counter = 0
        pokemon.volatile.erase("confuse_turns")
        cured = true
    elif (item == "PECHA BERRY" and status == "POISON") or \
            (item == "CHERI BERRY" and status == "PARALYSIS") or \
            (item == "ASPEAR BERRY" and status == "FREEZE") or \
            (item == "CHESTO BERRY" and status == "SLEEP") or \
            (item == "RAWST BERRY" and status == "BURN"):
        pokemon.status = ""
        pokemon.status_counter = 0
        pokemon.toxic_counter = 0
        cured = true
    elif item == "PERSIM BERRY" and int(pokemon.volatile.get("confuse_turns", 0)) > 0:
        pokemon.volatile.erase("confuse_turns")
        cured = true
    if cured:
        pokemon.held_item = ""
        return "%s consumed its %s and was cured!" % [display_name(pokemon), item]
    var heal_amount := 0
    if int(pokemon.hp) * 2 <= int(pokemon.max_hp):
        if item in ["BERRY JUICE", "RAGECANDYBAR"]:
            heal_amount = 20
        elif item == "MOOMOO MILK":
            heal_amount = 100
    if heal_amount > 0:
        var restored := mini(heal_amount, int(pokemon.max_hp) - int(pokemon.hp))
        pokemon.hp = int(pokemon.hp) + restored
        pokemon.held_item = ""
        return "%s consumed its %s and restored %d HP!" % [
            display_name(pokemon), item, restored]
    return ""

static func switch_in_message(pokemon: Dictionary, opponents: Array,
        field: Dictionary) -> String:
    var ability := String(pokemon.get("ability", ""))
    var messages: Array[String] = []
    match ability:
        "DRIZZLE":
            field.weather = "RAIN"
            field.weather_turns = 5
            messages.append("%s's DRIZZLE made it rain!" % display_name(pokemon))
        "DROUGHT":
            field.weather = "SUN"
            field.weather_turns = 5
            messages.append("%s's DROUGHT intensified the sun!" % display_name(pokemon))
        "SAND STREAM":
            field.weather = "SANDSTORM"
            field.weather_turns = 5
            messages.append("%s whipped up a sandstorm!" % display_name(pokemon))
        "SNOW WARNING":
            field.weather = "SNOW"
            field.weather_turns = 5
            messages.append("%s made it snow!" % display_name(pokemon))
        "INTIMIDATE":
            var lowered := 0
            for raw_opponent in opponents:
                if typeof(raw_opponent) != TYPE_DICTIONARY:
                    continue
                var opponent := raw_opponent as Dictionary
                if int(opponent.get("hp", 0)) <= 0 or String(opponent.get("ability", "")) == "CLEAR BODY":
                    continue
                opponent.stages.attack = clampi(int(opponent.stages.get("attack", 0)) - 1, -6, 6)
                lowered += 1
            if lowered > 0:
                messages.append("%s's INTIMIDATE lowered the opposing ATTACK!" % display_name(pokemon))
    return " ".join(messages)

static func switch_out_message(pokemon: Dictionary) -> String:
    if String(pokemon.get("ability", "")) != "REGENERATOR" or int(pokemon.get("hp", 0)) <= 0:
        return ""
    var restored := mini(int(pokemon.max_hp) - int(pokemon.hp),
        maxi(1, int(int(pokemon.max_hp) / 3.0)))
    pokemon.hp = int(pokemon.hp) + restored
    return "%s restored HP with REGENERATOR!" % display_name(pokemon)

static func move_targets_all(move_name: String) -> bool:
    return move_name.to_upper() in [
        "SURF", "EARTHQUAKE", "ROCK_SLIDE", "BLIZZARD", "RAZOR_LEAF",
        "SWIFT", "ICY_WIND", "HEAT_WAVE", "DISCHARGE", "DAZZLING_GLEAM",
        "HYPER_VOICE", "AIR_CUTTER", "STRUGGLE_BUG", "BULLDOZE", "MUDDY_WATER"
    ]

static func move_hits_all_adjacent(move_name: String) -> bool:
    return move_name.to_upper() in [
        "SURF", "EARTHQUAKE", "DISCHARGE", "SLUDGE_WAVE", "BOOMBURST",
        "EXPLOSION", "SELFDESTRUCT", "BULLDOZE"
    ]

static func move_targets_self(move_name: String) -> bool:
    var move := PokemonData.move_info(move_name)
    if move.is_empty() or int(move.get("power", 0)) > 0:
        return false
    var effect := String(move.get("effect", ""))
    if effect in [
            "EFFECT_SLEEP", "EFFECT_POISON", "EFFECT_TOXIC", "EFFECT_PARALYZE",
            "EFFECT_CONFUSE", "EFFECT_ATTRACT", "EFFECT_DISABLE", "EFFECT_ENCORE",
            "EFFECT_LEECH_SEED", "EFFECT_MEAN_LOOK", "EFFECT_FORCE_SWITCH",
            "EFFECT_NIGHTMARE", "EFFECT_SPIKES", "EFFECT_SWAGGER"]:
        return false
    return "_UP" in effect or effect in [
        "EFFECT_HEAL", "EFFECT_MORNING_SUN", "EFFECT_SYNTHESIS", "EFFECT_MOONLIGHT",
        "EFFECT_PROTECT", "EFFECT_ENDURE", "EFFECT_LIGHT_SCREEN", "EFFECT_REFLECT",
        "EFFECT_FOCUS_ENERGY", "EFFECT_MIST", "EFFECT_SAFEGUARD",
        "EFFECT_SUBSTITUTE", "EFFECT_BELLY_DRUM", "EFFECT_DEFENSE_CURL"
    ]

static func choose_ai_action(attacker: Dictionary, opponents: Array,
        allies: Array, field: Dictionary, rng: RandomNumberGenerator,
        difficulty: int = 2) -> Dictionary:
    var forced := forced_move(attacker)
    var moves: Array = [forced] if not forced.is_empty() else attacker.get("moves", ["TACKLE"])
    var best := {"move":"STRUGGLE", "target":0, "score":-999999.0,
        "spread":false}
    for raw_move in moves:
        var move_name := String(raw_move)
        if move_name != "STRUGGLE" and not move_is_usable(attacker, move_name):
            continue
        var spread := move_targets_all(move_name)
        for target_index in range(opponents.size()):
            if typeof(opponents[target_index]) != TYPE_DICTIONARY:
                continue
            var target := opponents[target_index] as Dictionary
            if int(target.get("hp", 0)) <= 0:
                continue
            var score := _ai_move_score(attacker, target, move_name, field)
            if spread:
                score *= 1.0 + 0.65 * maxi(0, _living_count(opponents) - 1)
            if difficulty <= 0:
                score += rng.randf_range(-80.0, 80.0)
            elif difficulty == 1:
                score += rng.randf_range(-25.0, 25.0)
            else:
                score += rng.randf_range(-4.0, 4.0)
            if score > float(best.score):
                best = {"move":move_name, "target":target_index,
                    "score":score, "spread":spread}
    return best

static func _living_count(pokemon: Array) -> int:
    var result := 0
    for raw in pokemon:
        if typeof(raw) == TYPE_DICTIONARY and int((raw as Dictionary).get("hp", 0)) > 0:
            result += 1
    return result

static func _ai_move_score(attacker: Dictionary, defender: Dictionary,
        move_name: String, field: Dictionary) -> float:
    if move_name == "STRUGGLE":
        return 1.0
    var move := PokemonData.move_info(move_name)
    if move.is_empty():
        return -1000.0
    var move_type := String(move.get("type", "NORMAL"))
    if not _ability_immunity(defender, move_type).is_empty():
        return -500.0
    var power := int(move.get("power", 0))
    var accuracy := clampf(float(move.get("accuracy", 100)) / 100.0, 0.1, 1.0)
    var type_scale := effectiveness(move_type, defender.get("types", []))
    if power > 0:
        var special := SourceBattleRules.move_category(move_name) != "PHYSICAL"
        var attack_stat := effective_stat(attacker, "sp_attack" if special else "attack", field)
        var defense_stat := effective_stat(defender, "sp_defense" if special else "defense", field)
        var expected := (((2.0 * int(attacker.level) / 5.0 + 2.0) * power * attack_stat /
            maxf(1.0, defense_stat)) / 50.0 + 2.0)
        expected *= type_scale * accuracy
        if (attacker.get("types", []) as Array).has(move_type):
            expected *= 1.5
        expected *= _ability_damage_multiplier(attacker, defender, move_name,
            move_type, power, "special" if special else "physical", type_scale)
        expected *= PokemonState.held_damage_multiplier(attacker, move_type)
        if expected >= int(defender.hp):
            expected += 75.0
        return expected
    var effect := String(move.get("effect", ""))
    if "HEAL" in effect and int(attacker.hp) * 2 < int(attacker.max_hp):
        return 90.0
    if ("SLEEP" in effect or "PARALYZE" in effect or "BURN" in effect or "POISON" in effect) and \
            String(defender.get("status", "")).is_empty():
        return 55.0 * accuracy
    if "_UP" in effect and int(attacker.stages.get("attack", 0)) < 2:
        return 42.0
    if "_DOWN" in effect and int(defender.stages.get("attack", 0)) > -2:
        return 34.0
    if effect in ["EFFECT_PROTECT", "EFFECT_LIGHT_SCREEN", "EFFECT_REFLECT"]:
        return 28.0
    return 8.0

static func best_switch_index(party: Array, active_indices: Array,
        opponent: Dictionary, field: Dictionary) -> int:
    var best_index := -1
    var best_score := -999999.0
    for index in range(party.size()):
        if active_indices.has(index) or typeof(party[index]) != TYPE_DICTIONARY:
            continue
        var candidate := ensure_pokemon(party[index] as Dictionary)
        if int(candidate.hp) <= 0 or bool(candidate.get("is_egg", false)):
            continue
        var score := float(candidate.hp) / maxf(1.0, float(candidate.max_hp)) * 25.0
        for raw_move in candidate.get("moves", []):
            score = maxf(score, _ai_move_score(candidate, opponent, String(raw_move), field))
        if score > best_score:
            best_score = score
            best_index = index
    return best_index

static func experience_reward(defeated: Dictionary, participants: int = 1) -> int:
    # Battle.calcFaintExp: divide before multiplying, including shared rounding.
    if participants <= 0: return 0
    var base_exp := int(PokemonData.info(String(defeated.species)).get("base_exp", 64))
    return int(base_exp * int(defeated.level) / (7 * participants)) * 5

static func experience_recipients(party: Array, participants: Array,
        active_index: int, capture: bool = false) -> Array[int]:
    # CheckEndOfBattle / CatchPokemonWobblesThenCatch: active recipient first.
    var result: Array[int] = []
    for index in range(party.size()):
        var pokemon: Dictionary = party[index]
        if int(pokemon.get("hp", 0)) <= 0 or int(pokemon.get("level", 1)) >= 100:
            continue
        if capture:
            if bool(pokemon.get("is_egg", false)): continue
        elif not participants.has(index):
            continue
        if index == active_index: result.push_front(index)
        else: result.append(index)
    return result

static func moves_learned_at_level(species: String, level: int) -> Array[String]:
    var result: Array[String] = []
    for raw_learned in PokemonData.info(species).get("learnset", []):
        if typeof(raw_learned) != TYPE_DICTIONARY:
            continue
        var learned := raw_learned as Dictionary
        if int(learned.get("level", -1)) != level:
            continue
        var move_name := String(learned.get("move", "")).to_upper().replace(" ", "_")
        if move_name.is_empty() or PokemonData.move_info(move_name).is_empty():
            continue
        if not result.has(move_name):
            result.append(move_name)
    return result

static func refill_pp(pokemon: Dictionary) -> void:
    var restored: Dictionary = {}
    var raw_moves = pokemon.get("moves", [])
    if typeof(raw_moves) != TYPE_ARRAY:
        pokemon["pp"] = restored
        return
    for raw_move in raw_moves as Array:
        var move_name: String = String(raw_move).to_upper().replace(" ", "_")
        if move_name.is_empty():
            continue
        var move_data: Dictionary = PokemonData.move_info(move_name)
        restored[move_name] = maxi(0, int(move_data.get("pp", 35)))
    pokemon["pp"] = restored

static func gain_level(pokemon: Dictionary) -> Dictionary:
    var old_level = int(pokemon.get("level", 1))
    var old_stats = (pokemon.get("stats", {}) as Dictionary).duplicate(true)
    var old_max_hp = int(pokemon.get("max_hp", 1))
    if old_level >= 100:
        return {
            "old_level": old_level, "new_level": old_level,
            "old_stats": old_stats, "new_stats": old_stats.duplicate(true),
            "old_max_hp": old_max_hp, "new_max_hp": old_max_hp,
            "moves": []
        }
    pokemon["level"] = old_level + 1
    PokemonState.apply_stats(pokemon, true)
    # Requested 9.21 behavior: level-up fully restores current move PP.
    refill_pp(pokemon)
    return {
        "old_level": old_level,
        "new_level": int(pokemon.level),
        "old_stats": old_stats,
        "new_stats": (pokemon.get("stats", {}) as Dictionary).duplicate(true),
        "old_max_hp": old_max_hp,
        "new_max_hp": int(pokemon.get("max_hp", old_max_hp)),
        "moves": moves_learned_at_level(String(pokemon.species), int(pokemon.level))
    }

static func learn_move(pokemon: Dictionary, move_name: String,
        replace_index: int = -1) -> bool:
    var normalized := move_name.to_upper().replace(" ", "_")
    if normalized.is_empty() or PokemonData.move_info(normalized).is_empty():
        return false
    var moves: Array = pokemon.get("moves", [])
    if moves.has(normalized):
        return false
    if moves.size() < 4:
        moves.append(normalized)
    elif replace_index >= 0 and replace_index < moves.size():
        var forgotten := String(moves[replace_index])
        moves[replace_index] = normalized
        var existing_pp: Dictionary = pokemon.get("pp", {})
        existing_pp.erase(forgotten)
        pokemon["pp"] = existing_pp
    else:
        return false
    pokemon["moves"] = moves
    var pp: Dictionary = pokemon.get("pp", {})
    pp[normalized] = int(PokemonData.move_info(normalized).get("pp", 35))
    pokemon["pp"] = pp
    return true

static func resolved_evolution_species(pokemon: Dictionary, target: String) -> String:
    if target.to_lower() == "meowstic":
        return "meowstic_female" if String(pokemon.get("gender", "male")) == "female" else "meowstic_male"
    return target.to_lower()

static func evolution_target(pokemon: Dictionary, party: Array = [],
        time_of_day: String = "day") -> String:
    var evolutions: Array = PokemonData.evolution_rules(pokemon)
    var current_level := int(pokemon.get("level", 1))

    # Check numeric levels in ascending order, matching CheckEvo's 1..level
    # lookup against Specie.gen2Evos.
    var level_candidates: Array[Dictionary] = []
    for raw_evolution in evolutions:
        if typeof(raw_evolution) != TYPE_DICTIONARY:
            continue
        var evolution := raw_evolution as Dictionary
        if String(evolution.get("method", "")) == "EVOLVE_LEVEL" and \
                int(evolution.get("parameter", 101)) <= current_level:
            level_candidates.append(evolution)
    level_candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
        return int(a.get("parameter", 101)) < int(b.get("parameter", 101)))
    if not level_candidates.is_empty():
        return resolved_evolution_species(pokemon, String(level_candidates[0].get("species", "")))

    var happiness := int(pokemon.get("happiness", pokemon.get("friendship", 70)))
    if happiness >= 120:
        var normalized_time := time_of_day.to_lower()
        for raw_evolution in evolutions:
            if typeof(raw_evolution) != TYPE_DICTIONARY:
                continue
            var evolution := raw_evolution as Dictionary
            if String(evolution.get("method", "")) != "EVOLVE_HAPPINESS":
                continue
            var trigger := String(evolution.get("parameter", "")).to_upper()
            if trigger == "TR_ANYTIME" or \
                    (trigger == "TR_MORNDAY" and normalized_time == "day") or \
                    (trigger == "TR_NITE" and normalized_time == "night"):
                return String(evolution.get("species", "")).to_lower()

    # Check party species in party order, excluding this exact record.
    for raw_member in party:
        if typeof(raw_member) != TYPE_DICTIONARY or is_same(raw_member, pokemon):
            continue
        var member_species := String((raw_member as Dictionary).get(
            "species", "")).to_upper().replace(" ", "_")
        for raw_evolution in evolutions:
            if typeof(raw_evolution) != TYPE_DICTIONARY:
                continue
            var evolution := raw_evolution as Dictionary
            if String(evolution.get("method", "")) == "EVOLVE_HASINPARTY" and \
                    String(evolution.get("parameter", "")).to_upper().replace(
                        " ", "_") == member_species:
                return String(evolution.get("species", "")).to_lower()

    # Finally check known attacks in their selected slot order.
    for raw_move in pokemon.get("moves", []):
        var move_name := String(raw_move).to_upper().replace(" ", "_")
        for raw_evolution in evolutions:
            if typeof(raw_evolution) != TYPE_DICTIONARY:
                continue
            var evolution := raw_evolution as Dictionary
            if String(evolution.get("method", "")) == "EVOLVE_MOVE" and \
                    String(evolution.get("parameter", "")).to_upper().replace(
                        " ", "_") == move_name:
                return String(evolution.get("species", "")).to_lower()
    return ""

static func apply_evolution(pokemon: Dictionary, new_species: String) -> bool:
    new_species = resolved_evolution_species(pokemon, new_species)
    if new_species.is_empty() or PokemonData.info(new_species).is_empty():
        return false
    var old_hp := int(pokemon.get("hp", 1))
    var old_max := maxi(1, int(pokemon.get("max_hp", 1)))
    var evolution_seed := pokemon.duplicate(true)
    evolution_seed["species"] = new_species
    for erased_key in ["stats", "max_hp", "hp", "types", "ability",
            "ability_slot", "base_stats"]:
        evolution_seed.erase(erased_key)
    var rebuilt := make_pokemon(new_species, int(pokemon.get("level", 1)), null,
        evolution_seed)
    pokemon["species"] = new_species
    for key in ["types", "stats", "max_hp", "moves", "pp", "ability",
            "ability_slot"]:
        if rebuilt.has(key):
            pokemon[key] = rebuilt[key]
    var damage := maxi(0, old_max - old_hp)
    pokemon["hp"] = clampi(int(pokemon.max_hp) - damage, 0, int(pokemon.max_hp))
    # Pokemon.evolveTo clears the persistent status after rebuilding stats.
    pokemon["status"] = ""
    pokemon["status_counter"] = 0
    return true

static func grant_experience(pokemon: Dictionary, amount: int) -> Array[String]:
    var messages: Array[String] = []
    pokemon.exp = int(pokemon.get("exp", 0)) + amount
    while int(pokemon.level) < 100 and int(pokemon.exp) >= exp_for_level(String(pokemon.species), int(pokemon.level) + 1):
        var level_result := gain_level(pokemon)
        messages.append("%s grew to level %d!" % [
            PokemonState.display_name(pokemon).to_upper(), int(pokemon.level)])
        for move_name in level_result.get("moves", []):
            if (pokemon.get("moves", []) as Array).size() < 4 and \
                    learn_move(pokemon, String(move_name)):
                messages.append("%s learned %s!" % [
                    PokemonState.display_name(pokemon).to_upper(),
                    String(move_name).replace("_", " ")])
        _check_level_evolution(pokemon, messages)
    return messages

static func exp_for_level(species: String, level: int) -> int:
    var n := float(level)
    var growth := String(PokemonData.info(species).get("growth_rate", "GROWTH_MEDIUM_FAST"))
    match growth:
        "GROWTH_FAST", "GROWTH_MEDIUM_FAST": return int(floor(4.0 * n * n * n / 5.0))
        "GROWTH_MEDIUM_SLOW": return int(6 * level * level * level / 5) - 15 * level * level + 100 * level - 140
        "GROWTH_SLOW": return int(floor(5.0 * n * n * n / 4.0))
        "GROWTH_ERRATIC":
            if level <= 50: return int(floor(n * n * n * (100.0 - n) / 50.0))
            if level <= 68: return int(floor(n * n * n * (150.0 - n) / 100.0))
            if level <= 98: return int(floor(n * n * n * floor((1911.0 - 10.0 * n) / 3.0) / 500.0))
            return int(floor(n * n * n * (160.0 - n) / 100.0))
        "GROWTH_FLUCTUATING":
            if level <= 15: return int(floor(n * n * n * (floor((n + 1.0) / 3.0) + 24.0) / 50.0))
            if level <= 36: return int(floor(n * n * n * (n + 14.0) / 50.0))
            return int(floor(n * n * n * (floor(n / 2.0) + 32.0) / 50.0))
        _: return int(floor(n * n * n))

static func _check_level_evolution(pokemon: Dictionary, messages: Array[String]) -> void:
    for evolution in PokemonData.evolution_rules(pokemon):
        if String(evolution.get("method", "")) != "EVOLVE_LEVEL":
            continue
        if int(pokemon.level) < int(evolution.get("parameter", 101)):
            continue
        var old_name := PokemonState.display_name(pokemon).to_upper()
        var new_species := String(evolution.get("species", pokemon.species)).to_lower()
        if apply_evolution(pokemon, new_species):
            messages.append("%s evolved into %s!" % [old_name,
                new_species.to_upper().replace("_", " ")])
        return

static func item_evolution_target(pokemon: Dictionary, item_name: String) -> String:
    if bool(pokemon.get("is_egg", false)):
        return ""
    var species := PokemonData.canonical_species(String(pokemon.get("species", "")))
    var gender := String(pokemon.get("gender", "")).to_lower()
    # DrawPokemonMenu's source item eligibility restrictions.
    if (species == "snorunt" and gender != "female") or (species == "kirlia" and gender != "male"):
        return ""
    var parameter := ItemData.normalize_name(item_name).replace(" ", "").replace("_", "")
    for evolution in PokemonData.evolution_rules(pokemon):
        if String(evolution.get("method", "")) not in ["EVOLVE_ITEM", "EVOLVE_TRADEITEM"]:
            continue
        var required := String(evolution.get("parameter", "")).to_upper().replace("_", "").replace(" ", "")
        if required != parameter:
            continue
        var target := resolved_evolution_species(pokemon, String(evolution.get("species", "")))
        if not PokemonData.info(target).is_empty():
            return target
    return ""

static func evolve_with_item(pokemon: Dictionary, item_name: String) -> String:
    var target := item_evolution_target(pokemon, item_name)
    var old_name := PokemonState.display_name(pokemon).to_upper()
    if not target.is_empty() and apply_evolution(pokemon, target):
        return "%s evolved into %s!" % [old_name, target.to_upper().replace("_", " ")]
    return ""

static func capture_succeeds(target: Dictionary, ball_bonus: float, rng: RandomNumberGenerator) -> bool:
    # Compatibility for callers supplying an explicit multiplier.
    var rate := mini(255, int(int(PokemonData.info(String(target.species)).get("catch_rate", 45)) * ball_bonus))
    return rng.randi_range(0, 255) <= SourceBattleRules.catch_threshold(target, rate)

static func capture_result(target: Dictionary, player: Dictionary, ball: String,
        context: Dictionary, rng: RandomNumberGenerator) -> int:
    if ball == "MASTER BALL": return -1
    var rate := SourceBattleRules.ball_rate(target, player, ball, context)
    var threshold := SourceBattleRules.catch_threshold(target, rate)
    if rng.randi_range(0, 255) <= threshold: return -1
    var limits := [1,2,3,4,5,7,10,15,20,30,40,50,60,80,100,120,140,160,180,200,220,240,254,255]
    var shakes := [63,75,84,90,95,103,113,126,134,149,160,169,177,191,201,211,220,227,234,240,246,251,253,255]
    var index := 0
    while threshold > int(limits[index]): index += 1
    for shake in range(3):
        if rng.randi_range(0, 255) >= int(shakes[index]): return shake
    return 3
