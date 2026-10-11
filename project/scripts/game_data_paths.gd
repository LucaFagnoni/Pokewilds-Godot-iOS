extends RefCounted
static var directory := ""
static var last_error := ""
static var android_storage: Variant = null

static func root_path() -> String:
    if not directory.is_empty(): return directory
    directory = "user://"
    if OS.get_name() == "Android":
        if Engine.has_singleton("JavaClassWrapper"):
            android_storage = Engine.get_singleton("JavaClassWrapper").wrap("com.godot.game.PokeWildsStorage")
            if android_storage != null:
                var external: String = android_storage.getExternalRoot()
                if not external.is_empty(): directory = external
        if directory == "user://":
            last_error = "Android external storage is unavailable. Saves remain in private storage."
            push_error(last_error)
    return directory

static func path(relative: String) -> String:
    return root_path().path_join(relative)

static func initialize() -> Error:
    var error := _initialize_external()
    if error != OK:
        last_error = "External save migration failed; original private saves remain active. Error %d" % error
        directory = "user://"
        for folder in ["saves", "world_cache"]:
            DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path(folder)))
    if android_storage != null:
        if not android_storage.setActiveRoot(ProjectSettings.globalize_path(root_path())):
            last_error = "Cannot expose the live game folder in Android Files."
            push_error(last_error)
    return error

static func _initialize_external() -> Error:
    for folder in ["saves", "world_cache"]:
        var error := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path(folder)))
        if error != OK: return error
    if root_path() == "user://" or FileAccess.file_exists(path(".private-saves-migrated")): return OK
    var sources: Array[String] = ["game.ini"]
    for folder in ["saves", "world_cache"]:
        for filename in DirAccess.get_files_at("user://" + folder): sources.append(folder + "/" + filename)
    for relative in sources:
        var source := "user://" + relative
        var target := path(relative)
        if not FileAccess.file_exists(source) or FileAccess.file_exists(target): continue
        var temporary := target + ".migrating"
        var error := DirAccess.copy_absolute(ProjectSettings.globalize_path(source), ProjectSettings.globalize_path(temporary))
        if error != OK: return error
        if FileAccess.get_sha256(source) != FileAccess.get_sha256(temporary): return ERR_FILE_CORRUPT
        error = DirAccess.rename_absolute(ProjectSettings.globalize_path(temporary), ProjectSettings.globalize_path(target))
        if error != OK: return error
    var marker := FileAccess.open(path(".private-saves-migrated"), FileAccess.WRITE)
    if marker == null: return FileAccess.get_open_error()
    marker.store_string("Private originals retained. External saves are now authoritative.\n")
    return OK
