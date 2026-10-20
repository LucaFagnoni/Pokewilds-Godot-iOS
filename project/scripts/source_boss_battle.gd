extends Control
const TexturePixels = preload("res://scripts/texture_pixels.gd")
## Original RegigigasBattle / SpecialBattleMegaGengar, 60 source ticks/sec.
signal special_damage_due
signal sendout_due
var intro_frame := -1
var ground_palettes: Dictionary = {}
var host: Node
var kind := ""
var body: Texture2D
var upper: TextureRect
var lower: TextureRect
var ground: Texture2D
var backdrop: Texture2D
var front: Control
var shade: ColorRect
var accumulator := 0.0
var timer := 0.0
var wave_timer := PI * 8.0
var wave_timer2 := 0.0
var alpha_timer := 0.0
var wave_sound_timer := 0
var breathing_timer := 300
var breathing_offset := 0
var overlay_offset := 0
var breathe := false
var can_move := true
var reveal_ground := false
var fade_alpha := 1.0
var shockwave_pending := false
var shock_sound_delay := -1
var special_tick_index := -1
var special_hit_count := 0
var enemy_position := Vector2.ZERO
var player_position := Vector2.ZERO
var palette_layers: Array[Dictionary] = []
var gengar_frames: Dictionary = {}
var original_z: Dictionary = {}
var palette_stage := 0
var wave_audio: AudioStreamPlayer
var appear_audio: AudioStreamPlayer
var original_hud_textures: Dictionary = {}
var original_hud_colors: Dictionary = {}
var original_hud_materials: Dictionary = {}
var original_gender_material: Material
var inverse_gender: TextureRect

func setup(owner_node: Node, event_kind: String, shiny: bool) -> void:
    host=owner_node
    kind=event_kind
    mouse_filter=Control.MOUSE_FILTER_IGNORE
    texture_filter=CanvasItem.TEXTURE_FILTER_NEAREST
    set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    enemy_position=host.enemy_sprite.position
    player_position=host.player_battle_sprite.position
    var suffix := "_shiny" if shiny else ""
    if kind=="regigigas":
        body=load("res://assets/source_bosses/regigigas_lower%s.png" % suffix)
        upper=_make_layer(load("res://assets/source_bosses/regigigas_upper%s.png" % suffix))
        ground=load("res://assets/source_bosses/gigas_ground4.png")
        _prepare_ground_palettes()
        backdrop=load("res://assets/source_exact/battle/intro_frame6.png")
    else:
        var base_image := TexturePixels.of(load("res://assets/source_bosses/mgengar_base1.png")) as Image
        var over_image := TexturePixels.of(load("res://assets/source_bosses/mgengar_over1.png")) as Image
        for base_offset in [0,-1]:
            for over_offset in [0,-1]:
                var composite := Image.create(64 if shiny else 56,64 if shiny else 56,false,Image.FORMAT_RGBA8)
                if shiny:
                    var shiny_front := TexturePixels.of(preload("res://assets/community_mega_gengar/battle/front-shiny.png"))
                    composite.blend_rect(shiny_front,Rect2i(0,0,64,64),Vector2i(0,base_offset))
                else:
                    composite.blend_rect(base_image,Rect2i(0,0,56,56),Vector2i(0,base_offset))
                    composite.blend_rect(over_image,Rect2i(0,0,56,56),Vector2i(0,over_offset))
                gengar_frames[Vector2i(base_offset,over_offset)]=ImageTexture.create_from_image(composite)
        body=gengar_frames[Vector2i.ZERO]
        backdrop=load("res://assets/source_exact/battle/battle_bg3.png")
    host.enemy_sprite.texture=body
    front=Control.new()
    front.mouse_filter=Control.MOUSE_FILTER_IGNORE
    front.z_index=2
    front.draw.connect(_draw_front)
    add_child(front)
    shade=ColorRect.new()
    shade.mouse_filter=Control.MOUSE_FILTER_IGNORE
    shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    shade.z_index=4
    var shader := Shader.new()
    shader.code="""shader_type canvas_item;
uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_nearest;
uniform float level=0.0;
void fragment(){vec4 c=texture(screen_texture,SCREEN_UV);
if (!(c.r>=.9 && c.g>=.9 && c.b>=.9)) c.rgb-=vec3(level); COLOR=c;}"""
    var mat := ShaderMaterial.new()
    mat.shader=shader
    shade.material=mat
    add_child(shade)
    for node in host.battle_panel.get_children():
        if node==self or not node is CanvasItem or node.name in ["Background","EnemySprite","WeatherOverlay","Transition"]:continue
        original_z[node]=node.z_index
        node.z_index=maxi(3,node.z_index)
    if kind=="regigigas":
        # DrawFriendlyHealth selects the inverse HUD over this dark battlefield.
        # Keep the approved HUD geometry and use its matching source GSC assets.
        for entry in [["PlayerFrame","friendly_healthbar1_inverse.png"],["PlayerLevelChar","friendly_levelchar_inverse.png"]]:
            var node: TextureRect=host.source_single_hud.get_node(entry[0])
            original_hud_textures[node]=node.texture
            node.texture=load("res://assets/source_exact/battle/gsc/"+entry[1])
        for node in host.source_single_hud.get_children():
            if node is Label and String(node.name).begins_with("Player"):
                original_hud_colors[node]=node.get_theme_color("font_color")
                node.add_theme_color_override("font_color",Color.WHITE)
        inverse_gender=host.source_single_hud.get_node("PlayerGender")
        original_gender_material=inverse_gender.material
        var gender_shader := Shader.new()
        gender_shader.code="shader_type canvas_item; void fragment(){vec4 c=texture(TEXTURE,UV);c.rgb=vec3(1.)-c.rgb;COLOR=c;}"
        var gender_material := ShaderMaterial.new()
        gender_material.shader=gender_shader
        inverse_gender.material=gender_material
        for node in original_hud_colors:
            original_hud_materials[node]=node.material
            node.material=gender_material
        wave_audio=AudioStreamPlayer.new()
        wave_audio.stream=load("res://assets/source_audio/sounds/ap3.ogg")
        AudioBalance.apply(wave_audio)
        add_child(wave_audio)
        appear_audio=AudioStreamPlayer.new()
        appear_audio.stream=load("res://assets/source_audio/sounds/boss_appear1.ogg")
        AudioBalance.apply(appear_audio)
        add_child(appear_audio)
        for actor in [host.enemy_sprite,host.player_battle_sprite,upper]:
            var palette_shader := Shader.new()
            palette_shader.code=preload("res://scripts/source_battle_effects.gd").PALETTE_CODE
            var palette_material := ShaderMaterial.new()
            palette_material.shader=palette_shader
            var colors: Array[Color] = preload("res://scripts/source_battle_effects.gd").palette(actor.texture)
            palette_material.set_shader_parameter("light_color",colors[0])
            palette_material.set_shader_parameter("dark_color",colors[1])
            palette_layers.append({"node":actor,"old":actor.material,"material":palette_material})
        upper.use_parent_material=false

