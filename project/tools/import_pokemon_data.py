#!/usr/bin/env python3
"""Build Godot-readable Pokemon metadata from the PokeWilds data repository."""
from __future__ import annotations

import json
import re
import shutil
import sys
from pathlib import Path

MOVE_ORDER = ["DIG", "POWER", "CUT", "SMASH", "SURF", "FLASH", "BUILD",
              "CHARM", "REPEL", "ATTACK", "TELEPORT", "HEADBUTT", "RIDE",
              "FLY", "PAINT"]


def db_lines(path: Path) -> list[str]:
    result = []
    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        code = raw.split(";", 1)[0].strip()
        if code.lower().startswith("db "):
            result.append(code[3:].strip())
    return result


def tokens(value: str) -> list[str]:
    return [x.strip().strip('"') for x in value.split(",") for x in x.split() if x.strip()]


def number(value: str, fallback: int = 0) -> int:
    match = re.search(r"-?\d+", value)
    return int(match.group()) if match else fallback


def decimal(value: str, fallback: float = 0.0) -> float:
    match = re.search(r"-?\d+(?:\.\d+)?", value)
    return float(match.group()) if match else fallback


def parse_tmhm(path: Path) -> list[str]:
    if not path.is_file():
        return []
    text = path.read_text(encoding="utf-8", errors="replace")
    match = re.search(r"^\s*tmhm\s+(.+)$", text, re.MULTILINE)
    if not match:
        return []
    return [
        value.upper().replace(" ", "_")
        for value in tokens(match.group(1).split(";", 1)[0])
        if re.fullmatch(r"[A-Z0-9_]+", value.upper().replace(" ", "_"))
    ]


def cry_file_for(folder_name: str, dex: int, cries_root: Path) -> Path | None:
    special_names = {
        "exeggutor_alolan": "exeggutor-alola.ogg",
        "farfetch_d_galarian": "farfetchd-galar.ogg",
        "grimer_alolan": "grimer-alola.ogg",
        "marowak_alolan": "marowak-alola.ogg",
        "mrmime_galarian": "mrmime-galarian.ogg",
        "muk_alolan": "muk-alola.ogg",
        "raichu_alolan": "raichu-alola.ogg",
        "shaymin_sky": "492s.ogg",
        "tornadus_therian": "641t.ogg",
        "thundurus_therian": "642t.ogg",
        "landorus_therian": "645t.ogg",
        "kyurem_black": "646bk.ogg",
        "kyurem_white": "646wk.ogg",
        "floette_eternal": "670E.ogg",
        "zygarde_10": "718A.ogg",
        "zygarde_complete": "718C.ogg",
        "diancie_mega": "719M.ogg",
        "hoopa_unbound": "720U.ogg",
        "lycanroc_dusk": "745D.ogg",
        "lycanroc_midnight": "745N.ogg",
        "lycanroc_midday": "745U.ogg",
        "toxtricity_lowkey": "849-lowkey.ogg",
        "eiscue_noice": "875N.ogg",
        "indeedee_female": "876F.ogg",
        "indeedee_male": "876M.ogg",
        "morpeko_hangry": "877H.ogg",
        "zacian_crowned": "888C.ogg",
        "zamazenta_crowned": "889C.ogg",
        "urshifu_rapidstrike": "892RS.ogg",
        "urshifu_singlestrike": "892SS.ogg",
        "calyrex_ice": "898IR.ogg",
        "calyrex_shadow": "898SR.ogg",
    }
    candidates = []
    if folder_name in special_names:
        candidates.append(cries_root / special_names[folder_name])
    candidates.extend([
        cries_root / f"{dex:03d}.ogg",
        cries_root / f"{dex}.ogg",
    ])
    return next((path for path in candidates if path.is_file()), None)


def parse_moves(source_root: Path) -> dict[str, dict]:
    result = {}
    pattern = re.compile(
        r"^\s*move\s+([A-Z0-9_]+),\s*([A-Z0-9_]+),\s*(\d+),\s*"
        r"([A-Z0-9_]+),\s*(\d+),\s*(\d+),\s*(\d+)"
    )
    for raw in (source_root / "pokemon" / "moves.asm").read_text(errors="replace").splitlines():
        match = pattern.match(raw)
        if not match:
            continue
        name, effect, power, move_type, accuracy, pp, chance = match.groups()
        result[name] = {
            "name": name.replace("_", " "), "effect": effect,
            "power": int(power), "type": move_type, "accuracy": int(accuracy),
            "pp": int(pp), "effect_chance": int(chance),
        }
    return result


