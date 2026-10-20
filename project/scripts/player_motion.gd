class_name PlayerMotion
extends RefCounted
## The player's CharacterBody2D.move_and_slide, without the physics engine.
##
## Godot's 2D physics did this game's walking with one 10x10 box against
## tiles and boxes. This is that code (GodotSpace2D::test_body_motion, the
## SAT solver it calls and CharacterBody2D's grounded slide, Godot 4.7)
## ported for those shapes only: the same 0.08 px margin and recovery, the
## same 8-step search for the safe fraction of a move, the same deepest
## contact for the normal, in the same 32-bit float steps (positions here sit
## on whole pixels, where a tie decides which way a corner pushes). The
## player rests and slides exactly where they did, corners included.
## Platforms, one-way shapes and rotation are left out: nothing used them.

const CMP_EPSILON := 0.00001
const SUPPORT_THRESHOLD := 0.99998
const UP := Vector2(0, -1)
const FLOOR_ANGLE_THRESHOLD := 0.01
const MAX_SLIDES := 4
## real_t values, as Godot holds them (32-bit).
static var MARGIN := _f32(0.08)
static var MIN_CONTACT_DEPTH := _f32(_f32(0.08) * 0.05)
static var FLOOR_MAX_ANGLE := _f32(deg_to_rad(45.0))
static var FLOOR_SNAP_LENGTH := 1.0
static var PRECISION := _f32(0.001)

## Rounds to a 32-bit float, as storing into a real_t does.
static func _f32(value: float) -> float:
    return Vector2(value, 0.0).x

## A solid: a convex polygon (a tile's collision polygon, counter-clockwise,
## as ConvexPolygonShape2D gave it) or a rectangle (a RectangleShape2D).
class Solid:
    var rect := false
    var center := Vector2.ZERO
    var half := Vector2.ZERO
    ## World points (the shape's own plus its origin) and the shape's own.
    var points := PackedVector2Array()
    var local := PackedVector2Array()
    var normals := PackedVector2Array()
    var aabb := Rect2()

    static func box(at: Rect2) -> Solid:
        var s := Solid.new()
        s.rect = true
        s.half = at.size * 0.5
        s.center = at.position + s.half
        s.aabb = at
        return s

    static func polygon(shape: PackedVector2Array, origin: Vector2) -> Solid:
        var s := Solid.new()
        var count := shape.size()
        s.local = shape
        s.points.resize(count)
        s.normals.resize(count)
        for i in count:
            s.points[i] = shape[i] + origin
            s.normals[i] = (shape[(i + 1) % count] - shape[i]).orthogonal().normalized()
        var aabb := Rect2(s.points[0], Vector2.ZERO)
        for i in count:
            aabb = aabb.expand(s.points[i])
        s.aabb = aabb
        return s

## A test motion's result (PhysicsServer2D::MotionResult).
class Result:
    var travel := Vector2.ZERO
    var remainder := Vector2.ZERO
    var normal := Vector2.ZERO
    var depth := 0.0
    var safe := 1.0
    var unsafe := 1.0

    func get_angle(up: Vector2) -> float:
        return PlayerMotion._f32(acos(normal.dot(up)))

## The body: a rectangle of these half extents, centred on the position plus
## this offset.
var half := Vector2(5, 5)
var offset := Vector2(0, 3)

# The moving body's state, as CharacterBody2D kept it.
var on_floor := false
var on_wall := false
var on_ceiling := false
var floor_normal := Vector2.ZERO
var wall_normal := Vector2.ZERO
## Every collision of the last move_and_slide (get_slide_collision).
var motion_results: Array[Result] = []

# SAT scratch state.
var _best_depth := 0.0
var _best_axis := Vector2.ZERO
var _contacts := PackedVector2Array()
var _corners: Array[Vector2] = []

func _init() -> void:
    _corners = []
    for i in 4:
        _corners.append(Vector2(((i & 1) * 2 - 1) * half.x, ((i >> 1) * 2 - 1) * half.y))

# --- SAT (godot_collision_solver_2d_sat.cpp) ---------------------------------

## GodotRectangleShape2D::project_range of the body at `origin`.
func _project_body(axis: Vector2, origin: Vector2) -> Vector2:
    var lo := 1e20
    var hi := -1e20
    for corner in _corners:
        var d := axis.dot(origin + corner)
        if d > hi: hi = d
        if d < lo: lo = d
    return Vector2(lo, hi)