func set_palette_stage(stage: int) -> void:
    palette_stage=stage
    if ground_palettes.has(stage):ground=ground_palettes[stage]
    for entry in palette_layers:
        if not is_instance_valid(entry.node):continue
        var colors: Array[Color] = preload("res://scripts/source_battle_effects.gd").palette(entry.node.texture)
        entry.material.set_shader_parameter("light_color",colors[0])
        entry.material.set_shader_parameter("dark_color",colors[1])
        entry.material.set_shader_parameter("effect",stage)
        entry.node.material=entry.material if stage>0 else entry.old

func _prepare_ground_palettes() -> void:
    # SpriteProxy creates these textures before row tint/alpha is applied.
    ground_palettes[0]=ground
    var original := TexturePixels.of(ground)
    var colors := preload("res://scripts/source_battle_effects.gd").palette(ground)
    for stage in [2,3,4]:
        var output := original.duplicate() as Image
        for y in range(output.get_height()):
            for x in range(output.get_width()):
                var c := original.get_pixel(x,y)
                if c.a==0.0:continue
                if c==colors[1]:c=Color.BLACK
                elif c==colors[0] and stage>=3:c=Color.BLACK if stage==4 else colors[1]
                output.set_pixel(x,y,c)
        ground_palettes[stage]=ImageTexture.create_from_image(output)

func _make_layer(texture: Texture2D) -> TextureRect:
    var layer := TextureRect.new()
    layer.texture=texture
    layer.expand_mode=TextureRect.EXPAND_IGNORE_SIZE
    layer.stretch_mode=TextureRect.STRETCH_KEEP_ASPECT_CENTERED
    layer.mouse_filter=Control.MOUSE_FILTER_IGNORE
    layer.use_parent_material=true
    host.enemy_sprite.add_child(layer)
    layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    return layer

