extends "res://scripts/source_chunk_tile_layer.gd"

# All terrain cells are installed before play. Camera movement only changes
# engine culling; it never resolves, loads or removes terrain cells.
const TileSheet = preload("res://scripts/tile_sheet.gd")
const CellFingerprints = preload("res://scripts/cell_fingerprints.gd")
var resident_layers: Array = []
var sheet_generation := 0
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
var last_source_parts: Array = []
var last_source_id := -1
## Ground on the GPU. Every plain 16x16 ground tile (still or animated, most
## of the map) is drawn by one quad (TerrainView): its shader reads the cell's
## tile id from gpu_cells, the tile's place on a TileSheet page from
## gpu_table, and samples that page. Tidal, gate and odd-sized ground keeps
## its TileMapLayer cell. Tiles are drawn with their corners snapped to
## screen pixels (snap_2d_vertices_to_pixel); the shader snaps each cell the
## same way, so the result matches the TileMapLayer pixel for pixel.
const GPU_SHADER := "shader_type canvas_item; uniform sampler2D cells : filter_nearest; uniform sampler2D table : filter_nearest; uniform sampler2D page0 : filter_nearest; uniform sampler2D page1 : filter_nearest; uniform sampler2D page2 : filter_nearest; uniform sampler2D page3 : filter_nearest; uniform highp vec2 cells_origin; uniform highp vec2 cells_size; uniform highp vec2 page_size; varying highp vec2 spos; varying highp vec4 xf; varying vec4 tint; void vertex(){highp mat4 m=CANVAS_MATRIX*MODEL_MATRIX; spos=floor((m*vec4(VERTEX,0.0,1.0)).xy+0.5); xf=vec4(m[0][0],m[1][1],m[3][0],m[3][1]); tint=COLOR;} void fragment(){highp vec2 scl=xf.xy; highp vec2 off=xf.zw; highp vec2 cell=floor((spos-off)/scl/16.0); highp vec2 e0=floor(cell*16.0*scl+off+0.5); highp vec2 e1=floor((cell+1.0)*16.0*scl+off+0.5); cell+=step(e1,spos)-(1.0-step(e0,spos)); e0=floor(cell*16.0*scl+off+0.5); e1=floor((cell+1.0)*16.0*scl+off+0.5); highp vec2 at=cell-cells_origin; if(at.x<0.0||at.y<0.0||at.x>=cells_size.x||at.y>=cells_size.y) discard; vec4 c=texelFetch(cells,ivec2(at),0); int id=int(c.r*255.0+0.5)+int(c.g*255.0+0.5)*256; if(id==0) discard; highp vec4 row=texelFetch(table,ivec2(id%256,id/256),0); highp vec2 pos=row.xy; highp vec2 uv=clamp((pos+(spos-e0)/(e1-e0)*16.0)/page_size+1e-5,(pos+0.5)/page_size,(pos+15.5)/page_size); int page=int(row.z+0.5); vec4 col; if(page==0) col=textureLod(page0,uv,0.0); else if(page==1) col=textureLod(page1,uv,0.0); else if(page==2) col=textureLod(page2,uv,0.0); else col=textureLod(page3,uv,0.0); COLOR=tint*col;}"
const GPU_TABLE_WIDTH := 256
const GPU_MAX_IDS := 4096
const GPU_PAGES := 4
var gpu_cells: Image
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
## Ground with no upper name: [color][name] -> id, so most cells skip the spec work.
var gpu_fast: Array = [{}, {}]
var upper_spec_empty := {}

