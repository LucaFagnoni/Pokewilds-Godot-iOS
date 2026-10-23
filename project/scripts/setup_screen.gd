extends RefCounted

## The setup screen before a game: its rows (mode, world size, names, look, GO),
## the LOAD selector, typing a name, the loading screen's progress, and the
## finger swipe through the rows.
## Split out of main.gd; reaches the game through `main`.

const WorldSaves = preload("res://scripts/world_saves.gd")
const PlayerLooks = preload("res://scripts/player_looks.gd")
const JOIN_HIDDEN_NODES := ["ModeSelectionTick", "ModeLabel", "WorldSizeLabel", "WorldLabel", "WorldEdit", "NameLabel"]
const JOIN_ROW_NODES := ["AppearanceLabel", "ColorUp", "ColorDown", "PlayerColorSwatch", "ModelUp", "ModelDown", "PlayerPreview"]
## The PLAYER row is 168 px wide from x=14; this centres it on the 320 px screen.
const JOIN_ROW_SHIFT := 62.0
const MENU_ROW_MODE := 1
const MENU_ROW_SIZE := 2
const MENU_ROW_WORLD_NAME := 3
const MENU_ROW_PLAYER_NAME := 4
const JOIN_HIDDEN_ROWS := [MENU_ROW_MODE, MENU_ROW_SIZE, MENU_ROW_WORLD_NAME, MENU_ROW_PLAYER_NAME]
const MENU_ROW_GO := 6
const JOHTO_FONT := preload("res://assets/source_text_font.fnt")
const SETUP_SAVE_PATH := "user://m3_setup.cfg"

var main: GameMain
var custom_player_name := ""
## Joining someone else's world: the world is theirs, so only the player's look
## is offered. The world rows are hidden and skipped, not just locked.
var join_layout := false
var join_info: Label
var join_note: Label
var swipe_rows: Array[Control] = []
var swipe_selection := 0
var swipe_cursor: TextureRect

func _init(owner_main: GameMain) -> void:
    main = owner_main

func setup_menu_navigation() -> void:
    main.menu_row = main.MENU_ROW_LOCAL
    main.menu_col = 0
    update_classic_menu_labels()
    update_menu_cursor()

func set_join_layout(joining: bool) -> void:
    join_layout = joining
    for node_name in JOIN_HIDDEN_NODES:
        (main.setup_panel.get_node(node_name) as CanvasItem).visible = not joining
    # Where the world rows were: which world this is, then the chosen player's
    # name, then the PLAYER row, all centred.
    if join_info == null:
        join_info = main._source_ui_label(main.setup_panel, "JoinInfo", Vector2(8, 38), Vector2(304, 40), 12, "")
        join_info.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    if join_note == null:
        join_note = main._source_ui_label(main.setup_panel, "JoinNote", Vector2(8, 21), Vector2(304, 12), 8,
            "PRIVATE STORAGE FOLLOWS YOU INTO ANY WORLD")
        join_note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    join_note.visible = joining
    join_info.visible = joining
    if joining:
        var lobby: Dictionary = main.coop_game.join_lobby
        join_info.text = "JOINING\n%s" % String(lobby.get("name", "WORLD")).to_upper().left(24)
    for node_name in JOIN_ROW_NODES:
        var piece = main.setup_panel.get_node(node_name) # Controls and one Sprite2D
        if not piece.has_meta("solo_x"):
            piece.set_meta("solo_x", piece.position.x)
        piece.position.x = float(piece.get_meta("solo_x")) + (JOIN_ROW_SHIFT if joining else 0.0)
    if not main.player_model_name.has_meta("solo_rect"):
        main.player_model_name.set_meta("solo_rect", Rect2(main.player_model_name.position, main.player_model_name.size))
        main.player_model_name.set_meta("solo_align", main.player_model_name.horizontal_alignment)
    var name_home: Rect2 = main.player_model_name.get_meta("solo_rect")
    if joining:
        main.player_model_name.position = Vector2(8, 84)
        main.player_model_name.size = Vector2(304, name_home.size.y)
        main.player_model_name.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
        main.player_model_name.scale.x = 1.0
    else:
        main.player_model_name.position = name_home.position
        main.player_model_name.size = name_home.size
        main.player_model_name.horizontal_alignment = main.player_model_name.get_meta("solo_align")
        fit_player_name()
    if joining and main.menu_row in JOIN_HIDDEN_ROWS:
        main.menu_row = main.MENU_ROW_COLOR
        main.menu_col = 0
    update_menu_cursor()

