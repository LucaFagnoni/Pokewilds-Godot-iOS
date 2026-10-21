extends RefCounted
## Online checkpoints cannot enter the local save index or local save directory.
const Paths=preload("res://scripts/game_data_paths.gd")
const Store=preload("res://scripts/coop_store.gd")
var root:String

func _init(directory:String="")->void:
    root=Paths.path("online_worlds") if directory.is_empty() else directory

func path_for(id:String)->String:
    return root.path_join(id).path_join("host.save") if Store.valid_id(id) else ""

func save_host(id:String,actor:String,data:Dictionary)->Error:
    var path=path_for(id)
    if path.is_empty() or actor.is_empty():return ERR_INVALID_PARAMETER
    var error=DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
    if error!=OK:return error
    var payload=JSON.stringify({"mode":"online","format":1,"id":id,"owner":actor,"game":data},"",true,true)
    var file=FileAccess.open(path+".pending",FileAccess.WRITE)
    if file==null:return FileAccess.get_open_error()
    file.store_string(JSON.stringify({"payload":payload,"sha256":payload.sha256_text()}))
    file.flush();error=file.get_error();file.close()
    if error!=OK:return error
    if _read(path+".pending",id,actor).is_empty():return ERR_FILE_CORRUPT
    if FileAccess.file_exists(path):
        error=DirAccess.copy_absolute(path,path+".bak")
        if error!=OK:return error
    return DirAccess.rename_absolute(path+".pending",path)

func _read(path:String,id:String,actor:String)->Dictionary:
    if not FileAccess.file_exists(path):return {}
    var parser=JSON.new()
    if parser.parse(FileAccess.get_file_as_string(path))!=OK:return {}
    var envelope=parser.data
    if not envelope is Dictionary or not envelope.get("payload") is String:return {}
    if envelope.payload.sha256_text()!=envelope.get("sha256",""):return {}
    if parser.parse(envelope.payload)!=OK:return {}
    var value=parser.data
    if not value is Dictionary or value.get("mode")!="online" or value.get("format")!=1:return {}
    if value.get("id")!=id or value.get("owner")!=actor or not value.get("game") is Dictionary:return {}
    return value.game

func load_host(id:String,actor:String)->Dictionary:
    var path=path_for(id)
    if path.is_empty():return {}
    var data=_read(path,id,actor)
    return _read(path+".bak",id,actor) if data.is_empty() else data

## Deletes an online world from this device (SAVED WORLDS' bin): its whole
## folder, with its saves, journal, backups, snapshots and caches.
func delete_world(id:String)->Error:
    if not Store.valid_id(id):return ERR_INVALID_PARAMETER
    return _remove_tree(root.path_join(id))

static func _remove_tree(path:String)->Error:
    var directory=DirAccess.open(path)
    if directory==null:return DirAccess.get_open_error()
    directory.include_hidden=true
    for name in directory.get_directories():
        var error=_remove_tree(path.path_join(name))
        if error!=OK:return error
    for name in directory.get_files():
        var error=DirAccess.remove_absolute(path.path_join(name))
        if error!=OK:return error
    return DirAccess.remove_absolute(path)

func entries(actor:String)->Array[Dictionary]:
    var result:Array[Dictionary]=[]
    var directory=DirAccess.open(root)
    if directory==null:return result
    for id in directory.get_directories():
        if not Store.valid_id(id):continue
        var data=load_host(id,actor)
        if data.is_empty():continue
        result.append({"id":id,"data":data,"modified":FileAccess.get_modified_time(path_for(id))})
    result.sort_custom(func(a,b):return int(a.modified)>int(b.modified))
    return result
