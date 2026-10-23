extends "res://scripts/source_chunk_tile_layer.gd"
const TexturePixels = preload("res://scripts/texture_pixels.gd")

# All terrain cells are installed before play. Camera movement only changes
# engine culling; it never resolves, loads or removes terrain cells.
const TileSheet = preload("res://scripts/tile_sheet.gd")
const CellFingerprints = preload("res://scripts/cell_fingerprints.gd")
var resident_layers: Array = []
var resident_tileset: TileSet
var resident_sources: Dictionary = {}
var resident_animations: Array = []
var resident_dirty := false
var resident_build_count := 0
var resident_shader: Shader
var resident_fingerprints := CellFingerprints.new()
var reward_composites: Dictionary = {}
var resident_animation_clock: Array = []
var pending_tide_near: Dictionary = {}
var pending_tide_far: Dictionary = {}
var far_tide_queued_at := 0
var far_tide_groups: Dictionary = {}
var far_tide_order: Array = []
var far_tide_wait := 0
## Cells per side of one map block: the layers' rendering_quadrant_size.
const TILE_BLOCK := 16
## Map blocks are drawn as the view nears them (build_resident_async).
var lazy_blocks := false
## Blocks drawn so far (never undrawn).
var built_blocks := {}
## Blocks in view are drawn in the frame they come into view (after draw_view_async).
var view_armed := false
## The block rectangle last found all drawn.
var drawn_view := Rect2i()
## Drawn blocks whose tide changed while they were far from the view:
## block -> {cell: true}. Redrawn as the view nears them, like undrawn blocks.
var stale_tide := {}
## Sprites reach at most two cells past their own: one more for the camera.
const VIEW_MARGIN_CELLS := 3
## Blocks drawn ahead of the view: this many on every side, and more in the
## direction the view is moving (up to AHEAD_LEAD_BLOCKS beyond the view,
## about AHEAD_LEAD_SECONDS of travel).
const AHEAD_BLOCKS := 2
const AHEAD_LEAD_BLOCKS := 4
const AHEAD_LEAD_SECONDS := 8.0
## Drawing ahead of the view: the time a frame may spend on it, by how close the
## nearest undrawn block is (1 block out, 2 blocks out, further).
const AHEAD_BUDGETS_USEC := [2000, 1500, 1000]
## Rows of a block drawn between two looks at the clock.
const SLICE_ROWS := 2
## The time a frame may spend preparing the view of a teleport (prepare_view),
## and on all drawing ahead of the view together (both streams).
const PREPARE_BUDGET_USEC := 3000
const FRAME_BUDGET_USEC := 3000
## Blocks drawn in part: block -> the next row to draw.
var partial_blocks := {}
## Where the view is going: its middle, and its speed in pixels a second.
var view_center := Vector2.ZERO
var view_speed := Vector2.ZERO
var view_center_known := false
## Blocks to draw before the view moves there (prepare_view).
var prepared_blocks := Rect2i()
var last_source_parts: Array = []
var last_source_id := -1
## Ground on the GPU. Every plain 16x16 ground tile (still or animated, most
## of the map) is drawn by one quad (TerrainView): its shader reads the cell's
## tile id from gpu_cells, the tile's place on a TileSheet page from
## gpu_table, and samples that page. Tidal, gate and odd-sized ground keeps
## its TileMapLayer cell. Tiles are drawn with their corners snapped to
## screen pixels (snap_2d_vertices_to_pixel); the shader snaps each cell the
## same way, so the result matches the TileMapLayer pixel for pixel.
##
## The upper layer works the same way (UpperView) for sprites that are a plain
## 16x16 tile, and draws the shoreline (ShoreView, TidalShoreView) from a
## per-cell pair of shore ids. The ground's beach tide overlay (TideView)
## reads a flag kept in the ground cells. Each view is a child placed where
## the TileMapLayer it replaces is drawn, so the order of layers is kept.
## Within the sprite layer, a TileMapLayer draws 16-cell blocks by rows
## (top first, right block first) and cells in a block by columns: a GPU cell
## is drawn before every sprite on the layer, so a cell that a sprite drawn
## earlier overlaps stays on the TileMapLayer (pins), unless it draws nothing.
## Cells: id in R and the low 4 bits of G; G's top bit is the tide flag.
const GPU_SHADER := "shader_type canvas_item; uniform sampler2D cells : filter_nearest; uniform sampler2D table : filter_nearest; uniform sampler2D page0 : filter_nearest; uniform sampler2D page1 : filter_nearest; uniform sampler2D page2 : filter_nearest; uniform sampler2D page3 : filter_nearest; uniform highp vec2 cells_origin; uniform highp vec2 cells_size; uniform highp vec2 page_size; varying highp vec2 spos; varying flat highp vec4 m0; varying flat highp vec4 m1; varying flat highp vec4 m3; varying vec4 tint; highp vec2 snapped(highp vec2 w){return floor((mat4(m0,m1,vec4(0.0,0.0,1.0,0.0),m3)*vec4(w,0.0,1.0)).xy+0.5);} void vertex(){highp mat4 m=CANVAS_MATRIX*MODEL_MATRIX; spos=floor((m*vec4(VERTEX,0.0,1.0)).xy+0.5); m0=m[0]; m1=m[1]; m3=m[3]; tint=COLOR;} void fragment(){highp vec2 p=floor(spos)+0.5; highp vec2 scl=vec2(m0.x,m1.y); highp vec2 off=m3.xy; highp vec2 cell=floor((p-off)/scl/16.0); highp vec2 e0=snapped(cell*16.0); highp vec2 e1=snapped((cell+1.0)*16.0); cell+=step(e1,p)-(1.0-step(e0,p)); e0=snapped(cell*16.0); e1=snapped((cell+1.0)*16.0); highp vec2 at=cell-cells_origin; if(at.x<0.0||at.y<0.0||at.x>=cells_size.x||at.y>=cells_size.y) discard; vec4 c=texelFetch(cells,ivec2(at),0); int id=int(c.r*255.0+0.5)+(int(c.g*255.0+0.5)&15)*256; if(id==0) discard; highp vec4 row=texelFetch(table,ivec2(id%256,id/256),0); highp vec2 pos=row.xy; highp vec2 uv=clamp((pos+(p-e0)/(e1-e0)*16.0)/page_size+1e-5,(pos+0.5)/page_size,(pos+15.5)/page_size); int page=int(row.z+0.5); vec4 col; if(page==0) col=textureLod(page0,uv,0.0); else if(page==1) col=textureLod(page1,uv,0.0); else if(page==2) col=textureLod(page2,uv,0.0); else col=textureLod(page3,uv,0.0); COLOR=tint*col;}"
const GPU_TABLE_WIDTH := 256
const GPU_MAX_IDS := 4096
const GPU_PAGES := 4
## Shoreline: 8x8 pieces snapped like 8x8 tiles. Per cell, an ocean (R) and a
## tidal (G) shore id; per id and quadrant (table), the piece's frame-0 place
## on its sheet (B: 1 outer, 2 inner, 0 none). Frames are a fixed stride apart.
## Like the animated tiles' shader it replaces (which reads UV before Godot
## adds its 1e-5 snap offset), a pixel exactly on a texel edge takes the
## texel before it.
const SHORE_SHADER := "shader_type canvas_item; uniform sampler2D cells : filter_nearest; uniform sampler2D table : filter_nearest; uniform sampler2D outer : filter_nearest; uniform sampler2D inner : filter_nearest; uniform highp vec2 cells_origin; uniform highp vec2 cells_size; uniform highp vec2 outer_size; uniform highp vec2 inner_size; uniform int channel; uniform int frame; varying highp vec2 spos; varying flat highp vec4 m0; varying flat highp vec4 m1; varying flat highp vec4 m3; varying vec4 tint; highp vec2 snapped(highp vec2 w){return floor((mat4(m0,m1,vec4(0.0,0.0,1.0,0.0),m3)*vec4(w,0.0,1.0)).xy+0.5);} void vertex(){highp mat4 m=CANVAS_MATRIX*MODEL_MATRIX; spos=floor((m*vec4(VERTEX,0.0,1.0)).xy+0.5); m0=m[0]; m1=m[1]; m3=m[3]; tint=COLOR;} void fragment(){highp vec2 p=floor(spos)+0.5; highp vec2 scl=vec2(m0.x,m1.y); highp vec2 off=m3.xy; highp vec2 q=floor((p-off)/scl/8.0); highp vec2 e0=snapped(q*8.0); highp vec2 e1=snapped((q+1.0)*8.0); q+=step(e1,p)-(1.0-step(e0,p)); e0=snapped(q*8.0); e1=snapped((q+1.0)*8.0); highp vec2 cell=floor(q*0.5); highp vec2 at=cell-cells_origin; if(at.x<0.0||at.y<0.0||at.x>=cells_size.x||at.y>=cells_size.y) discard; vec4 c=texelFetch(cells,ivec2(at),0); int id=int((channel==0?c.r:c.g)*255.0+0.5); if(id==0) discard; ivec2 sub=ivec2(q-cell*2.0); vec4 row=texelFetch(table,ivec2(id,sub.x+sub.y*2),0); int sheet=int(row.b*255.0+0.5); if(sheet==0) discard; highp vec2 size=sheet==1?outer_size:inner_size; highp vec2 pos=floor(row.rg*255.0+0.5); pos.x+=float(frame)*floor(size.x/7.0); highp vec2 uv=clamp((pos+(p-e0)/(e1-e0)*8.0)/size-1e-5,(pos+0.5)/size,(pos+7.5)/size); vec4 col; if(sheet==1) col=textureLod(outer,uv,0.0); else col=textureLod(inner,uv,0.0); COLOR=tint*col;}"
const SHORE_MAX_IDS := 256
## Beach tide: water2 at half alpha over the cells flagged in the ground
## cells (texel edges as in the shoreline shader).
const TIDE_SHADER := "shader_type canvas_item; uniform sampler2D cells : filter_nearest; uniform sampler2D water : filter_nearest; uniform highp vec2 cells_origin; uniform highp vec2 cells_size; uniform highp vec2 water_size; uniform int frame; varying highp vec2 spos; varying flat highp vec4 m0; varying flat highp vec4 m1; varying flat highp vec4 m3; varying vec4 tint; highp vec2 snapped(highp vec2 w){return floor((mat4(m0,m1,vec4(0.0,0.0,1.0,0.0),m3)*vec4(w,0.0,1.0)).xy+0.5);} void vertex(){highp mat4 m=CANVAS_MATRIX*MODEL_MATRIX; spos=floor((m*vec4(VERTEX,0.0,1.0)).xy+0.5); m0=m[0]; m1=m[1]; m3=m[3]; tint=COLOR;} void fragment(){highp vec2 p=floor(spos)+0.5; highp vec2 scl=vec2(m0.x,m1.y); highp vec2 off=m3.xy; highp vec2 cell=floor((p-off)/scl/16.0); highp vec2 e0=snapped(cell*16.0); highp vec2 e1=snapped((cell+1.0)*16.0); cell+=step(e1,p)-(1.0-step(e0,p)); e0=snapped(cell*16.0); e1=snapped((cell+1.0)*16.0); highp vec2 at=cell-cells_origin; if(at.x<0.0||at.y<0.0||at.x>=cells_size.x||at.y>=cells_size.y) discard; vec4 c=texelFetch(cells,ivec2(at),0); if((int(c.g*255.0+0.5)&128)==0) discard; highp vec2 pos=vec2(float(frame)*16.0,0.0); highp vec2 uv=clamp((pos+(p-e0)/(e1-e0)*16.0)/water_size-1e-5,(pos+0.5)/water_size,(pos+15.5)/water_size); COLOR=tint*textureLod(water,uv,0.0);}"
const GPU_TIDE := 0x8000
var gpu_cells: Image
## The cells' bytes (R, G per cell), copied into gpu_cells when sent: writing
## bytes costs far less than set_pixel on 400k cells.
var gpu_bytes := PackedByteArray()
var gpu_width := 0
var gpu_height := 0
var gpu_cells_texture: ImageTexture
var gpu_cells_dirty := false
var gpu_table: Image
var gpu_table_texture: ImageTexture
var gpu_table_dirty := false
var gpu_view: Node2D
var gpu_pages_bound := 0
## Tile kind key -> id (row in gpu_table; 0 means "not on the GPU").
var gpu_ids := {}
## Per id: {"pos", "page"} and, for animated kinds, {"spec_key", "region"}.
var gpu_rows: Array = [{}]
var gpu_animated: Array[int] = []
## The animation clock and row count _update_gpu_animations last ran with:
## the rows follow only the source and flower clocks, not the shore one.
var gpu_animation_clock: Array = []
var gpu_animation_rows := -1
## Ground with no upper name: [color][name] -> id, so most cells skip the spec work.
var gpu_fast: Array = [{}, {}]
var upper_spec_empty := {}
## What cells of one tile kind (base name, upper name, color) draw on this
## stream, settled once per kind by _resolve_kind: a GPU id (> 0), KIND_EMPTY
## (nothing), KIND_SPRITE (a TileMapLayer sprite: kind_sprites) or KIND_SLOW (the
## cell is settled by _redraw_cells).
const KIND_SLOW := -1
const KIND_EMPTY := 0
const KIND_SPRITE := -2
const KIND_UNKNOWN := -3
var kinds := {}
## Kind -> [spec, atlas source id, whether the sprite stays inside its cell,
## whether a tree may need drawing again in front of a mountain].
var kind_sprites := {}
## String id -> whether the string names a mountain or a ledge (cached).
var mountain_strings := {}
const TREE_OFFSETS := [Vector2i.ZERO, Vector2i.UP, Vector2i.DOWN, Vector2i.LEFT, Vector2i.RIGHT]
## Map blocks holding UpperView cells: it covers only those.
var gpu_blocks := {}
var tide_view: Node2D
var tide_blocks := {}
## Cells a sprite drawn before them overlaps: cell -> number of such sprites.
var pins := {}
## Sprite cell -> the cells it pins.
var pinned_by := {}
var shore_cells: Image
var shore_bytes := PackedByteArray()
var shore_cells_texture: ImageTexture
var shore_cells_dirty := false
var shore_table: Image
var shore_table_texture: ImageTexture
var shore_table_dirty := false
## [ocean view, tidal view] and the map blocks each covers.
var shore_views: Array = []
var shore_blocks: Array = [{}, {}]
## The shore sheets as shoreline_quads returns them.
var shore_sources: Array = []
## Shore string -> id (-1: drawn by the TileMapLayers); per id (0 is none),
## four [sheet, frame-0 position]; quads (as text) -> id.
var shore_ids := {}
var shore_rows: Array = []
var shore_keys := {}
## Some shoreline ran out of ids and is on the TileMapLayers.
var shore_fallback := false

