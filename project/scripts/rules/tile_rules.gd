extends RefCounted
## What the field rules ask of an area's tiles (AreaState, area_state.gd):
## which resource stands on a cell, what ground lies under it, what DIG may
## break, how holes join up and where the shore runs. Static and node-free,
## so the World (a single-player game, a host for its own area) and a host or
## server for any other area answer the same. Moved out of world.gd and
## world_field_moves.gd unchanged; their old names call these.
##
## Writes go through state.edit(cell) (the tile, kept for undo while a
## prediction records) and state.put/drop (the overlays, marked for co-op).

const FieldMoveData = preload("res://scripts/field_move_data.gd")
const NO_CELL := Vector2i(-2147483648, -2147483648)
const TILE := 16
const SOURCE_BIOME_ALIASES := {"TUNDRA": "SNOW", "SNOW": "SNOW", "DEEP FOREST": "DEEP_FOREST",
    "WOODED LAKE": "WOODED_LAKE", "BEACH_BLACKSAND": "BEACH"}

static func cell_center(cell: Vector2i) -> Vector2:
    return Vector2(cell * TILE) + Vector2(TILE, TILE) / 2.0

static func cell_key(cell: Vector2i) -> String:
    return "%d,%d" % [cell.x, cell.y]

static func key_cell(key: String) -> Vector2i:
    var parts := key.split(",")
    if parts.size() != 2: return NO_CELL
    return Vector2i(int(parts[0]), int(parts[1]))

# --- Overlays onto tiles ------------------------------------------------------

## An overlay entry (as a save, a record or another player brings it) laid on
## the tiles, the way the World does on loading and on a co-op change
## (world.gd restore_crafting_save_state, _apply_source_interior_mutation;
## coop_build_runtime.gd apply_records), but for the data only: no sprites,
## no redraws, no timers (an agitated berry tree is cleared at once). Already
## in the state's group (`value` null: gone). For an area held without a
## World (area_sim.gd) and for a replica checked against its authority.
static func apply_overlay(state, group: String, key: String, value: Variant) -> void:
    if state.tiles == null: return
    var cell := key_cell(key)
    match group:
        "terrain_changes":
            if value != null: _set_names(state, cell, "sand1" if int(value) == 1 else "green1", "")
        "removed_resources":
            if value != null:
                var tile: SourceTile = state.tile_at(cell)
                if tile != null: _set_names(state, cell, tile.name, "")
        "source_plant_farms":
            if value is Dictionary: _set_names(state, cell, String(value.get("base", "")), String(value.get("upper", "")))
        "source_interior_mutations":
            if value is Dictionary: apply_mutation(state, cell, value)

static func _set_names(state, cell: Vector2i, base: String, upper: String) -> void:
    var tile: SourceTile = state.edit(cell)
    if tile != null: tile.set_names(base, upper)

