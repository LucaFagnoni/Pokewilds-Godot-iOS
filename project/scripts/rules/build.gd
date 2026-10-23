extends RefCounted
## BUILD as one command: apply(state, player, cmd, rng) -> {"ok", "reason",
## "events", "grant", "consume"} (field_dig.gd has the shape). A piece is
## placed on an area's data (AreaState: its structures, blocked cells,
## overlays and tiles) with every check the game makes, as world_buildings.gd
## placed it; the World draws the events. A host runs the same apply on its
## own copy of the area and decides. Also what remove.gd and paint.gd share:
## how pieces join up (connect_around), a house's inside worked out from the
## area's data alone (house) and the house helpers.
##
## cmd: {"recipe": a build recipe, "cell": Vector2i (as the player aims it: a
##   window or clock already on the wall it faces)}.
## player: {"area_id", "bag" (checked when given), "house": the inside of the
##   house the player is in (the World's own, world_buildings.gd
##   house_context; or worked out here from "house_door" and the hint
##   "house_origin", context()): "door", "origin", "size", "footprint",
##   "capacity", "floors", "interior", "walls", "exits"}.
## events, besides field_dig's ("sound", "message", "house_decoration"):
##   ["structure", cell] (a piece to draw, or to draw again, from its data),
##   ["unbuilt", cell, piece] (a piece gone: its nodes go with it),
##   ["restyle", cell] (the pieces joined around cell take their look again),
##   ["house_floor", cell], ["decoration_gone", cell], ["painted", cell,
##   picture], ["refresh_streams"] (tiles edited), ["refund", items] (what a
##   removed piece gives back: a game alone grants these as they come).
## consume: the recipe's cost (the authority takes it from the bag).

const CraftingData = preload("res://scripts/crafting_data.gd")
const SourceHouseStyles = preload("res://scripts/source_house_styles.gd")
const SourceWorldData = preload("res://scripts/source_world_data.gd")
const TileRules = preload("res://scripts/rules/tile_rules.gd")
const NO_CELL := Vector2i(-2147483648, -2147483648)
const FAR := Vector2i(2147483647, 2147483647)
const FLOOR_STRIDE := 64
const HOUSE_PIECES := ["WALL", "ROOF", "DOOR", "WINDOW", "CHIMNEY"]
const OUTSIDE_ONLY := ["FENCE", "WALL", "ROOF", "DOOR"]
## Fields of a structure that are not part of a structure record (AreaState.STRUCTURE_RUNTIME, "x", "y").
const NOT_RECORDED := ["sprite", "collision", "solid", "bridged_water", "x", "y"]

static func apply(state, player: Dictionary, cmd: Dictionary, _rng: RandomNumberGenerator) -> Dictionary:
    var out := {"ok": false, "reason": "", "events": [], "grant": {}, "consume": {}}
    var build_name := String(cmd.get("recipe", ""))
    var cell: Vector2i = cmd.get("cell", Vector2i.ZERO)
    var recipe := CraftingData.build_recipe(build_name)
    if recipe.is_empty():
        out.reason = "invalid_recipe"
        return out
    if state.tiles == null:
        out.reason = "no_area"
        return out
    if not context(state, player):
        out.reason = "no_house"
        return out
    var cost: Dictionary = recipe.get("cost", {})
    if player.has("bag") and not CraftingData.can_afford(player.bag, cost):
        out.events.append(["message", "Not enough materials for %s." % build_name])
        out.reason = "not_enough_materials"
        return out
    if not place(state, player, build_name, cell, false, {}, false, out):
        if out.reason.is_empty(): out.reason = "cannot_place"
        return out
    out.consume = cost.duplicate(true)
    out.reason = ""
    out.ok = true
    return out

## player.house worked out from player.house_door when it has none (a host);
## false when the player is in a house but the door names none.
static func context(state, player: Dictionary) -> bool:
    if player.has("house") or String(player.get("area_id", "OVERWORLD")) != "HOUSE": return true
    var door = player.get("house_door")
    if not door is Vector2i: return false
    player["house"] = house(state, door, int(player.get("house_origin", -1)))
    return not player.house.is_empty()

static func _say(out: Dictionary, text: String) -> void:
    out.events.append(["message", text])

# --- Placing ------------------------------------------------------------------

