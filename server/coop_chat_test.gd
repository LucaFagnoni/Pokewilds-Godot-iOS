# World chat (coop_chat.gd): the sanitiser on hostile text; a host and two
# guests on this machine passing chat through real sessions (names from the
# session, hostile packets cleaned, spam dropped by the rate limit); and the
# chat on a touch screen in a real game, clear of the HUD: its button in the
# top row between the battery and the menu button, with a red dot for unread
# messages, and the newest message centred under the clock (or the notice) for
# a few seconds, at 320 and 390 px wide.
# Run: godot --headless --path project -s ../server/coop_chat_test.gd -- --touch-ui
# Run it windowed (no --headless) to also save screenshots into CHAT_SHOTS
# (an environment variable; the system temp folder's chat_ui otherwise).
extends SceneTree

const Chat = preload("res://scripts/coop_chat.gd")
const Session = preload("res://scripts/coop_session.gd")
const Paths = preload("res://scripts/game_data_paths.gd")
const Hud = preload("res://scripts/hud_style.gd")

var main: Node
var checks := 0
var failed := 0

func check(ok: bool, what: String) -> void:
    checks += 1
    if not ok:
        failed += 1
        printerr("COOP CHAT TEST FAIL: ", what)

func _frames(count: int) -> void:
    for i in count: await process_frame

func _initialize() -> void:
    create_timer(600.0).timeout.connect(func(): printerr("COOP CHAT TEST FAIL: timed out"); quit(2))
    _sanitiser()
    await _network()
    await _touch_screen()
    print("COOP CHAT TEST: %d checks, %d failed" % [checks, failed])
    quit(1 if failed > 0 else 0)

# --- the sanitiser ----------------------------------------------------------------

## Only what the font draws, no runs of spaces, none at either end, within the limit.
func inert(text: String, limit: int = Chat.MAX_LENGTH) -> bool:
    for character in text:
        if not Chat.GLYPHS.contains(character): return false
    return text.length() <= limit and not text.contains("  ") and text == text.strip_edges()

func _sanitiser() -> void:
    var exact := [
        ["[url=https://evil.example]free[/url]", "?url?https://evil.example?free?/url?"],
        ["[img]res://icon.svg[/img]", "?img?res://icon.svg?/img?"],
        ["[color=#ff0000]red[/color]", "?color??ff0000?red?/color?"],
        ["a\u0001b\u0007c\u001bd\u007fe\u0085f\u009fg", "abcde fg"],
        ["ab\u202Ecd\u202Aef\u2066gh\u2069i\u061Cj", "abcdefghij"],
        ["a\u200Bb\u200Cc\u200Dd\u200Ee\u200Ff\uFEFFg\u2060h", "abcdefgh"],
        ["  hello \t\n\r\u00A0 world \u3000 ", "hello world"],
        ["%s %d %% %(x)s", "%s %d %% %?x?s"],
        ["{0} {name} {}", "?0? ?name? ??"],
        ["OS.execute(\"cmd.exe\", [\"/c\", \"calc\"])", "OS.execute??cmd.exe?, ??/c?, ?calc???"],
        ["\u00C9 \u00E9moji \U01F600 \u4E2D\u6587 <b>", "\u00C9 \u00E9moji ? ?? ?b?"],
    ]
    for case in exact:
        check(Chat.clean(case[0]) == case[1], "clean(%s) = %s, not %s" % [case[0].c_escape(), Chat.clean(case[0]), case[1]])
    check(Chat.clean("x".repeat(100000)) == "x".repeat(Chat.MAX_LENGTH), "very long text is cut to %d" % Chat.MAX_LENGTH)
    check(Chat.clean("\u200B".repeat(100000) + "hi") == "", "a flood of invisible characters is not read to its end")
    for value in [null, 42, 4.2, true, [], ["hi"], {}, {"text": "hi"}, Vector2.ONE, PackedByteArray([72, 73]), &"hi", NodePath("hi")]:
        check(Chat.clean(value) == "", "a %s is not text" % type_string(typeof(value)))
    # GDScript-looking text stays inert text: nothing runs it, and its brackets and quotes go.
    for code in ["OS.execute('calc.exe', [])", "load(\"res://x.gd\").new()", "get_tree().quit()", "Expression.new().parse(\"1+1\")", "str_to_var(\"Object()\")"]:
        var text := Chat.clean(code)
        check(inert(text) and not text.contains("(") and not text.contains("\""), "code stays inert text: %s" % text)
    check(Chat.clean_name("HOST: hi") == "HOST hi", "a name cannot pose as another sender")
    check(Chat.clean_name(5) == "PLAYER" and Chat.clean_name("\u202E\u200B") == "PLAYER", "no name: PLAYER")
    check(Chat.clean_name("N".repeat(100)) == "N".repeat(Chat.NAME_LENGTH), "a name is cut to %d" % Chat.NAME_LENGTH)
    # Anything at all comes out inert, and cleaning twice changes nothing.
    var noise := RandomNumberGenerator.new()
    noise.seed = 11
    for i in 400:
        var text := ""
        for j in noise.randi_range(0, 200):
            var code := noise.randi_range(0, 0x10FFFF) if noise.randf() < 0.3 else noise.randi_range(0, 0x3000)
            if code < 0xD800 or code > 0xDFFF: text += String.chr(code)
        var once := Chat.clean(text)
        check(inert(once) and Chat.clean(once) == once, "random text comes out inert: %s" % once.c_escape())
    # Shown in a Label it is that text, character for character.
    var label := Label.new()
    label.text = Chat.clean("[b]bold[/b] %s")
    check(label.get_class() == "Label" and label.text == "?b?bold?/b? %s", "a Label shows it as it is: %s" % label.text)
    label.free()