## (name, biome, route) ids -> _is_beach_high_tide, for tide_kinds_store.
var tide_kinds := {}
var tide_kinds_store: WorldTileStore

func queue_tide_refresh(cells: Array):
    var center = Vector2i(tracked_player.global_position/float(tile_size))
    var store: WorldTileStore = source_tiles if source_tiles is WorldTileStore else null
    if store != tide_kinds_store:
        tide_kinds_store = store
        tide_kinds.clear()
    for cell in cells:
        var key = cell*tile_size if source_keys_are_pixels else cell
        # From the store's arrays: a tile proxy per cell (~15 us) was half the
        # cost of a tide turn's frames. Beach tide reads name, biome and route.
        var index := -1 if store == null else store.index_of(key)
        if index >= 0:
            resident_fingerprints.fp_put(key, store.revision_at(index) + 1)
            var kind := Vector3i(store.name_ids[index], store.biome_ids[index], store.route_ids[index])
            if not tide_kinds.has(kind): tide_kinds[kind] = _is_beach_high_tide(store.cursor(index))
            if tide_kinds[kind]: frame_tidal_cells[cell] = true
            else: frame_tidal_cells.erase(cell)
        elif source_tiles.has(key):
            var tile = source_tiles.tile(key)
            resident_fingerprints.fp_put(key, _fingerprint(key))
            if _is_beach_high_tide(tile): frame_tidal_cells[cell] = true
            else: frame_tidal_cells.erase(cell)
        for y in range(-1 if draw_upper else 0,2 if draw_upper else 1):
            for x in range(-1 if draw_upper else 0,2 if draw_upper else 1):
                var at = cell+Vector2i(x,y)
                if absi(at.x-center.x)<40 and absi(at.y-center.y)<30: pending_tide_near[at]=true
                else:
                    pending_tide_far[at]=true
                    far_tide_queued_at=Time.get_ticks_msec()

func _flush_tide_budget():
    var deadline = Time.get_ticks_usec()+1500
    # Tiles near the player change at once, so the tide is seen moving.
    while not pending_tide_near.is_empty():
        var batch = {}
        for cell in pending_tide_near:
            batch[cell]=true
            if batch.size()>=8: break
        for cell in batch: pending_tide_near.erase(cell)
        _redraw_cells(batch)
        if Time.get_ticks_usec()>=deadline: return
    # Far tiles are out of sight. Changing a few of them every frame, scattered
    # along every coast, made the engine rebuild many map blocks per frame for
    # the whole fifteen seconds of a tide change - a drop to 20 fps on every
    # device with nothing to see. They now wait until the tide has finished
    # queueing, and are then done one map block at a time, nearest first.
    # With blocks drawn as the view nears them, a far block is only marked
    # stale and redrawn when it comes near (a block not drawn yet is drawn as
    # it is then anyway): nothing is spent on coasts nobody looks at.
    if lazy_blocks:
        # Once the tide has finished queueing, as before: marking them as
        # they came made every frame of the change look for stale blocks.
        if pending_tide_far.is_empty() or Time.get_ticks_msec()-far_tide_queued_at<1500: return
        for cell in pending_tide_far:
            var block := Vector2i(cell.x >> 4, cell.y >> 4)
            if not built_blocks.has(block): continue
            if not stale_tide.has(block): stale_tide[block] = {}
            stale_tide[block][cell] = true
        if not pending_tide_far.is_empty(): drawn_view = Rect2i()
        pending_tide_far.clear()
        return
    if far_tide_groups.is_empty():
        if pending_tide_far.is_empty() or Time.get_ticks_msec()-far_tide_queued_at<1500: return
        if not is_instance_valid(tracked_player): return
        var block = TILE_BLOCK
        for cell in pending_tide_far:
            var group = Vector2i(floori(float(cell.x)/block),floori(float(cell.y)/block))
            if not far_tide_groups.has(group): far_tide_groups[group]=[]
            far_tide_groups[group].append(cell)
        pending_tide_far.clear()
        var center = Vector2i(tracked_player.global_position/float(tile_size))/block
        far_tide_order = far_tide_groups.keys()
        far_tide_order.sort_custom(func(a,b): return (a-center).length_squared()<(b-center).length_squared())
        return
    # One block every few frames: these tiles are out of sight, and a block
    # on every frame kept the frame rate down for half a minute afterwards.
    far_tide_wait -= 1
    if far_tide_wait > 0: return
    far_tide_wait = 6
    var group = far_tide_order[0]
    var cells: Array = far_tide_groups[group]
    while not cells.is_empty():
        var batch = {}
        while not cells.is_empty() and batch.size()<16: batch[cells.pop_back()]=true
        _redraw_cells(batch)
        if Time.get_ticks_usec()>=deadline: break
    if cells.is_empty():
        far_tide_groups.erase(group)
        far_tide_order.pop_front()

func _reward_composite(spec):
    var key = str(spec)
    if reward_composites.has(key): return reward_composites[key]
    var reward: Texture2D = _world_data().texture_for("pokeball1")
    var bounds := Rect2(0,0,16,16)
    if not spec.is_empty(): bounds = bounds.merge(Rect2(spec.get("offset",Vector2.ZERO),spec.region.size))
    var image := Image.create(int(bounds.size.x),int(bounds.size.y),false,Image.FORMAT_RGBA8)
    image.fill(Color.TRANSPARENT)
    if not spec.is_empty():
        image.blend_rect(TexturePixels.of(spec.texture),Rect2i(spec.region),Vector2i(spec.get("offset",Vector2.ZERO)-bounds.position))
    image.blend_rect(TexturePixels.of(reward),Rect2i(0,0,16,16),Vector2i(-bounds.position))
    var combined = {"texture":TexturePixels.texture_from(image),"region":Rect2(Vector2.ZERO,bounds.size),"offset":bounds.position}
    reward_composites[key] = combined
    return combined

