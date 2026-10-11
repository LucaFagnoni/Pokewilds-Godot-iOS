#!/usr/bin/env python3
"""Import the exact PokeWilds overworld assets used by the Godot port."""
from __future__ import annotations

import shutil
import sys
from pathlib import Path

from PIL import Image


PLAYER_PALETTES = {
    "green": ((23, 37, 41), (47, 91, 66), (235, 238, 210)),
    "blue": ((23, 37, 41), (48, 79, 139), (235, 238, 210)),
    "red": ((23, 37, 41), (132, 55, 55), (235, 238, 210)),
    "gold": ((23, 37, 41), (128, 92, 34), (235, 238, 210)),
}

SOURCE_PLAYER_COLORS = {
    (0, 0, 0): 0,
    (248, 56, 8): 1,
    (248, 152, 80): 2,
}

EXACT_ASSETS = {
    "tiles/green_savanna4.png": "biome_savanna.png",
    "tiles/mountain2.png": "biome_mountain.png",
    "tiles/desert1.png": "biome_desert.png",
    "tiles/snow2.png": "biome_snow.png",
    "tiles/green5.png": "biome_wooded_lake.png",
    "tiles/tree_savanna1.png": "biome_tree_savanna.png",
    "tiles/cactus5.png": "biome_cactus.png",
    "tiles/tree7.png": "biome_tree_snow.png",
    "pokemon/egg1.png": "pokemon_egg_sheet.png",
}


def recolor_running(source: Path, destination: Path, palette: tuple) -> None:
    image = Image.open(source).convert("RGBA")
    pixels = []
    for red, green, blue, alpha in image.getdata():
        if alpha == 0:
            pixels.append((0, 0, 0, 0))
            continue
        palette_index = SOURCE_PLAYER_COLORS.get((red, green, blue), 0)
        color = palette[palette_index]
        pixels.append((*color, 255))
    image.putdata(pixels)
    image.save(destination)


def main() -> int:
    if len(sys.argv) != 3:
        raise SystemExit("usage: import_overworld_assets.py SOURCE_ROOT GODOT_PROJECT")
    source_root = Path(sys.argv[1]).resolve()
    project = Path(sys.argv[2]).resolve()
    destination = project / "assets"
    destination.mkdir(parents=True, exist_ok=True)

    for relative_source, output_name in EXACT_ASSETS.items():
        shutil.copy2(source_root / relative_source, destination / output_name)

    egg_sheet = Image.open(source_root / "pokemon" / "egg1.png").convert("RGBA")
    egg_sheet.crop((0, 0, 16, 16)).save(destination / "pokemon_egg.png")

    running = source_root / "player" / "chase-running.png"
    for name, palette in PLAYER_PALETTES.items():
        recolor_running(running, destination / f"player_run_{name}.png", palette)

    print("Imported original biome, egg, and Chase running assets")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
