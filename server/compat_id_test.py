"""Checks tools/compat_id.py and tools/client_only_paths.txt: editing a
client-only file keeps the compat id, editing a shared or adding an unknown
file changes it, CRLF and LF give the same id, and every list entry still
matches a file of project/ (none of the files below that must stay shared).

    python server/compat_id_test.py        (from the repository root; exits 0 on success)"""
import os, shutil, sys, tempfile

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "tools"))
import compat_id as C

PROJECT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "project")
# Written by builds, so absent from a checkout.
STAMPS = {"build_id.txt", "build_version.txt", "compat_id.txt", "lobby_server.txt"}
# Mix drawing with logic, or are game data: never client-only.
SHARED = ["scripts/main.gd", "scripts/world.gd", "scripts/coop_session.gd", "scripts/coop_chat.gd", "scripts/coop_menu.gd",
          "scripts/coop_server_ping.gd", "scripts/options_menu.gd", "scripts/game_options.gd", "scripts/dedicated_server.gd",
          "scripts/world_environment_system.gd", "scripts/coop_interaction_ui.gd", "data/pokemon_db.json",
          "project.godot", "scenes/main.tscn", "assets/environment/cloud5.png"]
COPIED = ["scripts/status_hud.gd", "scripts/touch_icons.gd", "scripts/world.gd", "scripts/coop_session.gd", "data/source_catch_weights.json"]
failed = 0


def check(ok, what):
    global failed
    print(("ok   " if ok else "FAIL ") + what)
    failed += not ok


def edit(root, rel, data=b"\n# changed\n", mode="ab"):
    os.makedirs(os.path.dirname(os.path.join(root, rel)), exist_ok=True)
    with open(os.path.join(root, rel), mode) as f: f.write(data)


globs = C.client_only()
files = C.shared_files(PROJECT, [])
for g in globs:
    if g not in STAMPS: check(any(C.fnmatch.fnmatchcase(f, g) for f in files), f"{g} matches a file")
for rel in SHARED:
    check(rel in files and not any(C.fnmatch.fnmatchcase(rel, g) for g in globs), f"{rel} is shared")

work = tempfile.mkdtemp(prefix="pw-compat-")
try:
    lf, crlf = os.path.join(work, "lf"), os.path.join(work, "crlf")
    for rel in COPIED:
        text = open(os.path.join(PROJECT, rel), "rb").read().replace(b"\r\n", b"\n")
        edit(lf, rel, text, "wb")
        edit(crlf, rel, text.replace(b"\n", b"\r\n"), "wb")
    edit(lf, "assets/source_audio/cries/1.ogg", b"OggS\r\n\x00")
    edit(crlf, "assets/source_audio/cries/1.ogg", b"OggS\r\n\x00")
    base = C.compat_id(lf, globs)
    check(C.compat_id(crlf, globs) == base, "CRLF and LF give the same id")
    check(C.compat_id(lf, globs) == base, "the same files give the same id")
    for rel in ["scripts/status_hud.gd", "scripts/touch_icons.gd", "assets/source_audio/cries/1.ogg", "build_id.txt", "compat_id.txt", ".godot/imported/x.ctex"]:
        edit(lf, rel)
        check(C.compat_id(lf, globs) == base, f"client-only {rel} keeps the id")
    for rel in ["data/source_catch_weights.json", "scripts/coop_session.gd", "scripts/world.gd", "scripts/new_rules.gd", "assets/new.png"]:
        edit(lf, rel)
        changed = C.compat_id(lf, globs)
        check(changed != base, f"shared {rel} changes the id")
        base = changed
finally:
    shutil.rmtree(work, ignore_errors=True)

print(f"COMPAT ID TEST: {failed} failed")
sys.exit(1 if failed else 0)
