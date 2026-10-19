extends RefCounted
## Data-only acceptance checks. Runs on the generation worker before caching.
const STEPS := [Vector2i(16,0),Vector2i(-16,0),Vector2i(0,16),Vector2i(0,-16)]

static func signature(tile: SourceTile) -> Array:
    return [tile.name, tile.name_upper, tile.has_item, tile.has_item_amount,
        tile.door_snapshot().duplicate(), tile.item_snapshot().duplicate(true)]

static func capture(kind: String, at: Vector2i, exterior: Dictionary, layers: Dictionary) -> Dictionary:
    var record := {"kind":kind,"origin":at,"exterior":{},"layers":{}}
    for pos in exterior:
        var tile: SourceTile = exterior[pos]
        if kind == "mansion" and "pkmnmansion" not in tile.name + tile.name_upper: continue
        record.exterior[pos] = signature(tile)
    for li in layers:
        record.layers[li] = {}
        for pos in layers[li]: record.layers[li][pos] = signature(layers[li][pos])
    return record

static func validate(generator) -> Dictionary:
    var errors: Array[String] = []
    var counts := {"mansion":0,"regi":0,"mine":0,"fossil_lab":0}
    var biomes := {}
    var exterior_owners := {}
    var interior_owners := {}
    var keys := 0
    for tile in generator.tiles_to_add.values():
        if tile.name_upper == "pokemon_mansion_key": keys += 1
        if not tile.biome.is_empty(): biomes[tile.biome] = true
        if tile.route_belongs_to != null:
            var route_name: String = tile.route_belongs_to.name
            if route_name == "forest1": biomes["forest"] = true
            if route_name == "oasis1": biomes["oasis"] = true
    for biome in ["forest", "deep_forest", "wooded_lake", "savanna", "desert", "graveyard", "mountain", "tundra", "volcano", "beach", "oasis"]:
        if not biomes.has(biome): errors.append("Missing biome: " + biome)
    if keys == 0: errors.append("Mansion key missing")
    for record in generator.validation_records:
        var kind: String = record.kind
        counts[kind] += 1
        for pos in record.exterior:
            if exterior_owners.has(pos) and exterior_owners[pos] != kind:
                _error(errors,"Landmark exterior overlap")
            exterior_owners[pos] = kind
            var tile = generator.tiles_to_add.get(pos)
            if tile == null or signature(tile) != record.exterior[pos]:
                _error(errors,kind + " exterior overwritten or missing")
        var layers := {}
        for li in record.layers:
            var final_layer = generator.interior_tiles_to_add[li]
            layers[li] = {}
            for pos in record.layers[li]:
                var cell := Vector3i(pos.x,pos.y,li)
                if interior_owners.has(cell) and interior_owners[cell] != kind:
                    _error(errors,"Landmark interior overlap")
                interior_owners[cell] = kind
                var tile = final_layer.get(pos) if final_layer is Dictionary else null
                if tile == null or signature(tile) != record.layers[li][pos]:
                    _error(errors,kind + " interior overwritten or missing")
                if tile != null: layers[li][pos] = tile
        _check_rooms(kind,layers,record.origin,errors)
        var entry_name: String = "pkmnmansion_ext_door" if kind == "fossil_lab" else "pkmnmansion_ext_locked" if kind == "mansion" else ("cave1_door1" if kind == "regi" else "stairs_down2")
        var entries := 0
        for pos in record.exterior:
            var tile = generator.tiles_to_add.get(pos)
            if tile != null and entry_name in [tile.name,tile.name_upper]: entries += 1
        if entries != 1: _error(errors,kind+" surface entry missing or duplicated")
        if kind == "mine":
            var actors := 0
            for actor in generator.interior_pokemon:
                if actor.get("name","") != "dusclops": continue
                actors += 1
                if actor.get("level",0) != 44 or not actor.get("aggressive",false): _error(errors,"Mine guardian rule mismatch")
                if actor.get("area_index",-1) not in [96,97] or not layers.get(actor.get("area_index",-1),{}).has(actor.get("position")):
                    _error(errors,"Mine guardian floor missing")
            if actors < 4 or actors > 8: _error(errors,"Mine guardian population missing")
    for kind in counts:
        if counts[kind] != 1: errors.append("Expected one %s, found %d" % [kind,counts[kind]])
    return {"ok":errors.is_empty(),"errors":errors,"landmarks":counts,"biomes":biomes.keys()}

static func _error(errors: Array[String], message: String) -> void:
    if not errors.has(message): errors.append(message)