## Whether `build_name` may go at `cell` (world_buildings.gd can_place_structure).
## `ignore`: a piece being laid again from a save or a record.
static func can_place(state, player: Dictionary, build_name: String, cell: Vector2i, ignore: bool, out: Dictionary) -> bool:
    var area_id := String(player.get("area_id", "OVERWORLD"))
    var ctx: Dictionary = player.get("house", {})
    var recipe := CraftingData.build_recipe(build_name)
    if recipe.is_empty():
        out.reason = "invalid_recipe"
        return false
    # The pieces of a house's outside, and fences, are only kept on the open
    # map. One built inside a house or a cave was lost on the next load, and
    # online it ended the session for the other players, who could not place
    # it. They are refused indoors; INTERIOR WALL is the wall for a room.
    if not ignore and area_id != "OVERWORLD" and piece_name(build_name) in OUTSIDE_ONLY:
        _say(out, "%s can only be built outside." % build_name)
        out.reason = "outside_only"
        return false
    out.reason = "occupied"
    if not ignore:
        if String(state.structures.get(cell + Vector2i.DOWN, {}).get("name", "")) == "BED": return false
        if couch_anchor_at(state, cell) != FAR: return false
        if piece_name(build_name) == "COUCH":
            for occupied in couch_footprint(build_name, cell):
                if not is_floor_cell(state, player, occupied) or state.structures.has(occupied) or state.interactables.has(occupied) \
                        or _pokemon_at(state, occupied) or state.blocked.has(occupied): return false
    if build_name == "BED" and not ignore:
        var head_cell := cell + Vector2i.UP
        if not is_floor_cell(state, player, head_cell) or state.structures.has(head_cell) or state.interactables.has(head_cell) or _pokemon_at(state, head_cell):
            return false
    out.reason = "cannot_place"
    if is_window(build_name) and area_id == "OVERWORLD":
        var wall: Dictionary = state.structures.get(cell, {})
        return String(wall.get("name", "")) == "WALL" and not bool(wall.get("window", false))
    # A torch goes on the ground or, as in the source game, on a wall.
    if build_name == "TORCH" and not ignore and torch_wall_at(state, cell):
        var torch_wall: Dictionary = state.structures[cell]
        return not bool(torch_wall.get("torch", false)) and not bool(torch_wall.get("window", false))
    if is_house_decoration(build_name) and not (build_name == "CLOCK" and ignore):
        if area_id != "HOUSE": return false
        var on_wall := is_window(build_name) or build_name == "CLOCK"
        if on_wall and not ctx.get("walls", {}).has(cell): return false
        if not on_wall and not (is_floor_cell(state, player, cell) or floor_can_expand(state, player, cell)): return false
        return String(state.built_house_decorations.get(paint_key(ctx, cell), {}).get("name", "")) != build_name
    if build_name in ["WINDOW", "CHIMNEY"] and area_id == "OVERWORLD" and not ignore:
        var shell: Dictionary = state.structures.get(cell, {})
        var required := "WALL" if build_name == "WINDOW" else "ROOF"
        return String(shell.get("name", "")) == required and not bool(shell.get(build_name.to_lower(), false))
    if not ignore and String(state.structures.get(cell + Vector2i.DOWN, {}).get("name", "")) == "BED":
        return false
    if build_name == "FLOOR" and area_id == "HOUSE":
        return floor_can_expand(state, player, cell)
    var in_built_house := is_floor_cell(state, player, cell)
    if build_name == "STAIRS" and area_id == "HOUSE" and not ignore:
        var stair_floor := floor_index_for_cell(ctx, cell)
        if stair_floor < 0 or stair_floor >= int(ctx.get("capacity", 1)) - 1:
            _say(out, "This house needs to be taller.")
            return false
        var upper_cell := global_cell(ctx, stair_floor + 1, cell - floor_origin(ctx, stair_floor))
        if state.structures.has(upper_cell):
            _say(out, "The floor above is blocked.")
            return false
    # Saved indoor structures live in the generated house coordinate space,
    # outside overworld bounds. Permit only an indoor recipe on restore there.
    var restoring_indoor: bool = ignore and (bool(recipe.get("indoors", false)) or build_name in ["TORCH", "STORAGE BOX", "PRIVATE CHEST", "SIGN", "STATUE", "PLANT", "GRAVE", "FLOWERS", "CAMPFIRE"]) \
        and not state.in_bounds(cell)
    if not state.in_bounds(cell) and not in_built_house and not restoring_indoor:
        out.reason = "out_of_bounds"
        return false
    if state.structures.has(cell) or state.landmarks.has(cell) or _pokemon_at(state, cell) or state.interactables.has(cell) \
            or (state.wild != null and state.wild.id_at(cell) >= 0):
        out.reason = "occupied"
        return false
    if TileRules.is_tall_grass(state, cell) and not (build_name == "BRIDGE" and bridge_surface_at(state, cell)):
        out.reason = "tall_grass"
        return false
    if bool(recipe.get("indoors", false)) and not ignore and not is_cell_indoors(state, area_id, cell):
        _say(out, "That must be built indoors.")
        out.reason = "not_indoors"
        return false
    # Every recorded built-house interior cell is authored floor. It is valid
    # for indoor furniture and linked stairs even though it is off the overworld.
    if in_built_house or restoring_indoor: return true
    if build_name == "BRIDGE": return bridge_surface_at(state, cell)
    if terrain_kind_at(state, cell) == 0:
        out.reason = "water"
        return false
    out.reason = "blocked"
    return not state.blocked.has(cell)

## A Pokemon left in a habitat, or an egg, on `cell`.
static func _pokemon_at(state, cell: Vector2i) -> bool:
    return (state.habitat != null and state.habitat.records.has(cell)) or (state.eggs != null and state.eggs.records.has(cell))

