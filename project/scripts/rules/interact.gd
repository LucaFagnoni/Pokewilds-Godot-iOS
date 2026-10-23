extends RefCounted
## What a player does to a built piece that changes it for everyone, as one
## command: apply(state, player, cmd, rng) -> {"ok", "reason", "events",
## "grant", "consume"} (build.gd has the events): a SIGN written, a BEACON
## named, a TORCH lit or put out, a WINDOW turned, a window's glass changed,
## a PLANT's MIRACLE SEED picked once a day (by the authority's clock).
## Doors are opened by walking into them, each player's own.
##
## cmd: {"cell": Vector2i, "action": one of ACTIONS, "text": a SIGN's words
##   or a BEACON's name}. player.now: world seconds (the day a PLANT counts).

const Build = preload("res://scripts/rules/build.gd")
const ACTIONS := ["sign", "beacon", "torch", "window", "plant", "glass"]
const DAY_SECONDS := (18000.0 + 5000.0) / 60.0

static func apply(state, player: Dictionary, cmd: Dictionary, _rng: RandomNumberGenerator) -> Dictionary:
    var out := {"ok": false, "reason": "", "events": [], "grant": {}, "consume": {}}
    var cell: Vector2i = cmd.get("cell", Vector2i.ZERO)
    var action := String(cmd.get("action", ""))
    if not Build.context(state, player):
        out.reason = "no_house"
        return out
    if action == "glass":
        out.ok = glass(state, player, cell, out)
        if not out.ok: out.reason = "no_window"
        return out
    var name := String(state.structures.get(cell, {}).get("name", ""))
    var wanted := {"sign": "SIGN", "beacon": "BEACON", "torch": "TORCH", "window": "WINDOW", "plant": "PLANT"}
    if not wanted.has(action) or name != wanted[action]:
        out.reason = "not_a_" + (action if wanted.has(action) else "piece")
        return out
    var piece: Dictionary = state.structures[cell]
    match action:
        "sign":
            var text := String(cmd.get("text", "")).strip_edges().left(64)
            Build.set_field(state, cell, "text", text)
            out.events.append(["message", "The SIGN now reads: %s" % text])
        "beacon":
            var label := String(cmd.get("text", "")).strip_edges().left(32)
            Build.set_field(state, cell, "label", label)
            out.events.append(["message", "The BEACON name was cleared." if label.is_empty() else "BEACON named %s." % label])
        "torch":
            var lit := not bool(piece.get("lit", true))
            Build.set_field(state, cell, "lit", lit)
            out.events.append(["structure", cell])
            out.events.append(["message", "The TORCH is now %s." % ("lit" if lit else "out")])
        "window":
            Build.set_field(state, cell, "variant", wrapi(int(piece.get("variant", 0)) + 1, 0, 3))
            out.events.append(["structure", cell])
            out.events.append(["message", "You adjusted the WINDOW."])
        "plant":
            var day := int(floor(float(player.get("now", 0.0)) / DAY_SECONDS))
            if int(piece.get("last_harvest_day", -1)) >= day:
                out.events.append(["message", "The PLANT needs another day to grow."])
                out.reason = "not_grown"
                return out
            Build.set_field(state, cell, "last_harvest_day", day)
            out.events.append(["material", "MIRACLE SEED", 1])
            out.grant["MIRACLE SEED"] = 1
            out.events.append(["message", "The PLANT yielded a MIRACLE SEED."])
    out.ok = true
    return out

## Whether `cell` has glass to change: an indoor window set in a wall outside,
## or a window hung inside a house (world_buildings.gd interact_house_window).
static func has_glass(state, player: Dictionary, cell: Vector2i) -> bool:
    if String(player.get("area_id", "")) == "OVERWORLD":
        var wall: Dictionary = state.structures.get(cell, {})
        return bool(wall.get("window", false)) and String(wall.get("window_recipe", "")).begins_with("INDOOR WINDOW ")
    if String(player.get("area_id", "")) != "HOUSE": return false
    return Build.is_window(String(state.built_house_decorations.get(Build.paint_key(player.get("house", {}), cell), {}).get("name", "")))

## A window's glass turned to its next look; false when there is none at `cell`.
static func glass(state, player: Dictionary, cell: Vector2i, out: Dictionary) -> bool:
    if not has_glass(state, player, cell): return false
    if String(player.get("area_id", "")) == "OVERWORLD":
        var kind := String(state.structures[cell].get("window_recipe", ""))
        Build.set_field(state, cell, "window_variant", wrapi(int(state.structures[cell].get("window_variant", 0)) + 1, 0, 3 if kind.ends_with("1") else 2))
        out.events.append(["structure", cell])
        out.events.append(["sound", "seed1"])
        return true
    var key := Build.paint_key(player.get("house", {}), cell)
    var data: Dictionary = state.built_house_decorations.get(key, {})
    var build_name := String(data.get("name", ""))
    if build_name == "INDOOR WINDOW 1": return true
    var turned := data.duplicate()
    turned["variant"] = wrapi(int(data.get("variant", 0)) + 1, 0, 2 if build_name.ends_with("2") else 3)
    state.put("built_house_decorations", key, turned)
    out.events.append(["house_decoration", cell])
    out.events.append(["sound", "seed1"])
    return true