func move_menu_vertical(direction: int) -> void:
    main.menu_row = wrapi(main.menu_row + direction, main.MENU_ROW_LOCAL, MENU_ROW_GO + 1)
    while join_layout and main.menu_row in JOIN_HIDDEN_ROWS:
        main.menu_row = wrapi(main.menu_row + direction, main.MENU_ROW_LOCAL, MENU_ROW_GO + 1)

    # Clamp/restore the horizontal choice for each row.
    if main.menu_row == MENU_ROW_MODE:
        main.menu_col = 0 if main.selected_mode == "NEW" else 1
    elif main.menu_row == MENU_ROW_SIZE:
        main.menu_col = main.selected_world_size
    elif main.menu_row == main.MENU_ROW_COLOR:
        # Enter the row itself first. Right/Confirm enters its selectors;
        # Left/Cancel returns here, after which Up/Down can leave the row.
        main.menu_col = 0
    else:
        main.menu_col = 0

    update_menu_cursor()
    _update_persistent_selection_ticks()

func menu_left_right(direction: int) -> void:
    if not main.coop_game.join_setup_code.is_empty() and main.menu_row in [MENU_ROW_SIZE,MENU_ROW_MODE]:return
    if main.menu_row == main.MENU_ROW_LOCAL:
        return
    if main.menu_row == MENU_ROW_MODE:
        main.menu_col = wrapi(main.menu_col + direction, 0, 2)
        main.selected_mode = "NEW" if main.menu_col == 0 else "LOAD"
        update_classic_menu_labels()
        update_menu_cursor()
        return

    if main.menu_row == MENU_ROW_SIZE:
        main.menu_col = wrapi(main.menu_col + direction, 0, main.WORLD_SIZE_NAMES.size())
        main.selected_world_size = main.menu_col
        update_classic_menu_labels()
        update_menu_cursor()
        return

    if main.menu_row == main.MENU_ROW_COLOR:
        main.menu_col = clampi(main.menu_col + direction, 0, 2)
        update_menu_cursor()
        return

    if main.menu_row == MENU_ROW_WORLD_NAME:
        begin_text_entry("world")
    elif main.menu_row == MENU_ROW_PLAYER_NAME:
        begin_text_entry("player")

func activate_menu_item() -> void:
    match main.menu_row:
        main.MENU_ROW_LOCAL:
            main.coop_game.cancel_join();main.coop_menu.open()
        MENU_ROW_MODE:
            if main.selected_mode == "LOAD":
                main.menu_status.text = "LOAD READY" if not main.saves.find(main.world_edit.text.strip_edges()).is_empty() else "NO SAVE FILE"
            else:
                main.menu_status.text = "NEW WORLD"
        MENU_ROW_SIZE:
            main.menu_status.text = "WORLD SIZE: %s" % main.WORLD_SIZE_NAMES[main.selected_world_size]
        MENU_ROW_WORLD_NAME:
            begin_text_entry("world")
        MENU_ROW_PLAYER_NAME:
            begin_text_entry("player")
        main.MENU_ROW_COLOR:
            if main.menu_col == 0:
                main.menu_col = 1
            elif main.menu_col == 1:
                main.appearance.next_color()
            elif main.menu_col == 2:
                main.appearance.next_model()
        MENU_ROW_GO:
            main._start_game()

    update_menu_cursor()

func update_classic_menu_labels() -> void:
    var mode_label := main.get_node("UI/SetupPanel/ModeLabel") as Label
    var size_label := main.get_node("UI/SetupPanel/WorldSizeLabel") as Label

    mode_label.text = "NEW        LOAD"
    size_label.text = "WORLD   S   M   L   XL   XXL"

    _update_persistent_selection_ticks()

func _update_persistent_selection_ticks() -> void:
    var mode_tick := main.get_node("UI/SetupPanel/ModeSelectionTick") as Label
    var mode_label := main.get_node("UI/SetupPanel/ModeLabel") as Label

    # Use the same native-pixel alignment on navigation and confirmation.
    var mode_font := mode_label.get_theme_font_size("font_size")
    var load_x := mode_label.position.x + JOHTO_FONT.get_string_size(
        "NEW        ", HORIZONTAL_ALIGNMENT_LEFT, -1, mode_font).x - 10.0
    mode_tick.visible = main.menu_row == MENU_ROW_MODE
    mode_tick.position.x = 0.0 if main.selected_mode == "NEW" else roundf(load_x)
    main._align_menu_tick(mode_tick, mode_label)