## `build_name` put at `cell`, its data only (world_buildings.gd place_structure
## without the drawing): false when it may not go there. `restoring` lays a
## saved piece again (`restored_state` its record); `committed`: the
## authority has placed it already, so it is not checked.
static func place(state, player: Dictionary, build_name: String, cell: Vector2i, restoring: bool, restored_state: Dictionary, committed: bool, out: Dictionary) -> bool:
    var area_id := String(player.get("area_id", "OVERWORLD"))
    var ctx: Dictionary = player.get("house", {})
    # Persisted exterior pieces are authoritative. Reconstructed terrain,
    # regrowth and actors must not silently delete walls/roofs during loading.
    if restoring and piece_name(build_name) in OUTSIDE_ONLY:
        if not state.in_bounds(cell) or state.structures.has(cell): return false
    elif not committed and not can_place(state, player, build_name, cell, restoring, out):
        return false
    if is_window(build_name) and area_id == "OVERWORLD" and not restoring:
        var wall := _edit(state, cell)
        wall["window"] = true
        wall["window_recipe"] = build_name
        wall["window_variant"] = 0
        out.events.append(["structure", cell])
        return true
    if build_name == "TORCH" and not restoring and torch_wall_at(state, cell):
        _edit(state, cell)["torch"] = true
        out.events.append(["structure", cell])
        return true
    if is_house_decoration(build_name) and not (build_name == "CLOCK" and restoring):
        if build_name.begins_with("CARPET ") and not ctx.get("interior", {}).has(cell):
            var floor_index := floor_index_for_cell(ctx, cell)
            if not add_floor_cell(state, ctx, floor_index, cell - floor_origin(ctx, floor_index), true, out): return false
        state.put("built_house_decorations", paint_key(ctx, cell), {"name":build_name, "variant":0})
        out.events.append(["house_decoration", cell])
        if build_name.begins_with("CARPET "):
            for bed_cell in [cell, cell + Vector2i.DOWN]:
                if String(state.structures.get(bed_cell, {}).get("name", "")) != "BED": continue
                _edit(state, bed_cell)["bed_carpet"] = int(build_name.get_slice(" ", 1))
                out.events.append(["structure", bed_cell])
        return true
    if build_name in ["WINDOW", "CHIMNEY"] and area_id == "OVERWORLD" and not restoring:
        _edit(state, cell)[build_name.to_lower()] = true
        out.events.append(["structure", cell])
        return true
    if build_name == "FLOOR" and area_id == "HOUSE" and not restoring:
        if not floor_can_expand(state, player, cell):
            _say(out, "FLOOR needs an empty space within this house.")
            return false
        var floor_index := floor_index_for_cell(ctx, cell)
        return add_floor_cell(state, ctx, floor_index, cell - floor_origin(ctx, floor_index), true, out)

    var recipe := CraftingData.build_recipe(build_name)
    var requested_name := build_name
    var house_style := String(restored_state.get("house_style", house_style_for(requested_name)))
    var structure_name := String(restored_state.get("name", piece_name(requested_name)))
    if restoring and restored_state.has("recipe_name"):
        requested_name = String(restored_state.get("recipe_name", requested_name))
        house_style = String(restored_state.get("house_style", house_style_for(requested_name)))
        structure_name = String(restored_state.get("name", piece_name(requested_name)))
    var solid := bool(recipe.get("solid", false))
    var bridged_water := structure_name == "BRIDGE" and bridge_surface_at(state, cell)
    if bridged_water: state.drop("blocked", cell)
    elif solid: state.put("blocked", cell, true)
    var piece := restored_state.duplicate(true)
    for runtime_key in NOT_RECORDED: piece.erase(runtime_key)
    piece.merge({
        "name": structure_name,
        "recipe_name": requested_name,
        "house_style": house_style,
        "solid": solid,
        "bridged_water": bridged_water,
        "open": bool(piece.get("open", false)),
        "variant": int(piece.get("variant", 0)),
        "text": String(piece.get("text", "")),
        "last_harvest_day": int(piece.get("last_harvest_day", -1))
    }, true)
    if structure_name == "STAIRS" and area_id == "HOUSE" and not restoring:
        var stair_metadata := stair_metadata(ctx, cell)
        for key in stair_metadata: piece[key] = stair_metadata[key]
        piece["generated_stair_pair"] = false
    state.put("structures", cell, piece)
    if structure_name == "COUCH":
        for occupied in couch_footprint(requested_name, cell): state.put("blocked", occupied, true)
    if structure_name == "INTERIOR WALL" and is_house_wall_cell(ctx, cell) and ctx.has("walls"):
        ctx.walls[cell] = true
    out.events.append(["structure", cell])
    if structure_name == "STAIRS" and area_id == "HOUSE" and not restoring:
        create_stair_pair(state, ctx, cell, out)
    if structure_name == "DOOR":
        set_solid(state, cell, not bool(piece.get("open", false)))
    connect_around(state, player, cell, out)
    return true

## The structure at `cell` to change in place: a copy put in its stead while
## a prediction records (so a rollback puts the one before back), else the
## piece itself, marked changed.
static func _edit(state, cell: Vector2i) -> Dictionary:
    var piece: Dictionary = state.structures[cell]
    if state.recording():
        piece = piece.duplicate()
        state.put("structures", cell, piece)
    else:
        state.mark("structures", cell)
    return piece

## One field of the structure at `cell` set, unless it already holds that
## (marked changed, and kept for undo while a prediction records).
static func set_field(state, cell: Vector2i, key: String, value: Variant) -> void:
    var piece: Dictionary = state.structures[cell]
    if piece.has(key) and typeof(piece[key]) == typeof(value) and piece[key] == value: return
    _edit(state, cell)[key] = value