## The tile side of a saved interior mutation (world.gd _apply_mutation_by_kind
## and _apply_source_interior_mutation): kinds that only draw or that belong to
## the interiors' own layers are left to the World.
static func apply_mutation(state, cell: Vector2i, mutation: Dictionary) -> void:
    var kind := String(mutation.get("kind", ""))
    var tile: SourceTile = state.tile_at(cell)
    match kind:
        "BERRY_AGITATED":
            if tile != null: _set_names(state, cell, String(mutation.get("base", tile.name)), "")
            state.drop("source_plant_farms", cell_key(cell))
            return
        "BIOME_DIG_SITE":
            if tile != null:
                _set_names(state, cell, String(mutation.get("base", tile.name)),
                    String(mutation.get("crack", FieldMoveData.dig_site_name(tile, source_biome(tile)))))
            return
        "TILE_NAMES":
            if tile != null:
                _set_names(state, cell, String(mutation.get("base", tile.name)), String(mutation.get("upper", tile.name_upper)))
                unblock_ground(state, cell)
        "BERRY_EMPTY":
            if tile != null: _set_names(state, cell, tile.name, String(mutation.get("upper", tile.name_upper)).replace("_full", "_empty"))
            return
        "COLLECTED":
            state.drop("interactables", cell)
            if tile != null:
                tile = state.edit(cell)
                tile.has_item = ""
                tile.has_item_amount = 0
                tile.set_names(tile.name, "")
            return
        "MANSION_DOOR":
            if tile != null:
                _set_names(state, cell, "pkmnmansion_ext_door", "")
                state.put("interactables", cell, "GOTO_AREA:MANSION_0")
            return
        "EVENT_CLEARED":
            state.drop("interactables", cell)
            state.drop("blocked", cell)
            if tile != null:
                tile = state.edit(cell)
                tile.set_names(tile.name, "")
                tile.has_item = ""
                tile.has_item_amount = 0
            return
        _:
            return
    # A TILE_NAMES mutation also carries what DIG left: the buried item, the
    # dug ground's biome and route, a mountain cleared.
    tile = state.edit(cell)
    if tile == null: return
    if mutation.has("dig_item"):
        tile.has_item = String(mutation.dig_item)
        tile.has_item_amount = int(mutation.get("dig_item_amount", 0))
        if not tile.has_item.is_empty():
            state.put("interactables", cell, "ITEM:%s:%d" % [tile.has_item, tile.has_item_amount])
        elif String(state.interactables.get(cell, "")).begins_with("ITEM:"):
            state.drop("interactables", cell)
    if mutation.has("dig_biome"):
        tile.biome = String(mutation.dig_biome)
        var route_name := String(mutation.get("dig_route", ""))
        tile.route_belongs_to = null if route_name.is_empty() else SourceRoute.new(route_name, int(mutation.get("dig_route_level", 22)))
        if bool(mutation.get("dig_mountain_cleared", false)):
            tile.is_bottom_mtn_layer = false
            state.drop("blocked", cell)
    elif tile.name in ["green_woodedlake", "green_deepforest"]:
        # Palette identifiers saved as ground by older DIG code: their soil is
        # unambiguous; any dug upper or item stays.
        var saved_upper := tile.name_upper
        FieldMoveData.apply_dig_terrain(tile, "WOODED LAKE" if tile.name == "green_woodedlake" else "DEEP FOREST")
        tile.set_names(tile.name, saved_upper)
        save_dig_tile(state, cell)
    # Edited ground rejoins its holes and loses the shore it had before.
    connect_holes(state, cell)
    recoastify(state, [cell])

# --- Biomes and levels -------------------------------------------------------

static func canonical_biome(raw_biome: String) -> String:
    var key := raw_biome.strip_edges().to_upper().replace("-", "_")
    if SOURCE_BIOME_ALIASES.has(key):
        return String(SOURCE_BIOME_ALIASES[key])
    return key.replace(" ", "_")

static func source_biome(tile: SourceTile) -> String:
    var raw_biome := canonical_biome(tile.biome)
    var route_name := ""
    if tile.route_belongs_to != null:
        route_name = tile.route_belongs_to.name.to_lower()
    # Rivers reuse wooded_lake_water1 in the Java source. Wooded-lake cells
    # carry their explicit biome while river cuts keep the biome they crossed.
    if tile.is_water and route_name == "wooded_lake_water1":
        if raw_biome == "WOODED_LAKE":
            return "WOODED_LAKE"
        return "RIVER"
    if not raw_biome.is_empty():
        return raw_biome
    # Route fallbacks cover source tiles that intentionally have no biome tag.
    if not route_name.is_empty():
        if route_name == "ocean1" or "ocean" in route_name:
            return "OCEAN"
        if "beach" in route_name or "tidal" in route_name:
            return "BEACH"
        if "wooded_lake" in route_name:
            return "WOODED_LAKE"
        if "graveyard" in route_name:
            return "GRAVEYARD"
        if "volcano" in route_name:
            return "VOLCANO"
        if "oasis" in route_name:
            return "OASIS"
        if "desert" in route_name or "ruins" in route_name or "sand_pit" in route_name:
            return "DESERT"
        if "snow" in route_name or "tundra" in route_name:
            return "SNOW"
        if "mountain" in route_name or "cave" in route_name:
            return "MOUNTAIN"
        if "savanna" in route_name:
            return "SAVANNA"
        if "deep" in route_name:
            return "DEEP_FOREST"
        if "forest" in route_name:
            return "FOREST"
    if tile.is_water:
        return "OCEAN"
    return "FOREST"

