class_name SourceForestGenerator
extends RefCounted

const MATES := {
    "nidoqueen": "nidoking", "nidoking": "nidoqueen",
    "charizard": "charizard", "venusaur": "venusaur",
    "meganium": "meganium", "nidorina": "nidorino",
    "nidorino": "nidorina"
}
const MATES_2 := {"tauros": "miltank", "miltank": "tauros"}

static func generate(
        start_location: Vector2i,
        end_location: Vector2i,
        maze_random: SourceJavaRandom,
        biome_random: SourceJavaRandom
    ) -> Dictionary:
    var square_size := 96
    var width := int(float(end_location.x - start_location.x) / float(square_size)) * 2
    var height := int(float(end_location.y - start_location.y) / float(square_size)) * 2
    # The original constructor passes these locals in this order, despite the
    # Maze_Algo1 parameter names being complexity then density.
    var density := 0.1
    var complexity := 0.9
    var nodes := SourceMaze.maze_algo1(width, height, density, complexity, square_size, maze_random)
    var tiles: Dictionary = {}
    for node: Dictionary in SourceJavaHashOrder.values(nodes):
        var square: Array[SourceTile]
        if String(node.get("type", "")) == "platform1":
            square = get_tile_square_platform(node, start_location, maze_random)
        else:
            square = get_tile_square(node, start_location, maze_random)
        for tile in square:
            tiles[tile.position] = tile
    var spawned := apply_forest_biome(tiles, start_location, end_location, biome_random)
    return {"tiles": tiles, "pokemon": spawned}

static func flip_format(format: Array) -> void:
    var i := 0
    for sub: Array in format:
        var j := 0
        for _tile_name: String in sub:
            if i >= 5 - j:
                break
            var temp: Variant = format[i][j]
            format[i][j] = format[5 - j][5 - i]
            format[5 - j][5 - i] = temp
            j += 1
        i += 1

static func gen_tiles(
        format: Array,
        offset_x: int,
        offset_y: int,
        random: SourceJavaRandom,
        color := false
    ) -> Array[SourceTile]:
    var tiles: Array[SourceTile] = []
    var i := 5
    for sub: Array in format:
        var j := 0
        for raw_name: String in sub:
            var tile_name := raw_name
            if tile_name == "either":
                tile_name = ["solid", ""][random.next_int(2)]
            if tile_name != "":
                tiles.append(SourceTile.new(tile_name, Vector2i(j * 16 + offset_x, i * 16 + offset_y), "", color))
            j += 1
        i -= 1
    return tiles

# Direct port of GenForest2.getTileSquare. The two alternative templates and
# every random draw are preserved in Java order.
static func get_tile_square(node: Dictionary, start_location: Vector2i, random: SourceJavaRandom, color := false) -> Array[SourceTile]:
    var offset_x := int(node["square_size"]) * int(node["x"]) + start_location.x
    var offset_y := int(node["square_size"]) * int(node["y"]) + start_location.y
    var squares: Array = []
    var format: Array
    # Route.java creates and mutates this unused local array. Preserve the
    # otherwise invisible draw because it advances java.util.Random.
    random.next_int(6)
    var left_open := bool(node["left_open"])
    var down_open := bool(node["down_open"])
    if not left_open and not down_open:
        format = [
            ["solid", "solid", "", "", "either", "either"],
            ["solid", "solid", "solid", "", "", "either"],
            ["solid", "solid", "solid", "solid", "", ""],
            ["solid", "solid", "solid", "solid", "solid", ""],
            ["solid", "solid", "solid", "solid", "solid", "solid"],
            ["solid", "solid", "solid", "solid", "solid", "solid"]
        ]
        squares.append(gen_tiles(format, offset_x, offset_y, random, color))
        format = [
            ["solid", "solid", "", "", "solid", "solid"],
            ["solid", "solid", "", "", "solid", "solid"],
            ["solid", "solid", "either", "", "", ""],
            ["solid", "solid", "either", "either", "", ""],
            ["solid", "solid", "solid", "solid", "solid", "solid"],
            ["solid", "solid", "solid", "solid", "solid", "solid"]
        ]
        squares.append(gen_tiles(format, offset_x, offset_y, random, color))
    elif left_open != down_open:
        format = [
            ["either", "either", "", "", "either", "either"],
            ["", "", "", "", "", ""], ["", "", "", "", "", ""],
            ["", "either", "", "either", "", ""],
            ["solid", "solid", "solid", "solid", "solid", "solid"],
            ["solid", "solid", "solid", "solid", "solid", "solid"]
        ]
        if down_open:
            flip_format(format)
            _maybe_add_ledge(format, random, true)
        squares.append(gen_tiles(format, offset_x, offset_y, random, color))
        format = [
            ["", "", "", "", "solid", "solid"],
            ["", "", "", "solid", "solid", "solid"],
            ["", "", "", "", "", ""], ["", "", "", "", "", ""],
            ["solid", "solid", "solid", "solid", "solid", "solid"],
            ["solid", "solid", "solid", "solid", "solid", "solid"]
        ]
        if down_open:
            flip_format(format)
            _maybe_add_ledge(format, random, false)
        squares.append(gen_tiles(format, offset_x, offset_y, random, color))
    else:
        format = [
            ["", "", "", "", "solid", "solid"],
            ["", "", "", "either", "solid", "solid"],
            ["", "", "", "", "either", ""],
            ["", "either", "", "", "", ""],
            ["solid", "solid", "either", "", "", ""],
            ["solid", "solid", "", "", "", ""]
        ]
        squares.append(gen_tiles(format, offset_x, offset_y, random, color))
        format = [
            ["", "", "", "", "", ""], ["", "", "", "", "", ""],
            ["", "", "", "", "", ""], ["", "", "", "", "", ""],
            ["solid", "solid", "", "", "", ""],
            ["solid", "solid", "", "", "", ""]
        ]
        squares.append(gen_tiles(format, offset_x, offset_y, random, color))
    return squares[random.next_int(squares.size())]

