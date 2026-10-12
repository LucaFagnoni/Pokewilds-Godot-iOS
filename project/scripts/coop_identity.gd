extends RefCounted
const Paths=preload("res://scripts/game_data_paths.gd")
static func token() -> String:
    var path:=Paths.path("coop_identity.cfg")
    var config:=ConfigFile.new()
    if config.load(path)==OK:
        var existing:=String(config.get_value("player","token",""))
        if existing.length()==64 and existing.is_valid_hex_number():return existing
        return "" # Never silently replace a damaged identity and lose its online saves.
    if FileAccess.file_exists(path):return ""
    var value:=preload("res://scripts/coop_random.gd").hex(32)
    config.set_value("player","token",value)
    if config.save(path+".pending")!=OK:return ""
    if DirAccess.rename_absolute(path+".pending",path)!=OK:return ""
    return value

static func mods() -> Dictionary:
    var packs=load("res://scripts/native_mod_pack.gd")
    if not packs.last_error.is_empty():return {"error":"Resolve mod loading errors before joining."}
    var entries: Array=[]
    for row in packs.library():
        if not row.get("enabled",false):continue
        var path:=String(row.get("path",""))
        if not FileAccess.file_exists(path):return {"error":"An enabled mod package is missing."}
        entries.append({"id":String(row.id),"name":String(row.get("name","MOD")),
            "version":String(row.get("version","")),"sha256":FileAccess.get_sha256(path)})
    # Ordered content hashes detect same-name edits and differing override order.
    return {"entries":entries,"digest":JSON.stringify(entries,"",true,true).sha256_text()}
