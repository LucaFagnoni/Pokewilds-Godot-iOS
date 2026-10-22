"""Fails when a per-frame function calls tile_at(.

A SourceTile proxy costs ~10 us to make; a few dozen a frame were 17-37 ms of
a phone's frame (aca92b3b). Per-frame code reads the WorldTileStore arrays
instead (store.index_of, flags, name_ids...). Per-frame functions are
_process, _physics_process and _draw, and every function whose doc comment
(the ## lines right above it) has a line "## per-frame".

    python tools/lint_tile_at.py [ROOT]     (ROOT: the repository, default ..)
Exits 1 and lists file:line for each call found; 0 when there are none."""
import os
import re
import sys

ENGINE = {"_process", "_physics_process", "_draw"}


def scan(path):
    lines = open(path, encoding="utf-8").read().splitlines()
    found = []
    name = None
    tagged = False
    for number, line in enumerate(lines, 1):
        func = re.match(r"(?:static )?func (\w+)", line)
        if func:
            name = func.group(1)
            doc = number - 2
            tagged = False
            while doc >= 0 and lines[doc].startswith("#"):
                if lines[doc].strip() == "## per-frame":
                    tagged = True
                doc -= 1
            continue
        if line and not line[0].isspace() and not line.startswith("#"):
            name = None  # back at the class level
            continue
        code = line.split("#", 1)[0]
        if name and (name in ENGINE or tagged) and "tile_at(" in code:
            found.append((number, name))
    return found


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
    scripts = os.path.join(root, "project", "scripts")
    failures = 0
    checked = 0
    for directory, _, files in os.walk(scripts):
        for file in sorted(files):
            if not file.endswith(".gd"):
                continue
            path = os.path.join(directory, file)
            checked += 1
            for number, name in scan(path):
                failures += 1
                print(f"{os.path.relpath(path, root)}:{number}: tile_at( in per-frame {name}()")
    print(f"LINT TILE_AT: {checked} scripts, {failures} per-frame tile_at calls")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
