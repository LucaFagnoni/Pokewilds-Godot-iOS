# MY SERVERS (the saved dedicated servers in MULTIPLAYER), driven the way a phone drives it:
# taps on the real row and field labels and key presses for typing, on a throwaway data folder.
# Run: godot --headless --path project -s <this file> -- --touch-ui
extends SceneTree

const Paths = preload("res://scripts/game_data_paths.gd")
const Saved = preload("res://scripts/coop_saved_servers.gd")

var main: Node
var menu: Control
var checks := 0
var failed := 0
var joins: Array = []
var dir := ""

func check(ok: bool, what: String) -> void:
    checks += 1
    if not ok:
        failed += 1
        printerr("SAVED SERVERS TEST FAIL: ", what)

func _frames(count: int) -> void:
    for i in count: await process_frame

func inject(event: InputEvent) -> void:
    Input.parse_input_event(event)
    await _frames(2)

## A finger tap on the middle of a control.
func tap(control: Control) -> void:
    check(control.is_visible_in_tree(), "tappable: %s" % control.get_path())
    var at: Vector2 = root.get_final_transform() * (control.get_global_transform_with_canvas() * (control.size / 2.0))
    for pressed in [true, false]:
        var touch := InputEventScreenTouch.new()
        touch.position = at
        touch.pressed = pressed
        await inject(touch)
    await _frames(3)

func key(keycode: int, unicode: int = 0) -> void:
    for pressed in [true, false]:
        var event := InputEventKey.new()
        event.keycode = keycode
        event.unicode = unicode
        event.pressed = pressed
        await inject(event)

## The controller button mapped to an action (A/B swap with the button layout option).
func pad(action: String) -> void:
    var source: InputEventJoypadButton
    for mapped in InputMap.action_get_events(action):
        if mapped is InputEventJoypadButton: source = mapped
    check(source != null, "a controller button is mapped to %s" % action)
    if source == null: return
    for pressed in [true, false]:
        var event := InputEventJoypadButton.new()
        event.button_index = source.button_index
        event.pressed = pressed
        await inject(event)

func type_text(text: String) -> void:
    for character in text:
        await key(character.to_upper().unicode_at(0), character.unicode_at(0))

## Taps a form row, replaces its text, and confirms with OK (or Enter when there is no OK button).
func fill(row: int, text: String) -> void:
    await tap(menu.form_rows[row])
    check(menu.page == "server_text", "typing page for form row %d" % row)
    for i in menu.buffer.length(): await key(KEY_BACKSPACE)
    await type_text(text)
    check(menu.buffer == text, "typed text %s is %s" % [text, menu.buffer])
    if menu.type_ok.visible: await tap(menu.type_ok)
    else: await key(KEY_ENTER)
    check(menu.page == "server_form", "back on the form after row %d" % row)

func stored() -> Array:
    var parsed = JSON.parse_string(FileAccess.get_file_as_string(Paths.path(Saved.FILE)))
    return parsed.servers if parsed is Dictionary and parsed.get("servers") is Array else []

func listed() -> Array:
    var names := []
    for row in menu.rows:
        if row.visible: names.append(row.text)
    return names

func boot() -> void:
    change_scene_to_file("res://scenes/main.tscn")
    await _frames(30)
    main = current_scene
    while not main.startup_complete: await process_frame
    menu = main.coop_menu
    joins.clear()
    menu.chosen.connect(func(action, value): joins.append([action, value]))

## From the start menu to the MY SERVERS list by tapping MY SERVERS.
func open_servers() -> void:
    main.coop_game.cancel_join()
    menu.open()
    menu._go("multi")
    await tap(menu.rows[2])
    check(menu.page == "servers", "MY SERVERS opens")

func add_server(server: Dictionary) -> void:
    await tap(menu.rows[menu.servers.size()])
    check(menu.page == "server_form", "ADD SERVER opens the form")
    await fill(0, server.name)
    await fill(1, server.address)
    await fill(2, server.id)
    await fill(3, server.password)
    await tap(menu.form_rows[4])
    check(menu.page == "servers", "SAVE returns to the list")

## The JOIN GAME list with one LAN lobby that uses accounts (set directly: no beacon is opened).
func show_lobbies() -> void:
    menu.page = "browse"
    menu._refresh_at = Time.get_ticks_msec() + 600000
    var found: Array[Dictionary] = [{"name": "LAN fun", "address": "192.168.1.77", "port": 54600, "players": 1, "max": 4, "private": false, "salt": "", "accounts": true}]
    menu.lobbies = found
    menu.refresh()

func remove_dir(path: String) -> void:
    for sub in DirAccess.get_directories_at(path): remove_dir(path.path_join(sub))
    for file in DirAccess.get_files_at(path): DirAccess.remove_absolute(path.path_join(file))
    DirAccess.remove_absolute(path)