static func _project_solid(axis: Vector2, b: Solid) -> Vector2:
    var lo: float
    var hi: float
    if b.rect:
        lo = 1e20
        hi = -1e20
        for i in 4:
            var d := axis.dot(b.center + Vector2(((i & 1) * 2 - 1) * b.half.x, ((i >> 1) * 2 - 1) * b.half.y))
            if d > hi: hi = d
            if d < lo: lo = d
    else:
        lo = axis.dot(b.points[0])
        hi = lo
        for i in range(1, b.points.size()):
            var d := axis.dot(b.points[i])
            if d > hi: hi = d
            if d < lo: lo = d
    return Vector2(lo, hi)

## SeparatorAxisTest2D::test_axis: body A at `origin` (swept by `cast` when
## that is not zero, grown by `margin`) against solid B.
func _test_axis(axis: Vector2, origin: Vector2, cast: Vector2, margin: float, b: Solid) -> bool:
    if is_zero_approx(axis.x) and is_zero_approx(axis.y):
        axis = Vector2(0.0, 1.0)
    var a := _project_body(axis, origin)
    if cast != Vector2.ZERO:
        var moved := _project_body(axis, origin + cast)
        a = Vector2(minf(a.x, moved.x), maxf(a.y, moved.y))
    var bb := _project_solid(axis, b)
    var min_a := a.x
    var max_a := a.y
    var min_b := bb.x
    var max_b := bb.y
    if margin != 0.0:
        min_a = _f32(min_a - margin)
        max_a = _f32(max_a + margin)
    var width := _f32(max_a - min_a) * 0.5
    min_b = _f32(min_b - width)
    max_b = _f32(max_b + width)
    var middle := _f32(min_a + max_a) * 0.5
    var dmin := _f32(min_b - middle)
    var dmax := _f32(max_b - middle)
    if dmin > 0.0 or dmax < 0.0:
        return false
    dmin = absf(dmin)
    if dmax < dmin:
        if dmax < _best_depth:
            _best_depth = dmax
            _best_axis = axis
    elif dmin < _best_depth:
        _best_depth = dmin
        _best_axis = -axis
    return true

## Corner of a box at `centre` (half extents `h`) on the side of `toward`.
static func _corner(centre: Vector2, h: Vector2, toward: Vector2) -> Vector2:
    var local := toward - centre
    return Vector2(-h.x if local.x < 0.0 else h.x, -h.y if local.y < 0.0 else h.y) + centre

## _collision_rectangle_rectangle / _collision_rectangle_convex_polygon: do A
## and B overlap (A grown by `margin`, swept by `cast`)? With `contacts`, the
## contact pairs go to _contacts as the solver gave them to its callback.
func _solve(origin: Vector2, cast: Vector2, margin: float, b: Solid, contacts: bool) -> bool:
    _best_depth = 1e15
    _best_axis = Vector2.ZERO
    if cast != Vector2.ZERO:
        var na := cast.normalized()
        if not _test_axis(na, origin, cast, margin, b): return false
        if not _test_axis(na.orthogonal(), origin, cast, margin, b): return false
    if not _test_axis(Vector2(1, 0), origin, cast, margin, b): return false
    if not _test_axis(Vector2(0, 1), origin, cast, margin, b): return false
    if b.rect:
        if not _test_axis(Vector2(1, 0), origin, cast, margin, b): return false
        if not _test_axis(Vector2(0, 1), origin, cast, margin, b): return false
        if margin != 0.0:
            # get_box_axis: between the nearest corners.
            var axis := (_corner(origin, half, b.center) - _corner(b.center, b.half, origin)).normalized()
            if not _test_axis(axis, origin, cast, margin, b): return false
    else:
        var count := b.points.size()
        for i in count:
            var next := b.points[(i + 1) % count]
            if not _test_axis((next - b.points[i]).normalized().orthogonal(), origin, cast, margin, b): return false
            if margin != 0.0:
                # get_circle_axis: from the vertex to the box's nearest corner.
                var axis := (_corner(origin, half, b.points[i]) - b.points[i]).normalized()
                if not _test_axis(axis, origin, cast, margin, b): return false
    if _best_axis == Vector2.ZERO:
        return false
    if contacts:
        _generate_contacts(origin, margin, b)
    return true

