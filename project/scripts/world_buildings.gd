extends RefCounted

const World = preload("res://scripts/world.gd")
const CraftingData = preload("res://scripts/crafting_data.gd")
const FLOWER_1 := preload("res://assets/flower1_runtime.png")
const FieldMoveData = preload("res://scripts/field_move_data.gd")
const SOURCE_HOUSE12_DOOR := preload("res://assets/source_0_8_11/tiles/buildings/house12_door1.png")
const SOURCE_HOUSE12_ROOF := preload("res://assets/source_0_8_11/tiles/buildings/house12_roof_middle1.png")
const SOURCE_HOUSE12_WALL_SHEET := preload("res://assets/source_0_8_11/tiles/buildings/house12_all.png")
const SOURCE_HOUSE5_WALL := preload("res://assets/source_0_8_11/tiles/buildings/house5_wall1.png")
const SOURCE_HOUSE5_WALL_MIDDLE := preload("res://assets/source_0_8_11/tiles/buildings/house5_middle1.png")
const SOURCE_HOUSE8_DOOR := preload("res://assets/source_0_8_11/tiles/buildings/house8_door1.png")
const SOURCE_HOUSE8_ROOF := preload("res://assets/source_0_8_11/tiles/buildings/house8_roof_middle1.png")
const SOURCE_HOUSE8_WALL_SHEET := preload("res://assets/source_0_8_11/tiles/buildings/house8_all.png")
const SourceChunkCollisionStreamer = preload("res://scripts/source_resident_collision_layer.gd")
const SourceHouseStyles = preload("res://scripts/source_house_styles.gd")
const SourceWorldData = preload("res://scripts/source_world_data.gd")
const TexturePixels = preload("res://scripts/texture_pixels.gd")
## The rules of building (rules/): this World plays their events.
const Build = preload("res://scripts/rules/build.gd")
const Remove = preload("res://scripts/rules/remove.gd")

var world: World

func _init(owner_world: World) -> void:
    world = owner_world

func refresh_house_structure_depths() -> void:
    for cell in world.built_structures:
        var data: Dictionary = world.built_structures[cell]
        var kind := String(data.get("name", ""))
        # Furniture inside a house is ordered by its row as well. Its depth was
        # only worked out once, from wherever the player stood when it was
        # placed, so a couch could be drawn over the plant in front of it.
        var furniture: bool = world.built_house_interior_cells.has(cell) and kind != "FLOOR"
        if kind not in ["STATUE", "WALL", "ROOF", "DOOR"] and not furniture: continue
        var sprite := data.get("sprite") as Sprite2D
        if not is_instance_valid(sprite): continue
        if world.built_house_interior_cells.has(cell):
            sprite.z_index = 0 if kind == "WALL" else _house_piece_z(kind, cell)
        else:
            sprite.z_index = world._depth_z(cell)
    if world.active_area_id != "HOUSE": return
    # Things hung on a wall stay just in front of that wall.
    for hung in [world.built_house_decoration_sprites, world.built_house_paint_sprites]:
        for cell in hung:
            var hung_sprite := hung[cell] as Sprite2D
            if is_instance_valid(hung_sprite) and hung_sprite.z_index >= 0:
                hung_sprite.z_index = world._depth_z(cell, World.HOUSE_FURNITURE_Z)

func _house_piece_z(kind: String, cell: Vector2i) -> int:
    if kind == "STAIRS": return World.HOUSE_STAIRS_Z
    return world._depth_z(cell, 0 if kind == "INTERIOR WALL" else World.HOUSE_FURNITURE_Z)

func cycle_build_selection(direction: int) -> void:
    if CraftingData.build_recipes().is_empty():
        return
    set_build_selection_index(world.build_selection_index + direction)
    var build_name := current_build_name()
    var recipe := CraftingData.build_recipe(build_name)
    world.world_message.emit("BUILD: %s\n%s" % [CraftingData.build_display_name(build_name), CraftingData.format_cost(recipe.get("cost", {}))])

func current_build_name() -> String:
    if CraftingData.build_recipes().is_empty():
        return ""
    var recipe: Dictionary = CraftingData.build_recipes()[world.build_selection_index]
    return String(recipe.get("name", ""))

func get_build_selection_index() -> int:
    return world.build_selection_index

func set_build_selection_index(index: int) -> void:
    if CraftingData.build_recipes().is_empty():
        world.build_selection_index = 0
        return
    var normalized := wrapi(index, 0, CraftingData.build_recipes().size())
    var changed := normalized != world.build_selection_index
    world.build_selection_index = normalized
    update_build_preview()
    if changed:
        world.build_selection_changed.emit(world.build_selection_index)

func set_build_preview_active(active: bool) -> void:
    world.build_mode_active = active and world.active_field_move == "BUILD"
    if not world.build_mode_active:
        if world.build_preview_sprite != null and is_instance_valid(world.build_preview_sprite):
            world.build_preview_sprite.queue_free()
        world.build_preview_sprite = null
        return
    if world.build_preview_sprite == null or not is_instance_valid(world.build_preview_sprite):
        world.build_preview_sprite = Sprite2D.new()
        world.build_preview_sprite.name = "BuildPlacementPreview"
        world.build_preview_sprite.centered = true
        world.build_preview_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
        world.build_preview_sprite.z_as_relative = false
        var layer := world.get_node_or_null("LandmarkLayer") as Node2D
        if layer != null:
            layer.add_child(world.build_preview_sprite)
        else:
            world.add_child(world.build_preview_sprite)
    update_build_preview()

func show_current_build_selection() -> void:
    if CraftingData.build_recipes().is_empty():
        return
    var build_name := current_build_name()
    var recipe := CraftingData.build_recipe(build_name)
    world.world_message.emit("BUILD: %s\n%s" % [CraftingData.build_display_name(build_name), CraftingData.format_cost(recipe.get("cost", {}))])

## An interior wall takes windows, clocks and paint wherever it stands in the
## room: on a floor tile, or on the old row just above the room.
## The window or clock hanging on this house wall, or "" when it is bare.
func house_wall_decoration_at(cell: Vector2i) -> String:
    return Build.wall_decoration_at(world.area, _player(cell), cell)

## CUT takes a window or clock off its wall and leaves the wall standing. The
## room's own rear wall is not a built piece and could never be cut, so
## without this nothing hung on it could ever be removed.
func remove_house_wall_decoration(cell: Vector2i, refund: bool) -> bool:
    var out := _out()
    var removed := Remove.remove_decoration(world.area, _player(cell), cell, refund, out)
    world.field_moves.play_rule(out)
    return removed

func _is_house_wall_cell(cell: Vector2i) -> bool:
    return Build.is_house_wall_cell(house_context(), cell)

func built_house_rear_wall_floor(cell: Vector2i) -> int:
    return Build.rear_wall_floor(house_context(), cell)

## The inside of the house this World holds (rules/build.gd player.house):
## its own dictionaries, which the rules read and add floor and walls to.
func house_context() -> Dictionary:
    return {"door": world.active_built_house_door, "origin": world.built_house_interior_origin, "size": world.built_house_room_size,
        "footprint": world.built_house_footprint, "capacity": world.built_house_floor_capacity, "floors": world.built_house_floor_origins,
        "interior": world.built_house_interior_cells, "walls": world.built_house_paintable_walls, "exits": {}}

## What the rules are told about this World's player (world_field_moves.gd rule_player).
func _player(cell: Vector2i = Vector2i.ZERO) -> Dictionary:
    return world.field_moves.rule_player(cell)

static func _out() -> Dictionary:
    return {"ok": false, "reason": "", "events": [], "grant": {}, "consume": {}}

