"""Dedicated server console commands against a real headless server and clients:
`maxplayers` (live, saved to server.cfg with its comments kept), up to that many
players at once (more than the 4 of before) and one more turned away, `list
on|off` against the lobby directory run locally (node), `restart 3` (players
see the countdown 3, 2, 1, are told why they are dropped, the server ends with
the launcher's restart code and comes back up listed), `stop 5` + `cancel`, and
`stop 2`.

    python server/dedicated_commands_test.py GODOT [--clients N]   (default 5)

Run from the repository root with node on the PATH. Exits 0 on success."""
import json, os, socket, subprocess, sys, tempfile, time, urllib.request

godot = sys.argv[1]
clients = int(sys.argv[sys.argv.index("--clients") + 1]) if "--clients" in sys.argv else 5
command = [godot, "--path", "project"]
work = tempfile.mkdtemp(prefix="pw-server-commands-")
port = "54778"
logs, processes = {}, []
RESTART_EXIT = 75


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0)); return s.getsockname()[1]


def start(name, args, stdin=None):
    logs[name] = os.path.join(work, name + ".log")
    env = dict(os.environ, POKEWILDS_BUILD_ID="commands", POKEWILDS_COMPAT_ID="commands")
    process = subprocess.Popen(command + ["--headless"] + args, stdin=stdin, stdout=open(logs[name], "wb"), stderr=subprocess.STDOUT, env=env)
    processes.append(process)
    return process


def text(name):
    return open(logs[name], "rb").read().decode("utf-8", "replace")


def fail(reason):
    for name in logs:
        print(f"----- {name} log (last lines) -----")
        print("\n".join(text(name).splitlines()[-30:]))
    print("COMMANDS FAIL:", reason)
    sys.exit(1)


def wait_for(name, needle, seconds, process=None, count=1):
    deadline = time.time() + seconds
    while time.time() < deadline:
        if text(name).count(needle) >= count: return
        if process is not None and process.poll() is not None: fail(f"{name} exited ({process.returncode}) before {needle!r}")
        time.sleep(0.5)
    fail(f"{name}: no {needle!r} after {seconds}s")


def send(line):
    server.stdin.write((line + "\n").encode()); server.stdin.flush()


def listed(servers=True):
    with urllib.request.urlopen(f"{directory}/v1/lobbies" + ("?servers=1" if servers else "")) as answer:
        return json.load(answer)["lobbies"]


def until(check, seconds, what):
    deadline = time.time() + seconds
    while time.time() < deadline:
        if check(): return
        time.sleep(0.5)
    fail(what)


def start_server(name):
    global server
    server = start(name, ["--server", "--port", port, "--world", "Commands", "--size", "S", "--data", data, "--config", config,
        "--accounts", "off", "--no-upnp", "--area-size", "S"], subprocess.PIPE)
    wait_for(name, "listening on TCP port " + port, 900, server)
    return name


def join(index):
    name = f"player{index}"
    start(name, ["--join", "127.0.0.1:" + port, "--data", os.path.join(work, name)])
    return name


