class_name OriginalMods
extends Node

const SETTINGS := "user://original_mods.cfg"
const ROOT := "user://mods"
const PACKAGES := "user://mod_packages"
const DATA_PARSER = preload("res://scripts/original_mod_data.gd")
static var patches: Array[Dictionary] = []
static var resources: Array[Resource] = []
static var report: Array[String] = []
static var path_map: Dictionary = {}
static var database: Dictionary = {}
static var applied := 0
static var startup_enabled := true

func _enter_tree() -> void:
    startup_enabled = true
    preload("res://scripts/native_mod_pack.gd").start()

static func clean_path(raw: String) -> String:
    var path := raw.replace("\\","/")
    if path.begins_with("/") or ":" in path: return ""
    for part in path.split("/"):
        if part in ["..","."]: return ""
    var lower := path.to_lower()
    if lower.begins_with("mods/"): path=path.substr(5)
    elif "/mods/" in lower: path=path.substr(lower.find("/mods/")+6)
    return path.to_lower()

static func inspect_zip(path: String) -> Dictionary:
    var zip := ZIPReader.new()
    if zip.open(path)!=OK: return {"error":"Unable to open ZIP"}
    var files := {}
    var total := 0
    var names := zip.get_files()
    if names.size()>10000: zip.close();return {"error":"ZIP contains too many files"}
    for name in names:
        if name.ends_with("/"): continue
        var clean := clean_path(name)
        if clean.is_empty(): zip.close();return {"error":"Invalid archive path: "+name}
        if files.has(clean): zip.close();return {"error":"Duplicate mod path: "+clean}
        var bytes := zip.read_file(name)
        total+=bytes.size()
        if bytes.size()>33554432 or total>268435456: zip.close();return {"error":"Mod exceeds 32 MB per file / 256 MB total"}
        files[clean]=bytes
    zip.close()
    return {"files":files}

static func _read_loose(folder: String, prefix: String, files: Dictionary) -> void:
    var directory := DirAccess.open(folder)
    if directory==null: return
    for file in directory.get_files():
        if not directory.is_link(file): files[(prefix+file).to_lower()]=FileAccess.get_file_as_bytes(folder.path_join(file))
    for child in directory.get_directories():
        if not directory.is_link(child): _read_loose(folder.path_join(child),prefix+child+"/",files)

static func prepare(path: String, bytes: PackedByteArray) -> Dictionary:
    if path_map.is_empty():
        path_map=JSON.parse_string(FileAccess.get_file_as_string("res://data/original_mod_paths.json"))
    if database.is_empty():
        database=JSON.parse_string(FileAccess.get_file_as_string("res://data/pokemon_db.json"))
    if path.begins_with("pokemon/") and path.get_file() in ["base_stats.asm","evos_attacks.asm","egg_moves.asm"]:
        return DATA_PARSER.parse(path,bytes.get_string_from_utf8(),database)
    if not path_map.has(path): return {"error":"Unsupported path: "+path}
    var replacements := []
    if path.ends_with(".png"):
        var image := Image.new()
        if image.load_png_from_buffer(bytes)!=OK: return {"error":"Invalid PNG: "+path}
        if image.get_width()>4096 or image.get_height()>8192: return {"error":"Oversized image: "+path}
        for mapping in path_map[path]:
            var converted := image
            if mapping.mode=="overworld":
                # Source mods use one 16px-wide column of six 16px frames.
                if image.get_size()!=Vector2i(16,96): return {"error":"Overworld mods require source 16x96 layout: "+path}
                converted=Image.create(96,16,false,Image.FORMAT_RGBA8)
                image.convert(Image.FORMAT_RGBA8)
                for i in range(6): converted.blit_rect(image,Rect2i(0,i*16,16,16),Vector2i(i*16,0))
            elif mapping.mode=="front":
                if image.get_width()<16 or image.get_height()%image.get_width()!=0: return {"error":"Front sprite requires square frames stacked vertically: "+path}
            elif image.get_size()!=Vector2i(int(mapping.size[0]),int(mapping.size[1])):
                return {"error":"Image dimensions differ from supported source asset: "+path}
            replacements.append({"path":mapping.path,"resource":ImageTexture.create_from_image(converted)})
    elif path.ends_with(".ogg"):
        var stream := AudioStreamOggVorbis.load_from_buffer(bytes)
        if stream==null: return {"error":"Invalid OGG: "+path}
        for mapping in path_map[path]:
            var replacement := stream.duplicate() as AudioStreamOggVorbis
            var original := load(String(mapping.path)) as AudioStreamOggVorbis
            if original!=null:
                replacement.loop=original.loop
                replacement.loop_offset=original.loop_offset
            replacements.append({"path":mapping.path,"resource":replacement})
    else: return {"error":"Unsupported file: "+path}
    return {"replacements":replacements}

static func _apply_files(files: Dictionary) -> void:
    var names := files.keys();names.sort()
    for path in names:
        var result := prepare(path,files[path])
        if result.has("error"):
            report.append(String(result.error));continue
        if result.has("patch"): patches.append(result)
        for replacement in result.get("replacements",[]):
            var resource := replacement.resource as Resource
            resource.take_over_path(String(replacement.path))
            resources.append(resource)
        applied+=1
        report.append("Loaded: "+path)

static func apply_data(target: Dictionary) -> void:
    for species in preload("res://scripts/native_mod_pack.gd").species_patches:
        if target.species.has(species):
            target.species[species].merge(preload("res://scripts/native_mod_pack.gd").species_patches[species],true)
    for entry in patches:
        if target.species.has(entry.species): target.species[entry.species].merge(entry.patch,true)

static func install_zip(path: String) -> String:
    var checked := inspect_zip(path)
    if checked.has("error"): return String(checked.error)
    var accepted := 0
    var rejected: Array[String] = []
    for file in checked.files:
        var result := prepare(file,checked.files[file])
        if result.has("error"): rejected.append(String(result.error))
        else: accepted+=1
    if accepted==0: return "No compatible files.\n"+"\n".join(rejected)
    var bytes := FileAccess.get_file_as_bytes(path)
    var hashing := HashingContext.new();hashing.start(HashingContext.HASH_SHA256);hashing.update(bytes)
    var destination := PACKAGES.path_join(hashing.finish().hex_encode()+".zip")
    var file := FileAccess.open(destination,FileAccess.WRITE)
    if file==null: return "Could not save package; active mod unchanged."
    file.store_buffer(bytes);file.close()
    var config := ConfigFile.new();config.load(SETTINGS)
    config.set_value("mods","package",destination);config.set_value("mods","enabled",true)
    if config.save(SETTINGS)!=OK: return "Could not save mod selection."
    return "Installed %d compatible files; %d skipped. Fully close and reopen the game to apply.\n" % [accepted,rejected.size()]+"\n".join(rejected)

static func set_enabled(enabled: bool) -> void:
    var config := ConfigFile.new();config.load(SETTINGS)
    config.set_value("mods","enabled",enabled);config.save(SETTINGS)
