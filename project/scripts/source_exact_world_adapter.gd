class_name SourceExactWorldAdapter
extends RefCounted

const TILE_SIZE := 16

## A Dictionary of SourceTile objects while freshly generated tiles are
## repaired, then (and from a v3 cache) a WorldTileStore.
var tiles = {}
var pokemon: Dictionary = {}
var burrowed_pokemon: Array = []
var edges: Array = []
var bottom_left_cell := Vector2i.ZERO
var top_right_cell := Vector2i.ZERO
var spawn_cell := Vector2i.ZERO
var interior_plans: Array[Dictionary] = []
var used_dungeons: Array[String] = []
var regi_relocated_cells: Dictionary = {}
## A fresh world's ocean cells are ints in the Dictionary until packed:
## indices into these read-only templates (SourceIslandGenerator.ocean_tiles).
var _ocean: Array = []

## Every tile as a list, built once. Asking the dictionary for its values makes
## a fresh copy of the whole map each time; the dawn and dusk passes each did
## that in a single frame, which is the stall felt when night turns to day.
var _tile_list: Array = []
var _tile_list_size := -1  # -1 forces a rebuild (set whenever an entry is replaced)

func tile_list() -> Array:
    # Whole-map loops use tiles.indices() and tiles.cursor() instead: a list
    # of every tile would be ~400k proxies.
    if tiles is WorldTileStore: return tiles.values()
    if _tile_list_size != tiles.size():
        _tile_list = tiles.values()
        _tile_list_size = tiles.size()
    return _tile_list

static func from_generator_result(
        result: Dictionary,
        spawn_random: SourceJavaRandom
    ) -> SourceExactWorldAdapter:
    var adapter := SourceExactWorldAdapter.new()
    if result.get("store") is WorldTileStore:
        # A v3 cache holds the adapted world: nothing to repair or mirror.
        adapter.tiles = result.store
        adapter.pokemon = result.get("pokemon", {})
        adapter.burrowed_pokemon = result.get("burrowed_pokemon", [])
        adapter.edges = result.get("edges", [])
        adapter.regi_relocated_cells = result.get("regi_relocated_cells", {})
        adapter._finish(result, spawn_random)
        return adapter
    adapter.tiles = result.get("tiles", {})
    adapter._ocean = result.get("ocean_tiles", [])
    adapter.pokemon = result.get("pokemon", {})
    adapter.repair_regi_mansion_overlap()
    adapter.repair_graveyard_side_fences()
    adapter.burrowed_pokemon = result.get("burrowed_pokemon", [])
    adapter.edges = result.get("edges", [])
    # GenIsland1 authors the mansion exterior in Java's Y-up map space. The
    # rest of the exact adapter deliberately preserves source coordinates, but
    # this building has directional N/S artwork whose rows otherwise appear
    # upside-down in Godot. Mirror only the single mansion exterior route.
    adapter._normalize_oasis_facades_for_godot()
    adapter.repair_mansion_roof_grass()
    adapter._normalize_mansion_exterior_for_godot()
    adapter.tiles = WorldTileStore.from_dictionary(adapter.tiles, adapter._ocean)
    adapter._ocean = []
    # Packed: the generator's tile objects are not needed any more. Free them
    # now rather than when the caller drops the result (it keeps it while the
    # world is built).
    result.erase("tiles")
    result.erase("mountains")
    # Edges were tile objects: keep positions, so no object outlives packing.
    # Built locally and assigned once: writing adapter.edges[i] one element at
    # a time copied the whole array each time (minutes on a size M map).
    var edge_positions: Array = []
    edge_positions.resize(adapter.edges.size())
    for index in range(adapter.edges.size()):
        var edge: Variant = adapter.edges[index]
        edge_positions[index] = (edge as SourceTile).position if edge is SourceTile else edge
    adapter.edges = edge_positions
    result.erase("edges")
    adapter._finish(result, spawn_random)
    return adapter

## The Dictionary's tile at `position` (null if none), an ocean cell made
## real (it may be changed).
func _dict_tile(position: Vector2i) -> SourceTile:
    var raw: Variant = tiles.get(position)
    if raw is int:
        raw = (_ocean[raw] as SourceTile).copy_at(position)
        tiles[position] = raw
    return raw

## Read-only look at the Dictionary's tile: an ocean cell gives its template,
## whose position is not the cell's.
func _dict_peek(position: Vector2i) -> SourceTile:
    var raw: Variant = tiles.get(position)
    return _ocean[raw] if raw is int else raw

