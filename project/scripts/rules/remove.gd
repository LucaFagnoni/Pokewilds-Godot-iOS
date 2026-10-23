extends RefCounted
## A built piece cut or smashed away, or a window or clock taken off a house
## wall, as one command: apply(state, player, cmd, rng) -> {"ok", "reason",
## "events", "grant", "consume"} (build.gd has the events and the player).
## What the pieces cost comes back (grant; a game alone grants each "refund"
## event as it comes). The authority's `rng` decides what rises from a GRAVE.
##
## cmd: {"cell": Vector2i, "move": "CUT"|"SMASH", "decoration": true to take
##   the window or clock hung at cell}.

const Build = preload("res://scripts/rules/build.gd")
const CraftingData = preload("res://scripts/crafting_data.gd")
const TileRules = preload("res://scripts/rules/tile_rules.gd")
const GHOSTS := ["gastly", "misdreavus", "duskull", "shuppet"]

static func apply(state, player: Dictionary, cmd: Dictionary, rng: RandomNumberGenerator) -> Dictionary:
    var out := {"ok": false, "reason": "", "events": [], "grant": {}, "consume": {}}
    var cell: Vector2i = cmd.get("cell", Vector2i.ZERO)
    if not Build.context(state, player):
        out.reason = "no_house"
        return out
    if bool(cmd.get("decoration", false)):
        out.ok = remove_decoration(state, player, cell, true, out)
        if not out.ok: out.reason = "nothing_hung"
        return out
    var move := String(cmd.get("move", "CUT"))
    if not state.structures.has(cell):
        out.reason = "already_removed"
        return out
    var build_name := String(state.structures[cell].get("name", ""))
    if move not in ["CUT", "SMASH"] or (move == "CUT" and build_name in ["GRAVE", "STATUE"]) or (move == "SMASH" and build_name not in ["GRAVE", "STATUE"]):
        out.reason = "wrong_field_move"
        return out
    remove(state, player, cell, true, out)
    if build_name == "GRAVE" and rng.randi_range(0, 8) == 0:
        var spooky := String(GHOSTS[rng.randi_range(0, GHOSTS.size() - 1)])
        out.events.append(["message", "Something rose from the shattered GRAVE!"])
        out.events.append(["encounter", spooky, 22, {}, false])
    out.ok = true
    return out

## The piece at `cell` gone (world_buildings.gd remove_structure, its data),
## with what goes with it: the tile of a house's room behind a piece of its
## outside and whatever stands there, the stairs' landing above, the window
## of an inside wall. `refund`: each piece's cost given back.
static func remove(state, player: Dictionary, cell: Vector2i, refund: bool, out: Dictionary) -> void:
    if not state.structures.has(cell): return
    var area_id := String(player.get("area_id", "OVERWORLD"))
    var ctx: Dictionary = player.get("house", {})
    # As in the Java game, a piece cut out of the outside of a house takes its
    # tile of the room with it, and whatever was built on that tile.
    for inside_cell in interior_cells_behind(state, player, cell):
        if state.structures.has(inside_cell): remove(state, player, inside_cell, refund, out)
    if area_id == "HOUSE" and String(state.structures[cell].get("name", "")) == "INTERIOR WALL":
        var key := Build.paint_key(ctx, cell)
        var hung := String(state.built_house_decorations.get(key, {}).get("name", ""))
        # A wall on a floor tile takes its window or clock with it, and the
        # bare floor left behind is no longer somewhere to hang one.
        var on_floor := Build.floor_index_for_cell(ctx, cell) >= 0
        if Build.is_window(hung) or (on_floor and hung == "CLOCK"):
            state.drop("built_house_decorations", key)
            out.events.append(["decoration_gone", cell])
        if on_floor and ctx.has("walls"): ctx.walls.erase(cell)
    var data: Dictionary = state.structures[cell]
    var build_name := String(data.get("name", ""))
    if build_name == "STAIRS" and area_id == "HOUSE" and Build.belongs_to_house(ctx, data):
        var primary_cell: Vector2i = cell
        if bool(data.get("generated_stair_pair", false)):
            primary_cell = Vector2i(int(data.get("stair_primary_x", -2147483648)), int(data.get("stair_primary_y", -2147483648)))
            if not state.structures.has(primary_cell): primary_cell = cell
        # The landing above goes first; it is not a separately paid build.
        var pair_cells: Array[Vector2i] = []
        for raw_pair in state.structures.keys():
            var pair_data: Dictionary = state.structures[raw_pair]
            if bool(pair_data.get("generated_stair_pair", false)) and int(pair_data.get("stair_primary_x", -1)) == primary_cell.x \
                    and int(pair_data.get("stair_primary_y", -1)) == primary_cell.y:
                pair_cells.append(Vector2i(raw_pair))
        for pair_cell in pair_cells:
            var pair_data: Dictionary = state.structures[pair_cell]
            state.drop("structures", pair_cell)
            out.events.append(["unbuilt", pair_cell, pair_data])
        if cell != primary_cell and state.structures.has(primary_cell):
            cell = primary_cell
            data = state.structures[cell]
            build_name = "STAIRS"
    if build_name == "COUCH":
        for occupied in Build.couch_footprint(String(data.get("recipe_name", "COUCH")), cell):
            if occupied == cell or not state.structures.has(occupied): state.drop("blocked", occupied)
    if bool(data.get("solid", false)): state.drop("blocked", cell)
    state.drop("structures", cell)
    out.events.append(["unbuilt", cell, data])
    # A restored shell can cover regenerated grass. Cutting that shell must
    # leave its previously cleared building ground usable for a new doorway.
    if build_name in ["WALL", "ROOF", "DOOR"] and area_id == "OVERWORLD" and state.tiles != null:
        var underneath: SourceTile = state.tile_at(cell)
        if underneath != null and underneath.is_grass:
            var cleared := TileRules.cuttable_grass_replacement(state, underneath, cell)
            underneath = state.edit(cell)
            underneath.set_names(String(cleared.base), String(cleared.upper))
            state.put("source_interior_mutations", TileRules.cell_key(cell), {"kind":"TILE_NAMES", "base":underneath.name, "upper":underneath.name_upper})
            out.events.append(["refresh_streams"])
    Build.connect_around(state, player, cell, out)
    if refund:
        var cost: Dictionary = CraftingData.build_recipe(String(data.get("recipe_name", build_name))).get("cost", {})
        _refund(out, cost)

