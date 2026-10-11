class_name PokemonEcology
extends RefCounted

const PokemonData = preload("res://scripts/pokemon_data.gd")
const PokemonState = preload("res://scripts/pokemon_state.gd")

# Pokemon.java 0.8.11 works in 60 Hz ticks. Habitat upkeep is staggered over
# 96 ticks, eggs are checked in a 7x7 tile square, and parents react within
# 160 pixels (ten 16-pixel cells).
const HABITAT_RADIUS := 3
const PARENT_ALERT_RADIUS := 10
const HABITAT_CHECK_SECONDS := 96.0 / 60.0
const LAY_EGG_SECONDS := 7200.0 / 60.0
## A couple stops laying while this many of its eggs still sit in the overworld.
const MAX_EGGS_PER_COUPLE := 2
## An egg nobody collects is released into the wild after this many world days.
const EGG_RELEASE_DAYS := 9.0
const FRIEND_SECONDS := 960.0 / 60.0
const DEFAULT_HARVEST_SECONDS := 9000.0 / 60.0
const EGG_STEP_INTERVAL := 16
const FRIENDSHIP_STEP_INTERVAL := 512
const MAX_HAPPINESS := 220

const TYPE_HABITATS := {
    "BUG": ["flower|potted"],
    "WATER": ["water"],
    "FLYING": ["tree|bush"],
    "ROCK": ["rock|statue|gym"],
    "FIRE": ["campfire|lava|soot|volcano"],
    "GRASS": ["grass"],
    "GROUND": ["mountain|sand|desert"],
    "STEEL": ["mountain"],
    "GHOST": ["gravestone|green12"],
    "ICE": ["snow"]
}

const TYPE_HARVEST := {
    "BUG": ["SILKY THREAD"],
    "WATER": ["HARD SHELL"],
    "FLYING": ["SOFT FEATHER"],
    "ROCK": ["HARD STONE"],
    "FIRE": ["CHARCOAL"],
    "GRASS": ["MIRACLE SEED"],
    "POISON": ["POISON BARB"],
    "GROUND": ["SOFT SAND"],
    "STEEL": ["METAL COAT"],
    "PSYCHIC": ["PSI ENERGY"],
    "DARK": ["DARK ENERGY"],
    "GHOST": ["LIFE FORCE"],
    "FIGHTING": ["BINDING BAND"],
    "FAIRY": ["STARDUST"],
    "DRAGON": ["DRAGON FANG", "DRAGON SCALE", "DRAGON SCALE", "DRAGON SCALE", "DRAGON SCALE"],
    "ICE": ["NEVERMELTICE"],
    "ELECTRIC": ["MAGNET"]
}

const DELIBIRD_HARVEST := [
    "NEVERMELTICE", "MAGNET", "ANCIENTPOWDER", "SOFT WOOL",
    "MOOMOO MILK", "HARD STONE", "MANURE", "BERRY JUICE",
    "SOFT SAND", "DRAGON FANG", "DRAGON SCALE", "LIFE FORCE",
    "PSI ENERGY", "DARK ENERGY", "METAL COAT", "SILKY THREAD",
    "HARD SHELL", "SOFT FEATHER", "CHARCOAL", "GRASS", "HONEY"
]

const FOOD_HAPPINESS := {
    "LUM BERRY": 5,
    "PECHA BERRY": 5,
    "CHERI BERRY": 5,
    "ASPEAR BERRY": 5,
    "CHESTO BERRY": 5,
    "RAWST BERRY": 5,
    "PERSIM BERRY": 5,
    "BERRY JUICE": 8,
    "HONEY": 8,
    "SWEET APPLE": 10,
    "RAGECANDYBAR": 10,
    "MOOMOO MILK": 12
}

static func normalize_species(species: String) -> String:
    return species.to_lower().strip_edges().replace(" ", "_")

static func gender_from_ratio(
        ratio: String, rng: RandomNumberGenerator = null
    ) -> String:
    var threshold := int({
        "GENDER_F0": 0,
        "GENDER_F12_5": 125,
        "GENDER_F25": 250,
        "GENDER_F50": 500,
        "GENDER_F75": 750,
        "GENDER_F100": 1000
    }.get(ratio.to_upper(), -1))
    if threshold < 0:
        return "unknown"
    var roll := rng.randi_range(0, 999) if rng != null else 500
    return "female" if roll < threshold else "male"

