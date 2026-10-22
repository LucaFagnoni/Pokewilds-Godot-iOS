# The co-op boxes on a touch screen, in a real game on a throwaway data folder:
# the title's notice on its dark tag, the TRADE / BATTLE / request boxes
# (coop_interaction_ui.gd) clear of the HUD with rows a finger picks, and the
# joined / left / hosting notice as a HUD chip centred under the clock, on a
# 320 and a 390 px wide screen.
# Run: godot --headless --path project -s <this file> -- --touch-ui
# Run it windowed (no --headless) to also save screenshots into SHOTS (the system temp folder).
extends SceneTree

const Paths = preload("res://scripts/game_data_paths.gd")
const Hud = preload("res://scripts/hud_style.gd")
var SHOTS := OS.get_temp_dir().path_join("coop_ui")
const BREAKS := TextServer.BREAK_MANDATORY | TextServer.BREAK_WORD_BOUND | TextServer.BREAK_ADAPTIVE | TextServer.BREAK_TRIM_EDGE_SPACES

var main: Node
var checks := 0
var failed := 0

func check(ok: bool, what: String) -> void:
    checks += 1
    if not ok:
        failed += 1
        printerr("COOP UI TEST FAIL: ", what)

func _frames(count: int) -> void:
    for i in count: await process_frame

func shot(file: String) -> void:
    if DisplayServer.get_name() == "headless": return
    await RenderingServer.frame_post_draw
    DirAccess.make_dir_recursive_absolute(SHOTS)
    root.get_texture().get_image().save_png(SHOTS.path_join(file))

## A finger down and up at a point of the 320x180 canvas.
func tap_at(point: Vector2) -> void:
    for pressed in [true, false]:
        var touch := InputEventScreenTouch.new()
        touch.position = root.get_final_transform() * point
        touch.pressed = pressed
        Input.parse_input_event(touch)
        await _frames(2)
    await _frames(3)

func key(action: String) -> void:
    for pressed in [true, false]:
        var event := InputEventAction.new()
        event.action = action
        event.pressed = pressed
        Input.parse_input_event(event)
        await _frames(1)
    await _frames(2)

## What the HUD shows in the field: minimap, clock, battery and menu button.
func hud_rects() -> Dictionary:
    var out := {}
    if main.minimap_root.is_visible_in_tree(): out["minimap"] = main.minimap_root.get_global_rect()
    if main.status_hud.clock_chip.is_visible_in_tree(): out["clock"] = main.status_hud.clock_chip.get_global_rect()
    if main.status_hud.battery_chip.is_visible_in_tree(): out["battery"] = main.status_hud.battery_chip.get_global_rect()
    # The on-screen buttons where a phone has them (a PC with --touch-ui does not show them).
    var pad: Control = main.touch_controls
    for name in ["Start", "A", "B", "L2", "R2", "LeftStick"]:
        out[name] = (pad.get_node(name) as Control).get_global_rect()
    return out

func clear_of_hud(rect: Rect2, hud: Dictionary, what: String) -> void:
    var screen: Vector2 = main.get_viewport().get_visible_rect().size
    check(Rect2(Vector2.ZERO, screen).encloses(rect), "%s on screen: %s" % [what, rect])
    for name in hud:
        check(not rect.intersects(hud[name]), "%s %s clear of the %s %s" % [what, rect, name, hud[name]])

## Lines a label of this width shows, as the label's own wrapping makes them.
func planned_lines(text: String, font: Font, size: int, width: float) -> int:
    return roundi(font.get_multiline_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, width, size, -1, BREAKS).y / font.get_height(size))

