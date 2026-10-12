extends RefCounted
static var cache := {}
static func texture(species: String, kind: String, shiny: bool) -> Texture2D:
    var overhaul = preload("res://scripts/gen3_overhaul.gd")
    if not overhaul.enabled or species not in ["arceus","regigigas","regieleki","regidrago","raikou","entei","suicune"]: return null
    if species in ["raikou","entei","suicune"] and kind!="overworld": return null
    if kind not in ["front","back","overworld"]: return null
    var original := str(PokemonData.info(species).get(kind,""))
    if overhaul.user_paths.has(original): return null
    var key := species+"-"+kind+("-shiny" if shiny else "-normal")
    if not cache.has(key):
        var result: Texture2D = load("res://assets/gen3_legendaries/"+key+".png")
        if kind=="overworld":
            result.set_meta("mega_gengar_walk",true)
            result.set_meta("overworld_feet_offset",Vector2(0,-8))
        cache[key]=result
    return cache[key]
