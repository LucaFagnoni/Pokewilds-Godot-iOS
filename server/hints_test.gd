# On a touch screen no visible label tells the player to press A or B.
# Run: godot --headless --path project -s <this file> -- --touch-ui   (also without --touch-ui: the controller hints stay)
extends SceneTree

const Paths = preload("res://scripts/game_data_paths.gd")

var main: Node
var checks := 0
var failed := 0
var touch := OS.get_cmdline_user_args().has("--touch-ui")

func check(ok: bool, what: String) -> void:
    checks += 1
    if not ok:
        failed += 1
        printerr("HINTS TEST FAIL: ", what)

func hints(node: Node, out: Array) -> void:
    if (node is Label or node is Button) and node.is_visible_in_tree():
        var text: String = node.text
        for part in text.split("\n"):
            if part.begins_with("A: ") or part.begins_with("B: ") or " B: " in part:
                out.append(text)
                break
    for child in node.get_children(): hints(child, out)

func scan(what: String) -> Array:
    await create_timer(0.1).timeout
    var out := []
    hints(root, out)
    if touch: check(out.is_empty(), "%s shows no button hint on touch: %s" % [what, out])
    return out

func _initialize() -> void:
    create_timer(300.0).timeout.connect(func(): printerr("HINTS TEST FAIL: timed out"); quit(2))
    var dir := OS.get_temp_dir().path_join("hints_test_%d" % Time.get_ticks_usec())
    DirAccess.make_dir_recursive_absolute(dir)
    FileAccess.open(dir.path_join(".private-saves-migrated"), FileAccess.WRITE).close()
    Paths.directory = dir
    change_scene_to_file("res://scenes/main.tscn")
    for i in 30: await process_frame
    main = current_scene
    while not main.startup_complete: await process_frame
    check(main.touch_on() == touch, "touch_on matches --touch-ui")
    var menu: Control = main.coop_menu
    menu.open()
    var shown := []
    for page in ["title", "servers", "password_join", "password_set", "browse", "load"]:
        menu._go(page)
        menu._update_status()
        shown += await scan("co-op page " + page)
    menu.close()
    main._open_modding_menu()
    shown += await scan("MODDING")
    main.mod_menu_panel.hide()
    main._open_game_files_menu()
    shown += await scan("GAME FILES")
    main.game_files_menu.hide()
    if not touch: check(not shown.is_empty(), "the controller still shows hints")
    print("hints_test: %d checks, %d failed" % [checks, failed])
    quit(1 if failed > 0 else 0)
