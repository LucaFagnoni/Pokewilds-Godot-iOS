extends RefCounted
static var online_enabled:=false
static var _online_recipes:Array=[]
const PRIVATE_CHEST={"name":"PRIVATE CHEST","display_name":"PRIVATE","cost":{"LOG":2},"solid":true}
## The same purple chest in single-player, where it holds the storage shared
## by every single-player save on the device.
const SHARED_CHEST={"name":"PRIVATE CHEST","display_name":"SHARED","cost":{"LOG":2},"solid":true}
static var _offline_recipes:Array=[]

static func build_recipes()->Array:
    if not online_enabled:
        if _offline_recipes.is_empty():_offline_recipes=BUILD_RECIPES.duplicate();_offline_recipes.append(SHARED_CHEST)
        return _offline_recipes
    if _online_recipes.is_empty():_online_recipes=BUILD_RECIPES.duplicate();_online_recipes.append(PRIVATE_CHEST)
    return _online_recipes
const ItemData = preload("res://scripts/item_data.gd")
const MATERIALS := [
    "LOG", "GRASS", "MIRACLE SEED", "MANURE", "SOFT FEATHER",
    "HARD SHELL", "POISON BARB", "MAGNET", "CHARCOAL", "PSI ENERGY",
    "DARK ENERGY", "LIFE FORCE", "HONEY", "SOFT SAND", "NEVERMELTICE",
    "SILKY THREAD", "HARD STONE", "STARDUST", "STAR PIECE", "DRAGON SCALE",
    "DRAGON FANG", "METAL COAT", "SOFT WOOL", "BINDING BAND", "CLEAR GLASS",
    "THIN PAPER", "SPELL TAG", "DRY SAND", "LIGHT CLAY", "CURSED SOIL",
    "MYSTIC SOIL", "DAMP SOIL", "DRY SOIL", "FLOWERS", "ASHEN SOIL",
    "BIG PEARL", "SCRAP METAL", "MYSTIC WATER", "CONCRETE", "BERRY JUICE",
    "ANCIENTPOWDER", "BLACK APRICORN", "BLUE APRICORN", "GREEN APRICORN",
    "PINK APRICORN", "RED APRICORN", "WHITE APRICORN", "YELLOW APRICORN",
    "DUSK STONE"
]

const CRAFTED_ITEMS := [
    "HEAVY BALL", "LURE BALL", "FRIEND BALL", "LOVE BALL", "LEVEL BALL",
    "FAST BALL", "MOON BALL", "SOFT BEDDING", "REPEL", "MAX REPEL",
    "RARE CANDY", "SILPH SCOPE", "RAGECANDYBAR", "OLD ROD", "GOOD ROD",
    "SUPER ROD", "POKE BALL", "GREAT BALL", "ULTRA BALL", "DUSK BALL",
    "NET BALL", "DIVE BALL", "QUICK BALL", "HEAL BALL", "NEST BALL",
    "DREAM BALL", "TIMER BALL"
]

