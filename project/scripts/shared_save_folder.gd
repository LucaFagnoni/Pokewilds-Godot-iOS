extends Node
# A normal Android SAF folder mirrors the engine's local working files.
# Import before loading settings/saves; export only after complete writes.
var bridge: Variant
var last_notice := ""
var exporting := false

func start_exports(main: Node) -> void:
    if bridge == null: return
    await export_files(main)

func prepare(main: Node) -> void:
    if OS.get_name() != "Android" or not Engine.has_singleton("JavaClassWrapper"): return
    bridge = Engine.get_singleton("JavaClassWrapper").wrap("com.godot.game.PokeWildsSharedFolder")
    if bridge == null:
        push_error("This Android build is missing the shared save folder bridge.")
        return
    await prepare_configured_folder(main)

func prepare_configured_folder(main: Node) -> void:
    # Folder selection belongs exclusively to GAME FILES in the swipe panel.
    # A fresh install must reach the title screen without opening another activity.
    if bridge == null or not bridge.configured(): return
    bridge.synchronize(true)
    while bridge.busy(): await get_tree().process_frame
    report_error(main)

func export_files(main: Node) -> void:
    if bridge == null or not bridge.configured(): return
    while exporting: await get_tree().process_frame
    exporting=true
    while bridge.busy(): await get_tree().process_frame
    bridge.synchronize(false)
    while bridge.busy(): await get_tree().process_frame
    report_error(main)
    exporting=false

func report_error(main: Node) -> void:
    if bridge == null: return
    var message: String = bridge.error()
    if message.is_empty() or message == last_notice: return
    last_notice=message
    push_error(message)
    # Ready-time errors are deferred until the existing game dialogue is ready.
    main.call_deferred("_show_message",message)
