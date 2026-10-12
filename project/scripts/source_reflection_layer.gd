class_name SourceReflectionLayer
extends Node2D

var world: Node
var exact_world: SourceExactWorldAdapter
var tracked_player: Node2D
var ripple_time := 0.0
var frame_masks: Dictionary = {}
var frame_half_view := Vector2.ZERO
var palm_cache_key: Array = []
var palm_cache: Array = []
var palm_state: Array = []
var palm_canvas: Node2D
var canvas: CanvasItem

func configure(world_node: Node, source_world: SourceExactWorldAdapter,
        player_node: Node2D) -> void:
    world = world_node
    exact_world = source_world
    tracked_player = player_node
    texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
    canvas = self
    if not is_instance_valid(palm_canvas):
        palm_canvas = Node2D.new()
        palm_canvas.name = "PalmReflections"
        # The same order as before: palms first, then everything else over them.
        palm_canvas.show_behind_parent = true
        palm_canvas.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
        add_child(palm_canvas)
        palm_canvas.draw.connect(_draw_palm_canvas)
    set_process(true)
    visible = true
    queue_redraw()

func _process(delta: float) -> void:
    ripple_time = fmod(ripple_time + delta, 48.0 / 60.0)
    queue_redraw()

func _draw() -> void:
    if world == null or exact_world == null:
        return
    var camera := get_viewport().get_camera_2d()
    var zoom := Vector2.ONE if camera == null else camera.zoom
    frame_half_view = get_viewport_rect().size / zoom * 0.5 + Vector2(48, 48)
    frame_masks.clear()
    _update_palm_canvas()
    canvas = self
    var sprites: Array[Sprite2D] = []
    _append_sprite(sprites, tracked_player)
    _append_sprite(sprites, world.get("follower_sprite"))
    _append_sprite(sprites, world.get("field_helper_sprite"))
    # Only Pokemon near the player can be reflected on screen; asking every
    # one in the world each frame cost about 2 ms.
    var wild := world.get("wild_pokemon") as Dictionary
    for near_id in world.nearby_wild_ids():
        var record = wild.get(near_id)
        if record is Dictionary:
            _append_sprite(sprites, (record as Dictionary).get("sprite"))
    for record in (world.get("deployed_pokemon") as Dictionary).values():
        if record is Dictionary:
            _append_sprite(sprites, (record as Dictionary).get("sprite"))
    for sprite in sprites:
        _draw_sprite_reflection(sprite)

func _update_palm_canvas() -> void:
    if not is_instance_valid(tracked_player):
        return
    var camera := get_viewport().get_camera_2d()
    var zoom := Vector2.ONE if camera == null else camera.zoom
    var half_view := get_viewport_rect().size / zoom * 0.5 + Vector2(64, 64)
    var center := to_local(tracked_player.global_position)
    var first := Vector2i((center - half_view).floor() / 16.0)
    var last := Vector2i((center + half_view).ceil() / 16.0)
    var key := [exact_world.get_instance_id(), first, last, world.map_art_revision]
    if key != palm_cache_key:
        palm_cache_key = key
        palm_cache.clear()
        for y in range(first.y, last.y + 1):
            for x in range(first.x, last.x + 1):
                var cell := Vector2i(x, y)
                var tile := exact_world.tile_at(cell)
                if tile == null or (tile.name_upper != "tree6" and tile.name != "tree5"):
                    continue
                var spec := SourceWorldData.render_spec(tile, true)
                if spec.is_empty(): continue
                var texture := spec.get("texture") as Texture2D
                var source: Rect2 = spec.get("region", Rect2(0, 0, 16, 32))
                var offset: Vector2 = spec.get("offset", Vector2.ZERO)
                var anchor := Vector2(cell * 16) + offset + Vector2(0, source.size.y - 8)
                palm_cache.append([texture, source, anchor])
    # Palm trees do not move and their ripple has three shapes in its 48-tick
    # cycle. They are drawn on their own canvas, which is redrawn only when
    # the shape, the view or the map changes: a few times a second, where
    # redrawing every palm pixel by pixel on every frame cost 5-8 ms.
    var tick := int(ripple_time * 60.0)
    var shape := 1 if tick >= 9 and tick < 24 else 2 if tick >= 33 else 0
    var state := [key, shape, Time.get_ticks_msec() / 500]
    if state != palm_state:
        palm_state = state
        palm_canvas.queue_redraw()

