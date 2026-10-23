"""Co-op traffic and CPU profile: a real headless dedicated server and real
players (coop_net_profile.gd), through these phases, each printed per message
kind by the server and by every player:

  idle1      one player standing still
  walk1      one player walking
  idleN      N players standing still in the spawn area
  walkN      N players walking in the spawn area
  walkNsplit N players walking, the odd ones in the area east of it
  walkNaway  N players walking, all in the area east (the server's own area empty)
  walkNlong  (with --long S) N players walking back in the spawn area for S seconds,
             long enough for autosaves (--autosave MINUTES) and journal folds
  walkNfour  N players walking in four areas: one in four stays, the others go
             west, east and south of where they are (two areas the server makes)

After each walking phase every player's wild Pokemon are compared with the
server's, in the player's area (CONSISTENCY: how many stand where the server
has them; a few may be a step apart, moving as the two looked). The last
player joins while the others walk (joinN). The server also prints
its frame time distribution per phase (FRAMES) and, for frames over 16 ms,
what took the most (SPIKES: the sections a test build times into Engine meta
"probe_frame", name -> microseconds this frame, "_top" the outermost summed).

    python server/coop_net_profile.py GODOT [--clients N] [--seconds S] [--long S] [--autosave MINUTES] [--breakdown]
        [--project DIR] [--world-from DIR] [--world NAME] [--port N] [--area-generation auto|on|off] [--keep]

--world-from copies a server data folder (a server_data, or a server folder
kept with --keep) and --world names the world in it to load.

--breakdown then prints the server's frame cost by script (each script's nodes
stopped for a moment while the players keep walking).
Run from the repository root. Prints the PROFILE lines and a summary table."""
import json, os, re, shutil, subprocess, sys, tempfile, time

godot = sys.argv[1]
clients = int(sys.argv[sys.argv.index("--clients") + 1]) if "--clients" in sys.argv else 8
seconds = float(sys.argv[sys.argv.index("--seconds") + 1]) if "--seconds" in sys.argv else 15
long_seconds = float(sys.argv[sys.argv.index("--long") + 1]) if "--long" in sys.argv else 0
world = sys.argv[sys.argv.index("--world") + 1] if "--world" in sys.argv else "Profile"
autosave = sys.argv[sys.argv.index("--autosave") + 1] if "--autosave" in sys.argv else "5"
work = tempfile.mkdtemp(prefix="pw-netprofile-")
port = int(sys.argv[sys.argv.index("--port") + 1]) if "--port" in sys.argv else 54793
script = os.path.abspath("server/coop_net_profile.gd")
phase_file = os.path.join(work, "phase.txt")
project = sys.argv[sys.argv.index("--project") + 1] if "--project" in sys.argv else "project"
override = os.path.join(project, "override.cfg")
made_override = not os.path.exists(override)
if made_override:
    with open(override, "w") as f: f.write('[physics]\n2d/physics_engine="Dummy"\n')
env = dict(os.environ, POKEWILDS_BUILD_ID="profile", POKEWILDS_COMPAT_ID="profile")
logs, processes = {}, []


def start(name, args, stdin=None):
    logs[name] = os.path.join(work, name + ".log")
    p = subprocess.Popen([godot, "--path", project, "--headless", "-s", script] + args, stdin=stdin,
        stdout=open(logs[name], "wb"), stderr=subprocess.STDOUT, env=env)
    processes.append(p)
    return p


def text(name): return open(logs[name], "rb").read().decode("utf-8", "replace")


def wait_for(name, needle, limit):
    deadline = time.time() + limit
    while needle not in text(name):
        if time.time() > deadline or "CLIENT ERROR" in text(name): print(text(name)[-3000:]); sys.exit(f"PROFILE FAIL: {name} no {needle!r}")
        time.sleep(0.5)


def set_phase(name):
    open(phase_file, "w").write(name)
    time.sleep(0.6)


def measure(name, length=seconds):
    print("phase", name, flush=True)
    set_phase(name)
    time.sleep(length)
    set_phase("rest")


