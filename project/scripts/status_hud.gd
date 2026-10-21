extends RefCounted
## OPTIONS > BATTERY and CLOCK, like a phone's status bar: the clock at the top
## centre of the screen, the battery top right, left of the menu button. Each is
## a chip in the touch buttons' style, so it reads over any ground. The texts
## change every few seconds at most; on touch a tap on the clock switches
## between real time and game time.

const Settings = preload("res://scripts/game_options.gd")
const TouchUI = preload("res://scripts/touch_ui.gd")
const BLACK_FONT := preload("res://assets/source_text_font.fnt")
const WHITE_FONT := preload("res://assets/source_text_font_white.fnt")
## Set by ios/plugins/pokewilds_battery: "<percent, or -1>,<state>" with the
## state 2 charging, 3 full. Empty where nothing reads a battery (desktop, server).
const BATTERY_ENV := "POKEWILDS_BATTERY"
const CLOCK_REAL := 1
const CLOCK_GAME := 2
const LOW_BATTERY_COLOR := Color8(232, 56, 40)
const CHARGING_COLOR := Color8(56, 176, 48)
const FONT_SIZE := 8
## The digits' ink is rows 1-6 of the font's 8-pixel cell, so its centre line
## is 4 cell pixels under the label's top (as _align_menu_tick has it).
const INK_CENTRE := 4.0 * FONT_SIZE / 10.0
const CHIP_HEIGHT := 11.0
const PAD := 3.0
const MARGIN := 2.0
## The battery's case; its nub sticks out one more pixel on the right.
const BATTERY := Vector2(13, 6)

var main: Node
var root: Control
var clock_chip: Panel
var clock: Label
var battery_chip: Panel
var battery_fill: ColorRect
var percent: Label
var wait := 0.0

func _init(owner_main: Node) -> void:
    main = owner_main

static func battery_available() -> bool:
    return not OS.get_environment(BATTERY_ENV).is_empty()

## Every frame from main; top_free: nothing (menu, battle, top box) covers the top.
func refresh(delta: float, top_free: bool) -> void:
    var wanted: bool = top_free and not main.touch_controls.edit_mode \
            and (int(Settings.values.clock) > 0 or Settings.enabled("battery_hud"))
    if root == null:
        if not wanted: return
        _build()
    root.visible = wanted
    if not wanted:
        wait = 0.0  # fresh texts as soon as it shows again (an option may have changed)
        return
    wait -= delta / maxf(Engine.time_scale, 0.01)
    if wait <= 0.0: update()
    _place()

## The clock centred on the screen, the battery on the same line at the right
## edge of the safe area, moved left of the menu button or the FPS counter
## when either is on that line.
func _place() -> void:
    var safe: Rect2 = main.touch_controls.usable_rect
    var top := safe.position.y + MARGIN
    var centre: float = main.get_viewport().get_visible_rect().size.x / 2.0
    _move(clock_chip, Vector2(roundf(centre - clock_chip.size.x / 2.0), top))
    var right := safe.end.x - MARGIN
    for obstacle in [main.touch_controls.get_node_or_null("Start"), main.fps_label]:
        if obstacle is Control and obstacle.is_visible_in_tree():
            var rect: Rect2 = obstacle.get_global_rect()
            if rect.position.y < top + CHIP_HEIGHT and rect.end.y > top and rect.end.x > right - battery_chip.size.x:
                right = minf(right, rect.position.x - 3.0)
    _move(battery_chip, Vector2(right - battery_chip.size.x, top))

func _move(chip: Control, at: Vector2) -> void:
    if chip.position != at: chip.position = at

## Touch: a tap on the clock switches between the phone's time and the world's.
func switch_clock() -> void:
    Settings.change("clock", CLOCK_REAL if int(Settings.values.clock) == CLOCK_GAME else CLOCK_GAME)
    update()

