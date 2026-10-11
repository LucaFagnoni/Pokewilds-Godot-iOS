extends Control
## ThrowOutPokemonCrystal's 8x8 sprite-cell expansion and authored poof frames.
const DURATIONS := [34,4,2,2,2,2,2,2,26]
var back: Texture2D
var poof: Texture2D = preload("res://assets/source_exact/global/poof_sheet2.png")
var phase := 0
var medium: Array = []
var small: Array = []

func setup(texture: Texture2D) -> void:
    back = texture
    mouse_filter = Control.MOUSE_FILTER_IGNORE
    texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
    for x in range(6):
        var column: Array = []
        for y in range(6): column.append(Vector2i(x,5-y))
        column[1]=column[2]; column[2]=column[3]; column[3]=column[5]
        column[4]=null; column[5]=null
        medium.append(column)
    medium[1]=medium[0]; medium[0]=[]
    medium[4]=medium[5]; medium[5]=[]
    small=medium.duplicate(true)
    for column in small:
        if column.is_empty(): continue
        column[1]=column[3]
        for y in range(2,6): column[y]=null
    small[2]=small[1]; small[1]=[]
    small[3]=small[4]; small[4]=[]; small[5]=[]

func _draw() -> void:
    if phase==0 or back==null: return
    var scale_value := minf(size.x/48.0,size.y/48.0)
    var origin := (size-Vector2(48,48)*scale_value)/2.0
    draw_set_transform(origin,0,Vector2.ONE*scale_value)
    if phase in [3,4,5,6]:
        var cells: Array = small if phase<5 else medium
        for x in range(cells.size()):
            for y in range(cells[x].size()):
                if cells[x][y]==null: continue
                draw_texture_rect_region(back,Rect2(x*8,40-y*8,8,8),Rect2(Vector2(cells[x][y])*8,Vector2(8,8)))
    elif phase>=7:
        draw_texture_rect(back,Rect2(0,0,48,48),false)
    if phase<=7:
        var frame := 0 if phase==1 else 1 if phase<=3 else 2 if phase<=5 else 3
        draw_texture_rect_region(poof,Rect2(-4,8,48,48),Rect2(frame*48,0,48,48))
    draw_set_transform(Vector2.ZERO)

func play(host: Node) -> void:
    if not preload("res://scripts/game_options.gd").enabled("battle_animations"):
        phase = 8
        queue_redraw()
        return
    var elapsed := 0.0
    var end_tick := DURATIONS[0]
    phase=0
    while phase<DURATIONS.size():
        await get_tree().process_frame
        elapsed+=get_process_delta_time()
        while phase<DURATIONS.size() and int(elapsed*60.0)>=end_tick:
            phase+=1
            if phase<DURATIONS.size(): end_tick+=DURATIONS[phase]
            if phase==1: host._play_source_battle_sound("poof1.ogg")
        queue_redraw()
