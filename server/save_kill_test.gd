# Single-player saves survive the app being killed (iOS ends suspended apps):
# the save when the app goes to the background, a kill while a save is written
# (a cut .pending file, or a cut save from an older game, falls back to .bak),
# a shared storage write that fails is told, the world still loads, and world
# caches no save needs are removed.
# Run: godot --headless --path project -s <this file> -- --touch-ui
extends SceneTree

const Paths = preload("res://scripts/game_data_paths.gd")
const SharedStorage = preload("res://scripts/shared_storage.gd")
const Cache = preload("res://scripts/source_world_cache.gd")

var main: Node
var checks := 0
var failed := 0

func check(ok: bool, what: String) -> void:
    checks += 1
    if not ok:
        failed += 1
        printerr("SAVE KILL TEST FAIL: ", what)

func _frames(count: int) -> void:
    for i in count: await process_frame

func _open_main() -> void:
    change_scene_to_file("res://scenes/main.tscn")
    await _frames(30)
    main = current_scene
    while not main.startup_complete: await process_frame

func _wait_started() -> void:
    var waited := 0
    while not main.started and waited < 36000:
        await process_frame
        waited += 1

func _parsed(path: String) -> Variant:
    return JSON.parse_string(FileAccess.get_file_as_string(path)) if FileAccess.file_exists(path) else null

func _cut(path: String) -> void:
    var text := FileAccess.get_file_as_string(path)
    var file := FileAccess.open(path, FileAccess.WRITE)
    file.store_string(text.left(text.length() / 2))
    file.close()

func _initialize() -> void:
    var dir := OS.get_temp_dir().path_join("save_kill_test_%d" % Time.get_ticks_usec())
    DirAccess.make_dir_recursive_absolute(dir)
    FileAccess.open(dir.path_join(".private-saves-migrated"), FileAccess.WRITE).close()
    Paths.directory = dir

    await _open_main()
    main.world_edit.text = "KillTest"
    main.selected_mode = "NEW"
    main._start_game()
    await _wait_started()
    check(main.started, "the world started")
    await _frames(10)
    var save: String = main._save_path_for_world("KillTest")
    var seed_value := int(main.world.get("world_seed"))
    var player: Node2D = main.world.get_node("Player")

    # Background: the save is written as the app goes to the background.
    var began := Time.get_ticks_usec()
    main._notification(NOTIFICATION_APPLICATION_PAUSED)
    print("SAVE KILL TEST: background save took %.1f ms" % ((Time.get_ticks_usec() - began) / 1000.0))
    var first = _parsed(save)
    check(first is Dictionary and int(first.world_seed) == seed_value, "saved when the app went to the background")
    check(not FileAccess.file_exists(save + ".pending"), "no .pending left after a save")
    # Not in a battle.
    main.battle_active = true
    player.position.x += 16.0
    main._notification(NOTIFICATION_APPLICATION_PAUSED)
    main.battle_active = false
    check(float(_parsed(save).player_x) == float(first.player_x), "no background save during a battle")

    # A second save keeps the first as .bak.
    main._notification(NOTIFICATION_APPLICATION_PAUSED)
    var second = _parsed(save)
    check(float(second.player_x) == player.position.x and float(_parsed(save + ".bak").player_x) == float(first.player_x), "the save before is kept as .bak")

    # SAVE writes on a thread; going to the background meanwhile waits for it
    # and its own, newer save is the one kept.
    player.position.x += 16.0
    main._save_current_game()
    check(main.save_thread != null, "SAVE writes on a thread")
    player.position.x += 16.0
    main._notification(NOTIFICATION_APPLICATION_PAUSED)
    check(float(_parsed(save).player_x) == player.position.x, "the background save comes after the one in flight")
    while main.save_thread != null: await process_frame
    await _frames(2)
    check(float(_parsed(save).player_x) == player.position.x and main.message_label.text == "GAME SAVED.", "both saves end well")

    # A shared storage write that fails is told, not GAME SAVED.
    var blocker := SharedStorage.path() + ".pending"
    DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(blocker))
    await main._save_current_game()
    check(main.shared_storage_error != OK and "STORAGE BOXES" in main.message_label.text, "a failed storage write is told: %s" % main.message_label.text)
    check(float(_parsed(save).player_x) == player.position.x, "the world itself was saved")
    DirAccess.remove_absolute(ProjectSettings.globalize_path(blocker))
    await main._save_current_game()
    check(main.shared_storage_error == OK and main.message_label.text == "GAME SAVED.", "GAME SAVED once storage can be written")

    # Killed while writing: a cut .pending file is ignored.
    var expected_x := player.position.x
    FileAccess.open(save + ".pending", FileAccess.WRITE).store_string(FileAccess.get_file_as_string(save).left(100))
    check(float(main._find_save_path("KillTest").get("data", {}).get("player_x", -1)) == expected_x, "a cut .pending file is ignored")
    # A save cut by a game from before (written in place) falls back to .bak.
    _cut(save)
    check(_parsed(save) == null, "the save is cut")
    check(float(main._read_save_file(save).get("player_x", -1)) == expected_x, "a cut save falls back to .bak")
    check(main._available_save_entries().any(func(entry): return entry.path == save), "the world is still in the LOAD list")

    # At startup, world caches no save needs are removed, on a thread.
    var cache: String = Cache.cache_path(seed_value, int(main.world.get("map_size_index")))
    check(FileAccess.file_exists(cache), "the world has a cache")
    var unused := [Cache.cache_path(99, 1), Cache.cache_path(99, 1, Cache.CACHE_VERSION)]
    for path in unused + [Cache.cache_directory().path_join("notes.txt")]:
        FileAccess.open(path, FileAccess.WRITE).store_string("x")
    await create_timer(1.1).timeout

    # And it loads.
    await _open_main()
    while main.world_cache_cleanup.is_alive(): await process_frame
    check(not unused.any(func(path): return FileAccess.file_exists(path)), "unused caches removed at startup")
    check(FileAccess.file_exists(cache) and FileAccess.file_exists(Cache.cache_directory().path_join("notes.txt")), "the saved world's cache and other files stay")
    check(main.world_edit.text == "KillTest", "the newest save is offered: %s" % main.world_edit.text)
    main.selected_mode = "LOAD"
    main.setup_load_path = save
    main.setup_load_committed = true
    main._start_game()
    await _wait_started()
    check(main.started and int(main.world.get("world_seed")) == seed_value, "the world loads from .bak")
    check(main.world.get_node("Player").position.x == expected_x, "at the saved place")
    main._notification(NOTIFICATION_APPLICATION_PAUSED)
    check(_parsed(save) is Dictionary, "the next save mends the cut file")

    # Deleting the world removes its .bak too, or it would come back.
    check(main._delete_save("KillTest", save) == OK, "deleted")
    check(not FileAccess.file_exists(save + ".bak") and main._read_save_file(save).is_empty(), "no copy brings it back")
    while main.world_cache_cleanup.is_alive(): await process_frame
    check(not FileAccess.file_exists(cache), "its cache goes with the last save that needed it")

    print("SAVE KILL TEST: %d checks, %d failed" % [checks, failed])
    quit(1 if failed > 0 else 0)
