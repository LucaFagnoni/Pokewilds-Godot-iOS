extends RefCounted

## The POKEMON (party) menu of the game menu: its rows (shared with the battle's
## party view and the storage screen), the action menu (stats, switch, field
## moves, deploy) and the three stats pages.
## Split out of main.gd; reaches the game through `main`.

const PokemonData = preload("res://scripts/pokemon_data.gd")
const BattleEngine = preload("res://scripts/battle_engine.gd")
const PokemonEcology = preload("res://scripts/pokemon_ecology.gd")
const FieldMoveData = preload("res://scripts/field_move_data.gd")
const PokemonState = preload("res://scripts/pokemon_state.gd")
const GameOptions = preload("res://scripts/game_options.gd")
const SOURCE_MALE_SYMBOL = preload("res://assets/source_exact/global/male_symbol1.png")
const SOURCE_PARTY_HEALTH_ROW := preload(
    "res://assets/source_exact/menu/gsc/health_bar1.png")
const POKEMON_EGG_TEXTURE := preload("res://assets/pokemon_egg.png")
const SOURCE_STATS_BACKGROUNDS := [
    preload("res://assets/source_exact/menu/stats_screen1.png"),
    preload("res://assets/source_exact/menu/stats_screen2.png"),
    preload("res://assets/source_exact/menu/stats_screen3.png")
]
const JOHTO_FONT := preload("res://assets/source_text_font.fnt")

var main: GameMain
var pokemon_action_cursor: TextureRect
var pokemon_menu_gender: TextureRect
var party_sprite_animation_elapsed := 0.0
var party_sprite_animation_frame := 0
var pokemon_stats_pages: Array[Control] = []
var pokemon_stats_tabs: Array[ColorRect] = []
var pokemon_stats_tab_ticks: Array[Label] = []
var pokemon_stats_fields: Dictionary = {}
var pokemon_stats_exp_fill: ColorRect
var pokemon_stats_background: TextureRect
var pokemon_stats_sprite: TextureRect
var pokemon_stats_header_left: Label
var pokemon_stats_header_right: Label
var pokemon_stats_shiny: TextureRect
var pokemon_stats_gender: TextureRect
var pokemon_stats_hp_fill: ColorRect
var pokemon_stats_page := 0
var pokemon_stats_pokemon: Dictionary = {}
var pokemon_stats_return_context := ""
var pokemon_move_index := 0

func _init(owner_main: GameMain) -> void:
    main = owner_main

func create_party_list_row(parent: Control, row_index: int) -> Dictionary:
    # M74.3.9.11: reproduce the ORIGINAL PokeWilds party-row composition
    # from picture 2 instead of spreading every source X-coordinate across the
    # 16:9 viewport.  The 160x144 source menu has 16px rows; 1.25x vertical
    # mapping to the unchanged y=138 border gives a 19px row pitch in the existing 320x180 UI.  The left
    # cluster (cursor/sprite/name/gender/level/HP plate) keeps that same 1.25x
    # source spacing and native aspect.  ONLY the straight HP meter and its
    # right-aligned number consume the extra widescreen width.  This preserves
    # the source look without letterboxing or warping sprites/text.
    const PARTY_ROW_PITCH := 19.0
    const PARTY_RIGHT := 318.0
    const HP_TRACK_X := 130.0
    const HP_TRACK_Y := 20.0
    const HP_TRACK_H := 7.0
    const HP_RIGHT_CAP_W := 5.0
    const HP_FILL_Y := 2.0
    const HP_FILL_H := 2.0

    var row := Control.new()
    row.name = "PartyRow%d" % row_index
    row.position = Vector2(0, row_index * PARTY_ROW_PITCH)
    row.size = Vector2(320, PARTY_ROW_PITCH)
    row.mouse_filter = Control.MOUSE_FILTER_IGNORE
    parent.add_child(row)

    # Source anchors from the actual PokeWilds 160px row, scaled by 1.25:
    # cursor x0, sprite x7, name x24, gender x25, level x67,
    # HP plate x88 and meter x104.  These are deliberately COMPACT.
    var cursor := main._source_texture_rect(row, "Cursor", Vector2(1, 9),
        Vector2(6, 8), main.source_command_cursor.texture)
    cursor.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED

    var sprite := main._source_texture_rect(row, "PokemonSprite", Vector2(9, 6),
        Vector2(19, 19))
    sprite.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
    var held_icon := main._source_texture_rect(row, "HeldItem", Vector2(9, 17), Vector2(8, 8), preload("res://assets/landmark_pokeball.png"))
    held_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
    held_icon.visible = false
    var shiny_icon := main._source_texture_rect(row, "ShinyIcon", Vector2(20, 17), Vector2(8, 8), preload("res://scripts/menu_symbol_palette.gd").shiny())
    shiny_icon.visible = false

    # First line: source-like name cluster on the left; HP number remains
    # flush-right above the extended meter, exactly as the source does above
    # its shorter meter.
    var name_label := main._source_ui_label(row, "Name", Vector2(30, 9),
        Vector2(124, 11), 11)
    name_label.clip_text = true
    name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
    var hp_value := main._source_ui_label(row, "HPValue", Vector2(220, 10),
        Vector2(98, 11), 11)
    hp_value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT

    # Second line exactly follows picture 2: gender immediately below the
    # name, then :L##, the authored gold HP: plate, and the meter on ONE line.
    var status_label := main._source_ui_label(row, "Status", Vector2(30, 18),
        Vector2(27, 9), 8)
    status_label.clip_text = true
    var gender := main._source_texture_rect(row, "Gender", Vector2(58, 18),
        Vector2(10, 10), SOURCE_MALE_SYMBOL)
    gender.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
    var level := main._source_ui_label(row, "Level", Vector2(84, 20),
        Vector2(46, 10), 10)
    var hp_badge := main._source_texture_rect(row, "HPBadge", Vector2(113, 20),
        Vector2(17, 7), main._source_texture_region(
            SOURCE_PARTY_HEALTH_ROW, Rect2(88, 9, 16, 6)))
    hp_badge.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED

    # Recreate the source bar geometry instead of drawing a boxed rectangle.
    # Original source pixels: white trough, green/orange/red fill, one black
    # bottom rule and a four-pixel black end cap.  Widescreen merely extends
    # the straight trough; nothing with recognizable artwork is stretched.
    var hp_track := Control.new()
    hp_track.name = "HPTrack"
    hp_track.position = Vector2(HP_TRACK_X, HP_TRACK_Y)
    hp_track.size = Vector2(PARTY_RIGHT - HP_TRACK_X, HP_TRACK_H)
    hp_track.mouse_filter = Control.MOUSE_FILTER_IGNORE
    row.add_child(hp_track)

    var hp_bottom := ColorRect.new()
    hp_bottom.name = "BottomRule"
    hp_bottom.position = Vector2(0, HP_TRACK_H - 1)
    hp_bottom.size = Vector2(hp_track.size.x, 1)
    hp_bottom.color = Color.BLACK
    hp_bottom.mouse_filter = Control.MOUSE_FILTER_IGNORE
    hp_track.add_child(hp_bottom)

    var hp_end_cap := ColorRect.new()
    hp_end_cap.name = "EndCap"
    hp_end_cap.position = Vector2(hp_track.size.x - HP_RIGHT_CAP_W, 0)
    hp_end_cap.size = Vector2(HP_RIGHT_CAP_W, HP_TRACK_H)
    hp_end_cap.color = Color.BLACK
    hp_end_cap.mouse_filter = Control.MOUSE_FILTER_IGNORE
    hp_track.add_child(hp_end_cap)

    var hp_fill := ColorRect.new()
    hp_fill.name = "Fill"
    hp_fill.position = Vector2(0, HP_FILL_Y)
    hp_fill.size = Vector2(hp_track.size.x - HP_RIGHT_CAP_W, HP_FILL_H)
    hp_fill.color = Color8(0, 184, 0)
    hp_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
    hp_track.add_child(hp_fill)

    return {
        "root":row, "cursor":cursor, "sprite":sprite, "shiny_icon":shiny_icon, "held_icon":held_icon,
        "name":name_label, "gender":gender, "status":status_label, "level":level,
        "hp_value":hp_value, "hp_fill":hp_fill,
        "hp_capacity":hp_track.size.x - HP_RIGHT_CAP_W,
        "row_index":row_index, "species":"", "is_egg":false
    }