func queue_tide_refresh(cells: Array):
    var center = Vector2i(tracked_player.global_position/float(tile_size))
    for cell in cells:
        var key = cell*tile_size if source_keys_are_pixels else cell
        if source_tiles.has(key):
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
        image.blend_rect(spec.texture.get_image(),Rect2i(spec.region),Vector2i(spec.get("offset",Vector2.ZERO)-bounds.position))
    image.blend_rect(reward.get_image(),Rect2i(0,0,16,16),Vector2i(-bounds.position))
    var combined = {"texture":ImageTexture.create_from_image(image),"region":Rect2(Vector2.ZERO,bounds.size),"offset":bounds.position}
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
    if not draw_upper and tile_size == 16: _prepare_gpu()
    _prepare_tide_sources()
    if draw_upper:
        var names: Array = preload("res://scripts/field_move_data.gd").CRACKED_LOOT.keys()
        names.append("cactus2_cacturne")
        for name in names:
            _install(-1,Vector2i.ZERO,_world_data().render_spec({"base":"desert4","upper":name},true))
    _prepare_dig_sources()
    if draw_upper:
        # Harvesting must reuse atlas sources: adding one during play makes
        # Godot rebuild every populated quadrant in the shared TileSet.
        for berry in ["aspear", "cheri", "chesto", "lum", "pecha", "persim", "rawst"]:
            for state in ["full", "empty"]:
                for colored in [false, true]:
                    _install(-1, Vector2i.ZERO, _cached_render_spec({"base":"green1", "upper":"berrytree_%s_%s" % [berry, state], "color":colored}))
    if not deferred_build: refresh_now()

func build_resident_async():
    # Install the complete world before play, yielding between small batches.
    set_process(false)
    resident_build_count += 1
    var batch := {}
    var deadline := Time.get_ticks_usec() + 13000
    var store: WorldTileStore = source_tiles
    var tidal := {}
    for index in store.with_name_containing("_tidalwater"): tidal[index] = true
    for index in store.indices():
        var key := store.key_of(index)
        var cell = Vector2i(key / tile_size) if source_keys_are_pixels else key
        resident_fingerprints.fp_put(key, store.revision_at(index))
        if tidal.has(index) and _is_beach_high_tide(store.cursor(index)): frame_tidal_cells[cell] = true
        batch[cell] = true
        if batch.size() >= 64 or Time.get_ticks_usec() >= deadline:
            _redraw_cells(batch, false)
            batch.clear()
            if Time.get_ticks_usec() >= deadline:
                await get_tree().process_frame
                deadline = Time.get_ticks_usec() + 13000
    if not batch.is_empty(): _redraw_cells(batch, false)
    _flush_gpu()
    resident_dirty = false
    set_process(true)
    await get_tree().process_frame

func _prepare_tide_sources():
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
    else:
        var prepared = {}
        for index in (source_tiles as WorldTileStore).with_name_containing("_tidal"):
            var name = (source_tiles as WorldTileStore).name_at(index)
            if not "_tidal" in name: continue
            for next_name in [name.replace("_tidalwater","_tidaloff"),name.replace("_tidaloff","_tidalwater")]:
                if prepared.has(next_name): continue
                prepared[next_name]=true
                var spec = _world_data().render_spec({"base":next_name,"upper":""},false)
                _install(-1,Vector2i.ZERO,spec)
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
    if sheet_generation != TileSheet.generation:
        # Tile art was swapped (the Gen 3 pack): place every tile again.
        sheet_generation = TileSheet.generation
        _reset_gpu()
        upper_spec_empty.clear()
        resident_fingerprints.clear()
        last_source_parts = []
        last_source_id = -1
        refresh_now()
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
    for animation in resident_animations:
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
        animation_key = ["tile", _field(animation[1], "name", ""), _field(animation[1], "name_upper", ""), _field(animation[1], "color", false)]
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
        if source_tiles.has(key) and _is_beach_high_tide(source_tiles.tile(key)): frame_tidal_cells[cell] = true
        else: frame_tidal_cells.erase(cell)
    _redraw_cells(affected)

