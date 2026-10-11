class_name PokemonState
extends RefCounted

const PokemonData = preload("res://scripts/pokemon_data.gd")

const STAT_KEYS := ["hp", "attack", "defense", "speed", "sp_attack", "sp_defense"]
const SHINY_RATE := 256
const NATURE_ORDER := [
    "HARDY", "LONELY", "BRAVE", "ADAMANT", "NAUGHTY",
    "BOLD", "DOCILE", "RELAXED", "IMPISH", "LAX",
    "TIMID", "HASTY", "SERIOUS", "JOLLY", "NAIVE",
    "MODEST", "MILD", "QUIET", "BASHFUL", "RASH",
    "CALM", "GENTLE", "SASSY", "CAREFUL", "QUIRKY"
]
const NATURE_EFFECTS := {
    "LONELY":["attack", "defense"], "BRAVE":["attack", "speed"],
    "ADAMANT":["attack", "sp_attack"], "NAUGHTY":["attack", "sp_defense"],
    "BOLD":["defense", "attack"], "RELAXED":["defense", "speed"],
    "IMPISH":["defense", "sp_attack"], "LAX":["defense", "sp_defense"],
    "TIMID":["speed", "attack"], "HASTY":["speed", "defense"],
    "JOLLY":["speed", "sp_attack"], "NAIVE":["speed", "sp_defense"],
    "MODEST":["sp_attack", "attack"], "MILD":["sp_attack", "defense"],
    "QUIET":["sp_attack", "speed"], "RASH":["sp_attack", "sp_defense"],
    "CALM":["sp_defense", "attack"], "GENTLE":["sp_defense", "defense"],
    "SASSY":["sp_defense", "speed"], "CAREFUL":["sp_defense", "sp_attack"]
}

const TYPE_ABILITY_POOLS := {
    "NORMAL":["RUN AWAY", "KEEN EYE", "GUTS", "TECHNICIAN"],
    "FIRE":["BLAZE", "FLASH FIRE", "FLAME BODY", "DROUGHT"],
    "WATER":["TORRENT", "WATER ABSORB", "SWIFT SWIM", "STORM DRAIN"],
    "ELECTRIC":["STATIC", "VOLT ABSORB", "LIGHTNING ROD", "MOTOR DRIVE"],
    "GRASS":["OVERGROW", "CHLOROPHYLL", "SAP SIPPER", "EFFECT SPORE"],
    "ICE":["SNOW CLOAK", "THICK FAT", "ICE BODY", "SNOW WARNING"],
    "FIGHTING":["GUTS", "INNER FOCUS", "IRON FIST", "PURE POWER"],
    "POISON":["POISON POINT", "IMMUNITY", "LIQUID OOZE", "POISON HEAL"],
    "GROUND":["SAND VEIL", "SAND RUSH", "LIGHTNING ROD", "SOLID ROCK"],
    "FLYING":["KEEN EYE", "INNER FOCUS", "GALE WINGS", "REGENERATOR"],
    "PSYCHIC":["SYNCHRONIZE", "INNER FOCUS", "MAGIC GUARD", "OWN TEMPO"],
    "BUG":["SWARM", "COMPOUND EYES", "SHED SKIN", "TINTED LENS"],
    "ROCK":["STURDY", "ROCK HEAD", "SAND STREAM", "SOLID ROCK"],
    "GHOST":["CURSED BODY", "LEVITATE", "INSOMNIA", "PRANKSTER"],
    "DRAGON":["INNER FOCUS", "MULTISCALE", "ROUGH SKIN", "INTIMIDATE"],
    "DARK":["INTIMIDATE", "PRANKSTER", "KEEN EYE", "STRONG JAW"],
    "STEEL":["STURDY", "CLEAR BODY", "HEATPROOF", "IRON BARBS"],
    "FAIRY":["CUTE CHARM", "MAGIC GUARD", "PIXILATE", "FILTER"]
}

