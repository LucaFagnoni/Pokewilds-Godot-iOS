extends RefCounted
## What can be touched on the screen in front of the player (see touch_ui.gd).
## Every action goes through the game's own functions or menu actions, so touch
## and controller always share one code path.

const JOHTO_FONT := preload("res://assets/source_text_font.fnt")
const GameOptions = preload("res://scripts/game_options.gd")
const CraftingData = preload("res://scripts/crafting_data.gd")
const START_LABELS := ["POKEDEX", "POKEMON", "ITEM", "STORAGE", "MAP", "GUIDE", "OPTIONS", "SAVE", "EXIT"]

var main: Node
var ui: Node
var map_from_minimap := false
var start_menu: Control
var start_tiles: Array[Panel] = []
var start_subtitles: Array[Label] = []
var start_icons: Array[TextureRect] = []
var party_slots: Array[Control] = []
const Icons = preload("res://scripts/touch_icons.gd")
var setup_screen: Control
var backdrop: ColorRect
var field_hud: RefCounted
var move_cards: Control
var move_card_signature := []
var card_styles := {}
var shown_pocket := -1
var map_hint: Label
var build_hint: Control
var bag_tabs: Control
var bag_tab_buttons: Array[Control] = []
const POCKET_NAMES := ["ITEMS", "BALLS", "MATERIALS", "KEY ITEMS", "MEDICINE"]
var move_card_nodes: Array[Panel] = []

func _init(owner_main: Node, owner_ui: Node) -> void:
    main = owner_main
    ui = owner_ui
    field_hud = preload("res://scripts/touch_field_hud.gd").new(owner_main, owner_ui)

func press(action: String) -> void:
    ui.press(action)

static func grown(control: Control, by: Vector2 = Vector2(8, 6)) -> Rect2:
    return control.get_global_rect().grow_individual(by.x, by.y, by.x, by.y)

# --- screens ------------------------------------------------------------------

func build() -> Dictionary:
    var m := main
    # Loading (also before the first world starts): nothing to press, so the pad steps aside.
    if m.generating: return {"tap_at": func(_p): pass}
    if not m.started:
        return setup_screen.surface() if is_instance_valid(setup_screen) else {}
    if not m.game_menu_open: map_from_minimap = false
    if m.touch_controls.edit_mode:
        var bounds: Rect2 = m.touch_controls.usable_rect
        return {"modal": false, "hide_pad": false, "buttons": [["DONE", func(): _finish_layout_edit(),
            Rect2(Vector2(bounds.get_center().x - 30, bounds.position.y + 4), Vector2(60, 20))]]}
    if m.touch_config.visible:
        # The touch settings panel has real sliders and buttons.
        return {"modal": false, "hide_pad": true}
    if is_instance_valid(m.waypoint_ui) and m.waypoint_ui.naming: return _waypoint_naming()
    if m.progression_active: return _progression()
    if m.quit_prompt_open: return _yes_no(m.quit_prompt, func(i): m.quit_prompt_index = i; m._update_quit_prompt_cursor())
    if is_instance_valid(m.pokedex_menu) and m.pokedex_menu.visible: return _pokedex()
    if is_instance_valid(m.options_menu) and m.options_menu.visible: return _options()
    if m.pokemon_stats_open: return _stats()
    if is_instance_valid(m.safari_ui) and m.safari_ui.is_visible_in_tree(): return _safari()
    if m.battle_active or m.battle_entry_pending: return _battle()
    if m.storage_menu_open: return _storage()
    if is_instance_valid(m.bag_action_ui): return _bag_actions()
    if m.game_menu_open: return _game_menu()
    if m.craft_menu_open: return _crafting()
    if m.build_menu_open: return _build_menu()
    var prompt := _field_prompt()
    if not prompt.is_empty(): return prompt
    return _field()

func _field_active() -> bool:
    var m := main
    return m.started and not m.generating and not m.game_menu_open and not m.battle_active         and not m._field_ui_blocks_gameplay() and not m.field_move_wheel_open and not m._sleeping_bag_active()

func _field() -> Dictionary:
    var m := main
    if not _field_active(): return {}
    var minimap: Control = m.m3924_minimap_root
    var rows := []
    if is_instance_valid(minimap) and minimap.is_visible_in_tree(): rows.append(minimap.get_global_rect())
    var buttons: Array = field_hud.buttons()
    # A tap on the clock switches real time and game time.
    var hotspots := []
    var clock: Control = m.status_hud.clock_chip
    if is_instance_valid(clock) and clock.is_visible_in_tree(): hotspots.append(["CLOCK", func(): m.status_hud.switch_clock(), grown(clock, Vector2(3, 6))])
    if rows.is_empty() and buttons.is_empty() and hotspots.is_empty(): return {}
    return {
        "modal": false,
        "rows": rows,
        "tap": func(_i): _open_map_from_minimap(),
        "buttons": buttons,
        "hotspots": hotspots,
        "hud": true,
    }

func _finish_layout_edit() -> void:
    var m := main
    m.touch_controls.end_edit()
    m._open_game_menu()
    m.options_menu.open()
    for i in m.options_menu.CATEGORIES.size():
        if m.options_menu.CATEGORIES[i][0] == "CONTROLS": m.options_menu.open_category(i)

