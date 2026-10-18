extends Control
## Touch version of the NEW / LOAD setup screen. It sits over the classic
## setup panel (kept for controllers) and drives the same state and functions.

const WHITE_FONT := preload("res://assets/source_text_font_white.fnt")
const JOHTO_FONT := preload("res://assets/source_text_font.fnt")
const SIZE_NAMES := ["S", "M", "L", "XL", "XXL"]
const SAVE_ROW_HEIGHT := 32.0

var main: Node
var ui: Node
var back_button: Control
var new_tab: Control
var load_tab: Control
var title: Label
var world_card: Panel
var trainer_card: Panel
var world_field: Control
var player_field: Control
var size_chips: Array[Control] = []
var color_prev: Control
var color_next: Control
var model_prev: Control
var model_next: Control
var swatch: TextureRect
var preview: TextureRect
var start_button: Control
var status: Label
var load_list: Control
var load_rows: Array[Panel] = []
var load_empty: Label
var saves: Array[Dictionary] = []
var load_scroll := 0
var showing_load := false

func configure(owner_main: Node, owner_ui: Node) -> void:
    main = owner_main
    ui = owner_ui
    name = "TouchSetupScreen"
    size = Vector2(320, 180)
    z_index = 20
    mouse_filter = Control.MOUSE_FILTER_IGNORE
    var backdrop := ColorRect.new()
    backdrop.size = Vector2(320, 180)
    backdrop.color = Color.WHITE
    backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
    add_child(backdrop)
    back_button = ui.make_button(self, "BACK", Vector2(48, 20), 9)
    back_button.position = Vector2(6, 5)
    new_tab = ui.make_button(self, "NEW GAME", Vector2(76, 20), 9)
    new_tab.position = Vector2(84, 5)
    load_tab = ui.make_button(self, "LOAD GAME", Vector2(76, 20), 9)
    load_tab.position = Vector2(162, 5)
    title = main._source_ui_label(self, "Title", Vector2(84, 9), Vector2(154, 14), 10, "JOIN GAME")
    title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER

    world_card = _card(Vector2(6, 30), Vector2(150, 112), "WORLD")
    world_field = _field(world_card, Vector2(8, 20), Vector2(134, 22))
    main._source_ui_label(world_card, "SizeHeader", Vector2(10, 50), Vector2(80, 10), 7, "SIZE")
    for i in SIZE_NAMES.size():
        var chip: Control = ui.make_button(world_card, SIZE_NAMES[i], Vector2(26, 22), 8)
        chip.position = Vector2(8 + i * 27, 62)
        size_chips.append(chip)

    trainer_card = _card(Vector2(164, 30), Vector2(150, 112), "TRAINER")
    preview = main._source_texture_rect(trainer_card, "Preview", Vector2(6, 22), Vector2(48, 48))
    preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
    player_field = _field(trainer_card, Vector2(58, 20), Vector2(84, 22))
    color_prev = _arrow(trainer_card, true, Vector2(58, 48))
    swatch = main._source_texture_rect(trainer_card, "Swatch", Vector2(84, 50), Vector2(30, 18))
    swatch.stretch_mode = TextureRect.STRETCH_SCALE
    color_next = _arrow(trainer_card, false, Vector2(118, 48))
    model_prev = _arrow(trainer_card, true, Vector2(58, 74))
    main._source_ui_label(trainer_card, "Style", Vector2(82, 80), Vector2(34, 10), 7, "STYLE").horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    model_next = _arrow(trainer_card, false, Vector2(118, 74))
    main._source_ui_label(trainer_card, "ColorHint", Vector2(6, 76), Vector2(48, 10), 7, "TAP NAMES").horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    main._source_ui_label(trainer_card, "ColorHint2", Vector2(6, 86), Vector2(48, 10), 7, "TO EDIT").horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER

    start_button = ui.make_button(self, "START!", Vector2(104, 28), 11)
    start_button.position = Vector2(210, 147)
    status = main._source_ui_label(self, "Status", Vector2(8, 155), Vector2(196, 14), 8, "")

    load_list = Control.new()
    load_list.position = Vector2(6, 30)
    load_list.size = Vector2(308, 144)
    load_list.clip_contents = true
    load_list.mouse_filter = Control.MOUSE_FILTER_IGNORE
    add_child(load_list)
    for i in 5:
        var row := Panel.new()
        row.size = Vector2(308, SAVE_ROW_HEIGHT - 3)
        row.position = Vector2(0, i * SAVE_ROW_HEIGHT)
        row.mouse_filter = Control.MOUSE_FILTER_IGNORE
        row.add_theme_stylebox_override("panel", main._classic_dialogue_style())
        load_list.add_child(row)
        main._source_ui_label(row, "Name", Vector2(12, 4), Vector2(200, 12), 10, "")
        main._source_ui_label(row, "Info", Vector2(12, 17), Vector2(284, 9), 7, "")
        load_rows.append(row)
    load_empty = main._source_ui_label(load_list, "Empty", Vector2(0, 50), Vector2(308, 14), 10, "NO SAVED WORLDS YET")
    load_empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    hide()
    main.get_node("UI").add_child(self)

