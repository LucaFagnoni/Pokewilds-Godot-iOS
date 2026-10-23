extends RefCounted

const World = preload("res://scripts/world.gd")
const CraftingData = preload("res://scripts/crafting_data.gd")
const FLY_SHADOW_TEXTURE = preload("res://assets/source_exact/global/shadow1.png")
const FieldMoveData = preload("res://scripts/field_move_data.gd")
const GRASS := preload("res://assets/grass_runtime.png")
const PokemonData = preload("res://scripts/pokemon_data.gd")
const PokemonEcology = preload("res://scripts/pokemon_ecology.gd")
const SourceWorldData = preload("res://scripts/source_world_data.gd")
const TileRules = preload("res://scripts/rules/tile_rules.gd")
const FieldDig = preload("res://scripts/rules/field_dig.gd")
const FieldCut = preload("res://scripts/rules/field_cut.gd")

var world: World

func _init(owner_world: World) -> void:
    world = owner_world

func set_active_field_move(pokemon_data: Dictionary, move: String, ball_landing: bool = false) -> bool:
    if is_instance_valid(world.sleeping_bag_sprite):
        world.world_message.emit("Get up before using a Field Move.")
        return false
    if int(pokemon_data.get("hp", 1)) <= 0:
        world.world_message.emit("A fainted POKEMON cannot use a Field Move.")
        return false
    if world.active_field_move == "SURF" and world.terrain_kind_at(world._player_cell()) == 0:
        world.world_message.emit("Reach dry land before changing field moves.")
        return false
    if world.active_field_move == "FLY" and not valid_fly_landing(world._player_cell()):
        world.world_message.emit("Land on safe ground before changing field moves.")
        return false
    clear_active_field_move(false)
    world.active_field_pokemon = pokemon_data.duplicate(true)
    world.active_field_species = String(pokemon_data.get("species", "")).to_lower()
    world.active_field_move = move.to_upper()
    if world.active_field_move == "FLY" and "FLY" not in FieldMoveData.field_moves_for(world.active_field_species):
        world.world_message.emit("This Pokemon cannot use FLY.")
        world.active_field_move = ""
        world.active_field_species = ""
        world.active_field_pokemon.clear()
        return false
    if world.active_field_move == "PAINT" and world.active_field_species != "smeargle":
        world.world_message.emit("Only SMEARGLE can use PAINT.")
        world.active_field_move = ""
        world.active_field_species = ""
        world.active_field_pokemon.clear()
        return false
    if world.active_field_move == "SURF":
        var target = world._player_cell() if ball_landing else world._player_cell() + world._facing_cell()
        if world.active_area_id != "OVERWORLD" or world.terrain_kind_at(target) != 0:
            world.world_message.emit("Face open water to use SURF.")
            world.active_field_move = ""
            world.active_field_species = ""
            world.active_field_pokemon.clear()
            return false
    if world.active_field_move == "FLY" and world.active_area_id != "OVERWORLD":
        world.world_message.emit("FLY cannot be used indoors.")
        world.active_field_move = ""
        world.active_field_species = ""
        world.active_field_pokemon.clear()
        return false
    if world.active_field_move == "TELEPORT" and travel_destinations(false).is_empty():
        world.world_message.emit("Place a BEACON before using TELEPORT.")
        world.active_field_move = ""
        world.active_field_species = ""
        world.active_field_pokemon.clear()
        return false
    var placed = (
        world.set_follower(pokemon_data, false)
        if world.active_field_move in ["FOLLOW", "FLASH", "POWER"]
        else _set_field_helper(pokemon_data)
    )
    if not placed:
        world.active_field_move = ""
        world.active_field_species = ""
        world.active_field_pokemon.clear()
        return false
    # A party member has one live actor: activating its helper replaces its
    # follower, while a different party member may keep following normally.
    if is_instance_valid(world.field_helper_sprite) and world.same_party_actor(pokemon_data, world.follower_pokemon):
        world.clear_follower()
    world.build_mode_active = world.active_field_move in ["BUILD", "PAINT"]
    if world.active_field_move == "RIDE":
        if world.player.has_method("set_field_rider_visual_lock"):
            world.player.call("set_field_rider_visual_lock", true)
        if world.player.has_method("set_field_fixed_speed_pixels_per_frame"):
            world.player.call("set_field_fixed_speed_pixels_per_frame", 2.0)
        if world.player.has_method("set_field_visual_offset"):
            # Correct mount composition: the rider overlaps the Pokemon instead
            # of floating a full sprite-height above it.
            world.player.call("set_field_visual_offset", Vector2(0, -3))
        set_fly_shadow_active(false)
    if world.active_field_move == "FLY":
        if world.player.has_method("set_field_rider_visual_lock"):
            world.player.call("set_field_rider_visual_lock", true)
        world.field_previous_collision_mask = world.player.collision_mask
        world.player.collision_mask = 0
        if world.player.has_method("set_field_fixed_speed_pixels_per_frame"):
            world.player.call("set_field_fixed_speed_pixels_per_frame", 2.0)
        world.fly_phase = "TAKEOFF"
        world.fly_phase_elapsed = 0.0
        world.fly_height = 0.0
        world.fly_landing_start_height = 0.0
        if world.player.has_method("set_field_visual_offset"):
            world.player.call("set_field_visual_offset", Vector2(0, -3))
        set_fly_shadow_active(true)
        world.world_message.emit("FLY is active. Move freely; press B over safe ground to land.")
    if world.active_field_move == "SURF":
        if world.player.has_method("set_field_rider_visual_lock"):
            world.player.call("set_field_rider_visual_lock", true)
        world._set_water_collision_enabled(false)
        # SURF uses the same fixed source-speed rider path as RIDE.
        if world.player.has_method("set_field_fixed_speed_pixels_per_frame"):
            world.player.call("set_field_fixed_speed_pixels_per_frame", 2.0)
        if world.player.has_method("set_field_visual_offset"):
            world.player.call("set_field_visual_offset", Vector2(0, -3))
    if world.active_field_move == "REPEL":
        world.repel_until_elapsed = 0.0
        world.world_message.emit("REPEL is active.")
    elif world.active_field_move == "BUILD":
        position_build_helper()
        world.set_build_preview_active(true)
        world._show_current_build_selection()
    elif world.active_field_move == "DIG":
        world.dig_step_active = false
        world.dig_action_pending = false
        world.dig_return_position = world.work_trainer_position
        _show_current_dig_selection()
    elif world.active_field_move == "PAINT":
        _show_current_paint_selection()
    elif world.active_field_move == "TELEPORT":
        world.travel_selection_index = 0
        world.teleport_map_requested.emit(travel_destinations(false))
    world.planting_item = ""
    return true

func clear_active_field_move(show_message: bool = true) -> void:
    world.dig_step_active = false
    world.dig_action_pending = false
    if world.active_field_move == "DIG" and not world._is_walkable(world._player_cell()):
        var landing := _nearest_walkable_cell(world._player_cell(), 4)
        world.player.position = world._cell_center(landing) if landing.x > -2147483648 else world.dig_return_position

    if world.active_field_move == "SURF" and show_message and world.terrain_kind_at(world._player_cell()) == 0:
        world.world_message.emit("Reach dry land before getting off.")
        return
    # User-requested FLY cancellation plays the authored landing sequence. Internal
    # cleanup (show_message=false) remains immediate so battles/map transitions
    # cannot be delayed by a field-move animation.
    if world.active_field_move == "FLY" and show_message and world.fly_phase != "LANDING":
        if not valid_fly_landing(world._player_cell()):
            world.world_message.emit("You cannot land here.")
            return
        world.player.position = world._cell_center(world._player_cell())
        world.fly_phase = "LANDING"
        world.fly_phase_elapsed = 0.0
        world.fly_landing_start_height = world.fly_height
        world.fly_landing_show_message = show_message
        if world.player.has_method("set_field_fixed_speed_pixels_per_frame"):
            world.player.call("set_field_fixed_speed_pixels_per_frame", 0.0)
        world.play_source_sound("fly_landing1")
        return

    var previous_move = world.active_field_move
    # Forced off FLY or SURF over the sea (a battle, a deploy...): nobody can
    # stand there on foot, and open sea keeps no collision. Put them ashore.
    if world.active_field_move in ["FLY", "SURF"] and world.active_area_id == "OVERWORLD" and not world._is_walkable(world._player_cell()):
        var shore := _nearest_walkable_cell(world._player_cell(), 24)
        if shore.x == -2147483648:
            # Far out at sea: back where a whiteout would put them.
            var home := world.respawn_cell if world.respawn_cell.x > -2147483648 else world.spawn_cell
            if world._is_walkable(home): shore = home
        if shore.x > -2147483648: world.player.position = world._cell_center(shore)
    if world.active_field_move == "FLY":
        world.player.collision_mask = world.field_previous_collision_mask
        set_fly_shadow_active(false)
        world.fly_phase = ""
        world.fly_phase_elapsed = 0.0
        world.fly_height = 0.0
    if world.active_field_move == "SURF":
        world._set_water_collision_enabled(true)
    if (
            world.active_field_move in ["RIDE", "SURF", "FLY"]
            and world.player.has_method("set_field_visual_offset")
        ):
        world.player.call("set_field_visual_offset", Vector2.ZERO)
    if world.active_field_move == "RIDE":
        set_fly_shadow_active(false)
    if world.player.has_method("set_field_rider_visual_lock"):
        world.player.call("set_field_rider_visual_lock", false)
    if world.player.has_method("set_field_speed_multiplier"):
        world.player.call("set_field_speed_multiplier", 1.0)
    if world.player.has_method("set_field_fixed_speed_pixels_per_frame"):
        world.player.call("set_field_fixed_speed_pixels_per_frame", 0.0)
    world.active_field_move = ""
    world.active_field_species = ""
    world.active_field_pokemon.clear()
    world.repel_until_elapsed = 0.0
    world.build_mode_active = false
    world.set_build_preview_active(false)
    clear_field_helper()
    if previous_move in ["FOLLOW", "FLASH", "POWER"]:
        world.clear_follower()
    # Field moves stop silently.

