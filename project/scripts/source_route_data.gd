class_name SourceRouteData
extends RefCounted

# PokeWilds 0.8.11 Route.java, with approved forest Cleffa/Igglybuff/Sunkern
# and mountain Mawile additions (.102). Existing day/night restrictions apply.
# Ordering and duplicate
# entries are intentional: the Java game samples uniformly by list index, so
# duplicates are encounter weights.
const ALLOWED_POKEMON := {
    "mountain1": ["rhydon", "rhyhorn", "onix", "machop", "machoke", "cubone", "phanpy", "skarmory", "whismur", "makuhita", "duraludon", "mawile"],
    "mountain1_water1": ["magikarp", "poliwag", "goldeen"],
    "deep_forest": ["zubat", "golbat", "houndour", "murkrow", "nidorina", "nidorino", "scyther", "pinsir", "growlithe", "vulpix", "breloom", "sableye", "ralts", "gastly", "volbeat", "noibat"],
    "forest1": ["oddish", "gloom", "pidgey", "spearow", "taillow", "hoppip", "bulbasaur", "charmander", "chikorita", "paras", "pikachu", "weedle", "caterpie", "spinarak", "ledyba", "hoothoot", "shroomish", "combee", "cleffa", "igglybuff", "sunkern"],
    "savanna1": [
        "ponyta", "miltank",
        "drowzee", "oddish", "chikorita", "bulbasaur", "hoppip", "pidgey", "taillow", "charmander", "cyndaquil", "mareep", "ekans", "doduo", "sentret", "rattata", "yanma", "poochyena", "eevee", "cutiefly", "shinx",
        "drowzee", "oddish", "chikorita", "bulbasaur", "hoppip", "pidgey", "taillow", "charmander", "cyndaquil", "mareep", "ekans", "doduo", "sentret", "rattata", "yanma", "poochyena", "eevee", "cutiefly", "shinx"
    ],
    "savanna2": ["ponyta", "miltank", "tauros", "drowzee", "spearow", "girafarig", "aipom", "doduo", "sentret", "rattata", "yanma", "eevee", "shinx", "chansey", "scyther", "pinsir", "rhyhorn", "nidoran_m", "nidoran_f", "kangaskhan", "phanpy", "natu", "mankey", "mareep", "plusle", "minun"],
    "beach1": ["squirtle", "krabby", "totodile", "shellder", "wooper", "staryu", "marill", "slowpoke", "psyduck", "wingull", "corphish"],
    "beach2": ["squirtle", "krabby", "totodile", "shellder", "wooper", "staryu", "marill", "slowpoke", "psyduck", "corphish", "octillery", "araichu", "aexeggutor", "sandygast", "pikipek"],
    "beach2_rocks": ["corsola", "corsola", "corsola", "corsola", "squirtle", "krabby", "totodile", "shellder", "staryu", "corphish"],
    "beach2_plateau": ["corsola", "corsola", "corsola", "corsola", "squirtle", "krabby", "totodile", "shellder", "staryu", "corphish", "wingull"],
    "beach2_water": [
        "staryu", "squirtle", "mantine", "totodile", "tentacool", "magikarp",
        "staryu", "squirtle", "mantine", "totodile", "tentacool", "magikarp",
        "staryu", "squirtle", "mantine", "totodile", "tentacool", "magikarp",
        "lapras", "araichu"
    ],
    "desert1": ["kangaskhan", "cubone", "numel", "camerupt", "drapion"],
    "wooded_lake1": ["pidgey", "ledyba", "cutiefly", "hoothoot", "zubat", "paras", "scyther", "pinsir", "spinarak", "murkrow", "chingling", "pichu", "ekans", "oddish", "natu", "taillow", "ralts", "shroomish", "phanpy", "wooper", "yanma", "azurill", "exeggcute", "slowpoke", "poliwag", "makuhita"],
    "wooded_lake_water1": ["magikarp", "surskit", "lotad", "wooper", "azurill", "goldeen", "buizel"],
    "wooded_lake_fishing1": ["magikarp", "poliwag", "goldeen", "dratini", "feebas", "corphish"],
    "graveyard1": ["gastly", "litwick", "murkrow", "drifloon", "misdreavus", "zubat", "chingling", "chimecho", "cubone", "houndour", "hoothoot", "spinarak", "absol", "duskull"],
    "sand_pit1": ["diglett", "sandile"],
    "oasis1": ["surskit", "poliwag", "lotad", "lombre", "zigzagoon", "sandshrew", "exeggcute"],
    "ruins1_outer": ["sigilyph", "natu", "nosepass", "beldum", "metang", "smeargle", "solrock", "bronzor"],
    "ruins1_inner": ["lunatone", "elgyem", "duskull", "sandile", "sandshrew"],
    "snow1": ["larvitar", "sneasel", "aron", "swinub", "piloswine", "jynx", "delibird", "snorunt", "riolu", "gdarumaka"],
    "fossil_lab1": [],
    "pkmnmansion1": ["magmar", "grimer", "rattata", "koffing", "vulpix", "growlithe", "ponyta", "ditto"],
    "regi_cave1": [],
    "oasis_pond1": ["poliwag", "goldeen", "feebas", "remoraid"],
    "sea1": ["tentacool", "magikarp", "corsola", "horsea", "qwilfish"],
    "ocean1": ["carvanha"],
    "river1": ["magikarp", "poliwag", "goldeen", "remoraid"],
    "sand_fishing1": ["trapinch", "trapinch", "sandile", "sandile", "gible"],
    "rock_smash1": ["geodude", "geodude", "shuckle"],
    "": [],
    "volcano1": ["slugma", "geodude", "charmander", "magmar", "torkoal", "cubone", "koffing", "diglett", "numel", "amarowak"]
}