static func ensure_record(
        source: Dictionary,
        rng: RandomNumberGenerator = null,
        ecology_id: String = ""
    ) -> Dictionary:
    var result := source.duplicate(true)
    var species := normalize_species(String(result.get("species", result.get("name", "pidgey"))))
    result["species"] = species
    var info := PokemonData.info(species)
    if String(result.get("gender", "")).is_empty():
        result["gender"] = gender_from_ratio(
            String(info.get("gender_ratio", "GENDER_UNKNOWN")), rng
        )
    result["egg_groups"] = _string_array(
        result.get("egg_groups", info.get("egg_groups", ["EGG_NONE", "EGG_NONE"]))
    )
    result["base_species"] = String(
        result.get("base_species", base_species_for(species))
    )
    result["happiness"] = clampi(
        int(result.get("happiness", result.get("friendship", info.get("base_happiness", 70)))),
        0,
        MAX_HAPPINESS
    )
    result["friendship"] = int(result["happiness"])
    result["lay_egg_seconds"] = float(result.get("lay_egg_seconds", LAY_EGG_SECONDS))
    result["friend_seconds"] = float(result.get("friend_seconds", FRIEND_SECONDS))
    result["mate_id"] = String(result.get("mate_id", ""))
    result["friend_id"] = String(result.get("friend_id", ""))
    result["in_habitat"] = bool(result.get("in_habitat", false))
    result["in_shelter"] = bool(result.get("in_shelter", false))
    result["nearby_pokemon"] = int(result.get("nearby_pokemon", 0))
    result["held_item"] = String(result.get("held_item", ""))
    result["harvest_progress"] = float(result.get("harvest_progress", 0.0))
    if not ecology_id.is_empty():
        result["ecology_id"] = ecology_id
    elif not result.has("ecology_id"):
        result["ecology_id"] = ""
    if not result.has("moves"):
        result["moves"] = moves_for_level(species, int(result.get("level", 1)))
    return result

static func habitat_groups(species: String) -> Array[String]:
    species = normalize_species(species)
    var data := PokemonData.info(species)
    var result: Array[String] = []
    _append_type_habitats(result, data.get("types", ["NORMAL"]))
    if species in ["dratini", "dragonair", "dragonite"]:
        result = ["water"]
    if result.is_empty():
        result.append("green")
    return result

static func _append_type_habitats(result: Array[String], raw_types: Array) -> void:
    for raw_type in raw_types:
        for raw_group in TYPE_HABITATS.get(String(raw_type).to_upper(), []):
            var group := String(raw_group)
            if not result.has(group):
                result.append(group)

static func harvest_items(species: String) -> Array[String]:
    species = normalize_species(species)
    if preload("res://scripts/rare_biome_legendaries.gd").HABITATS.has(species):
        return ["ANCIENTPOWDER"]
    var data := PokemonData.info(species)
    var result: Array[String] = []
    _append_type_harvest(result, data.get("types", ["NORMAL"]))
    if species in ["dratini", "dragonair", "dragonite"]:
        result.clear()
        _append_type_harvest(result, ["DRAGON"])
    if species in ["mareep", "flaaffy", "ampharos"]:
        result = ["SOFT WOOL"]
    elif (
            species in ["beedrill", "vespiquen", "cutiefly", "ribombee"]
            or "combee" in species
        ):
        result = ["HONEY"]
    elif species == "miltank":
        result = ["MOOMOO MILK"]
    elif species == "delibird":
        result.assign(DELIBIRD_HARVEST)
    elif "unown" in species:
        result = ["ANCIENTPOWDER"]
    elif "regi" in species or species == "mewtwo":
        result.append("ANCIENTPOWDER")
    elif species == "shuckle":
        result = ["BERRY JUICE"]
    elif species == "sableye":
        result.clear()
        # Game.evoStones order and weighting in Specie.initHabitatValues.
        for stone in ["WATER STONE", "FIRE STONE", "LEAF STONE", "THUNDERSTONE",
                "MOON STONE", "SUN STONE", "ICE STONE", "DAWN STONE",
                "DUSK STONE", "SHINY STONE", "SWEET APPLE"]:
            result.append_array([stone, "DARK ENERGY", "LIFE FORCE"])
    elif species in ["applin", "appletun"]:
        result.append_array(["SWEET APPLE", "SWEET APPLE", "SWEET APPLE"])
    elif species in ["staryu", "starmie"]:
        result.append_array(["STAR PIECE", "STAR PIECE"])
    if result.is_empty():
        result.append("MANURE")
    return result

