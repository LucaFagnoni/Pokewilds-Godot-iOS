extends RefCounted

# Battle.LoadAndPlayAnimation and SpriteProxy (0.8.11).
# Authored frame images remain separate from runtime screenshot/palette effects.
var main: Node
var overlay: TextureRect
var warp: ShaderMaterial
var sprite_materials: Array[ShaderMaterial] = []
var original_materials: Array = []
var original_textures: Array[Texture2D] = []
var shrink_cache: Dictionary = {}
var original_hud_visibility: Dictionary = {}
var original_panel_position := Vector2.ZERO
var original_background := Color.WHITE
var displacement_progress := 0
var displacement_last_frame := 1
var key := ""

const PALETTE_CODE := """
shader_type canvas_item;
uniform vec4 light_color : source_color = vec4(0.66,0.66,0.66,1.0);
uniform vec4 dark_color : source_color = vec4(0.33,0.33,0.33,1.0);
uniform int effect = 0;
bool same(vec3 a, vec3 b) { return distance(a,b) < 0.004; }
void fragment() {
    vec4 c = texture(TEXTURE, UV);
    bool black = same(c.rgb,vec3(0.0));
    bool white = same(c.rgb,vec3(1.0)) || same(c.rgb,vec3(1.0,251.0/255.0,1.0));
    bool light = same(c.rgb,light_color.rgb);
    bool dark = same(c.rgb,dark_color.rgb);
    if (effect == 1) {
        if(black) c.rgb=vec3(1.0); else if(white) c.rgb=vec3(0.0);
        else if(light) c.rgb=dark_color.rgb; else if(dark) c.rgb=light_color.rgb;
    } else if(effect==2 && dark) c.rgb=vec3(0.0);
    else if(effect==3) { if(dark)c.rgb=vec3(0.0);else if(light)c.rgb=dark_color.rgb; }
    else if(effect==4 && (light||dark)) c.rgb=vec3(0.0);
    else if(effect==5) { if(black)c.rgb=dark_color.rgb;else if(dark)c.rgb=light_color.rgb;else if(light)c.rgb=vec3(1.0); }
    else if(effect==6) { if(black)c.rgb=light_color.rgb;else if(light||dark)c.rgb=vec3(1.0); }
    else if(effect==7) { if(black)c.rgb=light_color.rgb;else if(white)c.rgb=vec3(0.0);else if(light)c.rgb=vec3(1.0); }
    else if(effect==8) { if(black)c.rgb=dark_color.rgb;else if(white)c.rgb=vec3(0.0);else if(dark)c.rgb=vec3(1.0); }
    COLOR=c;
}
"""

const WARP_CODE := """
shader_type canvas_item;
render_mode unshaded;
uniform float rows[144];
uniform int mode = 0;
uniform int progress = 0;
uniform bool ignore_player = false;
uniform bool ignore_enemy = false;
uniform vec4 player_light : source_color;
uniform vec4 player_dark : source_color;
uniform vec4 enemy_light : source_color;
uniform vec4 enemy_dark : source_color;
uniform int player_effect = 0;
uniform int enemy_effect = 0;
uniform int global_effect = 0;
bool same(vec3 a, vec3 b) { return distance(a,b) < 0.004; }
vec4 recolor(vec4 c, vec4 light_color, vec4 dark_color, int effect) {
    bool black = same(c.rgb,vec3(0.0));
    bool white = same(c.rgb,vec3(1.0)) || same(c.rgb,vec3(1.0,251.0/255.0,1.0));
    bool light = same(c.rgb,light_color.rgb);
    bool dark = same(c.rgb,dark_color.rgb);
    if (effect == 1) {
        if(black) c.rgb=vec3(1.0); else if(white) c.rgb=vec3(0.0);
        else if(light) c.rgb=dark_color.rgb; else if(dark) c.rgb=light_color.rgb;
    } else if(effect==2 && dark) c.rgb=vec3(0.0);
    else if(effect==3) { if(dark)c.rgb=vec3(0.0);else if(light)c.rgb=dark_color.rgb; }
    else if(effect==4 && (light||dark)) c.rgb=vec3(0.0);
    else if(effect==5) { if(black)c.rgb=dark_color.rgb;else if(dark)c.rgb=light_color.rgb;else if(light)c.rgb=vec3(1.0); }
    else if(effect==6) { if(black)c.rgb=light_color.rgb;else if(light||dark)c.rgb=vec3(1.0); }
    else if(effect==7) { if(black)c.rgb=light_color.rgb;else if(white)c.rgb=vec3(0.0);else if(light)c.rgb=vec3(1.0); }
    else if(effect==8) { if(black)c.rgb=dark_color.rgb;else if(white)c.rgb=vec3(0.0);else if(dark)c.rgb=vec3(1.0); }
    return c;
}
void fragment() {
    vec2 p=floor(UV*vec2(160.0,144.0));
    vec2 q=p;
    float source_y=144.0-p.y;
    if(mode==1) {
        if(!((ignore_player && p.x<86.0 && source_y<112.0) || (ignore_enemy && p.x>=96.0 && source_y>=88.0)))
            q.y=rows[clamp(int(p.y),0,143)];
    } else if(mode==2 && source_y>=48.0) {
        if(!((ignore_player && (source_y<88.0 || p.x<86.0)) || (ignore_enemy && (source_y>=92.0 || p.x>=96.0))))
            q.x-=trunc(5.0*sin(0.5235987755982988*(source_y+float(progress))));
    } else if(mode==3 && source_y>=48.0) {
        if(!((ignore_player && (source_y<88.0 || p.x<86.0)) || (ignore_enemy && (source_y>=92.0 || p.x>=96.0))))
            q.x-=float(progress)*(mod(source_y,2.0)==0.0?-1.0:1.0);
    }
    // Java starts each warp with the original screenshot, then writes shifted
    // pixels over it; uncovered rows retain the original image.
    if(q.x<0.0 || q.x>=160.0 || q.y<0.0 || q.y>=144.0) q=p;
    vec4 c=texture(TEXTURE,(q+0.5)/vec2(160.0,144.0));
    if(q.x>=94.0 && q.y<60.0) c=recolor(c,enemy_light,enemy_dark,enemy_effect);
    else if(q.x<80.0 && q.y>=48.0 && q.y<96.0) c=recolor(c,player_light,player_dark,player_effect);
    else if(global_effect==1) c=recolor(c,vec4(1.0),vec4(0.0),1);
    COLOR=c;
}
"""

