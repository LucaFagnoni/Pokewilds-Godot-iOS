#!/usr/bin/env python3
"""Pack every upstream PokeWilds GSC attack frame into Godot-safe sheets."""

from __future__ import annotations

import argparse
import json
import math
import re
import shutil
from pathlib import Path

from PIL import Image


# Keep generated textures comfortably below common Android 4096px limits.
FRAMES_PER_SHEET = 240
COLUMNS = 15
FRAME_TIME = 1.0 / 60.0


def natural_frame_key(path: Path) -> tuple[int, str]:
    match = re.search(r"(\d+)$", path.stem)
    return (int(match.group(1)) if match else 0, path.name)


def parse_metadata(path: Path) -> dict[str, dict[str, object]]:
    """Keep source runtime directives keyed by their one-based frame number."""
    result: dict[str, dict[str, object]] = {}
    if not path.is_file():
        return result
    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        match = re.match(r"\s*(\d+)\s*,\s*(.*)$", raw)
        if not match:
            continue
        frame_number, text = match.groups()
        entry = {}
        for token in text.split():
            if token == "_":
                continue
            if ":" not in token:
                entry[token] = True
                continue
            key, value = token.split(":", 1)
            values = [float(v) if "." in v else int(v) if re.fullmatch(r"-?\d+", v) else v
                      for v in value.split(",")]
            if key == "row_copy":
                entry.setdefault(key, []).append(values)
            else:
                entry[key] = values if len(values) > 1 else values[0]
        if entry:
            result[frame_number] = entry
    return result


def build(source_root: Path, project_root: Path) -> dict[str, object]:
    animation_root = project_root / "assets" / "battle_animations"
    audio_root = project_root / "assets" / "battle_audio"
    animation_root.mkdir(parents=True, exist_ok=True)
    audio_root.mkdir(parents=True, exist_ok=True)

    # Only generated PNGs in this exact output folder are replaced.
    for generated in animation_root.glob("*.png"):
        generated.unlink()

    manifest: dict[str, object] = {
        "version": 2,
        "source": "PokeWilds 0.8.11 GSC attack exports",
        "frame_time": FRAME_TIME,
        "animations": {},
        "audio": {},
    }
    animations: dict[str, object] = manifest["animations"]  # type: ignore[assignment]
    audio: dict[str, str] = manifest["audio"]  # type: ignore[assignment]

    for attack_dir in sorted(path for path in source_root.iterdir() if path.is_dir()):
        key = attack_dir.name
        frames = sorted((attack_dir / "output").glob("frame-*.png"), key=natural_frame_key)
        if frames:
            with Image.open(frames[0]) as opened:
                first = opened.convert("RGBA")
            frame_width, frame_height = first.size
            sheets: list[dict[str, object]] = []
            for sheet_index, start in enumerate(range(0, len(frames), FRAMES_PER_SHEET)):
                chosen = frames[start:start + FRAMES_PER_SHEET]
                rows = math.ceil(len(chosen) / COLUMNS)
                sheet = Image.new(
                    "RGBA",
                    (frame_width * COLUMNS, frame_height * rows),
                    (0, 0, 0, 0),
                )
                for index, frame_path in enumerate(chosen):
                    with Image.open(frame_path) as opened:
                        frame = opened.convert("RGBA")
                    if frame.size != (frame_width, frame_height):
                        frame = frame.resize(
                            (frame_width, frame_height), Image.Resampling.NEAREST
                        )
                    sheet.alpha_composite(
                        frame,
                        ((index % COLUMNS) * frame_width,
                         (index // COLUMNS) * frame_height),
                    )
                suffix = "" if len(frames) <= FRAMES_PER_SHEET else f"_{sheet_index + 1:02d}"
                output_path = animation_root / f"{key}{suffix}.png"
                sheet.save(output_path, compress_level=6)
                sheets.append({
                    "path": f"res://assets/battle_animations/{output_path.name}",
                    "start_frame": start,
                    "frames": len(chosen),
                })
            animations[key] = {
                "path": str(sheets[0]["path"]),
                "sheets": sheets,
                "frames": len(frames),
                "columns": COLUMNS,
                "frame_width": frame_width,
                "frame_height": frame_height,
                "frame_time": FRAME_TIME,
                "source_frame_count": len(frames),
                "directives": parse_metadata(attack_dir / "metadata.out"),
            }

        sound_path = attack_dir / "sound.ogg"
        if sound_path.is_file():
            output_sound = audio_root / f"{key}.ogg"
            shutil.copy2(sound_path, output_sound)
            audio[key] = f"res://assets/battle_audio/{output_sound.name}"
            base_key = key.removesuffix("_player_gsc").removesuffix("_enemy_gsc")
            audio.setdefault(base_key, f"res://assets/battle_audio/{output_sound.name}")

    manifest_path = animation_root / "manifest.json"
    manifest_path.write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    return manifest


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("source_root", type=Path)
    parser.add_argument("project_root", type=Path)
    args = parser.parse_args()
    manifest = build(args.source_root.resolve(), args.project_root.resolve())
    frame_count = sum(
        int(entry["frames"])
        for entry in manifest["animations"].values()  # type: ignore[union-attr]
    )
    print(
        f"Packed every source frame for {len(manifest['animations'])} animations "
        f"({frame_count} frames) and {len(manifest['audio'])} audio mappings."
    )


if __name__ == "__main__":
    main()
