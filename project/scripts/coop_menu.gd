extends Control
## Start menu and MULTIPLAYER flow. Uses the game's font, frame and tick alignment helpers.
## The first choice is plain text over the startup artwork, which stays up until a mode is picked.
##   SINGLE PLAYER -> the normal world setup screen
##   MULTIPLAYER   -> CREATE GAME (PUBLIC / PRIVATE + password) or JOIN GAME (lobby list)
signal chosen(action:String,value:String)
const Settings=preload("res://scripts/game_options.gd")
const Network=preload("res://scripts/coop_network.gd")
const EMPTY_LOBBIES:="No active public or private games at this time, go back and create a game if you want to play online."
const VISIBLE_ROWS:=4
const PASSWORD_LENGTH:=16
const CHOICES:={"title":["SINGLE PLAYER","MULTIPLAYER"],"multi":["CREATE GAME","JOIN GAME"],
    "access":["PUBLIC","PRIVATE"],"world":["NEW WORLD","SAVED WORLD"]}
const TITLES:={"title":"POKEWILDS","multi":"MULTIPLAYER","access":"CREATE GAME","world":"CREATE GAME",
    "load":"SAVED WORLDS","browse":"JOIN GAME","password_set":"SET A PASSWORD",
    "password_join":"ENTER PASSWORD","connecting":"JOIN GAME","loading":"SAVED WORLDS"}
const BACK:={"multi":"title","access":"multi","password_set":"access","world":"access","load":"world",
    "browse":"multi","password_join":"browse","connecting":"browse"}
var main:Node
var page:=""
var selection:=0
var entries:Array[Dictionary]=[]
var lobbies:Array[Dictionary]=[]
var rows:Array[Label]=[]
var panel:Panel
var tick:TextureRect
## Password text is entered the way the WORLD NAME is: a buffer shown in a label,
## filled from key events, with the Android keyboard raised directly.
var entry:Label
var buffer:=""
var status:Label
var empty:Label
var stick_y:=0
var _scroll:=0
## Shown beside a list longer than the four rows on screen: which entry the
## cursor is on out of how many, and an arrow wherever more rows are hidden.
var counter:Label
var more_above:Polygon2D
var more_below:Polygon2D
var _refresh_at:=0
var _hint:=""
var backdrop:ColorRect
var splash:CanvasLayer
var title_box:Control
var title_rows:Array[Label]=[]
var title_tick:TextureRect
var title_notice:Label
const TITLE_ROW_Y:=[0.515,0.61]

func configure(game:Node)->void:
    main=game;name="OnlineMenu";size=Vector2(320,180);z_index=345
    mouse_filter=Control.MOUSE_FILTER_STOP
    process_mode=Node.PROCESS_MODE_ALWAYS
    backdrop=ColorRect.new();backdrop.size=size;backdrop.color=Color.WHITE;add_child(backdrop)
    _build_title()
    panel=Panel.new();panel.position=Vector2(48,16);panel.size=Vector2(224,148)
    panel.add_theme_stylebox_override("panel",Settings.style());add_child(panel)
    main._source_ui_label(panel,"Title",Vector2(16,10),Vector2(190,16),12,"POKEWILDS")
    for i in range(VISIBLE_ROWS):
        var row:Label=main._source_ui_label(panel,"Choice%d"%i,Vector2(26,34+i*20),Vector2(182,18),12,"")
        row.mouse_filter=Control.MOUSE_FILTER_STOP
        row.gui_input.connect(func(event):
            if event is InputEventMouseButton and event.pressed and event.button_index==MOUSE_BUTTON_LEFT:
                if _count()>0:selection=clampi(_scroll+i,0,_count()-1)
                refresh();activate();accept_event())
        rows.append(row)
    tick=main._source_texture_rect(panel,"Tick",Vector2(15,36),Vector2(5,7),main.source_command_cursor.texture)
    empty=main._source_ui_label(panel,"Empty",Vector2(14,36),Vector2(196,74),8,EMPTY_LOBBIES)
    empty.autowrap_mode=TextServer.AUTOWRAP_WORD_SMART
    status=main._source_ui_label(panel,"Status",Vector2(12,115),Vector2(200,23),7,"")
    status.autowrap_mode=TextServer.AUTOWRAP_WORD_SMART
    entry=main._source_ui_label(panel,"Entry",Vector2(26,38),Vector2(182,18),12,"")
    counter=main._source_ui_label(panel,"Counter",Vector2(150,13),Vector2(60,12),8,"")
    counter.horizontal_alignment=HORIZONTAL_ALIGNMENT_RIGHT
    more_above=_list_arrow(Vector2(206,30),true)
    more_below=_list_arrow(Vector2(206,105),false)
    hide()

