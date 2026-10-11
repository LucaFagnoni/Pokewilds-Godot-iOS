extends Node
var main: Node
var cursor_cell:=Vector2.ZERO
var cursor: Control
var markers: Array[Control]=[]
var mini_markers: Array[TextureRect]=[]
var naming:=false
var selection := 0
var closed_msec := -1000
var selection_tick: TextureRect
var stick_direction := Vector2i.ZERO
var panel: Panel
var edit: LineEdit
var icon: Texture2D
var marker_index := 0
var marker_preview: TextureRect
var marker_label: Label
var marker_icons: Dictionary = {}
var save_button: Button
var cancel_button: Button
var delete_button: Button
var editing_existing := false
const Settings = preload("res://scripts/game_options.gd")
const MAP_SPEED := 80.0
const MARKER_FORMS := "ABCDEFGHIJKLMNOPQRSTUVWXYZ!?"
var outline: ShaderMaterial
var bounds:=Rect2i()
func configure(owner_main: Node) -> void:
    main=owner_main
    icon=main._party_record_frame({"species":"unown_a"})
    outline=ShaderMaterial.new()
    var shader:=Shader.new()
    shader.code="shader_type canvas_item; void fragment(){ vec4 p=texture(TEXTURE,UV); float a=0.0; for(int x=-1;x<=1;x++){for(int y=-1;y<=1;y++){a=max(a,texture(TEXTURE,UV+vec2(float(x),float(y))*TEXTURE_PIXEL_SIZE).a);}} COLOR=vec4(mix(vec3(1.0),p.rgb,p.a),max(p.a,a)*COLOR.a); }"
    outline.shader=shader
    panel=Panel.new();panel.position=Vector2(34,14);panel.size=Vector2(252,152);panel.z_index=500
    panel.add_theme_stylebox_override("panel",main._classic_dialogue_style());main.get_node("UI").add_child(panel)
    main._source_ui_label(panel,"Title",Vector2(12,10),Vector2(228,14),9,"NAME WAYPOINT")
    edit=LineEdit.new();edit.position=Vector2(24,30);edit.size=Vector2(216,26);edit.max_length=24
    edit.add_theme_font_override("font",main.JOHTO_FONT);edit.add_theme_font_size_override("font_size",9)
    var input_style:=StyleBoxFlat.new()
    input_style.bg_color=Color.WHITE;input_style.border_color=Color.BLACK
    input_style.set_border_width_all(1);input_style.set_content_margin_all(4)
    edit.add_theme_stylebox_override("normal",input_style)
    edit.add_theme_stylebox_override("focus",input_style)
    edit.add_theme_color_override("font_color",Color.BLACK)
    edit.add_theme_color_override("caret_color",Color.BLACK)
    edit.size=Vector2(216,26)
    panel.add_child(edit);edit.text_submitted.connect(func(_value:String):save_name())
    marker_preview=main._source_texture_rect(panel,"Marker",Vector2(126,76),Vector2(16,16),icon)
    marker_label=main._source_ui_label(panel,"MarkerName",Vector2(148,79),Vector2(88,12),8,"UNOWN A")
    _button("PREV",Vector2(12,68),Vector2(48,30),func():cycle_marker(-1))
    _button("NEXT",Vector2(66,68),Vector2(48,30),func():cycle_marker(1))
    save_button=_button("A: SAVE",Vector2(12,114),Vector2(108,30),save_name)
    cancel_button=_button("B: BACK",Vector2(132,114),Vector2(108,30),cancel_name)
    delete_button=_button("DELETE MARKER",Vector2(72,95),Vector2(156,18),delete_marker)
    delete_button.hide()
    selection_tick=main._source_texture_rect(panel,"Selection",Vector2(12,39),Vector2(5,7),main.source_command_cursor.texture)
    panel.hide()
func context_key() -> String:
    return "%d,%d|%s|%s" % [main.current_world_grid.x,main.current_world_grid.y,String(main.world.active_area_id),str(main.world.active_built_house_door) if main.world.active_area_id!="OVERWORLD" else ""]
