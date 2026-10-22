# The CO-OP menu as a first-time player walks it (coop_menu.gd): every page and back again,
# HOST A GAME's WORLD / ACCESS / PLAYERS / NEXT (coop_game.max_players gets the count, kept in
# 2..max_players_cap()), JOIN A GAME with stubbed games and dedicated servers (tags, n/max,
# PRIVATE, the server's version in green or red, SAVE to MY SERVERS), a listed server joined
# directly or through the login form, the empty lists, no A/B hints on touch, every row tappable
# and inside the panel, clear of the touch X. On a throwaway data folder.
# Run: godot --headless --path project -s ../server/coop_menu_flow_test.gd -- --touch-ui   (and without --touch-ui)
# Windowed (--rendering-driver opengl3 instead of --headless) with -- --shots <folder> it also saves
# every page at 320 and 390 px wide, the main ones in dark mode too.
extends SceneTree

const Paths = preload("res://scripts/game_data_paths.gd")
const Saved = preload("res://scripts/coop_saved_servers.gd")
const Session = preload("res://scripts/coop_session.gd")
const Settings = preload("res://scripts/game_options.gd")

var main: Node
var menu: Control
var checks := 0
var failed := 0
var chosen: Array = []
var touch := OS.get_cmdline_user_args().has("--touch-ui")

func check(ok: bool, what: String) -> void:
    checks += 1
    if not ok:
        failed += 1
        printerr("COOP MENU FLOW TEST FAIL: ", what)

func _frames(count: int) -> void:
    for i in count: await process_frame

func inject(event: InputEvent) -> void:
    Input.parse_input_event(event)
    await _frames(2)

## A finger tap on the middle of a control (emulated as a mouse click without the touch UI).
func tap(control: Control) -> void:
    check(control.is_visible_in_tree(), "tappable: %s" % control.get_path())
    var at: Vector2 = root.get_final_transform() * (control.get_global_transform_with_canvas() * (control.size / 2.0))
    for pressed in [true, false]:
        var event := InputEventScreenTouch.new()
        event.position = at
        event.pressed = pressed
        await inject(event)
    await _frames(3)

func key(keycode: int, unicode: int = 0) -> void:
    for pressed in [true, false]:
        var event := InputEventKey.new()
        event.keycode = keycode
        event.unicode = unicode
        event.pressed = pressed
        await inject(event)

func pad(action: String) -> void:
    var source: InputEventJoypadButton
    for mapped in InputMap.action_get_events(action):
        if mapped is InputEventJoypadButton: source = mapped
    if source == null:
        # The D-pad may be mapped as an axis: the action itself then.
        for pressed in [true, false]:
            var event := InputEventAction.new()
            event.action = action
            event.pressed = pressed
            await inject(event)
        return
    for pressed in [true, false]:
        var event := InputEventJoypadButton.new()
        event.button_index = source.button_index
        event.pressed = pressed
        await inject(event)

## Back the way the player has it: the X on a touch screen, Escape on a keyboard.
func back() -> void:
    # A beat between taps, as a finger has: the X follows the page a frame late.
    await create_timer(0.3).timeout
    if touch:
        var x: Control = main.touch_ui.close_button
        check(x.visible, "the X is up on %s" % menu.page)
        if x.visible: await tap_point(screen_rect(x).get_center())
        return
    await key(KEY_ESCAPE)

func tap_point(point: Vector2) -> void:
    for pressed in [true, false]:
        var event := InputEventScreenTouch.new()
        event.position = root.get_final_transform() * point
        event.pressed = pressed
        await inject(event)
    await _frames(3)

## A tap on a row's caption, left of its value (PLAYERS has - and + on the right).
func tap_caption(row: Control) -> void:
    check(row.is_visible_in_tree(), "tappable: %s" % row.get_path())
    await tap_point(row.get_global_transform_with_canvas() * Vector2(16, row.size.y / 2.0))

