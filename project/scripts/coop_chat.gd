extends Control
## World chat for everyone in an online world. A guest sends its text to the
## host; the host (or dedicated server) relays it to every player, the sender
## included, under the name its session gave that connection.
## Chat text is untrusted input from the network. It goes through clean() on
## the sender, on the host before relaying and again on every receiver, and is
## only ever shown as the text of plain Labels: no BBCode, no translation
## lookup, never a format string, never parsed or evaluated.
## This node is the open chat (T, or CHAT on a touch screen): the last HISTORY
## lines over the line being typed, in the HUD's glass. New lines also show
## for a few seconds in a chip beside the minimap.
const HudStyle=preload("res://scripts/hud_style.gd")
const Server=preload("res://scripts/dedicated_server.gd")
const MAX_LENGTH:=80
const NAME_LENGTH:=24
const HISTORY:=20
## Host, per player: at most RATE messages in RATE_MS; the rest are dropped.
const RATE:=3
const RATE_MS:=5000
## What the HUD font draws, less < and >, which it draws as PK and MN.
const GLYPHS:=" !%',-./0123456789:?ABCDEFGHIJKLMNOPQRSTUVWXYZ_abcdefghijklmnopqrstuvwxyzÉé"
## Characters that count as a space; a run of them becomes one.
const SPACES:=[9,10,11,12,13,32,0x85,0xA0,0x1680,0x2028,0x2029,0x202F,0x205F,0x3000]
## Line pitch, as the notice chip: the capitals' 6 px of ink and a 4 px gap.
const LINE:=10
const LOG_MESSAGES:=3
const LOG_LINES:=4
const LOG_SECONDS:=6.0
var main:Node
var game:Node
var session:Node
var history:Array[String]=[]
var buffer:=""
## Lines scrolled back from the newest.
var scroll:=0
var _sent:Dictionary={}
var _lines:Label
var _entry:Label
var _log:Control
var _log_text:Label
var _log_fade:Tween

## The one way chat text is made safe: anything but a String is "", control,
## bidi and zero-width characters go, a run of spaces becomes one, a character
## the font cannot draw becomes ?, and it is cut to `limit` characters.
static func clean(value:Variant,limit:int=MAX_LENGTH)->String:
    if not value is String:return ""
    var out:=""
    var space:=false
    for character in (value as String).left(limit*8):
        var code:=character.unicode_at(0)
        if code in SPACES or (code>=0x2000 and code<=0x200A):space=not out.is_empty();continue
        if code<0x20 or (code>=0x7F and code<=0x9F) or (code>=0x200B and code<=0x200F) or (code>=0x202A and code<=0x202E) \
                or (code>=0x2060 and code<=0x2069) or code in [0x061C,0xFEFF]:continue
        if space:out+=" ";space=false
        out+=character if GLYPHS.contains(character) else "?"
        if out.length()>=limit:break
    return out

## A sender's name: cleaned, without a colon (it could pose as another sender).
static func clean_name(value:Variant)->String:
    var name:=clean(value,NAME_LENGTH).replace(":","").strip_edges()
    return name if not name.is_empty() else "PLAYER"

func configure(owner_main:Node,coordinator:Node)->void:
    main=owner_main;game=coordinator;session=game.session;z_index=350
    _lines=_label(self);_entry=_label(self)
    _log=HudStyle.chip(main.get_node("UI"),"ChatLog");_log.z_index=340;_log.hide()
    _log_text=_log.get_node("Text");_text_settings(_log_text)
    _text_settings(_lines);_entry.auto_translate_mode=Node.AUTO_TRANSLATE_MODE_DISABLED
    hide()
    visibility_changed.connect(_sync_gameplay)

func _label(parent:Node)->Label:
    var label:=HudStyle.label();parent.add_child(label);return label

## Shown as typed, never looked up as a translation key.
func _text_settings(label:Label)->void:
    label.auto_translate_mode=Node.AUTO_TRANSLATE_MODE_DISABLED
    label.autowrap_mode=TextServer.AUTOWRAP_WORD_SMART
    label.add_theme_constant_override("line_spacing",LINE-roundi(HudStyle.FONT.get_height(HudStyle.FONT_SIZE)))