func _finish(result: Dictionary, spawn_random: SourceJavaRandom) -> void:
    var adapter := self
    adapter.bottom_left_cell = SourceWorldData.pixel_to_cell(
        Vector2i(result.get("bottom_left", Vector2i.ZERO))
    )
    adapter.top_right_cell = SourceWorldData.pixel_to_cell(
        Vector2i(result.get("top_right", Vector2i.ZERO))
    )
    adapter.used_dungeons = result.get("already_used_dungeons", [])
    adapter.interior_plans = SourceInteriorGenerator.from_source_layers(
        result.get("interiors", []), result.get("interior_pokemon", [])
    )
    adapter.spawn_cell = adapter._choose_edge_spawn(spawn_random)


func repair_regi_mansion_overlap() -> Array[Vector2i]:
    # Repair the old required-cave placement bug in v2 caches without regenerating
    # the world or its interiors. Its 54 source tiles replaced the mansion roof.
    var repaired: Array[Vector2i] = []
    var corners: Dictionary = {}
    var cave_doors: Array[SourceTile] = []
    # Ocean cells (ints) are no door, roof, cave or forest: skipped below.
    for raw in tiles.values():
        if raw is int: continue
        var tile := raw as SourceTile
        if tile == null: continue
        if tile.name == "cave1_door1": cave_doors.append(tile)
        if tile.route_belongs_to != null and tile.name_upper in [
                "pkmnmansion_roof_NW", "pkmnmansion_roof_NE", "pkmnmansion_roof_SW", "pkmnmansion_roof_SE"]:
            var id := tile.route_belongs_to.get_instance_id()
            if not corners.has(id): corners[id] = {}
            corners[id][tile.name_upper.trim_prefix("pkmnmansion_roof_")] = tile
    for group in corners.values():
        if group.size() != 4: continue
        var nw := group.NW as SourceTile
        var ne := group.NE as SourceTile
        var sw := group.SW as SourceTile
        var roof := Rect2i(nw.position.x, mini(nw.position.y,sw.position.y),31*16,26*16)
        if ne.position.x - nw.position.x != 30*16 or absi(nw.position.y-sw.position.y) != 25*16: continue
        for door in cave_doors:
            if not roof.has_point(door.position): continue
            var cave: Array[SourceTile] = []
            var contained := true
            for raw in tiles.values():
                if raw is int: continue
                var tile := raw as SourceTile
                if tile.route_belongs_to == door.route_belongs_to:
                    cave.append(tile)
                    if not roof.has_point(tile.position): contained = false
            # Only the known, fully overwritten roof footprint is reconstructible.
            if not contained or cave.size() != 54: continue
            var candidates: Array[Vector2i] = []
            for raw in tiles.values():
                if raw is int: continue
                var tile := raw as SourceTile
                if (tile.biome == "deep_forest" or "deepforest" in tile.name) and not tile.is_solid and not tile.is_water:
                    candidates.append(tile.position)
            candidates.sort_custom(func(a: Vector2i,b: Vector2i):
                var da := (a-door.position).length_squared()
                var db := (b-door.position).length_squared()
                return da<db if da!=db else (a.y<b.y if a.y!=b.y else a.x<b.x))
            var destination := Vector2i(2147483647,2147483647)
            for candidate in candidates:
                var safe := true
                for original in cave:
                    var target := candidate + original.position - door.position
                    var tile := _dict_peek(target)
                    if roof.grow(16).has_point(target) or pokemon.has(target) or tile==null or tile.is_water or tile.is_lava or tile.is_ledge or tile.is_bottom_mtn_layer or not tile.has_item.is_empty() or not tile.item_snapshot().is_empty():
                        safe=false;break
                    if "mtn" in tile.name or "mountain" in tile.name or "cave" in tile.name or "ruins" in tile.name or "building" in tile.name or "pkmnmansion" in tile.name or "pkmnmansion" in tile.name_upper or "fence" in tile.name or "fence" in tile.name_upper or "grave" in tile.name or "grave" in tile.name_upper or "key" in tile.name_upper:
                        safe=false;break
                var entrance := _dict_peek(candidate + Vector2i(0,-16))
                for original in cave:
                    if original.position == door.position + Vector2i(0,-16): entrance = original
                if entrance==null or entrance.is_solid or entrance.is_water: safe=false
                if safe:
                    destination=candidate
                    break
            if destination.x==2147483647: continue
            var old_door := door.position
            regi_relocated_cells[SourceWorldData.pixel_to_cell(old_door + Vector2i(0,-16))] = SourceWorldData.pixel_to_cell(destination + Vector2i(0,-16))
            for original in cave:
                var position := original.position
                var suffix := "N" if position.y==nw.position.y else "S" if position.y==sw.position.y else ""
                suffix += "W" if position.x==nw.position.x else "E" if position.x==ne.position.x else ""
                tiles[position]=SourceTile.new("sand1",position,"pkmnmansion_roof"+("_"+suffix if not suffix.is_empty() else ""),true,nw.route_belongs_to)
                _tile_list_size = -1 # entry replaced: tile_list() must rebuild
                var moved := original.copy_at(destination+position-old_door)
                tiles[moved.position]=moved
                _tile_list_size = -1 # entry replaced: tile_list() must rebuild
                regi_relocated_cells[SourceWorldData.pixel_to_cell(position)] = SourceWorldData.pixel_to_cell(moved.position)
                repaired.append(position)
    return repaired