func _hide_legacy_party_card() -> void:
    main.pokemon_menu_cursor.visible = false
    main.pokemon_menu_sprite.visible = false
    main.pokemon_menu_name.visible = false
    main.pokemon_menu_level.visible = false
    main.pokemon_menu_hp_value.visible = false
    main.pokemon_menu_hp_fill.get_parent().visible = false
    if pokemon_menu_gender != null:
        pokemon_menu_gender.visible = false

func _party_status_abbreviation(status: String) -> String:
    match status.to_upper():
        "BURN":
            return "BRN"
        "POISON":
            return "PSN"
        "PARALYSIS":
            return "PAR"
        "SLEEP":
            return "SLP"
        "FREEZE":
            return "FRZ"
    return ""

func _set_party_list_row(row_data: Dictionary, pokemon: Dictionary,
        selected: bool) -> void:
    var root := row_data["root"] as Control
    root.visible = not pokemon.is_empty()
    if pokemon.is_empty():
        row_data["species"] = ""
        row_data["is_egg"] = false
        return
    (row_data["cursor"] as TextureRect).visible = selected
    var sprite := row_data["sprite"] as TextureRect
    var name_label := row_data["name"] as Label
    var gender := row_data["gender"] as TextureRect
    var status_label := row_data["status"] as Label
    var level := row_data["level"] as Label
    var hp_value := row_data["hp_value"] as Label
    var hp_fill := row_data["hp_fill"] as ColorRect
    (row_data["shiny_icon"] as TextureRect).visible = PokemonData.is_shiny(pokemon) and not bool(pokemon.get("is_egg", false))
    (row_data["held_icon"] as TextureRect).visible = not bool(pokemon.get("is_egg", false)) and not String(pokemon.get("held_item", "")).is_empty()
    if bool(pokemon.get("is_egg", false)):
        row_data["species"] = ""
        row_data["is_egg"] = true
        sprite.texture = POKEMON_EGG_TEXTURE
        sprite.visible = true
        name_label.text = "EGG"
        name_label.scale.x = 1.0
        gender.visible = false
        status_label.text = ""
        level.text = ""
        hp_value.text = "--/--"
        hp_fill.size.x = 0.0
        return
    var record := BattleEngine.ensure_pokemon(pokemon)
    var species := String(record.get("species", "machop")).to_lower()
    row_data["species"] = species
    row_data["shiny"] = PokemonData.is_shiny(record)
    row_data["form"] = String(record.get("form", ""))
    row_data["is_egg"] = false
    sprite.texture = party_record_frame(row_data)
    sprite.visible = sprite.texture != null
    set_fitting_pokemon_name(name_label, record)
    status_label.text = _party_status_abbreviation(String(record.get("status", "")))
    level.text = ":L%d" % int(record.get("level", 1))
    # The bitmap font advances eight pixels even at this label's font size.
    # Fit the complete level before the shifted badge, including level 100.
    var level_width := level.get_theme_font("font").get_string_size(
        level.text, HORIZONTAL_ALIGNMENT_LEFT, -1, 10).x
    level.scale.x = minf(1.0, 28.0 / maxf(1.0, level_width))
    main._set_source_gender(gender, record)
    var hp := int(record.get("hp", 0))
    var max_hp := maxi(1, int(record.get("max_hp", 1)))
    var ratio := clampf(float(hp) / float(max_hp), 0.0, 1.0)
    hp_value.text = "%d/%d" % [hp, max_hp]
    var hp_capacity := float(row_data.get("hp_capacity", 100.0))
    hp_fill.size.x = main._battle_hp_width(ratio, hp_capacity)
    hp_fill.color = main._battle_hp_color(ratio)