## per-frame
func set_fly_shadow_active(active: bool) -> void:
    # Use the authored PokeWilds shadow1 asset instead of the fabricated polygon.
    if active:
        if not is_instance_valid(world.fly_shadow_sprite):
            world.fly_shadow_sprite = Sprite2D.new()
            world.fly_shadow_sprite.name = "SourceFlyShadow"
            world.fly_shadow_sprite.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
            world.fly_shadow_sprite.texture = FLY_SHADOW_TEXTURE
            world.fly_shadow_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
            world.fly_shadow_sprite.z_as_relative = false
            world.add_child(world.fly_shadow_sprite)
        world.fly_shadow_sprite.visible = true
        update_fly_shadow()
    elif is_instance_valid(world.fly_shadow_sprite):
        world.fly_shadow_sprite.visible = false
    if is_instance_valid(world.fly_shadow):
        world.fly_shadow.visible = false

## per-frame
func update_fly_shadow() -> void:
    if not is_instance_valid(world.fly_shadow_sprite):
        return
    world.fly_shadow_sprite.global_position = (world.player.global_position + Vector2(0, 7)).round()
    world.fly_shadow_sprite.z_index = world.player.z_index - 2

func _set_field_helper(pokemon_data: Dictionary) -> bool:
    var species := String(pokemon_data.get("species", "")).to_lower()
    var texture := PokemonData.record_texture(pokemon_data, "overworld")
    if texture == null:
        texture = World.FARM_POKEMON_TEXTURES.get(species) as Texture2D
    if texture == null:
        return false
    if world.active_field_move in ["CUT", "BUILD", "DIG", "HEADBUTT", "SMASH"]:
        var front := world._player_cell() + world._facing_cell()
        var clear := world._is_built_house_floor_cell(front) and not world.blocked.has(front) and not world.built_structures.has(front) and not world.deployed_pokemon.has(front)
        clear = clear or _field_helper_cell_is_clear(front)
        if not clear or (world.active_field_move in ["CUT", "HEADBUTT"] and (world._is_cuttable_grass_cell(front) or cut_helper_tree_cell(front))) or (world.active_field_move == "SMASH" and smash_helper_rock_cell(front)):
            world.world_message.emit("Leave one clear tile ahead for your POKEMON.")
            return false
    clear_field_helper()
    world.field_helper_pokemon = PokemonEcology.ensure_record(
        pokemon_data, world.rng, "field:%s" % species)
    world.field_helper_sprite = Sprite2D.new()
    world.field_helper_sprite.texture = texture
    world.field_helper_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
    world.field_helper_sprite.z_as_relative = false
    world.field_helper_sprite.physics_interpolation_mode = \
        Node.PHYSICS_INTERPOLATION_MODE_OFF
    world._configure_overworld_sprite(world.field_helper_sprite)
    if species in ["aexeggutor", "exeggutor_alolan"]:
        world.field_helper_sprite.hframes = 6
        world.field_helper_sprite.vframes = 1
        world.field_helper_sprite.set_meta("alolan_exeggutor_walk", true)
    var layer := world.get_node_or_null("LandmarkLayer") as Node2D
    if layer == null:
        world.field_helper_pokemon.clear()
        world.field_helper_sprite = null
        return false
    layer.add_child(world.field_helper_sprite)
    preload("res://scripts/shiny_sparkles.gd").attach(world.field_helper_sprite, pokemon_data)
    place_field_helper_live()
    return true

func clear_field_helper() -> void:
    if is_instance_valid(world.work_trainer_sprite):
        world.work_trainer_sprite.queue_free()
    world.work_trainer_sprite = null
    world.work_trail.clear()
    if is_instance_valid(world.player) and is_instance_valid(world.player.sprite):
        world.player.sprite.visible = true
    if is_instance_valid(world.field_helper_sprite):
        world.field_helper_sprite.queue_free()
    world.field_helper_sprite = null
    world.field_helper_pokemon.clear()
    world.field_helper_cell = Vector2i(-2147483648, -2147483648)

func present_field_move_pokemon() -> void:
    # Field-move users appear directly in front of the player before settling
    # into the normal follower cadence. There is no rotation or spin effect.
    var sprite := world.follower_sprite if world.active_field_move == "FOLLOW" else world.field_helper_sprite
    if not is_instance_valid(sprite):
        return
    if world.active_field_move == "FOLLOW":
        world._place_follower_live()
    else:
        place_field_helper_live()
    var source_sound := String({
        "BUILD":"move_object", "CUT":"cut1", "FLY":"fly_takingoff1",
        "SURF":"swim1", "DIG":"dig1", "RIDE":"ride1",
        "SMASH":"strength1", "TELEPORT":"teleport_start1",
        "FLASH":"ap1", "CHARM":"fanfare1"
    }.get(world.active_field_move, ""))
    if not source_sound.is_empty():
        world.play_source_sound(source_sound)

func position_build_helper() -> void:
    if (
            world.active_field_move != "BUILD"
            or world.field_helper_pokemon.is_empty()
            or not is_instance_valid(world.field_helper_sprite)
        ):
        return
    place_field_helper_live()

## per-frame
func place_field_helper_live() -> void:
    if world.field_helper_pokemon.is_empty() or not is_instance_valid(world.field_helper_sprite):
        return
    if world.active_field_move not in ["RIDE", "FLY"]:
        _place_walking_field_helper()
        if world.active_field_move == "SURF": preload("res://scripts/mount_layers.gd").apply(world)
        if world.active_field_move == "BUILD":
            var phase := int(world.player.walk_phase) if world.player.velocity.length_squared() > 0.01 else 0
            world._set_overworld_motion_frame(world.field_helper_sprite, world._facing_cell(), phase)
        return

    var facing = world._facing_cell()
    var visual_offset = Vector2.ZERO
    if world.player.has_method("mount_visual_offset"):
        visual_offset = Vector2(world.player.call("mount_visual_offset"))
    var mount_lift = 0.0
    var rider_lift = 3.0

    if world.active_field_move == "FLY":
        world.fly_phase_elapsed += world.frame_delta
        if world.fly_phase == "TAKEOFF":
            var takeoff_progress = clampf(world.fly_phase_elapsed / World.FLY_TAKEOFF_SECONDS, 0.0, 1.0)
            world.fly_height = 32.0 * takeoff_progress
            if takeoff_progress >= 1.0:
                world.fly_phase = "HOVER"
                world.fly_phase_elapsed = 0.0
        elif world.fly_phase == "LANDING":
            var landing_progress = clampf(world.fly_phase_elapsed / World.FLY_LANDING_SECONDS, 0.0, 1.0)
            world.fly_height = lerpf(world.fly_landing_start_height, 0.0, landing_progress)
            if landing_progress >= 1.0:
                # Phase is already LANDING, so this call performs final cleanup
                # instead of recursively starting another landing.
                clear_active_field_move(world.fly_landing_show_message)
                return
        else:
            world.fly_phase = "HOVER"
            # Player.Flying updates height every four source ticks and resets
            # its counter at 255. Keep the existing rider/mount offsets intact.
            var tick := posmod(int(floor(world.fly_phase_elapsed * 60.0 + 0.000001)), 255)
            var phase := posmod(tick, 32)
            world.fly_height = float([32, 31, 30, 29, 30, 31, 32, 33][phase / 4])
            if phase == 31:
                world.fly_height = 32.0
        mount_lift = world.fly_height
        if world.player.has_method("set_field_visual_offset"):
            world.player.call("set_field_visual_offset", Vector2(0, -mount_lift - rider_lift))
    else:
        # RIDE keeps the player seated into the mount rather than 12 pixels above.
        if world.player.has_method("set_field_visual_offset"):
            world.player.call("set_field_visual_offset", Vector2(0, -rider_lift))

    world.field_helper_cell = world._player_cell()
    world.field_helper_sprite.visible = true
    world.field_helper_sprite.position = (
        world.player.position + visual_offset + Vector2(0, -mount_lift + 2.0)
    ).round()
    world.field_helper_sprite.z_index = world.player.z_index - 1
    var moving = world.player.velocity.length_squared() > 0.01 or (
        world.player.has_method("is_ledge_jump_active")
        and bool(world.player.call("is_ledge_jump_active"))
    )
    var phase = int(preload("res://scripts/game_clock.gd").ticks_msec() / 180) % 2 if moving or world.active_field_move == "FLY" else 0
    world._set_overworld_motion_frame(world.field_helper_sprite, facing, phase)
    world.field_helper_sprite.offset = Vector2.ZERO
    preload("res://scripts/mount_layers.gd").apply(world)

