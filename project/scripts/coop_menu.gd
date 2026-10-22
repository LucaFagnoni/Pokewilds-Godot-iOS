extends Control
## Start menu and MULTIPLAYER flow. Uses the game's font, frame and tick alignment helpers.
## The first choice is plain text over the startup artwork, which stays up until a mode is picked.
##   SOLO  -> the normal world setup screen
##   CO-OP -> CREATE GAME (PUBLIC / PRIVATE + password), JOIN GAME (lobby list)
##                    or MY SERVERS (dedicated servers saved on this device)
## MY SERVERS is a list: tapping a server (A) joins it in one step, its EDIT tag (START/E on a
## controller or keyboard) opens its form, and the last row, ADD SERVER, opens an empty form.
## The form has NAME, ADDRESS (address:port, host name or join code), PLAYER ID and PASSWORD,
## then SAVE, DELETE (twice: SURE?) and BACK. Tapping a field types it with the phone keyboard
## (the panel moves to the top so OK / BACK stay above it). A refused join returns to that form
## when the host names the PLAYER ID or PASSWORD, otherwise to the list. A LAN lobby that uses
## player accounts opens the form prefilled from the lobby; SAVE AND JOIN there joins it at once.
## The saved list lives in coop_saved_servers.gd. Under each name: the server's version and ping,
## green when it would let this copy in, red when not, grey while it does not answer
## (coop_server_ping.gd; asked when the page opens and every few seconds, one at a time per server).
signal chosen(action:String,value:String)
const Settings=preload("res://scripts/game_options.gd")
const Network=preload("res://scripts/coop_network.gd")
const Saved=preload("res://scripts/coop_saved_servers.gd")
const Ping=preload("res://scripts/coop_server_ping.gd")
const PING_EVERY_MS:=6000
const PING_COLORS:={"green":Color("2f9e44"),"red":Color("d9412f"),"grey":Color("8c8c8c")}
## Dark mode inks the text light purple first (dark_mode.gd INK); these tints bring it back to green, red, grey.
const PING_COLORS_DARK:={"green":Color(0.4,1.0,0.45),"red":Color(1.0,0.42,0.38),"grey":Color(0.75,0.75,0.68)}
const EMPTY_LOBBIES:="No active public or private games at this time, go back and create a game if you want to play online."
const EMPTY_SERVERS:="No saved servers yet. Choose ADD SERVER and type its address and your player ID."
const VISIBLE_ROWS:=4
const PASSWORD_LENGTH:=16
const ADDRESS_LENGTH:=48
const JoinCode=preload("res://scripts/coop_join_code.gd")
const CHOICES:={"title":["SOLO","CO-OP"],"multi":["CREATE GAME","JOIN GAME","MY SERVERS"],
    "access":["PUBLIC","PRIVATE"],"world":["NEW WORLD","SAVED WORLD"]}
const TITLES:={"title":"POKEWILDS","multi":"CO-OP","access":"CREATE GAME","world":"CREATE GAME",
    "load":"SAVED WORLDS","browse":"JOIN GAME","password_set":"SET A PASSWORD",
    "password_join":"ENTER PASSWORD","connecting":"JOIN GAME","loading":"SAVED WORLDS","servers":"MY SERVERS",
    "server_form":"EDIT SERVER"}
const BACK:={"multi":"title","access":"multi","password_set":"access","world":"access","load":"world",
    "browse":"multi","password_join":"browse","connecting":"browse","servers":"multi","server_form":"servers",
    "server_text":"server_form"}
## The server form: field names (also the keys of the saved entry) and what each one asks for.
const FIELDS:=["name","address","id","password"]
const CAPTIONS:={"name":"NAME","address":"ADDRESS","id":"PLAYER ID","password":"PASSWORD"}
const FIELD_HINTS:={"name":"HOW IT SHOWS IN YOUR LIST.","address":"IP:PORT, HOST NAME OR JOIN CODE.",
    "id":"YOUR PLAYER ID ON THAT SERVER.","password":"YOUR PASSWORD ON THAT SERVER."}
