extends "res://scripts/population_view.gd"
## The sprites of the habitat Pokemon or of the eggs (a HabitatPopulation): a
## pool of them for the records outdoors in the view and a margin round it,
## as PopulationView keeps for the wild ones (where every record had its own
## sprite, a dedicated server's too). A record's "sprite" is the one it holds
## while in view, none otherwise; one in a house (its "house_door") keeps a
## sprite of its own, made where it is placed. The world's LandmarkLayer
## (habitat Pokemon) and WildEggLayer (eggs) each hold one of these.
##
## The pool runs again only when the view's cells or the records change.

const HabitatPopulation = preload("res://scripts/habitat_population.gd")
const HeldItemEmote = preload("res://scripts/held_item_emote.gd")

var records_of: HabitatPopulation
## sprite -> the record holding it.
var held := {}
## sprite -> the tween stepping it (World._habitat_step_visuals).
var steps := {}
var _rect := Rect2i()
var _version := -1
var _size := -1

func configure_records(owner_world: Node, population: HabitatPopulation) -> void:
    world = owner_world
    records_of = population
    drawn = not preload("res://scripts/dedicated_server.gd").active
    process_priority = 1000

func _process(_delta: float) -> void:
    if records_of == null or not drawn:
        return
    var rect := _view_cells() if world.generated and world.active_area_id == "OVERWORLD" else Rect2i()
    var records := records_of.records
    if rect == _rect and records_of.version == _version and records.size() == _size:
        return
    _rect = rect
    _version = records_of.version
    _size = records.size()
    for sprite in held.keys():
        var data: Dictionary = held[sprite]
        var cell: Vector2i = data.get("cell", Vector2i(-2147483648, 0))
        if not is_same(records.get(cell), data) or not rect.has_point(cell) or not is_same(data.get("sprite"), sprite):
            release(sprite)
    if not rect.has_area():
        return
    for raw_cell in records:
        var cell: Vector2i = raw_cell
        if not rect.has_point(cell):
            continue
        var data: Dictionary = records[cell]
        if not data.has("house_door") and not is_instance_valid(data.get("sprite")):
            _acquire_record(data, cell)

func _acquire_record(data: Dictionary, cell: Vector2i) -> void:
    var texture: Texture2D
    if records_of.group == "wild_eggs":
        texture = world.POKEMON_EGG
    else:
        texture = PokemonData.record_texture(data, "overworld")
        if texture == null:
            texture = world.FARM_POKEMON_TEXTURES.get(String(data.get("species", "")).to_lower()) as Texture2D
    if texture == null:
        return
    var sprite := _take()
    sprite.texture = texture
    sprite.position = world._cell_center(cell)
    sprite.z_index = world._depth_z(cell)
    sprite.visible = true
    held[sprite] = data
    data["sprite"] = sprite
    if records_of.group == "wild_eggs":
        return
    world._configure_overworld_sprite(sprite)
    ShinySparkles.attach(sprite, data)
    world._update_pokemon_water_visual(data)
    HeldItemEmote.refresh(data)

## `sprite` goes back to the pool and its record no longer holds it.
func release(sprite: Sprite2D) -> void:
    var data = held.get(sprite)
    held.erase(sprite)
    var tween = steps.get(sprite)
    steps.erase(sprite)
    if tween is Tween and tween.is_valid():
        tween.kill()
    if data is Dictionary:
        if is_same(data.get("sprite"), sprite):
            data.erase("sprite")
        var moving = data.get("ball_move_tween")
        if moving is Tween and moving.is_valid():
            moving.kill()
    if is_instance_valid(sprite) and not sprite.is_queued_for_deletion():
        _give_back(sprite)