func configure(tiles, player_node, upper_layer, source_tile_size = 16, pixel_keys = false, deferred_build = false):
    last_source_parts.clear()
    last_source_id = -1
    source_tiles = tiles
    tracked_player = player_node
    draw_upper = upper_layer
    tile_size = source_tile_size
    source_keys_are_pixels = pixel_keys
    texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
    resident_fingerprints = CellFingerprints.new(_source_bounds(), tile_size if source_keys_are_pixels else 1)
    resident_tileset = TileSet.new()
    resident_tileset.tile_size = Vector2i(tile_size, tile_size)
    resident_shader = Shader.new()
    resident_shader.code = "shader_type canvas_item; uniform highp vec2 uv_shift; uniform highp vec2 sample_min; uniform highp vec2 sample_max; varying vec4 tint; varying highp vec2 source_uv; void vertex(){tint=COLOR; source_uv=UV;} void fragment(){highp vec2 sample_uv=clamp(source_uv+uv_shift,sample_min,sample_max); COLOR=tint*texture(TEXTURE,sample_uv);}"
    # Four ocean quadrants, four tidal quadrants, terrain, tide, reward, canopy.
    for index in range(12):
        var layer := TileMapLayer.new()
        layer.tile_set = resident_tileset
        layer.collision_enabled = false
        layer.navigation_enabled = false
        # A changed tile makes the engine rebuild its whole block. At 32 that
        # was 1,024 tiles per change, and a tide change (many tiles a frame,
        # for fifteen seconds) held every device at 15-30 fps. A block of 16
        # is a quarter of the work; with tiles on a shared sheet the extra
        # blocks cost only a few more draw calls.
        layer.rendering_quadrant_size = TILE_BLOCK
        add_child(layer)
        resident_layers.append(layer)
    # A deferred build prepares the sources in build_resident_async, a slice of
    # a frame at a time (it took ~50-100 ms in one frame here, per stream).
    if deferred_build: return
    _prepare_sources()
    refresh_now()

## The time at which _pause waits for the next frame (0: never), and whether
## _prepare_sources is done.
var setup_deadline := 0
var sources_ready := false
const SETUP_SLICE_USEC := 12000

## Waits for the next frame once the slice that setup_deadline ends is used up
## (never when it is 0: the setup then runs in one go).
func _pause() -> void:
    if setup_deadline > 0 and Time.get_ticks_usec() >= setup_deadline:
        await get_tree().process_frame
        setup_deadline = Time.get_ticks_usec() + SETUP_SLICE_USEC

## The GPU images and every atlas source kept for later, in the order that
## hands out the same atlas source ids whether or not the setup is sliced.
func _prepare_sources() -> void:
    if tile_size == 16: _prepare_gpu()
    await _pause()
    await _prepare_tide_sources()
    if draw_upper:
        var names: Array = preload("res://scripts/field_move_data.gd").CRACKED_LOOT.keys()
        names.append("cactus2_cacturne")
        for name in names:
            _install(-1,Vector2i.ZERO,_world_data().render_spec({"base":"desert4","upper":name},true))
            await _pause()
    await _prepare_dig_sources()
    if draw_upper:
        # Harvesting must reuse atlas sources: adding one during play makes
        # Godot rebuild every populated quadrant in the shared TileSet.
        for berry in ["aspear", "cheri", "chesto", "lum", "pecha", "persim", "rawst"]:
            for state in ["full", "empty"]:
                for colored in [false, true]:
                    _install(-1, Vector2i.ZERO, _cached_render_spec({"base":"green1", "upper":"berrytree_%s_%s" % [berry, state], "color":colored}))
            await _pause()
    sources_ready = true

func build_resident_async():
    # The whole map's data now; its cells are drawn one map block at a time
    # as the view comes near (_draw_near_view). Drawing every block before
    # play took ~10 s of a load, mostly for blocks nobody would see soon.
    set_process(false)
    resident_build_count += 1
    # What configure left for here (the GPU images, the atlas sources), the scan
    # of the map and the tile kinds it holds: SETUP_SLICE_USEC of each frame.
    setup_deadline = Time.get_ticks_usec() + SETUP_SLICE_USEC
    await _prepare_sources()
    var store: WorldTileStore = source_tiles
    # The fingerprints have the store's bounds (_source_bounds): one value
    # per store index, filled here in a local and handed over once.
    var flags := store.flags
    var revisions := store.revisions
    var names := store.name_ids
    var uppers := store.upper_ids
    var biomes := store.biome_ids
    var routes := store.route_ids
    var values := PackedInt32Array()
    values.resize(flags.size())
    var count := 0
    # Which base and upper names the map uses (string ids), for _warm_kinds: bit 0
    # when plain, bit 1 when colored.
    var seen_names := PackedByteArray()
    seen_names.resize(store.strings.size())
    var seen_uppers := PackedByteArray()
    seen_uppers.resize(store.strings.size())
    # Beach tide reads a cell's name, biome and route: settled once per triple.
    var tidal_names := {}
    for id in store.strings.size():
        if store.strings[id].containsn("_tidalwater"): tidal_names[id] = true
    var beach := {}
    for index in flags.size():
        if flags[index] & WorldTileStore.PRESENT:
            values[index] = revisions[index] + 1
            count += 1
            var colored := 2 if flags[index] & WorldTileStore.COLOR else 1
            seen_names[names[index]] |= colored
            seen_uppers[uppers[index]] |= colored
            if tidal_names.has(names[index]):
                var kind := Vector3i(names[index], biomes[index], routes[index])
                if not beach.has(kind): beach[kind] = _is_beach_high_tide(store.cursor(index))
                if beach[kind]: frame_tidal_cells[Vector2i(index % store.width, index / store.width) + store.origin] = true
        if (index & 4095) == 0: await _pause()
    resident_fingerprints.values = values
    resident_fingerprints.count = count
    await _warm_kinds(seen_names, seen_uppers)
    setup_deadline = 0
    lazy_blocks = true
    resident_dirty = false
    # After the camera has moved this frame, so the view drawn is the one shown.
    process_priority = 1000
    set_process(true)
    await get_tree().process_frame

## Draws the blocks in view before the loading screen goes, a few per frame.
## From then on a block coming into view is drawn in that same frame.
## Nothing is drawn headless (the dedicated server).
func draw_view_async() -> void:
    while lazy_blocks and DisplayServer.get_name() != "headless" and not _draw_blocks_in(_view_blocks(), 13000):
        await get_tree().process_frame
    view_armed = lazy_blocks

## The map blocks under the view and VIEW_MARGIN_CELLS around it. The view
## is the camera's and the player's (a teleport moves the player before the camera).
## After a jump the camera is a view away or more: then only the player's view
## counts (the camera is there next frame), not every block between the two.
func _view_blocks() -> Rect2i:
    var shown := get_global_transform_with_canvas().affine_inverse() * get_viewport().get_visible_rect()
    if is_instance_valid(tracked_player):
        var players := Rect2(to_local(tracked_player.global_position) - shown.size / 2.0, shown.size)
        var gap := (players.get_center() - shown.get_center()).abs()
        shown = shown.merge(players) if gap.x < shown.size.x and gap.y < shown.size.y else players
    return _blocks_under(shown)

func _blocks_under(shown: Rect2) -> Rect2i:
    shown = shown.grow(VIEW_MARGIN_CELLS * tile_size)
    var span := float(tile_size * TILE_BLOCK)
    var first := Vector2i((shown.position / span).floor())
    var last := Vector2i((shown.end / span).floor())
    return Rect2i(first, last - first + Vector2i.ONE)

## Draws, from now on, the blocks of the view at a place it is about to jump
## to (a teleport, leaving a building): a few ms of each frame, so that the
## jump finds them drawn instead of drawing them all in its own frame.
func prepare_view(world_position: Vector2) -> void:
    if not lazy_blocks or DisplayServer.get_name() == "headless": return
    var shown := get_global_transform_with_canvas().affine_inverse() * get_viewport().get_visible_rect()
    prepared_blocks = _blocks_under(Rect2(to_local(world_position) - shown.size / 2.0, shown.size))

## Frames until the next look at where the way out of the building is.
var off_map_wait := 0

## Prepares the view of the cell the world says the way out of the area the
## player is in leads to (area_return_cells), so leaving finds it drawn.
func _prepare_way_out() -> void:
    var world: Node = tracked_player.get_parent() if is_instance_valid(tracked_player) else null
    if world == null: return
    var area: Variant = world.get("active_area_id")
    var returns: Variant = world.get("area_return_cells")
    if not area is String or not returns is Dictionary or area == "OVERWORLD": return
    var home: Variant = (returns as Dictionary).get("%s_RETURN" % area)
    if home is Vector2i:
        var cell: Vector2i = home
        prepare_view(Vector2(cell * tile_size) + Vector2(tile_size, tile_size) / 2.0)

## Follows the view: its speed, smoothed, or none after a jump.
func _track_view(delta: float) -> void:
    if not is_instance_valid(tracked_player): return
    var center := to_local(tracked_player.global_position)
    if view_center_known and delta > 0.0:
        var step := center - view_center
        view_speed = Vector2.ZERO if step.length() > 64.0 else view_speed.lerp(step / delta, 0.1)
    view_center = center
    view_center_known = true

## The blocks to have drawn round the view: AHEAD_BLOCKS on every side and,
## the way the view is moving, up to AHEAD_LEAD_SECONDS of travel.
func _ahead_blocks(near: Rect2i) -> Rect2i:
    var span := float(tile_size * TILE_BLOCK)
    var lead := view_speed * AHEAD_LEAD_SECONDS / span
    var more := AHEAD_LEAD_BLOCKS - AHEAD_BLOCKS
    var east := clampi(ceili(lead.x - 0.3), 0, more)
    var west := clampi(ceili(-lead.x - 0.3), 0, more)
    var south := clampi(ceili(lead.y - 0.3), 0, more)
    var north := clampi(ceili(-lead.y - 0.3), 0, more)
    var ahead := near.grow(AHEAD_BLOCKS)
    return Rect2i(ahead.position - Vector2i(west, north), ahead.size + Vector2i(west + east, north + south))

## The time a frame may spend drawing ahead: while the view moves, the nearer
## the first undrawn block to it, the more; standing still, the least.
func _ahead_budget(near: Rect2i) -> int:
    var ring := AHEAD_BUDGETS_USEC.size()
    if view_speed.length_squared() > 64.0:
        ring = 1
        while ring < AHEAD_BUDGETS_USEC.size() and _undrawn_in(near.grow(ring), true).is_empty():
            ring += 1
    return AHEAD_BUDGETS_USEC[ring - 1]

## The blocks that hold the map's cells.
func _map_blocks() -> Rect2i:
    if map_blocks.has_area(): return map_blocks
    var store: WorldTileStore = source_tiles
    var first := Vector2i(floori(store.origin.x / float(TILE_BLOCK)), floori(store.origin.y / float(TILE_BLOCK)))
    var last := Vector2i(floori((store.origin.x + store.width - 1) / float(TILE_BLOCK)), floori((store.origin.y + store.height - 1) / float(TILE_BLOCK)))
    map_blocks = Rect2i(first, last - first + Vector2i.ONE)
    return map_blocks