const CAMPFIRE_RECIPES := [
    # Early catch progression: source Apricorns can immediately become balls.
    # ANY APRICORN is a pseudo-cost consumed by can_afford()/consume().
    {"name":"POKE BALL", "cost":{"ANY APRICORN":1}},
    {"name":"HEAVY BALL", "cost":{"BLACK APRICORN":1}},
    {"name":"LURE BALL", "cost":{"BLUE APRICORN":1}},
    {"name":"FRIEND BALL", "cost":{"GREEN APRICORN":1}},
    {"name":"LOVE BALL", "cost":{"PINK APRICORN":1}},
    {"name":"LEVEL BALL", "cost":{"RED APRICORN":1}},
    {"name":"FAST BALL", "cost":{"WHITE APRICORN":1}},
    {"name":"MOON BALL", "cost":{"YELLOW APRICORN":1}},
    {"name":"SOFT BEDDING", "cost":{"SOFT FEATHER":3, "SILKY THREAD":3}},
    {"name":"REPEL", "cost":{"CHARCOAL":1, "MANURE":1}},
    {"name":"MAX REPEL", "cost":{"REPEL":1, "POISON BARB":1}},
    {"name":"RARE CANDY", "cost":{"BERRY JUICE":3, "ANCIENTPOWDER":1}},
    {"name":"CLEAR GLASS", "cost":{"SOFT SAND":3}},
    {"name":"SILPH SCOPE", "cost":{"CLEAR GLASS":2, "METAL COAT":2}},
    {"name":"BINDING BAND", "cost":{"GRASS":3}},
    {"name":"THIN PAPER", "cost":{"LOG":1}},
    {"name":"RAGECANDYBAR", "cost":{"HONEY":2, "CHARCOAL":1}},
    {"name":"OLD ROD", "cost":{"LOG":1, "SILKY THREAD":1}},
    {"name":"GOOD ROD", "cost":{"OLD ROD":1, "METAL COAT":2}},
    {"name":"SUPER ROD", "cost":{"GOOD ROD":1, "MAGNET":3}},
    {"name":"SPELL TAG", "cost":{"LIFE FORCE":1, "THIN PAPER":1}},
    {"name":"STARDUST", "cost":{"STAR PIECE":1}}
]

const KILN_RECIPES := [
    {"name":"GREAT BALL", "cost":{"POKE BALL":1, "METAL COAT":1}},
    {"name":"ULTRA BALL", "cost":{"GREAT BALL":1, "LIFE FORCE":1}},
    {"name":"DUSK BALL", "cost":{"MOON BALL":1, "DARK ENERGY":1}},
    {"name":"NET BALL", "cost":{"LURE BALL":1, "SILKY THREAD":1}},
    {"name":"DIVE BALL", "cost":{"LURE BALL":1, "HARD SHELL":1}},
    {"name":"QUICK BALL", "cost":{"FAST BALL":1, "MAGNET":1}},
    {"name":"HEAL BALL", "cost":{"FRIEND BALL":1, "STARDUST":1}},
    {"name":"NEST BALL", "cost":{"FRIEND BALL":1, "BINDING BAND":1}},
    {"name":"DREAM BALL", "cost":{"LOVE BALL":1, "PSI ENERGY":1}},
    {"name":"TIMER BALL", "cost":{"HEAVY BALL":1, "HARD STONE":1}}
]

const REGI_RECIPES := [
    {"name":"REGISTEEL", "event":true, "cost":{"METAL COAT":47, "SPELL TAG":1}},
    {"name":"REGIROCK", "event":true, "cost":{"HARD STONE":47, "SPELL TAG":1}},
    {"name":"REGICE", "event":true, "cost":{"NEVERMELTICE":47, "SPELL TAG":1}},
    {"name":"REGIDRAGO", "event":true, "cost":{"DRAGON SCALE":43, "DRAGON FANG":4, "SPELL TAG":1}},
    {"name":"REGIELEKI", "event":true, "cost":{"MAGNET":43, "BINDING BAND":4, "SPELL TAG":1}}
]

const FOSSIL_RECIPES := [
    {"name":"OLD AMBER", "event":true, "cost":{"OLD AMBER":1}},
    {"name":"HELIX FOSSIL", "event":true, "cost":{"HELIX FOSSIL":1}},
    {"name":"DOME FOSSIL", "event":true, "cost":{"DOME FOSSIL":1}},
    {"name":"CLAW FOSSIL", "event":true, "cost":{"CLAW FOSSIL":1}},
    {"name":"ROOT FOSSIL", "event":true, "cost":{"ROOT FOSSIL":1}},
    {"name":"SHIELD FOSSIL", "event":true, "cost":{"SHIELD FOSSIL":1}},
    {"name":"SKULL FOSSIL", "event":true, "cost":{"SKULL FOSSIL":1}}
]