func _open_map_from_minimap() -> void:
    map_from_minimap = true
    main._open_game_menu()
    main._show_map_menu()

func _game_menu() -> Dictionary:
    var m := main
    if m.game_menu_map_screen.visible: return _map()
    if m.overworld_evolution_item != "": return _party_rows(func(i): m.pokemon_menu_index = i; m._refresh_evolution_item_target(); press("confirm"))
    if m.item_pocket_menu.visible and m.item_pocket_context == "OVERWORLD": return _items(func(): press("cancel"))
    if m.pokemon_action_open: return _pokemon_actions()
    if m.pokemon_menu_open:
        var party := _party_rows(func(i): m.pokemon_menu_index = i; m._refresh_pokemon_category_menu(); press("confirm"))
        party["long_press"] = func(i): _pick_party(i)
        party["drop"] = func(i, p): _drop_party(i, p, party.rows)
        return party
    if m.save_confirm_open: return _yes_no(m.save_confirm, func(i): m.save_confirm_index = i; m._update_save_confirm_cursor())
    if m.guide_topic_open: return {"back": func(): press("cancel"), "tap_at": func(_p): press("cancel")}
    if m.guide_menu_open: return _guide()
    if m.game_menu_box.visible and not m.game_menu_detail_open: return _start_menu()
    # Anything else inside the menu: never leave the player without a way out.
    return {"back": func(): m._close_game_menu(), "tap_at": func(_p): press("confirm")}

func _yes_no(panel: Control, select: Callable) -> Dictionary:
    return {
        "rows": [grown(panel.get_node("Yes"), Vector2(18, 10)), grown(panel.get_node("No"), Vector2(18, 10))],
        "tap": func(i): select.call(i); press("confirm"),
        "back": func(): press("cancel"),
    }

func _start_menu() -> Dictionary:
    var rows := []
    for tile in start_tiles: rows.append(tile.get_global_rect())
    return {
        "rows": rows,
        "tap": func(i): main.game_menu_index = i; main._activate_game_menu_option(),
        "back": func(): main._close_game_menu(),
    }

func _party_rows(on_tap: Callable) -> Dictionary:
    var m := main
    var rows := []
    for i in mini(6, m.caught_pokemon.size()):
        rows.append(m.pokemon_party_rows[i].root.get_global_rect())
    return {"rows": rows, "tap": on_tap, "back": func(): press("cancel")}

func _pokemon_actions() -> Dictionary:
    var m := main
    var count: int = m.pokemon_action_list.get_line_count()
    var first: int = maxi(0, m.pokemon_action_index - 5)
    return {
        "rows": ui.label_lines(m.pokemon_action_list, count),
        "tap": func(i): m.pokemon_action_index = first + i; press("confirm"),
        "scroll": func(d): press("move_down" if d > 0 else "move_up"),
        "back": func(): press("cancel"),
    }

func _stats() -> Dictionary:
    var middle: float = main.touch_controls.usable_rect.get_center().x
    return {
        "tap_at": func(p: Vector2): press("move_left" if p.x < middle else "move_right"),
        "swipe": func(d): press("move_right" if d > 0 else "move_left"),
        "back": func(): press("cancel"),
    }

func _items(back: Callable) -> Dictionary:
    var m := main
    var count: int = m.battle_item_menu_names.size() + 1
    var page_start: int = int(m.battle_item_menu_index / m.ITEM_MENU_VISIBLE_ROWS) * m.ITEM_MENU_VISIBLE_ROWS
    var visible_rows: int = mini(m.ITEM_MENU_VISIBLE_ROWS, count - page_start)
    var pocket_frame := Rect2(m.item_pocket_label.get_global_rect().position - Vector2(20, 12), Vector2(82, 123))
    var tabs := []
    for i in bag_tab_buttons.size():
        tabs.append(["", func(): m._switch_battle_item_pocket(i - int(m.battle_item_pocket_index)), bag_tab_buttons[i].get_global_rect()])
    return {
        "hotspots": tabs,
        "rows": ui.label_lines(m.item_pocket_list, visible_rows, 200),
        "tap": func(i): m.battle_item_menu_index = page_start + i; m._refresh_battle_item_pocket_menu(); press("confirm"),
        # Long press reads the description without using the item.
        "long_press": func(i): m.battle_item_menu_index = page_start + i; m._refresh_battle_item_pocket_menu(),
        "scroll": func(d): press("move_down" if d > 0 else "move_up"),
        "swipe": func(d): press("move_right" if d > 0 else "move_left"),
        "tap_at": func(p: Vector2): if pocket_frame.has_point(p): press("move_right"),
        "back": back,
    }

func _bag_actions() -> Dictionary:
    var bag: Control = main.bag_action_ui
    var back := func(): press("cancel")
    if bag.choosing_amount:
        var footer := Rect2(bag.panel.get_global_rect().position + Vector2(-60, 82), Vector2(176, 22))
        return {
            "buttons": [
                ["-10", func(): press("move_left"), Rect2(footer.position, Vector2(32, 20))],
                ["-1", func(): press("move_down"), Rect2(footer.position + Vector2(36, 0), Vector2(28, 20))],
                ["+1", func(): press("move_up"), Rect2(footer.position + Vector2(68, 0), Vector2(28, 20))],
                ["+10", func(): press("move_right"), Rect2(footer.position + Vector2(100, 0), Vector2(32, 20))],
                ["DROP", func(): press("confirm"), Rect2(footer.position + Vector2(136, 0), Vector2(44, 20))],
            ],
            "back": back,
        }
    var rows := []
    for row in bag.rows: rows.append(grown(row, Vector2(14, 1)))
    return {"rows": rows, "tap": func(i): bag.choice = i; bag.refresh(); press("confirm"), "back": back}

