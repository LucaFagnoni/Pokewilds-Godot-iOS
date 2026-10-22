# MY SERVERS status pings (coop_server_ping.gd) against a real headless dedicated server:
# the same compat id answers with its version in green (another build too), another compat id
# is red, a copy without a compat id needs the same build, a host from before
# status requests is red, a closed port or a silent address is OFFLINE within the timeout, and
# malformed status packets neither crash the server nor stop it answering. Then the real
# MY SERVERS list shows those rows in green, red and grey and pings again while open.
# Run: godot --headless --path project -s ../server/server_ping_test.gd
# Windowed (--rendering-driver opengl3 instead of --headless) with -- --shots <folder> it also
# saves screenshots of that list in light and dark mode.
extends SceneTree

const Paths = preload("res://scripts/game_data_paths.gd")
const Ping = preload("res://scripts/coop_server_ping.gd")
const Saved = preload("res://scripts/coop_saved_servers.gd")
const Session = preload("res://scripts/coop_session.gd")
const PORT := 54781
const OLD_PORT := 54782
const OTHER_PORT := 54783
const CLOSED_PORT := 54784

var checks := 0
var failed := 0
var server: Dictionary = {}
var server_log := ""
var stubs: Array = []

func check(ok: bool, what: String) -> void:
    checks += 1
    if not ok:
        failed += 1
        printerr("SERVER PING TEST FAIL: ", what)

func _frames(count: int) -> void:
    for i in count: await process_frame

## One ping to the end, polled every frame as the menu does.
func ping(address: String, port: int, mods: String = "") -> Dictionary:
    var probe := Ping.new(address, port, mods)
    while not probe.poll():
        _serve_stubs(); _drain()
        await process_frame
    return probe.result

## Stand-ins on other ports: one answers as a host from before status requests did, one as a
## host of another version that would refuse this copy.
func _serve_stubs() -> void:
    for stub in stubs:
        var listener: TCPServer = stub.listener
        while listener.is_connection_available():
            var socket := listener.take_connection()
            var body := JSON.stringify(stub.reply).to_utf8_buffer()
            var frame := PackedByteArray(); frame.resize(4); frame.encode_u32(0, body.size()); frame.append_array(body)
            socket.put_data(frame)
            stub.sockets.append(socket)

func _drain() -> void:
    if server.is_empty(): return
    # Both pipes: a full one stops the server at its next print.
    for pipe: FileAccess in [server.stdio, server.stderr]:
        var chunk := pipe.get_buffer(65536)
        while not chunk.is_empty():
            server_log += chunk.get_string_from_utf8()
            chunk = pipe.get_buffer(65536)

func server_running() -> bool:
    return not server.is_empty() and OS.is_process_running(int(server.pid))

## Raw bytes to the server's port; whatever comes back within a second.
func raw(bytes: PackedByteArray) -> PackedByteArray:
    var socket := StreamPeerTCP.new()
    socket.connect_to_host("127.0.0.1", PORT)
    var until := Time.get_ticks_msec() + 2000
    while socket.get_status() == StreamPeerTCP.STATUS_CONNECTING and Time.get_ticks_msec() < until:
        socket.poll(); _drain(); await process_frame
    if socket.get_status() == StreamPeerTCP.STATUS_CONNECTED: socket.put_data(bytes)
    var got := PackedByteArray()
    until = Time.get_ticks_msec() + 1000
    while Time.get_ticks_msec() < until:
        socket.poll()
        if socket.get_status() != StreamPeerTCP.STATUS_CONNECTED: break
        var available := socket.get_available_bytes()
        if available > 0: got.append_array(socket.get_data(available)[1])
        _drain(); await process_frame
    socket.disconnect_from_host()
    _drain()
    return got

func framed(text: String) -> PackedByteArray:
    var body := text.to_utf8_buffer()
    var frame := PackedByteArray(); frame.resize(4); frame.encode_u32(0, body.size()); frame.append_array(body)
    return frame

