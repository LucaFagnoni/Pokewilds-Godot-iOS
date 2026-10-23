extends RefCounted

## The progression screens over the battle and the field: experience filling
## the bar, level-up stats, learning a move (and forgetting one), evolution and
## egg hatching.
## Split out of main.gd; reaches the game through `main`.

const PokemonData = preload("res://scripts/pokemon_data.gd")
const PokemonState = preload("res://scripts/pokemon_state.gd")
const BattleEngine = preload("res://scripts/battle_engine.gd")
const SOURCE_LEVEL_STATS_MIN_FRAMES := 82
const SOURCE_EXP_UNITS := 68
const SOURCE_HATCH_BACKGROUND := preload(
    "res://assets/source_exact/battle/intro_frame6.png")
const HATCH_PLAYBACK_SPEED := 1.2
const SOURCE_HATCH_COMPLETE_FRAME := 588
const SOURCE_EVOLUTION_CANCEL_END_FRAME := 464

var main: GameMain
var progression_move_frame: Panel
var progression_type_frame: Panel
var progression_pp_label: Label
var progression_menu_cursor: Label
var progression_yes_no_cursor: Label
var hatch_skip_requested := false
# The move last shown on the forget screen, kept across its YES/NO questions.
var progression_move_index := 0
var progression_pending_move := ""
var progression_pokemon: Dictionary = {}
var evolution_greyscale_material: ShaderMaterial

func _init(owner_main: GameMain) -> void:
    main = owner_main

func create_evolution_greyscale_material() -> void:
    var shader := Shader.new()
    # This is the nonlinear 5-bit greyscale shader used by EvolutionAnim in
    # the source JAR, translated directly to Godot's canvas shader syntax.
    shader.code = (
        "shader_type canvas_item;\n" +
        "void fragment() {\n" +
        "  vec4 c = texture(TEXTURE, UV) * COLOR;\n" +
        "  float r = floor(c.r * 31.0);\n" +
        "  float g = floor(c.g * 31.0);\n" +
        "  float b = floor(c.b * 31.0);\n" +
        "  float sum = r + g + b;\n" +
        "  float grey = floor(sum * sum * sum / 25947.0) / 31.0;\n" +
        "  COLOR = vec4(vec3(grey), c.a);\n" +
        "}\n"
    )
    evolution_greyscale_material = ShaderMaterial.new()
    evolution_greyscale_material.shader = shader

func handle_progression_input(event: InputEvent) -> void:
    if main.progression_mode == "HATCH_ANIMATION":
        if event.is_action_pressed("confirm") and not event.is_echo():
            hatch_skip_requested = true
        main.get_viewport().set_input_as_handled()
        return
    if main.progression_mode == "EVOLUTION":
        if not main.overworld_evolution_running and event.is_action_pressed("cancel"):
            main.evolution_cancel_requested = true
            main.get_viewport().set_input_as_handled()
        return
    if main.progression_mode in ["STATS", "HATCH_DONE"]:
        if main.progression_waiting_input and (event.is_action_pressed("confirm") or
                event.is_action_pressed("start")):
            main.progression_waiting_input = false
            main.progression_confirmed.emit()
            main.get_viewport().set_input_as_handled()
        return
    if main.progression_mode == "MOVE_SELECT":
        var moves: Array = progression_pokemon.get("moves", [])
        if moves.is_empty():
            return
        if event.is_action_pressed("move_up") or event.is_action_pressed("move_left"):
            main.progression_choice_index = wrapi(
                main.progression_choice_index - 1, 0, moves.size())
            refresh_progression_move_menu()
        elif event.is_action_pressed("move_down") or event.is_action_pressed("move_right"):
            main.progression_choice_index = wrapi(
                main.progression_choice_index + 1, 0, moves.size())
            refresh_progression_move_menu()
        elif event.is_action_pressed("confirm"):
            main.progression_mode = ""
            main.progression_choice_made.emit(main.progression_choice_index)
        elif event.is_action_pressed("cancel"):
            show_progression_yes_no(
                "Give up on learning %s?" % progression_pending_move.replace("_", " "),
                "MOVE_GIVEUP")
        else:
            return
        main.get_viewport().set_input_as_handled()
        return
    if main.progression_mode in ["MOVE_GIVEUP", "YES_NO"]:
        if event.is_action_pressed("move_up") or event.is_action_pressed("move_down") or \
                event.is_action_pressed("move_left") or event.is_action_pressed("move_right"):
            main.progression_choice_index = 1 - main.progression_choice_index
            refresh_progression_yes_no()
        elif event.is_action_pressed("confirm"):
            if main.progression_mode == "MOVE_GIVEUP":
                if main.progression_choice_index == 0:
                    main.progression_mode = ""
                    main.progression_choice_made.emit(-1)
                else:
                    _show_progression_move_menu(
                        progression_pokemon, progression_pending_move)
            else:
                main.progression_mode = ""
                main.progression_choice_made.emit(
                    1 if main.progression_choice_index == 0 else 0)
        elif event.is_action_pressed("cancel"):
            if main.progression_mode == "MOVE_GIVEUP":
                _show_progression_move_menu(
                    progression_pokemon, progression_pending_move)
            else:
                main.progression_mode = ""
                main.progression_choice_made.emit(0)
        else:
            return
        main.get_viewport().set_input_as_handled()