func _card(at: Vector2, dimensions: Vector2, heading: String) -> Panel:
    var card := Panel.new()
    card.position = at
    card.size = dimensions
    card.mouse_filter = Control.MOUSE_FILTER_IGNORE
    card.add_theme_stylebox_override("panel", main._classic_dialogue_style())
    add_child(card)
    main._source_ui_label(card, "Heading", Vector2(10, 6), Vector2(130, 12), 8, heading)
    return card

func _field(parent: Control, at: Vector2, dimensions: Vector2) -> Control:
    var field: Control = ui.make_button(parent, "", dimensions, 10)
    field.position = at
    (field.get_node("Text") as Label).set_meta("align_left", true)
    return field

func _arrow(parent: Control, pointing_left: bool, at: Vector2) -> Control:
    var arrow: Control = ui.make_arrow(parent, pointing_left, Vector2(24, 22))
    arrow.position = at
    return arrow

static func _set_selected(button: Control, selected: bool) -> void:
    preload("res://scripts/touch_ui.gd").set_selected(button, selected)

func _set_field(control: Control, text: String) -> void:
    if (control.get_node("Text") as Label).text != text: ui.set_text(control, text)

func _joining() -> bool:
    return not String(main.coop_game.join_setup_code).is_empty()

## Shown while the classic setup panel would be (title screen and load list excluded).
func refresh() -> void:
    var m := main
    var active: bool = m.setup_panel.visible and not m.coop_menu.visible and not m.started \
        and not m.generating and not m.setup_load_open
    visible = active
    m.setup_panel.modulate.a = 0.0
    if not active: return
    showing_load = m.selected_mode == "LOAD" and not _joining()
    var joining := _joining()
    new_tab.visible = not joining
    load_tab.visible = not joining
    title.visible = joining
    _set_selected(new_tab, not showing_load)
    _set_selected(load_tab, showing_load)
    world_card.visible = not showing_load and not joining
    trainer_card.visible = not showing_load
    trainer_card.position.x = 85 if joining else 164
    load_list.visible = showing_load and not m.coop_game.new_setup_pending
    for i in size_chips.size(): _set_selected(size_chips[i], i == m.selected_world_size)
    var typing: String = m.text_entry_target
    _set_field(world_field, (m.text_entry_buffer + "_") if typing == "world" else String(m.world_edit.text))
    _set_field(player_field, (m.text_entry_buffer + "_") if typing == "player" else String(m.player_model_name.text))
    swatch.texture = m.player_color_swatch.texture
    var sprite: Sprite2D = m.player_preview
    if sprite.texture != null:
        var frame := AtlasTexture.new()
        var frame_width: float = sprite.texture.get_width() / float(maxi(1, sprite.hframes))
        frame.atlas = sprite.texture
        frame.region = Rect2(frame_width * sprite.frame, 0, frame_width, sprite.texture.get_height())
        if not (preview.texture is AtlasTexture) or preview.texture.atlas != frame.atlas or preview.texture.region != frame.region:
            preview.texture = frame
    _set_field(start_button, "JOIN!" if joining else ("CHOOSE SAVE" if showing_load and m.coop_game.new_setup_pending else "START!"))
    start_button.visible = not showing_load or m.coop_game.new_setup_pending
    status.text = String(m.menu_status.text) if String(m.menu_status.text) not in ["SINGLE PLAYER", ""] else ""
    if load_list.visible: _refresh_saves()

