# Loads every exported script and scene with the stripped engine, so a class
# or module the game needs but the profile removed fails CI instead of the phone.
extends SceneTree

func _init() -> void:
    var failures := 0
    var checked := 0
    for path in _walk("res://scripts") + _walk("res://scenes"):
        checked += 1
        var resource := load(path)
        if resource == null:
            failures += 1
            printerr("SMOKE FAIL: ", path)
        elif resource is PackedScene:
            var node: Node = resource.instantiate()
            if node == null:
                failures += 1
                printerr("SMOKE FAIL (instantiate): ", path)
            else:
                node.free()
    print("SMOKE: checked %d, failed %d" % [checked, failures])
    quit(1 if failures > 0 else 0)

func _walk(dir: String) -> Array:
    var found := []
    for sub in DirAccess.get_directories_at(dir):
        found += _walk(dir.path_join(sub))
    for file in DirAccess.get_files_at(dir):
        # Exported files may appear as *.gdc or *.remap; load() takes the source path.
        file = file.trim_suffix(".remap").replace(".gdc", ".gd")
        if (file.ends_with(".gd") or file.ends_with(".tscn")) and not found.has(dir.path_join(file)):
            found.append(dir.path_join(file))
    return found