const DEFAULT_ALLOWED_POKEMON := ["mamoswine", "weavile", "magmortar", "electivire", "metagross"]
const GOOD_ROD_POKEMON := ["corsola", "horsea"]
const SUPER_ROD_POKEMON := ["feebas", "remoraid", "qwilfish", "gible"]
const DAY_POKEMON := ["ledyba", "ledian", "sunkern", "sunflora", "spearow", "fearow", "pidgey", "pidgeotto", "pidgeot", "ponyta", "rapidash", "growlithe", "arcanine", "doduo", "dodrio", "hoppip", "skiploom", "jumpluff", "miltank", "tauros", "solrock", "sentret", "furret", "bellossom", "mawile", "yanma"]
const NIGHT_POKEMON := ["hoothoot", "noctowl", "spinarak", "ariados", "houndour", "houndoom", "poochyena", "mightyena", "oddish", "gloom", "vileplume", "murkrow", "honchkrow", "sneasel", "zubat", "golbat", "crobat", "lunatone", "cleffa", "clefairy", "clefable", "igglybuff", "jigglypuff", "wigglytuff", "sableye", "gastly", "haunter", "gengar"]

const DUNGEON_ROUTES := {
    "pkmnmansion1": true,
    "fossil_lab1": true,
    "regi_cave1": true,
    "ruins1_inner": true
}

const ROUTE_MUSIC := {
    "ruins1_inner": ["relic_castle2", "relic_castle2"],
    "fossil_lab1": ["silence1", "silence1"],
    "graveyard1": ["old_chateau3", "old_chateau3"],
    "pkmnmansion1": ["pkmnmansion", "pkmnmansion"],
    "regi_cave1": ["sealed_chamber2", "sealed_chamber2"],
    "desert1": ["route_111-2", "route_111-2"],
    "ruins1_outer": ["route_111-2", "route_111-2"],
    "oasis1": ["route_111-2", "route_111-2"],
    "sand_pit1": ["route_111-2", "route_111-2"],
    "volcano1": ["ambient_rumbling", "ambient_rumbling"],
    "deep_forest": ["DP_EternaForest", "DP_EternaForest"],
    "wooded_lake1": ["lake6", "BW_Dreamyard-stitched", "national_park1", "pokemon_tcg_gym1", "overw3", "DP_League"],
    "wooded_lake_water1": ["lake6", "BW_Dreamyard-stitched", "national_park1", "pokemon_tcg_gym1", "overw3", "DP_League"],
    "snow1": ["pokemon_tcg_gym1", "overw3", "DP_Route216-stitched", "national_park1"]
}

const DEFAULT_MUSIC := ["pokemon_tcg_gym1", "overw3", "route_42", "national_park1", "viridian_forest_gs", "route_3_gs", "route_3_rb", "route_1", "route_idk1"]

static func allowed_pokemon(route_name: String) -> Array:
    if ALLOWED_POKEMON.has(route_name):
        return (ALLOWED_POKEMON[route_name] as Array).duplicate()
    return DEFAULT_ALLOWED_POKEMON.duplicate()

static func is_dungeon(route_name: String) -> bool:
    return DUNGEON_ROUTES.has(route_name)

static func route_type(route_name: String) -> String:
    if route_name in ["desert1", "ruins1_outer", "oasis1", "sand_pit1"]:
        return "desert"
    if route_name == "graveyard1":
        return "graveyard"
    if route_name == "volcano1":
        return "volcano"
    if route_name == "deep_forest":
        return "deep_forest"
    return ""

static func music(route_name: String) -> Array:
    if ROUTE_MUSIC.has(route_name):
        return (ROUTE_MUSIC[route_name] as Array).duplicate()
    return DEFAULT_MUSIC.duplicate()

static func good_rod_pokemon() -> Array:
    return GOOD_ROD_POKEMON.duplicate()

static func super_rod_pokemon() -> Array:
    return SUPER_ROD_POKEMON.duplicate()

static func day_pokemon() -> Array:
    return DAY_POKEMON.duplicate()

static func night_pokemon() -> Array:
    return NIGHT_POKEMON.duplicate()
