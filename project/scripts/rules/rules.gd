extends RefCounted
## The field commands the rules decide, by op (DIG, CUT, building, paint and
## taking built pieces away): each rule's
## apply(state, player, cmd, rng) -> {"ok", "reason", "events", "grant",
## "consume"} (field_dig.gd has the shape). A game alone calls the rule and
## plays its events; online the player predicts with the same call and sends
## the command, and the authority (the host) runs it again on its own copy of
## the area with its own random numbers, which decide the rewards.

const OPS := {
    "field_dig": preload("res://scripts/rules/field_dig.gd"),
    "field_cut": preload("res://scripts/rules/field_cut.gd"),
    "build": preload("res://scripts/rules/build.gd"),
    "paint": preload("res://scripts/rules/paint.gd"),
    "remove_build": preload("res://scripts/rules/remove.gd"),
}
const CraftingData = preload("res://scripts/crafting_data.gd")
const DIG_ACTIONS := ["dig", "fill", "surface", "take", "berry", "plant"]
const CUT_MOVES := ["CUT", "SMASH", "HEADBUTT"]
const CUT_TARGETS := ["", "grass", "resource"]
## Events the authority's answer carries to the player (JSON-safe): what the
## player gained, what it says and an encounter. Sounds and redraws the player
## already played with its prediction.
const ANSWERED := ["dig_reward", "material", "bundle", "item", "message", "encounter"]

## The parts of the player's record (coop_state.gd PARTS) the command reads:
## the bag for one that pays from it (a fill, a planting, a build, a
## picture), saved just ahead of it when it changed here (coop_game.gd
## command), so the authority reads the bag as the player has it. None
## otherwise: what any command gives or takes is a change the host makes to
## the bag (grant, consume), never a record saved before it.
static func reads(op: String, cmd: Variant) -> Array:
    if not cmd is Dictionary: return []
    if op in ["build", "paint"] or (op == "field_dig" and String(cmd.get("action", "")) in ["fill", "plant"]): return ["bag"]
    return []

static func apply(op: String, state, player: Dictionary, cmd: Dictionary, rng: RandomNumberGenerator) -> Dictionary:
    var rule = OPS.get(op)
    if rule == null: return {"ok": false, "reason": "invalid_command", "events": [], "grant": {}, "consume": {}}
    return rule.apply(state, player, cmd, rng)

## `cmd` as it travels (JSON: a cell as [x, y]).
static func to_wire(cmd: Dictionary) -> Dictionary:
    var wire := cmd.duplicate()
    var cell: Vector2i = cmd.get("cell", Vector2i.ZERO)
    wire["cell"] = [cell.x, cell.y]
    return wire

## A command from the wire, checked field by field; null when it is not one.
static func from_wire(op: String, wire: Variant) -> Variant:
    if not wire is Dictionary or wire.size() > 12 or not OPS.has(op): return null
    var cell = wire.get("cell")
    if not cell is Array or cell.size() != 2 or not _whole(cell[0]) or not _whole(cell[1]): return null
    var cmd := {"cell": Vector2i(int(cell[0]), int(cell[1]))}
    if op == "field_dig":
        if not wire.get("action") in DIG_ACTIONS: return null
        cmd["action"] = String(wire.action)
        for key in ["choice", "item", "item_action"]:
            if wire.has(key):
                if not wire[key] is String or wire[key].length() > 64: return null
                cmd[key] = wire[key]
    elif op == "field_cut":
        if not wire.get("move") in CUT_MOVES or not String(wire.get("target", "")) in CUT_TARGETS: return null
        cmd["move"] = String(wire.move)
        cmd["target"] = String(wire.get("target", ""))
    elif op == "build":
        var recipe = wire.get("recipe")
        if not recipe is String or recipe.length() > 64 or CraftingData.build_recipe(recipe).is_empty(): return null
        cmd["recipe"] = recipe
    elif op == "paint":
        if not _whole(wire.get("picture")) or int(wire.picture) < 1 or int(wire.picture) > 20: return null
        cmd["picture"] = int(wire.picture)
    else:
        if not wire.get("move") in ["CUT", "SMASH"]: return null
        cmd["move"] = String(wire.move)
        for key in ["decoration", "wipe"]:
            if wire.has(key):
                if not wire[key] is bool: return null
                cmd[key] = wire[key]
    return cmd

## The events of a result fit for the answer: only ANSWERED, cells as [x, y].
static func answered(events: Array) -> Array:
    var kept := []
    for event in events:
        if not event[0] in ANSWERED: continue
        var copy: Array = event.duplicate()
        if copy[0] == "encounter" and copy.size() > 5:
            var cell: Vector2i = copy[5]
            copy[5] = [cell.x, cell.y]
        kept.append(copy)
    return kept

static func _whole(value: Variant) -> bool:
    return (value is int or value is float) and is_finite(float(value)) and float(value) == floor(float(value)) and absf(float(value)) < 1000000.0
