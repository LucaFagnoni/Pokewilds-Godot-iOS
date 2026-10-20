class_name CollisionBody
extends Node
## Takes the place of a StaticBody2D: the solid rectangles (CollisionBox) of
## the overworld's objects, of the interiors or of a built house, kept by map
## cell so the player's mover reads only the few cells round the player. With
## collision_layer 0 (the interiors while in a built house and the other way
## round) none of them is solid.

const TILE := 16
## The bodies in the scene tree.
static var live: Array[CollisionBody] = []

var collision_layer := 1
var collision_mask := 1
var _cells := {}
var _boxes := {}

func add_box(rect: Rect2) -> CollisionBox:
    var box := CollisionBox.new()
    box.rect = rect
    box.body = self
    _boxes[box] = true
    _index(box)
    return box

func add_cell(cell: Vector2i) -> CollisionBox:
    return add_box(Rect2(Vector2(cell * TILE), Vector2(TILE, TILE)))

## Appends the boxes (PlayerMotion.Solid) that overlap `area` (in world
## pixels), if this body collides with `mask`.
func collect(area: Rect2, mask: int, out: Array) -> void:
    if collision_layer & mask == 0 or _cells.is_empty(): return
    for y in range(floori(area.position.y / TILE), floori(area.end.y / TILE) + 1):
        for x in range(floori(area.position.x / TILE), floori(area.end.x / TILE) + 1):
            var boxes = _cells.get(Vector2i(x, y))
            if boxes == null: continue
            for box: CollisionBox in boxes:
                if not box.disabled and box.rect.intersects(area): out.append(box.solid())

func _index(box: CollisionBox) -> void:
    for cell in _cells_of(box.rect):
        var boxes: Array = _cells.get_or_add(cell, [])
        boxes.append(box)

func _unindex(box: CollisionBox) -> void:
    for cell in _cells_of(box.rect):
        var boxes = _cells.get(cell)
        if boxes == null: continue
        boxes.erase(box)
        if boxes.is_empty(): _cells.erase(cell)

func _remove(box: CollisionBox) -> void:
    if _boxes.erase(box): _unindex(box)

func _cells_of(rect: Rect2) -> Array[Vector2i]:
    var cells: Array[Vector2i] = []
    for y in range(floori(rect.position.y / TILE), ceili(rect.end.y / TILE)):
        for x in range(floori(rect.position.x / TILE), ceili(rect.end.x / TILE)):
            cells.append(Vector2i(x, y))
    return cells

func _enter_tree() -> void:
    live.append(self)

func _exit_tree() -> void:
    live.erase(self)

func _notification(what: int) -> void:
    if what == NOTIFICATION_PREDELETE:
        # Over a copy of the keys: walking the Dictionary finds each next key
        # by looking up the current one, which is freed by then, and freed
        # objects all compare equal. An earlier box with the same hash (its
        # address) matched instead and the walk went back over freed boxes.
        for box: CollisionBox in _boxes.keys():
            box.body = null
            box.free()
        _boxes.clear()
        _cells.clear()