func snap_build_cell(build_name: String, desired: Vector2i) -> Vector2i:
    if (build_name == "CLOCK" or _is_window_recipe(build_name)) and world.active_area_id == "HOUSE":
        # It goes on the wall piece being faced. Interior walls now stand on
        # the room's own floor tiles; the old row above the northernmost floor
        # tile is only used by rooms that still have their wall there. Facing
        # open floor, it goes on the first wall straight ahead to the north.
        if world.built_house_paintable_walls.has(desired):
            return desired
        var origin: Vector2i = world.source_area_origins.get("HOUSE", world.built_house_interior_origin)
        var floor_index := world._built_house_floor_index_for_cell(world._player_cell())
        if floor_index >= 0:
            origin = world._built_house_floor_origin(floor_index)
        for y in range(desired.y - 1, origin.y - 2, -1):
            if world.built_house_paintable_walls.has(Vector2i(desired.x, y)):
                return Vector2i(desired.x, y)
        return desired
    # Other pieces retain their exact aimed grid cell.
    return desired

func restore_house_rear_walls() -> void:
    # Keep saved partitions on their original floor and cell. Older rear-wall
    # pieces remain where they were saved; loading never relocates a wall.
    for cell in world.built_structures:
        if String(world.built_structures[cell].get("name", "")) != "INTERIOR WALL": continue
        if _is_house_wall_cell(cell):
            world.built_house_paintable_walls[cell] = true
        refresh_connected_structures_around(cell)

func get_build_preview_cell() -> Vector2i:
    # The tile immediately ahead of the controlled work Pokemon.
    var desired: Vector2i = world._player_cell() + world._facing_cell()
    return snap_build_cell(current_build_name(), desired)

func get_build_execution_cell() -> Vector2i:
    # The controlled body is the leading Pokemon. Build at its preview target,
    # never underneath it; both input paths share this snapped destination.
    return get_build_preview_cell()

## per-frame
func update_build_preview() -> void:
    if not world.build_mode_active or world.build_preview_sprite == null or not is_instance_valid(world.build_preview_sprite):
        return
    if is_instance_valid(world.field_helper_sprite) and world.active_field_move == "BUILD":
        world._position_build_helper()
    var build_name := current_build_name()
    var target := get_build_preview_cell()
    var texture := structure_display_texture(build_name)
    world.build_preview_sprite.texture = texture
    if texture == null:
        world.build_preview_sprite.visible = false
        return
    world.build_preview_sprite.visible = true
    # Display the item on the actual placement tile.
    var display_cell := target
    # Use the identical bottom-anchored pixel origin as place_structure.
    world.build_preview_sprite.centered = false
    world.build_preview_sprite.position = Vector2(display_cell.x * World.TILE, display_cell.y * World.TILE - maxi(0, int(texture.get_height()) - World.TILE))
    world.build_preview_sprite.offset = Vector2.ZERO
    world.build_preview_sprite.z_index = world._depth_z(display_cell)
    if build_name == "CHIMNEY":
        # Match the actual roof attachment position.
        world.build_preview_sprite.centered = false
        world.build_preview_sprite.offset = Vector2.ZERO
        var shell := (world.built_structures.get(target, {}) as Dictionary).get("sprite") as Sprite2D
        world.build_preview_sprite.position = (shell.position if is_instance_valid(shell) else Vector2(target) * float(World.TILE)) + Vector2(0, -16)
    if is_instance_valid(world.field_helper_sprite) and world.active_field_move == "BUILD":
        var helper_rect := world.field_helper_sprite.get_rect()
        helper_rect.position += world.field_helper_sprite.position
        var preview_rect := world.build_preview_sprite.get_rect()
        preview_rect.position += world.build_preview_sprite.position
        # Tall artwork may extend beyond its tile. Keep the Pokemon visible
        # without moving the preview away from the tile that will be built.
        if preview_rect.intersects(helper_rect):
            world.build_preview_sprite.z_index = mini(world.build_preview_sprite.z_index, world.field_helper_sprite.z_index - 1)
    # Source BUILD preview is an opaque sprite, not a translucent ghost.
    world.build_preview_sprite.modulate = Color.WHITE

func _house_style_for_recipe(build_name: String) -> String:
    return Build.house_style_for(build_name)

func _house_piece_name(build_name: String) -> String:
    return Build.piece_name(build_name)

func _styled_house_piece_texture(build_name: String) -> Texture2D:
    var style := _house_style_for_recipe(build_name)
    var piece := _house_piece_name(build_name)
    if SourceHouseStyles.STYLES.has(style):
        return SourceHouseStyles.texture(style, piece)
    if style == "DEFAULT":
        return null
    if piece == "ROOF":
        return SOURCE_HOUSE8_ROOF if style == "SAVANNA" else SOURCE_HOUSE12_ROOF
    if piece == "DOOR":
        return SOURCE_HOUSE8_DOOR if style == "SAVANNA" else SOURCE_HOUSE12_DOOR
    if piece != "WALL":
        return null
    # The alternate source house facades are complete 3-column sheets. Their
    # middle 16x16 wall cell is the authored repeatable material tile.
    var atlas := AtlasTexture.new()
    atlas.atlas = SOURCE_HOUSE8_WALL_SHEET if style == "SAVANNA" else SOURCE_HOUSE12_WALL_SHEET
    atlas.region = Rect2(16, 16, 16, 16)
    return atlas

func can_place_structure(
        build_name: String,
        cell: Vector2i,
        ignore_indoor_requirement: bool = false
    ) -> bool:
    var out := _out()
    var allowed := Build.can_place(world.area, _player(cell), build_name, cell, ignore_indoor_requirement, out)
    world.field_moves.play_rule(out)
    return allowed

func _bridge_surface_at(cell: Vector2i) -> bool:
    return Build.bridge_surface_at(world.area, cell)

## The recipe drawn for a piece's data: a styled house's walls, roof and door by its style.
static func _display_name(data: Dictionary) -> String:
    var style := String(data.get("house_style", "DEFAULT"))
    var name := String(data.get("name", ""))
    if style != "DEFAULT" and name in ["WALL", "ROOF", "DOOR"]: return "%s %s" % [style, name]
    return String(data.get("recipe_name", name))

## A new piece is placed by the rules (rules/build.gd) and drawn from what
## they did; a saved one (`restoring`) is laid again from its record, and one
## the co-op host has placed (`committed_online`) without the checks.
func place_structure(build_name: String, cell: Vector2i, restoring: bool = false, restored_state: Dictionary = {}, committed_online: bool = false) -> bool:
    # The map draws a building with the tiles within 4 of it.
    world._bump_map_art([cell], 4)
    if not restoring:
        cell = snap_build_cell(build_name, cell)
    # A piece with no picture is not placed at all.
    if _whole_piece(build_name, cell, restoring) and structure_display_texture(_display_name(_drawn(build_name, restoring, restored_state)), int(restored_state.get("variant", 0))) == null:
        return false
    var out := _out()
    var placed: bool
    if restoring:
        placed = Build.place(world.area, _player(cell), build_name, cell, true, restored_state, committed_online, out)
    else:
        out = Build.apply(world.area, _player(cell), {"recipe": build_name, "cell": cell}, world.rng)
        placed = out.ok
    world.field_moves.play_rule(out)
    return placed

