extends Control
## Attack.java's procedural presentation. BattleEngine retains the approved
## working move rules; this node owns only sound/visual state and cleanup.
var host: Node
var key := ""
var player_attacks := false
var sheet: Texture2D
var region := Rect2()
var draw_position := Vector2.ZERO
var second_region := Rect2()
var second_position := Vector2.ZERO
var screen_effect: ColorRect
var capture: TextureRect
var source_data: Dictionary
var frame := -1
var original_panel_position := Vector2.ZERO
var original_hud: Dictionary = {}
var grip_position := Vector2.ZERO
var completed := false
var palette_effect: RefCounted

func setup(owner_node: Node, move_name: String, player_side: bool) -> void:
    host=owner_node;key=move_name;player_attacks=player_side
    mouse_filter=Control.MOUSE_FILTER_IGNORE
    set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    texture_filter=CanvasItem.TEXTURE_FILTER_NEAREST
    original_panel_position=host.battle_panel.position
    z_index=10
    source_data=JSON.parse_string(FileAccess.get_file_as_string("res://data/source_procedural_attacks.json"))
    if key=="SHADOW_CLAW":sheet=load("res://assets/source_bosses/enemy_slash_sheet1.png")
    elif key=="LICK":sheet=load("res://assets/source_bosses/enemy_lick_sheet1.png")
    elif key=="CRUSH_GRIP":
        sheet=load("res://assets/source_bosses/crush_grip1.png")
        grip_position=Vector2(86,82) if player_attacks else Vector2(54,62)
        for child in host.source_single_hud.get_children():
            if String(child.name).begins_with("Player" if player_attacks else "Enemy"):
                original_hud[child]=child.visible
                child.hide()
    screen_effect=ColorRect.new()
    screen_effect.mouse_filter=Control.MOUSE_FILTER_IGNORE
    screen_effect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    var shader := Shader.new()
    shader.code="""shader_type canvas_item;
uniform sampler2D screen_texture:hint_screen_texture,repeat_disable,filter_nearest;
uniform float brightness=0.;uniform bool inverse=false;
void fragment(){vec4 c=texture(screen_texture,SCREEN_UV);c.rgb=inverse ? vec3(1.)-c.rgb : c.rgb+vec3(brightness);COLOR=c;}"""
    var mat := ShaderMaterial.new();mat.shader=shader
    screen_effect.material=mat
    add_child(screen_effect)
    screen_effect.hide()
    capture=TextureRect.new()
    capture.mouse_filter=Control.MOUSE_FILTER_IGNORE
    capture.expand_mode=TextureRect.EXPAND_IGNORE_SIZE
    capture.stretch_mode=TextureRect.STRETCH_SCALE
    capture.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    var row_shader := Shader.new()
    row_shader.code="""shader_type canvas_item;
uniform float shifts[16];
void fragment(){vec2 q=UV;int row=int(floor((1.-q.y)*144.));if(row<141)q.x-=shifts[row%16]/160.;COLOR=texture(TEXTURE,q);} """
    var row_mat := ShaderMaterial.new();row_mat.shader=row_shader;capture.material=row_mat
    add_child(capture);capture.hide()

func _phase(tick: int, durations: Array) -> int:
    var elapsed := 0
    for i in range(durations.size()):
        elapsed+=int(durations[i])
        if tick<elapsed:return i
    return durations.size()

func _shake(tick: int) -> void:
    var x := 2 if tick>=9 and tick<14 else 1 if tick>=23 and tick<27 else 0
    host.battle_panel.position=original_panel_position+Vector2(x,0)

