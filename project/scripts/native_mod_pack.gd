extends RefCounted

const CONFIG := "user://native_mods.cfg"
const INSTALLED := "user://mod_packages/selected.pwmod"
static var active_name := "OFF"
static var last_error := ""
## The resources enabled mods supply, by the res:// path they replace (keeps them alive).
static var replaced: Dictionary = {}
static var species_patches: Dictionary = {}
static var palettes: Dictionary = {}
# Battle animations are cropped atlas pages (tools/battle_atlas.py): a mod can
# repaint a page in place, the old full-frame sheets have nowhere to go.
const OLD_BATTLE_SHEET := "Battle animations are now atlas pages to repaint at the same size; old full-frame sheets are not supported: "

static func _safe_path(path: String) -> bool:
    return not path.is_empty() and not path.begins_with("/") and not ":" in path and not "\\" in path and not ".." in path.split("/")

static func validate(path: String) -> Dictionary:
    var zip := ZIPReader.new()
    if zip.open(path) != OK: return {"error":"Cannot open mod package."}
    var names := zip.get_files()
    if names.size() > 12000 or not names.has("mod.json"):
        zip.close();return {"error":"This is not a Godot PokeWilds mod package."}
    var seen := {}
    for name in names:
        if not _safe_path(name) or seen.has(name):
            zip.close();return {"error":"Unsafe or duplicate package path."}
        seen[name] = true
    var manifest = JSON.parse_string(zip.read_file("mod.json").get_string_from_utf8())
    if not manifest is Dictionary or manifest.get("format",0) != 1 or not manifest.get("resources",{}) is Dictionary or not manifest.get("species",{}) is Dictionary:
        zip.close();return {"error":"Invalid mod manifest."}
    var catalog: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/mod_resource_catalog.json"))
    var database: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/pokemon_db.json"))
    var prepared := []
    var total := 0
    for target in manifest.get("resources",{}):
        var file: String = str(manifest.resources[target])
        if not catalog.has(target) or not names.has(file) or not _safe_path(file):
            zip.close();return {"error":(OLD_BATTLE_SHEET if "/battle_animations/" in str(target) else "Unsupported asset destination: ") + str(target)}
        var bytes := zip.read_file(file)
        total += bytes.size()
        if bytes.size() > 33554432 or total > 268435456:
            zip.close();return {"error":"Mod exceeds the supported memory limits."}
        var resource: Resource
        if str(target).ends_with(".png"):
            var image := Image.new()
            if image.load_png_from_buffer(bytes) != OK:
                zip.close();return {"error":"Invalid mod image: " + file}
            var expected: Array = catalog[target].get("size",[])
            var valid := image.get_size() == Vector2i(int(expected[0]),int(expected[1]))
            if catalog[target].get("front",false):
                valid = image.get_width() > 0 and image.get_width() <= 96 and image.get_height() % image.get_width() == 0 and image.get_height() <= 8192
            # Converted walking strips replace source vertical sheets.
            if "overworld" in str(target) and image.get_size() == Vector2i(96,16): valid = true
            # The transition sheet before it kept only its first row of frames.
            if str(target).ends_with("/battle_intro_anim1_sheet1.png") and image.get_size() == Vector2i(8192,256): valid = true
            if not valid:
                zip.close();return {"error":(OLD_BATTLE_SHEET if "/battle_animations/" in str(target) else "Wrong image dimensions: ") + file}
            resource = ImageTexture.create_from_image(image)
        elif str(target).ends_with(".ogg"):
            resource = AudioStreamOggVorbis.load_from_buffer(bytes)
            if resource == null:
                zip.close();return {"error":"Invalid mod audio: " + file}
        else:
            zip.close();return {"error":"Executable mods are not supported."}
        prepared.append({"path":str(target),"resource":resource})
    for species in manifest.get("species",{}):
        var patch = manifest.species[species]
        if not database.species.has(species) or not patch is Dictionary:
            zip.close();return {"error":"Unknown species or invalid patch."}
        for field in patch:
            if not database.species[species].has(field) and field not in ["mod_name","front_shiny","back_shiny","overworld_shiny"]:
                zip.close();return {"error":"Unknown species property: " + str(field)}
            var baseline = database.species[species].get(field, "")
            if typeof(patch[field]) != typeof(baseline) and not (patch[field] is float and baseline is int) and not (patch[field] is int and baseline is float):
                zip.close();return {"error":"Wrong data type for: " + str(field)}
        if patch.has("stats"):
            if patch.stats.size()!=6:
                zip.close();return {"error":"A species needs six base stats."}
            for value in patch.stats:
                if not (value is float or value is int) or value<1 or value>255:
                    zip.close();return {"error":"Invalid base stat."}
        for learned in patch.get("learnset",[]):
            if not learned is Dictionary or not database.moves.has(learned.get("move","")) or float(learned.get("level",-1))<0 or float(learned.get("level",101))>100:
                zip.close();return {"error":"Invalid learned move."}
        for rule in patch.get("evolutions",[]):
            if not rule is Dictionary or not database.species.has(rule.get("species","")) or not rule.get("parameter",null) is String or rule.get("method","") not in ["EVOLVE_LEVEL","EVOLVE_ITEM","EVOLVE_TRADE","EVOLVE_HAPPINESS","EVOLVE_MOVE","EVOLVE_INPARTY","EVOLVE_HASINPARTY","EVOLVE_STAT"]:
                zip.close();return {"error":"Invalid evolution rule."}
        for field in ["types","special","forced_off","egg_groups","egg_moves","spawn_biomes","aggressive_biomes","habitat_tokens","harvest_tokens","tmhm"]:
            for value in patch.get(field,[]):
                if not value is String:
                    zip.close();return {"error":"Invalid text list: " + field}
        for kind in ["front","back","overworld","front_shiny","back_shiny","overworld_shiny","cry"]:
            if patch.has(kind) and not catalog.has(patch[kind]):
                zip.close();return {"error":"Unknown species asset path."}
        for form in patch.get("base_forms",[]):
            if not form is Dictionary or not database.species.has(form.get("species","")) or not (form.get("weight") is float or form.get("weight") is int):
                zip.close();return {"error":"Invalid breeding base form."}
        for field in ["catch_rate","base_exp","egg_cycles","weight_kg","height_m","dex"]:
            if patch.has(field) and (float(patch[field])<0 or float(patch[field])>100000):
                zip.close();return {"error":"Invalid numeric property: " + field}
        if patch.has("overworld_behavior"):
            for key in patch.overworld_behavior:
                var value = patch.overworld_behavior[key]
                if not value is bool and not value is float and not value is int:
                    zip.close();return {"error":"Invalid overworld behavior."}
    if not manifest.get("palettes",{}) is Dictionary:
        zip.close();return {"error":"Invalid shiny palette table."}
    for species in manifest.get("palettes",{}):
        var palette = manifest.palettes[species]
        if not database.species.has(species) or not palette is Dictionary:
            zip.close();return {"error":"Invalid shiny species."}
        for key in ["normal","back_normal","colors"]:
            if not palette.get(key) is Array or palette[key].size()!=2:
                zip.close();return {"error":"A palette needs two colors."}
            for rgb in palette[key]:
                if not rgb is Array or rgb.size()!=3:
                    zip.close();return {"error":"A color needs three channels."}
                for channel in rgb:
                    if not (channel is float or channel is int) or channel<0 or channel>255:
                        zip.close();return {"error":"Invalid palette channel."}
    zip.close()
    return {"manifest":manifest,"prepared":prepared}

