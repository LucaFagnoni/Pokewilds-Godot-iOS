extends RefCounted
## DIG and what goes with it, as one command: apply(state, player, cmd, rng)
## -> {"ok", "reason", "events", "grant", "consume"}. The same code runs for a
## game alone (the World plays the events), for a co-op player predicting its
## own action, and for the authority that decides it: the rewards come from
## `rng`, which only the authority's counts.
##
## cmd: {"action": ..., "cell": Vector2i, ...}
##   "dig"   the ground's own DIG at cell: a buried item or one lying there
##           taken, a mountain cleared, a hole dug (a cracked fossil site
##           buries its loot), or inside a house a hole in its floor. When the
##           cell would take soil instead the events say so ("soil") and
##           nothing changes: the player chooses it (then "fill").
##   "fill"  cmd.choice (a DIG_TERRAIN name, or "HOLE") put into the hole at cell.
##   "surface" a hole dug at cell whatever it would take (DIG's own ground).
##   "take"  the item buried or lying at cell (cmd.item_action: the cell's
##           "ITEM:NAME:AMOUNT" when the caller has it).
##   "berry" the ripe berries of the tree at cell.
##   "plant" cmd.item planted at cell.
## player: {"area_id": the player's area (OVERWORLD, HOUSE...), "bag": items
##   (checked when given), "now": world seconds, "shared": true online, inside
##   a house "house_key" and "house_floor" (the cell's floor key and whether
##   it is floor)}.
## events, in the order the game shows them: ["sound", name],
##   ["message", text], ["dig_reward", items], ["item", name] (one each),
##   ["refresh"] (tiles changed), ["refresh_cell", cell], ["refresh_around",
##   cell], ["farms", cell] (the habitats beside it see new ground),
##   ["collected", cell] (an item's sprite goes), ["house_decoration", cell],
##   ["soil", cell], ["encounter", species, level, record, take it off the
##   route], ["agitated", cell] (alone: the tree clears after a while),
##   ["planted", cell, upper].
## grant and consume are what the authority adds to and takes from the bag; a
## game alone leaves the bag to the signals the events become (main.gd).

const TileRules = preload("res://scripts/rules/tile_rules.gd")
const FieldMoveData = preload("res://scripts/field_move_data.gd")
const DAY_SECONDS := (18000.0 + 5000.0) / 60.0

static func apply(state, player: Dictionary, cmd: Dictionary, rng: RandomNumberGenerator) -> Dictionary:
    var out := {"ok": false, "reason": "", "events": [], "grant": {}, "consume": {}}
    var cell: Vector2i = cmd.get("cell", Vector2i.ZERO)
    if state.tiles == null:
        out.reason = "no_area"
        return out
    match String(cmd.get("action", "")):
        "dig": _dig(state, player, cell, out, rng)
        "fill": out.ok = _fill(state, player, cell, String(cmd.get("choice", "")), out, rng)
        "surface": out.ok = _surface(state, cell, out, rng)
        "take": out.ok = take(state, cell, out, String(cmd.get("item_action", "")))
        "berry": _berry(state, player, cell, out)
        "plant": _plant(state, player, cell, String(cmd.get("item", "")), out)
        _: out.reason = "invalid_action"
    if not out.ok and out.reason.is_empty(): out.reason = "nothing_to_do"
    return out

## Every item in `items` granted, also kept in out.grant.
static func _reward(out: Dictionary, event: Array, items: Dictionary) -> void:
    out.events.append(event)
    for item in items: out.grant[item] = int(out.grant.get(item, 0)) + int(items[item])

static func _dig(state, player: Dictionary, cell: Vector2i, out: Dictionary, rng: RandomNumberGenerator) -> void:
    if String(player.get("area_id", "OVERWORLD")) == "HOUSE":
        if not _house_target(state, player, cell): return
        var key := String(player.get("house_key", ""))
        if bool(state.built_house_decorations.get(key, {}).get("dig_hole", false)):
            out.events.append(["soil", cell])
            out.ok = true
            return
        var previous: Dictionary = state.built_house_decorations.get(key, {})
        var old_choice := String(previous.get("dig_choice", "FOREST"))
        var material := String(FieldMoveData.dig_choice_info(old_choice).get("material", "GRASS"))
        state.put("built_house_decorations", key, {"name":"DIG GROUND", "dig_choice":old_choice, "dig_hole":true,
            "dig_base_name":String(previous.get("name", "FLOOR")) if String(previous.get("name", "")) != "DIG GROUND" else String(previous.get("dig_base_name", "")),
            "variant":int(previous.get("variant", 0))})
        out.events.append(["house_decoration", cell])
        out.events.append(["sound", "dig1"])
        _reward(out, ["dig_reward", {material:1}], {material:1})
        out.ok = true
        return
    if not state.in_bounds(cell): return
    if collect_buried(state, cell, out):
        out.ok = true
        return
    var tile: SourceTile = state.tile_at(cell)
    if tile != null and not tile.has_item.is_empty():
        # An item tile has priority while DIG is selected: it is taken where it lies.
        out.ok = take(state, cell, out)
        return
    if TileRules.is_mountain(tile) or not TileRules.accepts_soil(state, cell):
        out.ok = _surface(state, cell, out, rng)
        return
    out.events.append(["soil", cell])
    out.ok = true

