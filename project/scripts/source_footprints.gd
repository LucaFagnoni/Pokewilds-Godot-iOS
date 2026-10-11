extends Sprite2D
# Player.FootPrintFade: 35% opacity, first fade at tick 64, then every 8 ticks.
const ART = preload("res://assets/source_exact/global/footprints1.png")
var ticks := 0.0
var world: Node2D
static func eligible(tile, local_feet: Vector2i = Vector2i(8,10)) -> bool:
    if tile == null or tile.is_water or "_tidalwater" in tile.name: return false
    for name in [tile.name, tile.name_upper]:
        if "_puddle1" in name and SourceWorldData.puddle_reflects_at(name, local_feet): return false
    return tile.name in ["desert4", "snow2", "snow5", "snow6", "sand1", "sand2"] or ("_tidaloff" in tile.name and ("sand" in tile.name or "beach" in tile.biome.to_lower()))
static func leave(owner_world: Node2D, from: Vector2i, to: Vector2i) -> void:
    leave_at(owner_world, from, to, owner_world.player.position, owner_world._facing_cell(), owner_world.active_field_move)

## Same marks for any walker: the local player, or another player in ONLINE.
static func leave_at(owner_world: Node2D, from: Vector2i, to: Vector2i, body: Vector2, direction: Vector2i, field_move: String) -> void:
    if owner_world.active_area_id != "OVERWORLD" or owner_world.exact_world == null or field_move in ["FLY", "RIDE", "SURF"]: return
    if from == to or absi(from.x-to.x)>1 or absi(from.y-to.y)>1: return
    var feet: Vector2 = body + Vector2(0,3)
    var center: Vector2 = (feet - Vector2(direction)*4.0).round()
    for sample in [feet, center]:
        var cell := Vector2i((sample/16.0).floor())
        if String(owner_world.built_structures.get(cell,{}).get("name","")) == "BRIDGE": return
        if not eligible(owner_world.exact_world.tile_at(cell), Vector2i(sample)-cell*16): return
    var mark = load("res://scripts/source_footprints.gd").new()
    mark.world = owner_world
    mark.texture = ART
    mark.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
    mark.centered = false
    mark.region_enabled = true
    mark.region_rect = Rect2(16 if direction.y else 0,0,16,16)
    mark.flip_h = direction.x > 0
    mark.flip_v = direction.y > 0
    mark.position = center-Vector2(8,8)
    mark.modulate.a = 0.35
    mark.z_index = 1
    owner_world.add_child(mark)
func _process(delta: float) -> void:
    if not is_instance_valid(world): queue_free(); return
    if not world.gameplay_enabled: return
    ticks += delta*60.0
    modulate.a = maxf(0.0,0.35-0.1*maxi(0,(int(ticks)-56)/8))
    if ticks >= 88: queue_free()