func repair_mansion_roof_grass() -> Array[Vector2i]:
    # GenIsland1.generateMansion: 31 columns, roof rows 3..28. Restrict
    # repairs to that authored rectangle, identified by its four source corners.
    # Corner positions also handle the adapter's Y-mirrored cached/save view.
    var groups: Dictionary = {}
    var repaired: Array[Vector2i] = []
    var corner_names := ["pkmnmansion_roof_NW", "pkmnmansion_roof_NE", "pkmnmansion_roof_SW", "pkmnmansion_roof_SE"]
    for raw_tile in (tiles.with_upper(corner_names) if tiles is WorldTileStore else tiles.values()):
        if raw_tile is int: continue  # ocean
        var tile := raw_tile as SourceTile
        if tile == null or tile.route_belongs_to == null:
            continue
        if tile.name_upper not in corner_names:
            continue
        var key := tile.route_belongs_to.get_instance_id()
        if not groups.has(key): groups[key] = {}
        groups[key][tile.name_upper.trim_prefix("pkmnmansion_roof_")] = tile
    for corners in groups.values():
        if corners.size() != 4: continue
        var nw := corners["NW"] as SourceTile
        var ne := corners["NE"] as SourceTile
        var sw := corners["SW"] as SourceTile
        var se := corners["SE"] as SourceTile
        if ne.position.x - nw.position.x != 30 * TILE_SIZE or absi(sw.position.y - nw.position.y) != 25 * TILE_SIZE:
            continue
        if sw.position.x != nw.position.x or se.position.x != ne.position.x or ne.position.y != nw.position.y or se.position.y != sw.position.y:
            continue
        for y in range(mini(nw.position.y, sw.position.y), maxi(nw.position.y, sw.position.y) + TILE_SIZE, TILE_SIZE):
            for x in range(nw.position.x, ne.position.x + TILE_SIZE, TILE_SIZE):
                var position := Vector2i(x, y)
                var tile := (tiles.tile(position) if tiles is WorldTileStore else _dict_peek(position)) as SourceTile
                if tile == null: continue
                var grass_base := tile.name.begins_with("grass") or tile.name.begins_with("green")
                var grass_upper := tile.name_upper.begins_with("grass")
                if not grass_base and not grass_upper: continue
                if not tile.name_upper.is_empty() and not grass_upper and not tile.name_upper.begins_with("pkmnmansion_roof"):
                    continue
                var suffix := "N" if y == nw.position.y else "S" if y == sw.position.y else ""
                suffix += "W" if x == nw.position.x else "E" if x == ne.position.x else ""
                var upper := "pkmnmansion_roof" + ("_" + suffix if not suffix.is_empty() else "")
                var roof := SourceTile.new("sand1", position, upper, true, nw.route_belongs_to)
                if tiles is WorldTileStore: tiles.put(position, roof)
                else: tiles[position] = roof
                _tile_list_size = -1 # entry replaced: tile_list() must rebuild
                repaired.append(SourceWorldData.pixel_to_cell(position))
    return repaired