func refresh_party_list_rows(rows: Array[Dictionary], party: Array,
        selected_index: int) -> void:
    for row_index in range(rows.size()):
        var pokemon: Dictionary = {}
        if row_index < mini(6, party.size()) and \
                typeof(party[row_index]) == TYPE_DICTIONARY:
            pokemon = party[row_index] as Dictionary
        _set_party_list_row(rows[row_index], pokemon, row_index == selected_index)

func _refresh_party_sprite_frames(rows: Array[Dictionary]) -> void:
    for row_data in rows:
        var species := String(row_data.get("species", ""))
        if species.is_empty():
            continue
        var sprite := row_data.get("sprite") as TextureRect
        if sprite == null or not sprite.visible:
            continue
        sprite.texture = party_record_frame(row_data)

func update_party_sprite_animation(delta: float) -> void:
    var overworld_party_visible := (
        main.pokemon_menu_open and main.pokemon_menu != null and main.pokemon_menu.visible)
    var battle_party_visible := (
        main.battle_party_view != null and main.battle_party_view.visible)
    # The touch start menu's party strip: its sprites walk and its HP bars follow
    # healing (a sleeping bag, a bed, a co-op campfire) while it stays open.
    var start_strip_visible: bool = is_instance_valid(main.touch_ui) and main.touch_ui.enabled         and is_instance_valid(main.touch_ui.surfaces.start_menu) and main.touch_ui.surfaces.start_menu.visible
    if not overworld_party_visible and not battle_party_visible and not main.storage_menu_open and not start_strip_visible:
        party_sprite_animation_elapsed = 0.0
        return
    party_sprite_animation_elapsed += delta
    if party_sprite_animation_elapsed < 0.30:
        return
    party_sprite_animation_elapsed = fmod(party_sprite_animation_elapsed, 0.30)
    party_sprite_animation_frame = (party_sprite_animation_frame + 1) & 1
    if overworld_party_visible:
        _refresh_party_sprite_frames(main.pokemon_party_rows)
    if battle_party_visible:
        _refresh_party_sprite_frames(main.battle_party_rows)
    if main.storage_menu_open:
        _refresh_party_sprite_frames(main.storage_rows)
    if start_strip_visible:
        main.touch_ui.surfaces._refresh_start_details()

func build_party_menu_ui() -> void:
    # Use the full viewport for both party selectors.  Keeping controls at
    # native scale makes the text readable and prevents the right-hand HP
    # values and popup entries from being clipped on Android.
    main.pokemon_menu_cursor.position = Vector2(4, 10)
    main.pokemon_menu_cursor.size = Vector2(10, 16)
    main.pokemon_menu_sprite.position = Vector2(20, 6)
    main.pokemon_menu_sprite.size = Vector2(32, 32)
    main.pokemon_menu_sprite.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
    main.pokemon_menu_name.position = Vector2(58, 10)
    main.pokemon_menu_name.size = Vector2(130, 18)
    main.pokemon_menu_level.position = Vector2(150, 26)
    main.pokemon_menu_level.size = Vector2(44, 16)
    main.pokemon_menu_hp_value.position = Vector2(230, 9)
    main.pokemon_menu_hp_value.size = Vector2(72, 18)
    var pokemon_hp_bar = main.pokemon_menu_hp_fill.get_parent() as ColorRect
    pokemon_hp_bar.position = Vector2(208, 34)
    pokemon_hp_bar.size = Vector2(94, 10)
    main.pokemon_menu_hp_fill.position = Vector2(3, 3)
    main.pokemon_menu_hp_fill.size = Vector2(88, 4)
    var prompt_box = main.pokemon_menu_prompt.get_parent() as Panel
    prompt_box.position = Vector2(4, 138)
    prompt_box.size = Vector2(312, 40)
    main.pokemon_menu_prompt.position = Vector2(14, 10)
    main.pokemon_menu_prompt.size = Vector2(280, 18)
    pokemon_menu_gender = main._source_texture_rect(main.pokemon_menu, "Gender",
        Vector2(62, 29), Vector2(10, 10), SOURCE_MALE_SYMBOL)
    _hide_legacy_party_card()
    for row_index in range(6):
        main.pokemon_party_rows.append(create_party_list_row(main.pokemon_menu, row_index))
    main.start_menu.pokemon_action_panel = Panel.new()
    main.start_menu.pokemon_action_panel.name = "PokemonActionMenu"
    main.start_menu.pokemon_action_panel.position = Vector2(166, 40)
    main.start_menu.pokemon_action_panel.size = Vector2(150, 138)
    main.start_menu.pokemon_action_panel.add_theme_stylebox_override("panel", main._classic_dialogue_style())
    main.pokemon_menu.add_child(main.start_menu.pokemon_action_panel)
    pokemon_action_cursor = main._source_texture_rect(main.start_menu.pokemon_action_panel, "Cursor",
        Vector2(12, 10), Vector2(5, 7), main.source_command_cursor.texture)
    pokemon_action_cursor.stretch_mode = TextureRect.STRETCH_SCALE
    main.pokemon_action_list = main._source_ui_label(main.start_menu.pokemon_action_panel, "List",
        Vector2(28, 10), Vector2(110, 116), 10)
    main.pokemon_action_list.add_theme_constant_override("line_spacing", 6)
    main.start_menu.pokemon_action_panel.visible = false

