extends RefCounted
## Field helpers for touch: a label over A naming what it will do, a chip for
## the active field move (tap to stop it), and arrows for the selections that
## the controller's LB/RB used to cycle (DIG material, PAINT picture, BUILD, TELEPORT).

const HINT_POLL := 0.2
const SELECTABLE := ["DIG", "PAINT"]

var main: Node
var ui: Node
var hint_label: Label
var hint_text := ""
var poll := 0.0

func _init(owner_main: Node, owner_ui: Node) -> void:
    main = owner_main
    ui = owner_ui

## What A would do on the tile in front of the player ("" when nothing).
func a_hint() -> String:
    var w: Node = main.world
    if not is_instance_valid(w) or not w.gameplay_enabled: return ""
    var target: Vector2i = w._player_cell() + w._facing_cell()
    var drops = w.dropped_items()
    if drops.records.has(drops.key(target)): return "PICK UP"
    if not String(w.planting_item).is_empty(): return "PLANT"
    var move := String(w.active_field_move)
    match move:
        "BUILD": return "BUILD"
        "CUT": return "CUT"
        "DIG": return "DIG"
        "SMASH": return "SMASH"
        "HEADBUTT": return "HEADBUTT"
        "TELEPORT": return "TELEPORT"
        "PAINT": return "PAINT"
    if w.wild_eggs.has(target): return "EGG"
    if target == w.follower_cell and not w.follower_pokemon.is_empty(): return "TALK"
    if w._wild_id_at_cell(target) >= 0: return "ATTACK" if move == "ATTACK" else "TALK"
    if w.deployed_pokemon.has(target): return "ATTACK" if move == "ATTACK" else "TALK"
    if w.interior_interactables.has(target): return "USE"
    if w.landmarks.has(target):
        match String(w.landmarks[target].get("type", "")):
            "sign", "source_route_sign": return "READ"
            "source_house", "source_cave", "source_area": return "ENTER"
            "campfire": return "CRAFT"
            "item", "source_key": return "TAKE"
        return "CHECK"
    if w.built_structures.has(target): return "USE"
    if move.is_empty():
        if w.is_empty_planting_hole(target): return "PLANT"
        if w._can_prompt_shore_surf(target): return "SURF"
        var anchor: Vector2i = w._exact_resource_anchor(target)
        if anchor.x > -2147483648 and not String(w._exact_berry_name(anchor)).is_empty(): return "PICK"
    return ""

## Buttons for the field surface (all non-modal; the pad stays).
func buttons() -> Array:
    var w: Node = main.world
    var move := String(w.active_field_move)
    if move.is_empty(): return []
    var bounds: Rect2 = main.touch_controls.usable_rect
    var top := bounds.position.y + 4
    var centre := bounds.get_center().x
    var result := [["STOP " + move, func(): ui.press("cancel"), Rect2(Vector2(centre - 40, top), Vector2(80, 20))]]
    var value := ""
    if move == "BUILD": value = String(w._current_build_name())
    elif move == "TELEPORT": value = "DESTINATION"
    elif move in SELECTABLE:
        var choices: Array = w.DIG_CHOICES if move == "DIG" else w.PAINT_CHOICES
        var index: int = w.dig_selection_index if move == "DIG" else w.paint_selection_index
        value = String(choices[index]) if index < choices.size() else ""
    if not value.is_empty():
        var y := top + 24
        result.append(["<", func(): ui.press("shoulder_left"), Rect2(Vector2(centre - 72, y), Vector2(22, 20))])
        result.append([value, func(): ui.press("shoulder_right"), Rect2(Vector2(centre - 46, y), Vector2(92, 20))])
        result.append([">", func(): ui.press("shoulder_right"), Rect2(Vector2(centre + 50, y), Vector2(22, 20))])
    return result

## Places the label over A; called every frame.
func refresh(delta: float, in_field: bool) -> void:
    if hint_label == null:
        hint_label = Label.new()
        hint_label.name = "AHint"
        hint_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
        hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
        hint_label.add_theme_font_override("font", preload("res://assets/source_text_font_white.fnt"))
        hint_label.add_theme_font_size_override("font_size", 7)
        hint_label.add_theme_color_override("font_color", Color.WHITE)
        hint_label.add_theme_color_override("font_outline_color", Color.BLACK)
        hint_label.add_theme_constant_override("outline_size", 3)
        ui.chrome.add_child(hint_label)
    var pad: Control = main.touch_controls
    var a_button := pad.get_node_or_null("A") as Control
    poll -= delta
    if poll <= 0.0:
        poll = HINT_POLL
        hint_text = a_hint() if in_field and pad.visible else ""
    hint_label.visible = not hint_text.is_empty() and a_button != null and a_button.is_visible_in_tree()
    if not hint_label.visible: return
    hint_label.text = hint_text
    var rect := a_button.get_global_rect()
    hint_label.size = Vector2(60, 10)
    hint_label.position = Vector2(rect.get_center().x - 30, rect.position.y - 11)
