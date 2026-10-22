# Who a host lets in (coop_session.gd refusal): the same compat id with another build is in
# (a newer build that changed only client-only files), another compat id is refused with both
# versions, and a side without a compat id (a build from before them) needs the same build.
# A status request (MY SERVERS, coop_server_ping.gd) to a real hosting session answers the same.
# Run: godot --headless --path project -s ../server/compat_test.gd
extends SceneTree

const Session = preload("res://scripts/coop_session.gd")
const Ping = preload("res://scripts/coop_server_ping.gd")
const PORT := 54791
const MODS := "compat-test-mods"

var checks := 0
var failed := 0

func check(ok: bool, what: String) -> void:
    checks += 1
    if not ok:
        failed += 1
        printerr("COMPAT TEST FAIL: ", what)

## This copy's build, compat id and version (the env overrides coop_session.gd reads).
func as_build(build: String, compat: String, version: String) -> void:
    for pair in [["POKEWILDS_BUILD_ID", build], ["POKEWILDS_COMPAT_ID", compat], ["POKEWILDS_BUILD_VERSION", version]]:
        if pair[1].is_empty(): OS.unset_environment(pair[0])
        else: OS.set_environment(pair[0], pair[1])

func hello(fields: Dictionary) -> Dictionary:
    var payload := {"kind": "hello", "protocol": Session.PROTOCOL, "mods": MODS}
    payload.merge(fields, true)
    return payload

func _initialize() -> void:
    check(not FileAccess.file_exists("res://compat_id.txt"), "no compat_id.txt in the project (CI writes it only for exports)")
    var session: Node = Session.new()
    root.add_child(session)
    await process_frame # _ready makes the transport
    session.mod_digest = MODS

    as_build("host-build-1", "compat-a", "0.10.300")
    check(Session.compat_id() == "compat-a", "compat_id() reads its override")
    check(session.refusal(hello({"build": "newer-build-2", "compat": "compat-a", "version": "0.10.301"})) == "", "same compat, other build: in")
    check(session.refusal(hello({"build": "host-build-1", "compat": "compat-a"})) == "", "same compat, same build: in")
    var refused: String = session.refusal(hello({"build": "newer-build-2", "compat": "compat-b", "version": "0.10.301"}))
    check(refused == "Different game version: host 0.10.300, yours 0.10.301.", "other compat: refused with both versions: %s" % refused)
    refused = session.refusal(hello({"build": "newer-build-2", "compat": "compat-b"}))
    check(refused == "Different game version: host 0.10.300, yours newer-bu.", "other compat, no version: their build instead: %s" % refused)
    check(session.refusal(hello({"build": "host-build-1", "compat": "compat-b"})) != "", "other compat, same build: refused (compat decides)")
    # A player from before compat ids: the build decides.
    check(session.refusal(hello({"build": "host-build-1"})) == "", "no compat, same build: in")
    refused = session.refusal(hello({"build": "old-build-0", "version": "0.10.250"}))
    check(refused == "Different game version: host 0.10.300, yours 0.10.250.", "no compat, other build: refused: %s" % refused)
    check(session.refusal(hello({})) == "", "no build at all (editor copy): in, as before")
    check(session.refusal(hello({"build": "newer-build-2", "compat": "compat-a", "protocol": "pokewilds-godot-coop-6"})) == "Game versions do not match.", "the protocol still comes first")
    check(session.refusal(hello({"build": "newer-build-2", "compat": "compat-a", "mods": "other"})) != "", "the mods still must match")

    # A host without compat_id.txt: its compat id is its build id, so the build decides.
    as_build("host-build-1", "", "")
    check(Session.compat_id() == "host-build-1", "without the file compat_id() is the build id")
    check(session.refusal(hello({"build": "host-build-1", "compat": "host-build-1"})) == "", "no compat file, same build: in")
    refused = session.refusal(hello({"build": "other-build", "compat": "other-build"}))
    check(refused == "Different game version: host host-bui, yours other-bu.", "no compat file, other build: refused by build: %s" % refused)
    # Local builds have neither: nobody is refused for it.
    as_build("", "", "")
    check(Session.compat_id() == "" and session.refusal(hello({"build": "x", "compat": "y"})) == "", "local builds skip the check")

    # A status request answers with the same rule, and the host's own version.
    as_build("host-build-1", "compat-a", "0.10.300")
    check(session.configure("ab".repeat(32), MODS, {"name": "HOST"}), "the host is configured")
    check(session.host("compat-test-world", PORT, "127.0.0.1") == OK, "the host listens on %d" % PORT)
    for case in [["newer-build-2", "compat-a", "0.10.301", true], ["newer-build-2", "compat-b", "0.10.301", false],
            ["host-build-1", "compat-b", "0.10.300", false], ["", "", "", true]]:
        as_build(case[0], case[1], case[2])
        var probe := Ping.new("127.0.0.1", PORT, MODS) # the request is made here, with this copy's ids
        as_build("host-build-1", "compat-a", "0.10.300")
        while not probe.poll(): await process_frame
        var found: Dictionary = probe.result
        check(found.get("state") == "ok" and found.get("version") == "0.10.300" and found.get("build") == "host-build-1" and found.get("compatible") == case[3],
            "status for build %s compat %s: compatible %s: %s" % [case[0], case[1], case[3], found])
    session.transport.stop()
    print("COMPAT TEST: %d checks, %d failed" % [checks, failed])
    quit(1 if failed > 0 else 0)
