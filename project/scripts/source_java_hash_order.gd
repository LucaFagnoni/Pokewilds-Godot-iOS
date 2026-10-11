class_name SourceJavaHashOrder
extends RefCounted

# Java HashMap tree bins use System.identityHashCode when distinct Vector2 keys
# have equal hashes. That order is unspecified, JVM-dependent, and can change
# without changing the world seed. The parity oracle normalizes those source
# HashMaps to insertion order; Godot Dictionary preserves that same stable order.

static func keys(source: Dictionary, capacity_hint: int = 0) -> Array:
    # capacity_hint remains in the signature so existing source-order call
    # sites do not need a second code path for QA and production.
    if capacity_hint < 0:
        return []
    return source.keys()

static func values(source: Dictionary, capacity_hint: int = 0) -> Array:
    if capacity_hint < 0: return []
    # Dictionary.values() preserves the same insertion order without a second
    # full-size temporary key array during large-world generation.
    return source.values()

static func _java_hash(key: Variant) -> int:
    if key is Vector2i:
        var vector := key as Vector2i
        var result := _i32(31 + _float_bits(float(vector.x)))
        return _i32(31 * result + _float_bits(float(vector.y)))
    if key is Vector2:
        var vector := key as Vector2
        var result := _i32(31 + _float_bits(vector.x))
        return _i32(31 * result + _float_bits(vector.y))
    if key is String:
        var result := 0
        for index in range((key as String).length()):
            result = _i32(31 * result + (key as String).unicode_at(index))
        return result
    if key is int:
        return _i32(int(key))
    # Tile does not override Object.hashCode in 0.8.11. Identity-hash parity is
    # tracked separately; coordinate-keyed maps cover the deterministic world
    # topology addressed by this helper.
    return _i32(hash(key))

static func _spread_hash(raw_hash: int) -> int:
    var unsigned_hash := raw_hash & 0xffffffff
    return _i32(unsigned_hash ^ (unsigned_hash >> 16))

static func _float_bits(value: float) -> int:
    var bytes := PackedByteArray()
    bytes.resize(4)
    bytes.encode_float(0, value)
    return _i32(bytes.decode_u32(0))

static func _i32(value: int) -> int:
    var result := value & 0xffffffff
    if result >= 0x80000000:
        result -= 0x100000000
    return result