static func level_for_cell(state, cell: Vector2i) -> int:
    var route: SourceRoute = state.tiles.route_at(cell)
    return clampi(2 if route == null else route.level, 2, 100)

# --- Resources ---------------------------------------------------------------

static func exact_resource_kind(state, cell: Vector2i) -> String:
    var tile: SourceTile = state.tile_at(cell)
    if tile == null:
        return ""
    var key := (tile.name + " " + tile.name_upper).to_lower()
    if "aloe_large1" in key:
        return "tree"
    if "cactus" in key:
        return "cactus"
    if "berrytree_" in key or "bush" in key:
        return "bush"
    if "tree" in key:
        return "tree"
    if "rock" in key or "stone" in key:
        return "rock"
    return ""

## tree_savanna1 is a 48x48 upper-layer sprite anchored one tile to the right
## of its visual left edge: every visible cell of its 3x3 resolves to it.
static func savanna_tree_anchor(state, cell: Vector2i) -> Vector2i:
    for y_offset in [0, -1, -2]:
        for x_offset in [-1, 0, 1]:
            var candidate: Vector2i = cell + Vector2i(int(x_offset), int(y_offset))
            var tile: SourceTile = state.tile_at(candidate)
            if tile == null:
                continue
            if tile.name_upper.to_lower().trim_suffix(".png") != "tree_savanna1":
                continue
            var visual_left: int = candidate.x - 1
            var visual_top: int = candidate.y
            if cell.x >= visual_left and cell.x <= visual_left + 2 and \
                    cell.y >= visual_top and cell.y <= visual_top + 2:
                return candidate
    return NO_CELL

static func exact_resource_anchor(state, cell: Vector2i) -> Vector2i:
    if state.tiles == null:
        return NO_CELL
    var savanna_anchor := savanna_tree_anchor(state, cell)
    if savanna_anchor.x > -2147483648:
        return savanna_anchor
    if not exact_resource_kind(state, cell).is_empty():
        return cell
    # Either visible half of a tall resource resolves to its authored tile.
    for candidate in [cell + Vector2i.UP, cell + Vector2i.DOWN]:
        if exact_resource_kind(state, candidate).is_empty():
            continue
        var tile: SourceTile = state.tile_at(candidate)
        if tile == null:
            continue
        var spec: Dictionary = SourceWorldData.render_spec(tile, true, 0, 0)
        var size: Vector2 = spec.get("size", Vector2.ZERO)
        var origin := Vector2(candidate * TILE) + Vector2(spec.get("offset", Vector2.ZERO))
        if size.y > float(TILE) and Rect2(origin, size).has_point(cell_center(cell)):
            return candidate
    return NO_CELL

static func is_large_tree(state, cell: Vector2i) -> bool:
    var tile: SourceTile = state.tile_at(cell)
    if tile == null:
        return false
    var key := (tile.name + " " + tile.name_upper).to_lower()
    return (
        "tree_large1" in key or "tree_large2" in key
        or "tree_large3" in key or "tree_large4" in key
        or "tree_savanna1" in key or "tree4" in key
    )