static func _refund(out: Dictionary, cost: Dictionary) -> void:
    out.events.append(["refund", cost.duplicate(true)])
    for item in cost: out.grant[item] = int(out.grant.get(item, 0)) + int(cost[item])

## CUT takes a window or clock off its wall and leaves the wall standing (the
## room's own rear wall is no built piece). False when nothing hangs there.
static func remove_decoration(state, player: Dictionary, cell: Vector2i, refund: bool, out: Dictionary) -> bool:
    var hung := Build.wall_decoration_at(state, player, cell)
    if hung.is_empty(): return false
    state.drop("built_house_decorations", Build.paint_key(player.get("house", {}), cell))
    out.events.append(["decoration_gone", cell])
    out.events.append(["sound", "cut1"])
    if refund: _refund(out, CraftingData.build_recipe(hung).get("cost", {}))
    return true

## The connected pieces of a house reached from `start`, as if the piece at
## `without` were already gone.
static func _house_pieces_from(state, start: Vector2i, without: Vector2i) -> Array[Vector2i]:
    var pieces: Array[Vector2i] = []
    var seen: Dictionary = {}
    var queue: Array[Vector2i] = [start]
    var index := 0
    while index < queue.size():
        var current: Vector2i = queue[index]
        index += 1
        if seen.has(current) or current == without or not state.structures.has(current): continue
        if String(state.structures[current].get("name", "")) not in Build.HOUSE_PIECES: continue
        seen[current] = true
        pieces.append(current)
        for direction in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]: queue.append(current + direction)
    return pieces

## What is built inside a house on the tile behind one piece of its outside,
## on every floor (world_buildings.gd house_interior_cells_behind). Cutting the
## piece cuts these with it, and nothing else. Empty for a piece that is not
## part of a house, and for a house nobody has been inside.
static func interior_cells_behind(state, player: Dictionary, cell: Vector2i) -> Array[Vector2i]:
    var result: Array[Vector2i] = []
    if String(player.get("area_id", "OVERWORLD")) != "OVERWORLD": return result
    var house: Array[Vector2i] = _house_pieces_from(state, cell, Build.FAR)
    if house.is_empty(): return result
    var origin_y := -1
    var corner := Vector2i(2147483647, 2147483647)
    var far_corner := Vector2i(-2147483648, -2147483648)
    for piece in house:
        corner = Vector2i(mini(corner.x, piece.x), mini(corner.y, piece.y))
        far_corner = Vector2i(maxi(far_corner.x, piece.x), maxi(far_corner.y, piece.y))
        if origin_y < 0 and String(state.structures[piece].get("name", "")) == "DOOR" and state.built_house_origins.has(TileRules.cell_key(piece)):
            origin_y = int(state.built_house_origins[TileRules.cell_key(piece)])
    # The first cut into a house fixes where its room is measured from, so
    # that cutting away its corner does not move every later tile along by one.
    if origin_y >= 0 and not state.rooms_seen.has(origin_y):
        state.rooms_seen[origin_y] = [corner, far_corner - corner + Vector2i.ONE]
    # The room as it was last walked into decides which tile is behind the
    # piece. Joined pieces alone cannot: a piece cut off from the door belongs
    # to no house by that test, and a house whose corner has been cut away
    # measures from a different place than its room was drawn from.
    for seen_origin in state.rooms_seen:
        var seen: Array = state.rooms_seen[seen_origin]
        if Rect2i(seen[0], seen[1]).has_point(cell) and (origin_y < 0 or int(seen_origin) == origin_y):
            origin_y = int(seen_origin)
            corner = seen[0]
            break
    if origin_y < 0: return result
    var behind := cell - corner
    for raw_cell in state.structures:
        var built_cell := Vector2i(raw_cell)
        var offset := built_cell - Vector2i(state.bounds.size.x + 9, origin_y)
        if offset.x < 0 or offset.y != behind.y or offset.x % Build.FLOOR_STRIDE != behind.x: continue
        if not bool(state.structures[built_cell].get("generated_stair_pair", false)): result.append(built_cell)
    return result