const ABILITY_OVERRIDES := {
    "bulbasaur":"OVERGROW", "ivysaur":"OVERGROW", "venusaur":"OVERGROW",
    "charmander":"BLAZE", "charmeleon":"BLAZE", "charizard":"BLAZE",
    "squirtle":"TORRENT", "wartortle":"TORRENT", "blastoise":"TORRENT",
    "caterpie":"SHIELD DUST", "metapod":"SHED SKIN", "butterfree":"COMPOUND EYES",
    "weedle":"SHIELD DUST", "kakuna":"SHED SKIN", "beedrill":"SWARM",
    "pidgey":"KEEN EYE", "pidgeotto":"KEEN EYE", "pidgeot":"KEEN EYE",
    "rattata":"RUN AWAY", "raticate":"GUTS", "spearow":"KEEN EYE", "fearow":"KEEN EYE",
    "ekans":"INTIMIDATE", "arbok":"INTIMIDATE", "pichu":"STATIC",
    "pikachu":"STATIC", "raichu":"STATIC", "sandshrew":"SAND VEIL",
    "sandslash":"SAND VEIL", "clefairy":"MAGIC GUARD", "clefable":"MAGIC GUARD",
    "vulpix":"FLASH FIRE", "ninetales":"FLASH FIRE", "jigglypuff":"CUTE CHARM",
    "wigglytuff":"CUTE CHARM", "zubat":"INNER FOCUS", "golbat":"INNER FOCUS",
    "crobat":"INNER FOCUS", "oddish":"CHLOROPHYLL", "gloom":"CHLOROPHYLL",
    "vileplume":"CHLOROPHYLL", "paras":"EFFECT SPORE", "parasect":"EFFECT SPORE",
    "diglett":"SAND VEIL", "dugtrio":"SAND VEIL", "meowth":"PICKUP",
    "persian":"TECHNICIAN", "psyduck":"DAMP", "golduck":"DAMP",
    "mankey":"VITAL SPIRIT", "primeape":"VITAL SPIRIT", "growlithe":"INTIMIDATE",
    "arcanine":"INTIMIDATE", "poliwag":"WATER ABSORB", "poliwhirl":"WATER ABSORB",
    "poliwrath":"WATER ABSORB", "abra":"SYNCHRONIZE", "kadabra":"SYNCHRONIZE",
    "alakazam":"SYNCHRONIZE", "machop":"GUTS", "machoke":"GUTS", "machamp":"GUTS",
    "geodude":"STURDY", "graveler":"STURDY", "golem":"STURDY",
    "ponyta":"FLASH FIRE", "rapidash":"FLASH FIRE", "slowpoke":"OWN TEMPO",
    "slowbro":"OWN TEMPO", "magnemite":"STURDY", "magneton":"STURDY",
    "farfetch_d":"KEEN EYE", "doduo":"RUN AWAY", "dodrio":"RUN AWAY",
    "seel":"THICK FAT", "dewgong":"THICK FAT", "grimer":"STENCH", "muk":"STENCH",
    "shellder":"SHELL ARMOR", "cloyster":"SHELL ARMOR", "gastly":"LEVITATE",
    "haunter":"LEVITATE", "gengar":"CURSED BODY", "onix":"STURDY",
    "drowzee":"INSOMNIA", "hypno":"INSOMNIA", "krabby":"SHELL ARMOR",
    "kingler":"SHELL ARMOR", "voltorb":"STATIC", "electrode":"STATIC",
    "cubone":"ROCK HEAD", "marowak":"ROCK HEAD", "hitmonlee":"LIMBER",
    "hitmonchan":"IRON FIST", "koffing":"LEVITATE", "weezing":"LEVITATE",
    "rhyhorn":"ROCK HEAD", "rhydon":"ROCK HEAD", "chansey":"NATURAL CURE",
    "kangaskhan":"EARLY BIRD", "horsea":"SWIFT SWIM", "seadra":"POISON POINT",
    "staryu":"NATURAL CURE", "starmie":"NATURAL CURE", "mrmime":"FILTER",
    "scyther":"TECHNICIAN", "jynx":"OBLIVIOUS", "electabuzz":"STATIC",
    "magmar":"FLAME BODY", "pinsir":"HYPER CUTTER", "tauros":"INTIMIDATE",
    "magikarp":"SWIFT SWIM", "gyarados":"INTIMIDATE", "lapras":"WATER ABSORB",
    "ditto":"LIMBER", "eevee":"RUN AWAY", "vaporeon":"WATER ABSORB",
    "jolteon":"VOLT ABSORB", "flareon":"FLASH FIRE", "porygon":"TRACE",
    "snorlax":"THICK FAT", "articuno":"PRESSURE", "zapdos":"PRESSURE",
    "moltres":"PRESSURE", "dratini":"SHED SKIN", "dragonair":"SHED SKIN",
    "dragonite":"INNER FOCUS", "mewtwo":"PRESSURE", "mew":"SYNCHRONIZE",
    "regirock":"CLEAR BODY", "regice":"CLEAR BODY", "registeel":"CLEAR BODY",
    "regigigas":"SLOW START", "spiritomb":"PRESSURE", "mimikyu":"DISGUISE",
    "volcarona":"FLAME BODY"
}