## The visible anchor of a giant tree (GenForest2: the anchor and three
## noSprite cells at +X, +Y and +X+Y), from any of its quadrants.
static func large_tree1_anchor(state, cell: Vector2i) -> Vector2i:
    if state.tiles == null:
        return NO_CELL
    var anchor_offsets: Array[Vector2i] = [Vector2i.ZERO, Vector2i.LEFT, Vector2i.UP, Vector2i(-1, -1)]
    var part_offsets: Array[Vector2i] = [Vector2i.ZERO, Vector2i.RIGHT, Vector2i.DOWN, Vector2i(1, 1)]
    for offset in anchor_offsets:
        var candidate: Vector2i = cell + offset
        var tile: SourceTile = state.tile_at(candidate)
        if tile == null:
            continue
        if tile.name.to_lower().trim_suffix(".png") != "tree_large1":
            continue
        var complete := true
        for part_offset in part_offsets:
            var part: SourceTile = state.tile_at(candidate + part_offset)
            if part == null:
                complete = false
                break
            var part_name := part.name.to_lower().trim_suffix(".png")
            if part_offset == Vector2i.ZERO:
                complete = complete and part_name == "tree_large1"
            else:
                complete = complete and part_name == "tree_large1_nosprite"
        if complete:
            return candidate
    return NO_CELL

static func berry_name(state, cell: Vector2i) -> String:
    var tile: SourceTile = state.tile_at(cell)
    if tile == null:
        return ""
    var upper := tile.name_upper.to_lower()
    if not upper.begins_with("berrytree_") or "full" not in upper:
        return ""
    var parts := upper.split("_")
    if parts.size() < 2:
        return ""
    return "%s BERRY" % String(parts[1]).to_upper()

## The commonest plain ground among the eight neighbours (of `biome_hint` when given).
static func contextual_ground_name(state, cell: Vector2i, biome_hint: String = "") -> String:
    if state.tiles == null:
        return ""
    var counts: Dictionary = {}
    for offset in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN,
            Vector2i(-1,-1), Vector2i(1,-1), Vector2i(-1,1), Vector2i(1,1)]:
        var nearby: SourceTile = state.tile_at(cell + offset)
        if nearby == null or nearby.is_water or nearby.is_solid or nearby.is_ledge:
            continue
        if not biome_hint.is_empty() and not String(nearby.biome).is_empty() and \
                String(nearby.biome) != biome_hint:
            continue
        var name := nearby.name
        var clean := name.to_lower().trim_suffix(".png")
        if clean.begins_with("grass") or clean.begins_with("green") or \
                clean.begins_with("sand") or clean.begins_with("desert") or \
                clean.begins_with("snow") or clean.begins_with("soot"):
            counts[name] = int(counts.get(name, 0)) + 1
    var best := ""
    var best_count := 0
    for raw_name in counts.keys():
        if int(counts[raw_name]) > best_count:
            best = String(raw_name)
            best_count = int(counts[raw_name])
    return best

## What a cut resource leaves behind.
static func cut_resource_replacement(state, tile: SourceTile, cell: Vector2i) -> Dictionary:
    var base := tile.name
    var upper := tile.name_upper
    var key := (base + " " + upper).to_lower()
    # Palm grows on sand and must expose sand when removed.
    if "tree5" in key or "tree6" in key:
        return {"base":"sand1", "upper":""}
    # Objects authored as an upper layer already have the correct biome floor.
    if not upper.is_empty():
        return {"base":base, "upper":""}
    var contextual := contextual_ground_name(state, cell, tile.biome)
    if not contextual.is_empty():
        return {"base":contextual, "upper":""}
    if "tree_large" in key or "tree5" in key:
        return {"base":"green1", "upper":""}
    if "aloe" in key or "cactus" in key:
        return {"base":"desert4", "upper":""}
    return {"base":base, "upper":""}

static func is_source_grass_name(asset_name: String) -> bool:
    var key := asset_name.to_lower().trim_suffix(".png")
    # Logical grass assets include the biome-specific variants. Do not match
    # ledge_grass_* because those are structural ledges rather than grass tufts.
    return key.begins_with("grass") and not key.begins_with("ledge_grass")

static func is_cuttable_grass(state, cell: Vector2i) -> bool:
    var tile: SourceTile = state.tile_at(cell)
    if tile == null:
        return false
    return is_source_grass_name(tile.name) or is_source_grass_name(tile.name_upper)

