# SPDX-License-Identifier: MIT
# Godot integration of the supplied single-player Ball* control patches.
extends Node2D
const Options = preload("res://scripts/game_options.gd")
const Data = preload("res://scripts/pokemon_data.gd")
const Rules = preload("res://scripts/overworld_ball_rules.gd")
const Ring = preload("res://scripts/ball_wheel_ring.gd")
const Clock = preload("res://scripts/game_clock.gd")
const TexturePixels = preload("res://scripts/texture_pixels.gd")
var main: Node
var ring = Ring.new()
var wheel_kind = 0
var wheel_page = 0
var wheel_entries: Array[Dictionary] = []
var busy = false
var throw_serial = 0
var projectile: Sprite2D
var held_target = {}
var held_scale = Vector2.ONE
var held_modulate = Color.WHITE
var held_visible = true
var held_material: Material
var active_scope = ""
var ball_textures = {}
var requested_battler = ""
var hud: Label
var hud_box: PanelContainer
var hud_seconds = 0.0
var next_icon: TextureRect
var next_shown = ""
var next_seconds = 0.0
var was_enabled = false
var actor: Sprite2D
var actor_origin = Vector2.ZERO
var actor_member = {}
var hop_origin = Vector2.ZERO
var hopping = false
var animation_debt = 0.0
var flight_direction = Vector2i.DOWN
var flight_origin = Vector2.ZERO
var party_reserved = {}
var capture_screen: Control
var capture_presenting := false

func world(): return main.world
func scope() -> String:
    return str([world().exact_world.get_instance_id() if world().exact_world!=null else 0,world().active_area_id,world().active_built_house_door])

func state() -> Dictionary:
    if not world().event_progress.has("ball_mechanics"):
        world().event_progress["ball_mechanics"] = {"mode":"CAPTURE","ball":"POKE BALL","member":"","moves":{}}
    return world().event_progress.ball_mechanics

func party_member() -> Dictionary:
    var id = str(state().get("member",""))
    for member in main.caught_pokemon:
        if id!="" and str(member.get("party_ecology_id",""))==id:
            if member.get("is_egg",false) or int(member.get("hp",0))<=0: break
            return member
    state().member = ""
    return {}

func bag_balls() -> Array:
    var result = []
    for ball in Rules.BALLS:
        if int(main.inventory.get(ball,0))>0: result.append(ball)
    return result

func can_act() -> bool:
    return main.started and not main.generating and not busy and not main.field_move_wheel_open and not main._field_ui_blocks_gameplay(world().active_field_move=="BUILD") and world().gameplay_enabled and world().active_field_move!="FLY" and not main._sleeping_bag_active()

func update_input() -> bool:
    if not Options.enabled("ball_mechanics"):
        if was_enabled:
            cancel()
            abandon_flight()
            ring.reset()
            if is_instance_valid(hud_box): hud_box.hide()
            hud_seconds = 0.0
        was_enabled = false
        return false
    if not was_enabled:
        # Changing options must not turn a trigger held in the menu into a throw.
        ring.reset()
        if Input.is_action_pressed("field_move_wheel") or Input.is_action_pressed("ball_mechanics"):
            main.field_wheel_wait_for_release = true
    was_enabled = true
    if main.field_wheel_wait_for_release:
        if not Input.is_action_pressed("field_move_wheel") and not Input.is_action_pressed("ball_mechanics"):
            main.field_wheel_wait_for_release = false
            ring.reset()
        return true
    if main.field_move_wheel_open and main._field_ui_blocks_gameplay(main.build_wheel_mode):
        cancel()
        return true
    var available = [Options.enabled("radial"),not main.caught_pokemon.is_empty(),not bag_balls().is_empty()]
    var idle = main.started and not main.generating and not busy and not main._field_ui_blocks_gameplay(world().active_field_move=="BUILD") and world().gameplay_enabled and not main._sleeping_bag_active()
    var events = ring.update(Input.is_action_pressed("field_move_wheel"),Input.is_action_pressed("ball_mechanics"),Time.get_ticks_msec(),idle,available,can_act())
    for event in events:
        match event[0]:
            "OPEN", "SWITCH": open_wheel(event[1])
            "CLOSE": close_wheel(true)
            "TAP": tap()
    if main.field_move_wheel_open:
        var stick = main._field_move_wheel_stick()
        var count = main.field_move_wheel.entries.size()
        if stick.length()>=0.35 and count>0:
            var step = TAU/count
            var angle = fposmod(atan2(stick.y,stick.x)+PI*0.5,TAU)
            main.field_move_wheel_index = posmod(int(floor((angle+step*0.5)/step)),count)
            main.field_move_wheel.select(main.field_move_wheel_index)
    return true

func open_wheel(kind: int) -> void:
    if main.build_wheel_mode and main.build_menu_open: main.build_panel.visible = true
    wheel_kind = kind
    wheel_page = 0
    if kind==Ring.FIELD:
        main._open_field_move_wheel()
        return
    main.field_move_wheel_open = true
    main.field_move_wheel_index = -1
    main.build_wheel_mode = false
    if main.build_menu_open: main.build_panel.visible = false
    main.message_panel.hide()
    world().set_gameplay_enabled(false)
    configure_wheel()
    main.field_move_wheel.show()

func configure_wheel() -> void:
    wheel_entries.clear()
    if wheel_kind==Ring.BALLS:
        var balls = bag_balls()
        var pages = maxi(1,ceili(balls.size()/8.0))
        wheel_page = posmod(wheel_page,pages)
        for index in range(wheel_page*8,mini(wheel_page*8+8,balls.size())):
            var ball = balls[index]
            wheel_entries.append({"move":ball,"available":true,"texture":ball_texture(ball),"ball":ball,"detail":"x%d  RANGE %d" % [main.inventory[ball],Rules.throw_range(ball)]})
        main.field_move_wheel.configure(wheel_entries)
        main.field_move_wheel.center_title = "POKE BALLS"
        main.field_move_wheel.page_label = "%d / %d  L / R" % [wheel_page+1,pages]
    else:
        for index in range(mini(6,main.caught_pokemon.size())):
            var id = main._ensure_party_ecology_id(index)
            var member = main.caught_pokemon[index]
            var usable = not member.get("is_egg",false) and int(member.get("hp",0))>0
            var move = str(state().moves.get(id,"AUTO"))
            wheel_entries.append({"move":"EGG" if member.get("is_egg",false) else PokemonState.display_name(member).to_upper(),"available":usable,"texture":main._field_move_wheel_icon(str(member.get("species","")),Data.is_shiny(member),str(member.get("form",""))),"member":id,"detail":move if usable else "EGG" if member.get("is_egg",false) else "FAINTED"})
        main.field_move_wheel.configure(wheel_entries)
        main.field_move_wheel.center_title = "PARTY"
        main.field_move_wheel.page_label = "L / R: FIELD MOVE"
    main.field_move_wheel.queue_redraw()