const HELD_TYPE_BOOSTS := {
    "CHARCOAL":"FIRE", "MYSTIC WATER":"WATER", "MIRACLE SEED":"GRASS",
    "MAGNET":"ELECTRIC", "NEVERMELTICE":"ICE", "POISON BARB":"POISON",
    "SOFT SAND":"GROUND", "SOFT FEATHER":"FLYING", "PSI ENERGY":"PSYCHIC",
    "SILKY THREAD":"BUG", "HARD STONE":"ROCK", "SPELL TAG":"GHOST",
    "DRAGON FANG":"DRAGON", "DARK ENERGY":"DARK", "METAL COAT":"STEEL"
}
const HOLDABLE_ITEMS := [
    "LUM BERRY", "PECHA BERRY", "CHERI BERRY", "ASPEAR BERRY",
    "CHESTO BERRY", "RAWST BERRY", "PERSIM BERRY", "BERRY JUICE",
    "RAGECANDYBAR", "MOOMOO MILK", "BINDING BAND", "HARD SHELL", "SOFT WOOL",
    "MAGNET", "NEVERMELTICE", "DRAGON FANG", "METAL COAT", "SOFT SAND",
    "POISON BARB", "MIRACLE SEED", "CHARCOAL", "HARD STONE", "SOFT FEATHER",
    "SILKY THREAD", "MYSTIC WATER", "SPELL TAG", "PSI ENERGY", "DARK ENERGY"
]

static func _usable_rng(rng: RandomNumberGenerator) -> RandomNumberGenerator:
    if rng != null:
        return rng
    var generated := RandomNumberGenerator.new()
    generated.randomize()
    return generated

static func gender_from_ratio(ratio: String, rng: RandomNumberGenerator = null) -> String:
    var threshold := int({
        "GENDER_F0":0, "GENDER_F12_5":125, "GENDER_F25":250,
        "GENDER_F50":500, "GENDER_F75":750, "GENDER_F100":1000
    }.get(ratio.to_upper(), -1))
    if threshold < 0:
        return "genderless"
    var source_rng := _usable_rng(rng)
    return "female" if source_rng.randi_range(0, 999) < threshold else "male"

static func ensure_core(source: Dictionary, rng: RandomNumberGenerator = null) -> Dictionary:
    var result := source.duplicate(true)
    var source_rng := _usable_rng(rng)
    var species := String(result.get("species", "rattata")).to_lower()
    var info := PokemonData.info(species)
    result["species"] = species
    result["level"] = clampi(int(result.get("level", 1)), 1, 100)
    if not result.has("personality"):
        result["personality"] = source_rng.randi_range(0, 2147483647)
    var personality := int(result["personality"])
    var nature := String(result.get("nature", "")).to_upper()
    if not NATURE_ORDER.has(nature):
        nature = NATURE_ORDER[posmod(personality, NATURE_ORDER.size())]
    result["nature"] = nature
    result["ivs"] = _normalized_values(result.get("ivs", {}), 31, source_rng, true)
    result["evs"] = _normalized_values(result.get("evs", {}), 252, source_rng, false)
    _cap_evs(result["evs"] as Dictionary)
    if String(result.get("gender", "")).is_empty() or String(result.get("gender", "")) == "unknown":
        result["gender"] = gender_from_ratio(String(info.get("gender_ratio", "GENDER_UNKNOWN")), source_rng)
    # Original 0.8.11 has no ability assignment/effects. Keep earlier port
    # metadata recoverable while preventing it from changing source battles.
    if not String(result.get("ability", "")).is_empty():
        result["legacy_ability"] = result["ability"]
        result["legacy_ability_slot"] = int(result.get("ability_slot", 0))
    result["ability"] = ""
    result["held_item"] = String(result.get("held_item", "")).to_upper()
    result["nickname"] = String(result.get("nickname", ""))
    result["original_trainer"] = String(result.get("original_trainer", "WILD"))
    result["trainer_id"] = int(result.get("trainer_id", 0))
    result["met_level"] = int(result.get("met_level", result["level"]))
    result["met_location"] = String(result.get("met_location", "WILDERNESS"))
    result["pokeball"] = String(result.get("pokeball", "POKE BALL"))
    result["generation"] = int(result.get("generation", generation_for_dex(int(info.get("dex", 0)))))
    ensure_shiny(result, source_rng)
    result["friendship"] = clampi(int(result.get("friendship", result.get(
        "happiness", info.get("base_happiness", 70)))), 0, 255)
    result["happiness"] = int(result["friendship"])
    result["ribbons"] = _array_value(result.get("ribbons", []))
    result["markings"] = int(result.get("markings", 0))
    result["pokerus"] = int(result.get("pokerus", 0))
    return result