## Whether placing `build_name` makes a piece of its own (not something hung
## on a wall or a floor tile), so that it needs a picture.
func _whole_piece(build_name: String, cell: Vector2i, restoring: bool) -> bool:
    if Build.is_window(build_name) and world.active_area_id == "OVERWORLD" and not restoring: return false
    if build_name == "TORCH" and not restoring and Build.torch_wall_at(world.area, cell): return false
    if Build.is_house_decoration(build_name) and not (build_name == "CLOCK" and restoring): return false
    if build_name in ["WINDOW", "CHIMNEY"] and world.active_area_id == "OVERWORLD" and not restoring: return false
    if build_name == "FLOOR" and world.active_area_id == "HOUSE" and not restoring: return false
    return true

## The fields of the piece `build_name` would make that decide its picture.
static func _drawn(build_name: String, restoring: bool, restored_state: Dictionary) -> Dictionary:
    var requested := build_name
    if restoring and restored_state.has("recipe_name"): requested = String(restored_state.recipe_name)
    return {"name": String(restored_state.get("name", Build.piece_name(requested))), "recipe_name": requested,
        "house_style": String(restored_state.get("house_style", Build.house_style_for(requested)))}

## The piece at `cell` drawn from its data (rules/build.gd "structure"): made
## when it has no sprite yet, its look and attachments brought up to date.
func draw_structure(cell: Vector2i) -> void:
    var data: Dictionary = world.built_structures.get(cell, {})
    if data.is_empty(): return
    world._bump_map_art([cell], 4)
    var name := String(data.get("name", ""))
    var sprite := data.get("sprite") as Sprite2D
    if is_instance_valid(sprite):
        if name == "BED" and int(data.get("bed_carpet", 0)) > 0: sprite.texture = colored_bed_texture(int(data.bed_carpet))
        refresh_shell_attachment(cell)
        return
    var layer := world.get_node_or_null("LandmarkLayer") as Node2D
    if layer == null: return
    sprite = Sprite2D.new()
    sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
    sprite.centered = false
    sprite.z_as_relative = false
    if bool(data.get("generated_stair_pair", false)):
        sprite.texture = SourceWorldData.texture_for("stairs_down1")
        sprite.position = Vector2(cell.x * World.TILE, cell.y * World.TILE)
        sprite.z_index = World.HOUSE_STAIRS_Z
        layer.add_child(sprite)
        data["sprite"] = sprite
        data["collision"] = null
        return
    # Player-placed stairs use the normal source STAIRS artwork (`stairs_up1`);
    # only the automatically generated landing on the floor above uses the
    # source house down-stair artwork. This mirrors the direction of travel.
    sprite.texture = structure_display_texture(_display_name(data), int(data.get("variant", 0)))
    if name == "BED" and int(data.get("bed_carpet", 0)) > 0:
        sprite.texture = colored_bed_texture(int(data.bed_carpet))
    if sprite.texture == null:
        sprite.free()
        return
    sprite.position = Vector2(cell.x * World.TILE, cell.y * World.TILE - maxi(0, int(sprite.texture.get_height()) - World.TILE))
    # A beacon is a floor tile that is stood on, like a bridge.
    sprite.z_index = 10 if name in ["BRIDGE", "BEACON"] else world._depth_z(cell)
    layer.add_child(sprite)
    var collision: CollisionBox = null
    if bool(data.get("bridged_water", false)):
        var exact_collision := world.get_node_or_null("ExactCollisionStream") as SourceChunkCollisionStreamer
        if exact_collision != null:
            exact_collision.set_cell_passable(cell, true)
        var water_collision: CollisionBox = world.ground_collisions.get(cell) as CollisionBox
        if is_instance_valid(water_collision):
            water_collision.queue_free()
        world.ground_collisions.erase(cell)
    elif bool(data.get("solid", false)):
        var body := world.get_node_or_null("WorldCollision") as CollisionBody
        if body != null:
            collision = world._add_block_collision(body, cell.x, cell.y)
    data["sprite"] = sprite
    data["collision"] = collision
    world.grass_exclusion[cell] = true
    if name == "COUCH" and is_instance_valid(collision):
        var recipe_name := String(data.get("recipe_name", "COUCH"))
        var width := 32 if recipe_name == "COUCH" else 16
        var height := 16 if recipe_name in ["COUCH", "COUCH 3", "COUCH 5"] else 32
        collision.rect = Rect2(Vector2(cell * World.TILE) + Vector2(0, World.TILE-height), Vector2(width,height))
    if name == "DOOR":
        sprite.visible = not bool(data.get("open", false))
    elif name == "TORCH":
        sprite.modulate = Color.WHITE if bool(data.get("lit", true)) else Color(0.45, 0.45, 0.45)
    if name == "FLOWERS":
        world.flower_cells[cell] = true
    refresh_shell_attachment(cell)

## A piece gone (rules "unbuilt"): its nodes go, unless the piece now at
## `cell` (put back by a rollback) still uses them.
func undraw_structure(cell: Vector2i, piece: Dictionary) -> void:
    world._bump_map_art([cell], 4)
    var current: Dictionary = world.built_structures.get(cell, {})
    var sprite := piece.get("sprite") as Sprite2D
    if is_instance_valid(sprite) and current.get("sprite") != sprite:
        sprite.queue_free()
    var collision := piece.get("collision") as CollisionBox
    if is_instance_valid(collision) and current.get("collision") != collision:
        collision.queue_free()
    if bool(piece.get("bridged_water", false)) and not bool(current.get("bridged_water", false)):
        var stream := world.get_node_or_null("ExactCollisionStream") as SourceChunkCollisionStreamer
        if stream != null: stream.set_cell_passable(cell, false)
    if current.is_empty():
        world.grass_exclusion.erase(cell)
        world.flower_cells.erase(cell)

## The pieces at these cells drawn again after a rollback put their data
## back: what `shown` (each cell's piece as drawn before it) used and the
## piece there now does not goes, a piece with no sprite is drawn, and they
## join up again.
func redraw_structures(shown: Dictionary) -> void:
    for cell in shown:
        var before: Dictionary = shown[cell]
        var current: Dictionary = world.built_structures.get(cell, {})
        if before.get("sprite") != current.get("sprite") or before.get("collision") != current.get("collision"):
            undraw_structure(cell, before)
        if not current.is_empty():
            draw_structure(cell)
            _sync_collision(cell)
    for cell in shown: restyle_around(cell)

