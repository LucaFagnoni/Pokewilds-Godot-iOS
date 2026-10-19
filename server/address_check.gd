# What players can type in JOIN BY IP, and how the server reads its outside
# address. Run: godot --headless --path project -s <this file> (smoke_test.py does).
extends SceneTree

func _init() -> void:
    var menu = load("res://scripts/coop_menu.gd")
    var server = load("res://scripts/dedicated_server.gd")
    var failures := 0
    var typed := {
        "1.2.3.4": ["1.2.3.4", 54555], "1.2.3.4:5000": ["1.2.3.4", 5000],
        "casa.duckdns.org:54555": ["casa.duckdns.org", 54555],
        "[2001:db8::1]:6000": ["2001:db8::1", 6000], "2001:db8::1": ["2001:db8::1", 54555],
        "1hge13i2": ["192.168.1.14", 54555],
        "bad host:1": null, "1.2.3.4:99999": null, "1.2.3.4:": ["1.2.3.4", 54555], "[zz::]:1": null, "": null,
    }
    for text in typed:
        var got: Dictionary = menu.parse_address(text)
        var want = typed[text]
        var ok: bool = got.is_empty() if want == null else (got.get("address") == want[0] and got.get("port") == want[1])
        if not ok: failures += 1; printerr("ADDRESS CHECK FAIL: ", text, " -> ", got)
    var kinds := {"82.89.52.249": "", "100.70.1.2": "cgnat", "192.168.1.1": "private", "10.0.0.138": "private", "172.20.0.1": "private", "172.32.0.1": ""}
    for address in kinds:
        if server.address_kind(address) != kinds[address]: failures += 1; printerr("ADDRESS CHECK FAIL: kind of ", address)
    print("ADDRESS CHECK: %d failed" % failures)
    quit(1 if failures > 0 else 0)
