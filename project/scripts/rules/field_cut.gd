extends RefCounted
## CUT, SMASH and HEADBUTT on what grows or lies on the ground, as one
## command: apply(state, player, cmd, rng) -> {"ok", "reason", "events",
## "grant", "consume"} (field_dig.gd has the shape). A window or clock on a
## house wall and a built piece are not cut here: the World sends those to the
## structure removal (remove_build).
##
## cmd: {"move": "CUT"|"SMASH"|"HEADBUTT", "cell": Vector2i, "target": ""|
## "grass"|"resource"}. CUT takes a planted crop, then grass, then the tree or
## bush the cell is part of ("grass": only grass; "resource": the resource
## anchored at the cell, no grass); SMASH and HEADBUTT the rock at the cell.
## player: {"species": the field move's Pokemon (a large tree needs a fully
## evolved one), "shared": true online}.
## events, besides field_dig's: ["material", item, amount] and ["bundle",
## items] (rewards as the game shows them), ["cut_halves", cell, tile] (the
## split drawn from the tile as it was, a copy).

const TileRules = preload("res://scripts/rules/tile_rules.gd")
const FieldMoveData = preload("res://scripts/field_move_data.gd")
const CraftingData = preload("res://scripts/crafting_data.gd")
const NO_CELL := Vector2i(-2147483648, -2147483648)

static func apply(state, player: Dictionary, cmd: Dictionary, rng: RandomNumberGenerator) -> Dictionary:
    var out := {"ok": false, "reason": "", "events": [], "grant": {}, "consume": {}}
    var cell: Vector2i = cmd.get("cell", Vector2i.ZERO)
    var move := String(cmd.get("move", "CUT"))
    if state.tiles == null:
        out.reason = "no_area"
    elif move == "CUT":
        var target := String(cmd.get("target", ""))
        if target == "resource":
            harvest(state, player, cell, move, out, rng)
        elif TileRules.is_cuttable_grass(state, cell):
            _grass(state, cell, out, rng)
        elif target == "grass":
            out.reason = "not_grass"
        else:
            var anchor := TileRules.exact_resource_anchor(state, cell)
            if anchor.x > -2147483648: harvest(state, player, anchor, move, out, rng)
            else: out.reason = "nothing_to_cut"
    elif move in ["SMASH", "HEADBUTT"]:
        harvest(state, player, cell, move, out, rng)
    else:
        out.reason = "invalid_move"
    if not out.ok and out.reason.is_empty(): out.reason = "nothing_to_cut"
    return out

static func _material(out: Dictionary, item: String, amount: int) -> void:
    out.events.append(["material", item, amount])
    out.grant[item] = int(out.grant.get(item, 0)) + amount

static func _bundle(out: Dictionary, items: Dictionary) -> void:
    out.events.append(["bundle", items.duplicate(true)])
    for item in items: out.grant[item] = int(out.grant.get(item, 0)) + maxi(1, int(items[item]))

## A grass tuft cut (a planted crop harvested first).
static func _grass(state, cell: Vector2i, out: Dictionary, rng: RandomNumberGenerator) -> void:
    if harvest_crop(state, cell, out, rng):
        out.ok = true
        return
    _material(out, "GRASS", 1)
    out.events.append(["sound", "cut1"])
    var tile: SourceTile = state.tile_at(cell)
    if tile != null:
        var old_base := tile.name.to_lower().trim_suffix(".png")
        # The grass2 Miracle Seed bonus; the GRASS itself is always x1.
        if old_base == "grass2" and rng.randi_range(0, 255) < 64:
            _material(out, "MIRACLE SEED", 1)
        var replacement := TileRules.cuttable_grass_replacement(state, tile, cell)
        tile = state.edit(cell)
        tile.set_names(String(replacement.get("base", tile.name)), String(replacement.get("upper", "")))
        state.put("source_interior_mutations", cell, {"kind":"TILE_NAMES", "base":tile.name, "upper":tile.name_upper})
        TileRules.unblock_ground(state, cell)
        out.events.append(["refresh"])
    out.ok = true

## A crop grown on `cell` (source_plant_farming.gd), harvested: false when there is none.
static func harvest_crop(state, cell: Vector2i, out: Dictionary, rng: RandomNumberGenerator) -> bool:
    if not state.source_plant_farms.has(cell): return false
    var record: Dictionary = state.source_plant_farms[cell]
    var rewards: Dictionary = record.get("rewards", {})
    var tile: SourceTile = state.tile_at(cell)
    var is_grass := tile.name.begins_with("grass") or tile.name_upper.begins_with("grass")
    if is_grass:
        if tile.name_upper == "grass_planted":
            rewards = {"MIRACLE SEED":1}
        else:
            var amount := 4 if tile.name_upper == "grass_savanna1" else 2 if tile.name in ["grass4","grass_sand3","grass_graveyard1"] or tile.name_upper == "grass_savanna2" else 1
            rewards = {"GRASS":amount}
            if tile.name == "grass2" and rng.randi_range(0, 255) < 64:
                rewards["MIRACLE SEED"] = 1
    if rewards.is_empty(): return false
    _bundle(out, rewards)
    tile = state.edit(cell)
    if is_grass:
        var replacement := TileRules.cuttable_grass_replacement(state, tile, cell)
        tile.set_names(String(replacement.base), String(replacement.upper))
    else:
        tile.set_names(tile.name, "")
    state.put("source_interior_mutations", cell, {"kind":"TILE_NAMES", "base":tile.name, "upper":""})
    state.drop("source_plant_farms", cell)
    out.events.append(["sound", "cut1"])
    out.events.append(["refresh"])
    return true