static func _maybe_add_ledge(format: Array, random: SourceJavaRandom, clear_vertical: bool) -> void:
    if random.next_int(3) != 1:
        return
    var row_index := random.next_int(format.size() - 2) + 1
    var row: Array = format[row_index]
    var on_ground := false
    var ledge_indices: Array[int] = []
    for i in range(row.size()):
        if row[i] != "solid":
            on_ground = true
            ledge_indices.append(i)
        elif on_ground:
            break
    var ramp_index := ledge_indices[random.next_int(ledge_indices.size())]
    for index in ledge_indices:
        row[index] = "ledge_grass_down"
        if index == ramp_index:
            row[index] = "ledge_grass_ramp"
            if clear_vertical:
                format[row_index - 1][index] = ""
                format[row_index + 1][index] = ""

# Direct port of GenForest2.getTileSquarePlatform1. These templates are used
# by platform nodes and remain available even though ordinary maze nodes start
# with an empty type.
static func get_tile_square_platform(node: Dictionary, start_location: Vector2i, random: SourceJavaRandom) -> Array[SourceTile]:
    var offset_x := int(node["square_size"]) * int(node["x"]) + start_location.x
    var offset_y := int(node["square_size"]) * int(node["y"]) + start_location.y
    var temp := ["bush1", "tree_small1"]
    var rs := [temp[random.next_int(temp.size())], "ground1", "ground1"]
    var left_open := bool(node["left_open"])
    var down_open := bool(node["down_open"])
    var ramp := String(node.get("ramp", ""))
    var format: Array
    if not left_open and not down_open:
        if ramp == "down":
            format = [
                ["tree_large1_noSprite", "tree_large1_noSprite", "ledge_grass_left", "", "", "ledge_grass_right"],
                ["tree_large1", "tree_large1_noSprite", "ledge_grass_left", "", "", "ledge_grass_right"],
                ["tree_large1_noSprite", "tree_large1_noSprite", "ledge_grass_left", "ledge_grass_inside_tl", "ledge_grass_ramp", "ledge1_corner_br"],
                ["tree_large1", "tree_large1_noSprite", "ledge1_corner_bl", "ledge1_corner_br", "", ""],
                _six("tree_large1_noSprite"), _tree_bottom()
            ]
        else:
            format = [
                ["tree_large1_noSprite", "tree_large1_noSprite", "", "ledge2_corner_tl", "ledge_grass_safari_up", "ledge_grass_safari_up"],
                ["tree_large1", "tree_large1_noSprite", "", "ledge_grass_left", "", ""],
                ["tree_large1_noSprite", "tree_large1_noSprite", "", "ledge1_corner_bl", "ledge_grass_ramp", "ledge_grass_inside_tr"],
                ["tree_large1", "tree_large1_noSprite", "", "", "", "ledge1_corner_bl"],
                _six("tree_large1_noSprite"), _tree_bottom()
            ]
    elif left_open and not down_open:
        if ramp == "down":
            format = [[rs[random.next_int(3)], rs[random.next_int(3)], rs[random.next_int(3)], rs[random.next_int(3)], rs[random.next_int(3)], rs[random.next_int(3)]], ["ledge_grass_left", "", "", "", "", "ledge_grass_right"], ["ledge1_corner_bl", "ledge_grass_down", "ledge_grass_down", "ledge_grass_ramp", "ledge_grass_down", "ledge1_corner_br"], ["", "", "", "", "", ""], _six("tree_large1_noSprite"), _tree_bottom()]
        elif ramp == "left":
            format = [["", "", "", "ledge2_corner_tl", "ledge_grass_safari_up", "ledge_grass_safari_up"], ["", "", "", "ledge_grass_left", "", ""], ["", "", "", "ledge1_corner_bl", "ledge_grass_ramp", "ledge_grass_inside_tr"], ["", "", "", "", "", "ledge1_corner_bl"], _six("tree_large1_noSprite"), _tree_bottom()]
        else:
            format = [["ledge_grass_safari_up", "ledge_grass_safari_up", "ledge_grass_safari_up", "ledge2_corner_tr", "", ""], ["", "", "", "ledge_grass_right", "", ""], ["", "ledge_grass_inside_tl", "ledge_grass_ramp", "ledge1_corner_br", "", ""], ["ledge_grass_down", "ledge1_corner_br", "", "", "", ""], _six("tree_large1_noSprite"), _tree_bottom()]
    elif not left_open and down_open:
        if ramp == "down":
            format = [["tree_large1_noSprite", "tree_large1_noSprite", "ledge_grass_left", "", "", "ledge_grass_right"], ["tree_large1", "tree_large1_noSprite", "ledge_grass_left", "", "", "ledge_grass_right"], ["tree_large1_noSprite", "tree_large1_noSprite", "ledge1_corner_bl", "ledge_grass_ramp", "ledge_grass_down", "ledge1_corner_br"], ["tree_large1", "tree_large1_noSprite", "", "", "", ""], ["tree_large1_noSprite", "tree_large1_noSprite", "", "", "", ""], ["tree_large1", "tree_large1_noSprite", "", "", "", ""]]
        elif ramp == "left":
            format = [["tree_large1_noSprite", "tree_large1_noSprite", "", "ledge2_corner_tl", "ledge_grass_safari_up", "ledge_grass_safari_up"], ["tree_large1", "tree_large1_noSprite", "", "ledge_grass_left", "", ""], ["tree_large1_noSprite", "tree_large1_noSprite", "", "ledge1_corner_bl", "ledge_grass_ramp", "ledge_grass_inside_tr"], ["tree_large1", "tree_large1_noSprite", "", "", "", "ledge1_corner_bl"], ["tree_large1_noSprite", "tree_large1_noSprite", "", "", "", ""], ["tree_large1", "tree_large1_noSprite", "", "", "", ""]]
        else:
            format = [["tree_large1_noSprite", "tree_large1_noSprite", "", "", "", ""], ["tree_large1", "tree_large1_noSprite", "ledge_grass_safari_up", "ledge_grass_safari_up", "ledge_grass_safari_up", "ledge2_corner_tr"], ["tree_large1_noSprite", "tree_large1_noSprite", "", "", "", "ledge_grass_right"], ["tree_large1", "tree_large1_noSprite", "", "ledge_grass_inside_tl", "ledge_grass_ramp", "ledge1_corner_br"], ["tree_large1_noSprite", "tree_large1_noSprite", "", "ledge_grass_right", "", ""], ["tree_large1", "tree_large1_noSprite", "", "ledge_grass_safari_up", "ledge_grass_safari_up", "ledge2_corner_tr"]]
    elif ramp == "down":
        format = [["", "", "ledge_grass_left", "", "", "ledge_grass_right"], ["", "", "ledge1_corner_bl", "ledge_grass_ramp", "ledge_grass_down", "ledge1_corner_br"], ["", "", "", "", rs[random.next_int(3)], ""], ["", rs[random.next_int(3)], "", "", "", ""], ["tree_large1_noSprite", "tree_large1_noSprite", rs[random.next_int(3)], "", "", ""], ["tree_large1", "tree_large1_noSprite", "", "", "", ""]]
    elif ramp == "up":
        format = [["", "", "", "", "", ""], ["", "ledge2_corner_tl", "ledge_grass_safari_up", "ledge_grass_safari_up", "ledge_grass_safari_up", "ledge2_corner_tr"], ["", "ledge_grass_left", "", "", "", "ledge_grass_right"], ["", "ledge1_corner_bl", "ledge_grass_ramp", "ledge_grass_inside_tr", "", "ledge_grass_right"], ["", "", "", "ledge_grass_left", "", "ledge_grass_right"], ["", "", "ledge2_corner_tl", "ledge_grass_safari_up", "", "ledge_grass_right"]]
    elif ramp == "left":
        format = [["", "", "ledge_grass_left", "", "", ""], ["", "", "ledge_grass_left", "", "", ""], ["", "", "ledge1_corner_br", "ledge_grass_ramp", "ledge_grass_inside_tr", ""], ["", "", "", "", "ledge_grass_left", ""], ["tree_large1_noSprite", "tree_large1_noSprite", "", "", "ledge_grass_left", ""], ["tree_large1", "tree_large1_noSprite", "", "", "ledge1_corner_br", "ledge_grass_down"]]
        if down_open:
            flip_format(format)
    else:
        format = [["", "", "", "ledge_grass_right", "", ""], ["", "", "", "ledge_grass_right", "", ""], ["", "ledge_grass_inside_tl", "ledge_grass_ramp", "ledge1_corner_br", "", ""], ["", "ledge_grass_right", "", "", "", ""], ["", "ledge_grass_right", "", "", "tree_large1_noSprite", "tree_large1_noSprite"], ["ledge_grass_down", "ledge1_corner_br", "", "", "tree_large1", "tree_large1_noSprite"]]
        if down_open:
            flip_format(format)
    var squares := [gen_tiles(format, offset_x, offset_y, random)]
    return squares[random.next_int(squares.size())]