func _place_walking_field_helper() -> void:
    if world.field_helper_pokemon.is_empty() or not is_instance_valid(world.field_helper_sprite):
        return
    var facing := world._facing_cell()
    if world.active_field_move in ["RIDE", "SURF", "FLY"]:
        # Mount field moves use the Pokemon as the mount, not a follower one tile
        # in front. Follow the player's rendered position so RIDE jump arcs and
        # FLY elevation stay visually locked together without per-frame path or
        # collision queries.
        var visual_offset := Vector2.ZERO
        if world.player.has_method("mount_visual_offset"):
            visual_offset = Vector2(world.player.call("mount_visual_offset"))
        var mount_offset := Vector2(0, 3)
        if world.active_field_move == "SURF":
            mount_offset = Vector2(0, 3)
        elif world.active_field_move == "FLY":
            mount_offset = Vector2(0, 2)
        world.field_helper_cell = world._player_cell()
        world.field_helper_sprite.visible = true
        world.field_helper_sprite.position = (
            world.player.position + visual_offset + mount_offset
        ).round()
        world.field_helper_sprite.z_index = world.player.z_index - 1
        var moving := world.player.velocity.length_squared() > 0.01 or \
            (world.player.has_method("is_ledge_jump_active") and \
            bool(world.player.call("is_ledge_jump_active")))
        var phase := int(preload("res://scripts/game_clock.gd").ticks_msec() / 180) % 2 if moving else 0
        world._set_overworld_motion_frame(world.field_helper_sprite, facing, phase)
        world.field_helper_sprite.offset = Vector2.ZERO
        return

    if world.active_field_move in ["CUT", "BUILD", "DIG", "HEADBUTT", "SMASH"]:
        _place_controlled_work_pokemon(facing)
        return

    # Other work helpers stand in the tile directly in front of the player.
    # They are visual actors and have no collision body, so an occupied work tile
    # is valid: CUT can stand on the tree/grass work point, BUILD on its preview,
    # DIG on the ground, etc. Never move a helper to a side or behind the player.
    var target_cell := world._player_cell() + facing
    world.field_helper_cell = target_cell
    world.field_helper_sprite.visible = true
    world.field_helper_sprite.position = (
        world.player.position + Vector2(facing) * float(World.TILE)
    ).round()
    world.field_helper_sprite.z_index = world._depth_z(target_cell) + 1
    if world.active_field_move == "CUT":
        _set_cut_helper_facing(facing, int(world.player.walk_phase))
    else:
        world._set_overworld_motion_frame(world.field_helper_sprite, facing, int(world.player.walk_phase))
    world.field_helper_sprite.offset = Vector2(0, -16) if world.field_helper_sprite.has_meta("alolan_exeggutor_walk") else Vector2.ZERO

func _place_controlled_work_pokemon(facing: Vector2i) -> void:
    if not is_instance_valid(world.work_trainer_sprite):
        world.work_trainer_sprite = Sprite2D.new()
        world.work_trainer_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
        world.work_trainer_sprite.z_as_relative = false
        world.field_helper_sprite.get_parent().add_child(world.work_trainer_sprite)
        # Keep the trainer where activation occurred; the controlled Pokemon
        # begins in the clear adjacent tile, not on top of the trainer.
        var start: Vector2 = world.player.position
        if world.active_field_move == "DIG":
            start = world._cell_center(world._player_cell())
            world.player.position = start
        world.player.position += Vector2(facing) * World.TILE
        world.work_trail.assign([start, world.player.position] if start != world.player.position else [start])
        world.work_trainer_position = start
        world.work_trainer_sprite.position = start.round()
        world.work_trainer_facing = facing
        world.work_trainer_walking = false
    world.player.sprite.visible = false
    world.field_helper_cell = world._player_cell()
    world.field_helper_sprite.position = world.player.position.round()
    world.field_helper_sprite.z_index = world._depth_z(world.field_helper_cell)
    world.field_helper_sprite.visible = true
    if world.active_field_move in ["CUT", "DIG"]:
        _set_cut_helper_facing(facing, int(world.player.walk_phase))
    else:
        world._set_overworld_motion_frame(world.field_helper_sprite, facing, int(world.player.walk_phase))
    world.field_helper_sprite.offset = Vector2(0, -16) if world.field_helper_sprite.has_meta("alolan_exeggutor_walk") else Vector2.ZERO
    var leader_moved := world.work_trail[-1].distance_to(world.player.position) > 0.001
    if leader_moved:
        if world.work_trail[-1].distance_to(world.player.position) > World.TILE * 2:
            world.work_trail.assign([world.player.position])
        else:
            world.work_trail.append(world.player.position)
    var remaining := float(World.TILE)
    var trainer_position: Vector2 = world.work_trail[0]
    for index in range(world.work_trail.size() - 1, 0, -1):
        var segment := world.work_trail[index].distance_to(world.work_trail[index - 1])
        if segment >= remaining:
            trainer_position = world.work_trail[index].move_toward(world.work_trail[index - 1], remaining)
            if index > 1:
                world.work_trail = world.work_trail.slice(index - 1)
            break
        remaining -= segment
    var trainer_motion := trainer_position - world.work_trainer_position
    if leader_moved:
        world.work_trainer_walking = trainer_motion.length_squared() > 0.001
    world.work_trainer_position = trainer_position
    if trainer_motion.length_squared() > 0.001:
        world.work_trainer_facing = Vector2i(int(signf(trainer_motion.x)), 0) if absf(trainer_motion.x) > absf(trainer_motion.y) else Vector2i(0, int(signf(trainer_motion.y)))
    world.work_trainer_sprite.position = trainer_position.round()
    world.work_trainer_sprite.texture = world.player.sprite.texture
    world.work_trainer_sprite.hframes = 8
    world.work_trainer_sprite.vframes = 1
    var base := 1 if world.work_trainer_facing.y < 0 else (0 if world.work_trainer_facing.y > 0 else (2 if world.work_trainer_facing.x < 0 else 3))
    world.work_trainer_sprite.frame = base + (4 if world.player.walk_phase and world.work_trainer_walking else 0)
    world.work_trainer_sprite.flip_h = world.player.walk_phase and world.player.source_alternate_step and world.work_trainer_facing.y != 0
    world.work_trainer_sprite.z_index = world._depth_z(Vector2i(floori(trainer_position.x / World.TILE), floori(trainer_position.y / World.TILE)))

func _set_cut_helper_facing(facing: Vector2i, phase: int = 0) -> void:
    # Most bundled sheets are side/back/front pairs. Krabby and Kingler's
    # authored sheets instead contain front/side/back pairs.
    var species := String(world.field_helper_pokemon.get("species", "")).to_lower()
    if species in ["krabby", "kingler"] and world.field_helper_sprite.hframes >= 6:
        world.field_helper_sprite.frame = (4 if facing.y < 0 else (0 if facing.y > 0 else 2)) + phase
        world.field_helper_sprite.flip_h = facing.x > 0
    else:
        world._set_overworld_motion_frame(world.field_helper_sprite, facing, phase)

func _field_helper_can_use_work_target(cell: Vector2i) -> bool:
    if world.active_field_move != "DIG":
        return _non_dig_work_target_allowed(cell)
    if world.deployed_pokemon.has(cell) or world.wild_eggs.has(cell) or world._wild_id_at_cell(cell) >= 0:
        return false
    if world.built_structures.has(cell) or world.landmarks.has(cell) or world.resource_objects.has(cell):
        return false
    if world.exact_world != null:
        var tile: SourceTile = world.exact_world.tile_at(cell)
        if tile == null:
            return false
        # Visible exact-world resources keep ownership of their tile; fossil
        # cracks are ground overlays and intentionally do not resolve as resources.
        if not dig_tile_is_fossil_site(tile) and not tile.name_upper.begins_with("hole1"):
            var resource_anchor: Vector2i = exact_resource_anchor(cell)
            if resource_anchor.x > -2147483648:
                return false
        return _dig_tile_is_surface(tile) or _dig_target_accepts_soil(cell)
    return world._in_bounds(cell) and world.terrain_kind_at(cell) != 0 and not world.blocked.has(cell)

func _non_dig_work_target_allowed(cell: Vector2i) -> bool:
    if world.deployed_pokemon.has(cell) or world.wild_eggs.has(cell) or \
            world._wild_id_at_cell(cell) >= 0:
        return false

    if world.active_field_move == "CUT":
        if not world.house_wall_decoration_at(cell).is_empty():
            return true
        if world.built_structures.has(cell):
            var built_name: String = String((world.built_structures[cell] as Dictionary).get(
                "name", ""))
            return built_name not in ["GRAVE", "STATUE"]
        if world._is_cuttable_grass_cell(cell):
            return true
        var cut_exact: Vector2i = exact_resource_anchor(cell)
        if cut_exact.x > -2147483648:
            return exact_resource_kind(cut_exact) in ["tree", "bush"]
        var cut_resource: Vector2i = resource_object_anchor(cell)
        if cut_resource.x > -2147483648:
            return String((world.resource_objects[cut_resource] as Dictionary).get(
                "type", "")) in ["tree", "bush"]
        return false

    if world.active_field_move == "HEADBUTT":
        var head_exact: Vector2i = exact_resource_anchor(cell)
        if head_exact.x > -2147483648 and world.exact_world != null:
            var head_tile: SourceTile = world.exact_world.tile_at(head_exact)
            return head_tile != null and (
                head_tile.is_headbuttable or exact_resource_kind(head_exact) == "rock"
            )
        var head_resource: Vector2i = resource_object_anchor(cell)
        if head_resource.x > -2147483648:
            return String((world.resource_objects[head_resource] as Dictionary).get(
                "type", "")) in ["tree", "bush", "cactus", "rock"]
        return false

    if world.active_field_move == "SMASH":
        if world.built_structures.has(cell):
            return String((world.built_structures[cell] as Dictionary).get(
                "name", "")) in ["GRAVE", "STATUE"]
        var smash_exact: Vector2i = exact_resource_anchor(cell)
        if smash_exact.x > -2147483648:
            return exact_resource_kind(smash_exact) == "rock"
        var smash_resource: Vector2i = resource_object_anchor(cell)
        return smash_resource.x > -2147483648 and String((
            world.resource_objects[smash_resource] as Dictionary).get("type", "")) == "rock"

    if world.active_field_move == "DIG":
        if world.active_area_id == "HOUSE":
            return world._is_built_house_floor_cell(cell) and not world.blocked.has(cell) and not world.built_structures.has(cell) and not world.interior_interactables.has(cell)
        if world.built_structures.has(cell) or world.landmarks.has(cell) or world.resource_objects.has(cell):
            return false
        if world.exact_world != null:
            var dig_tile: SourceTile = world.exact_world.tile_at(cell)
            if dig_tile == null or dig_tile.is_water:
                return false
            var dig_names: String = (dig_tile.name + " " + dig_tile.name_upper).to_lower()
            var diggable_mountain: bool = "mountain" in dig_names or "ledges3" in dig_names
            return (not dig_tile.is_solid and not dig_tile.is_ledge) or diggable_mountain
        return world._in_bounds(cell) and world.terrain_kind_at(cell) != 0 and not world.blocked.has(cell)

    if world.active_field_move == "PAINT":
        return world.active_area_id == "HOUSE" and world.built_house_paintable_walls.has(cell)
    return false

