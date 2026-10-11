extends Control
## Player-to-player choices use the same menu frame and font as the rest of the game.
signal battle_accepted(session:Dictionary)
var main:Node
var game:Node
var target:=""
var phase:=""
var selection:=0
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
    panel=Panel.new();panel.position=Vector2(34,12);panel.size=Vector2(252,156);add_child(panel)
    title=main._source_ui_label(panel,"Title",Vector2(14,9),Vector2(224,24),9,"")
    title.autowrap_mode=TextServer.AUTOWRAP_WORD_SMART
    for i in range(6):
        var label:Label=main._source_ui_label(panel,"Choice%d"%i,Vector2(26,36+i*15),Vector2(210,15),8,"")
        label.mouse_filter=Control.MOUSE_FILTER_STOP
        label.gui_input.connect(func(event):
            if event is InputEventMouseButton and event.pressed and event.button_index==MOUSE_BUTTON_LEFT:
                selection=maxi(0,selection-rows.size()+1)+i;activate();accept_event())
        rows.append(label)
    tick=main._source_texture_rect(panel,"Tick",Vector2(14,36),Vector2(5,7),main.source_command_cursor.texture)
    footer=main._source_ui_label(panel,"Footer",Vector2(14,133),Vector2(224,15),7,"A: SELECT   B: CANCEL")
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
    title.text={"choose":"CHOOSE AN ACTION","invite":"%s REQUEST"%String(interaction.get("kind","")),
        "trade":"CHOOSE YOUR POKEMON","wait":"WAITING FOR THE OTHER PLAYER...","confirm":"CONFIRM THIS TRADE?"}.get(phase,"")
    if phase=="beacons":title.text="SAVING BEACONS..." if game.beacons.busy else ("NO BEACONS" if names.is_empty() else "CHOOSE A BEACON")
    # Compact action/wait panels retain the same font, frame and tick helper.
    var compact=phase=="choose"
    var waiting=phase=="wait"
    panel.size=Vector2(96,54) if compact else Vector2(220,64) if waiting else Vector2(252,156)
    panel.position=(Vector2(320,180)-panel.size)*0.5
    title.visible=not compact
    title.size=Vector2(panel.size.x-28,28 if waiting else 24)
    footer.visible=not compact
    footer.text="B: CANCEL" if waiting else "A: SELECT   B: CANCEL"
    footer.position=Vector2(14,panel.size.y-23)
    footer.size.x=panel.size.x-28
    for i in range(rows.size()):
        rows[i].position=Vector2(26,(12 if compact else 36)+i*(18 if compact else 15))
        rows[i].size.x=panel.size.x-40
    var first=maxi(0,selection-rows.size()+1)
    if phase=="confirm":
        var offers:Dictionary=interaction.get("offers",{})
        var other=String(interaction.b) if interaction.get("a")==game.session.actor else String(interaction.get("a",""))
        if offers.has(other):title.text="RECEIVE "+main.PokemonState.display_name(offers[other].pokemon)+"?"
    for i in range(rows.size()):
        rows[i].visible=i+first<names.size()
        if i+first<names.size():
            rows[i].text=String(names[i+first])
            var width=rows[i].get_theme_font("font").get_string_size(rows[i].text,HORIZONTAL_ALIGNMENT_LEFT,-1,8).x
            rows[i].scale.x=minf(1.0,rows[i].size.x/maxf(1.0,width))
    tick.visible=not names.is_empty()
    if tick.visible:main._align_menu_tick(tick,rows[selection-first])

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
        title.text=String(result.get("reason","COULD NOT COMPLETE ACTION")).replace("_"," ").to_upper();return
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
