extends Node2D
## The wild Pokemon's sprites: a pool of them for the Pokemon in the view and
## a margin round it (a few dozen, where every wild Pokemon in the world had
## its own: up to ~1,000 sprites, ~1,200 nodes with the sand traps' extra two).
## Each copies what WildPopulation says of its Pokemon: where it is drawn, its
## pose, depth, water and sand trap; it plays the idle animation, and carries
## the emotes and sparkles shown on it. A dedicated server keeps none (it
## only moves the drawing on, advance()). World's WildPokemonLayer is this.
##
## A Pokemon held by a ball or a battle claim (its record's "ball_reserved")
## keeps its sprite and is left alone: ball_mechanics.gd draws it.

const TRAPINCH_BURROW := preload("res://assets/ecology/trapinch_ow1.png")
const DESERT_WHIRLPOOL := preload("res://assets/ecology/whirlpool_desert2.png")
const DESERT_BURROW_SAND := preload("res://assets/ecology/grass_over_sheet3.png")
const ShinySparkles := preload("res://scripts/shiny_sparkles.gd")
const WildPopulation := preload("res://scripts/wild_population.gd")
## Pixels of margin round the view, as the idle animation always had.
const MARGIN := 64.0
const IDLE_SECONDS := 16.0 / 60.0

var world: Node
var population: WildPopulation
## False on a dedicated server: no sprites.
var drawn := true
## id -> {sprite, whirl, sand, pose (the serial shown), cell (of its water
## look), last (position), idle (seconds)}.
var shown := {}
var _free: Array[Sprite2D] = []

func configure(owner_world: Node, wild: WildPopulation) -> void:
    world = owner_world
    population = wild
    drawn = not preload("res://scripts/dedicated_server.gd").active
    # After everything else in the frame, when tweens ran.
    process_priority = 1000

## The sprite showing wild Pokemon `id`, null when it has none (off screen, or
## a dedicated server).
func sprite_of(id: int) -> Sprite2D:
    var entry = shown.get(id)
    return null if entry == null else entry.sprite

## The sprites shown, for the reflections.
func sprites() -> Array[Sprite2D]:
    var result: Array[Sprite2D] = []
    for entry in shown.values():
        result.append(entry.sprite)
    return result

## Whether wild Pokemon `id` is drawn: its sprite's own visibility when it has
## one, else not hidden in the sand.
func is_drawn(id: int) -> bool:
    var entry = shown.get(id)
    if entry != null:
        return (entry.sprite as Sprite2D).visible
    var slot: int = population.slot_of.get(id, -1)
    return slot >= 0 and population.flags[slot] & WildPopulation.BURROWED == 0

func _process(delta: float) -> void:
    if population == null:
        return
    population.advance(delta)
    if not drawn:
        return
    var wanted := {}
    if world.generated and world.active_area_id == "OVERWORLD":
        for id in population.ids_in_rect(_view_cells()):
            wanted[id] = true
    for id in shown.keys():
        var record: Dictionary = population.records.get(id, {})
        if not record.is_empty() and (wanted.has(id) or bool(record.get("ball_reserved", false))):
            continue
        _release(id)
    for id in wanted:
        _show(id, delta)

## The cells in the view, and a margin round it.
func _view_cells() -> Rect2i:
    var camera := get_viewport().get_camera_2d()
    var center: Vector2 = world.player.global_position if camera == null else camera.get_screen_center_position()
    var zoom := Vector2.ONE if camera == null else camera.zoom
    var half := get_viewport_rect().size / zoom * 0.5 + Vector2(MARGIN, MARGIN)
    var local: Vector2 = world.to_local(center)
    var first := Vector2i(floori((local.x - half.x) / 16.0), floori((local.y - half.y) / 16.0))
    var last := Vector2i(floori((local.x + half.x) / 16.0), floori((local.y + half.y) / 16.0))
    return Rect2i(first, last - first + Vector2i.ONE)

func _show(id: int, delta: float) -> void:
    var record: Dictionary = population.records[id]
    var slot: int = population.slot_of[id]
    var burrowed: bool = population.flags[slot] & WildPopulation.BURROWED != 0
    var entry = shown.get(id)
    if entry == null:
        entry = _acquire(id, record, burrowed)
    if bool(record.get("ball_reserved", false)):
        return
    var sprite: Sprite2D = entry.sprite
    var cell := Vector2i(population.cell_x[slot], population.cell_y[slot])
    var depth: int = world._depth_z(cell)
    if burrowed:
        _draw_trap(entry, record, cell, depth)
        return
    var at := population.visual_position(id)
    if sprite.position != at: sprite.position = at
    if sprite.z_index != depth: sprite.z_index = depth
    if not sprite.visible: sprite.visible = true
    var pose = population.poses.get(id)
    if pose != null and pose.z != entry.pose:
        entry.pose = pose.z
        world._set_overworld_motion_frame(sprite, WildPopulation.DIRECTIONS[pose.x], pose.y)
    # Floating while it stands in water: worked out again when its sprite
    # reaches another cell.
    var water_cell := Vector2i(floori(at.x / 16.0), floori(at.y / 16.0))
    if water_cell != entry.cell:
        entry.cell = water_cell
        world._update_pokemon_water_visual({"sprite": sprite, "species": String(record.get("species", ""))})
    # Standing still, it shuffles between its two standing frames.
    if sprite.hframes < 2:
        return
    if not (entry.last as Vector2).is_equal_approx(at):
        entry.last = at
        entry.idle = 0.0
        return
    entry.idle += delta
    if entry.idle >= IDLE_SECONDS:
        entry.idle = fmod(entry.idle, IDLE_SECONDS)
        var next_frame := sprite.frame ^ 1
        if next_frame < sprite.hframes:
            sprite.frame = next_frame

