extends RefCounted

## The touch controls panel (show, auto-hide, opacity, size, theme, MOVE
## CONTROLS, RESET LAYOUT), opened from OPTIONS or the title.
## Split out of main.gd; reaches the game through `main`.

const GameOptions = preload("res://scripts/game_options.gd")
const JOHTO_FONT := preload("res://assets/source_text_font.fnt")

var main: GameMain
var touch_config_scroll: ScrollContainer
var swipe_stick_held := false

func _init(owner_main: GameMain) -> void:
    main = owner_main

func show_touch_changed(enabled: bool) -> void:
    main.touch_controls.set_touch_enabled(enabled)
    refresh_touch_config_labels()

func auto_hide_changed(enabled: bool) -> void:
    main.touch_controls.set_auto_hide_controller(enabled)
    refresh_touch_config_labels()

func touch_opacity_changed(value: float) -> void:
    main.touch_controls.set_control_opacity(value / 100.0)
    refresh_touch_config_labels()

func touch_size_changed(value: float) -> void:
    main.touch_controls.set_control_scale(value / 100.0)
    refresh_touch_config_labels()

func cycle_touch_theme() -> void:
    main.touch_controls.set_theme_mode((main.touch_controls.theme_mode + 1) % 3)
    refresh_touch_config_labels()
    apply_touch_config_theme()

func on_touch_theme_changed() -> void:
    if main.touch_config.visible:
        apply_touch_config_theme()

func refresh_touch_config_labels() -> void:
    main.auto_hide.text = "AUTO HIDE: %s" % ("ON" if main.touch_controls.auto_hide_controller else "OFF")
    main.show_touch.text = "TOUCH CONTROLS: %s" % (
        "ON" if main.touch_controls.touch_enabled else "OFF"
    )
    main.touch_opacity_label.text = "  OPACITY %d%%" % roundi(
        main.touch_controls.control_opacity * 100.0
    )
    main.touch_size_label.text = "  SIZE %d%%" % roundi(
        main.touch_controls.control_scale * 100.0
    )
    var theme_names := ["SYSTEM", "LIGHT", "DARK"]
    main.touch_theme_button.text = "THEME: %s" % theme_names[
        clampi(main.touch_controls.theme_mode, 0, theme_names.size() - 1)
    ]

func apply_touch_config_theme() -> void:
    main.touch_config.add_theme_stylebox_override("panel", GameOptions.style())
    _set_touch_config_colors(main.touch_config, Color.BLACK)
    _style_touch_config_buttons()
    _style_touch_config_sliders()
    if touch_config_scroll == null:
        # Keep every setting reachable on smaller screens and within cutouts.
        var contents := main.touch_config.get_node("VBox") as VBoxContainer
        touch_config_scroll = ScrollContainer.new()
        touch_config_scroll.name = "TouchSettingsScroll"
        touch_config_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
        touch_config_scroll.follow_focus = true
        main.touch_config.add_child(touch_config_scroll)
        contents.reparent(touch_config_scroll)
        contents.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
        contents.size_flags_horizontal = Control.SIZE_EXPAND_FILL
        main.touch_controls.safe_area_changed.connect(_layout_touch_config)
    var scroll_bar := touch_config_scroll.get_v_scroll_bar()
    var rail := StyleBoxFlat.new();rail.bg_color=Color(0.9,0.9,0.9);rail.content_margin_left=2;rail.content_margin_right=2
    var thumb := StyleBoxFlat.new();thumb.bg_color=Color.BLACK;thumb.content_margin_left=2;thumb.content_margin_right=2
    scroll_bar.add_theme_stylebox_override("scroll",rail)
    for state in ["grabber","grabber_highlight","grabber_pressed"]:scroll_bar.add_theme_stylebox_override(state,thumb)
    _layout_touch_config()
    main.setup_screen.prepare_swipe_cursor()

func _layout_touch_config(_bounds: Rect2 = Rect2()) -> void:
    if touch_config_scroll == null: return
    var bounds := main.touch_controls.usable_rect
    var panel_size := Vector2(minf(224.0, bounds.size.x - 8.0), minf(172.0, bounds.size.y - 8.0))
    main.touch_config.size = panel_size
    main.touch_config.position = (bounds.position + (bounds.size - panel_size) * 0.5).round()
    touch_config_scroll.position = Vector2(12, 10)
    touch_config_scroll.size = panel_size - Vector2(24, 20)

