extends RefCounted
## The solid shapes of a block of tiles, as a TileMapLayer made them for the
## physics engine: the cells' squares merged into one outline (holes where
## the block encloses open cells) and cut into convex pieces by the same
## polypartition code (Geometry2D.decompose_polygon_in_convex). One square
## per tile instead would put a corner at every seam of a flat wall, and the
## player, sliding flush along it, caught on them.

## Convex pieces (counter-clockwise, world pixels) covering `cells` (a set of
## Vector2i), cells `size` pixels wide.
static func pieces(cells: Dictionary, size: int) -> Array[PackedVector2Array]:
    var out: Array[PackedVector2Array] = []
    var outers: Array[PackedVector2Array] = []
    var holes: Array[PackedVector2Array] = []
    for loop in _trace(cells, size):
        # polypartition's orientation: outlines counter-clockwise, holes
        # clockwise (by its own area sign).
        if _area(loop) > 0.0: outers.append(loop)
        else: holes.append(loop)
    for outer in outers:
        var inside: Array[PackedVector2Array] = []
        for hole in holes:
            if _contains(outer, hole): inside.append(hole)
        var simple := _remove_holes(outer, inside) if not inside.is_empty() else outer
        for piece: PackedVector2Array in Geometry2D.decompose_polygon_in_convex(simple):
            if Geometry2D.is_polygon_clockwise(piece): piece.reverse()
            out.append(piece)
    return out

## Outline loops of the union of the cells, collinear points dropped. Two
## cells meeting at one corner only stay two outlines.
static func _trace(cells: Dictionary, size: int) -> Array[PackedVector2Array]:
    # Directed edges, solid on the right (screen coordinates): outlines run
    # one way, holes the other.
    var next := {}
    for c: Vector2i in cells:
        if not cells.has(c + Vector2i.UP): _edge(next, Vector2i(c.x, c.y), Vector2i(c.x + 1, c.y))
        if not cells.has(c + Vector2i.RIGHT): _edge(next, Vector2i(c.x + 1, c.y), Vector2i(c.x + 1, c.y + 1))
        if not cells.has(c + Vector2i.DOWN): _edge(next, Vector2i(c.x + 1, c.y + 1), Vector2i(c.x, c.y + 1))
        if not cells.has(c + Vector2i.LEFT): _edge(next, Vector2i(c.x, c.y + 1), Vector2i(c.x, c.y))
    var loops: Array[PackedVector2Array] = []
    while not next.is_empty():
        var start: Vector2i = next.keys()[0]
        var points: Array[Vector2i] = []
        var at := start
        var heading := Vector2i.ZERO
        while true:
            var options: Array = next[at]
            var pick := 0
            if options.size() > 1 and heading != Vector2i.ZERO:
                # A pinch (two cells touching at a corner only): keep to the
                # cell just walked along, turning right.
                var right := Vector2i(-heading.y, heading.x)
                for i in options.size():
                    if options[i] - at == right: pick = i
            var to: Vector2i = options[pick]
            options.remove_at(pick)
            if options.is_empty(): next.erase(at)
            points.append(at)
            heading = to - at
            at = to
            if at == start: break
        var loop := PackedVector2Array()
        var n := points.size()
        for i in n:
            var a := points[(i + n - 1) % n]
            var b := points[i]
            var c := points[(i + 1) % n]
            if (b - a).sign() != (c - b).sign(): loop.append(Vector2(b * size))
        loops.append(loop)
    return loops

static func _edge(next: Dictionary, from: Vector2i, to: Vector2i) -> void:
    var options: Array = next.get_or_add(from, [])
    options.append(to)

## Twice the signed area, as polypartition measures orientation (> 0 is its
## counter-clockwise).
static func _area(p: PackedVector2Array) -> float:
    var area := 0.0
    for i in p.size():
        var a := p[i]
        var b := p[(i + 1) % p.size()]
        area += a.x * b.y - a.y * b.x
    return area

static func _contains(outer: PackedVector2Array, hole: PackedVector2Array) -> bool:
    # A point just inside the hole's first edge (the hole is open space, so
    # its inside is to the left of a clockwise walk... test both sides).
    var a := hole[0]
    var b := hole[1]
    var mid := (a + b) * 0.5
    var normal := (b - a).normalized().orthogonal() * 0.25
    return Geometry2D.is_point_in_polygon(mid + normal, outer) and Geometry2D.is_point_in_polygon(mid - normal, outer)

## TPPLPartition::RemoveHoles: each hole joined to the outline by a cut
## from its rightmost point to the nearest outline point it can see.
static func _remove_holes(outer: PackedVector2Array, holes: Array[PackedVector2Array]) -> PackedVector2Array:
    var poly := outer
    var pending := holes.duplicate()
    while not pending.is_empty():
        # The hole point with the largest x.
        var hole_at := 0
        var point_at := 0
        for h in pending.size():
            for i in pending[h].size():
                if pending[h][i].x > pending[hole_at][point_at].x:
                    hole_at = h
                    point_at = i
        var hole: PackedVector2Array = pending[hole_at]
        var hole_point := hole[point_at]
        var found := -1
        var best := Vector2.ZERO
        for i in poly.size():
            var p := poly[i]
            if p.x <= hole_point.x: continue
            if not _in_cone(poly[(i + poly.size() - 1) % poly.size()], p, poly[(i + 1) % poly.size()], hole_point): continue
            if found >= 0:
                var v1 := (p - hole_point).normalized()
                var v2 := (best - hole_point).normalized()
                if v2.x > v1.x: continue
            var visible := true
            for k in poly.size():
                if _intersects(hole_point, p, poly[k], poly[(k + 1) % poly.size()]):
                    visible = false
                    break
            if visible:
                found = i
                best = p
        if found < 0:
            return outer
        var joined := PackedVector2Array()
        for i in found + 1: joined.append(poly[i])
        for i in hole.size() + 1: joined.append(hole[(i + point_at) % hole.size()])
        for i in range(found, poly.size()): joined.append(poly[i])
        poly = joined
        pending.remove_at(hole_at)
    return poly

static func _is_convex(p1: Vector2, p2: Vector2, p3: Vector2) -> bool:
    return (p3.y - p1.y) * (p2.x - p1.x) - (p3.x - p1.x) * (p2.y - p1.y) > 0.0

static func _in_cone(p1: Vector2, p2: Vector2, p3: Vector2, p: Vector2) -> bool:
    if _is_convex(p1, p2, p3):
        return _is_convex(p1, p2, p) and _is_convex(p2, p3, p)
    return _is_convex(p1, p2, p) or _is_convex(p2, p3, p)

## TPPLPartition::Intersects: do segments p11-p12 and p21-p22 cross (not
## counting shared end points)?
static func _intersects(p11: Vector2, p12: Vector2, p21: Vector2, p22: Vector2) -> bool:
    if p11 == p21 or p11 == p22 or p12 == p21 or p12 == p22: return false
    var v1ort := Vector2(p12.y - p11.y, p11.x - p12.x)
    var v2ort := Vector2(p22.y - p21.y, p21.x - p22.x)
    var dot21 := (p21 - p11).dot(v1ort)
    var dot22 := (p22 - p11).dot(v1ort)
    var dot11 := (p11 - p21).dot(v2ort)
    var dot12 := (p12 - p21).dot(v2ort)
    if dot11 * dot12 > 0.0: return false
    if dot21 * dot22 > 0.0: return false
    return true
