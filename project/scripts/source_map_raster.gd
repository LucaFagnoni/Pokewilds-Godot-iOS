extends RefCounted
## The full map's picture, kept up to date while playing so the map screen
## shows it at once. Drawing the whole map as one ~25 MB image whenever it
## opened after exploring took seconds on a phone (a black screen). Now the
## map is blocks of CHUNK x CHUNK tiles, one small texture each, made only
## where ground was discovered; the fog under them is one tiled 2x2-tile
## texture. A block is drawn again, by the minimap's drawing, when ground in it
## is discovered or its tiles or buildings change (the boxes the world keeps).
const CHUNK := 32
## Tall art reaches 3 tiles past its own tile (see main._m3924_minimap_paint).
const MARGIN := 3
const PIXELS := 4

var main: Node
## [exact world id, map bounds]: the blocks are dropped when it changes.
var context: Array = []
var bounds := Rect2i()
## Block -> ImageTexture.
var chunks := {}
## Blocks to draw again.
var dirty := {}
var seen_revision := 0
var seen_boxed := 0
var seen_discovered := 0
var seen_added := 0
var seen_structures := 0
var next_draw_msec := 0
## The open map screen's picture, redrawn when a block is added.
var view: TextureRect
static var fog: ImageTexture

func _init(owner: Node) -> void:
    main = owner

## The overworld (and any area drawn from its tiles); interiors have their own image.
func _outdoors() -> bool:
    var world = main.world
    return world.exact_world != null and (world.active_area_id == "OVERWORLD" or not world.source_area_layers.has(world.active_area_id))

func forget() -> void:
    context = []
    chunks.clear()
    dirty.clear()

## Each frame: takes the changes, and draws a changed block every half second
## while the map is closed, or 8 ms of them a frame while it is open (a still
## screen, at 30 FPS unless touched).
func update(open: bool) -> void:
    if not refresh() or dirty.is_empty(): return
    var now := Time.get_ticks_msec()
    if not open and now < next_draw_msec: return
    next_draw_msec = now + 500
    draw_dirty(8000 if open else 0)

## Marks the blocks the world changed since the last look. False indoors.
func refresh() -> bool:
    if not _outdoors(): return false
    var world = main.world
    var now_context := [world.exact_world.get_instance_id(), world.get_map_bounds()]
    if now_context != context:
        context = now_context
        bounds = now_context[1]
        chunks.clear()
        dirty.clear()
        _take_counts()
        _mark_discovered()
        if is_instance_valid(view): view.queue_redraw()
        return true
    # The world boxes what discovery and most edits change, and counts them;
    # anything else (a load, a co-op build) redraws every block.
    var art_bumps: int = world.map_art_revision - seen_revision
    var art_known: bool = art_bumps == world.map_art_boxed - seen_boxed and \
        (art_bumps > 0 or world.built_structures.size() == seen_structures)
    var fog_known: bool = world.discovered_cells.size() - seen_discovered == world.discovered_added - seen_added
    var fog_box: Rect2i = world.map_fog_dirty
    var art_box: Rect2i = world.map_art_dirty
    _take_counts()
    if not art_known or not fog_known:
        for chunk in chunks: dirty[chunk] = true
    if not fog_known: _mark_discovered()
    # New ground makes blocks; art only changes the blocks there are.
    if fog_box.has_area():
        _mark(fog_box, true)
        _mark(fog_box.grow(MARGIN), false)
    if art_box.has_area(): _mark(art_box.grow(MARGIN), false)
    return true

func _take_counts() -> void:
    var world = main.world
    seen_revision = world.map_art_revision
    seen_boxed = world.map_art_boxed
    seen_discovered = world.discovered_cells.size()
    seen_added = world.discovered_added
    seen_structures = world.built_structures.size()
    world.map_fog_dirty = Rect2i()
    world.map_art_dirty = Rect2i()

func _mark(cells: Rect2i, new_blocks: bool) -> void:
    cells = cells.intersection(bounds)
    if not cells.has_area(): return
    var first := (cells.position - bounds.position) / CHUNK
    var last := (cells.end - Vector2i.ONE - bounds.position) / CHUNK
    for y in range(first.y, last.y + 1):
        for x in range(first.x, last.x + 1):
            var chunk := Vector2i(x, y)
            if new_blocks or chunks.has(chunk): dirty[chunk] = true

## Every block with discovered ground (keys "x,y"); every block off the overworld.
func _mark_discovered() -> void:
    var world = main.world
    if world.active_area_id != "OVERWORLD":
        _mark(bounds, true)
        return
    for key in world.discovered_cells:
        var cell := Vector2i(String(key).get_slice(",", 0).to_int(), String(key).get_slice(",", 1).to_int())
        if bounds.has_point(cell): dirty[(cell - bounds.position) / CHUNK] = true

## Draws dirty blocks, nearest the player first, until budget_usec has passed
## (at least one). True while some are left.
func draw_dirty(budget_usec: int) -> bool:
    var deadline := Time.get_ticks_usec() + budget_usec
    var near: Vector2i = (main.world._player_cell() - bounds.position) / CHUNK
    var order := dirty.keys()
    order.sort_custom(func(a, b): return (a - near).length_squared() < (b - near).length_squared())
    for chunk in order:
        dirty.erase(chunk)
        _draw_chunk(chunk)
        if Time.get_ticks_usec() >= deadline: break
    return not dirty.is_empty()

func _draw_chunk(chunk: Vector2i) -> void:
    var cells := Rect2i(bounds.position + chunk * CHUNK, Vector2i(CHUNK, CHUNK)).intersection(bounds)
    var drawn: Image = main._m3924_minimap_render(cells.grow(MARGIN), bounds, main.world.exact_world)
    var pixels := drawn.get_region(Rect2i(Vector2i(MARGIN, MARGIN) * PIXELS, cells.size * PIXELS))
    var texture: ImageTexture = chunks.get(chunk)
    if texture != null:
        texture.update(pixels)
        return
    chunks[chunk] = ImageTexture.create_from_image(pixels)
    if is_instance_valid(view): view.queue_redraw()

## The map screen's picture: the fog, tiled, with the blocks drawn over it.
func make_view() -> TextureRect:
    refresh()
    if fog == null:
        var image := Image.create(PIXELS * 2, PIXELS * 2, false, Image.FORMAT_RGBA8)
        image.fill(Color(0.025, 0.035, 0.03, 1.0))
        image.fill_rect(Rect2i(PIXELS, 0, PIXELS, PIXELS), Color(0.045, 0.055, 0.05, 1.0))
        image.fill_rect(Rect2i(0, PIXELS, PIXELS, PIXELS), Color(0.045, 0.055, 0.05, 1.0))
        fog = ImageTexture.create_from_image(image)
    view = TextureRect.new()
    view.texture = fog
    view.stretch_mode = TextureRect.STRETCH_TILE
    view.texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED
    view.draw.connect(_draw_chunks.bind(view))
    return view

func _draw_chunks(on: TextureRect) -> void:
    for chunk in chunks:
        on.draw_texture(chunks[chunk], Vector2(chunk * CHUNK * PIXELS))
