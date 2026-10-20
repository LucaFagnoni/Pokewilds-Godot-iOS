extends RefCounted
## Authored normal-color sheets. Shiny artwork remains unchanged.
static var cache := {}
static func texture(species: String, kind: String, shiny: bool = false) -> Texture2D:
    if shiny: return null
    if species not in ["mega_gengar", "mega_charizard_x", "mega_blastoise", "mega_venusaur", "mega_gyarados"]: return null
    if kind not in ["overworld", "menu"]: return null
    var original := "res://assets/community_mega_gengar/princess_phoenix_sheet.png" if species=="mega_gengar" else str(PokemonData.info(species).get("overworld",""))
    if preload("res://scripts/native_mod_pack.gd").replaced.has(original): return null
    var key := species + "-" + kind
    if not cache.has(key):
        var result: Texture2D = load("res://assets/divinakra_megas/" + key + ".png")
        if kind == "overworld": result.set_meta("mega_gengar_walk", true)
        # Mega Gyarados is drawn at 50x50, larger than the other 32x32 sheets.
        # Lift it so it stands on its tile as they do instead of hanging below it.
        if kind == "overworld" and result.get_height() > 32: result.set_meta("overworld_feet_offset", Vector2(0, -(result.get_height() - 32) / 2.0))
        cache[key] = result
    return cache[key]
