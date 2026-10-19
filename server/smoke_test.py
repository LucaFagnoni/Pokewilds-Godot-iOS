"""Dedicated server smoke test: start a headless server, join it with a headless
client (a wrong password first), walk into a new area the server has to make,
and check that the client received the world and that the server saved it.

    python server/smoke_test.py GODOT            (GODOT = editor binary, runs project/)
    python server/smoke_test.py PokeWilds.console.exe --exe

Run from the repository root. Exits 0 on success."""
import hashlib, json, os, re, subprocess, sys, tempfile, time

godot = sys.argv[1]
command = [godot] if "--exe" in sys.argv else [godot, "--path", "project"]
work = tempfile.mkdtemp(prefix="pw-server-smoke-")
port = "54777"
logs = {}


def start(name, args, build="smoke-a"):
    logs[name] = os.path.join(work, name + ".log")
    out = open(logs[name], "wb")
    env = dict(os.environ, POKEWILDS_BUILD_ID=build)
    return subprocess.Popen(command + ["--headless"] + args, stdin=subprocess.PIPE, stdout=out, stderr=subprocess.STDOUT, env=env)


def text(name):
    return open(logs[name], "rb").read().decode("utf-8", "replace")


def fail(reason):
    for name in logs:
        print(f"----- {name} log (last lines) -----")
        print("\n".join(text(name).splitlines()[-40:]))
    print("SMOKE FAIL:", reason)
    sys.exit(1)


def wait_for(name, process, needle, seconds):
    deadline = time.time() + seconds
    while time.time() < deadline:
        if needle in text(name): return
        if process.poll() is not None: fail(f"{name} exited ({process.returncode}) before {needle!r}")
        time.sleep(1)
    fail(f"{name}: no {needle!r} after {seconds}s")


def send(process, line):
    process.stdin.write((line + "\n").encode()); process.stdin.flush()


# The address parser and the outside-address check first: seconds, not minutes.
if "--exe" not in sys.argv:
    check = subprocess.run(command + ["--headless", "-s", os.path.abspath("server/address_check.gd")], capture_output=True, text=True, errors="replace")
    if "ADDRESS CHECK: 0 failed" not in check.stdout: print(check.stdout[-2000:], check.stderr[-2000:]); print("SMOKE FAIL: address check"); sys.exit(1)
    print("address check ok")

server_data, client_data = os.path.join(work, "server"), os.path.join(work, "client")
server = start("server", ["--server", "--port", port, "--world", "Smoke", "--size", "S", "--data", server_data, "--password", "smoke",
                         "--no-upnp", "--area-size", "S"])
try:
    started = time.time()
    wait_for("server", server, "listening on TCP port " + port, 900)
    print(f"server ready in {time.time() - started:.0f}s")

    # A game from another build is refused before anything else.
    stranger = start("stranger", ["--join", "127.0.0.1:" + port, "--password", "smoke", "--data", os.path.join(work, "stranger")], build="smoke-b")
    try: stranger.wait(300)
    except subprocess.TimeoutExpired: stranger.kill(); fail("another build neither joined nor failed")
    if "DIFFERENT GAME BUILD" not in text("stranger"): fail("another build was not refused")
    print("another build refused")

    # A wrong password is refused; the right one, carried by the server's challenge, gets in.
    intruder = start("intruder", ["--join", "127.0.0.1:" + port, "--password", "wrong", "--data", os.path.join(work, "intruder")])
    try: intruder.wait(300)
    except subprocess.TimeoutExpired: intruder.kill(); fail("wrong password neither joined nor failed")
    if "WRONG PASSWORD" not in text("intruder"): fail("wrong password was not refused")
    print("wrong password refused")

    # The client also walks into a new area, which the server must make for it.
    client = start("client", ["--join", "127.0.0.1:" + port, "--password", "smoke", "--travel", "--quit-after-join", "--data", client_data])
    try: client.wait(900)
    except subprocess.TimeoutExpired: client.kill(); fail("client did not finish joining")
    joined = re.search(r"CLIENT joined world (\w+)", text("client"))
    if client.returncode != 0 or not joined: fail(f"client exit {client.returncode}, no join")
    print(joined.group(0))
    if "CLIENT travelled to area 1,0" not in text("client") or "SERVER made area 1,0" not in text("server"): fail("the server did not make the new area")
    print("the server made the new area the client walked into")
    wait_for("server", server, "SERVER join:", 30)

    saves_before = text("server").count("SERVER world saved")
    send(server, "save")
    deadline = time.time() + 120
    while text("server").count("SERVER world saved") == saves_before:
        if time.time() > deadline or server.poll() is not None: fail("server did not save")
        time.sleep(1)

    # The saved world must hold the client's player record.
    world = os.path.join(server_data, "online_worlds", joined.group(1), "world.json")
    if not os.path.isfile(world): fail("no world.json for the joined world")
    payload = json.load(open(world, encoding="utf-8"))["payload"]
    token = re.search(r'token="(\w+)"', open(os.path.join(client_data, "coop_identity.cfg")).read()).group(1)
    if "player/" + hashlib.sha256(token.encode()).hexdigest() not in payload: fail("client's player is not in the saved world")
    print("server saved the world with the client's player in it")

    send(server, "stop")
    # Closing the input as the launcher does lets the console-reading thread end
    # (on Linux the process otherwise waits for it at exit).
    server.stdin.close()
    try: server.wait(120)
    except subprocess.TimeoutExpired: fail("server did not stop")
    if text("server").count("SERVER world saved") < saves_before + 2: fail("server did not save on stop")
    print("SMOKE OK: server started, client joined, got the world and a server-made area, server saved and stopped")
finally:
    if server.poll() is None: server.kill()