func build_pokemon_stats_ui() -> void:
    # Three exact source stat-page plates with selected-Pokemon data layered
    # over their intended blank fields.
    main.pokemon_stats_overlay = Control.new()
    main.pokemon_stats_overlay.name = "PokemonStatsOverlay"
    main.pokemon_stats_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    main.pokemon_stats_overlay.z_index = 360
    main.get_node("UI").add_child(main.pokemon_stats_overlay)
    var stats_backdrop = ColorRect.new()
    stats_backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    stats_backdrop.color = Color.WHITE
    stats_backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
    main.pokemon_stats_overlay.add_child(stats_backdrop)
    var stats_source = Control.new()
    stats_source.name = "SourceCanvas"
    stats_source.position = Vector2.ZERO
    stats_source.size = Vector2(320, 180)
    stats_source.scale = Vector2.ONE
    main.pokemon_stats_overlay.add_child(stats_source)
    pokemon_stats_background = main._source_texture_rect(stats_source, "Background",
        Vector2.ZERO, Vector2(320, 180), SOURCE_STATS_BACKGROUNDS[0])
    pokemon_stats_background.stretch_mode = TextureRect.STRETCH_SCALE
    pokemon_stats_background.visible = false
    pokemon_stats_sprite = main._source_texture_rect(stats_source, "PokemonSprite",
        Vector2(14, 8), Vector2(64, 64))
    var header_line = ColorRect.new()
    header_line.name = "HeaderDivider"
    header_line.position = Vector2(0, 76)
    header_line.size = Vector2(320, 4)
    header_line.color = Color.WHITE
    stats_source.add_child(header_line)
    pokemon_stats_header_left = main._source_ui_label(stats_source, "HeaderLeft",
        Vector2(112, 4), Vector2(72, 14), 9)
    pokemon_stats_header_right = main._source_ui_label(stats_source, "HeaderRight",
        Vector2(228, 4), Vector2(48, 14), 10)
    pokemon_stats_header_right.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
    pokemon_stats_gender = main._source_texture_rect(stats_source, "Gender",
        Vector2(286, 4), Vector2(10, 10), SOURCE_MALE_SYMBOL)
    pokemon_stats_shiny = main._source_texture_rect(stats_source, "Shiny",
        Vector2(70, 64), Vector2(8, 8), preload("res://scripts/menu_symbol_palette.gd").shiny())
    pokemon_stats_shiny.visible = false
    _pokemon_stat_field(stats_source, "Name", Vector2(112, 25), Vector2(180, 18), 12)
    main._source_ui_label(stats_source, "Slash", Vector2(142, 48),
        Vector2(12, 12), 9, "/")
    var tab_colors = [Color8(248, 152, 248), Color8(176, 248, 104),
        Color8(136, 240, 240)]
    for tab_index in range(3):
        var tab_border = ColorRect.new()
        tab_border.name = "Tab%dBorder" % tab_index
        tab_border.position = Vector2(204 + tab_index * 36, 47)
        tab_border.size = Vector2(24, 24)
        tab_border.color = Color.BLACK
        stats_source.add_child(tab_border)
        var tab = ColorRect.new()
        tab.name = "Tab%d" % tab_index
        tab.position = Vector2(3, 3)
        tab.size = Vector2(18, 18)
        tab.color = tab_colors[tab_index]
        tab_border.add_child(tab)
        pokemon_stats_tabs.append(tab)
        var tick = main._source_ui_label(tab_border, "Tick", Vector2(5, 3),
            Vector2(14, 14), 9, "▼", true)
        tick.add_theme_color_override("font_color", Color.WHITE)
        pokemon_stats_tab_ticks.append(tick)
    _build_pokemon_stats_pages(stats_source)

func show_pokemon_menu() -> void:
    main.pokemon_menu_open = true
    main.pokemon_menu_index = 0
    pokemon_move_index = 0
    main.pokemon_action_open = false
    main.pokemon_switch_selecting = false
    main.start_menu.pokemon_action_panel.visible = false
    main.game_menu_box.visible = false
    main.game_menu_detail.visible = false
    main.game_menu_map.visible = false
    main.game_menu_map_screen.visible = false
    main.pokemon_menu.visible = true
    refresh_pokemon_category_menu()

func refresh_pokemon_category_menu() -> void:
    main.pokemon_menu_prompt.text = "Choose a POKEMON."

    if main.caught_pokemon.is_empty():
        refresh_party_list_rows(main.pokemon_party_rows, [], -1)
        main.pokemon_menu_prompt.text = "NO POKEMON." if main.touch_on() else "NO POKEMON.   B: BACK"
        return

    var visible_count := mini(6, main.caught_pokemon.size())
    main.pokemon_menu_index = clampi(main.pokemon_menu_index, 0, visible_count - 1)
    for index in range(visible_count):
        if typeof(main.caught_pokemon[index]) == TYPE_DICTIONARY:
            main.caught_pokemon[index] = BattleEngine.ensure_pokemon(
                main.caught_pokemon[index] as Dictionary)
    refresh_party_list_rows(main.pokemon_party_rows, main.caught_pokemon,
        main.pokemon_menu_index)
    var entry := main.caught_pokemon[main.pokemon_menu_index] as Dictionary
    if bool(entry.get("is_egg", false)):
        main.pokemon_menu_prompt.text = ("%d STEPS TO HATCH" if main.touch_on() else "%d STEPS TO HATCH   B: BACK") % int(
            entry.get("hatch_steps", main.EGG_HATCH_STEPS))
        return
    main.pokemon_menu_prompt.text = (
        "Move to which position?" if main.pokemon_switch_selecting
        else "Choose a POKEMON."
    )

func pokemon_world_actions(species: String, pokemon: Dictionary = {}) -> Array[String]:
    if bool(pokemon.get("is_egg", false)): return ["SWITCH", "DROP", "CANCEL"]
    var result := FieldMoveData.field_moves_for(species, String(pokemon.get("form", "")))
    if not result.has("FOLLOW"):
        result.append("FOLLOW")
    result.append("STATS")
    result.append("SWITCH")
    result.append("DROP")
    result.append("CANCEL")
    return result

func open_pokemon_action_menu() -> void:
    if main.caught_pokemon.is_empty():
        return
    var entry := main.caught_pokemon[main.pokemon_menu_index] as Dictionary
    main.start_menu.pokemon_action_entries = pokemon_world_actions(
        String(entry.get("species", "")), entry)
    main.pokemon_action_index = 0
    main.pokemon_action_open = true
    main.start_menu.pokemon_action_panel.visible = true
    refresh_pokemon_action_menu()

