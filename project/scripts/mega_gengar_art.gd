extends RefCounted
const TexturePixels = preload("res://scripts/texture_pixels.gd")
static var cache: Dictionary = {}

static func texture(kind: String, shiny: bool) -> Texture2D:
    var community := preload("res://scripts/divinakra_mega_art.gd").texture("mega_gengar", kind, shiny)
    if community != null: return community
    var key := kind + str(shiny)
    if cache.has(key): return cache[key]
    if kind in ["front", "back"]:
        var authored: Texture2D = load("res://assets/community_mega_gengar/battle/%s-%s.png" % [kind, "shiny" if shiny else "normal"])
        cache[key] = authored
        return authored
    var result: Image
    if kind == "overworld":
        # Existing credited Princess-Phoenix sheet: front/left/right/back rows,
        # two normal columns followed by the two authored shiny columns.
        var source := TexturePixels.of(preload("res://assets/community_mega_gengar/princess_phoenix_sheet.png"))
        result = Image.create(192, 32, false, Image.FORMAT_RGBA8)
        for index in range(6):
            var row: int = [1, 1, 3, 3, 0, 0][index]
            result.blit_rect(source, Rect2i((index % 2 + (2 if shiny else 0)) * 32, row * 32, 32, 32), Vector2i(index * 32, 0))
    else:
        # Same authored Mega Gengar composition used by the source boss battle.
        var base := TexturePixels.of(preload("res://assets/source_bosses/mgengar_base1.png"))
        var overlay := TexturePixels.of(preload("res://assets/source_bosses/mgengar_over1.png"))
        result = Image.create(56, 56, false, Image.FORMAT_RGBA8)
        result.blend_rect(base, Rect2i(0, 0, 56, 56), Vector2i.ZERO)
        result.blend_rect(overlay, Rect2i(0, 0, 56, 56), Vector2i.ZERO)
    var output := ImageTexture.create_from_image(result)
    if kind == "overworld": output.set_meta("mega_gengar_walk", true)
    cache[key] = output
    return output
