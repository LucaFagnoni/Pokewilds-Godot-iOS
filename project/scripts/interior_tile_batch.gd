extends Node2D
## Plain floor and wall tiles of an interior drawn by one canvas item, as a
## run of Sprite2Ds would draw them (same order, region, filter and depth).
## Interiors hold about 10,000 such tiles and each Sprite2D costs about 1.6 KB.

const LIMIT := 256

var textures: Array[Texture2D] = []
var texture_index: Dictionary = {}
var ids := PackedInt32Array()
## Per tile: position x, y, then region x, y, width, height.
var rects := PackedFloat32Array()

func _init() -> void:
    texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
    z_as_relative = false
    z_index = -4

func full() -> bool:
    return ids.size() >= LIMIT

func add(texture: Texture2D, at: Vector2, region: Rect2) -> void:
    if not texture_index.has(texture):
        texture_index[texture] = textures.size()
        textures.append(texture)
        texture.changed.connect(queue_redraw)
    ids.append(int(texture_index[texture]))
    rects.append_array([at.x, at.y, region.position.x, region.position.y, region.size.x, region.size.y])
    queue_redraw()

func _draw() -> void:
    for i in ids.size():
        var r := i * 6
        draw_texture_rect_region(textures[ids[i]], Rect2(rects[r], rects[r + 1], rects[r + 4], rects[r + 5]),
            Rect2(rects[r + 2], rects[r + 3], rects[r + 4], rects[r + 5]), Color(1, 1, 1, 1), false, false)

## Same as the interior map does for each tile sprite: a quarter-size copy at
## its place. `origin` is the map's top-left corner in this node's pixels.
func add_to_map(image: Image, previews: Dictionary, origin: Vector2) -> void:
    for i in ids.size():
        var r := i * 6
        var texture := textures[ids[i]]
        var rect := Rect2(rects[r + 2], rects[r + 3], rects[r + 4], rects[r + 5])
        var destination := Vector2i(((Vector2(rects[r], rects[r + 1]) - origin) / 4.0).round())
        var size := Vector2i((rect.size / 4.0).round())
        if size.x <= 0 or size.y <= 0 or not Rect2i(Vector2i.ZERO, image.get_size()).intersects(Rect2i(destination, size)):
            continue
        var preview_key: Array = [texture, rect, size, false, false]
        if not previews.has(preview_key):
            var preview := texture.get_image().get_region(Rect2i(rect))
            preview.resize(size.x, size.y, Image.INTERPOLATE_NEAREST)
            previews[preview_key] = preview
        image.blend_rect(previews[preview_key], Rect2i(Vector2i.ZERO, size), destination)
