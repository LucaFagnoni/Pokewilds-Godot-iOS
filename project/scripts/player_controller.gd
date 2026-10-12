extends CharacterBody2D
class_name PlayerController

@onready var input_router: InputRouter = get_node("/root/InputRouterSingleton")

@export var walk_speed: float = 60.0
@export var run_speed: float = 96.0
@onready var sprite: Sprite2D = $Sprite2D
@onready var camera: Camera2D = $Camera2D

var facing: Vector2 = Vector2.DOWN
var field_speed_multiplier: float = 1.0
var field_fixed_speed: float = 0.0
var anim_clock: float = 0.0
var walk_phase: bool = false
var source_step_distance := 0.0
var source_alternate_step := false
var walk_texture: Texture2D
var run_texture: Texture2D
var using_run_texture := false
var use_streamed_overworld_depth := false
var ledge_jump_active := false
## Movement once per drawn frame (as in the original game) instead of on the
## separate 60-per-second physics clock.
var frame_locked := true
var ledge_jump_elapsed := 0.0
var ledge_jump_start_offset := Vector2.ZERO
var field_visual_offset := Vector2.ZERO
var field_rider_visual_lock := false
const LEDGE_JUMP_DURATION := 0.30
const LEDGE_JUMP_ARC_HEIGHT := 5.0

func _ready() -> void:
    if frame_locked:
        camera.process_callback = Camera2D.CAMERA2D_PROCESS_IDLE
        # Before the world's own frame step, which places whatever the player
        # rides, flies or surfs on; after it, the mount trailed by a frame.
        process_priority = -10
    physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
    sprite.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
    camera.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
    walk_texture = sprite.texture
    sprite.hframes = 8
    sprite.vframes = 1
    sprite.frame = 0
    _update_depth()
    _apply_pixel_render_lock()

func _move(delta: float) -> void:
    if ledge_jump_active:
        velocity = Vector2.ZERO
        ledge_jump_elapsed += delta
        if ledge_jump_elapsed >= LEDGE_JUMP_DURATION:
            ledge_jump_elapsed = LEDGE_JUMP_DURATION
            ledge_jump_active = false
        _update_depth()
        _update_sprite_frame(false)
        _apply_pixel_render_lock()
        return

    var dir: Vector2 = input_router.movement_vector()
    var world = get_parent()
    if world != null and world.has_method("field_movement_direction"):
        dir = Vector2(world.call("field_movement_direction", dir))
    var is_running = (
        dir.length_squared() > 0.0001
        and input_router.is_running()
        and run_texture != null
    )

    if dir.length_squared() > 0.0001:
        _update_facing(dir)
    else:
        source_step_distance = 0.0
        walk_phase = false

    var speed: float = walk_speed
    if is_running:
        speed = run_speed
    if field_fixed_speed > 0.0:
        speed = field_fixed_speed
    else:
        speed *= field_speed_multiplier

    if world != null and world.get("active_field_move") == "DIG":
        var dig_before := position
        world.tick_dig_motion(dir, speed, delta)
        _advance_source_walk_frame(position.distance_to(dig_before))
        _update_depth()
        _update_sprite_frame(is_running)
        _apply_pixel_render_lock()
        return

    velocity = dir * speed
    if frame_locked:
        # Moved once per drawn frame, with the camera on the same step, and
        # not rounded to whole pixels (at a running 1.6 px that gave 2,1,2,2,1,
        # a visible shake). At a steady 60 this is the original's fixed step:
        # 1 px walking, 1.6 running, 2 riding or flying. Unlike the original,
        # a slow frame covers proportionally more ground, so a dip in frame
        # rate never plays the game in slow motion.
        velocity = dir * speed
    var before_position = position
    var digging: bool = world != null and world.get("active_field_move") == "DIG"
    if not digging and world != null and world.has_method("try_walk_into_door") and \
            bool(world.call("try_walk_into_door", position, dir)):
        velocity = Vector2.ZERO
        _update_depth()
        _update_sprite_frame(false)
        _apply_pixel_render_lock()
        return
    if not digging and dir.length_squared() > 0.0001 and world != null and \
            world.has_method("try_pre_move_field_jump"):
        var jump_target = world.call("try_pre_move_field_jump", before_position, dir)
        if typeof(jump_target) == TYPE_VECTOR2:
            position = jump_target
            velocity = Vector2.ZERO
            _update_depth()
            _update_sprite_frame(false)
            if world != null and world.has_method("field_motion_completed"):
                world.call("field_motion_completed", before_position, position, dir)
            _apply_pixel_render_lock()
            return
    move_and_slide()
    if world != null and world.has_method("constrain_player_motion"):
        position = world.call("constrain_player_motion",
            before_position, position)
    if world != null and world.has_method("field_motion_completed"):
        world.call("field_motion_completed", before_position, position, dir)
    var sliding := world != null and world.get("m3922_ice_slide_direction") != null and Vector2(world.get("m3922_ice_slide_direction")) != Vector2.ZERO
    if sliding:
        walk_phase = false
        source_step_distance = 0.0
        is_running = false
    else:
        _advance_source_walk_frame(position.distance_to(before_position))
    _update_depth()
    _update_sprite_frame(is_running)
    _apply_pixel_render_lock()

