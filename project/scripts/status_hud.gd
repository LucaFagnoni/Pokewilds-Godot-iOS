extends RefCounted
## OPTIONS > BATTERY and CLOCK: the phone's battery and a clock in the top left
## corner, right of the minimap. The texts change every few seconds at most;
## on touch a tap on the clock switches between real time and game time.

const Settings = preload("res://scripts/game_options.gd")
## Set by ios/plugins/pokewilds_battery: "<percent, or -1>,<state>" with the
## state 2 charging, 3 full. Empty where nothing reads a battery (desktop, server).
const BATTERY_ENV := "POKEWILDS_BATTERY"
const CLOCK_REAL := 1
const CLOCK_GAME := 2
## The world's time is gold, so it never passes for the phone's.
const GAME_CLOCK_COLOR := Color8(255, 216, 96)
const LOW_BATTERY_COLOR := Color8(232, 56, 40)
const CHARGING_COLOR := Color8(88, 208, 72)
const BATTERY_INSIDE := 11.0

var main: Node
var root: HBoxContainer
var battery: Control
var battery_fill: ColorRect
var percent: Label
var clock: Label
var wait := 0.0

func _init(owner_main: Node) -> void:
    main = owner_main

static func battery_available() -> bool:
    return not OS.get_environment(BATTERY_ENV).is_empty()

## Every frame from main; top_free: nothing (menu, battle, top box) covers the top.
func refresh(delta: float, top_free: bool) -> void:
    var wanted := top_free and (int(Settings.values.clock) > 0 or Settings.enabled("battery_hud"))
    if root == null:
        if not wanted: return
        _build()
    root.visible = wanted
    if not wanted:
        wait = 0.0  # fresh texts as soon as it shows again (an option may have changed)
        return
    var spot: Vector2 = main.touch_controls.usable_rect.position + Vector2(2, 2)
    var minimap: Control = main.m3924_minimap_root
    if minimap.visible: spot.x = maxf(spot.x, minimap.position.x + minimap.size.x + 4)
    if root.position != spot: root.position = spot
    wait -= delta / maxf(Engine.time_scale, 0.01)
    if wait <= 0.0: update()

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
    battery.visible = Settings.enabled("battery_hud") and level >= 0
    percent.visible = battery.visible
    if battery.visible:
        percent.text = "%d%%" % level
        battery_fill.size.x = roundf(BATTERY_INSIDE * clampi(level, 0, 100) / 100.0)
        battery_fill.color = CHARGING_COLOR if int(parts[1]) >= 2 else LOW_BATTERY_COLOR if level <= 20 else Color.WHITE
    clock.visible = mode > 0
    if mode == CLOCK_GAME:
        # A game minute lasts a quarter of a second: tick every second.
        wait = 1.0
        var minutes: int = main.world.clock_minutes()
        clock.text = "%02d:%02d" % [minutes / 60, minutes % 60]
    elif mode == CLOCK_REAL:
        var now := Time.get_time_dict_from_system()
        wait = minf(wait, 60.0 - float(now.second))
        clock.text = "%02d:%02d" % [now.hour, now.minute]
    clock.add_theme_color_override("font_color", GAME_CLOCK_COLOR if mode == CLOCK_GAME else Color.WHITE)

func _build() -> void:
    root = HBoxContainer.new()
    root.name = "StatusHud"
    root.mouse_filter = Control.MOUSE_FILTER_IGNORE
    root.z_index = 80
    root.add_theme_constant_override("separation", 3)
    main.get_node("UI").add_child(root)
    # A battery like the phone's own: black case, a fill as long as the charge.
    battery = Control.new()
    battery.custom_minimum_size = Vector2(14, 7)
    battery.size_flags_vertical = Control.SIZE_SHRINK_CENTER
    battery.mouse_filter = Control.MOUSE_FILTER_IGNORE
    root.add_child(battery)
    for part in [[Vector2(0, 0), Vector2(13, 7), Color.BLACK], [Vector2(13, 2), Vector2(1, 3), Color.BLACK], [Vector2(1, 1), Vector2(11, 5), Color(0.2, 0.2, 0.2)]]:
        _rect(part[0], part[1], part[2])
    battery_fill = _rect(Vector2(1, 1), Vector2(0, 5), Color.WHITE)
    percent = _label("Battery")
    clock = _label("Clock")

func _rect(at: Vector2, dimensions: Vector2, color: Color) -> ColorRect:
    var rect := ColorRect.new()
    rect.position = at
    rect.size = dimensions
    rect.color = color
    rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
    battery.add_child(rect)
    return rect

## White with a dark edge, like the FPS counter, so it reads over any ground.
func _label(node_name: String) -> Label:
    var label: Label = main._source_ui_label(root, node_name, Vector2.ZERO, Vector2.ZERO, 8)
    label.add_theme_color_override("font_color", Color.WHITE)
    label.add_theme_color_override("font_outline_color", Color.BLACK)
    label.add_theme_constant_override("outline_size", 3)
    return label
