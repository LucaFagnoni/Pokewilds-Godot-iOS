class_name FieldMoveRadial
extends Control
const SOURCE_FONT := preload("res://assets/source_text_font.fnt")
const Options = preload("res://scripts/game_options.gd")
const SMOOTH_RING_SHADER = preload("res://scripts/radial_frame.gdshader")
const OUTER_RADIUS := 76.0
const BORDER_OUTSET := 1.0
const INNER_RADIUS := 48.0
const ICON_RADIUS := 57.0
var entries: Array[Dictionary] = []
var selected_index := -1
var page_label := ""
var center_title := ""
var paper := Color.WHITE
var ink := Color(0.16,0.17,0.17)
var frame_ring: TextureRect
func _ready() -> void:
    mouse_filter = Control.MOUSE_FILTER_IGNORE
    set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    visible = false
    frame_ring=TextureRect.new()
    frame_ring.name="SmoothFrameRing"
    frame_ring.mouse_filter=Control.MOUSE_FILTER_IGNORE
    frame_ring.expand_mode=TextureRect.EXPAND_IGNORE_SIZE
    frame_ring.texture_filter=CanvasItem.TEXTURE_FILTER_NEAREST
    var ring_material:=ShaderMaterial.new()
    ring_material.shader=SMOOTH_RING_SHADER
    ring_material.set_shader_parameter("base_radius", OUTER_RADIUS)
    ring_material.set_shader_parameter("border_outset", BORDER_OUTSET)
    frame_ring.material=ring_material
    add_child(frame_ring)
    resized.connect(_position_frame_ring)
    _position_frame_ring()
func configure(new_entries: Array[Dictionary], initial_index: int = -1) -> void:
    entries = new_entries.duplicate(true)
    selected_index = -1 if initial_index < 0 else clampi(initial_index,0,maxi(0,entries.size()-1))
    page_label = ""
    center_title = ""
    var texture := Options.frame_texture()
    frame_ring.texture = ImageTexture.create_from_image(texture.get_image())
    var pixels := texture.get_image()
    paper = pixels.get_pixel(pixels.get_width()/2,pixels.get_height()/2)
    if paper.a < 0.5: paper = Color(0.96,0.95,0.91)
    ink = Color(0.15,0.16,0.16) if paper.get_luminance() > 0.45 else Color(0.95,0.95,0.92)
    queue_redraw()
func select(index: int) -> void:
    var next := -1 if index < 0 or entries.is_empty() else wrapi(index,0,entries.size())
    if next != selected_index:
        selected_index = next
        queue_redraw()
func _draw() -> void:
    if entries.is_empty(): return
    var center := size*0.5
    draw_rect(Rect2(Vector2.ZERO,size),Color(0,0,0,0.42))
    var step := TAU / entries.size()
    for index in range(entries.size()):
        var middle := -PI*0.5 + index*step
        var start := middle-step*0.5
        var finish := middle+step*0.5
        var polygon := PackedVector2Array()
        for point in range(33):
            polygon.append(center+Vector2.from_angle(lerpf(start,finish,point/32.0))*OUTER_RADIUS)
        for point in range(32,-1,-1):
            polygon.append(center+Vector2.from_angle(lerpf(start,finish,point/32.0))*INNER_RADIUS)
        var fill := paper.darkened(0.12 if index%2 else 0.05)
        if index == selected_index: fill = paper.lerp(ink,0.25)
        draw_colored_polygon(polygon,fill)
        draw_line(center+Vector2.from_angle(start)*INNER_RADIUS,center+Vector2.from_angle(start)*OUTER_RADIUS,ink,0.65,true)
        var icon := entries[index].get("texture") as Texture2D
        if icon != null:
            var icon_size := icon.get_size()
            icon_size *= minf(12.0/icon_size.x,12.0/icon_size.y)
            draw_texture_rect(icon,Rect2(center+Vector2.from_angle(middle)*ICON_RADIUS-icon_size/2,icon_size),false,Color.WHITE if entries[index].get("available",false) else Color(0.5,0.5,0.5,0.65))
    draw_circle(center,INNER_RADIUS-1,paper,true,-1.0,true)
    draw_arc(center,INNER_RADIUS,0,TAU,256,paper,2.0,true)
    var text_font: Font = preload("res://scripts/dark_mode.gd").light_font(SOURCE_FONT) if Options.enabled("dark_mode") else SOURCE_FONT
    var text_color := ink if Options.enabled("dark_mode") else paper
    var title := "SELECT ITEM" if not page_label.is_empty() else "FIELD MOVE"
    if not center_title.is_empty(): title = center_title
    if selected_index >= 0: title = String(entries[selected_index].get("move",title))
    var words := title.split(" ")
    var lines: Array[String] = [""]
    for word in words:
        var candidate := (lines[-1]+" "+word).strip_edges()
        if SOURCE_FONT.get_string_size(candidate,HORIZONTAL_ALIGNMENT_LEFT,-1,8).x > 82 and not lines[-1].is_empty(): lines.append(word)
        else: lines[-1] = candidate
    var y := center.y-float(lines.size()-1)*5.0-(14.0 if not page_label.is_empty() else 0.0)
    for line in lines:
        draw_string(text_font,Vector2(center.x-43,y),line,HORIZONTAL_ALIGNMENT_CENTER,86,8,text_color)
        y += 10
    if not page_label.is_empty():
        if selected_index >= 0:
            var detail := String(entries[selected_index].get("detail", ""))
            if not detail.is_empty():
                draw_string(text_font,center+Vector2(-42,12),detail,HORIZONTAL_ALIGNMENT_CENTER,84,6,text_color)
            var cost: Dictionary = entries[selected_index].get("cost", {})
            var cost_y := center.y + 5.0
            for material_name in cost:
                var label := "%s x%d" % [String(material_name), int(cost[material_name])]
                var font_size := 6
                while font_size > 4 and SOURCE_FONT.get_string_size(label,HORIZONTAL_ALIGNMENT_LEFT,-1,font_size).x > 78:
                    font_size -= 1
                draw_string(text_font,Vector2(center.x-40,cost_y),label,HORIZONTAL_ALIGNMENT_CENTER,80,font_size,text_color)
                cost_y += 8
        draw_string(text_font,center+Vector2(-36,35),page_label,HORIZONTAL_ALIGNMENT_CENTER,72,5,text_color)

# The shader draws at display resolution, without a low-resolution ring atlas
# or a CPU image-generation pause when opening the wheel.
func _position_frame_ring() -> void:
    if not is_instance_valid(frame_ring): return
    var border_radius := OUTER_RADIUS + BORDER_OUTSET
    frame_ring.position=size*0.5-Vector2.ONE*border_radius
    frame_ring.size=Vector2.ONE*border_radius*2.0