func records() -> Array:
    var value=main.map_waypoints.get(context_key(),[])
    return value if value is Array else []
func setup_map() -> void:
    bounds=main.world.get_map_bounds()
    cursor_cell=Vector2(main.world.player.position/16.0).floor()
    cursor=Control.new();cursor.name="WaypointCursor";cursor.size=Vector2(9,9);cursor.z_index=35
    main.map_view_node.add_child(cursor)
    for spec in [Rect2(0,0,3,1),Rect2(0,0,1,3),Rect2(6,0,3,1),Rect2(8,0,1,3),Rect2(0,8,3,1),Rect2(0,6,1,3),Rect2(6,8,3,1),Rect2(8,6,1,3)]:
        var line=ColorRect.new();line.position=spec.position;line.size=spec.size;line.color=Color.RED;line.mouse_filter=Control.MOUSE_FILTER_IGNORE;cursor.add_child(line)
    rebuild_markers();update_markers()
func rebuild_markers() -> void:
    for node in markers:
        if is_instance_valid(node):node.queue_free()
    markers.clear()
    if not is_instance_valid(main.map_view_node) or not Settings.enabled("map_waypoint"):return
    for record in records():
        if not record is Dictionary or not record.has("x") or not record.has("y"):continue
        var group=Control.new();group.z_index=25;group.set_meta("cell",Vector2(float(record.x),float(record.y)));main.map_view_node.add_child(group);markers.append(group)
        var marker:TextureRect=main._source_texture_rect(group,"Icon",Vector2(-5,-6),Vector2(10,12),marker_texture(String(record.get("marker","A"))))
        marker.material=outline
        var title=main._source_ui_label(group,"Title",Vector2(6,-4),Vector2(100,10),7,String(record.get("title","WAYPOINT")))
        title.add_theme_font_override("font",preload("res://assets/source_text_font_white.fnt"));title.add_theme_color_override("font_color",Color.WHITE);title.add_theme_color_override("font_outline_color",Color.BLACK);title.add_theme_constant_override("outline_size",2)
func update_markers() -> void:
    if not is_instance_valid(main.map_view_node):return
    var zoom:float=maxf(main.map_zoom,0.01)
    for group in markers:
        if not is_instance_valid(group):continue
        group.scale=Vector2.ONE/zoom
        group.position=(Vector2(group.get_meta("cell"))+Vector2(0.5,0.5)-Vector2(bounds.position))*main.SOURCE_MAP_TILE_PIXELS
    if is_instance_valid(cursor):
        cursor.scale=Vector2.ONE/zoom
        cursor.position=(cursor_cell+Vector2(0.5,0.5)-Vector2(bounds.position))*main.SOURCE_MAP_TILE_PIXELS-cursor.size/(zoom*2.0)
func move_cursor(delta: float) -> void:
    if naming or not is_instance_valid(cursor):return
    var pan := Input.get_vector("map_pan_left", "map_pan_right", "map_pan_up", "map_pan_down").normalized()
    if pan != Vector2.ZERO:
        main.map_pan -= pan * MAP_SPEED * delta
        main._update_map_transform()
    var movement := Input.get_vector("move_left", "move_right", "move_up", "move_down")
    if movement.length_squared()<0.01:return
    cursor_cell+=movement*MAP_SPEED*delta/(maxf(main.map_zoom,0.01)*main.SOURCE_MAP_TILE_PIXELS)
    cursor_cell=cursor_cell.clamp(Vector2(bounds.position),Vector2(bounds.end-Vector2i.ONE))
    update_markers()
    var screen:Vector2=main.map_view_node.position+(cursor_cell+Vector2(0.5,0.5)-Vector2(bounds.position))*main.SOURCE_MAP_TILE_PIXELS*main.map_zoom
    var half:Vector2=main.MAP_VIEWPORT_SIZE*0.5-Vector2(14,14)
    var clamped:Vector2=screen.clamp(main.MAP_VIEWPORT_CENTER-half,main.MAP_VIEWPORT_CENTER+half)
    main.map_pan+=clamped-screen;main._update_map_transform()