func structure_display_texture(build_name: String, variant: int = 0) -> Texture2D:
    if build_name == "INTERIOR WALL":
        return SOURCE_HOUSE5_WALL
    if build_name in ["PICHU DOLL", "DUSKULL DOLL", "SKITTY DOLL", "JIGGLYPUFF DOLL"]:
        return load("res://assets/source_0_8_11/tiles/buildings/house_plush%s.png" % build_name.get_slice(" ", 0).to_lower())
    if build_name == "FLOWERS":
        var flower := AtlasTexture.new()
        flower.atlas = FLOWER_1
        flower.region = Rect2(0, 0, 16, 16)
        return flower
    if build_name == "WALL":
        return SOURCE_HOUSE5_WALL_MIDDLE
    if build_name == "TORCH":
        return world.environment_structure_texture("TORCH", variant)
    if build_name == "ROOF":
        return preload("res://assets/source_0_8_11/tiles/buildings/house5_roof_middle1.png")
    if build_name in ["COUCH 2", "COUCH 3", "COUCH 4", "COUCH 5", "PLANT 2", "VANITY 2"]:
        var authored: Texture2D = load("res://assets/source_0_8_11/tiles/buildings/house_%s%s.png" % [build_name.get_slice(" ", 0).to_lower(), build_name.get_slice(" ", 1)])
        if authored.get_height() == 31:
            # Source selects a 16x32 region even for these 31px couch PNGs.
            var framed := AtlasTexture.new()
            framed.atlas = authored
            framed.region = Rect2(0,0,16,31)
            framed.margin = Rect2(0,0,0,1)
            return framed
        return authored
    if build_name == "WINDOW":
        if world.active_area_id == "HOUSE":
            return structure_display_texture("INDOOR WINDOW 1",variant)
        if not world.window_display_cache.has("normal_exterior"):
            var pixels := TexturePixels.of(preload("res://assets/source_0_8_11/tiles/buildings/exteriorwindows1.png"))
            pixels.convert(Image.FORMAT_RGBA8)
            pixels.fill_rect(Rect2i(0, 8, pixels.get_width(), pixels.get_height() - 8), Color.TRANSPARENT)
            world.window_display_cache["normal_exterior"] = ImageTexture.create_from_image(pixels)
        return world.window_display_cache["normal_exterior"]
    if build_name.begins_with("CARPET ") or build_name.begins_with("INDOOR WINDOW "):
        if build_name == "INDOOR WINDOW 1" and world.active_area_id == "HOUSE":
            variant = 0
        var file := "house_carpet" if build_name.begins_with("CARPET ") else "house_window"
        var texture: Texture2D = load("res://assets/source_0_8_11/tiles/buildings/%s%d.png" % [file, int(build_name.get_slice(" ", 1 if file == "house_carpet" else 2))])
        var frame := AtlasTexture.new()
        frame.atlas = texture
        frame.region = Rect2(wrapi(variant, 0, int(texture.get_width()) / 16) * 16, 0, 16, 16)
        if file == "house_window":
            # Authored windows occupy the upper ten pixels. The six rows below
            # are source wall backing; let the actual supporting wall show.
            var cache_key := build_name + ":" + str(frame.region.position.x)
            if not world.window_display_cache.has(cache_key):
                var window_pixels := TexturePixels.of(frame)
                window_pixels.fill_rect(Rect2i(0, 10, 16, 6), Color.TRANSPARENT)
                world.window_display_cache[cache_key] = ImageTexture.create_from_image(window_pixels)
            return world.window_display_cache[cache_key]
        return frame
    var styled := _styled_house_piece_texture(build_name)
    if styled != null:
        return styled
    var source := world.structure_textures.get(build_name) as Texture2D
    if source == null:
        return null
    if build_name == "PRIVATE CHEST":
        return _private_chest_texture(source)
    if build_name == "STORAGE BOX":
        # chest1.png's top-left 16x16 cell is transparent. The authored closed
        # storage-box frame used for placement starts on the second row.
        var chest_frame := AtlasTexture.new()
        chest_frame.atlas = source
        chest_frame.region = Rect2(0, 16, 16, 16)
        return chest_frame
    var source_size := source.get_size()
    var display_width := 64 if build_name == "CHIMNEY" else 32 if build_name == "COUCH" else mini(16, int(source_size.x))
    var display_height := 24 if build_name == "KILN" else 32 if build_name in ["STATUE", "PLANT", "BED", "SHELF", "DRESSER", "VANITY", "BEACON", "CHIMNEY"] else 20 if build_name == "CAMPFIRE" else mini(16, int(source_size.y))
    if int(source_size.x) <= display_width and int(source_size.y) <= display_height:
        return source
    var atlas := AtlasTexture.new()
    atlas.atlas = source
    var frames_x := maxi(1, int(source_size.x) / display_width)
    var frame := wrapi(variant, 0, frames_x)
    atlas.region = Rect2(frame * display_width, 0, display_width, mini(display_height, int(source_size.y)))
    return atlas

func colored_bed_texture(carpet_index: int) -> Texture2D:
    # DynamicTextures.cacheColoredHouseBed: carpet at (0,12), then bed frame.
    var image := Image.create(16, 32, false, Image.FORMAT_RGBA8)
    var carpet := TexturePixels.of((load("res://assets/source_0_8_11/tiles/buildings/house_carpet%d.png" % clampi(carpet_index,1,8)) as Texture2D))
    var frame := TexturePixels.of(preload("res://assets/source_0_8_11/tiles/buildings/house_bed1_colorbase.png"))
    image.blend_rect(carpet, Rect2i(0,0,16,16), Vector2i(0,12))
    image.blend_rect(frame, Rect2i(0,0,16,32), Vector2i.ZERO)
    return ImageTexture.create_from_image(image)

func interact_built_structure(cell: Vector2i) -> void:
    if not world.built_structures.has(cell):
        return
    var data: Dictionary = world.built_structures[cell]
    var build_name := String(data.get("name", ""))

    var recipe := CraftingData.build_recipe(build_name)
    var station := String(recipe.get("station", ""))
    if not station.is_empty():
        world.crafting_station_requested.emit(station)
        return

    if build_name == "DRESSER":
        world.structure_action.emit("DRESSER")
    elif build_name == "VANITY":
        world.structure_action.emit("VANITY")
    elif build_name == "BED":
        world.structure_action.emit("BED:%d:%d" % [cell.x, cell.y])
    elif build_name in ["STORAGE BOX","PRIVATE CHEST"]:
        world.structure_action.emit("STORAGE:%s" % world._cell_key(cell))
    elif build_name == "BEACON":
        world.structure_action.emit("BEACON_EDIT:%d:%d:%s" % [
            cell.x, cell.y, String(data.get("label", ""))
        ])
    elif build_name == "SIGN":
        var sign_text := String(data.get("text", ""))
        if sign_text.is_empty():
            world.structure_action.emit("SIGN_EDIT:%d:%d:" % [cell.x, cell.y])
        else:
            world.world_message.emit(sign_text)
    elif build_name == "DOOR":
        if bool(data.get("gate", false)):
            return # Source gates are passable; walking through requires no prompt.
        if world.active_area_id == "OVERWORLD":
            var house_state: Dictionary = built_house_state(cell)
            if bool(house_state.get("ready", false)):
                var outward := house_door_outward(cell)
                if outward == Vector2i.ZERO or not house_exit_clear(cell + outward):
                    world.world_message.emit("This entrance needs a clear outside tile.")
                    return
                world._prepare_built_house_interior(cell, house_state)
                world._enter_source_area("HOUSE", cell + outward)
            else:
                world.world_message.emit(String(house_state.get(
                    "message", "This house needs a completed roof.")))
        else:
            toggle_structure_door(cell)
    elif build_name == "WINDOW":
        data["variant"] = wrapi(int(data.get("variant", 0)) + 1, 0, 3)
        world.built_structures[cell] = data
        world.area.mark("structures", cell)
        var window_sprite := data.get("sprite") as Sprite2D
        if is_instance_valid(window_sprite):
            window_sprite.texture = structure_display_texture("WINDOW", int(data["variant"]))
        world.world_message.emit("You adjusted the WINDOW.")
    elif build_name == "PLANT":
        var day := world._world_day_index()
        if int(data.get("last_harvest_day", -1)) < day:
            data["last_harvest_day"] = day
            world.built_structures[cell] = data
            world.area.mark("structures", cell)
            world.material_collected.emit("MIRACLE SEED", 1)
            world.world_message.emit("The PLANT yielded a MIRACLE SEED.")
        else:
            world.world_message.emit("The PLANT needs another day to grow.")
    elif build_name == "CLOCK":
        var total_minutes := world.clock_minutes()
        world.world_message.emit("The CLOCK reads %02d:%02d on day %d." % [total_minutes / 60, total_minutes % 60, world._world_day_index() + 1])
    elif build_name == "STOOL":
        sit_on_stool(cell)
    elif build_name == "COUCH":
        sit_on_stool(cell)
    elif build_name.ends_with(" DOLL"):
        world.world_message.emit("A %s. Cute!" % build_name.to_lower())
    elif build_name == "TABLE":
        world.crafting_station_requested.emit("WORK TABLE")
    elif build_name == "TRASH CAN":
        world.world_message.emit("The TRASH CAN is empty.")
    elif build_name == "SHELF":
        world.world_message.emit("A sturdy SHELF for displaying supplies.")
    elif build_name == "STAIRS":
        use_linked_stairs(cell)
    elif build_name == "TORCH":
        data["lit"] = not bool(data.get("lit", true))
        world.built_structures[cell] = data
        world.area.mark("structures", cell)
        var torch_sprite := data.get("sprite") as Sprite2D
        if is_instance_valid(torch_sprite):
            torch_sprite.modulate = Color.WHITE if bool(data["lit"]) else Color(0.45, 0.45, 0.45)
        world.world_message.emit("The TORCH is now %s." % ("lit" if bool(data["lit"]) else "out"))
    else:
        world.world_message.emit("You inspect the %s." % build_name)

