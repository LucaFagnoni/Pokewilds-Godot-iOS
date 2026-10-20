#!/usr/bin/env python3
"""Convert the full-frame battle animation sheets (manifest version 3) in place
to cropped atlas pages (version 4), without the upstream exports.

Usage: convert_battle_sheets.py <project_root>
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from PIL import Image

import battle_atlas


def old_frames(animation: dict, project_root: Path) -> list[Image.Image]:
    columns = int(animation["columns"])
    width, height = int(animation["frame_width"]), int(animation["frame_height"])
    frames: list[Image.Image] = []
    for sheet in animation["sheets"]:
        path = project_root / sheet["path"].removeprefix("res://")
        with Image.open(path) as opened:
            image = opened.convert("RGBA")
        for local in range(int(sheet["frames"])):
            x, y = (local % columns) * width, (local // columns) * height
            frames.append(image.crop((x, y, x + width, y + height)))
    return frames


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("project_root", type=Path)
    project_root = parser.parse_args().project_root.resolve()
    folder = project_root / "assets" / "battle_animations"
    manifest_path = folder / "manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if manifest.get("version", 3) >= 4:
        raise SystemExit("already converted")

    # Read every old sheet before anything is replaced.
    converted = {}
    for key, animation in manifest["animations"].items():
        frames = old_frames(animation, project_root)
        assert len(frames) == int(animation["frames"]), key
        converted[key] = frames
    for png in folder.glob("*.png"):
        png.unlink()
        png.with_name(png.name + ".import").unlink(missing_ok=True)
    for key, frames in converted.items():
        battle_atlas.write(manifest["animations"][key], key, frames, folder)
        battle_atlas.embed_directives(manifest["animations"][key])
    manifest["version"] = 4
    manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n",
                             encoding="utf-8")
    print(f"converted {len(converted)} animations")


if __name__ == "__main__":
    main()