func reset_progression_overlay() -> void:
    main.progression_level_message.add_theme_font_size_override("font_size", 10)
    main.progression_level_message.position = Vector2(12,10)
    main.progression_level_message.size = Vector2(282,32)
    for panel in [progression_move_frame, progression_type_frame, main.progression_choice_frame]:
        if panel != null:
            panel.hide()
    main.progression_background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    main.progression_background.position = Vector2.ZERO
    main.progression_animation.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    main.progression_animation.position = Vector2.ZERO
    main.progression_background.texture = null
    main.progression_animation.texture = null
    main.progression_sprite_top.texture = null
    main.progression_sprite_bottom.texture = null
    main.progression_sprite_top.material = null
    main.progression_sprite_bottom.material = null
    main.progression_sprite_top.visible = false
    main.progression_sprite_bottom.visible = false
    main.progression_title.visible = false
    main.progression_list.visible = false
    main.progression_values.visible = false
    main.progression_cursor.visible = false
    main.progression_detail.visible = false
    main.progression_hint.visible = false
    main.progression_level_dialogue.visible = false
    if main.progression_stats_frame != null:
        main.progression_stats_frame.visible = false

func hide_progression_overlay() -> void:
    main.progression_mode = ""
    main.progression_waiting_input = false
    main.progression_overlay.visible = main.capture_experience_presenting
    reset_progression_overlay()

func _show_level_up_stats(pokemon: Dictionary) -> void:
    reset_progression_overlay()
    main.progression_overlay.visible = true
    main.progression_background.texture = null
    var species := String(pokemon.get("species", "machop"))
    var stats_texture := PokemonData.record_texture(pokemon, "back")
    if stats_texture == null:
        stats_texture = PokemonData.record_texture(pokemon, "front")
    main.progression_sprite_top.texture = main._battle_sprite_frame(stats_texture)
    # Stands on the text box (top edge at 123), as it does during the battle.
    main.progression_sprite_top.position = Vector2(14, 29)
    main.progression_sprite_top.size = Vector2(116, 94)
    main.progression_sprite_top.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
    main.progression_sprite_top.visible = main.progression_sprite_top.texture != null
    var stats: Dictionary = pokemon.get("stats", {})
    for index in range(5):
        main.progression_stats_fields[index].text = str(int(stats.get(
            ["attack", "defense", "sp_attack", "sp_defense", "speed"][index], 0)))
    main.progression_stats_frame.visible = true
    main.progression_level_message.text = "%s grew to LV.%d!" % [
        PokemonState.display_name(pokemon).to_upper(),
        int(pokemon.get("level", 1))
    ]
    main.progression_level_dialogue.visible = true
    main.progression_mode = "STATS"
    main.progression_waiting_input = false
    await main.get_tree().create_timer(
        SOURCE_LEVEL_STATS_MIN_FRAMES * main.SOURCE_FRAME_TIME).timeout
    main.progression_waiting_input = true
    main.progression_hint.text = ""
    main.progression_hint.visible = false
    await main.progression_confirmed
    hide_progression_overlay()

func _progression_panel(label: String, rect: Rect2) -> Panel:
    var panel := Panel.new()
    panel.name = label
    panel.position = rect.position
    panel.size = rect.size
    panel.z_index = 2
    panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
    panel.add_theme_stylebox_override("panel", main._classic_dialogue_style())
    main.progression_overlay.add_child(panel)
    panel.hide()
    return panel

