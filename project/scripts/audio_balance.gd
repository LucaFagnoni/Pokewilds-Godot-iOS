class_name AudioBalance
extends RefCounted

static var levels: Dictionary = {}

static func level_db(stream: AudioStream) -> float:
    if stream == null: return -14.0
    if stream.has_meta("balanced_db"): return float(stream.get_meta("balanced_db"))
    if levels.is_empty():
        levels = JSON.parse_string(FileAccess.get_file_as_string("res://data/audio_levels.json"))
    return float(levels.get(stream.resource_path, -14.0))

static func apply(player: AudioStreamPlayer) -> void:
    preload("res://scripts/game_options.gd").route_audio(player)
    player.volume_db = level_db(player.stream)
    # Cries are short, prominent sounds; keep them below the normalized music/SFX mix.
    if player.stream != null and player.stream.resource_path.begins_with("res://assets/source_audio/cries/"):
        player.volume_db -= 6.0