func _list_arrow(at:Vector2,up:bool)->Polygon2D:
    var arrow:=Polygon2D.new()
    arrow.polygon=PackedVector2Array([Vector2(0,4),Vector2(7,4),Vector2(3.5,0)] if up else [Vector2(0,0),Vector2(7,0),Vector2(3.5,4)])
    arrow.color=Color.BLACK;arrow.position=at
    panel.add_child(arrow)
    return arrow

func _build_title()->void:
    # Lives in the startup artwork's own layer so it scales with the artwork.
    splash=main.get_node("StartupSplash")
    title_box=Control.new();title_box.name="TitleChoices";title_box.mouse_filter=Control.MOUSE_FILTER_IGNORE
    splash.add_child(title_box);title_box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    for i in range(CHOICES.title.size()):
        var row:Label=main._source_ui_label(title_box,"Mode%d"%i,Vector2.ZERO,Vector2.ZERO,12,CHOICES.title[i])
        row.horizontal_alignment=HORIZONTAL_ALIGNMENT_CENTER;row.vertical_alignment=VERTICAL_ALIGNMENT_CENTER
        row.anchor_left=0.2;row.anchor_right=0.8;row.anchor_top=TITLE_ROW_Y[i];row.anchor_bottom=TITLE_ROW_Y[i]
        row.offset_left=0;row.offset_right=0;row.offset_top=-8;row.offset_bottom=8
        row.mouse_filter=Control.MOUSE_FILTER_STOP
        row.gui_input.connect(func(event):
            if event is InputEventMouseButton and event.pressed and event.button_index==MOUSE_BUTTON_LEFT and page=="title":
                selection=i;refresh();activate();row.accept_event())
        title_rows.append(row)
    title_tick=main._source_texture_rect(title_box,"Tick",Vector2.ZERO,Vector2(5,7),main.source_command_cursor.texture)
    title_notice=main._source_ui_label(title_box,"Notice",Vector2.ZERO,Vector2.ZERO,7,"")
    title_notice.horizontal_alignment=HORIZONTAL_ALIGNMENT_CENTER;title_notice.autowrap_mode=TextServer.AUTOWRAP_WORD_SMART
    title_notice.anchor_left=0.2;title_notice.anchor_right=0.8;title_notice.anchor_top=0.67;title_notice.anchor_bottom=0.67
    title_notice.offset_left=0;title_notice.offset_right=0;title_notice.offset_top=0;title_notice.offset_bottom=22

## Always starts at the start menu; nothing online is touched until MULTIPLAYER.
func open()->void:
    title_notice.text=String(main.coop_game.notice);main.coop_game.notice=""
    main.setup_panel.hide();show();_go("title")

func close()->void:
    _hide_keyboard();hide();page="";splash.hide()
    main.coop_game.lobby.browse(false)
    main.setup_panel.show()

func _go(target:String,keep_selection:bool=false)->void:
    if _typing():_hide_keyboard()
    if page=="connecting":main.generation_panel.hide()
    page=target
    if not keep_selection:selection=0;_scroll=0
    _hint=""
    main.coop_game.lobby.browse(page in ["browse","password_join"])
    if page in ["password_set","password_join"]:
        buffer=""
        refresh()
        if OS.has_feature("mobile"):
            DisplayServer.virtual_keyboard_show(buffer,Rect2i(),DisplayServer.KEYBOARD_TYPE_DEFAULT,PASSWORD_LENGTH,0,0)
        return
    refresh()

