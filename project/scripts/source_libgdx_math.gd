class_name SourceLibGDXMath
extends RefCounted

# libGDX 1.x MathUtils uses a 16,384-entry sine lookup for Vector2.rotateDeg.
# Every operation below is rounded to Java float precision.
const SIN_BITS := 14
const SIN_MASK := (1 << SIN_BITS) - 1
const SIN_COUNT := SIN_MASK + 1
const DEG_TO_INDEX := float(SIN_COUNT) / 360.0

static var _sin_table := PackedFloat32Array()

static func float32(value: float) -> float:
    # Vector2 stores 32-bit floats: the same round-to-nearest as Java's
    # (float) cast, without allocating a byte buffer per call.
    return Vector2(value, 0.0).x

# Below, building a Vector2 rounds both components to float, as float32()
# does: the same arithmetic in fewer calls. A Vector2's components already
# are floats, so float32(vector.x) is vector.x.
static func rotate_deg(vector: Vector2, degrees: float) -> Vector2:
    _ensure_sine_table()
    var angle := float32(degrees)
    var deg_to_index := float32(DEG_TO_INDEX)
    var indices := Vector2(float32(angle + 90.0) * deg_to_index, angle * deg_to_index)
    var cosine := float(_sin_table[int(indices.x) & SIN_MASK])
    var sine := float(_sin_table[int(indices.y) & SIN_MASK])
    var cross := Vector2(vector.x * cosine, vector.y * sine)
    var along := Vector2(vector.x * sine, vector.y * cosine)
    return Vector2(cross.x - cross.y, along.x + along.y)

static func distance(left: Vector2, right: Vector2) -> float:
    var delta := Vector2(right.x - left.x, right.y - left.y)
    var squared := Vector2(delta.x * delta.x, delta.y * delta.y)
    return float32(sqrt(float32(squared.x + squared.y)))

static func _ensure_sine_table() -> void:
    if not _sin_table.is_empty():
        return
    _sin_table.resize(SIN_COUNT)
    for index in range(SIN_COUNT):
        var phase := float32(float32(float(index) + 0.5) / float(SIN_COUNT))
        _sin_table[index] = float32(sin(phase * PI * 2.0))
    for degree in range(0, 360, 90):
        var index := int(float32(float(degree) * float32(DEG_TO_INDEX))) & SIN_MASK
        _sin_table[index] = float32(sin(deg_to_rad(float(degree))))