func begin_name() -> void:
    if not is_instance_valid(cursor) or not Settings.enabled("map_waypoint"):return
    main.world.set_gameplay_enabled(false)
    naming=true;selection=0;stick_direction=Vector2i.ZERO;edit.text="";marker_index=0
    editing_existing=false
    for record in records():
        if record is Dictionary and Vector2i(int(record.get("x",-1)),int(record.get("y",-1)))==Vector2i(cursor_cell.floor()):
            edit.text=String(record.get("title",""));marker_index=maxi(0,MARKER_FORMS.find(String(record.get("marker","A"))))
            editing_existing=true
            break
    delete_button.visible=editing_existing
    cycle_marker(0)
    panel.add_theme_stylebox_override("panel",main._classic_dialogue_style());panel.show();_refresh_selection();edit.grab_focus()
    if DisplayServer.has_feature(DisplayServer.FEATURE_VIRTUAL_KEYBOARD):DisplayServer.virtual_keyboard_show(edit.text)
func cancel_name() -> void:
    closed_msec=Time.get_ticks_msec()
    naming=false;edit.release_focus();panel.hide()
    main.world.set_gameplay_enabled(false)
    if DisplayServer.has_feature(DisplayServer.FEATURE_VIRTUAL_KEYBOARD):DisplayServer.virtual_keyboard_hide()
func save_name() -> void:
    if not naming:return
    var title:=edit.text.strip_edges()
    if title.is_empty():title="WAYPOINT"
    var items:=records().duplicate(true)
    var cell:=Vector2i(cursor_cell.floor())
    var entry={"x":cell.x,"y":cell.y,"title":title,"marker":MARKER_FORMS[marker_index]}
    var replaced:=false
    for i in range(items.size()):
        if int(items[i].x)==cell.x and int(items[i].y)==cell.y:items[i]=entry;replaced=true;break
    if not replaced:items.append(entry)
    main.map_waypoints[context_key()]=items
    cancel_name();rebuild_markers();update_markers()
func delete_marker() -> void:
    if not naming or not editing_existing:return
    var cell:=Vector2i(cursor_cell.floor())
    var items:=records().duplicate(true)
    for i in range(items.size()-1,-1,-1):
        if int(items[i].get("x",-1))==cell.x and int(items[i].get("y",-1))==cell.y:items.remove_at(i)
    main.map_waypoints[context_key()]=items
    cancel_name();rebuild_markers();update_markers()
func update_minimap(angle: float) -> void:
    var items:=records() if Settings.enabled("map_waypoint") else []
    while mini_markers.size()<items.size():
        var node:TextureRect=main._source_texture_rect(main.m3924_minimap_root,"Waypoint",Vector2.ZERO,Vector2(5,6),icon)
        node.material=outline;node.z_index=3;mini_markers.append(node)
    for node in mini_markers:node.hide()
    var origin:Vector2=main.m3924_minimap_map.get_meta("view_origin",Vector2.ZERO)
    var window:Vector2=main.m3924_minimap_map.get_meta("window_cells",Vector2(24,24))
    for i in range(items.size()):
        var record=items[i]
        if not record is Dictionary or not record.has("x") or not record.has("y"):continue
        var offset:Vector2=((Vector2(float(record.x)+0.5,float(record.y)+0.5)-origin)/window-Vector2(0.5,0.5))*main.M3924_MINIMAP_MAP_RADIUS*2.0
        if offset.length()>main.M3924_MINIMAP_MAP_RADIUS-3.0:continue
        mini_markers[i].texture=marker_texture(String(record.get("marker","A")))
        mini_markers[i].position=(main.M3924_MINIMAP_SIZE*0.5+offset.rotated(angle)-mini_markers[i].size*0.5).round();mini_markers[i].show()

func marker_texture(form: String) -> Texture2D:
    if form.length()!=1 or not MARKER_FORMS.contains(form):form="A"
    if not marker_icons.has(form):
        var species: String = "unown_qmark" if form=="?" else "unown_"+form.to_lower()
        marker_icons[form]=main._party_record_frame({"species":species})
    return marker_icons[form]