func _field_helper_target_cell(move: String) -> Vector2i:
    if world.active_field_move != move or world.field_helper_pokemon.is_empty():
        return Vector2i(-2147483648, -2147483648)
    if world.field_helper_cell.x <= -2147483648:
        return Vector2i(-2147483648, -2147483648)
    # SMASH works on what the Pokemon faces, like the other moves. It used to
    # work only on the tile the Pokemon stood on, so a GRAVE or STATUE, which
    # cannot be stood on, could never be smashed.
    var target := world.field_helper_cell + world._facing_cell() if move in ["CUT", "BUILD", "DIG", "HEADBUTT", "SMASH"] else world.field_helper_cell
    if move == "SMASH" and not _field_helper_can_use_work_target(target) and _field_helper_can_use_work_target(world.field_helper_cell):
        target = world.field_helper_cell
    if not _field_helper_can_use_work_target(target):
        return Vector2i(-2147483648, -2147483648)
    return target

func field_move_action_cell(default_cell: Vector2i, move: String) -> Vector2i:
    if move == "DIG" and world.active_field_move == "DIG":
        # The controlled body is the Pokemon. A cached helper cell can still
        # describe its previous physics position when an action arrives.
        return world._player_cell() + world._facing_cell()
    var helper_target: Vector2i = _field_helper_target_cell(move)
    return helper_target if helper_target.x > -2147483648 else default_cell

func cut_helper_target_cell() -> Vector2i:
    if world.active_field_move != "CUT" or world.field_helper_pokemon.is_empty():
        return Vector2i(-2147483648, -2147483648)
    place_field_helper_live()
    var target := world.field_helper_cell + world._facing_cell()
    if _field_helper_can_use_work_target(target):
        return target
    # The controlled body is 10px wide and can contact an adjacent row before
    # its center changes cells. Resolve only cells touched by its forward edge.
    var facing := Vector2(world._facing_cell())
    var tangent := Vector2(-facing.y, facing.x)
    var body_center: Vector2 = world.player.position + PlayerController.BODY_OFFSET
    for offset in [0.0, -4.9, 4.9]:
        var point: Vector2 = body_center + facing * 6.0 + tangent * float(offset)
        var contact := Vector2i(floori(point.x / World.TILE), floori(point.y / World.TILE))
        if _field_helper_can_use_work_target(contact): return contact
    return Vector2i(-2147483648, -2147483648)

func smash_helper_rock_cell(cell: Vector2i) -> bool:
    if String(world.built_structures.get(cell, {}).get("name", "")) in ["GRAVE", "STATUE"]:
        return true
    var exact_anchor := exact_resource_anchor(cell)
    if exact_anchor.x > -2147483648 and exact_resource_kind(exact_anchor) == "rock":
        return true
    var anchor := resource_object_anchor(cell)
    return anchor.x > -2147483648 and String(world.resource_objects[anchor].get("type", "")) == "rock"

func cut_helper_tree_cell(cell: Vector2i) -> bool:
    var exact_anchor := exact_resource_anchor(cell)
    if exact_anchor.x > -2147483648 and exact_resource_kind(exact_anchor) in ["tree", "bush"]:
        return true
    var anchor := resource_object_anchor(cell)
    return anchor.x > -2147483648 and String(world.resource_objects[anchor].get("type", "")) in ["tree", "bush"]

func _field_helper_cell_is_clear(cell: Vector2i) -> bool:
    if not world._pokemon_can_enter(world.active_field_species, cell):
        return false
    return (
        not world.built_structures.has(cell)
        and not world.landmarks.has(cell)
        and not world.resource_objects.has(cell)
        and not world.deployed_pokemon.has(cell)
        and not world.wild_eggs.has(cell)
        and world._wild_id_at_cell(cell) < 0
    )

func teleport_destinations() -> Array[Dictionary]:
    return travel_destinations(false)

func teleport_to_destination(index: int) -> bool:
    var destinations := travel_destinations(false)
    if destinations.is_empty():
        return false
    world.travel_selection_index = clampi(index, 0, destinations.size() - 1)
    _travel_to_selected_destination(false)
    return true

func travel_destinations(include_spawn: bool) -> Array[Dictionary]:
    var result: Array[Dictionary] = []
    # The Java source exposes warp_tile1 as the outdoor teleport build tile.
    # BEACON remains only as the internal save-compatible key for older saves.
    for key in world.built_structures.keys():
        var cell: Vector2i = key
        var data: Dictionary = world.built_structures[cell]
        if String(data.get("name", "")) == "BEACON":
            result.append({
                "name":String(data.get("label", "BEACON")),
                "cell":cell + Vector2i.DOWN
            })
    if not include_spawn:
        return result

    result.push_front({"name":"STARTING AREA", "cell":world.spawn_cell})
    for raw_name in world.source_landmarks.keys():
        var raw_value = world.source_landmarks[raw_name]
        var landmark_cell := Vector2i(-2147483648, -2147483648)
        if typeof(raw_value) == TYPE_VECTOR2I:
            landmark_cell = raw_value
        elif typeof(raw_value) == TYPE_DICTIONARY and (raw_value as Dictionary).has("cell"):
            landmark_cell = Vector2i((raw_value as Dictionary).get("cell", landmark_cell))
        if landmark_cell.x <= -2147483648 or not world.discovered_cells.has(landmark_cell):
            continue
        var landing := _nearest_walkable_cell(landmark_cell, 4)
        if landing.x <= -2147483648:
            continue
        result.append({"name":String(raw_name).replace("_", " ").to_upper(), "cell":landing})
    return result

## per-frame
func clamp_flying_player_to_world() -> void:
    var bounds := world.get_map_bounds()
    if bounds.size.x <= 0 or bounds.size.y <= 0:
        return
    var main := world.get_parent()
    if main != null and main.has_method("check_flying_map_edge"):
        main.check_flying_map_edge()

func valid_fly_landing(cell: Vector2i) -> bool:
    if not world._in_bounds(cell) or world.terrain_kind_at(cell) == 0 or world.blocked.has(cell):
        return false
    if world.built_structures.has(cell) or world.landmarks.has(cell) or world.resource_objects.has(cell) or world.deployed_pokemon.has(cell) or world.wild_eggs.has(cell) or world._wild_id_at_cell(cell) >= 0:
        return false
    if world.exact_world != null:
        var tile := world.exact_world.tile_at(cell)
        return tile != null and not world.exact_world.is_solid(cell) and not tile.is_ledge and not tile.is_bottom_mtn_layer
    return true

func _nearest_walkable_cell(origin: Vector2i, radius: int) -> Vector2i:
    if world._is_walkable(origin):
        return origin
    for distance in range(1, radius + 1):
        for y in range(origin.y - distance, origin.y + distance + 1):
            for x in range(origin.x - distance, origin.x + distance + 1):
                var cell := Vector2i(x, y)
                if maxi(absi(x - origin.x), absi(y - origin.y)) == distance and world._is_walkable(cell):
                    return cell
    return Vector2i(-2147483648, -2147483648)

func _show_current_travel_selection() -> void:
    var destinations := travel_destinations(world.active_field_move == "FLY")
    if destinations.is_empty():
        world.world_message.emit("No known destination can be reached.")
        return
    world.travel_selection_index = wrapi(world.travel_selection_index, 0, destinations.size())
    world.prepare_view_at(Vector2i(destinations[world.travel_selection_index].get("cell", world.spawn_cell)))
    world.world_message.emit("%s: %s (L/R selects, A confirms)" % [world.active_field_move, String(destinations[world.travel_selection_index].get("name", "DESTINATION"))])

func cycle_travel_selection(direction: int) -> void:
    var destinations := travel_destinations(world.active_field_move == "FLY")
    if destinations.is_empty():
        return
    world.travel_selection_index = wrapi(world.travel_selection_index + direction, 0, destinations.size())
    _show_current_travel_selection()

func _travel_to_selected_destination(include_spawn: bool) -> void:
    var destinations := travel_destinations(include_spawn)
    if destinations.is_empty():
        world.world_message.emit("No known destination can be reached.")
        return
    world.travel_selection_index = wrapi(world.travel_selection_index, 0, destinations.size())
    var destination := destinations[world.travel_selection_index]
    world.active_area_id = "OVERWORLD"
    world.player.position = world._cell_center(Vector2i(destination.get("cell", world.spawn_cell)))
    world._sync_follower_to_player()
    world._configure_camera()
    world.play_source_sound("fly_takingoff1" if world.active_field_move == "FLY" else "teleport1")
    world.world_message.emit("%s brought you to %s." % [world.active_field_move, String(destination.get("name", "the destination"))])

func cycle_paint_selection(direction: int) -> void:
    world.paint_selection_index = wrapi(world.paint_selection_index + direction, 0, World.PAINT_CHOICES.size())
    _show_current_paint_selection()

func _show_current_paint_selection() -> void:
    world.world_message.emit("PAINT: %s (L/R selects)" % World.PAINT_CHOICES[world.paint_selection_index])