## Where a control is on the 320 (or wider) x 180 screen, whatever canvas layer it is in.
func screen_rect(control: Control) -> Rect2:
    return control.get_global_transform_with_canvas() * Rect2(Vector2.ZERO, control.size)

func title() -> String:
    return menu.panel.get_node("Title").text

func listed() -> Array:
    var names := []
    for row in menu.rows:
        if row.visible: names.append(row.text)
    return names

func values() -> Array:
    return menu.host_values.map(func(l): return l.text)

## Title, the line under it, no A/B hints on touch, and every visible row a finger-sized
## target inside the panel, clear of the X.
func page_checks(what: String) -> void:
    await _frames(3)
    var panel: Rect2 = screen_rect(menu.panel)
    var screen: Rect2 = Rect2(Vector2.ZERO, main.get_viewport().get_visible_rect().size)
    check(screen.encloses(panel), "%s: the panel is on screen: %s" % [what, panel])
    check(not title().is_empty(), "%s has a title" % what)
    if not menu._typing() and menu.page != "server_form":
        check(menu.blurb.visible and not menu.blurb.text.is_empty(), "%s says what it is for" % what)
        var font: Font = menu.blurb.get_theme_font("font")
        var width := font.get_string_size(menu.blurb.text, HORIZONTAL_ALIGNMENT_LEFT, -1, menu.blurb.get_theme_font_size("font_size")).x
        check(width <= menu.blurb.size.x and panel.encloses(screen_rect(menu.blurb)), "%s: the line under the title fits the panel: %s %d" % [what, menu.blurb.text, width])
        var first: Label = menu.rows[0]
        # The labels' boxes are taller than their glyphs, which sit at the top: 7 px of ink.
        if first.visible: check(menu.blurb.position.y + 7 <= first.position.y, "%s: the line under the title is above the rows: %s %s" % [what, menu.blurb.position, first.position])
    var x: Control = main.touch_ui.close_button
    if touch:
        check(x.visible, "%s: the X is up" % what)
        check(not screen_rect(x).intersects(panel), "%s: the X %s is clear of the panel %s" % [what, screen_rect(x), panel])
    var targets: Array = []
    for row in menu.rows + menu.form_rows:
        if row.is_visible_in_tree(): targets.append(row)
    for extra in menu.edit_tags + [menu.step_minus, menu.step_plus] + menu.trash_bins:
        if extra.is_visible_in_tree(): targets.append(extra)
    for target: Control in targets:
        var rect := screen_rect(target)
        check(panel.encloses(rect), "%s: %s inside the panel" % [what, target.name])
        check(rect.size.y >= 12 and rect.size.x >= 12, "%s: %s is big enough to tap: %s" % [what, target.name, rect.size])
        check(target.mouse_filter == Control.MOUSE_FILTER_STOP, "%s: %s takes taps" % [what, target.name])
    var hints := []
    for label: Label in menu.find_children("*", "Label", true, false):
        if not label.is_visible_in_tree(): continue
        for part in label.text.split("\n"):
            if part.begins_with("A: ") or part.begins_with("B: ") or " B: " in part: hints.append(part)
    if touch: check(hints.is_empty(), "%s shows no A/B hint on touch: %s" % [what, hints])
    elif menu.page not in ["connecting", "loading"]: check(not hints.is_empty(), "%s shows its A/B hint on a keyboard" % what)

func stub_lobbies(found: Array) -> void:
    var typed: Array[Dictionary] = []
    typed.assign(found)
    menu._refresh_at = Time.get_ticks_msec() + 600000 # the real lobby list stays out of it
    menu.lobbies = typed
    menu.refresh()

func reopen(page: String) -> void:
    main.coop_game.cancel_join()
    menu.open()
    menu._go("multi")
    menu.selection = {"browse": 0, "host": 1, "servers": 2}[page]
    menu.activate()
    await _frames(2)