func handle(event: InputEvent) -> bool:
    if not Options.enabled("ball_mechanics"): return false
    if event.is_action_pressed("cancel"):
        cancel()
        return true
    if wheel_kind==Ring.FIELD: return false
    if event.is_action_pressed("shoulder_left") or event.is_action_pressed("shoulder_right"):
        var direction = 1 if event.is_action_pressed("shoulder_right") else -1
        if wheel_kind==Ring.BALLS:
            wheel_page += direction
            main.field_move_wheel_index = -1
            configure_wheel()
        elif main.field_move_wheel_index>=0:
            var index = main.field_move_wheel_index
            var member = main.caught_pokemon[index]
            var id = main._ensure_party_ecology_id(index)
            var moves = ["AUTO"]
            for move in Rules.FIELD_MOVES:
                if move in FieldMoveData.field_moves_for(str(member.get("species",""))):
                    if world().active_field_move in ["SURF","RIDE","FLY"] and move in ["SURF","RIDE","FLY"]: continue
                    moves.append(move)
            var selected = moves.find(state().moves.get(id,"AUTO"))
            state().moves[id] = moves[posmod(maxi(0,selected)+direction,moves.size())]
            configure_wheel()
            main.field_move_wheel.select(index)
        return true
    return true

func cancel() -> void:
    ring.cancel()
    close_wheel(false)
    main.field_wheel_wait_for_release = true

func close_wheel(accept: bool) -> void:
    if not main.field_move_wheel_open: return
    if wheel_kind==Ring.FIELD:
        main._close_field_move_wheel(accept)
        return
    var index = main.field_move_wheel_index
    main.field_move_wheel_open = false
    main.field_move_wheel.hide()
    if main.build_menu_open: main.build_panel.show()
    var resume = not main._field_ui_blocks_gameplay(main.build_menu_open)
    world().set_gameplay_enabled(resume)
    if not accept or not resume or index<0 or index>=wheel_entries.size(): return
    var entry = wheel_entries[index]
    if not entry.available: return
    if wheel_kind==Ring.BALLS:
        state().mode = "CAPTURE"
        state().ball = entry.ball
        show_hud("%s x%d" % [entry.ball,main.inventory.get(entry.ball,0)])
    else:
        state().mode = "PARTY"
        state().member = entry.member
        if is_instance_valid(hud_box): hud_box.hide()
        hud_seconds = 0.0

func show_hud(text: String) -> void:
    if not is_instance_valid(hud):
        # Top right, clear of the minimap, and held to that corner on any
        # screen shape. Drawn in the game's own text frame (the player's chosen
        # border, dark mode included) so it reads over any ground.
        # A row across the top of the screen with the box pushed to its right
        # end: the box then sizes to its text and always ends inside the screen.
        var row := HBoxContainer.new()
        row.name = "BallMechanicsHUD"
        main.get_node("UI").add_child(row)
        row.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
        row.offset_top = 4
        row.offset_right = -6
        row.alignment = BoxContainer.ALIGNMENT_END
        row.z_index = 240
        row.mouse_filter = Control.MOUSE_FILTER_IGNORE
        hud_box = PanelContainer.new()
        row.add_child(hud_box)
        hud_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
        var frame: StyleBoxTexture = main._classic_dialogue_style()
        frame.content_margin_left = 10
        frame.content_margin_right = 10
        frame.content_margin_top = 8
        frame.content_margin_bottom = 5
        hud_box.add_theme_stylebox_override("panel", frame)
        hud = main._source_ui_label(hud_box,"Text",Vector2.ZERO,Vector2.ZERO,8)
    hud.text = text
    # Sits under the FPS counter when that is showing in the same corner.
    (hud_box.get_parent() as Control).offset_top = 15 if main.GameOptions.enabled("fps_counter") else 4
    # Left of the small picture of what the next throw will be.
    (hud_box.get_parent() as Control).offset_right = -24
    hud_box.show()
    hud_seconds = 2.0

## A small picture in the top right corner of what the throw button will send
## out next: the ball it will throw, or the party Pokemon it will call. It
## shows for eleven seconds each time the choice changes and then fades away,
## so a MASTER BALL is not thrown into the sea by someone who thought a
## surfing Pokemon was selected.
func update_next_icon(delta: float) -> void:
    var wanted = ""
    var member = {}
    if Options.enabled("ball_mechanics") and main.started and not main.generating and not main.battle_active and is_instance_valid(world()) and world().generated and not main._field_ui_blocks_gameplay(world().active_field_move=="BUILD"):
        if state().mode=="PARTY":
            member = party_member()
            if not member.is_empty(): wanted = "P|"+str(member.get("party_ecology_id",""))+"|"+str(member.get("species",""))+"|"+str(member.get("form",""))+"|"+str(Data.is_shiny(member))
        if wanted=="" and state().mode!="PARTY":
            var ball = str(state().ball)
            if int(main.inventory.get(ball,0))<=0:
                var balls = bag_balls()
                ball = balls[0] if not balls.is_empty() else ""
            if ball!="": wanted = "B|"+ball
    if wanted=="":
        if is_instance_valid(next_icon): next_icon.hide()
        return
    if not is_instance_valid(next_icon):
        next_icon = TextureRect.new()
        next_icon.name = "BallMechanicsNext"
        main.get_node("UI").add_child(next_icon)
        next_icon.anchor_left = 1.0
        next_icon.anchor_right = 1.0
        next_icon.offset_left = -21
        next_icon.offset_right = -5
        next_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
        next_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
        next_icon.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
        next_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
        next_icon.z_index = 240
        next_shown = ""
    # Under the FPS counter when that is showing in the same corner.
    next_icon.offset_top = 14 if Options.enabled("fps_counter") else 3
    next_icon.offset_bottom = next_icon.offset_top+16
    if wanted!=next_shown:
        next_shown = wanted
        next_seconds = 11.0
        if wanted.begins_with("B|"): next_icon.texture = ball_texture(wanted.substr(2))
        else: next_icon.texture = main._field_move_wheel_icon(str(member.get("species","")).to_lower(),Data.is_shiny(member),str(member.get("form","")).to_lower())
    next_seconds = maxf(0.0,next_seconds-delta/maxf(Engine.time_scale,0.01))
    # The last second is the fade.
    next_icon.modulate.a = clampf(next_seconds,0.0,1.0)
    next_icon.visible = next_seconds>0.0