func _initialize() -> void:
    # Never the player's real data: a private folder, marked as already migrated.
    dir = OS.get_temp_dir().path_join("saved_servers_test_%d" % Time.get_ticks_usec())
    DirAccess.make_dir_recursive_absolute(dir)
    FileAccess.open(dir.path_join(".private-saves-migrated"), FileAccess.WRITE).close()
    Paths.directory = dir
    await boot()

    # 1. Add a server: name, address, player ID and password.
    await open_servers()
    check(menu.servers.is_empty() and listed() == ["ADD SERVER"], "starts with an empty list")
    check(menu.empty.visible, "the empty list shows its hint")
    await add_server({"name": "Home", "address": "192.168.1.50:54556", "id": "ash_01", "password": "secret"})
    check(listed() == ["HOME", "ADD SERVER"], "the new server is listed: %s" % [listed()])
    var saved := stored()
    check(saved.size() == 1 and saved[0] == {"name": "Home", "address": "192.168.1.50:54556", "id": "ash_01", "password": "secret"}, "the file holds the server: %s" % [saved])
    check(not FileAccess.file_exists(Paths.path(Saved.FILE) + ".pending"), "no .pending file is left behind")

    # A bad address is refused by OK and by SAVE, and the form stays open.
    await tap(menu.rows[1])
    await fill(0, "Bad")
    await tap(menu.form_rows[1])
    await type_text("bad host name")
    if menu.type_ok.visible: await tap(menu.type_ok)
    else: await key(KEY_ENTER)
    check(menu.page == "server_text", "an invalid address is not accepted by OK")
    if menu.type_back.visible: await tap(menu.type_back)
    else: await key(KEY_ESCAPE)
    check(menu.page == "server_form" and menu._draft.address == "", "BACK while typing drops the typed text")
    await tap(menu.form_rows[4])
    check(menu.page == "server_form" and stored().size() == 1, "SAVE without an address stays on the form")
    await tap(menu.form_rows[5])
    check(menu.page == "servers" and menu.servers.size() == 1, "BACK returns to the list without saving")

    # 2. Edit it: change the name and the password.
    await tap(menu.edit_tags[0])
    check(menu.page == "server_form" and menu._edit == 0, "EDIT opens the saved server")
    check(menu.form_rows[3].get_node("Value").text == "******", "the password shows as asterisks")
    await fill(0, "Home 2")
    await fill(3, "newpass")
    await tap(menu.form_rows[4])
    check(listed() == ["HOME 2", "ADD SERVER"], "the edit shows in the list: %s" % [listed()])
    saved = stored()
    check(saved.size() == 1 and saved[0].name == "Home 2" and saved[0].password == "newpass" and saved[0].id == "ash_01" and saved[0].address == "192.168.1.50:54556", "the file holds the edit: %s" % [saved])

    # 3. Add a second one, then delete the first.
    await add_server({"name": "Lab", "address": "my.host.net", "id": "", "password": "shared"})
    check(listed() == ["HOME 2", "LAB", "ADD SERVER"], "both are listed: %s" % [listed()])
    check(stored().size() == 2, "the file holds two servers")
    await tap(menu.edit_tags[0])
    await tap(menu.form_rows[5])
    check(menu.page == "server_form" and menu.form_rows[5].text == "SURE?" and stored().size() == 2, "DELETE asks once more")
    await tap(menu.form_rows[5])
    check(menu.page == "servers" and listed() == ["LAB", "ADD SERVER"], "the first server is gone from the list: %s" % [listed()])
    saved = stored()
    check(saved.size() == 1 and saved[0].name == "Lab", "the file holds only the second server: %s" % [saved])

    # 4. Restart: a new scene and a fresh read of the file.
    await boot()
    await open_servers()
    check(listed() == ["LAB", "ADD SERVER"], "the list survives a restart: %s" % [listed()])
    check(menu.servers == [{"name": "Lab", "address": "my.host.net", "id": "", "password": "shared"}], "its fields survive a restart")

    # 5. Tapping a row joins: no player ID, so the password is the shared server password.
    await tap(menu.rows[0])
    check(joins == [["JOIN_SETUP", "my.host.net"]], "tapping a row emits JOIN_SETUP: %s" % [joins])
    var lobby: Dictionary = main.coop_game.join_lobby
    check(lobby == {"name": "Lab", "address": "my.host.net", "port": 54555, "direct": true, "private": false, "salt": "", "account_id": "", "account_password": "shared"}, "join_lobby without an ID: %s" % [lobby])
    check(main.coop_game.join_password == "shared", "the shared server password is sent without an ID")

    # ...and with a player ID the account password goes through instead.
    joins.clear()
    await open_servers()
    await add_server({"name": "Ranked", "address": "127.0.0.1:59999", "id": "ash_01", "password": "pw1"})
    await tap(menu.rows[1])
    check(joins == [["JOIN_SETUP", "127.0.0.1"]], "the second server joins: %s" % [joins])
    lobby = main.coop_game.join_lobby
    check(lobby.address == "127.0.0.1" and lobby.port == 59999 and lobby.account_id == "ash_01" and lobby.account_password == "pw1" and lobby.direct == true and lobby.name == "Ranked", "join_lobby with an ID: %s" % [lobby])
    check(main.coop_game.join_password == "", "no shared password is sent with an ID")

    # A refusal naming the password reopens that server's form, anything else the list.
    menu.show_connecting("CONNECTING...")
    menu.connecting_failed("WRONG PASSWORD")
    check(menu.page == "server_form" and menu._edit == 1 and menu.selection == 3 and "WRONG PASSWORD" in menu.status.text, "a password refusal reopens the form: %s %s" % [menu.page, menu.status.text])
    await tap(menu.form_rows[6])
    check(menu.page == "servers" and menu.selection == 1, "BACK from the form returns to the list on that server")
    await tap(menu.rows[1])
    menu.show_connecting("CONNECTING...")
    menu.connecting_failed("UNKNOWN PLAYER ID")
    check(menu.page == "server_form" and menu.selection == 2, "an ID refusal opens the form on PLAYER ID: %s %d" % [menu.page, menu.selection])
    await tap(menu.form_rows[6])
    menu.show_connecting("CONNECTING...")
    menu.connecting_failed("SERVER NOT FOUND")
    check(menu.page == "servers" and "SERVER NOT FOUND" in menu.status.text, "another refusal returns to the list: %s" % menu.page)
    menu.show_connecting("CONNECTING...")
    var cancel := InputEventKey.new()
    cancel.keycode = KEY_ESCAPE
    cancel.pressed = true
    await inject(cancel)
    check(menu.page == "servers", "B while connecting returns to the list: %s" % menu.page)

    # Controller: D-pad moves, Start edits, B goes back, A joins.
    await pad("move_down")
    check(menu.page == "servers" and menu.selection == 1, "D-pad down moves the cursor: %d" % menu.selection)
    await pad("start")
    check(menu.page == "server_form" and menu._edit == 1, "Start edits the selected server: %s" % menu.page)
    await pad("cancel")
    check(menu.page == "servers" and menu.selection == 1, "B leaves the form for the list")
    await key(KEY_E)
    check(menu.page == "server_form" and menu._edit == 1, "E edits the selected server on a keyboard")
    await pad("cancel")
    joins.clear()
    await pad("confirm")
    check(joins == [["JOIN_SETUP", "127.0.0.1"]], "A joins the selected server: %s" % [joins])
    await open_servers()

    # A long list scrolls by tapping the arrow areas.
    for i in 4: menu.servers.append(Saved.clean({"name": "Extra %d" % i, "address": "10.0.0.%d" % i}))
    menu._go("servers")
    check(menu.page_down.visible and not menu.page_up.visible and menu.counter.text == "1/7", "a long list shows its down arrow: %s" % menu.counter.text)
    var first: String = menu.rows[0].text
    await tap(menu.page_down)
    check(menu.page_up.visible and menu.rows[0].text != first and menu._scroll == 1, "tapping the down arrow scrolls the list")
    await tap(menu.page_up)
    check(menu.rows[0].text == first and menu._scroll == 0, "tapping the up arrow scrolls back")
    menu.servers = Saved.load_all()

    # A LAN lobby with player accounts opens the form prefilled; SAVE AND JOIN joins it.
    show_lobbies()
    joins.clear()
    await tap(menu.rows[0])
    check(menu.page == "server_form" and menu._edit == -1 and menu._draft.name == "LAN fun" and menu._draft.address == "192.168.1.77:54600" and menu.selection == 2, "an accounts lobby opens the prefilled form: %s" % [menu._draft])
    check(menu.form_rows[4].text == "SAVE AND JOIN", "SAVE AND JOIN is offered")
    await fill(2, "misty")
    await fill(3, "lanpass")
    await tap(menu.form_rows[4])
    check(joins == [["JOIN_SETUP", "192.168.1.77"]], "SAVE AND JOIN joins: %s" % [joins])
    lobby = main.coop_game.join_lobby
    check(lobby.port == 54600 and lobby.account_id == "misty" and lobby.account_password == "lanpass", "the lobby is joined with its account: %s" % [lobby])
    check(stored().size() == 3 and stored()[2].address == "192.168.1.77:54600", "the lobby server was saved: %s" % [stored()])
    # The same lobby again is joined straight from the saved entry.
    main.coop_game.cancel_join()
    menu.open()
    show_lobbies()
    joins.clear()
    await tap(menu.rows[0])
    check(joins == [["JOIN_SETUP", "192.168.1.77"]] and stored().size() == 3, "a saved accounts lobby joins without the form: %s" % [joins])

    # The old "last address" becomes a first entry.
    var legacy := ConfigFile.new()
    legacy.set_value("join", "address", "old.example.org:5000")
    legacy.set_value("join", "password", "oldpass")
    DirAccess.remove_absolute(Paths.path(Saved.FILE))
    legacy.save(Paths.path(Saved.LEGACY_FILE))
    check(Saved.load_all() == [{"name": "old.example.org:5000", "address": "old.example.org:5000", "id": "", "password": "oldpass"}], "coop_direct.cfg migrates into one entry")
    check(stored().size() == 1, "the migrated entry is written to the file")

    remove_dir(dir)
    print("SAVED SERVERS TEST: %d checks, %d failed" % [checks, failed])
    quit(1 if failed > 0 else 0)