func _guide() -> Dictionary:
    var m := main
    var window_start: int = mini(maxi(0, m.guide_menu_index - 3), maxi(0, m.GUIDE_TOPICS.size() - m.guide_menu_rows.size()))
    var rows := []
    for row in m.guide_menu_rows: rows.append(grown(row, Vector2(30, 3)))
    return {
        "rows": rows,
        "tap": func(i): m.guide_menu_index = window_start + i; press("confirm"),
        "scroll": func(d): press("move_down" if d > 0 else "move_up"),
        "row_height": 24.0,
        "back": func(): press("cancel"),
    }

func _pokedex() -> Dictionary:
    var dex: Control = main.pokedex_menu
    if dex.touch_grid: return _pokedex_grid(dex)
    var first: int = int(dex.selection / dex.PAGE_SIZE) * dex.PAGE_SIZE
    var rows := []
    for row in dex.rows: rows.append(row.get_global_rect())
    return {
        "rows": rows,
        "tap": func(i):
            var index: int = first + i
            if index >= dex.roster.size(): return
            if index == dex.selection: dex.play_cry()
            else: dex.selection = index; dex.refresh(),
        "scroll": func(d): press("move_down" if d > 0 else "move_up"),
        "swipe": func(d): press("move_right" if d > 0 else "move_left"),
        "back": func(): dex.close(),
    }

func _options() -> Dictionary:
    var menu: Control = main.options_menu
    if is_instance_valid(menu.internet_setup) and menu.internet_setup.visible:
        return {"modal": false, "hide_pad": true}
    var back := func(): press("cancel")
    if menu.players_page or (is_instance_valid(menu.kick_prompt) and menu.kick_prompt.visible) \
            or (is_instance_valid(menu.action_prompt) and menu.action_prompt.visible) \
            or (is_instance_valid(menu.password_view) and menu.password_view.visible):
        # Online host pages: step through with drags, tap to choose.
        return {"scroll": func(d): press("move_down" if d > 0 else "move_up"), "tap_at": func(_p): press("confirm"), "back": back}
    var rows := []
    for row in menu.row_nodes: rows.append(Rect2(row.global_position - Vector2(10, 2), Vector2(298, 16)))
    return {
        "rows": rows,
        "tap": func(i, p: Vector2): menu.touch_tap(i, p),
        "scroll": func(d): press("move_down" if d > 0 else "move_up"),
        "back": back,
    }

func _storage() -> Dictionary:
    var m := main
    var back := func(): press("cancel")
    match String(m.storage_mode):
        "NICKNAME":
            return {"modal": false, "hide_pad": true, "back": back}
        "NOTICE":
            return {"tap_at": func(_p): press("confirm"), "back": back}
        "CONFIRM":
            return {
                "rows": [grown(m.storage_choice_label, Vector2(18, 6)), grown(m.storage_no_label, Vector2(18, 6))],
                "tap": func(i): m.storage_yes = i == 0; press("confirm"),
                "back": back,
            }
        "ACTION":
            var rows := []
            for label in m.storage_action_labels:
                if label.visible: rows.append(grown(label, Vector2(14, 1)))
            return {"rows": rows, "tap": func(i): m.storage_action_index = i; press("confirm"), "back": back}
    var entries: Array = m._storage_entries()
    var rows := []
    for i in mini(6, entries.size() - m.storage_box_window_start):
        rows.append(m.storage_rows[i].root.get_global_rect())
    var window_start: int = m.storage_box_window_start
    var toggle_label := "TO BOX" if m.storage_column == 0 else "TO PARTY"
    var bounds: Rect2 = m.touch_controls.usable_rect
    return {
        "rows": rows,
        "tap": func(i): m.storage_index = window_start + i; m._refresh_storage_menu(); press("confirm"),
        "long_press": func(i): _pick_storage(window_start + i),
        "drop": func(i, p): _drop_storage(window_start, i, p, rows),
        "scroll": func(d): press("move_down" if d > 0 else "move_up"),
        "row_height": 19.0,
        "swipe": func(d): press("move_right" if d > 0 else "move_left"),
        "buttons": [[toggle_label, func(): press("move_right" if m.storage_column == 0 else "move_left"),
            Rect2(Vector2(bounds.end.x - 76, bounds.end.y - 30), Vector2(70, 24))]],
        "back": back,
    }