func _process(delta: float) -> void:
    if not is_instance_valid(main): return
    update_next_icon(delta)
    if hud_seconds>0:
        hud_seconds -= delta
        if (hud_seconds<=0 or main.battle_active) and is_instance_valid(hud_box): hud_box.hide()
    if busy and (not main.started or main.generating or scope()!=active_scope): abandon_flight()

func ball_texture(ball: String) -> Texture2D:
    # Use the active art pack's ball; recolour only its coloured shell.
    var source = SourceWorldData.texture_for("pokeball1")
    var key = str(source.get_instance_id())+ball
    if ball_textures.has(key): return ball_textures[key]
    if ball=="POKE BALL": return source
    var image = preload("res://scripts/ball_shell_colors.gd").recolor(TexturePixels.of(source),ball)
    var texture = ImageTexture.create_from_image(image)
    ball_textures[key] = texture
    return texture

func tap() -> void:
    if not can_act(): return
    if state().mode=="PARTY":
        var member = party_member()
        if member.is_empty(): return
        if str(world().follower_pokemon.get("party_ecology_id",""))==str(state().member):
            recall_follower(member)
            return
        launch(str(member.get("pokeball","POKE BALL")),member)
        return
    var ball = str(state().ball)
    if int(main.inventory.get(ball,0))<=0:
        var balls = bag_balls()
        if balls.is_empty():
            main._show_message("No POKE BALLS!")
            return
        ball = balls[0]
        state().ball = ball
    launch(ball,{})

func tile_at(cell: Vector2i) -> SourceTile:
    if world().active_area_id=="OVERWORLD" and world().exact_world!=null: return world().exact_world.tile_at(cell)
    return world()._source_interior_tile_at_world_cell(cell)

func terrain(cell: Vector2i, direction: Vector2i) -> String:
    if world().built_structures.has(cell) or world().blocked.has(cell): return "BLOCKED"
    return Rules.classify(tile_at(cell),direction)

func target_at(cell: Vector2i) -> int:
    return world()._wild_id_at_cell(cell)

func launch(ball: String, member: Dictionary) -> void:
    if busy: return
    if member.is_empty() and int(main.inventory.get(ball,0))<=0: return
    if member.is_empty() and not main._can_receive_overworld_pokemon():
        main._show_message("There is no room for another POKEMON.")
        return
    if not member.is_empty() and world().active_field_move in ["RIDE","SURF"] and str(world().active_field_pokemon.get("party_ecology_id",""))==str(member.get("party_ecology_id","")):
        world().play_source_sound("bump2")
        return
    if not member.is_empty() and world().same_party_actor(member,world().active_field_pokemon):
        # Commit the handoff only on a throw, never while browsing the party wheel.
        if main.build_menu_open: main._close_build_menu(false)
        world().clear_active_field_move(false)
    var origin: Vector2i = world()._player_cell()
    var direction: Vector2i = world()._facing_cell()
    flight_direction=direction
    flight_origin=world().player.position
    var path = []
    var blocked_cell = origin
    var moves = FieldMoveData.field_moves_for(str(member.get("species",""))) if not member.is_empty() else []
    var choice = str(state().moves.get(str(member.get("party_ecology_id","")),"AUTO"))
    var mega_action = ""
    for distance in range(1,Rules.throw_range(ball)+1):
        var cell = origin+direction*distance
        var ground = tile_at(cell)
        if not member.is_empty() and "CUT" in moves and choice in ["AUTO","CUT"] and ground!=null and ground.is_cuttable and not world().built_structures.has(cell):
            blocked_cell=cell
            break
        if not member.is_empty() and "DIG" in moves and choice in ["AUTO","DIG"] and ground!=null and (world()._dig_is_mountain(ground) or world()._m3924_dig_tile_is_fossil_site(ground) or not ground.has_item.is_empty()):
            blocked_cell=cell
            break
        # A wild Mega stands on a closed tile as a special encounter. A ball or
        # a party Pokemon thrown at one begins that encounter, as walking up
        # to it does; either used to stop there as if thrown at a rock.
        var encounter = str(world().interior_interactables.get(cell,""))
        if encounter.begins_with("SPECIAL:") and preload("res://scripts/biome_megas.gd").is_mega(encounter.trim_prefix("SPECIAL:")):
            mega_action = encounter
            blocked_cell = cell
            break
        if terrain(cell,direction) in ["NONE","BLOCKED"]:
            blocked_cell = cell
            break
        path.append(cell)
    if path.is_empty() and member.is_empty():
        if not mega_action.is_empty(): world()._use_interior_interactable(mega_action,blocked_cell)
        else: world().play_source_sound("bump2")
        return
    if member.is_empty(): main.inventory[ball] = maxi(0,int(main.inventory.get(ball,0))-1)
    busy = true
    animation_debt = 0.0
    throw_serial += 1
    var serial = throw_serial
    active_scope = scope()
    projectile = Sprite2D.new()
    projectile.texture = ball_texture(ball)
    projectile.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
    projectile.z_as_relative = false
    world().add_child(projectile)
    projectile.position = world()._cell_center(origin)
    world().play_source_sound("throw_pokeball1")
    var online = is_instance_valid(main.coop_game) and main.coop_game.active
    if online:
        var cells = []
        for cell in path:
            cells.append(cell.x)
            cells.append(cell.y)
        main.coop_game.visuals.effect({"fx":"ball","ball":ball,"cells":cells,"frames":Rules.frames_per_tile(ball),"ox":origin.x,"oy":origin.y,"serial":serial})
    if member.is_empty(): show_hud(ball+" x"+str(main.inventory.get(ball,0)))
    var flown = []
    for cell in path:
        var start = projectile.position
        var end: Vector2 = world()._cell_center(cell)
        if not await animate_flight(start,end,Rules.frames_per_tile(ball)/60.0,serial): return
        flown.append(cell)
        if protected_actor_at(cell):
            if online: main.coop_game.visuals.effect({"fx":"ball_stop","serial":serial,"count":flown.size()})
            if member.is_empty(): await knock_away(ball,cell,direction,serial)
            else: await party_landing(member,cell-direction,cell,-1,serial)
            finish_flight(serial)
            return
        var target = target_at(cell)
        if target>=0:
            if online: main.coop_game.visuals.effect({"fx":"ball_stop","serial":serial,"count":flown.size()})
            if member.is_empty(): await capture(target,ball,direction,serial)
            else: await party_landing(member,cell,cell,target,serial)
            finish_flight(serial)
            return
    if not mega_action.is_empty():
        if online: main.coop_game.visuals.effect({"fx":"ball_stop","serial":serial,"count":flown.size()})
        if member.is_empty():
            # The ball is not spent: it comes back for the battle it began.
            main.inventory[ball] = int(main.inventory.get(ball,0))+1
            show_hud(ball+" x"+str(main.inventory.get(ball,0)))
        elif world().active_field_move in ["SURF","RIDE"]:
            world().play_source_sound("bump2")
            finish_flight(serial)
            return
        else:
            # The Pokemon thrown is the one sent out first.
            requested_battler = str(member.get("party_ecology_id",""))
        finish_flight(serial)
        world()._use_interior_interactable(mega_action,blocked_cell)
        return
    if member.is_empty():
        var candidates = flown.duplicate()
        candidates.reverse()
        if not await drop_ball(ball,candidates):
            main._show_message("The ball sank!" if terrain(path.back(),direction)=="WATER" else "The ball was lost!")
    else:
        await party_landing(member,path.back() if not path.is_empty() else origin,blocked_cell,-1,serial)
    finish_flight(serial)