func remove_dir(path: String) -> void:
    for sub in DirAccess.get_directories_at(path): remove_dir(path.path_join(sub))
    for file in DirAccess.get_files_at(path): DirAccess.remove_absolute(path.path_join(file))
    DirAccess.remove_absolute(path)

func _initialize() -> void:
    var dir := OS.get_temp_dir().path_join("server_ping_test_%d" % Time.get_ticks_usec())
    DirAccess.make_dir_recursive_absolute(dir.path_join("client"))
    FileAccess.open(dir.path_join("client").path_join(".private-saves-migrated"), FileAccess.WRITE).close()
    Paths.directory = dir.path_join("client")
    var mods := String(preload("res://scripts/coop_identity.gd").mods().get("digest", ""))
    check(not mods.is_empty(), "this copy's mods digest")
    # Server and this test share a build id, compat id and version (the child inherits the environment).
    OS.set_environment("POKEWILDS_BUILD_ID", "ping-build-a")
    OS.set_environment("POKEWILDS_COMPAT_ID", "ping-compat-a")
    OS.set_environment("POKEWILDS_BUILD_VERSION", "0.10.999")
    for pair in [[OLD_PORT, {"kind": "rejected", "reason": "Join handshake required."}],
            [OTHER_PORT, {"kind": "status", "protocol": "pokewilds-godot-coop-7", "version": "0.10.198", "build": "ping-build-b", "compatible": false}]]:
        var listener := TCPServer.new()
        check(listener.listen(pair[0], "127.0.0.1") == OK, "stub listens on %d" % pair[0])
        stubs.append({"listener": listener, "reply": pair[1], "sockets": []})

    # Nothing listens: refused at once, and an address that never answers within the timeout.
    var started := Time.get_ticks_msec()
    var found := await ping("127.0.0.1", CLOSED_PORT, mods)
    check(found.get("state") == "offline", "a closed port is offline: %s" % [found])
    check(Time.get_ticks_msec() - started <= Ping.TIMEOUT_MS + 500, "a closed port is offline within the timeout")
    started = Time.get_ticks_msec()
    found = await ping("10.255.255.1", PORT, mods)
    check(found.get("state") == "offline", "a silent address is offline: %s" % [found])
    check(Time.get_ticks_msec() - started <= Ping.TIMEOUT_MS + 500, "a silent address is offline within the timeout (%d ms)" % (Time.get_ticks_msec() - started))
    found = await ping("no-such-host.invalid", PORT, mods)
    check(found.get("state") == "offline", "an unknown host name is offline: %s" % [found])
    found = await ping("127.0.0.1", OLD_PORT, mods)
    check(found.get("state") == "old", "a host from before status requests is old: %s" % [found])
    found = await ping("127.0.0.1", OTHER_PORT, mods)
    check(found.get("state") == "ok" and found.version == "0.10.198" and not found.compatible, "another version is not compatible: %s" % [found])

    # The real dedicated server.
    var args := ["--headless", "--path", ProjectSettings.globalize_path("res://"), "--server", "--port", str(PORT), "--world", "Ping",
        "--size", "S", "--data", dir.path_join("server"), "--no-upnp", "--area-size", "S"]
    server = OS.execute_with_pipe(OS.get_executable_path(), args, false)
    # Every frame from now on, whatever the test waits for (a scene load included).
    process_frame.connect(func(): _drain(); _serve_stubs())
    check(not server.is_empty(), "the dedicated server starts")
    var deadline := Time.get_ticks_msec() + 900000
    while server_running() and not ("listening on TCP port %d" % PORT) in server_log and Time.get_ticks_msec() < deadline:
        _drain(); await _frames(10)
    check(("listening on TCP port %d" % PORT) in server_log, "the dedicated server is listening")
    print("server ready after ", (Time.get_ticks_msec() - started) / 1000, " s")

    found = await ping("127.0.0.1", PORT, mods)
    check(found.get("state") == "ok" and found.version == "0.10.999" and found.build == "ping-build-a" and found.compatible, "same build: version and compatible: %s" % [found])
    check(int(found.get("ms", 99999)) < 1000, "the ping is measured: %s ms" % [found.get("ms")])
    found = await ping("localhost", PORT, mods)
    check(found.get("state") == "ok" and found.compatible, "a host name is resolved: %s" % [found])
    # Another build with another compat id: the server's own rule refuses it, so red.
    OS.set_environment("POKEWILDS_BUILD_ID", "ping-build-old")
    OS.set_environment("POKEWILDS_COMPAT_ID", "ping-compat-old")
    found = await ping("127.0.0.1", PORT, mods)
    check(found.get("state") == "ok" and found.version == "0.10.999" and not found.compatible, "another compat id is not compatible: %s" % [found])
    # A newer build that changed only client-only files keeps the compat id: green, the server's own version.
    OS.set_environment("POKEWILDS_BUILD_ID", "ping-build-new")
    OS.set_environment("POKEWILDS_COMPAT_ID", "ping-compat-a")
    found = await ping("127.0.0.1", PORT, mods)
    check(found.get("state") == "ok" and found.version == "0.10.999" and found.build == "ping-build-a" and found.compatible, "another build with the same compat id is compatible: %s" % [found])
    OS.set_environment("POKEWILDS_BUILD_ID", "ping-build-a")
    # A copy from before compat ids sends only its build: the build decides.
    for pair in [["ping-build-a", true], ["ping-build-old", false]]:
        var old_reply = JSON.parse_string((await raw(framed(JSON.stringify({"kind": "status", "protocol": Session.PROTOCOL, "mods": mods, "build": pair[0]})))).slice(4).get_string_from_utf8())
        check(old_reply is Dictionary and old_reply.get("compatible") == pair[1], "no compat id, build %s: compatible %s: %s" % [pair[0], pair[1], old_reply])
    found = await ping("127.0.0.1", PORT, "other-mods")
    check(found.get("state") == "ok" and not found.compatible, "other mods are not compatible: %s" % [found])

    # Malformed packets: each closes its own connection, never the server.
    var huge := PackedByteArray(); huge.resize(4); huge.encode_u32(0, 0xFFFFFFFF)
    var zero := PackedByteArray(); zero.resize(4)
    for bytes in [huge, zero, "GET / HTTP/1.0\r\n\r\n".to_utf8_buffer(), framed("{not json"), framed("[1,2,3]"), framed("\"status\""),
            framed("{\"kind\":\"status\",\"protocol\":5,\"mods\":[1],\"build\":{\"a\":1}}"), framed("{\"kind\":7}"), framed("{\"kind\":\"status\"}" + " ".repeat(200000))]:
        await raw(bytes)
    var odd := await raw(framed("{\"kind\":\"status\",\"protocol\":5,\"mods\":[1],\"build\":{\"a\":1}}"))
    var odd_reply = JSON.parse_string(odd.slice(4).get_string_from_utf8()) if odd.size() > 4 else null
    check(odd_reply is Dictionary and odd_reply.get("compatible") == false, "odd status fields are answered as not compatible: %s" % [odd_reply])
    check(odd_reply is Dictionary and odd_reply.keys().all(func(k): return k in ["kind", "protocol", "version", "build", "compatible"]), "the reply says nothing about accounts: %s" % [odd_reply])
    check(server_running(), "the server survives malformed packets")
    found = await ping("127.0.0.1", PORT, mods)
    check(found.get("state") == "ok" and found.compatible, "the server still answers after malformed packets: %s" % [found])
    check(not "SCRIPT ERROR" in server_log, "no script errors on the server")

    await menu_rows()

    if server_running():
        server.stdio.store_line("stop"); server.stdio.flush()
        deadline = Time.get_ticks_msec() + 120000
        while server_running() and Time.get_ticks_msec() < deadline: _drain(); await _frames(10)
        if server_running(): OS.kill(int(server.pid))
    _drain()
    if failed > 0: print(server_log.right(4000))
    remove_dir(dir)
    print("SERVER PING TEST: %d checks, %d failed" % [checks, failed])
    quit(1 if failed > 0 else 0)

