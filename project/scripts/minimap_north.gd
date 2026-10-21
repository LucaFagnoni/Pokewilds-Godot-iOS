extends Control
## The minimap's north marker: a pixel N on the HUD's glass, on the ring.
const HudStyle = preload("res://scripts/hud_style.gd")
func _init() -> void:
    size=Vector2(7,9);mouse_filter=Control.MOUSE_FILTER_IGNORE;z_index=6
func _draw() -> void:
    draw_rect(Rect2(Vector2.ZERO,size),HudStyle.fill(false,true))
    var rows=["10001","11001","11001","10101","10011","10011","10001"]
    for y in range(7):
        for x in range(5):
            if rows[y][x]=="1":draw_rect(Rect2(x+1,y+1,1,1),HudStyle.INK)
