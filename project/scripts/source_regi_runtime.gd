class_name SourceRegiRuntime
extends RefCounted

# Reconcile the generated chamber with its saved forge/capture progression.
# RegigigasIntroAnim changes regi1 -> regi2; the fifth capture changes it to
# regi3 and replaces the pedestal with floor2 (CatchPokemonWobblesThenCatch).
static func sync(world) -> void:
    var caught: Array = world.event_progress.get("regis_caught", [])
    var all_caught := SourceEventData.REGI_SPECIES.all(func(s): return caught.has(s))
    var forged := not caught.is_empty()
    for mutation in world.source_interior_mutations.values():
        if mutation.get("kind", "") == "REGI":
            forged = true
    var completed: bool = world.event_progress.get("completed", {}).get("regigigas", false)
    for plan in world.generated_source_interior_plans:
        if int(plan.layer_index) != 90:
            continue
        var origin: Vector2i = world.source_area_origins.get(plan.id, Vector2i.ZERO)
        var tiles: InteriorTileStore = plan.tiles
        for index in tiles.cells.size():
            # Every tile below is a cave1_regi one: no tile object for the rest.
            if not tiles.name_at(index).begins_with("cave1_regi"):
                continue
            var tile := tiles.proxy(index)
            var cell: Vector2i = origin + tiles.cells[index]
            if tile.name in ["cave1_regi1", "cave1_regi2", "cave1_regi3"]:
                if completed:
                    world._hide_event_cell(cell)
                    continue
                tile.set_names("cave1_regi3" if all_caught else "cave1_regi2" if forged else "cave1_regi1")
                world.interior_interactables[cell] = "REGIGIGAS_GATE"
                var sprite: Sprite2D = world.source_interior_upper_sprites.get(cell)
                if is_instance_valid(sprite):
                    sprite.region_rect = Rect2(128 if forged or all_caught else 0, 0, 32, 32)
                    if all_caught and not sprite.has_meta("regi_idle"):
                        # MoveWater.regiTimer2, frames 0..160 at 60 Hz.
                        var tween := sprite.create_tween().set_loops()
                        sprite.set_meta("regi_idle", true)
                        for frame in [[160,4],[128,4],[160,4],[128,4],[160,4],
                                [128,32],[192,4],[224,4],[256,4],[288,4],[128,93]]:
                            tween.tween_callback(set_frame.bind(sprite, int(frame[0])))
                            tween.tween_interval(float(frame[1])/60.0)
            elif tile.name == "cave1_regi5":
                world.interior_interactables[cell] = "REGI_RIGHT"
            elif tile.name == "cave1_regipedistal1" and all_caught:
                world._hide_event_cell(cell)
                tile.set_names("cave1_floor2")
                # The existing base is cave1_up1; replace it with the source floor.
                var layer: Node2D = world._source_area_layer_at(cell)
                if layer != null:
                    world._add_source_sprite(layer, SourceWorldData.texture_for("cave1_floor2"), cell, -3)

static func right_half_action(world, cell: Vector2i) -> void:
    var left: Vector2i = cell + Vector2i.LEFT
    var tile: SourceTile = world._source_interior_tile_at_world_cell(left)
    if tile != null and tile.name in ["cave1_regi1", "cave1_regi2", "cave1_regi3"]:
        world._use_interior_interactable("REGIGIGAS_GATE", left)

static func set_frame(sprite: Sprite2D, x: int) -> void:
    if is_instance_valid(sprite):
        sprite.region_rect = Rect2(x, 0, 32, 32)