func _initialize() -> void:
    create_timer(600.0).timeout.connect(func(): printerr("COOP UI TEST FAIL: timed out"); quit(2))
    var dir := OS.get_temp_dir().path_join("coop_ui_test_%d" % Time.get_ticks_usec())
    DirAccess.make_dir_recursive_absolute(dir)
    FileAccess.open(dir.path_join(".private-saves-migrated"), FileAccess.WRITE).close()
    Paths.directory = dir
    change_scene_to_file("res://scenes/main.tscn")
    await _frames(30)
    main = current_scene
    while not main.startup_complete: await process_frame
    await _frames(10)
    check(main.touch_ui.enabled, "the touch UI is on (--touch-ui)")

    # --- the title's notice --------------------------------------------------
    var menu: Control = main.coop_menu
    var notice: Label = menu.title_notice
    var screen: Vector2 = main.get_viewport().get_visible_rect().size
    var messages := ["HOST DISCONNECTED.\nSESSION ENDED.", "COULD NOT REACH THE HOST.\nTRY AGAIN, OR CHECK THE WI-FI.",
        "ONLINE AREA COULD NOT BE SAVED. SESSION ENDED.", "FIELD ACTION COULD NOT BE SAVED. REJOIN THE WORLD.", "KICKED"]
    for i in messages.size():
        main.coop_game.notice = messages[i]
        menu.open()
        await _frames(4)
        var rect := notice.get_global_rect()
        var style: StyleBox = notice.get_theme_stylebox("normal")
        var inner := rect.size.x - style.content_margin_left - style.content_margin_right
        var font := notice.get_theme_font("font")
        check(notice.visible and notice.text == messages[i], "title notice %d shows" % i)
        check(style is StyleBoxFlat and (style as StyleBoxFlat).bg_color.a >= 0.8, "title notice %d on a dark tag" % i)
        check(Rect2(Vector2.ZERO, screen).encloses(rect) and rect.size.x <= screen.x * 0.75 + 9.0, "title notice %d inside the screen: %s" % [i, rect])
        check(not rect.intersects(menu.title_rows[1].get_global_rect()), "title notice %d under CO-OP: %s %s" % [i, rect, menu.title_rows[1].get_global_rect()])
        check(notice.get_line_count() == planned_lines(messages[i], font, 10, inner) and notice.get_line_count() <= 3,
            "title notice %d wraps as planned: %d lines" % [i, notice.get_line_count()])
        await shot("title_%d.png" % i)
    main.coop_game.notice = ""
    menu.open()
    await _frames(2)
    check(not notice.visible, "no notice, no tag")

    # --- a game ---------------------------------------------------------------
    menu.close()
    main.world_edit.text = "CoopUiTest"
    main.selected_mode = "NEW"
    main._start_game()
    var waited := 0
    while not main.started and waited < 36000:
        await process_frame
        waited += 1
    check(main.started, "the world started")
    await _frames(60)
    # Out of the welcome message, back to the plain field.
    for i in 6:
        if not main._field_ui_blocks_gameplay(): break
        await key("confirm")
        await _frames(20)
    var hud := hud_rects()
    check(hud.has("minimap") and hud.has("clock"), "the HUD is up: %s" % hud.keys())

    # --- the joined / left / hosting notice --------------------------------------
    # Centred under the clock, GAP below it, on a 320 and a phone's 390 px wide
    # screen, with a battery in the top row as on a phone.
    var coop: Node = main.coop_game
    OS.set_environment(main.status_hud.BATTERY_ENV, "60,1")
    main.status_hud.update()
    for width in [320, 390]:
        root.size = Vector2i(width * 4, 720)
        await create_timer(0.7).timeout
        await _frames(4)
        check(is_equal_approx(main.get_viewport().get_visible_rect().size.x, width), "%d px wide: %s" % [width, main.get_viewport().get_visible_rect().size])
        hud = hud_rects()
        check(hud.has("battery"), "the battery shows")
        for event in [["", "hosting"], ["ASH", "joined"], ["ABCDEFGHIJKLMNOPQRSTUVWX", "away"]]:
            coop.show_notice(event[0], event[1])
            await _frames(2)
            var box: Control = coop._notice_box
            var text: Label = coop._notice_label
            var where := "notice %s at %d" % [event[1], width]
            clear_of_hud(box.get_global_rect(), hud, where)
            var lines := text.get_line_count()
            var ink := Rect2(text.position + Vector2(0, Hud.INK_CENTRE - Hud.INK_HEIGHT / 2.0), Vector2(text.size.x - 1.0, Hud.INK_HEIGHT + (lines - 1) * coop.NOTICE_LINE))
            check(Rect2(Vector2.ZERO, box.size).grow(-Hud.PAD + 0.01).encloses(ink), "%s: the text %s fits its box %s" % [where, ink, box.size])
            check(lines == planned_lines(text.text, Hud.FONT, Hud.FONT_SIZE, text.size.x), "%s wraps where measured: %d" % [where, lines])
            check(text.get_theme_font("font") == Hud.FONT and text.get_theme_font_size("font_size") == Hud.FONT_SIZE, "%s in the HUD font" % where)
            var rect := box.get_global_rect()
            check(absf(rect.get_center().x - Rect2(hud.clock).get_center().x) <= 1.0, "%s centred under the clock: %s %s" % [where, rect, hud.clock])
            check(is_equal_approx(rect.position.y, Rect2(hud.clock).end.y + Hud.GAP), "%s GAP under the clock: %s %s" % [where, rect, hud.clock])
            await shot("notice_%s_%d.png" % [event[1], width])
    coop._notice_box.visible = false
    root.size = Vector2i(1280, 720)
    OS.set_environment(main.status_hud.BATTERY_ENV, "")
    main.status_hud.update()
    await _frames(4)
    hud = hud_rects()

    # --- TRADE REQUEST ----------------------------------------------------------
    var ui: Control = coop.interaction_ui
    ui.interaction = {"kind": "TRADE", "a": "OTHER", "b": coop.session.actor}
    ui.phase = "invite"; ui.selection = 0
    ui.show(); ui.refresh()
    await _frames(3)
    var panel: Rect2 = ui.panel.get_global_rect()
    clear_of_hud(panel, hud, "TRADE REQUEST")
    check(panel.size.x < 200 and panel.size.y < 100, "TRADE REQUEST fits its two rows: %s" % panel)
    check(not ui.footer.visible, "no A/B hint on a touch screen")
    var surface: Dictionary = main.touch_ui.surfaces.build()
    var rows: Array = surface.get("rows", [])
    check(rows.size() == 2 and surface.has("back"), "two rows and the X: %s" % surface.keys())
    for rect in rows: check(Rect2(rect).size.y >= 16 and Rect2(rect).size.x >= 80 and panel.encloses(rect), "a finger-sized row: %s" % rect)
    check(main.touch_ui.close_button.visible and not main.touch_ui.close_button.get_global_rect().intersects(panel), "the X is up, clear of the box")
    await shot("trade_request.png")
    # A tap on DECLINE picks it and sends it (offline: the answer comes back BUSY).
    await tap_at(Rect2(rows[1]).get_center())
    check(ui.selection == 1 and ui.title.text == "BUSY", "a tap picks and confirms DECLINE: %d %s" % [ui.selection, ui.title.text])

    # CONFIRM THIS TRADE?: CHANGE POKEMON goes back to the party.
    ui.interaction = {"kind": "TRADE", "a": coop.session.actor, "b": "OTHER", "accepted": true, "offers": {}}
    ui.phase = "confirm"; ui.selection = 0; ui.refresh()
    await _frames(2)
    clear_of_hud(ui.panel.get_global_rect(), hud, "CONFIRM")
    await shot("trade_confirm.png")
    await tap_at(Rect2(main.touch_ui.surfaces.build().rows[1]).get_center())
    check(ui.phase == "trade", "a tap on CHANGE POKEMON: %s" % ui.phase)
    check(main.touch_ui.surfaces.build().rows.size() == main.caught_pokemon.size(), "a row per party Pokemon")
    clear_of_hud(ui.panel.get_global_rect(), hud, "CHOOSE YOUR POKEMON")
    await shot("trade_choose_pokemon.png")

    # WAITING: no rows, the X cancels.
    ui.phase = "wait"; ui.refresh()
    await _frames(2)
    clear_of_hud(ui.panel.get_global_rect(), hud, "WAITING")
    check(main.touch_ui.surfaces.build().get("rows", []).is_empty() and main.touch_ui.close_button.visible, "waiting: only the X")
    await shot("trade_wait.png")

    # TRADE / BATTLE: the controller still moves the tick; the X closes it.
    ui.open_for("OTHER")
    await _frames(2)
    clear_of_hud(ui.panel.get_global_rect(), hud, "TRADE / BATTLE")
    await shot("choose_action.png")
    await key("move_down")
    check(ui.selection == 1, "the controller moves the tick")
    await tap_at(main.touch_ui.close_button.get_global_rect().get_center())
    check(not ui.visible, "the X closes the box")

    # Without the touch UI the A/B hint is back, inside the box.
    main.touch_ui.enabled = false
    ui.interaction = {"kind": "BATTLE", "a": "OTHER", "b": coop.session.actor}
    ui.phase = "invite"; ui.selection = 0; ui.show(); ui.refresh()
    await _frames(2)
    check(ui.footer.visible and Rect2(Vector2.ZERO, ui.panel.size).encloses(Rect2(ui.footer.position, ui.footer.size)), "the A/B hint on a keyboard: %s in %s" % [ui.footer.get_rect(), ui.panel.size])
    clear_of_hud(ui.panel.get_global_rect(), hud, "BATTLE REQUEST (keyboard)")
    await shot("battle_request_keyboard.png")
    ui.hide(); ui.phase = ""
    main.touch_ui.enabled = true

    print("COOP UI TEST: %d checks, %d failed" % [checks, failed])
    quit(1 if failed > 0 else 0)