static func _append_type_harvest(result: Array[String], raw_types: Array) -> void:
    # Java uses types.contains(), so a monotype's duplicated type is counted once.
    var seen: Dictionary = {}
    for raw_type in raw_types:
        var type_name := String(raw_type).to_upper()
        if seen.has(type_name):
            continue
        seen[type_name] = true
        for raw_item in TYPE_HARVEST.get(type_name, []):
            result.append(String(raw_item))

static func requires_night(species: String) -> bool:
    var data := PokemonData.info(normalize_species(species))
    for raw_type in data.get("types", []):
        if String(raw_type).to_upper() == "DARK":
            return true
    return false

static func harvest_seconds(species: String) -> float:
    return float(PokemonData.info(normalize_species(species)).get(
        "growth_ticks", 9000
    )) / 60.0

static func base_species_for(species: String) -> String:
    species = normalize_species(species)
    if "unown" in species:
        return "unown"
    if species in ["indeedee_male", "indeedee_female"]:
        return species
    var forms: Array = PokemonData.info(species).get("base_forms", [])
    for raw_form in forms:
        if typeof(raw_form) != TYPE_DICTIONARY:
            continue
        var candidate := normalize_species(String((raw_form as Dictionary).get("species", "")))
        if candidate == "nididoran_m":
            candidate = "nidoran_m"
        if not candidate.is_empty() and not PokemonData.info(candidate).is_empty():
            return candidate
    return species

static func can_mate(first: Dictionary, second: Dictionary) -> bool:
    if first.is_empty() or second.is_empty():
        return false
    if bool(first.get("is_egg", false)) or bool(second.get("is_egg", false)):
        return false
    var first_species := normalize_species(String(first.get("species", "")))
    var second_species := normalize_species(String(second.get("species", "")))
    if first_species == "ditto" and second_species == "ditto":
        return false
    var first_groups := _record_egg_groups(first)
    var second_groups := _record_egg_groups(second)
    if not share_egg_group(first_groups, second_groups):
        return false
    if first_groups.has("EGG_DITTO") or second_groups.has("EGG_DITTO"):
        return true
    if first_species != second_species:
        return false
    var first_gender := String(first.get("gender", "unknown")).to_lower()
    var second_gender := String(second.get("gender", "unknown")).to_lower()
    # Pokemon.checkHabitat uses this directional comparison, including its
    # unknown-gender case. Egg production separately requires female/Ditto.
    return second_gender == ("female" if first_gender == "male" else "male")

static func can_be_friends(first: Dictionary, second: Dictionary) -> bool:
    var first_groups := _record_egg_groups(first)
    var second_groups := _record_egg_groups(second)
    if first_groups.has("EGG_DITTO") or second_groups.has("EGG_DITTO"):
        return false
    if not share_egg_group(first_groups, second_groups):
        return false
    if can_mate(first, second):
        return false
    return not bool(first.get("is_egg", false)) and not bool(second.get("is_egg", false))

static func share_egg_group(first: Array[String], second: Array[String]) -> bool:
    if first.has("EGG_NONE") or second.has("EGG_NONE"):
        return false
    if first.has("EGG_DITTO") or second.has("EGG_DITTO"):
        return true
    for group in first:
        if second.has(group):
            return true
    return false