## A sand trap: hidden, or rising out of its whirlpool while it is active
## (World._update_sand_trap moves it on).
func _draw_trap(entry: Dictionary, record: Dictionary, cell: Vector2i, depth: int) -> void:
    var sprite: Sprite2D = entry.sprite
    var whirl: Sprite2D = entry.whirl
    var sand: Sprite2D = entry.sand
    var center := WildPopulation.cell_center(cell)
    whirl.position = center
    whirl.z_index = depth - 1
    sprite.z_index = depth
    sand.z_index = depth + 1
    var tick := int(record.get("burrow_tick", 0)) if bool(record.get("burrow_active", false)) else 0
    var height := clampi((tick - 50) * 4, 0, 12)
    if tick >= 141:
        height = maxi(0, 12 - (tick - 140))
    sprite.visible = height > 0
    if sprite.visible:
        sprite.hframes = 1
        sprite.region_enabled = true
        var frame := 0 if tick < 52 else 1
        if tick >= 120:
            frame = 0 if tick % 8 < 4 else 1
        sprite.region_rect = Rect2(frame * 16, 0, 16, height)
        sprite.position = center + Vector2(0, 2.0 - float(height) / 2.0)
    whirl.visible = tick > 0
    whirl.frame = 0 if int(record.get("burrow_whirl_tick", 0)) < 40 else 1
    sand.visible = tick >= 50 and tick < 66
    sand.frame = 0 if tick < 58 else 1
    sand.position = center + Vector2(0, -6)

func _acquire(id: int, record: Dictionary, burrowed: bool) -> Dictionary:
    var sprite := _take()
    var species := String(record.get("species", "")).to_lower()
    sprite.texture = TRAPINCH_BURROW if burrowed else PokemonData.record_texture(record, "overworld")
    sprite.position = population.visual_position(id)
    var exeggutor := species in ["aexeggutor", "exeggutor_alolan"]
    if exeggutor:
        sprite.offset = Vector2(0, -16)
    if burrowed:
        sprite.hframes = 2
        sprite.vframes = 1
        sprite.frame = 0
        sprite.visible = false
    else:
        world._configure_overworld_sprite(sprite)
        if exeggutor:
            sprite.hframes = 6
            sprite.vframes = 1
            sprite.frame = 4
            sprite.set_meta("alolan_exeggutor_walk", true)
        sprite.visible = true
    ShinySparkles.attach(sprite, record)
    var entry := {"sprite": sprite, "whirl": null, "sand": null, "pose": -1, "cell": Vector2i(-2147483648, 0),
        "last": sprite.position, "idle": 0.0}
    if burrowed:
        var whirl := _take()
        whirl.texture = DESERT_WHIRLPOOL
        whirl.hframes = 2
        whirl.visible = false
        var sand := _take()
        sand.texture = DESERT_BURROW_SAND
        sand.hframes = 2
        sand.vframes = 2
        sand.frame = 0
        sand.visible = false
        entry.whirl = whirl
        entry.sand = sand
    shown[id] = entry
    return entry

func _release(id: int) -> void:
    var entry: Dictionary = shown[id]
    shown.erase(id)
    for key in ["sprite", "whirl", "sand"]:
        var sprite = entry[key]
        if sprite != null:
            _give_back(sprite)

## A pooled sprite, as Sprite2D.new() made it.
func _take() -> Sprite2D:
    var sprite: Sprite2D = null
    # One freed behind the pool's back (with its record) is passed over.
    while sprite == null and not _free.is_empty():
        sprite = _free.pop_back()
        if not is_instance_valid(sprite) or sprite.is_queued_for_deletion():
            sprite = null
    if sprite == null:
        sprite = Sprite2D.new()
        sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
        sprite.z_as_relative = false
        add_child(sprite)
    return sprite

func _give_back(sprite: Sprite2D) -> void:
    # Emotes, sparkles and whatever else was shown on it go with its Pokemon.
    for child in sprite.get_children():
        sprite.remove_child(child)
        child.queue_free()
    for meta in sprite.get_meta_list():
        sprite.remove_meta(meta)
    sprite.visible = false
    sprite.texture = null
    sprite.material = null
    sprite.scale = Vector2.ONE
    sprite.modulate = Color.WHITE
    sprite.offset = Vector2.ZERO
    sprite.flip_h = false
    sprite.region_enabled = false
    sprite.hframes = 1
    sprite.vframes = 1
    sprite.frame = 0
    _free.append(sprite)
