extends Control
## Presentation only: generation and world persistence remain in main/world.
const BoundaryWater = preload("res://scripts/world_boundary_water.gd")
var elapsed := 0.0
var tile: Texture2D
var water_transform := Transform2D.IDENTITY
var start_tick := 0
func configure(world: Node) -> void:
    name = "WorldTravelView"
    mouse_filter=Control.MOUSE_FILTER_IGNORE
    size=get_viewport_rect().size;z_index=450
    texture_repeat=CanvasItem.TEXTURE_REPEAT_ENABLED
    texture_filter=CanvasItem.TEXTURE_FILTER_NEAREST
    water_transform=world.get_global_transform_with_canvas()
    start_tick=BoundaryWater.world_tick(world)
    tile=BoundaryWater.water_frame(start_tick)
    var sources: Array[Sprite2D]=[]
    if is_instance_valid(world.fly_shadow_sprite):sources.append(world.fly_shadow_sprite)
    if is_instance_valid(world.field_helper_sprite):sources.append(world.field_helper_sprite)
    sources.append(world.player.sprite)
    sources.sort_custom(func(a:Sprite2D,b:Sprite2D):return _effective_z(a)<_effective_z(b))
    for source in sources:
        if not source.visible:continue
        var sprite:=Sprite2D.new()
        sprite.texture=source.texture;sprite.hframes=source.hframes;sprite.vframes=source.vframes;sprite.frame=source.frame
        sprite.offset=source.offset;sprite.centered=source.centered
        sprite.flip_h=source.flip_h;sprite.flip_v=source.flip_v
        sprite.region_enabled=source.region_enabled;sprite.region_rect=source.region_rect
        sprite.modulate=source.modulate;sprite.material=source.material
        sprite.texture_filter=CanvasItem.TEXTURE_FILTER_NEAREST
        sprite.transform=source.get_global_transform_with_canvas()
        add_child(sprite)
    queue_redraw()
func _process(delta: float) -> void:
    elapsed+=delta
    var next := BoundaryWater.water_frame(start_tick+int(elapsed*60.0))
    if tile != next:
        tile=next
        queue_redraw()
func _draw() -> void:
    if tile==null:return
    var coverage := water_transform.affine_inverse()*Rect2(Vector2.ZERO,size)
    var origin := (coverage.position/16.0).floor()*16.0
    var end := (coverage.end/16.0).ceil()*16.0
    draw_set_transform_matrix(water_transform)
    draw_texture_rect(tile,Rect2(origin,end-origin),true)

func _effective_z(item: CanvasItem) -> int:
    var result:=item.z_index
    if item.z_as_relative and item.get_parent() is CanvasItem:
        result+=_effective_z(item.get_parent())
    return result
