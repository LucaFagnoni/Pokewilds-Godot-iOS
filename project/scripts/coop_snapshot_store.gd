extends Node
## Checksum and disk I/O run off the game thread. Immutable content files.
signal completed(id: int, result: Dictionary)
const MAX_BYTES:=128*1024*1024
const MAX_QUEUE:=4
var directory:=""
var _thread:Thread
var _queue:Array=[]
var _active:Dictionary={}
var _next_id:=0
var _reserved_bytes:=0
var _waiting:=0

func _ready()->void:process_mode=Node.PROCESS_MODE_ALWAYS

func configure(path:String)->Error:
    if _thread!=null or not _queue.is_empty():return ERR_BUSY
    directory=ProjectSettings.globalize_path(path)
    return DirAccess.make_dir_recursive_absolute(directory)

func save_bytes(bytes:PackedByteArray)->Dictionary:
    if directory.is_empty() or bytes.is_empty() or bytes.size()>MAX_BYTES:return {"ok":false,"reason":"invalid_snapshot"}
    return await _submit({"operation":"save","bytes":bytes})

func load_bytes(hash_value:String)->Dictionary:
    if directory.is_empty() or hash_value.length()!=64 or not hash_value.is_valid_hex_number():return {"ok":false,"reason":"invalid_snapshot"}
    return await _submit({"operation":"load","hash":hash_value.to_lower()})

func _submit(job:Dictionary)->Dictionary:
    var reserved:int=job.bytes.size() if job.operation=="save" else MAX_BYTES
    if _waiting>=MAX_QUEUE:return {"ok":false,"reason":"busy"}
    _waiting+=1
    var deadline=Time.get_ticks_msec()+60000
    while _queue.size()>=MAX_QUEUE or _reserved_bytes+reserved>MAX_BYTES:
        if Time.get_ticks_msec()>=deadline:
            _waiting-=1;return {"ok":false,"reason":"busy"}
        await get_tree().process_frame
    _waiting-=1
    _reserved_bytes+=reserved
    job["reserved"]=reserved
    _next_id+=1
    var id:=_next_id
    job["id"]=id;job["directory"]=directory
    _queue.append(job)
    while true:
        var result:Array=await completed
        if int(result[0])==id:return result[1]
    return {"ok":false}

func _process(_delta:float)->void:
    if _thread!=null and not _thread.is_alive():
        var result:Dictionary=_thread.wait_to_finish()
        var id:int=_active.id
        _reserved_bytes-=int(_active.reserved)
        _thread=null;_active={}
        completed.emit(id,result)
    if _thread==null and not _queue.is_empty():
        _active=_queue.pop_front()
        _thread=Thread.new()
        var error=_thread.start(_work.bind(_active))
        if error!=OK:
            var id:int=_active.id
            _reserved_bytes-=int(_active.reserved)
            _thread=null;_active={}
            completed.emit(id,{"ok":false,"reason":"worker_failed"})

static func _digest(bytes:PackedByteArray)->String:
    var hash_context=HashingContext.new()
    hash_context.start(HashingContext.HASH_SHA256)
    hash_context.update(bytes)
    return hash_context.finish().hex_encode()

static func _work(job:Dictionary)->Dictionary:
    if job.operation=="load":
        var path:String=job.directory.path_join(job.hash+".bin")
        var file=FileAccess.open(path,FileAccess.READ)
        if file==null:return {"ok":false,"reason":"missing_snapshot"}
        if file.get_length()>MAX_BYTES:file.close();return {"ok":false,"reason":"invalid_snapshot"}
        var bytes=file.get_buffer(file.get_length());file.close()
        if _digest(bytes)!=job.hash:return {"ok":false,"reason":"corrupt_snapshot"}
        return {"ok":true,"bytes":bytes,"sha256":job.hash}
    var bytes:PackedByteArray=job.bytes
    var hash_value:=_digest(bytes)
    var target:String=job.directory.path_join(hash_value+".bin")
    var pending:String=target+".pending"
    var file=FileAccess.open(pending,FileAccess.WRITE)
    if file==null:return {"ok":false,"reason":"save_failed"}
    file.store_buffer(bytes);file.flush()
    var error=file.get_error();file.close()
    if error!=OK:return {"ok":false,"reason":"save_failed"}
    error=DirAccess.rename_absolute(pending,target)
    if error!=OK:return {"ok":false,"reason":"save_failed"}
    return {"ok":true,"snapshot":hash_value+".bin","sha256":hash_value}

func _exit_tree()->void:
    if _thread!=null:_thread.wait_to_finish();_thread=null

## Every save of an area writes a new file here, named after what is in it, and
## nothing ever removed the ones it replaced. A world hosted for three days
## held 281 of them, 1.3 GB, of which one was in use. This removes the files
## nothing refers to any more. It runs on its own thread when a host loads a
## world, and leaves alone anything that the world, its journal, its backups
## or the last quarter of an hour could still need.
static func clean_up(snapshot_directory:String,world_home:String,in_use:Array)->int:
    var keep:={}
    for hash_value in in_use:keep[String(hash_value).to_lower()]=true
    var sources:Array=[]
    for file_name in ["world.json","world.json.bak","journal.jsonl","journal.folding.jsonl","journal.previous.jsonl"]:sources.append(world_home.path_join(file_name))
    var backups:=DirAccess.open(world_home.path_join("backups"))
    if backups!=null:
        for folder in backups.get_directories():
            for file_name in ["world.json","journal.folding.jsonl","journal.jsonl"]:sources.append(world_home.path_join("backups").path_join(folder).path_join(file_name))
    var pattern:=RegEx.new()
    if pattern.compile("sha256\\\\?\"\\s*:\\s*\\\\?\"([0-9a-fA-F]{64})")!=OK:return 0
    for source in sources:
        if not FileAccess.file_exists(source):continue
        var file:=FileAccess.open(source,FileAccess.READ)
        # A save that cannot be read might name files this would remove.
        if file==null:return 0
        var text:=file.get_as_text();file.close()
        for found in pattern.search_all(text):keep[found.get_string(1).to_lower()]=true
    if keep.is_empty():return 0
    var listing:=DirAccess.open(snapshot_directory)
    if listing==null:return 0
    var now:=int(Time.get_unix_time_from_system())
    var spare:Array=[]
    for file_name in listing.get_files():
        if not (file_name.ends_with(".bin") or file_name.ends_with(".bin.pending")):continue
        if keep.has(file_name.get_slice(".",0).to_lower()):continue
        var written:=int(FileAccess.get_modified_time(snapshot_directory.path_join(file_name)))
        if now-written<900:continue
        spare.append([written,file_name])
    # The newest few are kept as well, whatever refers to them.
    spare.sort_custom(func(first,second):return first[0]>second[0])
    var removed:=0
    for index in range(5,spare.size()):
        if listing.remove(String(spare[index][1]))==OK:removed+=1
    return removed