const FORM_PITCH:=12
const VALUE_X:=64
var main:Node
var page:=""
var selection:=0
var entries:Array[Dictionary]=[]
## SAVED WORLDS: the bins, and the world whose bin was tapped once (a second tap deletes it).
var trash_bins:Array[TextureRect]=[]
var _trash_armed:=-1
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
## Trainers left of each title word: one for SOLO, two for CO-OP (player sheets, first frame).
const TITLE_TRAINERS:=[["red"],["red","blue"]]
## Where the title words start, from the screen's centre; the trainers sit left of them,
## right-aligned, so trainers and words make one centred column.
const TITLE_TEXT_X:=-2.0
const TITLE_TRAINER_X:=[-38.0,-22.0]
## MY SERVERS: the saved list, the entry open in the form (-1 = a new one), the unsaved fields,
## the field being typed, and the entry being joined (so a refusal can reopen its form).
var servers:Array[Dictionary]=[]
var _edit:=-1
var _draft:Dictionary={}
var _field:=""
var _joining:=-1
var _from_lobby:=false
var _sure:=false
var form_rows:Array[Label]=[]
var edit_tags:Array[Label]=[]
## MY SERVERS: "address:port" -> {"probe":Ping or null,"result":{},"next":msec}, and this copy's mods.
var _pings:Dictionary={}
var _mods:=""
var ping_labels:Array[Label]=[]
var page_up:Control
var page_down:Control
## The game font plus the symbol font for what it lacks (* [ ] @ #), so typed text always shows.
## A FontFile copy, so dark mode can still make it light.
var text_font:FontFile
var type_ok:Label
var type_back:Label
var type_copy:Label
var type_paste:Label

func configure(game:Node)->void:
    main=game;name="OnlineMenu";size=Vector2(320,180);z_index=345
    text_font=main.JOHTO_FONT.duplicate(true);text_font.fallbacks=[main.SYMBOL_FONT]
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
        rows.append(row);row.add_theme_font_override("font",text_font)
        # MY SERVERS only: a small tappable EDIT at the right end of the row.
        var tag:Label=main._source_ui_label(row,"Edit",Vector2(136,0),Vector2(36,18),8,"EDIT")
        tag.horizontal_alignment=HORIZONTAL_ALIGNMENT_RIGHT
        _tap(tag,func():selection=_scroll+i;_edit_selected())
        edit_tags.append(tag)
        # MY SERVERS only: the server's version and ping under its name, coloured (see _ping_line).
        # The white glyphs take any colour; modulate, so dark mode's ink keeps it too.
        var ping:Label=main._source_ui_label(row,"Ping",Vector2(0,9),Vector2(172,9),7,"")
        ping.add_theme_font_override("font",load("res://assets/source_text_font_white.fnt"))
        ping.add_theme_color_override("font_color",Color.WHITE)
        ping_labels.append(ping)
        # SAVED WORLDS only: a bin at the right end of the row.
        var bin:=TextureRect.new();bin.name="Trash";bin.texture=preload("res://scripts/touch_icons.gd").icon("TRASH")
        # Centred on the 8 px name, which sits at the row's top.
        bin.position=Vector2(168,-3);bin.size=Vector2(12,12);bin.texture_filter=CanvasItem.TEXTURE_FILTER_NEAREST
        row.add_child(bin);_tap(bin,func():_trash(_scroll+i))
        trash_bins.append(bin)
    # The compact server form: four fields, then SAVE / DELETE / BACK, all visible at once.
    for i in range(FIELDS.size()+3):
        var row:Label=main._source_ui_label(panel,"Form%d"%i,Vector2(26,27+i*FORM_PITCH),Vector2(182,FORM_PITCH),8,"")
        _tap(row,func():
            if _count()>0:selection=clampi(i,0,_count()-1)
            refresh();activate())
        main._source_ui_label(row,"Value",Vector2(VALUE_X,0),Vector2(182-VALUE_X,FORM_PITCH),8,"").add_theme_font_override("font",text_font)
        form_rows.append(row)
    tick=main._source_texture_rect(panel,"Tick",Vector2(15,36),Vector2(5,7),main.source_command_cursor.texture)
    empty=main._source_ui_label(panel,"Empty",Vector2(14,36),Vector2(196,74),8,EMPTY_LOBBIES)
    empty.autowrap_mode=TextServer.AUTOWRAP_WORD_SMART
    status=main._source_ui_label(panel,"Status",Vector2(12,115),Vector2(200,23),7,"")
    status.autowrap_mode=TextServer.AUTOWRAP_WORD_SMART
    entry=main._source_ui_label(panel,"Entry",Vector2(26,38),Vector2(182,18),12,"")
    entry.add_theme_font_override("font",text_font)
    # Tapping the text brings the phone keyboard back if it was put away.
    entry.mouse_filter=Control.MOUSE_FILTER_STOP
    entry.gui_input.connect(func(event):
        if event is InputEventMouseButton and event.pressed and event.button_index==MOUSE_BUTTON_LEFT and _typing():_show_keyboard())
    counter=main._source_ui_label(panel,"Counter",Vector2(150,13),Vector2(60,12),8,"")
    counter.horizontal_alignment=HORIZONTAL_ALIGNMENT_RIGHT
    more_above=_list_arrow(Vector2(206,30),true)
    more_below=_list_arrow(Vector2(206,105),false)
    # Fingers cannot press an arrow that small: a larger invisible area scrolls the list.
    page_up=Control.new();page_up.position=Vector2(200,24);page_up.size=Vector2(22,24)
    page_down=Control.new();page_down.position=Vector2(200,96);page_down.size=Vector2(22,24)
    for zone in [page_up,page_down]:panel.add_child(zone)
    _tap(page_up,func():_nudge(-1));_tap(page_down,func():_nudge(1))
    # While typing on a phone the keyboard hides the lower half, so OK / BACK sit above it.
    type_ok=main._source_ui_label(panel,"TypeOk",Vector2(26,44),Vector2(30,16),12,"OK")
    type_back=main._source_ui_label(panel,"TypeBack",Vector2(62,44),Vector2(44,16),12,"BACK")
    # The text is not a system field, so iOS has no paste of its own: COPY and PASTE.
    type_copy=main._source_ui_label(panel,"TypeCopy",Vector2(114,44),Vector2(44,16),12,"COPY")
    type_paste=main._source_ui_label(panel,"TypePaste",Vector2(164,44),Vector2(50,16),12,"PASTE")
    _tap(type_ok,activate);_tap(type_back,_back)
    _tap(type_copy,func():DisplayServer.clipboard_set(buffer))
    _tap(type_paste,_paste)
    hide()