func _map() -> Dictionary:
    var m := main
    var bounds: Rect2 = m.touch_controls.usable_rect
    var close := func():
        if map_from_minimap or m.teleport_map_mode: m._close_game_menu()
        else: press("cancel")
    if m.teleport_map_mode:
        var y: float = bounds.end.y - 28
        var x: float = bounds.get_center().x
        return {
            "buttons": [
                ["PREV", func(): press("move_left"), Rect2(Vector2(x - 92, y), Vector2(56, 24))],
                ["GO", func(): press("confirm"), Rect2(Vector2(x - 28, y), Vector2(56, 24))],
                ["NEXT", func(): press("move_right"), Rect2(Vector2(x + 36, y), Vector2(56, 24))],
            ],
            "back": close,
        }
    var surface := {
        "drag": func(delta: Vector2): m.map_pan += delta; m._update_map_transform(),
        "tap_at": func(p: Vector2): _place_map_cursor(p),
        "back": close,
    }
    if GameOptions.enabled("zoom"):
        surface["pinch"] = func(ratio: float): m._set_map_zoom(m.map_zoom * ratio)
    if GameOptions.enabled("map_waypoint") and is_instance_valid(m.waypoint_ui):
        surface["buttons"] = [["MARKER", func(): m.waypoint_ui.begin_name(),
            Rect2(Vector2(bounds.end.x - 70, bounds.end.y - 28), Vector2(64, 24))]]
    return surface

func _place_map_cursor(point: Vector2) -> void:
    var m := main
    if not is_instance_valid(m.map_view_node) or not is_instance_valid(m.waypoint_ui): return
    var local: Vector2 = m.map_view_node.get_global_transform().affine_inverse() * point
    var waypoints = m.waypoint_ui
    var cell: Vector2 = (local / m.SOURCE_MAP_TILE_PIXELS).floor() + Vector2(waypoints.bounds.position)
    waypoints.cursor_cell = cell.clamp(Vector2(waypoints.bounds.position), Vector2(waypoints.bounds.end - Vector2i.ONE))
    waypoints.update_markers()

# --- visuals ------------------------------------------------------------------

## Called every frame: shows the touch start menu in place of the classic box.
func refresh_visuals(delta: float = 0.0) -> void:
    var m := main
    field_hud.refresh(delta, _field_active())
    if not is_instance_valid(start_menu): _build_start_menu()
    if not is_instance_valid(setup_screen):
        setup_screen = preload("res://scripts/touch_setup_screen.gd").new()
        setup_screen.configure(m, ui)
    setup_screen.refresh()
    _refresh_backdrop()
    _refresh_move_cards()
    _refresh_bag_tabs()
    # Controller hints that touch replaces.
    if build_hint == null: build_hint = m.build_panel.get_node("Hint")
    build_hint.visible = false
    var top_level: bool = m.started and m.game_menu_open and m.game_menu.visible \
        and m.game_menu_box.visible and not m.game_menu_detail_open and not m.save_confirm_open \
        and not m.guide_menu_open and not m.pokemon_menu_open and not m.item_pocket_menu.visible \
        and not (is_instance_valid(m.pokedex_menu) and m.pokedex_menu.visible) \
        and not (is_instance_valid(m.options_menu) and m.options_menu.visible)
    if top_level and not start_menu.visible: _refresh_start_details()
    start_menu.visible = top_level
    m.game_menu_box.modulate.a = 0.0
    if m.game_menu_map_screen.visible:
        if map_hint == null: map_hint = m.get_node("UI/GameMenu/MapScreen/Hint")
        map_hint.text = "DRAG: MOVE   PINCH: ZOOM   TAP: CURSOR" if not m.teleport_map_mode else ""

func _build_start_menu() -> void:
    var m := main
    start_menu = Control.new()
    start_menu.name = "TouchStartMenu"
    start_menu.size = Vector2(320, 180)
    start_menu.z_index = 240
    start_menu.mouse_filter = Control.MOUSE_FILTER_IGNORE
    var card := Panel.new()
    card.position = Vector2(10, 8)
    card.size = Vector2(300, 164)
    card.mouse_filter = Control.MOUSE_FILTER_IGNORE
    card.add_theme_stylebox_override("panel", m._classic_dialogue_style())
    start_menu.add_child(card)
    m._source_ui_label(card, "Title", Vector2(14, 8), Vector2(120, 14), 11, "MENU")
    # Party strip: who is with you and how they are doing, at a glance.
    for i in 6:
        var slot := Control.new()
        slot.position = Vector2(118 + i * 28, 4)
        slot.size = Vector2(24, 22)
        slot.mouse_filter = Control.MOUSE_FILTER_IGNORE
        card.add_child(slot)
        var sprite: TextureRect = m._source_texture_rect(slot, "Sprite", Vector2(3, 0), Vector2(18, 18))
        var track := ColorRect.new()
        track.name = "Track"
        track.position = Vector2(2, 19)
        track.size = Vector2(20, 3)
        track.color = Color("404040")
        track.mouse_filter = Control.MOUSE_FILTER_IGNORE
        slot.add_child(track)
        var fill := ColorRect.new()
        fill.name = "Fill"
        fill.position = Vector2(2, 19)
        fill.size = Vector2(20, 3)
        fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
        slot.add_child(fill)
        party_slots.append(slot)
    for i in START_LABELS.size():
        var tile := Panel.new()
        tile.position = Vector2(12 + (i % 3) * 94, 28 + int(i / 3) * 44)
        tile.size = Vector2(88, 38)
        tile.mouse_filter = Control.MOUSE_FILTER_IGNORE
        tile.add_theme_stylebox_override("panel", m._classic_dialogue_style())
        card.add_child(tile)
        var picture: TextureRect = m._source_texture_rect(tile, "Icon", Vector2(8, 7), Vector2(24, 24), Icons.icon(START_LABELS[i]))
        picture.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
        var title: Label = m._source_ui_label(tile, "Text", Vector2(34, 9), Vector2(50, 12), 9, START_LABELS[i])
        var width := title.get_theme_font("font").get_string_size(title.text, HORIZONTAL_ALIGNMENT_LEFT, -1, 9).x
        title.scale.x = minf(1.0, 48.0 / maxf(1.0, width))
        var subtitle: Label = m._source_ui_label(tile, "Sub", Vector2(34, 21), Vector2(50, 10), 7, "")
        start_tiles.append(tile)
        start_subtitles.append(subtitle)
        start_icons.append(picture)
    start_menu.visible = false
    m.get_node("UI").add_child(start_menu)
    GameOptions.refresh_frames(start_menu)