func animate_flight(start: Vector2, end: Vector2, seconds: float, serial: int) -> bool:
    var count = maxi(1,roundi(seconds*60))
    for frame in range(count):
        if not await frames(1,serial) or not is_instance_valid(projectile): return false
        var ratio = (frame+1)/float(count)
        projectile.position = start.lerp(end,ratio)+Vector2(0,-sin(ratio*PI)*3)
        projectile.z_index = world()._depth_z(Vector2i(end/16),22)
    projectile.position = end
    return true

func frames(count: int, serial: int) -> bool:
    animation_debt += count/60.0
    while animation_debt>0:
        await get_tree().process_frame
        if serial!=throw_serial: return false
        if main.battle_active or main._field_ui_blocks_gameplay(main.build_menu_open): continue
        animation_debt -= get_process_delta_time()
    return true

func drop_ball(ball: String, candidates: Array) -> bool:
    var online = is_instance_valid(main.coop_game) and main.coop_game.active
    if online:
        # Online the host puts the ball on the ground for everyone, and takes it
        # out of the bag as it does. Hand back the one the throw already took.
        main.inventory[ball] = int(main.inventory.get(ball,0))+1
        var give_up := Time.get_ticks_msec() + 2000
        while main.coop_game.active and main.coop_game._request_busy and Time.get_ticks_msec() < give_up:
            await get_tree().process_frame
    for cell in candidates:
        var tile = tile_at(cell)
        if tile==null or tile.is_water or tile.is_lava or tile.is_ledge or not tile.name_upper.is_empty(): continue
        if online:
            if await main.coop_game.drop_item(ball,1,cell,true): return true
            continue
        var drops = world().dropped_items()
        var key = drops.key(cell)
        if drops.records.has(key) and drops.records[key].item==ball:
            drops.records[key].amount += 1
            return true
        if drops.drop(ball,1,cell): return true
    if online: main.inventory[ball] = maxi(0,int(main.inventory.get(ball,0))-1)
    return false

func abandon_flight() -> void:
    if is_instance_valid(main.coop_game) and main.coop_game.active and not main.battle_active and not main.coop_game.wild.encounter.is_empty() and not main.coop_game.wild.finishing:
        main.coop_game.wild.finish_encounter("ran")
    if is_instance_valid(capture_screen):
        capture_screen.queue_free()
        capture_screen = null
    if capture_presenting:
        capture_presenting = false
        world().set_gameplay_enabled(not main._field_ui_blocks_gameplay(main.build_menu_open))
    throw_serial += 1
    restore_target()
    party_reserved.erase("ball_reserved")
    party_reserved={}
    if is_instance_valid(projectile): projectile.queue_free()
    projectile = null
    if is_instance_valid(actor): actor.queue_free()
    actor = null
    if hopping:
        world().player.position = hop_origin
        world().player.set_field_visual_offset(Vector2.ZERO)
        world().set_gameplay_enabled(not main._field_ui_blocks_gameplay(main.build_menu_open))
        hopping = false
    busy = false

func finish_flight(serial: int) -> void:
    if serial!=throw_serial: return
    if is_instance_valid(capture_screen):
        capture_screen.queue_free()
        capture_screen = null
    if capture_presenting:
        capture_presenting = false
        world().set_gameplay_enabled(not main._field_ui_blocks_gameplay(main.build_menu_open))
    restore_target()
    party_reserved.erase("ball_reserved")
    party_reserved={}
    if is_instance_valid(projectile): projectile.queue_free()
    projectile = null
    if is_instance_valid(actor): actor.queue_free()
    actor = null
    busy = false

func restore_target() -> void:
    if held_target.is_empty(): return
    held_target.erase("ball_reserved")
    var sprite = held_target.get("sprite")
    if is_instance_valid(sprite):
        sprite.scale = held_scale
        sprite.modulate = held_modulate
        sprite.visible = held_visible
        sprite.material = held_material
    held_target = {}

## The catch, played where it happens: the Pokemon is drawn into the ball on its
## own tile, the ball rocks once for each shake, then it clicks shut or bursts
## open. Timings match the battle version. Returns false if the throw was
## abandoned part way.
var pause_debt := 0.0

## count/60 s, carrying overshoot: a run of one-frame timers took twice as
## long at 30 FPS.
func capture_pause(count: int, serial: int) -> bool:
    pause_debt += count/60.0
    while pause_debt > 0.0:
        await get_tree().process_frame
        pause_debt -= get_process_delta_time()
    return serial==throw_serial and is_instance_valid(projectile)

