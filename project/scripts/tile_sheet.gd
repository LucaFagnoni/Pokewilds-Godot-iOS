extends RefCounted
## Tile art drawn from shared sheets, as the original game's TilesAtlas does.
##
## Each tile's image is still its own file (so mods replace it by path, as
## before), but the first time it is used it is copied onto a shared sheet in
## memory and drawn from there. The graphics chip can then draw a screen of
## mixed terrain in a few calls instead of one call per kind of tile.
const SIZE := 2048
## Space kept round every tile, filled with a copy of its own edge pixels, so
## a neighbour on the sheet never shows through at a tile's border.
const GAP := 1
const LARGEST := 256

static var enabled := true
## Goes up when tile art is swapped while the game runs (the Gen 3 pack).
static var generation := 0
static var pages: Array = []      # each: {"image", "texture", "x", "y", "row", "dirty"}
static var placed: Dictionary = {}
static var sources: Dictionary = {}

## Returns [sheet texture, region on the sheet], or [] to draw the tile from
## its own image (switched off, an unusual kind of texture, or too large).
static func place(texture: Texture2D, region: Rect2) -> Array:
    if not enabled or texture == null: return []
    # Nearly every tile image is wrapped by the Gen 3 pack's switch, whether or
    # not the pack is on. The picture it currently shows is what goes on the
    # sheet; when the pack is switched, `generation` changes and the tile
    # layers place every tile again.
    if texture.has_method("use") and texture.get("current") is Texture2D:
        texture = texture.get("current")
    if not (texture is CompressedTexture2D or texture is ImageTexture or texture is PortableCompressedTexture2D): return []
    var size := Vector2i(region.size)
    if size.x <= 0 or size.y <= 0 or size.x > LARGEST or size.y > LARGEST: return []
    var key := "%d|%d,%d,%d,%d" % [texture.get_instance_id(), int(region.position.x), int(region.position.y), size.x, size.y]
    if placed.has(key): return placed[key]
    var id := texture.get_instance_id()
    if not sources.has(id):
        var image := texture.get_image()
        if image != null:
            if image.is_compressed(): image.decompress()
            image.convert(Image.FORMAT_RGBA8)
        sources[id] = image
    var source: Image = sources[id]
    var from := Rect2i(Vector2i(region.position), size)
    if source == null or not Rect2i(Vector2i.ZERO, source.get_size()).encloses(from):
        placed[key] = []
        return []
    var need := size + Vector2i(GAP * 2, GAP * 2)
    var page: Dictionary = {} if pages.is_empty() else pages[-1]
    if not page.is_empty() and int(page.x) + need.x > SIZE:
        page.x = 0
        page.y = int(page.y) + int(page.row)
        page.row = 0
    if page.is_empty() or int(page.y) + need.y > SIZE:
        var blank := Image.create(SIZE, SIZE, false, Image.FORMAT_RGBA8)
        blank.fill(Color(0, 0, 0, 0))
        page = {"image": blank, "texture": ImageTexture.create_from_image(blank), "x": 0, "y": 0, "row": 0, "dirty": false}
        pages.append(page)
    var at := Vector2i(int(page.x) + GAP, int(page.y) + GAP)
    var sheet: Image = page.image
    sheet.blit_rect(source, from, at)
    # Repeat the tile's own edge into the gap round it.
    sheet.blit_rect(source, Rect2i(from.position, Vector2i(size.x, 1)), at + Vector2i(0, -1))
    sheet.blit_rect(source, Rect2i(from.position + Vector2i(0, size.y - 1), Vector2i(size.x, 1)), at + Vector2i(0, size.y))
    sheet.blit_rect(source, Rect2i(from.position, Vector2i(1, size.y)), at + Vector2i(-1, 0))
    sheet.blit_rect(source, Rect2i(from.position + Vector2i(size.x - 1, 0), Vector2i(1, size.y)), at + Vector2i(size.x, 0))
    page.x = int(page.x) + need.x
    page.row = maxi(int(page.row), need.y)
    page.dirty = true
    placed[key] = [page.texture, Rect2(Vector2(at), Vector2(size))]
    return placed[key]

## Sends newly added tiles to the graphics chip: once per frame, however many
## were added.
static func flush() -> void:
    for page in pages:
        if page.dirty:
            page.dirty = false
            (page.texture as ImageTexture).update(page.image)
