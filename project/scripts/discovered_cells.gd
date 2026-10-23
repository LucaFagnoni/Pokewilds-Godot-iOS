extends RefCounted
## The cells of the map the player has uncovered: one bit per cell of the
## map's rectangle (bounds), in rows. It was a Dictionary of "x,y" strings:
## 361 strings made at every step, over a hundred thousand in an explored
## world, copied whole by every save and co-op checkpoint.
##
## Saved as {"bounds": [x, y, w, h], "bits": base64} (to_save); from_save also
## reads the forms saves had before: a list of "x,y" strings (single player)
## and the co-op squares (to_squares).

## Co-op keeps a player's discovery as squares of this many cells a side, each
## a base64 string with a bit per cell, keyed "sx,sy": an unchanged square
## costs nothing to copy or compare.
const SQUARE := 32

var bounds := Rect2i()
var bits := PackedByteArray()
var _count := 0
## Co-op squares: "sx,sy" -> base64, and the squares changed since.
var _square_text := {}
var _square_dirty := {}
var _squares_whole := false

## Starts over, empty, over `rect` (the map's cells).
func reset(rect: Rect2i) -> void:
    bounds = rect
    bits = PackedByteArray()
    bits.resize((rect.size.x * rect.size.y + 7) >> 3)
    _count = 0
    _square_text = {}
    _square_dirty = {}
    _squares_whole = false

func clear() -> void:
    reset(bounds)

## How many cells are discovered.
func size() -> int:
    return _count

func is_empty() -> bool:
    return _count == 0

func _bit(cell: Vector2i) -> int:
    if not bounds.has_point(cell): return -1
    return (cell.y - bounds.position.y) * bounds.size.x + cell.x - bounds.position.x

func has(cell: Vector2i) -> bool:
    var bit := _bit(cell)
    return bit >= 0 and bits[bit >> 3] & (1 << (bit & 7)) != 0

## Marks `cell`; true if it was not discovered yet. Cells off the map are ignored.
func add(cell: Vector2i) -> bool:
    var bit := _bit(cell)
    if bit < 0: return false
    var mask := 1 << (bit & 7)
    var byte := bits[bit >> 3]
    if byte & mask: return false
    bits[bit >> 3] = byte | mask
    _count += 1
    _square_dirty[Vector2i(floori(float(cell.x) / SQUARE), floori(float(cell.y) / SQUARE))] = true
    return true

## Every discovered cell, row by row.
func cells() -> Array[Vector2i]:
    var result: Array[Vector2i] = []
    if _count == 0: return result
    var width := bounds.size.x
    for index in bits.size():
        var byte := bits[index]
        if byte == 0: continue
        for b in 8:
            if byte & (1 << b):
                var bit := (index << 3) | b
                result.append(bounds.position + Vector2i(bit % width, bit / width))
    return result

## True when a cell of `rect` is discovered.
func any_in(rect: Rect2i) -> bool:
    rect = rect.intersection(bounds)
    for y in range(rect.position.y, rect.end.y):
        for x in range(rect.position.x, rect.end.x):
            if has(Vector2i(x, y)): return true
    return false

func to_save() -> Dictionary:
    return {"bounds": [bounds.position.x, bounds.position.y, bounds.size.x, bounds.size.y],
        "bits": Marshalls.raw_to_base64(bits)}

## Reads a save's discovery (any form it has had) over the current bounds.
## Cells off the map are dropped, as before.
func from_save(value: Variant) -> void:
    clear()
    if value is Array or value is PackedStringArray:
        for key in value:
            var text := String(key)
            if text.get_slice_count(",") == 2:
                add(Vector2i(text.get_slice(",", 0).to_int(), text.get_slice(",", 1).to_int()))
    elif value is Dictionary and value.has("bits"):
        var saved_bounds = value.get("bounds", [])
        if not saved_bounds is Array or saved_bounds.size() != 4: return
        var rect := Rect2i(int(saved_bounds[0]), int(saved_bounds[1]), int(saved_bounds[2]), int(saved_bounds[3]))
        var saved := Marshalls.base64_to_raw(String(value.bits))
        if rect == bounds and saved.size() == bits.size():
            bits = saved
            _count = 0
            for byte in bits:
                while byte:
                    byte &= byte - 1
                    _count += 1
            _squares_whole = false
            return
        for bit in mini(rect.size.x * rect.size.y, saved.size() * 8):
            if saved[bit >> 3] & (1 << (bit & 7)):
                add(rect.position + Vector2i(bit % rect.size.x, bit / rect.size.x))
    elif value is Dictionary:
        from_squares(value)

## The co-op form: "sx,sy" -> base64 of a SQUARE x SQUARE bit square (row by
## row, bit 0 first). Only squares changed since the last call are encoded.
func to_squares() -> Dictionary:
    if not _squares_whole:
        _square_text = {}
        _square_dirty = {}
        for cell in cells():
            _square_dirty[Vector2i(floori(float(cell.x) / SQUARE), floori(float(cell.y) / SQUARE))] = true
        _squares_whole = true
    for square: Vector2i in _square_dirty:
        var square_bits := PackedByteArray()
        square_bits.resize(SQUARE * SQUARE / 8)
        var origin := square * SQUARE
        for y in SQUARE:
            for x in SQUARE:
                if has(origin + Vector2i(x, y)):
                    var bit := y * SQUARE + x
                    square_bits[bit >> 3] |= 1 << (bit & 7)
        _square_text["%d,%d" % [square.x, square.y]] = Marshalls.raw_to_base64(square_bits)
    _square_dirty = {}
    return _square_text.duplicate()

func from_squares(packed: Dictionary) -> void:
    for square in packed:
        var parts := String(square).split(",")
        if parts.size() != 2 or not packed[square] is String: continue
        var origin := Vector2i(int(parts[0]), int(parts[1])) * SQUARE
        var square_bits := Marshalls.base64_to_raw(String(packed[square]))
        for bit in range(mini(SQUARE * SQUARE, square_bits.size() * 8)):
            if square_bits[bit >> 3] & (1 << (bit & 7)):
                add(origin + Vector2i(bit % SQUARE, bit / SQUARE))
