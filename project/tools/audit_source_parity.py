#!/usr/bin/env python3
"""Fail when source-derived runtime data or assets drift from PokeWilds 0.8.11."""

from __future__ import annotations

import argparse
import hashlib
import base64
import json
import re
from pathlib import Path


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def require(condition: bool, message: str, failures: list[str]) -> None:
    if not condition:
        failures.append(message)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("source_root", type=Path)
    parser.add_argument("project_root", type=Path)
    args = parser.parse_args()
    source = args.source_root.resolve()
    project = args.project_root.resolve()
    failures: list[str] = []

    exact = json.loads((project / "data/source_exact_asset_manifest.json").read_text())
    for record in exact["files"]:
        source_path = source / record["source"]
        target_path = project / record["target"]
        require(source_path.is_file(), f"missing source {record['source']}", failures)
        require(target_path.is_file(), f"missing target {record['target']}", failures)
        if source_path.is_file() and target_path.is_file():
            expected = record["sha256"]
            require(sha256(source_path) == expected,
                    f"source hash drift {record['source']}", failures)
            require(sha256(target_path) == expected,
                    f"target hash drift {record['target']}", failures)

    database = json.loads((project / "data/pokemon_db.json").read_text())
    source_species = [
        folder for folder in (source / "pokemon/pokemon").iterdir()
        if folder.is_dir() and (folder / "wilds_data.asm").is_file()
        and (folder / "base_stats.asm").is_file()
    ]
    require(database.get("species_count") == len(source_species),
            "Pokemon/form record count differs from source", failures)
    require(len(database.get("species", {})) == len(source_species),
            "Pokemon database keys differ from source", failures)

    moves_text = (source / "pokemon/moves.asm").read_text(
        encoding="utf-8", errors="replace")
    source_moves = set(re.findall(r"^\s*move\s+([A-Z0-9_]+)\s*,", moves_text,
                                  re.MULTILINE))
    require(set(database.get("moves", {})) == source_moves,
            "move database differs from source moves.asm", failures)

    battle = json.loads((project / "assets/battle_animations/manifest.json").read_text())
    source_animation_dirs = [
        folder for folder in (source / "attacks").iterdir()
        if folder.is_dir() and any((folder / "output").glob("frame-*.png"))
    ]
    animations = battle.get("animations", {})
    require(len(animations) == len(source_animation_dirs),
            "battle animation directory count differs from source", failures)
    for folder in source_animation_dirs:
        count = len(list((folder / "output").glob("frame-*.png")))
        entry = animations.get(folder.name, {})
        require(int(entry.get("frames", -1)) == count,
                f"frame count mismatch: {folder.name}", failures)
        require(int(entry.get("source_frame_count", -1)) == count,
                f"source frame audit mismatch: {folder.name}", failures)
        require(len(base64.b64decode(entry.get("frame_table", ""))) == 14 * count,
                f"sheet frame total mismatch: {folder.name}", failures)

    state_text = (project / "scripts/pokemon_state.gd").read_text()
    require(re.search(r"const\s+SHINY_RATE\s*:=\s*256\b", state_text) is not None,
            "runtime shiny rate is not the source 1/256", failures)

    if failures:
        print("SOURCE PARITY AUDIT FAILED")
        for failure in failures:
            print(f"- {failure}")
        return 1
    print(
        "SOURCE PARITY AUDIT PASSED: "
        f"{len(source_species)} Pokemon/forms, {len(source_moves)} moves, "
        f"{len(source_animation_dirs)} complete animations, "
        f"{exact['file_count']} byte-exact assets."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