## The floor a cut grass tuft leaves.
static func cuttable_grass_replacement(state, tile: SourceTile, cell: Vector2i) -> Dictionary:
    var base := tile.name
    var upper := tile.name_upper
    var base_key := base.to_lower().trim_suffix(".png")
    var upper_key := upper.to_lower().trim_suffix(".png")
    # Grass authored as an upper sprite simply clears to its already-authored floor.
    if is_source_grass_name(upper_key):
        return {"base":base, "upper":""}
    # Base-layer grass is a tuft over a source-specific floor: prefer the
    # neighbouring authored floor so CUT never paints a foreign square.
    var contextual := contextual_ground_name(state, cell, tile.biome)
    if not contextual.is_empty() and not is_source_grass_name(contextual):
        return {"base":contextual, "upper":""}
    match base_key:
        "grass1", "grass2", "grass4", "grass_fairy1", "grass_fairy2", "grass_fairy3", "grass_safari", "grass_short2", "grass_short3", "grass_planted":
            return {"base":"green1", "upper":""}
        "grass3":
            return {"base":"snow1", "upper":""}
        "grass_sand1", "grass_sand2":
            return {"base":"sand1", "upper":""}
        "grass_sand3":
            return {"base":"desert4", "upper":""}
        "grass_graveyard1":
            return {"base":"green11", "upper":""}
        "grass_savanna1", "grass_savanna2":
            return {"base":"savanna1", "upper":""}
        "grass_desert1":
            return {"base":"desert4", "upper":""}
    # An unknown grass falls back to its biome's native floor.
    match source_biome(tile):
        "SNOW":
            return {"base":"snow1", "upper":""}
        "BEACH":
            return {"base":"sand1", "upper":""}
        "DESERT":
            return {"base":"desert4", "upper":""}
        "SAVANNA":
            return {"base":"savanna1", "upper":""}
        "GRAVEYARD":
            return {"base":"green11", "upper":""}
        _:
            return {"base":"green1", "upper":""}

## Clearing what grew on a tile unblocks the ground, but not a wall or roof
## built there since, nor an item lying on it.
static func unblock_ground(state, cell: Vector2i) -> void:
    if bool(state.structures.get(cell, {}).get("solid", false)):
        return
    if state.blocked.get(cell) is String:
        return
    state.drop("blocked", cell)

# --- DIG ---------------------------------------------------------------------

static func fossil_site(tile: SourceTile) -> bool:
    if tile == null:
        return false
    return "_cracked" in (tile.name + " " + tile.name_upper).to_lower()

static func dig_surface_ok(tile: SourceTile) -> bool:
    if tile == null or tile.is_water or tile.is_lava:
        return false
    if fossil_site(tile):
        return true
    var names: String = (tile.name + " " + tile.name_upper).to_lower()
    if "_tidaloff" in names:
        return true
    # The authored DIG terrain bases.
    for raw_info in FieldMoveData.DIG_TERRAIN.values():
        var info: Dictionary = raw_info
        var authored_base: String = String(info.get("base", "")).to_lower()
        if not authored_base.is_empty() and tile.name.to_lower() == authored_base:
            return true
    # Ordinary non-solid ground; mountain and cliff ground also.
    if not tile.is_solid and not tile.is_ledge:
        return true
    return "mountain" in names or "ledges3" in names

static func dig_material_at(state, cell: Vector2i) -> String:
    var tile: SourceTile = state.tile_at(cell)
    if tile == null:
        return ""
    var route_name: String = "" if tile.route_belongs_to == null else tile.route_belongs_to.name
    return FieldMoveData.dig_material(tile.name, tile.name_upper, tile.biome, route_name)

## Terrain placement is only for a hole, water2/water5, or lava
## (Player.updateBuildTiles / DrawBuildTile); intact ground is dug.
static func accepts_soil(state, cell: Vector2i) -> bool:
    var tile: SourceTile = state.tile_at(cell)
    if tile == null:
        return false
    return "hole" in tile.name_upper or "water2" in tile.name or \
        "water5" in tile.name or "lava" in tile.name

