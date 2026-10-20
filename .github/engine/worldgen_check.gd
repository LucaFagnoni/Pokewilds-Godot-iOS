# World generation must stay byte-identical for a given seed and size: saves,
# world caches and co-op peers all regenerate from the seed. This hashes the
# whole generate_exact_source_world result in canonical form (insertion order
# and shared objects kept, timings dropped) and compares it with the hashes of
# the reference code.
# Run: godot --headless --path project -s ../.github/engine/worldgen_check.gd
#      (add "-- <seed> <size>" to print one world's hash instead)
extends SceneTree

const EXPECTED := {
    "12345 0": "da0c497d68695946fc9afda904c6c6d9b86e92746c627e9648c5bd1299a087f0",
    "987654321 0": "4fa40ba0c9ac8c4f4a6dc171c63d71461fe91d77511e9e0e043688988736baa8",
    "1792426775391992 0": "7ac39c6c4e5ef4e21268b987982a74dd5d1f66499e156b79052ac80768fa14e9",
    "1792426775391992 1": "9e7dca0e8af639393d73baf05341ffc01da0b40bc213e41a88c59aa8ff095c2c",
    "424242 1": "e635d3d7286d62ea295da2cf573750211e449ab8b44a13f35299395bd7bb8eb7",
}

var _ids: Dictionary = {}
var _tile_props: Array[String] = []
var _route_props: Array[String] = []
var _context: HashingContext
var _lines := PackedStringArray()

func _initialize() -> void:
    for p in SourceTile.new("x", Vector2i.ZERO).get_property_list():
        # Proxy bookkeeping and accessor aliases are not tile state.
        if p.usage & PROPERTY_USAGE_SCRIPT_VARIABLE and p.name not in [
                "_store", "_loading", "_index", "resident_revision", "items", "door_tiles"]:
            _tile_props.append(p.name)
    for p in SourceRoute.new("x", 0).get_property_list():
        if p.usage & PROPERTY_USAGE_SCRIPT_VARIABLE:
            _route_props.append(p.name)
    var args := OS.get_cmdline_user_args()
    if args.size() >= 2:
        print("WORLDGEN %s %s %s" % [args[0], args[1], _world_hash(int(args[0]), int(args[1]))])
        quit()
        return
    var failures := 0
    for key: String in EXPECTED:
        var parts := key.split(" ")
        var started := Time.get_ticks_msec()
        var digest := _world_hash(int(parts[0]), int(parts[1]))
        var ok: bool = digest == EXPECTED[key]
        if not ok: failures += 1
        print("WORLDGEN %s seed=%s size=%s (%d ms)" % [
            "PASS" if ok else "FAIL", parts[0], parts[1], Time.get_ticks_msec() - started])
    print("WORLDGEN: checked %d, failed %d" % [EXPECTED.size(), failures])
    quit(1 if failures else 0)

func _world_hash(seed_value: int, size_index: int) -> String:
    var result := SourceWorldGenerator.generate_exact_source_world(seed_value, size_index)
    var validation: Dictionary = result.get("generation_validation", {}).duplicate(true)
    validation.erase("elapsed_ms")
    result["generation_validation"] = validation
    _ids.clear()
    _context = HashingContext.new()
    _context.start(HashingContext.HASH_SHA256)
    for key in result:
        _emit("== " + str(key))
        _walk(result[key], 0)
    _flush()
    return _context.finish().hex_encode()

func _emit(line: String) -> void:
    _lines.append(line)
    if _lines.size() >= 4096: _flush()

func _flush() -> void:
    if _lines.is_empty(): return
    _context.update(("\n".join(_lines) + "\n").to_utf8_buffer())
    _lines.clear()

func _walk(value: Variant, depth: int) -> void:
    var pad := " ".repeat(depth)
    if value is SourceTile or value is SourceRoute:
        # Objects are numbered on first sight, so sharing shows in the hash.
        var id: int = value.get_instance_id()
        if _ids.has(id):
            _emit(pad + "@" + str(_ids[id]))
            return
        _ids[id] = _ids.size()
        var is_tile: bool = value is SourceTile
        var props := _tile_props if is_tile else _route_props
        var parts := PackedStringArray([("T#" if is_tile else "R#") + str(_ids[id])])
        for prop in props:
            var field: Variant = value.get(prop)
            if not (field is Object or field is Dictionary or field is Array):
                parts.append(prop + "=" + var_to_str(field))
        _emit(pad + " ".join(parts))
        for prop in props:
            var field: Variant = value.get(prop)
            if field is Object or field is Dictionary or field is Array:
                _emit(pad + " ." + prop)
                _walk(field, depth + 2)
    elif value is Dictionary:
        _emit(pad + "{%d" % (value as Dictionary).size())
        for key in value:
            _emit(pad + "k " + var_to_str(key))
            _walk(value[key], depth + 1)
    elif value is Array:
        _emit(pad + "[%d" % (value as Array).size())
        for item in value:
            _walk(item, depth + 1)
    elif value is Object:
        _emit(pad + "O " + str(value.get_class()))
    else:
        _emit(pad + var_to_str(value))
