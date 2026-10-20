extends RefCounted
const TexturePixels = preload("res://scripts/texture_pixels.gd")

const Settings = preload("res://scripts/game_options.gd")
const EMOTES = preload("res://assets/ecology/emotes.png")
static var check_textures: Dictionary = {}

static func texture() -> Texture2D:
    var hd := Settings.enabled("hd_emotes")
    if not check_textures.has(hd):
        # Preserve the original 16-pixel speech balloon, outline and tail.
        var pixels := TexturePixels.of(preload("res://scripts/emote_style.gd").sheet()).get_region(Rect2i(144, 0, 16, 16))
        for y in range(3, 11):
            for x in range(3, 13):
                pixels.set_pixel(x, y, Color.WHITE)
        var ink := Color8(34, 177, 76) if hd else Color.BLACK
        # Retain the exact original checkmark shape and balloon geometry.
        for point in [Vector2i(3,6),Vector2i(4,7),Vector2i(5,8),Vector2i(6,9),Vector2i(7,8),Vector2i(8,7),Vector2i(9,6),Vector2i(10,5),Vector2i(11,4)]:
            pixels.set_pixelv(point, ink)
            pixels.set_pixelv(point + Vector2i.UP, ink)
        check_textures[hd] = ImageTexture.create_from_image(pixels)
    return check_textures[hd]

static func refresh(record: Dictionary) -> void:
    if not is_instance_valid(record.get("sprite")):return
    var actor := record.get("sprite") as Sprite2D
    if not is_instance_valid(actor): return
    var marker := actor.get_node_or_null("HeldItemEmote") as Sprite2D
    var ready := Settings.enabled("held_emotes") and not String(record.get("held_item", "")).is_empty()
    if ready and not is_instance_valid(marker):
        marker = Sprite2D.new()
        marker.name = "HeldItemEmote"
        marker.texture = texture()
        marker.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
        marker.position = Vector2(0, -16)
        marker.z_index = 19
        actor.add_child(marker)
        marker.add_to_group("styled_held_emotes")
    if is_instance_valid(marker):
        marker.texture = texture()
        # Temporary source reactions take priority without being disabled.
        marker.visible = ready and not is_instance_valid(actor.get_node_or_null("SourceEmote"))