func _draw_palm_canvas() -> void:
    canvas = palm_canvas
    for palm in palm_cache:
        _draw_palm_ripple(palm[0], palm[1], palm[2])
    canvas = self


func _draw_palm_ripple(texture: Texture2D, source: Rect2, anchor: Vector2) -> void:
    # DrawReflections.java expands the middle column, then contracts the left
    # half over the same 48-tick cycle used by actor reflections.
    var tick := int(ripple_time * 60.0)
    var half_width := source.size.x * 0.5
    var sections: Array[Vector3] = []
    if tick >= 9 and tick < 24:
        sections = [Vector3(0, half_width, 0), Vector3(half_width, 1, half_width),
            Vector3(half_width, half_width, half_width + 1)]
    elif tick >= 33:
        sections = [Vector3(0, half_width - 1, 1),
            Vector3(half_width, half_width, half_width)]
    else:
        sections = [Vector3(0, source.size.x, 0)]
    for section in sections:
        var part := Rect2(source.position + Vector2(section.x, 0),
            Vector2(section.y, source.size.y))
        var destination := Rect2(anchor + Vector2(section.z, 0), part.size)
        _draw_masked_tree_part(texture, part, destination)

func _draw_masked_tree_part(texture: Texture2D, source: Rect2, destination: Rect2) -> void:
    if not _reflection_rect_allowed(destination):
        return
    for y in range(floori(destination.position.y), ceili(destination.end.y)):
        var run := -2147483648
        for x in range(floori(destination.position.x), ceili(destination.end.x) + 1):
            var allowed := x < ceili(destination.end.x) and _reflection_pixel_allowed(Vector2i(x, y))
            if allowed and run == -2147483648:
                run = x
            if not allowed and run != -2147483648:
                _draw_reflection_run(texture, source, destination, Vector2.ONE,
                    Rect2(run, y, x - run, 1), false)
                run = -2147483648

func _append_sprite(target: Array[Sprite2D], candidate: Variant) -> void:
    var sprite: Sprite2D = null
    if candidate is Sprite2D and is_instance_valid(candidate):
        sprite = candidate as Sprite2D
    elif candidate is Node and is_instance_valid(candidate):
        # World.configure() tracks the Player CharacterBody2D, while the actual
        # visible artwork is its Sprite2D child. Resolve actor nodes here so the
        # player uses the exact same puddle reflection path as follower, wild,
        # helper, and deployed Pokemon sprites.
        sprite = (candidate as Node).get_node_or_null("Sprite2D") as Sprite2D
    if sprite == null or not is_instance_valid(sprite) or not sprite.visible:
        return
    if tracked_player != null and is_instance_valid(tracked_player):
        var half_view := frame_half_view
        var delta := sprite.global_position - tracked_player.global_position
        if absf(delta.x) > half_view.x or absf(delta.y) > half_view.y:
            return
    target.append(sprite)

