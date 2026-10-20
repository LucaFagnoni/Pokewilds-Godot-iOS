#!/usr/bin/env python3
"""Convert the full-frame battle animation sheets a .pwmod replaces (the old
layout: 160x144 frames, 15 columns, 240 frames per sheet, named <key>.png or
<key>_01.png, <key>_02.png...) to atlas pages with the pack's own frame table
(tools/battle_atlas.py). The pages take over the base pages' paths and the
table goes to mod.json "battle_frame_tables" (read by scripts/gen3_overhaul.gd;
directives still come from the base manifest). Sheets a pack does not replace
keep the base frames.

Usage: convert_pack_battle_sheets.py <pack.pwmod> <project_root>
Rewrites the pack in place and prints its SHA-256 (gen3_overhaul.gd PACK_HASH).
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import io
import json
import math
import struct
import zipfile
from pathlib import Path

from PIL import Image

import battle_atlas

COLUMNS, PER_SHEET = 15, 240
PREFIX = "res://assets/battle_animations/"


def old_sheets(key: str, frames: int) -> list[tuple[str, int]]:
    """(path, frame count) of each old sheet of an animation."""
    count = max(1, math.ceil(frames / PER_SHEET))
    names = [f"{key}.png"] if count == 1 else [f"{key}_{n + 1:02d}.png" for n in range(count)]
    return [(PREFIX + name, min(PER_SHEET, frames - n * PER_SHEET)) for n, name in enumerate(names)]


def base_frames(animation: dict, project_root: Path) -> list[Image.Image]:
    width, height = int(animation["frame_width"]), int(animation["frame_height"])
    pages = [Image.open(project_root / p.removeprefix("res://")).convert("RGBA")
             for p in animation["pages"]]
    table = base64.b64decode(animation["frame_table"])
    frames = []
    for n in range(int(animation["frames"])):
        page, x, y, w, h, ox, oy, _ = struct.unpack_from("<8H", table, n * 16)
        frame = Image.new("RGBA", (width, height), (0, 0, 0, 0))
        if w:
            frame.paste(pages[page].crop((x, y, x + w, y + h)), (ox, oy))
        frames.append(frame)
    return frames


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("pack", type=Path)
    parser.add_argument("project_root", type=Path)
    args = parser.parse_args()
    project_root = args.project_root.resolve()
    battle = json.loads((project_root / "assets/battle_animations/manifest.json").read_text(encoding="utf-8"))
    with zipfile.ZipFile(args.pack) as pack:
        entries = [(info, pack.read(info)) for info in pack.infolist()]
    files = {info.filename: data for info, data in entries}
    mod = json.loads(files["mod.json"])
    resources: dict = mod["resources"]
    tables = mod.setdefault("battle_frame_tables", {})

    for key, animation in battle["animations"].items():
        width, height = int(animation["frame_width"]), int(animation["frame_height"])
        replaced = {}
        start = 0
        for path, count in old_sheets(key, int(animation["frames"])):
            if path in resources:
                sheet = Image.open(io.BytesIO(files[resources[path]])).convert("RGBA")
                # A page of the current format keeps the base layout: leave it alone.
                if sheet.size == (COLUMNS * width, math.ceil(count / COLUMNS) * height):
                    replaced[path] = (start, count, sheet)
            start += count
        if not replaced:
            continue
        frames = base_frames(animation, project_root)
        for path, (start, count, sheet) in replaced.items():
            for local in range(count):
                x, y = (local % COLUMNS) * width, (local // COLUMNS) * height
                frames[start + local] = sheet.crop((x, y, x + width, y + height))
            del resources[path]
        pages, table = battle_atlas.pack(frames)
        if len(pages) > len(animation["pages"]):
            raise SystemExit(f"{key}: {len(pages)} pages, the base has {len(animation['pages'])}")
        for page, target in zip(pages, animation["pages"]):
            out = io.BytesIO()
            page.save(out, format="PNG", compress_level=9, optimize=True)
            name = f"files/{hashlib.sha256(out.getvalue()).hexdigest()[:24]}.png"
            files[name] = out.getvalue()
            resources[target] = name
        tables[key] = {"pages": animation["pages"][:len(pages)],
                       "frame_table": base64.b64encode(table).decode("ascii")}
        print(f"{key}: {len(replaced)} sheets -> {len(pages)} page(s)")

    files["mod.json"] = json.dumps(mod, ensure_ascii=False).encode("utf-8")
    used = {"mod.json", "CREDITS.txt", *resources.values()}
    stamp = entries[0][0].date_time
    with zipfile.ZipFile(args.pack, "w", zipfile.ZIP_DEFLATED) as out:
        for info, _ in entries:
            if info.filename in used:
                out.writestr(info, files.pop(info.filename))
        for name in sorted(set(files) & used):
            out.writestr(zipfile.ZipInfo(name, stamp), files[name], zipfile.ZIP_DEFLATED)
    print(hashlib.sha256(args.pack.read_bytes()).hexdigest())


if __name__ == "__main__":
    main()