func set_level(value: float) -> void:
    (shade.material as ShaderMaterial).set_shader_parameter("level",value)
    shade.visible=value!=0.0

func _process(delta: float) -> void:
    if host==null:return
    if not preload("res://scripts/game_options.gd").enabled("battle_animations"): return
    accumulator+=delta*60.0
    while accumulator>=1.0:
        accumulator-=1.0
        tick()
    var pixel_scale := minf(host.enemy_sprite.size.x/56.0,host.enemy_sprite.size.y/56.0)
    if is_instance_valid(upper):upper.position.y=-breathing_offset*pixel_scale
    if is_instance_valid(upper):upper.use_parent_material=host.source_effect_playing
    if kind=="mega_gengar":
        var next_body: Texture2D = gengar_frames[Vector2i(breathing_offset,overlay_offset)]
        body=next_body
        if not host.source_effect_playing:host.enemy_sprite.texture=body
    queue_redraw()
    front.queue_redraw()

func tick() -> void:
    if breathe:
        breathing_timer-=1
        if breathing_timer==149:breathing_offset=-1
        elif breathing_timer<=0:
            breathing_timer=300
            breathing_offset=0
        if kind=="mega_gengar":
            if breathing_timer==74:overlay_offset=-1
            elif breathing_timer==274:overlay_offset=0
    if kind!="regigigas":return
    if reveal_ground:fade_alpha-=0.05
    if shockwave_pending:
        shockwave_pending=false
        wave_timer=0.0
        wave_sound_timer=0
        shock_sound_delay=0 if fade_alpha>0.0 else 30
    if shock_sound_delay==0:appear_audio.play()
    if shock_sound_delay>=0:shock_sound_delay-=1
    if can_move:
        timer+=PI/128.0
        if timer>=TAU:timer=0.0
    if wave_timer<PI*8.0:wave_timer+=PI/24.0
    if alpha_timer>PI*4.0 and wave_timer>PI and wave_timer<PI*4.0:
        wave_sound_timer+=1
        if wave_sound_timer%5==0:wave_audio.play()
    wave_timer2+=PI/64.0
    if wave_timer2>PI*4.0:wave_timer2=-TAU
    if reveal_ground and alpha_timer<PI*8.0:alpha_timer+=PI/64.0

func special_tick(frame: int) -> void:
    special_tick_index=frame
    if frame==0:
        can_move=false
        breathe=false
        breathing_offset=0
    elif frame==96:shockwave_pending=true
    elif frame==116:
        breathing_offset=-17
        host._play_source_battle_feedback("NEUTRAL_EFFECTIVE",false,{})
    elif frame==160:breathe=true
    elif frame==170:can_move=true
    elif frame==181:
        special_hit_count+=1
        special_damage_due.emit()
    if frame==0:set_palette_stage(4)
    elif frame==160:set_palette_stage(3)
    elif frame==180:set_palette_stage(2)
    elif frame==200:set_palette_stage(0)
    if frame>=170 and (frame<182 or (frame<192 and frame%2==0)):
        breathing_offset+=1

func play_special() -> void:
    if not preload("res://scripts/game_options.gd").enabled("battle_animations"):
        special_hit_count += 1
        special_damage_due.emit()
        return
    var start := preload("res://scripts/game_clock.gd").ticks_usec()
    for frame in range(201):
        while preload("res://scripts/game_clock.gd").ticks_usec()-start<int(frame*1000000.0/60.0):
            await get_tree().process_frame
        special_tick(frame)
    set_level(0.0)