func begin(owner_node: Node, source_key: String) -> void:
    main = owner_node
    main._restore_battle_background()
    key = source_key
    original_panel_position = main.battle_panel.position
    original_background = main.battle_panel.get_node("Background").color
    for child in main.source_single_hud.get_children():
        if child is CanvasItem:
            original_hud_visibility[child] = child.visible
    var shader := Shader.new()
    shader.code = PALETTE_CODE
    for sprite in [main.player_battle_sprite, main.enemy_sprite]:
        original_materials.append(sprite.material)
        original_textures.append(sprite.texture)
        var material := ShaderMaterial.new()
        material.shader = shader
        var colors := palette(sprite.texture)
        material.set_shader_parameter("light_color", colors[0])
        material.set_shader_parameter("dark_color", colors[1])
        sprite.material = material
        sprite_materials.append(material)
    overlay = TextureRect.new()
    overlay.name = "SourceBattleScreenshotEffect"
    overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
    overlay.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
    overlay.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
    overlay.stretch_mode = TextureRect.STRETCH_SCALE
    overlay.position = main.battle_move_animation.position
    overlay.size = main.battle_move_animation.size
    overlay.visible = false
    main.battle_panel.add_child(overlay)
    main.battle_panel.move_child(overlay, main.battle_move_animation.get_index())
    var warp_shader := Shader.new()
    warp_shader.code = WARP_CODE
    warp = ShaderMaterial.new()
    warp.shader = warp_shader
    overlay.material = warp
    var player_colors := palette(main.player_battle_sprite.texture)
    var enemy_colors := palette(main.enemy_sprite.texture)
    warp.set_shader_parameter("player_light",player_colors[0])
    warp.set_shader_parameter("player_dark",player_colors[1])
    warp.set_shader_parameter("enemy_light",enemy_colors[0])
    warp.set_shader_parameter("enemy_dark",enemy_colors[1])

static func palette(texture: Texture2D) -> Array[Color]:
    var colors: Array[Color] = []
    if texture != null:
        var image := texture.get_image()
        for y in range(image.get_height()):
            for x in range(image.get_width()):
                var c := image.get_pixel(x,y)
                if c.a < 0.01 or c == Color.BLACK or c == Color.WHITE or colors.has(c): continue
                if colors.size() < 2: colors.append(c)
            if colors.size() == 2: break
    while colors.size() < 2: colors.append(Color.WHITE if colors.is_empty() else Color.BLACK)
    if colors[0].r+colors[0].g+colors[0].b < colors[1].r+colors[1].g+colors[1].b:
        colors.reverse()
    return colors

static func effect_id(frame: Dictionary, side: String = "") -> int:
    if frame.has("inverse_colors"): return 1
    for entry in [["darken_effect1",2],["darken_effect2",3],["darken_effect3",4],
            ["lighten_effect1",5],["lighten_effect2",6],["confuseray_effect1",7],["confuseray_effect2",8]]:
        if frame.has(entry[0]) or (not side.is_empty() and frame.has(side+"_"+entry[0])):
            return int(entry[1])
    return 0

