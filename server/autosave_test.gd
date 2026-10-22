# The game's own saves (the app going to the background) are autosaves: a
# <world>.autosave.json next to the player's SAVE, which they never touch. LOAD
# lists each world's save with its autosave under it (touch list and controller
# selector), a world only ever autosaved too; an autosave loads, a SAVE after it
# writes the world's save and drops the autosave, the bins delete both or just
# the autosave, Continue resumes the newer one and the autosave is written as
# safely as the save (a cut .pending is ignored, a cut file falls back to .bak).
# Run: godot --headless --path project -s <this file> -- --touch-ui
# Run it windowed (no --headless) to also save screenshots into SHOTS
# (the system temp folder, or --shots=<folder> after --).
extends SceneTree

const Paths = preload("res://scripts/game_data_paths.gd")
var SHOTS := OS.get_temp_dir().path_join("autosave_ui")

var main: Node
var checks := 0
var failed := 0

func check(ok: bool, what: String) -> void:
    checks += 1
    if not ok:
        failed += 1
        printerr("AUTOSAVE TEST FAIL: ", what)

func _frames(count: int) -> void:
    for i in count: await process_frame

func shot(file: String) -> void:
    if DisplayServer.get_name() == "headless": return
    await RenderingServer.frame_post_draw
    DirAccess.make_dir_recursive_absolute(SHOTS)
    root.get_texture().get_image().save_png(SHOTS.path_join(file))

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

func _new_world(world_name: String) -> void:
    main.world_edit.text = world_name
    main.selected_mode = "NEW"
    main._start_game()
    await _wait_started()
    check(main.started, "%s started" % world_name)
    await _frames(10)

func _parsed(path: String) -> Variant:
    return JSON.parse_string(FileAccess.get_file_as_string(path)) if FileAccess.file_exists(path) else null

func _cut(path: String) -> void:
    var text := FileAccess.get_file_as_string(path)
    var file := FileAccess.open(path, FileAccess.WRITE)
    file.store_string(text.left(text.length() / 2))
    file.close()

func _index(section: String, key: String) -> String:
    var cfg := ConfigFile.new()
    cfg.load(main.saves.index_path)
    return String(cfg.get_value(section, key, ""))

## The touch LOAD list, read afresh.
func _touch_load_list() -> Node:
    main.coop_menu.close()
    var setup = main.touch_ui.surfaces.setup_screen
    setup._set_mode("LOAD")
    setup.saves_signature = []
    await _frames(5)
    return setup

func _row_index(setup: Node, path: String) -> int:
    for i in setup.saves.size():
        if String(setup.saves[i].path) == path: return i
    return -1

