extends RefCounted
## Dedicated servers saved on this device: {"servers":[{"name","address","id","password"}]}
## in coop_servers.json inside the game data folder, so the list survives app updates.
## The first run turns the old "last address joined" (coop_direct.cfg) into one entry.
const Paths=preload("res://scripts/game_data_paths.gd")
const FILE:="coop_servers.json"
const LEGACY_FILE:="coop_direct.cfg"
const LIMITS:={"name":24,"address":48,"id":16,"password":32}

static func limit(field:String)->int:
    return int(LIMITS.get(field,32))

## Letters, digits, "_" and "-" only.
static func id_char(character:String)->bool:
    return character.length()==1 and (character in "_-" or (character.to_lower() in "abcdefghijklmnopqrstuvwxyz0123456789"))

## One entry with every field cut to its limit; the name falls back to the address.
static func clean(source:Dictionary)->Dictionary:
    var address:=String(source.get("address","")).strip_edges().left(limit("address"))
    var id:=""
    for character in String(source.get("id","")).strip_edges().left(limit("id")):
        if id_char(character):id+=character
    var name:=String(source.get("name","")).strip_edges().left(limit("name"))
    return {"name":name if not name.is_empty() else address.left(limit("name")),"address":address,"id":id,
        "password":String(source.get("password","")).strip_edges().left(limit("password"))}

static func load_all()->Array[Dictionary]:
    var list:Array[Dictionary]=[]
    var path:=Paths.path(FILE)
    if not FileAccess.file_exists(path):
        var old:=ConfigFile.new();old.load(Paths.path(LEGACY_FILE))
        var address:=String(old.get_value("join","address","")).strip_edges()
        if address.is_empty():return list
        list.append(clean({"address":address,"password":old.get_value("join","password","")}))
        save_all(list)
        return list
    var parsed=JSON.parse_string(FileAccess.get_file_as_string(path))
    if parsed is Dictionary and parsed.get("servers") is Array:
        for item in parsed.servers:
            if item is Dictionary and not String(item.get("address","")).strip_edges().is_empty():list.append(clean(item))
    return list

## Written to a .pending file first, so a crash never leaves half a list.
static func save_all(list:Array[Dictionary])->bool:
    var path:=Paths.path(FILE)
    var file:=FileAccess.open(path+".pending",FileAccess.WRITE)
    if file==null:return false
    file.store_string(JSON.stringify({"servers":list},"\t"));file.close()
    return DirAccess.rename_absolute(path+".pending",path)==OK
