extends RefCounted

const POCKET_ITEMS := 0
const POCKET_BALLS := 1
const POCKET_MATERIALS := 2
const POCKET_KEY_ITEMS := 3
const POCKET_MEDICINE := 4
const POCKET_COUNT := 5

# Source data and older saves use a few spelling variants. Normalize them at
# the inventory boundary so every menu and battle reads the same item stack.
const SOURCE_ITEM_ALIASES := {
    "POKÉ BALL":"POKE BALL",
    "POKEBALL":"POKE BALL",
    "ANCIENT POWDER":"ANCIENTPOWDER",
    "MANSION KEY":"SECRET KEY"
}

const ITEMS: Array[String] = [
    "OLD AMBER", "HELIX FOSSIL", "DOME FOSSIL", "CLAW FOSSIL",
    "ROOT FOSSIL", "SHIELD FOSSIL", "SKULL FOSSIL", "SWEET APPLE",
    "WATER STONE", "FIRE STONE", "LEAF STONE", "THUNDERSTONE",
    "MOON STONE", "SUN STONE", "ICE STONE", "DAWN STONE",
    "DUSK STONE", "SHINY STONE", "MAX REPEL", "REPEL",
    "RARE CANDY", "BERRY SEED", "POKE DOLL"
]

const BALLS: Array[String] = [
    "POKE BALL", "GREAT BALL", "ULTRA BALL", "LOVE BALL", "FAST BALL",
    "LURE BALL", "MOON BALL", "FRIEND BALL", "HEAVY BALL", "MASTER BALL",
    "DUSK BALL", "NET BALL", "DIVE BALL", "QUICK BALL", "HEAL BALL",
    "NEST BALL", "DREAM BALL", "TIMER BALL", "LEVEL BALL", "PARK BALL"
]

const MATERIALS: Array[String] = [
    "LOG", "GRASS", "DRY SAND", "LIGHT CLAY", "FLOWERS", "CURSED SOIL",
    "ASHEN SOIL", "DRY SOIL", "MANURE", "PSI ENERGY", "STAR PIECE",
    "DARK ENERGY", "LIFE FORCE", "ANCIENTPOWDER", "HONEY", "SOFT WOOL",
    "MAGNET", "NEVERMELTICE", "DRAGON SCALE", "DRAGON FANG", "STARDUST",
    "BINDING BAND", "METAL COAT", "SOFT SAND", "POISON BARB",
    "MIRACLE SEED", "CHARCOAL", "HARD STONE", "SOFT FEATHER",
    "HARD SHELL", "SILKY THREAD", "MYSTIC SOIL", "DAMP SOIL",
    "THIN PAPER", "SOFT BEDDING", "CLEAR GLASS", "BIG PEARL", "SPELL TAG",
    "BLACK APRICORN", "BLUE APRICORN", "GREEN APRICORN", "PINK APRICORN",
    "RED APRICORN", "WHITE APRICORN", "YELLOW APRICORN", "SCRAP METAL",
    "MYSTIC WATER", "CONCRETE"
]

const KEY_ITEMS: Array[String] = [
    "SLEEPING BAG", "ESCAPE ROPE", "SILPH SCOPE", "OLD ROD", "GOOD ROD",
    "SUPER ROD", "SECRET KEY", "BLANK DISC", "UPGRADE", "DUBIOUS DISC"
]

const MEDICINE: Array[String] = [
    "POTION", "SUPER POTION", "HYPER POTION", "MAX POTION", "FULL RESTORE",
    "FULL HEAL", "ANTIDOTE", "BURN HEAL", "ICE HEAL", "AWAKENING",
    "PARLYZ HEAL", "LUM BERRY", "PECHA BERRY", "CHERI BERRY",
    "ASPEAR BERRY", "CHESTO BERRY", "RAWST BERRY", "PERSIM BERRY",
    "BERRY JUICE", "MOOMOO MILK", "RAGECANDYBAR", "REVIVE", "MAX REVIVE"
]

const EVOLUTION_ITEMS: Array[String] = [
    "SWEET APPLE", "WATER STONE", "FIRE STONE", "LEAF STONE",
    "THUNDERSTONE", "MOON STONE", "SUN STONE", "ICE STONE", "DAWN STONE",
    "DUSK STONE", "SHINY STONE", "UPGRADE", "DUBIOUS DISC"
]