static func _manifest(path: String) -> Dictionary:
    var zip := ZIPReader.new()
    if zip.open(path) != OK: return {}
    var value = JSON.parse_string(zip.read_file("mod.json").get_string_from_utf8())
    zip.close()
    return value if value is Dictionary else {}

static func _identity(manifest: Dictionary, path: String) -> String:
    var id := str(manifest.get("id", "")).strip_edges()
    return id if not id.is_empty() else "legacy-" + FileAccess.get_sha256(path)

static func _store(rows: Array) -> Error:
    var config := ConfigFile.new()
    config.set_value("library", "version", 2)
    config.set_value("library", "entries", rows)
    var error := config.save(CONFIG + ".pending")
    if error != OK: return error
    return DirAccess.rename_absolute(CONFIG + ".pending", CONFIG)

static func library() -> Array:
    var config := ConfigFile.new()
    config.load(CONFIG)
    if config.get_value("library", "version", 0) == 2:
        var saved = config.get_value("library", "entries", [])
        if not saved is Array: return []
        var clean := []
        for entry in saved:
            if entry is Dictionary and entry.get("path", "") is String and entry.get("id", "") is String:
                clean.append(entry)
        return clean
    # Keep the previous imported pack even when its selection was OFF.
    var rows := []
    var selection := str(config.get_value("mods", "selected", "off"))
    for path in [INSTALLED]:
        if not FileAccess.file_exists(path): continue
        var manifest := _manifest(path)
        if manifest.is_empty(): continue
        rows.append({"id":_identity(manifest,path), "path":path,
            "name":str(manifest.get("name","Mod")), "version":str(manifest.get("version","")),
            "enabled":selection == "installed"})
    if _store(rows) != OK: last_error = "Could not save migrated mod library. Existing packages retained."
    return rows

static func set_enabled(index: int, enabled: bool) -> Error:
    var rows := library()
    if index < 0 or index >= rows.size(): return ERR_INVALID_PARAMETER
    rows[index].enabled = enabled
    return _store(rows)