func use_headbutt(cell: Vector2i) -> void:
    var exact_anchor := exact_resource_anchor(cell)
    if exact_anchor.x > -2147483648 and exact_resource_kind(exact_anchor) == "rock":
        harvest_exact_resource(exact_anchor, "HEADBUTT")
        return
    # Tall palms/cacti can be faced through either visible half. Resolve that
    # visual cell back to the authored SourceTile so its stored encounter route
    # (including occasional Exeggutor/Exeggcute/Maractus) is not skipped.
    var exact_headbutt_cell := cell
    if exact_anchor.x > -2147483648:
        exact_headbutt_cell = exact_anchor
    var resource_anchor := resource_object_anchor(cell)
    if resource_anchor.x > -2147483648 and \
            String((world.resource_objects[resource_anchor] as Dictionary).get("type", "")) == "rock":
        harvest_resource_with_move(resource_anchor, "HEADBUTT")
        return
    var headbuttable := false
    if world.exact_world != null:
        var tile := world.exact_world.tile_at(exact_headbutt_cell)
        headbuttable = tile != null and tile.is_headbuttable
        if headbuttable and tile.route_belongs_to != null and not tile.route_belongs_to.stored_pokemon.is_empty():
            var record := (tile.route_belongs_to.stored_pokemon[0] as Dictionary).duplicate(true)
            world.pending_encounter_record = record.duplicate(true)
            world.play_source_sound("headbutt1")
            world.encounter_requested.emit(String(record.get("name", "pidgey")).to_lower(), int(record.get("level", world._level_for_cell(exact_headbutt_cell))))
            world.world_message.emit("HEADBUTT! A Pokemon fell from the tree!")
            return
    elif resource_anchor.x > -2147483648:
        headbuttable = String((world.resource_objects[resource_anchor] as Dictionary).get(
            "type", "")) in ["tree", "bush", "cactus"]
    if not headbuttable:
        world.world_message.emit("There is nothing to HEADBUTT here.")
        return
    world.play_source_sound("headbutt1")
    world.world_message.emit("HEADBUTT! The tree shook, but nothing fell.")

func ride_jump_over(obstacle: Vector2i) -> void:
    if world.active_field_move == "RIDE" and world.exact_world != null and world.active_area_id == "OVERWORLD":
        var tile = world.exact_world.tile_at(obstacle)
        if tile != null and (tile.is_bottom_mtn_layer or "ledges3" in (String(tile.name) + " " + String(tile.name_upper))):
            var landing = try_pre_move_field_jump(world.player.position, Vector2(world._facing_cell()))
            if typeof(landing) == TYPE_VECTOR2:
                world.player.position = landing
                world.last_player_cell = world._player_cell()
                world._sync_follower_to_player()
            return
    var jump_direction := world._facing_cell()
    if world.exact_world != null:
        var obstacle_tile := world.exact_world.tile_at(obstacle)
        if obstacle_tile != null and obstacle_tile.is_ledge:
            var ledge_key: String = (obstacle_tile.name + " " + obstacle_tile.name_upper).to_lower()
            var strict_brown_drop: bool = "ledge_grass_down" in ledge_key
            if strict_brown_drop or world.active_field_move != "RIDE":
                var permitted := world._permitted_ledge_direction(obstacle_tile)
                if permitted != jump_direction:
                    world.world_message.emit("That ledge can only be crossed downhill.")
                    return
    var landing := obstacle + jump_direction
    if not world._in_bounds(landing) or not world._is_walkable(landing) or world.built_structures.has(landing):
        world.world_message.emit("There is no room to land beyond it.")
        return
    world.player.position = world._cell_center(landing)
    world.last_player_cell = landing
    world._sync_follower_to_player()
    world.play_source_sound("ride1")
    world.world_message.emit("RIDE cleared the obstacle!")

## per-frame
func field_movement_direction(input_direction: Vector2) -> Vector2:
    if world.active_field_move == "FLY" and world.fly_phase in ["TAKEOFF", "LANDING"]:
        return Vector2.ZERO
    if world.active_field_move in ["CUT", "BUILD", "DIG", "HEADBUTT", "SMASH"] and input_direction.length_squared() > 0.0001:
        # Work Pokemon steer on the same cardinal axes as D-pad input.
        # Retain the current axis near a diagonal to prevent stick jitter.
        var horizontal := absf(input_direction.x)
        var vertical := absf(input_direction.y)
        if horizontal > vertical * 1.20:
            input_direction = Vector2(signf(input_direction.x), 0)
        elif vertical > horizontal * 1.20:
            input_direction = Vector2(0, signf(input_direction.y))
        elif world.player.facing.x != 0:
            input_direction = Vector2(signf(input_direction.x), 0)
        else:
            input_direction = Vector2(0, signf(input_direction.y))
    # Source ice is continuous sliding: once a direction is committed on ice,
    # releasing/turning the stick does not stop or turn the player until the
    # slide leaves ice or meets an obstruction.
    if world.exact_world == null or world.active_area_id != "OVERWORLD" or world.active_field_move in ["FLY", "DIG"]:
        world.ice_slide_direction = Vector2.ZERO
        return input_direction
    var cell = world._player_cell()
    var names := world._exact_names_at(cell)
    var on_ice = not names.is_empty() and world._source_tile_key(names[0]) == "ice2"
    if not on_ice:
        world.ice_slide_direction = Vector2.ZERO
        world.ice_blocked_direction = Vector2.ZERO
        return input_direction
    if world.ice_blocked_direction != Vector2.ZERO:
        if input_direction.dot(world.ice_blocked_direction) > 0.7:
            return Vector2.ZERO
        world.ice_blocked_direction = Vector2.ZERO
    if world.ice_slide_direction == Vector2.ZERO:
        if input_direction.length_squared() <= 0.0001:
            return input_direction
        if absf(input_direction.x) > absf(input_direction.y):
            world.ice_slide_direction = Vector2(1 if input_direction.x > 0.0 else -1, 0)
        else:
            world.ice_slide_direction = Vector2(0, 1 if input_direction.y > 0.0 else -1)
    return world.ice_slide_direction

## per-frame
func field_motion_completed(before: Vector2, after: Vector2, movement_direction: Vector2) -> void:
    if world.active_field_move == "DIG" and world._is_walkable(world._player_cell()):
        world.dig_return_position = world._cell_center(world._player_cell())
    world._animate_walked_gates(before, after)
    _update_source_surf_wake(before, after, movement_direction)
    if world.ice_slide_direction == Vector2.ZERO or world.exact_world == null:
        return
    var after_cell = Vector2i(floori(after.x / World.TILE), floori(after.y / World.TILE))
    var after_names := world._exact_names_at(after_cell)
    var still_on_ice = not after_names.is_empty() and world._source_tile_key(after_names[0]) == "ice2"
    var stopped := before.distance_squared_to(after) < 0.0025 and movement_direction.length_squared() > 0.0001
    if not stopped and still_on_ice:
        _align_ice_slide(after_cell)
    for normal in world.player.slide_normals:
        if normal.dot(world.ice_slide_direction) < -0.5:
            stopped = true
    if stopped: world.ice_blocked_direction = world.ice_slide_direction
    if not still_on_ice or stopped:
        world.ice_slide_direction = Vector2.ZERO

## Slides on ice run along a row or column of tiles, as in the source game,
## where the player is always on one tile. Here a player can be a pixel or two
## off the middle of a row, and a slide along the foot of a wall then caught
## the corner of the next tile of that wall and stopped dead on open ice. The
## sideways offset is taken out a little at a time while sliding, never
## through anything solid.
func _align_ice_slide(cell: Vector2i) -> void:
    var centre := world._cell_center(cell)
    var offset := Vector2(0.0, centre.y - world.player.position.y) if world.ice_slide_direction.x != 0.0 else Vector2(centre.x - world.player.position.x, 0.0)
    if offset.length_squared() < 0.0001:
        return
    # 1 px per 60th of a second, whatever the frame rate.
    var step := offset.limit_length(60.0 * world.frame_delta)
    if not world.player.test_move(world.player.transform, step):
        world.player.position += step

