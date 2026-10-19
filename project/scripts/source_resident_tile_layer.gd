extends "res://scripts/source_chunk_tile_layer.gd"

# All terrain cells are installed before play. Camera movement only changes
# engine culling; it never resolves, loads or removes terrain cells.
const TileSheet = preload("res://scripts/tile_sheet.gd")
var resident_layers: Array = []
var sheet_generation := 0
var resident_tileset: TileSet
var resident_sources: Dictionary = {}
var resident_animations: Array = []
var resident_dirty := false
var resident_build_count := 0
var resident_shader: Shader
var resident_fingerprints: Dictionary = {}
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

func queue_tide_refresh(cells: Array):
    var center = Vector2i(tracked_player.global_position/float(tile_size))
    for cell in cells:
        var key = cell*tile_size if source_keys_are_pixels else cell
        if source_tiles.has(key):
            var tile = source_tiles[key]
            resident_fingerprints[key] = hash([tile.get_instance_id(), tile.resident_revision])
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
    for key in source_tiles:
        var tile = source_tiles[key]
        var cell = Vector2i(key / tile_size) if source_keys_are_pixels else key
        resident_fingerprints[key] = hash([tile.get_instance_id(), tile.resident_revision]) if tile is SourceTile else hash(tile)
        if _is_beach_high_tide(tile): frame_tidal_cells[cell] = true
        batch[cell] = true
        if batch.size() >= 64 or Time.get_ticks_usec() >= deadline:
            _redraw_cells(batch, false)
            batch.clear()
            if Time.get_ticks_usec() >= deadline:
                await get_tree().process_frame
                deadline = Time.get_ticks_usec() + 13000
    if not batch.is_empty(): _redraw_cells(batch, false)
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
        for tile in source_tiles.values():
            var name = str(_field(tile,"name",""))
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
        resident_fingerprints.clear()
        last_source_parts = []
        last_source_id = -1
        refresh_now()
    TileSheet.flush()
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
    var key = str(parts)
    var id = resident_sources.get(key, -1)
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
        resident_sources[key] = id
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
    var current := {} if changed_hint.is_empty() else resident_fingerprints
    var changed := {}
    var keys = source_tiles.keys() if changed_hint.is_empty() else changed_hint.map(func(cell): return cell * tile_size if source_keys_are_pixels else cell)
    for key in keys:
        if not source_tiles.has(key):
            current.erase(key)
            changed[Vector2i(key / tile_size) if source_keys_are_pixels else key] = true
            continue
        var tile = source_tiles[key]
        var fingerprint = hash([tile.get_instance_id(), tile.resident_revision]) if tile is SourceTile else hash(tile)
        if resident_fingerprints.get(key) != fingerprint:
            changed[Vector2i(key / tile_size) if source_keys_are_pixels else key] = true
        current[key] = fingerprint
    if changed_hint.is_empty():
        for key in resident_fingerprints:
            if not current.has(key): changed[Vector2i(key / tile_size) if source_keys_are_pixels else key] = true
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
        if source_tiles.has(key) and _is_beach_high_tide(source_tiles[key]): frame_tidal_cells[cell] = true
        else: frame_tidal_cells.erase(cell)
    _redraw_cells(affected)

func _redraw_cells(affected: Dictionary, erase_absent: bool = true):
    var desired: Array = []
    if erase_absent:
        for index in range(12): desired.append({})
    drawing_tidal_shores = true
    for cell in affected:
        var key = cell * tile_size if source_keys_are_pixels else cell
        if not source_tiles.has(key): continue
        var tile = source_tiles[key]
        if draw_upper:
            var shores = [str(_field(tile, "shore_ocean", "")), _active_beach_tidal_shore(cell, tile)]
            for kind in range(2):
                if shores[kind].is_empty(): continue
                var quads = _world_data().shoreline_quads(shores[kind], shore_animation_frame)
                for quadrant in range(quads.size()):
                    var quad = quads[quadrant]
                    var layer_index = kind * 4 + quadrant
                    _install(layer_index, cell, {"texture":quad["texture"], "region":quad["source"], "offset":quad["offset"]}, Color.WHITE if kind == 0 else Color(1,1,1,0.5), ["shore",shores[kind],quadrant])
                    if erase_absent: desired[layer_index][cell] = true
        var spec = _cached_render_spec(tile)
        var identity = str(_field(tile, "name_upper" if draw_upper else "name", "")).to_lower()
        if "gate" in identity and open_gate_cells.has(cell): continue
        if draw_upper and identity.begins_with("hole1") and not str(_field(tile,"has_item","")).is_empty():
            spec = _reward_composite(spec)
        if not spec.is_empty():
            var animation = []
            if identity.begins_with("water") or identity.begins_with("lava") or identity.begins_with("flower") or identity in ["campfire1", "torch1"]:
                animation = ["tile", tile, 0]
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