## A left click or finger tap on this control runs the action.
func _tap(control:Control,action:Callable)->void:
    control.mouse_filter=Control.MOUSE_FILTER_STOP
    control.gui_input.connect(func(event):
        if event is InputEventMouseButton and event.pressed and event.button_index==MOUSE_BUTTON_LEFT:
            action.call();accept_event())

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
        row.horizontal_alignment=HORIZONTAL_ALIGNMENT_LEFT;row.vertical_alignment=VERTICAL_ALIGNMENT_CENTER
        row.anchor_left=0.5;row.anchor_right=0.5;row.anchor_top=TITLE_ROW_Y[i];row.anchor_bottom=TITLE_ROW_Y[i]
        row.offset_left=TITLE_TEXT_X;row.offset_right=TITLE_TEXT_X+64;row.offset_top=-8;row.offset_bottom=8
        var trainers:Array=TITLE_TRAINERS[i]
        # Trainers centred on the word's capitals, as _align_menu_tick centres the cursor.
        var ink:float=(16.0-row.get_theme_font("font").get_height(12))/2.0+4.0*12.0/10.0
        for j in trainers.size():
            var look:=AtlasTexture.new();look.atlas=load("res://assets/player_%s.png"%trainers[j]);look.region=Rect2(0,0,16,16)
            var trainer:=TextureRect.new();trainer.name="Trainer%d"%j;trainer.texture=look
            trainer.texture_filter=CanvasItem.TEXTURE_FILTER_NEAREST
            # A tap on a trainer picks its row like a tap on the word.
            trainer.mouse_filter=Control.MOUSE_FILTER_PASS
            trainer.position=Vector2(TITLE_TRAINER_X[j+TITLE_TRAINER_X.size()-trainers.size()],roundf(ink-8.0));trainer.size=Vector2(16,16)
            row.add_child(trainer)
        row.mouse_filter=Control.MOUSE_FILTER_STOP
        row.gui_input.connect(func(event):
            if event is InputEventMouseButton and event.pressed and event.button_index==MOUSE_BUTTON_LEFT and page=="title":
                selection=i;refresh();activate();row.accept_event())
        title_rows.append(row)
    title_tick=main._source_texture_rect(title_box,"Tick",Vector2.ZERO,Vector2(5,7),main.source_command_cursor.texture)
    # Why the last game ended, under the rows: on the version's dark tag, as wide as its lines.
    title_notice=main._source_ui_label(title_box,"Notice",Vector2.ZERO,Vector2.ZERO,10,"")
    title_notice.horizontal_alignment=HORIZONTAL_ALIGNMENT_CENTER;title_notice.autowrap_mode=TextServer.AUTOWRAP_WORD_SMART
    _tag(title_notice,4,0)
    # Lines 11 px apart; the glyphs sit at the top of their 13 px line, so the room goes above.
    title_notice.add_theme_constant_override("line_spacing",-2)
    title_notice.get_theme_stylebox("normal").content_margin_top=4
    title_notice.anchor_left=0.5;title_notice.anchor_right=0.5;title_notice.anchor_top=0.68;title_notice.anchor_bottom=0.68
    title_notice.grow_horizontal=Control.GROW_DIRECTION_BOTH
    # The build's version, small in the bottom right corner (CI writes build_version.txt).
    var version:=FileAccess.get_file_as_string("res://build_version.txt").strip_edges() if FileAccess.file_exists("res://build_version.txt") else ""
    if not version.is_empty():
        var tag:Label=main._source_ui_label(title_box,"Version",Vector2.ZERO,Vector2.ZERO,7,"v"+version)
        # It grows left from the corner, clear of the screen's rounded edge.
        _tag(tag,3,1)
        tag.anchor_left=1.0;tag.anchor_right=1.0;tag.anchor_top=1.0;tag.anchor_bottom=1.0
        tag.grow_horizontal=Control.GROW_DIRECTION_BEGIN;tag.grow_vertical=Control.GROW_DIRECTION_BEGIN
        tag.offset_left=-12;tag.offset_right=-12;tag.offset_top=-8;tag.offset_bottom=-8