## One full-screen layer behind touch menus: menus are 320 wide, phones wider.
func _refresh_backdrop() -> void:
    var m := main
    if not is_instance_valid(backdrop):
        backdrop = ColorRect.new()
        backdrop.name = "TouchBackdrop"
        backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
        m.get_node("UI").add_child(backdrop)
        m.get_node("UI").move_child(backdrop, 0)
    m.game_menu_map.clip_contents = false
    var dim := Color(0, 0, 0, 0.45)
    var color := Color.TRANSPARENT
    if m.started and not m.generating:
        if m.game_menu_open and m.game_menu_map_screen.visible: color = Color.BLACK
        elif start_menu.visible or m.save_confirm_open or m.quit_prompt_open: color = dim
        elif m.game_menu_open: color = Color.WHITE
    backdrop.visible = color.a > 0.0
    backdrop.color = color


# --- battle -------------------------------------------------------------------

func _battle() -> Dictionary:
    var m := main
    # Holding a finger down fast-forwards battle text.
    var advance := {"tap_at": func(_p): press("confirm"), "hold": func(): if m.battle_text_busy: m._finish_battle_text()}
    if m.battle_entry_pending: return advance
    # The command prompt re-types itself; a command tap must not wait for it.
    if String(m.battle_ui_mode) == "COMMAND" and not m.battle_submenu.visible and not m.item_pocket_menu.visible:
        return _battle_commands()
    if m.battle_text_busy: return advance
    if m.item_pocket_menu.visible and m.item_pocket_context == "BATTLE": return _items(func(): press("cancel"))
    if m.battle_submenu.visible: return _battle_submenu()
    match String(m.battle_ui_mode):
        "COMMAND": return _battle_commands()
        "MOVE": return _battle_moves()
    return advance

func _battle_commands() -> Dictionary:
    var m := main
    var rows := []
    for button in [m.fight_button, m.party_button, m.item_button, m.run_button]:
        rows.append(button.get_global_rect())
    var surface := {
        "rows": rows,
        "tap": func(i): _battle_command(i),
    }
    # The controller's Y repeated the last ball; on touch it is a button in the free space.
    var ball: String = m.last_battle_ball
    var context: Dictionary = m.battle_context if m.battle_context is Dictionary else {}
    var can_repeat: bool = not ball.is_empty() and int(m.inventory.get(ball, 0)) > 0 \
        and String(context.get("kind", "")) != "trainer" and bool(context.get("can_catch", false)) \
        and not m.battle_turn_busy
    if can_repeat:
        var origin: Vector2 = m.battle_command_box.get_global_rect().position
        surface["buttons"] = [["%s x%d" % [ball, int(m.inventory[ball])], func(): m._repeat_last_battle_ball(),
            Rect2(origin + Vector2(98, -26), Vector2(92, 22))]]
    return surface

func _battle_command(i: int) -> void:
    var m := main
    if m.battle_text_busy: m._finish_battle_text()
    if m.battle_turn_busy: return
    m.battle_command_index = i
    m._update_battle_command_cursor()
    m._activate_battle_command()

func _battle_moves() -> Dictionary:
    var m := main
    var count: int = mini(4, (m._command_pokemon().get("moves", []) as Array).size())
    var rows := []
    for i in count: rows.append(move_card_nodes[i].get_global_rect())
    return {
        "rows": rows,
        "tap": func(i): m.battle_move_index = i; m._refresh_battle_move_menu(); press("confirm"),
        "back": func(): press("cancel"),
    }

func _battle_submenu() -> Dictionary:
    var m := main
    var back := func(): press("cancel")
    if m.battle_party_action_open:
        var count: int = m.battle_party_action_list.get_line_count()
        var first: int = maxi(0, m.battle_party_action_index - 5)
        return {
            "rows": ui.label_lines(m.battle_party_action_list, count),
            "tap": func(i): m.battle_party_action_index = first + i; press("confirm"),
            "scroll": func(d): press("move_down" if d > 0 else "move_up"),
            "back": back,
        }
    var entries: int = m.battle_submenu_entries.size()
    if String(m.battle_submenu_mode) in ["DOUBLE_TARGET", "ITEM"]:
        var page: int = int(m.battle_submenu_index / 6) * 6
        return {
            "rows": ui.label_lines(m.battle_submenu_list, mini(6, entries - page), 220),
            "tap": func(i): m.battle_submenu_index = page + i; m._refresh_battle_submenu(); press("confirm"),
            "back": back,
        }
    var rows := []
    for i in mini(6, entries): rows.append(m.battle_party_rows[i].root.get_global_rect())
    var surface := {
        "rows": rows,
        "tap": func(i): m.battle_submenu_index = i; m._refresh_battle_submenu(); press("confirm"),
    }
    # A fainted Pokemon must be replaced: no way back.
    if String(m.battle_submenu_mode) not in ["FORCED", "BATON_PASS", "DOUBLE_FORCED"]: surface["back"] = back
    return surface