func create_progression_menu_frames() -> void:
    progression_type_frame = _progression_panel("MoveTypeBorder", Rect2(142, 2, 176, 117))
    progression_move_frame = _progression_panel("MoveListBorder", Rect2(2, 2, 138, 117))
    main.progression_choice_frame = _progression_panel("MoveChoiceBorder", Rect2(234, 51, 84, 70))
    main.progression_type_label = main._source_ui_label(progression_type_frame, "Type", Vector2(10, 10), Vector2(156, 95), 8)
    main.progression_type_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    progression_pp_label = main._source_ui_label(progression_type_frame, "PP", Vector2(12, 67), Vector2(94, 34), 10)
    for index in range(4):
        var row := main._source_ui_label(progression_move_frame, "Move%d" % index,
            Vector2(24, 10 + index * 25), Vector2(104, 20), 10)
        row.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
        main.progression_move_rows.append(row)
    progression_menu_cursor = main._source_ui_label(progression_move_frame, "Tick", Vector2(8, 10), Vector2(14, 20), 10, "▶", true)
    progression_menu_cursor.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
    progression_yes_no_cursor = main._source_ui_label(main.progression_choice_frame, "Tick", Vector2(11, 8), Vector2(14, 20), 10, "▶", true)
    progression_yes_no_cursor.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
    for index in range(2):
        var row := main._source_ui_label(main.progression_choice_frame, "Choice%d" % index,
            Vector2(28, 10 + index * 28), Vector2(46, 22), 10, "YES" if index == 0 else "NO")
        row.vertical_alignment = VERTICAL_ALIGNMENT_CENTER

func _show_progression_move_menu(pokemon: Dictionary, move_name: String) -> void:
    reset_progression_overlay()
    main.progression_overlay.show()
    progression_pokemon = pokemon
    progression_pending_move = move_name.to_upper().replace(" ", "_")
    var moves: Array = pokemon.get("moves", [])
    main.progression_choice_index = clampi(progression_move_index, 0, maxi(0, moves.size() - 1))
    main.progression_level_message.text = "Which move should be forgotten?"
    main.progression_level_dialogue.show()
    progression_move_frame.show()
    progression_type_frame.show()
    main.progression_mode = "MOVE_SELECT"
    refresh_progression_move_menu()