func apply_tick(tick: int) -> void:
    frame=tick
    region=Rect2();second_region=Rect2()
    if key=="SHADOW_CLAW":
        # repeat>0 in the Java class means every listed repeat lasts +1 tick.
        var phase := _phase(tick,[20,40,7,7,7,7,6])
        if phase>=2 and phase<=5:
            region=Rect2((phase-2)*48,0,48,48)
            draw_position=Vector2(16,56) # Source bottom-origin (16,40).
        screen_effect.visible=tick>=20 and tick<94
        screen_effect.material.set_shader_parameter("inverse",true)
        if tick==60:host._play_source_battle_sound("slash1.ogg")
        if tick>=94:_shake(tick-94)
    elif key=="LICK":
        var phase := _phase(tick,[19,13,6,6,7,6,6,7,23])
        if phase>=1 and phase<=7:
            region=Rect2((phase-1)*160,0,160,144);draw_position=Vector2.ZERO
        if tick==0:host._play_source_battle_sound("lick1.ogg")
        if tick==70:host._play_source_battle_sound("hit_normal1.ogg")
        if tick>=93:_shake(tick-93)
    elif key in ["PSYCHIC","NIGHT_SHADE"]:
        var levels: Array=source_data.psychic_levels
        if tick==0:host._play_source_battle_sound("night_shade1.ogg" if key=="NIGHT_SHADE" else "psychic1.ogg")
        screen_effect.visible=tick<levels.size()
        if tick<levels.size():screen_effect.material.set_shader_parameter("brightness",float(levels[tick]))
        else:
            if capture.texture==null:
                await RenderingServer.frame_post_draw
                if not is_inside_tree():return
                capture.texture=ImageTexture.create_from_image(get_viewport().get_texture().get_image())
            var row_index := tick-levels.size()
            if row_index<source_data.psychic_rows.size():
                capture.material.set_shader_parameter("shifts",PackedFloat32Array(source_data.psychic_rows[row_index]))
                capture.show()
    elif key=="CRUSH_GRIP":
        var t := tick-40
        var shake := 0
        if t>=-20 and t< -10:
            grip_position+=Vector2(2,1)*(1 if player_attacks else -1)
        if t>=20 and t<166:shake=2 if t%2==0 else -2
        host.battle_panel.position=original_panel_position+Vector2(shake,0)
        region=Rect2(192 if t<20 else 160,0,32,32)
        draw_position=Vector2(grip_position.x-shake,144-grip_position.y-32)
        for interval in [[90,98,-8,8],[106,114,8,8],[122,130,-8,-8],[138,146,8,-8]]:
            if t>=interval[0] and t<interval[1]:
                second_region=Rect2(64,0,32,32)
                second_position=draw_position+Vector2(interval[2],-interval[3])
        # Crush Grip uses SpriteProxy's palette swap, not RGB inversion.
        if t==206:
            palette_effect=preload("res://scripts/source_battle_effects.gd").new()
            palette_effect.begin(host,"crush_grip_player_gsc" if player_attacks else "crush_grip_enemy_gsc")
            palette_effect.apply({"inverse_colors":true},1)
        if t== -20:host._play_source_battle_feedback_audio("rolling_kick_player_gsc")
        if t in [20,206]:host._play_source_battle_feedback_audio("rock_throw_player_gsc")
        if t==70:host.battle_audio.stop()
        if t in [90,106,122,138]:host._play_source_battle_sound("ap1.ogg")
    queue_redraw()

func play() -> void:
    var count: int = 140 if key=="SHADOW_CLAW" else 139 if key=="LICK" else 300 if key=="CRUSH_GRIP" else source_data.psychic_levels.size()+source_data.psychic_rows.size()
    var start := preload("res://scripts/game_clock.gd").ticks_usec()
    for tick in range(count):
        while preload("res://scripts/game_clock.gd").ticks_usec()-start<int(tick*1000000.0/60.0):await get_tree().process_frame
        await apply_tick(tick)
    completed=true
    cleanup()

func cleanup() -> void:
    if not is_instance_valid(host):return
    if palette_effect!=null:
        palette_effect.finish()
        palette_effect=null
    host.battle_panel.position=original_panel_position
    for node in original_hud:
        if is_instance_valid(node):node.visible=original_hud[node]
    if is_instance_valid(screen_effect):screen_effect.hide()
    if is_instance_valid(capture):capture.hide()
    region=Rect2();second_region=Rect2();queue_redraw()

func _draw() -> void:
    if sheet==null:return
    draw_set_transform(Vector2.ZERO,0,size/Vector2(160,144))
    if region.has_area():draw_texture_rect_region(sheet,Rect2(draw_position,region.size),region)
    if second_region.has_area():draw_texture_rect_region(sheet,Rect2(second_position,second_region.size),second_region)
    draw_set_transform(Vector2.ZERO)

func _exit_tree() -> void:cleanup()
