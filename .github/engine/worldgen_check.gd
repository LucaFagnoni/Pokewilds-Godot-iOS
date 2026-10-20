# World generation must stay byte-identical for a given seed and size: saves,
# world caches and co-op peers all regenerate from the seed. This hashes the
# final world the game keeps (and caches): the adapter's packed tile store and
# its routes, the interiors, pokemon, edges, spawn, landmarks and the
# validation report (timings dropped), one hash per part, and compares the
# combined hash with the reference code's.
# Run: godot --headless --path project -s ../.github/engine/worldgen_check.gd
#      (add "-- <seed> <size>" to print one world's hash and its parts)
extends SceneTree

const EXPECTED := {
    "12345 0": "1d804798cdad9e508597d818d376c99067d33ed88e052b9f52479ccaf1eda1a8",
    "987654321 0": "b3d992b97f70826a7ff2618b0e4d396d71a4e7d731783a0a5f61805e9a033f45",
    "1792426775391992 0": "634a29c7cf0a77d8d0b8746cd46c1644a73c537fff1a7751d30ba6b632f2c2fd",
    # Its first attempt fails validation: the retry path.
    "1 0": "ed43abe8ab0fe81fbcd72252afa000b4dfeb0b1c5f39f4f68624f23b48727ea6",
    "1792426775391992 1": "cd2d28670042002434879fcd178af656d5402ce7233c67f9396c68bbc55cd50f",
    "424242 1": "1d2e6359573c8ab229b5c62d9bcb39fcbcc0ca804c7405e85efebb6989e141cf",
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
        var parts := {}
        var digest := _world_hash(int(args[0]), int(args[1]), parts)
        print("WORLDGEN %s %s %s" % [args[0], args[1], digest])
        for part in parts: print("  %s %s" % [part, parts[part]])
        quit()
        return
    var failures := 0
    for key: String in EXPECTED:
        var parts := key.split(" ")
        var started := Time.get_ticks_msec()
        var digest := _world_hash(int(parts[0]), int(parts[1]), {})
        var ok: bool = digest == EXPECTED[key]
        if not ok: failures += 1
        print("WORLDGEN %s seed=%s size=%s (%d ms)%s" % [
            "PASS" if ok else "FAIL", parts[0], parts[1], Time.get_ticks_msec() - started,
            "" if ok else " got " + digest])
    print("WORLDGEN: checked %d, failed %d" % [EXPECTED.size(), failures])
    quit(1 if failures else 0)

## Fills `parts` with one hash per part of the world; returns their hash.
func _world_hash(seed_value: int, size_index: int, parts: Dictionary) -> String:
    var result := SourceWorldGenerator.generate_exact_source_world(seed_value, size_index)
    var validation: Dictionary = result.get("generation_validation", {}).duplicate(true)
    validation.erase("elapsed_ms")
    var bottom_left: Variant = result.get("bottom_left")
    var top_right: Variant = result.get("top_right")
    var landmarks: Variant = result.get("landmark_origins")
    var interiors: Variant = result.get("interiors")
    var interior_pokemon: Variant = result.get("interior_pokemon")
    var world := SourceExactWorldAdapter.from_generator_result(
        result, SourceJavaRandom.new(seed_value ^ 0x535041574E))
    var store := world.tiles as WorldTileStore
    _ids.clear()
    var record := store.to_record()
    for key in record:
        var value: Variant = record[key]
        if value is PackedInt32Array:
            parts["store." + key] = _bytes_hash((value as PackedInt32Array).to_byte_array())
        elif value is PackedStringArray:
            parts["store." + key] = _bytes_hash("\n".join(value).to_utf8_buffer())
        else:
            parts["store." + key] = _walk_hash(value)
    # Routes are objects shared with the interiors: numbered in this order.
    parts["routes"] = _walk_hash(store.routes)
    parts["interiors"] = _walk_hash(interiors)
    parts["interior_pokemon"] = _walk_hash(interior_pokemon)
    parts["pokemon"] = _walk_hash(world.pokemon)
    parts["burrowed_pokemon"] = _walk_hash(world.burrowed_pokemon)
    parts["edges"] = _walk_hash(world.edges)
    parts["world"] = _walk_hash([world.bottom_left_cell, world.top_right_cell, world.spawn_cell,
        world.used_dungeons, world.regi_relocated_cells, bottom_left, top_right, landmarks])
    parts["validation"] = _walk_hash(validation)
    var all := HashingContext.new()
    all.start(HashingContext.HASH_SHA256)
    for part in parts: all.update((part + " " + parts[part] + "\n").to_utf8_buffer())
    return all.finish().hex_encode()

func _bytes_hash(bytes: PackedByteArray) -> String:
    var context := HashingContext.new()
    context.start(HashingContext.HASH_SHA256)
    context.update(bytes)
    return context.finish().hex_encode()

func _walk_hash(value: Variant) -> String:
    _context = HashingContext.new()
    _context.start(HashingContext.HASH_SHA256)
    _walk(value, 0)
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