static func is_egg_parent_match(pokemon: Dictionary, egg: Dictionary) -> bool:
    if bool(pokemon.get("is_egg", false)):
        return false
    var pokemon_base := String(pokemon.get(
        "base_species", base_species_for(String(pokemon.get("species", "")))
    ))
    var egg_base := String(egg.get(
        "base_species", base_species_for(String(egg.get("species", "")))
    ))
    return (
        pokemon_base == egg_base
        or share_egg_group(_record_egg_groups(pokemon), _record_egg_groups(egg))
    )

static func egg_record(
        parent: Dictionary,
        partner: Dictionary,
        rng: RandomNumberGenerator
    ) -> Dictionary:
    var producer_species := normalize_species(String(parent.get("species", "pidgey")))
    if producer_species == "ditto":
        producer_species = normalize_species(String(partner.get("species", "pidgey")))
    var species := base_species_for(producer_species)
    if species == "nididoran_m":
        species = "nidoran_m"
    if species == "nidoran_f" and rng.randi_range(0, 255) < 128:
        species = "nidoran_m"
    var info := PokemonData.info(species)
    var cycles := maxi(1, int(info.get("egg_cycles", 20)))
    var inherited: Array[String] = []
    var producer_moves := _normalized_moves(parent.get("moves", []))
    var partner_moves := _normalized_moves(partner.get("moves", []))
    for raw_move in info.get("egg_moves", []):
        var move := String(raw_move).to_upper().replace(" ", "_")
        if not PokemonData.move_info(move).is_empty() and partner_moves.has(move) and not producer_moves.has(move):
            inherited.append(move)
    var parent_state := PokemonState.ensure_core(parent, rng)
    var partner_state := PokemonState.ensure_core(partner, rng)
    var hatch_state := PokemonState.ensure_core({
        "species":species, "level":5, "original_trainer":"PLAYER",
        "met_location":"HABITAT EGG"
    }, rng)
    var inherited_ivs: Dictionary = hatch_state.get("ivs", {})
    var available_stats: Array = PokemonState.STAT_KEYS.duplicate()
    for inherited_slot in range(3):
        var pick := rng.randi_range(0, available_stats.size() - 1)
        var stat_name := String(available_stats.pop_at(pick))
        var source_parent := parent_state if rng.randi_range(0, 1) == 0 else partner_state
        inherited_ivs[stat_name] = int((source_parent.get("ivs", {}) as Dictionary).get(stat_name, 0))
    hatch_state["ivs"] = inherited_ivs
    return {
        "species": species,
        "egg_species": species,
        "base_species": base_species_for(species),
        "level": 5,
        "is_egg": true,
        "shiny": bool(hatch_state["shiny"]),
        "is_shiny": bool(hatch_state["shiny"]),
        "gender": gender_from_ratio(String(info.get("gender_ratio", "GENDER_UNKNOWN")), rng),
        "personality": int(hatch_state.get("personality", 0)),
        "nature": String(hatch_state.get("nature", "HARDY")),
        "ability": String(hatch_state.get("ability", "")),
        "ability_slot": int(hatch_state.get("ability_slot", 0)),
        "ivs": inherited_ivs,
        "evs": hatch_state.get("evs", {}).duplicate(true),
        "original_trainer": "PLAYER",
        "met_level": 5,
        "met_location": "HABITAT EGG",
        "pokeball": "POKE BALL",
        "egg_groups": _string_array(info.get("egg_groups", ["EGG_NONE", "EGG_NONE"])),
        "hatch_cycles": cycles,
        "hatch_steps": cycles * EGG_STEP_INTERVAL,
        "inherited_moves": inherited,
        "parent_ids": [String(parent.get("ecology_id", "")), String(partner.get("ecology_id", ""))]
    }

static func moves_for_level(species: String, level: int) -> Array[String]:
    var result: Array[String] = []
    for raw_learned in PokemonData.info(normalize_species(species)).get("learnset", []):
        if typeof(raw_learned) != TYPE_DICTIONARY:
            continue
        var learned := raw_learned as Dictionary
        if int(learned.get("level", 1)) <= level:
            result.append(String(learned.get("move", "TACKLE")).to_upper())
    if result.is_empty():
        result.append("TACKLE")
    if result.size() > 4:
        result = result.slice(result.size() - 4)
    return result