func _safari() -> Dictionary:
    var safari: Control = main.safari_ui
    var rows := []
    for label in safari.choices: rows.append(grown(label, Vector2(6, 2)))
    return {"rows": rows, "tap": func(i): _safari_choose(i), "tap_at": func(_p): press("confirm")}

func _safari_choose(i: int) -> void:
    var safari: Control = main.safari_ui
    if safari.busy:
        press("confirm")
        return
    safari.selection = i
    safari.refresh()
    safari.act(i)

func _progression() -> Dictionary:
    var m := main
    match String(m.progression_mode):
        "EVOLUTION":
            var bounds: Rect2 = m.touch_controls.usable_rect
            return {"buttons": [["STOP", func(): press("cancel"),
                Rect2(Vector2(bounds.end.x - 62, bounds.position.y + 4), Vector2(58, 22))]]}
        "MOVE_SELECT":
            var rows := []
            for row in m.progression_move_rows:
                if row.text != "-" and not row.text.is_empty(): rows.append(grown(row, Vector2(16, 2)))
            return {
                "rows": rows,
                "tap": func(i): _pick_move_to_forget(i),
                "back": func(): press("cancel"),
            }
        "MOVE_GIVEUP", "YES_NO":
            var frame: Control = m.progression_choice_frame
            return {
                "rows": [grown(frame.get_node("Choice0"), Vector2(18, 4)), grown(frame.get_node("Choice1"), Vector2(18, 4))],
                "tap": func(i): m.progression_choice_index = i; m._refresh_progression_yes_no(); press("confirm"),
            }
    return {"tap_at": func(_p): press("confirm")}

## A tap shows a move's details; a tap on the move already shown asks to replace it.
func _pick_move_to_forget(i: int) -> void:
    if i == main.progression_choice_index: press("confirm")
    else:
        main.progression_choice_index = i
        main._refresh_progression_move_menu()

# --- field prompts ------------------------------------------------------------

func _field_prompt() -> Dictionary:
    var m := main
    var cancel := func(): press("cancel")
    var advance := func(_p): press("confirm")
    if m.wild_pokemon_prompt_open:
        # The prompt ignores a confirm until one has been released after it opened.
        if m.wild_pokemon_prompt_stage == 1:
            return _yes_no(m.wild_choice_panel, func(i): _wild_choice(i))
        return {"tap_at": func(_p): m.wild_pokemon_prompt_confirm_armed = true; press("confirm"), "back": cancel}
    if m.mansion_switch_open:
        if m.mansion_switch_stage == 1:
            return _yes_no(m.egg_choice_panel, func(i): _mansion_choice(i))
        return {"tap_at": advance, "back": cancel}
    if m.egg_pickup_open:
        if m.egg_pickup_stage == 1:
            return _yes_no(m.egg_choice_panel, func(i): m.egg_pickup_index = i; m._update_egg_pickup_cursor())
        return {"tap_at": advance, "back": cancel}
    if m.trainer_tip_open: return {"tap_at": advance, "back": cancel}
    return {}

func _wild_choice(i: int) -> void:
    main.wild_pokemon_prompt_confirm_armed = true
    main.wild_pokemon_prompt_index = i
    main._update_wild_pokemon_prompt_cursor()

func _mansion_choice(i: int) -> void:
    main.mansion_switch_index = i
    main._align_menu_tick(main.egg_choice_cursor, main.egg_choice_panel.get_node("Yes" if i == 0 else "No"))

# --- battle move cards ----------------------------------------------------------

const TYPE_COLORS := {
    "NORMAL": "a8a878", "FIRE": "f08030", "WATER": "6890f0", "ELECTRIC": "f8d030",
    "GRASS": "78c850", "ICE": "98d8d8", "FIGHTING": "c03028", "POISON": "a040a0",
    "GROUND": "e0c068", "FLYING": "a890f0", "PSYCHIC": "f85888", "BUG": "a8b820",
    "ROCK": "b8a038", "GHOST": "705898", "DRAGON": "7038f8", "DARK": "705848",
    "STEEL": "b8b8d0", "FAIRY": "ee99ac",
}

func _build_move_cards() -> void:
    var m := main
    move_cards = Control.new()
    move_cards.name = "TouchMoveCards"
    move_cards.size = Vector2(320, 180)
    move_cards.z_index = 30
    move_cards.mouse_filter = Control.MOUSE_FILTER_IGNORE
    for i in 4:
        var card := Panel.new()
        card.position = Vector2(4 + (i % 2) * 158, 117 + int(i / 2) * 31)
        card.size = Vector2(154, 28)
        card.mouse_filter = Control.MOUSE_FILTER_IGNORE
        move_cards.add_child(card)
        m._source_ui_label(card, "Name", Vector2(7, 4), Vector2(140, 12), 9, "")
        var info: Label = m._source_ui_label(card, "Info", Vector2(7, 16), Vector2(140, 9), 7, "")
        info.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
        move_card_nodes.append(card)
    move_cards.visible = false
    m.get_node("UI").add_child(move_cards)