## Light text (the white copy of the font: the bitmap glyphs are black) on a
## small dark tag, readable over trees or lake whatever the screen's shape.
func _tag(label:Label,side:int,band:int)->void:
    label.add_theme_font_override("font",load("res://assets/source_text_font_white.fnt"))
    label.add_theme_color_override("font_color",Color("f6f4e7"))
    var back:=StyleBoxFlat.new();back.bg_color=Color(0.13,0.23,0.25,0.8);back.set_corner_radius_all(2)
    back.content_margin_left=side;back.content_margin_right=side;back.content_margin_top=band;back.content_margin_bottom=band
    label.add_theme_stylebox_override("normal",back)

## The notice wraps within 75% of the screen; its tag is only as wide as the longest line.
func _set_title_notice(text:String)->void:
    title_notice.text=text;title_notice.visible=not text.is_empty()
    var font:Font=title_notice.get_theme_font("font")
    var width:=font.get_multiline_string_size(text,HORIZONTAL_ALIGNMENT_CENTER,roundf(title_box.get_viewport_rect().size.x*0.75),10,-1,
        TextServer.BREAK_MANDATORY|TextServer.BREAK_WORD_BOUND|TextServer.BREAK_ADAPTIVE|TextServer.BREAK_TRIM_EDGE_SPACES).x
    var half:=ceilf(width/2.0)+title_notice.get_theme_stylebox("normal").content_margin_left
    title_notice.offset_left=-half;title_notice.offset_right=half;title_notice.offset_top=0;title_notice.offset_bottom=0

## Always starts at the start menu; nothing online is touched until MULTIPLAYER.
func open()->void:
    _set_title_notice(String(main.coop_game.notice));main.coop_game.notice=""
    main.setup_panel.hide();show();_go("title")

func close()->void:
    _hide_keyboard();hide();page="";splash.hide()
    main.coop_game.lobby.browse(false)
    main.setup_panel.show()

func _go(target:String,keep_selection:bool=false)->void:
    if _typing():_hide_keyboard()
    if page=="connecting":main.generation_panel.hide()
    if target=="servers" and page!="servers" and page!="server_form":_pings.clear();_mods="" # fresh answers on opening
    page=target
    if not keep_selection:selection=0;_scroll=0
    _hint="";_sure=false
    main.coop_game.lobby.browse(page in ["browse","password_join"])
    if _typing():
        buffer=String(_draft.get(_field,"")) if page=="server_text" else ""
        refresh()
        _show_keyboard()
        return
    refresh()

func _show_keyboard()->void:
    if not OS.has_feature("mobile"):return
    var kind:=DisplayServer.KEYBOARD_TYPE_URL if page=="server_text" and _field=="address" else DisplayServer.KEYBOARD_TYPE_DEFAULT
    DisplayServer.virtual_keyboard_show(buffer,Rect2i(),kind,_limit(),buffer.length(),buffer.length())

## The clipboard's text at the end of what is typed, as far as the field takes it.
func _paste()->void:
    for character in DisplayServer.clipboard_get().replace("\n"," ").strip_edges():
        if buffer.length()>=_limit():break
        if _field!="id" or page!="server_text" or Saved.id_char(character):buffer+=character
    refresh();_show_keyboard()

func _limit()->int:
    return Saved.limit(_field) if page=="server_text" else PASSWORD_LENGTH

## True on a phone, or on a PC started with --touch-ui to test it.
func _phone()->bool:
    return OS.has_feature("mobile") or OS.get_cmdline_user_args().has("--touch-ui")

## The phone keyboard covers the lower half of the screen. While typing, the panel moves to the
## top and shrinks to fit above it, with OK / BACK in the strip the keyboard leaves free.
func _layout_typing()->void:
    var raised:=_typing() and _phone()
    panel.position.y=2.0 if raised else 16.0
    panel.size.y=92.0 if raised else 148.0
    entry.position.y=26.0 if raised else 38.0
    status.position.y=62.0 if raised else 115.0
    type_ok.visible=raised;type_back.visible=raised;type_copy.visible=raised;type_paste.visible=raised