func present_capture(sprite: Sprite2D, center: Vector2, ball: String, outcome: int, serial: int) -> bool:
    projectile.texture = ball_texture(ball)
    projectile.position = center
    projectile.z_index = sprite.z_index+1
    projectile.show()
    world().play_source_sound("poof1")
    sprite.modulate = Color(1,0.3,0.3)
    for step in range(9):
        if not await capture_pause(1,serial) or not is_instance_valid(sprite): return false
        sprite.scale = held_scale*(1.0-(step+1)/9.0)
    sprite.hide()
    var key = "capture_wiggle:"+ball+str(preload("res://scripts/gen3_overhaul.gd").enabled)
    if not ball_textures.has(key):
        ball_textures[key] = ImageTexture.create_from_image(preload("res://scripts/ball_shell_colors.gd").recolor(TexturePixels.of(preload("res://assets/source_exact/global/pokeball_wiggleSheet1_color.png")),ball))
    var sheet: Texture2D = ball_textures[key]
    if not await capture_pause(12,serial): return false
    for shake in range(3 if outcome<0 else outcome):
        if not await capture_pause(24,serial): return false
        world().play_source_sound("pokeball_wiggle1")
        for pose in [1,2,0,2,0]:
            var frame = AtlasTexture.new()
            frame.atlas = sheet
            frame.region = Rect2(pose*12,0,12,12)
            projectile.texture = frame
            if not await capture_pause(3,serial): return false
    if outcome<0:
        if not await capture_pause(24,serial): return false
        var stars = []
        for offset in [Vector2(-9,-7),Vector2(0,-12),Vector2(9,-7)]:
            var star = Sprite2D.new()
            star.texture = preload("res://scripts/menu_symbol_palette.gd").shiny()
            star.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
            star.position = offset
            projectile.add_child(star)
            stars.append(star)
        if not await capture_pause(20,serial): return false
        for star in stars: star.queue_free()
    return true

func capture(id: int, ball: String, direction: Vector2i, serial: int) -> void:
    if not world().wild_pokemon.has(id): return
    var record: Dictionary = world().wild_pokemon[id]
    var cell: Vector2i = record.cell
    if not Rules.eligible(record):
        world().play_source_sound("bump2")
        var side = Vector2i(direction.y,-direction.x)
        var recovered = await drop_ball(ball,[cell+direction,cell+side,cell-side])
        main._show_message("It knocked the ball away!"+("" if recovered else " The ball was lost!"))
        return
    var online=is_instance_valid(main.coop_game) and main.coop_game.active
    if online:
        if not await main.coop_game.wild.reserve(id):return
    var saved = world()._serializable_ecology_record(record,cell)
    for key in record.get("source_record",{}):
        if not saved.has(key): saved[key] = record.source_record[key]
    var capture_level: int = 70 if not str(record.get("source_record", {}).get("rare_legendary", "")).is_empty() else world()._effective_wild_level(int(record.level))
    var pokemon = BattleEngine.make_pokemon(str(record.species),capture_level,world().rng,saved)
    var facing = record.get("ball_facing",record.get("facing",Vector2.DOWN))
    var alert = float(record.get("ball_alert_until",0))>world().world_elapsed_seconds
    var stealth = not record.get("aggro_player",false) and not alert and int(record.get("flee_steps",0))<=0 and Vector2(facing)!=-Vector2(direction)
    var ground = tile_at(cell)
    var result = Rules.roll(pokemon,main.caught_pokemon,ball,{"stealth":stealth,"alert":alert,"water":ground!=null and ground.is_water,"dusk":world().active_area_id!="OVERWORLD" or main._world_source_time_of_day()=="night"},world().rng)
    record.ball_reserved = true
    held_target = record
    var sprite: Sprite2D = record.get("sprite")
    if not is_instance_valid(sprite):
        if online:await main.coop_game.wild.finish_encounter("ran")
        return
    held_scale = sprite.scale
    held_modulate = sprite.modulate
    held_visible = sprite.visible
    held_material = sprite.material
    var center: Vector2 = world()._cell_center(cell)
    var movement = record.get("ball_move_tween")
    if movement is Tween and movement.is_valid(): movement.kill()
    sprite.position = center
    projectile.hide()
    capture_presenting = true
    world().set_gameplay_enabled(false)
    if Options.enabled("battle_animations"):
        # The player may walk about while the ball rocks; the catch itself is
        # already decided and the Pokemon is held for it.
        world().set_gameplay_enabled(true)
        if not await present_capture(sprite,center,ball,result,serial): return
        world().set_gameplay_enabled(false)
    sprite.hide()
    if result<0:
        if not main._can_receive_overworld_pokemon():
            main._show_message("There is no room for another POKEMON.")
            if online:await main.coop_game.wild.finish_encounter("ran")
            return
        var recipients = BattleEngine.experience_recipients(main.caught_pokemon,[],main._first_healthy_party_index(),true)
        pokemon.pokeball = ball
        if ball=="HEAL BALL":
            pokemon.hp = pokemon.max_hp
            pokemon.status = ""
            pokemon.sleep_turns = 0
            pokemon.toxic_counter = 0
            for move in pokemon.moves: pokemon.pp[move] = int(Data.move_info(move).get("pp",0))
        if ball=="FRIEND BALL": pokemon.friendship = 200
        for key in ["source_record","cell","id","ball_reserved","x","y"]: pokemon.erase(key)
        preload("res://scripts/rare_biome_legendaries.gd").captured(world(), str(record.get("source_record", {}).get("rare_legendary", "")))
        world()._remove_wild_pokemon(id)
        held_target = {}
        var destination = main._route_received_pokemon(pokemon)
        if not str(pokemon.species) in main.caught_species: main.caught_species.append(str(pokemon.species))
        world().play_source_sound("fanfare1")
        var notices = ["All right! %s was caught!" % PokemonState.display_name(pokemon).to_upper()]
        var notice = main._received_pokemon_notice(pokemon,destination)
        if not notice.is_empty(): notices.append(notice)
        # EXP from a field catch is given where the player stands. Only a move
        # that needs one forgotten, or an evolution, opens the progression
        # screen, because those need the player's answer.
        var follow_up = quiet_experience(pokemon,recipients,notices)
        show_notices(notices)
        if not follow_up.is_empty():
            main.field_item_busy = true
            world().set_gameplay_enabled(false)
            # A fifth move is settled in a window over the world.
            for index in follow_up:
                for move in follow_up[index]: await choose_move(index,move)
            # Evolution keeps its full screen.
            var evolving = false
            for index in follow_up:
                if not BattleEngine.evolution_target(main.caught_pokemon[index],main.caught_pokemon,main._world_source_time_of_day()).is_empty(): evolving = true
            if evolving:
                var previous_progression = main.overworld_evolution_running
                var previous_actor = main.battle_player
                main.overworld_evolution_running = true
                main.capture_experience_presenting = true
                for index in follow_up:
                    await main._check_reward_evolution(main.caught_pokemon[index],index)
                main.progression_active = false
                main.overworld_evolution_running = previous_progression
                main.battle_player = previous_actor
                main.capture_experience_presenting = false
                main._hide_progression_overlay()
            main.field_item_busy = false
            world().set_gameplay_enabled(not main._field_ui_blocks_gameplay(main.build_menu_open))
    else:
        world().play_source_sound("poof1")
        projectile.hide()
        restore_target()
        record.ball_alert_until = world().world_elapsed_seconds+30.0
        # A fully evolved Pokemon that breaks out turns on the player. One at
        # its first stage runs from them. A middle stage only takes notice.
        var stage = evolution_stage(str(record.get("species","")))
        if stage=="ADULT" or record.get("aggro_player",false) or world()._wild_chases_when_provoked(record):
            record.aggro_player = true
            record.source_aggro_emote_seconds = 241.0/60.0
            world()._show_ecology_emote(sprite,"skull")
        elif stage=="BABY" or record.get("behavior",{}).get("flee",false):
            record.ball_flee_until = world().world_elapsed_seconds+FLEE_SECONDS
            world()._show_ecology_emote(sprite,"alert")
        else: world()._show_ecology_emote(sprite,"alert")
        world().begin_encounter_grace(0.5)
    if online:
        var aftermath:Dictionary={}
        if result>=0:
            for key in ["aggro_player","ball_alert_until","flee_steps","ball_flee_until"]:
                if record.has(key):aftermath[key]=record[key]
        await main.coop_game.wild.finish_encounter("captured" if result<0 else "ran",aftermath)

