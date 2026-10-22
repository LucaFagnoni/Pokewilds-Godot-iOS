"""Co-op actions over a simulated phone connection: a real headless dedicated
server, the netem proxy (netem_proxy.py) in front of it, and a real game
client (coop_latency_probe.gd) that joins through the proxy and times each
action from the input to its result on the client. Fails when a common action
takes longer than its budget (3 round trips + 300 ms unless the action says
otherwise).

    python server/coop_latency_probe.py GODOT [--profile 4g|bad4g|lan] [--skip-spawn] [--keep]

The player is a long-played one (explored map, full Pokedex, party and bag, a
box of 200 Pokemon). --skip-spawn leaves out the actions in the server's own
area; --keep keeps the logs.

Run from the repository root (GODOT = editor binary, runs project/). Exits 0
when every action is within its budget."""
import os, re, shutil, subprocess, sys, tempfile, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from netem_proxy import Proxy, PROFILES

godot = sys.argv[1]
profile = sys.argv[sys.argv.index("--profile") + 1] if "--profile" in sys.argv else "4g"
work = tempfile.mkdtemp(prefix="pw-latency-")
server_port, proxy_port = 54791, 54792
override = os.path.join("project", "override.cfg")
made_override = not os.path.exists(override)
if made_override:
    with open(override, "w") as f: f.write('[physics]\n2d/physics_engine="Dummy"\n')
env = dict(os.environ, POKEWILDS_BUILD_ID="probe", POKEWILDS_COMPAT_ID="probe")
server_log = os.path.join(work, "server.log")
server = subprocess.Popen([godot, "--path", "project", "--headless", "--server", "--port", str(server_port), "--world", "Probe", "--size", "S",
    "--data", os.path.join(work, "server"), "--no-upnp", "--area-size", "S", "--accounts", "off"],
    stdin=subprocess.PIPE, stdout=open(server_log, "wb"), stderr=subprocess.STDOUT, env=env)


def text(path): return open(path, "rb").read().decode("utf-8", "replace")


try:
    deadline = time.time() + 900
    while "listening on TCP port" not in text(server_log):
        if server.poll() is not None or time.time() > deadline: print(text(server_log)[-3000:]); sys.exit("PROBE FAIL: server did not start")
        time.sleep(1)
    Proxy(proxy_port, "127.0.0.1", server_port, profile).start()
    p = PROFILES[profile]
    rtt = 2 * p["delay"]
    print(f"profile {profile}: one-way {p['delay']}+-{p['jitter']} ms, up {p['up']} kbit/s, down {p['down']} kbit/s, stalls {p['stall']*100:.0f}% x {p['stall_ms']} ms")
    client_log = os.path.join(work, "client.log")
    client = subprocess.run([godot, "--path", "project", "--headless", "-s", os.path.abspath("server/coop_latency_probe.gd"),
        "--join", f"127.0.0.1:{proxy_port}", "--data", os.path.join(work, "device"), "--", f"--rtt={rtt}"] + [a for a in sys.argv if a == "--skip-spawn"],
        stdout=open(client_log, "wb"), stderr=subprocess.STDOUT, env=env, timeout=1800)
    out = text(client_log)
    print("\n".join(line for line in out.splitlines() if line.startswith("PROBE")))
    failed = re.search(r"PROBE RESULT: (\d+) over budget", out)
    if not failed: print(out[-4000:]); print("----- server -----"); print(text(server_log)[-3000:]); sys.exit("PROBE FAIL: the client did not finish")
    if failed.group(1) != "0": print("----- server -----"); print(text(server_log)[-2000:]); sys.exit(f"PROBE FAIL: {failed.group(1)} actions over budget")
    print("PROBE OK")
finally:
    try: server.stdin.write(b"stop\n"); server.stdin.close(); server.wait(60)
    except Exception: server.kill()
    if made_override and os.path.exists(override): os.remove(override)
    if "--keep" not in sys.argv: shutil.rmtree(work, ignore_errors=True)
    else: print("logs in", work)
