extends Control
## World chat for everyone in an online world. A guest sends its text to the
## host; the host (or dedicated server) relays it to every player, the sender
## included, under the name its session gave that connection.
## Chat text is untrusted input from the network. It goes through clean() on
## the sender, on the host before relaying and again on every receiver, and is
## only ever shown as the text of plain Labels: no BBCode, no translation
## lookup, never a format string, never parsed or evaluated.
## This node is the open chat (T, or the chat button on a touch screen): the
## last HISTORY lines over the line being typed, in the HUD's glass. The newest
## message also shows for a few seconds in a chip centred under the clock (and
## under coop_game.gd's notice), and lights a red dot on the chat button until
## the chat is opened.
const HudStyle=preload("res://scripts/hud_style.gd")
const Icons=preload("res://scripts/touch_icons.gd")
const BADGE:=Color8(232,56,40)
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
## The newest message: at most LOG_LINES lines (then "..."), for LOG_SECONDS.
const LOG_LINES:=3
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
## The online HUD (the log, the chat button, coop_game.gd's notice): placed on
## the whole screen like the top row, not on the centred 320x180 area.
var hud:Control
var _button:Control
## A message from someone else arrived while the chat was closed.
var unread:=false
var _button_look:=[]

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
    hud=Control.new();hud.name="OnlineHud";hud.mouse_filter=Control.MOUSE_FILTER_IGNORE;main.get_node("UI").add_child(hud)
    _log=HudStyle.chip(hud,"ChatLog");_log.z_index=340;_log.hide()
    _button=Control.new();_button.name="ChatButton";_button.mouse_filter=Control.MOUSE_FILTER_IGNORE
    _button.z_index=80;_button.texture_filter=CanvasItem.TEXTURE_FILTER_NEAREST;_button.hide();hud.add_child(_button)
    _button.draw.connect(_draw_button);main.status_hud.chat_chip=_button
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
        if other!=1:session.send_to(other,{"kind":"chat","name":name,"text":line,"mine":other==peer})
    if Server.active:print("CHAT ",name,": ",line)
    _add(name,line,peer==1)
    return true

## Guest: the host's relay, cleaned again here. "mine": the echo of this
## player's own message (it only keeps the red dot off).
func receive(packet:Dictionary)->void:
    if not packet.get("name") is String or not packet.get("text") is String:return
    var line:=clean(packet.text)
    if not line.is_empty():_add(clean_name(packet.name),line,packet.get("mine")==true)

func _allowed(key:String)->bool:
    var now:=Time.get_ticks_msec()
    var times:Array=_sent.get(key,[]).filter(func(at):return now-int(at)<RATE_MS)
    var allowed:=times.size()<RATE
    if allowed:times.append(now)
    _sent[key]=times
    return allowed

## A line for the history: "NAME: text", or a note of this game's own without a name.
func _add(name:String,line:String,mine:bool=false)->void:
    history.append(line if name.is_empty() else name+": "+line)
    while history.size()>HISTORY:history.pop_front()
    if main==null or not main.started:return
    # This game's own notes (Too fast) only show in the open chat.
    if visible or name.is_empty():
        if visible:_refresh()
        return
    _show_log(name+": "+line)
    if not mine:unread=true

# --- the newest message under the clock ----------------------------------------------

## The newest message, centred under the clock (under a notice while one
## shows), wrapped as the notice and cut to LOG_LINES lines (the open chat
## keeps it whole); LOG_SECONDS later it fades. A new one replaces it.
func _show_log(text:String)->void:
    fit(_log,text,room(),LINE,LOG_LINES)
    _place_log()
    _log.modulate.a=1.0;_log.visible=true
    if _log_fade!=null and _log_fade.is_valid():_log_fade.kill()
    _log_fade=create_tween();_log_fade.set_speed_scale(1.0/maxf(Engine.time_scale,0.01))
    _log_fade.tween_interval(LOG_SECONDS)
    _log_fade.tween_property(_log,"modulate:a",0.0,1.0)
    _log_fade.tween_callback(_log.hide)

## Where the notice and the newest message centre: on the clock, or mid-screen without it.
func centre()->float:
    var clock:Control=main.status_hud.clock_chip
    return clock.position.x+clock.size.x/2.0 if is_instance_valid(clock) and clock.visible else main.get_viewport().get_visible_rect().size.x/2.0

## Their wrap width: the room the minimap leaves either side of the middle, at
## most what a 320 px screen has, so a wider phone wraps them the same way.
func room()->float:
    var left:float=main.get_viewport().get_visible_rect().size.x/2.0-main.touch_controls.usable_rect.position.x
    return 2.0*(minf(left,160.0)-(HudStyle.MARGIN+main.M3924_MINIMAP_SIZE.x+HudStyle.GAP+HudStyle.PAD))

static func _advance(text:String)->float:
    return HudStyle.FONT.get_string_size(text,HORIZONTAL_ALIGNMENT_LEFT,-1,HudStyle.FONT_SIZE).x

