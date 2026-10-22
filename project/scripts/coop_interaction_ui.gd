extends Control
## Player-to-player choices use the same menu frame, font and tick as the game's
## other in-game dialogs (QUIT GAME?, KICK): a box as big as its text, centred
## and clear of the HUD's top row and minimap. On a touch screen every row is a
## finger-sized target (touch_surfaces.gd), the X button cancels and the A/B
## hints are left out.
signal battle_accepted(session:Dictionary)
const HudStyle=preload("res://scripts/hud_style.gd")
const FONT_SIZE:=10
const LINE:=13
const PITCH:=16
const PAD:=12
const ROW_X:=24
const MIN_WIDTH:=96
var main:Node
var game:Node
var target:=""
var phase:=""
var selection:=0
## The first choice on screen, when there are more than fit.
var first:=0
var busy:=false
var stick_y:=0
var interaction:Dictionary={}
var panel:Panel
var title:Label
var rows:Array[Label]=[]
var tick:TextureRect
var footer:Label

func configure(owner_main:Node,coordinator:Node)->void:
    main=owner_main;game=coordinator;z_index=350;size=Vector2(320,180)
    panel=Panel.new();add_child(panel)
    title=main._source_ui_label(panel,"Title",Vector2(PAD,9),Vector2(224,LINE),FONT_SIZE,"")
    title.autowrap_mode=TextServer.AUTOWRAP_WORD_SMART
    for i in range(6):
        var label:Label=main._source_ui_label(panel,"Choice%d"%i,Vector2(ROW_X,0),Vector2(210,PITCH),FONT_SIZE,"")
        label.vertical_alignment=VERTICAL_ALIGNMENT_CENTER
        label.mouse_filter=Control.MOUSE_FILTER_STOP
        label.gui_input.connect(func(event):
            if event is InputEventMouseButton and event.pressed and event.button_index==MOUSE_BUTTON_LEFT:
                selection=first+i;activate();accept_event())
        rows.append(label)
    tick=main._source_texture_rect(panel,"Tick",Vector2(PAD,0),Vector2(5,7),main.source_command_cursor.texture)
    footer=main._source_ui_label(panel,"Footer",Vector2(PAD,0),Vector2(224,12),7,"A: SELECT   B: CANCEL")
    hide()
    visibility_changed.connect(_sync_gameplay)

func _sync_gameplay()->void:
    if not main.started or main.generating:return
    if visible:main.world.player.velocity=Vector2.ZERO
    main.world.set_gameplay_enabled(not main._field_ui_blocks_gameplay())

func open_for(actor:String)->void:
    target=actor;phase="choose";selection=0;stick_y=0;interaction={};show();refresh()

func choices()->Array:
    match phase:
        "beacons":return game.beacons.names()
        "choose":return ["TRADE","BATTLE"]
        "invite":return ["ACCEPT","DECLINE"]
        "confirm":return ["CONFIRM","CHANGE POKEMON","CANCEL"]
        "trade":
            var names:Array=[]
            for pokemon in main.caught_pokemon:names.append(main.PokemonState.display_name(pokemon))
            return names
    return []

func refresh()->void:
    panel.add_theme_stylebox_override("panel",main._classic_dialogue_style())
    var names=choices();selection=clampi(selection,0,maxi(0,names.size()-1))
    title.text={"invite":"%s REQUEST"%String(interaction.get("kind","")),
        "trade":"CHOOSE YOUR POKEMON","wait":"WAITING FOR THE OTHER PLAYER...","confirm":"CONFIRM THIS TRADE?"}.get(phase,"")
    if phase=="beacons":title.text="SAVING BEACONS..." if game.beacons.busy else ("NO BEACONS" if names.is_empty() else "CHOOSE A BEACON")
    if phase=="confirm":
        var offers:Dictionary=interaction.get("offers",{})
        var other=String(interaction.b) if interaction.get("a")==game.session.actor else String(interaction.get("a",""))
        if offers.has(other):title.text="RECEIVE "+main.PokemonState.display_name(offers[other].pokemon)+"?"
    _layout(names)