func _generate_contacts(origin: Vector2, margin: float, b: Solid) -> void:
    var axis := _best_axis
    var supports_a := _rect_supports(-axis, origin, half)
    for i in supports_a.size():
        supports_a[i] += -axis * margin
    var supports_b := _rect_supports(axis, b.center, b.half) if b.rect else _polygon_supports(axis, b)
    var normal := axis
    var swap := false
    if supports_a.size() > supports_b.size():
        swap = true
        normal = -normal
        var keep := supports_a
        supports_a = supports_b
        supports_b = keep
    if supports_a.size() == 1 and supports_b.size() == 1:
        _contact(supports_a[0], supports_b[0], swap)
    elif supports_a.size() == 1:
        var closest := Geometry2D.get_closest_point_to_segment_uncapped(supports_a[0], supports_b[0], supports_b[1])
        _contact(supports_a[0], closest, swap)
    else:
        _edge_edge(supports_a, supports_b, normal, swap)

## GodotRectangleShape2D::get_supports, then placed at `centre`.
static func _rect_supports(n: Vector2, centre: Vector2, h: Vector2) -> PackedVector2Array:
    var out := PackedVector2Array()
    n = n.normalized()
    for i in 2:
        var dp: float = n[i]
        if absf(dp) <= SUPPORT_THRESHOLD:
            continue
        var sgn := 1.0 if dp > 0.0 else -1.0
        var a := Vector2.ZERO
        var b := Vector2.ZERO
        a[i] = h[i] * sgn
        a[i ^ 1] = h[i ^ 1]
        b[i] = h[i] * sgn
        b[i ^ 1] = -h[i ^ 1]
        out.append(a + centre)
        out.append(b + centre)
        return out
    out.append(Vector2(-h.x if n.x < 0.0 else h.x, -h.y if n.y < 0.0 else h.y) + centre)
    return out

## GodotConvexPolygonShape2D::get_supports, then placed in the world.
static func _polygon_supports(n: Vector2, b: Solid) -> PackedVector2Array:
    n = n.normalized()
    var out := PackedVector2Array()
    var best := -1
    var d := -1e10
    var count := b.local.size()
    for i in count:
        var ld := n.dot(b.local[i])
        if ld > d:
            best = i
            d = ld
        if b.normals[i].dot(n) > SUPPORT_THRESHOLD:
            out.append(b.points[i])
            out.append(b.points[(i + 1) % count])
            return out
    out.append(b.points[best])
    return out

func _edge_edge(a: PackedVector2Array, b: PackedVector2Array, n: Vector2, swap: bool) -> void:
    var t := n.orthogonal()
    var da := n.dot(a[0])
    var db := n.dot(b[0])
    # Sorted along the edge (insertion sort, stable, as SortArray does for 4).
    var order := [[t.dot(a[0]), true, 0], [t.dot(a[1]), true, 1], [t.dot(b[0]), false, 0], [t.dot(b[1]), false, 1]]
    for i in range(1, 4):
        var item = order[i]
        var j := i - 1
        while j >= 0 and item[0] < order[j][0]:
            order[j + 1] = order[j]
            j -= 1
        order[j + 1] = item
    for i in range(1, 3):
        var p: Vector2
        var q: Vector2
        if order[i][1]:
            p = a[order[i][2]]
            q = p - n * (n.dot(p) - db)
        else:
            q = b[order[i][2]]
            p = q - n * (n.dot(q) - da)
        if n.dot(p) > n.dot(q) - CMP_EPSILON:
            continue
        _contact(p, q, swap)

func _contact(p: Vector2, q: Vector2, swap: bool) -> void:
    if swap:
        _contacts.append(q)
        _contacts.append(p)
    else:
        _contacts.append(p)
        _contacts.append(q)

# --- GodotSpace2D::test_body_motion -------------------------------------------