## Gives the catch's EXP without leaving the overworld. Levels and moves that
## fit are applied at once and written into `notices`. Returns, per party slot,
## the moves that still need one forgotten (an empty list when only an
## evolution is due); an empty result means nothing needs the player.
func quiet_experience(defeated: Dictionary, recipients: Array, notices: Array) -> Dictionary:
    var follow_up = {}
    if recipients.is_empty(): return follow_up
    var reward = BattleEngine.experience_reward(defeated,recipients.size())
    for index in recipients:
        var member: Dictionary = main.caught_pokemon[index]
        var title = PokemonState.display_name(member).to_upper()
        var species = str(member.get("species","machop"))
        var started = int(member.get("level",1))
        var total = int(member.get("exp",BattleEngine.exp_for_level(species,started)))+maxi(0,reward)
        var waiting = []
        var learned = []
        while int(member.get("level",1))<100 and total>=BattleEngine.exp_for_level(species,int(member.level)+1):
            for raw in BattleEngine.gain_level(member).get("moves",[]):
                var move = str(raw).to_upper().replace(" ","_")
                if (member.get("moves",[]) as Array).has(move) or move in waiting: continue
                if (member.get("moves",[]) as Array).size()<4:
                    if BattleEngine.learn_move(member,move): learned.append(move)
                else: waiting.append(move)
        member["exp"] = total
        main.caught_pokemon[index] = member
        var line = "%s +%d EXP" % [title,reward]
        if int(member.level)>started: line += ", now L%d!" % int(member.level)
        notices.append(line)
        for move in learned: notices.append("%s learned %s!" % [title,move.replace("_"," ")])
        if not waiting.is_empty() or not BattleEngine.evolution_target(member,main.caught_pokemon,main._world_source_time_of_day()).is_empty():
            follow_up[index] = waiting
    return follow_up

## Asks which move to forget for one new move, in a window over the world.
func choose_move(index: int, move: String) -> void:
    var member: Dictionary = main.caught_pokemon[index]
    var title = PokemonState.display_name(member).to_upper()
    var window = preload("res://scripts/field_move_choice.gd").new()
    main.get_node("UI").add_child(window)
    var slot: int = await window.ask(main,member,move)
    if slot<0 or slot>=(member.get("moves",[]) as Array).size():
        main._show_message("%s did not learn %s." % [title,move.replace("_"," ")])
        return
    var old = str(member.moves[slot])
    if BattleEngine.learn_move(member,move,slot):
        main.caught_pokemon[index] = member
        world().play_source_sound("fanfare1")
        main._show_message("%s forgot %s and learned %s!" % [title,old.replace("_"," "),move.replace("_"," ")])

## Short lines in the ordinary message box, a few at a time, while play goes on.
func show_notices(notices: Array) -> void:
    var serial = throw_serial
    for start in range(0,notices.size(),3):
        main._show_message("\n".join(notices.slice(start,start+3)))
        if start+3<notices.size():
            await get_tree().create_timer(2.2).timeout
            if serial!=throw_serial and main.battle_active: return

