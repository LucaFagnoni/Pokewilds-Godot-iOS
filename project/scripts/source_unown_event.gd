extends RefCounted

# Per-world progress is already included in normal saves and neighboring caches.
const KEY := "unown_cycle"

static func signs(world: Node) -> Dictionary:
    var result := {}
    if world.exact_world == null: return result
    if not world.exact_world.has_meta("unown_generated_signs"):
        var generated: Array = []
        for tile in world.exact_world.tiles.values():
            if tile != null and String(tile.has_item).begins_with("trainer_tips"):
                generated.append(Vector2i(tile.position / 16))
        world.exact_world.set_meta("unown_generated_signs", generated)
    for raw_cell in world.exact_world.get_meta("unown_generated_signs"):
        var cell := Vector2i(raw_cell)
        var tile = world.exact_world.tiles.get(cell * 16)
        if tile == null or not String(tile.has_item).begins_with("trainer_tips"): continue
        if world.removed_resources.has(world._cell_key(cell)) or world.built_structures.has(cell): continue
        if tile.name_upper != "sign1": continue
        result[world._cell_key(cell)] = tile.has_item == "trainer_tips_unown"
    return result

static func state(world: Node) -> Dictionary:
    if world.event_progress.has(KEY): return world.event_progress[KEY]
    var available := signs(world)
    var armed: Array = []
    var completed: Dictionary = world.event_progress.get("completed", {})
    for key in available:
        if available[key] and not completed.get("unown_sign:OVERWORLD:" + key, false):
            armed.append(key)
    # Repair old saves whose original cursed sign was permanently consumed.
    if armed.is_empty() and not available.is_empty():
        armed.append(available.keys()[world.rng.randi_range(0, available.size()-1)])
    var result := {"armed": armed, "active": false, "last_sign": "", "king_caught": false}
    world.event_progress[KEY] = result
    return result

static func active(world: Node) -> bool:
    return bool((world.event_progress.get(KEY, {}) as Dictionary).get("active", false))

static func read_sign(world: Node, cell: Vector2i) -> bool:
    if world.active_area_id != "OVERWORLD": return false
    var available := signs(world)
    var key: String = world._cell_key(cell)
    if not available.has(key): return false
    var progress := state(world)
    var armed: Array = progress.armed
    # A removed/cut host must not permanently strand the cycle.
    armed = armed.filter(func(value): return available.has(value))
    if armed.is_empty() and not progress.active:
        armed.append(available.keys()[world.rng.randi_range(0, available.size()-1)])
    progress.armed = armed
    if not armed.has(key): return false
    armed.erase(key)
    progress.active = true
    progress.last_sign = key
    return true

static func complete(world: Node, result: Dictionary) -> void:
    if not active(world): return
    var progress := state(world)
    var context: Dictionary = result.get("context", {})
    if bool(context.get("unown_king", false)) and result.get("outcome", "") == "captured":
        progress.king_caught = true
    progress.active = false
    var available := signs(world)
    var candidates: Array = available.keys()
    if candidates.size() > 1: candidates.erase(String(progress.last_sign))
    var armed: Array = progress.armed
    armed = armed.filter(func(value): return available.has(value))
    if not candidates.is_empty():
        var next: String = candidates[world.rng.randi_range(0, candidates.size()-1)]
        if not armed.has(next): armed.append(next)
    progress.armed = armed

static func encounter(world: Node, king_available: bool = false) -> Dictionary:
    var progress := state(world)
    var allow_king := king_available and not bool(progress.king_caught)
    var roll: int = world.rng.randi_range(0, 29 if allow_king else 27)
    var king := roll >= 28
    var letters := "abcdefghijklmnopqrstuvwxyz"
    var species := "unown_king" if king else "unown_" + (letters.substr(roll, 1) if roll < 26 else "!" if roll == 26 else "qmark")
    return {"id": "source_unown", "kind": "wild", "can_run": true,
        "can_catch": true, "source_unown": true, "unown_king": king,
        "party": [{"species": species, "level": 70 if king else 13}]}