# --- host and guests ------------------------------------------------------------------

func _player(name: String, token: String) -> Array:
    var session := Session.new()
    root.add_child(session)
    session.configure(token, "chat-test", {"name": name, "model": 0, "color": 0})
    var chat := Chat.new()
    chat.session = session
    root.add_child(chat)
    session.message.connect(chat.message)
    return [session, chat]

func _wait(condition: Callable, seconds: float = 10.0) -> bool:
    var deadline := Time.get_ticks_msec() + int(seconds * 1000.0)
    while not condition.call() and Time.get_ticks_msec() < deadline: await process_frame
    return condition.call()

func _network() -> void:
    var port := 55000 + randi() % 900
    var host := _player("HOST", "a".repeat(64))
    # The names these players gave: the host passes them on cleaned.
    var ann := _player("[b]Ann\u202E[/b]", "b".repeat(64))
    var bob := _player("Bob", "c".repeat(64))
    await _frames(2)
    check(host[0].host("chat-test-world", port, "127.0.0.1") == OK, "the host listens")
    ann[0].join_address("127.0.0.1", port)
    check(await _wait(func(): return ann[0].trusted and host[0].players.size() == 2), "Ann joins")
    bob[0].join_address("127.0.0.1", port)
    check(await _wait(func(): return bob[0].trusted and host[0].players.size() == 3), "Bob joins")
    var ann_name := Chat.clean_name("[b]Ann\u202E[/b]")
    check(ann_name == "?b?Ann?/b?", "Ann's name, cleaned: %s" % ann_name)

    # Ann's game cleans what she types; the host relays it to everyone, her too.
    ann[1].send("hi [url=https://x.example]there[/url]\u200B %s")
    check(await _wait(func(): return bob[1].history.size() == 1 and ann[1].history.size() == 1 and host[1].history.size() == 1), "the message reaches the host and both guests")
    var expected := ann_name + ": hi ?url?https://x.example?there?/url? %s"
    check(bob[1].history == [expected] and ann[1].history == [expected] and host[1].history == [expected], "everyone has it as %s: %s" % [expected, bob[1].history])
    # A game that does not clean, and a name in the message: the host cleans it and uses the session's name.
    ann[0].send_host({"kind": "chat", "text": "[color=red]x\u0001y\u202E[/color]", "name": "HOST"})
    ann[0].send_host({"kind": "chat", "text": 123})
    ann[0].send_host({"kind": "chat", "text": ["a"]})
    ann[0].send_host({"kind": "chat", "text": " \u200B\u202E "})
    ann[0].send_host({"kind": "chat"})
    check(await _wait(func(): return bob[1].history.size() == 2), "the second message arrives")
    check(bob[1].history[1] == ann_name + ": ?color?red?xy?/color?", "cleaned on the host, under the session's name: %s" % bob[1].history[1])
    # Third in five seconds still passes; the fourth and fifth are dropped (sent around Ann's own limit).
    ann[0].send_host({"kind": "chat", "text": "three"})
    ann[0].send_host({"kind": "chat", "text": "spam one"})
    ann[0].send_host({"kind": "chat", "text": "spam two"})
    await _wait(func(): return false, 1.0)
    check(bob[1].history.size() == 3 and bob[1].history[2] == ann_name + ": three", "over the rate limit is dropped: %s" % [bob[1].history])
    check(host[1].history.size() == 3, "on the host too: %d" % host[1].history.size())
    # Others are not held back by Ann.
    host[1].send("welcome")
    check(await _wait(func(): return ann[1].history.size() == 4), "the host still talks")
    # A sender's own game holds it back as well, and says so.
    for line in ["b1", "b2", "b3", "b4"]: bob[1].send(line)
    check(bob[1].history.has("Too fast. Wait a moment."), "the sender is told: %s" % [bob[1].history])
    check(await _wait(func(): return ann[1].history.size() == 7), "Bob's first three arrive")
    await _wait(func(): return false, 0.5)
    check(ann[1].history.slice(3) == ["HOST: welcome", "Bob: b1", "Bob: b2", "Bob: b3"], "in order, with their names: %s" % [ann[1].history.slice(3)])
    # After the five seconds Ann may speak again.
    await _wait(func(): return false, Chat.RATE_MS / 1000.0)
    ann[1].send("back again")
    check(await _wait(func(): return bob[1].history.back() == ann_name + ": back again"), "after %d ms Ann speaks again" % Chat.RATE_MS)

    # A guest cleans what the host sends too: never trust the network.
    var before: int = bob[1].history.size()
    bob[1].receive({"kind": "chat", "name": "Evil\u202E: SYSTEM", "text": "[img]res://icon.svg[/img]\u0007"})
    bob[1].receive({"kind": "chat", "name": 5, "text": "x"})
    bob[1].receive({"kind": "chat", "name": "A", "text": {"x": 1}})
    bob[1].receive({"kind": "chat", "name": "A", "text": "\u200B"})
    check(bob[1].history.size() == before + 1 and bob[1].history.back() == "Evil SYSTEM: ?img?res://icon.svg?/img?", "a guest cleans the host's packet: %s" % bob[1].history.back())
    for i in 30: bob[1].receive({"name": "A", "text": "line %d" % i})
    check(bob[1].history.size() == Chat.HISTORY and bob[1].history.back() == "A: line 29", "the history keeps the last %d" % Chat.HISTORY)
    for player in [ann, bob, host]:
        player[0].stop()
        player[0].queue_free()
        player[1].queue_free()
    await _frames(2)

