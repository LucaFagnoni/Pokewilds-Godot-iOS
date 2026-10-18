extends RefCounted
## What can be touched on the screen in front of the player (see touch_ui.gd).
## Every action goes through the game's own functions or menu actions, so touch
## and controller always share one code path.

const JOHTO_FONT := preload("res://assets/source_text_font.fnt")
const GameOptions = preload("res://scripts/game_options.gd")
const START_LABELS := ["POKEDEX", "POKEMON", "ITEM", "STORAGE", "MAP", "GUIDE", "OPTIONS", "SAVE", "EXIT"]

var main: Node
var ui: Node
var map_from_minimap := false
var start_menu: Control
var start_tiles: Array[Panel] = []
var start_subtitles: Array[Label] = []
var setup_screen: Control
var backdrop: ColorRect

func _init(owner_main: Node, owner_ui: Node) -> void:
    main = owner_main
    ui = owner_ui

func press(action: String) -> void:
    ui.press(action)

static func grown(control: Control, by: Vector2 = Vector2(8, 6)) -> Rect2:
    return control.get_global_rect().grow_individual(by.x, by.y, by.x, by.y)

# --- screens ------------------------------------------------------------------

func build() -> Dictionary:
    var m := main
    if not m.started:
        return setup_screen.surface() if is_instance_valid(setup_screen) else {}
    if m.generating: return {}
    if not m.game_menu_open: map_from_minimap = false
    if is_instance_valid(m.waypoint_ui) and m.waypoint_ui.naming:
        # The naming panel has real buttons and a text field.
        return {"modal": false, "hide_pad": true}
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
    var prompt := _field_prompt()
    if not prompt.is_empty(): return prompt
    return _field()

func _field() -> Dictionary:
    var m := main
    var minimap: Control = m.m3924_minimap_root
    if not is_instance_valid(minimap) or not minimap.is_visible_in_tree(): return {}
    if m._field_ui_blocks_gameplay() or m.field_move_wheel_open or m._sleeping_bag_active(): return {}
    return {
        "modal": false,
        "rows": [minimap.get_global_rect()],
        "tap": func(_i): _open_map_from_minimap(),
    }

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
    if m.pokemon_menu_open: return _party_rows(func(i): m.pokemon_menu_index = i; m._refresh_pokemon_category_menu(); press("confirm"))
    if m.save_confirm_open: return _yes_no(m.save_confirm, func(i): m.save_confirm_index = i; m._update_save_confirm_cursor())
    if m.guide_topic_open: return {"back": func(): press("cancel"), "tap_at": func(_p): press("cancel")}
    if m.guide_menu_open: return _guide()
    if m.game_menu_box.visible and not m.game_menu_detail_open: return _start_menu()
    # Anything else inside the menu: never leave the player without a way back.
    return {"back": func(): press("cancel"), "tap_at": func(_p): press("confirm")}

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
    return {
        "rows": ui.label_lines(m.item_pocket_list, visible_rows, 200),
        "tap": func(i): m.battle_item_menu_index = page_start + i; m._refresh_battle_item_pocket_menu(); press("confirm"),
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
        "tap": func(i, p: Vector2):
            var index: int = menu.first + i
            if menu.controls_page:
                menu.control_index = mini(index, menu.control_rows.size() - 1); menu.refresh(); return
            if index >= menu.menu_rows.size(): return
            menu.selection = index; menu.refresh()
            # Left of the value steps it down; anywhere else steps up / toggles / opens.
            var value_left: float = menu.row_nodes[i].global_position.x + 132.0
            press("move_left" if p.x >= value_left and p.x < value_left + 70.0 else "confirm"),
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
func refresh_visuals() -> void:
    var m := main
    if not is_instance_valid(start_menu): _build_start_menu()
    if not is_instance_valid(setup_screen):
        setup_screen = preload("res://scripts/touch_setup_screen.gd").new()
        setup_screen.configure(m, ui)
    setup_screen.refresh()
    _refresh_backdrop()
    # Taller move rows for fingers; four lines still fit the move box.
    m.battle_move_list.add_theme_constant_override("line_spacing", 4)
    var top_level: bool = m.started and m.game_menu_open and m.game_menu.visible \
        and m.game_menu_box.visible and not m.game_menu_detail_open and not m.save_confirm_open \
        and not m.guide_menu_open and not m.pokemon_menu_open and not m.item_pocket_menu.visible \
        and not (is_instance_valid(m.pokedex_menu) and m.pokedex_menu.visible) \
        and not (is_instance_valid(m.options_menu) and m.options_menu.visible)
    start_menu.visible = top_level
    m.game_menu_box.modulate.a = 0.0
    if top_level:
        start_subtitles[1].text = "%d / 6" % mini(6, m.caught_pokemon.size())
    if m.game_menu_map_screen.visible:
        m.get_node("UI/GameMenu/MapScreen/Hint").text = "DRAG: MOVE   PINCH: ZOOM   TAP: CURSOR" if not m.teleport_map_mode else ""

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
    for i in START_LABELS.size():
        var tile := Panel.new()
        tile.position = Vector2(12 + (i % 3) * 94, 28 + int(i / 3) * 44)
        tile.size = Vector2(88, 38)
        tile.mouse_filter = Control.MOUSE_FILTER_IGNORE
        tile.add_theme_stylebox_override("panel", m._classic_dialogue_style())
        card.add_child(tile)
        var title: Label = m._source_ui_label(tile, "Text", Vector2(0, 7), Vector2(88, 14), 10, START_LABELS[i])
        title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
        var subtitle: Label = m._source_ui_label(tile, "Sub", Vector2(0, 21), Vector2(88, 10), 7, "")
        subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
        start_tiles.append(tile)
        start_subtitles.append(subtitle)
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
    var advance := {"tap_at": func(_p): press("confirm")}
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
    var count: int = mini(4, m.battle_move_list.get_line_count())
    return {
        "rows": ui.label_lines(m.battle_move_list, count, 190),
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
                "tap": func(i): m.progression_choice_index = i; m._refresh_progression_move_menu(); press("confirm"),
                "back": func(): press("cancel"),
            }
        "MOVE_GIVEUP", "YES_NO":
            var frame: Control = m.progression_choice_frame
            return {
                "rows": [grown(frame.get_node("Choice0"), Vector2(18, 4)), grown(frame.get_node("Choice1"), Vector2(18, 4))],
                "tap": func(i): m.progression_choice_index = i; m._refresh_progression_yes_no(); press("confirm"),
            }
    return {"tap_at": func(_p): press("confirm")}

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
    var window := m.get_node_or_null("UI/FieldMoveChoice")
    if window != null and window.is_visible_in_tree():
        var rows := []
        for row in window.rows: rows.append(grown(row, Vector2(10, 0)))
        return {
            "rows": rows,
            "tap": func(i): window.chosen.emit(-1 if i == window.rows.size() - 1 else i),
            "back": func(): window.chosen.emit(-1),
        }
    return {}

func _wild_choice(i: int) -> void:
    main.wild_pokemon_prompt_confirm_armed = true
    main.wild_pokemon_prompt_index = i
    main._update_wild_pokemon_prompt_cursor()

func _mansion_choice(i: int) -> void:
    main.mansion_switch_index = i
    main._align_menu_tick(main.egg_choice_cursor, main.egg_choice_panel.get_node("Yes" if i == 0 else "No"))