## Text that fits the width: cut from the end, or from the start to keep the cursor end in view.
func _clip(text:String,font_size:int,width:float,from_start:bool=false)->String:
    while text.length()>1 and text_font.get_string_size(text,HORIZONTAL_ALIGNMENT_LEFT,-1,font_size).x>width:
        text=text.substr(1) if from_start else text.left(text.length()-1)
    return text

func _names()->Array:
    if CHOICES.has(page):return CHOICES[page]
    var names:Array=[]
    if page=="load":
        for entry in entries:names.append(_clip(String(entry.data.get("world_name","WORLD")).left(24),8,136.0))
    elif page=="browse":
        for lobby in lobbies:
            names.append("%s  %d/%d%s"%[String(lobby.name).to_upper().left(13),int(lobby.players),int(lobby["max"]),"  PRIVATE" if lobby.private else ""])
    elif page=="servers":
        for server in servers:names.append(_clip(String(server.name).to_upper(),8,126.0))
        names.append("ADD SERVER")
    elif page=="server_form":
        for id in _form_ids():names.append(id)
    return names

## The form's rows in order: the four fields, then SAVE, DELETE (an existing entry only) and BACK.
func _form_ids()->Array:
    var ids:Array=FIELDS.duplicate()
    ids.append("save")
    if _edit>=0:ids.append("delete")
    ids.append("back")
    return ids

func _title()->String:
    if page=="server_form":return "EDIT SERVER" if _edit>=0 else "ADD SERVER"
    if page=="server_text":return String(CAPTIONS.get(_field,""))
    return String(TITLES.get(page,"POKEWILDS"))

func _count()->int:
    return _names().size()

func refresh()->void:
    var on_title:=page=="title"
    splash.visible=visible and on_title
    if splash.visible:splash.call("intro") # title_screen.gd: the logo drops in, once
    var unseen:=on_title or page in ["loading","connecting"]
    backdrop.visible=not unseen;panel.visible=not unseen
    _layout_typing()
    var entry_size:=8 if buffer.length()>18 else 12
    entry.visible=_typing();entry.text=_clip(buffer+"_",entry_size,entry.size.x,true)
    entry.add_theme_font_size_override("font_size",entry_size)
    if on_title:
        var chosen_row:Label=title_rows[clampi(selection,0,title_rows.size()-1)]
        # Just left of the chosen row's first trainer.
        var trainers:int=TITLE_TRAINERS[clampi(selection,0,title_rows.size()-1)].size()
        title_tick.position.x=roundf(chosen_row.position.x+TITLE_TRAINER_X[TITLE_TRAINER_X.size()-trainers]-12.0)
        main._align_menu_tick(title_tick,chosen_row) # Same glyph-centred height as every other menu.
        return
    panel.get_node("Title").text=_title()
    var names:=_names()
    var forming:=page=="server_form"
    var listing:=page in ["load","browse","servers"]
    if names.is_empty():selection=0;_scroll=0
    else:
        selection=clampi(selection,0,names.size()-1)
        _scroll=0 if forming else clampi(_scroll,maxi(0,selection-VISIBLE_ROWS+1),selection)
    if forming and _sure and _form_ids()[selection]!="delete":_sure=false;_hint=""
    # A bin stays armed only while its world is the one chosen.
    if _trash_armed>=0 and (page!="load" or selection!=_trash_armed):_trash_armed=-1;_hint=""
    for i in range(rows.size()):
        var index:=_scroll+i
        rows[i].visible=not _typing() and not forming and page not in ["connecting","loading"] and index<names.size()
        rows[i].text=names[index] if index<names.size() else ""
        rows[i].add_theme_font_size_override("font_size",8 if listing else 12)
        edit_tags[i].visible=page=="servers" and index<servers.size()
        ping_labels[i].visible=edit_tags[i].visible
        if ping_labels[i].visible:_ping_line(ping_labels[i],servers[index])
        trash_bins[i].visible=page=="load" and index<entries.size()
        trash_bins[i].modulate=Color(1.0,0.35,0.3) if index==_trash_armed else Color.WHITE
    _refresh_form()
    var no_servers:=page=="servers" and servers.is_empty()
    empty.visible=(listing and names.is_empty()) or no_servers
    # Set here, not when built: its first long text had widened it past the panel.
    empty.position.y=62.0 if page=="servers" else 36.0;empty.size=Vector2(196,48 if page=="servers" else 74)
    empty.text=EMPTY_LOBBIES if page=="browse" else (EMPTY_SERVERS if page=="servers" else "No saved multiplayer worlds on this device yet. Go back and choose NEW WORLD.")
    tick.visible=not names.is_empty() and not _typing() and page not in ["connecting","loading"]
    if tick.visible:main._align_menu_tick(tick,form_rows[selection] if forming else rows[selection-_scroll])
    var scrolling:bool=listing and tick.visible and names.size()>VISIBLE_ROWS
    counter.visible=listing and tick.visible
    counter.text="%d/%d"%[selection+1,names.size()]
    more_above.visible=scrolling and _scroll>0
    more_below.visible=scrolling and _scroll+VISIBLE_ROWS<names.size()
    page_up.visible=more_above.visible;page_down.visible=more_below.visible
    _update_status()

