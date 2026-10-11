extends RefCounted
const Settings=preload("res://scripts/game_options.gd")
const NORMAL=preload("res://assets/ecology/emotes.png")
const HD=preload("res://assets/ecology/emotes_hd.png")
static func sheet()->Texture2D:
    return HD if Settings.enabled("hd_emotes") else NORMAL
static func refresh_tree(tree: SceneTree)->void:
    for sprite in tree.get_nodes_in_group("styled_source_emotes"):
        if is_instance_valid(sprite):sprite.texture=sheet()
    # HeldItemEmote refreshes its own texture on the existing 0.1-second tick.
