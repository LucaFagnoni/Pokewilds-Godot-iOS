"""Makes server/fixtures/online: the folder of an online world as THIS game saves
it (world.json, host.save, journal, area snapshots) as a zip, after a short
dedicated server run: a player joins, walks into a new area the server makes,
and leaves.
fixture_load_test.gd loads it with the code of the day. Run it again only to make
a new fixture of the current format: keep the old ones, they are the point.

    python server/make_online_fixture.py GODOT OUTPUT.zip     (from the repository root)

Never point it at a real server's data: it only writes OUTPUT.zip."""
import json, os, subprocess, sys, tempfile, time, zipfile

godot, out = sys.argv[1], os.path.abspath(sys.argv[2])
work = tempfile.mkdtemp(prefix="pw-online-fixture-")
port = "54931"
env = dict(os.environ, POKEWILDS_BUILD_ID="fixture", POKEWILDS_COMPAT_ID="fixture")
command = [godot, "--path", "project", "--headless"]


def start(name, args):
    log = os.path.join(work, name + ".log")
    return subprocess.Popen(command + args, stdin=subprocess.PIPE, stdout=open(log, "wb"), stderr=subprocess.STDOUT, env=env), log


def wait_for(log, needle, seconds):
    deadline = time.time() + seconds
    while time.time() < deadline:
        if needle in open(log, "rb").read().decode("utf-8", "replace"): return
        time.sleep(1)
    sys.exit(f"no {needle!r} in {log} after {seconds} s")


data = os.path.join(work, "server")
server, log = start("server", ["--server", "--port", port, "--world", "Fixture", "--size", "S", "--data", data,
                               "--no-upnp", "--area-size", "S", "--accounts", "off"])
wait_for(log, "listening on TCP port " + port, 900)
for name in ["walker"]:
    args = ["--join", "127.0.0.1:" + port, "--data", os.path.join(work, "device-" + name), "--quit-after-join"]
    client, client_log = start(name, args + (["--travel"] if name == "walker" else []))
    client.wait(900)
server.stdin.write(b"stop\n"); server.stdin.flush(); server.stdin.close()
server.wait(120)
if "SERVER world saved" not in open(log, "rb").read().decode("utf-8", "replace"): sys.exit("the server did not save")
worlds = os.path.join(data, "online_worlds")
(world,) = os.listdir(worlds)
# Backups, the world cache (the seed makes it again) and the area
# snapshots no area record names (older versions) are not needed.
home = os.path.join(worlds, world)
records = json.loads(json.load(open(os.path.join(home, "world.json"), encoding="utf-8"))["payload"])["state"]["records"]
snapshots = {"snapshots/" + r["snapshot"] for k, r in records.items() if k.startswith("area/")}
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
    for folder, _, files in os.walk(os.path.join(worlds, world)):
        for name in files:
            path = os.path.join(folder, name)
            relative = os.path.relpath(path, os.path.join(worlds, world))
            relative = relative.replace(os.sep, "/")
            old_snapshot = relative.startswith("snapshots/") and relative not in snapshots
            if not (relative.startswith(("backups", "world_cache")) or name.endswith(".pending") or name == "host.save.bak" or old_snapshot):
                archive.write(path, relative)
print("online fixture", out, os.path.getsize(out), "bytes; world id", world)