func refresh_progression_move_menu() -> void:
    progression_move_index = main.progression_choice_index
    var moves: Array = progression_pokemon.get("moves", [])
    for index in range(4):
        var row := main.progression_move_rows[index]
        row.text = String(moves[index]).replace("_", " ") if index < moves.size() else "-"
        var font_size := 10
        while font_size > 6 and row.get_theme_font("font").get_string_size(row.text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x > row.size.x:
            font_size -= 1
        row.add_theme_font_size_override("font_size", font_size)
    main._align_menu_tick(progression_menu_cursor, main.progression_move_rows[main.progression_choice_index])
    if moves.is_empty():
        main.progression_type_label.text = "TYPE/\n---"
        progression_pp_label.text = "PP\n0/0"
        return
    var selected := String(moves[main.progression_choice_index])
    var move_data := PokemonData.move_info(selected)
    var maximum_pp := int(move_data.get("pp", 0))
    var current_pp := int((progression_pokemon.get("pp", {}) as Dictionary).get(selected, maximum_pp))
    var details = preload("res://scripts/move_details.gd")
    progression_pp_label.hide()
    main.progression_type_label.text = "%s\nPP %d / %d\n\n%s" % [details.stats_text(selected).replace("  PP %d" % maximum_pp,""),current_pp,maximum_pp,details.effect_text(selected)]
    main.progression_level_message.add_theme_font_size_override("font_size", 7)
    main.progression_level_message.position = Vector2(12,7)
    main.progression_level_message.size = Vector2(288,44)
    main.progression_level_message.text = "NEW: %s  (%s)\n%s\n%s" % [progression_pending_move.replace("_"," "), PokemonState.display_name(progression_pokemon).to_upper(), details.stats_text(progression_pending_move).replace("\n","  "), details.effect_text(progression_pending_move)]

func show_progression_yes_no(prompt: String, mode: String = "YES_NO") -> void:
    reset_progression_overlay()
    main.progression_overlay.show()
    main.progression_level_message.text = prompt
    main.progression_level_dialogue.show()
    main.progression_choice_frame.show()
    main.progression_choice_index = 0
    main.progression_mode = mode
    refresh_progression_yes_no()

func refresh_progression_yes_no() -> void:
    main._align_menu_tick(progression_yes_no_cursor, main.progression_choice_frame.get_node("Choice%d" % main.progression_choice_index))

func _ask_progression_yes_no(prompt: String) -> bool:
    show_progression_yes_no(prompt)
    var result = await main.progression_choice_made
    return int(result) == 1

func choose_move_to_forget(pokemon: Dictionary,
        move_name: String) -> int:
    progression_move_index = 0
    while true:
        _show_progression_move_menu(pokemon, move_name)
        var choice = await main.progression_choice_made
        var selected_index := int(choice)
        if selected_index < 0:
            hide_progression_overlay()
            return -1
        var moves: Array = pokemon.get("moves", [])
        if selected_index >= moves.size():
            continue
        var forgotten := String(moves[selected_index]).replace("_", " ")
        if await _ask_progression_yes_no("Replace %s?" % forgotten):
            hide_progression_overlay()
            return selected_index
    return -1

func _learn_level_moves(pokemon: Dictionary, moves_to_learn: Array) -> void:
    var display_name := PokemonState.display_name(pokemon).to_upper()
    for raw_move in moves_to_learn:
        var move_name := String(raw_move).to_upper().replace(" ", "_")
        if (pokemon.get("moves", []) as Array).has(move_name):
            continue
        if (pokemon.get("moves", []) as Array).size() < 4:
            if BattleEngine.learn_move(pokemon, move_name):
                main._play_source_battle_sound("fanfare1.ogg")
                await main._type_battle_text("%s learned %s!" % [
                    display_name, move_name.replace("_", " ")])
            continue
        await main._type_battle_text("%s is trying to learn %s." % [
            display_name, move_name.replace("_", " ")])
        await main._type_battle_text("Which move should be forgotten?")
        var replace_index := await choose_move_to_forget(pokemon, move_name)
        main._note_battle_choice(replace_index)
        if replace_index < 0:
            await main._type_battle_text("%s did not learn %s." % [
                display_name, move_name.replace("_", " ")])
            continue
        var old_move := String((pokemon.get("moves", []) as Array)[replace_index])
        await main._type_battle_text("And one... two... three... POOF!")
        await main._type_battle_text("%s forgot %s and..." % [
            display_name, old_move.replace("_", " ")])
        if BattleEngine.learn_move(pokemon, move_name, replace_index):
            main._play_source_battle_sound("fanfare1.ogg")
            await main._type_battle_text("%s learned %s!" % [
                display_name, move_name.replace("_", " ")])

func _experience_bar_index(species: String, level: int,
        experience: int) -> int:
    if level >= 100:
        return SOURCE_EXP_UNITS
    var floor_exp := BattleEngine.exp_for_level(species, level)
    var ceiling_exp := BattleEngine.exp_for_level(species, level + 1)
    return clampi(int(floor(float(SOURCE_EXP_UNITS) *
        float(experience - floor_exp) /
        maxf(1.0, float(ceiling_exp - floor_exp)))), 0, SOURCE_EXP_UNITS)

func _animate_experience_segment(pokemon: Dictionary, from_exp: int,
        to_exp: int) -> void:
    var species := String(pokemon.get("species", "machop"))
    var level := int(pokemon.get("level", 1))
    var start_index := _experience_bar_index(species, level, from_exp)
    var target_index := _experience_bar_index(species, level, to_exp)
    var segment_start := preload("res://scripts/game_clock.gd").ticks_usec()
    for bar_index in range(start_index + 1, target_index + 1):
        set_player_exp_bar_ratio(
            float(bar_index) / float(SOURCE_EXP_UNITS))
        var deadline := segment_start + int((bar_index - start_index) * main.SOURCE_FRAME_TIME * 1000000.0)
        while preload("res://scripts/game_clock.gd").ticks_usec() < deadline:
            await main.get_tree().process_frame

func set_player_exp_bar_ratio(ratio: float) -> void:
    var clamped := clampf(ratio, 0.0, 1.0)
    var legacy_width := roundf(96.0 * clamped)
    var source_width := roundf(66.0 * clamped)
    # Both bars share a fixed right edge like the source GSC HUD.
    main.player_exp_fill.position.x = 145.0 - legacy_width
    main.player_exp_fill.size.x = legacy_width
    main.source_player_exp_fill.position.x = 184.0 - source_width
    main.source_player_exp_fill.size.x = source_width
    main.player_exp_fill.color = Color8(47, 152, 233)
    main.source_player_exp_fill.color = Color8(32, 136, 248)

func world_source_time_of_day() -> String:
    if main.world.has_method("source_time_of_day"):
        return String(main.world.call("source_time_of_day"))
    return "day"

func run_experience_progression(pokemon: Dictionary, amount: int,
        party_index: int, defer_evolution: bool = false) -> void:
    main.progression_active = true
    main.progression_mode = ""
    hide_progression_overlay()
    var original_hud_pokemon := main.battle_player
    var showing_other_pokemon := not is_same(pokemon, main.battle_player)
    if showing_other_pokemon:
        main.battle_player = pokemon
        main._update_battle_hud()

    var current_exp := int(pokemon.get("exp", BattleEngine.exp_for_level(
        String(pokemon.get("species", "machop")), int(pokemon.get("level", 1)))))
    var target_exp := current_exp + maxi(0, amount)
    var gained_level := false
    if int(pokemon.get("level", 1)) < 100 and target_exp > current_exp:
        main._play_source_battle_sound("xp-gain1.ogg")
        await main.get_tree().create_timer(9.0 * main.SOURCE_FRAME_TIME).timeout

    while int(pokemon.get("level", 1)) < 100:
        var next_level_exp := BattleEngine.exp_for_level(
            String(pokemon.get("species", "machop")),
            int(pokemon.get("level", 1)) + 1)
        if target_exp < next_level_exp:
            break
        await _animate_experience_segment(pokemon, current_exp, next_level_exp)
        pokemon["exp"] = next_level_exp
        main.battle_audio.stop()
        main._play_level_up_sound()
        set_player_exp_bar_ratio(1.0)
        # The source holds a completely filled bar before it rolls into the
        # next level rather than clearing it on the same frame.
        await main.get_tree().create_timer(9.0 * main.SOURCE_FRAME_TIME).timeout
        var level_result := BattleEngine.gain_level(pokemon)
        gained_level = true
        current_exp = next_level_exp
        if party_index >= 0 and party_index < main.caught_pokemon.size():
            main.caught_pokemon[party_index] = pokemon
        main._update_battle_hud()
        main._play_source_battle_sound("fanfare1.ogg")
        await main._type_battle_text("%s grew to level %d!" % [
            PokemonState.display_name(pokemon).to_upper(), int(pokemon.level)])
        await _learn_level_moves(pokemon, level_result.get("moves", []))
        if int(pokemon.get("level", 1)) < 100 and target_exp >= \
                BattleEngine.exp_for_level(String(pokemon.species),
                    int(pokemon.level) + 1):
            main._play_source_battle_sound("xp-gain1.ogg")

    if int(pokemon.get("level", 1)) < 100 and target_exp > current_exp:
        await _animate_experience_segment(pokemon, current_exp, target_exp)
    pokemon["exp"] = target_exp
    main.battle_audio.stop()
    if party_index >= 0 and party_index < main.caught_pokemon.size():
        main.caught_pokemon[party_index] = pokemon
    main._update_battle_hud()

    if gained_level:
        await _show_level_up_stats(pokemon)
        if not defer_evolution:
            await main._check_reward_evolution(pokemon, party_index)

    if showing_other_pokemon:
        main.battle_player = original_hud_pokemon
        main._update_battle_hud()
    hide_progression_overlay()
    progression_pokemon = {}
    progression_pending_move = ""
    main.progression_active = false

func _set_progression_sprite_half(node: TextureRect, texture: Texture2D,
        top_half: bool, greyscale: bool,
        source_baseline_y: float = 72.0, bottom_height: int = -1,
        horizontal_scale: float = 2.0, horizontal_offset: float = 0.0) -> void:
    if texture == null:
        node.texture = null
        node.visible = false
        return
    var width := texture.get_width()
    var height := texture.get_height()
    var split := height - bottom_height if bottom_height >= 0 else int(height / 2.0)
    var region_y := 0 if top_half else split
    var region_height := split if top_half else height - split
    node.texture = main._source_texture_region(texture,
        Rect2(0, region_y, width, region_height))
    var source_left := 84.0 - float(width) / 2.0
    var source_top := 144.0 - source_baseline_y - float(height)
    node.position = Vector2(
        horizontal_offset + source_left * horizontal_scale,
        (source_top + float(region_y)) * 1.25)
    node.size = Vector2(float(width) * horizontal_scale, float(region_height) * 1.25)
    node.material = evolution_greyscale_material if greyscale else null
    node.visible = true

func _set_evolution_sprite_halves(old_texture: Texture2D,
        new_texture: Texture2D, directive: Dictionary,
        sprites_visible: bool) -> void:
    if not sprites_visible:
        main.progression_sprite_top.visible = false
        main.progression_sprite_bottom.visible = false
        return
    var greyscale := bool(directive.get("sprite_greyscale", false))
    var top_texture := new_texture if bool(directive.get(
        "evo_top_sprite_changed", false)) else old_texture
    var bottom_texture := new_texture if bool(directive.get(
        "evo_bottom_sprite_changed", false)) else old_texture
    _set_progression_sprite_half(
        main.progression_sprite_top, top_texture, true, greyscale, 72.0,
        int(old_texture.get_height() / 2.0), 1.25, 60.0)
    _set_progression_sprite_half(
        main.progression_sprite_bottom, bottom_texture, false, greyscale, 72.0,
        int(old_texture.get_height() / 2.0), 1.25, 60.0)

func _set_progression_full_sprite(texture: Texture2D,
        source_baseline_y: float) -> void:
    if texture == null:
        main.progression_sprite_top.visible = false
        main.progression_sprite_bottom.visible = false
        return
    main.progression_sprite_bottom.visible = false
    main.progression_sprite_top.texture = texture
    main.progression_sprite_top.material = null
    main.progression_sprite_top.position = Vector2(
        (84.0 - float(texture.get_width()) / 2.0) * 2.0,
        (144.0 - source_baseline_y - float(texture.get_height())) * 1.25)
    main.progression_sprite_top.size = Vector2(
        float(texture.get_width()) * 2.0,
        float(texture.get_height()) * 1.25)
    main.progression_sprite_top.visible = true

func _set_hatch_progression_canvas() -> void:
    # The source hatch canvas is 160x144. Fit it to the 320x180 viewport with
    # one uniform scale (1.25x) so the egg/Pokemon are never horizontally
    # stretched; the remaining 60 px on each side are intentional pillarbox.
    for node in [main.progression_background, main.progression_animation]:
        node.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
        node.position = Vector2(60.0, 0.0)
        node.size = Vector2(200.0, 180.0)

func _set_hatch_sprite_half(node: TextureRect, texture: Texture2D,
        top_half: bool, source_baseline_y: float = 64.0) -> void:
    if texture == null:
        node.texture = null
        node.visible = false
        return
    var width := texture.get_width()
    var height := texture.get_height()
    var split := int(height / 2.0)
    var region_y := 0 if top_half else split
    var region_height := split if top_half else height - split
    node.texture = main._source_texture_region(texture,
        Rect2(0, region_y, width, region_height))
    var scale := 1.25
    var source_left := 84.0 - float(width) / 2.0
    var source_top := 144.0 - source_baseline_y - float(height)
    node.position = Vector2(
        60.0 + source_left * scale,
        (source_top + float(region_y)) * scale)
    node.size = Vector2(float(width) * scale, float(region_height) * scale)
    node.material = null
    node.visible = true

func _set_hatch_full_sprite(texture: Texture2D,
        source_baseline_y: float = 64.0) -> void:
    if texture == null:
        main.progression_sprite_top.visible = false
        main.progression_sprite_bottom.visible = false
        return
    var scale := 1.25
    main.progression_sprite_bottom.visible = false
    main.progression_sprite_top.texture = texture
    main.progression_sprite_top.material = null
    main.progression_sprite_top.position = Vector2(
        60.0 + (84.0 - float(texture.get_width()) / 2.0) * scale,
        (144.0 - source_baseline_y - float(texture.get_height())) * scale)
    main.progression_sprite_top.size = Vector2(
        float(texture.get_width()) * scale,
        float(texture.get_height()) * scale)
    main.progression_sprite_top.visible = true

func _set_hatch_sprite_halves(texture: Texture2D,
        show_bottom: bool, show_top: bool) -> void:
    if show_top:
        _set_hatch_sprite_half(
            main.progression_sprite_top, texture, true, 64.0)
    else:
        main.progression_sprite_top.visible = false
    if show_bottom:
        _set_hatch_sprite_half(
            main.progression_sprite_bottom, texture, false, 64.0)
    else:
        main.progression_sprite_bottom.visible = false

func _play_progression_cry(pokemon: Dictionary) -> void:
    var cry_path := PokemonData.cry_path(String(pokemon.get("species", "")))
    if cry_path.is_empty() or not ResourceLoader.exists(cry_path):
        return
    var cry_player := AudioStreamPlayer.new()
    cry_player.stream = load(cry_path) as AudioStream
    cry_player.finished.connect(func() -> void: cry_player.queue_free())
    main.add_child(cry_player)
    AudioBalance.apply(cry_player)
    cry_player.play()

func run_egg_hatch_sequence(party_index: int, hatched: Dictionary) -> void:
    main.progression_active = true
    main.progression_mode = ""
    main.field_item_busy = true
    main.world.set_gameplay_enabled(false)
    main.caught_pokemon[party_index] = hatched
    main.pokedex_progress.mark(hatched, true)
    var species := String(hatched.get("species", "pidgey")).to_lower()
    if not main.caught_species.has(species):
        main.caught_species.append(species)

    # PlayerStanding waits 61 + 3 source frames before its random hatch cue.
    await main.get_tree().create_timer(61.0 * main.SOURCE_FRAME_TIME).timeout
    await main.get_tree().create_timer(3.0 * main.SOURCE_FRAME_TIME).timeout
    main.message_timer = 0.0
    main.message_label.text = ["Huh?", "Oh?"][main.battle_rng.randi_range(0, 1)]
    main.message_panel.visible = true
    await main.get_tree().create_timer(51.0 * main.SOURCE_FRAME_TIME).timeout
    main.message_panel.visible = false

    reset_progression_overlay()
    main.progression_overlay.visible = true
    _set_hatch_progression_canvas()
    main.progression_background.texture = main._source_texture_region(
        SOURCE_HATCH_BACKGROUND, Rect2(0, 0, 160, 144))
    main.progression_mode = "HATCH_ANIMATION"
    var skip_hint := main._source_ui_label(main.progression_overlay, "HatchSkipHint", Vector2(190, 167), Vector2(124, 11), 7, "Press A to skip")
    skip_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
    skip_hint.z_index = 10
    hatch_skip_requested = false
    var previous_pitch := main.battle_audio.pitch_scale
    main.battle_audio.pitch_scale = HATCH_PLAYBACK_SPEED
    main._play_battle_animation_sound("egg_hatch_gsc")
    var front_sheet := PokemonData.record_texture(hatched, "front")
    var front_frame := main._battle_sprite_frame(front_sheet)
    var show_bottom := false
    var show_top := false
    # One elapsed-time clock advances both visuals and pitched source audio.
    # Per-frame timers accumulated extra display frames on slower devices.
    var hatch_start := preload("res://scripts/game_clock.gd").ticks_usec()
    var last_frame := -1
    while not hatch_skip_requested:
        var frame_index := int(float(preload("res://scripts/game_clock.gd").ticks_usec() - hatch_start) / 1000000.0 * HATCH_PLAYBACK_SPEED / main.SOURCE_FRAME_TIME)
        if frame_index >= SOURCE_HATCH_COMPLETE_FRAME:
            break
        main.progression_animation.texture = main._source_animation_frame_texture(
            "egg_hatch_gsc", frame_index)
        for directive_frame in range(last_frame + 1, frame_index + 1):
            var directive := main._source_animation_directive("egg_hatch_gsc", directive_frame)
            show_bottom = show_bottom or bool(directive.get("draw_hatch_bottom_sprite", false))
            show_top = show_top or bool(directive.get("draw_hatch_top_sprite", false))
        last_frame = frame_index
        _set_hatch_sprite_halves(front_frame, show_bottom, show_top)
        await main.get_tree().process_frame

    main.battle_audio.stop()
    main.battle_audio.pitch_scale = previous_pitch
    skip_hint.queue_free()
    main.progression_mode = "HATCH_REVEAL"
    main.progression_animation.texture = null
    var intro_frame_count := 1
    if front_sheet != null and front_sheet.get_width() > 0:
        intro_frame_count = maxi(1, roundi(
            float(front_sheet.get_height()) / float(front_sheet.get_width())))
    var cry_started := false
    var reveal_start := preload("res://scripts/game_clock.gd").ticks_usec()
    for intro_index in range(intro_frame_count):
        var sprite_frame := front_frame
        if front_sheet != null and front_sheet.get_height() > front_sheet.get_width():
            var frame_height := mini(front_sheet.get_height(), front_sheet.get_width())
            sprite_frame = main._source_texture_region(front_sheet, Rect2(
                0, intro_index * frame_height,
                front_sheet.get_width(), frame_height))
        _set_hatch_full_sprite(sprite_frame, 64.0)
        var deadline := reveal_start + int((intro_index + 1) * main.SOURCE_FRAME_TIME * 1000000.0)
        while preload("res://scripts/game_clock.gd").ticks_usec() < deadline:
            await main.get_tree().process_frame
        if intro_index == 3:
            _play_progression_cry(hatched)
            cry_started = true
    if not cry_started:
        _play_progression_cry(hatched)
    await main.get_tree().create_timer(4.0 * main.SOURCE_FRAME_TIME).timeout

    hide_progression_overlay()
    main._play_source_battle_sound("fanfare2.ogg")
    main.message_timer = 0.0
    main.message_label.text = "%s came out of its EGG!" % \
        PokemonState.display_name(hatched).to_upper()
    main.message_panel.visible = true
    main.progression_mode = "HATCH_DONE"
    main.progression_waiting_input = true
    await main.progression_confirmed
    await main.get_tree().create_timer(13.0 * main.SOURCE_FRAME_TIME).timeout
    main.battle_audio.stop()
    main.message_panel.visible = false
    main.progression_mode = ""
    main.progression_waiting_input = false
    main.progression_active = false
    main.field_item_busy = false
    main.world.set_gameplay_enabled(true)

func _evolution_sprite_texture(species: String, shiny: bool) -> Texture2D:
    return PokemonData.texture(species, "front", shiny)

func set_evolution_message(message: String) -> void:
    var font := main.progression_level_message.get_theme_font("font")
    var result := message
    var chosen_size := 10
    for size in range(10, 4, -1):
        var lines: Array[String] = [""]
        for word in message.split(" "):
            var candidate := word if lines[-1].is_empty() else lines[-1] + " " + word
            if font.get_string_size(candidate, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x > 282 and not lines[-1].is_empty():
                lines.append(word)
            else:
                lines[-1] = candidate
        if lines.size() <= 2:
            result = "\n".join(lines)
            chosen_size = size
            break
    main.progression_level_message.add_theme_font_size_override("font_size", chosen_size)
    main.progression_level_message.text = result

func run_evolution_sequence(pokemon: Dictionary, new_species: String,
        party_index: int) -> bool:
    new_species = BattleEngine.resolved_evolution_species(pokemon, new_species)
    var old_display_name := PokemonState.display_name(pokemon).to_upper()
    var old_texture := main._battle_sprite_frame(
        _evolution_sprite_texture(String(pokemon.get("species", "")), PokemonData.is_shiny(pokemon)))
    var new_texture := main._battle_sprite_frame(
        _evolution_sprite_texture(new_species, PokemonData.is_shiny(pokemon)))
    await main._type_battle_text("What? %s is evolving!" % old_display_name)
    await main.get_tree().create_timer(51.0 * main.SOURCE_FRAME_TIME).timeout

    reset_progression_overlay()
    main.progression_overlay.visible = true
    # Keep the source animation in its native proportions above the approved
    # dialogue panel; its baked-in vanilla border must not replace our UI.
    main.progression_background.texture = null
    main.progression_animation.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
    main.progression_animation.position = Vector2(60.0, 0.0)
    main.progression_animation.size = Vector2(200.0, 120.0)
    main.progression_level_dialogue.visible = true
    set_evolution_message("What? %s is evolving!" % old_display_name)
    main.progression_mode = "EVOLUTION"
    main.evolution_cancel_requested = false
    var evolution_music_states: Array[bool] = main.world.environment_system.pause_music_for_evolution()
    main._play_source_battle_sound("evolution1.ogg")
    var animations: Dictionary = main.battle_animation_manifest.get("animations", {})
    var animation: Dictionary = animations.get("evolve_gsc", {})
    var frame_count := int(animation.get("frames", 502))
    var fanfare_played := false
    var evolution_started_usec := preload("res://scripts/game_clock.gd").ticks_usec()
    for frame_index in range(frame_count):
        if frame_index >= SOURCE_EVOLUTION_CANCEL_END_FRAME:
            main.progression_mode = "EVOLUTION_FINISHING"
        main.progression_animation.texture = main._source_animation_frame_texture(
            "evolve_gsc", frame_index, Rect2(0, 0, 160, 96))
        var directive := main._source_animation_directive("evolve_gsc", frame_index)
        _set_evolution_sprite_halves(
            old_texture, new_texture, directive, frame_index >= 33)
        if bool(directive.get("play_evo_fanfare", false)) and not fanfare_played:
            fanfare_played = true
            main._play_source_battle_sound("evolve_fanfare1.ogg")
        # Absolute deadlines preserve the source's 60 Hz timeline. Creating a
        # fresh one-frame timer per frame accumulated an extra render-frame wait.
        var deadline := evolution_started_usec + int(
            float(frame_index + 1) * main.SOURCE_FRAME_TIME * 1000000.0)
        while preload("res://scripts/game_clock.gd").ticks_usec() < deadline:
            await main.get_tree().process_frame
        if main.evolution_cancel_requested:
            break
    main.battle_audio.stop()
    main.world.environment_system.resume_music_after_evolution(evolution_music_states)
    main.progression_mode = "EVOLUTION_DONE"
    main.progression_animation.texture = null
    main._note_battle_choice(not main.evolution_cancel_requested)

    if main.evolution_cancel_requested:
        _set_evolution_sprite_halves(old_texture, old_texture, {}, true)
        await main.get_tree().create_timer(30.0 * main.SOURCE_FRAME_TIME).timeout
        set_evolution_message("Huh? %s stopped evolving!" % old_display_name)
        await main._type_battle_text("Huh? %s stopped evolving!" % old_display_name)
        hide_progression_overlay()
        return false

    if not BattleEngine.apply_evolution(pokemon, new_species):
        hide_progression_overlay()
        return false
    main.pokedex_progress.mark(pokemon, true)
    _set_evolution_sprite_halves(new_texture, new_texture, {}, true)
    if party_index >= 0 and party_index < main.caught_pokemon.size():
        main.caught_pokemon[party_index] = pokemon
    main._refresh_battle_sprites()
    main._update_battle_hud()
    main._play_pokemon_cry(pokemon)
    await main.get_tree().create_timer(30.0 * main.SOURCE_FRAME_TIME).timeout
    main._play_source_battle_sound("fanfare2.ogg")
    set_evolution_message("Congratulations! Your %s evolved into %s!" % [
        old_display_name, new_species.to_upper().replace("_", " ")])
    await main._type_battle_text("Congratulations! Your %s evolved into %s!" % [
        old_display_name, new_species.to_upper().replace("_", " ")])
    hide_progression_overlay()
    await _learn_level_moves(pokemon, BattleEngine.moves_learned_at_level(
        new_species, int(pokemon.get("level", 1))))
    return true