func _touch_config_box(color: Color, border: Color, radius: int) -> StyleBoxFlat:
    var style := StyleBoxFlat.new()
    style.bg_color = color
    style.border_color = border
    style.set_border_width_all(1)
    style.corner_radius_top_left = radius
    style.corner_radius_top_right = radius
    style.corner_radius_bottom_left = radius
    style.corner_radius_bottom_right = radius
    return style

func _style_touch_config_buttons() -> void:
    for node in main.touch_config.find_children("*", "Button", true, false):
        var button := node as Button
        button.text = button.text.to_upper()
        button.alignment = HORIZONTAL_ALIGNMENT_LEFT
        button.custom_minimum_size.y = 16
        button.focus_mode = Control.FOCUS_NONE
        var plain := StyleBoxEmpty.new()
        plain.content_margin_left = 12
        for state in ["normal", "hover", "pressed", "focus", "disabled"]:
            button.add_theme_stylebox_override(state, plain)
        if button is CheckButton:
            var blank := ImageTexture.create_from_image(Image.create(1,1,false,Image.FORMAT_RGBA8))
            for icon_name in ["checked", "unchecked", "checked_disabled", "unchecked_disabled", "checked_mirrored", "unchecked_mirrored"]:
                button.add_theme_icon_override(icon_name, blank)

func _style_touch_config_sliders() -> void:
    var track := _touch_config_box(Color.BLACK,Color.BLACK,0)
    track.content_margin_top = 1.0
    track.content_margin_bottom = 1.0
    var fill := _touch_config_box(Color.BLACK,Color.BLACK,0)
    var grabber := GradientTexture2D.new()
    var gradient := Gradient.new()
    gradient.set_color(0,Color(0.75,0.15,0.15))
    gradient.set_color(1,Color(0.75,0.15,0.15))
    grabber.gradient = gradient
    grabber.width = 6
    grabber.height = 10
    for slider in [main.touch_opacity_slider,main.touch_size_slider]:
        slider.add_theme_stylebox_override("slider",track)
        slider.add_theme_stylebox_override("grabber_area",fill)
        slider.add_theme_stylebox_override("grabber_area_highlight",fill)
        for state in ["grabber","grabber_highlight","grabber_disabled"]:
            slider.add_theme_icon_override(state,grabber)

func _set_touch_config_colors(node: Node, color: Color) -> void:
    if node is Label or node is Button:
        var control := node as Control
        control.add_theme_font_override("font",JOHTO_FONT)
        control.add_theme_font_size_override("font_size",8)
        control.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
        for state in ["font_color","font_hover_color","font_pressed_color","font_focus_color","font_hover_pressed_color","font_disabled_color"]:
            control.add_theme_color_override(state,color)
    for child in node.get_children():
        _set_touch_config_colors(child,color)

func open_touch_config(from_options: bool = false) -> void:
    if not from_options and not main._is_android_touch_runtime():
        main.touch_config.visible = false
        main.touch_controls.set_game_active(false)
        return
    if main.touch_controls.edit_mode:
        main.touch_controls.end_edit()
    if main.field_move_wheel_open:
        main.move_wheel.close_field_move_wheel(false)
    main.touch_config.visible = true
    swipe_stick_held = false
    main.setup_screen.position_swipe_cursor.call_deferred()
    main.touch_controls.set_game_active(false)
    main.show_touch.button_pressed = main.touch_controls.touch_enabled
    main.auto_hide.button_pressed = main.touch_controls.auto_hide_controller
    main.touch_opacity_slider.set_value_no_signal(
        main.touch_controls.control_opacity * 100.0
    )
    main.touch_size_slider.set_value_no_signal(
        main.touch_controls.control_scale * 100.0
    )
    refresh_touch_config_labels()
    apply_touch_config_theme()
    if main.started:
        main.world.set_gameplay_enabled(false)

func move_controls() -> void:
    main.touch_config.visible = false
    main.touch_controls.set_game_active(true)
    main.touch_controls.begin_edit()

func reset_layout() -> void:
    main.touch_controls.reset_layout()

func close_touch_config() -> void:
    main.touch_config.visible = false
    if not main.started:
        main.touch_controls.set_game_active(true)
        return
    var gameplay_should_resume := (
        not main.battle_active
        and not main.game_menu_open
        and not main.craft_menu_open
        and not main.quit_prompt_open
    )
    main.world.set_gameplay_enabled(gameplay_should_resume)
    main.touch_controls.set_game_active(true)
