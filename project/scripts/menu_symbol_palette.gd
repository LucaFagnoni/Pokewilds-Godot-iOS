extends RefCounted
## Recolor source menu symbols without changing their pixels, size or alignment.
static var cache: Dictionary = {}
static func recolor(texture: Texture2D, ink: Color) -> Texture2D:
    if texture == null: return null
    var key := str(texture.get_rid().get_id())+str(ink)
    if cache.has(key): return cache[key]
    var pixels: Image = texture.get_image().duplicate()
    pixels.convert(Image.FORMAT_RGBA8)
    for y in range(pixels.get_height()):
        for x in range(pixels.get_width()):
            var source := pixels.get_pixel(x,y)
            var color := ink
            color.a = source.a if source.v < 0.5 else 0.0
            pixels.set_pixel(x,y,color)
    var result := ImageTexture.create_from_image(pixels)
    cache[key] = result
    return result

static func shiny() -> Texture2D:
    if cache.has("outlined_shiny"): return cache["outlined_shiny"]
    var pixels := recolor(preload("res://assets/source_exact/global/shiny.png"),Color(1.0,1.0,0.0)).get_image()
    var mask := pixels.duplicate()
    for y in range(pixels.get_height()):
        for x in range(pixels.get_width()):
            if mask.get_pixel(x,y).a == 0.0: continue
            for offset in [Vector2i.LEFT,Vector2i.RIGHT,Vector2i.UP,Vector2i.DOWN]:
                var at: Vector2i = Vector2i(x,y)+offset
                if at.x<0 or at.y<0 or at.x>=mask.get_width() or at.y>=mask.get_height() or mask.get_pixelv(at).a==0.0:
                    pixels.set_pixel(x,y,Color("f5a000"))
                    break
    cache["outlined_shiny"] = ImageTexture.create_from_image(pixels)
    return cache["outlined_shiny"]
