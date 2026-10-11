extends Control
## Overworld window for a Pokemon that levelled up outside battle and wants a
## fifth move: its four moves and a way to keep them, over the world rather
## than on the battle screen.
signal chosen(index: int)
const Options = preload("res://scripts/game_options.gd")
var main: Node
var rows: Array[Label] = []
var cursor: TextureRect
var selection := 0

## Returns the slot to replace (0-3), or -1 to keep the old moves.
func ask(owner_main: Node, pokemon: Dictionary, move_name: String) -> int:
    main = owner_main
    name = "FieldMoveChoice"
    size = Vector2(320, 180)
    z_index = 300
    mouse_filter = Control.MOUSE_FILTER_IGNORE
    set_anchors_and_offsets_preset(Control.PRESET_CENTER)
    var panel := Panel.new()
    panel.size = Vector2(216, 124)
    panel.position = (size - panel.size) * 0.5
    panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
    panel.add_theme_stylebox_override("panel", Options.style())
    add_child(panel)
    # Two fixed lines, so a long name never runs down into the list.
    var lines := ["%s wants to learn" % PokemonState.display_name(pokemon).to_upper(),
        "%s. Forget which?" % move_name.replace("_", " ")]
    for line in range(lines.size()):
        var title: Label = main._source_ui_label(panel, "Title%d" % line, Vector2(14, 11 + line * 12), Vector2(188, 12), 8, lines[line])
        var width := title.get_theme_font("font").get_string_size(title.text, HORIZONTAL_ALIGNMENT_LEFT, -1, 8).x
        title.scale.x = minf(1.0, 188.0 / maxf(1.0, width))
    var moves: Array = pokemon.get("moves", [])
    for index in range(moves.size() + 1):
        var text := "KEEP OLD MOVES" if index == moves.size() else String(moves[index]).replace("_", " ")
        rows.append(main._source_ui_label(panel, "Move%d" % index,
            Vector2(30, 44 + index * 14), Vector2(170, 14), 8, text))
    cursor = main._source_texture_rect(panel, "Cursor", Vector2(18, 44), Vector2(5, 7),
        main.source_command_cursor.texture)
    _place()
    var picked: int = await chosen
    queue_free()
    return picked

func _place() -> void:
    main._align_menu_tick(cursor, rows[selection])

func _input(event: InputEvent) -> void:
    if rows.is_empty() or event.is_echo():
        return
    var handled := true
    if event.is_action_pressed("move_up"):
        selection = wrapi(selection - 1, 0, rows.size())
        _place()
    elif event.is_action_pressed("move_down"):
        selection = wrapi(selection + 1, 0, rows.size())
        _place()
    elif event.is_action_pressed("confirm"):
        chosen.emit(-1 if selection == rows.size() - 1 else selection)
    elif event.is_action_pressed("cancel"):
        chosen.emit(-1)
    else:
        # Nothing else reaches the world or its menus while this is open.
        handled = event.is_action_type()
    if handled:
        get_viewport().set_input_as_handled()