func available()->bool:
    return game.active and session.trusted and main.started and not main.generating

# --- network ------------------------------------------------------------------

## coop_game.gd hands every packet here first; true when it was chat.
func message(peer:int,actor:String,packet:Dictionary)->bool:
    if packet.get("kind")!="chat":return false
    if session.hosting:relay(peer,actor,packet.get("text"))
    else:receive(packet)
    return true

## This player's message. The host relays it at once; a guest sends it to the
## host, whose echo shows it here.
func send(text:String)->void:
    var line:=clean(text)
    if line.is_empty() or not session.trusted:return
    var sent:bool=relay(1,session.actor,line) if session.hosting else (_allowed("") and session.send_host({"kind":"chat","text":line})==OK)
    if not sent:_add("","Too fast. Wait a moment.")

## Host: a message from `peer` (1 = this player), checked again whatever the
## sender's game did. Text that is not a String or cleans to nothing, and a
## player over the rate limit, are dropped. The name is the one this session
## gave the connection, never one from the message.
func relay(peer:int,actor:String,text:Variant)->bool:
    var line:=clean(text)
    if line.is_empty() or not session.players.has(peer) or not _allowed(actor):return false
    var name:=clean_name(session.players[peer].profile.get("name"))
    for other in session.players:
        if other!=1:session.send_to(other,{"kind":"chat","name":name,"text":line})
    if Server.active:print("CHAT ",name,": ",line)
    _add(name,line)
    return true

## Guest: the host's relay, cleaned again here.
func receive(packet:Dictionary)->void:
    if not packet.get("name") is String or not packet.get("text") is String:return
    var line:=clean(packet.text)
    if not line.is_empty():_add(clean_name(packet.name),line)

func _allowed(key:String)->bool:
    var now:=Time.get_ticks_msec()
    var times:Array=_sent.get(key,[]).filter(func(at):return now-int(at)<RATE_MS)
    var allowed:=times.size()<RATE
    if allowed:times.append(now)
    _sent[key]=times
    return allowed

## A line for the history: "NAME: text", or a note of this game's own without a name.
func _add(name:String,line:String)->void:
    history.append(line if name.is_empty() else name+": "+line)
    while history.size()>HISTORY:history.pop_front()
    if main==null or not main.started:return
    if visible:_refresh()
    else:_show_log()

# --- the log beside the minimap -------------------------------------------------

func _show_log()->void:
    _log_text.text="\n".join(history.slice(-LOG_MESSAGES))
    var room:=_log_room()
    var ink:=HudStyle.FONT.get_multiline_string_size(_log_text.text,HORIZONTAL_ALIGNMENT_LEFT,room,HudStyle.FONT_SIZE,-1,
        TextServer.BREAK_MANDATORY|TextServer.BREAK_WORD_BOUND|TextServer.BREAK_ADAPTIVE|TextServer.BREAK_TRIM_EDGE_SPACES)
    _log_text.size=Vector2(ink.x,0)
    # The newest lines when the last messages wrap to more than LOG_LINES.
    _log_text.max_lines_visible=-1
    var count:=_log_text.get_line_count()
    _log_text.lines_skipped=maxi(0,count-LOG_LINES);_log_text.max_lines_visible=LOG_LINES
    _log_text.position=Vector2(HudStyle.PAD,HudStyle.PAD+HudStyle.INK_HEIGHT/2.0-HudStyle.INK_CENTRE)
    _log.size=Vector2(ink.x-1+2*HudStyle.PAD,2*HudStyle.PAD+HudStyle.INK_HEIGHT+(mini(count,LOG_LINES)-1)*LINE)
    _place_log();_log.queue_redraw()
    _log.modulate.a=1.0;_log.visible=true
    if _log_fade!=null and _log_fade.is_valid():_log_fade.kill()
    _log_fade=create_tween();_log_fade.set_speed_scale(1.0/maxf(Engine.time_scale,0.01))
    _log_fade.tween_interval(LOG_SECONDS)
    _log_fade.tween_property(_log,"modulate:a",0.0,1.0)
    _log_fade.tween_callback(_log.hide)