var map_blocks := Rect2i()

## The blocks of a rectangle that are not drawn (or not drawn whole, or have
## tide changes to draw), inside the map. first_only: just look for one.
func _undrawn_in(blocks: Rect2i, first_only := false) -> Array[Vector2i]:
    blocks = blocks.intersection(_map_blocks())
    var todo: Array[Vector2i] = []
    for y in range(blocks.position.y, blocks.end.y):
        for x in range(blocks.position.x, blocks.end.x):
            var block := Vector2i(x, y)
            if not built_blocks.has(block) or partial_blocks.has(block) or stale_tide.has(block):
                todo.append(block)
                if first_only: return todo
    return todo

## Draws the undrawn blocks of a rectangle of blocks, nearest the middle
## first, until budget_usec runs out (< 0: all). True when all are drawn.
## A block is drawn a few rows at a time, so the clock is looked at often.
func _draw_blocks_in(blocks: Rect2i, budget_usec: int) -> bool:
    var todo := _undrawn_in(blocks)
    if todo.is_empty(): return true
    var middle := Vector2(blocks.position) + Vector2(blocks.size - Vector2i.ONE) / 2.0
    var order := PackedInt64Array()
    for block in todo:
        order.append((int((Vector2(block) - middle).length_squared() * 16.0) << 26) | ((block.x + 4096) << 13) | (block.y + 4096))
    order.sort()
    var deadline := 0 if budget_usec < 0 else Time.get_ticks_usec() + budget_usec
    for packed in order:
        if budget_usec >= 0 and Time.get_ticks_usec() >= deadline: return false
        if not _draw_block(Vector2i(((packed >> 13) & 8191) - 4096, (packed & 8191) - 4096), deadline): return false
    return true

## Draws a block, or what is left of it, until the clock (usec) passes
## deadline (0: all of it). True when the block is drawn.
func _draw_block(block: Vector2i, deadline: int = 0) -> bool:
    if built_blocks.has(block) and not partial_blocks.has(block):
        # Drawn before: only its cells the tide changed since.
        _redraw_cells(stale_tide[block])
        stale_tide.erase(block)
        return true
    # Cells changed from now on are drawn at once (_redraw_cells skips the
    # cells of blocks not drawn yet): the rows still to come draw them as they are then.
    built_blocks[block] = true
    var row: int = partial_blocks.get(block, 0)
    var rows := SLICE_ROWS if deadline > 0 else TILE_BLOCK
    while row < TILE_BLOCK:
        _draw_rows(block, row, mini(row + rows, TILE_BLOCK))
        row += rows
        if deadline > 0 and row < TILE_BLOCK and Time.get_ticks_usec() >= deadline:
            partial_blocks[block] = row
            return false
    partial_blocks.erase(block)
    if stale_tide.has(block):
        _redraw_cells(stale_tide[block])
        stale_tide.erase(block)
    return true

## Draws rows row0..row1-1 of a block for the first time (_redraw_cells with
## erase_absent false). A cell of a kind settled before (see _resolve_kind) is
## drawn here straight from the store's arrays; the others go to _redraw_cells.
func _draw_rows(block: Vector2i, row0: int, row1: int) -> void:
    var store: WorldTileStore = source_tiles
    var first := block * TILE_BLOCK
    var x0 := maxi(first.x, store.origin.x)
    var x1 := mini(first.x + TILE_BLOCK, store.origin.x + store.width)
    var y0 := maxi(first.y + row0, store.origin.y)
    var y1 := mini(first.y + row1, store.origin.y + store.height)
    if x0 >= x1 or y0 >= y1: return
    var flags := store.flags
    # gpu_bytes is indexed like the store's arrays (both cover its rectangle).
    if gpu_cells == null or gpu_width != store.width or resident_fingerprints.origin != store.origin:
        var batch := {}
        for y in range(y0, y1):
            for x in range(x0, x1):
                if flags[(y - store.origin.y) * store.width + x - store.origin.x] & WorldTileStore.PRESENT: batch[Vector2i(x, y)] = true
        if not batch.is_empty(): _redraw_cells(batch, false)
        return
    var names := store.name_ids
    var uppers := store.upper_ids
    var oceans := store.shore_ocean_ids
    # Cells next to a beach tide cell take their shoreline from _redraw_cells.
    var near := _tide_near(first, y0, y1) if draw_upper else PackedByteArray()
    var layer: TileMapLayer = resident_layers[8]
    var slow := {}
    var pin_flips := {}
    var marked := false
    for y in range(y0, y1):
        var row_at := (y - store.origin.y) * store.width - store.origin.x
        for x in range(x0, x1):
            var index := row_at + x
            var bits := flags[index]
            if not bits & WorldTileStore.PRESENT: continue
            var cell := Vector2i(x, y)
            if not pinned_by.is_empty() and pinned_by.has(cell):
                slow[cell] = true
                continue
            var key: int = names[index] | (uppers[index] << 24) | ((bits & WorldTileStore.COLOR) << 47)
            var kind: int = kinds.get(key, KIND_UNKNOWN)
            if kind == KIND_UNKNOWN: kind = _resolve_kind(key, names[index], uppers[index], (bits & WorldTileStore.COLOR) != 0)
            if kind == KIND_SLOW or (draw_upper and (oceans[index] != 0 or (not near.is_empty() and near[(y - first.y) * TILE_BLOCK + x - first.x] != 0))):
                slow[cell] = true
                continue
            var at := index * 2
            if kind > 0:
                if not pins.is_empty() and pins.has(cell) and not gpu_rows[kind].get("clear", false):
                    slow[cell] = true
                    continue
                if draw_upper and not marked:
                    marked = true
                    _mark_block(gpu_view, gpu_blocks, cell)
                if gpu_bytes[at] != (kind & 255) or gpu_bytes[at + 1] != (kind >> 8):
                    gpu_bytes[at] = kind & 255
                    gpu_bytes[at + 1] = kind >> 8
                    gpu_cells_dirty = true
                continue
            if gpu_bytes[at] != 0 or gpu_bytes[at + 1] != 0:
                gpu_bytes[at] = 0
                gpu_bytes[at + 1] = 0
                gpu_cells_dirty = true
            if kind == KIND_EMPTY: continue
            var sprite: Array = kind_sprites[key]
            if layer.get_cell_source_id(cell) != sprite[1]: layer.set_cell(cell, sprite[1], Vector2i.ZERO)
            if not sprite[2]: _pin(cell, sprite[0], pin_flips)
            if sprite[3] and _tree_before_mountain(cell):
                var front: TileMapLayer = resident_layers[11]
                if front.get_cell_source_id(cell) != sprite[1]: front.set_cell(cell, sprite[1], Vector2i.ZERO)
    if not slow.is_empty(): _redraw_cells(slow, false)
    # A cell that became pinned leaves the GPU, one no longer pinned may join it.
    var redo := {}
    for cell in pin_flips:
        if pins.has(cell) != pin_flips[cell]: redo[cell] = true
    if not redo.is_empty(): _redraw_cells(redo)

## In rows y0..y1-1 of the block at first: which cells (index (y - first.y) *
## TILE_BLOCK + x - first.x) have a beach tide cell among their neighbours,
## which gives them a shoreline. Empty when none has.
func _tide_near(first: Vector2i, y0: int, y1: int) -> PackedByteArray:
    var near := PackedByteArray()
    if frame_tidal_cells.is_empty(): return near
    for y in range(y0 - 1, y1 + 1):
        for x in range(first.x - 1, first.x + TILE_BLOCK + 1):
            if not frame_tidal_cells.has(Vector2i(x, y)): continue
            if near.is_empty(): near.resize(TILE_BLOCK * TILE_BLOCK)
            for ny in range(maxi(y - 1, y0), mini(y + 2, y1)):
                for nx in range(maxi(x - 1, first.x), mini(x + 2, first.x + TILE_BLOCK)):
                    near[(ny - first.y) * TILE_BLOCK + nx - first.x] = 1
    return near

## _mountain_tree_needs_front_redraw for a tree that is tall enough, read from
## the store's arrays: a mountain or ledge on the cell or the four beside it.
func _tree_before_mountain(cell: Vector2i) -> bool:
    var store: WorldTileStore = source_tiles
    var flags := store.flags
    var names := store.name_ids
    var uppers := store.upper_ids
    for offset in TREE_OFFSETS:
        var at: Vector2i = cell + offset - store.origin
        if at.x < 0 or at.y < 0 or at.x >= store.width or at.y >= store.height: continue
        var index := at.y * store.width + at.x
        if not flags[index] & WorldTileStore.PRESENT: continue
        if _mountainish(names[index]) or _mountainish(uppers[index]): return true
    return false

func _mountainish(string_id: int) -> bool:
    var found: Variant = mountain_strings.get(string_id)
    if found == null:
        var text := (source_tiles as WorldTileStore).strings[string_id].to_lower()
        found = "mountain" in text or "ledges3" in text
        mountain_strings[string_id] = found
    return bool(found)

## Settles what cells of a tile kind draw on this stream, once (see kinds).
## It does the work _redraw_cells does for each cell of the kind - the render
## spec, the GPU id, the atlas source - and keeps its outcome. What depends on
## more than the kind (gates, hole rewards, beach tide, pins) stays with _redraw_cells.
func _resolve_kind(key: int, name_id: int, upper_id: int, colored: bool, remember := true) -> int:
    var store := source_tiles as WorldTileStore
    var name := store.strings[name_id]
    var upper := store.strings[upper_id]
    var kind := KIND_SLOW
    var identity := (upper if draw_upper else name).to_lower()
    if gpu_cells != null:
        var tile := {"name": name, "name_upper": upper, "base": name, "upper": upper, "color": colored, "shore_ocean": "", "is_water": false, "biome": "", "route_belongs_to": null, "has_item": ""}
        var spec: Dictionary = _cached_render_spec(tile)
        if "gate" in identity or identity.begins_with("hole1"):
            # An open gate, a reward: settled per cell by _redraw_cells; the art is made now.
            if spec.get("texture") != null: _install(-1, Vector2i.ZERO, spec)
        elif spec.is_empty():
            kind = KIND_EMPTY
        elif spec.get("texture") != null:
            var id := _gpu_id(tile, spec, identity)
            var animated := identity.begins_with("water") or identity.begins_with("lava") or identity.begins_with("flower") or identity in ["campfire1", "torch1"]
            # A plain tile drawn by the GPU is a TileMapLayer sprite where a sprite
            # drawn before it overlaps it (pins): its atlas source is made now, not then.
            if not animated: _install(-1, Vector2i.ZERO, spec)
            if id > 0:
                kind = id
            elif not animated:
                var size: Vector2 = spec["region"].size
                var corner := Vector2i((Vector2(tile_size, tile_size) - size) / 2.0 - Vector2(spec.get("offset", Vector2.ZERO)))
                var inside := Rect2(Vector2.ZERO, Vector2(tile_size, tile_size)).encloses(Rect2(Vector2(tile_size, tile_size) / 2.0 - size / 2.0 - Vector2(corner), size))
                var tall: bool = draw_upper and "tree" in (name + " " + upper).to_lower() and Vector2(spec.get("size", Vector2.ZERO)).y > float(tile_size)
                if remember: kind_sprites[key] = [spec, last_source_id, inside, tall]
                kind = KIND_SPRITE
    # Beach tide reads the cell's biome and route, and its neighbours' shoreline.
    if name.containsn("_tidalwater"): kind = KIND_SLOW
    if remember: kinds[key] = kind
    return kind