func party_landing(member: Dictionary, cell: Vector2i, target_cell: Vector2i, wild_id: int, serial: int) -> void:
    var member_id = str(member.get("party_ecology_id",""))
    if party_member().is_empty() or str(party_member().get("party_ecology_id",""))!=member_id: return
    var choice = str(state().moves.get(member_id,"AUTO"))
    var moves = FieldMoveData.field_moves_for(str(member.get("species","")))
    # AUTO explicitly means the normal follower, even when the throw hits a
    # resource or wild Pokemon. Specific moves retain their action paths.
    # A Pokemon that can only swim cannot follow on land. Thrown at water on
    # AUTO it is surfed on, rather than appearing at the shore and going back.
    if choice == "AUTO" and "SURF" in moves and bool(Data.info(str(member.get("species",""))).get("overworld_behavior",{}).get("swim_only",false)) and terrain(cell,flight_direction)=="WATER" and world().active_area_id=="OVERWORLD" and world().active_field_move not in ["SURF","RIDE"]:
        choice = "SURF"
    # AUTO thrown at a wild Pokemon sends this one out to fight it, as in the
    # Java game. Thrown anywhere else it comes out to follow.
    if choice == "AUTO" and wild_id < 0:
        var follow_cell = cell
        if not world()._is_walkable(follow_cell) or protected_actor_at(follow_cell) or world()._wild_id_at_cell(follow_cell) >= 0:
            follow_cell = world()._player_cell()
        if not await appear_actor(member, follow_cell, serial): return
        world().set_active_field_move(member, "FOLLOW")
        return
    if wild_id>=0:
        var wild: Dictionary = world().wild_pokemon.get(wild_id,{})
        if wild.is_empty(): return
        if not Rules.eligible(wild):
            world().play_source_sound("bump2")
            return
        wild.ball_reserved=true
        party_reserved=wild
        var at=cell-flight_direction
        if not world()._is_walkable(at) or protected_actor_at(at): at=Vector2i(flight_origin/16)
        if not await appear_actor(member,at,serial): return
        wild.erase("ball_reserved")
        party_reserved={}
        if "CHARM" in moves and choice == "CHARM" and not world()._wild_chases_when_provoked(wild):
            wild.charmed = true
            wild.ball_charm_until = world().world_elapsed_seconds+30.0
            world()._show_ecology_emote(wild.get("sprite"),"heart")
            if choice=="CHARM": world().set_active_field_move(member,choice)
            else: await recall_actor(serial)
            return
        requested_battler = member_id
        if world().active_field_move in ["SURF","RIDE"]:
            requested_battler = ""
            world().play_source_sound("bump2")
            return
        world()._begin_wild_encounter(wild_id,true)
        return
    # A throw never relocates the player or rewrites BUILD/DIG helper placement.
    var land = cell
    var direction: Vector2i = flight_direction
    if choice == "DIG":
        target_cell = land + direction
    elif target_cell==Vector2i(flight_origin/16): target_cell = cell
    var tile = tile_at(target_cell)
    var action = ""
    var resource = world()._exact_resource_kind(target_cell) if world().active_area_id=="OVERWORLD" else ""
    if resource in ["tree","bush","cactus"] or (tile!=null and tile.is_cuttable):
        if "CUT" in moves and choice in ["AUTO","CUT"]: action = "CUT"
        elif "HEADBUTT" in moves and choice in ["AUTO","HEADBUTT"]: action = "HEADBUTT"
    elif resource=="rock":
        if "HEADBUTT" in moves and choice in ["AUTO","HEADBUTT"]: action = "HEADBUTT"
        elif "SMASH" in moves and choice in ["AUTO","SMASH"]: action = "SMASH"
    elif str(world().interior_interactables.get(target_cell,"")).begins_with("ITEM:") and choice=="AUTO": action = "FETCH"
    elif world().interior_interactables.get(target_cell,"")=="FOSSIL_MACHINE" and "POWER" in moves and choice in ["AUTO","POWER"]: action = "POWER"
    elif tile!=null and "DIG" in moves and choice in ["AUTO","DIG"] and (choice=="DIG" or world()._dig_is_mountain(tile) or world()._m3924_dig_tile_is_fossil_site(tile) or not tile.has_item.is_empty()): action = "DIG"
    var mounted = world().active_field_move in ["SURF","RIDE"]
    var mount = ""
    if action.is_empty() and not mounted and world().active_area_id=="OVERWORLD":
        if terrain(land,direction)=="WATER":
            if "SURF" in moves and choice in ["AUTO","SURF"]: mount = "SURF"
            elif "FLY" in moves and choice in ["AUTO","FLY"]: mount = "FLY"
        elif "RIDE" in moves and choice in ["AUTO","RIDE"]: mount = "RIDE"
        elif "FLY" in moves and choice in ["AUTO","FLY"]: mount = "FLY"
    if terrain(land,direction)=="WATER" and mount.is_empty():
        # Non-swimmers backtrack to the last clear tile instead of vanishing in water.
        while land!=world()._player_cell() and terrain(land,direction)=="WATER": land-=direction
    if protected_actor_at(land) or world()._wild_id_at_cell(land)>=0: return
    if mount.is_empty() and land!=world()._player_cell() and not world()._is_walkable(land): return
    if not await appear_actor(member,land,serial): return
    if not mount.is_empty():
        await mount_actor(member,land,mount,serial)
        return
    var previous_mon = world().active_field_pokemon
    var previous_species = world().active_field_species
    # Synchronous one-shot field actions use their normal eligibility/rewards.
    world().active_field_pokemon = member
    world().active_field_species = str(member.species)
    requested_battler = member_id
    world().set_meta("ball_action_reward", true)
    match action:
        "CUT":
            if world()._is_cuttable_grass_cell(target_cell): world()._cut_tall_grass(target_cell)
            else: world()._harvest_exact_resource(target_cell,action)
        "SMASH", "HEADBUTT": world()._use_headbutt(target_cell)
        "DIG":
            if not protected_actor_at(target_cell) and world()._wild_id_at_cell(target_cell)<0:
                world()._use_dig(target_cell)
        "POWER":
            world().event_progress.fossil_machine_powered = true
            world()._use_interior_interactable("FOSSIL_MACHINE",target_cell)
    world().remove_meta("ball_action_reward")
    world().active_field_pokemon = previous_mon
    world().active_field_species = previous_species
    if main.battle_active or main.battle_entry_pending: return
    requested_battler = ""
    if action=="FETCH" and world().interior_interactables.has(target_cell):
        world()._use_interior_interactable(str(world().interior_interactables[target_cell]),target_cell)
    if not main.battle_active:
        if choice in moves and choice not in ["AUTO","CUT","DIG","HEADBUTT","SMASH","FLY","SURF","RIDE"] and not mounted:
            if world().set_active_field_move(member,choice):
                if choice == "BUILD": main._open_build_menu()
        else:
            await recall_actor(serial)

const FLEE_SECONDS = 60.0

## BABY: first of a line that goes on to evolve. MIDDLE: evolved, and evolves
## again. ADULT: nothing left to evolve into, which includes Pokemon that never
## evolve at all.
func evolution_stage(species: String) -> String:
    var Ecology = preload("res://scripts/pokemon_ecology.gd")
    var kind = Ecology.normalize_species(species)
    if (Data.info(kind).get("evolutions",[]) as Array).is_empty(): return "ADULT"
    return "BABY" if Ecology.base_species_for(kind)==kind else "MIDDLE"

## A ball thrown at one of the player's own Pokemon is batted aside: it hops
## off at a slant and lands on the ground, and the Pokemon shows a heart.
func knock_away(ball: String, cell: Vector2i, direction: Vector2i, serial: int) -> void:
    var side = Vector2i(direction.y,-direction.x)
    if world().rng.randi_range(0,1)==1: side = -side
    var landing = Vector2i(-2147483648,-2147483648)
    for candidate in [cell-direction+side,cell-direction-side,cell+side,cell-side,cell-direction]:
        var ground = tile_at(candidate)
        if ground==null or ground.is_water or ground.is_lava or ground.is_ledge or not ground.name_upper.is_empty(): continue
        if protected_actor_at(candidate) or target_at(candidate)>=0 or candidate==world()._player_cell(): continue
        landing = candidate
        break
    world().play_source_sound("ledge1")
    var owned: Dictionary = world().deployed_pokemon.get(cell,{})
    var keeper = owned.get("sprite") as Sprite2D
    if not is_instance_valid(keeper) and not world().follower_pokemon.is_empty() and world().follower_cell==cell:
        keeper = world().follower_pokemon.get("sprite") as Sprite2D
    world()._show_ecology_emote(keeper,"heart")
    if landing.x<=-2147483648:
        if not await drop_ball(ball,[cell+direction,cell+side,cell-side]): main._show_message("The ball was lost!")
        return
    var start: Vector2 = projectile.position
    var end: Vector2 = world()._cell_center(landing)
    for frame in range(14):
        if not await frames(1,serial) or not is_instance_valid(projectile): return
        var ratio = (frame+1)/14.0
        projectile.position = start.lerp(end,ratio)+Vector2(0,-sin(ratio*PI)*9)
        projectile.z_index = world()._depth_z(landing,22)
    if not await drop_ball(ball,[landing,cell+side,cell-side]): main._show_message("The ball was lost!")

