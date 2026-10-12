class_name SourceMaze
extends RefCounted

# Direct cell-coordinate ports of GenForest2.Maze_Algo1/2/3/4.

static func maze_algo2(width: int, height: int, complexity: float, density: float, random: SourceJavaRandom) -> Array:
    width = int(width / 2) * 2 + 2
    height = int(height / 2) * 2 + 2
    # GenForest2 stores both inputs and both products as Java floats before
    # truncating them to integers.  This matters at exact-looking boundaries
    # such as 0.7f * 90: Java rounds that product to 63.0f, while Godot's
    # double-precision 0.7 * 90 lands just below 63 and truncates to 62.
    var complexity_steps := int(SourceLibGDXMath.float32(
        SourceLibGDXMath.float32(complexity)
        * SourceLibGDXMath.float32(float(5 * (height + width)))
    ))
    var density_steps := int(SourceLibGDXMath.float32(
        SourceLibGDXMath.float32(density)
        * SourceLibGDXMath.float32(float(int(height / 2) * int(width / 2)))
    ))
    var maze := _bool_grid(width, height)
    for x in range(width):
        for y in range(height):
            if x == 0 or y == 0 or x == width - 2 or y == height - 2:
                maze[x][y] = true
    for _iteration in range(density_steps):
        var x := random.next_int(int(width / 2)) * 2
        var y := random.next_int(int(height / 2)) * 2
        maze[x][y] = true
        for _step in range(complexity_steps):
            var neighbours := _maze_neighbours(x, y, width, height)
            if neighbours.is_empty():
                continue
            var selected: Vector2i = neighbours[random.next_int(neighbours.size())]
            if maze[selected.x][selected.y]:
                continue
            maze[selected.x][selected.y] = true
            maze[selected.x + int((x - selected.x) / 2)][selected.y + int((y - selected.y) / 2)] = true
            x = selected.x
            y = selected.y
    return maze

static func maze_algo3(width: int, height: int, complexity: float, density: float, random: SourceJavaRandom, start_locations: Array) -> Array:
    width = int(width / 2) * 2 + 2
    height = int(height / 2) * 2 + 2
    var endpoints: Array[Vector2i] = []
    var maze := _bool_grid(width, height)
    for _iteration in range(int(ceil(density))):
        var x: int
        var y: int
        if not start_locations.is_empty():
            var supplied := Vector2i(start_locations.pop_front())
            x = supplied.x
            y = supplied.y
        else:
            x = random.next_int(int(width / 2)) * 2
            y = random.next_int(int(height / 2)) * 2
        x = clampi(x, 0, width - 1)
        y = clampi(y, 0, height - 1)
        maze[x][y] = true
        var placed_one_wall := false
        for _step in range(int(ceil(complexity))):
            var neighbours := _maze_neighbours(x, y, width, height)
            if neighbours.is_empty():
                continue
            var selected: Vector2i = neighbours[random.next_int(neighbours.size())]
            if maze[selected.x][selected.y]:
                continue
            maze[selected.x][selected.y] = true
            maze[selected.x + int((x - selected.x) / 2)][selected.y + int((y - selected.y) / 2)] = true
            x = selected.x
            y = selected.y
            placed_one_wall = true
        if placed_one_wall:
            endpoints.append(Vector2i(x, y))
    start_locations.clear()
    start_locations.append_array(endpoints)
    return maze

static func maze_algo1(width: int, height: int, complexity: float, density: float, square_size: int, random: SourceJavaRandom) -> Dictionary:
    var maze := maze_algo2(width, height, complexity, density, random)
    var nodes := {}
    for x in range(int(maze.size() / 2)):
        for y in range(int(maze[0].size() / 2)):
            nodes[Vector2i(x, y)] = {
                "x": x, "y": y,
                "left_open": not maze[x * 2][y * 2 + 1],
                "down_open": not maze[x * 2 + 1][y * 2],
                "square_size": square_size, "type": "", "ramp": ""
            }
    return nodes

static func maze_algo4(width: int, height: int, complexity_steps: float, density_steps: float, square_size: int, random: SourceJavaRandom) -> Dictionary:
    width = int(width / 2) * 2 + 2
    height = int(height / 2) * 2 + 2
    var maze := _bool_grid(width, height)
    for x in range(width):
        for y in range(height):
            if x == 0 or x == width - 2 or y == 0 or y == height - 2:
                maze[x][y] = true
    for _iteration in range(int(ceil(density_steps))):
        var x := random.next_int(int(width / 2)) * 2
        var y := random.next_int(int(height / 2)) * 2
        maze[x][y] = true
        for _step in range(int(ceil(complexity_steps))):
            var neighbours := _maze_neighbours(x, y, width, height)
            if neighbours.is_empty():
                continue
            var selected: Vector2i = neighbours[random.next_int(neighbours.size())]
            if maze[selected.x][selected.y]:
                continue
            maze[selected.x][selected.y] = true
            maze[selected.x + int((x - selected.x) / 2)][selected.y + int((y - selected.y) / 2)] = true
            x = selected.x
            y = selected.y
    var nodes := {}
    for x in range(int(width / 2)):
        for y in range(int(height / 2)):
            nodes[Vector2i(x, y)] = {
                "x": x, "y": y,
                "left_open": not maze[x * 2][y * 2 + 1],
                "down_open": not maze[x * 2 + 1][y * 2],
                "square_size": square_size, "type": "", "ramp": ""
            }
    return nodes

static func _bool_grid(width: int, height: int) -> Array:
    var result: Array = []
    for _x in range(width):
        var column: Array[bool] = []
        column.resize(height)
        column.fill(false)
        result.append(column)
    return result

static func _maze_neighbours(x: int, y: int, width: int, height: int) -> Array[Vector2i]:
    var neighbours: Array[Vector2i] = []
    if x > 1: neighbours.append(Vector2i(x - 2, y))
    if x < width - 2: neighbours.append(Vector2i(x + 2, y))
    if y > 1: neighbours.append(Vector2i(x, y - 2))
    if y < height - 2: neighbours.append(Vector2i(x, y + 2))
    return neighbours
