extends Node2D
# Visual-only sparkles, attached to the existing actor so movement/depth stay shared.
const Palette = preload("res://scripts/menu_symbol_palette.gd")
const Settings = preload("res://scripts/game_options.gd")
var phase := 0.0
static func attach(sprite: Sprite2D, record: Dictionary) -> void:
    if not PokemonData.is_shiny(record) or bool(record.get("is_egg",false)) or bool(record.get("is_ghost",false)):return
    if sprite.has_node("ShinySparkles"):return
    var effect=load("res://scripts/shiny_sparkles.gd").new()
    effect.name="ShinySparkles";effect.z_index=1;sprite.add_child(effect)
func _process(delta: float) -> void:
    visible = Settings.enabled("shiny_sparkles")
    if not is_visible_in_tree():return
    phase=fmod(phase+delta,2.4)
    queue_redraw()
func _draw() -> void:
    var actor=get_parent() as Sprite2D
    if actor==null:return
    var bounds=actor.get_rect()
    for i in range(3):
        var t=fmod(phase+float(i)*0.8,2.4)
        if t>=0.7:continue
        var pulse=sin(t/0.7*PI)
        var width=roundf(3.0+5.0*pulse)
        var at=bounds.position+bounds.size*Vector2([0.18,0.82,0.55][i],[0.30,0.52,0.12][i])
        draw_texture_rect(Palette.shiny(),Rect2((at-Vector2.ONE*width*0.5).round(),Vector2.ONE*width),false,Color(1,0.75+0.25*pulse,1,pulse))
