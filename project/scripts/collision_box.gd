class_name CollisionBox
extends Object
## One solid rectangle in world pixels: a tree, a sign, an interior wall, a
## built wall, a dropped item. It takes the place of a CollisionShape2D, so
## the code that keeps one tests it with is_instance_valid(), switches it off
## with `disabled` and removes it with queue_free(). It lives in a
## CollisionBody, which frees what is left of it when the body goes.

var body: CollisionBody
var rect := Rect2(): set = set_rect
var disabled := false
## The centre, as a CollisionShape2D's position was: moving it moves the box.
var position: Vector2:
    get: return rect.get_center()
    set(value): rect = Rect2(value - rect.size * 0.5, rect.size)

var _solid: PlayerMotion.Solid

func set_rect(value: Rect2) -> void:
    if body != null: body._unindex(self)
    rect = value
    _solid = null
    if body != null: body._index(self)

## As the player's mover sees it: a RectangleShape2D.
func solid() -> PlayerMotion.Solid:
    if _solid == null: _solid = PlayerMotion.Solid.box(rect)
    return _solid

## As Node.queue_free(): gone at the end of the frame, solid no longer now.
func queue_free() -> void:
    if body != null: body._remove(self)
    body = null
    call_deferred("free")