## A tree, bush, cactus or rock at `cell` cut or smashed: its materials,
## sometimes a Pokemon from a rock's route.
static func harvest(state, player: Dictionary, cell: Vector2i, move: String, out: Dictionary, rng: RandomNumberGenerator) -> void:
    if move == "CUT" and harvest_crop(state, cell, out, rng):
        out.ok = true
        return
    var tile: SourceTile = state.tile_at(cell)
    if tile == null:
        return
    var kind := TileRules.exact_resource_kind(state, cell)
    if move == "CUT" and kind not in ["tree", "bush"]:
        out.events.append(["message", "CUT can't be used on that."])
        out.reason = "not_a_tree"
        return
    var key := (tile.name + " " + tile.name_upper).to_lower()
    if move == "CUT" and kind == "tree" and TileRules.is_large_tree(state, cell) and "tree4" not in key and \
            not FieldMoveData.is_fully_evolved(String(player.get("species", ""))):
        out.events.append(["message", "This tree needs a fully evolved Pokemon to CUT it."])
        out.reason = "needs_evolved"
        return
    if move in ["SMASH", "HEADBUTT"] and kind != "rock":
        out.events.append(["message", "%s can't be used on that." % move])
        out.reason = "not_a_rock"
        return
    var smash_encounter: Dictionary = {}
    var smash_bonus_item := ""
    if move in ["SMASH", "HEADBUTT"] and tile.route_belongs_to != null and not tile.route_belongs_to.stored_pokemon.is_empty():
        var raw_smash = tile.route_belongs_to.stored_pokemon[0]
        if typeof(raw_smash) == TYPE_DICTIONARY:
            smash_encounter = (raw_smash as Dictionary).duplicate(true)
    out.events.append(["sound", "cut1" if move == "CUT" else ("headbutt1" if move == "HEADBUTT" else "strength1")])
    # Source-parity CUT rewards. Logical palm tree5 renders with tree6 art;
    # both identities are seed-only and must never leak into the LOG path.
    if move == "CUT" and "berrytree_" in key:
        _material(out, "BERRY SEED", 2)
    elif move == "CUT" and ("tree5" in key or "tree6" in key):
        _material(out, "MIRACLE SEED", 1)
    elif move == "CUT" and kind == "bush" and (String(tile.biome).to_upper() in ["SNOW", "TUNDRA", "SAVANNA"] or "bush_savanna1" in key):
        # Savannah bushes are the source's simple LOG + GRASS, no Apricorn roll.
        _bundle(out, {"GRASS":1, "LOG":1})
    elif move == "CUT" and "bush2_color" in key:
        var apricorn := String(CraftingData.APRICORNS[rng.randi_range(0, CraftingData.APRICORNS.size() - 1)])
        _bundle(out, {"LOG":1, apricorn:1})
    else:
        var material := "HARD STONE" if kind == "rock" else "LOG"
        var amount := 1
        if kind == "tree" and TileRules.is_large_tree(state, cell):
            amount = rng.randi_range(2, 7)
        _material(out, material, amount)
        if move == "SMASH" and kind == "rock" and TileRules.source_biome(tile) == "MOUNTAIN" and rng.randi_range(0, 15) == 0:
            smash_bonus_item = "MOON STONE"
            _material(out, smash_bonus_item, 1)
        if move == "CUT" and "aloe_large1" in key:
            _material(out, "MIRACLE SEED", 1)
    var giant_anchor := TileRules.large_tree1_anchor(state, cell) if move == "CUT" else NO_CELL
    if move == "CUT":
        var shown := giant_anchor if giant_anchor.x > -2147483648 else cell
        var as_it_was: SourceTile = state.tile_at(shown)
        out.events.append(["cut_halves", shown, as_it_was.copy_at() if as_it_was != null else null])
    if giant_anchor.x > -2147483648:
        _cut_large_tree1(state, giant_anchor)
    else:
        var replacement := TileRules.cut_resource_replacement(state, tile, cell)
        tile = state.edit(cell)
        tile.set_names(String(replacement.get("base", tile.name)), String(replacement.get("upper", "")))
        state.put("source_interior_mutations", cell, {"kind":"TILE_NAMES", "base":tile.name, "upper":tile.name_upper})
        TileRules.unblock_ground(state, cell)
    out.events.append(["refresh"])
    if move in ["SMASH", "HEADBUTT"]:
        if smash_encounter.is_empty():
            if move == "SMASH" and not smash_bonus_item.is_empty():
                out.events.append(["message", "SMASH! You gathered HARD STONE and found a %s." % smash_bonus_item])
            else:
                out.events.append(["message", "%s! You gathered HARD STONE." % move])
        else:
            out.events.append(["message", "%s! A Pokemon jumped out of the rock!" % move])
            out.events.append(["encounter", String(smash_encounter.get("name", "geodude")).to_lower(),
                int(smash_encounter.get("level", TileRules.level_for_cell(state, cell))), smash_encounter, false])
    out.ok = true

## The four parts of a giant tree cleared to the ground around them.
static func _cut_large_tree1(state, anchor: Vector2i) -> void:
    for offset in [Vector2i.ZERO, Vector2i.RIGHT, Vector2i.DOWN, Vector2i(1, 1)]:
        var part_cell: Vector2i = anchor + offset
        var part: SourceTile = state.tile_at(part_cell)
        if part == null:
            continue
        var replacement := TileRules.contextual_ground_name(state, part_cell, part.biome)
        if replacement.is_empty() or replacement.begins_with("grass"):
            replacement = "green1"
        part = state.edit(part_cell)
        part.set_names(replacement, "")
        state.put("source_interior_mutations", part_cell, {"kind":"TILE_NAMES", "base":replacement, "upper":""})
        state.drop("blocked", part_cell)