func _initialize() -> void:
    for arg in OS.get_cmdline_user_args():
        if arg.begins_with("--shots="): SHOTS = arg.trim_prefix("--shots=")
    var dir := OS.get_temp_dir().path_join("autosave_test_%d" % Time.get_ticks_usec())
    DirAccess.make_dir_recursive_absolute(dir)
    FileAccess.open(dir.path_join(".private-saves-migrated"), FileAccess.WRITE).close()
    Paths.directory = dir

    await _open_main()
    await _new_world("AutoTest")
    var save: String = main.saves.path_for_world("AutoTest")
    var auto: String = main.saves.autosave_path(save)
    var player: Node2D = main.world.get_node("Player")

    # SAVE writes the world's save, no autosave.
    await main._save_current_game()
    check(_parsed(save) is Dictionary and not FileAccess.file_exists(auto), "SAVE writes the world's save only")
    var saved_x := float(_parsed(save).player_x)

    # Going to the background writes the autosave; the save stays byte for byte.
    var save_bytes := FileAccess.get_file_as_bytes(save)
    player.position.x += 16.0
    var auto_x := player.position.x
    main._notification(NOTIFICATION_APPLICATION_PAUSED)
    check(_parsed(auto) is Dictionary and float(_parsed(auto).player_x) == auto_x, "the background save is the autosave")
    check(FileAccess.get_file_as_bytes(save) == save_bytes and not FileAccess.file_exists(save + ".bak"), "the world's save is untouched")
    check(not FileAccess.file_exists(auto + ".pending"), "no .pending left after an autosave")
    check(_index("worlds", "autotest") == save.get_file() and _index("last", "save_path") == auto.get_file(), "the index names the save, last the autosave")
    check(main.saves.find_newest().get("path", "") == auto and main.saves.find("AutoTest").get("path", "") == auto, "Continue resumes the autosave")

    # The autosave is written as safely as the save.
    player.position.x += 16.0
    main._notification(NOTIFICATION_APPLICATION_PAUSED)
    var latest_x := player.position.x
    FileAccess.open(auto + ".pending", FileAccess.WRITE).store_string(FileAccess.get_file_as_string(auto).left(100))
    check(float(main.saves.read(auto).get("player_x", -1)) == latest_x, "a cut autosave .pending is ignored")
    _cut(auto)
    check(_parsed(auto) == null and float(main.saves.read(auto).get("player_x", -1)) == auto_x, "a cut autosave falls back to its .bak")
    check(main.saves.entries().any(func(entry): return entry.path == auto), "the cut autosave is still listed")
    main._notification(NOTIFICATION_APPLICATION_PAUSED)
    check(float(_parsed(auto).player_x) == latest_x and FileAccess.get_file_as_bytes(save) == save_bytes, "the next autosave mends it, the save still untouched")

    # A world only ever autosaved, made a second later (newest first in the list).
    await create_timer(1.1).timeout
    await _open_main()
    await _new_world("OnlyAuto")
    var only_save: String = main.saves.path_for_world("OnlyAuto")
    var only_auto: String = main.saves.autosave_path(only_save)
    main._notification(NOTIFICATION_APPLICATION_PAUSED)
    check(FileAccess.file_exists(only_auto) and not FileAccess.file_exists(only_save), "OnlyAuto has just an autosave")

    # LOAD: worlds newest first, each world's save with its autosave under it.
    await _open_main()
    var listed: Array = main.saves.entries().map(func(entry): return [entry.path, entry.autosave])
    check(listed == [[only_auto, true], [save, false], [auto, true]], "LOAD order: %s" % [listed])
    check(main.saves.find("OnlyAuto").get("path", "") == only_auto, "an autosave-only world is found")
    var setup = await _touch_load_list()
    var rows: Array = setup.load_rows
    var texts: Array = rows.map(func(row): return [row.get_node("Name").text, row.get_node("Info").text.get_slice(" ", 0), row.position.x])
    check(texts == [["OnlyAuto", "AUTOSAVE", 0.0], ["AutoTest", String(_parsed(save).player_name).to_upper().get_slice(" ", 0), 0.0], ["AutoTest", "AUTOSAVE", setup.AUTOSAVE_INDENT]],
        "touch rows: %s" % [texts])
    for row in rows:
        for label_name in ["Name", "Info"]:
            var label: Label = row.get_node(label_name)
            check(label.get_minimum_size().x <= label.size.x and label.position.x + label.size.x <= row.get_node("Trash").position.x + 2,
                "%s fits its row: %s > %s" % [label.text, label.get_minimum_size().x, label.size.x])
        check(row.position.x + row.size.x <= 308.0, "the row is inside the list")
    await shot("load_list.png")
    setup._trash(2)
    await _frames(3)
    await shot("load_list_bin_armed.png")
    setup.delete_armed = -1
    # The controller selector shows the same list, autosaves labelled.
    main._open_setup_load_selector()
    var infos := []
    for i in main.setup_load_entries.size():
        main.setup_load_index = i
        main._refresh_setup_load_selector()
        infos.append(main.setup_load_panel.get_node("LoadFrame/SaveInfo").text.begins_with("AUTOSAVE"))
    check(infos == [true, false, true], "controller selector labels: %s" % [infos])
    main.setup_load_index = 2
    main._refresh_setup_load_selector()
    await _frames(2)
    await shot("controller_load_autosave.png")
    main.setup_load_open = false
    main.setup_load_panel.visible = false
    main.setup_panel.visible = true

    # Loading the autosave restores it; the next SAVE writes the world's save
    # and drops the autosave it supersedes.
    setup._load_save(2)
    await _wait_started()
    check(main.started and main.world.get_node("Player").position.x == latest_x, "the autosave loads at its place")
    await main._save_current_game()
    check(float(_parsed(save).player_x) == latest_x and float(_parsed(save + ".bak").player_x) == saved_x, "SAVE after it writes the world's save")
    check(not FileAccess.file_exists(auto) and not FileAccess.file_exists(auto + ".bak"), "and the autosave goes")
    check(_index("last", "save_path") == save.get_file(), "last is the save again")
    main._notification(NOTIFICATION_APPLICATION_PAUSED)
    check(FileAccess.file_exists(auto), "a new autosave")

    # The bin on an autosave deletes just that.
    await _open_main()
    setup = await _touch_load_list()
    var at := _row_index(setup, auto)
    setup._trash(at)
    setup._trash(at)
    check(not FileAccess.file_exists(auto) and not FileAccess.file_exists(auto + ".bak") and FileAccess.file_exists(save), "the autosave's bin deletes just the autosave")
    check(_row_index(setup, auto) == -1 and _row_index(setup, save) != -1, "its row goes")

    # The bin on a world deletes its save, its autosave and their index lines.
    main.saves.write(auto, _parsed(save))
    FileAccess.open(auto + ".pending", FileAccess.WRITE).store_string("{")
    setup = await _touch_load_list()
    at = _row_index(setup, save)
    check(_row_index(setup, auto) == at + 1, "the autosave is back under its world")
    setup._trash(at)
    setup._trash(at)
    for path in [save, save + ".bak", auto, auto + ".bak", auto + ".pending"]:
        check(not FileAccess.file_exists(path), "deleted: %s" % path.get_file())
    check(_index("worlds", "autotest") == "" and _index("last", "save_path") == "", "its index lines go")
    check(setup.saves.map(func(entry): return entry.path) == [only_auto], "only OnlyAuto is left: %s" % [setup.saves.map(func(entry): return entry.path)])

    # An autosave-only world goes with its bin.
    setup._trash(0)
    setup._trash(0)
    check(not FileAccess.file_exists(only_auto) and main.saves.entries().is_empty(), "OnlyAuto deleted")
    while main.saves.cache_cleanup != null and main.saves.cache_cleanup.is_alive(): await process_frame

    print("AUTOSAVE TEST: %d checks, %d failed" % [checks, failed])
    quit(1 if failed > 0 else 0)