func _redraw_cells(affected: Dictionary, erase_absent: bool = true):
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
    for cell in affected:
        var key = cell * tile_size if source_keys_are_pixels else cell
        var index: int = store.index_of(key)
        if index < 0:
            if gpu_cells != null: _set_gpu_cell(cell, 0)
            continue
        # Two thirds of the map is open sea: settle those cells by ids alone.
        if cell_uppers[index] == 0:
            var color_slot := 1 if cell_flags[index] & WorldTileStore.COLOR else 0
            if draw_upper:
                if cell_flags[index] & WorldTileStore.WATER and cell_oceans[index] == 0                         and _upper_spec_is_empty(cell_names[index], color_slot): continue
            elif gpu_cells != null:
                var fast: int = gpu_fast[color_slot].get(cell_names[index], 0)
                if fast > 0:
                    _set_gpu_cell(cell, fast)
                    continue
        # The fields drawing reads, as a small Dictionary (every helper here
        # takes one): loading a SourceTile proxy per cell cost ~17 us.
        var tile := _tile_view(store, index)
        if draw_upper:
            var shores = [String(tile.shore_ocean), _active_beach_tidal_shore(cell, tile)]
            for kind in range(2):
                if shores[kind].is_empty(): continue
                var quads = _world_data().shoreline_quads(shores[kind], shore_animation_frame)
                for quadrant in range(quads.size()):
                    var quad = quads[quadrant]
                    var layer_index = kind * 4 + quadrant
                    _install(layer_index, cell, {"texture":quad["texture"], "region":quad["source"], "offset":quad["offset"]}, Color.WHITE if kind == 0 else Color(1,1,1,0.5), ["shore",shores[kind],quadrant])
                    if erase_absent: desired[layer_index][cell] = true
        var spec = _cached_render_spec(tile)
        var identity = String(tile.name_upper if draw_upper else tile.name).to_lower()
        if gpu_cells != null:
            var gpu_id := _gpu_id(tile, spec, identity)
            _set_gpu_cell(cell, gpu_id)
            if gpu_id > 0: continue
        if "gate" in identity and open_gate_cells.has(cell): continue
        if draw_upper and identity.begins_with("hole1") and not str(_field(tile,"has_item","")).is_empty():
            spec = _reward_composite(spec)
        if not spec.is_empty():
            var animation = []
            if identity.begins_with("water") or identity.begins_with("lava") or identity.begins_with("flower") or identity in ["campfire1", "torch1"]:
                animation = ["tile", {"base": tile.name, "upper": tile.name_upper, "color": tile.color}, 0]  # a name key: views are not kept
            _install(8, cell, spec, Color.WHITE, animation)
            if erase_absent: desired[8][cell] = true
            if not draw_upper and _is_beach_high_tide(tile):
                _install(9, cell, {"texture":_world_data().texture_for("water2"),"region":Rect2(0,0,16,16)}, Color(1,1,1,0.5), ["tide","",0])
                if erase_absent: desired[9][cell] = true
            if draw_upper and _mountain_tree_needs_front_redraw(cell,tile,spec):
                _install(11, cell, spec)
                if erase_absent: desired[11][cell] = true
    drawing_tidal_shores = false
    if not erase_absent: return
    for index in range(12):
        var layer: TileMapLayer = resident_layers[index]
        for cell in affected:
            if not desired[index].has(cell) and layer.get_cell_source_id(cell) >= 0: layer.erase_cell(cell)
        # Godot applies changed cells together at the end of this frame.

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
        return
    for prefix in ["ledges3", "ledges3snow", "ledges3volcano"]:
        for suffix in ["none", "N", "NE", "E", "SE", "S", "SW", "W", "NW", "NW_inner", "NE_inner", "SW_inner", "SE_inner"]:
            for colored in [false,true]:
                _install(-1,Vector2i.ZERO,_world_data().render_spec({"base":"green1","upper":prefix+"_"+suffix,"color":colored},true))
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

## A cell's revision in the store: it changes whenever the cell does.
func _fingerprint(key: Vector2i) -> int:
    var index: int = source_tiles.index_of(key)
    return -1 if index < 0 else source_tiles.revision_at(index)

func _prepare_gpu() -> void:
    if source_tiles.is_empty(): return
    var bounds := Rect2i(resident_fingerprints.origin, Vector2i(resident_fingerprints.width, resident_fingerprints.height))
    gpu_cells = Image.create(bounds.size.x, bounds.size.y, false, Image.FORMAT_RG8)
    gpu_cells_texture = ImageTexture.create_from_image(gpu_cells)
    gpu_table = Image.create(GPU_TABLE_WIDTH, GPU_MAX_IDS / GPU_TABLE_WIDTH, false, Image.FORMAT_RGBAF)
    gpu_table_texture = ImageTexture.create_from_image(gpu_table)
    gpu_view = Node2D.new()
    gpu_view.name = "TerrainView"
    var material := ShaderMaterial.new()
    material.shader = Shader.new()
    material.shader.code = GPU_SHADER
    material.set_shader_parameter("cells", gpu_cells_texture)
    material.set_shader_parameter("table", gpu_table_texture)
    material.set_shader_parameter("cells_origin", Vector2(bounds.position))
    material.set_shader_parameter("cells_size", Vector2(bounds.size))
    material.set_shader_parameter("page_size", Vector2(TileSheet.SIZE, TileSheet.SIZE))
    gpu_view.material = material
    var area := Rect2(Vector2(bounds.position * tile_size), Vector2(bounds.size * tile_size))
    gpu_view.draw.connect(func(): gpu_view.draw_rect(area, Color.WHITE))
    add_child(gpu_view)
    move_child(gpu_view, 0)