static func ensure_shiny(record: Dictionary, rng: RandomNumberGenerator = null) -> void:
    var known := record.has("shiny") or record.has("is_shiny") or record.has("isShiny")
    var shiny := PokemonData.is_shiny(record) if known else _usable_rng(rng).randi_range(0, SHINY_RATE - 1) == 0
    record["shiny"] = shiny
    record["is_shiny"] = shiny

static func _normalized_values(raw, maximum: int, rng: RandomNumberGenerator,
        random_missing: bool) -> Dictionary:
    var source: Dictionary = raw if typeof(raw) == TYPE_DICTIONARY else {}
    var result := {}
    for key in STAT_KEYS:
        var fallback := rng.randi_range(0, maximum) if random_missing else 0
        result[key] = clampi(int(source.get(key, fallback)), 0, maximum)
    return result

static func _cap_evs(evs: Dictionary) -> void:
    var remaining := 510
    for key in STAT_KEYS:
        var value := mini(remaining, clampi(int(evs.get(key, 0)), 0, 252))
        evs[key] = value
        remaining -= value

static func _array_value(raw) -> Array:
    return (raw as Array).duplicate(true) if typeof(raw) == TYPE_ARRAY else []

static func nature_modifier(nature: String, stat_name: String) -> float:
    var effects: Array = NATURE_EFFECTS.get(nature.to_upper(), [])
    if effects.size() < 2:
        return 1.0
    if String(effects[0]) == stat_name:
        return 1.1
    if String(effects[1]) == stat_name:
        return 0.9
    return 1.0

static func calculate_stats(record: Dictionary, base_override: Array = []) -> Dictionary:
    var info := PokemonData.info(String(record.get("species", "rattata")))
    var base: Array = base_override.duplicate() if base_override.size() >= 6 else (
        info.get("stats", [45, 45, 45, 45, 45, 45]) as Array).duplicate()
    while base.size() < 6:
        base.append(45)
    var level := clampi(int(record.get("level", 1)), 1, 100)
    var result := {}
    for index in range(STAT_KEYS.size()):
        var stat_name := String(STAT_KEYS[index])
        var base_stat := int(base[index]) + (50 if stat_name == "hp" else 0)
        result[stat_name] = int(base_stat * level / 50) + 10
    return result

static func apply_stats(record: Dictionary, preserve_damage: bool = true,
        base_override: Array = []) -> void:
    var old_max := int(record.get("max_hp", 0))
    var old_hp := int(record.get("hp", old_max))
    var stats := calculate_stats(record, base_override)
    record["stats"] = stats
    record["max_hp"] = int(stats["hp"])
    if old_max <= 0:
        record["hp"] = int(record["max_hp"])
    elif preserve_damage and old_hp <= 0:
        record["hp"] = 0
    elif preserve_damage:
        record["hp"] = clampi(int(record["max_hp"]) - maxi(0, old_max - old_hp), 0,
            int(record["max_hp"]))
    else:
        record["hp"] = int(record["max_hp"])

static func ability_choices(species: String) -> Array[String]:
    species = species.to_lower()
    if ABILITY_OVERRIDES.has(species):
        return [String(ABILITY_OVERRIDES[species])]
    var info := PokemonData.info(species)
    var types: Array = info.get("types", ["NORMAL"])
    var primary := String(types[0]) if not types.is_empty() else "NORMAL"
    var result: Array[String] = []
    for raw in TYPE_ABILITY_POOLS.get(primary, TYPE_ABILITY_POOLS["NORMAL"]):
        result.append(String(raw))
    return result

static func generation_for_dex(dex: int) -> int:
    if dex <= 0: return 0
    if dex <= 151: return 1
    if dex <= 251: return 2
    if dex <= 386: return 3
    if dex <= 493: return 4
    if dex <= 649: return 5
    if dex <= 721: return 6
    if dex <= 809: return 7
    if dex <= 905: return 8
    return 9