## MY SERVERS with a green, two red and an offline row, in light and dark mode.
func menu_rows() -> void:
    Saved.save_all([{"name": "Home server", "address": "127.0.0.1:%d" % PORT, "id": "ash", "password": "x"},
        {"name": "Old friend server", "address": "127.0.0.1:%d" % OLD_PORT, "id": "", "password": ""},
        {"name": "Newer build", "address": "127.0.0.1:%d" % OTHER_PORT, "id": "", "password": ""},
        {"name": "Switched off", "address": "127.0.0.1:%d" % CLOSED_PORT, "id": "", "password": ""}] as Array[Dictionary])
    change_scene_to_file("res://scenes/main.tscn")
    await _frames(30)
    var main: Node = current_scene
    while not main.startup_complete: await process_frame
    var menu: Control = main.coop_menu
    menu.open(); menu._go("multi"); menu.selection = 2; menu.activate()
    check(menu.page == "servers", "MY SERVERS opens")
    var texts := func(): return menu.ping_labels.map(func(l): return l.text)
    check(texts.call().slice(0, 4) == ["...", "...", "...", "..."], "rows wait for their first answer: %s" % [texts.call()])
    var until := Time.get_ticks_msec() + 5000
    while Time.get_ticks_msec() < until and "..." in texts.call().slice(0, 4):
        _serve_stubs(); await process_frame
    var shown: Array = texts.call()
    check(shown[0].begins_with("V0.10.999 ") and shown[0].ends_with("MS") and menu.ping_labels[0].modulate == menu.PING_COLORS.green, "the same build is green: %s" % shown[0])
    check(shown[1] == "OLD VERSION" and menu.ping_labels[1].modulate == menu.PING_COLORS.red, "an old host is red: %s" % shown[1])
    check(shown[2].begins_with("V0.10.198 ") and menu.ping_labels[2].modulate == menu.PING_COLORS.red, "another build is red: %s" % shown[2])
    check(shown[3] == "OFFLINE" and menu.ping_labels[3].modulate == menu.PING_COLORS.grey, "a closed port is grey OFFLINE: %s" % shown[3])
    await _shot("my_servers_light.png")
    # The next round of pings comes by itself.
    var first: Dictionary = menu._pings["127.0.0.1:%d" % PORT]
    var next := int(first.next)
    until = Time.get_ticks_msec() + menu.PING_EVERY_MS + 4000
    while Time.get_ticks_msec() < until and int(first.next) == next:
        _serve_stubs(); await process_frame
    check(int(first.next) > next, "the list pings again while it is open")
    preload("res://scripts/game_options.gd").change("dark_mode", true)
    main._apply_game_options(); menu.refresh()
    await _frames(5)
    check(menu.ping_labels[0].modulate == menu.PING_COLORS_DARK.green and menu.ping_labels[1].modulate == menu.PING_COLORS_DARK.red, "dark mode has its own tints")
    await _shot("my_servers_dark.png")
    preload("res://scripts/game_options.gd").change("dark_mode", false)
    main._apply_game_options()

## Windowed with -- --shots <folder> only.
func _shot(file: String) -> void:
    var args := OS.get_cmdline_user_args()
    if DisplayServer.get_name() == "headless" or args.find("--shots") < 0 or args.find("--shots") + 1 >= args.size(): return
    var folder: String = args[args.find("--shots") + 1]
    DirAccess.make_dir_recursive_absolute(folder)
    await RenderingServer.frame_post_draw
    root.get_texture().get_image().save_png(folder.path_join(file))
    print("screenshot ", folder.path_join(file))
