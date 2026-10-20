class_name SourceInteriorGenerator
extends RefCounted

# GenIsland1 writes generated interiors into shared coordinate planes rather
# than isolated generic rooms. Layers 95-101 contain Mansion/Ruins content,
# layer 100 also contains the Fossil Lab, and layer 90 contains the Regi room.
# This adapter preserves that representation and only converts Java's 16-pixel
# positions into renderer cells.

static func from_source_layers(
        source_layers: Array,
        source_pokemon: Array = []
    ) -> Array[Dictionary]:
    var plans: Array[Dictionary] = []
    for layer_index in range(source_layers.size()):
        if source_layers[layer_index] == null:
            continue
        var source_tiles := source_layers[layer_index] as Dictionary
        if source_tiles.is_empty():
            continue
        plans.append(_make_layer_plan(layer_index, source_tiles, source_pokemon))
    return plans

static func _make_layer_plan(
        layer_index: int,
        source_tiles: Dictionary,
        source_pokemon: Array
    ) -> Dictionary:
    var minimum := Vector2i(2147483647, 2147483647)
    var maximum := Vector2i(-2147483648, -2147483648)
    var world_tiles: Dictionary = {}
    var solids: Dictionary = {}
    var transitions: Dictionary = {}
    var interactables: Dictionary = {}
    var routes: Dictionary = {}
    var entries: Array[Vector2i] = []

    for raw_tile in source_tiles.values():
        var tile := raw_tile as SourceTile
        if tile == null:
            continue
        var cell := SourceWorldData.pixel_to_cell(tile.position)
        minimum.x = mini(minimum.x, cell.x)
        minimum.y = mini(minimum.y, cell.y)
        maximum.x = maxi(maximum.x, cell.x)
        maximum.y = maxi(maximum.y, cell.y)
        world_tiles[cell] = tile
        if tile.route_belongs_to != null and tile.route_belongs_to.name == "regi_cave1" and "up" in tile.name:
            # Tile.init: cave up tiles are ledges, not solid cave walls.
            tile.is_solid = false
            tile.is_ledge = true
            tile.ledge_dir = "up"
        if tile.is_solid:
            solids[cell] = true
        var route_name := ""
        if tile.route_belongs_to != null:
            route_name = tile.route_belongs_to.name
            routes[route_name] = int(routes.get(route_name, 0)) + 1
        var stair_name := _stair_name(tile)
        if not stair_name.is_empty():
            solids.erase(cell)
            transitions[cell] = {
                "source_cell": cell,
                "target_layer": layer_index + 1 if "up" in stair_name else layer_index - 1,
                "exit_overworld": "exit" in stair_name,
                "tile": stair_name
            }
            entries.append(cell)
        elif _is_source_exit(tile, source_tiles):
            solids.erase(cell)
            transitions[cell] = {
                "source_cell": cell,
                "target_layer": -1,
                "exit_overworld": true,
                "tile": tile.name if not tile.name.is_empty() else tile.name_upper
            }
            entries.append(cell)
        if tile.name_upper == "building1_fossilreviver1":
            interactables[cell] = "FOSSIL_MACHINE"
        elif tile.name_upper == "mewtwo_overworld":
            interactables[cell] = "SPECIAL:mewtwo"
        elif tile.name == "mega_gengar_overworld1" or tile.name_upper == "mega_gengar_overworld1":
            interactables[cell] = "SPECIAL:mega_gengar"
        elif tile.name == "pkmnmansion_statue1" and not tile.door_tiles.is_empty():
            interactables[cell] = "MANSION_SWITCH"
        elif tile.name_upper == "volcarona":
            interactables[cell] = "SPECIAL:volcarona"
        elif tile.name_upper.begins_with("REGI"):
            interactables[cell] = "SPECIAL:%s" % tile.name_upper.to_lower()
        elif tile.name == "cave1_regipedistal1":
            # Tile.onPressA opens DrawCraftsMenu with the recipes carried by
            # this pedestal's items map. It does not award those keys as loot.
            interactables[cell] = "REGI_FORGE"
        elif tile.name == "cave1_regi3":
            interactables[cell] = "REGIGIGAS_GATE"
        elif not tile.has_item.is_empty():
            interactables[cell] = "ITEM:%s:%d" % [tile.has_item, tile.has_item_amount]

    var normalized_tiles: Dictionary = {}
    var normalized_solids: Dictionary = {}
    var normalized_transitions: Dictionary = {}
    var normalized_interactables: Dictionary = {}
    var source_to_local: Dictionary = {}
    for raw_source_cell in world_tiles:
        var source_cell := Vector2i(raw_source_cell)
        var local_cell := Vector2i(source_cell.x - minimum.x, maximum.y - source_cell.y)
        normalized_tiles[local_cell] = world_tiles[source_cell]
        source_to_local[source_cell] = local_cell
        if solids.has(source_cell):
            normalized_solids[local_cell] = true
        if transitions.has(source_cell):
            normalized_transitions[local_cell] = transitions[source_cell]
        if interactables.has(source_cell):
            normalized_interactables[local_cell] = interactables[source_cell]

    var pokemon: Array[Dictionary] = []
    for raw_spawn in source_pokemon:
        var spawn := raw_spawn as Dictionary
        if int(spawn.get("area_index", -1)) != layer_index:
            continue
        var source_position: Vector2i = spawn.get("position", Vector2i.ZERO)
        var source_cell := SourceWorldData.pixel_to_cell(source_position)
        var converted := spawn.duplicate(true)
        converted["source_cell"] = source_cell
        converted["cell"] = Vector2i(source_cell.x - minimum.x, maximum.y - source_cell.y)
        pokemon.append(converted)

    return {
        "id": "INTERIOR_%d" % layer_index,
        "layer_index": layer_index,
        "source_bounds": Rect2i(minimum, maximum - minimum + Vector2i.ONE),
        "size": maximum - minimum + Vector2i.ONE,
        # Packed: the tile objects are freed once the plan is made.
        "tiles": InteriorTileStore.pack(normalized_tiles),
        "solids": normalized_solids,
        "transitions": normalized_transitions,
        "interactables": normalized_interactables,
        "source_to_local": source_to_local,
        "entries": entries,
        "routes": routes,
        "pokemon": pokemon
    }

static func _stair_name(tile: SourceTile) -> String:
    if "stairs" in tile.name_upper:
        return tile.name_upper
    if "stairs" in tile.name:
        return tile.name
    return ""

static func _is_source_exit(tile: SourceTile, source_tiles: Dictionary) -> bool:
    var combined := "%s %s" % [tile.name.to_lower(), tile.name_upper.to_lower()]
    if "entrance" in combined:
        return true
    if "rug" not in combined:
        return false
    for offset in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
        var neighbor := source_tiles.get(tile.position + offset * 16) as SourceTile
        if neighbor == null or "wall" in neighbor.name or "wall" in neighbor.name_upper:
            return true
    return false
