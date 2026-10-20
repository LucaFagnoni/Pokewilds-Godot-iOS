class_name SourceJavaRandom
extends RefCounted

# java.util.Random's 48-bit LCG, used by GenIsland1 and GenForest2.
const MULTIPLIER := 25214903917
const ADDEND := 11
const MASK_48 := 281474976710655
const MASK_24 := 16777215

var _seed: int = 0
var _trace_enabled := false
var _trace_count := 0
var _trace_limit := 400

func _init(seed_value: int = 0) -> void:
    set_seed(seed_value)

func set_seed(seed_value: int) -> void:
    _seed = (seed_value ^ MULTIPLIER) & MASK_48

func state() -> int:
    return _seed

func trace_count() -> int:
    return _trace_count

func enable_trace(limit := 400) -> void:
    _trace_enabled = true
    _trace_count = 0
    _trace_limit = limit

func _multiply_48(left: int, right: int) -> int:
    var left_low := left & MASK_24
    var left_high := (left >> 24) & MASK_24
    var right_low := right & MASK_24
    var right_high := (right >> 24) & MASK_24
    var low_product := left_low * right_low
    var cross_low := (left_low * right_high + left_high * right_low) & MASK_24
    return (low_product + (cross_low << 24)) & MASK_48

func _next_bits(bits: int) -> int:
    # seed * MULTIPLIER mod 2^48 from two 24-bit halves of the seed: each
    # partial product stays below 2^59, so no 64-bit overflow.
    _seed = ((_seed & MASK_24) * MULTIPLIER
        + ((((_seed >> 24) * MULTIPLIER) & MASK_24) << 24) + ADDEND) & MASK_48
    return _seed >> (48 - bits)

# Hot path of world generation: _next_bits is inlined below.
func next_int(bound: int = -1) -> int:
    if bound < 0:
        var value := _next_bits(32)
        var result := value - 4294967296 if value >= 2147483648 else value
        if _trace_enabled: _trace_draw(bound, result)
        return result
    assert(bound > 0, "java.util.Random.nextInt bound must be positive")
    if (bound & -bound) == bound:
        _seed = ((_seed & MASK_24) * MULTIPLIER
            + ((((_seed >> 24) * MULTIPLIER) & MASK_24) << 24) + ADDEND) & MASK_48
        var result := (bound * (_seed >> 17)) >> 31
        if _trace_enabled: _trace_draw(bound, result)
        return result
    while true:
        _seed = ((_seed & MASK_24) * MULTIPLIER
            + ((((_seed >> 24) * MULTIPLIER) & MASK_24) << 24) + ADDEND) & MASK_48
        var bits := _seed >> 17
        var value := bits % bound
        if bits - value + (bound - 1) <= 2147483647:
            if _trace_enabled: _trace_draw(bound, value)
            return value
    return 0

func _trace_draw(bound: int, value: int) -> void:
    if not _trace_enabled:
        return
    _trace_count += 1
    if _trace_count <= _trace_limit:
        print("GODOT_SOURCE_RANDOM_DRAW=%d:%d:%d" % [
            _trace_count, bound, value
        ])

func next_boolean() -> bool:
    return _next_bits(1) != 0

func next_float() -> float:
    return float(_next_bits(24)) / 16777216.0

func next_double() -> float:
    return float((_next_bits(26) << 27) + _next_bits(27)) / 9007199254740992.0

func range_int(minimum: int, maximum_inclusive: int) -> int:
    assert(maximum_inclusive >= minimum)
    return minimum + next_int(maximum_inclusive - minimum + 1)

func choose(values: Array) -> Variant:
    assert(not values.is_empty())
    return values[next_int(values.size())]

func shuffle(values: Array) -> void:
    for index in range(values.size(), 1, -1):
        var swap_index := next_int(index)
        var held: Variant = values[index - 1]
        values[index - 1] = values[swap_index]
        values[swap_index] = held
