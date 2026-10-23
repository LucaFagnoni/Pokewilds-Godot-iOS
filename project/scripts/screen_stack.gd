extends RefCounted
## The screens open over the field, oldest first: menus, prompts, the battle,
## the evolution and hatch screens. Each is pushed when it opens and removed
## when it closes (main.gd's *_open flags read and write this stack), and the
## field takes no input while any of them is open.
##
## Screens drawn by other scripts' nodes (the POKEDEX, OPTIONS, ...) are
## watched instead: they count as open while their node is shown.

var _open: Array[StringName] = []
var _watched := {} # screen -> Callable returning whether it is open now

func set_open(screen: StringName, open: bool) -> void:
    var at := _open.find(screen)
    if open and at < 0:
        _open.push_back(screen)
    elif not open and at >= 0:
        _open.remove_at(at)

func is_open(screen: StringName) -> bool:
    return _open.has(screen)

func watch(screen: StringName, open_now: Callable) -> void:
    _watched[screen] = open_now

## Whether an open screen other than `except` keeps the player from moving.
func blocks_gameplay(except: StringName = &"") -> bool:
    for screen in _open:
        if screen != except:
            return true
    for screen: StringName in _watched:
        if screen != except and _watched[screen].call():
            return true
    return false
