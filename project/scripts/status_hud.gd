extends RefCounted
## The HUD's top row, on one line MARGIN under the safe area's top edge (see
## hud_style.gd): the minimap at the left edge, the clock (OPTIONS > CLOCK) at
## the centre of the screen, and at the right edge the menu button, then the
## chat button (online, coop_chat.gd), the battery (OPTIONS > BATTERY) and the
## FPS counter (OPTIONS > FPS COUNTER) to its left, GAP apart. Chips are as tall as the menu button. The texts change
## every few seconds at most (the FPS twice a second); on touch a tap on the
## clock switches between real time and game time.

const Settings = preload("res://scripts/game_options.gd")
const HudStyle = preload("res://scripts/hud_style.gd")
## Set by ios/plugins/pokewilds_battery: "<percent, or -1>,<state>" with the
## state 2 charging, 3 full. Empty where nothing reads a battery (desktop, server).
const BATTERY_ENV := "POKEWILDS_BATTERY"
const CLOCK_REAL := 1
const CLOCK_GAME := 2
const LOW_BATTERY_COLOR := Color8(232, 56, 40)
const CHARGING_COLOR := Color8(88, 208, 72)
## The battery's case, as tall as the digits; its nub sticks out one more pixel.
const BATTERY := Vector2(13, 6)
const BATTERY_ROOM := 14.0 + 3.0
## The sun or moon before the world's time.
const SUN_ROOM := HudStyle.INK_HEIGHT + 3.0

var main: Node
var root: Control
var clock_chip: Control
var battery_chip: Control
var battery_fill: ColorRect
var fps_chip: Control
## Set by coop_chat.gd, which shows it; placed here with the chips.
var chat_chip: Control
var wait := 0.0
var fps_wait := 0.0
var top_free := false
var dark := true
var height := HudStyle.ROW

func _init(owner_main: Node) -> void:
    main = owner_main

static func battery_available() -> bool:
    return not OS.get_environment(BATTERY_ENV).is_empty()

## Every frame from main; top_free: nothing (menu, battle, top box) covers the top.
func refresh(delta: float, free: bool) -> void:
    if root == null: _build()
    top_free = free and not main.touch_controls.edit_mode
    if row_height() != height:
        # BUTTON SIZE changed the menu button: the chips follow at once.
        height = row_height()
        wait = 0.0
        fps_wait = 0.0
    var clock_on := top_free and int(Settings.values.clock) > 0
    var battery_on := top_free and Settings.enabled("battery_hud")
    if not clock_on and not battery_on:
        clock_chip.hide()
        battery_chip.hide()
        wait = 0.0  # fresh texts as soon as they show again (an option may have changed)
    else:
        wait -= delta / maxf(Engine.time_scale, 0.01)
        if wait <= 0.0: update()
    _place()

## Every frame from main: the FPS counter, in the field like the rest of the row.
func update_fps(delta: float) -> void:
    if root == null: return
    fps_chip.visible = top_free and Settings.enabled("fps_counter")
    if not fps_chip.visible: return
    fps_wait -= delta / maxf(Engine.time_scale, 0.01)
    if fps_wait <= 0.0:
        fps_wait = 0.5
        HudStyle.set_chip_text(fps_chip, str(roundi(Engine.get_frames_per_second())), row_height())

## The menu button's height when it is on screen (BUTTON SIZE scales it), else ROW.
func row_height() -> float:
    var menu := _menu()
    return menu.size.y * menu.scale.y if menu != null else HudStyle.ROW

## The menu button, when the touch controls use it in the top row.
func _menu() -> Control:
    var pad: Control = main.touch_controls
    var menu := pad.get_node_or_null("Start") as Control
    if menu == null or not pad.android_runtime: return null
    return menu if menu.position.y < pad.usable_rect.position.y + HudStyle.ROW * 2.0 else null

func _place() -> void:
    var safe: Rect2 = main.touch_controls.usable_rect
    var top := safe.position.y + HudStyle.MARGIN
    # The button theme reaches every piece of the HUD.
    if dark != HudStyle.dark:
        dark = HudStyle.dark
        for item in [clock_chip, battery_chip, fps_chip, main.m3924_minimap_root.get_node("Ring"), main.minimap_north]:
            item.queue_redraw()
    _move(main.m3924_minimap_root, Vector2(safe.position.x + HudStyle.MARGIN, top))
    var centre: float = main.get_viewport().get_visible_rect().size.x / 2.0
    _move(clock_chip, Vector2(roundf(centre - clock_chip.size.x / 2.0), top))
    var right := safe.end.x - HudStyle.MARGIN
    var menu := _menu()
    if menu != null: right = menu.position.x - HudStyle.GAP
    for chip in [chat_chip, battery_chip, fps_chip]:
        if chip == null or not chip.visible: continue
        _move(chip, Vector2(right - chip.size.x, top))
        right = chip.position.x - HudStyle.GAP