func _names()->Array:
    if CHOICES.has(page):return CHOICES[page]
    var names:Array=[]
    if page=="load":
        for entry in entries:names.append(String(entry.data.get("world_name","WORLD")).left(24))
    elif page=="browse":
        for lobby in lobbies:
            names.append("%s  %d/%d%s"%[String(lobby.name).to_upper().left(13),int(lobby.players),int(lobby["max"]),"  PRIVATE" if lobby.private else ""])
    return names

func _count()->int:
    return _names().size()

func refresh()->void:
    var on_title:=page=="title"
    splash.visible=visible and on_title
    var unseen:=on_title or page in ["loading","connecting"]
    backdrop.visible=not unseen;panel.visible=not unseen
    entry.visible=_typing();entry.text=buffer+"_"
    if on_title:
        var chosen_row:Label=title_rows[clampi(selection,0,title_rows.size()-1)]
        var width:float=main.JOHTO_FONT.get_string_size(chosen_row.text,HORIZONTAL_ALIGNMENT_LEFT,-1,12).x
        title_tick.position.x=roundf(chosen_row.position.x+(chosen_row.size.x-width)/2.0-12.0)
        main._align_menu_tick(title_tick,chosen_row) # Same glyph-centred height as every other menu.
        return
    panel.get_node("Title").text=String(TITLES.get(page,"POKEWILDS"))
    var names:=_names()
    var listing:=page in ["load","browse"]
    if names.is_empty():selection=0;_scroll=0
    else:
        selection=clampi(selection,0,names.size()-1)
        _scroll=clampi(_scroll,maxi(0,selection-VISIBLE_ROWS+1),selection)
    for i in range(rows.size()):
        var index:=_scroll+i
        rows[i].visible=not _typing() and page not in ["connecting","loading"] and index<names.size()
        rows[i].text=names[index] if index<names.size() else ""
        rows[i].add_theme_font_size_override("font_size",8 if listing else 12)
    empty.visible=listing and names.is_empty()
    empty.text=EMPTY_LOBBIES if page=="browse" else "No saved multiplayer worlds on this device yet. Go back and choose NEW WORLD."
    tick.visible=not names.is_empty() and not _typing() and page not in ["connecting","loading"]
    if tick.visible:main._align_menu_tick(tick,rows[selection-_scroll])
    var scrolling:bool=listing and tick.visible and names.size()>VISIBLE_ROWS
    counter.visible=listing and tick.visible
    counter.text="%d/%d"%[selection+1,names.size()]
    more_above.visible=scrolling and _scroll>0
    more_below.visible=scrolling and _scroll+VISIBLE_ROWS<names.size()
    _update_status()

func _update_status()->void:
    if page in ["connecting","loading"]:return # Owned by the join or load in progress.
    var lines:PackedStringArray=[]
    match page:
        "title":lines.append("A: SELECT")
        "password_set":lines.append("FRIENDS NEED THIS PASSWORD TO JOIN.");lines.append("A: OK   B: BACK")
        "password_join":lines.append("ASK THE HOST FOR THE PASSWORD.");lines.append("A: JOIN   B: BACK")
        "browse":
            var trouble:=String(main.coop_game.lobby.list_error)
            lines.append(Network.status_text() if trouble.is_empty() else trouble);lines.append("A: JOIN   B: BACK")
        "load":lines.append("A: LOAD   B: BACK")
        _:lines.append(Network.status_text());lines.append("A: SELECT   B: BACK")
    if not _hint.is_empty():lines[0]=_hint
    status.text="\n".join(lines)

func _process(_delta:float)->void:
    if not visible or page in ["","title","load","connecting","loading"]:return
    var now:=Time.get_ticks_msec()
    if now<_refresh_at:return
    _refresh_at=now+500
    if page!="browse":
        _update_status();return
    # Keep the cursor on the same lobby while the list changes underneath it.
    var current:=String(lobbies[selection].address) if selection<lobbies.size() else ""
    lobbies=main.coop_game.lobby.entries()
    for i in range(lobbies.size()):
        if String(lobbies[i].address)==current:selection=i
    refresh()