static func is_food(item_name: String) -> bool:
    return FOOD_HAPPINESS.has(item_name.to_upper())

static func food_happiness(item_name: String) -> int:
    return int(FOOD_HAPPINESS.get(item_name.to_upper(), 0))

static func _record_egg_groups(record: Dictionary) -> Array[String]:
    if record.has("egg_groups"):
        return _string_array(record.get("egg_groups", []))
    return _string_array(PokemonData.info(String(record.get("species", ""))).get(
        "egg_groups", ["EGG_NONE", "EGG_NONE"]
    ))

static func _normalized_moves(raw_moves: Variant) -> Array[String]:
    var result: Array[String] = []
    if typeof(raw_moves) != TYPE_ARRAY:
        return result
    for raw_move in raw_moves:
        result.append(String(raw_move).to_upper().replace(" ", "_"))
    return result

static func _string_array(raw_values: Variant) -> Array[String]:
    var result: Array[String] = []
    if typeof(raw_values) != TYPE_ARRAY:
        return result
    for raw_value in raw_values:
        result.append(String(raw_value).to_upper())
    return result

# Tile.java interaction rule; Pokemon.java baseSpecies built from both source ASM files.
const SOURCE_EVOLVED_SPECIES := ["abomasnow", "accelgor", "aegislash", "aexeggutor", "aggron", "alakazam", "alcremie", "altaria", "amarowak", "ambipom", "amoonguss", "ampharos", "appletun", "araichu", "araquanid", "arbok", "arcanine", "archeops", "ariados", "armaldo", "aromatisse", "atk_eq_def", "atk_gt_def", "atk_lt_def", "aurorus", "avalugg", "azumarill", "banette", "barbaracle", "barraskewda", "bastiodon", "bayleef", "beartic", "beautifly", "beedrill", "beheeyem", "bellossom", "bewear", "bibarel", "bisharp", "blastoise", "blaziken", "blissey", "boldore", "boltund", "braixen", "braviary", "breloom", "brionne", "bronzong", "butterfree", "cacturne", "camerupt", "carkol", "carracosta", "cascoon", "centiskorch", "chandelure", "chansey", "charizard", "charjabug", "charmeleon", "cherrim", "chesnaught", "chimecho", "cinccino", "cinderace", "clawitzer", "claydol", "clefable", "clefairy", "cloyster", "coalossal", "cofagrigus", "combee_female", "combusken", "conkeldurr", "copperajah", "corviknight", "corvisquire", "cosmoem", "crabominable", "cradily", "crawdaunt", "crobat", "croconaw", "crustle", "darmanitan", "darmanitanzen", "dartrix", "decidueye", "delcatty", "delphox", "dewgong", "dewott", "diggersby", "dodrio", "donphan", "dottler", "doublade", "dragalge", "dragapult", "dragonair", "dragonite", "drakloak", "drapion", "drednaw", "drifblim", "drizzile", "dubwool", "dugtrio", "duosion", "dusclops", "dusknoir", "dustox", "eelektrik", "eelektross", "eldegoss", "electabuzz", "electivire", "electrode", "emboar", "empoleon", "escavalier", "espeon", "excadrill", "exeggutor", "exploud", "fearow", "feraligatr", "ferrothorn", "flaaffy", "flareon", "fletchinder", "floatzel", "floette", "florges", "flygon", "forretress", "fraxure", "frogadier", "froslass", "frosmoth", "furret", "gabite", "gallade", "galvantula", "garbodor", "garchomp", "gardevoir", "gastrodon", "gdarmanitan", "gengar", "gigalith", "glaceon", "glalie", "gliscor", "gloom", "gogoat", "golbat", "golduck", "golem", "golisopod", "golurk", "goodra", "gorebyss", "gothitelle", "gothorita", "gourgeist", "granbull", "grapploct", "graveler", "greedent", "greninja", "grimmsnarl", "grotle", "grovyle", "grumpig", "gumshoos", "gurdurr", "gyarados", "hakamoo", "hariyama", "hatterene", "hattrem", "haunter", "haxorus", "heliolisk", "herdier", "hippowdon", "hitmonchan", "hitmonlee", "hitmontop", "honchkrow", "houndoom", "huntail", "hydreigon", "hypno", "incineroar", "infernape", "inteleon", "ivysaur", "jellicent", "jigglypuff", "jolteon", "jumpluff", "jynx", "kabutops", "kadabra", "kakuna", "kingdra", "kingler", "kirlia", "klang", "klinklang", "kommoo", "kricketune", "krokorok", "krookodile", "lairon", "lampent", "lanturn", "leafeon", "leavanny", "ledian", "lickilicky", "liepard", "lilligant", "linoone", "lombre", "lopunny", "loudred", "lucario", "ludicolo", "lumineon", "lunala", "lurantis", "luxio", "luxray", "lycanroc", "machamp", "machoke", "magcargo", "magmar", "magmortar", "magneton", "magnezone", "malamar", "mamoswine", "mandibuzz", "manectric", "mantine", "marill", "marowak", "marshtomp", "masquerain", "medicham", "meganium", "meowstic", "metagross", "metang", "metapod", "mienshao", "mightyena", "milotic", "mismagius", "monferno", "morgrem", "mothim", "mrmime", "mudsdale", "muk", "musharna", "naganadel", "nidoking", "nidoqueen", "nidorina", "nidorino", "ninetales", "ninjask", "noctowl", "noivern", "nuzleaf", "octillery", "omastar", "orbeetle", "palossand", "palpitoad", "pangoro", "parasect", "pelipper", "persian", "pidgeot", "pidgeotto", "pignite", "pikachu", "piloswine", "politoed", "poliwhirl", "poliwrath", "polteageist", "porygon2", "porygonz", "primarina", "primeape", "prinplup", "probopass", "pupitar", "purugly", "pyroar", "quagsire", "quilava", "quilladin", "raboot", "raichu", "rampardos", "rapidash", "raticate", "reuniclus", "rhydon", "rhyperior", "ribombee", "rillaboom", "roselia", "roserade", "runerigus", "salamence", "salazzle", "samurott", "sandaconda", "sandslash", "sawsbuck", "sceptile", "scizor", "scolipede", "scrafty", "seadra", "seaking", "sealeo", "seismitoad", "serperior", "servine", "sharpedo", "shedinja", "shelgon", "shiftry", "shiinotic", "silcoon", "silvally", "simipour", "simisage", "simisear", "skiploom", "skuntank", "slaking", "sliggoo", "slowbro", "slowking", "slurpuff", "snorlax", "solgaleo", "spewpa", "staraptor", "staravia", "starmie", "steelix", "steenee", "stoutland", "sudowoodo", "sunflora", "swadloon", "swalot", "swampert", "swanna", "swellow", "swoobat", "sylveon", "talonflame", "tangrowth", "tentacruel", "thievul", "thwackey", "togekiss", "togetic", "torracat", "torterra", "toucannon", "toxapex", "toxicroak", "toxtricity", "tranquill", "trevenant", "trumbeak", "tsareena", "typhlosion", "tyranitar", "tyrantrum", "umbreon", "unfezant", "ursaring", "urshifu", "vanillish", "vanilluxe", "vaporeon", "venomoth", "venusaur", "vespiquen", "vibrava", "victreebel", "vigoroth", "vikavolt", "vileplume", "vivillon", "volcarona", "wailord", "walrein", "wartortle", "watchog", "weavile", "weepinbell", "weezing", "whimsicott", "whirlipede", "whiscash", "wigglytuff", "wobbuffet", "wormadam", "xatu", "yanmega", "zebstrika", "zoroark", "zweilous"]

static func wild_interaction_kind(species: String) -> String:
    species = PokemonData.source_species(species)
    if species in ["ekans", "pidgey", "spearow", "rattata", "chansey"]:
        return "SKITTISH"
    if species in ["poochyena", "sneasel", "skarmory", "pinsir", "tauros", "duraludon"]:
        return "AGGRESSIVE"
    if species in SOURCE_EVOLVED_SPECIES and species not in ["bellossom", "gardevoir", "jumpluff", "marill", "chansey", "blissey", "pikachu"]:
        return "AGGRESSIVE"
    return "FRIENDLY"