## Settles the kinds the map uses (every base name on the ground stream; every
## upper name, and every base name without one, on the sprite stream) now, behind
## the loading screen, instead of when the view first meets them: a tile that is new
## to the sheet draws the whole sheet page again and sends it to the graphics chip
## (~10 ms), a new atlas source makes the engine rebuild every block drawn.
## Nothing headless: the dedicated server draws nothing.
func _warm_kinds(seen_names: PackedByteArray, seen_uppers: PackedByteArray) -> void:
    if gpu_cells == null or DisplayServer.get_name() == "headless": return
    for color_bit in [1, 2]:
        for id in seen_names.size():
            if not seen_names[id] & color_bit: continue
            _resolve_kind(id | ((color_bit - 1) << 48), id, 0, color_bit == 2)
            await _pause()
        if not draw_upper: continue
        for id in range(1, seen_uppers.size()):
            if not seen_uppers[id] & color_bit: continue
            # The base name does not matter to an upper sprite's art.
            _resolve_kind(0, 0, id, color_bit == 2, false)
            await _pause()

## Drawing that is not for the view itself (the ring round it, a teleport's
## destination) shares FRAME_BUDGET_USEC a frame between all the streams.
static var budget_frame := -1
static var budget_spent := 0

func _draw_within_budget(blocks: Rect2i, wanted_usec: int) -> bool:
    var frame := Engine.get_process_frames()
    if frame != budget_frame:
        budget_frame = frame
        budget_spent = 0
    var started := Time.get_ticks_usec()
    var done := _draw_blocks_in(blocks, clampi(FRAME_BUDGET_USEC - budget_spent, 0, wanted_usec))
    budget_spent += Time.get_ticks_usec() - started
    return done

## Once armed, the blocks in view are drawn at once; the ones around them
## while the frame has time, more of it the nearer they are, so that walking
## rarely meets an undrawn one.
func _draw_near_view(delta: float) -> void:
    if not lazy_blocks or DisplayServer.get_name() == "headless": return
    _track_view(delta)
    var preparing := prepared_blocks.has_area()
    if preparing and _draw_within_budget(prepared_blocks, PREPARE_BUDGET_USEC): prepared_blocks = Rect2i()
    var near := _view_blocks()
    # Inside a building or a cave (the view is off the map), the blocks round
    # the way out are drawn already; a few seconds after a save is loaded from
    # inside one, they are not.
    if not near.intersects(_map_blocks()):
        off_map_wait -= 1
        if off_map_wait <= 0:
            off_map_wait = 30
            _prepare_way_out()
    var ahead := _ahead_blocks(near)
    if ahead == drawn_view: return
    var started := Time.get_ticks_usec()
    if view_armed: _draw_blocks_in(near, -1)
    # A frame that had to draw the view's own blocks leaves the rest to later ones.
    if Time.get_ticks_usec() - started > 2000: return
    if _draw_within_budget(ahead, _ahead_budget(near)): drawn_view = ahead

func _prepare_tide_sources() -> void:
    # Prepare every shoreline corner once. Tide changes then reuse atlas sources
    # rather than changing the shared TileSet and invalidating the whole map.
    if draw_upper:
        var directions = ["N","S","E","W","NE","NW","SE","SW"]
        for mask in range(256):
            var shore = ""
            for bit in range(8):
                if mask & (1 << bit): shore += "["+directions[bit]+"]"
            if shore.is_empty(): continue
            var quads = _world_data().shoreline_quads(shore,0)
            for quadrant in range(quads.size()):
                var quad = quads[quadrant]
                for tint in [Color.WHITE,Color(1,1,1,0.5)]:
                    _install(-1,Vector2i.ZERO,{"texture":quad.texture,"region":quad.source,"offset":quad.offset},tint,["shore",shore,quadrant])
            await _pause()
    else:
        var prepared = {}
        var named := {}
        for index in (source_tiles as WorldTileStore).with_name_containing("_tidal"):
            # Each name once (thousands of cells share a few names).
            var name_id: int = (source_tiles as WorldTileStore).name_ids[index]
            if named.has(name_id): continue
            named[name_id] = true
            var name = (source_tiles as WorldTileStore).name_at(index)
            if not "_tidal" in name: continue
            for next_name in [name.replace("_tidalwater","_tidaloff"),name.replace("_tidaloff","_tidalwater")]:
                if prepared.has(next_name): continue
                prepared[next_name]=true
                var spec = _world_data().render_spec({"base":next_name,"upper":""},false)
                _install(-1,Vector2i.ZERO,spec)
            await _pause()
        _install(-1,Vector2i.ZERO,{"texture":_world_data().texture_for("water2"),"region":Rect2(0,0,16,16)},Color(1,1,1,0.5),["tide","",0])

func _refresh_visible_rect(_force):
    pass

func _draw():
    pass

func invalidate_tiles():
    resident_dirty = true

func refresh_changed_tiles(cells: Array):
    if source_tiles.size() != resident_fingerprints.size():
        refresh_now()
        return
    var affected = cells.duplicate()
    affected.append_array(open_gate_cells.keys())
    affected.append_array(resident_open_gates.keys())
    if not affected.is_empty(): refresh_now(affected)

func _process(delta):
    super._process(delta)
    _draw_near_view(delta)
    TileSheet.flush()
    _flush_gpu()
    _flush_tide_budget()
    if resident_dirty:
        resident_dirty = false
        var cells: Array = []
        for key in SourceTile.resident_changed_cells:
            if source_tiles.has(key if source_keys_are_pixels else Vector2i(key / tile_size)):
                cells.append(Vector2i(key / tile_size))
        refresh_changed_tiles(cells)
    var clock = [source_animation_signature,shore_animation_frame,flower_animation_frame,posmod(int(source_animation_tick/19),2)]
    if clock == resident_animation_clock: return
    resident_animation_clock = clock
    _update_gpu_animations()
    for view in shore_views: (view.material as ShaderMaterial).set_shader_parameter("frame", shore_animation_frame)
    if tide_view != null: (tide_view.material as ShaderMaterial).set_shader_parameter("frame", clock[3])
    for animation in resident_animations:
        # Shore pieces are on the GPU unless some ran out of ids.
        if animation[0] == "shore_region" and shore_cells != null and not shore_fallback: continue
        var region: Rect2
        if animation[0] == "tile":
            region = _cached_render_spec(animation[1]).get("region", animation[3])
        elif animation[0] == "shore_region":
            region = Rect2(animation[1]+Vector2(shore_animation_frame*animation[2],0),Vector2(8,8))
        else:
            region = Rect2(posmod(int(source_animation_tick / 19), 2) * tile_size, 0, 16, 16)
        if region == animation[6]: continue
        animation[6] = region
        animation[4].set_shader_parameter("uv_shift", (region.position - animation[3].position) / animation[5])
        animation[4].set_shader_parameter("sample_min", (region.position+Vector2(0.5,0.5))/animation[5])
        animation[4].set_shader_parameter("sample_max", (region.end-Vector2(0.5,0.5))/animation[5])

func _install(layer_index, cell, spec, tint = Color.WHITE, animation = []):
    if spec.is_empty() or spec.get("texture") == null:
        return
    var texture: Texture2D = spec["texture"]
    var region: Rect2 = spec["region"]
    var offset: Vector2 = spec.get("offset", Vector2.ZERO)
    # Still tiles are drawn from the shared sheet. Animated ones keep their own
    # image: their shader moves along a strip of frames in it.
    var sheeted := false
    if animation.is_empty():
        var on_sheet: Array = TileSheet.place(texture, region)
        if not on_sheet.is_empty():
            texture = on_sheet[0]
            region = on_sheet[1]
            sheeted = true
    var animation_key = animation
    if not animation.is_empty() and animation[0] == "shore":
        var stride = texture.get_width()/7
        var base = Vector2(fposmod(region.position.x,stride),region.position.y)
        animation = ["shore_region",base,stride]
        animation_key = animation
        region.position = base
    if not animation.is_empty() and animation[0] == "tile":
        # Cells pass a {base, upper, color} key, dig previews a SourceTile.
        animation_key = ["tile", _field(animation[1], "base", _field(animation[1], "name", "")), _field(animation[1], "upper", _field(animation[1], "name_upper", "")), _field(animation[1], "color", false)]
    var parts = [texture.get_instance_id(), region if animation.is_empty() else region.size, offset, tint, animation_key]
    if last_source_id >= 0 and parts == last_source_parts:
        if layer_index >= 0:
            var cached_layer: TileMapLayer = resident_layers[layer_index]
            if cached_layer.get_cell_source_id(cell) != last_source_id:
                cached_layer.set_cell(cell,last_source_id,Vector2i.ZERO)
        return
    # The parts array itself is the key: building str(parts) for every new
    # neighbour kind was a large share of the map build.
    var id = resident_sources.get(parts, -1)
    if id < 0:
        var atlas := TileSetAtlasSource.new()
        atlas.texture = texture
        # Padding makes a private copy of the whole texture for each source,
        # which would undo the sharing; the sheet has its own gaps instead.
        atlas.use_texture_padding = animation.is_empty() and not sheeted
        atlas.margins = Vector2i(region.position)
        atlas.texture_region_size = Vector2i(region.size)
        atlas.create_tile(Vector2i.ZERO)
        var data := atlas.get_tile_data(Vector2i.ZERO, 0)
        data.texture_origin = Vector2i((Vector2(tile_size, tile_size) - region.size) / 2.0 - offset)
        data.modulate = tint
        if not animation.is_empty():
            var material := ShaderMaterial.new()
            material.shader = resident_shader
            material.set_shader_parameter("sample_min", (region.position+Vector2(0.5,0.5))/texture.get_size())
            material.set_shader_parameter("sample_max", (region.end-Vector2(0.5,0.5))/texture.get_size())
            data.material = material
            resident_animations.append([animation[0], animation[1], animation[2], region, material, texture.get_size(), region])
            resident_animation_clock.clear()
        id = resident_tileset.add_source(atlas)
        resident_sources[parts] = id
    last_source_parts = parts
    last_source_id = id
    if layer_index < 0: return
    var layer: TileMapLayer = resident_layers[layer_index]
    if layer.get_cell_source_id(cell) != id:
        layer.set_cell(cell, id, Vector2i.ZERO)