try:
    lobby_port = free_port()
    directory = f"http://127.0.0.1:{lobby_port}"
    logs["directory"] = os.path.join(work, "directory.log")
    processes.append(subprocess.Popen(["node", "lobby-directory/test/local_server.mjs", str(lobby_port)], stdout=open(logs["directory"], "wb"), stderr=subprocess.STDOUT))
    wait_for("directory", "lobby list on", 30)
    data = os.path.join(work, "server")
    os.makedirs(data)
    # The directory to announce to: [lobby] url in the data folder, as on a phone.
    open(os.path.join(data, "zerotier.cfg"), "w").write(f'[lobby]\nurl="{directory}"\n')
    config = os.path.join(work, "server.cfg")
    open(config, "w").write("; my notes\n[server]\n; Players at once.\nmax_players=4\n")

    run = start_server("server1")
    send("maxplayers 99")
    wait_for(run, "usage: maxplayers", 30)
    send(f"maxplayers {clients}")
    wait_for(run, f"max players {clients}", 30)
    saved = open(config).read()
    if f"max_players={clients}" not in saved or "; my notes" not in saved or "; Players at once." not in saved: fail("server.cfg not updated in place: " + saved)
    print(f"maxplayers {clients}: live and saved, comments kept")

    send("list on")
    wait_for(run, "listed in the online games list", 60)
    until(lambda: any(l.get("kind") == "server" for l in listed()), 30, "the server is not in the list")
    entry = next(l for l in listed() if l["kind"] == "server")
    if entry["max"] != clients or entry["port"] != int(port) or entry["players"] != 0 or entry["name"] != "Commands": fail(f"listed as {entry}")
    if any(l.get("kind") == "server" for l in listed(servers=False)): fail("older builds were shown the server")
    if "listed=true" not in open(config).read(): fail("listed not saved")
    send("list off")
    wait_for(run, "removed from the online games list", 30)
    if listed(): fail("still listed after list off")
    send("list on")
    wait_for(run, "listed in the online games list", 60, count=2)
    print("list on/off: announced, removed, announced again")

    # As many players as allowed, one at a time (each loads the world), then one too many.
    started = time.time()
    names = []
    for index in range(1, clients + 1):
        names.append(join(index))
        wait_for(names[-1], "CLIENT joined world", 900, processes[-1])
        wait_for(run, f"({index}/{clients})", 60)
    print(f"{clients} players in at once ({time.time() - started:.0f}s)")
    until(lambda: any(l["players"] == clients for l in listed()), 60, "the list did not show the players")
    extra = join(clients + 1)
    wait_for(extra, "CLIENT ERROR: THIS GAME IS FULL.", 180, None)
    if "CLIENT joined" in text(extra): fail("a player over the limit got in")
    print("one more is told the game is full; the list shows them all")

    # restart 3: everyone sees 3, 2, 1, then why they were dropped.
    send("restart 3")
    try: server.wait(180)
    except subprocess.TimeoutExpired: fail("restart did not end the server")
    if server.returncode != RESTART_EXIT: fail(f"restart ended with {server.returncode}, not {RESTART_EXIT}")
    for name in names:
        wait_for(name, "SERVER RESTARTING. TRY AGAIN IN A MOMENT.", 30)
        for seconds in (3, 2, 1):
            if f"ONLINE notice: Server restarting in {seconds} s" not in text(name): fail(f"{name} did not see {seconds}")
    if "SERVER world saved" not in text(run): fail("not saved before the restart")
    if any(l.get("kind") == "server" for l in listed()): fail("still listed while restarting")
    print("restart 3: countdown seen by every player, saved, dropped with the reason, unlisted")
    for process in processes[2:]: process.kill()

    # What start_server.bat does on that exit code: start it again.
    run = start_server("server2")
    wait_for(run, "listed in the online games list", 60)
    if f"max_players={clients}" not in open(config).read(): fail("max players lost")
    print("came back up, listed again with the saved settings")

    last = join(clients + 2)
    wait_for(last, "CLIENT joined world", 900)
    send("stop 5")
    wait_for(last, "ONLINE notice: Server shutting down in 4 s", 30)
    send("cancel")
    wait_for(last, "ONLINE notice: Server shutdown cancelled.", 30)
    time.sleep(6)
    if server.poll() is not None: fail("cancel did not stop the countdown")
    send("stop 2")
    try: server.wait(180)
    except subprocess.TimeoutExpired: fail("stop 2 did not end the server")
    if server.returncode != 0: fail(f"stop ended with {server.returncode}")
    wait_for(last, "THE SERVER WAS SHUT DOWN.", 30)
    if listed(): fail("still listed after stop")
    print("stop 5 + cancel keeps it running; stop 2 counts down, saves, stops, unlists")
    print(f"COMMANDS OK: maxplayers, {clients} players, list on/off, restart, cancel and stop all behave")
finally:
    for process in processes:
        if process.poll() is None: process.kill()
