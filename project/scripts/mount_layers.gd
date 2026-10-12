extends RefCounted
## DrawPlayerUpper and Player.Flying: mount head/rider drawing order.
static func apply(world: Node) -> void:
    var mount: Sprite2D = world.field_helper_sprite
    if not is_instance_valid(mount): return
    var move: String = world.active_field_move
    if move not in ["FLY", "SURF", "RIDE"]: return
    var species := PokemonData.source_species(world.active_field_species)
    var facing: Vector2i = world._facing_cell()
    var rider_z: int = world.player.z_index
    mount.z_index = rider_z - 1
    if move == "FLY":
        var mount_in_front := facing == Vector2i.DOWN and species != "mantine"
        if species == "dragonite": mount_in_front = facing != Vector2i.UP
        if mount_in_front: mount.z_index = mini(4095, rider_z + 1)
        return
    # Java draws the mount over the rider, then redraws the rider's head.
    mount.z_index = mini(4094, rider_z + 1)
    var in_front := facing == Vector2i.DOWN
    if move == "RIDE" and species in ["rhyhorn", "probopass"]: in_front = false
    if move == "SURF" and species == "ludicolo": in_front = false
    # The large Mega Gyarados sheet is drawn around its rider. Facing down its
    # head and horns go in front of the trainer; facing up the trainer is on
    # its back and goes in front of it. From the side its fins cover the
    # trainer as any other mount does.
    if move == "SURF" and mount.texture != null and mount.texture.get_height() / maxi(1, mount.vframes) > 32:
        in_front = false
        if facing == Vector2i.UP: mount.z_index = rider_z - 1
    var front := mount.get_node_or_null("RiderHead") as Sprite2D
    if not is_instance_valid(front):
        front = Sprite2D.new();front.name = "RiderHead"
        front.centered = false;front.region_enabled = true
        front.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
        front.z_as_relative = false;mount.add_child(front)
    front.visible = in_front
    if not in_front: return
    var height := 8
    if move == "SURF":
        height = 10 + int({"lapras":3, "araichu":3, "raichu":4, "pikachu":4}.get(species, 0))
    var rider: Sprite2D = world.player.sprite
    var frame_size := rider.texture.get_size() / Vector2(rider.hframes, rider.vframes)
    front.texture = rider.texture
    front.region_rect = Rect2(Vector2(rider.frame_coords) * frame_size, Vector2(frame_size.x, mini(height, int(frame_size.y))))
    front.global_position = rider.global_position + rider.offset - frame_size * 0.5
    front.flip_h = rider.flip_h
    front.z_index = mini(4095, mount.z_index + 1)