func refresh_pokemon_action_menu() -> void:
    if main.start_menu.pokemon_action_entries.is_empty():
        main.start_menu.pokemon_action_entries = ["CANCEL"]
    main.pokemon_action_index = wrapi(main.pokemon_action_index, 0, main.start_menu.pokemon_action_entries.size())
    refresh_source_action_rows(main.pokemon_action_list, pokemon_action_cursor,
        main.start_menu.pokemon_action_entries, main.pokemon_action_index)

func close_pokemon_action_menu() -> void:
    main.pokemon_action_open = false
    main.start_menu.pokemon_action_panel.visible = false

func activate_pokemon_action() -> void:
    if main.start_menu.pokemon_action_entries.is_empty():
        return
    var action := String(main.start_menu.pokemon_action_entries[main.pokemon_action_index])
    if action == "CANCEL":
        close_pokemon_action_menu()
        return
    if action == "STATS":
        var selected := BattleEngine.ensure_pokemon(main.caught_pokemon[main.pokemon_menu_index])
        main.caught_pokemon[main.pokemon_menu_index] = selected
        close_pokemon_action_menu()
        open_pokemon_stats(selected, "OVERWORLD")
        return
    if action == "SWITCH":
        close_pokemon_action_menu()
        main.pokemon_switch_selecting = true
        main.pokemon_switch_source_index = main.pokemon_menu_index
        main.pokemon_menu_prompt.text = "Move to which position?"
        return
    if action == "DROP":
        close_pokemon_action_menu()
        _deploy_selected_pokemon()
        return
    pokemon_move_index = main.start_menu.pokemon_action_entries.find(action)
    close_pokemon_action_menu()
    _activate_selected_field_move()

func finish_pokemon_switch() -> void:
    if main.caught_pokemon.is_empty():
        return
    var destination := main.pokemon_menu_index
    var source_index := clampi(main.pokemon_switch_source_index, 0,
        main.caught_pokemon.size() - 1)
    if source_index != destination:
        var source_pokemon = main.caught_pokemon[source_index]
        main.caught_pokemon[source_index] = main.caught_pokemon[destination]
        main.caught_pokemon[destination] = source_pokemon
    main.pokemon_switch_selecting = false
    main.pokemon_switch_source_index = -1
    main.pokemon_menu_index = destination
    refresh_pokemon_category_menu()

func open_pokemon_stats(pokemon: Dictionary, return_context: String) -> void:
    pokemon_stats_pokemon = BattleEngine.ensure_pokemon(pokemon)
    pokemon_stats_return_context = return_context
    pokemon_stats_page = 0
    main.pokemon_stats_open = true
    main.pokemon_stats_overlay.visible = true
    _refresh_pokemon_stats()

func _refresh_pokemon_stats() -> void:
    if pokemon_stats_pokemon.is_empty():
        return
    var pokemon = pokemon_stats_pokemon
    var species = String(pokemon.get("species", "machop")).to_lower()
    var info = PokemonData.info(species)
    var stats = pokemon.get("stats", {}) as Dictionary
    var level = int(pokemon.get("level", 1))
    pokemon_stats_background.texture = SOURCE_STATS_BACKGROUNDS[pokemon_stats_page]
    pokemon_stats_sprite.texture = main._battle_sprite_frame(PokemonData.record_texture(pokemon, "front"))
    pokemon_stats_header_left.text = "No.%03d" % int(info.get("dex", 0))
    pokemon_stats_header_right.text = ":L%d" % level
    var level_width := pokemon_stats_header_right.get_theme_font("font").get_string_size(pokemon_stats_header_right.text, HORIZONTAL_ALIGNMENT_LEFT, -1, 10).x
    pokemon_stats_header_right.size.x = maxf(48.0, level_width)
    pokemon_stats_header_right.position.x = 276.0 - pokemon_stats_header_right.size.x
    pokemon_stats_shiny.visible = PokemonData.is_shiny(pokemon)
    set_fitting_pokemon_name(pokemon_stats_fields.Name as Label, pokemon)
    main._set_source_gender(pokemon_stats_gender, pokemon)
    for index in range(3):
        pokemon_stats_pages[index].visible = index == pokemon_stats_page
        pokemon_stats_tab_ticks[index].visible = index == pokemon_stats_page
        pokemon_stats_tabs[index].color = [Color8(248, 152, 248),
            Color8(176, 248, 104), Color8(136, 240, 240)][index]
    var hp = int(pokemon.get("hp", 0))
    var max_hp = maxi(1, int(pokemon.get("max_hp", 1)))
    (pokemon_stats_fields.HP as Label).text = "%d/%d" % [hp, max_hp]
    var status = String(pokemon.get("status", ""))
    (pokemon_stats_fields.Status as Label).text = "OK" if status.is_empty() else status
    (pokemon_stats_fields.Types as Label).text = "\n".join(info.get("types", ["NORMAL"]))
    var current_exp = int(pokemon.get("exp", BattleEngine.exp_for_level(species, level)))
    var next_exp = BattleEngine.exp_for_level(species, mini(100, level + 1))
    (pokemon_stats_fields.Exp as Label).text = str(current_exp)
    (pokemon_stats_fields.NextExp as Label).text = str(maxi(0, next_exp - current_exp))
    (pokemon_stats_fields.NextLevel as Label).text = "TO :L%d" % mini(100, level + 1)
    var exp_floor = BattleEngine.exp_for_level(species, level)
    var exp_ratio = 1.0 if level >= 100 else clampf(
        float(current_exp - exp_floor) / maxf(1.0, float(next_exp - exp_floor)), 0.0, 1.0)
    if pokemon_stats_exp_fill != null:
        pokemon_stats_exp_fill.size.x = floorf(126.0 * exp_ratio)
    var held = String(pokemon.get("held_item", ""))
    (pokemon_stats_fields.Item as Label).text = "---" if held.is_empty() else held
    var moves: Array = pokemon.get("moves", [])
    for index in range(4):
        (pokemon_stats_fields["Move%d" % index] as Label).text = (
            String(moves[index]).replace("_", " ") if index < moves.size() else "-")
    (pokemon_stats_fields.TrainerId as Label).text = "%05d" % int(pokemon.get("trainer_id", 0))
    (pokemon_stats_fields.OriginalTrainer as Label).text = String(
        pokemon.get("original_trainer", main.player_model_name.text)).to_upper().left(9)
    for key in ["attack", "defense", "sp_attack", "sp_defense", "speed"]:
        (pokemon_stats_fields[key] as Label).text = str(int(stats.get(key, 0)))

