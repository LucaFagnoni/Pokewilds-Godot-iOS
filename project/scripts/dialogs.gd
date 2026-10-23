extends RefCounted

## Field messages and dialogue boxes: the bottom message box and its text
## scrolling, Unown text, trainer tips, the sign editor, YES/NO questions,
## the acquired-resource popup and the loading screen's tips.
## Split out of main.gd; reaches the game through `main`.

const GameOptions = preload("res://scripts/game_options.gd")
const SourceEventData = preload("res://scripts/source_event_data.gd")
const JOHTO_FONT := preload("res://assets/source_text_font.fnt")
const UNOWN_FONT := preload("res://assets/source_exact/global/unown_font.fnt")
const GENERATION_TIP_SECONDS := 5.0

var main: GameMain
var trainer_tip_pages: Array[String] = []
var trainer_tip_page_index := 0
var message_reveal_elapsed := 0.0
var message_reveal_text := ""

func _init(owner_main: GameMain) -> void:
    main = owner_main

func show_message(message: String) -> void:
    if main.trainer_tip_open:
        close_trainer_tip()
    if main.game_menu_open and main.item_pocket_menu.visible and not main.battle_active:
        main.bag_notice = message
        main.bag_notice_item = main.battle_item_menu_names[main.battle_item_menu_index]             if main.battle_item_menu_index < main.battle_item_menu_names.size() else ""
        main.item_pocket_description.text = message
        return
    # Active field moves must not paint control instructions across the bottom
    # dialogue area. Keep actual results/errors, but suppress selection/control
    # hints because the dedicated field/build UI already carries the state.
    var active_move := String(main.world.get("active_field_move")).to_upper()
    if not active_move.is_empty():
        if message.begins_with("BUILD:") or message.begins_with("DIG:") or \
                message.begins_with("PAINT:") or "L/R selects" in message or \
                message.begins_with("FLY is active.") or \
                message.begins_with("Fly to safe ground") or \
                message.begins_with("SURF lets you cross water") or \
                message.begins_with("RIDE increases speed"):
            return
    if main.build_menu_open and message.begins_with("BUILD:"):
        return
    main.message_label.add_theme_font_override("font", JOHTO_FONT)
    main.message_label.add_theme_font_size_override("font_size", 10)
    main.message_label.clip_text = true
    main.message_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    main.message_label.max_lines_visible = 3
    main.message_label.text = message
    main.message_label.visible_characters = 0
    message_reveal_elapsed = 0.0
    message_reveal_text = message
    main.message_panel.visible = true
    main.message_timer = main.MESSAGE_HOLD_SECONDS + message.length() * main.BATTLE_TEXT_CHAR_DELAY / GameOptions.text_multiplier()

## The bottom message box: its text scrolls in, then it closes when its time is up.
func update_message_box(delta: float) -> void:
    if main.message_label.text != message_reveal_text:
        main.message_label.visible_characters = -1
    if main.message_timer > 0.0:
        if main.message_label.visible_characters >= 0:
            message_reveal_elapsed += delta
            main.message_label.visible_characters = mini(main.message_label.text.length(),int(message_reveal_elapsed * GameOptions.text_multiplier() / main.BATTLE_TEXT_CHAR_DELAY))
        main.message_timer -= delta
        if main.message_timer <= 0.0:
            main.message_panel.visible = false

func show_unown_message(message: String) -> void:
    if main.trainer_tip_open:
        close_trainer_tip()
    main.message_label.add_theme_font_override("font", UNOWN_FONT)
    main.message_label.add_theme_font_size_override("font_size", 9)
    main.message_label.clip_text = true
    main.message_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    main.message_label.max_lines_visible = 3
    main.message_label.text = message
    main.message_panel.visible = true
    main.message_timer = 1.2

func _trainer_tip_wrap_lines(message: String, max_chars: int = 39) -> Array[String]:
    var result: Array[String] = []
    for paragraph in message.split("\n"):
        var current := ""
        for raw_word in String(paragraph).split(" ", false):
            var word := String(raw_word)
            var candidate := word if current.is_empty() else current + " " + word
            if candidate.length() <= max_chars:
                current = candidate
            else:
                if not current.is_empty():
                    result.append(current)
                current = word
        if not current.is_empty():
            result.append(current)
    if result.is_empty():
        result.append("")
    return result

func show_trainer_tip_message(message: String) -> void:
    trainer_tip_pages.clear()
    var lines := _trainer_tip_wrap_lines(message)
    var index := 0
    while index < lines.size():
        var page_lines: Array[String] = []
        page_lines.append(lines[index])
        if index + 1 < lines.size():
            page_lines.append(lines[index + 1])
        trainer_tip_pages.append("\n".join(page_lines))
        index += 2
    trainer_tip_page_index = 0
    main.trainer_tip_open = true
    main.world.set_gameplay_enabled(false)
    _show_trainer_tip_page()

func _show_trainer_tip_page() -> void:
    if trainer_tip_pages.is_empty():
        close_trainer_tip()
        return
    main.message_label.add_theme_font_override("font", JOHTO_FONT)
    main.message_label.add_theme_font_size_override("font_size", 8)
    main.message_label.clip_text = true
    main.message_label.autowrap_mode = TextServer.AUTOWRAP_OFF
    main.message_label.max_lines_visible = 2
    main.message_label.text = trainer_tip_pages[trainer_tip_page_index]
    main.message_panel.visible = true
    main.message_timer = 0.0
    if main.trainer_tip_continue != null:
        main.trainer_tip_continue.visible = (
            trainer_tip_page_index < trainer_tip_pages.size() - 1
        )

