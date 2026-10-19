extends RefCounted
## One int per map cell, keyed like the source tile dictionary (pixel or cell
## keys). Replaces a Dictionary of ~400k entries per tile layer: a packed
## array over the map's bounds costs 4 bytes a cell. Keys outside the bounds
## (rare) fall back to a Dictionary.

var origin := Vector2i.ZERO
var width := 0
var height := 0
var key_scale := 1
var values := PackedInt32Array()
var extra := {}
var count := 0

func _init(bounds: Rect2i = Rect2i(), scale: int = 1) -> void:
    origin = bounds.position
    width = bounds.size.x
    height = bounds.size.y
    key_scale = scale
    values.resize(width * height)

## A copy with the same bounds and nothing stored.
func blank():
    return get_script().new(Rect2i(origin, Vector2i(width, height)), key_scale)

func _index(key: Vector2i) -> int:
    var at := key / key_scale - origin
    if at.x < 0 or at.y < 0 or at.x >= width or at.y >= height: return -1
    return at.y * width + at.x

## The stored value, or null when the key has none.
func fp_get(key: Vector2i) -> Variant:
    var index := _index(key)
    if index < 0: return extra.get(key)
    var value := values[index]
    return null if value == 0 else value

## Values are 32-bit hashes; 0 marks an empty slot, so it is stored as 1.
func fp_put(key: Vector2i, value: int) -> void:
    var stored := normalized(value)
    var index := _index(key)
    if index < 0:
        if not extra.has(key): count += 1
        extra[key] = stored
        return
    if values[index] == 0: count += 1
    values[index] = stored

func fp_erase(key: Vector2i) -> void:
    var index := _index(key)
    if index < 0:
        if extra.erase(key): count -= 1
        return
    if values[index] != 0:
        values[index] = 0
        count -= 1

func size() -> int:
    return count

func is_empty() -> bool:
    return count == 0

func clear() -> void:
    values.fill(0)
    extra.clear()
    count = 0

## Every stored key. Walks the whole map: only for full rebuilds.
func keys() -> Array:
    var result := []
    for index in values.size():
        if values[index] != 0:
            result.append((Vector2i(index % width, index / width) + origin) * key_scale)
    result.append_array(extra.keys())
    return result

## Stored value comparable with a fresh hash, as fp_put stores it.
static func normalized(value: int) -> int:
    var stored := value & 0xFFFFFFFF
    stored = stored - 0x100000000 if stored >= 0x80000000 else stored
    return 1 if stored == 0 else stored