func _normalize_mansion_exterior_for_godot() -> void:
    # Both the Oasis fossil lab and the real Pokemon Mansion use
    # pkmnmansion_* exterior art. The old first-match lookup could therefore
    # mirror the tiny Oasis facade and leave the true 31-tile-wide Mansion
    # unnormalised. Count each authored route and select the large non-oasis
    # exterior explicitly.
    var route_counts: Dictionary = {}
    var route_refs: Dictionary = {}
    for raw_tile in tiles.values():
        if raw_tile is int: continue  # ocean
        var tile := raw_tile as SourceTile
        if tile == null or tile.route_belongs_to == null:
            continue
        if not (
                tile.name_upper.begins_with("pkmnmansion_ext")
                or tile.name_upper.begins_with("pkmnmansion_roof")
            ):
            continue
        var route := tile.route_belongs_to
        var route_name := String(route.name).to_lower()
        if route_name == "oasis1":
            continue
        var key := str(route.get_instance_id())
        route_refs[key] = route
        route_counts[key] = int(route_counts.get(key, 0)) + 1
    var mansion_route: SourceRoute = null
    var mansion_count := -1
    for raw_key in route_counts.keys():
        var key := String(raw_key)
        var count := int(route_counts[key])
        if count > mansion_count:
            mansion_count = count
            mansion_route = route_refs[key] as SourceRoute
    if mansion_route == null:
        return

    var route_positions: Array[Vector2i] = []
    var minimum_y := 2147483647
    var maximum_y := -2147483648
    for raw_tile in tiles.values():
        if raw_tile is int: continue  # ocean
        var tile := raw_tile as SourceTile
        if tile == null or not is_same(tile.route_belongs_to, mansion_route):
            continue
        if not (
                tile.name_upper.begins_with("pkmnmansion_ext")
                or tile.name_upper.begins_with("pkmnmansion_roof")
            ):
            continue
        route_positions.append(tile.position)
        minimum_y = mini(minimum_y, tile.position.y)
        maximum_y = maxi(maximum_y, tile.position.y)
    if route_positions.is_empty():
        return

    var position_map: Dictionary = {}
    var replacements: Dictionary = {}
    for old_position in route_positions:
        var tile := _dict_tile(old_position)
        if tile == null:
            continue
        var new_position := Vector2i(
            old_position.x, minimum_y + maximum_y - old_position.y)
        position_map[old_position] = new_position
        replacements[new_position] = tile.copy_at(new_position)
    for old_position in route_positions:
        tiles.erase(old_position)
    for new_position in replacements:
        tiles[new_position] = replacements[new_position]
        _tile_list_size = -1 # entry replaced: tile_list() must rebuild

    var remapped_pokemon: Dictionary = {}
    for raw_position in pokemon.keys():
        var old_position := Vector2i(raw_position)
        var new_position: Vector2i = position_map.get(old_position, old_position)
        var record := (pokemon[raw_position] as Dictionary).duplicate(true)
        if position_map.has(old_position):
            record["position"] = new_position
        remapped_pokemon[new_position] = record
    pokemon = remapped_pokemon
    for raw_record in burrowed_pokemon:
        if not (raw_record is Dictionary):
            continue
        var record := raw_record as Dictionary
        var old_position: Vector2i = record.get("position", Vector2i.ZERO)
        if position_map.has(old_position):
            record["position"] = Vector2i(position_map[old_position])
    for index in range(edges.size()):
        var edge: Variant = edges[index]
        if edge is SourceTile:
            var edge_position := (edge as SourceTile).position
            if position_map.has(edge_position):
                edges[index] = tiles.get(position_map[edge_position], edge)
        elif edge is Vector2i and position_map.has(edge):
            edges[index] = position_map[edge]

func tile_at(cell: Vector2i) -> SourceTile:
    if tiles is WorldTileStore: return tiles.tile(cell * TILE_SIZE)
    return tiles.get(cell * TILE_SIZE) as SourceTile

func contains_cell(cell: Vector2i) -> bool:
    return tiles.has(cell * TILE_SIZE)

func is_solid(cell: Vector2i) -> bool:
    if SourceWorldData.berry_tree_collision(tiles, cell): return true
    var savanna := SourceWorldData.savanna_trunk_collision(tiles, cell)
    if savanna >= 0:
        return savanna == 1
    var tile := tile_at(cell)
    return tile == null or tile.is_solid

func route_at(cell: Vector2i) -> SourceRoute:
    var tile := tile_at(cell)
    return null if tile == null else tile.route_belongs_to

func bounds() -> Rect2i:
    return Rect2i(
        bottom_left_cell,
        top_right_cell - bottom_left_cell + Vector2i.ONE
    )