func cycle_marker(direction: int) -> void:
    marker_index=wrapi(marker_index+direction,0,MARKER_FORMS.length())
    marker_preview.texture=marker_texture(MARKER_FORMS[marker_index])
    marker_label.text="UNOWN "+MARKER_FORMS[marker_index]

func _button(text: String, at: Vector2, dimensions: Vector2, callback: Callable) -> Button:
    var button:=Button.new()
    button.text=text;button.position=at;button.size=dimensions
    button.focus_mode=Control.FOCUS_NONE
    button.add_theme_font_override("font",main.JOHTO_FONT)
    button.add_theme_font_size_override("font_size",8)
    button.add_theme_color_override("font_color",Color.BLACK)
    button.add_theme_color_override("font_hover_color",Color.BLACK)
    button.add_theme_color_override("font_pressed_color",Color.BLACK)
    button.flat=true
    var style:=StyleBoxEmpty.new()
    for state in ["normal","hover","pressed","focus"]:button.add_theme_stylebox_override(state,style)
    button.size=dimensions
    button.pressed.connect(callback);panel.add_child(button)
    return button

func _refresh_selection() -> void:
    selection_tick.position = [Vector2(12,39),Vector2(2,79),Vector2(4,125),Vector2(124,125),Vector2(99,105)][selection]

func _navigate(direction: Vector2i) -> void:
    edit.release_focus()
    if direction.y != 0:
        var order: Array=[0,1,4,2,3] if editing_existing else [0,1,2,3]
        selection=order[wrapi(order.find(selection)+direction.y,0,order.size())]
    elif selection == 1: cycle_marker(direction.x)
    elif selection in [2,3]: selection=3 if direction.x>0 else 2
    _refresh_selection()

func handle_input(event: InputEvent) -> void:
    if not naming or event.is_echo():return
    if event is InputEventKey:
        if event.pressed and event.keycode in [KEY_ESCAPE,KEY_BACK]:
            cancel_name();get_viewport().set_input_as_handled()
        elif event.pressed and event.keycode in [KEY_ENTER,KEY_KP_ENTER]:
            save_name();get_viewport().set_input_as_handled()
        return
    if event is InputEventJoypadMotion:
        if event.axis in [JOY_AXIS_LEFT_X,JOY_AXIS_LEFT_Y]:
            var direction:=Vector2i.ZERO
            if absf(event.axis_value)>0.55:
                direction=Vector2i(int(signf(event.axis_value)),0) if event.axis==JOY_AXIS_LEFT_X else Vector2i(0,int(signf(event.axis_value)))
            if direction!=Vector2i.ZERO:_navigate(direction)
            stick_direction=direction
        get_viewport().set_input_as_handled()
    elif event is InputEventJoypadButton or event is InputEventAction:
        if event.is_action_pressed("cancel"):cancel_name()
        elif event.is_action_pressed("move_up"):_navigate(Vector2i.UP)
        elif event.is_action_pressed("move_down"):_navigate(Vector2i.DOWN)
        elif event.is_action_pressed("move_left"):_navigate(Vector2i.LEFT)
        elif event.is_action_pressed("move_right"):_navigate(Vector2i.RIGHT)
        elif event.is_action_pressed("shoulder_left"):cycle_marker(-1)
        elif event.is_action_pressed("shoulder_right"):cycle_marker(1)
        elif event.is_action_pressed("confirm"):
            if selection==3:cancel_name()
            elif selection==4:delete_marker()
            elif selection==1:cycle_marker(1)
            else:save_name()
        get_viewport().set_input_as_handled()
    elif event is InputEventScreenTouch or event is InputEventMouseButton:
        if event is InputEventMouseButton and event.button_index!=MOUSE_BUTTON_LEFT:return
        if panel.get_global_rect().has_point(event.position):
            for child in panel.get_children():
                if child is Button and child.get_global_rect().has_point(event.position):
                    if event.pressed:child.pressed.emit()
                    get_viewport().set_input_as_handled()
                    return