func handle_pokemon_stats_input(event: InputEvent) -> void:
    if event.is_action_pressed("move_left") or event.is_action_pressed("move_up"):
        pokemon_stats_page = wrapi(pokemon_stats_page - 1, 0, 3)
        _refresh_pokemon_stats()
    elif event.is_action_pressed("move_right") or event.is_action_pressed("move_down") or \
            event.is_action_pressed("confirm"):
        pokemon_stats_page = wrapi(pokemon_stats_page + 1, 0, 3)
        _refresh_pokemon_stats()
    elif event.is_action_pressed("cancel") or event.is_action_pressed("start"):
        _close_pokemon_stats()
    else:
        return
    main.get_viewport().set_input_as_handled()

func _close_pokemon_stats() -> void:
    main.pokemon_stats_open = false
    main.pokemon_stats_overlay.visible = false
    if pokemon_stats_return_context == "OVERWORLD" and main.pokemon_menu_open:
        main.pokemon_action_open = true
        main.start_menu.pokemon_action_panel.visible = true
    elif pokemon_stats_return_context == "BATTLE" and main.battle_active and \
            main.battle_submenu_mode == "PARTY":
        main.battle_party_action_open = true
        main.battle_party_action_panel.visible = true
    pokemon_stats_return_context = ""
    pokemon_stats_pokemon = {}

func _cycle_selected_field_move(direction: int) -> void:
    if main.caught_pokemon.is_empty():
        return
    var entry = main.caught_pokemon[clampi(main.pokemon_menu_index, 0, main.caught_pokemon.size() - 1)]
    if typeof(entry) != TYPE_DICTIONARY:
        return
    if bool((entry as Dictionary).get("is_egg", false)):
        return
    var moves := pokemon_world_actions(String(entry.get("species", "")), entry)
    pokemon_move_index = wrapi(pokemon_move_index + direction, 0, moves.size())
    refresh_pokemon_category_menu()

func _activate_selected_field_move() -> void:
    if main.caught_pokemon.is_empty():
        return
    main.pokemon_menu_index = clampi(main.pokemon_menu_index, 0, main.caught_pokemon.size() - 1)
    main._ensure_party_ecology_id(main.pokemon_menu_index)
    var entry = main.caught_pokemon[main.pokemon_menu_index]
    if typeof(entry) != TYPE_DICTIONARY:
        return
    if bool((entry as Dictionary).get("is_egg", false)):
        main.dialogs.show_message("An EGG has no field move.")
        return
    if int((entry as Dictionary).get("hp", 1)) <= 0:
        main.dialogs.show_message("A fainted POKEMON cannot use a FIELD MOVE.")
        return
    var species := String(entry.get("species", "")).to_lower()
    var moves := pokemon_world_actions(species, entry)
    pokemon_move_index = clampi(pokemon_move_index, 0, moves.size() - 1)
    var move := String(moves[pokemon_move_index])
    if move == "STATS":
        var pokemon := BattleEngine.ensure_pokemon(entry)
        main.caught_pokemon[main.pokemon_menu_index] = pokemon
        open_pokemon_stats(pokemon, "OVERWORLD")
        return
    if move == "DROP":
        _deploy_selected_pokemon()
        return
    if move in ["SWITCH", "CANCEL"]:
        return
    if move == "TAKE ITEM":
        var held_item := String(entry.get("held_item", ""))
        if not held_item.is_empty():
            main.inventory[held_item] = int(main.inventory.get(held_item, 0)) + 1
            entry["held_item"] = ""
            main.caught_pokemon[main.pokemon_menu_index] = entry
            main.dialogs.show_message("Took %s from %s." % [held_item, PokemonData.battle_display_name(species)])
            pokemon_move_index = 0
            refresh_pokemon_category_menu()
        return
    if move.begins_with("HOLD:"):
        var item_name := move.trim_prefix("HOLD:")
        if int(main.inventory.get(item_name, 0)) <= 0:
            main.dialogs.show_message("There is no %s left." % item_name)
            return
        var old_item := String(entry.get("held_item", ""))
        if not old_item.is_empty():
            main.inventory[old_item] = int(main.inventory.get(old_item, 0)) + 1
        main.inventory[item_name] = int(main.inventory.get(item_name, 0)) - 1
        entry["held_item"] = item_name
        main.caught_pokemon[main.pokemon_menu_index] = entry
        main.dialogs.show_message("%s is now holding %s." % [PokemonData.battle_display_name(species), item_name])
        pokemon_move_index = 0
        refresh_pokemon_category_menu()
        return
    if main.bag_menu.sleeping_bag_active():
        main.dialogs.show_message("Get up before using a Field Move.")
        return
    var activated := bool(main.world.set_active_field_move(entry, move))
    if not activated:
        # Gyarados and other fish follow only while their trainer is in water.
        if move == "FOLLOW" and bool(PokemonData.info(species).get("overworld_behavior", {}).get("swim_only", false)):
            main.dialogs.show_message("%s can only follow while swimming." % PokemonData.battle_display_name(species))
        else:
            main.dialogs.show_message("%s cannot follow here." % PokemonData.battle_display_name(species))
        return
    if move == "FLY":
        main._play_pokemon_cry(entry)
    main.pokemon_menu_open = false
    main.pokemon_menu.visible = false
    main.game_menu_open = false
    main.game_menu.visible = false
    main.world.set_gameplay_enabled(true)
    main.touch_controls.set_game_active(true)
    if move == "BUILD":
        main.crafting_menu.open_build_menu()
    elif move == "FOLLOW":
        main.dialogs.show_message("%s is following you." % PokemonData.battle_display_name(species))
    else:
        if move not in ["CUT", "DIG"]:
            main.dialogs.show_message("%s is using %s." % [PokemonData.battle_display_name(species), move])

