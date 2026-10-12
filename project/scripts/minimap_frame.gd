extends RefCounted
static var cache: Dictionary={}
static func ring(frame: int, texture: Texture2D) -> Texture2D:
    if cache.has(frame):return cache[frame]
    var source:=texture.get_image()
    var result:=Image.create(128,128,false,Image.FORMAT_RGBA8)
    result.fill(Color.TRANSPARENT)
    var edge_width:=maxi(1,source.get_width()-16)
    for y in range(128):
        for x in range(128):
            var offset:=Vector2(x+0.5,y+0.5)-Vector2(64,64)
            var radius:=offset.length()
            if radius<53.0 or radius>63.0:continue
            var angle:=fposmod(offset.angle()+PI*0.5,TAU)
            var sx:=8+posmod(int(angle*30.0),edge_width)
            var sy:=clampi(int((63.0-radius)*0.7),0,mini(7,source.get_height()-1))
            var ink:=source.get_pixel(sx,sy)
            if ink.a<0.5:ink=Color.WHITE
            result.set_pixel(x,y,ink)
    cache[frame]=ImageTexture.create_from_image(result)
    return cache[frame]
