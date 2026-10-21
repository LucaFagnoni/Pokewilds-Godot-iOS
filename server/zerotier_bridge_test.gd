# The game's side of the iOS ZeroTier plugin, against server/zerotier_stub.py
# (which runs this and stands in for the plugin): coop_network.gd finds the
# plugin, the node comes up, a host and a guest play through the loopback
# forwarding with the real co-op transport, the lobby directory answers, a
# lost control connection comes back, and a host leaving the app (flush) gets
# its last messages out without another frame.
# Run: python server/zerotier_stub.py GODOT
extends SceneTree

const Network = preload("res://scripts/coop_network.gd")
const Transport = preload("res://scripts/coop_transport.gd")

var checks := 0
var failed := 0

func check(ok: bool, what: String) -> void:
	checks += 1
	if not ok:
		failed += 1
		printerr("ZEROTIER BRIDGE TEST FAIL: ", what)

func _initialize() -> void:
	_run.call_deferred()

func _until(done: Callable, seconds := 5.0) -> bool:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000)
	while not done.call():
		if Time.get_ticks_msec() > deadline: return false
		await process_frame
	return true

func _http(url: String, body := "") -> Dictionary:
	var id := Network.http_start(url, body)
	var answer := {}
	await _until(func(): answer.merge(Network.http_take(id)); return not answer.is_empty())
	return answer

func _run() -> void:
	check(Network.embedded(), "coop_network finds the plugin")
	check(Network.uses_directory(), "lobbies come from the directory, as on Android")
	check(Network.status().state == "starting", "before start the node counts as starting")
	Network.start()
	check(await _until(func(): return Network.status().state == "ready"), "the node comes up")
	var online := Network.status()
	check(not online.lan and String(online.address).contains(":"), "ready with a ZeroTier IPv6 address")
	check(Network.status_text() == "ONLINE", "status text ONLINE")
	var began := Time.get_ticks_usec()
	for i in 200: Network.status()
	var each := (Time.get_ticks_usec() - began) / 200.0
	print("status() takes %.0f us" % each)
	check(each < 2000.0, "a call costs well under a frame")

	# iOS can take the control connection while the app sleeps.
	Network.bridge._peer.disconnect_from_host()
	check(Network.status().state == "ready", "a lost control connection comes back")

	var host := Transport.new(); root.add_child(host)
	check(host.host(Network.GAME_PORT) == OK, "the host listens on the game port")
	Network.host_open()
	var endpoint := Network.join_endpoint(String(online.address))
	check(endpoint.get("address") == "127.0.0.1" and int(endpoint.get("port", 0)) > 0, "a guest connects through loopback")
	var guest := Transport.new(); root.add_child(guest)
	guest.join_address(endpoint.address, endpoint.port)
	var got := {"host": [], "guest": []}
	host.received.connect(func(_peer, message): got.host.append(message))
	guest.received.connect(func(_peer, message): got.guest.append(message))
	check(await _until(func(): return host.peers.size() == 1 and guest.peers.has(1) and guest.peers[1].ready), "the guest reaches the host")
	var big := "x".repeat(200000)
	guest.send(1, {"kind": "hello", "pad": big})
	check(await _until(func(): return got.host.size() == 1), "a large message crosses (guest to host)")
	check(not got.host.is_empty() and got.host[0].get("pad") == big, "and arrives whole")

	# Leaving the app: what is queued goes to the socket at once.
	var peer: int = host.peers.keys()[0]
	host.send(peer, {"kind": "player_notice", "name": "HOST", "event": "away"})
	host.flush()
	check(host.peers[peer].tx.is_empty(), "flush hands everything to the socket")
	check(await _until(func(): return got.guest.size() == 1), "and the guest gets it")

	var url := "https://lobby.example/lobbies"
	var answer := await _http(url, JSON.stringify({"key": "k1", "name": "TEST", "address": online.address}))
	check(int(answer.get("code", 0)) == 200, "the lobby announce is answered")
	answer = await _http(url)
	var listed = JSON.parse_string(String(answer.get("body", "")))
	check(listed is Dictionary and listed.get("lobbies", []).size() == 1 and listed.lobbies[0].address == online.address, "the lobby list has it")

	Network.host_close()
	Network.join_close()
	host.stop(); guest.stop()
	print("ZEROTIER BRIDGE TEST: %d checks, %d failed" % [checks, failed])
	quit(1 if failed > 0 else 0)