## Moves the body (at `from`; its box centred on `from` + offset) by `motion`
## through `solids`, as body_test_motion did. Result.normal is zero when
## nothing was hit.
func test_motion(from: Vector2, motion: Vector2, solids: Array, margin: float, recovery_as_collision: bool) -> Result:
    margin = _f32(maxf(margin, 0.0001))
    var min_contact_depth := _f32(margin * 0.05)
    var motion_length := motion.length()
    var body := from
    var recovered := false
    # Step 1: free the body if stuck.
    for attempt in 4:
        _contacts.clear()
        var collided := false
        var origin := body + offset
        var body_aabb := Rect2(origin - half, half * 2.0).grow(margin)
        for s: Solid in solids:
            if not s.aabb.intersects(body_aabb, true): continue
            var before := _contacts.size()
            if _solve(origin, Vector2.ZERO, margin, s, true) and _contacts.size() > before:
                collided = true
        if not collided:
            break
        recovered = true
        var recover := Vector2.ZERO
        for i in range(0, _contacts.size(), 2):
            var a := _contacts[i]
            var b := _contacts[i + 1]
            var n := (a - b).normalized()
            var d := n.dot(b)
            var depth := _f32(n.dot(a + recover) - d)
            if depth > min_contact_depth + CMP_EPSILON:
                recover -= n * _f32(depth - min_contact_depth) * 0.4
        if recover == Vector2.ZERO:
            break
        body += recover
    # Step 2: attempt the motion.
    var safe := 1.0
    var unsafe := 1.0
    var shape_at := body + offset
    var body_box := Rect2(shape_at - half, half * 2.0).grow(margin)
    var motion_box := body_box.merge(Rect2(body_box.position + motion, body_box.size))
    var stuck := false
    for s: Solid in solids:
        if not s.aabb.intersects(motion_box, true): continue
        if not _solve(shape_at, motion, 0.0, s, false): continue
        if _solve(shape_at, Vector2.ZERO, 0.0, s, false):
            stuck = true
            break
        var low := 0.0
        var hi := 1.0
        var coeff := 0.5
        for k in 8:
            var fraction := _f32(low + _f32(_f32(hi - low) * coeff))
            if _solve(shape_at, motion * fraction, 0.0, s, false):
                hi = fraction
                coeff = 0.5 if k == 0 or low > 0.0 else 0.25
            else:
                low = fraction
                coeff = 0.5 if k == 0 or hi < 1.0 else 0.75
        if low < safe:
            safe = low
            unsafe = hi
    if stuck:
        safe = 0.0
        unsafe = 0.0
    var result := Result.new()
    if (recovery_as_collision and recovered) or safe < 1.0:
        # Rest info at the unsafe advance: the deepest contact.
        var at := (body + motion * unsafe) + offset
        var best_len := 0.0
        var best_normal := Vector2.ZERO
        var min_allowed := minf(motion_length, min_contact_depth)
        var rest_box := Rect2(at - half, half * 2.0).grow(margin)
        for s: Solid in solids:
            if not s.aabb.intersects(rest_box, true): continue
            _contacts.clear()
            if not _solve(at, Vector2.ZERO, margin, s, true): continue
            for i in range(0, _contacts.size(), 2):
                var rel := _contacts[i + 1] - _contacts[i]
                var length := rel.length()
                if length < min_allowed or length <= best_len: continue
                best_len = length
                best_normal = rel / length
        if best_len != 0.0:
            result.normal = best_normal
            result.depth = best_len
            result.safe = safe
            result.unsafe = unsafe
            result.travel = safe * motion + (body - from)
            result.remainder = motion - safe * motion
            return result
    result.travel = motion + (body - from)
    return result

## PhysicsBody2D::move_and_collide's result: test_motion, then (cancel
## sliding) the travel put back along the motion unless the body was deep in
## something. The caller moves the body by result.travel.
func move_and_collide(position: Vector2, motion: Vector2, solids: Array, margin: float, cancel_sliding: bool) -> Result:
    var result := test_motion(position, motion, solids, margin, true)
    var collided := result.normal != Vector2.ZERO
    if cancel_sliding:
        var motion_length := motion.length()
        var precision := PRECISION
        if collided:
            precision = _f32(precision + _f32(motion_length * _f32(result.unsafe - result.safe)))
            if result.depth > _f32(margin + precision):
                cancel_sliding = false
        if cancel_sliding:
            var motion_normal := Vector2.ZERO
            if motion_length > CMP_EPSILON:
                motion_normal = motion / motion_length
            var projected := result.travel.dot(motion_normal)
            var recovery := result.travel - motion_normal * projected
            if recovery.length() < _f32(margin + precision):
                result.travel = motion_normal * projected
                result.remainder = motion - result.travel
    return result

func _is_floor(r: Result) -> bool:
    return r.get_angle(UP) <= FLOOR_MAX_ANGLE + FLOOR_ANGLE_THRESHOLD

func _is_ceiling(r: Result) -> bool:
    return r.get_angle(-UP) <= FLOOR_MAX_ANGLE + FLOOR_ANGLE_THRESHOLD