def parse_progression(path: Path) -> tuple[list[dict], list[dict]]:
    evolutions, learnset = [], []
    if not path.exists():
        return evolutions, learnset
    in_moves = False
    for row in db_lines(path):
        parts = tokens(row)
        if not parts:
            continue
        if not in_moves:
            if parts[0] == "0":
                in_moves = True
            elif parts[0].startswith("EVOLVE_"):
                evolutions.append({"method": parts[0], "parameter": parts[1] if len(parts) > 1 else "", "species": parts[-1].lower()})
        elif len(parts) >= 2 and parts[0].isdigit() and parts[0] != "0":
            learnset.append({"level": int(parts[0]), "move": parts[1]})
    return evolutions, learnset


def parse_egg_moves(path: Path) -> list[str]:
    if not path.exists():
        return []
    result = []
    for row in db_lines(path):
        for move in tokens(row):
            normalized = move.upper().replace(" ", "_")
            if re.fullmatch(r"[A-Z0-9_]+", normalized):
                result.append(normalized)
    return result


def parse_species(folder: Path, cries_root: Path) -> dict | None:
    wild = folder / "wilds_data.asm"
    stats = folder / "base_stats.asm"
    if not wild.exists() or not stats.exists():
        return None
    wl = db_lines(wild)
    sl = db_lines(stats)
    if len(wl) < 12 or len(sl) < 4:
        return None

    stat_values = []
    for value in tokens(sl[1] if len(sl) > 1 else ""):
        if re.fullmatch(r"\d+", value):
            stat_values.append(int(value))
    type_values = list(dict.fromkeys(x for x in tokens(sl[2] if len(sl) > 2 else "") if x not in {"TYPE", "NONE"}))
    move_flags = []
    # Wilds records are stable: field flags are the 15 numeric db rows following
    # display/dex/text/size/base-form/biome/group/disguise/habitat/harvest.
    numeric_rows = [int(x) for x in wl[11:26] if re.fullmatch(r"[012]", x)]
    if len(numeric_rows) == 15:
        move_flags = numeric_rows
    special = [MOVE_ORDER[i] for i, flag in enumerate(move_flags) if flag == 1]
    forced_off = [MOVE_ORDER[i] for i, flag in enumerate(move_flags) if flag == 2]

    spawn_row = wl[6] if len(wl) > 6 else "TYPE"
    spawn_biomes = [
        x for x in tokens(spawn_row)
        if re.fullmatch(r"[A-Z0-9_]+", x) and x != "NONE"
    ]
    base_tokens = tokens(wl[5] if len(wl) > 5 else "")
    base_forms = []
    for index in range(0, len(base_tokens) - 1, 2):
        if not re.fullmatch(r"[A-Z0-9_]+", base_tokens[index]):
            continue
        base_forms.append({
            "species": base_tokens[index].lower(),
            "weight": number(base_tokens[index + 1], 100),
        })

    habitat_row = wl[9] if len(wl) > 9 else "TYPE"
    harvest_row = wl[10] if len(wl) > 10 else "TYPE"
    habitat_tokens = [x.upper() for x in tokens(habitat_row) if x != "NONE"]
    harvest_tokens = [x.upper() for x in tokens(harvest_row) if x != "NONE"]
    habitats = [x for x in habitat_tokens if x != "TYPE"]
    harvest = [x.replace("_", " ") for x in harvest_tokens if x != "TYPE"]
    dex = next((int(x) for x in wl[1:4] if re.fullmatch(r"\d+", x)), 0)
    evolution = folder / "evos_attacks.asm"
    evolutions, learnset = parse_progression(evolution)
    stats_text = stats.read_text(errors="replace")
    growth_match = re.search(r"GROWTH_[A-Z_]+", stats_text)
    # Form-specific base_stats files also contain a `dn 7, 7` picture-size
    # row. Match the labeled egg-group row rather than the first `dn` row.
    egg_group_match = re.search(
        r"^\s*dn\s+([^;]+?)\s*;\s*egg\s+groups?\b",
        stats_text,
        re.MULTILINE | re.IGNORECASE,
    )
    egg_groups = []
    if egg_group_match:
        egg_groups = [
            value.replace("EGG_GROUND", "EGG_FIELD")
            for value in tokens(egg_group_match.group(1))
        ]
    gender_ratio = sl[6].strip() if len(sl) > 6 else "GENDER_UNKNOWN"
    if not gender_ratio.startswith("GENDER_"):
        gender_ratio = "GENDER_UNKNOWN"
    egg_cycles = number(sl[8], 20) if len(sl) > 8 else 20
    cry = cry_file_for(folder.name, dex, cries_root)
    held_items = [
        item.replace("_", " ")
        for item in tokens(sl[5] if len(sl) > 5 else "")
        if item not in {"NO_ITEM", "NONE"}
    ]
    return {
        "id": folder.name,
        "name": folder.name.replace("_", " ").upper(),
        "dex": dex,
        "dex_entry": (wl[2].strip().removeprefix("<").removesuffix(">")
                      if len(wl) > 2 else ""),
        "weight_kg": decimal(wl[3], 0.0) if len(wl) > 3 else 0.0,
        "height_m": decimal(wl[4], 0.0) if len(wl) > 4 else 0.0,
        "types": type_values or ["NORMAL"],
        "stats": stat_values[:6],
        "catch_rate": number(sl[3], 45) if len(sl) > 3 else 45,
        "base_exp": number(sl[4], 64) if len(sl) > 4 else 64,
        "growth_rate": growth_match.group() if growth_match else "GROWTH_MEDIUM_FAST",
        "special": special,
        "forced_off": forced_off,
        "fully_evolved": not evolutions,
        "evolutions": evolutions,
        "learnset": learnset,
        "base_forms": base_forms,
        "spawn_biomes": spawn_biomes,
        "aggressive_biomes": [
            x for x in tokens(wl[7] if len(wl) > 7 else "NONE")
            if x != "NONE"
        ],
        "disguise_tile": (
            "" if len(wl) <= 8 or wl[8] == "NONE" else wl[8].lower()
        ),
        "habitats": habitats,
        "harvest": harvest,
        "habitat_tokens": habitat_tokens,
        "harvest_tokens": harvest_tokens,
        "gender_ratio": gender_ratio,
        "egg_groups": egg_groups or ["EGG_NONE", "EGG_NONE"],
        "egg_cycles": egg_cycles,
        "egg_moves": parse_egg_moves(folder / "egg_moves.asm"),
        "tmhm": parse_tmhm(stats),
        "wild_held_items": held_items,
        "base_happiness": 70,
        "overworld_behavior": {
            "swim_only": number(wl[26], 0) == 1 if len(wl) > 26 else False,
            "flee": number(wl[27], 0) == 1 if len(wl) > 27 else False,
            "lunge": number(wl[28], 0) == 1 if len(wl) > 28 else False,
            "aggression": number(wl[29], 0) if len(wl) > 29 else 1,
            "flip_walk_3": number(wl[30], 0) == 1 if len(wl) > 30 else False,
            "flip_walk_4": number(wl[31], 0) == 1 if len(wl) > 31 else False,
            "stationary": number(wl[32], 0) == 1 if len(wl) > 32 else False,
            "water_offset": number(wl[33], 0) if len(wl) > 33 else 0,
        },
        "growth_ticks": 12600 if folder.name.startswith("unown") else 9000,
        "front": f"res://assets/original_pokemon/{folder.name}/front.png" if (folder / "front.png").exists() else "",
        "back": f"res://assets/original_pokemon/{folder.name}/back.png" if (folder / "back.png").exists() else "",
        "overworld": f"res://assets/original_pokemon/{folder.name}/overworld.png" if (folder / "overworld.png").exists() else "",
        "overworld_shiny": f"res://assets/original_pokemon/{folder.name}/overworld-shiny.png" if (folder / "overworld-shiny.png").exists() else "",
        "cry": f"res://assets/source_audio/cries/{cry.name}" if cry else "",
    }