func _refresh_saves() -> void:
    load_empty.visible = saves.is_empty()
    load_scroll = clampi(load_scroll, 0, maxi(0, saves.size() - 4))
    for i in load_rows.size():
        var row := load_rows[i]
        var index := load_scroll + i
        row.visible = index < saves.size()
        if not row.visible: continue
        var data: Dictionary = saves[index].data
        var world_name := String(data.get("world_name", "default")).strip_edges()
        (row.get_node("Name") as Label).text = world_name if not world_name.is_empty() else "default"
        var party: Array = data.get("caught_pokemon", [])
        var saved := Time.get_datetime_string_from_unix_time(FileAccess.get_modified_time(String(saves[index].path))).replace("T", "  ")
        (row.get_node("Info") as Label).text = "%s   %s   SIZE %s   %d POKEMON" % [
            String(data.get("player_name", "")).to_upper(), saved.left(17),
            SIZE_NAMES[clampi(int(data.get("world_size", 0)), 0, 4)], party.size()]

func _set_mode(mode: String) -> void:
    if main.text_entry_target != "": main._finish_text_entry(true)
    main.selected_mode = mode
    if mode == "LOAD":
        saves = main._available_save_entries()
        load_scroll = 0
    main._update_classic_menu_labels()
    main._update_menu_cursor()

func _load_save(index: int) -> void:
    var m := main
    if index >= saves.size(): return
    var data: Dictionary = saves[index].data
    m.setup_load_path = String(saves[index].path)
    m.world_edit.text = String(data.get("world_name", m.world_edit.text))
    m.selected_world_size = clampi(int(data.get("world_size", m.selected_world_size)), 0, m.WORLD_SIZE_NAMES.size() - 1)
    m.setup_load_committed = true
    m._start_game()

func _edit(target: String) -> void:
    if main.text_entry_target == target:
        main._finish_text_entry(true)
    else:
        if main.text_entry_target != "": main._finish_text_entry(true)
        main._begin_text_entry(target)

func surface() -> Dictionary:
    if not visible: return {}
    var m := main
    var buttons := []
    var add := func(control: Control, action: Callable):
        if control.is_visible_in_tree(): buttons.append(["", action, control.get_global_rect()])
    add.call(back_button, func(): m.coop_game.cancel_join(); m.coop_menu.open())
    add.call(new_tab, func(): _set_mode("NEW"))
    add.call(load_tab, func(): _set_mode("LOAD"))
    add.call(world_field, func(): _edit("world"))
    add.call(player_field, func(): _edit("player"))
    for i in size_chips.size():
        add.call(size_chips[i], func(): m.selected_world_size = i; m._update_classic_menu_labels())
    add.call(color_prev, func(): m._previous_color())
    add.call(color_next, func(): m._next_color())
    add.call(model_prev, func(): m._previous_model())
    add.call(model_next, func(): m._next_model())
    add.call(start_button, func():
        if m.text_entry_target != "": m._finish_text_entry(true)
        m._start_game())
    var rows := []
    if load_list.visible:
        for row in load_rows:
            if row.visible: rows.append(row.get_global_rect())
    return {
        "hotspots": buttons,
        "rows": rows,
        "tap": func(i): _load_save(load_scroll + i),
        "scroll": func(d): load_scroll += d; _refresh_saves(),
        "row_height": SAVE_ROW_HEIGHT,
        "tap_at": func(_p): if m.text_entry_target != "": m._finish_text_entry(true),
    }
