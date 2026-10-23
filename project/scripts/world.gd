extends Node2D
const TexturePixels = preload("res://scripts/texture_pixels.gd")

const SourceMineRuntime = preload("res://scripts/source_mine_runtime.gd")
const InteriorTileBatch = preload("res://scripts/interior_tile_batch.gd")
## The player's collision box (BODY_OFFSET, BODY_HALF).
const PLAYER_BODY = preload("res://scripts/player_controller.gd")
var source_mine_pokemon: Dictionary = {}

signal generation_progress(value: float, message: String)
signal generation_finished
signal encounter_requested(species: String, level: int)
signal battle_requested(context: Dictionary)
signal world_message(message: String)
signal unown_message(message: String)
signal trainer_tip_message(message: String)
signal item_collected(item_name: String)
signal material_collected(item_name: String, amount: int)
signal material_bundle_collected(items: Dictionary)
signal paint_requested(picture_index: int, cell: Vector2i)
signal teleport_map_requested(destinations: Array)
signal crafting_station_requested(station: String)
signal build_requested(build_name: String, cell: Vector2i)
signal build_selection_changed(index: int)
signal dig_requested(choice: String, cell: Vector2i, material: String)
signal build_refund_requested(refund: Dictionary)
signal structure_removal_requested(cell: Vector2i, move: String)
signal pokemon_recalled(pokemon_data: Dictionary)
signal deployed_recall_requested(cell: Vector2i, species: String, message: String)
signal structure_action(action: String)
signal egg_collected(species: String)
signal egg_pickup_prompt_requested(cell: Vector2i)
# Source-style A-button wild interaction prompt. Main owns the modal box so it
# can reuse the approved dialogue border/font without changing world logic.
signal wild_pokemon_prompt_requested(wild_id: int, species: String, kind: String)
signal player_stepped
signal pokemon_ecology_changed(pokemon_data: Dictionary)
signal dig_reward_collected(items: Dictionary)

## Ecology id of the habitat Pokemon whose "take it back?" prompt is open or
## whose recall is on its way: it does not wander off meanwhile.
var recall_hold := ""

## The world's parts that live in scripts of their own. They keep no state:
## what they change is the world's (its vars), so saves and co-op see it as
## before.
const WorldTides = preload("res://scripts/world_tides.gd")
## The tide: when it turns, the bands of shore it moves through, the wading
## visuals.
var tides := WorldTides.new(self)
const WorldFieldMoves = preload("res://scripts/world_field_moves.gd")
## Field moves: choosing one, the helper Pokemon that does it, FLY, RIDE,
## SURF and ice movement, travel, CUT/SMASH/HEADBUTT on resources, DIG.
var field_moves := WorldFieldMoves.new(self)
const WorldBuildings = preload("res://scripts/world_buildings.gd")
## Houses and buildings: BUILD's selection and preview, placing and removing
## structures, house shells, furniture and what using it does.
var buildings := WorldBuildings.new(self)
const WorldInteriors = preload("res://scripts/world_interiors.gd")
## Interiors: the generated caves, dungeons and mansions and going in and out
## of them, the inside of built houses (floors, stairs, paintings), the
## interior map.
var interiors := WorldInteriors.new(self)

const TILE := 16
const CraftingData = preload("res://scripts/crafting_data.gd")
const FieldMoveData = preload("res://scripts/field_move_data.gd")
const PokemonData = preload("res://scripts/pokemon_data.gd")
const PokemonEcology = preload("res://scripts/pokemon_ecology.gd")
const WorldParity = preload("res://scripts/world_parity.gd")
const SourceWorldGenerator = preload("res://scripts/source_world_generator.gd")
const SourceWorldCache = preload("res://scripts/source_world_cache.gd")
const SourceWorldData = preload("res://scripts/source_world_data.gd")
const SourceRouteData = preload("res://scripts/source_route_data.gd")
const SourceExactWorldAdapter = preload("res://scripts/source_exact_world_adapter.gd")
const SOURCE_CHUNK_TILE_LAYER_SCRIPT = preload("res://scripts/source_resident_tile_layer.gd")
const SourceChunkCollisionStreamer = preload("res://scripts/source_resident_collision_layer.gd")
const SourceReflectionLayerScript = preload("res://scripts/source_resident_reflection_layer.gd")
const SourceJavaRandom = preload("res://scripts/source_java_random.gd")
const SourceEventData = preload("res://scripts/source_event_data.gd")
const WorldEnvironmentSystem = preload(
    "res://scripts/world_environment_system.gd"
)

const SOURCE_DAY_TICKS := 18000.0
const SOURCE_NIGHT_TICKS := 5000.0
const WORLD_DAY_SECONDS := (SOURCE_DAY_TICKS + SOURCE_NIGHT_TICKS) / 60.0
const NIGHT_START_FRACTION := (
    SOURCE_DAY_TICKS / (SOURCE_DAY_TICKS + SOURCE_NIGHT_TICKS)
)
const LOW_TIDE_START_1 := 5000.0 / 23000.0
const LOW_TIDE_END_1 := 13000.0 / 23000.0
const LOW_TIDE_START_2 := 18000.0 / 23000.0
const TIDE_MESSAGE_COOLDOWN_SECONDS := 600.0
const WILD_INITIAL_EGG_SECONDS := 30.0
const MATE_BOND_RADIUS := 6

# One entry per world size: the size index is clamped to them. The world's
# real extent comes from the GenIsland1 generator (exact_world_bounds).
const MAP_SIZE_PRESETS := [
    Vector2i(80, 60),
    Vector2i(96, 72),
    Vector2i(112, 84),
    Vector2i(128, 96),
    Vector2i(144, 108)
]

var map_w: int = 64
var map_h: int = 48
var map_size_index: int = 1
var exact_world: SourceExactWorldAdapter
var exact_world_bounds := Rect2i()

const GRASS := preload("res://assets/grass_runtime.png")
const SAND := preload("res://assets/sand_runtime.png")
const WATER := preload("res://assets/water_runtime.png")
const FLOWER_1 := preload("res://assets/flower1_runtime.png")
const POKEMON_EGG := preload("res://assets/pokemon_egg.png")
const SOURCE_STORAGE_BOX := preload(
    "res://assets/source_0_8_11/tiles/chest1.png"
)
const TRAPINCH_BURROW := preload("res://assets/ecology/trapinch_ow1.png")
const DESERT_WHIRLPOOL := preload("res://assets/ecology/whirlpool_desert2.png")
const DESERT_BURROW_SAND := preload("res://assets/ecology/grass_over_sheet3.png")
const LANDMARK_BALL := preload("res://assets/landmark_pokeball.png")
const SOURCE_SIGN := preload("res://assets/world_source/sign1.png")
const SOURCE_CAVE_DOOR := preload("res://assets/world_source/cave_door.png")
const SOURCE_HOUSE := preload("res://assets/world_source/house6_all.png")
const SOURCE_HOUSE_ROOF := preload("res://assets/world_source/house6_roof_all.png")
const SOURCE_HOUSE_DOOR := preload("res://assets/world_source/house6_door1.png")
const SOURCE_SAVANNA_TREE := preload("res://assets/source_0_8_11/tiles/tree_savanna1.png")
const SOURCE_HOUSE5_RUG := preload("res://assets/source_0_8_11/tiles/buildings/house5_floor_rug1.png")
const SOURCE_HOUSE5_WALL := preload("res://assets/source_0_8_11/tiles/buildings/house5_wall1.png")
const SOURCE_HOUSE5_WALL_MIDDLE := preload("res://assets/source_0_8_11/tiles/buildings/house5_middle1.png")
const SOURCE_HOUSE5_DOOR := preload("res://assets/source_0_8_11/tiles/buildings/house5_door1.png")
const SOURCE_HOUSE8_WALL_SHEET := preload("res://assets/source_0_8_11/tiles/buildings/house8_all.png")
const SOURCE_HOUSE8_ROOF := preload("res://assets/source_0_8_11/tiles/buildings/house8_roof_middle1.png")
const SOURCE_HOUSE8_DOOR := preload("res://assets/source_0_8_11/tiles/buildings/house8_door1.png")
const SOURCE_HOUSE12_WALL_SHEET := preload("res://assets/source_0_8_11/tiles/buildings/house12_all.png")
const SOURCE_HOUSE12_ROOF := preload("res://assets/source_0_8_11/tiles/buildings/house12_roof_middle1.png")
const SOURCE_HOUSE12_DOOR := preload("res://assets/source_0_8_11/tiles/buildings/house12_door1.png")
const SOURCE_TABLE := preload("res://assets/world_source/house_table1_default.png")
const SOURCE_MYSTERY_NPC := preload("res://assets/events/npc1.png")
const SOURCE_PUDDLE_SPLASH := preload("res://assets/source_ui/puddle3.png")
const SOURCE_TIDAL_WATER := preload("res://assets/source_0_8_11/tiles/water2.png")
const SOURCE_SLEEPING_BAG := preload("res://assets/source_ui/sleeping_bag1.png")
const SOURCE_PIXEL_FONT := preload("res://assets/source_text_font.fnt")
const FARM_POKEMON_TEXTURES := {
    "pidgey": preload("res://assets/pokemon_pidgey.png"),
    "rattata": preload("res://assets/pokemon_rattata.png"),
    "caterpie": preload("res://assets/pokemon_caterpie.png"),
    "pikachu": preload("res://assets/pokemon_pikachu.png"),
    "machop": preload("res://assets/pokemon_machop.png")
}

var rng := RandomNumberGenerator.new()

var terrain: Array = []
var biomes: Array = []
var blocked: Dictionary = {}
var tall_grass: Dictionary = {}
var landmarks: Dictionary = {}
var resource_objects: Dictionary = {}
var ground_sprites: Dictionary = {}
var ground_collisions: Dictionary = {}
var removed_resources: Dictionary = {}
var terrain_changes: Dictionary = {}
var built_structures: Dictionary = {}
var deployed_pokemon: Dictionary = {}
var build_mode_active := false
var build_selection_index := 0
var build_preview_sprite: Sprite2D
var source_plant_farms: Dictionary = {}
var planting_item := ""
var source_plant_system

func plants():
    if source_plant_system == null:
        source_plant_system = preload("res://scripts/source_plant_farming.gd").new()
        source_plant_system.configure(self)
    return source_plant_system

var active_field_move := ""
var active_field_species := ""
var active_field_pokemon: Dictionary = {}
var dig_selection_index := 0
var world_elapsed_seconds := 0.0
var repel_until_elapsed := 0.0
const DIG_CHOICES := FieldMoveData.DIG_CHOICES
const PAINT_CHOICES := [
    "PICTURE 1", "PICTURE 2", "PICTURE 3", "PICTURE 4", "PICTURE 5",
    "PICTURE 6", "PICTURE 7", "PICTURE 8", "PICTURE 9", "PICTURE 10",
    "PICTURE 11", "PICTURE 12", "PICTURE 13", "PICTURE 14", "PICTURE 15",
    "PICTURE 16", "PICTURE 17", "PICTURE 18", "PICTURE 19", "PICTURE 20"
]
var travel_selection_index := 0
var paint_selection_index := 0
var respawn_cell := Vector2i(-2147483648, -2147483648)
var respawn_house: Dictionary = {}
var field_previous_collision_mask := 1
var structure_textures: Dictionary = {}
var grass_exclusion: Dictionary = {}
var flower_cells: Dictionary = {}
var animated_flowers: Array[Sprite2D] = []
var flower_anim_time := 0.0
var spawn_cell := Vector2i(map_w / 2, map_h / 2)
var biome_centers: Dictionary = {}
var route_cells: Dictionary = {}
var source_landmarks: Dictionary = {}
var source_tiles: Dictionary = {}
var habitat_routes: Dictionary = {}
var source_area_entries: Dictionary = {}
var source_area_rects: Dictionary = {}
var source_area_layers: Dictionary = {}
var source_area_origins: Dictionary = {}
var source_layer_area_ids: Dictionary = {}
var generated_source_interior_plans: Array[Dictionary] = []
var interior_interactables: Dictionary = {}
var source_interior_upper_sprites: Dictionary = {}
var source_interior_mutations: Dictionary = {}
var built_house_interior_cells: Dictionary = {}
var built_house_paintable_walls: Dictionary = {}
# Persistent paint records are keyed by exterior door + local interior wall.
var built_house_paintings: Dictionary = {}
# Sprite instances are runtime-only and rebuilt whenever the house is entered.
var built_house_paint_sprites: Dictionary = {}
var active_built_house_door := Vector2i(-2147483648, -2147483648)
var built_house_interior_origin := Vector2i.ZERO
# Built houses use separate off-map coordinate bands for each source-style
# interior floor. Upper floors begin as void except for the 3x3 patch created
# by a staircase and can then be expanded with FLOOR tiles.
const BUILT_HOUSE_FLOOR_STRIDE := 64
var built_house_floor_origins: Dictionary = {}
var built_house_origins: Dictionary = {}
var built_house_exit_doors: Dictionary = {}
var built_house_room_size := Vector2i.ZERO
var built_house_footprint: Dictionary = {}
## Where each house's room was last drawn from: its place in the interior
## strip -> [the outside corner the room was measured from, the room's size].
## Lets a piece of the outside be matched to its tile of the room after the
## piece has been cut off from the door, or the house has changed shape.
var built_house_rooms_seen: Dictionary = {}
var built_house_floor_capacity := 1
var built_house_floor_tiles: Dictionary = {}
var built_house_decorations: Dictionary = {}
var built_house_decoration_sprites: Dictionary = {}
var built_house_void_collisions: Dictionary = {}
## The inside of a built house and the generated dungeons are laid out in the
## same far-off stretch of coordinates, so a dungeon's walls could mark tiles
## of a house's floor as blocked: BUILD and the other work moves then refused
## to start on open floor ("Leave one clear tile ahead"), and furniture could
## not be placed there. While a house is entered those marks are set aside
## here, and put back when it is left.
var built_house_displaced_blocks: Dictionary = {}
var built_house_blocks_stale := false
var normal_grass_front_sprite: Sprite2D
var savanna_tree_front_sprite: Sprite2D
var active_regi_pedestal_cell := Vector2i(-2147483648, -2147483648)
var active_area_id := "OVERWORLD"
var area_return_cells: Dictionary = {}
const DiscoveredCells = preload("res://scripts/discovered_cells.gd")
## The cells the player has uncovered: a bitset over the map (discovered_cells.gd).
var discovered_cells := DiscoveredCells.new()
## What _discover_around added to discovered_cells since the minimap last took
## it: the cells' bounding box (empty if none), and how many were added in all.
## The minimap redraws just that box; if discovered_cells changed by any other
## way, the counts disagree and it redraws everything.
var discovered_dirty := Rect2i()
var discovered_added := 0
var map_art_revision := 0
## The same for the full map (main.map_raster takes them): a box round the
## cells discovered, one round the tiles and buildings whose art changed, and
## how many map_art_revision bumps came with a box (_bump_map_art). The map
## redraws all it has after a bump without one.
var map_fog_dirty := Rect2i()
var map_art_dirty := Rect2i()
var map_art_boxed := 0

func _bump_map_art(cells: Array, reach := 0) -> void:
    map_art_revision += 1
    map_art_boxed += 1
    for cell in cells:
        var box := Rect2i(cell, Vector2i.ONE).grow(reach)
        map_art_dirty = box if map_art_dirty.size == Vector2i.ZERO else map_art_dirty.merge(box)

var dropped_item_manager: Node2D

func dropped_items() -> Node2D:
    if not is_instance_valid(dropped_item_manager):
        dropped_item_manager = preload("res://scripts/source_dropped_items.gd").new()
        add_child(dropped_item_manager)
        dropped_item_manager.world = self
    return dropped_item_manager

const WildPopulation = preload("res://scripts/wild_population.gd")
## The wild Pokemon (wild_population.gd): where each stands in packed arrays and
## a grid, the rest in its record.
var wild_population := WildPopulation.new()
## Its records by id (the same dictionary): add, move and remove them through
## wild_population.
var wild_pokemon: Dictionary = wild_population.records
var wild_eggs: Dictionary = {}
var next_wild_id := 1
var next_deployed_id := 1
var ecology_accumulator := 0.0
var follower_pokemon: Dictionary = {}
var follower_sprite: Sprite2D
var follower_move_tween: Tween
var follower_walk_phase := 0
var field_helper_pokemon: Dictionary = {}
var field_helper_sprite: Sprite2D
var fly_shadow: Polygon2D
var field_helper_cell := Vector2i(-2147483648, -2147483648)
var work_trainer_sprite: Sprite2D
var work_trail: Array[Vector2] = []
var stool_seated_sprite: Sprite2D
var work_trainer_facing := Vector2i.DOWN
var work_trainer_position := Vector2.ZERO
var work_trainer_walking := false
var reflection_layer: SourceReflectionLayer
var sleeping_bag_sprite: Sprite2D
var sleeping_bag_rest_texture: Texture2D
var sleeping_bag_sleep_marks: Array[Label] = []
var sleeping_bag_anim_time := 0.0
var bed_rest_active := false
var last_pokemon_push_msec := -1000
var follower_cell := Vector2i(-2147483648, -2147483648)
var deployed_recall_candidate := Vector2i(-2147483648, -2147483648)
var deployed_recall_candidate_msec := 0
var pending_egg_record: Dictionary = {}
var burrow_busy := false
var sand_trap_ids: Dictionary = {}
var pending_encounter_record: Dictionary = {}
var pending_battle_context: Dictionary = {}
var event_progress: Dictionary = {
    "completed": {},
    "trainer_defeated": {},
    "keystone_life_force": {},
    "regis_caught": [],
    "mewtwo_defeated_day": -1,
    "fossil_machine_powered": false,
    "biome_first_entries": {}
}
var event_npcs: Dictionary = {}
var source_event_collisions: Dictionary = {}
var ghost_step_countdown := -1
var last_event_day := 0


# Source GenIsland1 keeps several authored habitat names that the surrounding
# Godot systems historically collapsed into the six compatibility biomes.
# Normalize only aliases that are semantically identical (notably TUNDRA ->
# SNOW); preserve real sub-biomes such as GRAVEYARD, VOLCANO, BEACH and RIVER.
const SOURCE_BIOME_ALIASES := {
    "TUNDRA": "SNOW",
    "SNOW": "SNOW",
    "DEEP FOREST": "DEEP_FOREST",
    "WOODED LAKE": "WOODED_LAKE",
    "BEACH_BLACKSAND": "BEACH"
}
const DISCOVERY_RADIUS := 5
const WILD_MOVE_MIN := 1.0
const WILD_MOVE_MAX := 4.0
const ECOLOGY_ACTIVE_RADIUS := 24
const SOURCE_GRASS_ENCOUNTER_RATE := 75
const SOURCE_INTERIOR_ENCOUNTER_RATE := 4
const ENCOUNTER_GRACE_SECONDS := 24.0

var world_seed: int = 81102
var generated := false
var gameplay_enabled := true
var last_player_cell := Vector2i(-9999, -9999)
var encounter_count := 0
var encounter_grace_remaining := 0.0
var water_sprites: Array[Sprite2D] = []
var water_anim_time := 0.0
var water_frame := 0
var environment_system: WorldEnvironmentSystem
var tide_initialized := false
var low_tide_active := false
var tide_target_low := false
var tide_band_cursor := 0
var tide_transition_bands: Array = []
var tide_topology_bands: Array = []
var tide_transition_band_index: int = 0
var tide_transition_accumulator := 0.0
var tide_wade_ripple: Sprite2D
var tide_wade_base: Sprite2D
var last_tide_message_seconds := -TIDE_MESSAGE_COOLDOWN_SECONDS
# The source video shows a coherent shoreline draining/flooding over several
# seconds, not globally ordered single-cell flicker. Each interval advances
# one distance band from the permanent ocean.
const TIDE_FRONTIER_SECONDS := 0.45
const TIDE_RETREAT_FRONTIER_SECONDS := 0.50
const TIDE_TRANSITION_STEPS := 14
const WATER_FRAME_TIME := 0.32
const CAMERA_ZOOM_MIN := 0.45
const CAMERA_ZOOM_MAX := 1.60
const CAMERA_ZOOM_STEP := 0.10
var camera_zoom_level := 1.0

@onready var player: PlayerController = $Player

func _ready() -> void:
    # Generation is intentionally started by main.gd so the normal generation
    # screen can be shown first.
    player.visible = false
    for recipe in CraftingData.build_recipes():
        var build_name := String(recipe.get("name", ""))
        var asset_name := build_name.to_lower().replace(" ", "_")
        var texture_path := "res://assets/build/%s.png" % asset_name
        if ResourceLoader.exists(texture_path):
            structure_textures[build_name] = load(texture_path)
    # The original build sprites live in the imported 0.8.11 tile tree.  Keep
    # the recipe names stable while using those source textures directly.
    var source_build_textures := {
        "TORCH":"torch_sheet1.png", "STORAGE BOX":"chest1.png",
        "SIGN":"sign_built1.png", "STATUE":"statue1.png",
        "GRAVE":"gravestone1.png", "BRIDGE":"bridge1.png",
        "FENCE":"fence1.png", "CAMPFIRE":"campfire1.png",
        "CHIMNEY":"chimney_sheet1.png", "STAIRS":"stairs_up1.png",
        "BEACON":"warp_tile1.png", "KILN":"ball_kiln1.png",
        "FLOWERS":"flower1.png"
    }
    for raw_name in source_build_textures.keys():
        var build_name := String(raw_name)
        if structure_textures.has(build_name):
            continue
        var source_path := "res://assets/source_0_8_11/tiles/%s" % String(source_build_textures[raw_name])
        if ResourceLoader.exists(source_path):
            structure_textures[build_name] = load(source_path)
    # Always use the authored chest sheet. A legacy transparent placeholder
    # could otherwise win the generic res://assets/build lookup above.
    structure_textures["STORAGE BOX"] = SOURCE_STORAGE_BOX
    structure_textures["PRIVATE CHEST"] = SOURCE_STORAGE_BOX
    structure_textures["TABLE"] = SOURCE_TABLE
    var source_warp_tile := "res://assets/source_0_8_11/tiles/warp_tile1.png"
    if ResourceLoader.exists(source_warp_tile):
        structure_textures["BEACON"] = load(source_warp_tile)
    var indoor_build_textures := {
        "PLANT":"house_plant1.png", "WALL":"building1_wall1.png",
        "ROOF":"house6_roof_middle1.png", "WINDOW":"house_window1.png",
        "BED":"house_bed1.png", "CLOCK":"house_clock1.png",
        "COUCH":"house_couch1.png", "TRASH CAN":"house_trashcan1.png",
        "SHELF":"house_shelf1.png", "DRESSER":"house_wardrobe1.png",
        "VANITY":"house_vanity1.png", "STOOL":"house_stool1.png",
        "TABLE":"table.png", "FLOOR":"building1_floor1.png",
        "INTERIOR WALL":"house5_wall1.png", "DOOR":"house5_door1.png"
    }
    for raw_name in indoor_build_textures.keys():
        var build_name := String(raw_name)
        if structure_textures.has(build_name):
            continue
        var source_path := "res://assets/source_0_8_11/tiles/buildings/%s" % String(indoor_build_textures[raw_name])
        if ResourceLoader.exists(source_path):
            structure_textures[build_name] = load(source_path)
    # Match the downstairs brown vertical-plank back wall, including legacy builds.
    structure_textures["INTERIOR WALL"] = SOURCE_HOUSE5_WALL
    var doll_texture := "res://assets/source_0_8_11/tiles/pokedoll1.png"
    if ResourceLoader.exists(doll_texture):
        for doll in ["PICHU DOLL", "DUSKULL DOLL", "SKITTY DOLL", "JIGGLYPUFF DOLL"]:
            if not structure_textures.has(doll):
                structure_textures[doll] = load(doll_texture)
    environment_system = WorldEnvironmentSystem.new()
    environment_system.name = "WorldEnvironmentSystem"
    add_child(environment_system)
    environment_system.configure(self)

var generation_error := ""
var _accepted_exact_result: Dictionary = {}

func generate_world(
        seed_value: int, size_index: int = 1, prefer_saved_cache: bool = false
    ) -> void:
    generation_error = ""
    PokemonData.load_in_background()
    var previous_gameplay_enabled := gameplay_enabled
    gameplay_enabled = false
    var normalized_seed: int = absi(seed_value)
    if normalized_seed == 0: normalized_seed = 81102
    var accepted := await _prepare_exact_world(normalized_seed, clampi(size_index,0,MAP_SIZE_PRESETS.size()-1), prefer_saved_cache)
    if accepted.is_empty() or accepted.has("generation_error"):
        generation_error = String(accepted.get("generation_error", "World generation failed. Please try again."))
        gameplay_enabled = previous_gameplay_enabled
        return
    _accepted_exact_result = accepted
    generated = false
    gameplay_enabled = false

    map_size_index = clampi(size_index, 0, MAP_SIZE_PRESETS.size() - 1)
    var selected_size: Vector2i = MAP_SIZE_PRESETS[map_size_index]
    map_w = selected_size.x
    map_h = selected_size.y
    spawn_cell = Vector2i(map_w / 2, map_h / 2)

    if player.has_method("set_streamed_overworld_depth"):
        player.call("set_streamed_overworld_depth", true)

    world_seed = abs(seed_value)
    if world_seed == 0:
        world_seed = 81102

    await _clear_generated_world()
    generation_progress.emit(0.90, "Preparing world...")
    await get_tree().process_frame

    terrain.clear()
    biomes.clear()
    blocked.clear()
    built_house_displaced_blocks.clear()
    built_house_blocks_stale = false
    tall_grass.clear()
    landmarks.clear()
    resource_objects.clear()
    ground_sprites.clear()
    ground_collisions.clear()
    removed_resources.clear()
    terrain_changes.clear()
    built_structures.clear()
    deployed_pokemon.clear()
    build_mode_active = false
    build_selection_index = 0
    build_preview_sprite = null
    source_plant_farms.clear()
    interior_map_cache_key.clear()
    interior_map_bounds_key.clear()
    interior_map_cache = null
    planting_item = ""
    active_field_move = ""
    active_field_species = ""
    active_field_pokemon.clear()
    dig_selection_index = 0
    world_elapsed_seconds = 0.0
    repel_until_elapsed = 0.0
    grass_exclusion.clear()
    flower_cells.clear()
    animated_flowers.clear()
    flower_anim_time = 0.0
    encounter_count = 0
    encounter_grace_remaining = 0.0
    discovered_cells.reset(Rect2i())
    dropped_items().restore({})
    map_art_revision += 1
    wild_population.clear()
    sand_trap_ids.clear()
    sand_trap_clocks.clear()
    sand_trap_clock_of.clear()
    wild_eggs.clear()
    next_wild_id = 1
    next_deployed_id = 1
    ecology_accumulator = 0.0
    follower_pokemon.clear()
    follower_sprite = null
    follower_move_tween = null
    follower_walk_phase = 0
    follower_cell = Vector2i(-2147483648, -2147483648)
    field_helper_pokemon.clear()
    field_helper_sprite = null
    field_helper_cell = Vector2i(-2147483648, -2147483648)
    work_trainer_sprite = null
    work_trail.clear()
    player.sprite.visible = true
    if is_instance_valid(fly_shadow):
        fly_shadow.queue_free()
    fly_shadow = null
    if player.has_method("set_field_visual_offset"):
        player.call("set_field_visual_offset", Vector2.ZERO)
    reflection_layer = null
    tide_initialized = false
    low_tide_active = false
    tide_target_low = false
    tide_transition_bands.clear()
    tide_topology_bands.clear()
    tide_transition_band_index = 0
    tide_transition_accumulator = 0.0
    if is_instance_valid(tide_wade_ripple):
        tide_wade_ripple.queue_free()
    tide_wade_ripple = null
    if is_instance_valid(tide_wade_base):
        tide_wade_base.queue_free()
    tide_wade_base = null
    deployed_recall_candidate = Vector2i(-2147483648, -2147483648)
    deployed_recall_candidate_msec = 0
    pending_egg_record.clear()
    burrow_busy = false
    pending_encounter_record.clear()
    pending_battle_context.clear()
    event_progress = {
        "completed": {}, "trainer_defeated": {},
        "keystone_life_force": {}, "regis_caught": [],
        "mewtwo_defeated_day": -1, "fossil_machine_powered": false,
        "biome_first_entries": {}
    }
    event_npcs.clear()
    source_event_collisions.clear()
    ghost_step_countdown = -1
    last_event_day = 0
    biome_centers.clear()
    route_cells.clear()
    source_landmarks.clear()
    source_tiles.clear()
    habitat_routes.clear()
    source_area_entries.clear()
    source_area_rects.clear()
    source_area_layers.clear()
    source_area_origins.clear()
    source_layer_area_ids.clear()
    generated_source_interior_plans.clear()
    interior_interactables.clear()
    source_interior_upper_sprites.clear()
    source_interior_mutations.clear()
    source_mine_pokemon.clear()
    built_house_rooms_seen.clear()
    built_house_interior_cells.clear()
    built_house_paintable_walls.clear()
    built_house_paint_sprites.clear()
    built_house_decoration_sprites.clear()
    built_house_floor_origins.clear()
    built_house_floor_tiles.clear()
    built_house_decorations.clear()
    built_house_void_collisions.clear()
    built_house_room_size = Vector2i.ZERO
    built_house_floor_capacity = 1
    active_built_house_door = Vector2i(-2147483648, -2147483648)
    built_house_interior_origin = Vector2i.ZERO
    built_house_origins.clear()
    built_house_exit_doors.clear()
    respawn_house.clear()
    active_regi_pedestal_cell = Vector2i(-2147483648, -2147483648)
    exact_world = null
    exact_world_bounds = Rect2i()
    area_return_cells.clear()
    active_area_id = "OVERWORLD"
    water_sprites.clear()
    water_anim_time = 0.0
    water_frame = 0
    tide_initialized = false
    low_tide_active = false
    last_tide_message_seconds = -TIDE_MESSAGE_COOLDOWN_SECONDS

    var ground_layer := Node2D.new()
    ground_layer.name = "GroundLayer"
    ground_layer.z_index = -20
    add_child(ground_layer)
    move_child(ground_layer, 0)

    var decor_layer := Node2D.new()
    decor_layer.name = "DecorLayer"
    decor_layer.z_index = 0
    add_child(decor_layer)

    var route_layer := Node2D.new()
    route_layer.name = "RouteLayer"
    route_layer.z_index = -10
    add_child(route_layer)

    var grass_layer := Node2D.new()
    grass_layer.name = "TallGrassLayer"
    grass_layer.z_index = 0
    add_child(grass_layer)

    var grass_front_layer := Node2D.new()
    grass_front_layer.name = "TallGrassFrontLayer"
    grass_front_layer.z_index = 0
    add_child(grass_front_layer)

    var landmark_layer := Node2D.new()
    landmark_layer.name = "LandmarkLayer"
    landmark_layer.z_index = 0
    add_child(landmark_layer)

    var wild_layer := Node2D.new()
    wild_layer.name = "WildPokemonLayer"
    wild_layer.z_index = 0
    add_child(wild_layer)

    var egg_layer := Node2D.new()
    egg_layer.name = "WildEggLayer"
    egg_layer.z_index = 0
    add_child(egg_layer)

    var collision_body := CollisionBody.new()
    collision_body.name = "WorldCollision"
    add_child(collision_body)

    await _generate_exact_live_world(
        world_seed, map_size_index, ground_layer, decor_layer,
        collision_body, prefer_saved_cache
    )

func _prepare_exact_world(seed_value: int, size_index: int, prefer_saved_cache: bool) -> Dictionary:
    var exact_result: Dictionary = {}
    if prefer_saved_cache:
        generation_progress.emit(0.08, "Loading saved world...")
        await get_tree().process_frame
        var cache_reader := Thread.new()
        var cache_error := cache_reader.start(
            SourceWorldCache.load_result.bind(seed_value, size_index))
        if cache_error == OK:
            while cache_reader.is_alive():
                await get_tree().process_frame
            exact_result = cache_reader.wait_to_finish()
        else:
            push_warning("Saved-world cache worker unavailable; regenerating world.")

    if exact_result.is_empty():
        generation_progress.emit(0.08, "Reproducing GenIsland1 source world...")
        await get_tree().process_frame
        var generation_thread := Thread.new()
        var start_error := generation_thread.start(
            Callable(self, "_run_exact_generation_job").bind(seed_value, size_index)
        )
        if start_error != OK:
            return {"generation_error":"Could not start world generation. Please try again."}
        var pulse := 0.08
        var exact_started_at := Time.get_ticks_msec()
        var expected_seconds: Array[float] = [90.0, 130.0, 180.0, 240.0, 310.0]
        while generation_thread.is_alive():
            var elapsed_seconds := (
                Time.get_ticks_msec() - exact_started_at
            ) / 1000.0
            var expected := expected_seconds[clampi(
                size_index, 0, expected_seconds.size() - 1
            )]
            pulse = 0.08 + 0.80 * minf(elapsed_seconds / expected, 0.99)
            generation_progress.emit(
                pulse,
                "Building the original full landmass... %ds" % int(elapsed_seconds)
            )
            await get_tree().create_timer(0.10).timeout
        exact_result = generation_thread.wait_to_finish()
        if exact_result.has("generation_error"): return exact_result
        # Cached once adapted and packed (_generate_exact_live_world).
        if not exact_result.is_empty(): exact_result["_write_packed_cache"] = true
    if exact_result.is_empty():
        return {"generation_error":"World generation returned no data. Please try again."}
    return exact_result

func _generate_exact_live_world(
        seed_value: int,
        size_index: int,
        ground_layer: Node2D,
        decor_layer: Node2D,
        collision_body: CollisionBody,
        prefer_saved_cache: bool
    ) -> void:
    var exact_result := _accepted_exact_result
    _accepted_exact_result = {}
    var adapter_job := Thread.new()
    var adapter_work := func(): return SourceExactWorldAdapter.from_generator_result(exact_result, SourceJavaRandom.new(seed_value ^ 0x535041574E))
    if adapter_job.start(adapter_work) == OK:
        while adapter_job.is_alive(): await get_tree().process_frame
        exact_world = adapter_job.wait_to_finish()
    else:
        exact_world = adapter_work.call()
    if bool(exact_result.get("_write_packed_cache", false)):
        generation_progress.emit(0.89, "Preparing fast saved-game loading...")
        # Serialization/compression is data-only: keep the window responsive.
        var cache_writer := Thread.new()
        if cache_writer.start(SourceWorldCache.save_world.bind(seed_value, size_index, exact_world, exact_result)) == OK:
            while cache_writer.is_alive(): await get_tree().process_frame
            cache_writer.wait_to_finish()
        else:
            push_warning("Saved-world cache worker unavailable; cache was not written.")
    _repair_orphaned_large_trees()
    exact_world_bounds = exact_world.bounds()
    # Discovery covers every cell _in_bounds accepts: the tile store's rectangle.
    var store_tiles = exact_world.tiles
    discovered_cells.reset(Rect2i(store_tiles.origin, Vector2i(store_tiles.width, store_tiles.height)) if store_tiles is WorldTileStore else exact_world_bounds)
    map_w = exact_world_bounds.size.x
    map_h = exact_world_bounds.size.y
    spawn_cell = exact_world.spawn_cell
    generated_source_interior_plans = exact_world.interior_plans

    # Put the tracked player at the source-selected spawn before configuring
    # either streamer. Their first visible/collision windows must be centered
    # on the real spawn rather than the scene's temporary origin.
    player.position = _cell_center(spawn_cell)
    if player.has_method("set_streamed_overworld_depth"):
        player.call("set_streamed_overworld_depth", true)

    var base_stream = SOURCE_CHUNK_TILE_LAYER_SCRIPT.new()
    base_stream.name = "ExactBaseTileStream"
    base_stream.z_index = -20
    ground_layer.add_child(base_stream)
    base_stream.configure(exact_world.tiles, player, false, TILE, true, true)
    await base_stream.build_resident_async()
    var upper_stream = SOURCE_CHUNK_TILE_LAYER_SCRIPT.new()
    upper_stream.name = "ExactUpperTileStream"
    upper_stream.z_index = 2
    decor_layer.add_child(upper_stream)
    upper_stream.configure(exact_world.tiles, player, true, TILE, true, true)
    await upper_stream.build_resident_async()
    _setup_normal_grass_front_overlay()
    _setup_savanna_tree_front_overlay()
    if "source_walked_open_gates" in self: get("source_walked_open_gates").clear()
    var canopy := preload("res://scripts/tree_canopy_overlay.gd").new()
    canopy.name = "TreeCanopyOverlay"
    canopy.world = self
    canopy.z_index = 106
    canopy.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
    add_child(canopy)

    reflection_layer = SourceReflectionLayerScript.new()
    reflection_layer.name = "ExactReflectionLayer"
    reflection_layer.z_index = -19
    add_child(reflection_layer)
    reflection_layer.configure(self, exact_world, player)

    var collision_stream := SourceChunkCollisionStreamer.new()
    collision_stream.name = "ExactCollisionStream"
    add_child(collision_stream)
    collision_stream.configure(exact_world.tiles, player, TILE, true)
    SourceTile.resident_changed_cells.clear()
    await _build_source_interiors(collision_body)
    await _register_exact_exterior_interactables()
    # A saved world's Pokemon come from its save (restore_crafting_save_state),
    # which replaced these anyway: ~1.3 s of spawning thrown away on every load.
    # A save without them is given this same population there.
    if not prefer_saved_cache:
        var source_pokemon_records := exact_world.pokemon_cell_records()
        await _spawn_exact_source_pokemon(source_pokemon_records, true)
        await _spawn_extra_biome_pokemon(source_pokemon_records, true)
        _spawn_exact_burrowed_pokemon(exact_world.burrowed_cell_records())
    _discover_around(spawn_cell, DISCOVERY_RADIUS)

    player.visible = true
    _configure_camera()
    last_player_cell = _player_cell()
    # New worlds seed their first renewable Dig sites immediately. Saved
    # worlds restore their mutations after generation, then refresh for the
    # saved day in _refresh_daily_events(); do not create orphaned sites first.
    if not prefer_saved_cache:
        await _refresh_biome_dig_sites(true)
        SourceForestBoss.install(self)
        await preload("res://scripts/biome_megas.gd").prepare_load(self)
        preload("res://scripts/biome_megas.gd").install(self)
    # Prepare the coast topology before gameplay: the first full-world scan
    # must not block movement or the first focus return after loading.
    await _update_tide_state(false, 0.0, true)
    # A frame of its own: the restore that follows starts in the next one.
    await get_tree().process_frame
    generated = true
    gameplay_enabled = true
    generation_progress.emit(1.0, "Exact source world ready!")
    generation_finished.emit()

func _run_exact_generation_job(seed_value: int, size_index: int) -> Dictionary:
    return SourceWorldGenerator.generate_exact_source_world(seed_value, size_index)

func _register_exact_exterior_interactables() -> void:
    var unown_generated_signs: Array = []
    for plan in generated_source_interior_plans:
        var layer_index := int(plan.get("layer_index", -1))
        var transitions := plan.get("transitions", {}) as Dictionary
        var bounds: Rect2i = plan.get("source_bounds", Rect2i())
        for raw_local_cell in transitions:
            var transition := transitions[raw_local_cell] as Dictionary
            if not bool(transition.get("exit_overworld", false)):
                continue
            var source_cell: Vector2i = transition.get(
                "source_cell", bounds.position + Vector2i(raw_local_cell)
            )
            var exterior_tile := exact_world.tile_at(source_cell)
            var exterior_name := "" if exterior_tile == null else exterior_tile.name + " " + exterior_tile.name_upper
            if exterior_tile != null and ("stairs" in exterior_name or "door" in exterior_name or "entrance" in exterior_name):
                interior_interactables[source_cell] = "GOTO_SOURCE_LAYER:%d:%d:%d" % [
                    layer_index, source_cell.x, source_cell.y
                ]
    var store: WorldTileStore = exact_world.tiles
    var door_ids := {store.string_ids.get("cave1_door1", -1): true, store.string_ids.get("pkmnmansion_ext_door", -1): true}
    # Of the upper names only these do anything below: a cursor for every
    # tree and rock on the map made this ~200 ms of a load, in one frame.
    var upper_kinds := {}
    for upper in ["odd_keystone2", "pokedoll1", "pokedoll1_banette", "pokedoll1_mimikyu", "gravestone2", "pkmnmansion_ext_locked", "pkmnmansion_ext_door"]:
        if store.string_ids.has(upper): upper_kinds[store.string_ids[upper]] = true
    var item_ids := store.has_item_ids
    var upper_ids := store.upper_ids
    var name_ids := store.name_ids
    var flags := store.flags
    var deadline := Time.get_ticks_usec() + 13000
    for index in flags.size():
        if (index & 4095) == 0 and Time.get_ticks_usec() >= deadline:
            await get_tree().process_frame
            deadline = Time.get_ticks_usec() + 13000
            item_ids = store.has_item_ids
            upper_ids = store.upper_ids
            name_ids = store.name_ids
            flags = store.flags
        if not (item_ids[index] != 0 or upper_kinds.has(upper_ids[index]) or door_ids.has(name_ids[index])) \
                or not flags[index] & WorldTileStore.PRESENT:
            continue
        var tile := store.cursor(index)
        var cell := SourceWorldData.pixel_to_cell(tile.position)
        if tile.has_item.begins_with("trainer_tips"):
            unown_generated_signs.append(cell)
            var tip_index := posmod(cell.x * 31 + cell.y * 17, SourceEventData.TRAINER_TIPS.size())
            interior_interactables[cell] = "TRAINER_TIP:%d:%d" % [
                tip_index, 1 if tile.has_item == "trainer_tips_unown" else 0
            ]
        elif not tile.has_item.is_empty():
            interior_interactables[cell] = "ITEM:%s:%d" % [
                tile.has_item, tile.has_item_amount
            ]
        if tile.name_upper == "odd_keystone2":
            interior_interactables[cell] = "ODD_KEYSTONE"
        elif tile.name_upper == "pokedoll1":
            interior_interactables[cell] = "POKE_DOLL"
        elif tile.name_upper == "pokedoll1_banette":
            interior_interactables[cell] = "SPECIAL:doll_banette"
        elif tile.name_upper == "pokedoll1_mimikyu":
            interior_interactables[cell] = "SPECIAL:doll_mimikyu"
        elif tile.name_upper == "gravestone2":
            interior_interactables[cell] = "GRAVESTONE"
        if tile.name_upper == "pkmnmansion_ext_locked":
            interior_interactables[cell] = "MANSION_LOCK:%d:%d" % [cell.x, cell.y]
        var target_layer := -1
        if tile.name == "cave1_door1":
            target_layer = 90
        elif tile.name == "pkmnmansion_ext_door" or tile.name_upper == "pkmnmansion_ext_door":
            # The Oasis fossil lab deliberately reuses pkmnmansion exterior
            # artwork. Route identity is therefore required: oasis1 enters the
            # fossil lab, while the large snow/deep-forest Mansion enters the
            # pkmnmansion1 alias. Treating every shared door as MANSION_0 was
            # the source of the small face-like "mansion" regression.
            var exterior_route_name := ""
            if tile.route_belongs_to != null:
                exterior_route_name = tile.route_belongs_to.name.to_lower()
            interior_interactables[cell] = (
                "GOTO_AREA:FOSSIL_LAB"
                if exterior_route_name == "oasis1"
                else "GOTO_AREA:MANSION_0"
            )
            continue
        if target_layer >= 0:
            interior_interactables[cell] = "GOTO_SOURCE_LAYER:%d:%d:%d" % [
                target_layer, cell.x, cell.y
            ]

    if exact_world != null:
        exact_world.set_meta("unown_generated_signs", unown_generated_signs)

func _spawn_exact_source_pokemon(records: Array[Dictionary], spread: bool = false) -> void:
    var spawn_deadline := Time.get_ticks_usec() + 13000
    for record in records:
        if spread and Time.get_ticks_usec() >= spawn_deadline:
            await get_tree().process_frame
            spawn_deadline = Time.get_ticks_usec() + 13000
        var species := String(record.get("name", "")).to_lower()
        var cell: Vector2i = record.get("cell", Vector2i.ZERO)
        if species.is_empty() or not exact_world.contains_cell(cell):
            continue
        var tile := exact_world.tile_at(cell)
        var home_biome := "OCEAN" if tile == null else _source_biome_for_tile(tile)
        _add_wild_pokemon(
            species, int(record.get("level", 2)), cell, home_biome, 0, record
        )

func _spawn_extra_biome_pokemon(_records: Array[Dictionary], spread: bool = false) -> void:
    var spawn_deadline := Time.get_ticks_usec() + 13000
    # New-world companions replace the old partial 50% density pass.
    # Preserve authored encounters and only create valid breeding partners.
    var occupied: Dictionary = {}
    for id in wild_pokemon:
        occupied[wild_pokemon[id].cell] = id
    var initial_ids := wild_pokemon.keys()
    var paired: Dictionary = {}
    var offsets: Array[Vector2i] = []
    for radius in range(1, MATE_BOND_RADIUS + 1):
        for y in range(-radius, radius + 1):
            for x in range(-radius, radius + 1):
                if maxi(absi(x), absi(y)) == radius:
                    offsets.append(Vector2i(x, y))
    for id in initial_ids:
        if spread and Time.get_ticks_usec() >= spawn_deadline:
            await get_tree().process_frame
            spawn_deadline = Time.get_ticks_usec() + 13000
        if paired.has(id): continue
        var original: Dictionary = wild_pokemon[id]
        var species := String(original.species)
        var groups: Array = original.get("egg_groups", [])
        var gender := String(original.get("gender", "unknown"))
        if groups.has("EGG_NONE") or groups.has("EGG_DITTO") or gender == "unknown" or bool(original.get("burrowed", false)) or bool(original.get("behavior", {}).get("stationary", false)):
            continue
        var origin: Vector2i = original.cell
        # Use an existing adjacent compatible animal before adding another.
        var partner_id := -1
        for offset in offsets:
            var nearby_id := int(occupied.get(origin + offset, -1))
            if nearby_id >= 0 and not paired.has(nearby_id) and PokemonEcology.can_mate(original, wild_pokemon[nearby_id]):
                partner_id = nearby_id
                break
        if partner_id < 0:
            var origin_tile := exact_world.tile_at(origin)
            var route := "" if origin_tile == null or origin_tile.route_belongs_to == null else origin_tile.route_belongs_to.name
            var partner_gender := "male" if gender == "female" else "female"
            var partner_species := ""
            var candidates: Array[String] = [species]
            for candidate_species in SourceRouteData.allowed_pokemon(route):
                if not candidates.has(String(candidate_species)): candidates.append(String(candidate_species))
            for candidate_species in candidates:
                var info := PokemonData.info(candidate_species)
                var ratio := String(info.get("gender_ratio", "GENDER_UNKNOWN"))
                if ratio == "GENDER_UNKNOWN" or (ratio == "GENDER_F0" and partner_gender == "female") or (ratio == "GENDER_F100" and partner_gender == "male"): continue
                if PokemonData.texture(candidate_species, "overworld") == null: continue
                var test_partner := PokemonEcology.ensure_record({"species":candidate_species,"gender":partner_gender}, rng)
                if PokemonEcology.can_mate(original, test_partner):
                    partner_species = candidate_species
                    break
            if partner_species.is_empty(): continue
            for offset in offsets:
                var candidate := origin + offset
                if occupied.has(candidate) or wild_eggs.has(candidate) or deployed_pokemon.has(candidate) or not _pokemon_can_move_between(partner_species, origin, candidate): continue
                var tile := exact_world.tile_at(candidate)
                if tile == null or tile.route_belongs_to == null or tile.route_belongs_to.name != route: continue
                var new_id := next_wild_id
                _add_wild_pokemon(partner_species, int(original.level), candidate, String(original.home_biome), 0, {"gender":partner_gender, "generation":original.get("source_record", {}).get("generation", "")})
                if not wild_pokemon.has(new_id): continue
                occupied[candidate] = new_id
                partner_id = new_id
                break
            if partner_id < 0:
                # An isolated authored cell may have no room for two actors.
                # Find two adjacent cells in the SAME source route, keeping
                # both the terrain and the encounter species list intact.
                for radius in range(1, 17):
                    if partner_id >= 0: break
                    # A search that finds nothing took ~220 ms: a ring per slice.
                    if spread and Time.get_ticks_usec() >= spawn_deadline:
                        await get_tree().process_frame
                        spawn_deadline = Time.get_ticks_usec() + 13000
                    for y in range(-radius, radius + 1):
                        if partner_id >= 0: break
                        for x in range(-radius, radius + 1):
                            if maxi(absi(x), absi(y)) != radius: continue
                            var first := origin + Vector2i(x, y)
                            if occupied.has(first) or wild_eggs.has(first) or deployed_pokemon.has(first) or not _pokemon_can_move_between(species, origin, first): continue
                            var first_tile := exact_world.tile_at(first)
                            if first_tile == null or first_tile.route_belongs_to == null or first_tile.route_belongs_to.name != route: continue
                            for direction in [Vector2i.LEFT,Vector2i.RIGHT,Vector2i.UP,Vector2i.DOWN]:
                                var second: Vector2i = first + direction
                                if occupied.has(second) or wild_eggs.has(second) or deployed_pokemon.has(second) or not _pokemon_can_move_between(partner_species, origin, second): continue
                                var second_tile := exact_world.tile_at(second)
                                if second_tile == null or second_tile.route_belongs_to == null or second_tile.route_belongs_to.name != route: continue
                                var new_id := next_wild_id
                                _add_wild_pokemon(partner_species, int(original.level), second, String(original.home_biome), 0, {"gender":partner_gender, "generation":original.get("source_record", {}).get("generation", "")})
                                if not wild_pokemon.has(new_id): continue
                                occupied.erase(origin)
                                occupied[first] = id
                                occupied[second] = new_id
                                wild_population.move(id, first)
                                var sprite := original.get("sprite") as Sprite2D
                                if is_instance_valid(sprite): sprite.position = _cell_center(first)
                                partner_id = new_id
                                break
                            if partner_id >= 0: break
        if partner_id >= 0:
            var partner: Dictionary = wild_pokemon[partner_id]
            original["mate_id"] = partner.ecology_id
            partner["mate_id"] = original.ecology_id
            wild_pokemon[id] = original
            wild_pokemon[partner_id] = partner
            paired[id] = true
            paired[partner_id] = true

func _spawn_exact_burrowed_pokemon(records: Array[Dictionary]) -> void:
    for record in records:
        var cell: Vector2i = record.get("cell", Vector2i.ZERO)
        if not exact_world.contains_cell(cell):
            continue
        var tile := exact_world.tile_at(cell)
        var home_biome := "DESERT" if tile == null else _source_biome_for_tile(tile)
        _add_wild_pokemon(
            "trapinch", int(record.get("level", 22)), cell,
            home_biome, 0, record
        )

func _place_source_landmarks(
        parent: Node2D,
        collision_body: CollisionBody
    ) -> void:
    _place_generated_source_landmarks(parent, collision_body)
    if source_landmarks.has("house_anchor"):
        var anchor: Vector2i = source_landmarks["house_anchor"]
        var house := Sprite2D.new()
        house.texture = SOURCE_HOUSE
        house.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
        house.centered = false
        house.position = Vector2(anchor.x * TILE, anchor.y * TILE)
        house.z_as_relative = false
        house.z_index = _depth_z(anchor + Vector2i(1, 1))
        parent.add_child(house)
        var roof := _add_source_sprite(
            parent, SOURCE_HOUSE_ROOF, anchor, 23
        )
        roof.position = Vector2(anchor.x * TILE, anchor.y * TILE)
        var door_cell: Vector2i = source_landmarks["house_door"]
        var door := _add_source_sprite(parent, SOURCE_HOUSE_DOOR, door_cell, 31)
        for yy in range(anchor.y, anchor.y + 2):
            for xx in range(anchor.x, anchor.x + 2):
                var cell := Vector2i(xx, yy)
                blocked[cell] = true
                var collision := _add_landmark_collision(
                    collision_body, cell.x, cell.y
                )
                if cell == door_cell:
                    landmarks[cell] = {
                        "type": "source_house", "sprite": door,
                        "collision": collision, "used": false
                    }

    if source_landmarks.has("cave_door"):
        var cave_cell: Vector2i = source_landmarks["cave_door"]
        var cave := _add_source_sprite(parent, SOURCE_CAVE_DOOR, cave_cell, 31)
        blocked[cave_cell] = true
        var cave_collision := _add_landmark_collision(
            collision_body, cave_cell.x, cave_cell.y
        )
        landmarks[cave_cell] = {
            "type": "source_cave", "sprite": cave,
            "collision": cave_collision, "used": false
        }

    if source_landmarks.has("route_sign"):
        var sign_cell: Vector2i = source_landmarks["route_sign"]
        var sign := _add_source_sprite(parent, SOURCE_SIGN, sign_cell, 31)
        blocked[sign_cell] = true
        var sign_collision := _add_landmark_collision(
            collision_body, sign_cell.x, sign_cell.y
        )
        landmarks[sign_cell] = {
            "type": "source_route_sign", "sprite": sign,
            "collision": sign_collision, "used": false
        }

func _place_generated_source_landmarks(
        parent: Node2D,
        collision_body: CollisionBody
    ) -> void:
    # SourceWorldGenerator has already merged the real Java-generated exterior
    # layouts into source_tiles.  Only register their entrances here.  The old
    # code painted a rectangular placeholder over every footprint, including
    # complete animation sheets, which is what produced the duplicated Regi
    # rows and buildings nested inside themselves.
    for landmark_name in [
            "desert_ruins", "fossil_lab", "pokemon_mansion", "regi_dungeon"
        ]:
        if not source_landmarks.has(landmark_name):
            continue
        var descriptor: Dictionary = source_landmarks[landmark_name]
        var entry: Vector2i = descriptor.get(
            "entry", descriptor.get("anchor", Vector2i.ZERO)
        )
        if not _in_bounds(entry):
            continue
        var collision := ground_collisions.get(entry) as CollisionBox
        if not is_instance_valid(collision):
            collision = _add_landmark_collision(
                collision_body, entry.x, entry.y
            )
            ground_collisions[entry] = collision
        blocked[entry] = true
        grass_exclusion[entry] = true
        landmarks[entry] = {
            "type": "source_area",
            "area": String(descriptor.get("area", "")),
            "sprite": ground_sprites.get(entry),
            "collision": collision,
            "used": false
        }
    for raw_cave in source_landmarks.get("mountain_caves", []):
        var cave: Dictionary = raw_cave
        var cave_anchor: Vector2i = cave.get("anchor", Vector2i.ZERO)
        var cave_size: Vector2i = cave.get("size", Vector2i(3, 3))
        var cave_entry: Vector2i = cave.get("entry", cave_anchor + Vector2i(1, 2))
        for yy in range(cave_size.y):
            for xx in range(cave_size.x):
                var cave_cell := cave_anchor + Vector2i(xx, yy)
                if not _in_bounds(cave_cell):
                    continue
                blocked[cave_cell] = true
                var cave_collision := ground_collisions.get(cave_cell) as CollisionBox
                if not is_instance_valid(cave_collision):
                    cave_collision = _add_landmark_collision(
                        collision_body, cave_cell.x, cave_cell.y
                    )
                    ground_collisions[cave_cell] = cave_collision
                if cave_cell == cave_entry:
                    landmarks[cave_cell] = {
                        "type": "source_area",
                        "area": String(cave.get("area", "")),
                        "sprite": null,
                        "collision": cave_collision,
                        "used": false
                    }
    if source_landmarks.has("mansion_key"):
        var key_cell: Vector2i = (source_landmarks["mansion_key"] as Dictionary).get("cell", Vector2i.ZERO)
        if _in_bounds(key_cell):
            var key_sprite := _add_source_sprite(parent, LANDMARK_BALL, key_cell, 31)
            blocked[key_cell] = true
            var key_collision := _add_landmark_collision(collision_body, key_cell.x, key_cell.y)
            landmarks[key_cell] = {
                "type": "source_key", "item": "MANSION KEY",
                "sprite": key_sprite, "collision": key_collision, "used": false
            }

func _add_source_sprite(
        parent: Node2D,
        texture: Texture2D,
        cell: Vector2i,
        z_value: int,
        logical_frame_size: Vector2 = Vector2.ZERO
    ) -> Sprite2D:
    var sprite := Sprite2D.new()
    sprite.texture = texture
    sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
    sprite.centered = false
    var draw_size := texture.get_size()
    if logical_frame_size != Vector2.ZERO:
        sprite.region_enabled = true
        sprite.region_rect = Rect2(Vector2.ZERO, logical_frame_size)
        draw_size = logical_frame_size
    elif draw_size.x > TILE:
        # Wide source files are animation/variant atlases, not map-sized
        # sprites.  Render one logical frame and never spill the full sheet into
        # neighboring cells.
        sprite.region_enabled = true
        sprite.region_rect = Rect2(
            Vector2.ZERO,
            Vector2(TILE, minf(draw_size.y, TILE * 2.0))
        )
        draw_size = sprite.region_rect.size
    sprite.position = Vector2(
        cell.x * TILE + (TILE - draw_size.x) * 0.5,
        (cell.y + 1) * TILE - draw_size.y
    )
    sprite.z_as_relative = false
    sprite.z_index = z_value if z_value <= 5 else _depth_z(cell, z_value - 16)
    parent.add_child(sprite)
    return sprite

func _refresh_house_structure_depths() -> void:
    buildings.refresh_house_structure_depths()

## Depth of a piece inside a house. A row nearer the bottom of the screen is
## in front: someone standing behind a dresser is covered by it, and someone
## standing in front of it covers it.
const HOUSE_FURNITURE_Z := 1

## Stairs inside a house are part of the floor: over the floor and carpets,
## under furniture, plants and anyone walking on them.
const HOUSE_STAIRS_Z := -3

func _depth_z(cell: Vector2i, offset: int = 0) -> int:
    # Source-world cells can be deeply negative. Absolute cell Y placed
    # followers and roaming Pokemon behind the streamed ground layer.
    # Keep actors above both tile streams while preserving local north/
    # south ordering around the player.
    var relative_y := clampi(cell.y - _player_cell().y, -32, 32)
    return clampi(100 + relative_y * 2 + offset, 16, 190)

func _setup_normal_grass_front_overlay() -> void:
    # One live foreground sprite mirrors the exact source tile already rendered
    # under the player. Normal encounter grass uses the full 16px tile;
    # Savannah uses only the lower 8px. No independent grass animation exists.
    if normal_grass_front_sprite != null and is_instance_valid(normal_grass_front_sprite):
        normal_grass_front_sprite.queue_free()
    var sprite = Sprite2D.new()
    sprite.name = "NormalEncounterGrassFront"
    sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
    sprite.centered = false
    sprite.region_enabled = true
    sprite.z_as_relative = false
    sprite.visible = false
    add_child(sprite)
    normal_grass_front_sprite = sprite

## Base and upper tile names at a cell, read straight from the tile store:
## building a SourceTile proxy for a name costs about 10 us, and the per-frame
## overlays and wild Pokemon ask for many. Empty when there is no tile.
## per-frame
func _exact_names_at(cell: Vector2i) -> PackedStringArray:
    var store = exact_world.tiles
    var key := cell * TILE
    var tile: SourceTile = null
    if store is WorldTileStore:
        var index: int = store.index_of(key)
        if index >= 0:
            return PackedStringArray([store.name_at(index), store.upper_at(index)])
        # Off the packed cells: a plain tile object, as tile_at gives.
        tile = store.extra.get(key) as SourceTile
    else:
        tile = store.get(key) as SourceTile
    return PackedStringArray() if tile == null else PackedStringArray([tile.name, tile.name_upper])

## The world's own cursors for _frame_tile, one per slot.
var _frame_cursors: Array = [null, null]

## per-frame
## The tile at `cell` to read at once, without making a proxy (tile_at makes
## one, ~10 us, for each call: a few a frame were a phone's millisecond). It is
## one of the world's cursors re-pointed at the cell (fresh from the store), or
## the store's plain tile for a cell off its packed arrays. It changes at the
## next call with the same `slot`: read it at once, never keep it or write to
## it, and do not hand it to code that calls _frame_tile itself.
func _frame_tile(cell: Vector2i, slot: int = 0) -> SourceTile:
    var store = exact_world.tiles
    var key := cell * TILE
    if not store is WorldTileStore:
        return store.get(key) as SourceTile
    var index: int = store.index_of(key)
    if index < 0:
        return store.extra.get(key) as SourceTile
    var cursor: SourceTile = _frame_cursors[slot]
    if cursor == null or cursor._store != store:
        cursor = SourceTile.bound_to(store, index)
        _frame_cursors[slot] = cursor
    else:
        cursor.repoint(index)
    return cursor

func _source_tile_key(value: String) -> String:
    var key := value.to_lower().strip_edges()
    if key.ends_with(".png"):
        key = key.trim_suffix(".png")
    return key

func _is_normal_encounter_grass(cell: Vector2i) -> bool:
    if exact_world == null:
        return false
    var tile: SourceTile = exact_world.tile_at(cell)
    if tile == null:
        return false
    return (
        _source_tile_key(tile.name) == "grass1"
        or _source_tile_key(tile.name_upper) == "grass1"
    )

## per-frame
func _update_normal_grass_front_overlay(_cell: Vector2i) -> void:
    if not is_instance_valid(normal_grass_front_sprite):
        return
    # Hide only the fronts left unused: hiding all of them and showing them
    # again sent two visibility changes to the renderer every frame in grass.
    var used := _place_normal_grass_fronts()
    if used == 0:
        normal_grass_front_sprite.hide()
    for k in range(grass_front_sprites.size()):
        if k + 1 >= used and is_instance_valid(grass_front_sprites[k]):
            grass_front_sprites[k].hide()

func _setup_savanna_tree_front_overlay() -> void:
    if savanna_tree_front_sprite != null and is_instance_valid(savanna_tree_front_sprite):
        savanna_tree_front_sprite.queue_free()
    var sprite := Sprite2D.new()
    sprite.name = "SavannaTreeFront"
    sprite.texture = SOURCE_SAVANNA_TREE
    sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
    sprite.centered = false
    sprite.z_as_relative = false
    sprite.z_index = 106
    sprite.visible = false
    add_child(sprite)
    savanna_tree_front_sprite = sprite

func _savanna_tree_anchor_covering(cell: Vector2i) -> Vector2i:
    if exact_world == null:
        return Vector2i(-2147483648, -2147483648)
    # tree_savanna1 is the authored 48x48 source object. Its source anchor draws
    # one tile left and three tiles tall, so test only anchors whose visual
    # footprint can actually cover the player.
    for anchor_y in range(cell.y - 2, cell.y + 1):
        for anchor_x in range(cell.x - 1, cell.x + 2):
            var anchor_cell := Vector2i(anchor_x, anchor_y)
            var names := _exact_names_at(anchor_cell)
            if names.is_empty():
                continue
            var upper_key := _source_tile_key(names[1])
            var base_key := _source_tile_key(names[0])
            if upper_key != "tree_savanna1" and base_key != "tree_savanna1":
                continue
            if cell.x < anchor_x - 1 or cell.x > anchor_x + 1:
                continue
            if cell.y < anchor_y or cell.y > anchor_y + 2:
                continue
            return anchor_cell
    return Vector2i(-2147483648, -2147483648)

## per-frame
func _update_savanna_tree_front_overlay(cell: Vector2i) -> void:
    if savanna_tree_front_sprite == null or not is_instance_valid(savanna_tree_front_sprite):
        return
    if active_area_id != "OVERWORLD":
        savanna_tree_front_sprite.visible = false
        return
    var anchor_cell := _savanna_tree_anchor_covering(cell)
    if anchor_cell.x <= -2147483648:
        savanna_tree_front_sprite.visible = false
        return
    # tree_savanna1 is three tiles high. Only the upper two rows should cover
    # an actor. On the authored bottom/base row the actor's feet are in front;
    # redrawing the whole 48x48 tree there made the player look like they were
    # walking on top of the canopy/edge.
    if cell.y >= anchor_cell.y + 2:
        savanna_tree_front_sprite.visible = false
        return
    savanna_tree_front_sprite.position = Vector2(
        anchor_cell.x * TILE - TILE, anchor_cell.y * TILE)
    savanna_tree_front_sprite.z_index = 106
    savanna_tree_front_sprite.visible = true

func _build_source_interiors(_collision_body: CollisionBody) -> void:
    await interiors.build_source_interiors(_collision_body)

func _built_house_floor_origin(floor_index: int) -> Vector2i:
    return interiors.built_house_floor_origin(floor_index)

func _built_house_floor_index_for_cell(cell: Vector2i) -> int:
    return interiors.built_house_floor_index_for_cell(cell)

func _built_house_global_cell(floor_index: int, local_cell: Vector2i) -> Vector2i:
    return interiors.built_house_global_cell(floor_index, local_cell)

func _add_built_house_floor_cell(
        floor_index: int, local_cell: Vector2i, persist: bool = true
    ) -> bool:
    return interiors.add_built_house_floor_cell(floor_index, local_cell, persist)

func _built_house_floor_can_expand(cell: Vector2i) -> bool:
    return interiors.built_house_floor_can_expand(cell)

func _place_built_house_floor(cell: Vector2i) -> bool:
    return interiors.place_built_house_floor(cell)

func _built_house_stair_metadata(cell: Vector2i) -> Dictionary:
    return interiors.built_house_stair_metadata(cell)

func _stair_belongs_to_active_house(data: Dictionary) -> bool:
    return interiors.stair_belongs_to_active_house(data)

func _create_generated_house_stair_pair(primary_cell: Vector2i) -> void:
    interiors.create_generated_house_stair_pair(primary_cell)

func _set_active_built_house_floor(floor_index: int) -> void:
    interiors.set_active_built_house_floor(floor_index)

func _prepare_built_house_interior(door_cell: Vector2i, house_state: Dictionary) -> void:
    interiors.prepare_built_house_interior(door_cell, house_state)

func _restore_displaced_house_blocks() -> void:
    interiors.restore_displaced_house_blocks()

## Sets aside every blocked mark on this house's floors, and on the wall row
## above each, that does not come from something built in the house.
func _displace_foreign_house_blocks() -> void:
    interiors.displace_foreign_house_blocks()

func _built_house_paint_key(cell: Vector2i) -> String:
    return interiors.built_house_paint_key(cell)

func apply_paint(picture_index: int, cell: Vector2i) -> bool:
    return interiors.apply_paint(picture_index, cell)


var held_emote_refresh_remaining := 0.0
var window_display_cache: Dictionary = {}

func _process(delta: float) -> void:
    var building := active_field_move == "BUILD"
    if generated and building != camera_build_centered:
        camera_build_centered = building
        _configure_camera()
    frame_delta = delta
    _update_world_frame(delta)
    if generated and gameplay_enabled:
        source_dig_water_elapsed += delta
        if source_dig_water_elapsed >= 61.0 / 60.0:
            source_dig_water_elapsed = fmod(source_dig_water_elapsed, 61.0 / 60.0)
            _fill_source_dig_holes()
    if source_night_events == null:
        source_night_events = preload("res://scripts/source_night_events.gd").new()
        source_night_events.configure(self)
    source_night_events.update(delta)
    if roaming_ghosts == null:
        roaming_ghosts = preload("res://scripts/source_roaming_ghosts.gd").new()
        roaming_ghosts.world = self
    roaming_ghosts.update(delta)
    plants().update()
    for index in range(tidal_puddle_splashes.size() - 1, -1, -1):
        var splash = tidal_puddle_splashes[index]
        if not is_instance_valid(splash):
            tidal_puddle_splashes.remove_at(index)
            continue
        var tick := int(floor(world_elapsed_seconds * 60.0))
        var stream = get_node_or_null("GroundLayer/ExactBaseTileStream")
        if stream != null:
            tick = int(stream.get("source_animation_tick"))
        # A shader parameter write is sent to the renderer even when equal.
        var water_frame := posmod(int(tick / 19), 2)
        if splash.material.get_shader_parameter("water_frame") != water_frame:
            splash.material.set_shader_parameter("water_frame", water_frame)
    if generated and gameplay_enabled:
        _update_overworld_idle_sprites(delta)

## per-frame
func _update_world_frame(delta: float) -> void:
    _flush_exact_refresh_queue()
    if active_area_id == "HOUSE":
        if built_house_blocks_stale: _displace_foreign_house_blocks()
    elif not built_house_displaced_blocks.is_empty():
        _restore_displaced_house_blocks()
    held_emote_refresh_remaining -= delta
    if held_emote_refresh_remaining <= 0.0:
        held_emote_refresh_remaining = 0.1
        for resident in deployed_pokemon.values():
            preload("res://scripts/held_item_emote.gd").refresh(resident)
    if generated:
        var coordinator=get_parent().get("coop_game")
        if is_instance_valid(coordinator) and coordinator.active and coordinator.session.trusted:
            world_elapsed_seconds=coordinator.world_time(delta)
        else:world_elapsed_seconds += delta
        SourceForestBoss.update_visibility(self)
        preload("res://scripts/biome_megas.gd").update(self)
        if gameplay_enabled and encounter_grace_remaining > 0.0:
            encounter_grace_remaining = maxf(
                0.0, encounter_grace_remaining - delta
            )
        _update_tide_state(false, delta)
        _update_tidal_wade_visual()
        var current_day := _world_day_index()
        if current_day != last_event_day:
            last_event_day = current_day
            ghost_step_countdown = rng.randi_range(500, 999)
            _refresh_daily_events(true)
        # Decorative pink flowers sway one pixel left/right in place.
        flower_anim_time += delta
        var flower_offset := int(round(sin(flower_anim_time * 4.0)))
        for flower in animated_flowers:
            if is_instance_valid(flower):
                flower.offset.x = flower_offset

        water_anim_time += delta
        if water_anim_time >= WATER_FRAME_TIME:
            water_anim_time = 0.0
            water_frame = 1 - water_frame

            for sprite in water_sprites:
                if is_instance_valid(sprite):
                    sprite.region_rect = Rect2(water_frame * TILE, 0, TILE, TILE)

        if sleeping_bag_sprite != null and is_instance_valid(sleeping_bag_sprite):
            sleeping_bag_anim_time += delta
            if bed_rest_active:
                sleeping_bag_sprite.visible = true
                player.visible = false
            elif sleeping_bag_anim_time < 0.30:
                sleeping_bag_sprite.visible = false
                player.visible = true
                player.set("facing", Vector2.RIGHT)
                if player.has_method("_update_sprite_frame"):
                    player.call("_update_sprite_frame", false)
            elif sleeping_bag_anim_time < 0.72:
                sleeping_bag_sprite.visible = true
                sleeping_bag_sprite.texture = SOURCE_SLEEPING_BAG
                player.visible = true
                player.set("facing", Vector2.LEFT)
                if player.has_method("_update_sprite_frame"):
                    player.call("_update_sprite_frame", false)
            else:
                sleeping_bag_sprite.visible = true
                sleeping_bag_sprite.texture = (
                    sleeping_bag_rest_texture
                    if sleeping_bag_rest_texture != null
                    else SOURCE_SLEEPING_BAG
                )
                player.visible = false
            for mark_index in range(sleeping_bag_sleep_marks.size()):
                var mark := sleeping_bag_sleep_marks[mark_index]
                if is_instance_valid(mark):
                    var phase := fmod(sleeping_bag_anim_time + mark_index * 0.45, 1.35)
                    mark.visible = sleeping_bag_anim_time >= 0.72 and phase < 0.92
                    mark.position.y = -12.0 - mark_index * 5.0 - phase * 4.0

        if not field_helper_pokemon.is_empty() and is_instance_valid(field_helper_sprite):
            _place_field_helper_live()
        if active_field_move == "FLY":
            _set_fly_shadow_active(true)
            _update_fly_shadow()
        elif active_field_move == "RIDE":
            var ride_jumping := player.has_method("is_ledge_jump_active") and \
                bool(player.call("is_ledge_jump_active"))
            _set_fly_shadow_active(ride_jumping)
            if ride_jumping:
                _update_fly_shadow()
        elif is_instance_valid(fly_shadow):
            fly_shadow.visible = false
        if build_mode_active:
            _update_build_preview()

    _update_house_pokemon(delta)
    if not generated or not gameplay_enabled:
        return

    _update_sand_traps(delta)
    if not gameplay_enabled:
        return
    var cell := _player_cell()
    if active_field_move in ["FLY", "SURF"]:
        _clamp_flying_player_to_world()
        if not gameplay_enabled:
            return
        cell = _player_cell()

    _update_normal_grass_front_overlay(cell)
    _update_savanna_tree_front_overlay(cell)

    if active_area_id != "OVERWORLD":
        SourceMineRuntime.update(self, delta)
        if not gameplay_enabled:
            return
        if cell != last_player_cell:
            _advance_follower(last_player_cell, cell)
            last_player_cell = cell
            _refresh_house_structure_depths()
            _spawn_puddle_step_effect(cell)
            player_stepped.emit()
            if _try_step_transition(cell):
                return
            if (
                    not encounter_grace_active()
                    and not _repel_blocks(_level_for_cell(cell))
                    and rng.randi_range(1, 100) < SOURCE_INTERIOR_ENCOUNTER_RATE
                ):
                _request_source_area_encounter()
        return

    _update_ecology(delta)
    _update_deployed_pokemon(delta)
    _update_wild_pokemon(delta)

    if cell != last_player_cell:
        _advance_follower(last_player_cell, cell)
        preload("res://scripts/source_footprints.gd").leave(self, last_player_cell, cell)
        last_player_cell = cell
        _refresh_house_structure_depths()
        _spawn_puddle_step_effect(cell)
        if active_field_move == "SURF" and terrain_kind_at(cell) != 0:
            clear_active_field_move(false)
        _discover_around(cell, 9 if _flash_is_active() else DISCOVERY_RADIUS)
        _handle_biome_entry(cell)
        if active_field_move != "FLY":
            player_stepped.emit()
            preload("res://scripts/rare_forest_mew.gd").on_step(self, cell)
            preload("res://scripts/rare_biome_legendaries.gd").on_step(self, cell)
        if active_field_move == "FLY":
            return
        if _check_trainer_sight(cell):
            return
        if _try_step_transition(cell):
            return

        var wild_id := _wild_id_at_cell(cell)
        if active_field_move != "SURF" and wild_id >= 0 and not encounter_grace_active():
            # Visible overworld Pokemon are solid/contact actors, not grass-like
            # encounter triggers. Battles from angry Pokemon still start through
            # their pursuit/contact path below; hidden burrowed encounters keep
            # their authored step trigger.
            var stepped_wild: Dictionary = wild_pokemon.get(wild_id, {})
            var wild_repelled := _repel_blocks(int(stepped_wild.get("level", 1)))
            if bool(stepped_wild.get("burrowed", false)) and not wild_repelled:
                _trigger_burrowed_pokemon(wild_id)
                return

        if (
                active_field_move != "SURF"
                and not encounter_grace_active()
                and _is_tall_grass_cell(cell)
                and not _repel_blocks(_level_for_cell(cell))
            ):
            # Source PkmnMap rolls 1..100 and starts a grass encounter at
            # <= 75. Keep the source rate so encounter grass cannot appear dead.
            if rng.randi_range(1, 100) <= SOURCE_GRASS_ENCOUNTER_RATE:
                encounter_count += 1
                _request_random_encounter()

## per-frame
func try_walk_into_door(position: Vector2, movement: Vector2) -> bool:
    if not generated or not gameplay_enabled or build_mode_active or \
            active_field_move == "FLY" or movement.length_squared() < 0.0001:
        return false
    var direction := Vector2i(0, (1 if movement.y > 0.0 else -1 if movement.y < 0.0 else 0))
    if absf(movement.x) > absf(movement.y):
        direction = Vector2i((1 if movement.x > 0.0 else -1 if movement.x < 0.0 else 0), 0)
    # Probe just beyond the player's existing 10x10 collision body (offset Y=3).
    # Solid doors stop the body before its centre can reach a step trigger.
    var probe := position + Vector2(0, 3) + Vector2(direction) * 6.0
    var target := Vector2i((probe / float(TILE)).floor())
    if target == Vector2i((position / float(TILE)).floor()):
        return false
    var data: Dictionary = built_structures.get(target, {})
    if String(data.get("name", "")) == "DOOR" and not bool(data.get("gate", false)):
        if active_area_id == "OVERWORLD":
            var outward := _house_door_outward(target)
            if outward == Vector2i.ZERO or direction != -outward or not _house_exit_clear(target + outward):
                return false
            var state := _built_house_state(target)
            if not bool(state.get("ready", false)):
                return false
            _prepare_built_house_interior(target, state)
            _enter_source_area("HOUSE", target + outward)
            return true
        if not bool(data.get("open", false)):
            _toggle_structure_door(target)
        return false
    if active_area_id != "OVERWORLD" or direction != Vector2i.UP:
        return false
    var landmark: Dictionary = landmarks.get(target, {})
    var kind := String(landmark.get("type", ""))
    if kind in ["source_house", "source_cave", "source_area"]:
        var area := "HOUSE" if kind == "source_house" else "CAVE"
        if kind == "source_area":
            area = String(landmark.get("area", ""))
        _enter_source_area(area, target + Vector2i.DOWN)
        return true
    return _try_step_transition(target)


func _try_step_transition(cell: Vector2i) -> bool:
    # Built-house stairs are entered by stepping onto them, matching the source
    # house flow. A-button interaction remains available as a redundant route.
    if active_area_id == "HOUSE" and built_structures.has(cell):
        var built_data: Dictionary = built_structures[cell]
        if String(built_data.get("name", "")) == "STAIRS" and \
                _stair_belongs_to_active_house(built_data):
            _use_linked_stairs(cell)
            return true
    var action := String(interior_interactables.get(cell, ""))
    if not (
            action.begins_with("GOTO_SOURCE_LAYER:")
            or action.begins_with("EXIT_AREA:")
            or action.begins_with("GOTO_AREA:")
            or action == "EXIT_HOUSE"
            or action == "EXIT_CAVE"
        ):
        return false
    _use_interior_interactable(action, cell)
    return true

func _check_trainer_sight(player_cell: Vector2i) -> bool:
    var defeated := event_progress.get("trainer_defeated", {}) as Dictionary
    for raw_id in event_npcs.keys():
        var trainer_id := String(raw_id)
        if bool(defeated.get(trainer_id, false)):
            continue
        var npc := event_npcs[raw_id] as Dictionary
        var npc_cell: Vector2i = npc.get("cell", Vector2i.ZERO)
        var offset := player_cell - npc_cell
        if not (offset.x == 0 or offset.y == 0):
            continue
        var distance := absi(offset.x) + absi(offset.y)
        if distance <= 0 or distance > 5:
            continue
        var direction := Vector2i(signi(offset.x), signi(offset.y))
        var clear_line := true
        for step in range(1, distance):
            var check := npc_cell + direction * step
            if not _is_walkable(check) or interior_interactables.has(check):
                clear_line = false
                break
        if not clear_line:
            continue
        var context := (npc.get("context", {}) as Dictionary).duplicate(true)
        context["cell_x"] = npc_cell.x
        context["cell_y"] = npc_cell.y
        pending_battle_context = context.duplicate(true)
        world_message.emit("!")
        battle_requested.emit(context)
        return true
    return false

func _unhandled_input(event: InputEvent) -> void:
    if not generated or not gameplay_enabled:
        return

    if not planting_item.is_empty() and event.is_action_pressed("cancel"):
        planting_item = ""
        get_viewport().set_input_as_handled()
        return
    if event.is_action_pressed("shoulder_left"):
        if active_field_move == "BUILD":
            _cycle_build_selection(-1)
            get_viewport().set_input_as_handled()
            return
        if active_field_move == "DIG":
            _cycle_dig_selection(-1)
            get_viewport().set_input_as_handled()
            return
        if active_field_move == "PAINT":
            _cycle_paint_selection(-1)
            get_viewport().set_input_as_handled()
            return
        if active_field_move == "TELEPORT":
            _cycle_travel_selection(-1)
            get_viewport().set_input_as_handled()
            return

    if event.is_action_pressed("shoulder_right"):
        if active_field_move == "BUILD":
            _cycle_build_selection(1)
            get_viewport().set_input_as_handled()
            return
        if active_field_move == "DIG":
            _cycle_dig_selection(1)
            get_viewport().set_input_as_handled()
            return
        if active_field_move == "PAINT":
            _cycle_paint_selection(1)
            get_viewport().set_input_as_handled()
            return
        if active_field_move == "TELEPORT":
            _cycle_travel_selection(1)
            get_viewport().set_input_as_handled()
            return

    if not active_field_move.is_empty() and event.is_action_pressed("cancel"):
        if active_field_move == "FLY" and not _valid_fly_landing(_player_cell()):
            world_message.emit("You cannot land here.")
            get_viewport().set_input_as_handled()
            return
        clear_active_field_move()
        get_viewport().set_input_as_handled()
        return

    if event.is_action_pressed("cancel") and active_field_move.is_empty():
        var direction := _facing_cell()
        if _try_push_fenced_pokemon(_player_cell() + direction, direction, false):
            get_viewport().set_input_as_handled()
            return

    if event.is_action_pressed("confirm"):
        _interact_in_front()
        get_viewport().set_input_as_handled()

func clear_active_field_move(show_message: bool = true) -> void:
    field_moves.clear_active_field_move(show_message)

## per-frame
func _set_fly_shadow_active(active: bool) -> void:
    field_moves.set_fly_shadow_active(active)

## per-frame
func _update_fly_shadow() -> void:
    field_moves.update_fly_shadow()

func _repel_blocks(opponent_level: int) -> bool:
    if active_field_move == "REPEL":
        return _effective_wild_level(opponent_level) < maxi(
            1, int(active_field_pokemon.get("level", 1))
        )
    return world_elapsed_seconds < repel_until_elapsed

func _effective_wild_level(source_level: int) -> int:
    # Main owns the current party and its adaptive encounter rule. Keep raw
    # levels for isolated World fixtures and startup states with no party.
    var main := get_parent()
    if main != null and main.has_method("wild_level_for_player"):
        var party = main.get("caught_pokemon")
        if typeof(party) == TYPE_ARRAY and not (party as Array).is_empty():
            return int(main.call("wild_level_for_player", source_level))
    return source_level

func set_follower(
        pokemon_data: Dictionary, show_message: bool = true
    ) -> bool:
    var species := String(pokemon_data.get("species", "")).to_lower()
    var texture := PokemonData.record_texture(pokemon_data, "overworld")
    if texture == null:
        texture = FARM_POKEMON_TEXTURES.get(species) as Texture2D
    if texture == null:
        if show_message:
            world_message.emit("That Pokemon cannot follow here.")
        return false
    var behavior: Dictionary = PokemonData.info(species).get("overworld_behavior", {})
    # Mega Gyarados rears up out of the water and follows on land as well;
    # wild ones still keep to the water.
    if bool(behavior.get("swim_only", false)) and species != "mega_gyarados" and terrain_kind_at(_player_cell()) != 0:
        if show_message:
            world_message.emit("%s can only follow while swimming." % PokemonData.battle_display_name(species))
        return false

    clear_follower()
    follower_pokemon = PokemonEcology.ensure_record(
        pokemon_data, rng, "follower:%s" % species
    )
    follower_pokemon["behavior"] = behavior
    follower_sprite = Sprite2D.new()
    follower_sprite.texture = texture
    follower_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
    follower_sprite.z_as_relative = false
    follower_sprite.physics_interpolation_mode = \
        Node.PHYSICS_INTERPOLATION_MODE_OFF
    _configure_overworld_sprite(follower_sprite)
    var layer := get_node_or_null("LandmarkLayer") as Node2D
    if layer == null:
        follower_pokemon.clear()
        follower_sprite = null
        return false
    layer.add_child(follower_sprite)
    preload("res://scripts/shiny_sparkles.gd").attach(follower_sprite, pokemon_data)
    _sync_follower_to_player()
    if show_message:
        world_message.emit("%s is following you." % PokemonData.battle_display_name(species))
    return true

func clear_follower() -> void:
    if follower_move_tween != null and follower_move_tween.is_valid():
        follower_move_tween.kill()
    follower_move_tween = null
    if is_instance_valid(follower_sprite):
        follower_sprite.queue_free()
    follower_sprite = null
    follower_pokemon.clear()
    follower_cell = Vector2i(-2147483648, -2147483648)

func present_field_move_pokemon() -> void:
    field_moves.present_field_move_pokemon()

func _position_build_helper() -> void:
    field_moves.position_build_helper()

func _place_follower_live() -> void:
    if follower_pokemon.is_empty() or not is_instance_valid(follower_sprite):
        return
    if follower_move_tween != null and follower_move_tween.is_valid():
        follower_move_tween.kill()
    follower_move_tween = null
    var facing := _facing_cell()
    var offset := -facing
    var target_cell := _player_cell() + offset
    if active_area_id == "OVERWORLD":
        var can_use_target := _pokemon_can_enter(
            String(follower_pokemon.get("species", "")), target_cell)
        if not can_use_target or deployed_pokemon.has(target_cell) or \
                _wild_id_at_cell(target_cell) >= 0 or wild_eggs.has(target_cell):
            target_cell = _player_cell()
            offset = Vector2i.ZERO
    follower_cell = target_cell
    follower_sprite.visible = true
    follower_sprite.position = (
        player.position + Vector2(offset) * float(TILE)
    )
    follower_sprite.z_index = _depth_z(target_cell)
    _set_overworld_motion_frame(follower_sprite, facing, int(player.walk_phase))
    follower_sprite.offset = Vector2(0, -16) if follower_sprite.has_meta("alolan_exeggutor_walk") else Vector2.ZERO

## per-frame
func _place_field_helper_live() -> void:
    field_moves.place_field_helper_live()


func _field_move_action_cell(default_cell: Vector2i, move: String) -> Vector2i:
    return field_moves.field_move_action_cell(default_cell, move)

func _cut_helper_target_cell() -> Vector2i:
    return field_moves.cut_helper_target_cell()

func _smash_helper_rock_cell(cell: Vector2i) -> bool:
    return field_moves.smash_helper_rock_cell(cell)

func _cut_helper_tree_cell(cell: Vector2i) -> bool:
    return field_moves.cut_helper_tree_cell(cell)

func _sync_follower_to_player() -> void:
    if follower_pokemon.is_empty() or not is_instance_valid(follower_sprite):
        return
    _place_follower_live()

func _advance_follower(previous_player_cell: Vector2i, _new_player_cell: Vector2i) -> void:
    if follower_pokemon.is_empty() or not is_instance_valid(follower_sprite):
        return
    if previous_player_cell.x <= -2147483648:
        _place_follower_live()
        return
    var direction := previous_player_cell - follower_cell
    if direction == Vector2i.ZERO:
        direction = _facing_cell()
    follower_cell = previous_player_cell
    follower_walk_phase = 1 - follower_walk_phase
    _set_overworld_motion_frame(
        follower_sprite, Vector2(direction), follower_walk_phase)
    follower_sprite.z_index = _depth_z(follower_cell)
    if follower_move_tween != null and follower_move_tween.is_valid():
        follower_move_tween.kill()
    follower_move_tween = create_tween()
    follower_move_tween.set_trans(Tween.TRANS_LINEAR)
    follower_move_tween.tween_property(
        follower_sprite, "position", _cell_center(follower_cell), 0.18)
    follower_move_tween.tween_callback(func() -> void:
        if is_instance_valid(follower_sprite):
            _set_overworld_motion_frame(follower_sprite, Vector2(direction), 0)
    )

func _interact_follower() -> void:
    if follower_pokemon.is_empty():
        return
    var species := PokemonData.battle_display_name(String(follower_pokemon.get("species", "POKEMON")))
    var happiness := int(follower_pokemon.get("happiness", 70))
    if happiness >= 200:
        world_message.emit("%s is delighted to travel with you!" % species)
        _show_ecology_emote(follower_sprite, "heart")
    elif happiness >= 100:
        world_message.emit("%s is happily following your footsteps." % species)
        _show_ecology_emote(follower_sprite, "happy")
    else:
        world_message.emit("%s is watching the habitat closely." % species)
        _show_ecology_emote(follower_sprite, "question")

func feed_pokemon_in_front(item_name: String) -> bool:
    if not PokemonEcology.is_food(item_name):
        return false
    var target := _player_cell() + _facing_cell()
    var happiness_gain := PokemonEcology.food_happiness(item_name)
    if not follower_pokemon.is_empty() and target in [follower_cell, _player_cell()]:
        _feed_ecology_record(follower_pokemon, happiness_gain)
        if (
                String(active_field_pokemon.get("party_ecology_id", ""))
                == String(follower_pokemon.get("party_ecology_id", ""))
            ):
            active_field_pokemon["happiness"] = int(follower_pokemon["happiness"])
            active_field_pokemon["friendship"] = int(follower_pokemon["friendship"])
        pokemon_ecology_changed.emit(follower_pokemon.duplicate(true))
        _show_ecology_emote(follower_sprite, "heart")
        world_message.emit("%s enjoyed the %s." % [
            PokemonData.battle_display_name(String(follower_pokemon.get("species", "POKEMON"))), item_name
        ])
        return true
    if deployed_pokemon.has(target):
        var deployed: Dictionary = deployed_pokemon[target]
        _feed_ecology_record(deployed, happiness_gain)
        deployed_pokemon[target] = deployed
        _show_ecology_emote(deployed.get("sprite") as Sprite2D, "heart")
        world_message.emit("%s enjoyed the %s." % [
            PokemonData.battle_display_name(String(deployed.get("species", "POKEMON"))), item_name
        ])
        return true
    var wild_id := _wild_id_at_cell(target)
    if wild_id >= 0:
        var wild: Dictionary = wild_pokemon[wild_id]
        if bool(wild.get("burrowed", false)):
            return false
        _feed_ecology_record(wild, happiness_gain)
        wild["fed_until"] = world_elapsed_seconds + 8.0
        wild["aggro_player"] = false
        wild["warned"] = false
        wild_pokemon[wild_id] = wild
        _show_ecology_emote(wild.get("sprite") as Sprite2D, "heart")
        world_message.emit("Wild %s is eating the %s." % [
            PokemonData.battle_display_name(String(wild.get("species", "POKEMON"))), item_name
        ])
        return true
    return false

func _feed_ecology_record(data: Dictionary, happiness_gain: int) -> void:
    data["happiness"] = mini(
        PokemonEcology.MAX_HAPPINESS,
        int(data.get("happiness", 70)) + happiness_gain
    )
    data["friendship"] = int(data["happiness"])

func _set_water_collision_enabled(enabled: bool) -> void:
    var stream := get_node_or_null("ExactCollisionStream") as SourceChunkCollisionStreamer
    if stream != null:
        stream.set_allow_water(not enabled)

func _interact_in_front() -> void:
    var target := _player_cell() + _facing_cell()
    if dropped_items().collect(target): return
    if not planting_item.is_empty():
        var item := planting_item
        var main := get_parent()
        if int(main.inventory.get(item,0)) <= 0:
            planting_item = ""
            return
        if await plants().plant(target,item):
            if not main.coop_game.active:main._consume_inventory_item(item)
            if int(main.inventory.get(item,0)) <= 0: planting_item = ""
        return

    # BUILD owns A while its preview is active. Dungeon interaction records
    # share off-world coordinates with houses and must not swallow this action.
    if active_field_move == "BUILD":
        var build_name := _current_build_name()
        if not build_name.is_empty():
            build_requested.emit(build_name, get_build_execution_cell())
        return

    if active_field_move.is_empty() and not built_structures.has(target):
        var source_seat := _source_interior_tile_at_world_cell(target)
        if source_seat != null and "stool" in source_seat.name_upper:
            _sit_on_stool(target)
            return
    var couch_anchor := _couch_anchor_at(target)
    if couch_anchor != Vector2i(2147483647,2147483647):
        if active_field_move.is_empty():
            _interact_built_structure(couch_anchor)
            return
        if active_field_move == "CUT":
            structure_removal_requested.emit(couch_anchor, "CUT")
            return
    if active_field_move.is_empty() and _interact_house_window(target):
        return
    if active_field_move.is_empty() and String(built_structures.get(target + Vector2i.DOWN, {}).get("name", "")) == "BED":
        _interact_built_structure(target + Vector2i.DOWN)
        return
    if interior_interactables.has(target):
        _use_interior_interactable(
            String(interior_interactables[target]), target
        )
        return

    if wild_eggs.has(target):
        if active_field_move == "ATTACK":
            _attack_wild_egg(target)
        else:
            _show_ecology_emote(wild_eggs[target].get("sprite") as Sprite2D, "...")
            egg_pickup_prompt_requested.emit(target)
        return

    # A is the explicit action button for active CUT and BUILD. Resolve these
    # before follower interaction so pressing A uses the move instead of
    # talking to the helper Pokemon standing beside the player.
    if active_field_move == "CUT":
        var cut_target := _cut_helper_target_cell()
        if cut_target.x > -2147483648:
            _try_cut_target(cut_target)
        return
    if active_field_move == "BUILD":
        var build_name := _current_build_name()
        if not build_name.is_empty():
            build_requested.emit(build_name, get_build_execution_cell())
        return
    if active_field_move == "DIG":
        _use_dig(_field_move_action_cell(target, "DIG"))
        return
    if active_field_move == "SMASH":
        target = _field_move_action_cell(target, "SMASH")
        if built_structures.has(target) and String(
                (built_structures[target] as Dictionary).get("name", "")) in \
                ["GRAVE", "STATUE"]:
            structure_removal_requested.emit(target, "SMASH")
        elif not _exact_resource_kind(target).is_empty():
            _harvest_exact_resource(target, "SMASH")
        elif resource_objects.has(target):
            _harvest_resource_with_move(target, "SMASH")
        else:
            world_message.emit("There is nothing here that SMASH can break.")
        return
    if active_field_move == "HEADBUTT":
        _use_headbutt(_field_move_action_cell(target, "HEADBUTT"))
        return
    if active_field_move == "TELEPORT":
        teleport_map_requested.emit(_travel_destinations(false))
        return
    if active_field_move == "FLY":
        world_message.emit("Fly to safe ground, then press B to land.")
        return
    if active_field_move == "PAINT":
        paint_requested.emit(paint_selection_index + 1, _field_move_action_cell(target, "PAINT"))
        return
    if active_field_move == "SURF":
        var aquatic_id := _wild_id_at_cell(target)
        if aquatic_id >= 0:
            _interact_wild_pokemon(aquatic_id)
            return
        if deployed_pokemon.has(target):
            _interact_deployed_pokemon(target)
            return
    if active_field_move in ["POWER", "FLASH", "REPEL", "SURF"]:
        world_message.emit({
            "POWER":"There is no machine here that can receive POWER.",
            "FLASH":"FLASH lights the surrounding area.",
            "REPEL":"Wild Pokemon below level %d are being repelled." % maxi(
                1, int(active_field_pokemon.get("level", 1))),
            "SURF":"SURF lets you cross water. Press B to stop."
        }[active_field_move])
        return
    if active_field_move == "RIDE":
        if exact_world != null:
            var ride_tile := exact_world.tile_at(target)
            if ride_tile != null and ride_tile.is_ledge:
                _ride_jump_over(target)
                return
        world_message.emit("RIDE increases speed and can jump low ledges or fences.")
        return

    if target == follower_cell and not follower_pokemon.is_empty():
        _interact_follower()
        return

    var wild_id := _wild_id_at_cell(target)
    if wild_id >= 0:
        _interact_wild_pokemon(wild_id)
        return

    if deployed_pokemon.has(target) and (not deployed_pokemon[target].has("house_door") or _house_pokemon_visible(deployed_pokemon[target])):
        if active_field_move == "ATTACK":
            _attack_deployed_pokemon(target)
        else:
            _interact_deployed_pokemon(target)
        return

    if landmarks.has(target):
        var data: Dictionary = landmarks[target]
        var kind: String = String(data.get("type", ""))
        if kind == "sign":
            world_message.emit("A weathered sign: WILD POKEMON LIVE IN TALL GRASS.")
        elif kind == "source_route_sign":
            var route_name := String(route_cells.get(
                WorldParity.nearest_route_cell(target, route_cells), "forest1"
            )).replace("_", " ").to_upper()
            world_message.emit("ROUTE: %s" % route_name)
        elif kind == "source_house":
            _enter_source_area("HOUSE", target + Vector2i.DOWN)
        elif kind == "source_cave":
            _enter_source_area("CAVE", target + Vector2i.DOWN)
        elif kind == "source_area":
            _enter_source_area(
                String(data.get("area", "")),
                target + Vector2i.DOWN
            )
        elif kind == "source_key":
            if bool(data.get("used", false)):
                world_message.emit("There is nothing else here.")
                return
            data["used"] = true
            landmarks[target] = data
            var key_sprite: Sprite2D = data.get("sprite") as Sprite2D
            if is_instance_valid(key_sprite):
                key_sprite.visible = false
            var key_collision: CollisionBox = data.get("collision") as CollisionBox
            if is_instance_valid(key_collision):
                key_collision.queue_free()
            blocked.erase(target)
            item_collected.emit(String(data.get("item", "MANSION KEY")))
            world_message.emit("You found the MANSION KEY!")
        elif kind == "campfire":
            crafting_station_requested.emit("CAMPFIRE")
        elif kind == "item":
            if bool(data.get("used", false)):
                world_message.emit("There is nothing else here.")
                return
            data["used"] = true
            landmarks[target] = data
            var sprite: Sprite2D = data.get("sprite") as Sprite2D
            if is_instance_valid(sprite):
                sprite.visible = false
            var collision: CollisionBox = data.get("collision") as CollisionBox
            if is_instance_valid(collision):
                collision.queue_free()
            blocked.erase(target)
            item_collected.emit("POTION")
            world_message.emit("You found a POTION!")
        return

    # Built-object destruction follows PokeWilds field-move rules while normal
    # interaction continues to open stations/furniture.
    if built_structures.has(target):
        var built_data: Dictionary = built_structures[target]
        var built_name := String(built_data.get("name", ""))
        if active_field_move == "RIDE" and built_name == "FENCE":
            _ride_jump_over(target)
            return
        if active_field_move == "CUT" and built_name not in ["GRAVE", "STATUE"]:
            structure_removal_requested.emit(target, "CUT")
            return
        if active_field_move == "SMASH" and built_name in ["GRAVE", "STATUE"]:
            structure_removal_requested.emit(target, "SMASH")
            return
        _interact_built_structure(target)
        return

    if active_field_move.is_empty() and is_empty_planting_hole(target):
        structure_action.emit("PLANT_HOLE:%d:%d" % [target.x, target.y])
        return

    if active_field_move.is_empty() and _can_prompt_shore_surf(target):
        structure_action.emit("SHORE_SURF")
        return

    if active_field_move.is_empty():
        var berry_anchor := _exact_resource_anchor(target)
        if berry_anchor.x > -2147483648 and not _exact_berry_name(berry_anchor).is_empty():
            _pick_exact_berry_tree(berry_anchor)
            return

    # Active field moves get first claim on environmental actions.
    match active_field_move:
        "CUT":
            var helper_cut_target := _cut_helper_target_cell()
            if helper_cut_target.x > -2147483648:
                _try_cut_target(helper_cut_target)
            return
        "SMASH":
            target = _field_move_action_cell(target, "SMASH")
            if not _exact_resource_kind(target).is_empty():
                _harvest_exact_resource(target, "SMASH")
                return
            if resource_objects.has(target):
                _harvest_resource_with_move(target, "SMASH")
                return
        "DIG":
            _use_dig(_field_move_action_cell(target, "DIG"))
            return
        "BUILD":
            var build_name := _current_build_name()
            if not build_name.is_empty():
                build_requested.emit(build_name, get_build_execution_cell())
            return
        "HEADBUTT":
            _use_headbutt(_field_move_action_cell(target, "HEADBUTT"))
            return
        "TELEPORT":
            teleport_map_requested.emit(_travel_destinations(false))
            return
        "FLY":
            world_message.emit("Fly to safe ground, then press B to land.")
            return
        "PAINT":
            paint_requested.emit(paint_selection_index + 1, _field_move_action_cell(target, "PAINT"))
            return
        "POWER":
            world_message.emit("There is no machine here that can receive POWER.")
            return
        "FLASH":
            world_message.emit("FLASH lights the surrounding area.")
            return
        "CHARM":
            world_message.emit("CHARM suppresses hostile Pokemon below %s's level while active." % PokemonData.battle_display_name(active_field_species))
            return
        "ATTACK":
            world_message.emit("Face a wild Pokemon to command ATTACK.")
            return
        "REPEL":
            world_message.emit("Wild Pokemon below level %d are being repelled." % maxi(1, int(active_field_pokemon.get("level", 1))))
            return
        "SURF":
            world_message.emit("SURF lets you cross water. Press B to stop.")
            return
        "RIDE":
            if exact_world != null:
                var ride_tile := exact_world.tile_at(target)
                if ride_tile != null and ride_tile.is_ledge:
                    _ride_jump_over(target)
                    return
            world_message.emit("RIDE increases speed and can jump low ledges or fences.")
            return

    if _is_cuttable_grass_cell(target) or \
            _resource_object_anchor(target).x > -2147483648 or \
            _exact_resource_anchor(target).x > -2147483648:
        var cut_resource := _resource_object_anchor(target)
        var cut_exact := _exact_resource_anchor(target)
        var cuttable := _is_cuttable_grass_cell(target) or _exact_resource_kind(cut_exact) in ["tree", "bush"]
        cuttable = cuttable or String((resource_objects.get(cut_resource, {}) as Dictionary).get("type", "")) in ["tree", "bush"]
        if not cuttable:
            return

func _try_cut_target(cell:Vector2i)->bool:
    return field_moves.try_cut_target(cell)

func _interact_wild_pokemon(wild_id: int) -> void:
    if not wild_pokemon.has(wild_id):
        return
    var data: Dictionary = wild_pokemon[wild_id]
    var species = PokemonData.battle_display_name(String(data.get("species", "POKEMON")))
    if bool(data.get("burrowed", false)):
        world_message.emit("The sand shifts slightly, then goes still.")
        return
    if bool(data.get("source_record",{}).get("rare_forest_mew",false)) or not String(data.get("source_record",{}).get("rare_legendary", "")).is_empty():
        _begin_wild_encounter(wild_id)
        return
    if active_field_move == "ATTACK":
        _begin_wild_encounter(wild_id, true)
        return
    var sprite = data.get("sprite") as Sprite2D
    if is_instance_valid(sprite):
        _set_overworld_motion_frame(sprite, -_facing_cell(), 0)
    var kind = PokemonEcology.wild_interaction_kind(String(data.get("species", "")))
    var warned = bool(data.get("warned",false))
    # It stays where it was reached while the player is talking to it.
    data["move_timer"] = maxf(float(data.get("move_timer", 0.0)), 1.5)
    set_gameplay_enabled(false)
    await get_tree().create_timer(20.0/60.0).timeout
    if not wild_pokemon.has(wild_id):
        set_gameplay_enabled(true)
        return
    # One still shaken by a failed catch can be befriended, but is not glad of it.
    var frightened = kind == "FRIENDLY" and world_elapsed_seconds < float(data.get("ball_flee_until", 0.0))
    _show_ecology_emote(sprite, "sad" if frightened else "happy" if kind=="FRIENDLY" else "skull" if kind=="AGGRESSIVE" and not warned else "alert")
    await get_tree().create_timer(20.0/60.0).timeout
    get_parent()._play_pokemon_cry({"species":String(data.get("species",""))})
    if kind == "SKITTISH":
        _begin_wild_encounter(wild_id)
    elif kind == "FRIENDLY":
        wild_pokemon_prompt_requested.emit(wild_id, species, "FRIGHTENED" if frightened else "FRIENDLY")
    elif not warned:
        wild_pokemon_prompt_requested.emit(wild_id, species, "PROVOKE_WARNING")
    else:
        await get_tree().create_timer(10.0/60.0).timeout
        confirm_wild_provocation(wild_id)
        # Battle entry owns the gameplay lock after explicit provocation.

func mark_wild_provocation_warning(wild_id: int) -> void:
    if not wild_pokemon.has(wild_id):
        return
    var data: Dictionary = wild_pokemon[wild_id]
    if PokemonEcology.wild_interaction_kind(String(data.get("species", ""))) != "AGGRESSIVE":
        return
    data["warned"] = true
    wild_pokemon[wild_id] = data

func _wild_chases_when_provoked(data: Dictionary) -> bool:
    var behavior: Dictionary = data.get("behavior", {})
    if bool(behavior.get("lunge", false)) or int(behavior.get("aggression", 1)) >= 2:
        return true
    # GenIsland1 also marks specific authored overworld spawns as aggressive
    # (for example Drapion/Froslass/Primeape/Sharpedo and Lower-Ruins Dusclops).
    # Preserve that source record instead of reducing pursuit to the database's
    # generic species behavior table.
    var source_record: Dictionary = data.get("source_record", {})
    return bool(source_record.get("aggressive", false))

func confirm_wild_provocation(wild_id: int) -> void:
    if not wild_pokemon.has(wild_id):
        return
    var data: Dictionary = wild_pokemon[wild_id]
    if PokemonEcology.wild_interaction_kind(String(data.get("species", ""))) != "AGGRESSIVE":
        return
    data["warned"] = true
    data["aggro_player"] = true
    data["source_aggro_emote_seconds"] = 32.0 / 60.0
    data["move_timer"] = 32.0 / 60.0
    data["provocation_count"] = int(data.get("provocation_count", 0)) + 1
    wild_pokemon[wild_id] = data
    # The provocation interaction has finished. Start the battle immediately,
    # independent of idle clocks, grace, SURF or Repel.
    _begin_wild_encounter(wild_id)


func take_friendly_wild(wild_id: int) -> Dictionary:
    if not wild_pokemon.has(wild_id):
        return {}
    var data: Dictionary = wild_pokemon[wild_id]
    var behavior: Dictionary = data.get("behavior", {})
    if PokemonEcology.wild_interaction_kind(String(data.get("species", ""))) != "FRIENDLY" or bool(data.get("burrowed", false)):
        return {}
    var result := _serializable_ecology_record(
        data, Vector2i(data.get("cell", Vector2i.ZERO))
    )
    var source_record := data.get("source_record", {}) as Dictionary
    for property in source_record.keys():
        if not result.has(property):
            result[property] = source_record[property]
    result["species"] = String(data.get("species", "pidgey")).to_lower()
    result["level"] = maxi(1, int(data.get("level", 2)))
    _show_ecology_emote(data.get("sprite") as Sprite2D, "happy")
    _remove_wild_pokemon(wild_id)
    return result

func _exact_resource_kind(cell: Vector2i) -> String:
    return field_moves.exact_resource_kind(cell)

func _exact_resource_anchor(cell: Vector2i) -> Vector2i:
    return field_moves.exact_resource_anchor(cell)

func _resource_object_anchor(cell: Vector2i) -> Vector2i:
    return field_moves.resource_object_anchor(cell)

func _exact_berry_name(cell: Vector2i) -> String:
    return field_moves.exact_berry_name(cell)

func _pick_exact_berry_tree(cell: Vector2i) -> void:
    field_moves.pick_exact_berry_tree(cell)


## A giant tree is one visible tile and three invisible ones that only block.
## The original generator turns any incomplete giant tree into a bush, and
## runs that check again after placing the Regi cave. Here the cave (and the
## mansion) can also be placed by a later fallback with no check after it,
## which left invisible blocking tiles round the cave showing the sky. This
## gives those the original's result, a bush, in worlds old and new.
func _repair_orphaned_large_trees() -> void:
    field_moves.repair_orphaned_large_trees()

func _exact_large_tree1_anchor(cell: Vector2i) -> Vector2i:
    return field_moves.exact_large_tree1_anchor(cell)

## The Game Boy CUT effect, as CutTreeAnim.java draws it: the tree is sliced
## down the middle, the halves sit two pixels apart, then step outward three
## times with a blink before each step. It is only a picture laid over the
## cell. The tile itself is cut at once, so nothing waits for it.
func _show_cut_halves(cell: Vector2i) -> void:
    field_moves.show_cut_halves(cell)

func _harvest_exact_resource(cell:Vector2i,move:String)->void:
    field_moves.harvest_exact_resource(cell, move)

func _contextual_ground_name(cell: Vector2i, biome_hint: String = "") -> String:
    return field_moves.contextual_ground_name(cell, biome_hint)

func _harvest_resource_with_move(cell:Vector2i,move:String)->void:
    field_moves.harvest_resource_with_move(cell, move)

func _cycle_dig_selection(direction: int) -> void:
    field_moves.cycle_dig_selection(direction)

func _show_current_build_selection() -> void:
    buildings.show_current_build_selection()

func _use_dig(cell: Vector2i) -> void:
    field_moves.use_dig(cell)

func apply_dig_choice(cell: Vector2i, choice: String) -> bool:
    return field_moves.apply_dig_choice(cell, choice)

func _dig_surface(cell: Vector2i) -> void:
    field_moves.dig_surface(cell)

func teleport_destinations() -> Array[Dictionary]:
    return field_moves.teleport_destinations()

func teleport_to_destination(index: int) -> bool:
    return field_moves.teleport_to_destination(index)

func set_structure_beacon_label(cell: Vector2i, value: String) -> void:
    buildings.set_structure_beacon_label(cell, value)

func _travel_destinations(include_spawn: bool) -> Array[Dictionary]:
    return field_moves.travel_destinations(include_spawn)

## per-frame
func _clamp_flying_player_to_world() -> void:
    field_moves.clamp_flying_player_to_world()


func _valid_fly_landing(cell: Vector2i) -> bool:
    return field_moves.valid_fly_landing(cell)

## Has the tile streams draw the view round a cell, over the next frames, before
## the player is moved there (a teleport): it then needs no frame of its own.
func prepare_view_at(cell: Vector2i) -> void:
    for path in ["GroundLayer/ExactBaseTileStream", "DecorLayer/ExactUpperTileStream"]:
        var stream := get_node_or_null(path)
        if stream != null and stream.has_method("prepare_view"): stream.call("prepare_view", _cell_center(cell))

func _cycle_travel_selection(direction: int) -> void:
    field_moves.cycle_travel_selection(direction)

func _cycle_paint_selection(direction: int) -> void:
    field_moves.cycle_paint_selection(direction)

func _use_headbutt(cell: Vector2i) -> void:
    field_moves.use_headbutt(cell)

func _ride_jump_over(obstacle: Vector2i) -> void:
    field_moves.ride_jump_over(obstacle)

func _cycle_build_selection(direction: int) -> void:
    buildings.cycle_build_selection(direction)

func _current_build_name() -> String:
    return buildings.current_build_name()

func get_build_selection_index() -> int:
    return buildings.get_build_selection_index()

func set_build_selection_index(index: int) -> void:
    buildings.set_build_selection_index(index)

func set_build_preview_active(active: bool) -> void:
    buildings.set_build_preview_active(active)

func _is_built_house_floor_cell(cell: Vector2i) -> bool:
    return interiors.is_built_house_floor_cell(cell)

## An interior wall takes windows, clocks and paint wherever it stands in the
## room: on a floor tile, or on the old row just above the room.
## The window or clock hanging on this house wall, or "" when it is bare.
func house_wall_decoration_at(cell: Vector2i) -> String:
    return buildings.house_wall_decoration_at(cell)

## CUT takes a window or clock off its wall and leaves the wall standing. The
## room's own rear wall is not a built piece and could never be cut, so
## without this nothing hung on it could ever be removed.
func remove_house_wall_decoration(cell: Vector2i, refund: bool) -> bool:
    return buildings.remove_house_wall_decoration(cell, refund)

func _built_house_rear_wall_floor(cell: Vector2i) -> int:
    return buildings.built_house_rear_wall_floor(cell)

func _snap_build_cell(build_name: String, desired: Vector2i) -> Vector2i:
    return buildings.snap_build_cell(build_name, desired)

func _restore_house_rear_walls() -> void:
    buildings.restore_house_rear_walls()

func get_build_execution_cell() -> Vector2i:
    return buildings.get_build_execution_cell()

## per-frame
func _update_build_preview() -> void:
    buildings.update_build_preview()

func _resource_source_name(data: Dictionary) -> String:
    var source_name := String(data.get("source_name", "")).to_lower().trim_suffix(".png")
    if not source_name.is_empty():
        return source_name
    var sprite := data.get("sprite") as Sprite2D
    if is_instance_valid(sprite) and sprite.texture != null:
        var path := String(sprite.texture.resource_path).to_lower()
        if not path.is_empty():
            return path.get_file().trim_suffix(".png")
    return ""

func _harvest_resource(cell: Vector2i, source_move: String = "") -> void:
    if not resource_objects.has(cell):
        return
    var data: Dictionary = resource_objects[cell]
    var kind := String(data.get("type", ""))
    var move := source_move.to_upper()

    if kind == "tree":
        play_source_sound("cut1")
        var log_amount := rng.randi_range(2, 7) if bool(
            data.get("large", false)) else 1
        var source_name := _resource_source_name(data)
        if source_name in ["tree5", "tree6"] or "tree5" in source_name or "tree6" in source_name:
            # Palm CUT is seed-only and leaves source-style beach sand behind.
            # Do this in the compatibility path too so both renderers agree.
            material_collected.emit("MIRACLE SEED", 1)
            if _in_bounds(cell):
                terrain[cell.y][cell.x] = 1
                terrain_changes[_cell_key(cell)] = 1
                var ground_sprite := ground_sprites.get(cell) as Sprite2D
                if is_instance_valid(ground_sprite):
                    ground_sprite.texture = SAND
        else:
            material_collected.emit("LOG", log_amount)
            if rng.randf() < 0.35:
                var apricorn := String(CraftingData.APRICORNS[
                    rng.randi_range(0, CraftingData.APRICORNS.size() - 1)])
                material_collected.emit(apricorn, 1)
    elif kind == "bush":
        play_source_sound("cut1")
        if biome_at(cell) == "SNOW":
            material_bundle_collected.emit({"GRASS":1, "LOG":1})
        elif biome_at(cell) == "SAVANNA":
            material_bundle_collected.emit({"GRASS":1, "LOG":1})
        else:
            var apricorn := String(CraftingData.APRICORNS[
                rng.randi_range(0, CraftingData.APRICORNS.size() - 1)
            ])
            material_bundle_collected.emit({"LOG":1, apricorn:1})
    elif kind == "rock":
        play_source_sound("headbutt1" if move == "HEADBUTT" else "strength1")
        material_collected.emit("HARD STONE", 1)
        var found_moon_stone := (
            move == "SMASH" and biome_at(cell) == "MOUNTAIN"
            and rng.randi_range(0, 15) == 0
        )
        if found_moon_stone:
            material_collected.emit("MOON STONE", 1)
            world_message.emit("SMASH! You gathered HARD STONE and found a MOON STONE.")
        else:
            world_message.emit("%s! You gathered HARD STONE." % (
                "HEADBUTT" if move == "HEADBUTT" else "SMASH"))
    elif kind == "flower":
        material_collected.emit("FLOWERS", 1)
        if move != "CUT":
            world_message.emit("You gathered FLOWERS.")
    else:
        return

    _remove_resource(cell, true)

func _remove_resource(cell: Vector2i, remember: bool) -> void:
    if resource_objects.has(cell):
        var data: Dictionary = resource_objects[cell]
        var sprite: Sprite2D = data.get("sprite") as Sprite2D
        var collision: CollisionBox = data.get("collision") as CollisionBox
        if is_instance_valid(sprite):
            sprite.queue_free()
        if is_instance_valid(collision):
            collision.queue_free()
        resource_objects.erase(cell)
        blocked.erase(cell)
        grass_exclusion.erase(cell)
        flower_cells.erase(cell)
    elif tall_grass.has(cell):
        var grass_data = tall_grass[cell]
        if typeof(grass_data) == TYPE_DICTIONARY:
            var back: Sprite2D = grass_data.get("back") as Sprite2D
            var front: Sprite2D = grass_data.get("front") as Sprite2D
            if is_instance_valid(back):
                back.queue_free()
            if is_instance_valid(front):
                front.queue_free()
        tall_grass.erase(cell)

    if remember:
        removed_resources[_cell_key(cell)] = true

func _cut_tall_grass(cell: Vector2i) -> void:
    if not _is_cuttable_grass_cell(cell):
        return
    if plants().harvest(cell):
        return
    const GRASS_AMOUNT := 1
    material_collected.emit("GRASS", GRASS_AMOUNT)
    play_source_sound("cut1")
    var tile := exact_world.tile_at(cell)
    if tile != null:
        var old_base := tile.name.to_lower().trim_suffix(".png")
        # Preserve the source grass2 Miracle Seed bonus; the harvested
        # GRASS material itself is always exactly x1 for every grass tile.
        if old_base == "grass2" and rng.randi_range(0, 255) < 64:
            material_collected.emit("MIRACLE SEED", 1)
        var replacement := _cuttable_grass_replacement(tile, cell)
        tile.set_names(String(replacement.get("base", tile.name)),
            String(replacement.get("upper", "")))
        source_interior_mutations[_cell_key(cell)] = {
            "kind":"TILE_NAMES", "base":tile.name, "upper":tile.name_upper
        }
        _unblock_ground(cell)
        # CUT changes this tile; update resident neighbors without scanning
        # collision revisions for the entire world after every grass tuft.
        _refresh_exact_tile_streams()

func _set_exact_tile_names(cell: Vector2i, base_name: String, upper_name: String) -> void:
    if exact_world == null:
        return
    var tile := exact_world.tile_at(cell)
    if tile == null:
        return
    tile.set_names(base_name, upper_name)
    _refresh_exact_streams()

var restoring_saved_tiles := false
var restored_tiles_need_refresh := false

func _refresh_exact_pickup_cell(cell: Vector2i) -> void:
    _refresh_exact_pickup_cells([cell])

func _refresh_exact_pickup_cells(cells: Array) -> void:
    # Pickups mutate one tile. Never scan the whole resident world for them.
    _bump_map_art(cells)
    # A dedicated server draws nothing: of these it keeps only the collisions
    # current. Redrawing a day's new dig sites took it a tenth of a second.
    var drawn := not preload("res://scripts/dedicated_server.gd").active
    for path in ["GroundLayer/ExactBaseTileStream", "DecorLayer/ExactUpperTileStream"]:
        var stream := get_node_or_null(path)
        if stream == null or not drawn: continue
        if stream.has_method("refresh_changed_tiles"):
            stream.refresh_changed_tiles(cells)
        else:
            stream.invalidate_tiles()
    var collision_stream := get_node_or_null("ExactCollisionStream") as SourceChunkCollisionStreamer
    if collision_stream != null: collision_stream.refresh_cells(cells)
    if drawn and is_instance_valid(reflection_layer) and reflection_layer.has_method("refresh_cells"):
        reflection_layer.refresh_cells(cells)
    var canopy := get_node_or_null("TreeCanopyOverlay")
    if canopy != null: canopy.queue_redraw()

## Cells a whole day changes at once (its ~200 dig sites, the night's cacti),
## handed to the layers a few at a time by _flush_exact_refresh_queue. All at
## once they took one frame of 20-30 ms on a desktop, over 100 ms on a phone,
## and ~90 ms on a desktop for a player sent the day's dig sites by the host.
var exact_refresh_queue: Array = []
const EXACT_REFRESH_CHUNK := 16

## Queues `cells`, or with none the edited cells (resident_changed_cells).
## Either way they are taken out of resident_changed_cells: the next edit's
## refresh would redo them all at once otherwise.
func _queue_exact_refresh(cells: Array = []) -> void:
    if cells.is_empty():
        for key in SourceTile.resident_changed_cells:
            if exact_world.tiles.has(key): exact_refresh_queue.append(Vector2i(key / TILE))
        SourceTile.resident_changed_cells.clear()
        return
    for cell in cells:
        exact_refresh_queue.append(cell)
        SourceTile.resident_changed_cells.erase(cell * TILE)

## per-frame
## Every frame: queued cells to the layers until this frame's slice is used
## (at least one chunk).
func _flush_exact_refresh_queue() -> void:
    if exact_refresh_queue.is_empty(): return
    if exact_world == null:
        exact_refresh_queue.clear()
        return
    var deadline := Time.get_ticks_usec() + _daily_slice_usec()
    var done := 0
    while done < exact_refresh_queue.size():
        _refresh_exact_pickup_cells(exact_refresh_queue.slice(done, done + EXACT_REFRESH_CHUNK))
        done += EXACT_REFRESH_CHUNK
        if Time.get_ticks_usec() >= deadline: break
    exact_refresh_queue = exact_refresh_queue.slice(done)

func _refresh_exact_streams() -> void:
    if restoring_saved_tiles:
        restored_tiles_need_refresh = true
        return
    # Hand the edited cells to every layer, then forget them. Leaving them in
    # resident_changed_cells made each later edit redo every earlier one, and
    # the collision layer used to rescan the whole map (~0.5 s) instead.
    _refresh_exact_tile_streams()

func _set_exact_overworld_streaming(enabled: bool) -> void:
    var collision_stream := get_node_or_null("ExactCollisionStream") as SourceChunkCollisionStreamer
    if collision_stream != null:
        collision_stream.set_streaming_enabled(enabled)

const SourceHouseStyles = preload("res://scripts/source_house_styles.gd")

func can_place_structure(build_name: String, cell: Vector2i, ignore_indoor_requirement: bool = false) -> bool:
    return buildings.can_place_structure(build_name, cell, ignore_indoor_requirement)

func place_structure(build_name: String, cell: Vector2i, restoring: bool = false, restored_state: Dictionary = {}, committed_online: bool = false) -> bool:
    return buildings.place_structure(build_name, cell, restoring, restored_state, committed_online)

func _structure_display_texture(build_name: String, variant: int = 0) -> Texture2D:
    return buildings.structure_display_texture(build_name, variant)

func _colored_bed_texture(carpet_index: int) -> Texture2D:
    return buildings.colored_bed_texture(carpet_index)

func _interact_built_structure(cell: Vector2i) -> void:
    buildings.interact_built_structure(cell)

func _couch_anchor_at(cell: Vector2i) -> Vector2i:
    return buildings.couch_anchor_at(cell)

func _sit_on_stool(cell: Vector2i) -> void:
    buildings.sit_on_stool(cell)

func turn_seated_player(action: String) -> void:
    buildings.turn_seated_player(action)

func end_stool_sitting() -> void:
    buildings.end_stool_sitting()

func set_structure_sign_text(cell: Vector2i, value: String) -> void:
    buildings.set_structure_sign_text(cell, value)

func _built_house_state(door_cell: Vector2i) -> Dictionary:
    return buildings.built_house_state(door_cell)

func _toggle_structure_door(cell: Vector2i) -> void:
    buildings.toggle_structure_door(cell)

func _use_linked_stairs(source: Vector2i) -> void:
    await buildings.use_linked_stairs(source)

func _house_exit_clear(cell: Vector2i) -> bool:
    return buildings.house_exit_clear(cell)

func _house_door_outward(cell: Vector2i) -> Vector2i:
    return buildings.house_door_outward(cell)

func _refresh_connected_structures_around(center: Vector2i) -> void:
    buildings.refresh_connected_structures_around(center)

## What is built inside a house on the tile behind one piece of its outside,
## on every floor. Cutting the piece cuts these with it, and nothing else:
## whatever stands elsewhere in the house stays, reachable or not, for when
## the way to it is rebuilt. A door is a piece like any other. Empty for a
## piece that is not part of a house, and for a house nobody has been inside.
func house_interior_cells_behind(cell: Vector2i) -> Array[Vector2i]:
    return buildings.house_interior_cells_behind(cell)

func _remove_structure(cell: Vector2i, refund: bool) -> void:
    buildings.remove_structure(cell, refund)

func remove_structure_with_field_move(cell: Vector2i, move: String) -> bool:
    return buildings.remove_structure_with_field_move(cell, move)

func _is_cell_indoors(cell: Vector2i) -> bool:
    return interiors.is_cell_indoors(cell)

func deploy_pokemon(pokemon_data: Dictionary) -> bool:
    var cell := _player_cell() + _facing_cell()
    var indoors := active_area_id == "HOUSE"
    if (not _house_pokemon_cell_allowed(cell) if indoors else not _pokemon_drop_ground_allowed(pokemon_data, cell)):
        world_message.emit("There is no room to leave that Pokemon here.")
        return false
    if (
            deployed_pokemon.has(cell)
            or built_structures.has(cell)
            or (not indoors and landmarks.has(cell))
            or (not indoors and resource_objects.has(cell))
            or wild_eggs.has(cell)
            or (not indoors and _wild_id_at_cell(cell) >= 0)
            or cell == follower_cell
            or cell == field_helper_cell
        ):
        return false

    var species := String(pokemon_data.get("species", "")).to_lower()
    if bool(pokemon_data.get("is_egg", false)):
        var egg := pokemon_data.duplicate(true)
        egg["dropped_party_egg"] = true
        if indoors:
            egg["house_door"] = _cell_key(active_built_house_door)
            egg["house_floor"] = _built_house_floor_index_for_cell(cell)
        _add_wild_egg(species, cell, egg)
        return wild_eggs.has(cell)
    var pokemon_texture: Texture2D = PokemonData.record_texture(pokemon_data, "overworld")
    if pokemon_texture == null:
        pokemon_texture = FARM_POKEMON_TEXTURES.get(species) as Texture2D
    if pokemon_texture == null:
        world_message.emit("That Pokemon's overworld sprite is not available yet.")
        return false

    var sprite := Sprite2D.new()
    sprite.texture = pokemon_texture
    sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
    sprite.position = _cell_center(cell)
    sprite.z_as_relative = false
    sprite.z_index = _depth_z(cell)
    _configure_overworld_sprite(sprite)
    var layer := _house_pokemon_layer() if indoors else get_node_or_null("LandmarkLayer") as Node2D
    if layer == null:
        return false
    layer.add_child(sprite)
    preload("res://scripts/shiny_sparkles.gd").attach(sprite, pokemon_data)

    var stored := PokemonEcology.ensure_record(
        pokemon_data, rng, "owned:%d" % next_deployed_id
    )
    next_deployed_id += 1
    if indoors:
        stored["house_door"] = _cell_key(active_built_house_door)
        stored["house_floor"] = _built_house_floor_index_for_cell(cell)
    stored["x"] = cell.x
    stored["y"] = cell.y
    stored["cell"] = cell
    stored["move_timer"] = _wild_move_delay(species)
    stored["anim_phase"] = 0
    stored["behavior"] = PokemonData.info(species).get("overworld_behavior", {})
    stored["sprite"] = sprite
    stored = _refresh_record_habitat(stored, cell)
    deployed_pokemon[cell] = stored
    return true

func _recall_deployed_pokemon(cell:Vector2i,data:Dictionary)->void:
    var coordinator=get_parent().get("coop_game")
    if is_instance_valid(coordinator) and coordinator.active and not coordinator.population.applying:
        coordinator.population.recall(cell,"deployed_pokemon",String(data.get("ecology_id","")))
        return
    # Capacity is checked before items, ownership, sprites or world records change.
    var main := get_parent()
    if main == null or not main.has_method("_can_receive_overworld_pokemon") or not main._can_receive_overworld_pokemon():
        world_message.emit("Your party and storage are full.")
        return
    var species := String(data.get("species", "")).to_lower()
    var carried_item := String(data.get("held_item", ""))
    if not carried_item.is_empty():
        material_collected.emit(carried_item, 1)
    var recalled := data.duplicate(true)
    if not carried_item.is_empty():
        recalled["harvest_progress"] = 0.0
    for runtime_key in [
            "x", "y", "cell", "ready_at", "ready_at_elapsed",
            "last_harvest_day", "sprite", "move_timer", "anim_phase",
            "behavior", "ecology_id", "mate_id", "friend_id",
            "in_habitat", "in_shelter", "nearby_pokemon",
            "held_item", "can_lay_egg",
            "missing_habitats", "manured", "house_door", "house_floor"
        ]:
        recalled.erase(runtime_key)
    var sprite: Sprite2D = data.get("sprite") as Sprite2D
    if is_instance_valid(sprite):
        sprite.queue_free()
    deployed_pokemon.erase(cell)
    deployed_recall_candidate = Vector2i(-2147483648, -2147483648)
    deployed_recall_candidate_msec = 0
    pokemon_recalled.emit(recalled)

func _deployed_recall_hint(message: String) -> void:
    if deployed_pokemon.has(deployed_recall_candidate):
        var record: Dictionary = deployed_pokemon[deployed_recall_candidate]
        deployed_recall_requested.emit(deployed_recall_candidate, String(record.get("species", "")), message)

func _interact_deployed_pokemon(cell:Vector2i)->void:
    var coordinator=get_parent().get("coop_game")
    if is_instance_valid(coordinator) and coordinator.active and not String(deployed_pokemon.get(cell,{}).get("held_item","")).is_empty():
        deployed_recall_candidate=cell
        deployed_recall_candidate_msec=preload("res://scripts/game_clock.gd").ticks_msec()
        coordinator.population.harvest(cell)
        return
    if not deployed_pokemon.has(cell):
        return
    var data: Dictionary = deployed_pokemon[cell]
    var species := String(data.get("species", "")).to_lower()
    var now := preload("res://scripts/game_clock.gd").ticks_msec()

    deployed_recall_candidate = cell
    deployed_recall_candidate_msec = now

    var held_item := String(data.get("held_item", ""))
    if not held_item.is_empty():
        var amount := rng.randi_range(3,5) if held_item=="ANCIENTPOWDER" and preload("res://scripts/rare_biome_legendaries.gd").HABITATS.has(species) else 1
        material_collected.emit(held_item, amount)
        data["held_item"] = ""
        data["harvest_progress"] = 0.0
        deployed_pokemon[cell] = data
        _show_ecology_emote(data.get("sprite") as Sprite2D,
            "uncomfortable" if not bool(data.get("in_habitat", false)) else (
            "heart" if not String(data.get("mate_id", "")).is_empty() else "happy"))
        world_message.emit("%s produced %s!" % [PokemonState.display_name(data).to_upper(), held_item])
        return

    if not bool(data.get("in_habitat", false)):
        var missing: Array = data.get("missing_habitats", [])
        var need := "the right habitat" if missing.is_empty() else String(missing[0]).replace("|", " or ")
        _deployed_recall_hint("%s is uncomfortable. It needs %s nearby." % [
            PokemonState.display_name(data).to_upper(), need.to_upper()])
        _show_ecology_emote(data.get("sprite") as Sprite2D, "uncomfortable")
        return
    if not String(data.get("mate_id", "")).is_empty():
        _deployed_recall_hint("%s is happy with its mate." % PokemonState.display_name(data).to_upper())
        _show_ecology_emote(data.get("sprite") as Sprite2D, "heart")
        return
    if not String(data.get("friend_id", "")).is_empty():
        _deployed_recall_hint("%s is enjoying time with a friend." % PokemonState.display_name(data).to_upper())
        _show_ecology_emote(data.get("sprite") as Sprite2D, "happy")
        return
    if bool(data.get("in_shelter", false)):
        _deployed_recall_hint("%s is happy and sheltered here." % PokemonState.display_name(data).to_upper())
    else:
        _deployed_recall_hint("%s looks happy in this habitat." % PokemonState.display_name(data).to_upper())
    _show_ecology_emote(data.get("sprite") as Sprite2D, "happy")

func _refresh_record_habitat(
        data: Dictionary, cell: Vector2i, ecology_name_cache: Dictionary = {}
    ) -> Dictionary:
    var species := String(data.get("species", ""))
    # Build the seven-by-seven habitat window once. The old implementation
    # rebuilt the same strings once per required type and then again for
    # shelter, multiplying work across hundreds of exact-world Pokemon.
    var nearby_names := PackedStringArray()
    var fence_count := 0
    var roof_count := 0
    for y in range(cell.y - PokemonEcology.HABITAT_RADIUS, cell.y + PokemonEcology.HABITAT_RADIUS + 1):
        for x in range(cell.x - PokemonEcology.HABITAT_RADIUS, cell.x + PokemonEcology.HABITAT_RADIUS + 1):
            var habitat_cell := Vector2i(x, y)
            var names = ecology_name_cache.get(habitat_cell)
            if names == null:
                names = _ecology_names_at(habitat_cell)
                ecology_name_cache[habitat_cell] = names
            nearby_names.append(names)
            if "fence" in names:
                fence_count += 1
            elif "roof" in names:
                roof_count += 1
    # No habitat option holds a space, so one is in the joined window exactly
    # when it is in one of the cells' names. The species' groups (decoded
    # from the packed species data) are kept in the same cache by name.
    var window := " ".join(nearby_names)
    var habitat = ecology_name_cache.get(species)
    if habitat == null:
        var groups := []
        for raw_group in PokemonEcology.habitat_groups(species):
            groups.append([String(raw_group), String(raw_group).to_lower().split("|")])
        habitat = [groups, PokemonEcology.requires_night(species)]
        ecology_name_cache[species] = habitat
    var missing: Array[String] = []
    for group in habitat[0]:
        var satisfied := false
        for option in group[1]:
            if option in window:
                satisfied = true
                break
        if not satisfied:
            missing.append(group[0])
    if habitat[1] and not _is_night_time():
        missing.append("night")
    data["missing_habitats"] = missing
    data["in_habitat"] = missing.is_empty()
    data["in_shelter"] = roof_count >= 3 and fence_count >= 2
    return data

func _is_night_time() -> bool:
    var day_fraction := fmod(world_elapsed_seconds, WORLD_DAY_SECONDS) / WORLD_DAY_SECONDS
    return day_fraction >= NIGHT_START_FRACTION

func source_time_of_day() -> String:
    return "night" if _is_night_time() else "day"

func respawn_after_whiteout() -> void:
    if not respawn_house.is_empty():
        var door := Vector2i(int(respawn_house.x), int(respawn_house.y))
        var state := _built_house_state(door)
        if bool(state.get("ready", false)):
            if source_area_layers.has(active_area_id):
                (source_area_layers[active_area_id] as CanvasItem).hide()
            _prepare_built_house_interior(door, state)
            _enter_source_area_now("HOUSE", respawn_cell)
            var floor_index := clampi(int(respawn_house.floor), 0, built_house_floor_capacity - 1)
            _set_active_built_house_floor(floor_index)
            var target := _built_house_floor_origin(floor_index) + Vector2i(int(respawn_house.local_x), int(respawn_house.local_y))
            if _house_sleep_cell_clear(target): player.position = _cell_center(target)
            last_player_cell = _player_cell()
            _sync_follower_to_player()
            return
    # Whiteouts always return to the exterior overworld. Hide whatever source
    # interior was active and restore exterior streaming before moving the player.
    var old_area: String = active_area_id
    if source_area_layers.has(old_area):
        (source_area_layers[old_area] as CanvasItem).visible = false
    active_area_id = "OVERWORLD"
    _set_exact_overworld_streaming(true)
    var target := respawn_cell if respawn_cell.x > -2147483648 else spawn_cell
    player.position = _cell_center(target)
    last_player_cell = target
    _sync_follower_to_player()
    _discover_around(target, DISCOVERY_RADIUS)
    _configure_camera()
    _refresh_exact_tile_streams()

func _ecology_names_at(cell: Vector2i) -> String:
    if active_area_id == "HOUSE" and built_house_interior_cells.has(cell):
        return "house_floor " + String((built_structures.get(cell, {}) as Dictionary).get("name", "")).to_lower()
    if not _in_bounds(cell):
        return ""
    var names: Array[String] = []
    if exact_world != null:
        var tile_names := _exact_names_at(cell)
        if not tile_names.is_empty():
            names.append(tile_names[0].to_lower())
            names.append(tile_names[1].to_lower())
    elif source_tiles.has(cell):
        var source_data: Dictionary = source_tiles.get(cell, {})
        names.append(String(source_data.get("base", source_data.get("name", ""))).to_lower())
        names.append(String(source_data.get("upper", source_data.get("name_upper", ""))).to_lower())
        names.append(String(source_data.get("biome", "")).to_lower())
    if _is_tall_grass_cell(cell):
        names.append("grass")
    if flower_cells.has(cell):
        names.append("flower")
    if resource_objects.has(cell):
        names.append(String((resource_objects[cell] as Dictionary).get("type", "")).to_lower())
    if built_structures.has(cell):
        var built_name := String((built_structures[cell] as Dictionary).get("name", "")).to_lower()
        names.append(built_name)
        if built_name == "flowers":
            names.append("flower")
        elif built_name == "plant":
            names.append("potted")
        elif built_name == "grave":
            names.append("gravestone")
    if landmarks.has(cell):
        names.append(String((landmarks[cell] as Dictionary).get("type", "")).to_lower())
    if not terrain_changes.is_empty() and bool(terrain_changes.get("ice:%d,%d" % [cell.x, cell.y], false)):
        names.append("snow")
    return " ".join(names)

## per-frame
func _update_ecology(delta:float)->void:
    var coordinator=get_parent().get("coop_game")
    if is_instance_valid(coordinator) and coordinator.active:
        if not coordinator.population.authority() and not coordinator.population.authority(coordinator.population.local_scope()):return
        if ecology_accumulator+delta<PokemonEcology.HABITAT_CHECK_SECONDS:
            ecology_accumulator+=delta
            return
        # Only advance records simulated by this peer, while retaining the
        # original habitat, relationship and breeding calculations.
        var all_deployed=deployed_pokemon
        var all_wild=wild_pokemon
        deployed_pokemon={}
        for cell in all_deployed:
            if coordinator.population.authority(preload("res://scripts/coop_population_records.gd").record_scope(all_deployed[cell])):deployed_pokemon[cell]=all_deployed[cell]
        if not coordinator.population.authority():wild_pokemon={}
        _run_ecology_step(delta)
        all_deployed.merge(deployed_pokemon,true)
        deployed_pokemon=all_deployed;wild_pokemon=all_wild
        return
    _run_ecology_step(delta)

func _run_ecology_step(delta: float) -> void:
    ecology_accumulator += delta
    if ecology_accumulator < PokemonEcology.HABITAT_CHECK_SECONDS:
        return
    var ecology_delta := ecology_accumulator
    ecology_accumulator = fmod(
        ecology_accumulator, PokemonEcology.HABITAT_CHECK_SECONDS
    )
    var active_wild := _refresh_ecology_relationships()
    _release_old_eggs()

    for raw_cell in deployed_pokemon.keys():
        var cell: Vector2i = raw_cell
        if not deployed_pokemon.has(cell):
            continue
        var data: Dictionary = deployed_pokemon[cell]
        if (
                bool(data.get("in_habitat", false))
                and String(data.get("held_item", "")).is_empty()
            ):
            var shelter_multiplier := 2.0 if bool(data.get("in_shelter", false)) else 1.0
            data["harvest_progress"] = float(data.get("harvest_progress", 0.0)) + ecology_delta * shelter_multiplier
            var harvest_max := PokemonEcology.harvest_seconds(String(data.get("species", "")))
            if float(data["harvest_progress"]) >= harvest_max:
                var choices := PokemonEcology.harvest_items(String(data.get("species", "")))
                if not choices.is_empty():
                    data["held_item"] = choices[rng.randi_range(0, choices.size() - 1)]
        data = _advance_breeding_clock(data, ecology_delta)
        deployed_pokemon[cell] = data

    # The wild Pokemon in play are the ones the relationship pass just took
    # (not burrowed, near the player or a habitat); nothing since has moved
    # one, and each clock is its own record's. Scanning every wild Pokemon in
    # the world again for them was a fifth of this pass.
    for data in active_wild:
        _advance_breeding_clock(data, ecology_delta, true)

func _advance_breeding_clock(
        data: Dictionary, delta: float, allow_wild_crowding: bool = false
    ) -> Dictionary:
    var population_ok := allow_wild_crowding or int(data.get("nearby_pokemon", 0)) < 3
    if (
            bool(data.get("can_lay_egg", false))
            and bool(data.get("in_habitat", false))
            and bool(data.get("mate_nearby", false))
            and population_ok
            and float(data.get("lay_egg_seconds", PokemonEcology.LAY_EGG_SECONDS)) > 0.0
        ):
        data["lay_egg_seconds"] = maxf(
            0.0,
            float(data.get("lay_egg_seconds", PokemonEcology.LAY_EGG_SECONDS)) - delta
        )
    if (
            not String(data.get("friend_id", "")).is_empty()
            and float(data.get("friend_seconds", PokemonEcology.FRIEND_SECONDS)) > 0.0
        ):
        data["friend_seconds"] = maxf(
            0.0,
            float(data.get("friend_seconds", PokemonEcology.FRIEND_SECONDS)) - delta
        )
    return data

## Returns the wild records it covered, in wild_pokemon order.
func _refresh_ecology_relationships() -> Array[Dictionary]:
    var records: Array[Dictionary] = []
    var active_wild: Array[Dictionary] = []
    # Habitat windows heavily overlap. Cache each cell's ecology string for this
    # refresh so the 1.6-second relationship pass does not repeatedly resolve
    # the same tile/biome dozens of times and hitch while the player is running.
    var ecology_name_cache: Dictionary = {}
    for raw_cell in deployed_pokemon.keys():
        var cell: Vector2i = raw_cell
        records.append({
            "kind": "deployed", "key": cell, "cell": cell,
            "data": deployed_pokemon[cell]
        })
    var active_center := _player_cell()
    # The wild Pokemon near the player or a habitat (_wild_ecology_is_active),
    # from the buckets of wild_population's grid those squares touch.
    var squares: Array = [Vector3i(active_center.x, active_center.y, ECOLOGY_ACTIVE_RADIUS)]
    for raw_cell in deployed_pokemon:
        squares.append(Vector3i(raw_cell.x, raw_cell.y, PokemonEcology.HABITAT_RADIUS))
    for slot in wild_population.slots_in(squares):
        var raw_id := wild_population.ids[slot]
        var wild_data: Dictionary = wild_pokemon[raw_id]
        if bool(wild_data.get("burrowed", false)):
            continue
        var wild_cell: Vector2i = wild_data.get("cell", Vector2i.ZERO)
        active_wild.append(wild_data)
        records.append({
            "kind": "wild", "key": raw_id,
            "cell": wild_cell,
            "data": wild_data
        })

    var index_by_id: Dictionary = {}
    var cell_indices: Dictionary = {}
    for index in range(records.size()):
        var descriptor: Dictionary = records[index]
        var data: Dictionary = descriptor["data"]
        data["previous_mate_id"] = String(data.get("mate_id", ""))
        data["mate_id"] = ""
        data["friend_id"] = ""
        data["can_lay_egg"] = false
        data["mate_nearby"] = false
        data["nearby_pokemon"] = 0
        data = _refresh_record_habitat(
            data, descriptor["cell"], ecology_name_cache)
        descriptor["data"] = data
        records[index] = descriptor
        var ecology_id := String(data.get("ecology_id", ""))
        if not ecology_id.is_empty():
            index_by_id[ecology_id] = index
        var record_cell: Vector2i = descriptor["cell"]
        if not cell_indices.has(record_cell):
            cell_indices[record_cell] = []
        (cell_indices[record_cell] as Array).append(index)

    # Keep an established compatible pair bonded while it wanders a few tiles
    # apart. The old pass erased both IDs every refresh, so natural-looking
    # separation accidentally dissolved the pair before it could return.
    for index in range(records.size()):
        var first_descriptor: Dictionary = records[index]
        var first: Dictionary = first_descriptor["data"]
        var former_mate_id := String(first.get("previous_mate_id", ""))
        if former_mate_id.is_empty() or not index_by_id.has(former_mate_id):
            continue
        var mate_index := int(index_by_id[former_mate_id])
        if mate_index <= index:
            continue
        var second_descriptor: Dictionary = records[mate_index]
        var second: Dictionary = second_descriptor["data"]
        if String(second.get("previous_mate_id", "")) != \
                String(first.get("ecology_id", "")):
            continue
        var first_cell: Vector2i = first_descriptor["cell"]
        var second_cell: Vector2i = second_descriptor["cell"]
        var separation := maxi(
            absi(first_cell.x - second_cell.x),
            absi(first_cell.y - second_cell.y))
        if separation > MATE_BOND_RADIUS or not PokemonEcology.can_mate(first, second):
            continue
        first["mate_id"] = String(second.get("ecology_id", ""))
        second["mate_id"] = String(first.get("ecology_id", ""))
        first_descriptor["data"] = first
        second_descriptor["data"] = second
        records[index] = first_descriptor
        records[mate_index] = second_descriptor
    var nearby_indices: Array = []
    for index in range(records.size()):
        var descriptor: Dictionary = records[index]
        var center: Vector2i = descriptor["cell"]
        var nearby := 0
        var candidates: Array[int] = []
        for y in range(center.y - PokemonEcology.HABITAT_RADIUS, center.y + PokemonEcology.HABITAT_RADIUS + 1):
            for x in range(center.x - PokemonEcology.HABITAT_RADIUS, center.x + PokemonEcology.HABITAT_RADIUS + 1):
                var test := Vector2i(x, y)
                if cell_indices.has(test):
                    for raw_candidate_index in cell_indices[test]:
                        var candidate_index := int(raw_candidate_index)
                        if candidate_index != index:
                            nearby += 1
                            candidates.append(candidate_index)
                if wild_eggs.has(test):
                    nearby += 1
        # Preserve the former record-order choice when more than one mate or
        # friend is nearby while avoiding a scan of the whole world.
        candidates.sort()
        nearby_indices.append(candidates)
        var data: Dictionary = descriptor["data"]
        data["nearby_pokemon"] = nearby
        descriptor["data"] = data
        records[index] = descriptor

    for index in range(records.size()):
        var first_descriptor: Dictionary = records[index]
        var first: Dictionary = first_descriptor["data"]
        if not String(first.get("mate_id", "")).is_empty():
            continue
        for raw_candidate_index in nearby_indices[index]:
            var candidate_index := int(raw_candidate_index)
            if candidate_index <= index:
                continue
            var second_descriptor: Dictionary = records[candidate_index]
            var second: Dictionary = second_descriptor["data"]
            if not String(second.get("mate_id", "")).is_empty():
                continue
            if not PokemonEcology.can_mate(first, second):
                continue
            first["mate_id"] = String(second.get("ecology_id", ""))
            second["mate_id"] = String(first.get("ecology_id", ""))
            first["friend_id"] = ""
            second["friend_id"] = ""
            first_descriptor["data"] = first
            second_descriptor["data"] = second
            records[index] = first_descriptor
            records[candidate_index] = second_descriptor
            break

    for index in range(records.size()):
        var first_descriptor: Dictionary = records[index]
        var first: Dictionary = first_descriptor["data"]
        if (
                not String(first.get("mate_id", "")).is_empty()
                or not String(first.get("friend_id", "")).is_empty()
            ):
            continue
        for raw_candidate_index in nearby_indices[index]:
            var candidate_index := int(raw_candidate_index)
            if candidate_index <= index:
                continue
            var second_descriptor: Dictionary = records[candidate_index]
            var second: Dictionary = second_descriptor["data"]
            if (
                    not String(second.get("mate_id", "")).is_empty()
                    or not String(second.get("friend_id", "")).is_empty()
                    or not PokemonEcology.can_be_friends(first, second)
                ):
                continue
            first["friend_id"] = String(second.get("ecology_id", ""))
            second["friend_id"] = String(first.get("ecology_id", ""))
            first_descriptor["data"] = first
            second_descriptor["data"] = second
            records[index] = first_descriptor
            records[candidate_index] = second_descriptor
            break

    for index in range(records.size()):
        var descriptor: Dictionary = records[index]
        var data: Dictionary = descriptor["data"]
        var mate_id := String(data.get("mate_id", ""))
        if not mate_id.is_empty() and index_by_id.has(mate_id):
            var mate_descriptor: Dictionary = records[int(index_by_id[mate_id])]
            var mate: Dictionary = mate_descriptor["data"]
            var groups: Array = data.get("egg_groups", [])
            data["can_lay_egg"] = (
                String(data.get("gender", "")) == "female"
                or (
                    groups.has("EGG_DITTO")
                    and String(mate.get("gender", "")) == "male"
                )
            )
            var own_cell: Vector2i = descriptor["cell"]
            var mate_cell: Vector2i = mate_descriptor["cell"]
            data["mate_nearby"] = maxi(
                absi(own_cell.x - mate_cell.x),
                absi(own_cell.y - mate_cell.y)
            ) <= PokemonEcology.HABITAT_RADIUS
        if (
                not mate_id.is_empty()
                and mate_id != String(data.get("previous_mate_id", ""))
            ):
            _show_ecology_emote(data.get("sprite") as Sprite2D, "heart")
        data.erase("previous_mate_id")
        descriptor["data"] = data
        records[index] = descriptor
        _store_ecology_descriptor(descriptor)
    return active_wild

func _wild_ecology_is_active(
        cell: Vector2i, active_center: Vector2i
    ) -> bool:
    if (
            absi(cell.x - active_center.x) <= ECOLOGY_ACTIVE_RADIUS
            and absi(cell.y - active_center.y) <= ECOLOGY_ACTIVE_RADIUS
        ):
        return true
    # Player-owned habitat populations keep their nearby wild interactions
    # even while the player is elsewhere; unrelated offscreen wild Pokemon do
    # not need per-frame behavior or relationship scans.
    for raw_cell in deployed_pokemon:
        var deployed_cell := Vector2i(raw_cell)
        if (
                absi(cell.x - deployed_cell.x) <= PokemonEcology.HABITAT_RADIUS
                and absi(cell.y - deployed_cell.y) <= PokemonEcology.HABITAT_RADIUS
            ):
            return true
    return false

func _store_ecology_descriptor(descriptor: Dictionary) -> void:
    var data: Dictionary = descriptor["data"]
    if String(descriptor.get("kind", "")) == "deployed":
        var cell: Vector2i = descriptor["key"]
        if deployed_pokemon.has(cell):
            deployed_pokemon[cell] = data
    else:
        var wild_id = descriptor["key"]
        if wild_pokemon.has(wild_id):
            wild_pokemon[wild_id] = data

## per-frame
func _update_deployed_pokemon(delta: float) -> void:
    var coordinator=get_parent().get("coop_game")
    if is_instance_valid(coordinator) and coordinator.active and not coordinator.population.authority():return
    var directions = [
        Vector2i.ZERO, Vector2i.LEFT, Vector2i.RIGHT,
        Vector2i.UP, Vector2i.DOWN
    ]
    for raw_cell in deployed_pokemon.keys():
        var old_cell = raw_cell
        if not deployed_pokemon.has(old_cell):
            continue
        var data = deployed_pokemon[old_cell]
        if data.has("house_door"):
            continue
        # The Pokemon the player is calling back waits for them.
        if not recall_hold.is_empty() and String(data.get("ecology_id", "")) == recall_hold:
            continue
        _update_pokemon_water_visual(data)
        _update_friendly_passby(data, old_cell, true)
        data["move_timer"] = float(data.get("move_timer", 0.0)) - delta
        if float(data["move_timer"]) > 0.0:
            deployed_pokemon[old_cell] = data
            continue
        data["move_timer"] = _wild_move_delay(String(data.get("species", "")))
        data = _try_create_parent_egg(data, old_cell)
        var behavior = data.get("behavior", {})
        if bool(behavior.get("stationary", false)):
            deployed_pokemon[old_cell] = data
            continue
        if not String(data.get("held_item", "")).is_empty():
            var dance_sprite = data.get("sprite") as Sprite2D
            data["anim_phase"] = 1 - int(data.get("anim_phase", 0))
            if is_instance_valid(dance_sprite):
                _set_overworld_motion_frame(
                    dance_sprite, Vector2.DOWN, int(data["anim_phase"])
                )
            deployed_pokemon[old_cell] = data
            continue

        var direction = directions[rng.randi_range(0, directions.size() - 1)]
        var friend_id = String(data.get("friend_id", ""))
        var friend_reunion = (
            not friend_id.is_empty()
            and float(data.get("friend_seconds", PokemonEcology.FRIEND_SECONDS)) <= 0.0
        )
        var companion_id = friend_id
        if friend_reunion:
            data["friend_seconds"] = PokemonEcology.FRIEND_SECONDS
            _show_friend_reunion(data, friend_id)
        elif companion_id.is_empty() or rng.randf() < 0.18:
            companion_id = String(data.get("mate_id", companion_id))
        if not companion_id.is_empty() and (friend_reunion or rng.randf() < 0.20):
            var companion_cell = _ecology_cell_by_id(companion_id)
            if companion_cell.x > -2147483648:
                direction = _cardinal_direction(companion_cell - old_cell, false)
        direction = _paired_wander_direction(data, old_cell, direction)
        var target = old_cell + direction
        if (
                direction == Vector2i.ZERO
                or not _pokemon_can_move_between(String(data.get("species", "")), old_cell, target)
                or target == _player_cell()
                or target == follower_cell
                or target == field_helper_cell
                or deployed_pokemon.has(target)
                or _wild_id_at_cell(target) >= 0
                or wild_eggs.has(target)
            ):
            deployed_pokemon[old_cell] = data
            continue

        deployed_pokemon.erase(old_cell)
        data["cell"] = target
        data["x"] = target.x
        data["y"] = target.y
        data["anim_phase"] = 1 - int(data.get("anim_phase", 0))
        var sprite = data.get("sprite") as Sprite2D
        if is_instance_valid(sprite):
            _set_overworld_motion_frame(sprite, direction, int(data["anim_phase"]))
            sprite.z_index = _depth_z(target)
            var move_seconds = 0.20
            if bool(behavior.get("flee", false)):
                move_seconds = 16.0 / (2.0 * 60.0)
            create_tween().tween_property(
                sprite, "position", _cell_center(target), move_seconds
            ).set_trans(Tween.TRANS_LINEAR)
        deployed_pokemon[target] = data

func _egg_ground_cell_is_valid(cell: Vector2i, ignored_wild_id: int = -1) -> bool:
    if not _in_bounds(cell):
        return false
    if (
            wild_eggs.has(cell) or deployed_pokemon.has(cell)
            or _wild_id_at_cell(cell, ignored_wild_id) >= 0
            or built_structures.has(cell) or landmarks.has(cell)
            or resource_objects.has(cell) or blocked.has(cell)
        ):
        return false
    # Reject the full visible footprint of exact resources, especially the
    # 48x48 Savanna tree whose authored anchor is only one tile.
    if _exact_resource_anchor(cell).x > -2147483648:
        return false
    if exact_world != null:
        var tile: SourceTile = exact_world.tile_at(cell)
        if tile == null or tile.is_water or tile.is_solid or tile.is_ledge:
            return false
    elif terrain_kind_at(cell) == 0:
        return false
    return true

func _resolve_egg_ground_cell(preferred: Vector2i, ignored_wild_id: int = -1) -> Vector2i:
    # Search the complete source habitat radius, nearest ring first, while
    # consuming no RNG. The old short 13-cell list could fail in a healthy
    # wandering colony even when plenty of valid habitat ground was nearby.
    # Full deterministic rings keep both parents alive and moving and make the
    # authored breeding clock reliably produce a visible egg when room exists.
    if _egg_ground_cell_is_valid(preferred, ignored_wild_id):
        return preferred
    var preferred_offsets: Array[Vector2i] = [
        Vector2i.DOWN, Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP
    ]
    for offset in preferred_offsets:
        var nearby := preferred + offset
        if _egg_ground_cell_is_valid(nearby, ignored_wild_id):
            return nearby
    for radius in range(1, PokemonEcology.HABITAT_RADIUS + 1):
        for y_offset in range(-radius, radius + 1):
            for x_offset in range(-radius, radius + 1):
                if maxi(absi(x_offset), absi(y_offset)) != radius:
                    continue
                var offset := Vector2i(x_offset, y_offset)
                if preferred_offsets.has(offset):
                    continue
                var candidate := preferred + offset
                if _egg_ground_cell_is_valid(candidate, ignored_wild_id):
                    return candidate
    return Vector2i(-2147483648, -2147483648)

func _try_create_parent_egg(
        data: Dictionary, egg_cell: Vector2i, ignored_wild_id: int = -1
    ) -> Dictionary:
    if (
            float(data.get("lay_egg_seconds", PokemonEcology.LAY_EGG_SECONDS)) > 0.0
            or not bool(data.get("can_lay_egg", false))
        ):
        return data
    var partner := _ecology_record_by_id(String(data.get("mate_id", "")))
    if partner.is_empty():
        return data
    var partner_cell := _ecology_cell_by_id(String(data.get("mate_id", "")))
    if (
            partner_cell.x <= -2147483648
            or maxi(absi(partner_cell.x - egg_cell.x), absi(partner_cell.y - egg_cell.y)) > \
                PokemonEcology.HABITAT_RADIUS
            or not bool(data.get("in_habitat", false))
            or not bool(partner.get("in_habitat", false))
            or not PokemonEcology.can_mate(data, partner)
        ):
        return data
    # Nothing hatches or removes a habitat egg for days (see _release_old_eggs),
    # so an undisturbed couple would otherwise bury its habitat in eggs. Wait a
    # full cycle before checking again rather than holding the pair together.
    if _couple_egg_count(
            String(data.get("ecology_id", "")), String(partner.get("ecology_id", ""))
        ) >= PokemonEcology.MAX_EGGS_PER_COUPLE:
        data["lay_egg_seconds"] = PokemonEcology.LAY_EGG_SECONDS
        return data
    # The parent occupies egg_cell by definition. Do not reject its own tile;
    # resolve the egg onto the nearest free authored ground cell instead. This
    # fixes the deployed-parent path that could never lay and keeps both parents
    # alive/free to continue their normal paired wandering.
    var resolved_cell := _resolve_egg_ground_cell(egg_cell, ignored_wild_id)
    if resolved_cell.x <= -2147483648:
        return data
    var egg := PokemonEcology.egg_record(data, partner, rng)
    _add_wild_egg_record(egg, resolved_cell, ignored_wild_id)
    data["lay_egg_seconds"] = PokemonEcology.LAY_EGG_SECONDS
    _show_ecology_emote(data.get("sprite") as Sprite2D, "heart")
    var partner_sprite: Sprite2D = partner.get("sprite") as Sprite2D
    _show_ecology_emote(partner_sprite, "heart")
    return data

func _may_release_egg(egg:Dictionary)->bool:
    var coordinator=get_parent().get("coop_game")
    if is_instance_valid(coordinator) and coordinator.active:
        return coordinator.population.authority(preload("res://scripts/coop_population_records.gd").record_scope(egg))
    return true

func _release_old_eggs() -> void:
    # A habitat egg left alone is released into the wild: it simply leaves the
    # overworld. Eggs a player set down are theirs and stay. An egg from before
    # this rule starts its count when it is first seen.
    var lifetime := PokemonEcology.EGG_RELEASE_DAYS * WORLD_DAY_SECONDS
    for raw_cell in wild_eggs.keys():
        var egg: Dictionary = wild_eggs[raw_cell]
        if bool(egg.get("dropped_party_egg", false)) or not _may_release_egg(egg):
            continue
        if not egg.has("laid_at") or float(egg["laid_at"]) > world_elapsed_seconds:
            egg["laid_at"] = world_elapsed_seconds
            continue
        if world_elapsed_seconds - float(egg["laid_at"]) < lifetime:
            continue
        var egg_sprite: Sprite2D = egg.get("sprite") as Sprite2D
        if is_instance_valid(egg_sprite):
            egg_sprite.queue_free()
        wild_eggs.erase(raw_cell)

func _couple_egg_count(first_id: String, second_id: String) -> int:
    if first_id.is_empty() or second_id.is_empty():
        return 0
    var count := 0
    for egg in wild_eggs.values():
        if bool((egg as Dictionary).get("dropped_party_egg", false)):
            continue
        var parents = (egg as Dictionary).get("parent_ids", [])
        if parents is Array and parents.has(first_id) and parents.has(second_id):
            count += 1
    return count

func _ecology_record_by_id(ecology_id: String) -> Dictionary:
    if ecology_id.is_empty():
        return {}
    for data in deployed_pokemon.values():
        if String((data as Dictionary).get("ecology_id", "")) == ecology_id:
            return data as Dictionary
    return _wild_ecology_record(ecology_id)

func _ecology_cell_by_id(ecology_id: String) -> Vector2i:
    for raw_cell in deployed_pokemon.keys():
        var data: Dictionary = deployed_pokemon[raw_cell]
        if String(data.get("ecology_id", "")) == ecology_id:
            return Vector2i(raw_cell)
    var record := _wild_ecology_record(ecology_id)
    if not record.is_empty():
        return Vector2i(record.get("cell", Vector2i.ZERO))
    return Vector2i(-2147483648, -2147483648)

## The wild record with this ecology id, {} if none. _add_wild_pokemon names
## each one "wild:<its key>" (one per key), so that key is looked at first:
## scanning every wild Pokemon in the world for a mate was most of the time a
## wandering step took.
func _wild_ecology_record(ecology_id: String) -> Dictionary:
    if ecology_id.begins_with("wild:"):
        var record = wild_pokemon.get(int(ecology_id.substr(5)))
        if record != null and String(record.get("ecology_id", "")) == ecology_id:
            return record
    for data in wild_pokemon.values():
        if String((data as Dictionary).get("ecology_id", "")) == ecology_id:
            return data as Dictionary
    return {}

func _paired_wander_direction(
        data: Dictionary, origin: Vector2i, fallback: Vector2i
    ) -> Vector2i:
    var mate_id := String(data.get("mate_id", ""))
    if mate_id.is_empty():
        return fallback
    var mate_cell := _ecology_cell_by_id(mate_id)
    if mate_cell.x <= -2147483648:
        return fallback
    var delta := mate_cell - origin
    var distance := maxi(absi(delta.x), absi(delta.y))
    var egg_ready := bool(data.get("can_lay_egg", false)) and \
        float(data.get("lay_egg_seconds", PokemonEcology.LAY_EGG_SECONDS)) <= 0.0

    # Do not glue paired parents together. They are free to wander throughout
    # the source 7x7 habitat square; only pull them back at its edge. When an
    # egg is actually ready, converge the pair so the existing egg rule still
    # succeeds without changing fertility, timers, inheritance, or egg odds.
    if egg_ready and distance > 1:
        return _cardinal_direction(delta, false)
    if distance > PokemonEcology.HABITAT_RADIUS:
        return _cardinal_direction(delta, false)
    if distance == PokemonEcology.HABITAT_RADIUS and rng.randf() < 0.25:
        return _cardinal_direction(delta, false)
    if distance <= 1 and rng.randf() < 0.22:
        return _cardinal_direction(delta, true)
    return fallback

const WATER_FLOAT_OFFSETS := {"lapras": 5.0, "anorith": 2.0, "araichu": 7.0, "raichu_alolan": 7.0, "mantine": 4.0, "sharpedo": 2.0}
var water_pokemon_materials: Dictionary = {}
var water_pokemon_shader: Shader

## The shader of every swimming Pokemon: a size is only the `extra` and
## `frame_height` of its material. A canvas shader compiles when it is first
## drawn, and each new size used to make a shader of its own.
func _water_pokemon_shader() -> Shader:
    if water_pokemon_shader == null:
        water_pokemon_shader = Shader.new()
        water_pokemon_shader.code = """shader_type canvas_item;
uniform float extra = 0.0;
uniform float frame_height = 16.0;
void vertex() {
    float bob = step(40.0, mod(TIME * 60.0, 80.0));
    VERTEX.y += 4.0 - extra - bob;
}
void fragment() {
    float bob = step(40.0, mod(TIME * 60.0, 80.0));
    if (UV.y * frame_height >= frame_height - 8.0 + extra + bob) { discard; }
}
"""
    return water_pokemon_shader

func _source_pokemon_in_water(cell: Vector2i) -> bool:
    if exact_world != null:
        var names := _exact_names_at(cell)
        return not names.is_empty() and "water" in names[0] and not "_tidal" in names[0]
    return terrain_kind_at(cell) == 0

func _update_pokemon_water_visual(data: Dictionary) -> void:
    var sprite := data.get("sprite") as Sprite2D
    if not is_instance_valid(sprite) or bool(data.get("burrowed", false)):
        return
    var cell := Vector2i(floori(sprite.position.x / TILE), floori(sprite.position.y / TILE))
    var in_water := _source_pokemon_in_water(cell)
    if not in_water:
        if sprite.has_meta("water_visual"):
            sprite.material = null
            sprite.remove_meta("water_visual")
        return
    var species := String(data.get("species", ""))
    var extra := float(WATER_FLOAT_OFFSETS.get(species, 0.0))
    var height := float(sprite.texture.get_height()) / sprite.vframes
    if species == "mega_sharpedo": extra = 8.0 - height / 2.0
    # Half of this tall sprite under water left only its horns and eyes
    # showing. It rides higher: the whole face and upper body are seen.
    if species == "mega_gyarados": extra = 8.0 - roundf(height * 0.28)
    var key := Vector2(extra, height)
    if not water_pokemon_materials.has(key):
        var material := ShaderMaterial.new()
        material.shader = _water_pokemon_shader()
        material.set_shader_parameter("extra", extra)
        material.set_shader_parameter("frame_height", height)
        water_pokemon_materials[key] = material
    sprite.material = water_pokemon_materials[key]
    sprite.set_meta("water_visual", true)

func _pokemon_can_move_between(species: String, origin: Vector2i, target: Vector2i) -> bool:
    if exact_world != null:
        var destination := exact_world.tile_at(target)
        var current := exact_world.tile_at(origin)
        # Pokemon.java Move/Wander reject ledges even when player-passable.
        if destination == null or destination.is_ledge:
            return false
        if current != null and current.is_ledge and _permitted_ledge_direction(current) == Vector2i.UP and target.y < origin.y:
            return false
    if not _source_pokemon_in_water(origin):
        return _pokemon_can_enter(species, target)
    if not _in_bounds(target) or blocked.has(target):
        return false
    var structure: Dictionary = built_structures.get(target, {})
    if String(structure.get("name", "")) == "FENCE" or bool(structure.get("gate", false)):
        return false
    if exact_world != null:
        var tile := exact_world.tile_at(target)
        if tile == null or "fence" in tile.name_upper or "fence" in tile.name:
            return false
        var near_shore := false
        var target_near_shore := false
        for y in range(-1, 2):
            for x in range(-1, 2):
                var direction := Vector2i(x, y)
                var shore := exact_world.tile_at(origin + direction)
                var target_shore := exact_world.tile_at(target + direction)
                near_shore = near_shore or (shore != null and not "water" in shore.name)
                target_near_shore = target_near_shore or (target_shore != null and not "water" in target_shore.name)
        if near_shore and (not target_near_shore or not "water" in tile.name):
            return false
        var only_swim := bool(PokemonData.info(species).get("overworld_behavior", {}).get("swim_only", false))
        return tile.is_water if only_swim else (tile.is_water or not tile.is_solid)
    return _pokemon_can_enter(species, target)

## Clearing what grew on a tile unblocks the ground, but not a wall or roof
## that has since been built there, nor an item lying on it. Without this, a
## roof over ground where grass was once cut stopped blocking every time the
## world loaded, and Pokemon walked onto the house.
func _unblock_ground(cell: Vector2i) -> void:
    if bool(built_structures.get(cell, {}).get("solid", false)):
        return
    if blocked.get(cell) is String:
        return
    blocked.erase(cell)

func _pokemon_can_enter(species: String, cell: Vector2i) -> bool:
    if species.to_lower() in [
            "araichu", "raichu_alolan", "aexeggutor", "exeggutor_alolan"] and \
            exact_world != null and not blocked.has(cell):
        var tile: SourceTile = exact_world.tile_at(cell)
        if tile != null and tile.is_water and not tile.is_solid:
            var route_name := "" if tile.route_belongs_to == null else \
                tile.route_belongs_to.name.to_lower()
            if (species.to_lower() in ["araichu", "raichu_alolan"] and \
                    route_name == "beach2_water") or \
                    (route_name == "beach2" and _is_beach_tidal_tile(tile)):
                return true
    if not _in_bounds(cell) or blocked.has(cell):
        return false
    var structure: Dictionary = built_structures.get(cell, {})
    if String(structure.get("name", "")) == "FENCE" or \
            bool(structure.get("gate", false)):
        return false
    if exact_world != null:
        var tile: SourceTile = exact_world.tile_at(cell)
        if tile != null and (tile.is_ledge or "fence" in tile.name.to_lower() or \
                "fence" in tile.name_upper.to_lower()):
            return false
    var behavior: Dictionary = PokemonData.info(species).get("overworld_behavior", {})
    if bool(behavior.get("swim_only", false)):
        return terrain_kind_at(cell) == 0
    return _is_walkable(cell) and terrain_kind_at(cell) != 0

## include_population false leaves the habitat and wild Pokemon and the eggs
## out (empty): an online area save takes them from the shared records.
func get_crafting_save_state(include_population: bool = true) -> Dictionary:
    var structures: Array = []
    for key in built_structures.keys():
        var cell: Vector2i = key
        var data: Dictionary = built_structures[cell]
        if bool(data.get("generated_stair_pair", false)):
            continue
        var saved_structure := data.duplicate(true)
        for runtime_key in ["sprite", "collision", "solid", "bridged_water"]:
            saved_structure.erase(runtime_key)
        saved_structure["name"] = String(data.get("name", ""))
        saved_structure["x"] = cell.x
        saved_structure["y"] = cell.y
        structures.append(saved_structure)

    var farms: Array = []
    for key in (deployed_pokemon.keys() if include_population else []):
        var cell: Vector2i = key
        var data: Dictionary = deployed_pokemon[cell]
        farms.append(_serializable_ecology_record(data, cell))

    var saved_wild_pokemon: Array = []
    for raw_id in (wild_pokemon.keys() if include_population else []):
        var data: Dictionary = wild_pokemon[raw_id]
        var cell: Vector2i = data.get("cell", Vector2i.ZERO)
        var saved_wild := _serializable_ecology_record(data, cell)
        saved_wild["id"] = int(raw_id)
        saved_wild_pokemon.append(saved_wild)

    var saved_eggs: Array = []
    for raw_cell in (wild_eggs.keys() if include_population else []):
        var cell: Vector2i = raw_cell
        var data: Dictionary = wild_eggs[cell]
        var saved_egg := data.duplicate(true)
        saved_egg.erase("sprite")
        saved_egg.erase("cell")
        saved_egg["x"] = cell.x
        saved_egg["y"] = cell.y
        saved_eggs.append(saved_egg)

    var saved_follower: Dictionary = {}
    if not follower_pokemon.is_empty():
        saved_follower = follower_pokemon.duplicate(true)
        saved_follower.erase("sprite")

    return {
        "removed_resources": removed_resources.keys(),
        "terrain_changes": terrain_changes.duplicate(true),
        "source_plant_farms": plants().snapshot(),
        "structures": structures,
        "deployed_pokemon": farms,
        "wild_pokemon": saved_wild_pokemon,
        "wild_eggs": saved_eggs,
        "follower_pokemon": saved_follower,
        "active_field_move": active_field_move,
        "active_field_pokemon": active_field_pokemon.duplicate(true),
        "build_selection_index": build_selection_index,
        "next_deployed_id": next_deployed_id,
        "source_interior_mutations": source_interior_mutations.duplicate(true),
        "mine_pokemon": SourceMineRuntime.snapshot(self),
        "built_house_paintings": built_house_paintings.duplicate(true),
        "built_house_floor_tiles": built_house_floor_tiles.keys(),
        "built_house_decorations": built_house_decorations.duplicate(true),
        "built_house_origins": built_house_origins.duplicate(true),
        "event_progress": event_progress.duplicate(true),
        "ghost_step_countdown": ghost_step_countdown,
        "dropped_items": dropped_items().snapshot(),
        "discovered_cells": discovered_save_value(),
        "world_elapsed_seconds": world_elapsed_seconds,
        "repel_until_elapsed": repel_until_elapsed,
        "active_area_id": active_area_id,
        "source_interior_layout_version": 1,
        "source_return_x": Vector2i(area_return_cells.get("%s_RETURN" % active_area_id, spawn_cell)).x,
        "source_return_y": Vector2i(area_return_cells.get("%s_RETURN" % active_area_id, spawn_cell)).y,
        # Preserve enough built-house context to reconstruct the same floor
        # before Main restores the raw player position. Generated stair mirrors
        # are rebuilt from the saved primary stairs and are never serialized.
        "active_built_house_door_x": (
            active_built_house_door.x if active_area_id == "HOUSE" else -2147483648
        ),
        "active_built_house_door_y": (
            active_built_house_door.y if active_area_id == "HOUSE" else -2147483648
        ),
        "active_built_house_floor": (
            _built_house_floor_index_for_cell(_player_cell())
            if active_area_id == "HOUSE" else 0
        ),
        "camera_zoom_level": camera_zoom_level,
        "respawn_house": respawn_house.duplicate(true),
        "respawn_x": respawn_cell.x,
        "respawn_y": respawn_cell.y
    }

func _serializable_ecology_record(data: Dictionary, cell: Vector2i) -> Dictionary:
    var saved := data.duplicate(true)
    # A hidden sand trap's clock values live on its shared clock.
    var trap_id := int(data.get("id", -1))
    if sand_trap_clock_of.has(trap_id) and is_same(wild_pokemon.get(trap_id), data):
        _sand_trap_write(sand_trap_clock_of[trap_id], saved)
    for runtime_key in [
            "sprite", "burrow_whirl_sprite", "burrow_sand_sprite",
            "behavior", "cell",
            "previous_mate_id", "ball_move_tween", "ball_reserved", "ball_facing"
        ]:
        saved.erase(runtime_key)
    var source_record = saved.get("source_record", {})
    if typeof(source_record) == TYPE_DICTIONARY:
        var serializable_source := (source_record as Dictionary).duplicate(true)
        serializable_source.erase("position")
        saved["source_record"] = serializable_source
    saved["x"] = cell.x
    saved["y"] = cell.y
    return saved

func restore_crafting_save_state(state: Dictionary) -> void:
    if state.is_empty():
        # Loading spawns no Pokemon before this (_generate_exact_live_world).
        await _ensure_overworld_pokemon_population()
        return
    var prior_gameplay := gameplay_enabled
    gameplay_enabled = false
    var restore_deadline := Time.get_ticks_usec() + 13000
    restoring_saved_tiles = true
    restored_tiles_need_refresh = false
    # Main's own part of the restore (textures, options, party) ran in this
    # frame: the first slice of this one is the next.
    await get_tree().process_frame
    restore_deadline = Time.get_ticks_usec() + 13000
    dropped_items().clear_actors()
    world_elapsed_seconds = float(state.get("world_elapsed_seconds", world_elapsed_seconds))
    last_event_day = _world_day_index()
    ghost_step_countdown = int(state.get("ghost_step_countdown", -1))
    var saved_event_progress = state.get("event_progress", {})
    if typeof(saved_event_progress) == TYPE_DICTIONARY:
        var restored_progress := (saved_event_progress as Dictionary).duplicate(true)
        for required_key in [
                "completed", "trainer_defeated", "keystone_life_force",
                "regis_caught", "mewtwo_defeated_day",
                "fossil_machine_powered", "biome_first_entries"
            ]:
            if not restored_progress.has(required_key):
                restored_progress[required_key] = (
                    [] if required_key == "regis_caught"
                    else -1 if required_key == "mewtwo_defeated_day"
                    else false if required_key == "fossil_machine_powered"
                    else {}
                )
        event_progress = restored_progress
    repel_until_elapsed = float(state.get("repel_until_elapsed", 0.0))
    built_house_paintings.clear()
    built_house_floor_tiles.clear()
    built_house_decorations.clear()
    built_house_origins = (state.get("built_house_origins", {}) as Dictionary).duplicate(true)
    built_house_decorations = state.get("built_house_decorations", {}).duplicate(true)
    var saved_house_floors = state.get("built_house_floor_tiles", [])
    if typeof(saved_house_floors) == TYPE_ARRAY:
        for raw_floor_key in saved_house_floors:
            if Time.get_ticks_usec() >= restore_deadline:
                await get_tree().process_frame
                restore_deadline = Time.get_ticks_usec() + 13000
            built_house_floor_tiles[String(raw_floor_key)] = true
    var saved_house_paintings = state.get("built_house_paintings", {})
    if typeof(saved_house_paintings) == TYPE_DICTIONARY:
        for raw_key in (saved_house_paintings as Dictionary).keys():
            if Time.get_ticks_usec() >= restore_deadline:
                await get_tree().process_frame
                restore_deadline = Time.get_ticks_usec() + 13000
            var picture_index := clampi(int((saved_house_paintings as Dictionary)[raw_key]), 1, 20)
            built_house_paintings[String(raw_key)] = picture_index
    set_build_selection_index(int(state.get("build_selection_index", 0)))
    active_area_id = String(state.get("active_area_id", "OVERWORLD"))
    if (
            active_area_id not in ["OVERWORLD", "HOUSE", "CAVE"]
            and not source_area_entries.has(active_area_id)
        ):
        active_area_id = "OVERWORLD"
    if active_area_id not in ["OVERWORLD", "HOUSE", "CAVE"]:
        area_return_cells["%s_RETURN" % active_area_id] = (
            Vector2i(int(state["source_return_x"]), int(state["source_return_y"]))
            if state.has("source_return_x") and state.has("source_return_y")
            else _recover_source_dungeon_return(active_area_id))
    if source_area_layers.has(active_area_id):
        (source_area_layers[active_area_id] as CanvasItem).visible = true
    _set_exact_overworld_streaming(active_area_id == "OVERWORLD")
    camera_zoom_level = clampf(
        float(state.get("camera_zoom_level", 1.0)) if preload("res://scripts/game_options.gd").enabled("zoom") else 1.0,
        CAMERA_ZOOM_MIN,
        CAMERA_ZOOM_MAX
    )
    respawn_cell = Vector2i(
        int(state.get("respawn_x", -2147483648)),
        int(state.get("respawn_y", -2147483648))
    )
    respawn_house = (state.get("respawn_house", {}) as Dictionary).duplicate(true)
    call_deferred("_configure_camera")
    next_deployed_id = maxi(1, int(state.get("next_deployed_id", 1)))

    if state.has("discovered_cells"):
        var saved_discovery = state.get("discovered_cells", [])
        if typeof(saved_discovery) == TYPE_ARRAY:
            # A save from before the bitset: a list of "x,y" keys, read a
            # slice of the frame at a time (an explored world has 100 000s).
            discovered_cells.clear()
            for raw_key in saved_discovery:
                if Time.get_ticks_usec() >= restore_deadline:
                    await get_tree().process_frame
                    restore_deadline = Time.get_ticks_usec() + 13000
                var cell := _cell_from_key(String(raw_key))
                if _in_bounds(cell):
                    discovered_cells.add(cell)
        else:
            restore_discovered(saved_discovery)

    var saved_terrain = state.get("terrain_changes", {})
    if typeof(saved_terrain) == TYPE_DICTIONARY:
        for key in saved_terrain.keys():
            if Time.get_ticks_usec() >= restore_deadline:
                await get_tree().process_frame
                restore_deadline = Time.get_ticks_usec() + 13000
            var cell := _cell_from_key(String(key))
            if _in_bounds(cell):
                var kind := int(saved_terrain[key])
                terrain_changes[String(key)] = kind
                _set_exact_tile_names(
                    cell, "sand1" if kind == 1 else "green1", ""
                )

    var removed = state.get("removed_resources", [])
    if typeof(removed) == TYPE_ARRAY:
        for raw_key in removed:
            if Time.get_ticks_usec() >= restore_deadline:
                await get_tree().process_frame
                restore_deadline = Time.get_ticks_usec() + 13000
            var key := String(raw_key)
            var cell := _cell_from_key(key)
            if exact_world != null:
                var tile := exact_world.tile_at(cell)
                if tile != null:
                    tile.set_names(tile.name, "")
                    _refresh_exact_streams()
            else:
                _remove_resource(cell, false)
            removed_resources[key] = true

    var saved_structures = state.get("structures", [])
    if typeof(saved_structures) == TYPE_ARRAY:
        for raw in saved_structures:
            if Time.get_ticks_usec() >= restore_deadline:
                await get_tree().process_frame
                restore_deadline = Time.get_ticks_usec() + 13000
            if typeof(raw) != TYPE_DICTIONARY:
                continue
            var entry: Dictionary = raw
            var cell := Vector2i(int(entry.get("x", -1)), int(entry.get("y", -1)))
            if String(entry.get("name", "")) == "WINDOW" and _in_bounds(cell):
                entry = entry.duplicate(true)
                entry["name"] = "WALL"
                entry["recipe_name"] = "WALL"
                entry["window"] = true
            place_structure(String(entry.get("recipe_name", entry.get("name", ""))), cell, true, entry)

        # Resolve connections and attachments against the complete restored
        # shell, independently of the order in which its pieces were saved.
        for raw_cell in built_structures.keys():
            if Time.get_ticks_usec() >= restore_deadline:
                await get_tree().process_frame
                restore_deadline = Time.get_ticks_usec() + 13000
            _refresh_connected_structures_around(raw_cell)
            _refresh_shell_attachment(raw_cell)

    # Reconstruct a saved player-built house only after its exterior and
    # primary stairs have been restored. This recreates the interior layer,
    # generated stair mirrors, void collisions, and the selected upper floor
    # before Main restores the saved player coordinates.
    if active_area_id == "HOUSE":
        var saved_house_door: Vector2i = Vector2i(
            int(state.get("active_built_house_door_x", -2147483648)),
            int(state.get("active_built_house_door_y", -2147483648))
        )
        var saved_house_floor: int = maxi(0, int(state.get("active_built_house_floor", 0)))
        var valid_saved_house: bool = (
            saved_house_door.x > -2147483648
            and built_structures.has(saved_house_door)
            and String((built_structures[saved_house_door] as Dictionary).get("name", "")) == "DOOR"
        )
        if valid_saved_house:
            var saved_house_state: Dictionary = _built_house_state(saved_house_door)
            if bool(saved_house_state.get("ready", false)):
                _prepare_built_house_interior(saved_house_door, saved_house_state)
                _set_active_built_house_floor(saved_house_floor)
                var restored_house_layer: CanvasItem = get_node_or_null("BuiltHouseInterior") as CanvasItem
                if restored_house_layer != null:
                    restored_house_layer.visible = true
                _set_exact_overworld_streaming(false)
            else:
                active_area_id = "OVERWORLD"
        else:
            active_area_id = "OVERWORLD"
        if active_area_id == "OVERWORLD":
            _set_exact_overworld_streaming(true)

    var saved_farms = state.get("deployed_pokemon", [])
    if typeof(saved_farms) == TYPE_ARRAY:
        for raw in saved_farms:
            if Time.get_ticks_usec() >= restore_deadline:
                await get_tree().process_frame
                restore_deadline = Time.get_ticks_usec() + 13000
            if typeof(raw) != TYPE_DICTIONARY:
                continue
            var entry: Dictionary = raw
            var cell := Vector2i(int(entry.get("x", -1)), int(entry.get("y", -1)))
            _restore_deployed_pokemon(entry, cell)

    var wild_restored := false
    if state.has("wild_pokemon"):
        var saved_wild = state.get("wild_pokemon", [])
        # Early port saves wrote an empty array here, which erased every
        # source-generated overworld Pokemon on load. Preserve the freshly
        # reconstructed source population for those saves.
        if typeof(saved_wild) == TYPE_ARRAY and (not saved_wild.is_empty() or bool(state.get("coop_authoritative_population", false))):
            wild_restored = true
            _clear_wild_pokemon()
            for raw in saved_wild:
                if Time.get_ticks_usec() >= restore_deadline:
                    await get_tree().process_frame
                    restore_deadline = Time.get_ticks_usec() + 13000
                if typeof(raw) != TYPE_DICTIONARY:
                    continue
                var entry: Dictionary = raw
                var cell := Vector2i(
                    int(entry.get("x", -1)), int(entry.get("y", -1))
                )
                _add_wild_pokemon(
                    String(entry.get("species", "pidgey")),
                    int(entry.get("level", 2)),
                    cell,
                    String(entry.get("home_biome", biome_at(cell))),
                    int(entry.get("id", 0)),
                    entry.get("source_record", {}) as Dictionary,
                    entry
                )
    # Without saved Pokemon a load gets the world's own population here: none
    # is spawned before a load.
    if not bool(state.get("coop_authoritative_population", false)) or not wild_restored:
        await _ensure_overworld_pokemon_population()

    if state.has("wild_eggs"):
        _clear_wild_eggs()
        var saved_eggs = state.get("wild_eggs", [])
        if typeof(saved_eggs) == TYPE_ARRAY:
            for raw in saved_eggs:
                if Time.get_ticks_usec() >= restore_deadline:
                    await get_tree().process_frame
                    restore_deadline = Time.get_ticks_usec() + 13000
                if typeof(raw) != TYPE_DICTIONARY:
                    continue
                var entry: Dictionary = raw
                _add_wild_egg(
                    String(entry.get("species", "pidgey")),
                    Vector2i(int(entry.get("x", -1)), int(entry.get("y", -1))),
                    entry
                )

    # Field moves are momentary actions, not saved-game startup state. Loading
    # never auto-deploys a follower or silently starts BUILD/FOLLOW.
    clear_active_field_move(false)

    var saved_interior_mutations = state.get("source_interior_mutations", {})
    if typeof(saved_interior_mutations) == TYPE_DICTIONARY:
        source_interior_mutations.clear()
        for raw_key in saved_interior_mutations:
            if Time.get_ticks_usec() >= restore_deadline:
                await get_tree().process_frame
                restore_deadline = Time.get_ticks_usec() + 13000
            var key := String(raw_key)
            var mutation = saved_interior_mutations[raw_key]
            if typeof(mutation) != TYPE_DICTIONARY:
                continue
            var cell := _cell_from_key(key)
            if int(state.get("source_interior_layout_version", 0)) == 0:
                cell = _legacy_source_interior_cell(cell)
                key = _cell_key(cell)
            source_interior_mutations[key] = (mutation as Dictionary).duplicate(true)
            _apply_source_interior_mutation(cell, mutation as Dictionary)
    SourceRegiRuntime.sync(self)
    source_plant_farms = state.get("source_plant_farms", {}).duplicate(true)
    SourceMineRuntime.restore(self, state.get("mine_pokemon", {}))
    plants().restore()
    if exact_world != null:
        var repaired_roof_cells := exact_world.repair_mansion_roof_grass()
        for cell in repaired_roof_cells:
            if Time.get_ticks_usec() >= restore_deadline:
                await get_tree().process_frame
                restore_deadline = Time.get_ticks_usec() + 13000
            source_interior_mutations.erase(_cell_key(cell))
            source_plant_farms.erase(_cell_key(cell))
        if not repaired_roof_cells.is_empty():
            _refresh_exact_streams()
    await _refresh_daily_events(true)
    SourceForestBoss.install(self)
    await preload("res://scripts/biome_megas.gd").prepare_load(self)
    await get_tree().process_frame
    preload("res://scripts/biome_megas.gd").install(self)

    dropped_items().restore(state.get("dropped_items", {}))
    map_art_revision += 1
    restoring_saved_tiles = false
    if restored_tiles_need_refresh:
        restored_tiles_need_refresh = false
        _refresh_exact_streams()
    # What main does next (map, view) is the next frame.
    await get_tree().process_frame
    gameplay_enabled = prior_gameplay

func _clear_wild_pokemon() -> void:
    for raw_id in wild_pokemon.keys():
        var data: Dictionary = wild_pokemon[raw_id]
        var sprite: Sprite2D = data.get("sprite") as Sprite2D
        if is_instance_valid(sprite):
            sprite.queue_free()
        var whirl_sprite: Sprite2D = data.get("burrow_whirl_sprite") as Sprite2D
        if is_instance_valid(whirl_sprite):
            whirl_sprite.queue_free()
        var sand_sprite: Sprite2D = data.get("burrow_sand_sprite") as Sprite2D
        if is_instance_valid(sand_sprite):
            sand_sprite.queue_free()
    wild_population.clear()
    sand_trap_ids.clear()
    sand_trap_clocks.clear()
    sand_trap_clock_of.clear()
    next_wild_id = 1

func _clear_wild_eggs() -> void:
    for raw_cell in wild_eggs.keys():
        var data: Dictionary = wild_eggs[raw_cell]
        var sprite: Sprite2D = data.get("sprite") as Sprite2D
        if is_instance_valid(sprite):
            sprite.queue_free()
    wild_eggs.clear()

func _restore_deployed_pokemon(entry: Dictionary, cell: Vector2i) -> void:
    var indoors := entry.has("house_door")
    if not indoors and not _in_bounds(cell):
        return
    # One Pokemon, one tile: a second copy of one already standing is not
    # placed, and whatever stood on this tile goes, sprite included. Without
    # this a doubled entry left a frozen sprite behind with nothing under it.
    var restored_id := String(entry.get("ecology_id", ""))
    if not restored_id.is_empty():
        for other_cell in deployed_pokemon:
            if other_cell != cell and String(deployed_pokemon[other_cell].get("ecology_id", "")) == restored_id:
                return
    if deployed_pokemon.has(cell):
        var replaced = deployed_pokemon[cell].get("sprite")
        if is_instance_valid(replaced):
            replaced.queue_free()
        deployed_pokemon.erase(cell)
    var species := String(entry.get("species", "")).to_lower()
    var pokemon_texture: Texture2D = PokemonData.record_texture(entry, "overworld")
    if pokemon_texture == null:
        pokemon_texture = FARM_POKEMON_TEXTURES.get(species) as Texture2D
    if pokemon_texture == null:
        return
    var sprite := Sprite2D.new()
    sprite.texture = pokemon_texture
    sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
    sprite.position = _cell_center(cell)
    sprite.z_as_relative = false
    sprite.z_index = _depth_z(cell)
    _configure_overworld_sprite(sprite)
    var layer := _house_pokemon_layer() if indoors else get_node_or_null("LandmarkLayer") as Node2D
    if layer == null:
        return
    layer.add_child(sprite)
    preload("res://scripts/shiny_sparkles.gd").attach(sprite, entry)
    var ecology_id := String(entry.get("ecology_id", ""))
    if ecology_id.is_empty():
        ecology_id = "owned:%d" % next_deployed_id
        next_deployed_id += 1
    elif ecology_id.begins_with("owned:"):
        next_deployed_id = maxi(next_deployed_id, int(ecology_id.trim_prefix("owned:")) + 1)
    var stored := PokemonEcology.ensure_record(entry, rng, ecology_id)
    stored["cell"] = cell
    stored["x"] = cell.x
    stored["y"] = cell.y
    stored["behavior"] = PokemonData.info(species).get("overworld_behavior", {})
    stored["move_timer"] = float(stored.get("move_timer", _wild_move_delay(species)))
    stored["sprite"] = sprite
    deployed_pokemon[cell] = stored
    if indoors:
        sprite.visible = _house_pokemon_visible(stored)

func _cell_key(cell: Vector2i) -> String:
    return "%d,%d" % [cell.x, cell.y]

func _cell_from_key(key: String) -> Vector2i:
    var parts := key.split(",")
    if parts.size() != 2:
        return Vector2i(-1, -1)
    return Vector2i(int(parts[0]), int(parts[1]))

func _in_bounds(cell: Vector2i) -> bool:
    if exact_world != null:
        return exact_world.contains_cell(cell)
    return cell.x >= 0 and cell.y >= 0 and cell.x < map_w and cell.y < map_h

func _spawn_wild_pokemon() -> void:
    var candidates: Array[Vector2i] = []
    for y in range(3, map_h - 3):
        for x in range(3, map_w - 3):
            var cell := Vector2i(x, y)
            if not _is_walkable(cell) or Vector2(cell - spawn_cell).length() < 7.0:
                continue
            candidates.append(cell)
            # Tall-grass habitat receives extra source-style spawn weight.
            if tall_grass.has(cell):
                candidates.append(cell)
                candidates.append(cell)

    var target_count := maxi(6, int(float(map_w * map_h) / 300.0))
    var attempts := 0
    while wild_pokemon.size() < target_count and attempts < target_count * 80:
        attempts += 1
        if candidates.is_empty():
            break
        var cell := candidates[rng.randi_range(0, candidates.size() - 1)]
        if _wild_id_at_cell(cell) >= 0 or wild_eggs.has(cell):
            continue
        var biome := biome_at(cell)
        var species := _random_land_species_for_cell(cell)
        _add_wild_pokemon(species, _level_for_cell(cell), cell, biome)

func _ensure_overworld_pokemon_population() -> void:
    await _spawn_missing_overworld_population()
    if exact_world == null:
        return
    # Older saves persisted the roaming population before these source aliases
    # had visible textures. Restore only authored Alolan records absent from
    # that saved population; never invent a spawn or alter another species.
    var present := {"araichu": false, "aexeggutor": false}
    for raw_data in wild_pokemon.values():
        var species := String((raw_data as Dictionary).get("species", "")).to_lower()
        if species == "raichu_alolan":
            species = "araichu"
        elif species == "exeggutor_alolan":
            species = "aexeggutor"
        if present.has(species):
            present[species] = true
    for record in exact_world.pokemon_cell_records():
        var species := String(record.get("name", "")).to_lower()
        if not present.has(species) or bool(present[species]):
            continue
        var cell: Vector2i = record.get("cell", Vector2i.ZERO)
        if _wild_id_at_cell(cell) >= 0:
            continue
        var tile: SourceTile = exact_world.tile_at(cell)
        if tile == null:
            continue
        _add_wild_pokemon(
            species, int(record.get("level", 2)), cell,
            _source_biome_for_tile(tile), 0, record)
        present[species] = true

func _spawn_missing_overworld_population() -> void:
    if not wild_pokemon.is_empty():
        return
    if exact_world != null:
        var source_records := exact_world.pokemon_cell_records()
        await _spawn_exact_source_pokemon(source_records, true)
        await _spawn_extra_biome_pokemon(source_records, true)
        _spawn_exact_burrowed_pokemon(exact_world.burrowed_cell_records())
        return
    _spawn_wild_pokemon()

func _add_wild_pokemon(species:String,level:int,cell:Vector2i,home_biome:String,requested_id:int=0,source_record:Dictionary={},saved_state:Dictionary={})->void:
    var coordinator=get_parent().get("coop_game")
    var publish=requested_id==0 and is_instance_valid(coordinator) and coordinator.wild.source_spawn_enabled()
    if publish:
        requested_id=coordinator.wild.allocate_id()
        if requested_id==0:
            coordinator.end_session("ENCOUNTER IDENTIFIER COULD NOT BE CREATED.")
            return
    _create_wild_pokemon(species,level,cell,home_biome,requested_id,source_record,saved_state)
    if publish:coordinator.wild.source_added(requested_id)

func _create_wild_pokemon(
        species: String,
        level: int,
        cell: Vector2i,
        home_biome: String,
        requested_id: int = 0,
        source_record: Dictionary = {},
        saved_state: Dictionary = {}
    ) -> void:
    if not _in_bounds(cell) or _wild_id_at_cell(cell) >= 0:
        return
    # When the party has outgrown the authored route level, rerun the source
    # evolution checks against the adaptive encounter level. This preserves the
    # biome's species family while allowing the higher stages documented by
    # PokeWilds to appear for a sufficiently high-level party. Saved roaming
    # records keep their already-resolved species.
    if saved_state.is_empty() and not bool(source_record.get("is_trapping", false)) and exact_world != null:
        var adaptive_level := _effective_wild_level(level)
        if adaptive_level > level:
            # Keep adaptive evolution deterministic per world/cell and do not
            # consume World.rng, which other runtime ecology systems share.
            var evolution_rng := RandomNumberGenerator.new()
            evolution_rng.seed = (
                int(world_seed) * 1000003
                + cell.x * 73856093
                + cell.y * 19349663
                + adaptive_level * 83492791
                + species.hash()
            )
            var evolved_species := PokemonData.adaptive_source_evolution(
                species, adaptive_level, evolution_rng
            )
            var source_tile: SourceTile = exact_world.tile_at(cell)
            var source_route_name := ""
            var source_is_water := false
            if source_tile != null:
                source_is_water = source_tile.is_water
                if source_tile.route_belongs_to != null:
                    source_route_name = source_tile.route_belongs_to.name
            var route_allows_evolution := (
                source_route_name.is_empty()
                or PokemonData.source_route_species_allowed(
                    evolved_species, source_route_name, source_is_water
                )
            )
            if route_allows_evolution and \
                    PokemonData.texture(evolved_species, "overworld") != null:
                species = evolved_species
    var ecology_source := (
        saved_state.duplicate(true)
        if not saved_state.is_empty()
        else source_record.duplicate(true)
    )
    ecology_source["species"] = species.to_lower()
    ecology_source["level"] = level
    PokemonState.ensure_shiny(ecology_source, rng)
    var is_burrowed := bool(source_record.get("is_trapping", false))
    var texture: Texture2D = TRAPINCH_BURROW if is_burrowed else PokemonData.record_texture(ecology_source, "overworld")
    if texture == null:
        return
    var layer := get_node_or_null("WildPokemonLayer") as Node2D
    if layer == null:
        return

    # A dedicated server draws nothing: its wild Pokemon get no sprites (every
    # use of one checks is_instance_valid first), so no node, material or
    # tween per Pokemon or per step either.
    var drawn := not preload("res://scripts/dedicated_server.gd").active
    var sprite: Sprite2D = null
    if drawn:
        sprite = Sprite2D.new()
        sprite.texture = texture
        sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
        sprite.position = _cell_center(cell)
        if species.to_lower() in ["aexeggutor", "exeggutor_alolan"]:
            sprite.scale = Vector2.ONE
            sprite.offset = Vector2(0, -16)
        sprite.z_as_relative = false
        sprite.z_index = _depth_z(cell)
        if is_burrowed:
            sprite.hframes = 2
            sprite.vframes = 1
            sprite.frame = 0
            sprite.visible = false
        else:
            _configure_overworld_sprite(sprite)
            if species.to_lower() in ["aexeggutor", "exeggutor_alolan"]:
                sprite.hframes = 6
                sprite.vframes = 1
                sprite.frame = 4
                sprite.set_meta("alolan_exeggutor_walk", true)
        layer.add_child(sprite)
        preload("res://scripts/shiny_sparkles.gd").attach(sprite, ecology_source)

    var whirl_sprite: Sprite2D = null
    var sand_sprite: Sprite2D = null
    if is_burrowed and drawn:
        whirl_sprite = Sprite2D.new()
        whirl_sprite.texture = DESERT_WHIRLPOOL
        whirl_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
        whirl_sprite.hframes = 2
        whirl_sprite.position = _cell_center(cell)
        whirl_sprite.z_as_relative = false
        whirl_sprite.z_index = _depth_z(cell) - 1
        whirl_sprite.visible = false
        layer.add_child(whirl_sprite)
        sand_sprite = Sprite2D.new()
        sand_sprite.texture = DESERT_BURROW_SAND
        sand_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
        sand_sprite.hframes = 2
        sand_sprite.vframes = 2
        sand_sprite.frame = 0
        sand_sprite.position = _cell_center(cell) + Vector2(0, 6)
        sand_sprite.z_as_relative = false
        sand_sprite.z_index = _depth_z(cell) + 1
        sand_sprite.visible = false
        layer.add_child(sand_sprite)

    var wild_id := requested_id if requested_id > 0 else next_wild_id
    next_wild_id = maxi(next_wild_id, wild_id + 1)
    var stored := PokemonEcology.ensure_record(
        ecology_source, rng, "wild:%d" % wild_id
    )
    if saved_state.is_empty():
        # Keep the original two-minute repeat cycle, but stagger a new world's
        # first eligible egg so players can actually encounter wild eggs.
        stored["lay_egg_seconds"] = rng.randf_range(
            0.0, WILD_INITIAL_EGG_SECONDS
        )
    stored["id"] = wild_id
    stored["cell"] = cell
    stored["home_biome"] = home_biome
    if is_burrowed:
        sand_trap_ids[wild_id] = true
    stored["burrowed"] = is_burrowed
    stored["burrow_active"] = false
    stored["burrow_tick"] = 0
    stored["burrow_time"] = 0.0
    stored["burrow_whirl_tick"] = 0
    stored["move_timer"] = float(stored.get(
        "move_timer", _wild_move_delay(species, stored)
    ))
    stored["anim_phase"] = 0
    stored["behavior"] = PokemonData.info(species).get("overworld_behavior", {})
    stored["source_record"] = source_record.duplicate(true)
    stored["sprite"] = sprite
    stored["burrow_whirl_sprite"] = whirl_sprite
    stored["burrow_sand_sprite"] = sand_sprite
    # Source aggression affects how quickly a Pokemon becomes provoked; it is
    # not permission to force a battle on the first click or spawn frame.
    stored["aggro_player"] = bool(stored.get("aggro_player", source_record.get("aggressive", false)))
    stored["fed_until"] = float(stored.get("fed_until", 0.0))
    stored["flee_steps"] = int(stored.get("flee_steps", 0))
    wild_population.add(wild_id, stored)
    _sand_trap_leave(wild_id, stored, false)
    if is_burrowed: _sand_trap_join(wild_id, stored)
    _update_pokemon_water_visual(stored)

func _wild_move_delay(species: String, data: Dictionary = {}) -> float:
    if bool(data.get("burrowed", false)):
        return 999999.0
    var normalized := species.to_lower()
    if normalized in ["diglett", "dugtrio", "sharpedo"]:
        return rng.randf_range(0.35, 0.8)
    if bool(PokemonData.info(normalized).get("overworld_behavior", {}).get("lunge", false)):
        return rng.randf_range(0.35, 0.8)
    return rng.randf_range(WILD_MOVE_MIN, WILD_MOVE_MAX)

func _random_land_species_for_biome(biome: String) -> String:
    var species := "pidgey"
    for _attempt in range(12):
        species = PokemonData.random_species_for_biome(biome, rng)
        var behavior: Dictionary = PokemonData.info(species).get(
            "overworld_behavior", {}
        )
        if not bool(behavior.get("swim_only", false)):
            return species
    return species

func _random_land_species_for_cell(cell: Vector2i) -> String:
    var route_name := String(habitat_routes.get(cell, ""))
    var is_dungeon := SourceRouteData.is_dungeon(route_name)
    if exact_world != null:
        var source_route := exact_world.route_at(cell)
        route_name = "" if source_route == null else source_route.name
        is_dungeon = source_route != null and source_route.is_dungeon
    var allowed := SourceRouteData.allowed_pokemon(route_name)
    if not is_dungeon:
        allowed = _day_night_eligible_pokemon(allowed)
    if not allowed.is_empty():
        for _attempt in range(allowed.size() * 2):
            var species := String(allowed[rng.randi_range(0, allowed.size() - 1)])
            if PokemonData.texture(species, "overworld") != null:
                var behavior: Dictionary = PokemonData.info(species).get(
                    "overworld_behavior", {}
                )
                if not bool(behavior.get("swim_only", false)):
                    return species
    return _random_land_species_for_biome(biome_at(cell))

func _day_night_eligible_pokemon(source: Array) -> Array:
    var result: Array = []
    var excluded := (
        SourceRouteData.day_pokemon()
        if _is_night_time()
        else SourceRouteData.night_pokemon()
    )
    for raw_species in source:
        var species := String(raw_species).to_lower()
        if species not in excluded:
            result.append(raw_species)
    return result

func _is_tall_grass_cell(cell: Vector2i) -> bool:
    # Encounter grass and CUT-harvest grass are separate roles. Compatibility
    # snow/tundra grass is the harvestable GRASS source; other tall grass is
    # encounter habitat and must never disappear to CUT.
    if tall_grass.has(cell):
        return biome_at(cell) != "SNOW"
    if exact_world != null:
        # Same tests as below from the store's names and flags, without
        # building a tile object (only a tidal tile needs its biome).
        var store = exact_world.tiles
        var index: int = store.index_of(cell * TILE) if store is WorldTileStore else -1
        if index >= 0 and store.flags[index] & WorldTileStore.TIDAL == 0:
            if _source_tile_key(store.name_at(index)) == "grass1" or _source_tile_key(store.upper_at(index)) == "grass1":
                return true
            return store.flags[index] & WorldTileStore.GRASS != 0
        var tile := exact_world.tile_at(cell)
        if tile != null and tile.is_tidal and _source_biome_for_tile(tile) != "BEACH":
            return false
        # grass1 is the source's normal encounter grass. Check its authored
        # identity directly as well as the cached flag so a stale/rewritten
        # SourceTile flag can never make a visibly normal grass field inert.
        if _is_normal_encounter_grass(cell):
            return true
        # Grass remains encounter habitat until CUT actually replaces the tile.
        # Being harvestable must not silently disable its encounter role.
        return tile != null and tile.is_grass
    return false

func _is_source_grass_name(asset_name: String) -> bool:
    var key := asset_name.to_lower().trim_suffix(".png")
    # Logical grass assets include the biome-specific variants. Do not match
    # ledge_grass_* because those are structural ledges rather than grass tufts.
    return key.begins_with("grass") and not key.begins_with("ledge_grass")

func _is_cuttable_grass_cell(cell: Vector2i) -> bool:
    if tall_grass.has(cell):
        return true
    if exact_world == null:
        return false
    var tile: SourceTile = exact_world.tile_at(cell)
    if tile == null:
        return false
    return _is_source_grass_name(tile.name) or _is_source_grass_name(tile.name_upper)

func _cuttable_grass_replacement(tile: SourceTile, cell: Vector2i) -> Dictionary:
    var base := tile.name
    var upper := tile.name_upper
    var base_key := base.to_lower().trim_suffix(".png")
    var upper_key := upper.to_lower().trim_suffix(".png")
    # Grass authored as an upper sprite simply clears to its already-authored
    # floor, regardless of biome variant.
    if _is_source_grass_name(upper_key):
        return {"base":base, "upper":""}
    # Base-layer encounter grass is visually a tuft over a source-specific
    # floor. Prefer neighboring authored floor so CUT never paints a foreign
    # square into the biome.
    var contextual := _contextual_ground_name(cell, tile.biome)
    if not contextual.is_empty() and not _is_source_grass_name(contextual):
        return {"base":contextual, "upper":""}
    match base_key:
        "grass1", "grass2", "grass4", "grass_fairy1", "grass_fairy2", "grass_fairy3", "grass_safari", "grass_short2", "grass_short3", "grass_planted":
            return {"base":"green1", "upper":""}
        "grass3":
            return {"base":"snow1", "upper":""}
        "grass_sand1", "grass_sand2":
            return {"base":"sand1", "upper":""}
        "grass_sand3":
            return {"base":"desert4", "upper":""}
        "grass_graveyard1":
            return {"base":"green11", "upper":""}
        "grass_savanna1", "grass_savanna2":
            return {"base":"savanna1", "upper":""}
        "grass_desert1":
            return {"base":"desert4", "upper":""}
    # Do not leave an unknown authored grass tile visually unchanged after CUT.
    # Fall back to the native floor family for its biome rather than inventing
    # a foreign green square. This covers future/source grass variants while
    # preserving the explicit mappings above.
    match _source_biome_for_tile(tile):
        "SNOW":
            return {"base":"snow1", "upper":""}
        "BEACH":
            return {"base":"sand1", "upper":""}
        "DESERT":
            return {"base":"desert4", "upper":""}
        "SAVANNA":
            return {"base":"savanna1", "upper":""}
        "GRAVEYARD":
            return {"base":"green11", "upper":""}
        _:
            return {"base":"green1", "upper":""}

func _add_wild_egg(
        species: String, cell: Vector2i, egg_record: Dictionary = {},
        ignored_wild_id: int = -1
    ) -> void:
    if not bool(egg_record.get("dropped_party_egg", false)):
        cell = _resolve_egg_ground_cell(cell, ignored_wild_id)
    if cell.x <= -2147483648:
        return
    var layer := _house_pokemon_layer() if egg_record.has("house_door") else get_node_or_null("WildEggLayer") as Node2D
    if layer == null:
        return
    var sprite := Sprite2D.new()
    sprite.texture = POKEMON_EGG
    sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
    sprite.position = _cell_center(cell)
    sprite.z_as_relative = false
    sprite.z_index = _depth_z(cell)
    layer.add_child(sprite)
    var stored := egg_record.duplicate(true)
    stored["species"] = species.to_lower()
    stored["egg_species"] = String(stored.get("egg_species", species)).to_lower()
    stored["base_species"] = String(stored.get(
        "base_species", PokemonEcology.base_species_for(species)
    ))
    stored["egg_groups"] = stored.get(
        "egg_groups", PokemonData.info(species).get("egg_groups", ["EGG_NONE", "EGG_NONE"])
    )
    stored["is_egg"] = true
    stored["hatch_cycles"] = maxi(1, int(stored.get(
        "hatch_cycles", PokemonData.info(species).get("egg_cycles", 20)
    )))
    stored["hatch_steps"] = int(stored.get(
        "hatch_steps", int(stored["hatch_cycles"]) * PokemonEcology.EGG_STEP_INTERVAL
    ))
    stored["cell"] = cell
    stored["sprite"] = sprite
    if bool(stored.get("dropped_party_egg", false)) and egg_record.has("hatch_cycles"):
        stored["hatch_cycles"] = int(egg_record["hatch_cycles"])
    if stored.has("house_door"):
        sprite.visible = _house_pokemon_visible(stored)
    wild_eggs[cell] = stored

func _add_wild_egg_record(
        egg_record: Dictionary, cell: Vector2i, ignored_wild_id: int = -1
    ) -> void:
    _add_wild_egg(
        String(egg_record.get("species", "pidgey")), cell, egg_record,
        ignored_wild_id
    )

func _configure_overworld_sprite(sprite: Sprite2D) -> void:
    if sprite.texture == null:
        return
    var size := sprite.texture.get_size()
    if sprite.texture.has_meta("alolan_exeggutor_walk"):
        sprite.hframes = 6
        sprite.vframes = 1
        sprite.frame = 4
        sprite.offset = Vector2(0, -16)
        sprite.set_meta("alolan_exeggutor_walk", true)
    elif sprite.texture.has_meta("mega_gengar_walk"):
        sprite.hframes = 6
        sprite.vframes = 1
        sprite.frame = 4
        sprite.offset = sprite.texture.get_meta("overworld_feet_offset", Vector2.ZERO)
    elif int(size.y) == TILE and int(size.x) >= TILE * 6:
        sprite.hframes = int(size.x) / TILE
        sprite.vframes = 1
        sprite.frame = 4
    else:
        sprite.hframes = 1
        sprite.vframes = 1
        sprite.frame = 0

func _show_ecology_emote(sprite: Sprite2D, emote_name: String) -> void:
    if not is_instance_valid(sprite) or sprite.get_parent() == null:
        return
    # Original Pokemon.Emote/Player.Emote atlas order, 60 source ticks.
    # ?, bolt, sleep and fish are defined in the source atlas but have no
    # local gameplay call sites in the original 0.8.11 JAR.
    var frames := {"!": 0, "alert": 0, "?": 1, "question": 1,
        "happy": 2, "skull": 3, "angry": 3, "heart": 4,
        "bolt": 5, "sleep": 6, "fish": 7, "uncomfortable": 8,
        "sad": 8, "...": 9}
    if not frames.has(emote_name):
        return
    var previous := sprite.get_node_or_null("SourceEmote")
    if is_instance_valid(previous):
        sprite.remove_child(previous)
        previous.queue_free()
    var emote := Sprite2D.new()
    emote.name = "SourceEmote"
    emote.texture = preload("res://scripts/emote_style.gd").sheet()
    emote.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
    emote.hframes = 10
    emote.frame = int(frames[emote_name])
    emote.position = Vector2(0, -16)
    emote.z_index = 20
    sprite.add_child(emote)
    emote.add_to_group("styled_source_emotes")
    var tween := create_tween().bind_node(emote)
    tween.tween_interval(60.0 / 60.0)
    tween.tween_callback(emote.queue_free)

func _set_overworld_motion_frame(
        sprite: Sprite2D,
        direction: Vector2i,
        phase: int
    ) -> void:
    if sprite.has_meta("alolan_exeggutor_walk"):
        sprite.frame = (3 - phase) if direction.y < 0 else ((4 + phase) if direction.y > 0 else (1 - phase))
        sprite.flip_h = direction.x > 0
        return
    if sprite.hframes < 6:
        return
    sprite.flip_h = false
    if direction.y < 0:
        sprite.frame = 2 + phase
    elif direction.y > 0:
        sprite.frame = 4 + phase
    else:
        sprite.frame = phase
        sprite.flip_h = direction.x > 0

func _pokemon_has_field_move(pokemon_data: Dictionary, move_name: String) -> bool:
    var species := String(pokemon_data.get("species", "")).to_lower()
    return not species.is_empty() and FieldMoveData.field_moves_for(species).has(move_name)

func _flash_is_active() -> bool:
    # FLASH is passive while its Pokemon follows and remains active if that
    # same Pokemon is using another field move (RIDE/FLY/etc.).
    if active_field_move == "FLASH":
        return true
    if not active_field_pokemon.is_empty() and _pokemon_has_field_move(active_field_pokemon, "FLASH"):
        return true
    if not follower_pokemon.is_empty() and _pokemon_has_field_move(follower_pokemon, "FLASH"):
        return true
    return false

func _charm_suppresses(data: Dictionary) -> bool:
    if float(data.get("ball_charm_until", 0.0)) > world_elapsed_seconds:
        return true
    if active_field_move != "CHARM":
        return false
    return int(active_field_pokemon.get("level", 1)) >= _effective_wild_level(
        int(data.get("level", 1)))

## per-frame
func _update_wild_pokemon(delta: float) -> void:
    var coordinator=get_parent().get("coop_game")
    var online=is_instance_valid(coordinator) and coordinator.active
    if online and not coordinator.wild.authority():return
    if online:coordinator.wild.refresh_players()
    var directions = [
        Vector2i.ZERO, Vector2i.LEFT, Vector2i.RIGHT,
        Vector2i.UP, Vector2i.DOWN
    ]
    var player_cell = _player_cell()
    # Most wild Pokemon in a big world are nowhere near anyone. Settle that
    # with a few comparisons before the per-Pokemon work below, which for
    # hundreds of them every frame was a third of the host's frame time.
    # The zones are the same ones _wild_ecology_is_active tests.
    # Which Pokemon are inside a zone is worked out twice a second, not every
    # frame: with hundreds in the world, just asking each one cost 3-4 ms a
    # frame. One that wanders in or spawns is picked up within half a second.
    # The grid of wild_population looks only at the buckets the zones touch.
    var now_msec := Time.get_ticks_msec()
    if now_msec - _watched_wild_at >= 500:
        _watched_wild_at = now_msec
        var zones: Array = []
        if online:
            for watcher in coordinator.wild.players.values():
                zones.append(Vector3i(int(watcher.x), int(watcher.y), ECOLOGY_ACTIVE_RADIUS + 2))
        else:
            zones.append(Vector3i(player_cell.x, player_cell.y, ECOLOGY_ACTIVE_RADIUS + 2))
        for habitat_cell in deployed_pokemon.keys():
            zones.append(Vector3i(habitat_cell.x, habitat_cell.y, PokemonEcology.HABITAT_RADIUS + 2))
        _watched_wild_ids.clear()
        for slot in wild_population.slots_in(zones):
            _watched_wild_ids.append(wild_population.ids[slot])
    for raw_id in _watched_wild_ids.duplicate():
        var wild_id = int(raw_id)
        var data = wild_pokemon.get(wild_id)
        if data == null:
            continue
        if bool(data.get("ball_reserved", false)): continue
        if bool(data.get("burrowed", false)):
            continue
        var old_cell = data.get("cell", Vector2i.ZERO)
        # A dedicated server skips the frames nobody would see (coop_wild_runtime.gd).
        if online and coordinator.wild.idle_frame(data, delta): continue
        var local_target=true
        var target_player = null
        if online:
            target_player=coordinator.wild.target_for(data,old_cell)
            if target_player.is_empty():continue
            player_cell=Vector2i(target_player.x,target_player.y)
            local_target=target_player.actor==coordinator.session.actor
        if not _wild_ecology_is_active(old_cell, player_cell):
            continue
        var active_sprite = data.get("sprite") as Sprite2D
        if is_instance_valid(active_sprite):
            active_sprite.visible = true
            # z_index has no same-value check: writing it every frame for
            # every nearby Pokemon re-sent it to the renderer each time.
            var depth := _depth_z(old_cell)
            if active_sprite.z_index != depth: active_sprite.z_index = depth
        _update_pokemon_water_visual(data)
        var was_charmed = bool(data.get("charmed", false))
        var is_charmed = _charm_suppresses(data) if local_target else coordinator.wild.remote_charm(data,target_player)
        data["charmed"] = is_charmed
        if not online:_update_source_aggro_audio(data, old_cell, player_cell, delta)
        if is_charmed and not was_charmed:
            _show_ecology_emote(data.get("sprite") as Sprite2D, "heart")
        if bool(data.get("aggro_player", false)):
            data["source_aggro_emote_seconds"] = float(data.get("source_aggro_emote_seconds", 0.0)) - delta
            if float(data["source_aggro_emote_seconds"]) <= 0.0:
                _show_ecology_emote(data.get("sprite") as Sprite2D, "skull")
                data["source_aggro_emote_seconds"] = 241.0 / 60.0
        var move_timer := float(data.get("move_timer", 0.0)) - delta
        data["move_timer"] = move_timer
        # One that has just broken out of a ball bolts at once; it does not
        # first wait out whatever pause its wandering had left.
        var flee_until := float(data.get("ball_flee_until", 0.0))
        if world_elapsed_seconds < flee_until and float(_flee_started.get(wild_id, -1.0)) != flee_until:
            _flee_started[wild_id] = flee_until
        elif move_timer > 0.0:
            # data is wild_pokemon's own record: nothing to store back.
            continue
        data["move_timer"] = _wild_move_delay(String(data.get("species", "")), data)
        data = _try_create_parent_egg(data, old_cell, wild_id)
        var behavior = data.get("behavior", {})
        if bool(behavior.get("stationary", false)):
            wild_pokemon[wild_id] = data
            continue

        var player_delta = player_cell - old_cell
        var pursuing = bool(data.get("aggro_player", false)) and not is_charmed
        if world_elapsed_seconds < float(data.get("fed_until", 0.0)):
            var eating_sprite = data.get("sprite") as Sprite2D
            data["anim_phase"] = 1 - int(data.get("anim_phase", 0))
            if is_instance_valid(eating_sprite):
                _set_overworld_motion_frame(
                    eating_sprite, Vector2.DOWN, int(data["anim_phase"])
                )
            wild_pokemon[wild_id] = data
            continue
        if (
                pursuing
                and local_target
                and active_field_move not in ["SURF", "FLY"]
                and player_delta.length_squared() <= 1
                and not encounter_grace_active()
                and not _repel_blocks(int(data.get("level", 1)))
            ):
            _begin_wild_encounter(wild_id)
            return
        var direction = directions[rng.randi_range(0, directions.size() - 1)]
        # Timid species keep their distance; one that just broke out of a ball
        # runs from the player for a while, from further off.
        var scared = world_elapsed_seconds < float(data.get("ball_flee_until", 0.0))
        var fleeing = (bool(behavior.get("flee", false)) and player_delta.length_squared() <= 16) or \
            (scared and player_delta.length_squared() <= FLEE_RANGE_TILES * FLEE_RANGE_TILES)
        if fleeing:
            direction = _cardinal_direction(player_delta, true)
        elif pursuing and player_delta.length_squared() <= 64:
            direction = _cardinal_direction(player_delta, false)
        else:
            var friend_id = String(data.get("friend_id", ""))
            var friend_reunion = (
                not friend_id.is_empty()
                and float(data.get("friend_seconds", PokemonEcology.FRIEND_SECONDS)) <= 0.0
            )
            var companion_id = friend_id
            if friend_reunion:
                data["friend_seconds"] = PokemonEcology.FRIEND_SECONDS
                _show_friend_reunion(data, friend_id)
            elif companion_id.is_empty() or rng.randf() < 0.18:
                companion_id = String(data.get("mate_id", companion_id))
            if not companion_id.is_empty() and (friend_reunion or rng.randf() < 0.20):
                var companion_cell = _ecology_cell_by_id(companion_id)
                if companion_cell.x > -2147483648:
                    direction = _cardinal_direction(companion_cell - old_cell, false)
            elif rng.randf() < 0.12:
                var same_species_cell = _nearby_same_base_species_cell(data, old_cell)
                if same_species_cell.x > -2147483648:
                    direction = _cardinal_direction(same_species_cell - old_cell, false)
        if not pursuing and not fleeing:
            direction = _paired_wander_direction(data, old_cell, direction)
        if not scared:
            _flee_routes.erase(wild_id)
            _flee_started.erase(wild_id)
        elif fleeing:
            # Running from a failed catch: follow a route planned several steps
            # ahead (see _flee_direction), so walls, water and dead ends are
            # gone around rather than paced in front of.
            var runner = String(data.get("species", ""))
            var free_step = func(step: Vector2i) -> bool:
                return not (
                    step == player_cell or step == follower_cell or step == field_helper_cell
                    or (online and coordinator.wild.occupied(step))
                    or _wild_id_at_cell(step, wild_id) >= 0
                    or wild_eggs.has(step) or deployed_pokemon.has(step)
                )
            direction = _flee_direction(wild_id, runner, old_cell, player_cell, free_step)
        var target = old_cell + direction
        if bool(data.get("source_record", {}).get("rare_forest_mew", false)) and not preload("res://scripts/rare_forest_mew.gd").deep_forest(self,target):
            wild_pokemon[wild_id] = data
            continue
        var rare_species := String(data.get("source_record", {}).get("rare_legendary", ""))
        if not rare_species.is_empty() and not preload("res://scripts/rare_biome_legendaries.gd").habitat(self, rare_species, target):
            wild_pokemon[wild_id] = data
            continue
        if (
                direction == Vector2i.ZERO
                or not _pokemon_can_move_between(String(data.get("species", "")), old_cell, target)
                or target == player_cell
                or target == follower_cell
                or target == field_helper_cell
                or (online and coordinator.wild.occupied(target))
                or _wild_id_at_cell(target, wild_id) >= 0
                or wild_eggs.has(target)
                or deployed_pokemon.has(target)
            ):
            wild_pokemon[wild_id] = data
            continue

        var sprite = data.get("sprite") as Sprite2D
        var phase = 1 - int(data.get("anim_phase", 0))
        data["anim_phase"] = phase
        wild_population.move(wild_id, target)
        if online:coordinator.wild.mark_motion(wild_id)
        # The step's pace and facing are the Pokemon's own, sprite or not (a
        # dedicated server has none).
        var move_seconds = 0.20
        if bool(behavior.get("flee", false)) or (scared and fleeing):
            move_seconds = 16.0 / (2.0 * 60.0)
        elif pursuing:
            move_seconds = 16.0 / (1.5 * 60.0)
        data["ball_facing"] = Vector2(direction)
        if is_instance_valid(sprite):
            _set_overworld_motion_frame(sprite, direction, phase)
            sprite.z_index = _depth_z(target)
            var movement = create_tween()
            data["ball_move_tween"] = movement
            movement.tween_property(sprite, "position", _cell_center(target), move_seconds).set_trans(Tween.TRANS_LINEAR)
        if pursuing or fleeing:
            data["move_timer"] = move_seconds
        if bool(behavior.get("flee", false)):
            data["flee_steps"] = int(data.get("flee_steps", 0)) + 1
            if int(data["flee_steps"]) >= 3 and _is_tall_grass_cell(target):
                _remove_wild_pokemon(wild_id)
                continue
        wild_pokemon[wild_id] = data

func _show_friend_reunion(data: Dictionary, friend_id: String) -> void:
    _show_ecology_emote(data.get("sprite") as Sprite2D, "happy")
    var friend := _ecology_record_by_id(friend_id)
    if not friend.is_empty():
        _show_ecology_emote(friend.get("sprite") as Sprite2D, "happy")

func _nearby_same_base_species_cell(
        data: Dictionary, center: Vector2i
    ) -> Vector2i:
    var base_species := String(data.get("base_species", ""))
    var own_id := int(data.get("id", -1))
    for raw_id in wild_population.ids_near(center, PokemonEcology.HABITAT_RADIUS):
        if int(raw_id) == own_id:
            continue
        var candidate: Dictionary = wild_pokemon[raw_id]
        if String(candidate.get("base_species", "")) == base_species:
            return candidate.get("cell", Vector2i.ZERO)
    return Vector2i(-2147483648, -2147483648)

func _remove_wild_pokemon(wild_id:int)->void:
    var coordinator=get_parent().get("coop_game")
    if is_instance_valid(coordinator) and coordinator.active and coordinator.wild.authority() and not coordinator.wild.applying:
        coordinator.wild.mark_motion(wild_id)
    if not wild_pokemon.has(wild_id):
        return
    sand_trap_ids.erase(wild_id)
    _sand_trap_leave(wild_id, wild_pokemon[wild_id])
    var data: Dictionary = wild_pokemon[wild_id]
    if bool(data.get("burrowed", false)) and exact_world != null:
        var tile := exact_world.tile_at(Vector2i(data.get("cell", Vector2i.ZERO)))
        if tile != null:
            tile.items.erase("trapinch")
    var sprite: Sprite2D = data.get("sprite") as Sprite2D
    if is_instance_valid(sprite):
        sprite.queue_free()
    var whirl_sprite: Sprite2D = data.get("burrow_whirl_sprite") as Sprite2D
    if is_instance_valid(whirl_sprite):
        whirl_sprite.queue_free()
    var sand_sprite: Sprite2D = data.get("burrow_sand_sprite") as Sprite2D
    if is_instance_valid(sand_sprite):
        sand_sprite.queue_free()
    wild_population.remove(wild_id)

func _cardinal_direction(delta: Vector2i, away: bool) -> Vector2i:
    var direction := Vector2i.ZERO
    if absi(delta.x) >= absi(delta.y):
        direction = Vector2i(signi(delta.x), 0)
    else:
        direction = Vector2i(0, signi(delta.y))
    return -direction if away else direction

## The first wild Pokemon on the cell in wild_pokemon's order, -1 if none.
func _wild_id_at_cell(cell: Vector2i, ignored_id: int = -1) -> int:
    return wild_population.id_at(cell, ignored_id)

func _attack_wild_egg(cell:Vector2i)->void:
    var coordinator=get_parent().get("coop_game")
    if is_instance_valid(coordinator) and coordinator.active:
        coordinator.population_battles.begin(cell,"wild_eggs")
        return
    if not wild_eggs.has(cell):
        return
    var data: Dictionary = wild_eggs[cell]
    var species := String(data.get("species", "pidgey")).to_lower()
    var member := data.duplicate(true)
    member.erase("sprite")
    member.erase("cell")
    member["species"] = species
    member["level"] = maxi(1, int(member.get("level", 5)))
    var context := {
        "id":"attack_egg_%d_%d" % [cell.x, cell.y],
        "kind":"attack_egg",
        "intro":"The EGG contains %s!" % PokemonData.battle_display_name(species),
        "can_run":true, "can_catch":false,
        "cell_x":cell.x, "cell_y":cell.y,
        "party":[member]
    }
    pending_battle_context = context.duplicate(true)
    battle_requested.emit(context)

func _attack_deployed_pokemon(cell:Vector2i)->void:
    var coordinator=get_parent().get("coop_game")
    if is_instance_valid(coordinator) and coordinator.active:
        coordinator.population_battles.begin(cell,"deployed_pokemon")
        return
    if not deployed_pokemon.has(cell):
        return
    var data: Dictionary = deployed_pokemon[cell]
    var member := data.duplicate(true)
    for runtime_key in ["sprite", "cell", "x", "y", "move_timer", "anim_phase", "behavior"]:
        member.erase(runtime_key)
    var species := String(member.get("species", "pidgey")).to_lower()
    member["species"] = species
    member["level"] = maxi(1, int(member.get("level", 5)))
    var context := {
        "id":"attack_deployed_%d_%d" % [cell.x, cell.y],
        "kind":"attack_deployed",
        "intro":"You challenged your own %s!" % PokemonData.battle_display_name(species),
        "can_run":true, "can_catch":true,
        "cell_x":cell.x, "cell_y":cell.y,
        "party":[member]
    }
    pending_battle_context = context.duplicate(true)
    battle_requested.emit(context)

func _begin_wild_encounter(wild_id:int,field_attack:bool=false)->void:
    var coordinator=get_parent().get("coop_game")
    if is_instance_valid(coordinator) and coordinator.active and not coordinator.wild.applying:
        coordinator.wild.begin_encounter(wild_id,field_attack)
        return
    if bool(wild_pokemon.get(wild_id, {}).get("ball_reserved", false)): return
    # Java Pokemon pursuit/contact encounters explicitly exclude FLY.
    if active_field_move == "FLY" or not wild_pokemon.has(wild_id):
        return
    var data: Dictionary = wild_pokemon[wild_id]
    pending_encounter_record = _serializable_ecology_record(
        data, Vector2i(data.get("cell", Vector2i.ZERO))
    )
    if field_attack:
        pending_encounter_record["field_attack"] = true
    var source_record := data.get("source_record", {}) as Dictionary
    for property in source_record.keys():
        if not pending_encounter_record.has(property):
            pending_encounter_record[property] = source_record[property]
    _remove_wild_pokemon(wild_id)
    encounter_count += 1
    if not String(source_record.get("rare_legendary", "")).is_empty():
        var context := preload("res://scripts/rare_biome_legendaries.gd").context(String(data.species), pending_encounter_record)
        pending_battle_context = context.duplicate(true)
        battle_requested.emit(context)
        return
    if bool(source_record.get("rare_forest_mew",false)):
        var context := {"id":"rare_forest_mew","kind":"wild","fixed_level":true,
            "can_run":true,"can_catch":true,"party":[{"species":"mew","level":70}]}
        pending_battle_context = context.duplicate(true)
        battle_requested.emit(context)
        return
    if field_attack:
        # ATTACK starts the battle on the player's terms. Keep enough of the
        # overworld record to put the Pokemon back, calm, if the player runs.
        var context := {
            "id":"field_attack_wild_%d" % wild_id,
            "kind":"wild",
            "can_run":true,
            "can_catch":true,
            "field_attack":true,
            "field_attack_record":pending_encounter_record.duplicate(true),
            "party":[{
                "species":String(data.get("species", "pidgey")),
                "level":int(data.get("level", 2))
            }]
        }
        pending_battle_context = context.duplicate(true)
        battle_requested.emit(context)
        return
    encounter_requested.emit(
        String(data.get("species", "pidgey")),
        int(data.get("level", 2))
    )

func begin_encounter_grace(seconds: float = ENCOUNTER_GRACE_SECONDS) -> void:
    encounter_grace_remaining = maxf(encounter_grace_remaining, seconds)

func encounter_grace_active() -> bool:
    return encounter_grace_remaining > 0.0

func take_pending_encounter_record() -> Dictionary:
    var result := pending_encounter_record.duplicate(true)
    pending_encounter_record.clear()
    return result

func take_pending_egg_record() -> Dictionary:
    var result := pending_egg_record.duplicate(true)
    pending_egg_record.clear()
    return result

func confirm_wild_egg_pickup(cell: Vector2i) -> void:
    _collect_wild_egg(cell)

func _collect_wild_egg(cell:Vector2i)->void:
    var coordinator=get_parent().get("coop_game")
    if is_instance_valid(coordinator) and coordinator.active:
        coordinator.population.recall(cell,"wild_eggs")
        return
    if not wild_eggs.has(cell):
        return
    var data: Dictionary = wild_eggs[cell]
    if bool(data.get("dropped_party_egg", false)) and not get_parent()._can_receive_overworld_pokemon():
        world_message.emit("Your party and storage are full.")
        return
    var species := String(data.get("species", "pidgey"))
    var sprite: Sprite2D = data.get("sprite") as Sprite2D
    if is_instance_valid(sprite):
        sprite.queue_free()
    pending_egg_record = data.duplicate(true)
    pending_egg_record.erase("sprite")
    pending_egg_record.erase("cell")
    wild_eggs.erase(cell)
    if bool(data.get("dropped_party_egg", false)):
        egg_collected.emit(species)
        return
    var anger_count := 0
    for raw_id in wild_population.ids_near(cell, PokemonEcology.PARENT_ALERT_RADIUS):
        var wild_id := int(raw_id)
        var pokemon: Dictionary = wild_pokemon[wild_id]
        if bool(pokemon.get("burrowed", false)) or not PokemonEcology.is_egg_parent_match(pokemon, data):
            continue
        pokemon["aggro_player"] = true
        pokemon["warned"] = true
        wild_pokemon[wild_id] = pokemon
        _show_ecology_emote(pokemon.get("sprite") as Sprite2D, "alert")
        anger_count += 1
    egg_collected.emit(species)

func _trigger_burrowed_pokemon(wild_id: int) -> void:
    if active_field_move == "FLY" or encounter_grace_active() or not wild_pokemon.has(wild_id):
        return
    var data: Dictionary = wild_pokemon[wild_id]
    if bool(data.get("burrowed", false)):
        _sand_trap_leave(wild_id, data)
        data["burrow_active"] = true

## Hidden idle sand traps (150 in a big world) share clocks instead of each
## advancing its own burrow_time / burrow_whirl_tick every frame. A clock is
## [time, steps, traps on it] and advances exactly as a trap's own values
## did, so traps whose time is equal share one (at load, all of them). A
## trap on a clock: sand_trap_clock_of[id] = [clock id, the clock's steps
## and the trap's whirl tick when it joined]. Its dictionary keeps the values
## it joined with; _sand_trap_write gives the current ones (saves, co-op).
var sand_trap_clocks := {}
var sand_trap_clock_of := {}
var sand_trap_next_clock := 0

func _sand_trap_write(at: Array, into: Dictionary) -> void:
    var clock: Array = sand_trap_clocks[at[0]]
    into["burrow_time"] = clock[0]
    into["burrow_whirl_tick"] = (int(at[2]) + int(clock[1]) - int(at[1])) % 80

func _sand_trap_join(wild_id: int, data: Dictionary) -> void:
    var time := float(data.get("burrow_time", 0.0))
    var clock_id := -1
    for id in sand_trap_clocks:
        if sand_trap_clocks[id][0] == time:
            clock_id = id
            break
    if clock_id < 0:
        clock_id = sand_trap_next_clock
        sand_trap_next_clock += 1
        sand_trap_clocks[clock_id] = [time, 0, 0]
    var clock: Array = sand_trap_clocks[clock_id]
    clock[2] += 1
    sand_trap_clock_of[wild_id] = [clock_id, clock[1], int(data.get("burrow_whirl_tick", 0))]

## Takes a trap off its clock; with write, its dictionary gets the clock's
## current values (without: its own values are already the current ones).
func _sand_trap_leave(wild_id: int, data: Dictionary, write := true) -> void:
    if not sand_trap_clock_of.has(wild_id): return
    var at: Array = sand_trap_clock_of[wild_id]
    if write: _sand_trap_write(at, data)
    sand_trap_clock_of.erase(wild_id)
    var clock: Array = sand_trap_clocks[at[0]]
    clock[2] -= 1
    if clock[2] <= 0: sand_trap_clocks.erase(at[0])

## A co-op record was merged into a trap: its values are the current ones.
func _sand_trap_merged(wild_id: int) -> void:
    if not sand_trap_ids.has(wild_id) or not wild_pokemon.has(wild_id): return
    var data: Dictionary = wild_pokemon[wild_id]
    _sand_trap_leave(wild_id, data, false)
    if bool(data.get("burrowed", false)) and not bool(data.get("burrow_active", false)):
        _sand_trap_join(wild_id, data)

## per-frame
func _update_sand_traps(delta: float) -> void:
    if active_area_id != "OVERWORLD":
        return
    # Neither changes inside the loop; asked once, not once per trap (150 in a
    # big world, every frame).
    var player_cell := _player_cell()
    var flying := active_field_move == "FLY"
    var ticks := delta * 60.0
    # Traps on a clock are passed over unless the player stands on them; the
    # rest (active ones) run the per-trap code, in the same order as before.
    var under = wild_population.ids_at(player_cell)
    var ran: Array = []
    if sand_trap_clock_of.size() < sand_trap_ids.size() or under != null:
        var keys := sand_trap_ids.keys()
        for index in keys.size():
            var wild_id = keys[index]
            var clocked := sand_trap_clock_of.has(wild_id)
            if clocked and wild_id != under and not (under is Array and under.has(wild_id)): continue
            var data: Dictionary = wild_pokemon[wild_id]
            if clocked: _sand_trap_leave(wild_id, data)
            ran.append(wild_id)
            if not _update_sand_trap(wild_id, data, player_cell, flying, ticks):
                # An encounter began. As before, the traps before this one
                # moved on this frame and the ones after it did not.
                for earlier in keys.slice(0, index):
                    if sand_trap_clock_of.has(earlier):
                        var other: Dictionary = wild_pokemon[earlier]
                        _sand_trap_leave(earlier, other)
                        _update_sand_trap(earlier, other, player_cell, flying, ticks)
                        _sand_trap_join(earlier, other)
                for raw_id in ran:
                    var trap: Dictionary = wild_pokemon.get(raw_id, {})
                    if not trap.is_empty() and raw_id != wild_id and bool(trap.get("burrowed", false)) and not bool(trap.get("burrow_active", false)): _sand_trap_join(raw_id, trap)
                return
    for clock in sand_trap_clocks.values():
        var remainder: float = clock[0] + ticks
        var steps := int(remainder)
        clock[0] = remainder - steps
        clock[1] += steps
    for wild_id in ran:
        var data: Dictionary = wild_pokemon.get(wild_id, {})
        if not data.is_empty() and bool(data.get("burrowed", false)) and not bool(data.get("burrow_active", false)): _sand_trap_join(wild_id, data)

## One trap's frame, as every trap had it before the shared clocks. False
## when it began an encounter (the frame's trap updates stop there).
func _update_sand_trap(wild_id: int, data: Dictionary, player_cell: Vector2i, flying: bool, ticks: float) -> bool:
    if true:
        if not bool(data.get("burrowed", false)):
            return true
        var cell: Vector2i = data["cell"]
        var on_trap := player_cell == cell and not flying
        if on_trap and not encounter_grace_active() and not _repel_blocks(int(data.get("level", 22))):
            _trigger_burrowed_pokemon(wild_id)
        var remainder := float(data.get("burrow_time", 0.0)) + ticks
        var steps := int(remainder)
        data["burrow_time"] = remainder - steps
        if not bool(data.get("burrow_active", false)):
            # Hidden idle traps only need their source phase clock advanced.
            # Avoid rewriting three invisible sprites for every trap each frame.
            data["burrow_whirl_tick"] = (int(data.get("burrow_whirl_tick", 0)) + steps) % 80
            return true
        for step in range(steps):
            data["burrow_whirl_tick"] = (int(data.get("burrow_whirl_tick", 0)) + 1) % 80
            if not bool(data.get("burrow_active", false)):
                continue
            var tick := int(data.get("burrow_tick", 0))
            if tick < 66 or not on_trap:
                tick += 1
            data["burrow_tick"] = tick
            if (tick < 50 or (tick >= 120 and tick < 156)) and tick % 8 == 0:
                play_source_sound("move_object")
            if tick == 34 and get_parent().has_method("_play_pokemon_cry"):
                get_parent().call("_play_pokemon_cry", data)
            if tick >= 152:
                data["burrow_active"] = false
                data["burrow_tick"] = 0
            if tick >= 63 and on_trap and not encounter_grace_active():
                _begin_wild_encounter(wild_id)
                return false
        var tick := int(data.get("burrow_tick", 0))
        var height := clampi((tick - 50) * 4, 0, 12)
        if tick >= 141:
            height = maxi(0, 12 - (tick - 140))
        var sprite := data.get("sprite") as Sprite2D
        var whirl := data.get("burrow_whirl_sprite") as Sprite2D
        var sand := data.get("burrow_sand_sprite") as Sprite2D
        if is_instance_valid(sprite):
            sprite.visible = height > 0
            sprite.hframes = 1
            sprite.region_enabled = true
            var frame := 0 if tick < 52 else 1
            if tick >= 120:
                frame = 0 if tick % 8 < 4 else 1
            sprite.region_rect = Rect2(frame * 16, 0, 16, height)
            sprite.position = _cell_center(cell) + Vector2(0, 2.0 - float(height) / 2.0)
        if is_instance_valid(whirl):
            whirl.visible = tick > 0
            whirl.frame = 0 if int(data.get("burrow_whirl_tick", 0)) < 40 else 1
        if is_instance_valid(sand):
            sand.visible = tick >= 50 and tick < 66
            sand.frame = 0 if tick < 58 else 1
            sand.position = _cell_center(cell) + Vector2(0, -6)
    return true

func _level_for_cell(cell: Vector2i) -> int:
    if exact_world != null:
        var route := exact_world.route_at(cell)
        return clampi(2 if route == null else route.level, 2, 100)
    if source_tiles.has(cell):
        return clampi(int((source_tiles[cell] as Dictionary).get("level", 2)), 2, 100)
    var distance := Vector2(cell - spawn_cell).length()
    var maximum := maxf(1.0, Vector2(float(map_w), float(map_h)).length())
    return clampi(2 + int(round(distance / maximum * 22.0)), 2, 24)

func _adaptive_grass_encounter_species(
        species: String, cell: Vector2i, source_level: int
    ) -> String:
    if species.is_empty() or exact_world == null:
        return species
    var encounter_level: int = _effective_wild_level(source_level)
    if encounter_level <= source_level:
        return species
    var evolved: String = PokemonData.adaptive_source_evolution(
        species, encounter_level, rng
    )
    if evolved == species:
        return species
    var tile: SourceTile = exact_world.tile_at(cell)
    var route_name: String = ""
    var source_is_water: bool = false
    if tile != null:
        source_is_water = tile.is_water
        if tile.route_belongs_to != null:
            route_name = tile.route_belongs_to.name
    if not route_name.is_empty() and not PokemonData.source_route_species_allowed(
            evolved, route_name, source_is_water):
        return species
    if PokemonData.texture(evolved, "front") == null:
        return species
    return evolved

func _emit_source_grass_encounter(species: String, level: int, fixed_level: bool = false) -> void:
    # PlayerStanding: replace only rolled walking encounters, not fishing/actors.
    if preload("res://scripts/source_unown_event.gd").active(self):
        battle_requested.emit(preload("res://scripts/source_unown_event.gd").encounter(self, true))
        return
    if fixed_level:
        battle_requested.emit({"id":"mansion_grass", "kind":"wild",
            "fixed_level":true, "can_run":true, "can_catch":true,
            "party":[{"species":species,"level":level}]})
        return
    encounter_requested.emit(species, level)

func _request_random_encounter() -> void:
    var cell := _player_cell()
    var species := _random_land_species_for_cell(cell)
    if species.is_empty():
        return
    var level := _level_for_cell(cell)
    species = _adaptive_grass_encounter_species(species, cell, level)
    _emit_source_grass_encounter(species, level)

func _request_source_area_encounter() -> void:
    if active_area_id == "HOUSE":
        return
    var source_tile := _source_interior_tile_at_world_cell(_player_cell())
    if SourceMineRuntime.is_mine_tile(source_tile):
        # Java PlayerStanding: route + 0..2, encounter floors only, no
        # dungeon evolution escalation or party-level scaling in this mine.
        if source_tile.is_grass:
            var pool := SourceRouteData.allowed_pokemon("ruins1_inner")
            var species := String(pool[rng.randi_range(0, pool.size() - 1)])
            battle_requested.emit({"id":"mine_grass", "kind":"wild",
                "fixed_level":true, "can_run":true, "can_catch":true,
                "party":[{"species":species,"level":source_tile.route_belongs_to.level + rng.randi_range(0,2)}]})
        return
    if source_tile != null and source_tile.route_belongs_to != null and source_tile.route_belongs_to.name == "pkmnmansion1":
        if source_tile.is_grass:
            var encounter := SourceMansionRuntime.encounter(source_tile.route_belongs_to.level, rng)
            _emit_source_grass_encounter(encounter.species, encounter.level, true)
        return
    var route_name := ""
    var base_level := 12
    if active_area_id.begins_with("MANSION"):
        # Source requires an encounter floor with a route; rugs/props do not roll.
        return
    elif active_area_id.begins_with("RUINS"):
        return # No source encounter tile means no mine encounter.
    elif active_area_id == "REGI_CHAMBER":
        route_name = "regi_cave1"
        base_level = 35
    elif active_area_id.begins_with("INTERIOR_"):
        var route_data := _active_source_interior_route()
        route_name = String(route_data.get("name", ""))
        base_level = int(route_data.get("level", 12))
    if route_name.is_empty():
        return
    var allowed := SourceRouteData.allowed_pokemon(route_name)
    if allowed.is_empty():
        return
    for _attempt in range(allowed.size() * 2):
        var species := String(allowed[rng.randi_range(0, allowed.size() - 1)])
        if PokemonData.texture(species, "front") != null:
            var last_part := active_area_id.get_slice(
                "_", active_area_id.get_slice_count("_") - 1
            )
            var floor_number := int(last_part) if last_part.is_valid_int() else 0
            _emit_source_grass_encounter(species, clampi(base_level + floor_number * 3, 2, 100))
            return

func _active_source_interior_route() -> Dictionary:
    return interiors.active_source_interior_route()

var house_transition_active := false

func _enter_source_area(area_id: String, return_cell: Vector2i) -> void:
    interiors.enter_source_area(area_id, return_cell)

func _enter_source_area_now(area_id: String, return_cell: Vector2i) -> void:
    interiors.enter_source_area_now(area_id, return_cell)

func _leave_source_area() -> void:
    interiors.leave_source_area()

func _use_interior_interactable(action: String, action_cell: Vector2i = Vector2i.ZERO) -> void:
    var coordinator=get_parent().get("coop_game")
    if action.begins_with("ITEM:") and is_instance_valid(coordinator) and coordinator.active and not coordinator.building.collecting:
        coordinator.building.collect_item(action,action_cell)
        return
    if action.begins_with("ITEM:") and _collect_source_dig_item(action_cell): return
    if action.begins_with("MINE_POKEMON:"):
        SourceMineRuntime.begin_battle(self, action.trim_prefix("MINE_POKEMON:"))
        return
    if action == "MANSION_SWITCH":
        if _facing_cell() == Vector2i.UP:
            structure_action.emit("MANSION_SWITCH:%d:%d" % [action_cell.x, action_cell.y])
        return
    if action.begins_with("SPECIAL:"):
        _request_event_battle(action.trim_prefix("SPECIAL:"), action_cell)
        return
    if action.begins_with("TRAINER:"):
        var trainer_id := action.trim_prefix("TRAINER:")
        var defeated := event_progress.get("trainer_defeated", {}) as Dictionary
        if bool(defeated.get(trainer_id, false)):
            var old_context := (event_npcs.get(trainer_id, {}) as Dictionary).get("context", {}) as Dictionary
            world_message.emit(String(old_context.get("victory_text", "We already battled.")))
            return
        var npc := event_npcs.get(trainer_id, {}) as Dictionary
        var trainer_context := (npc.get("context", {}) as Dictionary).duplicate(true)
        if not trainer_context.is_empty():
            trainer_context["cell_x"] = action_cell.x
            trainer_context["cell_y"] = action_cell.y
            pending_battle_context = trainer_context.duplicate(true)
            battle_requested.emit(trainer_context)
        return
    if action.begins_with("TRAINER_TIP:"):
        var tip_parts := action.split(":")
        if tip_parts.size() >= 2:
            var tip_index := clampi(int(tip_parts[1]), 0, SourceEventData.TRAINER_TIPS.size() - 1)
            var tip := String(SourceEventData.TRAINER_TIPS[tip_index])
            if preload("res://scripts/source_unown_event.gd").read_sign(self, action_cell):
                environment_system.start_unown_music()
                unown_message.emit(tip.to_upper())
            else:
                trainer_tip_message.emit("TRAINER TIPS! " + tip)
        return
    if action == "GRAVESTONE":
        world_message.emit("The text is too faded to make out...")
        if rng.randi_range(0, 127) == 0:
            _show_mystery_npc(action_cell)
        return
    if action == "ODD_KEYSTONE":
        var keystone_amounts := event_progress.get("keystone_life_force", {}) as Dictionary
        var amount := int(keystone_amounts.get(_cell_key(action_cell), 0))
        structure_action.emit("ODD_KEYSTONE:%d:%d:%d" % [
            action_cell.x, action_cell.y, maxi(0, 107 - amount)
        ])
        return
    if action == "POKE_DOLL":
        item_collected.emit("POKE DOLL")
        world_message.emit("Found a POKE DOLL!")
        _clear_event_cell(action_cell, "pokedoll")
        return
    if action == "REGI_RIGHT":
        SourceRegiRuntime.right_half_action(self, action_cell)
        return
    if action == "REGIGIGAS_GATE":
        var statue := _source_interior_tile_at_world_cell(action_cell)
        if statue != null and statue.name == "cave1_regi1":
            return
        var caught_regis := event_progress.get("regis_caught", []) as Array
        if not SourceEventData.REGI_SPECIES.all(func(s): return caught_regis.has(s)):
            world_message.emit("...")
        else:
            _request_event_battle("regigigas", action_cell)
        return
    if action.begins_with("ITEM:"):
        var item_parts := action.split(":")
        if item_parts.size() == 3:
            var item_name := String(item_parts[1]).to_upper()
            var amount := maxi(1, int(item_parts[2]))
            for _item_index in range(amount):
                item_collected.emit(item_name)
            if item_name != "POKE BALL":
                world_message.emit("You found %s x%d!" % [item_name, amount])
            interior_interactables.erase(action_cell)
            source_interior_mutations[_cell_key(action_cell)] = {"kind": "COLLECTED"}
            SourceMansionRuntime.clear_collected_item(self, action_cell)
            SourceMineRuntime.clear_collected_item(self, action_cell)
            var item_sprite := source_interior_upper_sprites.get(action_cell) as Sprite2D
            if is_instance_valid(item_sprite):
                item_sprite.queue_free()
            source_interior_upper_sprites.erase(action_cell)
            if exact_world != null and exact_world.contains_cell(action_cell):
                var exterior_item_tile := exact_world.tile_at(action_cell)
                if exterior_item_tile != null:
                    exterior_item_tile.has_item = ""
                    exterior_item_tile.has_item_amount = 0
                    exterior_item_tile.set_names(exterior_item_tile.name, "")
                    _refresh_exact_pickup_cell(action_cell)
        return
    if action.begins_with("LEGENDARY:"):
        var parts := action.split(":")
        if parts.size() == 3:
            var legacy_context := SourceEventData.event_spec(String(parts[1]))
            if legacy_context.is_empty():
                encounter_requested.emit(String(parts[1]), int(parts[2]))
            else:
                _request_event_battle(String(parts[1]), action_cell)
        return
    if action.begins_with("WILD:"):
        var wild_parts := action.split(":")
        if wild_parts.size() == 3:
            encounter_requested.emit(String(wild_parts[1]), int(wild_parts[2]))
        return
    if action == "FOSSIL_MACHINE":
        if not bool(event_progress.get("fossil_machine_powered", false)) and active_field_move != "POWER":
            world_message.emit("The machine needs an Electric POKEMON using POWER.")
            return
        if not bool(event_progress.get("fossil_machine_powered", false)):
            event_progress["fossil_machine_powered"] = true
            world_message.emit("Electricity surges through the FOSSIL REVIVER!")
        crafting_station_requested.emit("FOSSIL REVIVER")
        return
    if action == "REGI_FORGE":
        active_regi_pedestal_cell = action_cell
        crafting_station_requested.emit("REGI FORGE")
        return
    if action.begins_with("MANSION_LOCK:"):
        structure_action.emit(action)
        return
    if action.begins_with("EXIT_AREA:"):
        _leave_source_area()
        return
    if action.begins_with("GOTO_SOURCE_LAYER:"):
        var transition_parts := action.split(":")
        if transition_parts.size() != 4:
            return
        var target_layer := int(transition_parts[1])
        var source_cell := Vector2i(
            int(transition_parts[2]), int(transition_parts[3])
        )
        var destination := String(source_layer_area_ids.get(target_layer, ""))
        if destination.is_empty():
            world_message.emit("The way forward is blocked.")
            return
        var destination_plan: Dictionary = {}
        for candidate in generated_source_interior_plans:
            if int(candidate.get("layer_index", -1)) == target_layer:
                destination_plan = candidate
                break
        var source_to_local := destination_plan.get("source_to_local", {}) as Dictionary
        if not source_to_local.has(source_cell):
            var closest_entry := Vector2i(2147483647, 2147483647)
            var closest_distance := 2147483647
            for raw_entry in destination_plan.get("entries", []) as Array:
                var entry_source := Vector2i(raw_entry)
                var distance := absi(entry_source.x - source_cell.x) + absi(entry_source.y - source_cell.y)
                if distance < closest_distance and source_to_local.has(entry_source):
                    closest_entry = entry_source
                    closest_distance = distance
            if closest_entry.x == 2147483647:
                world_message.emit("The entrance does not connect to this floor.")
                return
            source_cell = closest_entry
        var outside_return: Vector2i = (_player_cell() if active_area_id == "OVERWORLD"
            else area_return_cells.get("%s_RETURN" % active_area_id, spawn_cell))
        if source_area_layers.has(active_area_id):
            (source_area_layers[active_area_id] as CanvasItem).visible = false
        active_area_id = destination
        _set_exact_overworld_streaming(false)
        if source_area_layers.has(destination):
            (source_area_layers[destination] as CanvasItem).visible = true
        area_return_cells["%s_RETURN" % destination] = outside_return
        var destination_origin: Vector2i = source_area_origins[destination]
        var destination_cell := destination_origin + Vector2i(source_to_local[source_cell])
        player.position = _cell_center(destination_cell)
        last_player_cell = destination_cell
        _sync_follower_to_player()
        _configure_camera()
        return
    if action.begins_with("GOTO_AREA:"):
        var destination := action.trim_prefix("GOTO_AREA:")
        if not source_area_entries.has(destination):
            world_message.emit("The way forward is blocked.")
            return
        var outside_return: Vector2i = (_player_cell() if active_area_id == "OVERWORLD"
            else area_return_cells.get("%s_RETURN" % active_area_id, spawn_cell))
        if source_area_layers.has(active_area_id):
            (source_area_layers[active_area_id] as CanvasItem).visible = false
        active_area_id = destination
        _set_exact_overworld_streaming(false)
        if source_area_layers.has(destination):
            (source_area_layers[destination] as CanvasItem).visible = true
        area_return_cells["%s_RETURN" % destination] = outside_return
        var entry: Vector2i = source_area_entries[destination]
        player.position = _cell_center(entry)
        last_player_cell = entry
        _sync_follower_to_player()
        _configure_camera()
        world_message.emit("You entered %s." % destination.replace("_", " "))
        return
    match action:
        "EXIT_HOUSE", "EXIT_CAVE":
            if action == "EXIT_HOUSE" and built_house_exit_doors.has(action_cell):
                var exterior: Vector2i = built_house_exit_doors[action_cell]
                area_return_cells["HOUSE_RETURN"] = exterior + _house_door_outward(exterior)
            _leave_source_area()
        "BED":
            structure_action.emit("BED")
        "TABLE":
            crafting_station_requested.emit("WORK TABLE")
        "PLANT":
            world_message.emit("A healthy house plant is growing here.")

func _request_event_battle(
        event_id: String,
        action_cell: Vector2i,
        overrides: Dictionary = {}
    ) -> void:
    var completed := event_progress.get("completed", {}) as Dictionary
    if bool(completed.get(event_id, false)):
        world_message.emit("The presence here has faded.")
        return
    var context := SourceEventData.event_spec(event_id)
    if context.is_empty():
        return
    if preload("res://scripts/biome_megas.gd").is_mega(event_id):
        context = preload("res://scripts/biome_megas.gd").context(self, event_id, context)
    context.merge(overrides, true)
    context["cell_x"] = action_cell.x
    context["cell_y"] = action_cell.y
    pending_battle_context = context.duplicate(true)
    battle_requested.emit(context)

func complete_battle_event(result: Dictionary) -> void:
    preload("res://scripts/source_unown_event.gd").complete(self, result)
    var context := result.get("context", {}) as Dictionary
    if context.has("mine_pokemon_id"):
        SourceMineRuntime.complete(self, String(context.mine_pokemon_id), result)
        return
    if context.is_empty():
        return
    var event_id := String(context.get("id", ""))
    var kind := String(context.get("kind", "wild"))
    var outcome := String(result.get("outcome", ""))
    var cell := Vector2i(
        int(context.get("cell_x", -2147483648)),
        int(context.get("cell_y", -2147483648))
    )
    if kind == "attack_egg":
        # Running leaves the egg untouched. Defeating it destroys the egg.
        if outcome == "defeated" and wild_eggs.has(cell):
            var egg_data: Dictionary = wild_eggs[cell]
            var egg_sprite: Sprite2D = egg_data.get("sprite") as Sprite2D
            if is_instance_valid(egg_sprite):
                egg_sprite.queue_free()
            wild_eggs.erase(cell)
            world_message.emit("The EGG was destroyed.")
        return
    if kind == "attack_deployed":
        if outcome in ["captured", "defeated"] and deployed_pokemon.has(cell):
            var deployed: Dictionary = deployed_pokemon[cell]
            var deployed_sprite: Sprite2D = deployed.get("sprite") as Sprite2D
            if is_instance_valid(deployed_sprite):
                deployed_sprite.queue_free()
            deployed_pokemon.erase(cell)
            blocked.erase(cell)
        return
    if kind == "trainer":
        if outcome == "victory":
            var defeated := event_progress.get("trainer_defeated", {}) as Dictionary
            defeated[event_id] = true
            event_progress["trainer_defeated"] = defeated
            world_message.emit(String(context.get("victory_text", "Trainer defeated!")))
        return
    if kind == "wild":
        if outcome == "defeated" and preload("res://scripts/rare_biome_legendaries.gd").HABITATS.has(String(context.get("rare_legendary",""))):
            material_collected.emit("ANCIENTPOWDER", rng.randi_range(3,5))
        if outcome == "captured":
            preload("res://scripts/rare_biome_legendaries.gd").captured(self, String(context.get("rare_legendary", "")))
        if outcome == "ran" and (context.has("overworld_record") or context.has("field_attack_record")):
            var restored = context.get("overworld_record", context.get("field_attack_record", {}))
            if typeof(restored) == TYPE_DICTIONARY:
                var record := (restored as Dictionary).duplicate(true)
                var restore_cell := Vector2i(
                    int(record.get("x", -1)), int(record.get("y", -1))
                )
                if _in_bounds(restore_cell):
                    # Preserve the overworld identity and pursuit state after escaping.
                    if bool(context.get("field_attack", false)):
                        record["aggro_player"] = false
                        record["warned"] = false
                        record["charmed"] = false
                    _add_wild_pokemon(
                        String(record.get("species", "pidgey")),
                        int(record.get("level", 2)),
                        restore_cell,
                        String(record.get("home_biome", biome_at(restore_cell))),
                        int(record.get("id", 0)),
                        record.get("source_record", {}) as Dictionary,
                        record
                    )
        return
    if kind in ["ghost", "fossil"]:
        return
    if outcome not in ["captured", "defeated"]:
        return
    if bool(context.get("regi", false)):
        if outcome != "captured":
            world_message.emit("%s returned to the pedestal." % event_id.to_upper())
            return
        _complete_regi_capture(event_id.to_upper(), cell)
        return
    if event_id == "mewtwo" and outcome == "defeated":
        event_progress["mewtwo_defeated_day"] = _world_day_index()
        source_interior_mutations[_cell_key(cell)] = {
            "kind": "EVENT_COOLDOWN", "event_id": event_id,
            "day": _world_day_index()
        }
        _hide_event_cell(cell)
        world_message.emit("MEWTWO fled. It may return after recovering.")
        return
    var should_clear := (
        outcome == "captured" and bool(context.get("clear_on_capture", true))
    ) or (
        outcome == "defeated" and bool(context.get("clear_on_defeat", true))
    )
    if should_clear:
        var completed := event_progress.get("completed", {}) as Dictionary
        completed[event_id] = true
        event_progress["completed"] = completed
        _clear_event_cell(cell, event_id)

func _complete_regi_capture(species: String, cell: Vector2i) -> void:
    var caught := event_progress.get("regis_caught", []) as Array
    if not caught.has(species):
        caught.append(species)
    event_progress["regis_caught"] = caught
    world_message.emit(String(SourceEventData.REGI_LORE.get(species, "%s was caught." % species)))
    _hide_event_cell(cell)
    if caught.size() < SourceEventData.REGI_SPECIES.size():
        source_interior_mutations[_cell_key(cell)] = {"kind": "REGI_PEDESTAL"}
        _restore_regi_pedestal(cell)
        world_message.emit("A voice whispers: I desire more...")
    else:
        source_interior_mutations[_cell_key(cell)] = {
            "kind": "EVENT_CLEARED", "event_id": "regi_pedestal"
        }
        world_message.emit("My work is complete... REGIGIGAS awakened!")
    SourceRegiRuntime.sync(self)

func _clear_event_cell(cell: Vector2i, event_id: String) -> void:
    if preload("res://scripts/biome_megas.gd").is_mega(event_id):
        preload("res://scripts/biome_megas.gd").captured(self, event_id, cell)
        return
    if event_id == "mega_gengar" and event_progress.has(SourceForestBoss.SAVE_KEY):
        _hide_event_cell(cell)
        return
    source_interior_mutations[_cell_key(cell)] = {
        "kind": "EVENT_CLEARED", "event_id": event_id
    }
    _hide_event_cell(cell)
    if exact_world != null and exact_world.contains_cell(cell):
        var tile := exact_world.tile_at(cell)
        if tile != null:
            tile.set_names(tile.name, "")
            tile.has_item = ""
            tile.has_item_amount = 0
            _refresh_exact_streams()

func _hide_event_cell(cell: Vector2i) -> void:
    interior_interactables.erase(cell)
    var sprite := source_interior_upper_sprites.get(cell) as Sprite2D
    if is_instance_valid(sprite):
        sprite.queue_free()
    source_interior_upper_sprites.erase(cell)
    var collision := source_event_collisions.get(cell) as CollisionBox
    if is_instance_valid(collision):
        collision.queue_free()
    source_event_collisions.erase(cell)
    blocked.erase(cell)

func _restore_regi_pedestal(cell: Vector2i) -> void:
    interior_interactables[cell] = "REGI_FORGE"
    blocked[cell] = true
    var body := get_node_or_null("InteriorLayer/SourceInteriorCollision") as CollisionBody
    if body != null:
        var collision := _add_landmark_collision(body, cell.x, cell.y)
        source_event_collisions[cell] = collision
    var area_layer := _source_area_layer_at(cell)
    var texture := SourceWorldData.texture_for("cave1_regipedistal1")
    if area_layer != null and texture != null:
        source_interior_upper_sprites[cell] = _add_source_sprite(
            area_layer, texture, cell, 16
        )

func add_keystone_life_force(cell: Vector2i, available: int) -> int:
    if available <= 0:
        return 0
    var amounts := event_progress.get("keystone_life_force", {}) as Dictionary
    var key := _cell_key(cell)
    var old_amount := clampi(int(amounts.get(key, 0)), 0, 107)
    var used := mini(available, 107 - old_amount)
    var new_amount := old_amount + used
    amounts[key] = new_amount
    event_progress["keystone_life_force"] = amounts
    source_interior_mutations[key] = {
        "kind": "KEYSTONE", "amount": new_amount
    }
    if new_amount >= 107:
        interior_interactables[cell] = "SPECIAL:spiritomb"
        var tile := exact_world.tile_at(cell) if exact_world != null else null
        if tile != null:
            tile.set_names(tile.name, "spiritomb")
            _refresh_exact_streams()
        _show_event_pokemon_sprite(cell, "spiritomb")
        world_message.emit("Yulaaah! The spirits formed SPIRITOMB!")
    else:
        world_message.emit("The spirits entered the keystone... %d remain." % (107 - new_amount))
    return used

func _show_event_pokemon_sprite(cell: Vector2i, species: String) -> void:
    var old_sprite := source_interior_upper_sprites.get(cell) as Sprite2D
    if is_instance_valid(old_sprite):
        old_sprite.queue_free()
    var layer := get_node_or_null("LandmarkLayer") as Node2D
    var texture := PokemonData.texture(species, "overworld")
    if layer == null or texture == null:
        return
    var sprite := Sprite2D.new()
    sprite.texture = texture
    sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
    sprite.position = _cell_center(cell)
    sprite.z_as_relative = false
    sprite.z_index = _depth_z(cell, 18)
    _configure_overworld_sprite(sprite)
    layer.add_child(sprite)
    source_interior_upper_sprites[cell] = sprite

func _show_mystery_npc(gravestone_cell: Vector2i) -> void:
    var layer := get_node_or_null("LandmarkLayer") as Node2D
    if layer == null:
        return
    var target := gravestone_cell + Vector2i.DOWN * 2
    if not _is_walkable(target):
        target = gravestone_cell + Vector2i.RIGHT
    var sprite := Sprite2D.new()
    sprite.texture = SOURCE_MYSTERY_NPC
    sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
    sprite.position = _cell_center(target)
    sprite.z_as_relative = false
    sprite.z_index = _depth_z(target, 18)
    layer.add_child(sprite)
    world_message.emit("For a moment, someone is standing beyond the grave...")
    var tween := create_tween()
    tween.tween_interval(1.25)
    tween.tween_property(sprite, "modulate:a", 0.0, 0.4)
    tween.tween_callback(sprite.queue_free)

func _refresh_biome_dig_sites(spread: bool = false) -> void:
    if exact_world == null:
        return
    var day := _world_day_index()
    var identity := exact_world
    var slice_started := Time.get_ticks_usec()
    # Remove only untouched dynamic sites from an older day. A site that was
    # dug already became a normal TILE_NAMES mutation and is never restored.
    for raw_key in source_interior_mutations.keys().duplicate():
        if spread and Time.get_ticks_usec()-slice_started>=_daily_slice_usec():
            await get_tree().process_frame
            if exact_world!=identity or _world_day_index()!=day: return
            slice_started=Time.get_ticks_usec()
        var key := String(raw_key)
        var mutation := source_interior_mutations.get(key, {}) as Dictionary
        if String(mutation.get("kind", "")) != "BIOME_DIG_SITE":
            continue
        if int(mutation.get("day", -1)) == day:
            continue
        var old_cell := _cell_from_key(key)
        var old_tile := exact_world.tile_at(old_cell)
        if old_tile != null and "_cracked" in old_tile.name_upper.to_lower():
            old_tile.set_names(
                String(mutation.get("base", old_tile.name)),
                String(mutation.get("original_upper", ""))
            )
        source_interior_mutations.erase(key)

    var candidates: Dictionary = {}
    for crack_name in FieldMoveData.CRACKED_LOOT:
        candidates[crack_name] = []
    var store: WorldTileStore = exact_world.tiles
    var cell_flags := store.flags
    var cell_uppers := store.upper_ids
    var cell_names := store.name_ids
    var cell_biomes := store.biome_ids
    # dig_site_name reads only the name and biome: once per pair, not per cell
    # (a proxy per cell made this scan ~1 s of every load).
    var crack_of := {}
    var ruled_out := WorldTileStore.WATER | WorldTileStore.LAVA | WorldTileStore.SOLID | WorldTileStore.LEDGE | WorldTileStore.GRASS
    for index in cell_flags.size():
        if spread and Time.get_ticks_usec()-slice_started>=_daily_slice_usec():
            await get_tree().process_frame
            if exact_world!=identity or _world_day_index()!=day: return
            slice_started=Time.get_ticks_usec()
            # A dig or a pickup may have changed tiles meanwhile.
            cell_flags = store.flags
            cell_uppers = store.upper_ids
            cell_names = store.name_ids
            cell_biomes = store.biome_ids
        if not cell_flags[index] & WorldTileStore.PRESENT or cell_flags[index] & ruled_out or cell_uppers[index] != 0:
            continue
        var pair: int = (cell_names[index] << 24) | cell_biomes[index]
        if not crack_of.has(pair): crack_of[pair] = FieldMoveData.dig_site_name(store.cursor(index))
        var crack: String = crack_of[pair]
        if not candidates.has(crack):
            continue
        var cell := Vector2i(index % store.width, index / store.width) + store.origin
        if built_structures.has(cell) or landmarks.has(cell) or \
                resource_objects.has(cell) or blocked.has(cell):
            continue
        (candidates[crack] as Array).append(cell)

    var daily_rng := RandomNumberGenerator.new()
    daily_rng.seed = int(world_seed) * 1000003 + day * 9176 + 0xB10E
    for biome_name in candidates.keys():
        var cells := candidates[biome_name] as Array
        if cells.is_empty():
            continue
        # Keep sites sparse but reliably present in every eligible biome.
        var target_count := clampi(int(ceil(float(cells.size()) / 350.0)), 2, 12)
        target_count = mini(target_count, cells.size())
        for _index in range(target_count):
            if cells.is_empty():
                break
            if spread and Time.get_ticks_usec()-slice_started>=_daily_slice_usec():
                await get_tree().process_frame
                if exact_world!=identity or _world_day_index()!=day: return
                slice_started=Time.get_ticks_usec()
            var pick := daily_rng.randi_range(0, cells.size() - 1)
            var cell := cells.pop_at(pick) as Vector2i
            var key := _cell_key(cell)
            if source_interior_mutations.has(key):
                continue
            var tile := exact_world.tile_at(cell)
            if tile == null:
                continue
            var original_upper := tile.name_upper
            var original_base := tile.name
            var crack := FieldMoveData.dig_site_name(tile)
            tile.set_names(original_base, crack)
            source_interior_mutations[key] = {
                "kind":"BIOME_DIG_SITE", "day":day,
                "base":original_base, "original_upper":original_upper, "crack":crack
            }
    # Spread, the layers take the day's cells a few at a time.
    if spread: _queue_exact_refresh()
    else: _refresh_exact_tile_streams()

## Whole-map daily scans: 1 ms a frame in play, most of the frame behind the
## loading screen (at 1 ms a frame they added ~6 s to every load).
func _daily_slice_usec() -> int:
    return 13000 if restoring_saved_tiles or not gameplay_enabled else 1000

func _world_day_index() -> int:
    return int(floor(world_elapsed_seconds / WORLD_DAY_SECONDS))

## The world's time of day in minutes (0-1439), as a CLOCK reads it: the day
## starts at dawn and the 24 hours run evenly over one day-night cycle.
func clock_minutes() -> int:
    return int(floor(fmod(world_elapsed_seconds, WORLD_DAY_SECONDS) / WORLD_DAY_SECONDS * 24.0 * 60.0))

func _refresh_sand_traps(spread: bool = false) -> void:
    if exact_world == null or get_node_or_null("WildPokemonLayer") == null:
        return
    var day := _world_day_index()
    var identity := exact_world
    var slice_started := Time.get_ticks_usec()
    if int(event_progress.get("sand_trap_refresh_day", -1)) == day:
        return
    event_progress["sand_trap_refresh_day"] = day
    # CycleDayNight scans x=-4..4 and y=-4..3 around authored desert2 markers.
    # Keep source's maximum three traps and 32/256 chance per eligible cell.
    for index in exact_world.tiles.with_name(["desert2_trapinch_spawn"]):
        if spread and Time.get_ticks_usec()-slice_started>=_daily_slice_usec():
            await get_tree().process_frame
            if exact_world!=identity or _world_day_index()!=day: return
            slice_started=Time.get_ticks_usec()
        var marker: SourceTile = exact_world.tiles.proxy(index)
        if marker.name != "desert2_trapinch_spawn":
            continue
        var center := SourceWorldData.pixel_to_cell(marker.position)
        var found := 0
        var candidates: Array[Vector2i] = []
        for yy in range(-4, 4):
            for xx in range(-4, 5):
                var cell := center + Vector2i(xx, yy)
                var tile := exact_world.tile_at(cell)
                if tile == null or not "desert2" in tile.name:
                    continue
                var id := _wild_id_at_cell(cell)
                if id >= 0 and bool(wild_pokemon[id].get("burrowed", false)):
                    found += 1
                elif id < 0 and not built_structures.has(cell) and not deployed_pokemon.has(cell) and not wild_eggs.has(cell):
                    candidates.append(cell)
        for cell in candidates:
            if found >= 3:
                break
            if rng.randi_range(0, 255) >= 32:
                continue
            _add_wild_pokemon("trapinch", 22, cell, "DESERT", 0, {"name":"trapinch", "is_trapping":true, "level":22, "position":cell * TILE})
            if _wild_id_at_cell(cell) >= 0:
                exact_world.tile_at(cell).items["trapinch"] = 1
                found += 1

func _refresh_daily_events(spread: bool = false) -> void:
    var identity := exact_world
    await _refresh_sand_traps(spread)
    if exact_world!=identity: return
    await _refresh_biome_dig_sites(spread)
    if exact_world!=identity: return
    var defeated_day := int(event_progress.get("mewtwo_defeated_day", -1))
    if defeated_day < 0 or _world_day_index() <= defeated_day:
        return
    event_progress["mewtwo_defeated_day"] = -1
    for raw_key in source_interior_mutations.keys():
        var mutation := source_interior_mutations[raw_key] as Dictionary
        if String(mutation.get("kind", "")) != "EVENT_COOLDOWN":
            continue
        var cell := _cell_from_key(String(raw_key))
        source_interior_mutations.erase(raw_key)
        interior_interactables[cell] = "SPECIAL:mewtwo"
        blocked[cell] = true
        var area_layer := _source_area_layer_at(cell)
        var texture := PokemonData.texture("mewtwo", "overworld")
        if area_layer != null and texture != null:
            source_interior_upper_sprites[cell] = _add_source_sprite(
                area_layer, texture, cell, 18
            )
        var body := get_node_or_null("InteriorLayer/SourceInteriorCollision") as CollisionBody
        if body != null:
            source_event_collisions[cell] = _add_landmark_collision(
                body, cell.x, cell.y
            )
        world_message.emit("A psychic presence has returned to the mansion.")

func complete_regi_forge(species_name: String) -> bool:
    if active_regi_pedestal_cell.x == -2147483648:
        return false
    var species := species_name.strip_edges().to_upper()
    if species not in ["REGISTEEL", "REGIROCK", "REGICE", "REGIDRAGO", "REGIELEKI"]:
        return false
    var caught := event_progress.get("regis_caught", []) as Array
    if caught.has(species):
        world_message.emit("%s has already answered the pedestal." % species)
        return false
    var cell := active_regi_pedestal_cell
    var mutation := {
        "kind": "REGI", "species": species
    }
    source_interior_mutations[_cell_key(cell)] = mutation
    _apply_source_interior_mutation(cell, mutation)
    SourceRegiRuntime.sync(self)
    active_regi_pedestal_cell = Vector2i(-2147483648, -2147483648)
    _show_ecology_emote(player.sprite, "!")
    world_message.emit("%s awakened on the pedestal!" % species)
    return true

func can_awaken_regi(species_name: String) -> bool:
    var species := species_name.strip_edges().to_upper()
    return (
        active_regi_pedestal_cell.x != -2147483648
        and species in SourceEventData.REGI_SPECIES
        and not (event_progress.get("regis_caught", []) as Array).has(species)
    )

func unlock_mansion_door(cell: Vector2i) -> bool:
    if exact_world == null:
        return false
    var tile := exact_world.tile_at(cell)
    if tile == null or tile.name_upper != "pkmnmansion_ext_locked":
        return false
    tile.set_names("pkmnmansion_ext_door", "")
    interior_interactables[cell] = "GOTO_AREA:MANSION_0"
    source_interior_mutations[_cell_key(cell)] = {"kind": "MANSION_DOOR"}
    _refresh_exact_streams()
    return true

func _apply_source_interior_mutation(cell: Vector2i, mutation: Dictionary) -> void:
    if mutation.get("kind")=="BERRY_AGITATED":
        _finish_shared_agitated_tree(cell,mutation.duplicate(true))
        return
    _apply_mutation_by_kind(cell, mutation)
    if String(mutation.get("kind", "")) == "TILE_NAMES" and mutation.has("dig_item") and exact_world != null:
        var tile: SourceTile = exact_world.tile_at(cell)
        if tile != null:
            tile.has_item = String(mutation.dig_item)
            tile.has_item_amount = int(mutation.get("dig_item_amount", 0))
            if not tile.has_item.is_empty():
                interior_interactables[cell] = "ITEM:%s:%d" % [tile.has_item, tile.has_item_amount]
            elif String(interior_interactables.get(cell, "")).begins_with("ITEM:"):
                interior_interactables.erase(cell)
    if String(mutation.get("kind", "")) == "TILE_NAMES" and exact_world != null:
        var tile: SourceTile = exact_world.tile_at(cell)
        if tile != null and mutation.has("dig_biome"):
            tile.biome = String(mutation.dig_biome)
            var route_name := String(mutation.get("dig_route", ""))
            tile.route_belongs_to = null if route_name.is_empty() else SourceRoute.new(
                route_name, int(mutation.get("dig_route_level", 22)))
            if bool(mutation.get("dig_mountain_cleared", false)):
                tile.is_bottom_mtn_layer = false
                blocked.erase(cell)
        elif tile != null and tile.name in ["green_woodedlake", "green_deepforest"]:
            # These were palette identifiers saved as ground by older DIG code.
            # Their intended soil is unambiguous; preserve any dug upper/item.
            var saved_upper := tile.name_upper
            FieldMoveData.apply_dig_terrain(tile,
                "WOODED LAKE" if tile.name == "green_woodedlake" else "DEEP FOREST")
            tile.set_names(tile.name, saved_upper)
            _save_source_dig_tile(cell)
        # Reconnect edited ground and remove pre-edit shoreline on saved water.
        _connect_source_dig_holes(cell)
        _recoastify_exact_cells([cell])

func _apply_mutation_by_kind(cell: Vector2i, mutation: Dictionary) -> void:
    var kind := String(mutation.get("kind", ""))
    if kind == "BIOME_DIG_SITE":
        if exact_world != null and exact_world.contains_cell(cell):
            var dig_tile := exact_world.tile_at(cell)
            if dig_tile != null:
                dig_tile.set_names(
                    String(mutation.get("base", dig_tile.name)),
                    String(mutation.get("crack", FieldMoveData.dig_site_name(
                        dig_tile, _source_biome_for_tile(dig_tile))))
                )
                _refresh_exact_streams()
        return
    if kind == "TILE_NAMES":
        if exact_world != null and exact_world.contains_cell(cell):
            var changed_tile: SourceTile = exact_world.tile_at(cell)
            if changed_tile != null:
                changed_tile.set_names(
                    String(mutation.get("base", changed_tile.name)),
                    String(mutation.get("upper", changed_tile.name_upper)))
                _unblock_ground(cell)
                _refresh_exact_streams()
        return
    if kind == "BERRY_EMPTY":
        if exact_world != null and exact_world.contains_cell(cell):
            var berry_tile := exact_world.tile_at(cell)
            if berry_tile != null:
                berry_tile.set_names(
                    berry_tile.name,
                    String(mutation.get("upper", berry_tile.name_upper)).replace(
                        "_full", "_empty")
                )
                _refresh_exact_streams()
        return
    if kind == "MANSION_GATE":
        SourceMansionRuntime.set_gate(self, cell, String(mutation.get("name", "")))
        return
    if kind == "COLLECTED":
        SourceMansionRuntime.clear_collected_item(self, cell)
        SourceMineRuntime.clear_collected_item(self, cell)
        interior_interactables.erase(cell)
        var collected_sprite := source_interior_upper_sprites.get(cell) as Sprite2D
        if is_instance_valid(collected_sprite):
            collected_sprite.queue_free()
        source_interior_upper_sprites.erase(cell)
        if exact_world != null and exact_world.contains_cell(cell):
            var collected_tile := exact_world.tile_at(cell)
            if collected_tile != null:
                collected_tile.has_item = ""
                collected_tile.has_item_amount = 0
                collected_tile.set_names(collected_tile.name, "")
                _refresh_exact_streams()
        return
    if kind == "MANSION_DOOR":
        var locked_tile := exact_world.tile_at(cell) if exact_world != null else null
        if locked_tile != null:
            locked_tile.set_names("pkmnmansion_ext_door", "")
            interior_interactables[cell] = "GOTO_AREA:MANSION_0"
            _refresh_exact_streams()
        return
    if kind == "EVENT_CLEARED":
        _hide_event_cell(cell)
        if exact_world != null and exact_world.contains_cell(cell):
            var cleared_tile := exact_world.tile_at(cell)
            if cleared_tile != null:
                cleared_tile.set_names(cleared_tile.name, "")
                cleared_tile.has_item = ""
                cleared_tile.has_item_amount = 0
                _refresh_exact_streams()
        return
    if kind == "EVENT_COOLDOWN":
        _hide_event_cell(cell)
        return
    if kind == "REGI_PEDESTAL":
        _hide_event_cell(cell)
        _restore_regi_pedestal(cell)
        return
    if kind == "KEYSTONE":
        var amount := int(mutation.get("amount", 0))
        if amount >= 107:
            interior_interactables[cell] = "SPECIAL:spiritomb"
            var keystone_tile := exact_world.tile_at(cell) if exact_world != null else null
            if keystone_tile != null:
                keystone_tile.set_names(keystone_tile.name, "spiritomb")
                _refresh_exact_streams()
            _show_event_pokemon_sprite(cell, "spiritomb")
        else:
            interior_interactables[cell] = "ODD_KEYSTONE"
        return
    if kind != "REGI":
        return
    var species := String(mutation.get("species", "")).to_upper()
    interior_interactables[cell] = "SPECIAL:%s" % species.to_lower()
    var old_sprite := source_interior_upper_sprites.get(cell) as Sprite2D
    if is_instance_valid(old_sprite):
        old_sprite.queue_free()
    var area_layer := _source_area_layer_at(cell)
    var regi_texture := _regi_overworld_texture(species)
    if area_layer != null and regi_texture != null:
        source_interior_upper_sprites[cell] = _add_source_sprite(
            area_layer, regi_texture, cell, 18
        )

func _source_area_layer_at(cell: Vector2i) -> Node2D:
    return interiors.source_area_layer_at(cell)

func _regi_overworld_texture(species: String) -> Texture2D:
    var region_x: int = {
        "REGIDRAGO": 16, "REGIELEKI": 32, "REGICE": 48,
        "REGIROCK": 64, "REGISTEEL": 80
    }.get(species, -1)
    if region_x < 0:
        return null
    var sheet := load("res://assets/source_0_8_11/tiles/cave1/overworld2.png") as Texture2D
    if sheet == null:
        return null
    var atlas := AtlasTexture.new()
    atlas.atlas = sheet
    atlas.region = Rect2(region_x, 0, 16, 16)
    return atlas

func use_escape_rope() -> bool:
    if active_area_id != "OVERWORLD":
        _leave_source_area()
        world_message.emit("The ESCAPE ROPE returned you outside.")
        return true
    var origin: Vector2i = _player_cell()
    var nearest: Vector2i = Vector2i(-1, -1)
    var nearest_distance: int = 1000000
    var directions: Array[Vector2i] = [
        Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN
    ]
    if exact_world != null:
        for radius in range(1, 513):
            for offset in range(-radius, radius + 1):
                for cell in [
                        origin + Vector2i(offset, -radius),
                        origin + Vector2i(offset, radius),
                        origin + Vector2i(-radius, offset),
                        origin + Vector2i(radius, offset)
                    ]:
                    if not _is_walkable(cell):
                        continue
                    for direction in directions:
                        if terrain_kind_at(cell + direction) == 0:
                            player.position = _cell_center(cell)
                            _sync_follower_to_player()
                            world_message.emit("The ESCAPE ROPE took you to a nearby shore.")
                            return true
        world_message.emit("There is no reachable shore nearby.")
        return false
    for y in range(map_h):
        for x in range(map_w):
            var cell: Vector2i = Vector2i(x, y)
            if not _is_walkable(cell):
                continue
            var touches_water := false
            for direction in directions:
                var neighbor: Vector2i = cell + direction
                if _in_bounds(neighbor) and int(terrain[neighbor.y][neighbor.x]) == 0:
                    touches_water = true
                    break
            if not touches_water:
                continue
            var distance: int = absi(cell.x - origin.x) + absi(cell.y - origin.y)
            if distance < nearest_distance:
                nearest = cell
                nearest_distance = distance
    if nearest.x < 0:
        world_message.emit("There is no reachable shore nearby.")
        return false
    player.position = _cell_center(nearest)
    _sync_follower_to_player()
    world_message.emit("The ESCAPE ROPE took you to a nearby shore.")
    return true

func _house_sleep_cell_clear(cell: Vector2i) -> bool:
    if not _is_built_house_floor_cell(cell) or deployed_pokemon.has(cell) or wild_eggs.has(cell):
        return false
    if String(built_structures.get(cell + Vector2i.DOWN, {}).get("name", "")) == "BED":
        return false
    var piece := String(built_structures.get(cell, {}).get("name", ""))
    return piece.is_empty() or piece == "FLOOR" or piece.begins_with("CARPET ")

func begin_sleeping_bag(rest_texture: Texture2D = null) -> bool:
    if not active_field_move.is_empty():
        world_message.emit("You cannot set up the SLEEPING BAG while using a Field Move.")
        return false
    if sleeping_bag_sprite != null and is_instance_valid(sleeping_bag_sprite):
        return false

    var context := environment_context()
    if active_area_id != "HOUSE" and bool(context.get("dungeon", false)):
        world_message.emit("It is too dangerous to sleep here.")
        return false

    var cell := _player_cell()
    var right := cell + Vector2i.RIGHT
    var has_room := _house_sleep_cell_clear(cell) and _house_sleep_cell_clear(right) if active_area_id == "HOUSE" else _is_walkable(right)
    if not has_room:
        world_message.emit("There is not enough room for the SLEEPING BAG.")
        return false

    var terrain_names := _ecology_names_at(cell)
    var right_names := _ecology_names_at(right)
    var harsh_words := ["water", "lava", "volcano", "stairs", "snow", "ice", "desert", "sand"]
    for harsh_word in harsh_words:
        if harsh_word in terrain_names or harsh_word in right_names:
            world_message.emit("The terrain is too harsh to sleep here.")
            return false
    if active_area_id != "HOUSE" and (_is_tall_grass_cell(cell) or _is_tall_grass_cell(right)):
        world_message.emit("The grass is too thick to set up the SLEEPING BAG.")
        return false

    if not wild_population.ids_near(cell, 2).is_empty():
        world_message.emit("A wild POKEMON is too close to sleep safely.")
        return false

    respawn_cell = cell
    respawn_house.clear()
    if active_area_id == "HOUSE":
        var floor_index := _built_house_floor_index_for_cell(cell)
        var local := cell - _built_house_floor_origin(floor_index)
        respawn_house = {"x":active_built_house_door.x,"y":active_built_house_door.y,"floor":floor_index,"local_x":local.x,"local_y":local.y}
        respawn_cell = area_return_cells.get("HOUSE_RETURN", active_built_house_door + _house_door_outward(active_built_house_door))
    sleeping_bag_rest_texture = rest_texture
    sleeping_bag_sprite = Sprite2D.new()
    sleeping_bag_sprite.texture = SOURCE_SLEEPING_BAG
    sleeping_bag_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
    sleeping_bag_sprite.position = _cell_center(cell) + Vector2(4.0, 0.0)
    sleeping_bag_sprite.z_as_relative = false
    sleeping_bag_sprite.z_index = _depth_z(cell) + 2
    add_child(sleeping_bag_sprite)
    sleeping_bag_anim_time = 0.0
    sleeping_bag_sleep_marks.clear()
    for mark_index in range(3):
        var mark := Label.new()
        mark.text = "Z"
        mark.add_theme_font_override("font", SOURCE_PIXEL_FONT)
        mark.add_theme_font_size_override("font_size", 7)
        mark.add_theme_color_override("font_color", Color(0.08, 0.10, 0.08, 1.0))
        mark.position = Vector2(5.0 + mark_index * 3.0, -12.0 - mark_index * 5.0)
        mark.z_index = 3 + mark_index
        sleeping_bag_sprite.add_child(mark)
        sleeping_bag_sleep_marks.append(mark)
    player.visible = true
    set_gameplay_enabled(false)
    play_source_sound("healbed_jingle")
    world_message.emit("You settled into the SLEEPING BAG.")
    return true

func begin_bed_rest(cell: Vector2i) -> bool:
    if active_area_id != "HOUSE" or String(built_structures.get(cell, {}).get("name", "")) != "BED" or is_instance_valid(sleeping_bag_sprite):
        return false
    clear_active_field_move(false)
    bed_rest_active = true
    sleeping_bag_anim_time = 0.0
    sleeping_bag_sprite = Sprite2D.new()
    var head := AtlasTexture.new()
    head.atlas = player.walk_texture
    head.region = Rect2(0, 0, 16, 6)
    sleeping_bag_sprite.texture = head
    sleeping_bag_sprite.centered = false
    sleeping_bag_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
    sleeping_bag_sprite.position = Vector2(cell * TILE) + Vector2(0, -12)
    sleeping_bag_sprite.z_as_relative = false
    # Interior furniture receives its final depth in _refresh_shell_attachment.
    # Keep the source six-pixel head above the actual bed, not its old depth.
    var bed_sprite := built_structures[cell].get("sprite") as Sprite2D
    sleeping_bag_sprite.z_index = bed_sprite.z_index + 1 if is_instance_valid(bed_sprite) else _depth_z(cell, 25)
    add_child(sleeping_bag_sprite)
    for i in range(3):
        var mark := Label.new()
        mark.text = "Z"
        mark.add_theme_font_override("font", SOURCE_PIXEL_FONT)
        mark.add_theme_font_size_override("font_size", 7)
        mark.add_theme_color_override("font_color", Color(0.08,0.1,0.08))
        mark.position = Vector2(5 + i * 3, -12 - i * 5)
        sleeping_bag_sprite.add_child(mark)
        sleeping_bag_sleep_marks.append(mark)
    player.visible = false
    set_gameplay_enabled(false)
    return true

func end_sleeping_bag() -> void:
    bed_rest_active = false
    for mark in sleeping_bag_sleep_marks:
        if is_instance_valid(mark):
            mark.queue_free()
    sleeping_bag_sleep_marks.clear()
    if sleeping_bag_sprite != null and is_instance_valid(sleeping_bag_sprite):
        sleeping_bag_sprite.queue_free()
    sleeping_bag_sprite = null
    sleeping_bag_rest_texture = null
    sleeping_bag_anim_time = 0.0
    player.visible = true
    player.set("facing", Vector2.DOWN)
    if player.has_method("_update_sprite_frame"):
        player.call("_update_sprite_frame", false)
    set_gameplay_enabled(true)

func _spawn_puddle_step_effect(cell: Vector2i) -> void:
    tides.spawn_puddle_step_effect(cell)

## per-frame
func _update_tidal_wade_visual() -> void:
    tides.update_tidal_wade_visual()

func set_gameplay_enabled(enabled: bool) -> void:
    gameplay_enabled = enabled and not is_instance_valid(stool_seated_sprite)
    player.set_physics_process(gameplay_enabled)
    # The player also moves from _process when locked to drawn frames.
    player.set_process(gameplay_enabled)

func set_environment_battle_active(active: bool) -> void:
    if environment_system != null and is_instance_valid(environment_system):
        environment_system.set_battle_suspended(active)

func play_source_sound(sound_name: String) -> void:
    if environment_system != null and is_instance_valid(environment_system):
        environment_system.play_source_sound(sound_name)

func environment_day_seconds() -> float:
    return WORLD_DAY_SECONDS

func environment_player_position() -> Vector2:
    return player.position

func environment_camera_center() -> Vector2:
    var camera := player.get_node_or_null("Camera2D") as Camera2D
    if camera != null:
        return camera.get_screen_center_position()
    return player.position

## per-frame
func environment_context() -> Dictionary:
    if active_area_id == "HOUSE":
        return {"area_id":"HOUSE", "indoors":true, "dungeon":false, "route_name":"", "route_type":"", "biome":"INTERIOR"}
    var cell := _player_cell()
    var route_name := ""
    var dungeon := false
    # The environment asks every frame: one tile object for both the route
    # and the biome (biome_at would build a second one for the same cell).
    var biome := "INTERIOR"
    if active_area_id == "OVERWORLD":
        if exact_world != null:
            var exact_tile := _frame_tile(cell)
            var route: SourceRoute = exact_tile.route_belongs_to if exact_tile != null else null
            if route != null:
                route_name = route.name
                dungeon = route.is_dungeon
            biome = "OCEAN" if exact_tile == null else _source_biome_for_tile(exact_tile)
        else:
            route_name = String(habitat_routes.get(cell, ""))
            dungeon = SourceRouteData.is_dungeon(route_name)
            biome = biome_at(cell)
    else:
        var route_data := _active_source_interior_route()
        route_name = String(route_data.get("name", ""))
        dungeon = SourceRouteData.is_dungeon(route_name)
    return {
        "area_id": active_area_id,
        "indoors": active_area_id != "OVERWORLD",
        "dungeon": dungeon,
        "route_name": route_name,
        "route_type": SourceRouteData.route_type(route_name),
        "biome": biome
    }

func environment_tile_flags() -> Dictionary:
    var cell := _player_cell()
    var result := {
        "tidal": false,
        "dry_tidal": false,
        "puddle": false,
        "sand": terrain_kind_at(cell) == 1
    }
    if String(built_structures.get(cell, {}).get("name", "")) == "BRIDGE": return result
    if active_area_id != "OVERWORLD":
        return result
    if exact_world != null:
        var tile := exact_world.tile_at(cell)
        if tile != null:
            var beach_surface := _is_beach_tidal_tile(tile) or (
                _source_biome_for_tile(tile) in ["BEACH", "BEACH_BLACKSAND"]
            )
            result["tidal"] = _is_beach_tidal_tile(tile) and "_tidalwater" in tile.name
            result["dry_tidal"] = _is_beach_tidal_tile(tile) and "_tidaloff" in tile.name
            result["puddle"] = "puddle1" in tile.name
            result["sand"] = (
                "sand" in tile.name
                or "desert" in tile.name
                or "beach" in tile.biome
            )
    return result

func environment_nearby_lava_cells(radius: int = 12) -> Array:
    var result: Array = []
    if (
            active_area_id != "OVERWORLD"
            or exact_world == null
        ):
        return result
    var center := _player_cell()
    for y in range(center.y - radius, center.y + radius + 1):
        for x in range(center.x - radius, center.x + radius + 1):
            var cell := Vector2i(x, y)
            var tile := exact_world.tile_at(cell)
            if tile != null and (
                    tile.is_lava
                    or "lava" in tile.name
                    or "lava" in tile.name_upper
                ):
                result.append(cell)
    return result

func environment_structure_texture(
        build_name: String, frame: int
    ) -> Texture2D:
    var source := structure_textures.get(build_name) as Texture2D
    if source == null:
        return null
    var atlas := AtlasTexture.new()
    atlas.atlas = source
    if build_name == "CAMPFIRE":
        atlas.region = Rect2(posmod(frame, 2) * 16, 0, 16, 20)
    elif build_name == "TORCH":
        atlas.region = Rect2(posmod(frame, 2) * 16, 60, 16, 20)
    elif build_name == "CHIMNEY":
        atlas.region = Rect2(
            posmod(frame, 4) * 64,
            0,
            64,
            minf(32.0, source.get_height())
        )
    else:
        return _structure_display_texture(build_name, frame)
    return atlas

func _is_beach_tidal_tile(tile: SourceTile) -> bool:
    if tile == null:
        return false
    var route_name := "" if tile.route_belongs_to == null else \
        tile.route_belongs_to.name.to_lower()
    var biome := _source_biome_for_tile(tile)
    var beach_identity := biome in ["BEACH", "BEACH_BLACKSAND"] or \
        route_name.begins_with("beach")
    var tile_name := tile.name.to_lower()
    var authored_tide := "_tidalwater" in tile_name or "_tidaloff" in tile_name
    if not authored_tide:
        return false
    # The original generator also uses *_tidalwater for non-ocean systems
    # (mountain-bottom water and wooded-lake shores).  Ocean tide must therefore
    # remain tied to an authored beach biome/route; accepting an untagged suffix
    # caused the inland pale squares and tide fingers seen in the screenshots.
    return beach_identity

func _handle_biome_entry(cell: Vector2i) -> void:
    if active_area_id != "OVERWORLD":
        return
    var biome := biome_at(cell)
    if biome != "DESERT":
        return
    var entries := event_progress.get("biome_first_entries", {}) as Dictionary
    if bool(entries.get("DESERT", false)):
        return
    entries["DESERT"] = true
    event_progress["biome_first_entries"] = entries
    _show_ecology_emote(player.sprite, "!")
    world_message.emit("The desert is dangerous. Be careful as you explore.")

## per-frame
func _update_tide_state(force: bool = false, delta: float = 0.0, spread := false) -> void:
    await tides.update_tide_state(force, delta, spread)

func _refresh_exact_tile_streams() -> void:
    var changed_cells: Array = []
    for key in SourceTile.resident_changed_cells:
        if exact_world.tiles.has(key): changed_cells.append(Vector2i(key / TILE))
    _bump_map_art(changed_cells)
    var base_stream := get_node_or_null(
        "GroundLayer/ExactBaseTileStream")
    var upper_stream := get_node_or_null(
        "DecorLayer/ExactUpperTileStream")
    if base_stream != null:
        if base_stream.has_method("refresh_now"):
            base_stream.call("refresh_changed_tiles", changed_cells)
        else:
            base_stream.invalidate_tiles()
    if upper_stream != null:
        if upper_stream.has_method("refresh_now"):
            upper_stream.call("refresh_changed_tiles", changed_cells)
        else:
            upper_stream.invalidate_tiles()
    if is_instance_valid(reflection_layer):
        reflection_layer.queue_redraw()
    var collision_stream := get_node_or_null(
        "ExactCollisionStream") as SourceChunkCollisionStreamer
    if collision_stream != null:
        collision_stream.refresh_cells(changed_cells)
    if is_instance_valid(reflection_layer) and reflection_layer.has_method("refresh_cells"):
        reflection_layer.refresh_cells(changed_cells)
    SourceTile.resident_changed_cells.clear()
    var canopy := get_node_or_null("TreeCanopyOverlay")
    if canopy != null: canopy.queue_redraw()

func _recoastify_exact_cells(changed_cells: Array[Vector2i]) -> void:
    var targets: Dictionary = {}
    for changed in changed_cells:
        for y in range(changed.y - 1, changed.y + 2):
            for x in range(changed.x - 1, changed.x + 2):
                targets[Vector2i(x, y)] = true
    # Neighbours are read from the tile store's arrays: a proxy for each of
    # them cost ~0.5 ms per changed cell (48 ms for a load's tide cleanup).
    var store: WorldTileStore = exact_world.tiles
    var flags := store.flags
    var name_ids := store.name_ids
    var water6: int = store.string_ids.get("water6", -1)
    for raw_cell in targets.keys():
        var cell := raw_cell as Vector2i
        var tile := exact_world.tile_at(cell)
        if tile == null:
            continue
        tile.shore_ocean = ""
        tile.shore_tidal = ""
        if tile.is_water or "ledges" in tile.name_upper or tile.name == "ice2" or \
                "bridge" in tile.name or "waterfall" in tile.name:
            continue
        var names := ["W", "E", "S", "N", "SW", "NE", "SE", "NW"]
        var offsets := [
            Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN,
            Vector2i(-1, -1), Vector2i(1, 1),
            Vector2i(1, -1), Vector2i(-1, 1)]
        var ocean := ""
        var tidal := ""
        for index in range(offsets.size()):
            var at := store.index_of((cell + offsets[index]) * TILE)
            var bits := 0
            if at >= 0:
                if name_ids[at] == water6:
                    continue
                bits = flags[at]
            else:
                var neighbor := exact_world.tile_at(cell + offsets[index])
                if neighbor == null or neighbor.name == "water6":
                    continue
                bits = (WorldTileStore.TIDAL if neighbor.is_tidal else 0) | (WorldTileStore.WATER if neighbor.is_water else 0)
            var direction := String(names[index])
            if not tile.is_tidal and bits & WorldTileStore.TIDAL:
                if not _shore_diagonal_already_present(tidal, direction):
                    tidal += "[" + direction + "]"
                continue
            if not bits & WorldTileStore.WATER or \
                    _shore_diagonal_already_present(ocean, direction):
                continue
            ocean += "[" + direction + "]"
            tidal += "[" + direction + "]"
        tile.shore_ocean = ocean
        tile.shore_tidal = tidal

func _shore_diagonal_already_present(existing: String, direction: String) -> bool:
    if direction.length() < 2:
        return false
    for index in range(direction.length()):
        if "[" + direction.substr(index, 1) + "]" in existing:
            return true
    return false

func _permitted_ledge_direction(tile: SourceTile) -> Vector2i:
    if tile == null:
        return Vector2i.ZERO
    # The brown horizontal grass ledge is a one-way drop: screen-down is legal
    # and screen-up is blocked.  Keep this explicit instead of mirroring its
    # `_down` source suffix back upward.
    var ledge_key: String = (tile.name + " " + tile.name_upper).to_lower()
    if "ledge_grass_down" in ledge_key:
        return Vector2i.DOWN
    # The exact world deliberately preserves Java's Y-up cell coordinates on
    # Godot's Y-down canvas. Mirror only vertical movement directions here so
    # an authored downhill "up" edge is crossed toward screen-down, and vice
    # versa. Horizontal directions require no conversion.
    return {
        "up":Vector2i.DOWN, "down":Vector2i.UP,
        "left":Vector2i.LEFT, "right":Vector2i.RIGHT
    }.get(tile.ledge_dir, Vector2i.ZERO) as Vector2i

func _ledge_jump_landing_is_clear(cell:Vector2i)->bool:
    if not _ledge_landing_terrain_clear(cell):return false
    var coordinator=get_parent().get("coop_game")
    if is_instance_valid(coordinator) and coordinator.active:
        var target=_cell_center(cell)
        # Reached in several small steps, so compared with a little slack: an
        # exact match failed at random and the jump was refused.
        return coordinator.visuals.constrain_motion(player.position,target).distance_to(target)<0.5
    return true

func _ledge_landing_terrain_clear(cell: Vector2i) -> bool:
    if not _is_walkable(cell):
        return false
    var tile := exact_world.tile_at(cell) if exact_world != null else null
    if tile == null or tile.is_water or tile.is_ledge:
        return false
    return (
        not built_structures.has(cell)
        and not landmarks.has(cell)
        and not resource_objects.has(cell)
        and not deployed_pokemon.has(cell)
        and not wild_eggs.has(cell)
        and _wild_id_at_cell(cell) < 0
    )

## per-frame
func constrain_player_motion(before:Vector2,after:Vector2)->Vector2:
    var result:Vector2=_constrain_motion_to_terrain(before,after)
    var coordinator=get_parent().get("coop_game")
    if is_instance_valid(coordinator) and coordinator.active:
        var past:Vector2=coordinator.visuals.constrain_motion(before,result)
        # Easing round another player moves sideways; the ground must allow it.
        if past!=result and past!=before:past=_constrain_motion_to_terrain(before,past)
        result=past
    return result

func _constrain_motion_to_terrain(before: Vector2, after: Vector2) -> Vector2:
    var before_cell := Vector2i(floori(before.x / TILE), floori(before.y / TILE))
    var after_cell := Vector2i(floori(after.x / TILE), floori(after.y / TILE))
    # Holes block ground movement, including DIG's terrain bypass.
    if active_field_move != "FLY" and before_cell != after_cell:
        if active_area_id == "HOUSE" and bool(built_house_decorations.get(_built_house_paint_key(after_cell), {}).get("dig_hole", false)):
            return before
        if active_area_id == "OVERWORLD" and exact_world != null:
            var hole_tile: SourceTile = exact_world.tile_at(after_cell)
            # Empty outdoor holes use their visible outline in the physics layer.
            if hole_tile != null and hole_tile.name_upper.begins_with("hole1") and not hole_tile.has_item.is_empty():
                return before
    if active_field_move == "DIG" and before_cell != after_cell:
        if active_area_id in ["OVERWORLD", "HOUSE"]:
            if not _is_walkable(after_cell): return before
        else:
            var interior_dig_tile := _source_interior_tile_at_world_cell(after_cell)
            if interior_dig_tile == null or interior_dig_tile.is_solid or interior_dig_tile.is_ledge or not interior_dig_tile.has_item.is_empty(): return before
        if exact_world != null and active_area_id == "OVERWORLD":
            var dig_tile: SourceTile = exact_world.tile_at(after_cell)
            if dig_tile == null or dig_tile.is_ledge or not dig_tile.has_item.is_empty(): return before
    if active_field_move in ["CUT", "BUILD", "DIG", "HEADBUTT", "SMASH"] and before_cell != after_cell:
        var structure: Dictionary = built_structures.get(after_cell, {})
        if bool(structure.get("solid", false)) or String(structure.get("name", "")) in ["ROOF", "WALL", "INTERIOR WALL"]:
            return before
    if active_field_move != "FLY" and before_cell != after_cell:
        if String(built_structures.get(after_cell, {}).get("name", "")) == "BED" or String(built_structures.get(after_cell + Vector2i.DOWN, {}).get("name", "")) == "BED":
            return before
    if before_cell != after_cell and active_area_id not in ["OVERWORLD", "HOUSE", "CAVE"]:
        # Source PlayerMoving cannot enter a missing interior tile. Sparse maze
        # plans have empty space between corridors, not additional floor.
        if _source_interior_tile_at_world_cell(after_cell) == null:
            return before
    # Wild eggs are solid overworld objects. Walking/RIDE may approach from any
    # side but may never enter the egg's cell; interaction remains face-it + A.
    # FLY keeps its existing terrain/object bypass semantics.
    if active_field_move != "FLY" and before_cell != after_cell and \
            wild_eggs.has(after_cell):
        return before
    # Visible overworld Pokemon are solid actors. Walking/RIDE into their
    # sprite must stop at the occupied cell instead of starting a contact battle.
    # Burrowed Pokemon remain hidden step encounters and grass encounters are
    # handled separately by the unchanged grass encounter path.
    if active_field_move != "FLY" and before_cell != after_cell:
        if deployed_pokemon.has(after_cell):
            var resident: Dictionary = deployed_pokemon[after_cell]
            if not resident.has("house_door") or _house_pokemon_visible(resident):
                _try_push_fenced_pokemon(after_cell, after_cell - before_cell)
                return before
        if active_field_move in ["CUT", "HEADBUTT"] and (_is_cuttable_grass_cell(after_cell) or _cut_helper_tree_cell(after_cell)):
            return before
        # A SMASH Pokemon stops against a rock, tombstone or statue as a CUT
        # Pokemon stops against a tree, so that A then smashes what it faces.
        if active_field_move == "SMASH" and _smash_helper_rock_cell(after_cell):
            return before
        var blocking_wild_id := _wild_id_at_cell(after_cell)
        if blocking_wild_id >= 0:
            var blocking_wild: Dictionary = wild_pokemon.get(blocking_wild_id, {})
            if not bool(blocking_wild.get("burrowed", false)):
                _try_push_fenced_pokemon(after_cell, after_cell - before_cell)
                return before
    # FLY is the sole terrain bypass. RIDE still moves faster, but it may not
    # climb back up a one-way cliff or mountain edge.
    if active_field_move == "FLY" or \
            exact_world == null or active_area_id != "OVERWORLD":
        return after
    if before_cell == after_cell:
        return _keep_box_off_closed_ledges(before, after)
    var movement := after - before
    # The direction is the sign of the step, however small. Rounding the step
    # to a whole pixel first turned a short one (a light push on the stick, or
    # sliding along the edge) into "no direction", and the ledge refused the
    # jump: sometimes it let the player down and sometimes it did not.
    var direction := Vector2i.ZERO
    if absf(movement.x) > absf(movement.y):
        direction = Vector2i((1 if movement.x > 0.0 else -1 if movement.x < 0.0 else 0), 0)
    else:
        direction = Vector2i(0, (1 if movement.y > 0.0 else -1 if movement.y < 0.0 else 0))
    var from_tile := exact_world.tile_at(before_cell)
    var to_tile := exact_world.tile_at(after_cell)

    var crosses_one_way_edge := (
        (from_tile != null and (from_tile.is_ledge or from_tile.is_bottom_mtn_layer))
        or (to_tile != null and (to_tile.is_ledge or to_tile.is_bottom_mtn_layer))
    )
    # Do not assume screen-UP is uphill. The source tile's authored ledge_dir
    # determines the legal downhill direction for every mountain edge.

    # Diagonal input remains valid on open ground, but cannot cut across the
    # corner of a one-way edge and bypass its cardinal direction.
    var crossed_cells := after_cell - before_cell
    if crosses_one_way_edge and absi(crossed_cells.x) + absi(crossed_cells.y) > 1:
        return before

    # Entering a directional ledge automatically performs the source-style
    # two-cell hop. The far cell must be ordinary, unoccupied ground.
    if to_tile != null and to_tile.is_ledge:
        var permitted := _permitted_ledge_direction(to_tile)
        var to_ledge_key: String = (to_tile.name + " " + to_tile.name_upper).to_lower()
        var strict_brown_drop: bool = "ledge_grass_down" in to_ledge_key
        if (strict_brown_drop or active_field_move != "RIDE") and \
                (permitted == Vector2i.ZERO or direction != permitted):
            return before
        var landing_cell := after_cell + direction
        if not _ledge_jump_landing_is_clear(landing_cell):
            return before
        var landing_position := _cell_center(landing_cell)
        if player.has_method("begin_ledge_jump_visual"):
            player.call(
                "begin_ledge_jump_visual", before - landing_position
            )
        play_source_sound("ledge1")
        return landing_position

    for tile in [from_tile, to_tile]:
        if tile == null or not tile.is_ledge:
            continue
        var permitted := _permitted_ledge_direction(tile)
        var ledge_key: String = (String(tile.name) + " " + String(tile.name_upper)).to_lower()
        var strict_brown_drop_edge: bool = "ledge_grass_down" in ledge_key
        if (strict_brown_drop_edge or active_field_move != "RIDE") and \
                permitted != Vector2i.ZERO and direction != permitted:
            return before
    return _keep_box_off_closed_ledges(before, after)

## per-frame
## A ledge row is open ground for the player's box, so that it can be entered
## from the side it is jumped from, and the rule above only checks the box's
## centre: from any other side the box (and the sprite) went half onto the
## edge and stopped there, which looked like being stuck in a rock wall. Push
## the box back to the edge of such a cell, as a wall would. RIDE keeps its own
## rule for edges.
func _keep_box_off_closed_ledges(before: Vector2, at: Vector2) -> Vector2:
    if active_field_move == "RIDE":
        return at
    var store = exact_world.tiles
    var half: Vector2 = PLAYER_BODY.BODY_HALF
    var offset: Vector2 = PLAYER_BODY.BODY_OFFSET
    var centre := Vector2i(floori(at.x / TILE), floori(at.y / TILE))
    var box := Rect2(at + offset - half, half * 2.0)
    var first := Vector2i(floori(box.position.x / TILE), floori(box.position.y / TILE))
    var last := Vector2i(floori((box.end.x - 0.001) / TILE), floori((box.end.y - 0.001) / TILE))
    var result := at
    for y in range(first.y, last.y + 1):
        for x in range(first.x, last.x + 1):
            var cell := Vector2i(x, y)
            var side := cell - centre
            if side == Vector2i.ZERO:
                continue
            if store is WorldTileStore:
                var index: int = store.index_of(cell * TILE)
                if index < 0 or store.flags[index] & WorldTileStore.LEDGE == 0:
                    continue
            var tile: SourceTile = _frame_tile(cell)
            if tile == null or not tile.is_ledge:
                continue
            # Open only from the side it is jumped from. A corner cell is the
            # next cell of the same edge when the player comes from that side
            # (heading for the jump), and closed otherwise.
            var permitted := _permitted_ledge_direction(tile)
            var diagonal := side.x != 0 and side.y != 0
            if not diagonal and side == permitted:
                continue
            if diagonal and ((permitted.x != 0 and side.x == permitted.x) or (permitted.y != 0 and side.y == permitted.y)):
                continue
            # Back out the way it came in. Off a corner, sideways to the way the
            # player is going (so the corner never stops it), or along the
            # shallower overlap when it goes exactly diagonally.
            var along_x := side.y == 0
            if diagonal:
                var moved := at - before
                if absf(moved.y) > absf(moved.x) + 0.01:
                    along_x = true
                elif absf(moved.x) > absf(moved.y) + 0.01:
                    along_x = false
                else:
                    var into_x: float = box.end.x - x * TILE if side.x > 0 else (x + 1) * TILE - box.position.x
                    var into_y: float = box.end.y - y * TILE if side.y > 0 else (y + 1) * TILE - box.position.y
                    along_x = into_x < into_y
            if along_x:
                result.x = minf(result.x, x * TILE - half.x - offset.x) if side.x > 0 \
                    else maxf(result.x, (x + 1) * TILE + half.x - offset.x)
            else:
                result.y = minf(result.y, y * TILE - half.y - offset.y) if side.y > 0 \
                    else maxf(result.y, (y + 1) * TILE + half.y - offset.y)
    return result

func _player_cell() -> Vector2i:
    return Vector2i(
        int(floor(player.position.x / TILE)),
        int(floor(player.position.y / TILE))
    )

func _facing_cell() -> Vector2i:
    var facing: Vector2 = player.get("facing")
    if abs(facing.x) > abs(facing.y):
        return Vector2i(1 if facing.x > 0.0 else -1, 0)
    return Vector2i(0, 1 if facing.y > 0.0 else -1)

func biome_at(cell: Vector2i) -> String:
    if exact_world != null:
        var source_tile := exact_world.tile_at(cell)
        return "OCEAN" if source_tile == null else _source_biome_for_tile(source_tile)
    if not _in_bounds(cell) or biomes.is_empty():
        return "OCEAN"
    return String(biomes[cell.y][cell.x])

func _canonical_source_biome(raw_biome: String) -> String:
    var key := raw_biome.strip_edges().to_upper().replace("-", "_")
    if SOURCE_BIOME_ALIASES.has(key):
        return String(SOURCE_BIOME_ALIASES[key])
    return key.replace(" ", "_")

func _source_biome_for_tile(tile: SourceTile) -> String:
    var raw_biome := _canonical_source_biome(tile.biome)
    var route_name := ""
    if tile.route_belongs_to != null:
        route_name = tile.route_belongs_to.name.to_lower()

    # Rivers reuse wooded_lake_water1 in the Java source. Wooded-lake cells
    # carry their explicit biome while river cuts keep the biome they crossed,
    # so this distinction is recoverable without changing generator output.
    if tile.is_water and route_name == "wooded_lake_water1":
        if raw_biome == "WOODED_LAKE":
            return "WOODED_LAKE"
        return "RIVER"

    if not raw_biome.is_empty():
        return raw_biome

    # Route fallbacks cover source tiles that intentionally have no biome tag.
    # Check authored water/sub-biome routes before generic water so beach and
    # river ambience/ecology do not collapse into OCEAN.
    if not route_name.is_empty():
        if route_name == "ocean1" or "ocean" in route_name:
            return "OCEAN"
        if "beach" in route_name or "tidal" in route_name:
            return "BEACH"
        if "wooded_lake" in route_name:
            return "WOODED_LAKE"
        if "graveyard" in route_name:
            return "GRAVEYARD"
        if "volcano" in route_name:
            return "VOLCANO"
        if "oasis" in route_name:
            return "OASIS"
        if "desert" in route_name or "ruins" in route_name or "sand_pit" in route_name:
            return "DESERT"
        if "snow" in route_name or "tundra" in route_name:
            return "SNOW"
        if "mountain" in route_name or "cave" in route_name:
            return "MOUNTAIN"
        if "savanna" in route_name:
            return "SAVANNA"
        if "deep" in route_name:
            return "DEEP_FOREST"
        if "forest" in route_name:
            return "FOREST"
    if tile.is_water:
        return "OCEAN"
    return "FOREST"

func is_cell_discovered(cell: Vector2i) -> bool:
    if active_area_id != "OVERWORLD" and source_area_rects.has(active_area_id):
        return get_map_bounds().has_point(cell)
    return discovered_cells.has(cell)

## The discovered cells as a save keeps them: {"bounds": [x, y, w, h], "bits":
## base64}, one bit per cell of the map (DiscoveredCells.to_save).
func discovered_save_value() -> Dictionary:
    return discovered_cells.to_save()

## Takes a save's discovered cells in any form saves have had: the bitset
## (discovered_save_value), the co-op squares, or the old list of "x,y" keys.
func restore_discovered(value: Variant) -> void:
    discovered_cells.from_save(value)

func reveal_player_area() -> void:
    if active_area_id != "OVERWORLD":
        return
    last_player_cell = _player_cell()
    _sync_follower_to_player()
    _discover_around(last_player_cell, DISCOVERY_RADIUS)

func _discover_around(cell: Vector2i, radius: int) -> void:
    var added := 0
    var low := Vector2i(2147483647, 2147483647)
    var high := Vector2i(-2147483648, -2147483648)
    for y in range(cell.y - radius, cell.y + radius + 1):
        for x in range(cell.x - radius, cell.x + radius + 1):
            var test := Vector2i(x, y)
            if not _in_bounds(test):
                continue
            if Vector2(test - cell).length_squared() <= float(radius * radius + 2):
                if discovered_cells.add(test):
                    added += 1
                    low = Vector2i(mini(low.x, x), mini(low.y, y))
                    high = Vector2i(maxi(high.x, x), maxi(high.y, y))
    if added > 0:
        discovered_added += added
        var fresh := Rect2i(low, high - low + Vector2i.ONE)
        discovered_dirty = fresh if discovered_dirty.size == Vector2i.ZERO else discovered_dirty.merge(fresh)
        map_fog_dirty = fresh if map_fog_dirty.size == Vector2i.ZERO else map_fog_dirty.merge(fresh)

func map_color_for_cell(cell: Vector2i) -> Color:
    if not _in_bounds(cell):
        return Color.BLACK
    var terrain_kind := terrain_kind_at(cell)
    if terrain_kind == 0:
        return Color(0.27, 0.55, 0.78, 1.0)
    if terrain_kind == 1:
        return Color(0.82, 0.78, 0.56, 1.0)

    # Preserve small-scale source-map detail instead of painting every land
    # cell as a biome-only blob. Object/upper-tile colors intentionally sit
    # over the terrain color, matching the visual hierarchy of the world.
    if exact_world != null:
        var map_tile := exact_world.tile_at(cell)
        if map_tile != null:
            var map_key := (map_tile.name + " " + map_tile.name_upper).to_lower()
            if "fence" in map_key or "gate" in map_key:
                return Color(0.40, 0.25, 0.10, 1.0)
            if "gravestone" in map_key or "grave" in map_key:
                return Color(0.34, 0.36, 0.38, 1.0)
            if "rock" in map_key or "stone" in map_key or "mountain" in map_key or "ledge" in map_key:
                return Color(0.45, 0.43, 0.39, 1.0)
            if "tree" in map_key:
                return Color(0.08, 0.34, 0.08, 1.0)
            if "bush" in map_key or "grass2" in map_key or "grass3" in map_key or "grass4" in map_key:
                return Color(0.18, 0.49, 0.12, 1.0)
            if "flower" in map_key:
                return Color(0.82, 0.36, 0.56, 1.0)
            if "house" in map_key or "building" in map_key or "door" in map_key:
                return Color(0.62, 0.37, 0.18, 1.0)

    if built_structures.has(cell):
        return Color(0.62, 0.37, 0.18, 1.0)
    match biome_at(cell):
        "DEEP_FOREST":
            return Color(0.10, 0.31, 0.10, 1.0)
        "GRAVEYARD":
            return Color(0.30, 0.38, 0.27, 1.0)
        "FOREST":
            return Color(0.22, 0.52, 0.18, 1.0)
        "SAVANNA":
            return Color(0.58, 0.69, 0.18, 1.0)
        "MOUNTAIN":
            return Color(0.47, 0.36, 0.18, 1.0)
        "VOLCANO":
            return Color(0.40, 0.24, 0.19, 1.0)
        "DESERT", "OASIS":
            return Color(0.91, 0.76, 0.29, 1.0)
        "BEACH":
            return Color(0.88, 0.82, 0.53, 1.0)
        "SNOW":
            return Color(0.86, 0.94, 0.98, 1.0)
        "WOODED_LAKE":
            return Color(0.37, 0.68, 0.29, 1.0)
        "RIVER":
            return Color(0.27, 0.55, 0.78, 1.0)
        _:
            return Color(0.30, 0.62, 0.22, 1.0)

func _is_walkable(cell: Vector2i) -> bool:
    if String(built_structures.get(cell, {}).get("name", "")) == "BRIDGE":
        return not blocked.has(cell)
    if active_area_id == "HOUSE":
        var coordinator=get_parent().get("coop_game")
        var online_wild=is_instance_valid(coordinator) and coordinator.active and coordinator.wild.simulating
        if not online_wild:return built_house_interior_cells.has(cell) and not blocked.has(cell) and String(built_structures.get(cell + Vector2i.DOWN, {}).get("name", "")) != "BED"
    if exact_world != null:
        return exact_world.contains_cell(cell) and not exact_world.is_solid(cell) and not blocked.has(cell)
    if cell.x < 0 or cell.y < 0 or cell.x >= map_w or cell.y >= map_h:
        return false
    return terrain[cell.y][cell.x] != 0 and not blocked.has(cell)

func terrain_kind_at(cell: Vector2i) -> int:
    if String(built_structures.get(cell, {}).get("name", "")) == "BRIDGE":
        return 2
    if exact_world != null:
        var tile := exact_world.tile_at(cell)
        if tile == null or tile.is_water or SourceWorldData.is_water(tile.name):
            return 0
        if "sand" in tile.name or "desert" in tile.name or "beach" in tile.biome:
            return 1
        return 2
    if not _in_bounds(cell) or terrain.is_empty():
        return 0
    return int(terrain[cell.y][cell.x])

func get_map_bounds() -> Rect2i:
    if active_area_id != "OVERWORLD" and source_area_rects.has(active_area_id):
        return _interior_map_bounds()
    if exact_world != null:
        return exact_world_bounds
    return Rect2i(Vector2i.ZERO, Vector2i(map_w, map_h))

func battle_terrain_at(cell: Vector2i) -> String:
    var kind := terrain_kind_at(cell)
    if kind == 0:
        return "AQUATIC"
    if kind == 1:
        return "SANDY"
    return "GRASSY"

func _add_block_collision(body: CollisionBody, x: int, y: int) -> CollisionBox:
    return body.add_cell(Vector2i(x, y))

func _add_landmark_collision(
        body: CollisionBody,
        x: int,
        y: int
    ) -> CollisionBox:
    return body.add_cell(Vector2i(x, y))

func _cell_center(cell: Vector2i) -> Vector2:
    return Vector2(
        cell.x * TILE + TILE * 0.5,
        cell.y * TILE + TILE * 0.5
    )

func _configure_camera() -> void:
    # Apply on entry, exit, floor changes, load and whiteout without moving any
    # saved house/furniture coordinates or changing the player's collision mask.
    var dungeon_body := get_node_or_null("InteriorLayer/SourceInteriorCollision") as CollisionBody
    if dungeon_body != null:
        dungeon_body.collision_layer = 0 if active_area_id == "HOUSE" else 1
    var house_body := get_node_or_null("BuiltHouseCollision") as CollisionBody
    if house_body != null:
        house_body.collision_layer = 1 if active_area_id == "HOUSE" else 0
    var camera := player.get_node_or_null("Camera2D") as Camera2D
    if camera == null:
        return

    if player.has_method("set_streamed_overworld_depth"):
        player.call(
            "set_streamed_overworld_depth",
            # A built house orders its furniture round the player the same
            # way the open map does; without this the player was simply
            # drawn over everything in the room.
            active_area_id in ["OVERWORLD", "HOUSE"]
        )

    if active_area_id == "HOUSE" or active_field_move == "BUILD":
        camera.limit_left = -10000000
        camera.limit_top = -10000000
        camera.limit_right = 10000000
        camera.limit_bottom = 10000000
        camera.offset = Vector2.ZERO
    elif (
            exact_world != null
            and active_area_id == "OVERWORLD"
        ):
        # GenIsland1 is centered around Java pixel coordinate (0, 0), so its
        # renderer cells extend into negative X and Y. The compatibility map
        # starts at (0, 0), but applying those old limits here clamps the camera
        # away from a valid negative-coordinate spawn and leaves only the clear
        # canvas visible after generation.
        camera.limit_left = exact_world_bounds.position.x * TILE
        camera.limit_top = exact_world_bounds.position.y * TILE
        camera.limit_right = exact_world_bounds.end.x * TILE
        camera.limit_bottom = exact_world_bounds.end.y * TILE
    elif active_area_id == "FOSSIL_LAB":
        # The lab shares a sparse plane with the mansion. Plane-edge camera
        # clamping pushes this tiny room off-screen. Follow the actor here.
        camera.limit_left = -10000000
        camera.limit_top = -10000000
        camera.limit_right = 10000000
        camera.limit_bottom = 10000000
    elif source_area_rects.has(active_area_id):
        var area_rect: Rect2i = source_area_rects[active_area_id]
        camera.limit_left = area_rect.position.x * TILE
        camera.limit_top = area_rect.position.y * TILE
        camera.limit_right = area_rect.end.x * TILE
        camera.limit_bottom = area_rect.end.y * TILE
    elif active_area_id == "HOUSE":
        camera.limit_left = (map_w + 8) * TILE
        camera.limit_top = 4 * TILE
        camera.limit_right = (map_w + 28) * TILE
        camera.limit_bottom = 16 * TILE
    elif active_area_id == "CAVE":
        camera.limit_left = (map_w + 8) * TILE
        camera.limit_top = 20 * TILE
        camera.limit_right = (map_w + 28) * TILE
        camera.limit_bottom = 32 * TILE
    else:
        camera.limit_left = 0
        camera.limit_top = 0
        camera.limit_right = map_w * TILE
        camera.limit_bottom = map_h * TILE
    # The source game follows the player on exact pixels. Smoothing a
    # nearest-neighbour scene introduces visible cadence judder while walking.
    camera.position_smoothing_enabled = false
    camera.process_callback = Camera2D.CAMERA2D_PROCESS_IDLE if bool(player.get("frame_locked")) else Camera2D.CAMERA2D_PROCESS_PHYSICS
    camera.zoom = _pixel_exact_zoom(camera_zoom_level)

## The chosen zoom, nudged so one tile covers a whole number of screen pixels.
## At 45% on a 1080p screen a tile is 43.2 pixels wide; the leftover fraction
## shows up as thin stray lines between tiles, most visibly over open water.
## The nudge is under one percent and cannot be seen.
func _pixel_exact_zoom(level: float) -> Vector2:
    var screen_scale := get_viewport().get_stretch_transform().get_scale().x if is_inside_tree() else 0.0
    if screen_scale <= 0.0:
        return Vector2(level, level)
    var exact := maxf(1.0, roundf(float(TILE) * level * screen_scale)) / (float(TILE) * screen_scale)
    return Vector2(exact, exact)

func adjust_camera_zoom(direction: int) -> int:
    if not preload("res://scripts/game_options.gd").enabled("zoom"):
        return roundi(camera_zoom_level * 100.0)
    camera_zoom_level = clampf(
        camera_zoom_level + float(direction) * CAMERA_ZOOM_STEP,
        CAMERA_ZOOM_MIN,
        CAMERA_ZOOM_MAX
    )
    var camera := player.get_node_or_null("Camera2D") as Camera2D
    if camera != null:
        camera.zoom = _pixel_exact_zoom(camera_zoom_level)
    return roundi(camera_zoom_level * 100.0)

func _clear_generated_world() -> void:
    for name in [
            "GroundLayer", "DecorLayer", "TallGrassLayer",
            "TallGrassFrontLayer", "LandmarkLayer", "WildPokemonLayer",
            "WildEggLayer", "InteriorLayer", "WorldCollision", "RouteLayer",
            "ExactCollisionStream", "ExactReflectionLayer", "TreeCanopyOverlay"
        ]:
        var node := get_node_or_null(name)
        if node != null:
            node.queue_free()

    # Let queued children disappear before repopulating.
    await get_tree().process_frame

func _legacy_source_interior_cell(cell: Vector2i) -> Vector2i:
    return interiors.legacy_source_interior_cell(cell)

func migrate_source_interior_position(position_value: Vector2, state: Dictionary) -> Vector2:
    return interiors.migrate_source_interior_position(position_value, state)

func _source_interior_tile_at_world_cell(cell: Vector2i) -> SourceTile:
    return interiors.source_interior_tile_at_world_cell(cell)

func _recover_source_dungeon_return(area_id: String, interior_cell: Vector2i = Vector2i(-2147483648, -2147483648)) -> Vector2i:
    return interiors.recover_source_dungeon_return(area_id, interior_cell)

# Both map views use the active floor's actual rendered source sprites.
# Revealing an interior never modifies the overworld discovery dictionary.
var interior_map_cache_key: Array = []
var interior_map_cache: Image
var interior_map_bounds_key: Array = []
var interior_map_bounds_cache := Rect2i()

func _interior_map_bounds() -> Rect2i:
    return interiors.interior_map_bounds()

func interior_map_image(bounds: Rect2i) -> Image:
    return interiors.interior_map_image(bounds)


## Where to mark, on the map of the open world, someone standing at `at`
## (in tiles). The inside of a built house is kept far off to the east of the
## map, so a player indoors was marked at the map's edge; they are marked at
## that house's door instead. Anywhere else is returned unchanged.
func outdoor_map_position(at: Vector2) -> Vector2:
    return interiors.outdoor_map_position(at)

func _try_push_fenced_pokemon(cell: Vector2i, direction: Vector2i, require_fence: bool = true) -> bool:
    if active_area_id not in ["OVERWORLD", "HOUSE"] or not active_field_move.is_empty() or absi(direction.x) + absi(direction.y) != 1:
        return false
    if preload("res://scripts/game_clock.gd").ticks_msec() - last_pokemon_push_msec < 500: return false
    var near_fence := false
    for y in range(-4, 5):
        for x in range(-4, 5):
            if _is_fence_cell(cell + Vector2i(x,y)):
                near_fence = true
                break
        if near_fence: break
    if require_fence and not near_fence: return false
    var owned := deployed_pokemon.has(cell)
    var wild_id := _wild_id_at_cell(cell)
    var data: Dictionary = deployed_pokemon.get(cell, {}) if owned else wild_pokemon.get(wild_id, {})
    if data.is_empty() or bool(data.get("burrowed", false)) or bool(data.get("behavior", {}).get("stationary", false)): return false
    var target := cell + direction
    # The logical destination is reserved before a walking tween finishes.
    # Check the visible position as well, so pushing cannot overlap its origin.
    for resident in deployed_pokemon.values() + wild_pokemon.values():
        var other := resident.get("sprite") as Sprite2D
        if resident == data or not is_instance_valid(other) or not other.visible: continue
        if other.position.distance_to(_cell_center(target)) < TILE - 0.01: return false
    if active_area_id != "HOUSE" and blocked.has(target): return false
    if active_area_id == "HOUSE" and not _house_pokemon_cell_allowed(target): return false
    if active_area_id == "OVERWORLD" and exact_world != null:
        var ground: SourceTile = exact_world.tile_at(target)
        if ground == null or ground.is_solid or "roof" in ground.name + ground.name_upper: return false
    if built_structures.has(target) or deployed_pokemon.has(target) or wild_eggs.has(target) or target == follower_cell or target == field_helper_cell:
        return false
    if active_area_id != "HOUSE" and (landmarks.has(target) or resource_objects.has(target) or _wild_id_at_cell(target) >= 0):
        return false
    if target == _player_cell(): return false
    if active_area_id == "OVERWORLD" and not _pokemon_can_move_between(String(data.get("species", "")), cell, target): return false
    var sprite := data.get("sprite") as Sprite2D
    if not is_instance_valid(sprite) or sprite.position.distance_to(_cell_center(cell)) > 1.5: return false
    data["cell"] = target
    if not owned: wild_population.move(wild_id, target)
    data["x"] = target.x
    data["y"] = target.y
    data["move_timer"] = 1.0
    data["anim_phase"] = 1 - int(data.get("anim_phase", 0))
    _set_overworld_motion_frame(sprite, Vector2(direction), int(data.anim_phase))
    sprite.position = _cell_center(target)
    sprite.z_index = _depth_z(target)
    if owned:
        deployed_pokemon.erase(cell)
        deployed_pokemon[target] = data
    else:
        wild_pokemon[wild_id] = data
    last_pokemon_push_msec = preload("res://scripts/game_clock.gd").ticks_msec()
    return true

func _is_fence_cell(cell: Vector2i) -> bool:
    return buildings.is_fence_cell(cell)

func is_empty_planting_hole(cell: Vector2i) -> bool:
    if active_area_id != "OVERWORLD" or exact_world == null: return false
    var tile: SourceTile = exact_world.tile_at(cell)
    return tile != null and tile.name_upper.begins_with("hole1") and tile.has_item.is_empty() and not tile.is_water and not tile.is_lava

func _refresh_shell_attachment(cell: Vector2i) -> void:
    buildings.refresh_shell_attachment(cell)


func _can_prompt_shore_surf(target: Vector2i) -> bool:
    if active_area_id != "OVERWORLD" or active_field_move == "SURF":
        return false
    if built_structures.has(target) or _wild_id_at_cell(target) >= 0 or deployed_pokemon.has(target):
        return false
    if exact_world != null:
        var tile: SourceTile = exact_world.tile_at(target)
        return tile != null and tile.is_water
    return _in_bounds(target) and terrain_kind_at(target) == 0

func _draw_house_decoration(cell: Vector2i) -> void:
    buildings.draw_house_decoration(cell)

func _restore_house_decorations() -> void:
    buildings.restore_house_decorations()

func _interact_house_window(cell: Vector2i) -> bool:
    return buildings.interact_house_window(cell)


func _house_door_transition(action: String, change_area: Callable) -> void:
    await interiors.house_door_transition(action, change_area)


# House residents use a persistent layer: rebuilding the active room must not
# delete their actors. House identity and floor are serialized with each record.
func _house_pokemon_layer() -> Node2D:
    var layer := get_node_or_null("HousePokemonLayer") as Node2D
    if layer == null:
        layer = Node2D.new()
        layer.name = "HousePokemonLayer"
        add_child(layer)
    return layer

func _house_pokemon_visible(data: Dictionary) -> bool:
    return active_area_id == "HOUSE" and String(data.get("house_door", "")) == _cell_key(active_built_house_door) and int(data.get("house_floor", -1)) == _built_house_floor_index_for_cell(_player_cell())

func _house_pokemon_cell_allowed(cell: Vector2i) -> bool:
    if String(built_structures.get(cell + Vector2i.DOWN, {}).get("name", "")) == "BED":
        return false
    return active_area_id == "HOUSE" and built_house_interior_cells.has(cell) and not built_structures.has(cell) and _couch_anchor_at(cell) == Vector2i(2147483647,2147483647) and String(interior_interactables.get(cell,"")) != "EXIT_HOUSE" and _built_house_floor_index_for_cell(cell) == _built_house_floor_index_for_cell(_player_cell())

## per-frame
func _update_house_pokemon(delta:float)->void:
    var coordinator=get_parent().get("coop_game")
    if is_instance_valid(coordinator) and coordinator.active and not coordinator.population.authority(coordinator.population.local_scope()):
        for data in deployed_pokemon.values():
            if data.has("house_door") and is_instance_valid(data.get("sprite")):data.sprite.visible=_house_pokemon_visible(data)
        return
    for egg in wild_eggs.values():
        if egg.has("house_door") and is_instance_valid(egg.get("sprite")):
            egg.sprite.visible = _house_pokemon_visible(egg)
    for old_cell in deployed_pokemon.keys():
        var data: Dictionary = deployed_pokemon[old_cell]
        if not data.has("house_door"):
            continue
        var sprite := data.get("sprite") as Sprite2D
        var visible_here := _house_pokemon_visible(data)
        if is_instance_valid(sprite):
            sprite.visible = visible_here
            sprite.z_index = _depth_z(old_cell)
        if not visible_here or not generated or not gameplay_enabled:
            continue
        data["move_timer"] = float(data.get("move_timer", 0.0)) - delta
        if float(data.move_timer) > 0.0:
            continue
        data["move_timer"] = _wild_move_delay(String(data.get("species", "")))
        if bool(data.get("behavior", {}).get("stationary", false)):
            continue
        var direction: Vector2i = [Vector2i.UP,Vector2i.DOWN,Vector2i.LEFT,Vector2i.RIGHT][rng.randi_range(0,3)]
        var target: Vector2i = old_cell + direction
        if not _house_pokemon_cell_allowed(target) or deployed_pokemon.has(target) or wild_eggs.has(target) or target == _player_cell() or target == follower_cell or target == field_helper_cell:
            continue
        deployed_pokemon.erase(old_cell)
        data["cell"] = target
        data["x"] = target.x
        data["y"] = target.y
        data["anim_phase"] = 1 - int(data.get("anim_phase", 0))
        deployed_pokemon[target] = data
        if is_instance_valid(sprite):
            _set_overworld_motion_frame(sprite,direction,int(data.anim_phase))
            sprite.z_index = _depth_z(target)
            create_tween().tween_property(sprite,"position",_cell_center(target),0.20)

func _pokemon_drop_ground_allowed(pokemon: Dictionary, cell: Vector2i) -> bool:
    if not _in_bounds(cell): return false
    var water := _source_pokemon_in_water(cell)
    if exact_world != null:
        var tile := exact_world.tile_at(cell)
        if tile == null or tile.is_ledge or (tile.is_solid and not water): return false
        if SourceWorldData.is_upper_solid(tile.name_upper): return false
    if not water: return _is_walkable(cell)
    if bool(pokemon.get("is_egg",false)): return false
    # DrawPokemonMenu.java DROP: Water type or one of its explicit exceptions.
    var species := String(pokemon.get("species","")).to_lower()
    return "WATER" in PokemonData.info(species).get("types",[]) or species in ["azurill","dratini","dragonair","dragonite","anorith","armaldo","lileep","cradily","araichu"]

func _update_source_aggro_audio(data: Dictionary, cell: Vector2i, player_cell: Vector2i, delta: float) -> void:
    # Pokemon.Wander: nearby, uncharmed pursuit cries once per 241 source
    # ticks, with ride1 shuffles at ticks 8, 16 and 24. Delta is game-scaled.
    if not bool(data.get("aggro_player",false)) or bool(data.get("charmed",false)) or Vector2(cell-player_cell).length_squared() >= 56.25:
        data.erase("aggro_audio_tick")
        return
    var before := float(data.get("aggro_audio_tick",-1.0))
    var after := maxf(0.0,before) + delta * 60.0
    if before < 0.0 or after >= 241.0:
        if get_parent().has_method("_play_pokemon_cry"):
            get_parent().call("_play_pokemon_cry",data,0.2 if String(data.get("species",""))=="dusclops" else 1.0)
        if after >= 241.0: after = fmod(after,241.0)
        before = 0.0
    for tick in [8.0,16.0,24.0]:
        if before < tick and after >= tick and is_instance_valid(environment_system):
            environment_system._play_environment_sound("ride1",linear_to_db(0.5))
    data["aggro_audio_tick"] = after

var coop_private_chest_cache:Dictionary={}
const FLY_SHADOW_TEXTURE = preload("res://assets/source_exact/global/shadow1.png")
const SOURCE_TIDAL_FRONT_SPLASH = preload("res://assets/source_exact/global/splash_anim4.png")
const FLY_TAKEOFF_SECONDS = 96.0 / 60.0
const FLY_LANDING_SECONDS = 80.0 / 60.0
var fly_shadow_sprite: Sprite2D
var fly_phase: String = ""
var fly_phase_elapsed: float = 0.0
var fly_height: float = 0.0
var fly_landing_start_height: float = 0.0
var fly_landing_show_message: bool = true
var ice_slide_direction: Vector2 = Vector2.ZERO
var ice_blocked_direction := Vector2.ZERO
var tidal_front_splash_frames: SpriteFrames
var tidal_front_splash_phase_known := false


var tidal_puddle_splashes: Array[AnimatedSprite2D] = []
var tidal_puddle_shader: Shader
var frame_delta := 1.0 / 60.0
var grass_front_sprites: Array[Sprite2D] = []

var source_night_events
var roaming_ghosts
var source_dig_water_elapsed := 0.0

var camera_build_centered := false

var _watched_wild_ids: Array = []
var _watched_wild_at := -100000
var _near_wild_ids: Array = []
var _near_wild_at := -100000

## per-frame
## Wild Pokemon within sight or earshot of this player, refreshed twice a
## second. Per-frame work that only matters near the player (idle animation,
## pursuit sounds) uses this instead of visiting every Pokemon in the world.
func nearby_wild_ids() -> Array:
    var now_msec := Time.get_ticks_msec()
    if now_msec - _near_wild_at >= 500:
        _near_wild_at = now_msec
        _near_wild_ids = wild_population.ids_near(_player_cell(), 44)
    return _near_wild_ids
## Planned escape routes of Pokemon running from a failed catch, by wild id.
var _flee_routes := {}
var _flee_started := {}
## How near the player has to be for a frightened Pokemon to keep running:
## well past the edge of the screen, so it is not found waiting just out of view.
const FLEE_RANGE_TILES := 28
const FLEE_LOOK_AHEAD := 14
const FLEE_SEARCH_TILES := 180
const FLEE_REPLAN_STEPS := 5

## The next step for a Pokemon running from `threat`. It searches every tile it
## could walk to within FLEE_LOOK_AHEAD steps and heads for the one furthest
## from the player, keeping to that route for a few steps before looking again.
## One step at a time (always the tile furthest away) left it pacing back and
## forth in front of any wall or pond, which made it easy to catch.
func _flee_direction(wild_id: int, species: String, origin: Vector2i, threat: Vector2i, free_step: Callable) -> Vector2i:
    var route: Array = _flee_routes.get(wild_id, [])
    if not route.is_empty():
        var planned: Vector2i = route[0]
        if (
                (planned - origin).length_squared() == 1
                and (threat - planned).length_squared() > 2
                and _pokemon_can_move_between(species, origin, planned)
                and free_step.call(planned)
            ):
            route.pop_front()
            _flee_routes[wild_id] = route
            return planned - origin
    var came := {origin: origin}
    var depth := {origin: 0}
    var queue: Array[Vector2i] = [origin]
    var head := 0
    var goal := origin
    var goal_score := float((threat - origin).length_squared())
    while head < queue.size() and queue.size() < FLEE_SEARCH_TILES:
        var cell := queue[head]
        head += 1
        if int(depth[cell]) >= FLEE_LOOK_AHEAD:
            continue
        for option in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
            var step: Vector2i = cell + option
            # Never plan a way that brushes past the player.
            if came.has(step) or (threat - step).length_squared() <= 2:
                continue
            if not _pokemon_can_move_between(species, cell, step):
                continue
            if cell == origin and not free_step.call(step):
                continue
            came[step] = cell
            depth[step] = int(depth[cell]) + 1
            queue.append(step)
            # Further from the player is better; between equals, the nearer one.
            var score := float((threat - step).length_squared()) - 0.05 * float(depth[step])
            if score > goal_score:
                goal = step
                goal_score = score
    route = []
    while goal != origin:
        route.push_front(goal)
        goal = came[goal]
    if route.is_empty():
        _flee_routes.erase(wild_id)
        return Vector2i.ZERO
    var first: Vector2i = route.pop_front()
    _flee_routes[wild_id] = route.slice(0, FLEE_REPLAN_STEPS)
    return first - origin

## per-frame
func _update_overworld_idle_sprites(delta: float) -> void:
    var sprites: Array[Sprite2D] = []
    var animated: Array = deployed_pokemon.values()
    for near_id in nearby_wild_ids():
        if wild_pokemon.has(near_id): animated.append(wild_pokemon[near_id])
    for data in animated:
        if bool(data.get("burrowed", false)) or bool(data.get("is_egg", false)):
            continue
        var sprite := data.get("sprite") as Sprite2D
        if is_instance_valid(sprite):
            sprites.append(sprite)
    if is_instance_valid(follower_sprite):
        sprites.append(follower_sprite)
    var camera := get_viewport().get_camera_2d()
    var zoom := Vector2.ONE if camera == null else camera.zoom
    var half_view := get_viewport_rect().size / zoom * 0.5 + Vector2(64, 64)
    for sprite in sprites:
        var distance := sprite.global_position - player.global_position
        if absf(distance.x) > half_view.x or absf(distance.y) > half_view.y:
            continue
        if not sprite.visible or sprite.hframes < 2:
            continue
        var previous: Vector2 = sprite.get_meta("idle_last_position", sprite.position)
        sprite.set_meta("idle_last_position", sprite.position)
        if not previous.is_equal_approx(sprite.position):
            sprite.set_meta("idle_seconds", 0.0)
            continue
        var elapsed := float(sprite.get_meta("idle_seconds", 0.0)) + delta
        sprite.set_meta("idle_seconds", elapsed)
        # Retain the facing pair and use the source standing/dance cadence.
        if elapsed >= 16.0 / 60.0:
            sprite.set_meta("idle_seconds", fmod(elapsed, 16.0 / 60.0))
            var next_frame := sprite.frame ^ 1
            if next_frame < sprite.hframes:
                sprite.frame = next_frame

## One material of each shader the world makes while playing (the wading
## splash, swimming Pokemon), for main to draw once behind the loading screen:
## a canvas shader compiles when it is first drawn.
func warm_up_materials() -> Array[Material]:
    var swimmer := ShaderMaterial.new()
    swimmer.shader = _water_pokemon_shader()
    return [_tidal_puddle_material(), swimmer]

func _tidal_puddle_material() -> ShaderMaterial:
    return tides.tidal_puddle_material()

## per-frame
func _place_normal_grass_fronts() -> int:
    if active_area_id != "OVERWORLD" or exact_world == null:
        return 0
    if active_field_move in ["FLY", "RIDE", "SURF"]:
        return 0
    # DrawPlayerLower/Upper splits the 16px actor at row 8. Grass is between
    # those two parts: preserve the head, cover the lower half with source art.
    var center := to_local(player.sprite.global_position.round())
    var lower_half := Rect2(center + Vector2(-8, 0), Vector2(16, 8))
    var first := Vector2i(floori(lower_half.position.x / TILE), floori(lower_half.position.y / TILE))
    var last := Vector2i(floori((lower_half.end.x - 1) / TILE), floori((lower_half.end.y - 1) / TILE))
    var index := 0
    for y in range(first.y, last.y + 1):
        for x in range(first.x, last.x + 1):
            var cell := Vector2i(x, y)
            # Names first: the tile object is only needed under grass.
            var names := _exact_names_at(cell)
            if names.is_empty():
                continue
            var base := _source_tile_key(names[0])
            var upper := _source_tile_key(names[1])
            if base not in ["grass1", "grass2", "grass3", "grass4", "grass_sand1", "grass_sand2", "grass_sand3", "grass_graveyard1", "grass_savanna1", "grass_savanna2"] and upper not in ["grass1", "grass2_over", "grass3_over", "grass4_over", "grass5_over", "grass6_over", "grass_savanna1", "grass_savanna2"]:
                continue
            var tile := _frame_tile(cell)
            var tick := int(world_elapsed_seconds * 60.0)
            var stream = get_node_or_null("DecorLayer/ExactUpperTileStream")
            if stream != null:
                tick = int(stream.source_animation_tick)
            var spec := SourceWorldData.render_spec(tile, true, 0, tick)
            if spec.is_empty() and base in ["grass_savanna1", "grass_savanna2"]:
                spec = SourceWorldData.render_spec(tile, false, 0, tick)
            if spec.is_empty():
                continue
            var region: Rect2 = spec.get("region", Rect2(0,0,16,16))
            var origin := Vector2(cell * TILE) + Vector2(spec.get("offset",Vector2.ZERO))
            var clipped := Rect2(origin, region.size).intersection(lower_half)
            if not clipped.has_area():
                continue
            var front := normal_grass_front_sprite
            if index > 0:
                while grass_front_sprites.size() < index:
                    var extra := Sprite2D.new()
                    extra.centered = false
                    extra.region_enabled = true
                    extra.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
                    extra.z_as_relative = false
                    add_child(extra)
                    grass_front_sprites.append(extra)
                front = grass_front_sprites[index - 1]
            front.texture = spec.get("texture")
            front.region_rect = Rect2(region.position + clipped.position - origin, clipped.size)
            # Neither setter skips an unchanged value.
            if front.position != clipped.position: front.position = clipped.position
            if front.z_index != player.z_index + 1: front.z_index = player.z_index + 1
            front.show()
            index += 1
    return index

func set_active_field_move(pokemon_data: Dictionary, move: String, ball_landing: bool = false) -> bool:
    return field_moves.set_active_field_move(pokemon_data, move, ball_landing)

func same_party_actor(first: Dictionary, second: Dictionary) -> bool:
    var identity = str(first.get("party_ecology_id", ""))
    return not identity.is_empty() and identity == str(second.get("party_ecology_id", ""))

var dig_return_position := Vector2.ZERO
var dig_step_active := false
var dig_step_target := Vector2.ZERO
var dig_step_direction := Vector2.ZERO
var dig_action_pending := false

func tick_dig_motion(input_direction: Vector2, speed: float, delta: float) -> void:
    field_moves.tick_dig_motion(input_direction, speed, delta)

## per-frame
func field_movement_direction(input_direction: Vector2) -> Vector2:
    return field_moves.field_movement_direction(input_direction)

## per-frame
func field_motion_completed(before: Vector2, after: Vector2, movement_direction: Vector2) -> void:
    field_moves.field_motion_completed(before, after, movement_direction)

## per-frame
func try_pre_move_field_jump(before: Vector2, movement_direction: Vector2):
    return field_moves.try_pre_move_field_jump(before, movement_direction)

func _update_friendly_passby(_data: Dictionary, _cell: Vector2i, _owned: bool) -> void:
    # Proximity alone does not trigger CHARM's heart effect.
    pass


func request_fishing_encounter(rod_name: String) -> void:
    if rod_name not in ["OLD ROD", "GOOD ROD", "SUPER ROD"] or not active_field_move.is_empty():
        world_message.emit("Stop the field move before fishing.")
        return
    var target := _player_cell() + _facing_cell()
    var tile: SourceTile = exact_world.tile_at(target) if exact_world != null else null
    if tile == null or not ("water" in tile.name or tile.name == "desert2"):
        world_message.emit("Use the %s while facing water." % rod_name)
        return
    set_gameplay_enabled(false)
    var owner_game := get_parent()
    owner_game.field_item_busy = true
    var fishing_sprite := Sprite2D.new()
    var model: String = owner_game.PLAYER_MODEL_NAMES[owner_game.player_model_index]
    var path := "res://assets/source_exact/player/red/fishing.png" if model == "red" else "res://assets/source_exact/player/%s-fishing.png" % model
    fishing_sprite.texture = owner_game._recolor_texture(load(path), owner_game.PLAYER_MODEL_REPLACE_COLORS[owner_game.player_model_index], owner_game.PLAYER_COLOR_VALUES[owner_game.player_color_index], "fishing:%d:%d" % [owner_game.player_model_index,owner_game.player_color_index])
    fishing_sprite.centered = false
    fishing_sprite.region_enabled = true
    var facing := _facing_cell()
    fishing_sprite.region_rect = Rect2(0 if facing.y < 0 else 16, 0, 16, 24) if facing.y else Rect2(32,0,24,16)
    fishing_sprite.flip_h = facing.x < 0
    fishing_sprite.position = player.position - Vector2(8,8) + Vector2(-8 if facing.x < 0 else 0,-8 if facing.y < 0 else 0)
    fishing_sprite.z_index = player.z_index
    fishing_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
    add_child(fishing_sprite)
    player.sprite.hide()
    play_source_sound("rod1")
    await get_tree().create_timer(120.0 / 60.0).timeout
    var hooked := rng.randi_range(0, 1) == 0
    if not hooked:
        owner_game._show_trainer_tip_message("Not even a nibble...")
        while owner_game.trainer_tip_open: await get_tree().process_frame
        fishing_sprite.queue_free()
        player.sprite.show()
        owner_game.field_item_busy = false
        set_gameplay_enabled(true)
        return
    var choices := _source_fishing_species(tile, rod_name)
    var species: String = choices[rng.randi_range(0, choices.size() - 1)]
    var level := 10 if rod_name == "OLD ROD" else 20 if rod_name == "GOOD ROD" else 30
    # Tile.java rolls each evolution at the rod's fixed encounter level.
    var visited: Dictionary = {}
    while not visited.has(species):
        visited[species] = true
        var next_species := ""
        for evo in PokemonData.info(species).get("evolutions", []):
            var level_evo: bool = String(evo.get("method", "")) == "EVOLVE_LEVEL"
            if level_evo and int(evo.get("parameter", 101)) > level: continue
            if rng.randi_range(0, 255) < (128 if level_evo else 192): continue
            next_species = String(evo.get("species", "")).to_lower()
            break
        if next_species.is_empty(): break
        species = next_species
    var fishing_position := fishing_sprite.position
    # Paced by elapsed time: a 1/60 s timer lasts a whole frame, which made
    # the wiggle twice as long at 30 FPS.
    var wiggle_start := Time.get_ticks_usec()
    for tick in range(64):
        fishing_sprite.position.y = fishing_position.y + (1 if tick % 4 < 2 else 0)
        while Time.get_ticks_usec() - wiggle_start < int((tick + 1) * 1000000.0 / 60.0 / Engine.time_scale):
            await get_tree().process_frame
    fishing_sprite.position = fishing_position
    _show_ecology_emote(fishing_sprite, "!")
    owner_game._show_trainer_tip_message("A bite!")
    while owner_game.trainer_tip_open: await get_tree().process_frame
    set_gameplay_enabled(false)
    await get_tree().create_timer(30.0 / 60.0).timeout
    fishing_sprite.queue_free()
    player.sprite.show()
    owner_game.field_item_busy = false
    battle_requested.emit({
        "id":"fishing", "kind":"wild", "can_run":true, "can_catch":true,
        "fishing":true, "terrain":"AQUATIC", "_wild_level_scaled":true,
        "party":[{"species":species, "level":level}]
    })

func _source_fishing_species(tile: SourceTile, rod_name: String) -> Array:
    var route_name := tile.route_belongs_to.name if tile.route_belongs_to != null else ""
    var fishing_route := "oasis_pond1" if route_name == "oasis1" else "wooded_lake_fishing1" if route_name == "wooded_lake_water1" else "sea1" if tile.name == "water2" else "sand_fishing1" if tile.name == "desert2" else "river1"
    var choices := SourceRouteData.allowed_pokemon(fishing_route)
    if rod_name != "SUPER ROD":
        for species in SourceRouteData.SUPER_ROD_POKEMON: choices.erase(species)
    if rod_name == "OLD ROD":
        for species in SourceRouteData.GOOD_ROD_POKEMON: choices.erase(species)
    return choices

# M74.3.9.24 â€” DIG scope only.  Keep the frozen base implementation for every
# other field move; DIG explicitly recognizes authored soil/fossil surfaces so
# collision bookkeeping cannot make valid ground impossible to dig.
func _dig_tile_is_fossil_site(tile: SourceTile) -> bool:
    return field_moves.dig_tile_is_fossil_site(tile)

func get_dig_hud_state() -> Dictionary:
    return field_moves.get_dig_hud_state()

func _save_source_dig_tile(cell: Vector2i) -> void:
    field_moves.save_source_dig_tile(cell)

func _dig_is_mountain(tile: SourceTile) -> bool:
    return field_moves.dig_is_mountain(tile)

func _connect_source_dig_holes(changed: Vector2i) -> void:
    field_moves.connect_source_dig_holes(changed)

func _fill_source_dig_holes() -> void:
    field_moves.fill_source_dig_holes()

func _collect_source_dig_item(cell: Vector2i) -> bool:
    return field_moves.collect_source_dig_item(cell)

func _finish_shared_agitated_tree(cell:Vector2i,mutation:Dictionary)->void:
    await field_moves.finish_shared_agitated_tree(cell, mutation)

var source_surf_wake_distance := 16.0
var source_surf_wake_direction := Vector2.ZERO
var source_surf_wake_frames: Dictionary = {}


var walked_open_gates: Dictionary = {}

## per-frame
func _animate_walked_gates(before: Vector2, after: Vector2) -> void:
    # PlayerMoving.java removes the gate overlay after six pixels of approach
    # and restores it eleven pixels into the departure, with gate1/gate2 sounds.
    _animate_source_gates(before, after)
    var nearby: Dictionary = walked_open_gates.duplicate()
    var origin := Vector2i((after / float(TILE)).floor())
    if active_field_move != "FLY":
        for y in range(-1, 2):
            for x in range(-1, 2):
                var cell := origin + Vector2i(x, y)
                if bool(built_structures.get(cell, {}).get("gate", false)):
                    nearby[cell] = true
    for raw_cell in nearby:
        var cell: Vector2i = raw_cell
        var data: Dictionary = built_structures.get(cell, {})
        var sprite := data.get("sprite") as Sprite2D
        if not is_instance_valid(sprite) or not bool(data.get("gate", false)):
            walked_open_gates.erase(cell)
            continue
        var center := _cell_center(cell)
        var closest := Geometry2D.get_closest_point_to_segment(center, before, after)
        var open := walked_open_gates.has(cell)
        if not open and active_field_move != "FLY" and closest.distance_to(center) <= 10.0:
            walked_open_gates[cell] = true
            sprite.hide()
            play_source_sound("gate1")
        elif open and (active_field_move == "FLY" or after.distance_to(center) >= 11.0):
            walked_open_gates.erase(cell)
            sprite.show()
            play_source_sound("gate2")

var source_walked_open_gates: Dictionary = {}
## per-frame
func _animate_source_gates(before: Vector2, after: Vector2) -> void:
    var nearby := source_walked_open_gates.duplicate()
    var origin := Vector2i((after / float(TILE)).floor())
    if active_area_id == "OVERWORLD" and exact_world != null and active_field_move != "FLY":
        for y in range(-1,2):
            for x in range(-1,2):
                var cell := origin + Vector2i(x,y)
                # Names from the store: nine tile objects a frame of walking
                # (~190 us on a desktop) only to find no gate.
                var names := _exact_names_at(cell)
                if not names.is_empty() and "gate" in names[0] + names[1] and not built_structures.has(cell): nearby[cell] = true
    for cell in nearby:
        var center := _cell_center(cell)
        var closest := Geometry2D.get_closest_point_to_segment(center,before,after)
        var is_open := source_walked_open_gates.has(cell)
        if not is_open and active_area_id == "OVERWORLD" and active_field_move != "FLY" and closest.distance_to(center) <= 10.0:
            source_walked_open_gates[cell] = true
            play_source_sound("gate1")
        elif is_open and (active_area_id != "OVERWORLD" or active_field_move == "FLY" or after.distance_to(center) >= 11.0):
            source_walked_open_gates.erase(cell)
            play_source_sound("gate2")
        else: continue
        for path in ["GroundLayer/ExactBaseTileStream","DecorLayer/ExactUpperTileStream"]:
            var stream := get_node_or_null(path)
            if stream != null:
                stream.open_gate_cells = source_walked_open_gates.duplicate()
                stream.invalidate_tiles()