func _set_collision_direction(r: Result) -> void:
    if _is_floor(r):
        on_floor = true
        floor_normal = r.normal
    elif _is_ceiling(r):
        on_ceiling = true
    else:
        on_wall = true
        wall_normal = r.normal

# --- CharacterBody2D::move_and_slide (grounded) --------------------------------

## Returns [new position, new velocity]. `solids` is everything that can be
## touched this step.
func move_and_slide(position: Vector2, velocity: Vector2, delta: float, solids: Array) -> Array:
    motion_results.clear()
    var was_on_floor := on_floor
    on_floor = false
    on_ceiling = false
    on_wall = false
    var motion := velocity * delta
    var motion_slide_up := motion.slide(UP)
    floor_normal = Vector2.ZERO
    # floor_stop_on_slope: no sliding on the first attempt.
    var sliding_enabled := false
    var vel_dir_facing_up := velocity.dot(UP) > 0.0
    for iteration in MAX_SLIDES:
        var result := move_and_collide(position, motion, solids, MARGIN, not sliding_enabled)
        var collided := result.normal != Vector2.ZERO
        position += result.travel
        if collided:
            motion_results.append(result)
            _set_collision_direction(result)
            if on_floor and (velocity.normalized() + UP).length() < 0.01:
                if result.travel.length() <= MARGIN + CMP_EPSILON:
                    position -= result.travel
                velocity = Vector2.ZERO
                motion = Vector2.ZERO
                break
            if result.remainder.is_zero_approx():
                motion = Vector2.ZERO
                break
            if on_wall and motion_slide_up.dot(result.normal) <= 0.0:
                # floor_block_on_wall
                if was_on_floor and not on_floor and not vel_dir_facing_up:
                    if result.travel.length() <= MARGIN + CMP_EPSILON:
                        position -= result.travel
                    position = _snap_on_floor(position, true, false, true, solids)
                    velocity = Vector2.ZERO
                    motion = Vector2.ZERO
                    break
                elif not on_floor:
                    motion = UP * UP.dot(result.remainder)
                    motion = motion.slide(result.normal)
                else:
                    motion = result.remainder
            elif sliding_enabled or not on_floor:
                # Regular sliding (slide_on_ceiling is on).
                var slide_motion := result.remainder.slide(result.normal)
                if slide_motion.dot(velocity) > 0.0:
                    motion = slide_motion
                else:
                    motion = Vector2.ZERO
                if on_ceiling:
                    if vel_dir_facing_up:
                        velocity = velocity.slide(result.normal)
                    else:
                        velocity = UP * UP.dot(velocity)
            else:
                motion = result.remainder
        sliding_enabled = true
        if not collided or motion.is_zero_approx():
            break
    position = _snap_on_floor(position, was_on_floor, vel_dir_facing_up, false, solids)
    if on_wall and not on_floor and not on_ceiling and motion_slide_up.dot(motion_results[0].normal) < 0.0:
        var slide_motion := velocity.slide(motion_results[0].normal)
        if motion_slide_up.dot(slide_motion) < 0.0:
            velocity = UP * UP.dot(velocity)
        else:
            velocity = UP * UP.dot(velocity) + slide_motion.slide(UP)
    if on_floor and not vel_dir_facing_up:
        velocity = velocity.slide(UP)
    return [position, velocity]

func _snap_on_floor(position: Vector2, was_on_floor: bool, vel_dir_facing_up: bool, wall_as_floor: bool, solids: Array) -> Vector2:
    if on_floor or not was_on_floor or vel_dir_facing_up:
        return position
    # _apply_floor_snap
    var length := maxf(FLOOR_SNAP_LENGTH, MARGIN)
    var result := move_and_collide(position, -UP * length, solids, MARGIN, false)
    if result.normal == Vector2.ZERO:
        return position
    if _is_floor(result) or (wall_as_floor and result.get_angle(-UP) > FLOOR_MAX_ANGLE + FLOOR_ANGLE_THRESHOLD):
        on_floor = true
        floor_normal = result.normal
        var travel := result.travel
        if travel.length() > MARGIN:
            travel = UP * UP.dot(travel)
        else:
            travel = Vector2.ZERO
        position += travel
    return position

## PhysicsBody2D::test_move: would this motion collide?
func test_move(from: Vector2, motion: Vector2, solids: Array) -> bool:
    return test_motion(from, motion, solids, MARGIN, false).normal != Vector2.ZERO