func shot(file: String) -> void:
    var args := OS.get_cmdline_user_args()
    if DisplayServer.get_name() == "headless" or args.find("--shots") < 0 or args.find("--shots") + 1 >= args.size(): return
    var folder: String = args[args.find("--shots") + 1]
    DirAccess.make_dir_recursive_absolute(folder)
    await _frames(3)
    await RenderingServer.frame_post_draw
    root.get_texture().get_image().save_png(folder.path_join(file))

func remove_dir(path: String) -> void:
    for sub in DirAccess.get_directories_at(path): remove_dir(path.path_join(sub))
    for file in DirAccess.get_files_at(path): DirAccess.remove_absolute(path.path_join(file))
    DirAccess.remove_absolute(path)

func _initialize() -> void:
    create_timer(600.0).timeout.connect(func(): printerr("COOP MENU FLOW TEST FAIL: timed out"); quit(2))
    var dir := OS.get_temp_dir().path_join("coop_menu_flow_test_%d" % Time.get_ticks_usec())
    DirAccess.make_dir_recursive_absolute(dir)
    FileAccess.open(dir.path_join(".private-saves-migrated"), FileAccess.WRITE).close()
    Paths.directory = dir
    # A fixed compat id, so another server's id is told apart as in an official build.
    OS.set_environment("POKEWILDS_COMPAT_ID", "flow-compat-a")
    change_scene_to_file("res://scenes/main.tscn")
    await _frames(30)
    main = current_scene
    while not main.startup_complete: await process_frame
    menu = main.coop_menu
    menu.chosen.connect(func(action, value): chosen.append([action, value]))
    check(main.touch_on() == touch, "touch_on matches --touch-ui")

    # --- the map: title -> CO-OP -> each page and back ------------------------
    menu.open()
    await _frames(3)
    check(menu.page == "title", "the menu opens on the title")
    await tap(menu.title_rows[1])
    check(menu.page == "multi" and title() == "CO-OP", "CO-OP opens: %s" % menu.page)
    check(listed() == ["JOIN A GAME", "HOST A GAME", "MY SERVERS"], "CO-OP's rows: %s" % [listed()])
    await page_checks("CO-OP")
    var blurbs := []
    for i in 3:
        menu.selection = i; menu.refresh()
        blurbs.append(menu.blurb.text)
    check(blurbs.size() == 3 and blurbs[0] != blurbs[1] and blurbs[1] != blurbs[2], "each CO-OP row explains itself: %s" % [blurbs])
    for pair in [[0, "browse", "JOIN A GAME"], [1, "host", "HOST A GAME"], [2, "servers", "MY SERVERS"]]:
        await tap(menu.rows[pair[0]])
        check(menu.page == pair[1] and title() == pair[2], "%s opens: %s %s" % [pair[2], menu.page, title()])
        await page_checks(pair[2])
        await back()
        check(menu.page == "multi", "back from %s to CO-OP: %s" % [pair[2], menu.page])
    await back()
    check(menu.page == "title", "back from CO-OP to the title: %s" % menu.page)
    # The controller walks it too.
    menu._go("multi")
    await pad("move_down")
    await pad("confirm")
    check(menu.page == "host", "D-pad down and A open HOST A GAME: %s" % menu.page)
    await pad("cancel")
    check(menu.page == "multi", "B goes back: %s" % menu.page)

    # --- HOST A GAME -----------------------------------------------------------
    var coop: Node = main.coop_game
    var cap: int = menu.max_players_cap()
    var declared = (Session as Script).get_script_constant_map().get("MAX_PLAYERS")
    check(cap == (int(declared) if declared != null else 8), "the cap is coop_session.gd's MAX_PLAYERS (8 without it): %d" % cap)
    check(cap >= 4, "the cap allows at least the old 4: %d" % cap)
    coop.max_players = 4
    coop.lobby_private = true; coop.lobby_password = "stale"
    await reopen("host")
    check(menu.page == "host" and listed() == ["WORLD", "ACCESS", "PLAYERS", "NEXT"], "HOST A GAME's rows: %s" % [listed()])
    check(values().slice(0, 3) == ["NEW", "PUBLIC", "4"], "a fresh setup: new, public, 4: %s" % [values()])
    check(not coop.lobby_private and coop.lobby_password == "", "a fresh setup drops an old password")
    await page_checks("HOST A GAME")
    # PLAYERS: + and - step and stop at the ends; a tap on the row goes round.
    for i in cap + 2: await tap(menu.step_plus)
    check(coop.max_players == cap and values()[2] == str(cap), "+ stops at the cap: %d" % coop.max_players)
    for i in cap + 2: await tap(menu.step_minus)
    check(coop.max_players == 2 and values()[2] == "2", "- stops at 2: %d" % coop.max_players)
    await tap_caption(menu.rows[2])
    check(coop.max_players == 3 and menu.selection == 2, "a tap on PLAYERS adds one: %d" % coop.max_players)
    coop.max_players = cap; menu.refresh()
    await tap_caption(menu.rows[2])
    check(coop.max_players == 2, "past the cap a tap goes back to 2: %d" % coop.max_players)
    await pad("move_right")
    await pad("move_right")
    check(coop.max_players == 4 and menu.selection == 2, "right on PLAYERS adds: %d" % coop.max_players)
    await pad("move_left")
    check(coop.max_players == 3, "left on PLAYERS takes away: %d" % coop.max_players)
    menu._set_max_players(99)
    check(coop.max_players == cap, "a count above the cap is clamped: %d" % coop.max_players)
    menu._set_max_players(-5)
    check(coop.max_players == 2, "a count below 2 is clamped: %d" % coop.max_players)
    menu._set_max_players(6 if cap >= 6 else cap)
    var wanted: int = coop.max_players
    # WORLD: NEW <-> SAVED, by tap and by left / right.
    await tap(menu.rows[0])
    check(values()[0] == "SAVED" and menu.selection == 0, "a tap on WORLD picks SAVED: %s" % [values()])
    await pad("move_left")
    check(values()[0] == "NEW", "left on WORLD goes back to NEW: %s" % [values()])
    # ACCESS: PRIVATE asks for the password; BACK leaves it public.
    await tap(menu.rows[1])
    check(menu.page == "password_set" and title() == "SET A PASSWORD", "PRIVATE asks for a password: %s" % menu.page)
    await page_checks("SET A PASSWORD")
    await back()
    check(menu.page == "host" and menu.selection == 1 and not coop.lobby_private and values()[1] == "PUBLIC", "back from the password: still public, on ACCESS")
    await tap(menu.rows[1])
    for character in "pikachu": await key(character.to_upper().unicode_at(0), character.unicode_at(0))
    if menu.type_ok.visible: await tap(menu.type_ok)
    else: await key(KEY_ENTER)
    check(menu.page == "host" and menu.selection == 1 and coop.lobby_private and coop.lobby_password == "pikachu" and values()[1] == "PRIVATE", "a password makes it PRIVATE: %s %s" % [menu.page, values()])
    await tap(menu.rows[1])
    check(menu.page == "host" and not coop.lobby_private and coop.lobby_password == "", "a tap on PRIVATE makes it public again")
    await tap(menu.rows[1])
    for character in "pw": await key(character.to_upper().unicode_at(0), character.unicode_at(0))
    await key(KEY_ENTER)
    check(coop.lobby_private and coop.lobby_password == "pw", "private again")
    # NEXT with SAVED: SAVED WORLDS, empty here; back lands on NEXT.
    await tap(menu.rows[0])
    menu.selection = 3; menu.refresh()
    check(menu.blurb.text == "NEXT: PICK THE SAVED WORLD.", "NEXT says where it goes: %s" % menu.blurb.text)
    chosen.clear()
    await tap(menu.rows[3])
    await _frames(5)
    check(chosen == [["LIST", ""]] and menu.page == "load" and title() == "SAVED WORLDS", "NEXT with SAVED lists the saved worlds: %s %s" % [chosen, menu.page])
    check(menu.empty.visible and menu.empty.text == menu.EMPTY_WORLDS, "no saved worlds: the empty text says what to do")
    await page_checks("SAVED WORLDS")
    await shot_page("saved_worlds_empty")
    await back()
    check(menu.page == "host" and menu.selection == 3 and values()[0] == "SAVED", "back from SAVED WORLDS to NEXT: %s %d" % [menu.page, menu.selection])
    check(coop.max_players == wanted and coop.lobby_private, "the setup is kept: %d" % coop.max_players)
    # NEXT with NEW: the world setup screen, with the count and password set for hosting.
    await tap(menu.rows[0])
    chosen.clear()
    await tap(menu.rows[3])
    await _frames(5)
    check(chosen == [["SETUP", ""]] and not menu.visible and main.setup_panel.visible, "NEXT with NEW opens the world setup: %s" % [chosen])
    check(coop.max_players == wanted and coop.lobby_private and coop.lobby_password == "pw", "hosting gets PLAYERS and the password: %d" % coop.max_players)

    # --- JOIN A GAME -------------------------------------------------------------
    var mods: String = menu._my_mods()
    var found := [
        {"kind": "game", "name": "Ash's world", "host": "Ash", "address": "10.1.0.1", "port": 54555, "players": 1, "max": 4, "private": false, "salt": "", "protocol": Session.PROTOCOL, "mods": mods},
        {"kind": "game", "name": "Full house", "host": "Misty", "address": "10.1.0.2", "port": 54555, "players": 4, "max": 4, "private": true, "salt": "s", "protocol": Session.PROTOCOL, "mods": mods},
        {"kind": "server", "name": "Kanto server", "host": "", "address": "203.0.113.5", "port": 54600, "players": 2, "max": 8, "private": false, "salt": "", "protocol": Session.PROTOCOL, "mods": mods, "version": "0.10.999", "compat": Session.compat_id(), "accounts": false},
        {"kind": "server", "name": "Old server", "host": "", "address": "203.0.113.6", "port": 54601, "players": 0, "max": 6, "private": true, "salt": "k", "protocol": Session.PROTOCOL, "mods": mods, "version": "0.9.1", "compat": "another-compat", "accounts": false}]
    await reopen("browse")
    stub_lobbies([])
    check(menu.page == "browse" and title() == "JOIN A GAME", "JOIN A GAME opens")
    check(menu.empty.visible and menu.empty.text == menu.EMPTY_LOBBIES and "HOST A GAME" in menu.empty.text and "MY SERVERS" in menu.empty.text, "an empty list says how to host or add a server: %s" % menu.empty.text)
    await page_checks("JOIN A GAME (empty)")
    await shot_page("join_empty")
    stub_lobbies(found)
    check(not menu.empty.visible and listed() == ["ASH'S WORLD", "FULL HOUSE", "KANTO SERVER", "OLD SERVER"], "games and servers in one list: %s" % [listed()])
    var lines: Array = menu.ping_labels.map(func(l): return l.text)
    var colors: Dictionary = menu.PING_COLORS
    check(lines[0] == "GAME BY ASH  1/4" and menu.ping_labels[0].modulate == colors.grey, "a game shows its host and players: %s" % lines[0])
    check(lines[1] == "GAME BY MISTY  4/4  PRIVATE", "a private game says so: %s" % lines[1])
    check(lines[2] == "SERVER  2/8  V0.10.999" and menu.ping_labels[2].modulate == colors.green, "a server that lets this copy in is green with its version: %s" % lines[2])
    check(lines[3] == "SERVER  0/6  V0.9.1  PRIVATE" and menu.ping_labels[3].modulate == colors.red, "another version is red: %s" % lines[3])
    check(not menu.edit_tags[0].visible and not menu.edit_tags[1].visible, "games have no SAVE tag")
    check(menu.edit_tags[2].visible and menu.edit_tags[2].text == "SAVE" and menu.edit_tags[3].text == "SAVE", "servers offer SAVE")
    await page_checks("JOIN A GAME")
    await shot_page("join_list")
    # A full game is refused with a reason.
    chosen.clear()
    await tap(menu.rows[1])
    check(menu.page == "browse" and chosen.is_empty() and "FULL" in menu.status.text, "a full game says so: %s" % menu.status.text)
    # SAVE keeps a server in MY SERVERS, once.
    await tap(menu.edit_tags[2])
    var saved: Array = Saved.load_all()
    check(saved.size() == 1 and saved[0].name == "Kanto server" and saved[0].address == "203.0.113.5:54600", "SAVE stores the server: %s" % [saved])
    check(menu.edit_tags[2].text == "SAVED" and "MY SERVERS" in menu.status.text, "the tag says SAVED: %s" % menu.status.text)
    await tap(menu.edit_tags[2])
    check(Saved.load_all().size() == 1 and "ALREADY" in menu.status.text, "a second SAVE adds nothing: %s" % menu.status.text)
    # START / E saves the selected server on a controller or keyboard.
    menu.selection = 3; menu.refresh()
    await key(KEY_E)
    check(Saved.load_all().size() == 2 and menu.edit_tags[3].text == "SAVED", "E saves the selected server")
    # A server is joined directly at its address and port, like MY SERVERS.
    chosen.clear()
    await tap(menu.rows[2])
    var joining: Dictionary = coop.join_lobby
    check(chosen == [["JOIN_SETUP", "203.0.113.5"]], "tapping a server joins it: %s" % [chosen])
    check(joining.get("direct") == true and int(joining.port) == 54600 and joining.account_id == "" and joining.kind == "server", "a listed server is joined directly: %s" % [joining])
    # A refusal returns to the list, never to MY SERVERS.
    await reopen("browse")
    stub_lobbies(found)
    menu.show_connecting("CONNECTING...")
    menu.connecting_failed("SERVER IS FULL")
    check(menu.page == "browse" and "SERVER IS FULL" in menu.status.text, "a refused listed server returns to the list: %s" % menu.page)
    # A private server asks for its password; back returns to the list.
    stub_lobbies(found)
    await tap(menu.rows[3])
    check(menu.page == "password_join" and coop.join_lobby.get("direct") == true, "a private server asks for the password: %s" % menu.page)
    await page_checks("ENTER PASSWORD")
    await shot_page("password_join")
    await back()
    check(menu.page == "browse", "back from its password to the list: %s" % menu.page)
    # A game is joined through the lobby network as before.
    stub_lobbies(found)
    chosen.clear()
    await tap(menu.rows[0])
    check(chosen == [["JOIN_SETUP", "10.1.0.1"]] and coop.join_lobby.get("direct", false) == false, "a game joins as before: %s" % [chosen])
    # A server with player accounts goes through the login form, then is saved and joined.
    await reopen("browse")
    stub_lobbies([{"kind": "server", "name": "Login server", "host": "", "address": "203.0.113.9", "port": 54700, "players": 3, "max": 8, "private": false, "salt": "", "protocol": Session.PROTOCOL, "mods": mods, "version": "0.10.999", "compat": Session.compat_id(), "accounts": true}])
    check(menu.ping_labels[0].text == "SERVER  3/8  V0.10.999  LOGIN", "a login server says LOGIN: %s" % menu.ping_labels[0].text)
    await shot_page("join_login_server")
    chosen.clear()
    await tap(menu.rows[0])
    check(menu.page == "server_form" and menu._draft.address == "203.0.113.9:54700" and menu.selection == 2 and menu.form_rows[4].text == "SAVE AND JOIN", "a login server opens the login form on PLAYER ID: %s %s" % [menu.page, menu._draft])
    await page_checks("login form")
    await back()
    check(menu.page == "browse", "back from the login form to the list: %s" % menu.page)

    # --- MY SERVERS ---------------------------------------------------------------
    Saved.save_all([] as Array[Dictionary])
    await reopen("servers")
    check(menu.page == "servers" and menu.empty.visible and listed() == ["ADD SERVER"], "MY SERVERS empty: ADD SERVER and the hint")
    await page_checks("MY SERVERS (empty)")
    await shot_page("servers_empty")
    Saved.save_all([{"name": "Kanto server", "address": "203.0.113.5:54600", "id": "ash", "password": "x"},
        {"name": "Home", "address": "127.0.0.1:1", "id": "", "password": ""}] as Array[Dictionary])
    await reopen("servers")
    await page_checks("MY SERVERS")
    await shot_page("servers")
    await tap(menu.edit_tags[0])
    check(menu.page == "server_form" and title() == "EDIT SERVER", "EDIT opens the form")
    await page_checks("EDIT SERVER")
    await shot_page("server_form")
    await tap(menu.form_rows[1])
    check(menu.page == "server_text", "a field opens for typing")
    await page_checks("typing")
    await shot_page("server_text")
    await back()
    await back()
    await back()
    check(menu.page == "multi", "MY SERVERS backs out to CO-OP: %s" % menu.page)

    # --- screenshots of the rest, both widths, light and dark ------------------
    if DisplayServer.get_name() != "headless":
        for width in [320, 390]:
            root.size = Vector2i(width * 4, 720)
            await create_timer(0.7).timeout
            main.touch_controls._refresh_display_layout() # what a phone's safe-area poll does
            await _frames(3)
            for dark in [false, true]:
                Settings.change("dark_mode", dark)
                main._apply_game_options()
                var tag := "%d_%s" % [width, "dark" if dark else "light"]
                menu.open(); await _frames(10)
                await shot("title_%s.png" % tag)
                menu._go("multi"); menu.selection = 1; menu.refresh()
                await page_checks("CO-OP at %s" % tag)
                await shot("coop_%s.png" % tag)
                await reopen("host")
                coop.lobby_private = true; menu.selection = 2; menu.refresh()
                await page_checks("HOST A GAME at %s" % tag)
                await shot("host_%s.png" % tag)
                await reopen("browse")
                stub_lobbies(found)
                await page_checks("JOIN A GAME at %s" % tag)
                await shot("join_%s.png" % tag)
                await reopen("servers")
                await shot("servers_%s.png" % tag)
                if not dark:
                    await reopen("host")
                    menu._go("password_set")
                    await shot("password_set_%s.png" % tag)
                    await reopen("browse")
                    stub_lobbies([])
                    await shot("join_empty_%s.png" % tag)
                    stub_lobbies(found)
                    await tap(menu.rows[3])
                    await page_checks("ENTER PASSWORD at %s" % tag)
                    await shot("password_join_%s.png" % tag)
                    await reopen("host")
                    menu.selection = 3; menu._host_world = "SAVED"; menu.activate()
                    await _frames(5)
                    await page_checks("SAVED WORLDS at %s" % tag)
                    await shot("saved_worlds_%s.png" % tag)
                    await reopen("servers")
                    await tap(menu.edit_tags[0])
                    await page_checks("EDIT SERVER at %s" % tag)
                    await shot("server_form_%s.png" % tag)
                    await tap(menu.form_rows[1])
                    await page_checks("typing at %s" % tag)
                    await shot("server_text_%s.png" % tag)
        Settings.change("dark_mode", false)
        main._apply_game_options()
        root.size = Vector2i(1280, 720)

    remove_dir(dir)
    print("COOP MENU FLOW TEST (%s): %d checks, %d failed" % ["touch" if touch else "keyboard", checks, failed])
    quit(1 if failed > 0 else 0)

func shot_page(name: String) -> void:
    await shot("%s.png" % name)
