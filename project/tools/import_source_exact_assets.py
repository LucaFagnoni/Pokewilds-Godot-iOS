#!/usr/bin/env python3
"""Copy selected PokeWilds 0.8.11 assets byte-for-byte and record hashes."""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
from pathlib import Path


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def copy_exact(
    source_root: Path,
    project_root: Path,
    source: Path,
    destination: Path,
    records: list[dict[str, object]],
) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, destination)
    records.append({
        "source": source.relative_to(source_root).as_posix(),
        "target": destination.relative_to(project_root).as_posix(),
        "bytes": source.stat().st_size,
        "sha256": sha256(source),
    })


def copy_tree_kind(
    source_root: Path,
    project_root: Path,
    source_dir: Path,
    destination_dir: Path,
    suffixes: set[str],
    records: list[dict[str, object]],
) -> None:
    for source in sorted(path for path in source_dir.rglob("*") if path.is_file()):
        if source.suffix.lower() not in suffixes:
            continue
        copy_exact(
            source_root,
            project_root,
            source,
            destination_dir / source.relative_to(source_dir),
            records,
        )


def build(source_root: Path, project_root: Path) -> dict[str, object]:
    records: list[dict[str, object]] = []

    for source in sorted(source_root.glob("*.png")):
        copy_exact(
            source_root, project_root, source,
            project_root / "assets" / "source_exact" / "global" / source.name,
            records,
        )
    for folder in ("battle", "menu", "player"):
        copy_tree_kind(
            source_root, project_root, source_root / folder,
            project_root / "assets" / "source_exact" / folder,
            {".png"}, records,
        )
    copy_tree_kind(
        source_root, project_root, source_root / "music",
        project_root / "assets" / "environment" / "music",
        {".ogg"}, records,
    )
    copy_tree_kind(
        source_root, project_root, source_root / "sounds",
        project_root / "assets" / "source_audio" / "sounds",
        {".ogg"}, records,
    )
    copy_tree_kind(
        source_root, project_root, source_root / "pokemon" / "cries",
        project_root / "assets" / "source_audio" / "cries",
        {".ogg"}, records,
    )
    copy_tree_kind(
        source_root, project_root, source_root / "pokemon" / "pokemon",
        project_root / "assets" / "original_pokemon",
        {".png"}, records,
    )

    manifest: dict[str, object] = {
        "format": 1,
        "source": "PokeWilds 0.8.11 source assets",
        "file_count": len(records),
        "byte_count": sum(int(record["bytes"]) for record in records),
        "files": records,
    }
    destination = project_root / "data" / "source_exact_asset_manifest.json"
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    return manifest


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("source_root", type=Path)
    parser.add_argument("project_root", type=Path)
    args = parser.parse_args()
    manifest = build(args.source_root.resolve(), args.project_root.resolve())
    print(
        f"Imported {manifest['file_count']} exact assets "
        f"({manifest['byte_count']} bytes)."
    )


if __name__ == "__main__":
    main()