func update() -> void:
    var mode := int(Settings.values.clock)
    # iOS reports the battery at most once a minute; a charger shows within 10 s.
    wait = 10.0
    var parts := OS.get_environment(BATTERY_ENV).split(",")
    var level := int(parts[0]) if parts.size() == 2 else -1
    battery_chip.visible = Settings.enabled("battery_hud") and level >= 0
    if battery_chip.visible:
        _set_text(battery_chip, percent, "%d%%" % level)
        battery_fill.size.x = roundf((BATTERY.x - 2.0) * clampi(level, 0, 100) / 100.0)
        battery_fill.color = CHARGING_COLOR if int(parts[1]) >= 2 else LOW_BATTERY_COLOR if level <= 20 else Color.BLACK
    clock_chip.visible = mode > 0
    if mode == CLOCK_GAME:
        # A game minute lasts a quarter of a second: tick every second.
        wait = 1.0
        var minutes: int = main.world.clock_minutes()
        _set_text(clock_chip, clock, "%02d:%02d" % [minutes / 60, minutes % 60])
    elif mode == CLOCK_REAL:
        var now := Time.get_time_dict_from_system()
        wait = minf(wait, 60.0 - float(now.second))
        _set_text(clock_chip, clock, "%02d:%02d" % [now.hour, now.minute])
    # The world's time on a dark chip, so it never passes for the phone's.
    var style := TouchUI.button_style(mode == CLOCK_GAME)
    if clock_chip.get_theme_stylebox("panel") != style:
        clock_chip.add_theme_stylebox_override("panel", style)
        clock.add_theme_font_override("font", WHITE_FONT if mode == CLOCK_GAME else BLACK_FONT)

## A chip as wide as its text.
func _set_text(chip: Panel, label: Label, text: String) -> void:
    if label.text == text: return
    label.text = text
    chip.size.x = label.position.x + BLACK_FONT.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE).x + PAD

func _build() -> void:
    root = Control.new()
    root.name = "StatusHud"
    root.mouse_filter = Control.MOUSE_FILTER_IGNORE
    root.z_index = 80
    main.get_node("UI").add_child(root)
    clock_chip = _chip("Clock")
    clock = _label(clock_chip, PAD)
    battery_chip = _chip("Battery")
    # A battery like the phone's own, centred on the digits' line: black case
    # and nub, a fill as long as the charge.
    var at := Vector2(PAD, CHIP_HEIGHT / 2.0 - BATTERY.y / 2.0)
    _rect(at, BATTERY, Color.BLACK)
    _rect(at + Vector2(BATTERY.x, 2), Vector2(1, BATTERY.y - 4), Color.BLACK)
    _rect(at + Vector2.ONE, BATTERY - Vector2(2, 2), Color.WHITE)
    battery_fill = _rect(at + Vector2.ONE, Vector2(0, BATTERY.y - 2), Color.BLACK)
    percent = _label(battery_chip, PAD + BATTERY.x + 4)

func _chip(node_name: String) -> Panel:
    var chip := Panel.new()
    chip.name = node_name
    chip.size = Vector2(0, CHIP_HEIGHT)
    chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
    chip.add_theme_stylebox_override("panel", TouchUI.button_style(false))
    root.add_child(chip)
    return chip

func _rect(at: Vector2, dimensions: Vector2, color: Color) -> ColorRect:
    var rect := ColorRect.new()
    rect.position = at
    rect.size = dimensions
    rect.color = color
    rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
    battery_chip.add_child(rect)
    return rect

## The digits' ink centred on the chip's middle line, where the battery is too.
func _label(chip: Panel, x: float) -> Label:
    var label := Label.new()
    label.position = Vector2(x, CHIP_HEIGHT / 2.0 - INK_CENTRE)
    label.mouse_filter = Control.MOUSE_FILTER_IGNORE
    label.add_theme_font_override("font", BLACK_FONT)
    label.add_theme_font_size_override("font_size", FONT_SIZE)
    label.add_theme_color_override("font_color", Color.WHITE)
    chip.add_child(label)
    return label