func play_intro() -> void:
    if not preload("res://scripts/game_options.gd").enabled("battle_animations"):
        host._play_pokemon_cry(host.battle_enemy)
        if kind == "regigigas":
            await host._type_battle_text("The battlefield quakes under REGIGIGAS' presence!")
            reveal_ground = true
        else:
            await host._type_battle_text("MEGA GENGAR attacked!")
            sendout_due.emit()
        queue_redraw()
        front.queue_redraw()
        return
    var total := 160 if kind=="regigigas" else 390
    var start := preload("res://scripts/game_clock.gd").ticks_usec()
    if kind=="regigigas":set_palette_stage(4)
    else:set_level(0.8)
    for frame in range(total):
        while preload("res://scripts/game_clock.gd").ticks_usec()-start<int(frame*1000000.0/60.0):
            await get_tree().process_frame
        intro_frame=frame
        var slide := mini(144,frame)
        host.enemy_sprite.position=enemy_position+Vector2(slide-144,0)
        host.player_battle_sprite.position=player_position+Vector2(144-slide,0)
        if kind=="mega_gengar":
            var local_frame := frame-144
            var levels := {20:0.7,44:0.6,68:0.4,92:0.2,116:0.0}
            if levels.has(local_frame):set_level(levels[local_frame])
            if local_frame==20:host._start_battle_text("MEGA GENGAR attacked!")
            if local_frame==30:host._play_pokemon_cry(host.battle_enemy)
            if local_frame==216:sendout_due.emit()
    host.enemy_sprite.position=enemy_position
    host.player_battle_sprite.position=player_position
    set_level(0.0)
    set_palette_stage(0)
    breathe=true
    if kind=="regigigas":
        host._play_pokemon_cry(host.battle_enemy)
        await host._type_battle_text("The battlefield quakes under REGIGIGAS' presence!")
        reveal_ground=true
        shockwave_pending=true
        await get_tree().create_timer(60.0/60.0).timeout
    else:host._start_battle_text("")

func _draw() -> void:
    if backdrop==null:return
    draw_set_transform(Vector2.ZERO,0,size/Vector2(160,144))
    # Mega Gengar's source bitmap includes its old dialogue frame. The user's
    # approved panel owns that border; retain only the bitmap's blank backdrop.
    var source_region := Rect2(0,0,160,144) if kind=="regigigas" else Rect2(0,0,1,1)
    draw_texture_rect_region(backdrop,Rect2(0,0,160,144),source_region,Color(1,1,1,maxf(0.0,fade_alpha)) if kind=="regigigas" else Color.WHITE)
    if reveal_ground:_draw_ground(self,10,5)
    draw_set_transform(Vector2.ZERO)

func _draw_front() -> void:
    if reveal_ground:_draw_ground(front,4,-4)

func _draw_ground(canvas: Control, first: int, last: int) -> void:
    canvas.draw_set_transform(Vector2.ZERO,0,size/Vector2(160,144))
    for i in range(first,last-1,-1):
        var offset_y := 0
        if i>=2:
            offset_y=-2-2*(i-2)
            if i>=5:offset_y+=-2-2*(i-6)
            if i>=9:offset_y+=-2-2*(i-10)
        var offset_x := int(sin(timer+i*PI/12.0)*(32.0-24.0*i/10.0))
        for j in range(-3,21):
            var x := clampf(wave_timer-(10-i)*PI/5.0-pow((20-j)*PI/30.0,2),0.0,PI)
            var dampen := 32.0-28.0*(i/10.0)*((j+20)/20.0)
            var alpha := 1.0
            var offset_y2 := 0.0
            if alpha_timer<PI*8.0:
                alpha=minf(PI/2.0,x)/(PI/2.0)
                dampen/=4.0
                offset_y2=sin(x)
            elif i<j+4 and i<20-j-2:offset_y2=sin(x)
            var offset_y3 := sin(clampf(wave_timer2+i*PI/12.0-(20-j)*PI/48.0,0.0,PI))
            var y := 24+i*8+offset_y+int(offset_y2*dampen)+int(offset_y3*3.0)
            var color := Color((10.0-i)/10.0,(10.0-i)/10.0,(10.0-i)/10.0,alpha)
            canvas.draw_texture_rect_region(ground,Rect2(offset_x+j*16-80,144-y-32,32,32),Rect2(0,0,32,32),color)
    canvas.draw_set_transform(Vector2.ZERO)

func _exit_tree() -> void:
    set_palette_stage(0)
    for node in original_hud_textures:
        if is_instance_valid(node):node.texture=original_hud_textures[node]
    for node in original_hud_colors:
        if is_instance_valid(node):node.add_theme_color_override("font_color",original_hud_colors[node])
    for node in original_hud_materials:
        if is_instance_valid(node):node.material=original_hud_materials[node]
    if is_instance_valid(inverse_gender):inverse_gender.material=original_gender_material
    for node in original_z:
        if is_instance_valid(node):node.z_index=original_z[node]
    if is_instance_valid(upper):upper.queue_free()
    if is_instance_valid(lower):lower.queue_free()