## Right of the minimap, under the top row (and under a joined/left notice
## while one shows); on a touch screen, clear of the CHAT button.
func _log_left()->float:
    return main.touch_controls.usable_rect.position.x+HudStyle.MARGIN+main.M3924_MINIMAP_SIZE.x+HudStyle.GAP

func _log_room()->float:
    var right:float=main.touch_controls.usable_rect.end.x-HudStyle.MARGIN
    if _touch():right=button_rect().position.x-HudStyle.GAP
    return right-_log_left()-2*HudStyle.PAD

func _place_log()->void:
    var safe:Rect2=main.touch_controls.usable_rect
    var y:float=safe.position.y+HudStyle.MARGIN+float(main.status_hud.row_height())+HudStyle.GAP
    var notice:Control=game._notice_box
    if is_instance_valid(notice) and notice.visible and notice.modulate.a>0.0:y=notice.position.y+notice.size.y+HudStyle.GAP
    var at:=Vector2(_log_left(),y)
    if _log.position!=at:_log.position=at

func _process(_delta:float)->void:
    if is_instance_valid(_log) and _log.visible:_place_log()

# --- the open chat ----------------------------------------------------------------

func _touch()->bool:
    return is_instance_valid(main.touch_ui) and main.touch_ui.enabled

## True on a phone, or on a PC started with --touch-ui: the keyboard covers the lower half.
func _phone()->bool:
    return OS.has_feature("mobile") or OS.get_cmdline_user_args().has("--touch-ui")

## The CHAT button: right edge, under the menu button.
func button_rect()->Rect2:
    var safe:Rect2=main.touch_controls.usable_rect
    var width:float=main.touch_ui._ink_width("CHAT")+2*HudStyle.PAD
    return Rect2(Vector2(safe.end.x-HudStyle.MARGIN-width,safe.position.y+HudStyle.MARGIN+float(main.status_hud.row_height())+HudStyle.GAP),Vector2(width,HudStyle.ROW))

func open()->void:
    buffer="";scroll=0;_log.hide();show();_refresh();_show_keyboard()

func close()->void:
    hide()
    if OS.has_feature("mobile"):DisplayServer.virtual_keyboard_hide()

func _sync_gameplay()->void:
    if not main.started or main.generating:return
    if visible:main.world.player.velocity=Vector2.ZERO
    main.world.set_gameplay_enabled(not main._field_ui_blocks_gameplay())

func _show_keyboard()->void:
    if OS.has_feature("mobile"):DisplayServer.virtual_keyboard_show(buffer,Rect2i(),DisplayServer.KEYBOARD_TYPE_DEFAULT,MAX_LENGTH,buffer.length(),buffer.length())

## Only what the font draws is typed; the rest of a key or a paste is left out.
func type_text(text:String)->void:
    for character in text.replace("\n"," ").replace("\t"," "):
        if buffer.length()<MAX_LENGTH and GLYPHS.contains(character):buffer+=character
    _refresh()

func paste()->void:
    type_text(DisplayServer.clipboard_get());_show_keyboard()

## Sends what is typed; with nothing typed, closes.
func submit()->void:
    if buffer.strip_edges().is_empty():close();return
    send(buffer);buffer="";scroll=0;_refresh();_show_keyboard()

func handle(event:InputEvent)->void:
    # Typed characters first, so a letter bound to a game action still types.
    if event is InputEventKey:
        if not event.pressed:return
        if event.keycode in [KEY_ESCAPE,KEY_BACK]:close()
        elif event.keycode in [KEY_ENTER,KEY_KP_ENTER]:
            if not event.echo:submit()
        elif event.keycode==KEY_BACKSPACE:buffer=buffer.left(buffer.length()-1);_refresh()
        elif event.keycode in [KEY_UP,KEY_PAGEUP]:scroll_lines(1)
        elif event.keycode in [KEY_DOWN,KEY_PAGEDOWN]:scroll_lines(-1)
        elif event.unicode>=32 and event.unicode!=127:type_text(String.chr(event.unicode))
    elif event.is_action_pressed("cancel"):close()