def main() -> int:
    if len(sys.argv) != 3:
        raise SystemExit("usage: import_pokemon_data.py SOURCE_ROOT GODOT_PROJECT")
    source_root = Path(sys.argv[1]).resolve()
    source = source_root / "pokemon" / "pokemon"
    project = Path(sys.argv[2]).resolve()
    species = {}
    asset_root = project / "assets" / "original_pokemon"
    asset_root.mkdir(parents=True, exist_ok=True)
    for folder in sorted(x for x in source.iterdir() if x.is_dir()):
        entry = parse_species(folder, source_root / "pokemon" / "cries")
        if entry is None:
            continue
        species[folder.name] = entry
        destination = asset_root / folder.name
        destination.mkdir(exist_ok=True)
        for name in ("front.png", "back.png", "overworld.png", "overworld-shiny.png"):
            src = folder / name
            if src.exists():
                shutil.copy2(src, destination / name)
    # M40's one-frame battle extraction prevents six-frame source sheets from
    # rendering as duplicated battle sprites. Preserve those runtime paths.
    for species_name, entry in species.items():
        battle_front = project / "assets" / "battle_front_frames" / species_name / "front.png"
        if battle_front.exists():
            entry["front"] = f"res://assets/battle_front_frames/{species_name}/front.png"
    output = project / "data"
    output.mkdir(exist_ok=True)
    moves = parse_moves(source_root)
    (output / "pokemon_db.json").write_text(
        json.dumps({"format": 3, "species_count": len(species), "move_count": len(moves), "species": species, "moves": moves}, separators=(",", ":")),
        encoding="utf-8",
    )
    print(f"Imported {len(species)} Pokemon/form records and {len(moves)} moves")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