static func is_mountain(tile: SourceTile) -> bool:
    return tile != null and ("mountain" in tile.name or "ledges3" in tile.name or "ledges3" in tile.name_upper)

## The cell's tile, its item, biome and route as a TILE_NAMES mutation.
static func save_dig_tile(state, cell: Vector2i) -> void:
    var tile: SourceTile = state.tile_at(cell)
    if tile == null: return
    state.put("source_interior_mutations", cell_key(cell), {
        "kind":"TILE_NAMES", "base":tile.name, "upper":tile.name_upper,
        "dig_item":tile.has_item, "dig_item_amount":tile.has_item_amount,
        "dig_biome":tile.biome,
        "dig_route":tile.route_belongs_to.name if tile.route_belongs_to != null else "",
        "dig_route_level":tile.route_belongs_to.level if tile.route_belongs_to != null else 0})

static func leave_hole(state, cell: Vector2i) -> void:
    var tile: SourceTile = state.edit(cell)
    tile.set_names(tile.name, "hole1")
    state.drop("terrain_changes", cell_key(cell))
    save_dig_tile(state, cell)
    connect_holes(state, cell)

## A cliff's underlying ground: the commonest natural ground in the nearest
## ring of cells that has any (never structures, trees, holes or water).
static func mountain_ground(state, cell: Vector2i, tile: SourceTile) -> SourceTile:
    if not "mountain" in tile.name and not "ledges3" in tile.name:
        return tile
    var extent: Vector2i = state.tiles.top_right_cell - state.tiles.bottom_left_cell
    for radius in range(1, maxi(extent.x, extent.y) + 2):
        var choices: Dictionary = {}
        var samples: Dictionary = {}
        for step in range(-radius, radius):
            for offset in [Vector2i(step, -radius), Vector2i(radius, step), Vector2i(-step, radius), Vector2i(-radius, -step)]:
                var nearby: SourceTile = state.tile_at(cell + offset)
                if nearby == null or is_mountain(nearby) or nearby.is_water or nearby.is_lava or nearby.is_solid or nearby.is_ledge: continue
                if nearby.name_upper.begins_with("hole1"): continue
                var ground := nearby.name
                if not (ground.begins_with("green") or ground.begins_with("sand") or ground.begins_with("desert") or ground.begins_with("snow") or ground.begins_with("volcano") or ground.begins_with("soot")): continue
                choices[ground] = int(choices.get(ground, 0)) + 1
                samples[ground] = nearby
        if not choices.is_empty():
            var best: String = choices.keys()[0]
            for name in choices:
                if int(choices[name]) > int(choices[best]): best = name
            return samples[best]
    # No surrounding land exists (isolated all-mountain test/custom worlds).
    return SourceTile.new("green1", tile.position)

static func clear_dug_mountain(state, cell: Vector2i) -> void:
    var tile: SourceTile = state.edit(cell)
    var ground := mountain_ground(state, cell, tile)
    # The sample is read before this tile changes: its values, not the proxy.
    var ground_name := ground.name
    var ground_biome := ground.biome
    var ground_route := ground.route_belongs_to
    tile.set_names(ground_name, "")
    tile.biome = ground_biome
    tile.route_belongs_to = ground_route
    tile.is_bottom_mtn_layer = false
    tile.shore_ocean = ""
    tile.shore_tidal = ""
    state.drop("blocked", cell)
    state.drop("terrain_changes", cell_key(cell))
    save_dig_tile(state, cell)
    state.source_interior_mutations[cell_key(cell)]["dig_mountain_cleared"] = true
    recoastify(state, [cell])

static func dig_connects(state, cell: Vector2i, diagonal: bool = false) -> bool:
    var tile: SourceTile = state.tile_at(cell)
    if tile == null: return false
    var names := tile.name + " " + tile.name_upper
    if diagonal:
        return "water" in names or "hole" in tile.name_upper
    return "hole" in names or "water" in names or "lava" in names

