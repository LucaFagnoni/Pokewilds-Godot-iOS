extends RefCounted
# Atlas coordinates from 0.8.11 Tile.init; connection rules from PkmnMap.
const STYLES := {"DESERT":6, "LAKE":9, "STILT":7, "SNOW":8}
static var cache: Dictionary = {}
static func roof_texture(style: String, suffix: String) -> Texture2D:
    # The two older named recipes use source house 8 and the bundled house 12 atlas.
    if style in ["SAVANNA", "TUNDRA"]:
        var house := 8 if style == "SAVANNA" else 12
        var root := "res://assets/source_0_8_11/tiles/buildings/house%d_roof_" % house
        if suffix in ["left1", "middle1", "right1"]:
            return load(root + suffix + ".png")
        var result := AtlasTexture.new()
        result.atlas = load(root + "all.png")
        result.region = Rect2(16 - (16 if "E" in suffix else 0) + (16 if "W" in suffix else 0), 16 + (16 if "N" in suffix else 0) - (16 if "S" in suffix else 0), 16, 16)
        return result
    if style == "DEFAULT":
        return load("res://assets/source_0_8_11/tiles/buildings/house5_roof_%s.png" % suffix)
    return texture(style, "ROOF", suffix)
static func texture(style: String, piece: String, suffix: String = "") -> Texture2D:
    if not STYLES.has(style): return null
    var key := style + piece + suffix
    if cache.has(key): return cache[key]
    var house: int = STYLES[style]
    var root := "res://assets/source_0_8_11/tiles/buildings/"
    var file := "house%d" % house
    var region := Rect2(0, 0, 16, 16)
    var ext := suffix
    if house == 7:
        if piece == "ROOF" and ext.is_empty(): ext = "EW"
        file = "res://assets/source_0_8_11/tiles/house7_all.png"
        var wall := {"E":Vector2(0,16),"SE":Vector2(16,16),"W":Vector2(48,16),"SW":Vector2(32,16),"NE":Vector2(160,16),"NEW":Vector2(176,16),"N":Vector2(176,16),"NW":Vector2(192,16),"NSE":Vector2(160,0),"NSEW":Vector2(176,0),"S":Vector2(32,0),"SEW":Vector2(32,0),"NSW":Vector2(192,0)}
        var roof := {"E":Vector2(0,0),"EW":Vector2(16,0),"SE":Vector2(64,0),"W":Vector2(48,0),"SW":Vector2(96,0),"NE":Vector2(64,16),"NEW":Vector2(80,16),"N":Vector2(80,16),"NW":Vector2(96,16),"NSE":Vector2(112,0),"S":Vector2(80,0),"SEW":Vector2(80,0),"NSEW":Vector2(128,0),"NSW":Vector2(144,0)}
        if piece == "DOOR": region.position = Vector2(208,16)
        elif piece == "ROOF": region.position = roof.get(ext, Vector2(16,16))
        else: region.position = wall.get(ext if not ext.is_empty() else "S", Vector2(176,16))
    elif piece == "DOOR":
        file = root + file + "_door1.png"
    else:
        var is_roof := piece == "ROOF"
        if ext.is_empty(): ext = "middle1" if is_roof else "SEW" if house == 8 else "NEW"
        if is_roof: file += "_roof"
        if ext in ["left1", "middle1", "right1"]:
            file = root + file + "_" + ext + ".png"
        else:
            if "inner" in ext: file += "_inner"
            var scale := 16 if house == 8 or (house == 9 and is_roof) else 8
            region.position = Vector2(scale - (scale if "E" in ext else 0) + (scale if "W" in ext else 0), scale + (scale if "N" in ext else 0) - (scale if "S" in ext else 0))
            if house == 8 and not is_roof and not "S" in ext: region.size.y = 20
            file = root + file + "_all.png"
    var atlas := AtlasTexture.new()
    atlas.atlas = load(file)
    atlas.region = region
    cache[key] = atlas
    return atlas
