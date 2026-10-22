"""The quick headless GDScript tests of server/, a few at a time, as CI runs them.
A test passes when Godot exits 0 and every "N failed" it printed says 0; one that
fails runs once more (a cold first run can miss a timer) and is told as a warning
when the second run passes. Failures become annotations on GitHub.

    python server/fast_tests.py GODOT [--jobs 4] [--only recall_test coop_ui_test ...]

Run from the repository root with a project/override.cfg that sets
[physics] 2d/physics_engine="Dummy" (the phones' engine has no other). Exits 0 on success."""
import concurrent.futures, os, re, subprocess, sys, time

# (script, arguments after "--"). Slowest first, so the last test does not start late.
TESTS = [
    ("coop_ui_test", ["--touch-ui"]),
    ("coop_chat_test", ["--touch-ui"]),
    ("autosave_test", ["--touch-ui"]),
    ("coop_menu_flow_test", ["--touch-ui"]),
    ("coop_menu_flow_test", []),
    ("save_kill_test", ["--touch-ui"]),
    ("server_ping_test", []),
    ("touch_surface_cache_test", ["--touch-ui"]),
    ("move_learn_test", ["--touch-ui"]),
    ("saved_servers_test", ["--touch-ui"]),
    ("status_hud_test", ["--touch-ui"]),
    ("solo_keyboard_test", ["--touch-ui"]),
    ("hints_test", ["--touch-ui"]),
    ("hints_test", []),
    ("compat_test", []),
    ("recall_test", []),
    ("coop_traffic_check", []),
    ("world_save_test", []),
]
TIMEOUT = 900


def run(godot, test, args):
    """-> (ok, seconds, output)"""
    command = [godot, "--headless", "--path", "project", "-s", f"../server/{test}.gd"] + (["--"] + args if args else [])
    started = time.time()
    try:
        done = subprocess.run(command, capture_output=True, timeout=TIMEOUT)
        output = (done.stdout + done.stderr).decode("utf-8", "replace")
        counts = re.findall(r"(\d+) failed", output)
        ok = done.returncode == 0 and bool(counts) and all(n == "0" for n in counts) and "SCRIPT ERROR" not in output
    except subprocess.TimeoutExpired as late:
        output, ok = ((late.stdout or b"") + (late.stderr or b"")).decode("utf-8", "replace") + f"\nTIMEOUT after {TIMEOUT} s", False
    return ok, time.time() - started, output


def annotation(kind, title, text):
    if os.environ.get("GITHUB_ACTIONS"):
        text = text.replace("%", "%25").replace("\r", "").replace("\n", "%0A")
        print(f"::{kind} title={title}::{text}", flush=True)


def one(godot, test, args):
    name = test + (" " + " ".join(args) if args else "")
    ok, seconds, output = run(godot, test, args)
    first = output
    if not ok:
        ok, again, output = run(godot, test, args)
        seconds += again
        if ok:
            annotation("warning", name, "failed once, passed on the second run (flaky). First run:\n" + "\n".join(first.splitlines()[-15:]))
    lines = output.splitlines()
    bad = [l for l in lines if "FAIL" in l or "SCRIPT ERROR" in l or "TIMEOUT" in l]
    if not ok:
        annotation("error", name, "\n".join((bad or lines)[-10:]))
    return name, ok, seconds, output, first != output and ok


def main():
    godot = sys.argv[1]
    jobs = int(sys.argv[sys.argv.index("--jobs") + 1]) if "--jobs" in sys.argv else 4
    only = sys.argv[sys.argv.index("--only") + 1:] if "--only" in sys.argv else []
    picked = [t for t in TESTS if not only or t[0] in only]
    failed = []
    started = time.time()
    with concurrent.futures.ThreadPoolExecutor(jobs) as pool:
        for name, ok, seconds, output, flaky in pool.map(lambda t: one(godot, *t), picked):
            print(f"{'PASS' if ok else 'FAIL'} {name} ({seconds:.0f} s){' (flaky: passed on the second run)' if flaky else ''}", flush=True)
            if not ok:
                failed.append(name)
                print("::group::" + name + " output", flush=True)
                print("\n".join(output.splitlines()[-60:]), flush=True)
                print("::endgroup::", flush=True)
    print(f"{len(picked) - len(failed)} of {len(picked)} passed in {time.time() - started:.0f} s")
    sys.exit(1 if failed else 0)


main()