## Caption and value of each form row (the password only as asterisks).
func _refresh_form()->void:
    var ids:Array=_form_ids() if page=="server_form" else []
    for i in range(form_rows.size()):
        form_rows[i].visible=i<ids.size()
        if i>=ids.size():continue
        var id:String=ids[i]
        var action:String={"save":"SAVE AND JOIN" if _from_lobby else "SAVE","delete":"SURE?" if _sure else "DELETE","back":"BACK"}.get(id,"")
        form_rows[i].text=String(CAPTIONS[id]) if CAPTIONS.has(id) else action
        var value:String="*".repeat(String(_draft.get(id,"")).length()) if id=="password" else String(_draft.get(id,""))
        var shown:Label=form_rows[i].get_node("Value")
        shown.text=_clip(value,8,float(182-VALUE_X));shown.position.y=-3.0 if id=="password" else 0.0

func _update_status()->void:
    if page in ["connecting","loading"]:return # Owned by the join or load in progress.
    var lines:PackedStringArray=[]
    match page:
        "title":lines.append("A: SELECT")
        "password_set":lines.append("FRIENDS NEED THIS PASSWORD TO JOIN.");lines.append("A: OK   B: BACK")
        "password_join":lines.append("ASK THE HOST FOR THE PASSWORD.");lines.append("A: JOIN   B: BACK")
        "servers":
            lines.append("TAP A SERVER TO JOIN IT.")
            lines.append("A: JOIN   %s: EDIT   B: BACK"%("START" if not Input.get_connected_joypads().is_empty() else "E"))
        "server_form":
            var id:String=_form_ids()[clampi(selection,0,_form_ids().size()-1)]
            lines.append(String(FIELD_HINTS.get(id,"")));lines.append("A: %s   B: BACK"%("TYPE" if FIELD_HINTS.has(id) else "SELECT"))
        "server_text":lines.append(String(FIELD_HINTS.get(_field,"")));lines.append("A: OK   B: BACK")
        "browse":
            var trouble:=String(main.coop_game.lobby.list_error)
            lines.append(Network.status_text() if trouble.is_empty() else trouble);lines.append("A: JOIN   B: BACK")
        "load":lines.append("A: LOAD   B: BACK")
        _:lines.append(Network.status_text());lines.append("A: SELECT   B: BACK")
    if not _hint.is_empty():lines[0]=_hint
    status.text="\n".join(lines)

## "v0.10.214  23MS" in green (it would let you in) or red, "OLD VERSION" / "UNKNOWN SERVER" in red,
## "OFFLINE" / "BUSY" in grey, "..." until the first answer.
func _ping_line(label:Label,server:Dictionary)->void:
    var found:Dictionary=_pings.get(_ping_key(server),{}).get("result",{})
    var state:=String(found.get("state",""))
    var text:=String({"old":"OLD VERSION","unknown":"UNKNOWN SERVER","offline":"OFFLINE","busy":"BUSY"}.get(state,"..."))
    var color:String="red" if state in ["old","unknown"] else "grey"
    if state=="ok":
        var version:=String(found.version);var build:=String(found.build)
        text="%s  %dMS"%["V"+version if not version.is_empty() else ("BUILD "+build.left(7) if not build.is_empty() else "DEV BUILD"),int(found.ms)]
        color="green" if found.compatible else "red"
    label.text=text.to_upper();label.modulate=(PING_COLORS_DARK if Settings.enabled("dark_mode") else PING_COLORS)[color]

static func _ping_key(server:Dictionary)->String:
    var target:=parse_address(String(server.get("address","")))
    return "" if target.is_empty() else "%s:%d"%[target.address,int(target.port)]