const DESCRIPTIONS := {
    "LOG":"A sturdy LOG.",
    "GRASS":"Freshly cut GRASS.",
    "DRY SAND":"Hot, dry sand from the desert.",
    "LIGHT CLAY":"Soft clay from the mountains.",
    "FLOWERS":"Small, beautiful flowers.",
    "CURSED SOIL":"Soil taken from a graveyard.",
    "ASHEN SOIL":"Soil found near a volcano.",
    "DRY SOIL":"Dry soil from the savannah.",
    "MANURE":"A smelly fertilizer.",
    "PSI ENERGY":"An energy exuded by PSYCHIC types.",
    "STAR PIECE":"A sparkling gem.",
    "DARK ENERGY":"An energy exuded by DARK types.",
    "LIFE FORCE":"An energy exuded by GHOST types.",
    "ANCIENTPOWDER":"A mysterious and rare powder.",
    "HONEY":"A sweet and sticky treat.",
    "SOFT WOOL":"A held item that raises SPECIAL DEFENSE.",
    "MAGNET":"A held item that boosts ELECTRIC moves.",
    "NEVERMELTICE":"A held item that boosts ICE moves.",
    "DRAGON SCALE":"A scale from a DRAGON type.",
    "DRAGON FANG":"A held item that boosts DRAGON moves.",
    "STARDUST":"A sparkling powder.",
    "BINDING BAND":"A held item that strengthens trapping moves.",
    "METAL COAT":"A held item that boosts STEEL moves.",
    "SOFT SAND":"A held item that boosts GROUND moves.",
    "POISON BARB":"A held item that boosts POISON moves.",
    "MIRACLE SEED":"Plant it, or hold it to boost GRASS moves.",
    "CHARCOAL":"A held item that boosts FIRE moves.",
    "HARD STONE":"A held item that boosts ROCK moves.",
    "SOFT FEATHER":"A held item that boosts FLYING moves.",
    "HARD SHELL":"A held item that raises DEFENSE.",
    "SILKY THREAD":"A held item that boosts BUG moves.",
    "MYSTIC SOIL":"Soil from the Forest.",
    "DAMP SOIL":"Soil from the Lake.",
    "THIN PAPER":"A soft paper good for making posters.",
    "SOFT BEDDING":"For a comfy bed and faster healing.",
    "CLEAR GLASS":"Clear, delicate glass.",
    "BIG PEARL":"A big, beautiful pearl.",
    "SPELL TAG":"A held item that boosts GHOST moves.",
    "SCRAP METAL":"Discarded metal useful for crafting.",
    "MYSTIC WATER":"A held item that boosts WATER moves.",
    "CONCRETE":"A strong building material.",
    "BLACK APRICORN":"A black APRICORN.",
    "BLUE APRICORN":"A blue APRICORN.",
    "GREEN APRICORN":"A green APRICORN.",
    "PINK APRICORN":"A pink APRICORN.",
    "RED APRICORN":"A red APRICORN.",
    "WHITE APRICORN":"A white APRICORN.",
    "YELLOW APRICORN":"A yellow APRICORN.",
    "LUM BERRY":"Cures a POKEMON of STATUS EFFECTS.",
    "PECHA BERRY":"Cures a POKEMON of POISON.",
    "CHERI BERRY":"Cures a POKEMON of PARALYSIS.",
    "ASPEAR BERRY":"Cures a POKEMON of FREEZE.",
    "CHESTO BERRY":"Cures a POKEMON of SLEEP.",
    "RAWST BERRY":"Cures a POKEMON of BURN.",
    "PERSIM BERRY":"Cures a POKEMON of CONFUSION.",
    "POKE BALL":"A tool for catching POKEMON.",
    "GREAT BALL":"A good tool for catching POKEMON.",
    "ULTRA BALL":"An excellent tool for catching POKEMON.",
    "LOVE BALL":"Catch POKEMON of the opposite gender.",
    "FAST BALL":"Most effective on fast POKEMON.",
    "LURE BALL":"Most effective while fishing.",
    "MOON BALL":"For POKEMON that evolve by Moon Stone.",
    "FRIEND BALL":"A ball that raises FRIENDSHIP.",
    "HEAVY BALL":"Most effective on heavy POKEMON.",
    "MASTER BALL":"The best BALL. It never misses.",
    "DUSK BALL":"Most effective in dark areas.",
    "NET BALL":"Best for BUG and WATER type POKEMON.",
    "DIVE BALL":"Catch POKEMON underwater.",
    "QUICK BALL":"Best when used at start of encounter.",
    "HEAL BALL":"Heals the POKEMON it contains.",
    "NEST BALL":"Most effective on weaker POKEMON.",
    "DREAM BALL":"Catch sleeping POKEMON.",
    "TIMER BALL":"Most effective in a longer battle.",
    "LEVEL BALL":"Most effective on low-level POKEMON.",
    "PARK BALL":"A special BALL used in the Park.",
    "OLD AMBER":"Amber containing DNA of ancient POKEMON.",
    "HELIX FOSSIL":"A fossil of an ancient POKEMON.",
    "DOME FOSSIL":"A fossil of an ancient POKEMON.",
    "CLAW FOSSIL":"A fossil of an ancient POKEMON.",
    "ROOT FOSSIL":"A fossil of an ancient POKEMON.",
    "SHIELD FOSSIL":"A fossil of an ancient POKEMON.",
    "SKULL FOSSIL":"A fossil of an ancient POKEMON.",
    "SWEET APPLE":"Can evolve certain POKEMON.",
    "WATER STONE":"Can evolve certain POKEMON.",
    "FIRE STONE":"Can evolve certain POKEMON.",
    "LEAF STONE":"Can evolve certain POKEMON.",
    "THUNDERSTONE":"Can evolve certain POKEMON.",
    "MOON STONE":"Can evolve certain POKEMON.",
    "SUN STONE":"Can evolve certain POKEMON.",
    "ICE STONE":"Can evolve certain POKEMON.",
    "DAWN STONE":"Can evolve certain POKEMON.",
    "DUSK STONE":"Can evolve certain POKEMON.",
    "SHINY STONE":"Can evolve certain POKEMON.",
    "BERRY JUICE":"A healing drink that restores HP.",
    "MOOMOO MILK":"A nutritious drink that restores HP.",
    "MAX REPEL":"A spray that repels weak POKEMON.",
    "REPEL":"A spray that repels weak POKEMON.",
    "RAGECANDYBAR":"A candy bar that can restore HP.",
    "RARE CANDY":"Raises a POKEMON's level by 1.",
    "REVIVE":"Restores a fainted POKEMON to half HP.",
    "MAX REVIVE":"Fully restores a fainted POKEMON.",
    "BERRY SEED":"Can be planted to grow BERRIES.",
    "POKE DOLL":"A cute plushie.",
    "SILPH SCOPE":"An item that identifies ghosts.",
    "OLD ROD":"Use by water to fish for POKEMON.",
    "GOOD ROD":"Use by water to fish for POKEMON.",
    "SUPER ROD":"Use by water to fish for POKEMON.",
    "ESCAPE ROPE":"Takes you to a nearby shore.",
    "SLEEPING BAG":"Slowly restores party HP.",
    "SECRET KEY":"A mysterious key.",
    "BLANK DISC":"A worn disc with no recorded move.",
    "UPGRADE":"A transparent device filled with data.",
    "DUBIOUS DISC":"A device filled with dubious data.",
    "POTION":"Restores 20 HP.",
    "SUPER POTION":"Restores 50 HP.",
    "HYPER POTION":"Restores 200 HP.",
    "MAX POTION":"Fully restores a POKEMON's HP.",
    "FULL RESTORE":"Fully restores HP and status.",
    "FULL HEAL":"Cures all status conditions.",
    "ANTIDOTE":"Cures a POKEMON of POISON.",
    "BURN HEAL":"Cures a POKEMON of BURN.",
    "ICE HEAL":"Cures a POKEMON of FREEZE.",
    "AWAKENING":"Awakens a sleeping POKEMON.",
    "PARLYZ HEAL":"Cures a POKEMON of PARALYSIS."
}