## per-frame
func try_pre_move_field_jump(before: Vector2, movement_direction: Vector2):
    if world.active_field_move != "RIDE" or world.exact_world == null or world.active_area_id != "OVERWORLD":
        return null
    if world.player.has_method("is_ledge_jump_active") and bool(world.player.call("is_ledge_jump_active")):
        return null
    var direction = Vector2i.ZERO
    if absf(movement_direction.x) > absf(movement_direction.y):
        direction = Vector2i(1 if movement_direction.x > 0.0 else -1, 0)
    elif absf(movement_direction.y) > 0.01:
        direction = Vector2i(0, 1 if movement_direction.y > 0.0 else -1)
    if direction == Vector2i.ZERO:
        return null
    var start_cell = Vector2i(floori(before.x / float(World.TILE)), floori(before.y / float(World.TILE)))
    var obstacle_cell = start_cell + direction
    var obstacle = world._frame_tile(obstacle_cell)
    if obstacle == null:
        return null
    var obstacle_key = (String(obstacle.name) + " " + String(obstacle.name_upper)).to_lower()
    var fence := String(obstacle.name_upper) in ["fence1", "fence2", "fence1_NS", "fence2_NS"] or String((world.built_structures.get(obstacle_cell, {}) as Dictionary).get("name", "")) == "FENCE"
    if fence:
        var fence_axis := Vector2i.LEFT if "_NS" in String(obstacle.name_upper) else Vector2i.DOWN
        if world.built_structures.has(obstacle_cell):
            var vertical := false
            var horizontal := false
            for offset in [Vector2i.UP, Vector2i.DOWN, Vector2i.LEFT, Vector2i.RIGHT]:
                if String((world.built_structures.get(obstacle_cell + offset, {}) as Dictionary).get("name", "")) == "FENCE":
                    vertical = vertical or offset.y != 0
                    horizontal = horizontal or offset.x != 0
            if vertical and horizontal:
                return null
            fence_axis = Vector2i.LEFT if vertical else Vector2i.DOWN
        if direction != fence_axis and direction != -fence_axis:
            return null
        var fence_landing = start_cell + direction * 2
        if not world._ledge_jump_landing_is_clear(fence_landing):
            return null
        var fence_position = world._cell_center(fence_landing)
        world.player.call("begin_ledge_jump_visual", before - fence_position)
        set_fly_shadow_active(true)
        world.play_source_sound("ledge1")
        return fence_position
    var current_tile = world._frame_tile(start_cell, 1)
    var mountain_edge := bool(obstacle.is_bottom_mtn_layer) or "ledges3" in obstacle_key
    var leaving_mountain := current_tile != null and (bool(current_tile.is_bottom_mtn_layer) or "ledges3" in (String(current_tile.name) + " " + String(current_tile.name_upper)))
    if mountain_edge or leaving_mountain:
        # Mountain RIDE advances to the adjacent grid cell, never searches
        # across multiple rim layers for a distant plateau.
        if obstacle.is_water or obstacle.is_lava or world.built_structures.has(obstacle_cell) or world.landmarks.has(obstacle_cell) or world.resource_objects.has(obstacle_cell) or world.deployed_pokemon.has(obstacle_cell) or world.wild_eggs.has(obstacle_cell) or world._wild_id_at_cell(obstacle_cell) >= 0:
            return null
        if mountain_edge:
            # Only bypass the mountain edge itself, not objects on that edge.
            if not String(obstacle.name_upper).is_empty() and not "ledges3" in String(obstacle.name_upper):
                return null
        elif not world._ledge_jump_landing_is_clear(obstacle_cell):
            return null
        var mountain_position = world._cell_center(obstacle_cell)
        world.player.call("begin_ledge_jump_visual", before - mountain_position)
        set_fly_shadow_active(true)
        world.play_source_sound("ledge1")
        return mountain_position
    if not (bool(obstacle.is_ledge) or bool(obstacle.is_bottom_mtn_layer) or "ledges3" in obstacle_key):
        return null
    if bool(obstacle.is_ledge) and "ledge_grass_down" in obstacle_key:
        var permitted = world._permitted_ledge_direction(obstacle)
        if permitted == Vector2i.ZERO or direction != permitted:
            return null
    # Mountain rims can span several authored edge cells. Continue across the
    # contiguous rim and land on the first ordinary clear plateau/ground cell.
    for distance in range(2, 8):
        var landing_cell = start_cell + direction * distance
        if not world._ledge_jump_landing_is_clear(landing_cell):
            continue
        var landing_position = world._cell_center(landing_cell)
        if world.player.has_method("begin_ledge_jump_visual"):
            world.player.call("begin_ledge_jump_visual", before - landing_position)
        set_fly_shadow_active(true)
        world.play_source_sound("ledge1")
        return landing_position
    return null

## per-frame
func _update_source_surf_wake(before: Vector2, after: Vector2, direction: Vector2) -> void:
    if world.active_field_move != "SURF" or world.active_area_id != "OVERWORLD" or world.exact_world == null:
        world.source_surf_wake_distance = 16.0
        world.source_surf_wake_direction = Vector2.ZERO
        return
    var distance := before.distance_to(after)
    if distance <= 0.001:
        return
    var cell := Vector2i(floori(before.x / World.TILE), floori(before.y / World.TILE))
    var tile: SourceTile = world._frame_tile(cell)
    if tile == null or not tile.is_water:
        return
    var facing := Vector2(signf(direction.x), 0.0) if absf(direction.x) > absf(direction.y) else Vector2(0.0, signf(direction.y))
    if world.source_surf_wake_direction != facing:
        world.source_surf_wake_distance = 16.0
    world.source_surf_wake_direction = facing
    if world.source_surf_wake_distance >= 16.0:
        world.source_surf_wake_distance = fmod(world.source_surf_wake_distance, 16.0)
        _spawn_source_surf_wake(before, facing)
    world.source_surf_wake_distance += distance

func _spawn_source_surf_wake(anchor: Vector2, facing: Vector2) -> AnimatedSprite2D:
    var vertical := facing.y != 0.0
    var texture: Texture2D = preload("res://assets/source_exact/global/wake2.png") if vertical else preload("res://assets/source_exact/global/wake1.png")
    if not world.source_surf_wake_frames.has(vertical):
        var frames := SpriteFrames.new()
        frames.add_animation("wake")
        frames.set_animation_loop("wake", false)
        frames.set_animation_speed("wake", 60.0)
        for index in range(3):
            var frame := AtlasTexture.new()
            frame.atlas = texture
            frame.region = Rect2(index * 16, 0, 16, 16)
            frames.add_frame("wake", frame, 13.0 if index == 2 else 12.0)
        world.source_surf_wake_frames[vertical] = frames
    var wake := AnimatedSprite2D.new()
    wake.name = "SourceSurfWake"
    wake.sprite_frames = world.source_surf_wake_frames[vertical]
    wake.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
    wake.position = anchor.round() + Vector2(0.0, 0.0 if vertical else 4.0)
    wake.flip_h = facing.x > 0.0
    wake.flip_v = facing.y < 0.0
    wake.z_as_relative = false
    wake.z_index = world.player.z_index - 2
    world.add_child(wake)
    wake.animation_finished.connect(wake.queue_free)
    wake.play("wake")
    return wake

func tick_dig_motion(input_direction: Vector2, speed: float, delta: float) -> void:
    var before := world.player.position
    if not world.dig_step_active and input_direction != Vector2.ZERO:
        var direction := Vector2(world._facing_cell())
        var destination := world._cell_center(world._player_cell() + Vector2i(direction))
        # Check the whole stride before leaving its center. DIG keeps normal
        # physical collision, including mountain edges and buried rewards.
        # The body's lower edge rests exactly on the tile line, so a solid
        # tile below the path (water under the last shore tile) counted as a
        # hit. Test one pixel higher: touching is not being in the way.
        if world.constrain_player_motion(before, destination) == destination and \
                not world.player.test_move(world.player.transform.translated(Vector2.UP), destination - before):
            world.dig_step_direction = direction
            world.dig_step_target = destination
            world.dig_step_active = true
    if world.dig_step_active:
        world.player.facing = world.dig_step_direction
        var next := world.player.position.move_toward(world.dig_step_target, speed * delta)
        world.player.velocity = world.dig_step_direction * speed
        var coordinator=world.get_parent().get("coop_game")
        if is_instance_valid(coordinator) and coordinator.active:
            next=coordinator.visuals.constrain_motion(world.player.position,next)
        # The stride was checked before it began; moving by collision would
        # stop a hair short of a tile it only touches and never arrive.
        world.player.position = next
        if world.player.position.distance_squared_to(world.dig_step_target) < 0.000001:
            world.player.position = world.dig_step_target
            world.dig_step_active = false
    else:
        world.player.velocity = Vector2.ZERO
    field_motion_completed(before, world.player.position, world.dig_step_direction)
    place_field_helper_live()
    if not world.dig_step_active and world.dig_action_pending:
        world.dig_action_pending = false
        use_dig(world._player_cell() + world._facing_cell())

func try_cut_target(cell:Vector2i)->bool:
    # A window or clock comes off before the wall it hangs on.
    if not world.house_wall_decoration_at(cell).is_empty():
        world.structure_removal_requested.emit(cell,"CUT")
        return true
    var coordinator=world.get_parent().get("coop_game")
    if is_instance_valid(coordinator) and coordinator.active and not world.built_structures.has(cell):
        var available=world._is_cuttable_grass_cell(cell) or exact_resource_anchor(cell).x>-2147483648 or resource_object_anchor(cell).x>-2147483648
        if not available:return false
        coordinator.building.cut(cell)
        return true
    if world.built_structures.has(cell):
        var build_name := String((world.built_structures[cell] as Dictionary).get(
            "name", ""
        ))
        if build_name not in ["GRAVE", "STATUE"]:
            world.structure_removal_requested.emit(cell, "CUT")
            return true
    if world._is_cuttable_grass_cell(cell) or exact_resource_anchor(cell).x > -2147483648:
        play_rule(FieldCut.apply(world.area, rule_player(), {"move":"CUT", "cell":cell}, world.rng))
        return true
    var resource_anchor := resource_object_anchor(cell)
    if resource_anchor.x > -2147483648:
        harvest_resource_with_move(resource_anchor, "CUT")
        return true
    return false

## A grass tuft at `cell` cut (a crop there harvested), nothing else.
func cut_grass(cell: Vector2i) -> void:
    if not world._is_cuttable_grass_cell(cell):
        return
    play_rule(FieldCut.apply(world.area, rule_player(), {"move":"CUT", "cell":cell, "target":"grass"}, world.rng))

## What the rules (rules/) are told about the player of this game.
func rule_player(cell: Vector2i = Vector2i.ZERO) -> Dictionary:
    var player := {"area_id":world.active_area_id, "now":world.world_elapsed_seconds, "species":world.active_field_species}
    var coordinator = world.get_parent().get("coop_game") if world.get_parent() != null else null
    if is_instance_valid(coordinator) and coordinator.active: player["shared"] = true
    if world.active_area_id == "HOUSE":
        player["house_key"] = world._built_house_paint_key(cell)
        player["house_floor"] = world._is_built_house_floor_cell(cell)
    player["house"] = world.buildings.house_context()
    return player

