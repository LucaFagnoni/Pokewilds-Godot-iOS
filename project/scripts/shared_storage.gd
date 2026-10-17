extends RefCounted
## The Pokemon kept in single-player STORAGE BOXES belong to the device, not
## to one world: a Pokemon stored in one single-player save can be taken out
## in another. Online worlds keep their own storage and never use this file.
##
## The file is written only when a world is saved, together with that save, so
## what is in storage always matches a saved party. Each write is numbered; a
## save remembers the number it was written with. A save holding a higher
## number than this file was saved without the file being updated (the game
## was closed between the two writes), and its own copy of storage is used.
const Paths=preload("res://scripts/game_data_paths.gd")

## Beside the saves, so that it travels with them in the shared save folder.
## Not ".json": every such file in that folder is listed as a world to load.
static func path()->String:
    return Paths.path("saves/shared_storage.box")

static func read()->Dictionary:
    for candidate in [path(),path()+".bak"]:
        if not FileAccess.file_exists(candidate):continue
        var envelope=JSON.parse_string(FileAccess.get_file_as_string(candidate))
        if not envelope is Dictionary or not envelope.get("payload") is String:continue
        if envelope.payload.sha256_text()!=envelope.get("sha256",""):continue
        var data=JSON.parse_string(envelope.payload)
        if not data is Dictionary or not data.get("storage") is Dictionary:continue
        return {"exists":true,"serial":int(data.get("serial",0)),"storage":data.storage}
    return {"exists":false,"serial":0,"storage":{}}

static func write(storage:Dictionary,serial:int)->Error:
    var target:=path()
    var error:=DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(target.get_base_dir()))
    if error!=OK and error!=ERR_ALREADY_EXISTS:return error
    var payload:=JSON.stringify({"format":1,"serial":serial,"storage":storage})
    var file:=FileAccess.open(target+".pending",FileAccess.WRITE)
    if file==null:return FileAccess.get_open_error()
    file.store_string(JSON.stringify({"payload":payload,"sha256":payload.sha256_text()}))
    file.flush();error=file.get_error();file.close()
    if error!=OK:return error
    var written=JSON.parse_string(FileAccess.get_file_as_string(target+".pending"))
    if not written is Dictionary or written.get("payload")!=payload:return ERR_FILE_CORRUPT
    if FileAccess.file_exists(target):
        error=DirAccess.copy_absolute(target,target+".bak")
        if error!=OK:return error
    return DirAccess.rename_absolute(target+".pending",target)

## The storage a single-player world starts with, and the number it was last
## written under. `saved` is the storage held in the save being loaded ({} for
## a new game); `marked` and `save_serial` say whether, and when, that save
## was last written by a game that shares storage.
static func adopt(saved:Dictionary,marked:bool,save_serial:int)->Dictionary:
    var shared:=read()
    if marked:
        if save_serial>int(shared.serial):return {"storage":saved.duplicate(true),"serial":save_serial}
        return {"storage":shared.storage,"serial":int(shared.serial)}
    # A save from before storage was shared brings its boxes with it, once:
    # it is marked the next time it is saved.
    var merged:Dictionary=shared.storage
    for key in saved:
        if not saved[key] is Array:continue
        var box:Array=merged.get(key,[]) if merged.get(key,[]) is Array else []
        box.append_array(saved[key].duplicate(true))
        merged[key]=box
    return {"storage":merged,"serial":int(shared.serial)}