## Four big type-coloured cards replace the classic move list on touch.
func _refresh_move_cards() -> void:
    var m := main
    if not is_instance_valid(move_cards): _build_move_cards()
    var showing: bool = m.battle_active and String(m.battle_ui_mode) == "MOVE" and m.battle_move_box.visible
    move_cards.visible = showing
    m.battle_move_box.modulate.a = 0.0 if showing else 1.0
    m.battle_move_type_box.modulate.a = 0.0 if showing else 1.0
    if not showing:
        move_card_signature = []
        return
    var actor: Dictionary = m._command_pokemon()
    var moves: Array = actor.get("moves", [])
    var signature := [moves.duplicate(), (actor.get("pp", {}) as Dictionary).duplicate(), m.battle_move_index]
    if signature == move_card_signature: return
    move_card_signature = signature
    for i in 4:
        var card := move_card_nodes[i]
        card.visible = i < moves.size()
        if not card.visible: continue
        var move := String(moves[i])
        var data: Dictionary = PokemonData.move_info(move)
        var type := String(data.get("type", "NORMAL"))
        var colour := Color(String(TYPE_COLORS.get(type, "a8a878")))
        var maximum := int(data.get("pp", 0))
        var current := int((actor.get("pp", {}) as Dictionary).get(move, maximum))
        card.add_theme_stylebox_override("panel", _card_style(type, colour, i == m.battle_move_index))
        (card.get_node("Name") as Label).text = move.replace("_", " ")
        (card.get_node("Info") as Label).text = "%s   PP %d/%d" % [type, current, maximum]

func _refresh_start_details() -> void:
    var m := main
    var party: Array = m.caught_pokemon
    start_subtitles[1].text = "%d / 6" % mini(6, party.size())
    start_subtitles[0].text = "SEEN %d" % m.pokedex_progress.entries.size()
    var bag := 0
    for item in m.inventory: bag += int(m.inventory[item])
    start_subtitles[2].text = "%d ITEMS" % bag
    # The lead Pokemon and the live minimap stand in for two of the icons.
    start_icons[1].texture = _party_icon(party[0]) if not party.is_empty() else Icons.icon("POKEMON")
    var minimap := m.m3924_minimap_root.get_node_or_null("Map") as TextureRect if is_instance_valid(m.m3924_minimap_root) else null
    start_icons[4].texture = minimap.texture if minimap != null and minimap.texture != null else Icons.icon("MAP")
    for i in party_slots.size():
        var slot := party_slots[i]
        slot.visible = i < party.size()
        if not slot.visible: continue
        var record: Dictionary = party[i]
        (slot.get_node("Sprite") as TextureRect).texture = _party_icon(record)
        var egg := bool(record.get("is_egg", false))
        var ratio := clampf(float(record.get("hp", 0)) / maxf(1.0, float(record.get("max_hp", 1))), 0.0, 1.0)
        var fill := slot.get_node("Fill") as ColorRect
        fill.visible = not egg
        (slot.get_node("Track") as ColorRect).visible = not egg
        fill.size.x = 20.0 * ratio
        fill.color = Color("58c048") if ratio > 0.5 else (Color("f0c040") if ratio > 0.2 else Color("e04038"))

## A party member's walking frame, or the egg (an egg keeps its species).
func _party_icon(record: Dictionary) -> Texture2D:
    return main.POKEMON_EGG_TEXTURE if bool(record.get("is_egg", false)) else main._party_record_frame(record)

# --- reorder by drag ------------------------------------------------------------

func _pick_party(i: int) -> void:
    var m := main
    m.pokemon_menu_index = i
    m.pokemon_switch_selecting = true
    m.pokemon_switch_source_index = i
    m._refresh_pokemon_category_menu()

func _drop_party(_from: int, point: Vector2, rows: Array) -> void:
    var m := main
    for j in rows.size():
        if Rect2(rows[j]).has_point(point):
            m.pokemon_menu_index = j
            m._finish_pokemon_switch()
            return
    m.pokemon_switch_selecting = false
    m.pokemon_switch_source_index = -1
    m._refresh_pokemon_category_menu()

func _pick_storage(index: int) -> void:
    var m := main
    m.storage_index = index
    m.storage_switch_from = index
    m.storage_mode = "SWITCH"
    m._refresh_storage_menu()

func _drop_storage(window_start: int, _from: int, point: Vector2, rows: Array) -> void:
    var m := main
    for j in rows.size():
        if Rect2(rows[j]).has_point(point):
            m.storage_index = window_start + j
            m._refresh_storage_menu()
            press("confirm")
            return
    m.storage_mode = "LIST"
    m.storage_switch_from = -1
    m._refresh_storage_menu()

# --- bag pocket tabs ------------------------------------------------------------