static func _six(value: String) -> Array:
    return [value, value, value, value, value, value]

static func _tree_bottom() -> Array:
    return ["tree_large1", "tree_large1_noSprite", "tree_large1", "tree_large1_noSprite", "tree_large1", "tree_large1_noSprite"]

# Direct port of GenForest2.ApplyForestBiome.step. The Java class exposes
# additional pond/grass helpers, but its generation step performs this exact
# solid-to-tree/bush conversion.
static func apply_forest_biome(
        tiles: Dictionary,
        bottom_left: Vector2i,
        top_right: Vector2i,
        random: SourceJavaRandom,
        color := false
    ) -> Array:
    var spawned_pokemon: Array = []
    for x in range(bottom_left.x, top_right.x + 192, 16):
        for y in range(bottom_left.y, top_right.y + 192, 16):
            var position := Vector2i(x, y)
            var tile := tiles.get(position) as SourceTile
            if tile == null or tile.name != "solid":
                continue
            var right := tiles.get(position + Vector2i(16, 0)) as SourceTile
            var up := tiles.get(position + Vector2i(0, 16)) as SourceTile
            var up_right := tiles.get(position + Vector2i(16, 16)) as SourceTile
            if absi(position.x - bottom_left.x) % 32 == 0 and absi(position.y - bottom_left.y) % 32 == 0 and right != null and up != null and up_right != null and right.name == "solid" and up.name == "solid" and up_right.name == "solid":
                tiles[position] = SourceTile.new("tree_large1", position, "", color)
                tiles[position + Vector2i(16, 0)] = SourceTile.new("tree_large1_noSprite", position + Vector2i(16, 0))
                tiles[position + Vector2i(0, 16)] = SourceTile.new("tree_large1_noSprite", position + Vector2i(0, 16))
                tiles[position + Vector2i(16, 16)] = SourceTile.new("tree_large1_noSprite", position + Vector2i(16, 16))
                continue
            var route := SourceRoute.new("", 11)
            var pokemon := ["pineco", "aipom", "kakuna", "metapod", "spinarak", "heracross", "ledyba", "hoothoot", "zubat", "pidgey", "spearow", "forretress", "applin"]
            var random_value := random.next_int(3)
            if random_value == 2:
                random_value = random.next_int(pokemon.size())
                var stored := {"name": pokemon[random_value], "level": 10 + random.next_int(4)}
                route.stored_pokemon.append(stored)
                spawned_pokemon.append({"position": position, "pokemon": stored})
            tiles[position] = SourceTile.new("bush1", position, "", color, route)
    return spawned_pokemon