func update_menu_cursor() -> void:
    var cursor := main.get_node("UI/SetupPanel/MenuCursor") as Label
    var selecting_color := main.menu_row == main.MENU_ROW_COLOR and main.menu_col == 1
    var selecting_model := main.menu_row == main.MENU_ROW_COLOR and main.menu_col == 2
    main.get_node("UI/SetupPanel/ColorUp").visible = selecting_color
    main.get_node("UI/SetupPanel/ColorDown").visible = selecting_color
    main.get_node("UI/SetupPanel/ModelUp").visible = selecting_model
    main.get_node("UI/SetupPanel/ModelDown").visible = selecting_model
    # On the PLAYER row, the active arrow pair replaces the normal cursor.
    # This prevents an extra triangle appearing between the selectors.
    cursor.visible = main.menu_row not in [MENU_ROW_GO, MENU_ROW_MODE] and not (
        main.menu_row == main.MENU_ROW_COLOR and main.menu_col > 0
    )
    if main.setup_go_cursor != null:
        main.setup_go_cursor.visible = main.menu_row == MENU_ROW_GO
        var font_size := main.start_button.get_theme_font_size("font_size")
        var font_height := JOHTO_FONT.get_height(font_size)
        var text_width := JOHTO_FONT.get_string_size(main.start_button.text,
            HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
        var text_top := main.start_button.position.y + (main.start_button.size.y - font_height) / 2.0
        # Align the arrow with the visible GO! glyphs, not the font line box.
        main.setup_go_cursor.position = Vector2(
            roundf(main.start_button.position.x + (main.start_button.size.x - text_width) / 2.0 -
                main.setup_go_cursor.size.x - 2.0),
            roundf(text_top))

    var pos := Vector2(2, 2)

    match main.menu_row:
        main.MENU_ROW_LOCAL:
            # Leave the LOCAL text untouched; add one small source-pixel gap.
            pos = Vector2(roundf(main.online_label.position.x-10.0),3) if main.menu_col==1 and is_instance_valid(main.online_label) else Vector2(0,3)
        MENU_ROW_MODE:
            var mode_label := main.get_node("UI/SetupPanel/ModeLabel") as Label
            var mode_font := mode_label.get_theme_font_size("font_size")
            var load_x := mode_label.position.x + JOHTO_FONT.get_string_size(
                "NEW        ", HORIZONTAL_ALIGNMENT_LEFT, -1, mode_font).x - 10.0
            pos = Vector2(0, 28) if main.menu_col == 0 else Vector2(roundf(load_x), 26)
        MENU_ROW_SIZE:
            var size_label := main.get_node("UI/SetupPanel/WorldSizeLabel") as Label
            var size_font := size_label.get_theme_font_size("font_size")
            # _update_classic_menu_labels() supplies three-space separators at
            # runtime.  Measure those exact prefixes so M/XL/XXL never overlap
            # their selection triangle.
            var prefixes := [
                "WORLD   ",
                "WORLD   S   ",
                "WORLD   S   M   ",
                "WORLD   S   M   L   ",
                "WORLD   S   M   L   XL   "
            ]
            var option_x := size_label.position.x + JOHTO_FONT.get_string_size(
                prefixes[main.menu_col], HORIZONTAL_ALIGNMENT_LEFT, -1, size_font).x
            pos = Vector2(roundf(option_x - 10.0), 47)
        MENU_ROW_WORLD_NAME:
            pos = Vector2(2, 70)
        MENU_ROW_PLAYER_NAME:
            pos = Vector2(2, 95)
        main.MENU_ROW_COLOR:
            pos = Vector2(2.0 + (JOIN_ROW_SHIFT if join_layout else 0.0), 118)
        MENU_ROW_GO:
            pos = Vector2(2, 144)

    cursor.position = pos
    var labels := ["LocalLabel", "ModeLabel", "WorldSizeLabel", "WorldLabel", "NameLabel", "AppearanceLabel"]
    if main.menu_row >= 0 and main.menu_row < labels.size():
        main._align_menu_tick(cursor, main.online_label if main.menu_row==main.MENU_ROW_LOCAL and main.menu_col==1 and is_instance_valid(main.online_label) else main.setup_panel.get_node(labels[main.menu_row]))
    _update_persistent_selection_ticks()

func open_setup_load_selector() -> void:
    main.setup_load_entries = main.saves.entries()
    if main.setup_load_entries.is_empty():
        main.menu_status.text = "NO SAVE FILE"
        return
    main.setup_load_index = 0
    main.setup_load_open = true
    main.setup_panel.visible = false
    main.setup_load_panel.visible = true
    refresh_setup_load_selector()

func refresh_setup_load_selector() -> void:
    if main.setup_load_entries.is_empty():
        main.setup_load_name.text = "NO SAVE"
        return
    main.setup_load_index = wrapi(main.setup_load_index, 0, main.setup_load_entries.size())
    var data := main.setup_load_entries[main.setup_load_index].data as Dictionary
    var world_name := String(data.get("world_name", "default")).strip_edges()
    if world_name.is_empty():
        world_name = "default"
    main.setup_load_name.text = "%s.sav" % world_name
    main.setup_load_name.tooltip_text = main.setup_load_name.text
    # The autosave follows its world's save in the list (see WorldSaves.entries).
    var entry := main.setup_load_entries[main.setup_load_index]
    var saved := Time.get_datetime_string_from_unix_time(WorldSaves.saved_time(String(entry.path))).replace("T", "  ").left(17)
    (main.setup_load_name.get_parent().get_node("SaveInfo") as Label).text = \
        ("AUTOSAVE   " + saved) if entry.get("autosave", false) else saved

func handle_setup_load_input(event: InputEvent) -> void:
    if event.is_action_pressed("move_left") or event.is_action_pressed("move_up"):
        main.setup_load_index = wrapi(main.setup_load_index - 1, 0, main.setup_load_entries.size())
        refresh_setup_load_selector()
    elif event.is_action_pressed("move_right") or event.is_action_pressed("move_down"):
        main.setup_load_index = wrapi(main.setup_load_index + 1, 0, main.setup_load_entries.size())
        refresh_setup_load_selector()
    elif event.is_action_pressed("confirm") or event.is_action_pressed("start"):
        var entry := main.setup_load_entries[main.setup_load_index]
        var data := entry.data as Dictionary
        main.setup_load_path = String(entry.path)
        main.world_edit.text = String(data.get("world_name", main.world_edit.text))
        main.selected_world_size = clampi(int(data.get("world_size", main.selected_world_size)),
            0, main.WORLD_SIZE_NAMES.size() - 1)
        main.setup_load_open = false
        main.setup_load_panel.visible = false
        main.setup_load_committed = true
        main._start_game()
    elif event.is_action_pressed("cancel"):
        main.setup_load_open = false
        main.setup_load_panel.visible = false
        main.setup_panel.visible = true
    else:
        return
    main.get_viewport().set_input_as_handled()

func save_setup() -> void:
    var cfg := ConfigFile.new()
    cfg.set_value("setup", "player_name", main.player_model_name.text.strip_edges())
    cfg.set_value("setup", "player_name_custom", not custom_player_name.is_empty())
    cfg.set_value("setup", "world_name", main.world_edit.text.strip_edges())
    cfg.set_value("setup", "player_color", main.player_color_index)
    cfg.set_value("setup", "player_model", main.player_model_index)
    cfg.set_value("setup", "mode", main.selected_mode)
    cfg.set_value("setup", "world_size", main.selected_world_size)
    cfg.save(SETUP_SAVE_PATH)

func load_setup() -> void:
    var cfg := ConfigFile.new()
    if cfg.load(SETUP_SAVE_PATH) == OK:
        main.world_edit.text = str(cfg.get_value("setup", "world_name", "PokeWilds"))
        main.player_color_index = clampi(int(cfg.get_value("setup", "player_color", 0)), 0, main.PLAYER_TEXTURES.size() - 1)
        main.player_model_index = clampi(
            int(cfg.get_value("setup", "player_model", 0)),
            0,
            main.appearance.player_model_count() - 1
        )
        custom_player_name = str(cfg.get_value("setup","player_name","")).strip_edges().left(24) if bool(cfg.get_value("setup","player_name_custom",false)) else ""
        main.selected_mode = str(cfg.get_value("setup", "mode", "NEW"))
        main.selected_world_size = clampi(int(cfg.get_value("setup", "world_size", 1)), 0, main.WORLD_SIZE_NAMES.size() - 1)

    var newest := main.saves.find_newest()
    if not newest.is_empty():
        main.world_edit.text = String(newest.data.get("world_name", main.world_edit.text))

    update_classic_menu_labels()

func on_generation_progress(value: float, message: String) -> void:
    if main.edge_travel_busy:
        return # Travel presentation is independent of the NEW/LOAD setup choice.
    var _unused_progress := value
    var _unused_message := message
    main.generation_status.text = (
        "LOADING...\nPLEASE WAIT..."
        if main.selected_mode == "LOAD"
        else "Generating...\nPlease wait..."
    )

func display_field_gui_input(event: InputEvent, target: String) -> void:
    # On touch the touch setup screen's own name fields take the taps: this
    # classic field stays under it (only transparent), and tapping SOLO opened
    # the setup under the finger, whose touch then landed here (iPhone keyboard).
    if is_instance_valid(main.touch_ui) and main.touch_ui.enabled: return
    # Touching/clicking the field opens Android keyboard WITHOUT focusing LineEdit.
    if event is InputEventScreenTouch:
        var touch := event as InputEventScreenTouch
        if touch.pressed:
            begin_text_entry(target)
            main.get_viewport().set_input_as_handled()
    elif event is InputEventMouseButton:
        var mouse := event as InputEventMouseButton
        if mouse.pressed:
            begin_text_entry(target)
            main.get_viewport().set_input_as_handled()

func begin_text_entry(target: String) -> void:
    if target=="world" and not main.coop_game.join_setup_code.is_empty():return
    if target not in ["world", "player"]:
        return
    main.text_entry_target = target
    main.text_entry_buffer = main.world_edit.text if target == "world" else main.player_model_name.text
    main.menu_row = MENU_ROW_WORLD_NAME if target == "world" else MENU_ROW_PLAYER_NAME

    refresh_text_entry_display()
    _show_virtual_keyboard_custom()

func finish_text_entry(accept: bool) -> void:
    if main.text_entry_target == "":
        return

    if main.text_entry_target == "player":
        if accept:
            var entered := main.text_entry_buffer.strip_edges().left(24)
            custom_player_name = "" if entered.to_upper() == main.PLAYER_MODEL_NAMES[main.player_model_index].to_upper() else entered
        main.player_model_name.text = custom_player_name if not custom_player_name.is_empty() else main.PLAYER_MODEL_NAMES[main.player_model_index].to_upper()
        fit_player_name()
    elif accept:
        main.world_edit.text = main.text_entry_buffer

    main.text_entry_target = ""
    main.text_entry_buffer = ""
    hide_virtual_keyboard()
    main.menu_nav_cooldown = main.MENU_NAV_DELAY
    update_menu_cursor()

func fit_player_name() -> void:
    if join_layout:
        main.player_model_name.scale.x = 1.0
        return
    var width := main.player_model_name.get_theme_font("font").get_string_size(main.player_model_name.text,HORIZONTAL_ALIGNMENT_LEFT,-1,main.player_model_name.get_theme_font_size("font_size")).x
    main.player_model_name.scale.x = minf(1.0,210.0/maxf(1.0,width))

func refresh_text_entry_display() -> void:
    if main.text_entry_target == "world":
        main.world_edit.text = main.text_entry_buffer
    elif main.text_entry_target == "player":
        main.player_model_name.text = main.text_entry_buffer
        fit_player_name()

## COPY / PASTE while typing a name (the touch setup screen's buttons): the
## names are not system text fields, so iOS offers no paste of its own.
func paste_text_entry() -> void:
    if main.text_entry_target == "": return
    var clip := DisplayServer.clipboard_get().replace("\n", " ").strip_edges()
    main.text_entry_buffer = (main.text_entry_buffer + clip).left(24)
    refresh_text_entry_display()
    _show_virtual_keyboard_custom()  # the phone keyboard keeps its own copy of the text

func copy_text_entry() -> void:
    if main.text_entry_target != "": DisplayServer.clipboard_set(main.text_entry_buffer)

func _show_virtual_keyboard_custom() -> void:
    if not OS.has_feature("mobile"):
        return

    DisplayServer.virtual_keyboard_show(
        main.text_entry_buffer,
        Rect2i(),
        DisplayServer.KEYBOARD_TYPE_DEFAULT,
        24,
        main.text_entry_buffer.length(),
        main.text_entry_buffer.length()
    )

func hide_virtual_keyboard() -> void:
    if OS.has_feature("mobile"):
        DisplayServer.virtual_keyboard_hide()

func setup_generation_clouds() -> void:
    var background := main.get_node("UI/GenerationPanel/Background") as TextureRect
    background.texture = preload("res://assets/environment/cloud5.png")
    background.stretch_mode = TextureRect.STRETCH_SCALE
    var shader := Shader.new()
    shader.code = """
shader_type canvas_item;
render_mode unshaded;
void fragment() {
    // Game.render: four one-pixel steps per 65 source ticks.
    // Rotate the loading artwork 180 degrees and scroll right-to-left.
    float tick = floor(TIME * 60.0);
    float offset = floor(tick / 65.0) * 4.0 + floor(mod(tick, 65.0) / 16.0);
    vec2 pixel = floor(UV * vec2(320.0, 180.0));
    COLOR = texture(TEXTURE, (vec2(191.0) - mod(pixel + vec2(offset, 0.0), vec2(192.0)) + 0.5) / 192.0);
}
"""
    var material_value := ShaderMaterial.new()
    material_value.shader = shader
    background.material = material_value

func prepare_swipe_cursor() -> void:
    if is_instance_valid(swipe_cursor): return
    var contents := main.touch_config.find_child("VBox",true,false)
    for child in contents.get_children():
        if child is BaseButton or child is Slider:
            swipe_rows.append(child)
            var index := swipe_rows.size()-1
            child.mouse_entered.connect(func(): _select_swipe_row(index))
    swipe_cursor = TextureRect.new()
    swipe_cursor.texture = main.source_command_cursor.texture
    swipe_cursor.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
    swipe_cursor.size = Vector2(5,7)
    swipe_cursor.mouse_filter = Control.MOUSE_FILTER_IGNORE
    swipe_cursor.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
    main.touch_config.add_child(swipe_cursor)
    main.touch_config_panel.touch_config_scroll.get_v_scroll_bar().value_changed.connect(func(_value): position_swipe_cursor())
    _select_swipe_row(0)

func _select_swipe_row(index: int) -> void:
    swipe_selection = wrapi(index,0,swipe_rows.size())
    main.touch_config_panel.touch_config_scroll.ensure_control_visible(swipe_rows[swipe_selection])
    position_swipe_cursor.call_deferred()

func position_swipe_cursor() -> void:
    if not is_instance_valid(swipe_cursor): return
    var row := swipe_rows[swipe_selection]
    if row == main.touch_opacity_slider:row=main.touch_opacity_label
    elif row == main.touch_size_slider:row=main.touch_size_label
    swipe_cursor.global_position.x = roundf(row.global_position.x+2)
    main._align_control_tick(swipe_cursor,row)
    swipe_cursor.visible = main.touch_config_panel.touch_config_scroll.get_global_rect().encloses(swipe_cursor.get_global_rect())

func handle_swipe_menu(event: InputEvent) -> void:
    if event.is_echo(): return
    if event.is_action_pressed("cancel") or event.is_action_pressed("start"):
        main.touch_config_panel.close_touch_config();return
    var direction := 0
    var change := 0
    if event.is_action_pressed("move_down"): direction=1
    elif event.is_action_pressed("move_up"): direction=-1
    elif event.is_action_pressed("move_right"): change=1
    elif event.is_action_pressed("move_left"): change=-1
    if direction!=0: _select_swipe_row(swipe_selection+direction);return
    var row := swipe_rows[swipe_selection]
    if row is Slider:
        if change!=0: row.value += change*5
    elif event.is_action_pressed("confirm") or change!=0:
        if row is CheckButton:row.button_pressed=not row.button_pressed
        elif event.is_action_pressed("confirm"):row.pressed.emit()

## The setup screen's keys and buttons before a game starts: a name being
## typed (a direction or confirm ends it), the rows and the PLAYER
## selectors, BACK to the SOLO / CO-OP choice, START.
func handle_setup_menu_input(event: InputEvent) -> void:
    # Text-entry mode never owns controller focus. If the user navigates away,
    # accept the current text, close the Android keyboard, and continue moving
    # through the menu in the same input press.
    if main.text_entry_target != "":
        if event.is_action_pressed("move_up"):
            finish_text_entry(true)
            move_menu_vertical(-1)
            main.menu_nav_cooldown = main.MENU_NAV_DELAY
            main.get_viewport().set_input_as_handled()
            return

        if event.is_action_pressed("move_down"):
            finish_text_entry(true)
            move_menu_vertical(1)
            main.menu_nav_cooldown = main.MENU_NAV_DELAY
            main.get_viewport().set_input_as_handled()
            return

        if event.is_action_pressed("move_left"):
            finish_text_entry(true)
            menu_left_right(-1)
            main.menu_nav_cooldown = main.MENU_NAV_DELAY
            main.get_viewport().set_input_as_handled()
            return

        if event.is_action_pressed("move_right"):
            finish_text_entry(true)
            menu_left_right(1)
            main.menu_nav_cooldown = main.MENU_NAV_DELAY
            main.get_viewport().set_input_as_handled()
            return

        if event.is_action_pressed("confirm") or event.is_action_pressed("start"):
            finish_text_entry(true)
            main.get_viewport().set_input_as_handled()
            return

        if event.is_action_pressed("cancel"):
            finish_text_entry(true)
            main.get_viewport().set_input_as_handled()
            return

        # Characters from the Android soft keyboard arrive as key events.
        if event is InputEventKey:
            var key = event as InputEventKey
            if key.pressed and not key.echo:
                if key.keycode == KEY_BACKSPACE:
                    if main.text_entry_buffer.length() > 0:
                        main.text_entry_buffer = main.text_entry_buffer.left(main.text_entry_buffer.length() - 1)
                        refresh_text_entry_display()
                    main.get_viewport().set_input_as_handled()
                    return

                if key.unicode >= 32 and key.unicode != 127:
                    if main.text_entry_buffer.length() < 24:
                        main.text_entry_buffer += String.chr(key.unicode)
                        refresh_text_entry_display()
                    main.get_viewport().set_input_as_handled()
                    return

        return

    # Restore D-pad / left-stick menu navigation using the EXISTING actions.
    if event.is_action_pressed("move_up"):
        if main.menu_nav_cooldown <= 0.0:
            if main.menu_row == main.MENU_ROW_COLOR and main.menu_col > 0:
                main.appearance.change_player_selector(1)
            else:
                move_menu_vertical(-1)
            main.menu_nav_cooldown = main.MENU_NAV_DELAY
        main.get_viewport().set_input_as_handled()
        return

    if event.is_action_pressed("move_down"):
        if main.menu_nav_cooldown <= 0.0:
            if main.menu_row == main.MENU_ROW_COLOR and main.menu_col > 0:
                main.appearance.change_player_selector(-1)
            else:
                move_menu_vertical(1)
            main.menu_nav_cooldown = main.MENU_NAV_DELAY
        main.get_viewport().set_input_as_handled()
        return

    if event.is_action_pressed("move_left"):
        if main.menu_nav_cooldown <= 0.0:
            menu_left_right(-1)
            main.menu_nav_cooldown = main.MENU_NAV_DELAY
        main.get_viewport().set_input_as_handled()
        return

    if event.is_action_pressed("move_right"):
        if main.menu_nav_cooldown <= 0.0:
            menu_left_right(1)
            main.menu_nav_cooldown = main.MENU_NAV_DELAY
        main.get_viewport().set_input_as_handled()
        return

    if event.is_action_pressed("confirm"):
        activate_menu_item()
        main.get_viewport().set_input_as_handled()
        return

    if event.is_action_pressed("cancel"):
        # Leaving either PLAYER selector returns focus to the PLAYER row so
        # vertical navigation works again.  It must never trap the user in
        # color/model selection.
        if main.menu_row == main.MENU_ROW_COLOR and main.menu_col > 0:
            main.menu_col = 0
            update_menu_cursor()
            main.get_viewport().set_input_as_handled()
        elif not main.started and not main.generating:
            # Back to the SOLO / CO-OP choice.
            main.coop_game.cancel_join();main.coop_menu.open()
            main.get_viewport().set_input_as_handled()
        return

    if event.is_action_pressed("start"):
        main._start_game()
        main.get_viewport().set_input_as_handled()