func refresh_now(changed_hint: Array = []):
    if resident_layers.is_empty():
        return
    resident_dirty = false
    resident_build_count += 1
    # Detect authored edits independently of the camera. Resolve only affected
    # cells and their neighbours (shorelines and tree foreground rules).
    var first_build := resident_fingerprints.is_empty()
    var current = resident_fingerprints.blank() if changed_hint.is_empty() else resident_fingerprints
    var changed := {}
    var keys = source_tiles.keys() if changed_hint.is_empty() else changed_hint.map(func(cell): return cell * tile_size if source_keys_are_pixels else cell)
    for key in keys:
        if not source_tiles.has(key):
            current.fp_erase(key)
            changed[Vector2i(key / tile_size) if source_keys_are_pixels else key] = true
            continue
        var fingerprint := _fingerprint(key)
        if resident_fingerprints.fp_get(key) != CellFingerprints.normalized(fingerprint):
            changed[Vector2i(key / tile_size) if source_keys_are_pixels else key] = true
        current.fp_put(key, fingerprint)
    if changed_hint.is_empty():
        for key in resident_fingerprints.keys():
            if current.fp_get(key) == null: changed[Vector2i(key / tile_size) if source_keys_are_pixels else key] = true
    # Gates can change without altering tile identity.
    for cell in open_gate_cells: changed[cell] = true
    for cell in resident_open_gates: changed[cell] = true
    resident_open_gates = open_gate_cells.duplicate()
    resident_fingerprints = current
    if changed.is_empty(): return
    var affected := changed.duplicate()
    if not first_build:
        for cell in changed:
            for y in range(-1,2):
                for x in range(-1,2): affected[cell+Vector2i(x,y)] = true
    for cell in changed:
        var key = cell * tile_size if source_keys_are_pixels else cell
        # Only a *_tidalwater cell can be: a proxy for every changed cell
        # (~10 us each) was a third of a day's dig sites.
        var index: int = source_tiles.index_of(key)
        if index >= 0 and not source_tiles.name_at(index).containsn("_tidalwater"): frame_tidal_cells.erase(cell)
        elif source_tiles.has(key) and _is_beach_high_tide(source_tiles.tile(key)): frame_tidal_cells[cell] = true
        else: frame_tidal_cells.erase(cell)
    _redraw_cells(affected)

func _redraw_cells(affected: Dictionary, erase_absent: bool = true):
    # Before the GPU images and atlas sources exist (a deferred build prepares
    # them over a few frames) nothing is drawn: the blocks are drawn from the store.
    if not sources_ready: return
    var desired: Array = []
    if erase_absent:
        for index in range(12): desired.append({})
    drawing_tidal_shores = true
    var store: WorldTileStore = source_tiles
    # Read straight from the store's arrays for the common cases (these
    # copies share memory; nothing is written to the store in this loop).
    var cell_flags := store.flags
    var cell_names := store.name_ids
    var cell_uppers := store.upper_ids
    var cell_oceans := store.shore_ocean_ids
    # Cells whose pinned state these cells change: cell -> pinned before.
    var pin_flips := {}
    var origin := resident_fingerprints.origin
    for cell in affected:
        # A block not drawn yet is drawn whole, as it is then, when the view
        # nears it. (>> 4: TILE_BLOCK is 16.)
        if lazy_blocks and not built_blocks.has(Vector2i(cell.x >> 4, cell.y >> 4)): continue
        if pinned_by.has(cell): _unpin(cell, pin_flips)
        var key = cell * tile_size if source_keys_are_pixels else cell
        var index: int = store.index_of(key)
        if index < 0:
            if erase_absent: _clear_gpu_cell(cell)
            continue
        # Two thirds of the map is open sea: settle those cells by ids alone.
        if cell_uppers[index] == 0:
            var color_slot := 1 if cell_flags[index] & WorldTileStore.COLOR else 0
            if draw_upper:
                if cell_flags[index] & WorldTileStore.WATER and cell_oceans[index] == 0                         and _upper_spec_is_empty(cell_names[index], color_slot):
                    # The first build starts from empty cells.
                    if erase_absent: _clear_gpu_cell(cell)
                    continue
            elif gpu_cells != null:
                var fast: int = gpu_fast[color_slot].get(cell_names[index], 0)
                if fast > 0 and (not pins.has(cell) or gpu_rows[fast].get("clear", false)):
                    # _set_gpu_cell, inline: this runs for most of the map.
                    var at: int = ((cell.y - origin.y) * gpu_width + cell.x - origin.x) * 2
                    if gpu_bytes[at] != fast & 255 or gpu_bytes[at + 1] != fast >> 8:
                        gpu_bytes[at] = fast & 255
                        gpu_bytes[at + 1] = fast >> 8
                        gpu_cells_dirty = true
                    continue
        # The fields drawing reads, as a small Dictionary (every helper here
        # takes one): loading a SourceTile proxy per cell cost ~17 us.
        var tile := _tile_view(store, index)
        if draw_upper:
            var shores = [String(tile.shore_ocean), _active_beach_tidal_shore(cell, tile)]
            var shore_on_gpu := [0, 0] if shores[0].is_empty() and shores[1].is_empty() else _shore_ids(shores)
            if shore_cells != null and (erase_absent or shore_on_gpu != [0, 0]): _set_shore_cell(cell, shore_on_gpu)
            # Both kinds of a cell are drawn by the same layers: they overlap.
            if shore_on_gpu.is_empty() and not shore_fallback:
                shore_fallback = true
                resident_animation_clock.clear()
            for kind in range(2 if shore_on_gpu.is_empty() else 0):
                if shores[kind].is_empty(): continue
                var quads = _world_data().shoreline_quads(shores[kind], shore_animation_frame)
                for quadrant in range(quads.size()):
                    var quad = quads[quadrant]
                    var layer_index = kind * 4 + quadrant
                    _install(layer_index, cell, {"texture":quad["texture"], "region":quad["source"], "offset":quad["offset"]}, Color.WHITE if kind == 0 else Color(1,1,1,0.5), ["shore",shores[kind],quadrant])
                    if erase_absent: desired[layer_index][cell] = true
        var spec = _cached_render_spec(tile)
        var identity = String(tile.name_upper if draw_upper else tile.name).to_lower()
        if draw_upper and identity.begins_with("hole1") and not str(_field(tile,"has_item","")).is_empty():
            spec = _reward_composite(spec)
        var hidden: bool = spec.is_empty() or ("gate" in identity and open_gate_cells.has(cell))
        var tide: bool = not draw_upper and not hidden and _is_beach_high_tide(tile)
        if gpu_cells != null:
            var gpu_id := 0 if hidden else _gpu_id(tile, spec, identity)
            if gpu_id > 0 and not _gpu_allowed(cell, gpu_id): gpu_id = 0
            _set_gpu_cell(cell, gpu_id, tide)
            if gpu_id > 0: continue
        if hidden: continue
        var animation = []
        if identity.begins_with("water") or identity.begins_with("lava") or identity.begins_with("flower") or identity in ["campfire1", "torch1"]:
            animation = ["tile", {"base": tile.name, "upper": tile.name_upper, "color": tile.color}, 0]  # a name key: views are not kept
        _install(8, cell, spec, Color.WHITE, animation)
        if erase_absent: desired[8][cell] = true
        if gpu_cells != null: _pin(cell, spec, pin_flips)
        if tide and tide_view == null:
            _install(9, cell, {"texture":_world_data().texture_for("water2"),"region":Rect2(0,0,16,16)}, Color(1,1,1,0.5), ["tide","",0])
            if erase_absent: desired[9][cell] = true
        if draw_upper and _mountain_tree_needs_front_redraw(cell,tile,spec):
            _install(11, cell, spec)
            if erase_absent: desired[11][cell] = true
    drawing_tidal_shores = false
    if erase_absent:
        for index in range(12):
            var layer: TileMapLayer = resident_layers[index]
            for cell in affected:
                if not desired[index].has(cell) and layer.get_cell_source_id(cell) >= 0: layer.erase_cell(cell)
            # Godot applies changed cells together at the end of this frame.
    # A cell that became pinned leaves the GPU, one no longer pinned may join it.
    var redo := {}
    for cell in pin_flips:
        if pins.has(cell) != pin_flips[cell]: redo[cell] = true
    if not redo.is_empty(): _redraw_cells(redo)

var resident_open_gates: Dictionary = {}

func _prepare_dig_sources() -> void:
    if not draw_upper:
        for choice in preload("res://scripts/field_move_data.gd").DIG_TERRAIN:
            if choice == "CLIFF": continue
            for colored in [false, true]:
                var tile := SourceTile.new("green1", Vector2i.ZERO)
                preload("res://scripts/field_move_data.gd").apply_dig_terrain(tile, choice)
                tile.color = colored
                var spec: Dictionary = _cached_render_spec(tile)
                var animation := ["tile",tile,0] if tile.name.begins_with("flower") else []
                _install(-1,Vector2i.ZERO,spec,Color.WHITE,animation)
            await _pause()
        return
    for prefix in ["ledges3", "ledges3snow", "ledges3volcano"]:
        for suffix in ["none", "N", "NE", "E", "SE", "S", "SW", "W", "NW", "NW_inner", "NE_inner", "SW_inner", "SE_inner"]:
            for colored in [false,true]:
                _install(-1,Vector2i.ZERO,_world_data().render_spec({"base":"green1","upper":prefix+"_"+suffix,"color":colored},true))
            await _pause()
    # Adding an atlas after play starts invalidates every populated quadrant.
    # Prepare all legal joined-hole shapes (including corner fills and loot)
    # while the TileSet is still empty of world cells.
    for mask in range(16):
        var suffix := ""
        for i in range(4):
            if mask & (1 << i): suffix += ["N","S","E","W"][i]
        var corners: Array[String] = []
        for corner in ["NE","SE","SW","NW"]:
            if corner[0] in suffix and corner[1] in suffix: corners.append(corner)
        for fill in range(1 << corners.size()):
            var name := "hole1" + ("_"+suffix if not suffix.is_empty() else "")
            for i in range(corners.size()):
                if fill & (1 << i): name += "["+corners[i]+"]"
            var spec: Dictionary = _world_data().render_spec({"base":"green1","upper":name},true)
            _install(-1,Vector2i.ZERO,spec)
            _install(-1,Vector2i.ZERO,_reward_composite(spec))
            await _pause()