## Lines no wider than `width`: whole words, a word longer than a line cut inside it.
## Broken here, not by the Label, so the chip is sized to exactly what it shows.
static func wrap_lines(text:String,width:float)->PackedStringArray:
    var lines:=PackedStringArray()
    for part in text.split("\n"):
        var line:=""
        for word in part.split(" ",false):
            var joined:=word if line.is_empty() else line+" "+word
            if _advance(joined)<=width:line=joined;continue
            if _advance(word)>width:line=joined
            else:lines.append(line);line=word
            while _advance(line)>width:
                var cut:=line.length()-1
                while cut>1 and _advance(line.left(cut))>width:cut-=1
                lines.append(line.left(cut).strip_edges());line=line.substr(cut).strip_edges()
        lines.append(line)
    return lines

## A HUD chip of centred text in lines no wider than `width`, `line` px apart;
## past `most` lines it is cut and the last ends in "...". The ink PAD from
## every edge, as on the chips (glyphs leave their last column blank).
static func fit(box:Control,text:String,width:float,line:int,most:int=0)->void:
    var lines:=wrap_lines(text,width)
    if most>0 and lines.size()>most:
        lines.resize(most)
        var last:String=lines[most-1]
        while not last.is_empty() and _advance(last+"...")>width:
            var space:int=last.rfind(" ")
            last=last.left(space) if space>0 else last.left(-1)
        lines[most-1]=last+"..."
    var ink:=0.0
    for shown in lines:ink=maxf(ink,_advance(shown))
    var label:=box.get_node("Text") as Label
    label.autowrap_mode=TextServer.AUTOWRAP_OFF;label.horizontal_alignment=HORIZONTAL_ALIGNMENT_CENTER
    label.text="\n".join(lines);label.size=Vector2(ink,0)
    label.position=Vector2(HudStyle.PAD,HudStyle.PAD+HudStyle.INK_HEIGHT/2.0-HudStyle.INK_CENTRE)
    box.size=Vector2(ink-1+2*HudStyle.PAD,2*HudStyle.PAD+HudStyle.INK_HEIGHT+(lines.size()-1)*line)
    box.queue_redraw()

## GAP under the clock, or under the notice while one shows: it follows the
## notice coming and going.
func _place_log()->void:
    var y:float=main.touch_controls.usable_rect.position.y+HudStyle.MARGIN+float(main.status_hud.row_height())+HudStyle.GAP
    var notice:Control=game._notice_box
    if is_instance_valid(notice) and notice.visible and notice.modulate.a>0.0:y=notice.position.y+notice.size.y+HudStyle.GAP
    var at:=Vector2(roundf(centre()-_log.size.x/2.0),y)
    if _log.position!=at:_log.position=at

func _process(_delta:float)->void:
    if is_instance_valid(_log) and _log.visible:_place_log()
    if is_instance_valid(_button):_sync_button()

# --- the chat button ----------------------------------------------------------------

## On a touch screen while the field is up: in the top row between the battery
## and the menu button (status_hud.gd places it), as big as the menu button.
func _sync_button()->void:
    var shown:bool=_touch() and available() and not visible and main.status_hud.top_free and main.touch_ui.surfaces._field_active()
    var side:float=main.status_hud.row_height()
    if _button.size!=Vector2(side,side):_button.size=Vector2(side,side)
    if _button.visible!=shown:_button.visible=shown;main.status_hud._place()
    var look:=[unread,HudStyle.dark,side]
    if look!=_button_look:_button_look=look;_button.queue_redraw()

## The menu button's glass and ring, a speech bubble, and the red dot on its corner.
func _draw_button()->void:
    HudStyle.draw_shape(_button,Rect2(Vector2.ZERO,_button.size),false,HudStyle.INK,false,HudStyle.STROKE,true)
    var icon:=Icons.icon("CHAT")
    _button.draw_texture(icon,((_button.size-icon.get_size())/2.0).round())
    if unread:
        _button.draw_circle(Vector2(_button.size.x-2.0,2.0),3.5,HudStyle.fill(false,true))
        _button.draw_circle(Vector2(_button.size.x-2.0,2.0),2.5,BADGE)

## Where a tap opens the chat; empty while the button is hidden.
func button_rect()->Rect2:
    return _button.get_global_rect() if is_instance_valid(_button) and _button.visible else Rect2()

# --- the open chat ----------------------------------------------------------------

func _touch()->bool:
    return is_instance_valid(main.touch_ui) and main.touch_ui.enabled

## True on a phone, or on a PC started with --touch-ui: the keyboard covers the lower half.
func _phone()->bool:
    return OS.has_feature("mobile") or OS.get_cmdline_user_args().has("--touch-ui")

func open()->void:
    buffer="";scroll=0;unread=false;_log.hide();show();_refresh();_show_keyboard()

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