const BUILD_RECIPES := [
    {"name":"TORCH", "cost":{"LOG":1, "GRASS":1}, "solid":false},
    {"name":"STORAGE BOX", "cost":{"LOG":2}, "solid":true},
    {"name":"SIGN", "cost":{"LOG":1, "GRASS":1}, "solid":true},
    {"name":"STATUE", "cost":{"HARD STONE":2}, "solid":true},
    {"name":"PLANT", "cost":{"LOG":1, "MIRACLE SEED":1}, "solid":false},
    {"name":"BEACON", "display_name":"WARP TILE", "cost":{"DUSK STONE":2, "PSI ENERGY":2, "LIFE FORCE":2}, "solid":true},
    {"name":"GRAVE", "cost":{"HARD STONE":1}, "solid":true},
    {"name":"FLOWERS", "cost":{"MIRACLE SEED":1, "HARD STONE":1}, "solid":false},
    {"name":"BRIDGE", "cost":{"LOG":1, "HARD STONE":1}, "solid":false},
    {"name":"FENCE", "cost":{"LOG":1, "GRASS":1}, "solid":true},
    {"name":"CAMPFIRE", "cost":{"LOG":4, "GRASS":2}, "solid":true, "station":"CAMPFIRE"},
    {"name":"WALL", "display_name":"WOOD WALL", "cost":{"LOG":1, "GRASS":1}, "solid":true},
    {"name":"ROOF", "display_name":"WOOD ROOF", "cost":{"LOG":1, "GRASS":1}, "solid":true},
    {"name":"DOOR", "display_name":"WOOD DOOR", "cost":{"LOG":1, "GRASS":1}, "solid":false},
    {"name":"SAVANNA WALL", "cost":{"LOG":1, "GRASS":1}, "solid":true},
    {"name":"SAVANNA ROOF", "cost":{"LOG":1, "GRASS":1}, "solid":true},
    {"name":"SAVANNA DOOR", "cost":{"LOG":1, "GRASS":1}, "solid":false},
    {"name":"TUNDRA WALL", "cost":{"LOG":1, "GRASS":1}, "solid":true},
    {"name":"TUNDRA ROOF", "cost":{"LOG":1, "GRASS":1}, "solid":true},
    {"name":"TUNDRA DOOR", "cost":{"LOG":1, "GRASS":1}, "solid":false},
    {"name":"DESERT WALL", "cost":{"HARD STONE":1}, "solid":true},
    {"name":"DESERT ROOF", "cost":{"HARD STONE":1}, "solid":true},
    {"name":"DESERT DOOR", "cost":{"HARD STONE":1}, "solid":false},
    {"name":"LAKE WALL", "cost":{"LOG":1, "GRASS":1}, "solid":true},
    {"name":"LAKE ROOF", "cost":{"LOG":1, "GRASS":1}, "solid":true},
    {"name":"LAKE DOOR", "cost":{"LOG":1, "GRASS":1}, "solid":false},
    {"name":"STILT WALL", "cost":{"LOG":1, "GRASS":1}, "solid":true},
    {"name":"STILT ROOF", "cost":{"LOG":1, "GRASS":1}, "solid":true},
    {"name":"STILT DOOR", "cost":{"LOG":1, "GRASS":1}, "solid":false},
    {"name":"SNOW WALL", "cost":{"LOG":1, "GRASS":1}, "solid":true},
    {"name":"SNOW ROOF", "cost":{"LOG":1, "GRASS":1}, "solid":true},
    {"name":"SNOW DOOR", "cost":{"LOG":1, "GRASS":1}, "solid":false},
    {"name":"CARPET 1", "cost":{"GRASS":1}, "solid":false, "indoors":true},
    {"name":"CARPET 2", "cost":{"GRASS":1}, "solid":false, "indoors":true},
    {"name":"CARPET 3", "cost":{"GRASS":1}, "solid":false, "indoors":true},
    {"name":"CARPET 4", "cost":{"GRASS":1}, "solid":false, "indoors":true},
    {"name":"CARPET 5", "cost":{"GRASS":1}, "solid":false, "indoors":true},
    {"name":"CARPET 6", "cost":{"GRASS":1}, "solid":false, "indoors":true},
    {"name":"CARPET 7", "cost":{"GRASS":1}, "solid":false, "indoors":true},
    {"name":"CARPET 8", "cost":{"GRASS":1}, "solid":false, "indoors":true},
    {"name":"INDOOR WINDOW 1", "display_name":"WINDOW 1", "cost":{"CLEAR GLASS":1}, "solid":false, "indoors":true},
    {"name":"INDOOR WINDOW 2", "display_name":"WINDOW 2", "cost":{"CLEAR GLASS":1}, "solid":false, "indoors":true},
    {"name":"WINDOW", "cost":{"LOG":1, "CLEAR GLASS":1}, "solid":true},
    {"name":"CHIMNEY", "cost":{"LOG":1}, "solid":true},
    {"name":"STAIRS", "cost":{"LOG":2}, "solid":false, "indoors":true},
    {"name":"KILN", "cost":{"CHARCOAL":2, "HARD STONE":2}, "solid":true, "indoors":true, "station":"KILN"},
    {"name":"BED", "cost":{"LOG":4, "SOFT BEDDING":1}, "solid":true, "indoors":true},
    {"name":"INTERIOR WALL", "cost":{"LOG":1, "GRASS":1}, "solid":true, "indoors":true},
    {"name":"CLOCK", "cost":{"LOG":1, "CLEAR GLASS":1}, "solid":true, "indoors":true},
    {"name":"COUCH", "cost":{"SOFT WOOL":1, "LOG":1}, "solid":true, "indoors":true},
    {"name":"COUCH 2", "cost":{"SOFT WOOL":1, "LOG":1}, "solid":true, "indoors":true},
    {"name":"COUCH 3", "cost":{"SOFT WOOL":1, "LOG":1}, "solid":true, "indoors":true},
    {"name":"COUCH 4", "cost":{"SOFT WOOL":1, "LOG":1}, "solid":true, "indoors":true},
    {"name":"COUCH 5", "cost":{"SOFT WOOL":1, "LOG":1}, "solid":true, "indoors":true},
    {"name":"PLANT 2", "cost":{"LOG":1, "MIRACLE SEED":1}, "solid":true, "indoors":true},
    {"name":"VANITY 2", "cost":{"LOG":1, "CLEAR GLASS":1}, "solid":true, "indoors":true},
    {"name":"TRASH CAN", "cost":{"LOG":1}, "solid":true, "indoors":true},
    {"name":"PICHU DOLL", "cost":{"SOFT WOOL":1, "MAGNET":1}, "solid":true, "indoors":true},
    {"name":"DUSKULL DOLL", "cost":{"SOFT WOOL":1, "SPELL TAG":1}, "solid":true, "indoors":true},
    {"name":"SKITTY DOLL", "cost":{"SOFT WOOL":1, "GRASS":1}, "solid":true, "indoors":true},
    {"name":"JIGGLYPUFF DOLL", "cost":{"SOFT WOOL":1, "GRASS":1}, "solid":true, "indoors":true},
    {"name":"SHELF", "cost":{"LOG":1}, "solid":true, "indoors":true},
    {"name":"DRESSER", "cost":{"LOG":1}, "solid":true, "indoors":true},
    {"name":"VANITY", "cost":{"LOG":1, "CLEAR GLASS":1}, "solid":true, "indoors":true},
    {"name":"STOOL", "cost":{"LOG":1}, "solid":false, "indoors":true},
    {"name":"TABLE", "cost":{"LOG":1}, "solid":true, "indoors":true},
    {"name":"FLOOR", "cost":{"GRASS":1}, "solid":false, "indoors":true}
]