func _lookup_tile(key):
    var index: int = source_tiles.index_of(key)
    return null if index < 0 else _tile_view(source_tiles, index)

func _tile_view(store: WorldTileStore, index: int) -> Dictionary:
    var bits: int = store.flags[index]
    var name := store.name_at(index)
    var upper := store.upper_at(index)
    # Both key pairs: SourceWorldData.render_spec reads base/upper.
    return {"name": name, "name_upper": upper, "base": name, "upper": upper, "color": bits & WorldTileStore.COLOR != 0,
        "shore_ocean": store.shore_ocean_at(index), "is_water": bits & WorldTileStore.WATER != 0,
        "biome": store.biome_at(index), "route_belongs_to": store.route_at(index), "has_item": store.has_item_at(index)}

## The map's cells, as a rectangle (the overworld fills its rectangle).
func _source_bounds() -> Rect2i:
    var store := source_tiles as WorldTileStore
    return Rect2i(store.origin, Vector2i(store.width, store.height))

## A cell's revision in the store, plus one: it changes whenever the cell
## does. (The fingerprints store 0 as 1, so a cell's first edit, revision 0
## to 1, went unseen and the cell was not redrawn.)
func _fingerprint(key: Vector2i) -> int:
    var index: int = source_tiles.index_of(key)
    return -1 if index < 0 else source_tiles.revision_at(index) + 1

func _prepare_gpu() -> void:
    if source_tiles.is_empty(): return
    var bounds := Rect2i(resident_fingerprints.origin, Vector2i(resident_fingerprints.width, resident_fingerprints.height))
    gpu_width = bounds.size.x
    gpu_height = bounds.size.y
    gpu_bytes.resize(gpu_width * gpu_height * 2)
    gpu_cells = Image.create_from_data(gpu_width, gpu_height, false, Image.FORMAT_RG8, gpu_bytes)
    gpu_cells_texture = ImageTexture.create_from_image(gpu_cells)
    # Half floats, not RGBAF: where float textures cannot be filtered (every iPhone),
    # Godot converts an RGBAF image to half floats in place when it uploads it, and
    # every later update() is then refused for a format mismatch: the table stayed
    # all zeros and every cell drew the sheet's first tile. Positions (< 2048) and
    # pages are exact in half floats.
    gpu_table = Image.create(GPU_TABLE_WIDTH, GPU_MAX_IDS / GPU_TABLE_WIDTH, false, Image.FORMAT_RGBAH)
    gpu_table_texture = ImageTexture.create_from_image(gpu_table)
    if draw_upper:
        # Shoreline, then plain sprites: where layers 0-7 end and 8 begins.
        shore_bytes.resize(gpu_width * gpu_height * 2)
        shore_cells = Image.create_from_data(gpu_width, gpu_height, false, Image.FORMAT_RG8, shore_bytes)
        shore_cells_texture = ImageTexture.create_from_image(shore_cells)
        shore_table = Image.create(SHORE_MAX_IDS, 4, false, Image.FORMAT_RGBA8)
        shore_table_texture = ImageTexture.create_from_image(shore_table)
        for kind in range(2):
            var view := _gpu_pass(["ShoreView", "TidalShoreView"][kind], SHORE_SHADER, bounds, shore_blocks[kind], Color.WHITE if kind == 0 else Color(1, 1, 1, 0.5), resident_layers[8])
            (view.material as ShaderMaterial).set_shader_parameter("cells", shore_cells_texture)
            (view.material as ShaderMaterial).set_shader_parameter("table", shore_table_texture)
            (view.material as ShaderMaterial).set_shader_parameter("channel", kind)
            shore_views.append(view)
        _reset_shores()
        gpu_view = _gpu_pass("UpperView", GPU_SHADER, bounds, gpu_blocks, Color.WHITE, resident_layers[8])
    else:
        # The whole map, under everything.
        gpu_view = _gpu_pass("TerrainView", GPU_SHADER, bounds, null, Color.WHITE, resident_layers[0])
        tide_view = _gpu_pass("TideView", TIDE_SHADER, bounds, tide_blocks, Color(1, 1, 1, 0.5), resident_layers[9])
        (tide_view.material as ShaderMaterial).set_shader_parameter("cells", gpu_cells_texture)
        _bind_tide_water()
    var material := gpu_view.material as ShaderMaterial
    material.set_shader_parameter("cells", gpu_cells_texture)
    material.set_shader_parameter("table", gpu_table_texture)
    material.set_shader_parameter("page_size", Vector2(TileSheet.SIZE, TileSheet.SIZE))

## A view drawn by a shader over the map blocks listed in blocks (the whole
## map when null), placed just before the layer it is drawn under.
func _gpu_pass(pass_name: String, code: String, bounds: Rect2i, blocks, tint: Color, under: Node) -> Node2D:
    var view := Node2D.new()
    view.name = pass_name
    var material := ShaderMaterial.new()
    material.shader = Shader.new()
    material.shader.code = code
    material.set_shader_parameter("cells_origin", Vector2(bounds.position))
    material.set_shader_parameter("cells_size", Vector2(bounds.size))
    view.material = material
    if blocks == null:
        var area := Rect2(Vector2(bounds.position * tile_size), Vector2(bounds.size * tile_size))
        view.draw.connect(func(): view.draw_rect(area, tint))
    else:
        view.draw.connect(func(): _draw_blocks(view, blocks, tint))
    add_child(view)
    move_child(view, under.get_index())
    return view

## One rectangle per run of neighbouring blocks in a row.
func _draw_blocks(view: Node2D, blocks: Dictionary, tint: Color) -> void:
    var rows := {}
    for block in blocks:
        if not rows.has(block.y): rows[block.y] = []
        rows[block.y].append(block.x)
    var span := float(tile_size * TILE_BLOCK)
    for y in rows:
        var xs: Array = rows[y]
        xs.sort()
        var start: int = xs[0]
        for i in range(1, xs.size() + 1):
            if i < xs.size() and xs[i] == xs[i - 1] + 1: continue
            view.draw_rect(Rect2(Vector2(start, y) * span, Vector2(xs[i - 1] - start + 1, 1) * span), tint)
            if i < xs.size(): start = xs[i]

func _mark_block(view: Node2D, blocks: Dictionary, cell: Vector2i) -> void:
    var block := Vector2i(floori(cell.x / float(TILE_BLOCK)), floori(cell.y / float(TILE_BLOCK)))
    if blocks.has(block): return
    blocks[block] = true
    view.queue_redraw()

func _bind_tide_water() -> void:
    var water: Texture2D = _world_data().texture_for("water2")
    (tide_view.material as ShaderMaterial).set_shader_parameter("water", water)
    (tide_view.material as ShaderMaterial).set_shader_parameter("water_size", water.get_size())

## Forgets every shore id and binds the shore sheets.
func _reset_shores() -> void:
    shore_bytes.fill(0)
    shore_cells_dirty = true
    shore_ids = {"": 0}
    shore_rows = [null]
    shore_keys = {}
    shore_sources = [_world_data().texture_for("shore_sheet4"), _world_data().texture_for("shore1inner_sheet2")]
    for view in shore_views:
        var material := view.material as ShaderMaterial
        for sheet in range(2):
            material.set_shader_parameter(["outer", "inner"][sheet], shore_sources[sheet])
            material.set_shader_parameter(["outer_size", "inner_size"][sheet], shore_sources[sheet].get_size() if shore_sources[sheet] != null else Vector2.ONE)

## A cell's [ocean, tidal] shore ids, or [] when its shoreline stays on the
## TileMapLayers (no GPU, or out of ids).
func _shore_ids(shores: Array) -> Array:
    if shore_cells == null: return []
    var ids := []
    for shore in shores:
        if not shore_ids.has(shore): shore_ids[shore] = _new_shore_id(shore)
        var id: int = shore_ids[shore]
        if id < 0: return []
        ids.append(id)
    return ids

func _new_shore_id(shore: String) -> int:
    var quads: Array = _world_data().shoreline_quads(shore, 0)
    if quads.is_empty(): return 0
    var row := []
    for quadrant in range(4):
        var quad: Dictionary = quads[quadrant]
        var sheet := shore_sources.find(quad.texture)
        var place: Vector2 = quad.source.position
        if sheet < 0 or quad.source.size != Vector2(8, 8) or quad.offset != Vector2((quadrant % 2) * 8, (quadrant / 2) * 8): return -1
        if place.x < 0 or place.y < 0 or place.x > 255 or place.y > 255 or place != place.floor(): return -1
        row.append([sheet, place])
    var key := str(row)
    if shore_keys.has(key): return shore_keys[key]
    if shore_rows.size() >= SHORE_MAX_IDS: return -1
    var id := shore_rows.size()
    shore_rows.append(row)
    shore_keys[key] = id
    for quadrant in range(4):
        var place: Vector2 = row[quadrant][1]
        shore_table.set_pixel(id, quadrant, Color(place.x / 255.0, place.y / 255.0, (row[quadrant][0] + 1) / 255.0, 1.0))
    shore_table_dirty = true
    return id

func _set_shore_cell(cell: Vector2i, ids: Array) -> void:
    var at := _cell_at(cell)
    if at < 0: return
    var ocean: int = 0 if ids.is_empty() else ids[0]
    var tidal: int = 0 if ids.is_empty() else ids[1]
    if ocean > 0: _mark_block(shore_views[0], shore_blocks[0], cell)
    if tidal > 0: _mark_block(shore_views[1], shore_blocks[1], cell)
    if shore_bytes[at] == ocean and shore_bytes[at + 1] == tidal: return
    shore_bytes[at] = ocean
    shore_bytes[at + 1] = tidal
    shore_cells_dirty = true

## Where a cell's two bytes are in gpu_bytes and shore_bytes (-1: off the map).
func _cell_at(cell: Vector2i) -> int:
    var at := cell - resident_fingerprints.origin
    if at.x < 0 or at.y < 0 or at.x >= gpu_width or at.y >= gpu_height: return -1
    return (at.y * gpu_width + at.x) * 2

## Nothing of this cell is drawn by the GPU.
func _clear_gpu_cell(cell: Vector2i) -> void:
    if gpu_cells != null: _set_gpu_cell(cell, 0)
    if shore_cells != null: _set_shore_cell(cell, [])