## Whether the piece at `cell` stops a walker (world_buildings.gd
## _set_structure_solid, its data): the cell blocked or not with it.
static func set_solid(state, cell: Vector2i, solid: bool) -> void:
    if not state.structures.has(cell): return
    var was := bool(state.structures[cell].get("solid", false))
    if solid and not was: state.put("blocked", cell, true)
    elif not solid and was: state.drop("blocked", cell)
    set_field(state, cell, "solid", solid)

## An area held without a World (area_sim.gd) takes a structure record: its
## runtime fields and the cells it blocks, as placing it would.
static func lay(state, cell: Vector2i, before: Variant, piece: Variant) -> void:
    if before is Dictionary:
        if bool(before.get("solid", false)): state.blocked.erase(cell)
        if String(before.get("name", "")) == "COUCH":
            for occupied in couch_footprint(String(before.get("recipe_name", "COUCH")), cell): state.blocked.erase(occupied)
    if not piece is Dictionary: return
    var recipe := CraftingData.build_recipe(String(piece.get("recipe_name", piece.get("name", ""))))
    var solid := bool(recipe.get("solid", false)) and not bool(piece.get("generated_stair_pair", false))
    if String(piece.get("name", "")) == "DOOR": solid = not bool(piece.get("gate", false)) and not bool(piece.get("open", false))
    piece["bridged_water"] = String(piece.get("name", "")) == "BRIDGE" and bridge_surface_at(state, cell)
    piece["solid"] = solid and not piece.bridged_water
    if piece.solid: state.blocked[cell] = true
    if String(piece.get("name", "")) == "COUCH":
        for occupied in couch_footprint(String(piece.get("recipe_name", "COUCH")), cell): state.blocked[occupied] = true

# --- How pieces join ----------------------------------------------------------

