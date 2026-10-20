extends RefCounted
# Same authored raster as main's old MAP, built without a multi-second frame.
static func build(main: Node, bounds: Rect2i, serial: int) -> Texture2D:
    var world = main.world
    var exact = world.exact_world
    var key := cache_key(main, bounds)
    if main.map_art_cache != null and main.map_art_cache_key == key:
        return main.map_art_cache
    var context := context_key(main, bounds)
    var started := Time.get_ticks_usec()
    var deadline := started + 4000
    var size: Vector2i = bounds.size * main.SOURCE_MAP_TILE_PIXELS
    var image: Image = world.interior_map_image(bounds)
    var indoor := image != null
    if image == null:
        # Construct the old alternating-cell fog in native byte-array blocks.
        var rows: Array[PackedByteArray] = []
        for parity in [0, 1]:
            var row := PackedByteArray()
            for x in range(bounds.size.x):
                var color := Color(0.025,0.035,0.03,1) if (x+parity)%2 == 0 else Color(0.045,0.055,0.05,1)
                for _pixel in range(main.SOURCE_MAP_TILE_PIXELS):
                    row.append_array(PackedByteArray([int(color.r*255),int(color.g*255),int(color.b*255),255]))
            rows.append(row)
        # Two rows of cells, copied down the map. Building the whole map as
        # one growing byte array and then copying it into the image held
        # about 32 MB more at once (a 688x577 world).
        var bytes := PackedByteArray()
        for y in range(main.SOURCE_MAP_TILE_PIXELS * 2):
            bytes.append_array(rows[int(y/main.SOURCE_MAP_TILE_PIXELS)%2])
        var strip := Image.create_from_data(size.x,main.SOURCE_MAP_TILE_PIXELS * 2,false,Image.FORMAT_RGBA8,bytes)
        image = Image.create(size.x,size.y,false,Image.FORMAT_RGBA8)
        for y in range(0, size.y, strip.get_height()):
            image.blit_rect(strip,Rect2i(Vector2i.ZERO,strip.get_size()),Vector2i(0,y))
    var cells: Array[int] = []
    if not indoor:
        for raw_key in world.discovered_cells.keys():
            var cell: Vector2i = world._cell_from_key(String(raw_key))
            if bounds.has_point(cell):
                cells.append((cell.y-bounds.position.y)*bounds.size.x+cell.x-bounds.position.x)
                image.fill_rect(Rect2i((cell-bounds.position)*main.SOURCE_MAP_TILE_PIXELS,Vector2i.ONE*main.SOURCE_MAP_TILE_PIXELS),Color(0.025,0.035,0.03,1))
            if Time.get_ticks_usec() >= deadline:
                await main.get_tree().process_frame
                if not is_instance_valid(main) or not is_instance_valid(world) or (serial >= 0 and serial != main.map_build_serial) or context_key(main, bounds) != context: return null
                deadline=Time.get_ticks_usec()+4000
        cells.sort()
    var textures := {}
    var previews := {}
    var hidden := {}
    for upper in ([] if indoor else [false,true]):
        for cell_index in cells:
            var cell:=bounds.position+Vector2i(cell_index%bounds.size.x,int(cell_index/bounds.size.x))
            var dest: Vector2i = (cell-bounds.position)*main.SOURCE_MAP_TILE_PIXELS
            if world.exact_world_mode and exact != null:
                var tile: SourceTile = exact.tile_at(cell)
                if tile != null:
                    var spec: Dictionary = SourceWorldData.render_spec(tile,upper)
                    main._paint_source_map_tile(image,dest,spec,textures,previews)
                    # Mask only actual artwork overhang into undiscovered cells.
                    var region: Rect2 = spec.get("region",Rect2(0,0,16,16))
                    var offset: Vector2 = spec.get("offset",Vector2.ZERO)
                    var lo := cell+Vector2i((offset/16.0).floor())
                    var hi := cell+Vector2i(((offset+region.size)/16.0).ceil())
                    for y in range(lo.y,hi.y):
                        for x in range(lo.x,hi.x):
                            var at:=Vector2i(x,y)
                            if bounds.has_point(at) and not world.is_cell_discovered(at):hidden[at]=true
            elif not upper:
                image.fill_rect(Rect2i(dest,Vector2i.ONE*main.SOURCE_MAP_TILE_PIXELS),world.map_color_for_cell(cell))
            if Time.get_ticks_usec() >= deadline:
                await main.get_tree().process_frame
                if not is_instance_valid(main) or not is_instance_valid(world) or (serial >= 0 and serial != main.map_build_serial) or context_key(main, bounds) != context:return null
                deadline=Time.get_ticks_usec()+4000
    if not indoor:
        main._paint_built_structures_on_map(image,bounds.position)
        # Use the drawn sprite bounds, including offset and frame dimensions.
        for cell in world.built_structures:
            var actor: Sprite2D = world.built_structures[cell].get("sprite")
            if not is_instance_valid(actor) or actor.texture == null:continue
            var extent:Vector2=actor.region_rect.size if actor.region_enabled else actor.texture.get_size()/Vector2(actor.hframes,actor.vframes)
            var at:Vector2=actor.position+actor.offset-(extent*0.5 if actor.centered else Vector2.ZERO)
            var lo:=Vector2i((at/16.0).floor())
            var hi:=Vector2i(((at+extent)/16.0).ceil())
            for y in range(lo.y,hi.y):
                for x in range(lo.x,hi.x):
                    var hidden_cell:=Vector2i(x,y)
                    if bounds.has_point(hidden_cell) and not world.is_cell_discovered(hidden_cell):hidden[hidden_cell]=true
            if Time.get_ticks_usec() >= deadline:
                await main.get_tree().process_frame
                if not is_instance_valid(main) or not is_instance_valid(world) or (serial >= 0 and serial != main.map_build_serial) or context_key(main, bounds) != context:return null
                deadline=Time.get_ticks_usec()+4000
        for cell in hidden:
            var local:Vector2i=cell-bounds.position
            var shade:=Color(0.025,0.035,0.03,1) if (local.x+local.y)%2==0 else Color(0.045,0.055,0.05,1)
            image.fill_rect(Rect2i(local*main.SOURCE_MAP_TILE_PIXELS,Vector2i.ONE*main.SOURCE_MAP_TILE_PIXELS),shade)
    if not is_instance_valid(main) or not is_instance_valid(world) or (serial >= 0 and serial != main.map_build_serial) or context_key(main, bounds) != context:return null
    var texture:=ImageTexture.create_from_image(image)
    main.map_art_cache_context=context
    main.map_art_cache_key=key
    main.map_art_cache=texture
    return texture

static func cache_key(main: Node, bounds: Rect2i) -> String:
    var world = main.world
    var exact = world.exact_world
    return str([exact.get_instance_id() if exact != null else 0,
        bounds, world.active_area_id, world.active_built_house_door,
        world.map_art_revision, world.discovered_cells.size(), world.built_structures.size()])

static func context_key(main: Node, bounds: Rect2i) -> String:
    var exact = main.world.exact_world
    return str([exact.get_instance_id() if exact != null else 0, bounds, main.world.active_area_id, main.world.active_built_house_door])