func _draw_sprite_reflection(sprite: Sprite2D) -> void:
    var texture := sprite.texture
    if texture == null:
        return
    var source := sprite.region_rect if sprite.region_enabled else Rect2(
        Vector2(sprite.frame_coords) * Vector2(texture.get_size()) /
            Vector2(maxi(1, sprite.hframes), maxi(1, sprite.vframes)),
        Vector2(texture.get_size()) /
            Vector2(maxi(1, sprite.hframes), maxi(1, sprite.vframes)))
    var scale_size := source.size * sprite.global_scale.abs()
    if scale_size.x <= 0.0 or scale_size.y <= 0.0:
        return
    var foot := to_local(sprite.global_position)
    var ripple_frame := int(ripple_time * 60.0)
    foot.x += 1.0 if ripple_frame in range(9, 24) else \
        (-1.0 if ripple_frame in range(33, 48) else 0.0)
    var reflected := Rect2(
        foot.x - scale_size.x * 0.5, foot.y,
        scale_size.x, scale_size.y)
    if not _reflection_rect_allowed(reflected):
        return
    var first_pixel := Vector2i(
        floori(reflected.position.x), floori(reflected.position.y))
    var last_pixel := Vector2i(
        ceili(reflected.end.x) - 1, ceili(reflected.end.y) - 1)
    var source_scale := source.size / reflected.size
    for y in range(first_pixel.y, last_pixel.y + 1):
        var run_start := -2147483648
        for x in range(first_pixel.x, last_pixel.x + 2):
            var allowed := x <= last_pixel.x and \
                _reflection_pixel_allowed(Vector2i(x, y))
            if allowed and run_start <= -2147483648:
                run_start = x
            if allowed or run_start <= -2147483648:
                continue
            _draw_reflection_run(
                texture, source, reflected, source_scale,
                Rect2(run_start, y, x - run_start, 1), sprite.flip_h)
            run_start = -2147483648

func _reflection_rect_allowed(rect: Rect2) -> bool:
    # Reject only rectangles with no reflection mask at all. Partial puddles
    # retain the exact existing per-pixel clipping and ripple drawing path.
    var first := Vector2i(floori(rect.position.x / 16.0), floori(rect.position.y / 16.0))
    var last := Vector2i(floori((ceili(rect.end.x) - 1) / 16.0), floori((ceili(rect.end.y) - 1) / 16.0))
    for y in range(first.y, last.y + 1):
        for x in range(first.x, last.x + 1):
            if _reflection_cell_mask(Vector2i(x, y)).size() == 256:
                return true
    return false

func _reflection_cell_mask(cell: Vector2i) -> PackedByteArray:
    if not frame_masks.has(cell):
        var mask := PackedByteArray()
        var tile := exact_world.tile_at(cell)
        if tile != null and not tile.is_tidal and String(tile.biome).to_upper().replace("-", "_") in ["BEACH", "BEACH_BLACKSAND"]:
            var puddle_name := tile.name if "_puddle1" in tile.name else tile.name_upper
            if "_puddle1" in puddle_name and "_tidaloff" in puddle_name:
                mask = SourceWorldData.puddle_reflection_mask(puddle_name)
        frame_masks[cell] = mask
    return frame_masks[cell]

func _reflection_pixel_allowed(world_pixel: Vector2i) -> bool:
    var cell := Vector2i(
        floori(float(world_pixel.x) / 16.0),
        floori(float(world_pixel.y) / 16.0))
    if not frame_masks.has(cell):
        _reflection_cell_mask(cell)
    var mask: PackedByteArray = frame_masks[cell]
    return mask.size() == 256 and mask[posmod(world_pixel.y, 16) * 16 + posmod(world_pixel.x, 16)] != 0


func _draw_reflection_run(texture: Texture2D, source: Rect2,
        reflected: Rect2, source_scale: Vector2, destination: Rect2,
        flipped_horizontally: bool) -> void:
    var relative := destination.position - reflected.position
    var source_x := source.position.x + relative.x * source_scale.x
    var source_width := destination.size.x * source_scale.x
    if flipped_horizontally:
        source_x = source.position.x + source.size.x - \
            relative.x * source_scale.x
        source_width = -source_width
    canvas.draw_texture_rect_region(
        texture,
        destination,
        Rect2(
            source_x,
            source.position.y + source.size.y - relative.y * source_scale.y,
            source_width,
            -destination.size.y * source_scale.y),
        Color(1, 1, 1, 0.5))
