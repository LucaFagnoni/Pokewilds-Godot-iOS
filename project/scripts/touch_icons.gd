extends RefCounted
## 12x12 pixel icons for the touch start menu, drawn in code so they follow the
## game's palette without new art files.

const PALETTE := {
    "k": Color("181818"), "w": Color("f8f8f8"), "r": Color("e04038"), "g": Color("a0a0a8"),
    "y": Color("f0c040"), "b": Color("5888e0"), "n": Color("a06838"), "G": Color("68b850"),
}

const ART := {
    "POKEDEX": [
        ".kkkkkkkkkk.", "krrrrrrrrrrk", "krkkkkkkkkrk", "krkbbbbbbkrk", "krkbwbbbbkrk", "krkbbbbbbkrk",
        "krkkkkkkkkrk", "krrrrrrrrrrk", "krkkrrrrgkrk", "krkkrrrgggrk", "krrrrrrrrrrk", ".kkkkkkkkkk."],
    "POKEMON": [
        "....kkkk....", "..kkrrrrkk..", ".krrrrrrrrk.", ".krrrrrrrrk.", "krrrrrrrrrrk", "kkkkkwwkkkkk",
        "kwwwkwwkwwwk", ".kwwwkkwwwk.", ".kwwwwwwwwk.", "..kkwwwwkk..", "....kkkk....", "............"],
    "ITEM": [
        "....kkkk....", "...k....k...", "..kkkkkkkk..", ".knnnnnnnnk.", "knnnnnnnnnnk", "knnnyyynnnnk",
        "knnnykynnnnk", "knnnyyynnnnk", "knnnnnnnnnnk", "knnnnnnnnnnk", ".knnnnnnnnk.", "..kkkkkkkk.."],
    "STORAGE": [
        "............", ".kkkkkkkkkk.", ".kggggggggk.", ".kgbbbbbbgk.", ".kgbwbbbbgk.", ".kgbbbbbbgk.",
        ".kggggggggk.", ".kkkkkkkkkk.", "....kggk....", "..kkkkkkkk..", "..kggggggk..", "..kkkkkkkk.."],
    "MAP": [
        "kkkkkkkkkkkk", "kGGGbbbGGGGk", "kGGbbbGGGyGk", "kGbbbGGGyyGk", "kGGbbGGGGGGk", "kGGGbbGGnGGk",
        "knGGGbbGGGGk", "knnGGGbbGGGk", "kGnnGGGbbGGk", "kGGGGGGGbbbk", "kGGGGGGGGbbk", "kkkkkkkkkkkk"],
    "GUIDE": [
        "............", ".kkkkk.kkkk.", "kwwwwwkwwwwk", "kwkkwwkwkkwk", "kwwwwwkwwwwk", "kwkkkwkwkkwk",
        "kwwwwwkwwwwk", "kwkkwwkwkkwk", "kwwwwwkwwwwk", ".kkkkkkkkkk.", "............", "............"],
    "OPTIONS": [
        "....kkkk....", "..kkggggkk..", ".kgkggggkgk.", ".kggggggggk.", "kggggkkggggk", "kgggkwwkgggk",
        "kgggkwwkgggk", "kggggkkggggk", ".kggggggggk.", ".kgkggggkgk.", "..kkggggkk..", "....kkkk...."],
    "SAVE": [
        "kkkkkkkkkkk.", "kbbwwwwwbbbk", "kbbwwwwwbbbk", "kbbwwkwwbbbk", "kbbwwwwwbbbk", "kbbbbbbbbbbk",
        "kbbbbbbbbbbk", "kbwwwwwwwwbk", "kbwkkkkkkwbk", "kbwwwwwwwwbk", "kbwkkkkkkwbk", "kkkkkkkkkkkk"],
    "EXIT": [
        "..kkkkkkk...", "..knnnnnk...", "..knnnnnk...", "..knnnnnk..k", "..knnnnnk.kk", "..knnnynkkkk",
        "..knnnnnk.kk", "..knnnnnk..k", "..knnnnnk...", "..knnnnnk...", "..knnnnnk...", ".kkkkkkkkk.."],
}

static var _cache := {}

static func icon(name: String) -> Texture2D:
    if _cache.has(name): return _cache[name]
    var rows: Array = ART.get(name, ART["POKEMON"])
    var image := Image.create(12, 12, false, Image.FORMAT_RGBA8)
    for y in 12:
        var row := String(rows[y])
        for x in 12:
            var key := row[x]
            image.set_pixel(x, y, PALETTE[key] if PALETTE.has(key) else Color.TRANSPARENT)
    _cache[name] = ImageTexture.create_from_image(image)
    return _cache[name]