static func _check_rooms(kind: String, layers: Dictionary, at: Vector2i, errors: Array[String]) -> void:
    if kind == "fossil_lab":
        var room: Dictionary = layers.get(100, {})
        if room.is_empty(): _error(errors, "Fossil lab interior missing")
        return
    var expected := [90] if kind == "regi" else (range(95,102) if kind == "mansion" else range(95,100))
    for li in expected:
        if not layers.has(li) or layers[li].is_empty(): _error(errors,kind+" floor missing")
    var bosses := {};var rewards := 0;var switches := 0;var stairs := 0
    for li in layers:
        var layer: Dictionary = layers[li]
        if kind == "mansion" and li >= 96 and not layer.is_empty():
            var lo := Vector2i(2147483647,2147483647);var hi := -lo
            for pos in layer:
                lo = Vector2i(mini(lo.x,pos.x),mini(lo.y,pos.y))
                hi = Vector2i(maxi(hi.x,pos.x),maxi(hi.y,pos.y))
            var expected_count := ((hi.x-lo.x)/16+1)*((hi.y-lo.y)/16+1)
            if layer.size() != expected_count: _error(errors,"Mansion floor has holes")
        for pos in layer:
            var tile: SourceTile = layer[pos]
            if tile.name_upper in ["mewtwo_overworld","volcarona"]:
                bosses[Vector3i(tile.position.x,tile.position.y,li)] = true
            if not tile.has_item.is_empty():
                rewards += 1
                var valid := tile.has_item == "ultra ball" and tile.has_item_amount == (1 if kind == "mansion" else 2)
                if kind == "mine" and tile.has_item == "ancientpowder" and tile.has_item_amount in [2,3,4]: valid = true
                if not valid: _error(errors,kind+" reward rule mismatch")
            if "stairs" in tile.name_upper:
                stairs += 1
                if "exit" in tile.name_upper:
                    if kind == "mine" and pos != at: _error(errors,"Mine exit does not match surface entry")
                else:
                    var target: int = li+1 if "up" in tile.name_upper else li-1
                    if not layers.has(target) or not layers[target].has(pos): _error(errors,kind+" stair destination missing")
            if tile.name == "pkmnmansion_statue1" and not tile.door_tiles.is_empty():
                switches += 1
                for gate in tile.door_tiles:
                    var target = layers.get(li-1,{}).get(gate)
                    if target == null or not ("__on" in target.name or "__off" in target.name): _error(errors,"Mansion switch gate missing")
    if kind == "regi":
        if layers.get(90,{}).size() != 960: _error(errors,"Regi chamber incomplete")
        var rows := SourceLayoutData.rows("GenIsland1","generateRegiDungeon",1)
        for y in range(rows.size()):
            for x in range(rows[y].size()):
                if rows[y][x] == null: continue
                var tile = layers.get(90,{}).get(at+Vector2i(-288+x*16,272-y*16))
                if tile == null or tile.name != rows[y][x]: _error(errors,"Regi chamber source layout mismatch")
        var pedestals := 0
        for tile in layers.get(90,{}).values():
            if tile.name == "cave1_regipedistal1":
                pedestals += 1
                if tile.item_snapshot() != {"REGISTEEL":1,"REGICE":1,"REGIROCK":1,"REGIELEKI":1,"REGIDRAGO":1}: _error(errors,"Regi pedestal recipes incomplete")
        if pedestals != 1: _error(errors,"Regi pedestal missing")
    else:
        if bosses.size() != 1: _error(errors,kind+" boss missing or duplicated")
        if rewards == 0 or stairs == 0: _error(errors,kind+" rewards or stairs missing")
        if kind == "mansion" and switches == 0: _error(errors,"Mansion switches missing")
    if kind == "mine": _check_mine_paths(layers,errors)

static func _walkable(tile) -> bool:
    return tile != null and (not tile.is_solid or "stairs" in tile.name_upper)

static func _check_mine_paths(layers: Dictionary, errors: Array[String]) -> void:
    var seen := {};var queue: Array[Vector3i] = []
    for tile in layers.get(99,{}).values():
        if "exit" in tile.name_upper:
            var key := Vector3i(tile.position.x,tile.position.y,99)
            seen[key] = true;queue.append(key)
    if queue.is_empty(): _error(errors,"Mine surface exit missing");return
    var index := 0
    while index < queue.size():
        var node := queue[index];index += 1
        var pos := Vector2i(node.x,node.y);var layer: Dictionary = layers[node.z]
        for offset in STEPS:
            var next := Vector3i(pos.x+offset.x,pos.y+offset.y,node.z)
            if not seen.has(next) and _walkable(layer.get(pos+offset)):
                seen[next] = true;queue.append(next)
        var tile: SourceTile = layer[pos]
        if "stairs" in tile.name_upper and "exit" not in tile.name_upper:
            var target := node.z+1 if "up" in tile.name_upper else node.z-1
            var next := Vector3i(pos.x,pos.y,target)
            if not seen.has(next) and _walkable(layers.get(target,{}).get(pos)):
                seen[next] = true;queue.append(next)
    for li in layers:
        for tile in layers[li].values():
            var pos: Vector2i = tile.position
            if "stairs" in tile.name_upper and not seen.has(Vector3i(pos.x,pos.y,li)): _error(errors,"Mine stairs unreachable")
            if not tile.has_item.is_empty() or tile.name_upper == "volcarona":
                var reachable := false
                for offset in STEPS:
                    if seen.has(Vector3i(pos.x+offset.x,pos.y+offset.y,li)): reachable = true
                if not reachable: _error(errors,"Mine reward or boss unreachable")