static func add_pond(tiles: Dictionary, random: SourceJavaRandom) -> void:
    var keys := SourceJavaHashOrder.keys(tiles)
    if keys.is_empty():
        return
    var bottom_left := Vector2i(keys[random.next_int(keys.size())])
    var top_right := bottom_left + Vector2i(random.next_int(12) * 16 + 32, random.next_int(12) * 16 + 32)
    var pond: Array[Vector2i] = []
    for x in range(bottom_left.x, top_right.x, 16):
        for y in range(bottom_left.y, top_right.y, 16):
            var position := Vector2i(x, y)
            var surrounded := 0
            for direction in [Vector2i(16, 0), Vector2i(-16, 0), Vector2i(0, 16), Vector2i(0, -16)]:
                var neighbour := tiles.get(position + direction) as SourceTile
                if neighbour != null and neighbour.name == "solid":
                    surrounded += 1
            var tile := tiles.get(position) as SourceTile
            if tile != null and surrounded > 1 and tile.name == "solid":
                pond.append(position)
    for position in pond:
        var right := pond.has(position + Vector2i(16, 0))
        var left := pond.has(position + Vector2i(-16, 0))
        var up := pond.has(position + Vector2i(0, 16))
        var down := pond.has(position + Vector2i(0, -16))
        var tile_name := ""
        if right and not left and up and down:
            tile_name = "water1_ledge1_left"
        elif not right and left and up and down:
            tile_name = "water1_ledge1_right"
        elif right and left and not up and down:
            tile_name = "water1_ledge1_top"
        elif right and not left and not up and down:
            tile_name = "water1_ledge1_tl"
        elif not right and left and not up and down:
            tile_name = "water1_ledge1_tr"
        elif right and not left and up and not down:
            tile_name = "water1_ledge1_left"
        elif not right and left and up and not down:
            tile_name = "water1_ledge1_right"
        elif int(right) + int(left) + int(up) + int(down) > 1:
            tile_name = "water1"
        if tile_name != "":
            tiles[position] = SourceTile.new(tile_name, position)