func scroll_lines(direction:int)->void:
    scroll=maxi(0,scroll+direction);_refresh()

## From the top-left corner, clear of the X; down to the middle on a phone,
## where its keyboard begins. The newest lines at the bottom, over the line typed.
func _refresh()->void:
    var safe:Rect2=main.touch_controls.usable_rect
    var right:float=safe.end.x-HudStyle.MARGIN-(main.touch_ui.close_button.size.x+HudStyle.GAP if _touch() else 0.0)
    var bottom:float=safe.position.y+safe.size.y*0.5 if _phone() else safe.end.y-HudStyle.MARGIN
    position=safe.position+Vector2(HudStyle.MARGIN,HudStyle.MARGIN)
    size=Vector2(right,bottom)-position
    var width:=size.x-2*HudStyle.PAD
    var shown:=maxi(1,int((size.y-HudStyle.ROW-HudStyle.GAP-2*HudStyle.PAD-HudStyle.INK_HEIGHT)/LINE)+1)
    _lines.text="NO MESSAGES YET." if history.is_empty() else "\n".join(history)
    _lines.position=Vector2(HudStyle.PAD,HudStyle.PAD+HudStyle.INK_HEIGHT/2.0-HudStyle.INK_CENTRE)
    _lines.size=Vector2(width,0)
    _lines.max_lines_visible=-1
    var count:=_lines.get_line_count()
    scroll=clampi(scroll,0,maxi(0,count-shown))
    _lines.lines_skipped=maxi(0,count-shown-scroll);_lines.max_lines_visible=shown
    # The typed line, cut from the start so its end stays in view.
    var room:=width-(_buttons_width()+HudStyle.GAP if _touch() else 0.0)
    var typed:=buffer+"_"
    while typed.length()>1 and HudStyle.FONT.get_string_size(typed,HORIZONTAL_ALIGNMENT_LEFT,-1,HudStyle.FONT_SIZE).x>room:typed=typed.substr(1)
    _entry.text=typed
    _entry.position=Vector2(HudStyle.PAD,size.y-HudStyle.ROW+HudStyle.ROW/2.0-HudStyle.INK_CENTRE-1.0)
    queue_redraw()

func _draw()->void:
    HudStyle.draw_shape(self,Rect2(Vector2.ZERO,size),false,HudStyle.INK,false,HudStyle.STROKE,true)
    var y:=size.y-HudStyle.ROW-1.0
    draw_line(Vector2(HudStyle.PAD,y),Vector2(size.x-HudStyle.PAD,y),Color(HudStyle.INK,0.5),1.0)

func _buttons_width()->float:
    return main.touch_ui._ink_width("PASTE")+main.touch_ui._ink_width("SEND")+4*HudStyle.PAD+HudStyle.GAP

## Touch: PASTE and SEND at the end of the typed line, the X closes, a tap on
## the box brings the phone keyboard back and a drag scrolls.
func surface()->Dictionary:
    var send_width:float=main.touch_ui._ink_width("SEND")+2*HudStyle.PAD
    var paste_width:float=main.touch_ui._ink_width("PASTE")+2*HudStyle.PAD
    var y:=position.y+size.y-HudStyle.ROW-1.0
    var send_at:=Rect2(Vector2(position.x+size.x-HudStyle.PAD/2.0-send_width,y),Vector2(send_width,HudStyle.ROW))
    var paste_at:=Rect2(Vector2(send_at.position.x-HudStyle.GAP-paste_width,y),Vector2(paste_width,HudStyle.ROW))
    return {"modal":false,"hide_pad":true,"hud":true,
        "buttons":[["PASTE",paste,paste_at],["SEND",submit,send_at]],
        "rows":[get_global_rect()],"tap":func(_i):_show_keyboard(),
        "scroll":func(direction):scroll_lines(-direction),
        "back":close}
