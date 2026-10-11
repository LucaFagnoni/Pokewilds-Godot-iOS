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
    var bytes := PackedByteArray()
    bytes.resize(4)
    bytes.encode_float(0, value)
    return bytes.decode_float(0)

static func rotate_deg(vector: Vector2, degrees: float) -> Vector2:
    _ensure_sine_table()
    var angle := float32(degrees)
    var index_cos := int(float32(float32(angle + 90.0) * float32(DEG_TO_INDEX))) & SIN_MASK
    var index_sin := int(float32(angle * float32(DEG_TO_INDEX))) & SIN_MASK
    var cosine := float(_sin_table[index_cos])
    var sine := float(_sin_table[index_sin])
    var old_x := float32(vector.x)
    var old_y := float32(vector.y)
    return Vector2(
        float32(float32(old_x * cosine) - float32(old_y * sine)),
        float32(float32(old_x * sine) + float32(old_y * cosine))
    )

static func distance(left: Vector2, right: Vector2) -> float:
    var dx := float32(float32(right.x) - float32(left.x))
    var dy := float32(float32(right.y) - float32(left.y))
    var squared := float32(float32(dx * dx) + float32(dy * dy))
    return float32(sqrt(squared))

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
