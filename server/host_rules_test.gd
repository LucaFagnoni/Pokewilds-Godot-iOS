# The field moves of a player who hosts (a phone, not a dedicated server: its
# own player acts) go through the rules like everyone's (coop_rules_runtime.gd):
# a hole dug, filled with soil bought just before (the bag saved ahead of a
# command that pays, rules.gd pays) and grass cut, each kept in the host's
# World, in its records and in its bag exactly once: the bag the game shows is
# the bag its record holds after every one, and nothing is left recording.
# Run: godot --headless --path project -s ../server/host_rules_test.gd
#      (headless needs project/override.cfg: [physics] 2d/physics_engine="Dummy")
extends SceneTree

const Paths = preload("res://scripts/game_data_paths.gd")
const TileRules = preload("res://scripts/rules/tile_rules.gd")
const PORT := 54798

var main: Node
var coop: Node
var checks := 0
var failed := 0

func check(ok: bool, what: String) -> void:
    checks += 1
    if not ok:
        failed += 1
        printerr("HOST RULES TEST FAIL: ", what)

func _frames(count: int) -> void:
    for i in count: await process_frame

func _initialize() -> void:
    create_timer(600.0).timeout.connect(func(): printerr("HOST RULES TEST FAIL: timed out"); quit(2))
    var dir := OS.get_temp_dir().path_join("host_rules_test_%d" % Time.get_ticks_usec())
    DirAccess.make_dir_recursive_absolute(dir)
    FileAccess.open(dir.path_join(".private-saves-migrated"), FileAccess.WRITE).close()
    Paths.directory = dir
    change_scene_to_file("res://scenes/main.tscn")
    await _frames(30)
    main = current_scene
    while not main.startup_complete: await process_frame
    coop = main.coop_game
    coop.host_port = PORT
    main.world_edit.text = "HostRules"
    main.selected_world_size = 0
    await coop.choose("NEW", "")
    var waited := 0
    while not main.started and waited < 36000:
        await process_frame
        waited += 1
    check(main.started and coop.active and coop.hosting, "a world hosted (%s)" % main.menu_status.text)
    if not (main.started and coop.active and coop.hosting): _finish(); return
    await _frames(60)
    for i in 6:
        if not main._field_ui_blocks_gameplay(): break
        for pressed in [true, false]:
            var event := InputEventAction.new()
            event.action = "confirm"
            event.pressed = pressed
            Input.parse_input_event(event)
            await _frames(1)
        await _frames(20)
    await _dig_and_fill()
    await _cut()
    _finish()

func _finish() -> void:
    if is_instance_valid(coop) and coop.active: coop.session.stop()
    print("HOST RULES TEST: %d checks, %d failed" % [checks, failed])
    quit(1 if failed > 0 else 0)

## The bag the game shows against the one its record holds.
func _bag_kept(what: String) -> void:
    var record: Dictionary = coop.state.records.get("player/" + coop.session.actor, {})
    check(record.get("inventory", {}) == main.inventory, "%s: the bag is the record's bag (%s / %s)" % [what, main.inventory, record.get("inventory")])
    check(not main.world.area.recording(), "%s: nothing left recording" % what)

func _plain_ground() -> Vector2i:
    var world: Node = main.world
    var here: Vector2i = world._player_cell()
    for step in [Vector2i(1, 1), Vector2i(-1, 1), Vector2i(1, -1), Vector2i(-1, -1), Vector2i(2, 2), Vector2i(-2, 2), Vector2i(2, -2), Vector2i(-2, -2)]:
        var cell: Vector2i = here + step
        var tile: SourceTile = world.area.tile_at(cell)
        if tile == null or not TileRules.dig_surface_ok(tile) or TileRules.accepts_soil(world.area, cell) or TileRules.is_mountain(tile): continue
        if world.built_structures.has(cell) or world.landmarks.has(cell) or TileRules.exact_resource_anchor(world.area, cell).x > -2147483648: continue
        if not world.dropped_items().can_drop(cell) or not String(tile.has_item).is_empty(): continue
        return cell
    return Vector2i(999999, 999999)

func _dig_and_fill() -> void:
    var world: Node = main.world
    var cell := _plain_ground()
    check(cell.x != 999999, "plain ground beside the host at %s" % world._player_cell())
    if cell.x == 999999: return
    var key := "world/%s/source_interior_mutations/%s" % [coop._area(), ("%d,%d" % [cell.x, cell.y]).uri_encode()]
    var material := TileRules.dig_material_at(world.area, cell)
    var before := int(main.inventory.get(material, 0))
    await coop.building.dig(cell)
    check(world.area.tile_at(cell).name_upper.begins_with("hole1"), "the host's DIG leaves a hole in its World")
    check(coop.state.records.has(key), "the hole is in the records")
    check(int(main.inventory.get(material, 0)) == before + 1, "the ground's %s once in the bag: %d -> %d" % [material, before, int(main.inventory.get(material, 0))])
    _bag_kept("DIG")
    # Soil the record has not seen: the bag goes to the record just before the fill.
    main.inventory["GRASS"] = int(main.inventory.get("GRASS", 0)) + 2
    var grass := int(main.inventory["GRASS"])
    await coop.building.dig(cell, "FOREST")
    check(not world.area.tile_at(cell).name_upper.begins_with("hole1") and world.area.tile_at(cell).name == "green1", "the hole filled with FOREST ground: %s / %s" % [world.area.tile_at(cell).name, world.area.tile_at(cell).name_upper])
    check(int(main.inventory.get("GRASS", 0)) == grass - 1, "one GRASS paid: %d -> %d" % [grass, int(main.inventory.get("GRASS", 0))])
    _bag_kept("fill")

func _cut() -> void:
    var world: Node = main.world
    var here: Vector2i = world._player_cell()
    var cell := Vector2i(999999, 999999)
    for radius in range(1, 4):
        for dx in range(-radius, radius + 1):
            for dy in range(-radius, radius + 1):
                var at: Vector2i = here + Vector2i(dx, dy)
                if cell.x == 999999 and maxi(absi(dx), absi(dy)) == radius and world._is_cuttable_grass_cell(at) and not world.built_structures.has(at): cell = at
    if cell.x == 999999: print("HOST RULES TEST note: no grass near ", here, "; CUT not tried"); return
    var before := int(main.inventory.get("GRASS", 0))
    await coop.building.cut(cell)
    check(not world._is_cuttable_grass_cell(cell), "the host's CUT takes the grass from its World")
    check(int(main.inventory.get("GRASS", 0)) > before, "GRASS in the bag: %d -> %d" % [before, int(main.inventory.get("GRASS", 0))])
    _bag_kept("CUT")