func pokemon_cell_records() -> Array[Dictionary]:
    var records: Array[Dictionary] = []
    for raw_spawn in pokemon.values():
        var spawn := raw_spawn as Dictionary
        var converted := spawn.duplicate(true)
        var pixel_position: Vector2i = spawn.get("position", Vector2i.ZERO)
        converted["cell"] = SourceWorldData.pixel_to_cell(pixel_position)
        records.append(converted)
    return records

func burrowed_cell_records() -> Array[Dictionary]:
    var records: Array[Dictionary] = []
    for raw_spawn in burrowed_pokemon:
        if typeof(raw_spawn) != TYPE_DICTIONARY:
            continue
        var spawn := raw_spawn as Dictionary
        var converted := spawn.duplicate(true)
        var pixel_position: Vector2i = spawn.get("position", Vector2i.ZERO)
        converted["cell"] = SourceWorldData.pixel_to_cell(pixel_position)
        records.append(converted)
    return records

func _choose_edge_spawn(spawn_random: SourceJavaRandom) -> Vector2i:
    if edges.is_empty():
        return Vector2i.ZERO
    var selected: Variant = edges[spawn_random.next_int(edges.size())]
    if selected is SourceTile:
        return SourceWorldData.pixel_to_cell((selected as SourceTile).position)
    return SourceWorldData.pixel_to_cell(Vector2i(selected))

func _normalize_oasis_facades_for_godot() -> void:
    # GenIsland1.generateOasis uses the cracked mansion art in the supplied
    # screenshot. Convert that facade too, while keeping its fossil-lab identity.
    var facades: Dictionary = {}
    for tile in tiles.values():
        if tile is int: continue  # ocean
        if tile.route_belongs_to == null or tile.route_belongs_to.name != "oasis1":
            continue
        if not (tile.name_upper.begins_with("pkmnmansion_ext") or tile.name_upper.begins_with("pkmnmansion_roof")):
            continue
        var key: int = tile.route_belongs_to.get_instance_id()
        if not facades.has(key): facades[key] = []
        facades[key].append(tile)
    for facade in facades.values():
        var low := 2147483647
        var high := -2147483648
        for tile in facade:
            low = mini(low, tile.position.y)
            high = maxi(high, tile.position.y)
        var replacements := {}
        for tile in facade:
            var at := Vector2i(tile.position.x, low + high - tile.position.y)
            replacements[at] = tile.copy_at(at)
            tiles.erase(tile.position)
        tiles.merge(replacements, true)
        _tile_list_size = -1 # entry replaced: tile_list() must rebuild

func repair_graveyard_side_fences() -> int:
    # Older world caches retain missing side rails even after the generator
    # repair. Identify only source enclosures by all four matching corners.
    # Run before saved player mutations, so deliberately CUT fences stay removed.
    var repaired := 0
    for raw_tile in tiles.values():
        if raw_tile is int: continue  # ocean
        var corner := raw_tile as SourceTile
        if corner == null or corner.name_upper != "fence1_NE":
            continue
        if corner.biome != "graveyard" and (corner.route_belongs_to == null or not "graveyard" in corner.route_belongs_to.name):
            continue
        for width in range(4, 9):
            var right := _dict_tile(corner.position + Vector2i(width * 16, 0))
            if right == null or right.name_upper != "fence1_NW" or not is_same(right.route_belongs_to, corner.route_belongs_to):
                continue
            for height in range(4, 10):
                var left_top := _dict_tile(corner.position + Vector2i(0, height * 16))
                var right_top := _dict_tile(right.position + Vector2i(0, height * 16))
                if left_top == null or right_top == null or left_top.name_upper != "fence1_SE" or right_top.name_upper != "fence1_SW":
                    continue
                if not is_same(left_top.route_belongs_to, corner.route_belongs_to) or not is_same(right_top.route_belongs_to, corner.route_belongs_to):
                    continue
                for row in range(1, height):
                    for x in [corner.position.x, right.position.x]:
                        var side := _dict_tile(Vector2i(x, corner.position.y + row * 16))
                        if side == null or not is_same(side.route_belongs_to, corner.route_belongs_to):
                            continue
                        var upper := side.name_upper.to_lower()
                        if "door" in upper or "gate" in upper or "gravestone" in upper or "pokedoll" in upper:
                            continue
                        if upper.is_empty() or upper.begins_with("fence1") or upper.begins_with("grass"):
                            if side.name_upper != "fence1_NS":
                                side.set_names(side.name, "fence1_NS")
                                repaired += 1
    return repaired