## A rule's result (rules/) as this world shows it: sounds and words, the
## rewards through the signals main.gd turns into the bag and its popups,
## redraws. A planting's animation is its caller's to wait for.
func play_rule(result: Dictionary) -> void:
    for event in result.get("events", []):
        match String(event[0]):
            "sound": world.play_source_sound(String(event[1]))
            "message": world.world_message.emit(String(event[1]))
            "dig_reward": world.dig_reward_collected.emit(event[1])
            "item": world.item_collected.emit(String(event[1]))
            "material": world.material_collected.emit(String(event[1]), int(event[2]))
            "bundle": world.material_bundle_collected.emit(event[1])
            "refresh": world._refresh_exact_tile_streams()
            "refresh_cell": world._refresh_exact_pickup_cell(event[1])
            "refresh_around": world.plants()._redraw_around(event[1])
            "farms": _refresh_dig_farms(event[1])
            "collected": _clear_collected_item(event[1])
            "house_decoration": world._draw_house_decoration(event[1])
            "structure": world.buildings.draw_structure(event[1])
            "unbuilt": world.buildings.undraw_structure(event[1], event[2])
            "restyle":
                world.buildings.restyle_around(event[1])
                world.buildings.refresh_shell_attachment(event[1])
            "house_floor": world.interiors.draw_floor_cell(event[1])
            "decoration_gone": world.buildings.undraw_decoration(event[1])
            "painted": world.interiors._set_built_house_paint_sprite(event[1], event[2])
            "refresh_streams": world._refresh_exact_streams()
            "refund": world.build_refund_requested.emit((event[1] as Dictionary).duplicate(true))
            "soil":
                var choice := _dig_action_choice(event[1])
                world.dig_requested.emit(choice, event[1], String(FieldMoveData.dig_choice_info(choice).get("material", "GRASS")))
            "encounter":
                var cell: Vector2i = event[5] if event.size() > 5 else Vector2i.ZERO
                if bool(event[4]):
                    var tile := world.exact_world.tile_at(cell)
                    if tile != null and tile.route_belongs_to != null and not tile.route_belongs_to.stored_pokemon.is_empty():
                        tile.route_belongs_to.stored_pokemon.pop_front()
                world.pending_encounter_record = (event[3] as Dictionary).duplicate(true)
                world.encounter_requested.emit(String(event[1]), int(event[2]))
            "agitated":
                var tile := world.exact_world.tile_at(event[1])
                if tile != null: _clear_agitated_berry_tree(event[1], tile)
            "cut_halves":
                show_cut_halves(event[1], event[2])
                # Online the other players see the same split. Only this
                # player's own cut plays it here (coop_rules_runtime.gd COSMETIC).
                var coop = world.get_parent().get("coop_game") if world.get_parent() != null else null
                if is_instance_valid(coop) and coop.active: coop.visuals.effect({"fx":"cut", "x":event[1].x, "y":event[1].y})

## An item's own sprites and records go when it is taken.
func _clear_collected_item(cell: Vector2i) -> void:
    SourceMansionRuntime.clear_collected_item(world, cell)
    World.SourceMineRuntime.clear_collected_item(world, cell)
    var sprite := world.source_interior_upper_sprites.get(cell) as Sprite2D
    if is_instance_valid(sprite):
        sprite.queue_free()
    world.source_interior_upper_sprites.erase(cell)

func exact_resource_kind(cell: Vector2i) -> String:
    return TileRules.exact_resource_kind(world.area, cell) if world.exact_world != null else ""

func exact_resource_anchor(cell: Vector2i) -> Vector2i:
    return TileRules.exact_resource_anchor(world.area, cell)

func resource_object_anchor(cell: Vector2i) -> Vector2i:
    if world.resource_objects.has(cell):
        return cell
    # Tall compatibility/source-plan resources may expose either half as the
    # cell the player is facing. Resolve both vertical neighbors back to the
    # authored resource anchor. This is required for 16x32 tree4 tundra trees
    # and also makes palm/berry interaction independent of approach side.
    for candidate in [cell + Vector2i.DOWN, cell + Vector2i.UP]:
        if not world.resource_objects.has(candidate):
            continue
        var data: Dictionary = world.resource_objects[candidate]
        var sprite: Sprite2D = data.get("sprite") as Sprite2D
        if is_instance_valid(sprite) and sprite.texture != null and \
                sprite.texture.get_height() > World.TILE:
            return candidate
    return Vector2i(-2147483648, -2147483648)

func exact_berry_name(cell: Vector2i) -> String:
    return TileRules.berry_name(world.area, cell) if world.exact_world != null else ""

func pick_exact_berry_tree(cell: Vector2i) -> void:
    var coordinator=world.get_parent().get("coop_game")
    if is_instance_valid(coordinator) and coordinator.active:
        coordinator.building.pick_berry(cell)
        return
    play_rule(FieldDig.apply(world.area, rule_player(), {"action":"berry", "cell":cell}, world.rng))

func _clear_agitated_berry_tree(cell: Vector2i, tile: SourceTile) -> void:
    await world.get_tree().create_timer(400.0/60.0).timeout
    if world.exact_world == null or world.exact_world.tile_at(cell) != tile: return
    tile.set_names(tile.name, "")
    world.area.drop("source_plant_farms", cell)
    world.area.put("source_interior_mutations", cell, {"kind":"TILE_NAMES","base":tile.name,"upper":""})
    world._refresh_exact_streams()

func finish_shared_agitated_tree(cell:Vector2i,mutation:Dictionary)->void:
    var original_world=world.exact_world
    var delay=maxf(0.0,float(mutation.get("clear_at",0.0))-world.world_elapsed_seconds)
    if delay>0.0:await world.get_tree().create_timer(delay).timeout
    if world.source_interior_mutations.get(cell,{})!=mutation:return
    if world.exact_world==null or world.exact_world!=original_world:return
    var tile:SourceTile=world.exact_world.tile_at(cell)
    if tile==null:return
    tile.set_names(String(mutation.get("base",tile.name)),"")
    world.area.drop("source_plant_farms", cell)
    world._refresh_exact_pickup_cell(cell)

func _exact_tile_is_large_tree(cell: Vector2i) -> bool:
    return TileRules.is_large_tree(world.area, cell) if world.exact_world != null else false

## A giant tree is one visible tile and three invisible ones that only block.
## The original generator turns any incomplete giant tree into a bush, and
## runs that check again after placing the Regi cave. Here the cave (and the
## mansion) can also be placed by a later fallback with no check after it,
## which left invisible blocking tiles round the cave showing the sky. This
## gives those the original's result, a bush, in worlds old and new.
func repair_orphaned_large_trees() -> void:
    if world.exact_world == null:
        return
    # Anchors are read from the store's arrays: a proxy for each of the
    # thousands of cells made this ~220 ms of every load.
    var store: WorldTileStore = world.exact_world.tiles
    var names := store.name_ids
    var tree: int = store.string_ids.get("tree_large1", -1)
    for index in store.with_name(["tree_large1_noSprite"]):
        var rooted := false
        for offset in [Vector2i(-16, 0), Vector2i(0, -16), Vector2i(-16, -16)]:
            var key: Vector2i = store.key_of(index) + offset
            var at := store.index_of(key)
            var anchor: SourceTile = null if at >= 0 else store.tile(key)
            if (at >= 0 and names[at] == tree) or (anchor != null and anchor.name == "tree_large1"):
                rooted = true
                break
        if not rooted:
            var tile: SourceTile = store.proxy(index)
            tile.color = true
            tile.set_names("bush1", "")

func exact_large_tree1_anchor(cell: Vector2i) -> Vector2i:
    return TileRules.large_tree1_anchor(world.area, cell)

func show_cut_halves(cell: Vector2i, as_it_was: SourceTile = null) -> void:
    var tile := as_it_was if as_it_was != null else world.exact_world.tile_at(cell)
    if tile == null:
        return
    var spec: Dictionary = SourceWorldData.render_spec(tile, true)
    if spec.is_empty() or spec.get("texture") == null:
        # The giant tree keeps its whole picture on the base of its first part.
        if "tree_large1" not in tile.name.to_lower():
            return
        spec = SourceWorldData.render_spec(tile, false)
        if spec.is_empty() or spec.get("texture") == null:
            return
    var region: Rect2 = spec["region"]
    var half := floorf(region.size.x / 2.0)
    var corner: Vector2 = world._cell_center(cell) - Vector2(World.TILE, World.TILE) / 2.0 + (spec.get("offset", Vector2.ZERO) as Vector2)
    var holder := Node2D.new()
    holder.z_index = 2
    var over := world.get_node_or_null("DecorLayer")
    (over if over != null else world).add_child(holder)
    var halves: Array[Sprite2D] = []
    for side in range(2):
        var piece := Sprite2D.new()
        piece.texture = spec["texture"]
        piece.centered = false
        piece.region_enabled = true
        piece.region_rect = Rect2(region.position.x + half * side, region.position.y,
            half if side == 0 else region.size.x - half, region.size.y)
        piece.position = corner + Vector2(half * side + (-2.0 if side == 0 else 2.0), 0)
        holder.add_child(piece)
        halves.append(piece)
    var steps := holder.create_tween()
    steps.tween_interval(17.0 / 60.0)
    for step in range(3):
        steps.tween_callback(func(): holder.visible = false)
        steps.tween_interval(2.0 / 60.0)
        steps.tween_callback(func():
            halves[0].position.x -= 2.0
            halves[1].position.x += 2.0
            holder.visible = true)
        steps.tween_interval(2.0 / 60.0)
    steps.tween_callback(holder.queue_free)

func harvest_exact_resource(cell:Vector2i,move:String)->void:
    var coordinator=world.get_parent().get("coop_game")
    if move in ["SMASH","HEADBUTT"] and is_instance_valid(coordinator) and coordinator.active:
        coordinator.building.cut(cell,move)
        return
    if world.exact_world == null:
        return
    play_rule(FieldCut.apply(world.area, rule_player(), {"move":move, "cell":cell, "target":"resource"}, world.rng))

func contextual_ground_name(cell: Vector2i, biome_hint: String = "") -> String:
    return TileRules.contextual_ground_name(world.area, cell, biome_hint)