static func all_items() -> Array[String]:
    var result: Array[String] = []
    result.append_array(ITEMS)
    result.append_array(BALLS)
    result.append_array(MATERIALS)
    result.append_array(KEY_ITEMS)
    result.append_array(MEDICINE)
    return result

static func normalize_name(item_name: String) -> String:
    var normalized := item_name.strip_edges().to_upper()
    normalized = normalized.replace("É", "E")
    normalized = normalized.replace("_", " ").replace("-", " ")
    while "  " in normalized:
        normalized = normalized.replace("  ", " ")
    return String(SOURCE_ITEM_ALIASES.get(normalized, normalized))

static func items_for_pocket(index: int) -> Array[String]:
    match index:
        POCKET_ITEMS:
            return ITEMS.duplicate()
        POCKET_BALLS:
            return BALLS.duplicate()
        POCKET_MATERIALS:
            return MATERIALS.duplicate()
        POCKET_KEY_ITEMS:
            return KEY_ITEMS.duplicate()
        POCKET_MEDICINE:
            return MEDICINE.duplicate()
        _:
            return []

static func pocket_for(item_name: String) -> int:
    var normalized := normalize_name(item_name)
    if BALLS.has(normalized):
        return POCKET_BALLS
    if MATERIALS.has(normalized):
        return POCKET_MATERIALS
    if KEY_ITEMS.has(normalized):
        return POCKET_KEY_ITEMS
    if MEDICINE.has(normalized):
        return POCKET_MEDICINE
    return POCKET_ITEMS

static func description(item_name: String) -> String:
    return String(DESCRIPTIONS.get(normalize_name(item_name), "A useful item."))

static func needs_pokemon_target(item_name: String) -> bool:
    var normalized := normalize_name(item_name)
    return MEDICINE.has(normalized) or normalized == "RARE CANDY" or EVOLUTION_ITEMS.has(normalized)

static func is_evolution_item(item_name: String) -> bool:
    return EVOLUTION_ITEMS.has(normalize_name(item_name))