## The hole DIG leaves (or the mountain it clears): its material, and a
## cracked site's loot buried for the next DIG.
static func _surface(state, cell: Vector2i, out: Dictionary, rng: RandomNumberGenerator) -> bool:
    var tile: SourceTile = state.tile_at(cell)
    if collect_buried(state, cell, out): return true
    if tile != null and tile.name_upper.begins_with("hole1") and not TileRules.is_mountain(tile):
        out.events.append(["message", "There's already a hole here."])
        out.reason = "already_a_hole"
        return false
    if state.structures.has(cell) or state.landmarks.has(cell):
        out.events.append(["message", "DIG can't break that tile."])
        out.reason = "occupied"
        return false
    if tile == null or not TileRules.dig_surface_ok(tile):
        out.events.append(["message", "DIG can't break that tile."])
        out.reason = "not_ground"
        return false
    if not TileRules.fossil_site(tile) and TileRules.exact_resource_anchor(state, cell).x > -2147483648:
        out.events.append(["message", "DIG can't break that tile."])
        out.reason = "resource"
        return false
    var route_name: String = "" if tile.route_belongs_to == null else tile.route_belongs_to.name
    var material := FieldMoveData.dig_material(tile.name, tile.name_upper, tile.biome, route_name)
    var loot := FieldMoveData.cracked_loot(tile.name_upper)
    if not loot.is_empty():
        tile = state.edit(cell)
        tile.has_item = String(loot[rng.randi_range(0, loot.size() - 1)])
        tile.has_item_amount = 1
        state.put("interactables", cell, "ITEM:%s:1" % tile.has_item)
    if TileRules.is_mountain(tile):
        TileRules.clear_dug_mountain(state, cell)
    else:
        TileRules.leave_hole(state, cell)
    out.events.append(["refresh"])
    out.events.append(["sound", "dig1"])
    _reward(out, ["dig_reward", {material:1}], {material:1})
    out.events.append(["farms", cell])
    return true

## Soil (or a hole) put into the hole at `cell`, paid with its material.
static func _fill(state, player: Dictionary, cell: Vector2i, choice: String, out: Dictionary, rng: RandomNumberGenerator) -> bool:
    var info := FieldMoveData.dig_choice_info(choice)
    var material := String(info.get("material", ""))
    if String(player.get("area_id", "OVERWORLD")) == "HOUSE":
        var key := String(player.get("house_key", ""))
        if not _house_target(state, player, cell) or not bool(state.built_house_decorations.get(key, {}).get("dig_hole", false)): return false
        if not FieldMoveData.DIG_TERRAIN.has(choice): return false
        if not _pay(player, out, material): return false
        state.put("built_house_decorations", key, {"name":"DIG GROUND", "dig_choice":choice, "dig_hole":false})
        out.events.append(["house_decoration", cell])
        out.events.append(["sound", "dig1"])
        return true
    if collect_buried(state, cell, out): return false
    if state.structures.has(cell) or state.landmarks.has(cell):
        out.events.append(["message", "DIG can't change that tile."])
        out.reason = "occupied"
        return false
    if choice == "HOLE":
        _surface(state, cell, out, rng)
        return true
    if not TileRules.accepts_soil(state, cell):
        out.events.append(["message", "DIG can't change that tile."])
        out.reason = "not_a_hole"
        return false
    if info.is_empty():
        out.reason = "invalid_soil"
        return false
    var tile: SourceTile = state.tile_at(cell)
    if tile == null or not (TileRules.dig_surface_ok(tile) or TileRules.accepts_soil(state, cell)):
        out.events.append(["message", "DIG can't change that tile."])
        out.reason = "not_ground"
        return false
    if not TileRules.fossil_site(tile) and not tile.name_upper.begins_with("hole1"):
        if TileRules.exact_resource_anchor(state, cell).x > -2147483648:
            out.events.append(["message", "DIG can't change that tile."])
            out.reason = "resource"
            return false
    if not _pay(player, out, material): return false
    tile = state.edit(cell)
    FieldMoveData.apply_dig_terrain(tile, choice)
    if choice == "CLIFF": FieldMoveData.adjust_dig_cliff(tile, state.tiles.tiles)
    TileRules.save_dig_tile(state, cell)
    state.drop("terrain_changes", TileRules.cell_key(cell))
    TileRules.connect_holes(state, cell)
    TileRules.recoastify(state, [cell])
    out.events.append(["refresh"])
    out.events.append(["farms", cell])
    out.events.append(["sound", "dig1"])
    out.events.append(["message", "DIG changed the ground to %s." % choice])
    return true