## Every frame on MY SERVERS: answers read as they come, a new question every PING_EVERY_MS.
func _poll_pings()->void:
    var now:=Time.get_ticks_msec()
    var changed:=false
    if _mods.is_empty():_mods=String(preload("res://scripts/coop_identity.gd").mods().get("digest","-"))
    for server in servers:
        var key:=_ping_key(server)
        if key.is_empty():continue
        var ping:Dictionary=_pings.get(key,{"probe":null,"result":{},"next":0})
        _pings[key]=ping
        if ping.probe==null and now>=int(ping.next):
            var target:=parse_address(String(server.address))
            ping.probe=Ping.new(String(target.address),int(target.port),_mods)
        if ping.probe!=null and ping.probe.poll():
            ping.result=ping.probe.result;ping.probe=null;ping.next=now+PING_EVERY_MS;changed=true
    if changed:refresh()

func _process(_delta:float)->void:
    if visible and page=="servers":_poll_pings()
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
            elif selection==1:lobbies=[];_go("browse")
            else:servers=Saved.load_all();_go("servers")
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
            if bool(lobby.get("accounts",false)):_join_account_lobby(lobby);return
            main.coop_game.join_lobby=lobby.duplicate(true);main.coop_game.join_password=""
            if lobby.private:_go("password_join")
            else:chosen.emit("JOIN_SETUP",String(lobby.address))
        "password_set","password_join":submit_password()
        "servers":
            if selection<servers.size():_join(selection)
            else:_open_form(-1)
        "server_form":_form_activate()
        "server_text":_commit_field()

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
    # A saved server goes back to its form when the host names the ID or password, else to the list.
    var direct:=bool(main.coop_game.join_lobby.get("direct",false))
    var upper:=reason.to_upper()
    if direct and _joining>=0 and _joining<servers.size() and ("PASSWORD" in upper or "PLAYER ID" in upper):
        _open_form(_joining,2 if "PLAYER ID" in upper else 3)
    else:_go("servers" if direct else "browse")
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

## "1.2.3.4:5000", "my.server.net" (default port), an IPv6 address
## ("[2001:db8::1]:5000" or bare), or an 8-letter join code.
static func parse_address(text:String)->Dictionary:
    text=text.strip_edges()
    var code:=JoinCode.decode(text)
    if not code.is_empty():return {"address":code,"port":JoinCode.PORT}
    var host:=text
    var digits:=""
    if text.begins_with("[") and "]" in text:
        host=text.substr(1,text.find("]")-1);digits=text.substr(text.find("]")+1).trim_prefix(":")
    elif text.count(":")==1:
        host=text.get_slice(":",0);digits=text.get_slice(":",1)
    var port:=JoinCode.PORT
    if not digits.is_empty():
        if not digits.is_valid_int() or int(digits)<1 or int(digits)>65535:return {}
        port=int(digits)
    if host.is_empty() or host.length()>ADDRESS_LENGTH:return {}
    if ":" in host:return {"address":host,"port":port} if host.is_valid_ip_address() else {}
    for character in host:
        if not (character.to_lower() in "abcdefghijklmnopqrstuvwxyz0123456789.-"):return {}
    return {"address":host,"port":port}

## Joins the saved server in one step. A player ID means the account password goes to the
## server as such; without an ID the password is the host's old shared server password.
func _join(index:int)->void:
    var server:Dictionary=servers[index]
    var target:=parse_address(String(server.address))
    if target.is_empty():_open_form(index,1);_hint="CHECK THE ADDRESS.";_update_status();return
    _joining=index
    main.coop_game.join_lobby={"name":server.name,"address":target.address,"port":target.port,"direct":true,"private":false,
        "salt":"","account_id":server.id,"account_password":server.password}
    main.coop_game.join_password=String(server.password) if String(server.id).is_empty() else ""
    _hide_keyboard()
    chosen.emit("JOIN_SETUP",String(target.address))

func _edit_selected()->void:
    if page=="servers" and selection<servers.size():_open_form(selection)

## The form for a saved entry, or a new one (index -1, optionally prefilled), on the given row.
func _open_form(index:int,row:int=0,prefill:Dictionary={})->void:
    _edit=index;_from_lobby=index<0 and not prefill.is_empty()
    _draft={"name":"","address":"","id":"","password":""}
    _draft.merge(servers[index] if index>=0 else prefill,true)
    selection=row;_go("server_form",true)

## A LAN lobby with player accounts needs an ID and password. A server already saved with its
## address is joined straight away; otherwise the form opens with the name and address filled in.
func _join_account_lobby(lobby:Dictionary)->void:
    var address:=String(lobby.address)
    var port:=int(lobby.get("port",Network.GAME_PORT))
    servers=Saved.load_all()
    for i in range(servers.size()):
        var saved:=parse_address(String(servers[i].address))
        if not saved.is_empty() and String(saved.address)==address and int(saved.port)==port:_join(i);return
    var prefill:=Saved.clean({"name":lobby.name,"address":("[%s]:%d" if ":" in address else "%s:%d")%[address,port]})
    _open_form(-1,2,prefill)