static func disable_all() -> Error:
    var rows := library()
    for row in rows: row.enabled = false
    return _store(rows)

static func move_pack(index: int, direction: int) -> Error:
    var rows := library()
    var next := index + direction
    if index < 0 or index >= rows.size() or next < 0 or next >= rows.size(): return ERR_INVALID_PARAMETER
    var row = rows[index]
    rows.remove_at(index)
    rows.insert(next,row)
    return _store(rows)

static func remove_pack(index: int) -> Error:
    var rows := library()
    if index < 0 or index >= rows.size(): return ERR_INVALID_PARAMETER
    var path := str(rows[index].path)
    rows.remove_at(index)
    var error := _store(rows)
    if error == OK and path.begins_with("user://mod_packages/"):
        DirAccess.remove_absolute(path)
    return error

static func conflicts() -> Array:
    var owners := {}
    var result := []
    for row in library():
        if not row.get("enabled",false): continue
        var manifest := _manifest(row.path)
        if not manifest.get("resources",{}) is Dictionary or not manifest.get("species",{}) is Dictionary or not manifest.get("palettes",{}) is Dictionary: continue
        var keys := []
        for target in manifest.get("resources",{}): keys.append("Asset: " + str(target))
        for species in manifest.get("species",{}):
            if not manifest.species[species] is Dictionary: continue
            for field in manifest.species[species]: keys.append(str(species) + "." + str(field))
        for species in manifest.get("palettes",{}): keys.append("Shiny palette: " + str(species))
        for key in keys:
            if owners.has(key):
                result.append({"target":key,"earlier":owners[key],"winner":str(row.name)})
            owners[key] = str(row.name)
    return result

static func start() -> void:
    # Android kept a 16 MB copy of the removed built-in Gen 3 pack here.
    if FileAccess.file_exists("user://builtin_gen3_overhaul.pwmod"): DirAccess.remove_absolute("user://builtin_gen3_overhaul.pwmod")
    active_name = "OFF"
    last_error = ""
    species_patches = {}
    palettes = {}
    var active := PackedStringArray()
    var loaded_resources := {}
    var rows := library()
    for row in rows:
        if not row.get("enabled",false): continue
        var result := validate(row.path)
        if result.has("error"):
            last_error += str(row.name) + ": " + str(result.error) + "\n"
            continue
        # Validate each package completely before applying it. Later enabled
        # packages win only the resource/property/palette they actually supply.
        for entry in result.prepared:
            var resource: Resource = entry.resource
            if resource is AudioStreamOggVorbis:
                var original := load(entry.path) as AudioStreamOggVorbis
                if original != null:
                    resource.loop = original.loop
                    resource.loop_offset = original.loop_offset
            resource.take_over_path(entry.path)
            loaded_resources[entry.path] = resource
        for species in result.manifest.get("species",{}):
            if not species_patches.has(species): species_patches[species] = {}
            species_patches[species].merge(result.manifest.species[species],true)
        palettes.merge(result.manifest.get("palettes",{}),true)
        active.append(str(row.name) + " " + str(row.version))
    replaced = loaded_resources
    if not active.is_empty(): active_name = ", ".join(active)

static func install(path: String) -> String:
    var result := validate(path)
    if result.has("error"): return result.error
    var rows := library()
    var manifest: Dictionary = result.manifest
    var id := _identity(manifest,path)
    var digest := FileAccess.get_sha256(path)
    var destination := "user://mod_packages/" + digest + ".pwmod"
    if DirAccess.make_dir_recursive_absolute("user://mod_packages") != OK: return "Cannot create mod folder."
    if not FileAccess.file_exists(destination):
        var file := FileAccess.open(destination + ".pending",FileAccess.WRITE)
        if file == null: return "Cannot store mod. Library unchanged."
        file.store_buffer(FileAccess.get_file_as_bytes(path))
        file.close()
        if FileAccess.get_sha256(destination + ".pending") != digest: return "Copy verification failed. Library unchanged."
        if DirAccess.rename_absolute(destination + ".pending",destination) != OK: return "Cannot finish storing mod."
    var replacement := {"id":id,"path":destination,"name":str(manifest.get("name","Mod")),
        "version":str(manifest.get("version","")),"enabled":true}
    var old_path := ""
    var index := -1
    for i in range(rows.size()):
        if rows[i].id == id: index = i; break
    if index >= 0:
        old_path = rows[index].path
        replacement.enabled = rows[index].get("enabled",false)
        rows[index] = replacement
    else: rows.append(replacement)
    if _store(rows) != OK: return "Cannot save mod library. Previous library retained."
    if old_path != destination and old_path.begins_with("user://mod_packages/"): DirAccess.remove_absolute(old_path)
    return "Updated. Restart to apply." if index >= 0 else "Installed and enabled. Restart to apply."