func _couch_footprint(recipe: String, cell: Vector2i) -> Array[Vector2i]:
    return Build.couch_footprint(recipe, cell)

func couch_anchor_at(cell: Vector2i) -> Vector2i:
    return Build.couch_anchor_at(world.area, cell)

func sit_on_stool(cell: Vector2i) -> void:
    if is_instance_valid(world.stool_seated_sprite):
        return
    var main := world.get_parent()
    if main == null or not main.has_method("_player_sitting_texture"):
        return
    world.clear_active_field_move(false)
    world.stool_seated_sprite = Sprite2D.new()
    var recipe := String(world.built_structures.get(cell, {}).get("recipe_name", "STOOL"))
    var couch_side := recipe in ["COUCH 2", "COUCH 3", "COUCH 4", "COUCH 5"]
    world.stool_seated_sprite.texture = main._player_sitting_texture(2 if couch_side else 0)
    world.stool_seated_sprite.flip_h = recipe in ["COUCH 2", "COUCH 3"]
    world.stool_seated_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
    world.stool_seated_sprite.position = world._cell_center(cell)
    # Player.Sitting source offsets, with Java Y-up converted to Godot Y-down.
    if recipe == "COUCH": world.stool_seated_sprite.position += Vector2(0,-3)
    elif couch_side: world.stool_seated_sprite.position += Vector2(3 if world.stool_seated_sprite.flip_h else -3,-5)
    world.stool_seated_sprite.z_as_relative = false
    var stool := world.built_structures.get(cell, {}).get("sprite") as Sprite2D
    world.stool_seated_sprite.z_index = stool.z_index + 1 if is_instance_valid(stool) else world._depth_z(cell, 25)
    world.add_child(world.stool_seated_sprite)
    world.player.sprite.visible = false
    world.player.velocity = Vector2.ZERO
    world.set_gameplay_enabled(false)

func turn_seated_player(action: String) -> void:
    if not is_instance_valid(world.stool_seated_sprite): return
    var frame := 1 if action == "move_up" else 0 if action == "move_down" else 2
    world.stool_seated_sprite.texture = world.get_parent()._player_sitting_texture(frame)
    world.stool_seated_sprite.flip_h = action == "move_right"

func end_stool_sitting() -> void:
    if not is_instance_valid(world.stool_seated_sprite):
        return
    world.stool_seated_sprite.queue_free()
    world.stool_seated_sprite = null
    world.player.sprite.visible = true
    world.set_gameplay_enabled(true)

func set_structure_sign_text(cell: Vector2i, value: String) -> void:
    if not world.built_structures.has(cell):
        return
    var data: Dictionary = world.built_structures[cell]
    if String(data.get("name", "")) != "SIGN":
        return
    data["text"] = value.strip_edges().left(64)
    world.built_structures[cell] = data
    world.area.mark("structures", cell)
    world.world_message.emit("The SIGN now reads: %s" % String(data["text"]))

func set_structure_beacon_label(cell: Vector2i, value: String) -> void:
    if not world.built_structures.has(cell):
        return
    var data: Dictionary = world.built_structures[cell]
    if String(data.get("name", "")) != "BEACON":
        return
    data["label"] = value.strip_edges().left(32)
    world.built_structures[cell] = data
    world.area.mark("structures", cell)
    if String(data["label"]).is_empty():
        world.world_message.emit("The BEACON name was cleared.")
    else:
        world.world_message.emit("BEACON named %s." % String(data["label"]))

func _set_structure_solid(cell: Vector2i, solid: bool) -> void:
    if not world.built_structures.has(cell):
        return
    var data: Dictionary = world.built_structures[cell]
    var collision := data.get("collision") as CollisionBox
    if solid and not is_instance_valid(collision):
        var body := world.get_node_or_null("WorldCollision") as CollisionBody
        if body != null:
            collision = world._add_block_collision(body, cell.x, cell.y)
            world.blocked[cell] = true
    elif not solid and is_instance_valid(collision):
        collision.queue_free()
        collision = null
        world.blocked.erase(cell)
    data["collision"] = collision
    data["solid"] = solid
    world.built_structures[cell] = data
    world.area.mark("structures", cell)

func built_house_state(door_cell: Vector2i) -> Dictionary:
    return Build.house_state(world.area, door_cell)

func toggle_structure_door(cell: Vector2i) -> void:
    var data: Dictionary = world.built_structures[cell]
    var is_open := not bool(data.get("open", false))
    data["open"] = is_open
    world.built_structures[cell] = data
    world.area.mark("structures", cell)
    _set_structure_solid(cell, not is_open)
    var sprite := data.get("sprite") as Sprite2D
    if is_instance_valid(sprite):
        sprite.visible = not is_open
    world.world_message.emit("The DOOR opened." if is_open else "The DOOR closed.")

func _built_house_stair_landing(stair: Vector2i) -> Vector2i:
    for direction in [Vector2i.DOWN, Vector2i.UP, Vector2i.RIGHT, Vector2i.LEFT]:
        var cell: Vector2i = stair + direction
        if not world.built_house_interior_cells.has(cell):
            continue
        if world.interior_interactables.has(cell) or world.built_structures.has(cell) or \
                world.wild_eggs.has(cell) or world.deployed_pokemon.has(cell):
            continue
        if world._wild_id_at_cell(cell) >= 0:
            continue
        return cell
    # A 1-cell room can only land on the stair itself.
    if world.built_house_interior_cells.has(stair):
        return stair
    return Vector2i(-2147483648, -2147483648)