static func grant_evs(pokemon: Dictionary, defeated: Dictionary) -> Dictionary:
    return {"amount":0, "stat":""}

static func is_holdable(item_name: String) -> bool:
    return HOLDABLE_ITEMS.has(item_name.to_upper())

static func available_hold_items(inventory: Dictionary) -> Array[String]:
    var result: Array[String] = []
    for item_name in HOLDABLE_ITEMS:
        if int(inventory.get(item_name, 0)) > 0:
            result.append(item_name)
    result.sort()
    return result

static func held_stat_multiplier(pokemon: Dictionary, stat_name: String) -> float:
    var item := String(pokemon.get("held_item", ""))
    if item == "HARD SHELL" and stat_name == "defense":
        return 1.2
    if item == "SOFT WOOL" and stat_name == "sp_defense":
        return 1.2
    return 1.0

static func held_damage_multiplier(pokemon: Dictionary, move_type: String) -> float:
    var item := String(pokemon.get("held_item", ""))
    return 1.2 if String(HELD_TYPE_BOOSTS.get(item, "")) == move_type else 1.0

static func display_name(pokemon: Dictionary) -> String:
    var nickname := String(pokemon.get("nickname", "")).strip_edges()
    if not nickname.is_empty():
        return nickname
    var species := String(pokemon.get("species", "POKEMON")).to_lower()
    if species == "gengar" and String(pokemon.get("form", "")).to_lower() == "mega":
        return "MEGA GENGAR"
    if PokemonData.canonical_species(species) in ["raichu_alolan", "exeggutor_alolan"]:
        return PokemonData.battle_display_name(species)
    # Nidoran's sex is presentation data, not part of its visible species name.
    # Existing party/battle screens draw the male/female symbol beside the name.
    if species in ["nidoran_f", "nidoran_m"]:
        return PokemonData.battle_display_name(species)
    if species.begins_with("mega_"): return PokemonData.battle_display_name(species)
    if species == "unown_king": return "UNOWN KING"
    if species.begins_with("unown_"): return "UNOWN"
    return species.to_upper()

static func summary_text(pokemon: Dictionary) -> String:
    var ivs: Dictionary = pokemon.get("ivs", {})
    var evs: Dictionary = pokemon.get("evs", {})
    return "%s  %s  Lv.%d\n%s nature  %s\nAbility: %s\nHeld: %s\nHP %d/%d  ATK %d  DEF %d\nSPA %d  SPD %d  SPE %d\nIV %d/%d/%d/%d/%d/%d\nEV %d/%d/%d/%d/%d/%d" % [
        display_name(pokemon), String(pokemon.get("gender", "genderless")).to_upper(),
        int(pokemon.get("level", 1)), String(pokemon.get("nature", "HARDY")),
        "Shiny" if bool(pokemon.get("shiny", false)) else "Normal",
        String(pokemon.get("ability", "NONE")),
        String(pokemon.get("held_item", "NONE")) if not String(pokemon.get("held_item", "")).is_empty() else "NONE",
        int(pokemon.get("hp", 0)), int(pokemon.get("max_hp", 0)),
        int((pokemon.get("stats", {}) as Dictionary).get("attack", 0)),
        int((pokemon.get("stats", {}) as Dictionary).get("defense", 0)),
        int((pokemon.get("stats", {}) as Dictionary).get("sp_attack", 0)),
        int((pokemon.get("stats", {}) as Dictionary).get("sp_defense", 0)),
        int((pokemon.get("stats", {}) as Dictionary).get("speed", 0)),
        int(ivs.get("hp", 0)), int(ivs.get("attack", 0)), int(ivs.get("defense", 0)),
        int(ivs.get("sp_attack", 0)), int(ivs.get("sp_defense", 0)), int(ivs.get("speed", 0)),
        int(evs.get("hp", 0)), int(evs.get("attack", 0)), int(evs.get("defense", 0)),
        int(evs.get("sp_attack", 0)), int(evs.get("sp_defense", 0)), int(evs.get("speed", 0))
    ]

static func battle_display_name(pokemon: Dictionary) -> String:
    if not String(pokemon.get("nickname", "")).strip_edges().is_empty():
        return display_name(pokemon)
    var species := String(pokemon.get("species", "POKEMON"))
    return display_name(pokemon)
