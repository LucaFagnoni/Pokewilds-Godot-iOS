extends Control
const Settings = preload("res://scripts/game_options.gd")
const ROWS := ["CHOOSE FOLDER", "SYNC FILES", "SAVE DIRECTIONS", "BACK"]
const HELP := ["Choose a normal folder such as Documents/PokeWilds.", "Copy completed saves and game.ini to your chosen folder.", "How to copy or replace a save using Android Files.", "Return to the right-swipe menu."]
const DIRECTIONS := [
    "GET YOUR SAVE\n\nSave in-game first. Choose a folder here, then select SYNC FILES. In Android Files, open that folder and its saves folder. Copy your world's .json file.",
    "REPLACE A SAVE\n\nClose PokeWilds completely. Back up the existing .json file. Copy the replacement into your chosen folder's saves folder. Keep world_cache with shared worlds when provided.",
    "LOAD THE REPLACEMENT\n\nRestart PokeWilds, then select LOAD. Files are imported at startup. Edit game.ini while the app is closed. Sync does not delete local saves when you delete shared copies."
]
var main: Node
var selection := 0
var status: Label
var cursor: TextureRect
var busy := false
var help_page := 0
var showing_help := false
var body: Panel
var help_text: Label
var buttons: Array[Button] = []
var help_buttons: Array[Button] = []

func configure(owner_main: Node) -> void:
    main=owner_main;size=Vector2(320,180);z_index=400
    var background:=ColorRect.new();background.color=Color.WHITE;background.size=size;add_child(background)
    var heading:=_panel(Vector2(2,2),Vector2(316,25))
    main._source_ui_label(heading,"Title",Vector2(12,6),Vector2(280,14),10,"GAME FILES")
    body=_panel(Vector2(2,29),Vector2(316,100))
    cursor=main._source_texture_rect(body,"Cursor",Vector2(8,11),Vector2(5,7),main.source_command_cursor.texture)
    for i in range(ROWS.size()):
        var button:=Button.new();button.position=Vector2(20,6+i*20);button.size=Vector2(284,20)
        button.text=ROWS[i];button.alignment=HORIZONTAL_ALIGNMENT_LEFT;button.flat=true;button.focus_mode=Control.FOCUS_NONE
        button.add_theme_font_override("font",main.JOHTO_FONT);button.add_theme_font_size_override("font_size",8)
        for color in ["font_color","font_hover_color","font_pressed_color"]:button.add_theme_color_override(color,Color.BLACK)
        button.pressed.connect(func():selection=i;activate())
        body.add_child(button);buttons.append(button)
    help_text=main._source_ui_label(body,"Directions",Vector2(12,9),Vector2(292,84),7,"")
    help_text.autowrap_mode=TextServer.AUTOWRAP_WORD_SMART;help_text.add_theme_constant_override("line_spacing",0);help_text.hide()
    var footer:=_panel(Vector2(2,131),Vector2(316,47))
    status=main._source_ui_label(footer,"Status",Vector2(10,7),Vector2(294,34),7,"")
    status.autowrap_mode=TextServer.AUTOWRAP_WORD_SMART;status.add_theme_constant_override("line_spacing",-2)
    for i in range(2):
        var button:=Button.new();button.position=Vector2(10+i*152,25);button.size=Vector2(140,18)
        button.text="B: BACK" if i==0 else "A: NEXT"
        button.flat=true;button.focus_mode=Control.FOCUS_NONE
        button.add_theme_font_override("font",main.JOHTO_FONT);button.add_theme_font_size_override("font_size",7)
        for color in ["font_color","font_hover_color","font_pressed_color"]:button.add_theme_color_override(color,Color.BLACK)
        button.pressed.connect(func():
            if i==0:showing_help=false
            else:help_page=wrapi(help_page+1,0,3)
            _refresh())
        footer.add_child(button);help_buttons.append(button)
    hide()

func _panel(at: Vector2, dimensions: Vector2) -> Panel:
    var result:=Panel.new();result.position=at;result.size=dimensions
    result.add_theme_stylebox_override("panel",Settings.style());add_child(result);return result

func open() -> void:
    selection=0;showing_help=false;show();Settings.refresh_frames(self);_refresh()

func close() -> void:
    if busy:return
    hide();main._open_touch_config()

func _refresh() -> void:
    cursor.visible=not showing_help;help_text.visible=showing_help
    for button in buttons:button.visible=not showing_help
    for button in help_buttons:button.visible=showing_help
    main._align_control_tick(cursor,buttons[selection])
    if showing_help:
        help_text.text=DIRECTIONS[help_page]
        status.text="SAVE DIRECTIONS   %d / 3" % (help_page+1)
    else:status.text=HELP[selection]+"\nA: SELECT   B: BACK"

func handle(event: InputEvent) -> void:
    if busy or event.is_echo():return
    if event.is_action_pressed("cancel") or event.is_action_pressed("start"):
        if showing_help:showing_help=false;_refresh()
        else:close()
        return
    if showing_help:
        if event.is_action_pressed("confirm") or event.is_action_pressed("move_right"):help_page=wrapi(help_page+1,0,3);_refresh()
        elif event.is_action_pressed("move_left"):help_page=wrapi(help_page-1,0,3);_refresh()
        return
    if event.is_action_pressed("move_up"):selection=wrapi(selection-1,0,ROWS.size());_refresh()
    elif event.is_action_pressed("move_down"):selection=wrapi(selection+1,0,ROWS.size());_refresh()
    elif event.is_action_pressed("confirm"):activate()

func activate() -> void:
    if busy:return
    if selection==3:close();return
    if selection==2:showing_help=true;help_page=0;_refresh();return
    var shared:Node=main.shared_save_folder
    if shared.bridge==null:
        status.text="Folder selection is available in the Android app.";return
    busy=true
    status.text="Working... Keep the game open."
    while shared.exporting or shared.bridge.busy():await get_tree().process_frame
    if selection==0:
        shared.bridge.chooseFolder()
        while shared.bridge.choosing():await get_tree().process_frame
    if shared.bridge.configured():
        await shared.export_files(main)
        var error:String=shared.bridge.error()
        status.text="Files synced. Use Android Files to open your chosen folder." if error.is_empty() else "Files not synced. Local saves are safe. Restart to import external changes."
    else:status.text="No folder selected. Your local saves are unchanged."
    busy=false