# --- on a touch screen -----------------------------------------------------------------

var SHOTS := OS.get_environment("CHAT_SHOTS") if not OS.get_environment("CHAT_SHOTS").is_empty() else OS.get_temp_dir().path_join("chat_ui")

func shot(file: String) -> void:
    if DisplayServer.get_name() == "headless": return
    await RenderingServer.frame_post_draw
    DirAccess.make_dir_recursive_absolute(SHOTS)
    root.get_texture().get_image().save_png(SHOTS.path_join(file))

func tap_at(point: Vector2) -> void:
    for pressed in [true, false]:
        var touch := InputEventScreenTouch.new()
        touch.position = root.get_final_transform() * point
        touch.pressed = pressed
        Input.parse_input_event(touch)
        await _frames(2)
    await _frames(3)

func key(code: Key, unicode: int = 0) -> void:
    for pressed in [true, false]:
        var event := InputEventKey.new()
        event.keycode = code
        event.unicode = unicode if pressed else 0
        event.pressed = pressed
        Input.parse_input_event(event)
        await _frames(1)

func type(text: String) -> void:
    for character in text:
        var code := character.unicode_at(0)
        await key(OS.find_keycode_from_string(character.to_upper()) if character != " " else KEY_SPACE, code)

func hud_rects() -> Dictionary:
    var out := {}
    if main.minimap_root.is_visible_in_tree(): out["minimap"] = main.minimap_root.get_global_rect()
    if main.status_hud.clock_chip.is_visible_in_tree(): out["clock"] = main.status_hud.clock_chip.get_global_rect()
    if main.status_hud.battery_chip.is_visible_in_tree(): out["battery"] = main.status_hud.battery_chip.get_global_rect()
    var pad: Control = main.touch_controls
    for name in ["Start", "A", "B", "L2", "R2", "LeftStick"]:
        out[name] = (pad.get_node(name) as Control).get_global_rect()
    return out