func use_linked_stairs(source: Vector2i) -> void:
    if world.house_transition_active: return
    if not world.built_structures.has(source):
        return
    var source_data: Dictionary = world.built_structures[source]
    if world.active_area_id == "HOUSE" and world._stair_belongs_to_active_house(source_data):
        var source_floor: int = int(source_data.get("house_floor", -1))
        var destination: Vector2i = Vector2i(-2147483648, -2147483648)
        var destination_floor: int = source_floor
        if bool(source_data.get("generated_stair_pair", false)):
            var primary: Vector2i = Vector2i(
                int(source_data.get("stair_primary_x", -2147483648)),
                int(source_data.get("stair_primary_y", -2147483648))
            )
            if world.built_structures.has(primary):
                destination = primary
                destination_floor = source_floor - 1
        else:
            var local_cell: Vector2i = Vector2i(
                int(source_data.get("house_local_x", 0)),
                int(source_data.get("house_local_y", 0))
            )
            destination_floor = source_floor + 1
            if destination_floor < world.built_house_floor_capacity:
                destination = world._built_house_global_cell(destination_floor, local_cell)
                if not world.built_structures.has(destination):
                    world._create_generated_house_stair_pair(source)
        if destination.x <= -2147483648 or not world.built_structures.has(destination):
            world.world_message.emit("This house needs to be taller.")
            return
        var landing: Vector2i = _built_house_stair_landing(destination)
        if landing.x <= -2147483648:
            world.world_message.emit("The connected STAIRS need a clear landing.")
            return
        await world._house_door_transition("enter" if destination_floor > source_floor else "exit", func() -> void:
            world._set_active_built_house_floor(destination_floor)
            world.player.position = world._cell_center(landing)
            world.last_player_cell = landing
            world._sync_follower_to_player()
        )
        return

    # Compatibility behavior for any old non-house linked stair builds.
    var candidates: Array[Vector2i] = []
    for raw_cell in world.built_structures.keys():
        var cell: Vector2i = raw_cell
        if cell == source or String((world.built_structures[cell] as Dictionary).get(
                "name", "")) != "STAIRS":
            continue
        candidates.append(cell)
    if candidates.is_empty():
        world.world_message.emit("These STAIRS need a second staircase to connect to.")
        return
    candidates.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
        return a.distance_squared_to(source) < b.distance_squared_to(source))
    var destination: Vector2i = candidates[0] + Vector2i.DOWN
    await world._house_door_transition("enter", func() -> void:
        world.player.position = world._cell_center(destination)
        world.last_player_cell = destination
        world._sync_follower_to_player()
    )

func _house_connection_piece(cell: Vector2i) -> String:
    return Build.connection_piece(world.area, cell)

func _house_connection_style(cell: Vector2i) -> String:
    return Build.connection_style(world.area, cell)

func house_exit_clear(cell: Vector2i) -> bool:
    if world.built_structures.has(cell) or world.blocked.has(cell) or world.resource_objects.has(cell) or world.landmarks.has(cell): return false
    if world.exact_world != null:
        var tile: SourceTile = world.exact_world.tile_at(cell)
        return tile != null and not tile.is_solid and not tile.is_water and not tile.is_lava
    return world._in_bounds(cell) and world.terrain_kind_at(cell) != 0

func house_door_outward(cell: Vector2i) -> Vector2i:
    var left := String(world.built_structures.get(cell + Vector2i.LEFT, {}).get("name", ""))
    var right := String(world.built_structures.get(cell + Vector2i.RIGHT, {}).get("name", ""))
    if left in ["ROOF", "DOOR"] and right in ["ROOF", "DOOR"] and (left == "ROOF" or right == "ROOF"):
        return Vector2i.UP
    if _house_connection_piece(cell) in ["WALL", "ROOF"]:
        if house_exit_clear(cell + Vector2i.LEFT): return Vector2i.LEFT
        if house_exit_clear(cell + Vector2i.RIGHT): return Vector2i.RIGHT
        return Vector2i.ZERO
    return Vector2i.DOWN

func refresh_connected_structures_around(center: Vector2i) -> void:
    var out := _out()
    Build.connect_around(world.area, _player(center), center, out)
    world.field_moves.play_rule(out)

## The look of the pieces joined around `center` (rules/build.gd "restyle"):
## each drawn the way its data and its neighbours say it connects, with the
## door rugs and bridge supports that go with them.
func restyle_around(center: Vector2i) -> void:
    var refresh_cells: Array[Vector2i] = [center, center + Vector2i.LEFT, center + Vector2i.RIGHT, center + Vector2i.UP, center + Vector2i.DOWN]
    # Source desert roof inner corners also depend on diagonal neighbors.
    for offset in [Vector2i(-1,-1),Vector2i(1,-1),Vector2i(-1,1),Vector2i(1,1)]:
        if _house_connection_style(center+offset) == "DESERT" and _house_connection_piece(center+offset) == "ROOF":
            refresh_cells.append(center+offset)
    for cell in refresh_cells:
        if not world.built_structures.has(cell):
            continue
        var data: Dictionary = world.built_structures[cell]
        var name := String(data.get("name", ""))
        if name == "DOOR":
            var vertical_gate := is_fence_cell(cell + Vector2i.UP) and is_fence_cell(cell + Vector2i.DOWN)
            var gate := bool(data.get("gate", false))
            var door_sprite := data.get("sprite") as Sprite2D
            if is_instance_valid(door_sprite):
                door_sprite.visible = true
                var door_recipe := String(data.get("recipe_name", "DOOR"))
                if String(data.get("house_style", "DEFAULT")) == "DEFAULT" and not gate:
                    for direction in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
                        var neighbor: Dictionary = world.built_structures.get(cell + direction, {})
                        if String(neighbor.get("name", "")) == "WALL":
                            var neighbor_style := String(neighbor.get("house_style", "DEFAULT"))
                            if neighbor_style != "DEFAULT": door_recipe = neighbor_style + " DOOR"
                            break
                door_sprite.texture = SourceWorldData.texture_for("fence1gate1_NS" if vertical_gate else "fence1gate1") if gate else structure_display_texture(door_recipe)
                door_sprite.rotation = 0.0
                door_sprite.position = Vector2(cell * World.TILE) - Vector2(0, maxi(0, int(door_sprite.texture.get_height()) - World.TILE))
                door_sprite.z_index = world._depth_z(cell) + (0 if gate else 1)
                _sync_collision(cell)
            var old_rug := door_sprite.get_node_or_null("SideEntrance") if is_instance_valid(door_sprite) else null
            if is_instance_valid(old_rug):
                door_sprite.remove_child(old_rug)
                old_rug.queue_free()
            name = _house_connection_piece(cell)
            if name == "DOOR": continue
            if is_instance_valid(door_sprite):
                if name == "WALL":
                    var style := _house_connection_style(cell)
                    door_sprite.texture = SOURCE_HOUSE5_WALL_MIDDLE if style == "DEFAULT" else structure_display_texture(style + " WALL")
                var outward := house_door_outward(cell)
                if outward != Vector2i.ZERO and house_exit_clear(cell + outward):
                    var rug := Sprite2D.new()
                    rug.name = "SideEntrance"
                    rug.texture = SourceWorldData.texture_for("rug2_right" if outward == Vector2i.LEFT else "rug2_left" if outward == Vector2i.RIGHT else "rug2")
                    rug.centered = false
                    rug.position = Vector2(outward * World.TILE)
                    rug.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
                    # It is floor. As the door's child it took the door's depth
                    # and was drawn over anyone standing on it; put it at ground
                    # level, where a bridge sits, under players and Pokemon.
                    rug.z_as_relative = false
                    rug.z_index = 10
                    door_sprite.add_child(rug)
        if name == "INTERIOR WALL":
            var wall_sprite := data.get("sprite") as Sprite2D
            if is_instance_valid(wall_sprite):
                wall_sprite.texture = SOURCE_HOUSE5_WALL
                wall_sprite.position = Vector2(cell*World.TILE)
                wall_sprite.rotation = 0.0
                wall_sprite.z_index = world._depth_z(cell)
            continue
        if name not in ["FENCE", "WALL", "INTERIOR WALL", "ROOF", "TABLE"]:
            continue
        var sides := Build.connected_sides(world.area, cell, name)
        var north: bool = sides[0]
        var south: bool = sides[1]
        var east: bool = sides[2]
        var west: bool = sides[3]
        var source_style := _house_connection_style(cell)
        var horizontal := east or west
        var vertical := north or south
        var sprite := data.get("sprite") as Sprite2D
        if is_instance_valid(sprite):
            var suffix := ("N" if north else "") + ("S" if south else "") + ("E" if east else "") + ("W" if west else "")
            var connected_path := ""
            if name == "FENCE":
                # Single vertical ends use the authored NS tile too. Rotating
                # a non-centered horizontal sprite swings it into the next cell.
                if vertical and not horizontal:
                    suffix = "NS"
                connected_path = "res://assets/source_0_8_11/tiles/fence1%s.png" % (
                    "" if suffix in ["", "E", "W", "EW"] else "_" + suffix)
            elif name == "TABLE":
                var table_part: String = {"":"default", "E":"left1", "W":"right1", "EW":"middle1", "NS":"middle2", "N":"down1", "S":"up1"}.get(suffix, suffix)
                connected_path = "res://assets/source_0_8_11/tiles/buildings/house_table1_%s.png" % table_part
            var house_style := source_style
            if name == "ROOF" and house_style == "DEFAULT" and suffix.length() >= 2:
                connected_path = "res://assets/source_0_8_11/tiles/buildings/house5_roof_%s.png" % suffix
            elif name == "WALL" and house_style == "DEFAULT" and horizontal:
                connected_path = "res://assets/source_0_8_11/tiles/buildings/%s" % (
                    "house5_middle1.png" if east and west else "house5_left1.png" if east else "house5_right1.png"
                )
            if name == "ROOF" or (SourceHouseStyles.STYLES.has(house_style) and name == "WALL"):
                # Java north is screen-up for player-built shells.
                var ext := suffix
                if name == "WALL":
                    if house_style != "STILT":
                        if east and west and not north and not south: ext = "NEW"
                        if ext.length() <= 1: ext += "N"
                    elif ext.is_empty(): ext = "S"
                elif house_style != "STILT":
                    if ext.is_empty(): ext = "middle1"
                    if east and west and not north and not south: ext = "middle1"
                    elif (north or south) and not east and not west: ext = "NSEW"
                    elif ext.length() == 1: ext = "right1" if west else "left1" if east else ""
                    if house_style == "DESERT" and suffix.length() >= 3:
                        for corner in ["SE", "SW", "NE", "NW"]:
                            var offset := Vector2i(1 if "E" in corner else -1, -1 if "N" in corner else 1)
                            if corner[0] in suffix and corner[1] in suffix and _house_connection_piece(cell+offset) != "ROOF":
                                ext = corner + "inner"
                                break
                sprite.texture = SourceHouseStyles.roof_texture(house_style, ext) if name == "ROOF" else SourceHouseStyles.texture(house_style, name, ext)
                sprite.rotation_degrees = 0
                sprite.position.y = cell.y * World.TILE - maxi(0, int(sprite.texture.get_height()) - World.TILE)
                if bool(data.get("window", false)): refresh_shell_attachment(cell)
                continue
            if not connected_path.is_empty() and ResourceLoader.exists(connected_path):
                sprite.texture = load(connected_path)
                sprite.rotation_degrees = 0.0
            else:
                var display_name := name
                if house_style != "DEFAULT" and name in ["WALL", "ROOF", "DOOR"]:
                    display_name = "%s %s" % [house_style, name]
                sprite.texture = structure_display_texture(display_name, int(data.get("variant", 0)))
                sprite.rotation_degrees = 90.0 if vertical and not horizontal and name not in ["WALL", "INTERIOR WALL", "ROOF", "BRIDGE"] else 0.0
            if bool(data.get("window", false)):
                refresh_shell_attachment(cell)
    _refresh_bridge_support(center)
    _refresh_bridge_support(center+Vector2i.UP)

