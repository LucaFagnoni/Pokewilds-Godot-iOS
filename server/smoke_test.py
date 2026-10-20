"""Dedicated server smoke test, in three runs of a headless server on one world:
1. no player IDs: another build and a wrong shared password are refused; a
   client joins, walks into a new area the server has to make, and is saved;
2. player IDs, open: no ID is refused, a first login makes an ID, a wrong
   password is refused, the same ID on a second device gets the same character
   back, and a device that played before IDs keeps its character;
3. player IDs, closed: an unknown ID is refused until `account add` makes it.

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
    # World deltas and compressed transfers (coop_world_delta.gd, coop_blob.gd).
    check = subprocess.run(command + ["--headless", "-s", os.path.abspath("server/coop_traffic_check.gd")], capture_output=True, text=True, errors="replace")
    if "COOP TRAFFIC CHECK: 0 failed" not in check.stdout: print(check.stdout[-2000:], check.stderr[-2000:]); print("SMOKE FAIL: co-op traffic check"); sys.exit(1)
    print("co-op traffic check ok")
    # The phone's list of saved servers: add, edit, delete, survive a restart, join.
    check = subprocess.run(command + ["--headless", "-s", os.path.abspath("server/saved_servers_test.gd"), "--", "--touch-ui"], capture_output=True, text=True, errors="replace", timeout=900)
    found = re.search(r"SAVED SERVERS TEST: (\d+) checks, (\d+) failed", check.stdout)
    if not found or found.group(2) != "0": print(check.stdout[-3000:]); print("SMOKE FAIL: saved servers list"); sys.exit(1)
    print(f"saved servers list ok ({found.group(1)} checks)")

server_data = os.path.join(work, "server")
server = None


def start_server(name, extra):
    global server
    server = start(name, ["--server", "--port", port, "--world", "Smoke", "--size", "S", "--data", server_data, "--no-upnp", "--area-size", "S"] + extra)
    started = time.time()
    wait_for(name, server, "listening on TCP port " + port, 900)
    print(f"{name} ready in {time.time() - started:.0f}s")
    return name


def stop_server(name):
    saves = text(name).count("SERVER world saved")
    send(server, "stop")
    # Closing the input as the launcher does lets the console-reading thread end
    # (on Linux the process otherwise waits for it at exit).
    server.stdin.close()
    try: server.wait(120)
    except subprocess.TimeoutExpired: fail(f"{name} did not stop")
    if text(name).count("SERVER world saved") <= saves: fail(f"{name} did not save on stop")


def join(name, args, needle, build="smoke-a"):
    """Runs a client to its end; its log must contain `needle`."""
    client = start(name, ["--join", "127.0.0.1:" + port, "--data", os.path.join(work, "device-" + name.split("-")[0])] + args, build)
    try: client.wait(900)
    except subprocess.TimeoutExpired: client.kill(); fail(f"{name} neither joined nor failed")
    if needle not in text(name): fail(f"{name}: expected {needle!r}")
    return text(name)


def actor_of(name):
    found = re.search(r"CLIENT joined world (\w+) in area (\S+) .* as (\w+)", text(name))
    if not found: fail(f"{name} did not join")
    return found.groups()


def device_actor(device):
    token = re.search(r'token="(\w+)"', open(os.path.join(work, "device-" + device, "coop_identity.cfg")).read()).group(1)
    return hashlib.sha256(token.encode()).hexdigest()


try:
    # --- 1: no player IDs, the shared password ---------------------------------
    run = start_server("server1", ["--accounts", "off", "--password", "smoke"])
    join("stranger", ["--password", "smoke"], "DIFFERENT GAME BUILD", build="smoke-b")
    print("another build refused")
    join("intruder", ["--password", "wrong"], "WRONG PASSWORD")
    print("wrong shared password refused")
    # The client also walks into a new area, which the server must make for it.
    join("old", ["--password", "smoke", "--travel", "--quit-after-join"], "CLIENT travelled to area 1,0")
    world_id = actor_of("old")[0]
    if "SERVER made area 1,0" not in text(run): fail("the server did not make the new area")
    print("client joined; the server made the new area it walked into")
    stop_server(run)
    world = os.path.join(server_data, "online_worlds", world_id, "world.json")
    if "player/" + device_actor("old") not in json.load(open(world, encoding="utf-8"))["payload"]: fail("the client's player is not in the saved world")
    print("server saved the world with the client's player in it")

    # --- 2: player IDs, a first login makes the ID -----------------------------
    run = start_server("server2", [])
    join("noid", ["--quit-after-join"], "NEEDS A PLAYER ID")
    print("a player without an ID refused")
    join("phone", ["--id", "Alice", "--password", "secret-1", "--travel", "--quit-after-join"], "CLIENT travelled to area 1,0")
    _, _, alice = actor_of("phone")
    if "SERVER new player ID: alice" not in text(run): fail("the new ID was not registered")
    print("first login made the ID alice")
    join("tablet-wrong", ["--id", "alice", "--password", "secret-2"], "WRONG PLAYER ID OR PASSWORD")
    print("wrong password for alice refused")
    join("tablet", ["--id", "ALICE", "--password", "secret-1", "--quit-after-join"], "CLIENT joined world")
    _, area, again = actor_of("tablet")
    if again != alice or area != "1,0": fail(f"alice on a second device got {again} in {area}, not {alice} in 1,0")
    print("alice on a second device got her character back, where she left it")
    join("old-id", ["--id", "bob", "--password", "secret-3", "--quit-after-join"], "CLIENT joined world")
    if actor_of("old-id")[2] != device_actor("old")[:12]: fail("a device that played before IDs did not keep its character")
    print("a device that played before IDs kept its character as bob")
    stop_server(run)
    stored = open(os.path.join(server_data, "accounts.json"), encoding="utf-8").read()
    accounts = json.loads(stored)["accounts"]
    if set(accounts) != {"alice", "bob"} or "secret-1" in stored or not all(len(a["verifier"]) == 64 and a["salt"] for a in accounts.values()):
        fail("accounts.json is not just salted hashes of alice and bob")
    print("accounts.json holds salted hashes only")

    # --- 3: closed: only IDs made on the server --------------------------------
    run = start_server("server3", ["--accounts", "closed"])
    join("carol-unknown", ["--id", "carol", "--password", "pass-4"], "UNKNOWN PLAYER ID")
    send(server, "account add carol pass-4")
    wait_for(run, server, "carol can now log in", 30)
    join("carol", ["--id", "carol", "--password", "pass-4", "--quit-after-join"], "CLIENT joined world")
    print("closed server: unknown ID refused, admitted after account add")
    stop_server(run)
    print("SMOKE OK: builds, shared password, server-made area, saves, and player IDs (open and closed) all behave")
finally:
    if server is not None and server.poll() is None: server.kill()
