extends Node2D
## Water outside the map uses the same texture, tile origin and clock as terrain.
const WaterData = preload("res://scripts/source_world_data.gd")
static var frames: Dictionary = {}
var world: Node
var strips: Array[Sprite2D] = []

static func water_frame(tick: int) -> Texture2D:
    var spec := WaterData._render_spec_for_name("water1", 0, false, tick)
    var source: Texture2D = spec.texture
    var region: Rect2 = spec.region
    var key := str(source.get_rid().get_id()) + str(region)
    if not frames.has(key):
        frames[key] = ImageTexture.create_from_image(source.get_image().get_region(Rect2i(region)))
    return frames[key]

static func world_tick(source_world: Node) -> int:
    var stream := source_world.get_node_or_null("GroundLayer/ExactBaseTileStream")
    return int(stream.source_animation_tick) if stream != null else 0

func configure(source_world: Node) -> void:
    world = source_world
    var bounds: Rect2i = world.get_map_bounds()
    var rect := Rect2(Vector2(bounds.position)*16.0, Vector2(bounds.size)*16.0)
    var margin := 1024.0
    var regions: Array[Rect2] = [
        Rect2(rect.position-Vector2(margin,margin),Vector2(rect.size.x+margin*2,margin)),
        Rect2(Vector2(rect.position.x-margin,rect.end.y),Vector2(rect.size.x+margin*2,margin)),
        Rect2(rect.position-Vector2(margin,0),Vector2(margin,rect.size.y)),
        Rect2(Vector2(rect.end.x,rect.position.y),Vector2(margin,rect.size.y))]
    for region in regions:
        var strip := Sprite2D.new()
        strip.texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED
        strip.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
        strip.centered = false
        strip.region_enabled = true
        strip.region_rect = Rect2(Vector2.ZERO,region.size)
        strip.position = region.position
        strip.z_index = -4096
        strip.z_as_relative = false
        add_child(strip)
        strips.append(strip)
    _process(0.0)

func _process(_delta: float) -> void:
    if not is_instance_valid(world) or not visible: return
    var texture := water_frame(world_tick(world))
    for strip in strips:
        if strip.texture != texture: strip.texture = texture