func _deploy_selected_pokemon() -> void:
    if main.caught_pokemon.is_empty():
        main.dialogs.show_message("There is no Pokemon to leave here.")
        return
    main.pokemon_menu_index = clampi(main.pokemon_menu_index, 0, main.caught_pokemon.size() - 1)
    var entry = main.caught_pokemon[main.pokemon_menu_index]
    if typeof(entry) != TYPE_DICTIONARY:
        return
    var keep_surf: bool = main.world.active_field_move == "SURF" and main.world.terrain_kind_at(main.world._player_cell()) == 0
    if keep_surf and main._ensure_party_ecology_id(main.pokemon_menu_index) == String(main.world.active_field_pokemon.get("party_ecology_id","")):
        main.dialogs.show_message("Reach dry land before leaving your surfing POKEMON.")
        return
    if main.coop_game.active:
        main.coop_game.population.deploy(main.pokemon_menu_index,keep_surf)
        return
    if main.world.deploy_pokemon(entry):
        if not keep_surf: main.world.clear_active_field_move(false)
        var species := PokemonData.battle_display_name(String(entry.get("species", "POKEMON")))
        main.caught_pokemon.remove_at(main.pokemon_menu_index)
        main.pokemon_menu_open = false
        main.pokemon_menu.visible = false
        main.game_menu_open = false
        main.game_menu.visible = false
        main.world.set_gameplay_enabled(true)
        main.touch_controls.set_game_active(true)
        main.dialogs.show_message("The EGG was placed here." if bool(entry.get("is_egg", false)) else "%s was left in the habitat." % species)

func set_fitting_pokemon_name(label: Label, record: Dictionary, override_text: String = "") -> void:
    if not label.has_meta("original_name_overrun"):
        label.set_meta("original_name_overrun", label.text_overrun_behavior)
        label.set_meta("original_name_clip", label.clip_text)
    var mega_name := String(record.get("species", "")) in ["mega_charizard_x", "mega_charizard_y", "mega_venusaur", "mega_blastoise", "mega_gyarados", "mega_sharpedo", "mega_kangaskhan"]
    # Fit the full X/Y suffix before drawing; Label ellipsis runs before scale.
    label.text_overrun_behavior = TextServer.OVERRUN_NO_TRIMMING if mega_name else int(label.get_meta("original_name_overrun"))
    label.clip_text = false if mega_name else bool(label.get_meta("original_name_clip"))
    var full_name := PokemonState.display_name(record).to_upper() if override_text.is_empty() else override_text
    label.text = full_name
    var width := label.get_theme_font("font").get_string_size(label.text, HORIZONTAL_ALIGNMENT_LEFT, -1, label.get_theme_font_size("font_size")).x
    label.scale.x = minf(1.0, label.size.x / maxf(1.0, width))

func party_record_frame(row_data: Dictionary) -> Texture2D:
    var species := String(row_data.get("species", ""))
    var community_key := "mega_gengar" if species == "gengar" and String(row_data.get("form", "")) == "mega" else species
    var community := preload("res://scripts/divinakra_mega_art.gd").texture(community_key, "menu", PokemonData.is_shiny(row_data))
    if community != null:
        return main._source_texture_region(community, Rect2((4 + party_sprite_animation_frame % 2) * 16, 0, 16, 16))
    if species == "gengar" and String(row_data.get("form", "")) == "mega":
        var sheet := PokemonData.record_texture(row_data, "overworld")
        return main._source_texture_region(sheet, Rect2((4 + party_sprite_animation_frame % 2) * 32, 0, 32, 32))
    return _party_overworld_frame(species, party_sprite_animation_frame, bool(row_data.get("shiny", false)))

func _party_overworld_frame(species: String, animation_frame: int = 0, shiny: bool = false) -> Texture2D:
    # Picture 2 uses the Pokemon's actual PokeWilds 16x16 overworld artwork.
    # Use each authored sheet's front-facing pair; never reuse CUT pose state.
    var texture := PokemonData.texture(species, "overworld", shiny)
    if texture == null:
        return main._battle_sprite_frame(PokemonData.texture(species, "front", shiny))
    if texture.has_meta("mega_gengar_walk"):
        var mega_frame := texture.get_width() / 6.0
        return main._source_texture_region(texture, Rect2((4 + animation_frame % 2) * mega_frame, 0, mega_frame, texture.get_height()))
    var front_pair := 4
    if species.to_lower() in ["krabby", "kingler"]:
        front_pair = 0
    elif species.to_lower() in ["lombre", "lotad", "shellder", "slowpoke", "growlithe_hisuian"]:
        front_pair = 2
    var frame := front_pair + clampi(animation_frame, 0, 1)
    if species.to_lower() in ["aexeggutor", "exeggutor_alolan"] and texture.get_height() == 48:
        return main._source_texture_region(texture, Rect2(frame * 16, 0, 16, 48))
    if texture.get_width() >= 96 and texture.get_height() >= 16:
        return main._source_texture_region(texture, Rect2(frame * 16, 0, 16, 16))
    if texture.get_height() >= 96 and texture.get_width() >= 16:
        return main._source_texture_region(texture, Rect2(0, frame * 16, 16, 16))
    frame = clampi(animation_frame, 0, 1)
    if texture.get_width() >= 32 and texture.get_height() >= 16:
        return main._source_texture_region(texture, Rect2(frame * 16, 0, 16, 16))
    if texture.get_height() >= 32 and texture.get_width() >= 16:
        return main._source_texture_region(texture, Rect2(0, frame * 16, 16, 16))
    if texture.get_width() >= 16 and texture.get_height() >= 16:
        return main._source_texture_region(texture, Rect2(0, 0, 16, 16))
    return texture

