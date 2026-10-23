extends Node2D
const TexturePixels = preload("res://scripts/texture_pixels.gd")
var world: Node
var records: Dictionary = {}
var actors: Dictionary = {}
var current_scope := ""
func scope() -> String:
    return String(world.active_area_id)+("|"+str(world.active_built_house_door) if world.active_area_id=="HOUSE" else "")
func key(cell: Vector2i) -> String:
    return scope()+"|"+world._cell_key(cell)
func can_drop(cell: Vector2i) -> bool:
    if records.has(key(cell)) or world.blocked.has(cell) or world.built_structures.has(cell) or world.interior_interactables.has(cell) or world.wild_eggs.has(cell):return false
    if cell==world._player_cell():return false
    if world.active_area_id=="HOUSE":
        if not world._house_pokemon_cell_allowed(cell):return false
    else:
        var tile: SourceTile = world.exact_world.tile_at(cell) if world.active_area_id=="OVERWORLD" and world.exact_world!=null else world._source_interior_tile_at_world_cell(cell)
        if tile==null or tile.is_solid or not tile.has_item.is_empty() or "sign" in tile.name or "sign" in tile.name_upper:return false
    if world.deployed_pokemon.has(cell):return false
    return world._wild_id_at_cell(cell)<0
func drop(item: String, amount: int, cell: Vector2i) -> bool:
    if amount<1 or not can_drop(cell):return false
    records[key(cell)]={"scope":scope(),"x":cell.x,"y":cell.y,"item":item,"amount":amount}
    rebuild()
    world.play_source_sound("seed1")
    return true
func collect(cell: Vector2i) -> bool:
    var id:=key(cell)
    if not records.has(id):return false
    var record:Dictionary=records[id]
    if record.has("coop_id"):
        var game=world.get_parent()
        if is_instance_valid(game.coop_game) and game.coop_game.active:
            game.coop_game.pickup_item(record)
            return true
    records.erase(id)
    rebuild()
    world.material_collected.emit(String(record.item),int(record.amount))
    world.world_message.emit("Picked up %s x%d!"%[record.item,record.amount])
    return true
func snapshot() -> Dictionary:return records.duplicate(true)
func restore(saved: Dictionary) -> void:
    clear_actors()
    records=saved.duplicate(true)
    current_scope=""
    if is_instance_valid(world):rebuild()
func clear_actors() -> void:
    for cell in actors:
        var entry:Dictionary=actors[cell]
        var blocker = entry.blocked_map.get(cell)
        if typeof(blocker)==TYPE_STRING and blocker==entry.marker:entry.blocked_map.erase(cell)
        var box:CollisionBox=entry.box
        if is_instance_valid(box):box.queue_free()
        var body:Node2D=entry.body
        remove_child(body);body.queue_free()
    actors.clear()
static var _ball_art:Dictionary={}

## Every item on the ground is drawn as a ball. A ball that was thrown and
## missed keeps its own colours instead of turning into a plain POKE BALL.
static func _item_art(item:String)->Texture2D:
    var plain:Texture2D=preload("res://assets/source_0_8_11/tiles/pokeball1.png")
    var Shell=preload("res://scripts/ball_shell_colors.gd")
    if not Shell.PALETTES.has(item):return plain
    if not _ball_art.has(item):_ball_art[item]=ImageTexture.create_from_image(Shell.recolor(TexturePixels.of(plain),item))
    return _ball_art[item]

func rebuild() -> void:
    clear_actors();current_scope=scope()
    for id in records:
        var record:Dictionary=records[id]
        if String(record.get("scope",""))!=current_scope:continue
        var cell:=Vector2i(int(record.x),int(record.y))
        var body:=Node2D.new();body.position=world._cell_center(cell);add_child(body)
        var sprite:=Sprite2D.new();sprite.texture=_item_art(String(record.get("item","")));sprite.texture_filter=CanvasItem.TEXTURE_FILTER_NEAREST
        body.add_child(sprite);body.z_index=world._depth_z(cell,20)
        var solids:=world.get_node_or_null("WorldCollision") as CollisionBody
        var box:CollisionBox=solids.add_cell(cell) if solids!=null else null
        var marker := "dropped-item:"+str(body.get_instance_id())
        actors[cell]={"body":body,"box":box,"blocked_map":world.blocked,"marker":marker}
        if not world.blocked.has(cell):world.blocked[cell]=marker
func _process(_delta: float) -> void:
    if is_instance_valid(world) and current_scope!=scope():rebuild()
