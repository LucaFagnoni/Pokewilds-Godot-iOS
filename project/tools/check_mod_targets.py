#!/usr/bin/env python3
"""List mod targets that point at a missing file or at a PNG of another size:
data/mod_resource_catalog.json (user .pwmod targets) and data/original_mod_paths.json
(original-game mod files, existence only).

Usage: check_mod_targets.py <project_root>   (exit status 1 when anything is listed)
"""

from __future__ import annotations

import json
import struct
import sys
from pathlib import Path


def main() -> None:
    root = Path(sys.argv[1]).resolve()
    problems: list[str] = []

    def check(source: str, target: str, size=None) -> None:
        path = root / target.removeprefix("res://")
        if not path.is_file():
            problems.append(f"{source}: missing {target}")
        elif size and path.suffix == ".png":
            with path.open("rb") as png:
                actual = list(struct.unpack(">II", png.read(24)[16:24]))
            if actual != list(size):
                problems.append(f"{source}: {target} is {actual}, listed {list(size)}")

    catalog = json.loads((root / "data/mod_resource_catalog.json").read_text(encoding="utf-8"))
    for target, entry in catalog.items():
        check("catalog", target, None if entry.get("front") else entry.get("size"))
    # Sizes there are the original game's files, which may be laid out differently.
    for name, mappings in json.loads((root / "data/original_mod_paths.json").read_text(encoding="utf-8")).items():
        for mapping in mappings:
            check(f"original_mod_paths {name}", mapping["path"])

    print("\n".join(problems) or "all mod targets exist")
    sys.exit(1 if problems else 0)


if __name__ == "__main__":
    main()