const APRICORNS := [
    "BLACK APRICORN", "BLUE APRICORN", "GREEN APRICORN", "PINK APRICORN",
    "RED APRICORN", "WHITE APRICORN", "YELLOW APRICORN"
]

# Current-port species already present in M30. Their yields/requirements follow
# the PokeWilds type-based crafting loop without inventing extra species/sprites.
const CURRENT_POKEMON_HARVEST := {
    "pidgey": {"item":"SOFT FEATHER", "habitat":"TREE"},
    "rattata": {"item":"MANURE", "habitat":"BASIC"},
    "caterpie": {"item":"SILKY THREAD", "habitat":"FLOWERS"},
    "pikachu": {"item":"MAGNET", "habitat":"BASIC"}
}

static func ensure_inventory(source: Dictionary) -> Dictionary:
    var result: Dictionary = {}
    for raw_name in source.keys():
        var normalized := ItemData.normalize_name(String(raw_name))
        result[normalized] = int(result.get(normalized, 0)) + int(source[raw_name])
    for name in ItemData.all_items():
        if not result.has(name):
            result[name] = 0
    for name in MATERIALS:
        if not result.has(name):
            result[name] = 0
    for name in CRAFTED_ITEMS:
        if not result.has(name):
            result[name] = 0
    return result

