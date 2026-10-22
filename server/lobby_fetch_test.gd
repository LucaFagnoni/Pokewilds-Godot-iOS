# JOIN A GAME's online list (coop_lobby.gd) over a slow phone link: run by
# server/lobby_fetch_test.py, which serves the lobby directory locally behind a
# 4G-like proxy that drops the first connection. The list must appear within the
# budget without ever saying UNAVAILABLE first, keep its last good entries while
# the directory cannot be reached, say UNAVAILABLE only after a few failed tries,
# and come back by itself. "native" runs the same through the phone bridge's
# calls (http_start/http_take, as on iPhone and Android) instead of HTTPRequest.
# Run: python server/lobby_fetch_test.py GODOT
extends SceneTree

const Paths = preload("res://scripts/game_data_paths.gd")
const Network = preload("res://scripts/coop_network.gd")
const Lobby = preload("res://scripts/coop_lobby.gd")

var checks := 0
var failed := 0

func check(ok: bool, what: String) -> void:
    checks += 1
    if not ok:
        failed += 1
        printerr("LOBBY FETCH TEST FAIL: ", what)

## Stands in for the phone plugins' lobby requests (pokewilds_zerotier.mm,
## PokeWildsZeroTier.java): the same calls, answered by HTTPRequest here.
class Bridge extends Node:
    var results := {}
    var ids := 0
    func status() -> String: return "ready\tfd00::1\t"
    func setLobbyKey(_key: String) -> void: pass
    func httpStart(url: String, body: String) -> int:
        ids += 1
        var id := ids
        var request := HTTPRequest.new(); request.timeout = 10.0; add_child(request)
        request.request_completed.connect(func(result: int, code: int, _headers, data: PackedByteArray):
            results[id] = "%d\n%s" % [code if result == HTTPRequest.RESULT_SUCCESS else 0, data.get_string_from_utf8()]
            request.queue_free())
        request.request(url, [], HTTPClient.METHOD_GET if body.is_empty() else HTTPClient.METHOD_POST, body)
        return id
    func httpTake(id: int) -> String:
        var answer := String(results.get(id, "")); results.erase(id); return answer

func _initialize() -> void:
    _run.call_deferred()

func _set_url(url: String) -> void:
    var file := FileAccess.open(Paths.path("zerotier.cfg"), FileAccess.WRITE)
    file.store_string('[lobby]\nurl="%s"\nforce=true\n' % url); file.close()
    Network.settings_changed()

## Waits for `done`, noting every status line the list shows meanwhile.
func _until(done: Callable, seconds: float, lobby: Node, seen: Array) -> bool:
    var deadline := Time.get_ticks_msec() + int(seconds * 1000)
    while not done.call():
        if not String(lobby.list_error) in seen: seen.append(String(lobby.list_error))
        if Time.get_ticks_msec() > deadline: return false
        await process_frame
    return true

func _run() -> void:
    var args := OS.get_cmdline_user_args()
    var url: String = args[0]; var dead: String = args[2]; var budget := float(args[3])
    var native: bool = args[1] == "native"
    Paths.directory = args[4]
    _set_url(url)
    if native:
        var bridge := Bridge.new(); root.add_child(bridge)
        Network._checked = true; Network.bridge = bridge
    var lobby: Node = Lobby.new(); root.add_child(lobby)
    var seen: Array = []
    var began := Time.get_ticks_msec()
    lobby.browse(true)
    var listed := await _until(func(): return not lobby.entries().is_empty(), 30.0, lobby, seen)
    var took := (Time.get_ticks_msec() - began) / 1000.0
    print("LOBBY FETCH %s: first list after %.2f s (budget %.1f s), status lines meanwhile %s" % [args[1], took, budget, seen])
    check(listed and took < budget, "the list appears within %.1f s: %.2f s" % [budget, took])
    check(seen.all(func(line): return not "UNAVAILABLE" in line), "no UNAVAILABLE before the first list: %s" % [seen])
    check(listed and String(lobby.entries()[0].version) == "0.10.245" and lobby.list_error == "", "the listed server with its version, no status line: %s" % [lobby.entries()])

    # The directory goes away for a while: the list keeps its last good entries.
    _set_url(dead)
    seen.clear()
    check(await _until(func(): return int(lobby._failures) >= 1, 15.0, lobby, seen), "a failed try is noticed")
    check(lobby.entries().size() == 1 and not "UNAVAILABLE" in String(lobby.list_error), "one failure keeps the list and does not say UNAVAILABLE: %s" % lobby.list_error)
    began = Time.get_ticks_msec()
    check(await _until(func(): return "UNAVAILABLE" in String(lobby.list_error), 20.0, lobby, seen), "UNAVAILABLE after a few failures")
    print("LOBBY FETCH %s: UNAVAILABLE after %d failures, %.1f s after the first" % [args[1], int(lobby._failures), (Time.get_ticks_msec() - began) / 1000.0])
    check(lobby.entries().size() == 1, "the last good list stays while unavailable")
    _set_url(url)
    began = Time.get_ticks_msec()
    check(await _until(func(): return lobby.list_error == "", 15.0, lobby, seen), "the list comes back by itself")
    print("LOBBY FETCH %s: back %.1f s after the directory returned" % [args[1], (Time.get_ticks_msec() - began) / 1000.0])
    check(lobby.entries().size() == 1, "the list is there again")

    print("LOBBY FETCH TEST %s: %d checks, %d failed" % [args[1], checks, failed])
    quit(1 if failed else 0)
