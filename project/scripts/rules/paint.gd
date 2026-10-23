extends RefCounted
## SMEARGLE's PAINT on an inside house wall, as one command: apply(state,
## player, cmd, rng) -> {"ok", "reason", "events", "grant", "consume"}
## (build.gd has the events and the player). A picture costs one THIN PAPER.
##
## cmd: {"cell": Vector2i, "picture": 1..20}. player.species: the field
## move's Pokemon (only a SMEARGLE paints).

const Build = preload("res://scripts/rules/build.gd")
const COST := {"THIN PAPER": 1}

static func apply(state, player: Dictionary, cmd: Dictionary, _rng: RandomNumberGenerator) -> Dictionary:
    var out := {"ok": false, "reason": "", "events": [], "grant": {}, "consume": {}}
    var cell: Vector2i = cmd.get("cell", Vector2i.ZERO)
    if not Build.context(state, player):
        out.reason = "no_house"
        return out
    var ctx: Dictionary = player.get("house", {})
    if String(player.get("area_id", "")) != "HOUSE" or String(player.get("species", "")).to_lower() != "smeargle":
        out.events.append(["message", "PAINT can only be used by SMEARGLE on an inside house wall."])
        out.reason = "not_smeargle"
        return out
    if not ctx.get("walls", {}).has(cell):
        out.events.append(["message", "Face an inside house wall to PAINT it."])
        out.reason = "not_a_wall"
        return out
    if player.has("bag") and int(player.bag.get("THIN PAPER", 0)) < 1:
        out.events.append(["message", "PAINT needs 1 THIN PAPER."])
        out.reason = "not_enough_materials"
        return out
    var index := clampi(int(cmd.get("picture", 1)), 1, 20)
    var key := Build.paint_key(ctx, cell)
    if key.is_empty():
        out.reason = "no_house"
        return out
    state.put("built_house_paintings", key, index)
    out.events.append(["painted", cell, index])
    out.events.append(["sound", "craft1"])
    out.events.append(["message", "SMEARGLE painted PICTURE %d." % index])
    out.consume = COST.duplicate()
    out.ok = true
    return out
