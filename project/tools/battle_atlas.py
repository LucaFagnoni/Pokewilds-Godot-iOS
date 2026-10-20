"""Pack battle animation frames as cropped, deduplicated atlas pages.

A 160x144 frame is mostly transparent, so a frame stores only the bounding
box of its non-transparent pixels. Identical crops share one spot in the
atlas, and empty frames store nothing. The player draws a crop with
AtlasTexture(region=crop, margin=offset), which is pixel-identical to the
full frame.

Manifest fields per animation (version 4): "pages" (res:// paths) and
"frame_table", a base64 string of little-endian uint16 values, 8 per frame:
page, x, y, w, h (the crop in the page), ox, oy (the crop's place in the
frame), directive (index into the manifest's "directive_table", 0xFFFF for
none). w == 0 means the frame is empty. Keeping per-frame data in one string
instead of dictionaries keeps the parsed manifest small (~1 MB, not ~30 MB).

Import the pages with process/fix_alpha_border=false: the default rewrites the
colour of nearly transparent pixels, which would change the picture.
"""

from __future__ import annotations

import base64
import math
import struct
from pathlib import Path

from PIL import Image

GUTTER = 1  # transparent pixels between crops, so filtering never bleeds
MAX_PAGE = 2048  # comfortably below common 4096px mobile limits
NO_DIRECTIVE = 0xFFFF


def _shelf_pack(sizes: list[tuple[int, int]], width: int) -> list[tuple[int, int, int]]:
    """Place sizes (sorted tallest first) in shelves: (page, x, y) each."""
    spots: list[tuple[int, int, int]] = []
    page = x = y = shelf = 0
    for w, h in sizes:
        if x + w > width:
            x, y, shelf = 0, y + shelf + GUTTER, 0
        if y + h > MAX_PAGE:
            page, x, y, shelf = page + 1, 0, 0, 0
        spots.append((page, x, y))
        x += w + GUTTER
        shelf = max(shelf, h)
    return spots


def pack(frames: list[Image.Image]) -> tuple[list[Image.Image], bytes]:
    """Return (pages, frame_table bytes) for RGBA frames of one size."""
    unique: dict[tuple[int, int, bytes], int] = {}
    crops: list[Image.Image] = []
    entries: list[tuple[int, int, int]] = []  # (crop index or -1, ox, oy)
    for frame in frames:
        box = frame.getchannel("A").getbbox()
        if box is None:
            entries.append((-1, 0, 0))
            continue
        crop = frame.crop(box)
        key = (crop.width, crop.height, crop.tobytes())
        if key not in unique:
            unique[key] = len(crops)
            crops.append(crop)
        entries.append((unique[key], box[0], box[1]))

    order = sorted(range(len(crops)), key=lambda i: -crops[i].height)
    area = sum((c.width + GUTTER) * (c.height + GUTTER) for c in crops)
    widest = max((c.width for c in crops), default=1)
    width = min(MAX_PAGE, max(widest, 16 * math.ceil(math.sqrt(area * 1.1) / 16)))
    spots = _shelf_pack([crops[i].size for i in order], width)
    spot_of = {crop_index: spots[n] for n, crop_index in enumerate(order)}

    page_sizes: dict[int, list[int]] = {}
    for i, (page, x, y) in spot_of.items():
        size = page_sizes.setdefault(page, [1, 1])
        size[0] = max(size[0], x + crops[i].width)
        size[1] = max(size[1], y + crops[i].height)
    pages = [Image.new("RGBA", tuple(page_sizes[p]), (0, 0, 0, 0))
             for p in sorted(page_sizes)]
    for i, (page, x, y) in spot_of.items():
        pages[page].paste(crops[i], (x, y))

    table = bytearray()
    for crop_index, ox, oy in entries:
        if crop_index < 0:
            table += struct.pack("<8H", 0, 0, 0, 0, 0, 0, 0, NO_DIRECTIVE)
        else:
            page, x, y = spot_of[crop_index]
            crop = crops[crop_index]
            table += struct.pack("<8H", page, x, y, crop.width, crop.height, ox, oy, NO_DIRECTIVE)
    return pages, bytes(table)


def write(animation: dict, key: str, frames: list[Image.Image], out_dir: Path) -> list[Path]:
    """Save the pages of one animation and fill its manifest entry."""
    pages, table = pack(frames)
    paths = []
    for n, page in enumerate(pages):
        name = f"{key}.png" if len(pages) == 1 else f"{key}_{n + 1:02d}.png"
        page.save(out_dir / name, compress_level=9, optimize=True)
        paths.append(out_dir / name)
    for old in ("path", "sheets", "columns"):
        animation.pop(old, None)
    animation["pages"] = [f"res://assets/battle_animations/{p.name}" for p in paths]
    animation["frame_table"] = base64.b64encode(table).decode("ascii")
    return paths


def embed_directives(animation: dict) -> None:
    """Move animation["directives"] ({frame number: table index}) into the frame table."""
    table = bytearray(base64.b64decode(animation["frame_table"]))
    for frame, index in animation.pop("directives", {}).items():
        if int(frame) <= len(table) // 16:  # a directive past the last frame is never played
            struct.pack_into("<H", table, (int(frame) - 1) * 16 + 14, index)
    animation["frame_table"] = base64.b64encode(table).decode("ascii")