## Whether a cell may be drawn by the GPU with this id: not when a sprite
## drawn before it overlaps it, unless the tile is see-through.
func _gpu_allowed(cell: Vector2i, id: int) -> bool:
    return pins.is_empty() or not pins.has(cell) or gpu_rows[id].get("clear", false)

## Whether the sprite layer draws cell a before cell b (TileMapLayer order).
func _drawn_before(a: Vector2i, b: Vector2i) -> bool:
    var block_a := Vector2i(floori(a.x / float(TILE_BLOCK)), floori(a.y / float(TILE_BLOCK)))
    var block_b := Vector2i(floori(b.x / float(TILE_BLOCK)), floori(b.y / float(TILE_BLOCK)))
    if block_a.y != block_b.y: return block_a.y < block_b.y
    if block_a.x != block_b.x: return block_a.x > block_b.x
    if a.x != b.x: return a.x < b.x
    return a.y < b.y

## A sprite reaching past its cell pins the cells it overlaps that are drawn
## after it.
func _pin(cell: Vector2i, spec: Dictionary, flips: Dictionary) -> void:
    var size: Vector2 = spec["region"].size
    var origin := Vector2i((Vector2(tile_size, tile_size) - size) / 2.0 - Vector2(spec.get("offset", Vector2.ZERO)))
    var rect := Rect2(Vector2(cell * tile_size) + Vector2(tile_size, tile_size) / 2.0 - size / 2.0 - Vector2(origin), size)
    if Rect2(Vector2(cell * tile_size), Vector2(tile_size, tile_size)).encloses(rect): return
    var pinned: Array[Vector2i] = []
    for y in range(floori(rect.position.y / tile_size), ceili(rect.end.y / tile_size)):
        for x in range(floori(rect.position.x / tile_size), ceili(rect.end.x / tile_size)):
            var other := Vector2i(x, y)
            if other == cell or not _drawn_before(cell, other): continue
            if not flips.has(other): flips[other] = pins.has(other)
            pins[other] = pins.get(other, 0) + 1
            pinned.append(other)
    if not pinned.is_empty(): pinned_by[cell] = pinned

func _unpin(cell: Vector2i, flips: Dictionary) -> void:
    for other in pinned_by[cell]:
        if not flips.has(other): flips[other] = true
        if pins[other] > 1: pins[other] -= 1
        else: pins.erase(other)
    pinned_by.erase(cell)

## The id drawing this cell on the GPU, or 0 to keep it a TileMapLayer cell
## (gates, sprites that are not a plain 16x16 tile).
func _gpu_id(tile, spec: Dictionary, identity: String) -> int:
    if spec.is_empty() or spec.get("texture") == null or "gate" in identity: return 0
    var region: Rect2 = spec.get("region", Rect2())
    if region.size != Vector2(tile_size, tile_size) or Vector2(spec.get("offset", Vector2.ZERO)) != Vector2.ZERO: return 0
    var texture: Texture2D = spec["texture"]
    var name := str(_field(tile, "name", ""))
    var upper := str(_field(tile, "name_upper", ""))
    var color := bool(_field(tile, "color", false))
    var animated := identity.begins_with("water") or identity.begins_with("lava") or identity.begins_with("flower") or identity in ["campfire1", "torch1"]
    var placed: Array = TileSheet.place(texture, region)
    if placed.is_empty(): return 0
    var key: Array = ["anim", name, upper, color] if animated else [placed[0].get_instance_id(), placed[1]]
    var id: int = gpu_ids.get(key, 0)
    if id == 0:
        if gpu_rows.size() >= GPU_MAX_IDS: return 0
        var page := _gpu_page(placed[0])
        if page < 0: return 0
        id = gpu_rows.size()
        var row := {"pos": placed[1].position, "page": page}
        # A see-through tile may be drawn in any order.
        if not animated: row["clear"] = placed[2]
        if animated:
            var spec_key := {"base": name, "upper": upper, "color": color}
            if not _gpu_place_frames(spec_key): return 0
            row["spec_key"] = spec_key
            row["region"] = region
            gpu_animated.append(id)
        gpu_rows.append(row)
        gpu_ids[key] = id
        _write_gpu_row(id)
    # Beach tide depends on more than the name: those cells take the long way.
    if not draw_upper and upper.is_empty() and not "_tidal" in name: gpu_fast[1 if color else 0][(source_tiles as WorldTileStore).sid(name)] = id
    return id

## Puts every frame of an animated kind on the sheet up front, so the
## animation never adds to (and re-uploads) a sheet page during play.
func _gpu_place_frames(spec_key: Dictionary) -> bool:
    # The frames come from the name that picks the art (the ground's base name;
    # the sprite's upper name, or its base name when it has none) and the color:
    # another upper name over the same water has the same frames.
    var upper := String(spec_key.upper)
    var frames_key := [String(spec_key.base) if not draw_upper or upper.is_empty() else upper, bool(spec_key.color)]
    if frames_placed.has(frames_key): return frames_placed[frames_key]
    if frame_ticks.is_empty():
        # The first tick of every animation signature (the clock repeats).
        var seen_signatures := {}
        for tick in range(0, 4560, SOURCE_ANIMATION_STEP):
            var signature = _animation_signature(tick)
            if seen_signatures.has(signature): continue
            seen_signatures[signature] = true
            frame_ticks.append(tick)
    var result := true
    for tick in frame_ticks:
        for flower in [0, 1]:
            var spec: Dictionary = _world_data().render_spec(spec_key, draw_upper, flower, tick)
            var region: Rect2 = spec.get("region", Rect2())
            if spec.is_empty() or spec.get("texture") == null or region.size != Vector2(tile_size, tile_size):
                result = false
            else:
                var placed: Array = TileSheet.place(spec["texture"], region)
                if placed.is_empty() or _gpu_page(placed[0]) < 0: result = false
            if not result: break
        if not result: break
    frames_placed[frames_key] = result
    return result

## [art name, color] -> whether the frames of that animated art are all on the
## sheet (_gpu_place_frames), and the ticks that start every animation signature.
var frames_placed := {}
var frame_ticks: Array = []

func _gpu_page(texture: Texture2D) -> int:
    for index in mini(TileSheet.pages.size(), GPU_PAGES):
        if TileSheet.pages[index].texture == texture: return index
    return -1

func _write_gpu_row(id: int) -> void:
    var row: Dictionary = gpu_rows[id]
    gpu_table.set_pixel(id % GPU_TABLE_WIDTH, id / GPU_TABLE_WIDTH, Color(row.pos.x, row.pos.y, row.page, 0.0))
    gpu_table_dirty = true

func _set_gpu_cell(cell: Vector2i, id: int, tide := false) -> void:
    var at := _cell_at(cell)
    if at < 0: return
    if id > 0 and draw_upper: _mark_block(gpu_view, gpu_blocks, cell)
    if tide: _mark_block(tide_view, tide_blocks, cell)
    var bits := id | (GPU_TIDE if tide else 0)
    if gpu_bytes[at] == bits & 255 and gpu_bytes[at + 1] == bits >> 8: return
    gpu_bytes[at] = bits & 255
    gpu_bytes[at + 1] = bits >> 8
    gpu_cells_dirty = true

## Animated kinds move their table row to the current frame's place. Each row
## keeps the spec of every frame it has shown, keyed as _cached_render_spec
## keys it, so a frame seen before costs no cache-key string.
func _update_gpu_animations() -> void:
    var clock := [source_animation_signature, flower_animation_frame]
    if clock == gpu_animation_clock and gpu_animated.size() == gpu_animation_rows: return
    gpu_animation_clock = clock
    gpu_animation_rows = gpu_animated.size()
    for id in gpu_animated:
        var row: Dictionary = gpu_rows[id]
        if not row.has("frames"):
            var identity := str(row.spec_key.upper if draw_upper else row.spec_key.base).to_lower()
            row["frames"] = {}
            row["clocked"] = identity.begins_with("water") or identity.begins_with("lava") or identity == "campfire1" or identity == "torch1"
            row["flower"] = not row.clocked and identity.begins_with("flower")
        var frame_key: int = source_animation_signature + 1 if row.clocked else (1000 + flower_animation_frame if row.flower else 0)
        var spec = row.frames.get(frame_key)
        if spec == null:
            spec = _cached_render_spec(row.spec_key)
            row.frames[frame_key] = spec
        var region: Rect2 = spec.get("region", row.region)
        if region == row.region: continue
        row.region = region
        var placed: Array = TileSheet.place(spec["texture"], region)
        if placed.is_empty(): continue
        row.pos = placed[1].position
        row.page = maxi(0, _gpu_page(placed[0]))
        _write_gpu_row(id)

func _flush_gpu() -> void:
    if gpu_view == null: return
    TileSheet.flush()
    var material := gpu_view.material as ShaderMaterial
    var pages := mini(TileSheet.pages.size(), GPU_PAGES)
    if pages != gpu_pages_bound:
        for index in pages: material.set_shader_parameter("page%d" % index, TileSheet.pages[index].texture)
        gpu_pages_bound = pages
    if gpu_table_dirty:
        gpu_table_dirty = false
        gpu_table_texture.update(gpu_table)
    if gpu_cells_dirty:
        gpu_cells_dirty = false
        gpu_cells.set_data(gpu_width, gpu_height, false, Image.FORMAT_RG8, gpu_bytes)
        gpu_cells_texture.update(gpu_cells)
    if shore_table_dirty:
        shore_table_dirty = false
        shore_table_texture.update(shore_table)
    if shore_cells_dirty:
        shore_cells_dirty = false
        shore_cells.set_data(gpu_width, gpu_height, false, Image.FORMAT_RG8, shore_bytes)
        shore_cells_texture.update(shore_cells)

## Tile art was swapped: forget every id; the full redraw that follows
## assigns them again.
func _reset_gpu() -> void:
    if gpu_cells == null: return
    gpu_bytes.fill(0)
    gpu_cells_dirty = true
    gpu_ids.clear()
    gpu_rows = [{}]
    gpu_animated.clear()
    gpu_fast = [{}, {}]
    kinds.clear()
    kind_sprites.clear()
    frames_placed.clear()
    if shore_cells != null: _reset_shores()
    if tide_view != null: _bind_tide_water()

## Whether a tile with no upper name draws nothing on the upper layer. Such
## specs never animate, so the answer per name and color is fixed.
func _upper_spec_is_empty(name_id: int, color_slot: int) -> bool:
    var key := name_id * 2 + color_slot
    if not upper_spec_empty.has(key):
        var name: String = (source_tiles as WorldTileStore).strings[name_id]
        upper_spec_empty[key] = _cached_render_spec({"base": name, "upper": "", "color": color_slot == 1}).is_empty()
    return upper_spec_empty[key]