func _refresh_bag_tabs() -> void:
    var m := main
    if not is_instance_valid(bag_tabs):
        bag_tabs = Control.new()
        bag_tabs.name = "TouchPocketTabs"
        bag_tabs.position = Vector2(8, 8)
        bag_tabs.size = Vector2(74, 116)
        bag_tabs.z_index = 5
        bag_tabs.mouse_filter = Control.MOUSE_FILTER_IGNORE
        m.item_pocket_menu.add_child(bag_tabs)
        for i in POCKET_NAMES.size():
            var tab: Control = ui.make_button(bag_tabs, POCKET_NAMES[i], Vector2(72, 19), 8)
            tab.position = Vector2(0, i * 23)
            bag_tab_buttons.append(tab)
    var showing: bool = m.item_pocket_menu.visible
    bag_tabs.visible = showing
    # The tabs take the place of the pocket picture and name.
    m.item_pocket_label.modulate.a = 0.0
    m.item_pocket_bag.modulate.a = 0.0
    if not showing:
        shown_pocket = -1
        return
    if shown_pocket == int(m.battle_item_pocket_index): return
    shown_pocket = int(m.battle_item_pocket_index)
    for i in bag_tab_buttons.size():
        ui.set_selected(bag_tab_buttons[i], i == shown_pocket)

func _pokedex_grid(dex: Control) -> Dictionary:
    var rows := []
    for i in dex.grid_page_items.size(): rows.append(dex.grid_cells[i].get_global_rect())
    var bounds: Rect2 = main.touch_controls.usable_rect
    var search := "DONE" if dex.searching else ("CLEAR" if not String(dex.query).is_empty() else "SEARCH")
    return {
        "rows": rows,
        "tap": func(i): _pokedex_pick(dex, i),
        "swipe": func(d): dex.turn_page(d),
        "buttons": [[search, func(): _pokedex_search(dex), Rect2(Vector2(bounds.end.x - 92, bounds.position.y + 4), Vector2(62, 20))]],
        "back": func():
            if dex.searching: dex.end_search(true)
            else: dex.close(),
    }

func _pokedex_pick(dex: Control, i: int) -> void:
    if i >= dex.grid_page_items.size(): return
    var index := int(dex.grid_page_items[i])
    if index == dex.selection: dex.play_cry()
    else:
        dex.selection = index
        dex.refresh()

func _pokedex_search(dex: Control) -> void:
    if dex.searching: dex.end_search(false)
    elif not String(dex.query).is_empty(): dex.end_search(true)
    else: dex.begin_search()

# --- crafting and building --------------------------------------------------------

func _crafting() -> Dictionary:
    var panel: Rect2 = main.crafting_panel.get_global_rect()
    var y := panel.get_center().y - 11
    return {
        "buttons": [
            ["<", func(): press("move_left"), Rect2(Vector2(panel.position.x - 28, y), Vector2(24, 22))],
            [">", func(): press("move_right"), Rect2(Vector2(panel.end.x + 4, y), Vector2(24, 22))],
            ["CRAFT", func(): press("confirm"), Rect2(Vector2(panel.get_center().x - 36, panel.end.y + 4), Vector2(72, 22))],
        ],
        "swipe": func(d): press("move_right" if d > 0 else "move_left"),
        "back": func(): press("cancel"),
    }

## BUILD keeps the pad: the player walks to place the preview, A builds.
func _build_menu() -> Dictionary:
    var m := main
    # The game's own boxes (recipe name left, materials right) stay on top;
    # the touch row sits just under them.
    var name_box: Rect2 = m.build_panel.get_global_rect()
    var need_box: Rect2 = (m.build_panel.get_node("NeedPanel") as Control).get_global_rect()
    var y := name_box.end.y + 3
    return {
        "modal": false,
        "buttons": [
            ["<", func(): press("shoulder_left"), Rect2(Vector2(name_box.position.x + 4, y), Vector2(26, 20))],
            [">", func(): press("shoulder_right"), Rect2(Vector2(name_box.position.x + 34, y), Vector2(26, 20))],
            ["DONE", func(): press("cancel"), Rect2(Vector2(need_box.end.x - 54, y), Vector2(52, 20))],
        ],
    }

## The keyboard covers the lower half: the panel moves to the top and its
## SAVE/DELETE/BACK move into the strip the keyboard leaves free.
func _waypoint_naming() -> Dictionary:
    var waypoints = main.waypoint_ui
    waypoints.panel.position.y = 2
    var bounds: Rect2 = main.touch_controls.usable_rect
    var buttons := [["SAVE", func(): waypoints.save_name(), Rect2(Vector2(bounds.end.x - 82, bounds.position.y + 4), Vector2(54, 20))]]
    if waypoints.editing_existing:
        buttons.append(["DELETE", func(): waypoints.delete_marker(), Rect2(Vector2(bounds.end.x - 82, bounds.position.y + 28), Vector2(54, 20))])
    # Taps on the panel's own buttons and text field still reach them.
    return {"modal": false, "hide_pad": true, "buttons": buttons, "back": func(): waypoints.cancel_name()}

func _card_style(type: String, colour: Color, selected: bool) -> StyleBoxFlat:
    var key := "%s|%s" % [type, selected]
    if card_styles.has(key): return card_styles[key]
    var style := StyleBoxFlat.new()
    style.bg_color = colour.lerp(Color.WHITE, 0.55)
    style.border_color = Color.BLACK if selected else colour.darkened(0.45)
    style.set_border_width_all(2 if selected else 1)
    style.set_corner_radius_all(3)
    style.anti_aliasing = false
    card_styles[key] = style
    return style
