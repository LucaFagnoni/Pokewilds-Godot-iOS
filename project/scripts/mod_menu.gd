extends PanelContainer

var output: RichTextLabel
var picker: FileDialog
var owner_game: Node

func _ready() -> void:
    z_index=600
    position=Vector2(24,8)
    size=Vector2(272,164)
    var style := StyleBoxFlat.new()
    style.bg_color=Color.BLACK;style.border_color=Color.WHITE;style.set_border_width_all(1)
    style.set_content_margin_all(5)
    add_theme_stylebox_override("panel",style)
    var theme_override := Theme.new()
    theme_override.default_font=preload("res://assets/touch_ui/Anton-Regular.ttf")
    theme_override.default_font_size=8
    theme=theme_override
    var column := VBoxContainer.new();column.add_theme_constant_override("separation",2);add_child(column)
    var title := Label.new();title.text="POKEWILDS MODS";title.horizontal_alignment=HORIZONTAL_ALIGNMENT_CENTER;column.add_child(title)
    output=RichTextLabel.new();output.size_flags_vertical=Control.SIZE_EXPAND_FILL;output.custom_minimum_size=Vector2(0,70)
    output.add_theme_color_override("default_color",Color.WHITE)
    column.add_child(output)
    output.text="Active compatible files: %d\nImport a ZIP containing the original mods/ folder. Changes apply after fully closing and reopening the game.\n" % OriginalMods.applied+"\n".join(OriginalMods.report)
    var row := HBoxContainer.new();column.add_child(row)
    _button(row,"IMPORT ZIP",_choose)
    _button(row,"ENABLE",func(): OriginalMods.set_enabled(true);output.text="Mods enabled for next launch.")
    _button(row,"DISABLE",func(): OriginalMods.set_enabled(false);output.text="Mods disabled for next launch. Built-in files will be restored.")
    _button(column,"CLOSE",_close)
    picker=FileDialog.new();picker.file_mode=FileDialog.FILE_MODE_OPEN_FILE
    picker.access=FileDialog.ACCESS_FILESYSTEM;picker.use_native_dialog=true
    picker.filters=PackedStringArray(["*.zip ; PokeWilds mod ZIP"])
    picker.file_selected.connect(func(path: String): output.text=OriginalMods.install_zip(path))
    add_child(picker)

func _button(parent: Node,text: String,callback: Callable) -> void:
    var button := Button.new();button.text=text;button.size_flags_horizontal=Control.SIZE_EXPAND_FILL
    button.focus_mode=Control.FOCUS_NONE
    button.add_theme_color_override("font_color",Color.WHITE)
    button.pressed.connect(callback);parent.add_child(button)

func _choose() -> void:
    picker.popup_centered_ratio(0.8)

func _close() -> void:
    hide()
    if is_instance_valid(owner_game): owner_game._open_touch_config()