static func recipes_for_station(station: String) -> Array:
    if station in ["CAMPFIRE", "WORK TABLE"]:
        return CAMPFIRE_RECIPES
    if station == "KILN":
        return KILN_RECIPES
    if station == "REGI FORGE":
        return REGI_RECIPES
    if station == "FOSSIL REVIVER":
        return FOSSIL_RECIPES
    return []

static func build_recipe(name: String) -> Dictionary:
    if name=="PRIVATE CHEST":return PRIVATE_CHEST if online_enabled else SHARED_CHEST
    for recipe in BUILD_RECIPES:
        if String(recipe.get("name", "")) == name:
            if online_enabled and name=="BEACON":
                var walkable=recipe.duplicate(true);walkable["solid"]=false
                return walkable
            return recipe
    return {}

static func build_display_name(name: String) -> String:
    if online_enabled and name=="BEACON":return "BEACON"
    var recipe := build_recipe(name)
    return String(recipe.get("display_name", name))

static func can_afford(inventory: Dictionary, cost: Dictionary) -> bool:
    for key in cost.keys():
        var name := String(key)
        var needed := int(cost[key])
        if name == "ANY APRICORN":
            var total := 0
            for apricorn in APRICORNS:
                total += int(inventory.get(apricorn, 0))
            if total < needed:
                return false
        elif int(inventory.get(name, 0)) < needed:
            return false
    return true

static func consume(inventory: Dictionary, cost: Dictionary) -> void:
    for key in cost.keys():
        var name := String(key)
        var needed := int(cost[key])
        if name == "ANY APRICORN":
            # Prefer the most plentiful color so crafting never wastes the
            # player's last copy of a rarer color while another is abundant.
            var ordered := APRICORNS.duplicate()
            ordered.sort_custom(func(a: String, b: String) -> bool:
                return int(inventory.get(a, 0)) > int(inventory.get(b, 0)))
            for apricorn in ordered:
                if needed <= 0:
                    break
                var available := int(inventory.get(apricorn, 0))
                var take := mini(available, needed)
                inventory[apricorn] = available - take
                needed -= take
        else:
            inventory[name] = maxi(0, int(inventory.get(name, 0)) - needed)

static func grant(inventory: Dictionary, item_name: String, amount: int = 1) -> void:
    var normalized := ItemData.normalize_name(item_name)
    inventory[normalized] = int(inventory.get(normalized, 0)) + amount

static func format_cost(cost: Dictionary) -> String:
    var parts: Array[String] = []
    for key in cost.keys():
        parts.append("%s x%d" % [String(key), int(cost[key])])
    return ", ".join(parts)

static func format_cost_with_inventory(cost: Dictionary, inventory: Dictionary) -> String:
    var parts: Array[String] = []
    for key in cost.keys():
        var name := String(key)
        var current := int(inventory.get(name, 0))
        if name == "ANY APRICORN":
            current = 0
            for apricorn in APRICORNS:
                current += int(inventory.get(apricorn, 0))
        parts.append("%s %d/%d" % [name, current, int(cost[key])])
    return "  ".join(parts)
