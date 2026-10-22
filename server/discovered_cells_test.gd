# The discovered-cells bitset (discovered_cells.gd): adds and counts, the save
# form round trip, old saves' "x,y" lists and the co-op squares, which must stay
# byte for byte what the old packing made (other peers read them).
# Run: godot --headless --path project -s ../server/discovered_cells_test.gd
extends SceneTree

const DiscoveredCells = preload("res://scripts/discovered_cells.gd")

var failed := 0

func check(ok: bool, what: String) -> void:
    if not ok:
        failed += 1
        printerr("DISCOVERED CELLS TEST FAIL: ", what)

## The co-op packing as it was done from a Dictionary of "x,y" keys.
func old_squares(keys: Array) -> Dictionary:
    var squares := {}
    for key in keys:
        var x := int(String(key).get_slice(",", 0))
        var y := int(String(key).get_slice(",", 1))
        var sx := floori(float(x) / 32)
        var sy := floori(float(y) / 32)
        var square := "%d,%d" % [sx, sy]
        var bits: PackedByteArray = squares.get(square, PackedByteArray())
        if bits.is_empty(): bits.resize(128)
        var bit := (y - sy * 32) * 32 + (x - sx * 32)
        bits[bit >> 3] = bits[bit >> 3] | (1 << (bit & 7))
        squares[square] = bits
    var text := {}
    for square in squares: text[square] = Marshalls.raw_to_base64(squares[square])
    return text

func _initialize() -> void:
    var cells := DiscoveredCells.new()
    var rect := Rect2i(-70, -45, 150, 101)
    cells.reset(rect)
    var keys: Array = []
    var rng := RandomNumberGenerator.new()
    rng.seed = 7
    for i in 3000:
        var cell := Vector2i(rng.randi_range(rect.position.x, rect.end.x - 1), rng.randi_range(rect.position.y, rect.end.y - 1))
        var key := "%d,%d" % [cell.x, cell.y]
        check(cells.add(cell) == (key not in keys), "add reports a new cell")
        if key not in keys: keys.append(key)
    check(cells.size() == keys.size(), "count")
    check(not cells.add(rect.end), "a cell off the map is ignored")
    check(cells.has(Vector2i(int(keys[0].get_slice(",", 0)), int(keys[0].get_slice(",", 1)))), "has")
    check(cells.cells().size() == keys.size(), "cells()")
    check(cells.to_squares() == old_squares(keys), "co-op squares as before")
    var more := Vector2i(rect.position.x, rect.position.y)
    cells.add(more)
    keys.append("%d,%d" % [more.x, more.y])
    check(cells.to_squares() == old_squares(keys), "co-op squares after an add")
    var saved = JSON.parse_string(JSON.stringify(cells.to_save()))
    var loaded := DiscoveredCells.new()
    loaded.reset(rect)
    loaded.from_save(saved)
    check(loaded.size() == cells.size() and loaded.bits == cells.bits, "save round trip")
    var old_save := DiscoveredCells.new()
    old_save.reset(rect)
    old_save.from_save(keys)
    check(old_save.bits == cells.bits, "an old save's key list")
    var from_coop := DiscoveredCells.new()
    from_coop.reset(rect)
    from_coop.from_save(old_squares(keys))
    check(from_coop.bits == cells.bits, "co-op squares read back")
    var moved := DiscoveredCells.new()
    moved.reset(rect.grow(3))
    moved.from_save(saved)
    check(moved.size() == cells.size() and moved.cells().size() == cells.size(), "a save over other bounds")
    cells.clear()
    check(cells.size() == 0 and cells.to_squares().is_empty(), "clear")
    print("DISCOVERED CELLS TEST: %d failed" % failed)
    quit(1 if failed else 0)
