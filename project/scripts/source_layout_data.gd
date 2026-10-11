class_name SourceLayoutData
extends RefCounted

const DATA_PATH := "res://assets/source_0_8_11/generator_layouts.json"
static var _layouts: Dictionary = {}

static func rows(java_class: String, method: String, ordinal: int) -> Array:
    _load()
    return (_layouts.get(_key(java_class, method, ordinal), []) as Array).duplicate(true)

static func make_plan(
        area_id: String,
        java_class: String,
        method: String,
        ordinal: int,
        default_entry: Vector2i
    ) -> Dictionary:
    var layout_rows := rows(java_class, method, ordinal)
    assert(not layout_rows.is_empty(), "Missing source Java layout")
    var width := 0
    for row: Array in layout_rows:
        width = maxi(width, row.size())
    var tiles: Dictionary = {}
    var solids: Dictionary = {}
    var entry := default_entry
    var up := Vector2i(-1, -1)
    var down := Vector2i(-1, -1)
    for y in range(layout_rows.size()):
        var row: Array = layout_rows[y]
        for x in range(row.size()):
            if row[x] == null:
                continue
            var tile_name := String(row[x])
            var cell := Vector2i(x, y)
            tiles[cell] = tile_name
            if SourceWorldData.is_solid(tile_name):
                solids[cell] = true
            if "entrance" in tile_name or "door" in tile_name:
                entry = cell
            if "stairs_up" in tile_name:
                up = cell
            if "stairs_down" in tile_name:
                down = cell
    return {
        "id": area_id,
        "size": Vector2i(width, layout_rows.size()),
        "tiles": tiles,
        "solids": solids,
        "entry": entry,
        "up": up,
        "down": down,
        "previous": "OVERWORLD",
        "next": ""
    }

static func _load() -> void:
    if not _layouts.is_empty():
        return
    var file := FileAccess.open(DATA_PATH, FileAccess.READ)
    assert(file != null, "Missing extracted Java generator layouts")
    var payload: Dictionary = JSON.parse_string(file.get_as_text())
    for descriptor: Dictionary in payload.get("layouts", []):
        _layouts[_key(String(descriptor["class"]), String(descriptor["method"]), int(descriptor["ordinal"]))] = descriptor["rows"]

static func _key(java_class: String, method: String, ordinal: int) -> String:
    return "%s:%s:%d" % [java_class, method, ordinal]