func protected_actor_at(cell: Vector2i) -> bool:
    return world().deployed_pokemon.has(cell) or world().wild_eggs.has(cell) or (not world().follower_pokemon.is_empty() and world().follower_cell==cell) or (not world().field_helper_pokemon.is_empty() and world().field_helper_cell==cell)

func appear_actor(member: Dictionary, cell: Vector2i, serial: int) -> bool:
    actor = Sprite2D.new()
    actor_member = member
    actor.texture = Data.record_texture(member,"overworld")
    if actor.texture==null: actor.queue_free(); actor=null; return false
    actor.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
    actor.z_as_relative = false
    world().add_child(actor)
    world()._configure_overworld_sprite(actor)
    actor.position = world()._cell_center(cell)
    if cell==world()._player_cell(): actor.position+=Vector2(flight_direction)*8
    actor_origin = flight_origin
    actor.z_index = world()._depth_z(cell)
    world()._set_overworld_motion_frame(actor,Vector2(world()._facing_cell()),0)
    actor.hide()
    if not await frames(6,serial): return false
    if is_instance_valid(projectile): projectile.hide()
    world().play_source_sound("poof1")
    actor.show()
    actor.material=silhouette(Color.WHITE)
    var original = actor.scale
    for frame in range(9):
        actor.scale=original*(frame+1)/9.0
        if not await frames(1,serial): return false
    if not await frames(4,serial): return false
    actor.material=null
    if not await frames(6,serial): return false
    return true

func move_actor(to: Vector2, seconds: float, serial: int) -> bool:
    var from = actor.position
    var count=maxi(1,roundi(seconds*60))
    for frame in range(count):
        if not await frames(1,serial): return false
        actor.position=from.lerp(to,(frame+1)/float(count))
        actor.z_index=world()._depth_z(Vector2i(actor.position/16))
        world()._set_overworld_motion_frame(actor,(to-from).normalized(),int(frame/5)%2)
    actor.position=to
    return true

func recall_actor(serial: int) -> void:
    if not is_instance_valid(actor): return
    actor.material=silhouette(Color(1,0.25,0.25))
    if not await frames(4,serial): return
    var original=actor.scale
    world().play_source_sound("poof1")
    for frame in range(9):
        actor.scale=original*(1.0-(frame+1)/9.0)
        if not await frames(1,serial): return
    if is_instance_valid(projectile):
        projectile.show()
        projectile.position=actor.position
        await animate_flight(actor.position,world().player.position,maxf(0.05,actor.position.distance_to(world().player.position)/320.0),serial)

func recall_follower(member: Dictionary) -> void:
    busy=true
    animation_debt=0.0
    throw_serial+=1
    var serial=throw_serial
    active_scope=scope()
    actor=world().follower_sprite.duplicate()
    actor_member=member
    world().add_child(actor)
    world().clear_follower()
    projectile=Sprite2D.new()
    projectile.texture=ball_texture(str(member.get("pokeball","POKE BALL")))
    projectile.z_as_relative=false
    world().add_child(projectile)
    projectile.hide()
    await recall_actor(serial)
    finish_flight(serial)

func mount_actor(member: Dictionary, cell: Vector2i, move: String, serial: int) -> void:
    if main.build_menu_open: main._close_build_menu(false)
    if not world().active_field_move.is_empty(): world().clear_active_field_move(false)
    hop_origin=world().player.position
    hopping=true
    world().set_gameplay_enabled(false)
    var end: Vector2=world()._cell_center(cell)
    var tiles=roundi(hop_origin.distance_to(end)/16)
    var count=12+6*tiles
    world().play_source_sound("ledge1")
    for frame in range(count):
        if not await frames(1,serial): return
        var t=(frame+1)/float(count)
        world().player.position=hop_origin.lerp(end,t)
        world().player.set_field_visual_offset(Vector2(0,-minf(22,8+3*tiles)*4*t*(1-t)))
    world().player.position=end
    world().player.set_field_visual_offset(Vector2.ZERO)
    if not world().set_active_field_move(member,move,true): world().player.position=hop_origin
    hopping=false
    world().set_gameplay_enabled(not main._field_ui_blocks_gameplay(main.build_menu_open))

func catch_sparkles(serial: int) -> bool:
    var stars=[]
    var pixels=Image.create(5,5,false,Image.FORMAT_RGBA8)
    for pixel in range(5):
        pixels.set_pixel(2,pixel,Color(1,1,0.6))
        pixels.set_pixel(pixel,2,Color(1,1,0.6))
    var texture=ImageTexture.create_from_image(pixels)
    for index in range(4):
        var star=Sprite2D.new()
        star.texture=texture
        projectile.add_child(star)
        stars.append(star)
    for frame in range(24):
        for index in range(4):stars[index].position=Vector2.from_angle(PI/2*index+PI/4+frame*0.1)*(6+frame)
        if not await frames(1,serial): return false
    for star in stars: star.queue_free()
    return true

func breakout_poof(sprite: Sprite2D, serial: int) -> bool:
    var effect=Sprite2D.new()
    effect.texture=preload("res://assets/source_exact/global/poof_sheet1.png")
    effect.hframes=5
    projectile.add_child(effect)
    projectile.show()
    var ball_image=projectile.texture
    projectile.texture=null
    for frame in range(5):
        effect.frame=frame
        if frame==2:
            sprite.scale=held_scale
            sprite.modulate=held_modulate
            sprite.material=held_material
            sprite.show()
        if not await frames(4,serial): return false
    effect.queue_free()
    projectile.texture=ball_image
    projectile.hide()
    return true

func silhouette(color: Color) -> ShaderMaterial:
    var shader=Shader.new()
    shader.code="shader_type canvas_item; uniform vec4 tint : source_color = vec4(1.0); void fragment(){ COLOR=vec4(tint.rgb,texture(TEXTURE,UV).a*COLOR.a); }"
    var material=ShaderMaterial.new()
    material.shader=shader
    material.set_shader_parameter("tint",color)
    return material