func harvest_resource_with_move(cell:Vector2i,move:String)->void:
    var coordinator=world.get_parent().get("coop_game")
    if move in ["SMASH","HEADBUTT"] and is_instance_valid(coordinator) and coordinator.active:
        coordinator.building.cut(cell,move)
        return
    if not world.resource_objects.has(cell):
        return
    var data: Dictionary = world.resource_objects[cell]
    var kind := String(data.get("type", ""))
    if move == "CUT":
        if kind not in ["tree", "bush"]:
            world.world_message.emit("CUT can't be used on that.")
            return
        var source_name := world._resource_source_name(data)
        if kind == "tree" and bool(data.get("large", false)) and \
                source_name != "tree4" and \
                not FieldMoveData.is_fully_evolved(world.active_field_species):
            world.world_message.emit("This tree needs a fully evolved Pokemon to CUT it.")
            return
        world._harvest_resource(cell, move)
        return
    if move in ["SMASH", "HEADBUTT"]:
        if kind != "rock":
            world.world_message.emit("%s can't be used on that." % move)
            return
        world._harvest_resource(cell, move)

func cycle_dig_selection(direction: int) -> void:
    var target := field_move_action_cell(world._player_cell() + world._facing_cell(), "DIG")
    # PlayerStanding ignores terrain-selection input while currDigTile is active.
    if not _dig_target_accepts_soil(target):
        return
    world.dig_selection_index = 1 + wrapi(maxi(1, world.dig_selection_index) - 1 + direction, 0, World.DIG_CHOICES.size() - 1)
    _show_current_dig_selection()

func _show_current_dig_selection() -> void:
    # The persistent two-box DIG HUD is authoritative; do not stack a transient
    # message box over it every time L/R changes the selected soil.
    pass

func use_dig(cell: Vector2i) -> void:
    if world.active_field_move == "DIG" and world.dig_step_active:
        world.dig_action_pending = true
        return
    var coordinator=world.get_parent().get("coop_game")
    if is_instance_valid(coordinator) and coordinator.active:
        coordinator.building.dig(cell)
        return
    if world.active_area_id != "HOUSE" and not world._in_bounds(cell): return
    play_rule(FieldDig.apply(world.area, rule_player(cell), {"action":"dig", "cell":cell}, world.rng))

func apply_dig_choice(cell: Vector2i, choice: String) -> bool:
    var result := FieldDig.apply(world.area, rule_player(cell), {"action":"fill", "cell":cell, "choice":choice}, world.rng)
    play_rule(result)
    return bool(result.ok)

func dig_surface(cell: Vector2i) -> void:
    play_rule(FieldDig.apply(world.area, rule_player(cell), {"action":"surface", "cell":cell}, world.rng))

# M74.3.9.24 â€” DIG scope only.  Keep the frozen base implementation for every
# other field move; DIG explicitly recognizes authored soil/fossil surfaces so
# collision bookkeeping cannot make valid ground impossible to dig.
func dig_tile_is_fossil_site(tile: SourceTile) -> bool:
    return TileRules.fossil_site(tile)

func _dig_tile_is_surface(tile: SourceTile) -> bool:
    return TileRules.dig_surface_ok(tile)

func _refresh_dig_farms(changed_cell: Vector2i) -> void:
    # Deployed-Pokemon farming/habitat records use a 7x7 neighborhood. Refresh
    # only records whose habitat window includes the changed soil cell.
    var ecology_name_cache: Dictionary = {}
    for raw_cell in world.deployed_pokemon.keys():
        var farm_cell: Vector2i = raw_cell
        if absi(farm_cell.x - changed_cell.x) > 3 or absi(farm_cell.y - changed_cell.y) > 3:
            continue
        var data: Dictionary = world.deployed_pokemon[farm_cell]
        world.deployed_pokemon[farm_cell] = world._refresh_record_habitat(
            data, farm_cell, ecology_name_cache)
        world.habitat_population.mark(farm_cell)
    # Habitat data is stored back into deployed_pokemon above; no party-ecology
    # signal is emitted because that signal carries a specific Pokemon record.

func _dig_material_at(cell: Vector2i) -> String:
    if world.exact_world != null:
        var tile: SourceTile = world.exact_world.tile_at(cell)
        if tile == null:
            return ""
        var route_name: String = ""
        if tile.route_belongs_to != null:
            route_name = tile.route_belongs_to.name
        return FieldMoveData.dig_material(tile.name, tile.name_upper, tile.biome, route_name)
    if not world._in_bounds(cell) or world.terrain_kind_at(cell) == 0:
        return ""
    return "SOFT SAND" if world.terrain_kind_at(cell) == 1 else "GRASS"

func _dig_surface_name_at(cell: Vector2i) -> String:
    if world.exact_world != null:
        var tile: SourceTile = world.exact_world.tile_at(cell)
        if tile == null:
            return "GROUND"
        if dig_tile_is_fossil_site(tile):
            return "FOSSIL SOIL"
        var biome_name: String = world._source_biome_for_tile(tile).replace("_", " ")
        if not biome_name.is_empty():
            return biome_name
    var material: String = _dig_material_at(cell)
    return material if not material.is_empty() else "GROUND"

func _dig_target_accepts_soil(cell: Vector2i) -> bool:
    if world.active_area_id == "HOUSE":
        return bool(world.built_house_decorations.get(world._built_house_paint_key(cell), {}).get("dig_hole", false))
    if world.exact_world == null:
        return false
    return TileRules.accepts_soil(world.area, cell)

func _dig_action_choice(cell: Vector2i) -> String:
    if not _dig_target_accepts_soil(cell):
        return "HOLE"
    # Retain the approved palette selection for the next fillable target.
    # Source currDigTile is automatic on intact ground, never a fill choice.
    return String(World.DIG_CHOICES[maxi(1, world.dig_selection_index)])

func get_dig_hud_state() -> Dictionary:
    var target: Vector2i = field_move_action_cell(
        world._player_cell() + world._facing_cell(), "DIG")
    var choice := _dig_action_choice(target)
    if choice == "HOLE":
        var material: String = _dig_material_at(target)
        var fossil_site: bool = false
        if world.exact_world != null:
            fossil_site = dig_tile_is_fossil_site(world.exact_world.tile_at(target))
        return {
            "choice": choice,
            "left": "DIG\n%s" % _dig_surface_name_at(target),
            "right": "GET\n%s  x1%s" % [
                material if not material.is_empty() else "--",
                "\nFOSSIL SITE" if fossil_site else ""
            ],
            "target": target,
            "diggable": _field_helper_can_use_work_target(target)
        }
    var info: Dictionary = FieldMoveData.dig_choice_info(choice)
    var needed: String = String(info.get("material", ""))
    return {
        "choice": choice,
        "left": "DIG\n%s" % choice,
        "right": "NEED\n%s  x1" % needed,
        "target": target,
        "diggable": _field_helper_can_use_work_target(target)
    }

func save_source_dig_tile(cell: Vector2i) -> void:
    TileRules.save_dig_tile(world.area, cell)

func dig_is_mountain(tile: SourceTile) -> bool:
    return TileRules.is_mountain(tile)

func connect_source_dig_holes(changed: Vector2i) -> void:
    TileRules.connect_holes(world.area, changed)

func fill_source_dig_holes() -> void:
    if world.exact_world == null or world.active_area_id != "OVERWORLD": return
    var replacements := {}
    # Inspect only edited cells, never scan the full world each frame. Collect
    # before applying so a water pulse advances one hole at a time.
    for cell: Vector2i in world.source_interior_mutations:
        # Names straight from the tile store: no tile object per edited cell.
        var here := world._exact_names_at(cell)
        if here.is_empty() or not here[1].begins_with("hole1"): continue
        var water := false
        var lava := false
        for direction in [Vector2i.UP, Vector2i.DOWN, Vector2i.LEFT, Vector2i.RIGHT]:
            var neighbor := world._exact_names_at(cell + direction)
            if neighbor.is_empty(): continue
            var names := neighbor[0] + " " + neighbor[1]
            if "water" in names: water = true
            elif "lava" in names: lava = true
        if water or lava: replacements[cell] = "soot1" if water and lava else "water2" if water else "lava1"
    for cell in replacements:
        var tile: SourceTile = world.area.edit(cell)
        tile.set_names(replacements[cell], "")
        if tile.is_lava:
            # PkmnMap.adjustTile selects the source lava-sheet variant.
            var suffix := "_"
            if world.rng.randi_range(0, 2) != 0:
                if world.rng.randi_range(0, 1) == 1:
                    suffix += ["S", "", "N"][world.rng.randi_range(0, 2)]
                    suffix += ["W", "", "E"][posmod(cell.x, 3)]
                else:
                    suffix += ["S", "", "N"][posmod(cell.y, 3)]
                    suffix += ["W", "", "E"][world.rng.randi_range(0, 2)]
            tile.set_names("lava1" + suffix, "")
        TileRules.save_dig_tile(world.area, cell)
    for cell in replacements: TileRules.connect_holes(world.area, cell)
    if not replacements.is_empty():
        TileRules.recoastify(world.area, replacements.keys())
        world._refresh_exact_tile_streams()
        world.play_source_sound("sand1")

func collect_source_dig_item(cell: Vector2i) -> bool:
    if world.exact_world == null: return false
    var result := {"events": [], "grant": {}}
    var taken := FieldDig.collect_buried(world.area, cell, result)
    play_rule(result)
    return taken

func _house_dig_target_allowed(cell: Vector2i) -> bool:
    return world._is_built_house_floor_cell(cell) and not world.built_structures.has(cell) and not world.interior_interactables.has(cell) and not world.deployed_pokemon.has(cell) and not world.wild_eggs.has(cell) and not world.blocked.has(cell)
