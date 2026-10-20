extends RefCounted
const TexturePixels = preload("res://scripts/texture_pixels.gd")
## Front portraits are separate from the player's existing back/overworld art.
static var cache:Dictionary={}
static var entries:Dictionary={}

static func texture(main:Node,trainer:Dictionary)->Texture2D:
    if entries.is_empty():entries=JSON.parse_string(FileAccess.get_file_as_string("res://data/coop_trainer_portraits.json"))
    var index=clampi(int(trainer.get("model",0)),0,main.PLAYER_MODEL_NAMES.size()-1)
    var color_index=clampi(int(trainer.get("color",0)),0,main.PLAYER_COLOR_VALUES.size()-1)
    var model:String=main.PLAYER_MODEL_NAMES[index]
    var key=model+"/"+str(color_index)
    if cache.has(key):return cache[key]
    var entry:Dictionary=entries.get(model,{})
    if entry.is_empty():return null
    var source:Texture2D=load(entry.path)
    if source==null:return null
    var pixels=Image.new();pixels.copy_from(TexturePixels.of(source))
    # Bound recoloring work even for the two high-resolution supplied portraits.
    var source_bounds=pixels.get_used_rect()
    if source_bounds.size==Vector2i.ZERO:return null
    pixels=pixels.get_region(source_bounds)
    var initial_scale=minf(1.0,56.0/maxi(pixels.get_width(),pixels.get_height()))
    if initial_scale<1.0:pixels.resize(maxi(1,roundi(pixels.get_width()*initial_scale)),maxi(1,roundi(pixels.get_height()*initial_scale)),Image.INTERPOLATE_NEAREST)
    var target:Color=main.PLAYER_COLOR_VALUES[color_index]
    var palette:Array=entry.color
    var background:Array=entry.get("background",[])
    var tolerance:int=entry.get("tolerance",0)
    for y in range(pixels.get_height()):
        for x in range(pixels.get_width()):
            var pixel=pixels.get_pixel(x,y)
            if pixel.a8==0:continue
            if not background.is_empty() and pixel.r8==int(background[0]) and pixel.g8==int(background[1]) and pixel.b8==int(background[2]):
                pixels.set_pixel(x,y,Color.TRANSPARENT)
            elif absi(pixel.r8-int(palette[0]))<=tolerance and absi(pixel.g8-int(palette[1]))<=tolerance and absi(pixel.b8-int(palette[2]))<=tolerance:
                pixels.set_pixel(x,y,Color(target.r,target.g,target.b,pixel.a))
    var bounds=pixels.get_used_rect()
    if bounds.size==Vector2i.ZERO:return null
    pixels=pixels.get_region(bounds)
    var scale_factor=minf(1.0,56.0/maxi(pixels.get_width(),pixels.get_height()))
    if scale_factor<1.0:pixels.resize(maxi(1,roundi(pixels.get_width()*scale_factor)),maxi(1,roundi(pixels.get_height()*scale_factor)),Image.INTERPOLATE_NEAREST)
    var canvas=Image.create(56,56,false,Image.FORMAT_RGBA8)
    canvas.fill(Color.TRANSPARENT)
    canvas.blit_rect(pixels,Rect2i(Vector2i.ZERO,pixels.get_size()),Vector2i((56-pixels.get_width())/2,56-pixels.get_height()))
    var result=ImageTexture.create_from_image(canvas)
    cache[key]=result
    return result
