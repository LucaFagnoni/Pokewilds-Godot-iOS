extends RefCounted
## The field commands the rules decide, by op: each rule's
## apply(state, player, cmd, rng) -> {"ok", "reason", "events", "grant",
## "consume"} (field_dig.gd has the shape). A game alone calls the rule and
## plays its events; online the player predicts with the same call and sends
## the command, and the authority (the host) runs it again on its own copy of
## the area with its own random numbers, which decide the rewards.
##
## Peers that send and take commands this way say so with "cmd:<op>" among
## the capabilities of their hello and welcome (coop_session.gd); the older
## messages (patches and the rewards the player claimed) remain for the rest.

const OPS := {
    "field_dig": preload("res://scripts/rules/field_dig.gd"),
    "field_cut": preload("res://scripts/rules/field_cut.gd"),
}
const DIG_ACTIONS := ["dig", "fill", "surface", "take", "berry", "plant"]
const CUT_MOVES := ["CUT", "SMASH", "HEADBUTT"]
const CUT_TARGETS := ["", "grass", "resource"]
## Events the authority's answer carries to the player (JSON-safe): what the
## player gained, what it says and an encounter. Sounds and redraws the player
## already played with its prediction.
const ANSWERED := ["dig_reward", "material", "bundle", "item", "message", "encounter"]

static func capabilities() -> Array:
    var caps := ["bin:area"]
    for op in OPS: caps.append("cmd:" + op)
    return caps

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
    else:
        if not wire.get("move") in CUT_MOVES or not String(wire.get("target", "")) in CUT_TARGETS: return null
        cmd["move"] = String(wire.move)
        cmd["target"] = String(wire.get("target", ""))
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