func _advance_source_walk_frame(distance: float) -> void:
    # PlayerMoving/PlayerRunning: moving frame only between 2 and 13 pixels
    # of each 16-pixel stride. Collision stalls do not advance the legs.
    if field_rider_visual_lock:
        walk_phase = false
        source_step_distance = 0.0
        return
    source_step_distance += distance
    while source_step_distance >= 16.0:
        source_step_distance -= 16.0
        source_alternate_step = not source_alternate_step
    walk_phase = distance > 0.0001 and source_step_distance > 2.0 and source_step_distance < 13.0

func _apply_pixel_render_lock() -> void:
    # Keep collision movement continuous while presenting both the character
    # and its camera on the same integer pixel. This prevents diagonal shimmer
    # without changing speed, cadence, or collision behavior.
    if ledge_jump_active:
        var progress := clampf(
            ledge_jump_elapsed / LEDGE_JUMP_DURATION, 0.0, 1.0
        )
        var travel_offset := ledge_jump_start_offset.lerp(
            Vector2.ZERO, progress
        )
        var arc_offset := Vector2(
            0.0, -sin(progress * PI) * LEDGE_JUMP_ARC_HEIGHT
        )
        sprite.position = (
            global_position + travel_offset + arc_offset
        ).round() - global_position + field_visual_offset
        camera.position = (
            global_position + travel_offset
        ).round() - global_position
        return
    # The camera follows the player to the nearest pixel of the screen, not of
    # the game world. Whole world pixels made the scroll uneven; no rounding
    # at all let the edges of the map's drawing blocks fall halfway between
    # two screen pixels, where two blocks can round apart and show a one
    # pixel line of sky down or across the whole screen. On whole screen
    # pixels every block edge lands exactly on a pixel boundary.
    var pixel_offset := global_position.round() - global_position
    if frame_locked:
        var per_pixel := camera.zoom.x * get_viewport().get_stretch_transform().get_scale().x
        pixel_offset = Vector2.ZERO if per_pixel <= 0.0 else (global_position * per_pixel).round() / per_pixel - global_position
    sprite.position = pixel_offset + field_visual_offset
    camera.position = pixel_offset

func begin_ledge_jump_visual(start_offset: Vector2) -> void:
    ledge_jump_start_offset = start_offset
    ledge_jump_elapsed = 0.0
    ledge_jump_active = true
    anim_clock = 0.0
    walk_phase = false
    _apply_pixel_render_lock()

func is_ledge_jump_active() -> bool:
    return ledge_jump_active