func activate()->void:
    match page:
        "title":
            if selection==0:chosen.emit("SOLO","")
            else:Network.start();_go("multi")
        "multi":
            if selection==0:_go("access")
            else:lobbies=[];_go("browse")
        "access":
            if selection==0:
                main.coop_game.lobby_private=false;main.coop_game.lobby_password="";_go("world")
            else:_go("password_set")
        "world":
            if selection==0:chosen.emit("SETUP","")
            else:chosen.emit("LIST","")
        "load":
            if selection<entries.size():chosen.emit("LOAD",String(entries[selection].id))
        "browse":
            if selection>=lobbies.size():return
            var lobby:Dictionary=lobbies[selection]
            if int(lobby.players)>=int(lobby["max"]):_hint="THAT GAME IS FULL.";_update_status();return
            main.coop_game.join_lobby=lobby.duplicate(true);main.coop_game.join_password=""
            if lobby.private:_go("password_join")
            else:chosen.emit("JOIN_SETUP",String(lobby.address))
        "password_set","password_join":submit_password()

## A saved world can take a while to read. The game's own loading screen goes up
## at once; this menu stays in place, unseen, only to swallow button presses.
func show_loading()->void:
    if not visible:main.setup_panel.hide();show()
    page="loading";refresh()
    main.generation_status.text="LOADING...\nPLEASE WAIT..."
    main.generation_panel.show()

## Joining shows the same loading screen; this menu stays in place unseen so
## B can still cancel the attempt.
func show_connecting(text:String)->void:
    if not visible:main.setup_panel.hide();show()
    page="connecting";refresh()
    main.generation_status.text=text
    main.generation_panel.show()

func connecting_text(text:String)->void:
    if page=="connecting":main.generation_status.text=text

func connecting_failed(reason:String)->void:
    if not visible or page!="connecting":return
    main.generation_panel.hide()
    _go("browse")
    _hint=reason;_update_status()

func loading_finished(reason:String)->void:
    if not visible or page!="loading":return
    # Still here means the load failed; return to the list and say why.
    main.generation_panel.hide()
    page="load";refresh()
    _hint=reason;_update_status()

func show_saves(values:Array[Dictionary])->void:
    entries=values
    if not visible:main.setup_panel.hide();show()
    _go("load")

func submit_password()->void:
    var value:=buffer.strip_edges()
    if value.is_empty():_hint="TYPE A PASSWORD FIRST.";_update_status();return
    if page=="password_set":
        main.coop_game.lobby_private=true;main.coop_game.lobby_password=value;_go("world")
    elif page=="password_join":
        main.coop_game.join_password=value
        _hide_keyboard()
        chosen.emit("JOIN_SETUP",String(main.coop_game.join_lobby.get("address","")))

func _typing()->bool:
    return page in ["password_set","password_join"]

func _hide_keyboard()->void:
    if OS.has_feature("mobile"):DisplayServer.virtual_keyboard_hide()

## Kept for main.gd, which asks before consuming a key. Keys are read here.
func accepts_text_key(_event:InputEvent)->bool:
    return false

func handle(event:InputEvent)->void:
    if event.is_echo() or page=="loading":return
    # Typed characters first, so a letter bound to a game action still types.
    if _typing() and event is InputEventKey and event.pressed:
        if event.keycode==KEY_BACKSPACE:
            buffer=buffer.left(buffer.length()-1);refresh();return
        if event.keycode in [KEY_ENTER,KEY_KP_ENTER]:
            submit_password();return
        if event.keycode not in [KEY_ESCAPE,KEY_BACK] and event.unicode>=32 and event.unicode!=127:
            if buffer.length()<PASSWORD_LENGTH:buffer+=String.chr(event.unicode);refresh()
            return
    var direction=0
    if event.is_action_pressed("move_down") or event.is_action_pressed("move_right"):direction=1
    elif event.is_action_pressed("move_up") or event.is_action_pressed("move_left"):direction=-1
    if event.is_action_pressed("cancel") or (event is InputEventKey and event.pressed and event.keycode in [KEY_ESCAPE,KEY_BACK]):
        if page=="title":return
        main.coop_game.cancel_join()
        _go(String(BACK.get(page,"title")))
    elif event.is_action_pressed("confirm") or (event is InputEventKey and event.pressed and event.keycode in [KEY_ENTER,KEY_KP_ENTER]):activate()
    elif direction!=0 and not _typing() and page!="connecting":
        var count:=_count()
        if count>0:selection=wrapi(selection+direction,0,count);refresh()