try:
    set_phase("setup")
    # The same world for runs to compare: a copy of a server folder kept from an earlier run.
    if "--world-from" in sys.argv: shutil.copytree(sys.argv[sys.argv.index("--world-from") + 1], os.path.join(work, "server"))
    config = os.path.join(work, "server.cfg")
    open(config, "w").write(f"[server]\nmax_players={clients}\nautosave_minutes={autosave}\n")
    server = start("server", ["--server", "--port", str(port), "--world", world, "--size", "S", "--data", os.path.join(work, "server"),
        "--no-upnp", "--area-size", "S", "--accounts", "off", "--config", config]
        + (["--area-generation", sys.argv[sys.argv.index("--area-generation") + 1]] if "--area-generation" in sys.argv else [])
        + ["--", "--phase=" + phase_file], subprocess.PIPE)
    wait_for("server", "listening on TCP port", 900)

    def join(i):
        start(f"client{i}", ["--join", f"127.0.0.1:{port}", "--data", os.path.join(work, f"c{i}"), "--", "--phase=" + phase_file, f"--index={i}"])
        wait_for(f"client{i}", "CLIENT joined world", 900)

    join(0)
    time.sleep(3)
    measure("idle1"); measure("walk1")
    for i in range(1, clients - 1): join(i)
    if clients > 1:
        # The last one joins while the others walk.
        print("phase", f"join{clients}", flush=True)
        set_phase(f"join{clients}")
        join(clients - 1)
        set_phase("rest")
    time.sleep(5)
    measure(f"idle{clients}"); measure(f"walk{clients}")
    # The odd players travel east first (the server makes the area); measured once they are there.
    set_phase(f"walk{clients}split-travel")
    deadline = time.time() + 600
    while sum(text(f"client{i}").count("travelled to") for i in range(1, clients, 2)) < clients // 2 and time.time() < deadline: time.sleep(1)
    time.sleep(3)
    measure(f"walk{clients}split")
    set_phase(f"walk{clients}away-travel")
    deadline = time.time() + 600
    while sum(text(f"client{i}").count("travelled to") for i in range(clients)) < clients and time.time() < deadline: time.sleep(1)
    time.sleep(3)
    measure(f"walk{clients}away")
    if long_seconds > 0:
        # Everyone back in the spawn area (the server's own), walking for a long time.
        set_phase(f"walk{clients}long-travel")
        deadline = time.time() + 600
        while sum(text(f"client{i}").count("travelled back") for i in range(clients)) < clients and time.time() < deadline: time.sleep(1)
        time.sleep(3)
        measure(f"walk{clients}long", long_seconds)
    # Four areas: one player in four stays, the others go west, east and south.
    movers = [i for i in range(clients) if i % 4 != 0]
    set_phase(f"walk{clients}four-travel")
    deadline = time.time() + 900
    while sum(text(f"client{i}").count("spread to") for i in movers) < len(movers) and time.time() < deadline: time.sleep(1)
    time.sleep(3)
    measure(f"walk{clients}four")
    if "--breakdown" in sys.argv:
        set_phase("walk-breakdown")
        wait_for("server", "PROFILE SERVER breakdown", 900)
        time.sleep(3)
    time.sleep(2)
    rows = []
    for name in logs:
        for line in text(name).splitlines():
            if line.startswith("PROFILE") and " rest " not in line and " setup " not in line and ("-travel " not in line or " FRAMES " in line or " SPIKES " in line): rows.append(line)
    # Each player's wild Pokemon against the server's, phase by phase.
    for dump in sorted(f for f in os.listdir(work) if f.startswith("wild_SERVER_")):
        phase = dump[len("wild_SERVER_"):-len(".json")]
        server_areas = json.load(open(os.path.join(work, dump)))
        for i in range(clients):
            path = os.path.join(work, f"wild_CLIENT{i}_{phase}.json")
            if not os.path.exists(path): continue
            for area, cells in json.load(open(path)).items():
                truth = server_areas.get(area)
                if truth is None: rows.append(f"PROFILE CONSISTENCY {phase} client{i} area {area}: not run by the server"); continue
                shared = [k for k in cells if k in truth]
                same = sum(1 for k in shared if cells[k] == truth[k])
                rows.append(f"PROFILE CONSISTENCY {phase} client{i} area {area}: {same}/{len(shared)} where the server has them, "
                    f"{len(cells) - len(shared)} only on the player, {len(truth) - len(shared)} only on the server")
    print("\n".join(rows))
finally:
    try: server.stdin.write(b"stop\n"); server.stdin.close(); server.wait(60)
    except Exception: pass
    for p in processes:
        if p.poll() is None: p.kill()
    if made_override and os.path.exists(override): os.remove(override)
    if "--keep" not in sys.argv: shutil.rmtree(work, ignore_errors=True)
    else: print("logs in", work)