## The soil's material taken from the bag (checked when the bag is known).
static func _pay(player: Dictionary, out: Dictionary, material: String) -> bool:
    if material.is_empty(): return true
    var bag = player.get("bag")
    if bag is Dictionary and int(bag.get(material, 0)) < 1:
        out.reason = "not_enough_materials"
        return false
    out.consume[material] = int(out.consume.get(material, 0)) + 1
    return true

static func _house_target(state, player: Dictionary, cell: Vector2i) -> bool:
    return bool(player.get("house_floor", false)) and not state.structures.has(cell) and not state.interactables.has(cell) \
        and not state.habitat.records.has(cell) and not state.eggs.records.has(cell) and not state.blocked.has(cell)

## The item a DIG left buried in this cell's hole, if any.
static func collect_buried(state, cell: Vector2i, out: Dictionary) -> bool:
    var mutation: Dictionary = state.source_interior_mutations.get(TileRules.cell_key(cell), {})
    var item := String(mutation.get("dig_item", ""))
    if item.is_empty(): return false
    var tile: SourceTile = state.edit(cell)
    if tile == null: return false
    var amount := maxi(1, int(mutation.get("dig_item_amount", 1)))
    tile.has_item = ""
    tile.has_item_amount = 0
    state.drop("interactables", cell)
    TileRules.save_dig_tile(state, cell)
    out.events.append(["refresh"])
    _reward(out, ["dig_reward", {item:amount}], {item:amount})
    return true

## The item lying on `cell` (or buried in its hole), taken.
static func take(state, cell: Vector2i, out: Dictionary, item_action: String = "") -> bool:
    if collect_buried(state, cell, out): return true
    var tile: SourceTile = state.tile_at(cell)
    var action := item_action if item_action.begins_with("ITEM:") else String(state.interactables.get(cell, ""))
    if not action.begins_with("ITEM:"):
        if tile == null or tile.has_item.is_empty():
            out.reason = "no_item"
            return false
        action = "ITEM:%s:%d" % [tile.has_item, maxi(1, tile.has_item_amount)]
    var parts := action.split(":")
    if parts.size() != 3:
        out.reason = "no_item"
        return false
    var item_name := String(parts[1]).to_upper()
    var amount := maxi(1, int(parts[2]))
    for _index in range(amount): out.events.append(["item", item_name])
    out.grant[item_name] = int(out.grant.get(item_name, 0)) + amount
    if item_name != "POKE BALL": out.events.append(["message", "You found %s x%d!" % [item_name, amount]])
    state.drop("interactables", cell)
    state.put("source_interior_mutations", TileRules.cell_key(cell), {"kind": "COLLECTED"})
    out.events.append(["collected", cell])
    if state.in_bounds(cell) and tile != null:
        tile = state.edit(cell)
        tile.has_item = ""
        tile.has_item_amount = 0
        tile.set_names(tile.name, "")
        out.events.append(["refresh_cell", cell])
    return true