func clear_of(rect: Rect2, others: Dictionary, what: String) -> void:
    var screen: Vector2 = main.get_viewport().get_visible_rect().size
    check(Rect2(Vector2.ZERO, screen).encloses(rect), "%s on screen: %s" % [what, rect])
    for name in others:
        check(not rect.intersects(others[name]), "%s %s clear of the %s %s" % [what, rect, name, others[name]])

func _touch_screen() -> void:
    var dir := OS.get_temp_dir().path_join("coop_chat_test_%d" % Time.get_ticks_usec())
    DirAccess.make_dir_recursive_absolute(dir)
    FileAccess.open(dir.path_join(".private-saves-migrated"), FileAccess.WRITE).close()
    Paths.directory = dir
    change_scene_to_file("res://scenes/main.tscn")
    await _frames(30)
    main = current_scene
    while not main.startup_complete: await process_frame
    await _frames(10)
    check(main.touch_ui.enabled, "the touch UI is on (--touch-ui)")
    main.coop_menu.close()
    main.world_edit.text = "ChatTest"
    main.selected_mode = "NEW"
    main._start_game()
    var waited := 0
    while not main.started and waited < 36000:
        await process_frame
        waited += 1
    check(main.started, "the world started")
    await _frames(60)
    for i in 6:
        if not main._field_ui_blocks_gameplay(): break
        for pressed in [true, false]:
            var event := InputEventAction.new()
            event.action = "confirm"
            event.pressed = pressed
            Input.parse_input_event(event)
            await _frames(1)
        await _frames(20)
    var coop: Node = main.coop_game
    var chat: Control = coop.chat
    var surfaces = main.touch_ui.surfaces
    check(not chat.available() and not _has_chat_button(surfaces.build()), "playing alone: no chat")

    # Online as a host (the session itself is not started: no other players),
    # on a phone: the menu button in the top row, a battery beside it.
    coop.set_process(false)
    coop.active = true; coop.hosting = true
    coop.session.hosting = true; coop.session.trusted = true; coop.session.actor = "d".repeat(64)
    coop.session.players = {1: {"actor": coop.session.actor, "profile": {"name": "ASH"}}}
    var pad: Control = main.touch_controls
    pad.android_runtime = true
    pad._refresh_visibility()
    OS.set_environment(main.status_hud.BATTERY_ENV, "60,1")
    main.status_hud.update()
    await _frames(3)
    var hud := {}
    var surface: Dictionary = {}
    var button := Rect2()
    for width in [320, 390]:
        root.size = Vector2i(width * 4, 720)
        # The phone's pad looks at the screen twice a second.
        await create_timer(0.7).timeout
        await _frames(4)
        check(is_equal_approx(main.get_viewport().get_visible_rect().size.x, width), "%d px wide: %s" % [width, main.get_viewport().get_visible_rect().size])
        hud = hud_rects()
        surface = surfaces.build()
        check(_has_chat_button(surface), "online at %d: the chat button: %s" % [width, surface.get("hotspots", [])])
        button = chat.button_rect()
        var menu: Rect2 = hud.Start
        check(hud.has("battery"), "the battery shows at %d" % width)
        check(button.size.x >= menu.size.x and button.size.y >= menu.size.y, "the chat button as big as the menu button: %s %s" % [button, menu])
        check(is_equal_approx(button.get_center().y, menu.get_center().y), "on the menu button's line: %s %s" % [button, menu])
        check(is_equal_approx(button.end.x, menu.position.x - Hud.GAP) and is_equal_approx(hud.battery.end.x, button.position.x - Hud.GAP),
            "between the battery and the menu button, GAP apart: %s %s %s" % [hud.battery, button, menu])
        clear_of(button, hud, "chat button at %d" % width)
        # The notice centred under the clock, clear of the whole top row.
        chat.unread = false
        coop.show_notice("", "hosting")
        await _frames(2)
        var notice: Rect2 = coop._notice_box.get_global_rect()
        check(absf(notice.get_center().x - Rect2(hud.clock).get_center().x) <= 1.0 and is_equal_approx(notice.position.y, Rect2(hud.clock).end.y + Hud.GAP),
            "the notice centred under the clock at %d: %s %s" % [width, notice, hud.clock])
        clear_of(notice, hud.merged({"chat button": button}), "notice at %d" % width)
        await shot("chat_button_notice_%d.png" % width)
        # A message from someone else lights the red dot; this player's own do not.
        chat.send("my own line")
        chat.receive({"name": "ASH", "text": "my echo", "mine": true})
        chat._add("", "Too fast. Wait a moment.")
        await _frames(2)
        check(not chat.unread, "no dot for this player's own messages at %d" % width)
        chat.receive({"name": "MISTY", "text": "Over here!"})
        await _frames(2)
        check(chat.unread and chat._button.visible, "a message from someone else lights the dot at %d" % width)
        # Only the newest message (no note of this game's own), centred under the notice.
        var log: Control = chat._log
        var clock: Rect2 = hud.clock
        var at := "the message at %d" % width
        check(log.visible and chat._log_text.text == "MISTY: Over here!", "%s: only the newest: %s" % [at, chat._log_text.text])
        var rect := log.get_global_rect()
        check(absf(rect.get_center().x - clock.get_center().x) <= 1.0 and is_equal_approx(rect.position.y, notice.end.y + Hud.GAP),
            "%s centred under the notice: %s %s %s" % [at, rect, notice, clock])
        clear_of(rect, hud.merged({"chat button": button, "notice": notice}), at)
        await shot("chat_button_badge_%d.png" % width)
        # The notice goes: the message moves up under the clock.
        coop._notice_box.visible = false
        await _frames(2)
        rect = log.get_global_rect()
        check(absf(rect.get_center().x - clock.get_center().x) <= 1.0 and is_equal_approx(rect.position.y, clock.end.y + Hud.GAP),
            "%s centred under the clock: %s %s" % [at, rect, clock])
        # A long one replaces it, cut to LOG_LINES lines; the open chat keeps it whole.
        var long := "Found a shiny Magikarp at the lake, come and see it before it swims off, it is golden!"
        chat.receive({"name": "MISTY", "text": long})
        await _frames(2)
        rect = log.get_global_rect()
        check(chat._log_text.text.begins_with("MISTY: Found") and chat._log_text.text.ends_with("...") and chat._log_text.get_line_count() == Chat.LOG_LINES,
            "%s: a long one ends in ... after %d lines: %s (%d)" % [at, Chat.LOG_LINES, chat._log_text.text, chat._log_text.get_line_count()])
        check(chat.history.back() == "MISTY: " + Chat.clean(long), "the history keeps it whole")
        check(absf(rect.get_center().x - clock.get_center().x) <= 1.0 and is_equal_approx(rect.position.y, clock.end.y + Hud.GAP), "%s still under the clock: %s" % [at, rect])
        clear_of(rect, hud.merged({"chat button": button}), at)
        await shot("chat_message_%d.png" % width)
        # One endless word is cut inside it.
        chat.receive({"name": "MISTY", "text": "W".repeat(Chat.MAX_LENGTH)})
        await _frames(2)
        check(chat._log_text.text.begins_with("MISTY: WWW") and chat._log_text.text.ends_with("W...") and chat._log_text.get_line_count() == Chat.LOG_LINES,
            "%s: one long word cut: %s (%d)" % [at, chat._log_text.text, chat._log_text.get_line_count()])
        clear_of(log.get_global_rect(), hud.merged({"chat button": button}), at + " (one long word)")
        chat.receive({"name": "MISTY", "text": long})
        await _frames(2)
        # Gone LOG_SECONDS later, after its fade.
        await create_timer(Chat.LOG_SECONDS + 1.3).timeout
        check(not log.visible, "%s hides after %d s" % [at, Chat.LOG_SECONDS])
    # Without a battery the button sits just left of the menu button.
    OS.set_environment(main.status_hud.BATTERY_ENV, "")
    main.status_hud.update()
    await _frames(3)
    check(not main.status_hud.battery_chip.visible and chat.button_rect() == button, "no battery: still beside the menu button: %s" % chat.button_rect())
    hud = hud_rects()

    # A tap opens the chat; typing goes in, Enter sends it under this player's name.
    await tap_at(button.get_center())
    check(chat.visible and main._field_ui_blocks_gameplay(), "a tap on the chat button opens it and stops the player")
    check(not chat.unread and not chat._button.visible, "opening clears the dot; the button steps aside")
    surface = surfaces.build()
    check(surface.has("back") and surface.get("hide_pad", false) and surface.buttons.size() == 2, "the X, PASTE and SEND: %s" % [surface.get("buttons", [])])
    await type("Hello [b]there[/b]")
    check(chat.buffer == "Hello bthere/b", "only what the font draws is typed: %s" % chat.buffer)
    await key(KEY_ENTER)
    check(chat.history.back() == "ASH: Hello bthere/b" and chat.buffer.is_empty() and chat.visible, "Enter sends it: %s" % chat.history.back())
    for line in ["[url=https://evil.example]free stuff[/url]", "%s %d {0}", "OS.execute(\"calc\")", "Anyone near the lake? Bring a Surf Pokemon, the bridge is out."]:
        chat.receive({"name": "MISTY", "text": line})
    chat.receive({"name": "BROCK\u202E", "text": "on my way\u200B"})
    await _frames(2)
    var panel: Rect2 = chat.get_global_rect()
    var screen: Vector2 = main.get_viewport().get_visible_rect().size
    check(Rect2(Vector2.ZERO, screen).encloses(panel) and panel.end.y <= screen.y * 0.5 + 0.01, "the chat sits above the phone keyboard: %s" % panel)
    check(not panel.intersects(main.touch_ui.close_button.get_global_rect()), "clear of the X")
    for entry in surfaces.build().buttons:
        check(panel.encloses(entry[2]), "%s inside the box: %s" % [entry[0], entry[2]])
    check(chat._lines.get_class() == "Label" and chat._entry.get_class() == "Label" and chat._log_text.get_class() == "Label", "plain Labels only")
    check(chat._lines.auto_translate_mode == Node.AUTO_TRANSLATE_MODE_DISABLED and chat._entry.auto_translate_mode == Node.AUTO_TRANSLATE_MODE_DISABLED and chat._log_text.auto_translate_mode == Node.AUTO_TRANSLATE_MODE_DISABLED, "never looked up as translations")
    check(chat._lines.text.ends_with("BROCK: on my way"), "the newest line last: %s" % chat._lines.text.right(30))
    await type("see you")
    await shot("chat_open.png")
    # Scrolled back to older lines and down again.
    for i in 12: chat.receive({"name": "MISTY", "text": "line %d" % i})
    await key(KEY_UP); await key(KEY_UP)
    check(chat.scroll == 2 and chat._lines.lines_skipped < chat._lines.get_line_count() - chat._lines.max_lines_visible, "up scrolls back: %d" % chat.scroll)
    await key(KEY_DOWN); await key(KEY_DOWN)
    check(chat.scroll == 0, "down comes back")
    # The X closes it.
    await tap_at(main.touch_ui.close_button.get_global_rect().get_center())
    check(not chat.visible and not main._field_ui_blocks_gameplay(), "the X closes the chat")

    # A keyboard: T opens it, Escape closes it; a key bound to a game action still types.
    await key(KEY_T, "t".unicode_at(0))
    check(chat.visible and chat.buffer.is_empty(), "T opens the chat")
    await type("zx")
    check(chat.buffer == "zx", "Z and X type: %s" % chat.buffer)
    await key(KEY_ESCAPE)
    check(not chat.visible, "Escape closes it")

    coop.active = false; coop.hosting = false
    coop.session.hosting = false; coop.session.trusted = false; coop.session.players = {}
    await _frames(2)
    check(not _has_chat_button(surfaces.build()) and not chat._button.visible, "offline again: no chat button")

func _has_chat_button(surface: Dictionary) -> bool:
    for entry in surface.get("hotspots", []):
        if entry[0] == "CHAT": return true
    return false
