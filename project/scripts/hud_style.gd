extends RefCounted
## The field HUD's one look, for the on-screen buttons, the menu button, the
## status chips (clock, battery, FPS, the A hint, STOP) and the minimap's ring:
## dark glass that follows OPTIONS > BUTTON THEME, one 1.5 px ring (white, or
## the button's colour on A, B, MOSSE and LANCIO), rounded corners, and the
## game's pixel font in white at its own size. Pieces sit MARGIN from the safe
## area's edges and GAP from each other; the top row is ROW tall.
## Glass behind text (the top row, the chips) is denser and ignores BUTTON
## OPACITY, so the pixel text reads over any ground; the play buttons follow it.

const MARGIN := 4.0
const GAP := 4.0
const ROW := 18.0
const STROKE := 1.5
const RADIUS := 4.0
const INK := Color.WHITE
const FONT := preload("res://assets/source_text_font_white.fnt")
## The bitmap font's own size: whole pixels. Its capitals and digits are ink
## rows 1-6 and columns 0-6 of an 8-pixel cell.
const FONT_SIZE := 10
const INK_HEIGHT := 6.0
const INK_CENTRE := 4.0
## Room around a chip's text (and the menu button's icon) in the top row.
const PAD := (ROW - INK_HEIGHT) / 2.0

## Set by TouchControls from the resolved BUTTON THEME.
static var dark := true

static func fill(pressed: bool = false, dense: bool = false) -> Color:
    if pressed: return Color(0.25, 0.25, 0.25, 0.9)
    if dense: return Color(0.10, 0.10, 0.10, 0.85 if dark else 0.65)
    return Color(0.10, 0.10, 0.10, 0.80 if dark else 0.45)

## A circle, or a rounded rectangle, filling rect: glass inside, the ring on its edge.
static func draw_shape(item: CanvasItem, rect: Rect2, round: bool, ring: Color = INK, pressed: bool = false, stroke: float = STROKE, dense: bool = false) -> void:
    var inner := rect.grow(-stroke * 0.5)
    if round:
        var radius := minf(inner.size.x, inner.size.y) * 0.5
        item.draw_circle(rect.get_center(), radius, fill(pressed, dense))
        item.draw_arc(rect.get_center(), radius, 0.0, TAU, 48, ring, stroke, true)
        return
    var outline := rounded(inner, RADIUS * stroke / STROKE)
    item.draw_colored_polygon(outline, fill(pressed, dense))
    outline.append(outline[0])
    item.draw_polyline(outline, ring, stroke, true)

static func rounded(rect: Rect2, radius: float) -> PackedVector2Array:
    var r := minf(radius, minf(rect.size.x, rect.size.y) * 0.5)
    var centres := [Vector2(rect.end.x - r, rect.position.y + r), rect.end - Vector2(r, r),
        Vector2(rect.position.x + r, rect.end.y - r), rect.position + Vector2(r, r)]
    var points := PackedVector2Array()
    for corner in 4:
        for step in 7:
            var angle := (corner - 1 + step / 6.0) * PI / 2.0
            points.append(centres[corner] + Vector2(cos(angle), sin(angle)) * r)
    return points

## Three bars, as tall and as far from the edges as a chip's text.
static func draw_menu_icon(item: CanvasItem, size: Vector2, stroke: float = STROKE) -> void:
    var box := Rect2((size - Vector2(INK_HEIGHT, INK_HEIGHT)) * 0.5, Vector2(INK_HEIGHT, INK_HEIGHT))
    var bar := stroke
    for i in 3:
        item.draw_rect(Rect2(box.position.x, box.position.y + i * (INK_HEIGHT - bar) / 2.0, INK_HEIGHT, bar), INK)

## A chip: a Control painted with the HUD shape and a white label, as wide as its text.
static func chip(parent: Node, node_name: String) -> Control:
    var node := Control.new()
    node.name = node_name
    node.mouse_filter = Control.MOUSE_FILTER_IGNORE
    node.size = Vector2(ROW, ROW)
    node.draw.connect(func(): draw_shape(node, Rect2(Vector2.ZERO, node.size), false, INK, false, STROKE, true))
    node.add_child(label())
    parent.add_child(node)
    return node

static func label(node_name: String = "Text") -> Label:
    var text := Label.new()
    text.name = node_name
    text.mouse_filter = Control.MOUSE_FILTER_IGNORE
    text.add_theme_font_override("font", FONT)
    text.add_theme_font_size_override("font_size", FONT_SIZE)
    text.add_theme_color_override("font_color", INK)
    return text

## The text's ink centred on the chip's middle line, PAD from the left; the
## chip ends PAD after the last ink column (glyphs leave column 7 blank).
static func set_chip_text(node: Control, text: String, height: float = ROW, lead: float = 0.0) -> void:
    var text_label := node.get_node("Text") as Label
    var pad := (height - INK_HEIGHT) / 2.0
    text_label.text = text
    text_label.position = Vector2(pad + lead, roundf(height / 2.0 - INK_CENTRE))
    var width := FONT.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE).x - (0.0 if text.ends_with("%") else 1.0)
    var wanted := Vector2(pad + lead + width + pad, height)
    if node.size != wanted:
        node.size = wanted
        node.queue_redraw()
