extends RefCounted

## Travel to the neighbouring worlds: the sky past the map's edge while flying,
## the question at the edge, and the swap of world state when crossing.
## Split out of main.gd; reaches the game through `main`.

var main: GameMain

func _init(owner_main: GameMain) -> void:
    main = owner_main

func _show_flying_edge_sky() -> void:
    var bounds: Rect2i = main.world.get_map_bounds()
    if not is_instance_valid(main.edge_sky):
        main.edge_sky = preload("res://scripts/world_boundary_water.gd").new()
        main.edge_sky.name = "WorldBoundaryWater"
        main.world.get_node("GroundLayer").add_child(main.edge_sky)
        main.edge_sky.configure(main.world)
    main.edge_sky.visible = true
    var camera = main.world.player.camera
    camera.limit_left = bounds.position.x*16-192
    camera.limit_top = bounds.position.y*16-192
    camera.limit_right = bounds.end.x*16+192
    camera.limit_bottom = bounds.end.y*16+192

func check_flying_map_edge() -> void:
    if not main.started or main.generating or main.edge_travel_busy or main._field_ui_blocks_gameplay():
        return
    if main.world.active_area_id != "OVERWORLD" or main.world.active_field_move not in ["FLY","SURF"]: return
    _show_flying_edge_sky()
    var bounds: Rect2i = main.world.get_map_bounds()
    var cell: Vector2i = main.world._player_cell()
    if bounds.has_point(cell):
        if main.world.active_field_move != "SURF": return
        var facing: Vector2i = main.world._facing_cell()
        var intent: Vector2 = main.world.player.input_router.movement_vector()
        if bounds.has_point(cell+facing) or (main.world.player.velocity.dot(Vector2(facing))<=0 and intent.dot(Vector2(facing))<=0): return
        cell += facing
    var direction := Vector2i.ZERO
    if cell.x < bounds.position.x: direction = Vector2i.LEFT
    elif cell.x >= bounds.end.x: direction = Vector2i.RIGHT
    elif cell.y < bounds.position.y: direction = Vector2i.UP
    elif cell.y >= bounds.end.y: direction = Vector2i.DOWN
    main.edge_travel_busy = true
    main.world.set_gameplay_enabled(false)
    _prompt_adjacent_world.call_deferred(direction)

func _prompt_adjacent_world(direction: Vector2i) -> void:
    main.mansion_switch_open = true
    main.mansion_switch_stage = 0
    main.mansion_switch_index = 0
    main.message_panel.hide()
    main.egg_dialogue_label.text = "Going further will take you to a new area... keep going?"
    main.egg_dialogue_arrow.show()
    main.egg_dialogue_panel.show()
    main.egg_choice_panel.hide()
    var accepted: bool = await main.mansion_switch_answered
    main.egg_choice_panel.hide()
    main.egg_dialogue_arrow.hide()
    main.egg_dialogue_panel.hide()
    if accepted:
        await travel_adjacent_world(direction)
    else:
        var bounds: Rect2i = main.world.get_map_bounds()
        var cell: Vector2i = main.world._player_cell()
        cell.x = clampi(cell.x, bounds.position.x, bounds.end.x-1)
        cell.y = clampi(cell.y, bounds.position.y, bounds.end.y-1)
        main.world.player.position = main.world._cell_center(cell)
        main.world.player.facing = -Vector2(direction)
        main.world._place_field_helper_live()
    main.mansion_switch_open = false
    main.edge_travel_busy = false
    main.world.set_gameplay_enabled(not main._field_ui_blocks_gameplay())