## The collision of the piece at `cell` as its data says it is solid.
func _sync_collision(cell: Vector2i) -> void:
    var data: Dictionary = world.built_structures.get(cell, {})
    if data.is_empty(): return
    var collision := data.get("collision") as CollisionBox
    var solid := bool(data.get("solid", false))
    if solid and not is_instance_valid(collision):
        var body := world.get_node_or_null("WorldCollision") as CollisionBody
        if body != null:
            collision = world._add_block_collision(body, cell.x, cell.y)
    elif not solid and is_instance_valid(collision):
        collision.queue_free()
        collision = null
    data["collision"] = collision

func _refresh_bridge_support(cell: Vector2i) -> void:
    var data: Dictionary = world.built_structures.get(cell,{})
    if String(data.get("name","")) != "BRIDGE": return
    var deck := data.get("sprite") as Sprite2D
    if not is_instance_valid(deck): return
    deck.z_index = 10
    deck.rotation = 0.0
    var lower := deck.get_node_or_null("SourceBridgeSupport") as Sprite2D
    var below := cell+Vector2i.DOWN
    var visible_support := not world.built_structures.has(below) and _bridge_surface_at(below)
    if lower == null and visible_support:
        lower = Sprite2D.new()
        lower.name = "SourceBridgeSupport"
        lower.texture = preload("res://assets/source_0_8_11/tiles/bridge1_lower.png")
        lower.centered = false
        lower.position = Vector2(0,World.TILE)
        lower.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
        deck.add_child(lower)
    if lower != null: lower.visible = visible_support

## What is built inside a house on the tile behind one piece of its outside,
## on every floor (rules/remove.gd interior_cells_behind).
func house_interior_cells_behind(cell: Vector2i) -> Array[Vector2i]:
    return Remove.interior_cells_behind(world.area, _player(cell), cell)

func remove_structure(cell: Vector2i, refund: bool) -> void:
    var out := _out()
    Remove.remove(world.area, _player(cell), cell, refund, out)
    world.field_moves.play_rule(out)

func remove_structure_with_field_move(cell: Vector2i, move: String) -> bool:
    var result := Remove.apply(world.area, _player(cell), {"cell": cell, "move": move}, world.rng)
    world.field_moves.play_rule(result)
    return result.ok

func is_fence_cell(cell: Vector2i) -> bool:
    return Build.is_fence_cell(world.area, cell)

