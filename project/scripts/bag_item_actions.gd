extends Control
var main: Node
var item := ""
var choice := 0
var quantity := 1
var choosing_amount := false
var panel: Panel
var rows: Array[Label] = []
var tick: Label
var help: Label
var previous_cursor_visible := false
var online_request_pending:=false
func open(owner_main: Node, selected: String) -> void:
    main=owner_main;item=selected;z_index=300
    previous_cursor_visible=main.item_pocket_cursor.visible
    main.item_pocket_cursor.hide()
    panel=Panel.new();panel.position=Vector2(202,46);panel.size=Vector2(116,78);panel.add_theme_stylebox_override("panel",main._classic_dialogue_style());add_child(panel)
    for i in range(3):rows.append(main._source_ui_label(panel,"Row"+str(i),Vector2(25,9+20*i),Vector2(84,18),8,["USE","DROP","CANCEL"][i]))
    tick=main._source_ui_label(panel,"Tick",Vector2(12,9),Vector2(7,7),8,"")
    var footer:=Panel.new();footer.position=Vector2(2,126);footer.size=Vector2(316,52);footer.add_theme_stylebox_override("panel",main._classic_dialogue_style());add_child(footer)
    help=main._source_ui_label(footer,"Help",Vector2(12,7),Vector2(292,38),9,"");help.autowrap_mode=TextServer.AUTOWRAP_WORD_SMART
    refresh()
func refresh() -> void:
    if choosing_amount:
        rows[0].text="x%d"%quantity;rows[1].text="A: DROP";rows[2].text="B: BACK"
        tick.hide();help.text="%s\nChoose how many to drop."%item
    else:
        for i in range(3):rows[i].text=["USE","DROP","CANCEL"][i]
        tick.show();main._align_menu_tick(tick,rows[choice]);help.text=item+"\nChoose an action."
func close() -> void:
    main.item_pocket_cursor.visible=previous_cursor_visible
    main.bag_action_ui=null;queue_free()
func handle(event: InputEvent) -> void:
    if online_request_pending:return
    if event.is_action_pressed("cancel"):
        if choosing_amount:choosing_amount=false;refresh()
        else:close()
        return
    var up:=event.is_action_pressed("move_up");var down:=event.is_action_pressed("move_down")
    if choosing_amount:
        var delta:= (1 if up else -1 if down else 10 if event.is_action_pressed("move_right") else -10 if event.is_action_pressed("move_left") else 0)
        quantity=clampi(quantity+delta,1,maxi(1,int(main.inventory.get(item,0))))
        if event.is_action_pressed("confirm"):
            var cell:Vector2i=main.world._player_cell()+main.world._facing_cell()
            if is_instance_valid(main.coop_game) and main.coop_game.active:
                online_request_pending=true
                var dropped:bool=await main.coop_game.drop_item(item,quantity,cell)
                online_request_pending=false
                if not dropped:help.text="Could not drop that item here.";return
                main._close_game_menu();main._show_message("Dropped %s x%d."%[item,quantity]);close();return
            if int(main.inventory.get(item,0))<quantity or not main.world.dropped_items().drop(item,quantity,cell):
                help.text="Something is in the way!";return
            main.inventory[item]=int(main.inventory[item])-quantity
            if int(main.inventory[item])==0:main.inventory.erase(item)
            main._close_game_menu();main._show_message("Dropped %s x%d."%[item,quantity]);close();return
    else:
        if up:choice=posmod(choice-1,3)
        if down:choice=posmod(choice+1,3)
        if event.is_action_pressed("confirm"):
            if choice==0:close();main._use_overworld_item(item);return
            if choice==2:close();return
            choosing_amount=true;quantity=1
    refresh()
