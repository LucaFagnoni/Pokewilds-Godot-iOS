extends RefCounted
static var multiplier := 1.0
static var real_origin := Time.get_ticks_usec()
static var virtual_origin := 0
static var base_physics_ticks := Engine.physics_ticks_per_second
static var base_physics_steps := Engine.max_physics_steps_per_frame

static func ticks_usec() -> int:
    return virtual_origin + int((Time.get_ticks_usec() - real_origin) * multiplier)

static func ticks_msec() -> int:
    return ticks_usec() / 1000

static func set_speed(speed: float) -> void:
    speed = clampf(speed, 1.0, 4.0)
    virtual_origin = ticks_usec()
    real_origin = Time.get_ticks_usec()
    multiplier = speed
    Engine.time_scale = float(speed)
    Engine.physics_ticks_per_second = roundi(base_physics_ticks * speed)
    Engine.max_physics_steps_per_frame = roundi(base_physics_steps * speed)
    AudioServer.playback_speed_scale = float(speed)