func _form_activate()->void:
    var id:String=_form_ids()[clampi(selection,0,_form_ids().size()-1)]
    match id:
        "save":_save()
        "delete":
            if _sure:_delete()
            else:_sure=true;refresh();_hint="TAP AGAIN TO DELETE IT.";_update_status()
        "back":_back()
        _:
            _field=id;_go("server_text")

## Takes the typed text back to the form (not yet saved); a bad address stays for correcting.
func _commit_field()->void:
    var value:=buffer.strip_edges()
    if _field=="address" and not value.is_empty() and parse_address(value).is_empty():
        _hint="TYPE IP:PORT, OR A JOIN CODE.";_update_status();return
    _draft[_field]=value
    selection=FIELDS.find(_field);_go("server_form",true)

func _save()->void:
    var server:=Saved.clean(_draft)
    if parse_address(String(server.address)).is_empty():
        selection=1;refresh();_hint="TYPE IP:PORT, HOST NAME OR A JOIN CODE.";_update_status();return
    if _edit>=0:servers[_edit]=server
    else:servers.append(server);_edit=servers.size()-1
    if not Saved.save_all(servers):_hint="THE LIST COULD NOT BE SAVED.";_update_status();return
    if _from_lobby:_join(_edit);return
    selection=_edit;_go("servers",true);_hint="SAVED.";_update_status()

## SAVED WORLDS' bin (START or E on a controller or keyboard): the first press
## asks (the bin turns red), the second deletes that online world from the device.
func _trash(index:int)->void:
    if page!="load" or index>=entries.size():return
    if _trash_armed!=index:
        _trash_armed=index;selection=index
        _hint="TAP THE BIN AGAIN TO DELETE IT.";refresh();_update_status();return
    _trash_armed=-1
    if main.coop_game.saves.delete_world(String(entries[index].id))==OK:
        entries.remove_at(index);selection=clampi(selection,0,maxi(0,entries.size()-1))
        _hint="DELETED."
    else:_hint="IT COULD NOT BE DELETED."
    refresh();_update_status()

func _delete()->void:
    servers.remove_at(_edit)
    var saved:=Saved.save_all(servers)
    selection=_edit;_go("servers",true)
    _hint="DELETED." if saved else "THE LIST COULD NOT BE SAVED.";_update_status()

## One page of a long list at a time for fingers: the visible rows move, the cursor stays on screen.
func _nudge(direction:int)->void:
    _scroll=clampi(_scroll+direction,0,maxi(0,_count()-VISIBLE_ROWS))
    selection=clampi(selection,_scroll,_scroll+VISIBLE_ROWS-1);refresh()

## Back one step. From the form a lobby-prefilled one returns to the lobby list.
func _back()->void:
    if page=="title":return
    main.coop_game.cancel_join()
    var back:=String(BACK.get(page,"title"))
    var keep:=false
    var direct:=bool(main.coop_game.join_lobby.get("direct",false))
    if page in ["connecting","password_join"] and direct:back="servers"
    elif page=="server_text":selection=FIELDS.find(_field);keep=true
    elif page=="server_form":
        if _from_lobby:back="browse"
        else:selection=_edit if _edit>=0 else servers.size();keep=true
    _go(back,keep)

func _typing()->bool:
    return page in ["password_set","password_join","server_text"]

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
            activate();return
        if event.keycode not in [KEY_ESCAPE,KEY_BACK] and event.unicode>=32 and event.unicode!=127:
            var character:=String.chr(event.unicode)
            if buffer.length()<_limit() and (_field!="id" or page!="server_text" or Saved.id_char(character)):buffer+=character;refresh()
            return
    var direction=0
    if event.is_action_pressed("move_down") or event.is_action_pressed("move_right"):direction=1
    elif event.is_action_pressed("move_up") or event.is_action_pressed("move_left"):direction=-1
    if event.is_action_pressed("cancel") or (event is InputEventKey and event.pressed and event.keycode in [KEY_ESCAPE,KEY_BACK]):
        _back()
    elif page=="servers" and ((event is InputEventJoypadButton and event.pressed and event.is_action_pressed("start")) or (event is InputEventKey and event.pressed and event.keycode==KEY_E)):_edit_selected()
    elif page=="load" and ((event is InputEventJoypadButton and event.pressed and event.is_action_pressed("start")) or (event is InputEventKey and event.pressed and event.keycode==KEY_E)):_trash(selection)
    elif event.is_action_pressed("confirm") or (event is InputEventKey and event.pressed and event.keycode in [KEY_ENTER,KEY_KP_ENTER]):activate()
    elif direction!=0 and not _typing() and page!="connecting":
        var count:=_count()
        if count>0:selection=wrapi(selection+direction,0,count);refresh()
