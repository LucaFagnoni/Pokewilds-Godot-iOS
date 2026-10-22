"""Another player's movement as drawn over a phone link: a real headless
dedicated server, netem_proxy.py in front of it, and two real players
(remote_motion_test.gd) joined through it, one walking (a loop walking,
running and at riding speed, a teleport of 4 tiles and back, off the other's
screen and back) and one watching. From both players' logs (wall-clock ms):

  walk    largest step per frame, p99, steps over 1 tile, steps going backwards
          along the walker's path by over 2 px (rubber-banding; a guess past a
          corner during a stall is eased back by up to ~2 px a frame), how far behind (lag), the
          longest freeze while the walker kept moving, top drawn speed
  teleport  drawn in one step (no flight across), the only step over a tile
  away/zoom/back  hidden off screen and the cost per frame on and off screen,
          shown again when the zoom brings it into view, where it should be
          when it walks back in; the minimap marker keeps moving meanwhile

    python server/remote_motion_test.py GODOT [--profile lan|4g|bad4g] [--report-only] [--keep] [--shots DIR]

--report-only prints the numbers without failing (to measure the old code).
--shots DIR runs the observer in a window and saves contact sheets (16 frames)
of a stall and of the walker coming into view there.
Run from the repository root. Exits 0 when every check holds."""
import math, os, shutil, subprocess, sys, tempfile, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from netem_proxy import Proxy, PROFILES

godot = sys.argv[1]
profile = sys.argv[sys.argv.index("--profile") + 1] if "--profile" in sys.argv else "4g"
work = tempfile.mkdtemp(prefix="pw-motion-")
server_port, proxy_port = 54795, 54796
override = os.path.join("project", "override.cfg")
made_override = not os.path.exists(override)
if made_override:
    with open(override, "w") as f: f.write('[physics]\n2d/physics_engine="Dummy"\n')
env = dict(os.environ, POKEWILDS_BUILD_ID="motion", POKEWILDS_COMPAT_ID="motion")
script = os.path.abspath("server/remote_motion_test.gd")
phase_file = os.path.join(work, "phase.txt")
processes, logs = [], {}
failures = []


def text(path): return open(path, "rb").read().decode("utf-8", "replace") if os.path.exists(path) else ""


shots = sys.argv[sys.argv.index("--shots") + 1] if "--shots" in sys.argv else ""


def start(name, args):
    logs[name] = os.path.join(work, name + ".out")
    # --shots: the observer is windowed and saves contact sheets of its screen there.
    window = ["--rendering-driver", "opengl3", "--resolution", "1280x720"] if shots and name == "observer" else ["--headless"]
    p = subprocess.Popen([godot, "--path", "project"] + window + args, stdin=subprocess.PIPE,
        stdout=open(logs[name], "wb"), stderr=subprocess.STDOUT, env=env)
    processes.append(p)
    return p


def wait_for(name, needle, limit):
    deadline = time.time() + limit
    while needle not in text(logs[name]):
        if time.time() > deadline: print(text(logs[name])[-3000:]); sys.exit(f"MOTION FAIL: {name} no {needle!r}")
        time.sleep(0.5)


def set_phase(name, seconds=0.0):
    open(phase_file + ".tmp", "w").write(name)
    os.replace(phase_file + ".tmp", phase_file)
    time.sleep(seconds)


def check(ok, what):
    print(("  ok   " if ok else "  FAIL ") + what)
    if not ok: failures.append(what)


def read(path):
    rows = {"W": [], "O": [], "M": [], "E": [], "P": [], "C": [], "U": []}
    for line in text(path).splitlines():
        parts = line.split()
        if not parts or parts[0] not in rows: continue
        rows[parts[0]].append(parts[1:])
    return rows


def phase_spans(rows):
    spans, marks = {}, [(float(p[0]), p[1]) for p in rows["P"] if len(p) > 1]
    for i, (t, name) in enumerate(marks): spans[name] = (t, marks[i + 1][0] if i + 1 < len(marks) else 1e18)
    return spans


