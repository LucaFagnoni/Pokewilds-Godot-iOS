extends RefCounted
## The pixels of a texture, without reading them back from the graphics chip.
##
## Texture2D.get_image() on a phone (GLES3) draws the texture into a scratch
## buffer and reads that back: the processor waits for the graphics chip each
## time. The desktop editor answers from a copy in memory, which hides it.
## An imported texture's pixels are already in its .ctex file (a lossless WebP
## or PNG), which an exported game ships, so they are decoded from there. A
## texture the game makes from an Image can keep that Image (texture_from).
## Anything else is read back as before.

const KEY := &"pixels"
## "GST2", version, width, height, flags, mipmap limit and 3 reserved words.
const HEADER := 36
const PNG := 1
const WEBP := 2

## A new Image the caller may change, as get_image() returns on a phone.
static func of(texture: Texture2D) -> Image:
    if texture == null: return null
    if texture.has_meta(KEY): return (texture.get_meta(KEY) as Image).duplicate()
    if texture is CompressedTexture2D:
        var image := _decode((texture as CompressedTexture2D).load_path)
        if image != null: return image
    elif texture is AtlasTexture:
        var atlas := texture as AtlasTexture
        var whole := of(atlas.atlas)
        if whole == null: return null
        # The engine's own region of an atlas: whole size where one side is 0.
        var rect := Rect2i(Vector2i(atlas.region.position), Vector2i(atlas.region.size.floor()))
        if rect.size.x == 0: rect.size.x = whole.get_width()
        if rect.size.y == 0: rect.size.y = whole.get_height()
        return whole.get_region(rect)
    elif texture.get_script() != null and texture.get("current") is Texture2D:
        # The Gen 3 pack's switch shows another texture.
        return of(texture.get("current"))
    return texture.get_image()

## An ImageTexture that keeps `image` (do not change it afterwards) for of().
static func texture_from(image: Image) -> ImageTexture:
    var texture := ImageTexture.create_from_image(image)
    if texture != null: texture.set_meta(KEY, image)
    return texture

## The image inside a .ctex file when it is one plain WebP or PNG, as the
## engine loads it; null for other kinds (compressed, with mipmaps).
static func _decode(path: String) -> Image:
    if not path.ends_with(".ctex"): return null
    var file := FileAccess.open(path, FileAccess.READ)
    if file == null or file.get_length() < HEADER + 20 or file.get_buffer(4).get_string_from_ascii() != "GST2": return null
    file.seek(HEADER)
    var kind := file.get_32()
    file.get_32()    # width and height, 16 bits each
    var mipmaps := file.get_32()
    var format := file.get_32()
    if mipmaps != 0 or (kind != PNG and kind != WEBP): return null
    var size := file.get_32()
    if file.get_position() + size > file.get_length(): return null
    var bytes := file.get_buffer(size)
    var image := Image.new()
    if (image.load_png_from_buffer(bytes) if kind == PNG else image.load_webp_from_buffer(bytes)) != OK: return null
    if image.get_format() != format: image.convert(format as Image.Format)
    return image