## The edges and corners of the holes around `changed` (Java map coordinates:
## north is +Y here), saved with them.
static func connect_holes(state, changed: Vector2i) -> void:
    var dirs := {"N":Vector2i(0,1), "S":Vector2i(0,-1), "E":Vector2i(1,0), "W":Vector2i(-1,0)}
    for dy in range(-1,2):
        for dx in range(-1,2):
            var cell := changed + Vector2i(dx,dy)
            var tile: SourceTile = state.tile_at(cell)
            if tile == null or not tile.name_upper.begins_with("hole1"): continue
            var suffix := ""
            for direction in ["N", "S", "E", "W"]:
                if dig_connects(state, cell + dirs[direction]): suffix += direction
            var name := "hole1" + ("_" + suffix if not suffix.is_empty() else "")
            for corner in ["NE", "SE", "SW", "NW"]:
                if corner[0] in suffix and corner[1] in suffix and dig_connects(state, cell + dirs[corner[0]] + dirs[corner[1]], true):
                    name += "[" + corner + "]"
            tile = state.edit(cell)
            tile.set_names(tile.name, name)
            save_dig_tile(state, cell)

# --- Shore -------------------------------------------------------------------

## The shore edges of the cells around `changed_cells`, worked out again.
static func recoastify(state, changed_cells: Array) -> void:
    var targets: Dictionary = {}
    for changed in changed_cells:
        for y in range(changed.y - 1, changed.y + 2):
            for x in range(changed.x - 1, changed.x + 2):
                targets[Vector2i(x, y)] = true
    # Neighbours are read from the tile store's arrays: a proxy for each of
    # them cost ~0.5 ms per changed cell (48 ms for a load's tide cleanup).
    var store: WorldTileStore = state.tiles.tiles
    var flags := store.flags
    var name_ids := store.name_ids
    var water6: int = store.string_ids.get("water6", -1)
    for raw_cell in targets.keys():
        var cell := raw_cell as Vector2i
        var tile: SourceTile = state.tile_at(cell)
        if tile == null:
            continue
        tile = state.edit(cell)
        tile.shore_ocean = ""
        tile.shore_tidal = ""
        if tile.is_water or "ledges" in tile.name_upper or tile.name == "ice2" or \
                "bridge" in tile.name or "waterfall" in tile.name:
            continue
        var names := ["W", "E", "S", "N", "SW", "NE", "SE", "NW"]
        var offsets := [
            Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN,
            Vector2i(-1, -1), Vector2i(1, 1),
            Vector2i(1, -1), Vector2i(-1, 1)]
        var ocean := ""
        var tidal := ""
        for index in range(offsets.size()):
            var at := store.index_of((cell + offsets[index]) * TILE)
            var bits := 0
            if at >= 0:
                if name_ids[at] == water6:
                    continue
                bits = flags[at]
            else:
                var neighbor: SourceTile = state.tile_at(cell + offsets[index])
                if neighbor == null or neighbor.name == "water6":
                    continue
                bits = (WorldTileStore.TIDAL if neighbor.is_tidal else 0) | (WorldTileStore.WATER if neighbor.is_water else 0)
            var direction := String(names[index])
            if not tile.is_tidal and bits & WorldTileStore.TIDAL:
                if not shore_diagonal_present(tidal, direction):
                    tidal += "[" + direction + "]"
                continue
            if not bits & WorldTileStore.WATER or shore_diagonal_present(ocean, direction):
                continue
            ocean += "[" + direction + "]"
            tidal += "[" + direction + "]"
        tile.shore_ocean = ocean
        tile.shore_tidal = tidal

static func shore_diagonal_present(existing: String, direction: String) -> bool:
    if direction.length() < 2:
        return false
    for index in range(direction.length()):
        if "[" + direction.substr(index, 1) + "]" in existing:
            return true
    return false