## The id drawing this ground cell on the GPU, or 0 to keep it a TileMapLayer
## cell (tide overlays, gates, sprites that are not a plain 16x16 tile).
func _gpu_id(tile, spec: Dictionary, identity: String) -> int:
    if spec.is_empty() or spec.get("texture") == null or "_tidal" in identity or "gate" in identity: return 0
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
        if animated:
            var spec_key := {"base": name, "upper": upper, "color": color}
            if not _gpu_place_frames(spec_key): return 0
            row["spec_key"] = spec_key
            row["region"] = region
            gpu_animated.append(id)
        gpu_rows.append(row)
        gpu_ids[key] = id
        _write_gpu_row(id)
    if upper.is_empty(): gpu_fast[1 if color else 0][(source_tiles as WorldTileStore).sid(name)] = id
    return id

## Puts every frame of an animated ground kind on the sheet up front, so the
## animation never adds to (and re-uploads) a sheet page during play.
func _gpu_place_frames(spec_key: Dictionary) -> bool:
    var seen := {}
    for tick in range(0, 4560, SOURCE_ANIMATION_STEP):
        var signature = _animation_signature(tick)
        for flower in [0, 1]:
            if seen.has([signature, flower]): continue
            seen[[signature, flower]] = true
            var spec: Dictionary = _world_data().render_spec(spec_key, false, flower, tick)
            if spec.is_empty() or spec.get("texture") == null: return false
            var region: Rect2 = spec.get("region", Rect2())
            if region.size != Vector2(tile_size, tile_size): return false
            var placed: Array = TileSheet.place(spec["texture"], region)
            if placed.is_empty() or _gpu_page(placed[0]) < 0: return false
    return true

func _gpu_page(texture: Texture2D) -> int:
    for index in mini(TileSheet.pages.size(), GPU_PAGES):
        if TileSheet.pages[index].texture == texture: return index
    return -1

func _write_gpu_row(id: int) -> void:
    var row: Dictionary = gpu_rows[id]
    gpu_table.set_pixel(id % GPU_TABLE_WIDTH, id / GPU_TABLE_WIDTH, Color(row.pos.x, row.pos.y, row.page, 0.0))
    gpu_table_dirty = true

func _set_gpu_cell(cell: Vector2i, id: int) -> void:
    var at := cell - resident_fingerprints.origin
    if at.x < 0 or at.y < 0 or at.x >= gpu_cells.get_width() or at.y >= gpu_cells.get_height():
        return
    var value := Color((id & 255) / 255.0, (id >> 8) / 255.0, 0.0)
    if gpu_cells.get_pixelv(at) == value: return
    gpu_cells.set_pixelv(at, value)
    gpu_cells_dirty = true

## Animated kinds move their table row to the current frame's place.
func _update_gpu_animations() -> void:
    for id in gpu_animated:
        var row: Dictionary = gpu_rows[id]
        var spec: Dictionary = _cached_render_spec(row.spec_key)
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
        gpu_cells_texture.update(gpu_cells)

## Tile art was swapped: forget every id; the full redraw that follows
## assigns them again.
func _reset_gpu() -> void:
    if gpu_cells == null: return
    gpu_cells.fill(Color(0, 0, 0))
    gpu_cells_dirty = true
    gpu_ids.clear()
    gpu_rows = [{}]
    gpu_animated.clear()
    gpu_fast = [{}, {}]

## Whether a tile with no upper name draws nothing on the upper layer. Such
## specs never animate, so the answer per name and color is fixed.
func _upper_spec_is_empty(name_id: int, color_slot: int) -> bool:
    var key := name_id * 2 + color_slot
    if not upper_spec_empty.has(key):
        var name: String = (source_tiles as WorldTileStore).strings[name_id]
        upper_spec_empty[key] = _cached_render_spec({"base": name, "upper": "", "color": color_slot == 1}).is_empty()
    return upper_spec_empty[key]
