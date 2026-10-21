extends RefCounted
## Field helpers for touch: a label over A naming what it will do, a chip for
## the active field move (tap to stop it), and arrows for the selections that
## the controller's LB/RB used to cycle (DIG material, PAINT picture, BUILD, TELEPORT).

const HINT_POLL := 0.2
const SELECTABLE := ["DIG", "PAINT"]
const HudStyle = preload("res://scripts/hud_style.gd")

var main: Node
var ui: Node
var hint_chip: Control
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
    # HUD chips at the top centre, on the top row's line or GAP under the
    # clock, and clear of the BUILD boxes when the game shows them.
    var bounds: Rect2 = main.touch_controls.usable_rect
    var top := bounds.position.y + HudStyle.MARGIN
    if main.build_panel.visible: top = main.build_panel.get_global_rect().end.y + HudStyle.GAP
    var clock: Control = main.status_hud.clock_chip
    if is_instance_valid(clock) and clock.is_visible_in_tree(): top = maxf(top, clock.get_global_rect().end.y + HudStyle.GAP)
    var centre: float = main.get_viewport().get_visible_rect().size.x / 2.0
    var stop := "STOP " + move
    var width := _width(stop)
    var result := [[stop, func(): ui.press("cancel"), Rect2(Vector2(roundf(centre - width / 2.0), top), Vector2(width, HudStyle.ROW))]]
    var value := ""
    if move == "BUILD": value = String(w._current_build_name())
    elif move == "TELEPORT": value = "DESTINATION"
    elif move in SELECTABLE:
        var choices: Array = w.DIG_CHOICES if move == "DIG" else w.PAINT_CHOICES
        var index: int = w.dig_selection_index if move == "DIG" else w.paint_selection_index
        value = String(choices[index]) if index < choices.size() else ""
    if not value.is_empty():
        var y := top + HudStyle.ROW + HudStyle.GAP
        width = maxf(_width(value), 92.0)
        var left := roundf(centre - width / 2.0)
        result.append(["<", func(): ui.press("shoulder_left"), Rect2(Vector2(left - HudStyle.GAP - HudStyle.ROW, y), Vector2(HudStyle.ROW, HudStyle.ROW))])
        result.append([value, func(): ui.press("shoulder_right"), Rect2(Vector2(left, y), Vector2(width, HudStyle.ROW))])
        result.append([">", func(): ui.press("shoulder_right"), Rect2(Vector2(left + width + HudStyle.GAP, y), Vector2(HudStyle.ROW, HudStyle.ROW))])
    return result

## A chip's width for this text (PAD each side of the ink).
static func _width(text: String) -> float:
    return HudStyle.FONT.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, HudStyle.FONT_SIZE).x - 1.0 + HudStyle.PAD * 2.0

## What A would do, as a HUD chip on A's line, left of A (and of B when B
## shares that line), so it covers neither the buttons nor the player.
func refresh(delta: float, in_field: bool) -> void:
    if hint_chip == null:
        hint_chip = HudStyle.chip(ui.chrome, "AHint")
    var pad: Control = main.touch_controls
    var a_button := pad.get_node_or_null("A") as Control
    poll -= delta
    if poll <= 0.0:
        poll = HINT_POLL
        hint_text = a_hint() if in_field and pad.visible else ""
    hint_chip.visible = not hint_text.is_empty() and a_button != null and a_button.is_visible_in_tree()
    if not hint_chip.visible: return
    var text := "%s: %s" % [pad.face_letter("A"), hint_text]
    if (hint_chip.get_node("Text") as Label).text != text: HudStyle.set_chip_text(hint_chip, text)
    if hint_chip.get_meta("dark", true) != HudStyle.dark:
        hint_chip.set_meta("dark", HudStyle.dark)
        hint_chip.queue_redraw()
    var rect := a_button.get_global_rect()
    var right := rect.position.x - HudStyle.GAP
    var b_button := pad.get_node_or_null("B") as Control
    if b_button != null and b_button.is_visible_in_tree():
        var b := b_button.get_global_rect()
        if b.position.y < rect.get_center().y + HudStyle.ROW / 2.0 and b.end.y > rect.get_center().y - HudStyle.ROW / 2.0 and b.position.x < rect.position.x:
            right = minf(right, b.position.x - HudStyle.GAP)
    var at := Vector2(right - hint_chip.size.x, roundf(rect.get_center().y - hint_chip.size.y / 2.0))
    if hint_chip.position != at: hint_chip.position = at