## The pieces around `center` joined up again (world_buildings.gd
## refresh_connected_structures_around, its data): a door between fences is a
## gate, walls, fences, roofs and tables record which way they connect.
static func connect_around(state, player: Dictionary, center: Vector2i, out: Dictionary) -> void:
    var ctx: Dictionary = player.get("house", {})
    var refresh_cells: Array[Vector2i] = [center, center + Vector2i.LEFT, center + Vector2i.RIGHT, center + Vector2i.UP, center + Vector2i.DOWN]
    # Source desert roof inner corners also depend on diagonal neighbors.
    for offset in [Vector2i(-1, -1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(1, 1)]:
        if connection_style(state, center + offset) == "DESERT" and connection_piece(state, center + offset) == "ROOF":
            refresh_cells.append(center + offset)
    for cell in refresh_cells:
        if not state.structures.has(cell): continue
        var data: Dictionary = state.structures[cell]
        var name := String(data.get("name", ""))
        if name == "DOOR":
            var gate := (is_fence_cell(state, cell + Vector2i.LEFT) and is_fence_cell(state, cell + Vector2i.RIGHT)) \
                or (is_fence_cell(state, cell + Vector2i.UP) and is_fence_cell(state, cell + Vector2i.DOWN))
            set_field(state, cell, "gate", gate)
            set_solid(state, cell, false if gate else not bool(data.get("open", false)))
            name = connection_piece(state, cell)
            if name == "DOOR": continue
        if name == "INTERIOR WALL":
            var wall_suffix := ""
            for direction in [Vector2i.UP, Vector2i.DOWN, Vector2i.RIGHT, Vector2i.LEFT]:
                var neighbor: Vector2i = cell + direction
                var joined := String(state.structures.get(neighbor, {}).get("name", "")) == "INTERIOR WALL"
                if direction == Vector2i.UP:
                    joined = joined or rear_wall_floor(ctx, neighbor) >= 0
                elif direction.x != 0 and is_floor_cell(state, player, cell):
                    joined = joined or not is_floor_cell(state, player, neighbor)
                if joined: wall_suffix += "N" if direction == Vector2i.UP else "S" if direction == Vector2i.DOWN else "E" if direction == Vector2i.RIGHT else "W"
            set_field(state, cell, "wall_connections", wall_suffix)
            continue
        if name not in ["FENCE", "WALL", "INTERIOR WALL", "ROOF", "TABLE"]: continue
        var sides := connected_sides(state, cell, name)
        var horizontal: bool = sides[2] or sides[3]
        var vertical: bool = sides[0] or sides[1]
        set_field(state, cell, "connections", (1 if horizontal else 0) | (2 if vertical else 0))
    out.events.append(["restyle", center])

## [north, south, east, west]: which neighbours the piece at `cell`, acting as
## `name`, joins (a house style joins its own style and doors only).
static func connected_sides(state, cell: Vector2i, name: String) -> Array:
    var connection_names: Array[String] = [name]
    if name in ["WALL", "INTERIOR WALL"]: connection_names = ["WALL", "INTERIOR WALL", "DOOR", "WINDOW"]
    elif name == "ROOF": connection_names = ["ROOF", "CHIMNEY"]
    elif name == "FENCE": connection_names = ["FENCE", "DOOR"]
    var sides := []
    var style := connection_style(state, cell)
    for direction in [Vector2i.UP, Vector2i.DOWN, Vector2i.RIGHT, Vector2i.LEFT]:
        var joined := connection_piece(state, cell + direction) in connection_names
        if joined and SourceHouseStyles.STYLES.has(style):
            var neighbor: Dictionary = state.structures.get(cell + direction, {})
            joined = String(neighbor.get("name", "")) == "DOOR" or String(neighbor.get("house_style", "")) == style
        sides.append(joined)
    return sides

static func connection_piece(state, cell: Vector2i) -> String:
    var data: Dictionary = state.structures.get(cell, {})
    var name := String(data.get("name", ""))
    if name != "DOOR" or bool(data.get("gate", false)): return name
    var left := String(state.structures.get(cell + Vector2i.LEFT, {}).get("name", ""))
    var right := String(state.structures.get(cell + Vector2i.RIGHT, {}).get("name", ""))
    var up := String(state.structures.get(cell + Vector2i.UP, {}).get("name", ""))
    var down := String(state.structures.get(cell + Vector2i.DOWN, {}).get("name", ""))
    # PkmnMap.adjustTile: roof-sandwiched doors become roof with a north rug.
    if left in ["ROOF", "DOOR"] and right in ["ROOF", "DOOR"] and (left == "ROOF" or right == "ROOF"):
        return "ROOF"
    if up in ["WALL", "ROOF", "DOOR"] and down in ["WALL", "ROOF", "DOOR"] and (up != "DOOR" or down != "DOOR"):
        return "ROOF" if left == "ROOF" or right == "ROOF" else "WALL"
    return name

static func connection_style(state, cell: Vector2i) -> String:
    var data: Dictionary = state.structures.get(cell, {})
    var style := String(data.get("house_style", "DEFAULT"))
    if String(data.get("name", "")) == "DOOR" and style == "DEFAULT":
        for direction in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
            var neighbor: Dictionary = state.structures.get(cell + direction, {})
            if String(neighbor.get("name", "")) in ["ROOF", "WALL"]:
                return String(neighbor.get("house_style", "DEFAULT"))
    return style

static func is_fence_cell(state, cell: Vector2i) -> bool:
    var structure: Dictionary = state.structures.get(cell, {})
    if String(structure.get("name", "")) == "FENCE" or bool(structure.get("gate", false)):
        return true
    if state.tiles != null:
        var tile: SourceTile = state.tile_at(cell)
        return tile != null and ("fence" in tile.name or "fence" in tile.name_upper)
    return false

# --- Recipes and ground -------------------------------------------------------

static func house_style_for(build_name: String) -> String:
    for style in SourceHouseStyles.STYLES:
        if build_name.begins_with(style + " "): return style
    if build_name.begins_with("SAVANNA "): return "SAVANNA"
    if build_name.begins_with("TUNDRA "): return "TUNDRA"
    return "DEFAULT"

static func piece_name(build_name: String) -> String:
    if build_name in ["COUCH 2", "COUCH 3", "COUCH 4", "COUCH 5", "PLANT 2", "VANITY 2"]:
        return build_name.get_slice(" ", 0)
    for style in SourceHouseStyles.STYLES:
        if build_name.begins_with(style + " "): return build_name.trim_prefix(style + " ")
    if build_name.begins_with("SAVANNA "): return build_name.trim_prefix("SAVANNA ")
    if build_name.begins_with("TUNDRA "): return build_name.trim_prefix("TUNDRA ")
    return build_name

static func is_window(build_name: String) -> bool:
    return build_name == "WINDOW" or build_name.begins_with("INDOOR WINDOW ")

static func is_house_decoration(build_name: String) -> bool:
    return build_name == "CLOCK" or build_name.begins_with("CARPET ") or is_window(build_name)

static func torch_wall_at(state, cell: Vector2i) -> bool:
    return String(state.structures.get(cell, {}).get("name", "")) in ["WALL", "INTERIOR WALL"]

static func couch_footprint(recipe: String, cell: Vector2i) -> Array[Vector2i]:
    if recipe in ["COUCH 3", "COUCH 5"]: return [cell]
    return [cell, cell + (Vector2i.RIGHT if recipe == "COUCH" else Vector2i.UP)]

static func couch_anchor_at(state, cell: Vector2i) -> Vector2i:
    for candidate in [cell, cell + Vector2i.DOWN, cell + Vector2i.LEFT]:
        var data: Dictionary = state.structures.get(candidate, {})
        if String(data.get("name", "")) == "COUCH" and cell in couch_footprint(String(data.get("recipe_name", "COUCH")), candidate):
            return candidate
    return FAR

static func bridge_surface_at(state, cell: Vector2i) -> bool:
    var tile: SourceTile = state.tile_at(cell)
    return tile != null and ("water" in tile.name or "_tidal" in tile.name or "lava" in tile.name) and not "bridge" in tile.name

## 0 water (or nothing), 1 sand, 2 other ground (world.gd terrain_kind_at).
static func terrain_kind_at(state, cell: Vector2i) -> int:
    if String(state.structures.get(cell, {}).get("name", "")) == "BRIDGE": return 2
    var tile: SourceTile = state.tile_at(cell)
    if tile == null or tile.is_water or SourceWorldData.is_water(tile.name): return 0
    if "sand" in tile.name or "desert" in tile.name or "beach" in tile.biome: return 1
    return 2

## Walls (or a door) within 12 cells every way round `cell` on the open map.
static func is_cell_indoors(state, area_id: String, cell: Vector2i) -> bool:
    if area_id != "OVERWORLD": return true
    for direction in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
        var boundary_found := false
        for step in range(1, 13):
            var test: Vector2i = cell + direction * step
            if not state.in_bounds(test): break
            if state.structures.has(test):
                if String(state.structures[test].get("name", "")) in ["WALL", "INTERIOR WALL", "DOOR"]: boundary_found = true
                break
        if not boundary_found: return false
    return true

# --- Houses -------------------------------------------------------------------

## A house from its door (world_buildings.gd built_house_state): the
## connected pieces of its outside; ready with a door, walls and a roof.
static func house_state(state, door_cell: Vector2i) -> Dictionary:
    # Source smart-building follows connected house pieces from the door. It
    # does not impose M73's invented minimum counts/height. A connected door
    # with a roof and structural body is a completed enterable house.
    var visited: Dictionary = {}
    var queue: Array[Vector2i] = [door_cell]
    var queue_index := 0
    var has_door := false
    var has_roof := false
    var has_body := false
    var wall_rows: Dictionary = {}
    var cells: Array[Vector2i] = []
    while queue_index < queue.size():
        var current: Vector2i = queue[queue_index]
        queue_index += 1
        if visited.has(current) or not state.structures.has(current): continue
        var name := String((state.structures[current] as Dictionary).get("name", ""))
        if name not in HOUSE_PIECES: continue
        visited[current] = true
        cells.append(current)
        has_door = has_door or name == "DOOR"
        has_roof = has_roof or name in ["ROOF", "CHIMNEY"]
        has_body = has_body or name in ["WALL", "WINDOW", "DOOR"]
        if name in ["WALL", "WINDOW"]: wall_rows[current.y] = true
        for direction in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
            if not visited.has(current + direction): queue.append(current + direction)
    if not has_door or not has_body:
        return {"ready":false, "message":"This house still needs connected walls and a door.", "cells":cells}
    if not has_roof:
        return {"ready":false, "message":"This house still needs a connected roof.", "cells":cells}
    var door_style := "DEFAULT"
    if state.structures.has(door_cell): door_style = String((state.structures[door_cell] as Dictionary).get("house_style", "DEFAULT"))
    # Source house height rule: every exterior wall row permits one interior
    # floor. A basic one-row house therefore has only its ground floor; stairs
    # require another wall row before the roof.
    return {"ready":true, "message":"", "cells":cells, "house_style":door_style, "floor_count":maxi(1, wall_rows.size())}

## The door a house is known by: the first of its doors with an origin record.
static func canonical_door(state, door: Vector2i, cells: Array) -> Vector2i:
    # Origin records retain creation order even when a door is cut/rebuilt.
    # Looking through structure order instead can rename the saved house.
    for raw_key in state.built_house_origins:
        var saved_door := TileRules.key_cell(String(raw_key))
        if saved_door in cells and String(state.structures.get(saved_door, {}).get("name", "")) == "DOOR": return saved_door
    for raw_cell in state.structures:
        var cell := Vector2i(raw_cell)
        if cell in cells and String(state.structures[cell].get("name", "")) == "DOOR": return cell
    return door

## The inside of the house whose door is `door`, from the area's data alone
## (world_interiors.gd prepare_built_house_interior, without drawing): where
## its floors lie (its origin, recorded for its doors when it has none:
## `origin_hint` when no other house has it, as the player's game chose), its
## floor cells, walls and exits. {} when it is no finished house.
static func house(state, door: Vector2i, origin_hint: int = -1) -> Dictionary:
    var shape := house_state(state, door)
    if not shape.ready: return {}
    var cells: Array = shape.cells
    var min_cell := Vector2i(2147483647, 2147483647)
    var max_cell := Vector2i(-2147483648, -2147483648)
    for raw_cell in cells:
        min_cell = Vector2i(mini(min_cell.x, raw_cell.x), mini(min_cell.y, raw_cell.y))
        max_cell = Vector2i(maxi(max_cell.x, raw_cell.x), maxi(max_cell.y, raw_cell.y))
    var size := (max_cell - min_cell + Vector2i.ONE).max(Vector2i.ONE)
    var footprint := {}
    for raw_cell in cells: footprint[Vector2i(raw_cell) - min_cell] = true
    var canonical := canonical_door(state, door, cells)
    var key := TileRules.cell_key(canonical)
    var origin_y: int
    if state.built_house_origins.has(key):
        origin_y = int(state.built_house_origins[key])
    else:
        var taken := {}
        var next_y := 5
        for existing in state.built_house_origins.values():
            taken[int(existing)] = true
            next_y = maxi(next_y, int(existing) + state.bounds.size.y + FLOOR_STRIDE)
        origin_y = origin_hint if origin_hint >= 5 and not taken.has(origin_hint) else next_y
    for raw_cell in cells:
        if String(state.structures.get(raw_cell, {}).get("name", "")) != "DOOR": continue
        var door_key := TileRules.cell_key(raw_cell)
        if not state.built_house_origins.has(door_key) or int(state.built_house_origins[door_key]) != origin_y:
            state.put("built_house_origins", door_key, origin_y)
    var origin := Vector2i(state.bounds.size.x + 9, origin_y)
    var ctx := {"door": canonical, "origin": origin, "size": size, "footprint": footprint,
        "capacity": maxi(1, int(shape.get("floor_count", 1))), "floors": {}, "interior": {}, "walls": {}, "exits": {}}
    for floor_index in ctx.capacity: ctx.floors[floor_index] = origin + Vector2i(floor_index * FLOOR_STRIDE, 0)
    state.rooms_seen[origin_y] = [min_cell, size]
    for local in footprint: ctx.interior[origin + Vector2i(local)] = true
    # Every door of the house is a way out on the room's nearest edge.
    var exits: Array[Vector2i] = []
    for raw_cell in cells:
        var piece: Dictionary = state.structures.get(raw_cell, {})
        if String(piece.get("name", "")) == "DOOR" and not bool(piece.get("gate", false)): exits.append(Vector2i(raw_cell) - min_cell)
    if exits.is_empty(): exits.append((door - min_cell).clamp(Vector2i.ZERO, size - Vector2i.ONE))
    for local_exit in exits:
        var door_cell := origin + Vector2i(local_exit.x, size.y)
        if local_exit.y == 0: door_cell = origin + Vector2i(local_exit.x, -1)
        elif local_exit.y == size.y - 1: pass
        elif local_exit.x == 0: door_cell = origin + Vector2i(-1, local_exit.y)
        elif local_exit.x == size.x - 1: door_cell = origin + Vector2i(size.x, local_exit.y)
        ctx.interior[door_cell] = true
        ctx.exits[door_cell] = true
    for xx in size.x:
        if not ctx.exits.has(origin + Vector2i(xx, -1)): ctx.walls[origin + Vector2i(xx, -1)] = true
    for floor_index in range(1, ctx.capacity):
        for local in footprint:
            if state.built_house_floor_tiles.has(floor_tile_key(canonical, floor_index, local)):
                ctx.interior[floor_origin(ctx, floor_index) + Vector2i(local)] = true
    # Stairs built before their landing above was laid get it now, as on entering.
    for raw_cell in state.structures.keys():
        var stair: Dictionary = state.structures.get(raw_cell, {})
        if String(stair.get("name", "")) == "STAIRS" and not bool(stair.get("generated_stair_pair", false)) and belongs_to_house(ctx, stair):
            create_stair_pair(state, ctx, raw_cell, {"events": []})
    for raw_cell in state.structures:
        if String(state.structures[raw_cell].get("name", "")) == "INTERIOR WALL" and is_house_wall_cell(ctx, raw_cell): ctx.walls[raw_cell] = true
    return ctx

static func floor_tile_key(door: Vector2i, floor_index: int, local: Vector2i) -> String:
    return "%d,%d|%d|%d,%d" % [door.x, door.y, floor_index, local.x, local.y]

static func floor_origin(ctx: Dictionary, floor_index: int) -> Vector2i:
    var floors: Dictionary = ctx.get("floors", {})
    if floors.has(floor_index): return Vector2i(floors[floor_index])
    return Vector2i(ctx.get("origin", Vector2i.ZERO)) + Vector2i(maxi(0, floor_index) * FLOOR_STRIDE, 0)

static func floor_index_for_cell(ctx: Dictionary, cell: Vector2i) -> int:
    var size: Vector2i = ctx.get("size", Vector2i.ZERO)
    if size.x <= 0 or size.y <= 0: return -1
    var floors: Dictionary = ctx.get("floors", {})
    for raw_index in floors.keys():
        if Rect2i(Vector2i(floors[raw_index]), size).has_point(cell): return int(raw_index)
    return -1

static func global_cell(ctx: Dictionary, floor_index: int, local_cell: Vector2i) -> Vector2i:
    return floor_origin(ctx, floor_index) + local_cell

## The floor whose room has `cell` in the row just above it (its rear wall), -1 for none.
static func rear_wall_floor(ctx: Dictionary, cell: Vector2i) -> int:
    var size: Vector2i = ctx.get("size", Vector2i.ZERO)
    for raw_index in ctx.get("floors", {}):
        var origin := floor_origin(ctx, int(raw_index))
        if cell.y == origin.y - 1 and cell.x >= origin.x and cell.x < origin.x + size.x: return int(raw_index)
    return -1

static func is_house_wall_cell(ctx: Dictionary, cell: Vector2i) -> bool:
    return rear_wall_floor(ctx, cell) >= 0 or floor_index_for_cell(ctx, cell) >= 0

static func is_floor_cell(state, player: Dictionary, cell: Vector2i) -> bool:
    var ctx: Dictionary = player.get("house", {})
    return String(player.get("area_id", "")) == "HOUSE" and ctx.get("interior", {}).has(cell) \
        and not state.interactables.has(cell) and not ctx.get("exits", {}).has(cell)

static func floor_can_expand(state, player: Dictionary, cell: Vector2i) -> bool:
    if String(player.get("area_id", "")) != "HOUSE": return false
    var ctx: Dictionary = player.get("house", {})
    var floor_index := floor_index_for_cell(ctx, cell)
    if floor_index <= 0 or floor_index >= int(ctx.get("capacity", 1)): return false
    var local_cell := cell - floor_origin(ctx, floor_index)
    var size: Vector2i = ctx.get("size", Vector2i.ZERO)
    if local_cell.x < 0 or local_cell.y < 0 or local_cell.x >= size.x or local_cell.y >= size.y: return false
    if ctx.get("interior", {}).has(cell) or state.structures.has(cell): return false
    return ctx.get("footprint", {}).has(local_cell)

## A floor tile laid in the house (kept in the records above the ground floor
## when `persist`); false when the cell is no part of the house.
static func add_floor_cell(state, ctx: Dictionary, floor_index: int, local_cell: Vector2i, persist: bool, out: Dictionary) -> bool:
    var size: Vector2i = ctx.get("size", Vector2i.ZERO)
    var footprint: Dictionary = ctx.get("footprint", {})
    if floor_index < 0 or floor_index >= int(ctx.get("capacity", 1)): return false
    if local_cell.x < 0 or local_cell.y < 0 or local_cell.x >= size.x or local_cell.y >= size.y: return false
    if (floor_index > 0 or not footprint.is_empty()) and not footprint.has(local_cell): return false
    if floor_index > 0 and persist:
        var key := floor_tile_key(ctx.get("door", NO_CELL), floor_index, local_cell)
        if not state.built_house_floor_tiles.has(key): state.put("built_house_floor_tiles", key, true)
    var cell := global_cell(ctx, floor_index, local_cell)
    if ctx.get("interior", {}).has(cell): return true
    if ctx.has("interior"): ctx.interior[cell] = true
    out.events.append(["house_floor", cell])
    return true

## The key a house wall's paint and decorations are kept under: its door,
## floor (above the ground) and cell in the room. "" outside a house.
static func paint_key(ctx: Dictionary, cell: Vector2i) -> String:
    var door: Vector2i = ctx.get("door", NO_CELL)
    if door.x <= -2147483648: return ""
    var floor_index := floor_index_for_cell(ctx, cell)
    if floor_index < 0: floor_index = rear_wall_floor(ctx, cell)
    var local_cell := cell - floor_origin(ctx, floor_index) if floor_index >= 0 else cell - Vector2i(ctx.get("origin", Vector2i.ZERO))
    if floor_index <= 0: return "%d,%d|%d,%d" % [door.x, door.y, local_cell.x, local_cell.y]
    return "%d,%d|F%d|%d,%d" % [door.x, door.y, floor_index, local_cell.x, local_cell.y]

## The window or clock hanging on this house wall, or "" when it is bare.
static func wall_decoration_at(state, player: Dictionary, cell: Vector2i) -> String:
    var ctx: Dictionary = player.get("house", {})
    if String(player.get("area_id", "")) != "HOUSE" or not ctx.get("walls", {}).has(cell): return ""
    var hung := String(state.built_house_decorations.get(paint_key(ctx, cell), {}).get("name", ""))
    return hung if hung == "CLOCK" or is_window(hung) else ""

static func stair_metadata(ctx: Dictionary, cell: Vector2i) -> Dictionary:
    var floor_index := floor_index_for_cell(ctx, cell)
    if floor_index < 0: return {}
    var local_cell := cell - floor_origin(ctx, floor_index)
    var door: Vector2i = ctx.get("door", NO_CELL)
    return {"house_door_x": door.x, "house_door_y": door.y, "house_floor": floor_index, "house_local_x": local_cell.x, "house_local_y": local_cell.y}

static func belongs_to_house(ctx: Dictionary, data: Dictionary) -> bool:
    var door: Vector2i = ctx.get("door", NO_CELL)
    return int(data.get("house_door_x", -2147483648)) == door.x and int(data.get("house_door_y", -2147483648)) == door.y

## The landing above a staircase: a patch of floor round it on the floor
## above and the stairs down there (not a record: worked out again).
static func create_stair_pair(state, ctx: Dictionary, primary_cell: Vector2i, out: Dictionary) -> void:
    if not state.structures.has(primary_cell): return
    var data: Dictionary = state.structures[primary_cell]
    if bool(data.get("generated_stair_pair", false)) or not belongs_to_house(ctx, data): return
    var floor_index := int(data.get("house_floor", -1))
    var upper_floor := floor_index + 1
    if floor_index < 0 or upper_floor >= int(ctx.get("capacity", 1)): return
    var local_cell := Vector2i(int(data.get("house_local_x", 0)), int(data.get("house_local_y", 0)))
    for yy in range(local_cell.y - 1, local_cell.y + 2):
        for xx in range(local_cell.x - 1, local_cell.x + 2):
            add_floor_cell(state, ctx, upper_floor, Vector2i(xx, yy), true, out)
    var upper_cell := global_cell(ctx, upper_floor, local_cell)
    if state.structures.has(upper_cell): return
    var door: Vector2i = ctx.get("door", NO_CELL)
    state.put("structures", upper_cell, {
        "name":"STAIRS", "recipe_name":"STAIRS", "solid":false, "bridged_water":false,
        "open":false, "variant":0, "text":"", "last_harvest_day":-1,
        "generated_stair_pair":true,
        "stair_primary_x":primary_cell.x,
        "stair_primary_y":primary_cell.y,
        "house_door_x":int(data.get("house_door_x", door.x)),
        "house_door_y":int(data.get("house_door_y", door.y)),
        "house_floor":upper_floor,
        "house_local_x":local_cell.x,
        "house_local_y":local_cell.y
    })
    out.events.append(["structure", upper_cell])
