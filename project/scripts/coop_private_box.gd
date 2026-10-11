extends RefCounted
## The player's private storage box, kept on their own device so it goes with
## them into every ONLINE world they host or join.
##
## Inside a world the host still commits every deposit and withdrawal, exactly
## as before. This file mirrors the box after each change, and is offered to
## the next world on entry. `removed` remembers what the player has taken out,
## so an old copy left behind in another world cannot bring a Pokemon back.
const Paths=preload("res://scripts/game_data_paths.gd")
const CAPACITY:=4096
const REMEMBERED_REMOVALS:=8192

static func path()->String:
    return Paths.path("private_box.json")

## {"exists":bool,"entries":Array,"removed":Array}
static func read()->Dictionary:
    for candidate in [path(),path()+".bak"]:
        if not FileAccess.file_exists(candidate):continue
        var envelope=JSON.parse_string(FileAccess.get_file_as_string(candidate))
        if not envelope is Dictionary or not envelope.get("payload") is String:continue
        if envelope.payload.sha256_text()!=envelope.get("sha256",""):continue
        var data=JSON.parse_string(envelope.payload)
        if not data is Dictionary or not data.get("entries") is Array or not data.get("removed") is Array:continue
        return {"exists":true,"entries":clean(data.entries),"removed":data.removed}
    return {"exists":false,"entries":[],"removed":[]}

static func clean(entries:Array)->Array:
    var result:Array=[]
    var seen:={}
    for entry in entries:
        if not entry is Dictionary or not entry.get("id") is String or not entry.get("pokemon") is Dictionary:continue
        if entry.id.is_empty() or entry.id.length()>96 or seen.has(entry.id) or result.size()>=CAPACITY:continue
        seen[entry.id]=true
        result.append({"id":entry.id,"pokemon":entry.pokemon})
    return result

static func write(entries:Array,removed:Array)->Error:
    while removed.size()>REMEMBERED_REMOVALS:removed.remove_at(0)
    var payload:=JSON.stringify({"format":1,"entries":clean(entries),"removed":removed},"",true,true)
    var target:=path()
    var file:=FileAccess.open(target+".pending",FileAccess.WRITE)
    if file==null:return FileAccess.get_open_error()
    file.store_string(JSON.stringify({"payload":payload,"sha256":payload.sha256_text()}))
    file.flush();var error:=file.get_error();file.close()
    if error!=OK:return error
    if FileAccess.file_exists(target):
        error=DirAccess.copy_absolute(target,target+".bak")
        if error!=OK:return error
    return DirAccess.rename_absolute(target+".pending",target)

## Records the box as the host now holds it, noting anything that left it.
static func mirror(entries:Array)->Error:
    var before:=read()
    var now:={}
    for entry in entries:
        if entry is Dictionary and entry.get("id") is String:now[entry.id]=true
    var removed:Array=[]
    for id in before.removed:
        if id is String and not now.has(id) and id not in removed:removed.append(id)
    for entry in before.entries:
        if not now.has(entry.id) and entry.id not in removed:removed.append(entry.id)
    return write(entries,removed)

## What a world's box becomes when its owner arrives: everything already here
## and everything they carry, except what they have since taken out.
static func merge(here:Array,carried:Array,removed:Array)->Array:
    var gone:={}
    for id in removed:
        if id is String:gone[id]=true
    var result:Array=[]
    var seen:={}
    for source in [here,carried]:
        for entry in clean(source):
            if gone.has(entry.id) or seen.has(entry.id) or result.size()>=CAPACITY:continue
            seen[entry.id]=true
            result.append(entry)
    return result
