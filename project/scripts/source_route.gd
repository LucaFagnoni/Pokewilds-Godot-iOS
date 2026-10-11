class_name SourceRoute
extends RefCounted

var name: String
var level: int
var stored_pokemon: Array = []
var musics_index := 0
var is_dungeon := false
var dont_spawn_overworlds := false

func _init(route_name: String = "", route_level: int = 0) -> void:
    name = route_name
    level = route_level
    is_dungeon = SourceRouteData.is_dungeon(name)

func type() -> String:
    return SourceRouteData.route_type(name)

func allowed_pokemon() -> Array:
    return SourceRouteData.allowed_pokemon(name)

func musics() -> Array:
    return SourceRouteData.music(name)