func _move(item: Control, at: Vector2) -> void:
    if item.position != at: item.position = at

## Touch: a tap on the clock switches between the phone's time and the world's.
func switch_clock() -> void:
    Settings.change("clock", CLOCK_REAL if int(Settings.values.clock) == CLOCK_GAME else CLOCK_GAME)
    update()

func update() -> void:
    var mode := int(Settings.values.clock)
    height = row_height()
    # iOS reports the battery at most once a minute; a charger shows within 10 s.
    wait = 10.0
    var parts := OS.get_environment(BATTERY_ENV).split(",")
    var level := int(parts[0]) if parts.size() == 2 else -1
    battery_chip.visible = top_free and Settings.enabled("battery_hud") and level >= 0
    if battery_chip.visible:
        HudStyle.set_chip_text(battery_chip, "%d%%" % level, height, BATTERY_ROOM)
        battery_fill.get_parent().position.y = roundf(height / 2.0 - BATTERY.y / 2.0)
        battery_fill.get_parent().position.x = (height - HudStyle.INK_HEIGHT) / 2.0
        battery_fill.size.x = roundf((BATTERY.x - 2.0) * clampi(level, 0, 100) / 100.0)
        battery_fill.color = CHARGING_COLOR if int(parts[1]) >= 2 else LOW_BATTERY_COLOR if level <= 20 else HudStyle.INK
    clock_chip.visible = top_free and mode > 0
    if mode == CLOCK_GAME:
        # A game minute lasts a quarter of a second: tick every second.
        wait = 1.0
        var minutes: int = main.world.clock_minutes()
        HudStyle.set_chip_text(clock_chip, "%02d:%02d" % [minutes / 60, minutes % 60], height, SUN_ROOM)
    elif mode == CLOCK_REAL:
        var now := Time.get_time_dict_from_system()
        wait = minf(wait, 60.0 - float(now.second))
        HudStyle.set_chip_text(clock_chip, "%02d:%02d" % [now.hour, now.minute], height)
    # The world's time carries a sun or a moon, so it never passes for the phone's.
    var sun := clock_chip.get_node("Sun") as Control
    sun.visible = mode == CLOCK_GAME
    if sun.visible:
        sun.position = Vector2((height - HudStyle.INK_HEIGHT) / 2.0, roundf(height / 2.0 - HudStyle.INK_HEIGHT / 2.0))
        sun.set_meta("night", is_instance_valid(main.world.environment_system) and main.world.environment_system.is_night_time())
        sun.queue_redraw()

func _build() -> void:
    root = Control.new()
    root.name = "StatusHud"  # full screen: proportional_ui_layout.gd's FULL_SCREEN
    root.mouse_filter = Control.MOUSE_FILTER_IGNORE
    root.z_index = 80
    main.get_node("UI").add_child(root)
    # The minimap joins the row: placed on the whole screen, not the centred 320x180 area.
    main.m3924_minimap_root.reparent(root, false)
    main.m3924_minimap_root.z_index = 0
    clock_chip = HudStyle.chip(root, "Clock")
    var sun := Control.new()
    sun.name = "Sun"
    sun.size = Vector2(HudStyle.INK_HEIGHT, HudStyle.INK_HEIGHT)
    sun.mouse_filter = Control.MOUSE_FILTER_IGNORE
    sun.draw.connect(func():
        var r := HudStyle.INK_HEIGHT / 2.0
        if sun.get_meta("night", false): sun.draw_arc(Vector2(r, r), r - 1.0, PI * 0.5, PI * 1.5, 12, HudStyle.INK, 2.0, true)
        else: sun.draw_circle(Vector2(r, r), r, Color8(248, 216, 96)))
    clock_chip.add_child(sun)
    battery_chip = HudStyle.chip(root, "Battery")
    # A battery like the phone's own, on the digits' line: case, nub, and a
    # fill as long as the charge.
    var icon := Control.new()
    icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
    battery_chip.add_child(icon)
    for part in [[Vector2.ZERO, BATTERY, HudStyle.INK], [Vector2(BATTERY.x, 2), Vector2(1, BATTERY.y - 4), HudStyle.INK], [Vector2.ONE, BATTERY - Vector2(2, 2), Color(0.1, 0.1, 0.1)]]:
        _rect(icon, part[0], part[1], part[2])
    battery_fill = _rect(icon, Vector2(1, 1), Vector2(0, BATTERY.y - 2), HudStyle.INK)
    fps_chip = HudStyle.chip(root, "Fps")
    for chip in [clock_chip, battery_chip, fps_chip]: chip.hide()

func _rect(parent: Control, at: Vector2, dimensions: Vector2, color: Color) -> ColorRect:
    var rect := ColorRect.new()
    rect.position = at
    rect.size = dimensions
    rect.color = color
    rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
    parent.add_child(rect)
    return rect
