# The full map's kept picture (scripts/source_map_raster.gd) in a new world on
# a throwaway data folder: it opens at once, and after discovering ground, a tile
# edit and a building it is still exactly the whole map drawn afresh. Also the
# palm reflections' index against a look at every cell.
# Run with a window (headless, the dummy renderer ignores texture updates):
# godot --path project --resolution 1280x591 -s ../server/map_raster_test.gd -- --touch-ui
extends SceneTree

const Paths = preload("res://scripts/game_data_paths.gd")

var main: Node
var world: Node
var checks := 0
var failed := 0

func check(ok: bool, what: String) -> void:
    checks += 1
    if not ok:
        failed += 1
        printerr("MAP RASTER TEST FAIL: ", what)

func _frames(count: int) -> void:
    for i in count: await process_frame

## The map screen's picture as one image: the fog, tiled, and the blocks.
func _shown() -> Image:
    var raster = main.map_raster
    raster.refresh()
    while raster.draw_dirty(1000000000): pass
    if raster.fog == null: raster.make_view().free()
    var size: Vector2i = raster.bounds.size * raster.PIXELS
    var image := Image.create(size.x, size.y, false, Image.FORMAT_RGBA8)
    var fog: Image = raster.fog.get_image()
    for y in range(0, size.y, fog.get_height()):
        for x in range(0, size.x, fog.get_width()):
            image.blit_rect(fog, Rect2i(Vector2i.ZERO, fog.get_size()), Vector2i(x, y))
    for chunk in raster.chunks:
        var part: Image = raster.chunks[chunk].get_image()
        image.blit_rect(part, Rect2i(Vector2i.ZERO, part.get_size()), chunk * raster.CHUNK * raster.PIXELS)
    return image

func _same_as_whole(what: String) -> void:
    var bounds: Rect2i = main.map_raster.bounds
    var whole: Image = main._m3924_minimap_render(bounds, bounds, world.exact_world)
    var shown := _shown()
    var same := shown.get_data() == whole.get_data()
    if not same:
        shown.save_png(OS.get_temp_dir().path_join("map_raster_shown.png"))
        whole.save_png(OS.get_temp_dir().path_join("map_raster_whole.png"))
    check(same, "the map is the whole map drawn afresh %s (both saved in the temp folder)" % what)

func _palms_match(what: String) -> void:
    var bounds: Rect2i = world.get_map_bounds()
    var scan = load("res://scripts/source_reflection_layer.gd").new()
    scan.exact_world = world.exact_world
    var all: Array = scan._palms_in(bounds.position, bounds.end - Vector2i.ONE)
    scan.free()
    var indexed: Array = world.reflection_layer._palms_in(bounds.position, bounds.end - Vector2i.ONE)
    var same := all.size() == indexed.size()
    for i in mini(all.size(), indexed.size()):
        if all[i] != indexed[i].slice(0, 3): same = false
    check(same and not all.is_empty(), "%d palms indexed as found cell by cell (%d) %s" % [indexed.size(), all.size(), what])

func _initialize() -> void:
    if DisplayServer.get_name() == "headless":
        printerr("MAP RASTER TEST: needs a window, the headless renderer ignores texture updates")
        quit(1)
        return
    var dir := OS.get_temp_dir().path_join("map_raster_test_%d" % Time.get_ticks_usec())
    DirAccess.make_dir_recursive_absolute(dir)
    FileAccess.open(dir.path_join(".private-saves-migrated"), FileAccess.WRITE).close()
    Paths.directory = dir
    change_scene_to_file("res://scenes/main.tscn")
    await _frames(30)
    main = current_scene
    while not main.startup_complete: await process_frame
    main.world_edit.text = "MapTest"
    main.selected_mode = "NEW"
    main._start_game()
    var waited := 0
    while not main.started and waited < 36000:
        await process_frame
        waited += 1
    check(main.started, "the world started")
    await _frames(30)
    world = main.world
    world.encounter_grace_remaining = 1.0e9
    _same_as_whole("after loading")

    # Ground discovered while the map is closed is drawn in the background;
    # the map opens at once, with what it has, and draws the rest.
    var start: Vector2i = world._player_cell()
    for k in 4:
        world._discover_around(start + Vector2i(roundi(cos(k * 1.6) * 30), roundi(sin(k * 1.6) * 24)), 14)
    await _frames(2)
    var opened := Time.get_ticks_usec()
    main._open_game_menu()
    main._show_map_menu()
    check(is_instance_valid(main.map_view_node) and Time.get_ticks_usec() - opened < 100000,
        "the map is up in the same frame (%d us)" % (Time.get_ticks_usec() - opened))
    var frames := 0
    while not main.map_raster.dirty.is_empty() and frames < 600:
        await process_frame
        frames += 1
    check(main.map_raster.dirty.is_empty(), "the blocks left are drawn while it is open (%d frames)" % frames)
    _same_as_whole("after discovering")
    main._close_game_menu()
    await _frames(5)

    # A tile edit (a tree cut down) on discovered ground.
    var edited := Vector2i(-1, -1)
    for key in world.discovered_cells:
        var cell: Vector2i = world._cell_from_key(key)
        var tile: SourceTile = world.exact_world.tile_at(cell)
        if tile != null and not tile.name_upper.is_empty():
            edited = cell
            tile.set_names(tile.name, "")
            break
    check(edited.x != -1, "a discovered tile with art on it")
    world._refresh_exact_streams()
    var raster = main.map_raster
    raster.refresh()
    check(raster.dirty.has((edited - raster.bounds.position) / raster.CHUNK) and raster.dirty.size() <= 4,
        "a tile edit redraws only its blocks (%d of %d)" % [raster.dirty.size(), raster.chunks.size()])
    _same_as_whole("after a tile edit")

    # A building on discovered ground.
    var built := false
    for dy in range(-8, 9):
        for dx in range(-8, 9):
            if not built and world.is_cell_discovered(start + Vector2i(dx, dy)) and start + Vector2i(dx, dy) != world._player_cell():
                built = world.place_structure("FENCE", start + Vector2i(dx, dy))
    check(built, "a fence was built")
    await _frames(2)
    _same_as_whole("after building")

    _palms_match("after loading")
    # Cut one palm down: the index follows the edit.
    var bounds: Rect2i = world.get_map_bounds()
    var palms: Array = world.reflection_layer._palms_in(bounds.position, bounds.end - Vector2i.ONE)
    if not palms.is_empty():
        var cell: Vector2i = palms[0][3]
        var palm: SourceTile = world.exact_world.tile_at(cell)
        palm.set_names("sand1" if palm.name == "tree5" else palm.name, "")
        world._refresh_exact_streams()
        _palms_match("after cutting one down")
    print("MAP RASTER TEST: %d checks, %d failed" % [checks, failed])
    quit(1 if failed > 0 else 0)
