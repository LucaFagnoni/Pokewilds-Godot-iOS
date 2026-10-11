extends Control
## Presentation only. Catch odds, inventory, ownership and EXP stay in the caller.
var main: Node
var ball: TextureRect
var enemy: TextureRect
func picture(texture: Texture2D, at: Vector2, dimensions: Vector2) -> TextureRect:
    var node := TextureRect.new()
    node.texture=texture;node.position=at;node.size=dimensions
    node.expand_mode=TextureRect.EXPAND_IGNORE_SIZE
    node.stretch_mode=TextureRect.STRETCH_KEEP_ASPECT_CENTERED
    node.texture_filter=CanvasItem.TEXTURE_FILTER_NEAREST
    node.mouse_filter=Control.MOUSE_FILTER_IGNORE
    add_child(node)
    return node
func wait_frames(count: int) -> void:
    await get_tree().create_timer(count/60.0).timeout
func play(owner_main: Node, pokemon: Dictionary, ball_name: String, outcome: int) -> void:
    main=owner_main
    z_index=340;size=Vector2(320,180)
    var background:=ColorRect.new()
    background.size=size;background.color=Color("252629") if preload("res://scripts/game_options.gd").enabled("dark_mode") else Color.WHITE
    background.mouse_filter=Control.MOUSE_FILTER_IGNORE
    add_child(background)
    picture(main._remove_connected_sprite_background(main._trainer_battle_texture()),Vector2(20,68),Vector2(72,72))
    enemy=picture(main._battle_sprite_frame(PokemonData.record_texture(pokemon,"front")),Vector2(208,20),Vector2(72,72))
    ball=picture(main.ball_mechanics.ball_texture(ball_name),Vector2(64,87),Vector2(16,16))
    main.world.play_source_sound("throw_pokeball1")
    var start:=ball.position
    var target:=Vector2(236,68)
    var elapsed:=0.0
    var began:=preload("res://scripts/game_clock.gd").ticks_usec()
    while elapsed<0.34:
        var t:=minf(1.0,elapsed/0.34)
        ball.position=start.lerp(target,t)+Vector2(0,-28*sin(PI*t))
        await get_tree().process_frame
        elapsed=(preload("res://scripts/game_clock.gd").ticks_usec()-began)/1000000.0
    ball.position=target
    enemy.pivot_offset=enemy.size*0.5
    enemy.modulate=Color(1,0.3,0.3)
    main.world.play_source_sound("poof1")
    var shrink:=create_tween()
    shrink.tween_property(enemy,"scale",Vector2.ZERO,9.0/60.0)
    await shrink.finished
    enemy.hide()
    var settle:=create_tween()
    settle.tween_property(ball,"position",Vector2(236,92),0.16)
    await settle.finished
    var key:="capture_wiggle:"+ball_name+str(preload("res://scripts/gen3_overhaul.gd").enabled)
    if not main.ball_mechanics.ball_textures.has(key):
        main.ball_mechanics.ball_textures[key]=ImageTexture.create_from_image(preload("res://scripts/ball_shell_colors.gd").recolor(preload("res://assets/source_exact/global/pokeball_wiggleSheet1_color.png").get_image(),ball_name))
    var sheet:Texture2D=main.ball_mechanics.ball_textures[key]
    await wait_frames(12)
    for shake in range(3 if outcome<0 else outcome):
        await wait_frames(24)
        main.world.play_source_sound("pokeball_wiggle1")
        for pose in [1,2,0,2,0]:
            var frame:=AtlasTexture.new();frame.atlas=sheet;frame.region=Rect2(pose*12,0,12,12)
            ball.texture=frame
            await wait_frames(3)
    if outcome<0:
        await wait_frames(24)
        for offset in [Vector2(-12,-9),Vector2(10,-16),Vector2(23,-9)]:
            picture(preload("res://scripts/menu_symbol_palette.gd").shiny(),ball.position+offset,Vector2(8,8))
        await wait_frames(20)
    else:
        ball.hide();enemy.scale=Vector2.ONE;enemy.modulate=Color.WHITE;enemy.show()
        main.world.play_source_sound("poof1")
        await wait_frames(16)