func advance_trainer_tip() -> void:
    if not main.trainer_tip_open:
        return
    if trainer_tip_page_index < trainer_tip_pages.size() - 1:
        trainer_tip_page_index += 1
        _show_trainer_tip_page()
        return
    close_trainer_tip()

func close_trainer_tip() -> void:
    main.trainer_tip_open = false
    trainer_tip_pages.clear()
    trainer_tip_page_index = 0
    if main.trainer_tip_continue != null:
        main.trainer_tip_continue.visible = false
    main.message_panel.visible = false
    main.message_timer = 0.0
    if (
            main.started
            and not main.battle_active
            and not main.game_menu_open
            and not main.craft_menu_open
            and not main.build_menu_open
            and not main.storage_menu_open
        ):
        main.world.set_gameplay_enabled(true)

## A yes/no question whose cursor starts on NO, so that pressing A through it
## answers no.
func ask_yes_no_starting_on_no(prompt: String) -> bool:
    main.world.set_gameplay_enabled(false)
    # The question is only sent button presses while this is set; without it
    # the question appeared and then answered to nothing.
    var was_active := main.progression_active
    main.progression_active = true
    main.progression.show_progression_yes_no(prompt)
    main.progression_choice_index = 1
    main.progression.refresh_progression_yes_no()
    var result = await main.progression_choice_made
    main.progression.hide_progression_overlay()
    main.progression_active = was_active
    main.world.set_gameplay_enabled(not main._field_ui_blocks_gameplay(main.build_menu_open))
    return int(result) == 1

func create_sign_editor() -> void:
    main.sign_dialog = ConfirmationDialog.new()
    var sign_theme := Theme.new()
    sign_theme.default_font = JOHTO_FONT
    sign_theme.default_font_size = 10
    main.sign_dialog.theme = sign_theme
    main.sign_dialog.title = "Write on the sign"
    main.sign_dialog.exclusive = true
    main.sign_dialog.ok_button_text = "WRITE"
    main.sign_edit = LineEdit.new()
    main.sign_edit.placeholder_text = "Sign text"
    main.sign_edit.max_length = 64
    main.sign_edit.position = Vector2(12, 18)
    main.sign_edit.size = Vector2(236, 30)
    main.sign_dialog.add_child(main.sign_edit)
    main.get_node("UI").add_child(main.sign_dialog)
    main.sign_dialog.confirmed.connect(_confirm_sign_text)

func _confirm_sign_text() -> void:
    if main.sign_edit_mode == "BEACON":
        if main.world.has_method("set_structure_beacon_label"):
            main.world.call("set_structure_beacon_label", main.sign_edit_cell, main.sign_edit.text)
        return
    if main.world.has_method("set_structure_sign_text"):
        main.world.call("set_structure_sign_text", main.sign_edit_cell, main.sign_edit.text)

func show_acquired_resource(item_name: String, amount: int) -> void:
    if main.resource_popup.visible and main.resource_popup_timer > 0.0 and main.resource_popup_name == item_name:
        main.resource_popup_amount += amount
    else:
        main.resource_popup_name = item_name
        main.resource_popup_amount = amount
    main.resource_popup_text.text = "GOT\nx%d %s" % [
        main.resource_popup_amount, main.resource_popup_name
    ]
    main.resource_popup.visible = true
    main.resource_popup_timer = 0.9

func show_generation_tip() -> void:
    if SourceEventData.TRAINER_TIPS.is_empty():
        return
    var next_index := main.battle_rng.randi_range(0, SourceEventData.TRAINER_TIPS.size() - 1)
    if SourceEventData.TRAINER_TIPS.size() > 1 and next_index == main.generation_tip_index:
        next_index = (next_index + 1) % SourceEventData.TRAINER_TIPS.size()
    main.generation_tip_index = next_index
    main.generation_tip_title.text = "- Trainer Tips -"
    main.generation_tip_text.text = _format_generation_tip(
        String(SourceEventData.TRAINER_TIPS[main.generation_tip_index])
    )
    main.generation_tip_timer = GENERATION_TIP_SECONDS

func _format_generation_tip(tip: String) -> String:
    var words := tip.strip_edges().split(" ", false)
    if words.size() < 2:
        return tip
    var line_count := 3 if tip.length() > 64 else 2
    var lines: Array[String] = []
    var start := 0
    for line_index in range(line_count):
        var words_left := words.size() - start
        var lines_left := line_count - line_index
        if lines_left <= 1:
            var final_line := ""
            for word_index in range(start, words.size()):
                final_line += (
                    " " if not final_line.is_empty() else ""
                ) + String(words[word_index])
            lines.append(final_line)
            break
        var remaining_length := 0
        for word_index in range(start, words.size()):
            remaining_length += String(words[word_index]).length()
        remaining_length += maxi(0, words_left - 1)
        var target_length := ceili(float(remaining_length) / float(lines_left))
        var line := ""
        while start < words.size() - (lines_left - 1):
            var word := String(words[start])
            var candidate := line + (" " if not line.is_empty() else "") + word
            if not line.is_empty() and candidate.length() > target_length:
                break
            line = candidate
            start += 1
        lines.append(line)
    return "\n".join(lines)

func _two_line_generation_tip(tip: String) -> String:
    # Compatibility helper for older QA entry points.
    return _format_generation_tip(tip)