## A ripe berry tree picked: its berry, or the Pokemon hiding in it.
static func _berry(state, player: Dictionary, cell: Vector2i, out: Dictionary) -> void:
    var berry := TileRules.berry_name(state, cell)
    if berry.is_empty():
        out.events.append(["message", "There are no ripe BERRIES here."])
        out.reason = "no_berries"
        return
    var tile: SourceTile = state.tile_at(cell)
    if tile == null: return
    var key := TileRules.cell_key(cell)
    if tile.route_belongs_to != null and not tile.route_belongs_to.stored_pokemon.is_empty():
        # The route's hidden Pokemon: read here, taken off the route by whoever
        # plays the encounter (["encounter", ..., true]).
        var record: Dictionary = (tile.route_belongs_to.stored_pokemon[0] as Dictionary).duplicate(true)
        var clear_at := float(player.get("now", 0.0)) + 400.0 / 60.0
        if bool(player.get("shared", false)):
            # Online every player sees the tree shake and then stand bare
            # (world.gd _apply_source_interior_mutation); alone a timer does it.
            state.put("source_interior_mutations", key, {"kind":"BERRY_AGITATED", "base":tile.name, "clear_at":clear_at})
            state.drop("source_plant_farms", key)
        out.events.append(["sound", "ledge2"])
        out.events.append(["message", "The tree became agitated and attacked!"])
        out.events.append(["encounter", String(record.get("name", record.get("species", "sudowoodo"))).to_lower(), int(record.get("level", 1)), record, true, cell])
        if not bool(player.get("shared", false)): out.events.append(["agitated", cell])
        out.ok = true
        return
    out.events.append(["item", berry])
    out.grant[berry] = int(out.grant.get(berry, 0)) + 1
    out.events.append(["sound", "Berry_Get"])
    tile = state.edit(cell)
    tile.set_names(tile.name, tile.name_upper.replace("_full", "_empty"))
    store_plant(state, cell, float(player.get("now", 0.0)))
    state.put("source_interior_mutations", key, {"kind":"BERRY_EMPTY", "upper":tile.name_upper})
    out.events.append(["refresh_cell", cell])
    out.events.append(["message", "You picked a %s." % berry])
    out.ok = true

static func plant_day(now: float) -> int:
    # Growth happens after dawn's 320-frame fade, not at midnight.
    return maxi(0, floori((now - 320.0 / 60.0) / DAY_SECONDS))

static func store_plant(state, cell: Vector2i, now: float, rewards: Dictionary = {}) -> void:
    var tile: SourceTile = state.tile_at(cell)
    state.put("source_plant_farms", TileRules.cell_key(cell),
        {"base":tile.name, "upper":tile.name_upper, "day":plant_day(now), "rewards":rewards.duplicate(true)})

## `item` planted at `cell` (PlantTree): a sapling, a berry sprout, grass, or
## manure on a planted tree. Paid with one of the item.
static func _plant(state, player: Dictionary, cell: Vector2i, item: String, out: Dictionary) -> void:
    if String(player.get("area_id", "OVERWORLD")) != "OVERWORLD":
        out.reason = "not_outdoors"
        return
    var tile: SourceTile = state.tile_at(cell)
    if not (item in ["BERRY SEED","MIRACLE SEED","MANURE"] or item.ends_with(" APRICORN")):
        out.reason = "invalid_plant"
        return
    if not plants_valid(tile, item):
        out.events.append(["message", "That plant cannot grow here."])
        out.reason = "cannot_grow"
        return
    if not _pay(player, out, item): return
    tile = state.edit(cell)
    var upper := "tree_planted2"
    if item == "MANURE":
        upper = tile.name_upper + "_fertilized"
        tile.set_names("mountain1", upper)
    else:
        upper = "berry_planted" if item == "BERRY SEED" else "grass_planted" if item == "MIRACLE SEED" else "tree_planted2"
        tile.set_names(tile.name, upper)
        # A saved DIG hole is replaced too, so it cannot return after the
        # crop is harvested and the world reloaded; neighbouring holes rejoin.
        var mutation: Dictionary = state.source_interior_mutations.get(TileRules.cell_key(cell), {})
        if String(mutation.get("upper", "")).begins_with("hole1"):
            TileRules.save_dig_tile(state, cell)
        TileRules.connect_holes(state, cell)
    store_plant(state, cell, float(player.get("now", 0.0)))
    out.events.append(["sound", "seed1"])
    out.events.append(["refresh_around", cell])
    if item not in ["MANURE", "MIRACLE SEED"]: out.events.append(["planted", cell, upper])
    out.ok = true

static func plants_valid(tile: SourceTile, item: String) -> bool:
    if tile == null: return false
    var base := tile.name
    var upper := tile.name_upper
    if not tile.has_item.is_empty(): return false
    # DIG stores a dry hole in the upper layer; its underlying soil still
    # determines the crop. Flooded holes have water/lava bases, not dry soil.
    var dry_hole := upper.begins_with("hole1") and "water" not in base and "lava" not in base
    if dry_hole:
        upper = ""
    if item == "MANURE":
        return "fertilized" not in upper and ("tree_planted" in upper or "bush2_color" in upper)
    if item.ends_with(" APRICORN"):
        return (base=="green1" or "flower" in base or "sand" in base or "snow" in base or "desert" in base) and "tree" not in upper and (not tile.is_solid or dry_hole)
    if not upper.is_empty(): return false
    var soil := base=="green1" or base in ["green9","green10","green11","green12"] or "snow" in base or "sand" in base or "desert" in base or "green_savanna" in base or "flower" in base
    return soil or (item=="BERRY SEED" and ("volcano" in base or "savanna" in base or "graveyard" in base))