func apply(frame: Dictionary, frame_number: int) -> void:
    main.battle_panel.position = original_panel_position + Vector2(float(frame.get("screen_translate_x",0)), -float(frame.get("screen_translate_y",0)))
    # screen translation belongs to the complete UI batch, not just the PNG.
    main.battle_move_animation.position = overlay.position
    sprite_materials[0].set_shader_parameter("effect", effect_id(frame,"player"))
    sprite_materials[1].set_shader_parameter("effect", effect_id(frame,"enemy"))
    for index in range(2):
        var sprite = main.player_battle_sprite if index == 0 else main.enemy_sprite
        var side_name := "player" if index == 0 else "enemy"
        var progress := int(frame.get(side_name+"_shrink",0))
        sprite.scale = Vector2.ONE
        sprite.texture = original_textures[index]
        if progress > 0:
            var cache_key := str(index)+":"+str(progress)
            if not shrink_cache.has(cache_key):
                shrink_cache[cache_key] = shrink_texture(original_textures[index],progress)
            sprite.texture = shrink_cache[cache_key]
    for child in original_hud_visibility:
        var side := "enemy" if String(child.name).begins_with("Enemy") else "player"
        child.visible = original_hud_visibility[child] and not bool(frame.get(side+"_healthbar_gone",false))
    main.battle_panel.get_node("Background").color = Color.BLACK if frame.has("inverse_colors") else original_background
    warp.set_shader_parameter("player_effect",effect_id(frame,"player"))
    warp.set_shader_parameter("enemy_effect",effect_id(frame,"enemy"))
    warp.set_shader_parameter("global_effect",effect_id(frame))
    overlay.visible = false
    if frame.has("screenshot"):
        await RenderingServer.frame_post_draw
        var image: Image = main.get_viewport().get_texture().get_image()
        image.resize(160,144,Image.INTERPOLATE_NEAREST)
        overlay.texture = ImageTexture.create_from_image(image)
    if overlay.texture == null: return
    var mode := 1 if frame.has("row_copy") else 2 if frame.has("row_displace") else 3 if frame.has("row_split") else 0
    overlay.visible = mode != 0
    if mode == 0: return
    var ignore_player := "_player_" in key and not ("surf" in key or "whirlpool" in key)
    var ignore_enemy := "_enemy_" in key and not ("surf" in key or "whirlpool" in key)
    if mode == 1:
        var rows := PackedFloat32Array()
        for y in range(144): rows.append(float(y))
        for pair in frame.row_copy:
            if int(pair[0]) >= 0 and int(pair[0]) < 144: rows[int(pair[0])] = float(pair[1])
        warp.set_shader_parameter("rows",rows)
    elif mode == 2:
        var speed := float(frame.row_displace)
        if speed > 0.0 and frame_number >= displacement_last_frame + 1.0/speed:
            displacement_last_frame = frame_number
            displacement_progress += 1
        ignore_player = String(frame.get("displace_target","")) == "enemy"
        ignore_enemy = String(frame.get("displace_target","")) == "player"
        warp.set_shader_parameter("progress",displacement_progress)
    else:
        ignore_player = "_enemy_" in key
        ignore_enemy = "_player_" in key
        warp.set_shader_parameter("progress",int(frame.row_split))
    warp.set_shader_parameter("mode",mode)
    warp.set_shader_parameter("ignore_player",ignore_player)
    warp.set_shader_parameter("ignore_enemy",ignore_enemy)

func finish() -> void:
    main.battle_panel.position = original_panel_position
    main._restore_battle_background()
    main.player_battle_sprite.material = original_materials[0]
    main.enemy_sprite.material = original_materials[1]
    main.player_battle_sprite.texture = original_textures[0]
    main.enemy_sprite.texture = original_textures[1]
    for child in original_hud_visibility: child.visible = original_hud_visibility[child]
    overlay.queue_free()

static func shrink_texture(texture: Texture2D, progress: int) -> Texture2D:
    # Battle.LoadAndPlayAnimation: rearrange 8x8 tiles, never rescale pixels.
    var source := texture.get_image()
    var columns := source.get_width()/8
    var rows := source.get_height()/8
    var cells: Array = []
    for x in range(7):
        var column: Array = []
        for y in range(7):
            var sx := x-(7-rows)
            var sy := 6-y
            column.append(Vector2i(sx*8,sy*8) if sx>=0 and sx<columns and sy>=0 and sy<rows else Vector2i(-1,-1))
        column[1]=column[2]
        column[2]=column[3]
        column[3]=column[5]
        column[4]=Vector2i(-1,-1)
        column[5]=Vector2i(-1,-1)
        cells.append(column)
    cells[2]=cells[1]
    cells[1]=[]
    cells[5]=cells[6]
    cells[6]=[]
    if progress==2:
        for column in cells:
            if column.is_empty(): continue
            column[1]=column[3]
            for y in range(2,6): column[y]=Vector2i(-1,-1)
        cells[3]=cells[2]
        cells[2]=[]
        cells[4]=cells[5]
        cells[5]=[]
        cells[6]=[]
    var output := Image.create(56,56,false,Image.FORMAT_RGBA8)
    output.fill(Color.TRANSPARENT)
    for x in range(7):
        for y in range(cells[x].size()):
            var origin: Vector2i=cells[x][y]
            if origin.x>=0:
                output.blit_rect(source,Rect2i(origin,Vector2i(8,8)),Vector2i(x*8,(6-y)*8))
    return ImageTexture.create_from_image(output)