def analyse(walker, observer):
    ws = [(float(r[0]), float(r[1]), float(r[2])) for r in walker["W"]]
    obs = [(float(r[0]), float(r[1]), float(r[2]), r[3] == "1") for r in observer["O"]]
    spans = phase_spans(observer)
    wt = [w[0] for w in ws]
    import bisect

    def truth_velocity(t):
        i = bisect.bisect_left(wt, t)
        a, b = ws[max(0, i - 3)], ws[min(len(ws) - 1, i + 3)]
        dt = max(1.0, b[0] - a[0])
        return ((b[1] - a[1]) / dt, (b[2] - a[2]) / dt)

    def match(t, x, y, window=2000.0):
        # The walker's moment nearest to where it is drawn, within the last 2 s.
        lo, hi = bisect.bisect_left(wt, t - window), bisect.bisect_right(wt, t + 30)
        best, at = 1e9, None
        for i in range(lo, hi):
            d = math.hypot(ws[i][1] - x, ws[i][2] - y)
            if d < best - 1e-6 or (abs(d - best) < 1e-6 and at is not None and ws[i][0] > at): best, at = d, ws[i][0]
        return best, at

    out = {}
    s, e = spans.get("walk", (0, 0))
    walk = [o for o in obs if s + 1500 <= o[0] <= e and o[3]]
    steps, back, lags, far = [], 0, [], []
    still_from, longest_still = None, 0.0
    speeds = []
    for i in range(1, len(walk)):
        a, b = walk[i - 1], walk[i]
        step = math.hypot(b[1] - a[1], b[2] - a[2])
        steps.append(step)
        dist, at = match(b[0], b[1], b[2])
        if at is not None:
            lags.append(b[0] - at); far.append(dist)
            vx, vy = truth_velocity(at)
            norm = math.hypot(vx, vy)
            if norm > 0.01 and ((b[1] - a[1]) * vx + (b[2] - a[2]) * vy) / norm < -2.0:
                back += 1
                print("MOTION backward at %.0f ms: drawn (%.1f,%.1f)->(%.1f,%.1f), walker then moving (%.2f,%.2f) px/ms" % (b[0] - s, a[1], a[2], b[1], b[2], vx, vy))
        if step < 0.01:
            still_from = still_from if still_from is not None else a[0]
            longest_still = max(longest_still, b[0] - still_from)
        else: still_from = None
    for i in range(len(walk)):
        j = i
        while j < len(walk) and walk[j][0] - walk[i][0] < 100: j += 1
        if j < len(walk): speeds.append(math.hypot(walk[j][1] - walk[i][1], walk[j][2] - walk[i][2]) / (walk[j][0] - walk[i][0]) * 1000)
    srt = sorted(steps) or [0]
    lags.sort()
    out["walk"] = dict(frames=len(walk), max_step=srt[-1], p99=srt[int(len(srt) * 0.99)], over8=sum(1 for x in steps if x > 8), over16=sum(1 for x in steps if x > 16),
        backward=back, lag_median=lags[len(lags) // 2] if lags else 0, lag_p99=lags[int(len(lags) * 0.99)] if lags else 0, off_path_max=max(far or [0]),
        freeze_ms=longest_still, top_speed=max(speeds or [0]))
    # Teleport: the 64 px jump drawn as one step.
    s, e = spans.get("teleport", (0, 0))
    tele = [o for o in obs if s <= o[0] <= e and o[3]]
    tsteps = [math.hypot(tele[i][1] - tele[i - 1][1], tele[i][2] - tele[i - 1][2]) for i in range(1, len(tele))]
    out["teleport"] = dict(jumps=sum(1 for x in tsteps if x > 48), between=sum(1 for x in tsteps if 3 < x <= 48), biggest=max(tsteps or [0]))
    # Off screen, zoom, back.
    s, e = spans.get("far", (0, 0))
    away = [o for o in obs if s <= o[0] <= e]
    out["away"] = dict(hidden_at_end=bool(away) and not away[-1][3], hidden_frames=sum(1 for o in away if not o[3]))
    s, e = spans.get("zoom", (0, 0))
    zoom = [o for o in obs if s <= o[0] <= e]
    zoom_out = [o for o in zoom if o[0] - s < 2000]
    zoom_in = [o for o in zoom if o[0] - s > 2300]
    out["zoom"] = dict(shown_zoomed_out=bool(zoom_out) and zoom_out[-1][3], hidden_again=bool(zoom_in) and not zoom_in[-1][3])
    marks = [(float(r[0]), float(r[1]), float(r[2])) for r in observer["M"] if spans.get("far", (0, 0))[0] <= float(r[0]) <= spans.get("far", (0, 0))[1]]
    out["minimap"] = dict(markers=len(marks), moved=bool(marks) and math.hypot(marks[-1][1] - marks[0][1], marks[-1][2] - marks[0][2]) > 1.0)
    s, e = spans.get("back", (0, 0))
    back_rows = [o for o in obs if s <= o[0] <= e]
    entry = next((i for i in range(1, len(back_rows)) if back_rows[i][3] and not back_rows[i - 1][3]), None)
    if entry is not None:
        o = back_rows[entry]
        dist, at = match(o[0], o[1], o[2])
        nxt = back_rows[entry + 1] if entry + 1 < len(back_rows) else o
        out["entry"] = dict(off_path=dist, lag=o[0] - at if at else -1, next_step=math.hypot(nxt[1] - o[1], nxt[2] - o[2]))
    else: out["entry"] = dict(off_path=-1, lag=-1, next_step=-1)
    costs = {r[0]: (int(r[1]), int(r[2])) for r in observer["C"] if len(r) == 3}
    out["cost"] = {k: (v[0] / max(1, v[1])) for k, v in costs.items()}
    return out


def run():
    set_phase("setup")
    logs["server"] = os.path.join(work, "server.log")
    processes.append(subprocess.Popen([godot, "--path", "project", "--headless", "--server", "--port", str(server_port), "--world", "Motion", "--size", "S",
        "--data", os.path.join(work, "server"), "--no-upnp", "--area-size", "S", "--accounts", "off"],
        stdin=subprocess.PIPE, stdout=open(logs["server"], "wb"), stderr=subprocess.STDOUT, env=env))
    wait_for("server", "listening on TCP port", 900)
    Proxy(proxy_port, "127.0.0.1", server_port, profile).start()
    for role in ["observer", "walker"]:
        start(role, ["-s", script, "--join", f"127.0.0.1:{proxy_port}", "--data", os.path.join(work, role), "--",
            "--role=" + role, "--phase=" + phase_file, "--log=" + os.path.join(work, role + ".log")] + (["--shots=" + os.path.abspath(shots)] if shots else []))
        wait_for(role, "CLIENT joined world", 900)
    time.sleep(6)
    for name, seconds in [("walk", 22), ("rest", 1), ("teleport", 4.5), ("rest", 1), ("away", 5), ("far", 4), ("zoom", 4), ("back", 6), ("rest", 1)]: set_phase(name, seconds)
    set_phase("done", 3)


try:
    if "--logs" not in sys.argv:
        units = subprocess.run([godot, "--path", "project", "--headless", "-s", script, "--", "--role=units"], capture_output=True, env=env, timeout=600)
        print("\n".join(l for l in units.stdout.decode("utf-8", "replace").splitlines() if l.startswith("MOTION")))
        if "--report-only" not in sys.argv: check(units.returncode == 0, "the hand-fed checks pass")
    if "--logs" in sys.argv: work = sys.argv[sys.argv.index("--logs") + 1]
    else: run()
    walker, observer = read(os.path.join(work, "walker.log")), read(os.path.join(work, "observer.log"))
    r = analyse(walker, observer)
    p = PROFILES[profile]
    print(f"MOTION profile {profile}: one-way {p['delay']}+-{p['jitter']} ms, stalls {p['stall']*100:.0f}% x {p['stall_ms']} ms")
    w = r["walk"]
    print("MOTION walk: %d frames, max step %.1f px, p99 %.1f px, over 8 px %d, over 16 px %d, backward %d, lag median %.0f ms p99 %.0f ms, off path max %.1f px, longest freeze %.0f ms, top speed %.0f px/s"
        % (w["frames"], w["max_step"], w["p99"], w["over8"], w["over16"], w["backward"], w["lag_median"], w["lag_p99"], w["off_path_max"], w["freeze_ms"], w["top_speed"]))
    print("MOTION teleport: %(jumps)d jumps, %(between)d steps between, biggest %(biggest).1f px" % r["teleport"])
    print("MOTION away: hidden at end %(hidden_at_end)s (%(hidden_frames)d frames hidden); zoom: shown zoomed out %(shown_zoomed_out)s, hidden again %(hidden_again)s" % {**r["away"], **r["zoom"]})
    print("MOTION minimap: %(markers)d marker samples off screen, moved %(moved)s" % r["minimap"])
    print("MOTION entry: %(off_path).1f px off the walker's path, %(lag).0f ms behind, next step %(next_step).1f px" % r["entry"])
    print("MOTION cost per frame: " + ", ".join("%s %.1f us" % (k, v) for k, v in r["cost"].items()))
    if "--report-only" not in sys.argv:
        check(w["frames"] > 300, "the walk was seen (%d frames)" % w["frames"])
        check(w["over16"] == 0, "no step over a tile while walking (%d)" % w["over16"])
        check(w["backward"] == 0, "no step backwards along the path (%d)" % w["backward"])
        check(w["lag_p99"] < 1500, "lag bounded (p99 %.0f ms)" % w["lag_p99"])
        check(r["teleport"]["jumps"] == 2 and r["teleport"]["between"] <= 2, "a teleport is drawn as a jump (%(jumps)d jumps, %(between)d steps between)" % r["teleport"])
        check(r["away"]["hidden_at_end"], "hidden off screen")
        check(r["zoom"]["shown_zoomed_out"] and r["zoom"]["hidden_again"], "zooming out shows it, zooming back hides it")
        check(r["minimap"]["moved"], "the minimap marker moves while it is off screen")
        check(0 <= r["entry"]["off_path"] < 4 and r["entry"]["next_step"] < 8, "back on screen where it should be")
        on, off = r["cost"].get("walk", 0), r["cost"].get("far", 0)
        check(off < on, "off screen costs less (%.1f us against %.1f)" % (off, on))
        print("MOTION RESULT: %d failed" % len(failures))
        if failures: sys.exit(1)
finally:
    try: server.stdin.write(b"stop\n"); server.stdin.close(); server.wait(60)
    except Exception: pass
    for p in processes:
        if p.poll() is None: p.kill()
    if made_override and os.path.exists(override): os.remove(override)
    if "--keep" not in sys.argv and "--logs" not in sys.argv: shutil.rmtree(work, ignore_errors=True)
    else: print("logs in", work)