func ledge_jump_travel_offset() -> Vector2:
    if not ledge_jump_active:
        return Vector2.ZERO
    var progress := clampf(
        ledge_jump_elapsed / LEDGE_JUMP_DURATION, 0.0, 1.0
    )
    return ledge_jump_start_offset.lerp(Vector2.ZERO, progress)

func mount_visual_offset() -> Vector2:
    # Mount sprites follow pixel rounding and the complete ledge-jump travel/arc,
    # but not the rider-only vertical lift.  This keeps the Pokemon directly
    # underneath the player instead of sliding a tile ahead during RIDE hops.
    return sprite.position - field_visual_offset

func _update_depth() -> void:
    if get_parent().get("active_field_move") == "FLY":
        z_index = 4094
        return
    if use_streamed_overworld_depth:
        # The exact Java overworld is centered on (0, 0), so valid cells can
        # have a large negative Y.  Feeding that absolute coordinate into the
        # bounded-map depth formula puts the player behind both streamed tile
        # layers.  Those layers have fixed Z values, so the player needs one
        # stable foreground depth while on this streamed overworld.
        z_index = 100
        return
    # Depth follows the character's feet.  World props use the same scale, so
    # signs, boulders, doors and trees naturally pass behind/in front instead
    # of being permanently drawn over the player's head.
    z_index = clampi(100 + roundi(global_position.y), -4096, 4095)

func set_streamed_overworld_depth(enabled: bool) -> void:
    use_streamed_overworld_depth = enabled
    _update_depth()

func _update_facing(dir: Vector2) -> void:
    var ax: float = abs(dir.x)
    var ay: float = abs(dir.y)

    if ax > ay * 1.20:
        if dir.x > 0.0:
            facing = Vector2.RIGHT
        else:
            facing = Vector2.LEFT
    elif ay > ax * 1.20:
        if dir.y > 0.0:
            facing = Vector2.DOWN
        else:
            facing = Vector2.UP

func _update_sprite_frame(is_running: bool = false) -> void:
    if field_rider_visual_lock:
        is_running = false
        walk_phase = false
    var should_use_run := is_running and run_texture != null
    if should_use_run != using_run_texture:
        sprite.texture = run_texture if should_use_run else walk_texture
        sprite.hframes = 8
        sprite.vframes = 1
        using_run_texture = should_use_run

    var idle_frame: int = 0
    var walking_frame: int = 4

    if facing == Vector2.UP:
        idle_frame = 1
        walking_frame = 5
    elif facing == Vector2.LEFT:
        idle_frame = 2
        walking_frame = 6
    elif facing == Vector2.RIGHT:
        idle_frame = 3
        walking_frame = 7

    sprite.flip_h = walk_phase and source_alternate_step and facing in [Vector2.UP, Vector2.DOWN]
    if walk_phase:
        sprite.frame = walking_frame
    else:
        sprite.frame = idle_frame

func set_character_textures(
        new_walk_texture: Texture2D,
        new_run_texture: Texture2D
    ) -> void:
    walk_texture = new_walk_texture
    run_texture = new_run_texture
    using_run_texture = false
    sprite.texture = walk_texture
    sprite.hframes = 8
    sprite.vframes = 1
    sprite.frame = 0

func set_field_speed_multiplier(multiplier: float) -> void:
    field_speed_multiplier = maxf(multiplier, 0.1)

func set_field_fixed_speed_pixels_per_frame(pixels_per_frame: float) -> void:
    field_fixed_speed = maxf(0.0, pixels_per_frame) * 60.0

func set_field_visual_offset(offset: Vector2) -> void:
    field_visual_offset = offset
    _apply_pixel_render_lock()

func set_field_rider_visual_lock(enabled: bool) -> void:
    field_rider_visual_lock = enabled
    if enabled:
        anim_clock = 0.0
        walk_phase = false
    _update_sprite_frame(false)
    _apply_pixel_render_lock()

## Movement runs once per drawn frame, before the world's own frame step.
func _process(delta: float) -> void:
    _move(delta)