func refresh_shell_attachment(cell: Vector2i) -> void:
    var data: Dictionary = world.built_structures.get(cell, {})
    var shell := data.get("sprite") as Sprite2D
    if not is_instance_valid(shell): return
    if world.built_house_interior_cells.has(cell) and String(data.get("name", "")) not in ["INTERIOR WALL", "WALL", "ROOF", "FLOOR"]:
        shell.z_index = _house_piece_z(String(data.get("name", "")), cell)
    var wall_torch := shell.get_node_or_null("TORCH") as Sprite2D
    if bool(data.get("torch", false)) and shell.texture != null:
        if wall_torch == null:
            wall_torch = Sprite2D.new()
            wall_torch.name = "TORCH"
            wall_torch.centered = false
            wall_torch.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
            shell.add_child(wall_torch)
        wall_torch.texture = world.environment_structure_texture("TORCH", 0)
        # Hung on the face of the wall, a little above the ground.
        wall_torch.position = Vector2(0, shell.texture.get_height() - 24)
    elif wall_torch != null:
        shell.remove_child(wall_torch)
        wall_torch.queue_free()
    for kind in ["WINDOW", "CHIMNEY"]:
        if not bool(data.get(kind.to_lower(), false)): continue
        var part := shell.get_node_or_null(kind) as Sprite2D
        if part == null:
            part = Sprite2D.new()
            part.name = kind
            part.centered = false
            shell.add_child(part)
        part.texture = structure_display_texture(kind)
        if kind == "WINDOW":
            var window_recipe := String(data.get("window_recipe", "WINDOW"))
            part.hide()
            var facade := TexturePixels.of(shell.texture)
            var window_pixels := TexturePixels.of(preload("res://assets/source_0_8_11/tiles/buildings/exteriorwindows1.png"))
            if window_recipe == "INDOOR WINDOW 1":
                window_pixels = TexturePixels.of(preload("res://assets/source_0_8_11/tiles/buildings/exteriorwindows1-revertme.png"))
            elif window_recipe == "INDOOR WINDOW 2":
                window_pixels = TexturePixels.of(structure_display_texture(window_recipe, int(data.get("window_variant",0))))
            var wall_neighbors: Array[String] = ["WALL", "INTERIOR WALL", "DOOR", "WINDOW"]
            var east := String(world.built_structures.get(cell + Vector2i.RIGHT, {}).get("name", "")) in wall_neighbors
            var west := String(world.built_structures.get(cell + Vector2i.LEFT, {}).get("name", "")) in wall_neighbors
            var source_style := String(data.get("house_style", "DEFAULT"))
            if SourceHouseStyles.STYLES.has(source_style):
                east = east and (String(world.built_structures.get(cell+Vector2i.RIGHT,{}).get("name","")) == "DOOR" or String(world.built_structures.get(cell+Vector2i.RIGHT,{}).get("house_style","")) == source_style)
                west = west and (String(world.built_structures.get(cell+Vector2i.LEFT,{}).get("name","")) == "DOOR" or String(world.built_structures.get(cell+Vector2i.LEFT,{}).get("house_style","")) == source_style)
            for x in range(mini(16, facade.get_width())):
                for y in range(mini(8, facade.get_height())):
                    if (x < 8 and not east) or (x >= 8 and not west) or (east and west):
                        facade.set_pixel(x, y, window_pixels.get_pixel(x, y))
            shell.texture = TexturePixels.texture_from(facade)
        else:
            var colors: Array[Color] = []
            var roof := TexturePixels.of(shell.texture)
            for y in range(roof.get_height()):
                for x in range(roof.get_width()):
                    var color := roof.get_pixel(x,y)
                    if color.a == 0 or color in [Color.BLACK,Color.WHITE,Color8(0,251,0)]: continue
                    if not colors.has(color): colors.append(color)
                    if colors.size() == 2: break
                if colors.size() == 2: break
            if colors.size() == 2:
                colors.sort_custom(func(a: Color,b: Color): return a.r+a.g+a.b > b.r+b.g+b.b)
                var smoke := TexturePixels.of((world.structure_textures["CHIMNEY"] as Texture2D))
                for y in range(smoke.get_height()):
                    for x in range(smoke.get_width()):
                        var value := smoke.get_pixel(x,y).to_rgba32()
                        if value == 4285786111: smoke.set_pixel(x,y,colors[0])
                        elif value == 4280921599: smoke.set_pixel(x,y,colors[1])
                var colored := ImageTexture.create_from_image(smoke)
                part.set_meta("chimney_atlas", colored)
                part.texture = part.texture.duplicate()
                (part.texture as AtlasTexture).atlas = colored
            part.position = Vector2(0, -16)
        part.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST

func _is_house_decoration(build_name: String) -> bool:
    return Build.is_house_decoration(build_name)

func _torch_wall_at(cell: Vector2i) -> bool:
    return Build.torch_wall_at(world.area, cell)

func _is_window_recipe(build_name: String) -> bool:
    return Build.is_window(build_name)

## A window, clock or carpet gone (rules "decoration_gone").
func undraw_decoration(cell: Vector2i) -> void:
    var decoration := world.built_house_decoration_sprites.get(cell) as Sprite2D
    if is_instance_valid(decoration):
        decoration.queue_free()
    world.built_house_decoration_sprites.erase(cell)

func draw_house_decoration(cell: Vector2i) -> void:
    var data: Dictionary = world.built_house_decorations.get(world._built_house_paint_key(cell), {})
    if data.is_empty(): return
    var layer := world.source_area_layers.get("HOUSE") as Node2D
    if not is_instance_valid(layer): return
    var sprite := world.built_house_decoration_sprites.get(cell) as Sprite2D
    if not is_instance_valid(sprite):
        sprite = Sprite2D.new()
        sprite.centered = false
        sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
        sprite.z_as_relative = false
        layer.add_child(sprite)
        world.built_house_decoration_sprites[cell] = sprite
    sprite.position = Vector2(cell * World.TILE)
    if String(data.name) == "DIG GROUND":
        var tile := SourceTile.new("green1", Vector2i.ZERO)
        FieldMoveData.apply_dig_terrain(tile, String(data.get("dig_choice", "FOREST")))
        var original_base := String(data.get("dig_base_name", ""))
        sprite.texture = structure_display_texture("FLOOR") if original_base == "FLOOR" else structure_display_texture(original_base, int(data.get("variant", 0))) if not original_base.is_empty() else SourceWorldData.texture_for(tile.name)
        sprite.z_index = -4
        var hole := sprite.get_node_or_null("DigHole") as Sprite2D
        if bool(data.get("dig_hole", false)):
            if hole == null:
                hole = Sprite2D.new();hole.name = "DigHole";hole.centered = false;sprite.add_child(hole)
            hole.texture = SourceWorldData.texture_for("hole1")
        elif is_instance_valid(hole):
            sprite.remove_child(hole);hole.queue_free()
        return
    var old_hole := sprite.get_node_or_null("DigHole")
    if is_instance_valid(old_hole): sprite.remove_child(old_hole);old_hole.queue_free()
    sprite.texture = structure_display_texture(String(data.name), int(data.get("variant",0)))
    sprite.z_index = -4 if String(data.name).begins_with("CARPET ") else world._depth_z(cell, World.HOUSE_FURNITURE_Z)

func restore_house_decorations() -> void:
    for cell in world.built_house_interior_cells: draw_house_decoration(cell)
    for cell in world.built_house_paintable_walls: draw_house_decoration(cell)

func interact_house_window(cell: Vector2i) -> bool:
    if world.active_area_id == "OVERWORLD":
        var wall: Dictionary = world.built_structures.get(cell, {})
        var kind := String(wall.get("window_recipe", ""))
        if not bool(wall.get("window", false)) or not kind.begins_with("INDOOR WINDOW "):
            return false
        wall["window_variant"] = wrapi(int(wall.get("window_variant", 0)) + 1, 0, 3 if kind.ends_with("1") else 2)
        refresh_shell_attachment(cell)
        world.play_source_sound("seed1")
        return true
    if world.active_area_id != "HOUSE": return false
    var key := world._built_house_paint_key(cell)
    var data: Dictionary = world.built_house_decorations.get(key,{})
    var build_name := String(data.get("name",""))
    if not _is_window_recipe(build_name): return false
    if build_name == "INDOOR WINDOW 1": return true
    data.variant = wrapi(int(data.get("variant",0))+1,0,2 if build_name.ends_with("2") else 3)
    world.area.put("built_house_decorations", key, data)
    draw_house_decoration(cell)
    world.play_source_sound("seed1")
    return true

func _private_chest_texture(source:Texture2D)->Texture2D:
    var key=source.get_instance_id()
    if not world.coop_private_chest_cache.has(key):
        var source_image=TexturePixels.of(source)
        if source_image.is_compressed():source_image.decompress()
        var image=source_image.get_region(Rect2i(0,16,16,16))
        for y in range(16):
            for x in range(16):
                var pixel=image.get_pixel(x,y)
                if pixel.a<=0 or maxf(pixel.r,maxf(pixel.g,pixel.b))<0.15:continue
                var light=clampf(pixel.get_luminance()*1.5,0,1)
                var purple=Color(0.24,0.10,0.36).lerp(Color(0.84,0.58,1.0),light)
                purple.a=pixel.a;image.set_pixel(x,y,purple)
        world.coop_private_chest_cache[key]=ImageTexture.create_from_image(image)
    return world.coop_private_chest_cache[key]