func refresh_source_action_rows(label: Label, cursor: TextureRect,
        entries: Array, selected: int) -> void:
    var first := maxi(0, selected - 5)
    var lines: Array[String] = []
    for index in range(first, mini(first + 6, entries.size())):
        lines.append(String(entries[index]))
    label.text = "\n".join(lines)
    var font_size := label.get_theme_font_size("font_size")
    var pitch := JOHTO_FONT.get_height(font_size) + float(
        label.get_theme_constant("line_spacing"))
    cursor.position.y = roundf(label.position.y +
        float(selected - first) * pitch)

func _pokemon_stat_field(parent: Control, key: String, at: Vector2,
        dimensions: Vector2, font_size: int = 9, right: bool = false) -> Label:
    var label := main._source_ui_label(parent, key, at, dimensions, font_size)
    label.clip_text = true
    if right:
        label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
    pokemon_stats_fields[key] = label
    return label

func _pokemon_stats_border(parent: Control, at: Vector2,
        dimensions: Vector2) -> void:
    # Restore the original source-style NinePatch border. Only the unwanted
    # EXP track is removed; the stats-page frame itself remains intact.
    var border = NinePatchRect.new()
    border.texture = GameOptions.frame_texture()
    border.position = at
    border.size = dimensions
    border.patch_margin_left = 8 if int(GameOptions.values.frame) >= 2 else 10
    border.patch_margin_top = 8 if int(GameOptions.values.frame) >= 2 else 10
    border.patch_margin_right = 8 if int(GameOptions.values.frame) >= 2 else 10
    border.patch_margin_bottom = 8 if int(GameOptions.values.frame) >= 2 else 10
    border.draw_center = false
    border.mouse_filter = Control.MOUSE_FILTER_IGNORE
    border.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
    parent.add_child(border)
    parent.move_child(border, 0)

func _build_pokemon_stats_pages(parent: Control) -> void:
    for index in range(3):
        var page = ColorRect.new()
        page.name = "StatsPage%d" % index
        page.position = Vector2(0, 80)
        page.size = Vector2(320, 100)
        page.color = [Color8(248, 152, 248), Color8(176, 248, 104),
            Color8(136, 240, 240)][index]
        parent.add_child(page)
        pokemon_stats_pages.append(page)

    var hp_page = pokemon_stats_pages[0]
    main._source_ui_label(hp_page, "HPTitle", Vector2(14, 11), Vector2(30, 14), 9, "HP:")
    # M74.3.9.13: this is the stats page only. The source-font current/max HP
    # replaces the meter; battle and six-slot party HP bars are untouched.
    pokemon_stats_hp_fill = null
    _pokemon_stat_field(hp_page, "HP", Vector2(48, 10), Vector2(90, 14), 10, true)
    main._source_ui_label(hp_page, "StatusTitle", Vector2(14, 40), Vector2(82, 14), 9, "STATUS/")
    _pokemon_stat_field(hp_page, "Status", Vector2(52, 53), Vector2(84, 14), 9, true)
    main._source_ui_label(hp_page, "TypeTitle", Vector2(14, 69), Vector2(70, 14), 9, "TYPE/")
    _pokemon_stat_field(hp_page, "Types", Vector2(52, 65), Vector2(84, 24), 8, true)
    main._source_ui_label(hp_page, "ExpTitle", Vector2(171, 11), Vector2(132, 14), 10, "EXP POINTS")
    _pokemon_stat_field(hp_page, "Exp", Vector2(188, 24), Vector2(112, 14), 10, true)
    main._source_ui_label(hp_page, "NextTitle", Vector2(171, 42), Vector2(132, 14), 10, "LEVEL UP")
    _pokemon_stat_field(hp_page, "NextExp", Vector2(188, 58), Vector2(112, 14), 10, true)
    _pokemon_stat_field(hp_page, "NextLevel", Vector2(188, 73), Vector2(112, 14), 9, true)
    pokemon_stats_exp_fill = null
    _pokemon_stats_border(hp_page, Vector2.ZERO, Vector2(153, 100))
    _pokemon_stats_border(hp_page, Vector2(151, 0), Vector2(169, 100))

    var moves_page = pokemon_stats_pages[1]
    main._source_ui_label(moves_page, "ItemTitle", Vector2(16, 12), Vector2(72, 14), 10, "ITEM")
    _pokemon_stat_field(moves_page, "Item", Vector2(104, 12), Vector2(198, 14), 10)
    main._source_ui_label(moves_page, "MoveTitle", Vector2(16, 27), Vector2(72, 14), 10, "MOVE")
    for index in range(4):
        _pokemon_stat_field(moves_page, "Move%d" % index,
            Vector2(104, 27 + index * 16), Vector2(198, 15), 10)
    _pokemon_stats_border(moves_page, Vector2.ZERO, Vector2(320, 100))

    var stats_page = pokemon_stats_pages[2]
    main._source_ui_label(stats_page, "IdTitle", Vector2(16, 10), Vector2(82, 14), 9, "IDNo.")
    _pokemon_stat_field(stats_page, "TrainerId", Vector2(36, 27), Vector2(102, 14), 10)
    main._source_ui_label(stats_page, "OTTitle", Vector2(16, 51), Vector2(82, 14), 10, "OT/")
    _pokemon_stat_field(stats_page, "OriginalTrainer", Vector2(36, 68), Vector2(102, 18), 10)
    var keys = ["attack", "defense", "sp_attack", "sp_defense", "speed"]
    var titles = ["ATTACK", "DEFENSE", "SPCL.ATK", "SPCL.DEF", "SPEED"]
    for index in range(5):
        main._source_ui_label(stats_page, "Title%d" % index,
            Vector2(171, 11 + index * 17), Vector2(104, 14), 9, titles[index])
        _pokemon_stat_field(stats_page, keys[index],
            Vector2(268, 11 + index * 17), Vector2(34, 14), 9, true)
    _pokemon_stats_border(stats_page, Vector2.ZERO, Vector2(153, 100))
    _pokemon_stats_border(stats_page, Vector2(151, 0), Vector2(169, 100))