func travel_adjacent_world(direction: Vector2i) -> void:
    var online_destination:Dictionary={}
    if is_instance_valid(main.coop_game) and main.coop_game.active:
        online_destination=await main.coop_game.prepare_travel(main.current_world_grid+direction)
        if online_destination.has("error"):main.dialogs.show_message(String(online_destination.error));return
    var bounds: Rect2i = main.world.get_map_bounds()
    var cell: Vector2i = main.world._player_cell()
    var fraction := Vector2(cell-bounds.position)/Vector2(bounds.size)
    var mount: Dictionary = main.world.active_field_pokemon.duplicate(true)
    var travel_move := String(main.world.active_field_move)
    var elapsed: float = main.world.world_elapsed_seconds
    var key := main._world_grid_key(main.current_world_grid)
    main.adjacent_worlds[key] = {"seed":main.world.world_seed,"size":main.world.map_size_index,"state":main.world.get_crafting_save_state()}
    main.current_world_grid += direction
    var destination: Dictionary = main.adjacent_worlds.get(main._world_grid_key(main.current_world_grid), {})
    if not online_destination.is_empty():destination={} if online_destination.get("new",false) else online_destination
    var seed_value := int(destination.get("seed", 0))
    if seed_value == 0:
        var random := RandomNumberGenerator.new()
        random.randomize()
        seed_value = int(random.randi_range(1,2147483646))
    # Java chooses 40000, 50000, 54000 or 56000 radius parameters.
    var size_index := int(destination.get("size", randi_range(1,4)))
    main.generating = true
    var travel_view: Control
    if destination.is_empty():
        # A new area takes minutes to generate. It was shown as a plain grey
        # screen with the player hovering in it and no word of what was
        # happening, so it looked as if the game had stopped. It now has the
        # same sky, trainer tips and message as every other loading screen.
        main.generation_status.text = "GENERATING WORLD...\nPLEASE WAIT..."
        main.dialogs.show_generation_tip()
        main.generation_panel.show()
        await main.get_tree().process_frame
    else:
        main.generation_status.text = "LOADING...\nPLEASE WAIT...."
        main.generation_panel.show()
    await main.world.generate_world(seed_value, size_index, not destination.is_empty())
    if not main.world.generation_error.is_empty():
        main.current_world_grid -= direction
        # Preflight failure leaves the current world's terrain and items intact.
        main.world.player.position = main.world._cell_center(Vector2i(
            clampi(cell.x,bounds.position.x,bounds.end.x-1),
            clampi(cell.y,bounds.position.y,bounds.end.y-1)))
        main.world.player.facing = -Vector2(direction)
        # Failed preflight retains the existing mount along with the world.
        main.world.fly_phase = "HOVER"
        main.world.fly_height = 32.0
        main.world._place_field_helper_live()
        if is_instance_valid(travel_view): travel_view.queue_free()
        main.generation_panel.hide()
        main.generating = false
        main.dialogs.show_message(main.world.generation_error)
        return
    main.world.set_gameplay_enabled(false)
    if not destination.is_empty(): await main.world.restore_crafting_save_state(destination.state)
    main.world.world_elapsed_seconds = elapsed
    main.appearance.apply_world_player_textures()
    bounds = main.world.get_map_bounds()
    cell = bounds.position + Vector2i(Vector2(bounds.size)*fraction)
    cell.x = clampi(cell.x,bounds.position.x,bounds.end.x-1)
    cell.y = clampi(cell.y,bounds.position.y,bounds.end.y-1)
    if direction == Vector2i.LEFT: cell.x = bounds.end.x-1
    elif direction == Vector2i.RIGHT: cell.x = bounds.position.x
    elif direction == Vector2i.UP: cell.y = bounds.end.y-1
    else: cell.y = bounds.position.y
    main.world.player.position = main.world._cell_center(cell)
    main.world.player.facing = Vector2(direction)
    if travel_move == "SURF":
        # Find water along the destination edge rather than mounting on dry land.
        var water_cell := cell
        var found := false
        for offset in range(maxi(bounds.size.x,bounds.size.y)):
            for sign_value in [1,-1]:
                var candidate: Vector2i = cell + (Vector2i.DOWN if direction.x!=0 else Vector2i.RIGHT)*offset*sign_value
                if bounds.has_point(candidate) and main.world.terrain_kind_at(candidate)==0:
                    water_cell=candidate;found=true;break
            if found: break
        if found: main.world.player.position=main.world._cell_center(water_cell)
    main.world.set_active_field_move(mount, travel_move, travel_move=="SURF")
    main.world.fly_phase = "HOVER"
    main.world.fly_height = 32.0
    main.world._place_field_helper_live()
    main.world.begin_encounter_grace()
    # Generating a new area uncovers the map around wherever the player
    # stood in the area they left, which in the new one is somewhere they
    # have never been: a lone explored circle far from where they arrive.
    if destination.is_empty(): main.world.discovered_cells.clear()
    main.world.reveal_player_area()
    main.minimap.invalidate_travel_maps()
    _show_flying_edge_sky()
    main.world.player.camera.reset_smoothing()
    if is_instance_valid(main.coop_game) and main.coop_game.active:
        if not await main.coop_game.finish_travel():
            main.coop_game.end_session("ONLINE AREA COULD NOT BE SAVED. SESSION ENDED.")
            return
    await main._draw_world_view()
    if is_instance_valid(travel_view): travel_view.queue_free()
    main.message_panel.hide()
    main.generation_panel.hide()
    main.generating = false