static func fill_all_empty_tiles(tiles: Dictionary, bottom_left: Vector2i, top_right: Vector2i, random: SourceJavaRandom) -> void:
    var random_tiles := ["ground3", "ground1", "ground3", "ground1", "ground3", "ground1", "ground3", "ground1", "flower1"]
    for x in range(bottom_left.x, top_right.x, 16):
        for y in range(bottom_left.y, top_right.y, 16):
            var position := Vector2i(x, y)
            var tile_name: String = random_tiles[random.next_int(random_tiles.size())]
            if not tiles.has(position) and tile_name != "":
                tiles[position] = SourceTile.new(tile_name, position)

static func plant_grass(tiles: Dictionary, bottom_left: Vector2i, top_right: Vector2i, random: SourceJavaRandom, color := false) -> void:
    var start_position := Vector2i(2147483647, 2147483647)
    var iteration := 0
    while start_position.x == 2147483647 and iteration < 20 and top_right.x - bottom_left.x - 64 != 0:
        iteration += 1
        var random_x_bound := absi(top_right.x - bottom_left.x - 64) + bottom_left.x
        var random_x := random.next_int(maxi(1, random_x_bound)) / 16 * 16
        var random_y_bound := absi(top_right.y - bottom_left.y - 64) + bottom_left.y
        var random_y := random.next_int(maxi(1, random_y_bound)) / 16 * 16
        var candidate := Vector2i(random_x, random_y)
        if tiles.has(candidate) or tiles.has(candidate + Vector2i(16, 0)) or tiles.has(candidate + Vector2i(0, 16)) or tiles.has(candidate + Vector2i(16, 16)):
            continue
        start_position = candidate
    if start_position.x == 2147483647:
        return
    var tile_name := "grass2" if color else "grass1"
    var route := SourceRoute.new("forest1", 22)
    for offset in [Vector2i.ZERO, Vector2i(16, 0), Vector2i(0, 16), Vector2i(16, 16)]:
        tiles[start_position + offset] = SourceTile.new(tile_name, start_position + offset, "", color, route)
    var current := start_position
    var patches := random.next_int(10) + 2
    for _index in range(patches):
        var next_positions: Array[Vector2i] = []
        if not tiles.has(current + Vector2i(-16, 0)) and not tiles.has(current + Vector2i(-16, 16)):
            next_positions.append(current + Vector2i(-16, 0))
        if not tiles.has(current + Vector2i(32, 0)) and not tiles.has(current + Vector2i(32, 16)):
            next_positions.append(current + Vector2i(16, 0))
        if not tiles.has(current + Vector2i(0, 32)) and not tiles.has(current + Vector2i(16, 32)):
            next_positions.append(current + Vector2i(0, 16))
        if not tiles.has(current + Vector2i(0, -16)) and not tiles.has(current + Vector2i(16, -16)):
            next_positions.append(current + Vector2i(0, -16))
        if next_positions.is_empty():
            break
        var new_position := next_positions[random.next_int(next_positions.size())]
        tiles[new_position] = SourceTile.new(tile_name, new_position)
        for offset in [Vector2i(16, 0), Vector2i(0, 16), Vector2i(16, 16)]:
            tiles[new_position + offset] = SourceTile.new(tile_name, new_position + offset, "", color, route)
        current = new_position

