# Makes server/fixtures/solo: a single-player save as THIS game writes it, in a
# world played a bit (party, box, bag, built structures, Pokemon left outside,
# discovered cells), plus a "legacy" copy without the keys later versions added.
# fixture_load_test.gd loads both with the code of the day. Run it again only to
# make a new fixture of the current format: keep the old ones, they are the point.
# Run: godot --headless --path project -s ../server/make_solo_fixture.gd -- <folder>
#   (the folder gets saves/ and is made from the seed below; ~1 minute)
extends SceneTree

const Paths = preload("res://scripts/game_data_paths.gd")
const SEED := 12345
const SIZE := 0
const WORLD := "FixtureSolo"

var main: Node
var world: Node2D

func _frames(count: int) -> void:
    for i in count: await process_frame

func _initialize() -> void:
    var args := OS.get_cmdline_user_args()
    var dir := args[0] if args.size() > 0 else OS.get_temp_dir().path_join("solo_fixture_%d" % Time.get_ticks_usec())
    DirAccess.make_dir_recursive_absolute(dir.path_join("saves"))
    FileAccess.open(dir.path_join(".private-saves-migrated"), FileAccess.WRITE).close()
    Paths.directory = dir
    # The world comes from a minimal save with the seed: a new world has a random one.
    var path := dir.path_join("saves/fixturesolo.json")
    var seed_save := FileAccess.open(path, FileAccess.WRITE)
    seed_save.store_string(JSON.stringify({"version": 2, "world_seed": SEED, "world_size": SIZE, "world_name": WORLD,
        "player_name": "RED", "player_x": 0.0, "player_y": 0.0}))
    seed_save.close()
    change_scene_to_file("res://scenes/main.tscn")
    await _frames(30)
    main = current_scene
    while not main.startup_complete: await process_frame
    main.coop_menu.close()
    main.world_edit.text = WORLD
    main.selected_mode = "LOAD"
    main.setup_load_path = path
    main.setup_load_committed = true
    main._start_game()
    var waited := 0
    while not main.started and waited < 36000:
        await process_frame
        waited += 1
    if not main.started: _fail("the world did not start")
    await _frames(20)
    world = main.world
    var player: Node2D = world.get_node("Player")
    print("FIXTURE spawn ", world._player_cell())

    # A party of four, a box with two, and a bag.
    var BattleEngine = preload("res://scripts/battle_engine.gd")
    main.caught_pokemon = [main.caught_pokemon[0],
        BattleEngine.make_pokemon("pikachu", 25), BattleEngine.make_pokemon("eevee", 12), BattleEngine.make_pokemon("onix", 30)]
    main.caught_pokemon[0].level = 14
    main.caught_species = ["machop", "pikachu", "eevee", "onix"]
    main.pokemon_storage = {"BOX 1": [BattleEngine.make_pokemon("rattata", 3), BattleEngine.make_pokemon("zubat", 8)]}
    main.preferred_storage_box = "BOX 1"
    main.inventory["POTION"] = 7
    main.inventory["POKE BALL"] = 12
    main.inventory["LOG"] = 30
    main.inventory["GRASS"] = 30
    main.inventory["HARD STONE"] = 10
    main.map_waypoints = {}
    main.pokedex_progress.seed_owned(main.caught_pokemon)
    main._sync_pokedex_owned()

    # Structures and two Pokemon left outside, on the ground around the spawn.
    var start: Vector2i = world._player_cell()
    var wanted := ["CAMPFIRE", "FENCE", "FENCE", "TORCH", "STORAGE BOX", "SIGN", "WALL"]
    var placed := 0
    var left := [BattleEngine.make_pokemon("diglett", 10), BattleEngine.make_pokemon("psyduck", 15)]
    var deployed := 0
    for ring in range(2, 12):
        for step in range(-ring, ring + 1):
            for cell in [start + Vector2i(step, -ring), start + Vector2i(step, ring), start + Vector2i(-ring, step), start + Vector2i(ring, step)]:
                if placed < wanted.size() and world.place_structure(wanted[placed], cell):
                    placed += 1
                elif deployed < left.size() and placed >= 3:
                    player.position = world._cell_center(cell + Vector2i.LEFT)
                    player.set("facing", Vector2.RIGHT)
                    if world.deploy_pokemon(left[deployed]): deployed += 1
    print("FIXTURE placed %d structures, left %d Pokemon outside" % [placed, deployed])
    if placed < wanted.size() or deployed < left.size(): _fail("no room for the structures and Pokemon")

    # Cells seen: a walk of the spawn's surroundings.
    player.position = world._cell_center(start)
    for dx in range(-60, 61, 12):
        world._discover_around(start + Vector2i(dx, 0), 12)
    print("FIXTURE discovered ", world.discovered_cells.size())

    await main._save_current_game()
    var saved := FileAccess.get_file_as_string(path)
    var data = JSON.parse_string(saved)
    if not data is Dictionary or data.get("caught_pokemon", []).size() != 4: _fail("the save was not written")
    # The same save as an older game wrote it: none of what came later.
    for key in ["pokedex_shiny", "adjacent_worlds", "world_grid_x", "world_grid_y", "source_key_items_initialized",
            "next_party_ecology_id", "storage_shared", "storage_serial", "egg_step_timer", "friendship_step_timer",
            "preferred_storage_box", "waypoints", "options", "player_name_custom", "player_model"]:
        data.erase(key)
    data.world_name = "FixtureLegacy"
    var legacy := FileAccess.open(dir.path_join("saves/fixturelegacy.json"), FileAccess.WRITE)
    legacy.store_string(JSON.stringify(data))
    legacy.close()
    print("FIXTURE written to ", dir)
    quit(0)

func _fail(reason: String) -> void:
    printerr("FIXTURE FAIL: ", reason)
    quit(1)
