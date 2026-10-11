extends RefCounted
## Authored normal-color sheets. Shiny and GEN3 artwork remain unchanged.
static var cache := {}
static func texture(species: String, kind: String, shiny: bool = false) -> Texture2D:
    if shiny or preload("res://scripts/gen3_overhaul.gd").enabled: return null
    if species not in ["mega_gengar", "mega_charizard_x", "mega_blastoise", "mega_venusaur"]: return null
    if kind not in ["overworld", "menu"]: return null
    var original := "res://assets/community_mega_gengar/princess_phoenix_sheet.png" if species=="mega_gengar" else str(PokemonData.info(species).get("overworld",""))
    if preload("res://scripts/gen3_overhaul.gd").user_paths.has(original): return null
    var key := species + "-" + kind
    if not cache.has(key):
        var result: Texture2D = load("res://assets/divinakra_megas/" + key + ".png")
        if kind == "overworld": result.set_meta("mega_gengar_walk", true)
        cache[key] = result
    return cache[key]