static func add_platform(
        tiles_to_add: Array,
        free_positions: Array,
        start_location: Vector2i,
        end_location: Vector2i,
        random: SourceJavaRandom
    ) -> void:
    var x := random.next_int(end_location.x - start_location.x) + start_location.x
    var y := random.next_int(end_location.y - start_location.y) + start_location.y
    var width := int(0.5 * float(end_location.x - start_location.x) + float(random.next_int(10) + 1) / 10.0 * (1.0 / 3.0) * float(end_location.x - start_location.x) - (1.0 / 6.0) * float(end_location.x - start_location.x))
    var height := int(0.5 * float(end_location.y - start_location.y) + float(random.next_int(10) + 1) / 10.0 * (1.0 / 3.0) * float(end_location.y - start_location.y) - (1.0 / 6.0) * float(end_location.y - start_location.y))
    var bottom_left := Vector2i(x - width / 2, y - height / 2)
    var top_right := Vector2i(x + width / 2, y + height / 2)
    var platform: Array[Vector2i] = []
    for raw_position in free_positions:
        var position := Vector2i(raw_position)
        if position.x >= bottom_left.x and position.x <= top_right.x and position.y >= bottom_left.y and position.y <= top_right.y:
            platform.append(position)
    if platform.is_empty():
        return
    var bottom_ledges: Array[Vector2i] = []
    for position in platform:
        var right := platform.has(position + Vector2i(16, 0))
        var left := platform.has(position + Vector2i(-16, 0))
        var up := platform.has(position + Vector2i(0, 16))
        var down := platform.has(position + Vector2i(0, -16))
        var tile_name := "ground1"
        if right and not left and up and down: tile_name = "ledge_grass_left"
        elif not right and left and up and down: tile_name = "ledge_grass_right"
        elif right and left and not up and down: tile_name = "ledge_grass_safari_up"
        elif right and left and up and not down:
            tile_name = "ledge_grass_down"
            bottom_ledges.append(position)
        elif right and not left and up and not down: tile_name = "ledge1_corner_bl"
        elif not right and left and up and not down: tile_name = "ledge1_corner_br"
        elif right and not left and not up and down: tile_name = "ledge2_corner_tl"
        elif not right and left and not up and down: tile_name = "ledge2_corner_tr"
        elif not right and not left and not up and not down: tile_name = "rock1"
        tiles_to_add.append(SourceTile.new(tile_name, position))
        free_positions.erase(position)
    if not bottom_ledges.is_empty():
        tiles_to_add.append(SourceTile.new("ledge_grass_ramp", bottom_ledges[random.next_int(bottom_ledges.size())]))
        if random.next_int(2) == 1:
            tiles_to_add.append(SourceTile.new("ledge_grass_ramp", bottom_ledges[random.next_int(bottom_ledges.size())]))