## The box fits its text: centred, under the HUD's top row, and no wider than
## the room between the minimap and the same margin on the right.
func _layout(names:Array)->void:
    var touch:bool=is_instance_valid(main.touch_ui) and main.touch_ui.enabled
    var safe:Rect2=main.touch_controls.usable_rect
    var screen:=get_viewport_rect().size
    var top:=safe.position.y+HudStyle.MARGIN+float(main.status_hud.row_height())+HudStyle.GAP
    var centre:=screen.x/2.0
    var widest:float=2.0*(centre-(safe.position.x+HudStyle.MARGIN+main.MINIMAP_SIZE.x+HudStyle.GAP))
    # TRADE / BATTLE needs no title, but shows why an action failed.
    title.visible=not title.text.is_empty()
    # Keyboard and controller hints; a touch screen has the rows and the X instead.
    footer.visible=phase!="choose" and not touch
    footer.text="B: CANCEL" if phase=="wait" else "A: SELECT   B: CANCEL"
    var font:Font=main.JOHTO_FONT
    var width:=float(MIN_WIDTH)
    for name in names:width=maxf(width,ROW_X+font.get_string_size(String(name),HORIZONTAL_ALIGNMENT_LEFT,-1,FONT_SIZE).x+PAD)
    if title.visible:width=maxf(width,2*PAD+font.get_string_size(title.text,HORIZONTAL_ALIGNMENT_LEFT,-1,FONT_SIZE).x)
    if footer.visible:width=maxf(width,2*PAD+font.get_string_size(footer.text,HORIZONTAL_ALIGNMENT_LEFT,-1,7).x)
    width=roundf(minf(width,widest))
    var y:=9.0
    if title.visible:
        title.position=Vector2(PAD,y);title.size=Vector2(width-2*PAD,LINE)
        var lines:=title.get_line_count()
        title.size.y=lines*LINE;y+=lines*LINE+3
    var room:=safe.end.y-HudStyle.MARGIN-top-y-(14.0 if footer.visible else 0.0)-7.0
    var shown:=mini(names.size(),mini(rows.size(),int(room/PITCH)))
    first=clampi(selection-shown+1,0,maxi(0,names.size()-shown))
    for i in range(rows.size()):
        rows[i].visible=i<shown
        if not rows[i].visible:continue
        rows[i].text=String(names[first+i])
        rows[i].position=Vector2(ROW_X,y+i*PITCH);rows[i].size.x=width-ROW_X-PAD
        var text_width=font.get_string_size(rows[i].text,HORIZONTAL_ALIGNMENT_LEFT,-1,FONT_SIZE).x
        rows[i].scale.x=minf(1.0,rows[i].size.x/maxf(1.0,text_width))
    y+=shown*PITCH
    if footer.visible:footer.position=Vector2(PAD,y+2);footer.size=Vector2(width-2*PAD,12);y+=14
    panel.size=Vector2(width,y+7)
    panel.position=Vector2(roundf(centre-width/2.0),maxf(top,roundf((screen.y-panel.size.y)/2.0)))
    tick.visible=shown>0
    if tick.visible:main._align_menu_tick(tick,rows[selection-first])

## Where a finger picks each row on screen: the box's whole width, PITCH tall.
func row_rects()->Array:
    var rects:=[]
    for row in rows:
        if row.visible:rects.append(Rect2(panel.global_position.x+4,row.global_position.y,panel.size.x-8,PITCH))
    return rects

func update(result:Dictionary)->void:
    if result.get("kind") in ["closed","trade_complete"]:
        if result.get("kind")=="closed" and is_instance_valid(game.pvp):game.pvp.closed()
        hide();phase="";interaction={}
        if result.get("kind")=="trade_complete":main._sync_pokedex_owned();main.world.play_source_sound("ball_switch1")
        return
    if not result.get("session") is Dictionary:return
    interaction=result.session
    show()
    if not interaction.get("accepted",false):phase="invite" if interaction.b==game.session.actor else "wait"
    elif interaction.kind=="BATTLE":
        phase="battle";hide();battle_accepted.emit(interaction);return
    elif interaction.get("offers",{}).size()==2:phase="confirm"
    elif interaction.get("offers",{}).has(game.session.actor):phase="wait"
    else:phase="trade"
    selection=0;refresh()

func activate()->void:
    if busy:return
    if phase=="beacons":game.beacons.travel(selection);return
    var operation="";var args:Dictionary={}
    match phase:
        "choose":operation="interact";args={"target":target,"action":"TRADE" if selection==0 else "BATTLE"}
        "invite":operation="answer";args={"accept":selection==0}
        "trade":operation="trade_offer";args={"slot":selection}
        "confirm":
            if selection==1:phase="trade";selection=0;refresh();return
            operation="trade_confirm" if selection==0 else "cancel"
    if operation.is_empty():return
    busy=true
    var result:Dictionary=await game.command(operation,args)
    busy=false
    if not result.get("ok",false):
        title.text=String(result.get("reason","COULD NOT COMPLETE ACTION")).replace("_"," ").to_upper();_layout(choices());return
    if result.get("waiting",false):phase="wait";refresh()

func handle(event:InputEvent)->void:
    if event.is_echo() or busy:return
    if event.is_action_pressed("cancel"):
        if phase in ["choose","beacons"]:hide();phase="";return
        busy=true;await game.command("cancel",{});busy=false;hide();phase="";return
    var count=choices().size()
    if count>0 and event.is_action_pressed("move_down"):selection=wrapi(selection+1,0,count);refresh()
    elif count>0 and event.is_action_pressed("move_up"):selection=wrapi(selection-1,0,count);refresh()
    elif event.is_action_pressed("confirm"):activate()
