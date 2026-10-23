# AreaState (area_state.gd) without a world: overlay writes and what they mark
# dirty, a recorded prediction undone exactly (overlays and tiles, a live tile
# proxy read again), and the binary change frames read back (and refused when
# cut short or corrupt).
# Run: godot --headless --path project -s ../server/area_state_test.gd
extends SceneTree

const AreaState = preload("res://scripts/area_state.gd")

var failed := 0

func check(ok: bool, what: String) -> void:
    if not ok:
        failed += 1
        printerr("AREA STATE TEST FAIL: ", what)

## A 6x5 area of green1 with a tree in the middle.
static func small_area() -> AreaState:
    var store := WorldTileStore.with_bounds(Rect2i(0, 0, 6, 5))
    for y in 5:
        for x in 6:
            store._write(Vector2i(x, y) * 16, SourceTile.new("green1", Vector2i(x, y) * 16, "tree2" if Vector2i(x, y) == Vector2i(2, 2) else ""))
    var adapter := SourceExactWorldAdapter.new()
    adapter.tiles = store
    var state := AreaState.new()
    state.area = "3,-1"
    state.tiles = adapter
    state.bounds = Rect2i(0, 0, 6, 5)
    return state

func _initialize() -> void:
    var state := small_area()
    # Writes, and what they mark.
    state.put("terrain_changes", "1,1", 2)
    check(state.dirty.is_empty(), "nothing is collected until tracking")
    state.tracking = true
    state.put("source_interior_mutations", "2,2", {"kind":"TILE_NAMES", "base":"green1", "upper":""})
    state.put("removed_resources", "4,1", true)
    state.drop("terrain_changes", "1,1")
    state.drop("terrain_changes", "5,5")
    state.put("blocked", Vector2i(2, 2), true)
    state.structures[Vector2i(3, 3)] = {"name":"FENCE", "sprite":Node2D.new(), "collision":null}
    state.mark("structures", Vector2i(3, 3))
    var changes := state.take_dirty()
    check(changes.size() == 4, "four overlay entries changed (a drop of nothing and a local write are not)")
    check(changes[0] == ["terrain_changes", "1,1", null], "a dropped entry reads as null, groups in wire order")
    check(changes[1] == ["removed_resources", "4,1", true], "a set entry")
    check(changes[2][0] == "source_interior_mutations" and changes[2][2].kind == "TILE_NAMES", "a mutation")
    check(changes[3][0] == "structures" and changes[3][1] == Vector2i(3, 3), "a structure, by cell")
    check(state.take_dirty().is_empty(), "taken once")
    # The wire: every form, read back.
    var bytes := AreaState.encode_changes(state.area, 77, changes + [["built_house_paintings", "1,1|0|2,3", 5],
        ["event_progress", "regis_caught", ["regirock"]]])
    var read := AreaState.decode_changes(bytes)
    check(read.get("area") == "3,-1" and read.get("revision") == 77, "area and revision")
    var back: Array = read.get("changes", [])
    check(back.size() == 6, "every change read back")
    if back.size() == 6:
        check(back[0] == ["terrain_changes", "1,1", null], "null")
        check(back[1] == ["removed_resources", "4,1", true], "set")
        check(back[2][2] == state.source_interior_mutations["2,2"], "variant")
        check(back[3][1] == "3,3" and back[3][2] == {"name":"FENCE", "x":3, "y":3}, "a structure without its nodes")
        check(back[4] == ["built_house_paintings", "1,1|0|2,3", 5], "int")
        check(back[5][2] == ["regirock"], "event progress")
    check(AreaState.decode_changes(bytes.slice(0, bytes.size() - 1)).is_empty(), "cut short: refused")
    var longer := bytes.duplicate()
    longer.append(0)
    check(AreaState.decode_changes(longer).is_empty(), "trailing bytes: refused")
    var wrong := bytes.duplicate()
    wrong[2 + 2 + 4 + 6] = 200 # tag, kind, the area's length and "3,-1", revision and count
    check(AreaState.decode_changes(wrong).is_empty(), "an unknown group: refused")
    (state.structures[Vector2i(3, 3)].sprite as Node2D).free()

    # A prediction undone: overlays and tiles as they were.
    state = small_area()
    state.tracking = true
    state.put("source_plant_farms", "0,0", {"base":"green1"})
    state.take_dirty()
    var proxy := state.tile_at(Vector2i(2, 2))
    var store: WorldTileStore = state.tiles.tiles
    var index := store.index_of(Vector2i(2, 2) * 16)
    var before := [store.flags[index], store.name_ids[index], store.upper_ids[index], store.has_item_ids[index], store.amounts[index]]
    state.begin()
    check(state.recording(), "recording")
    var tile := state.edit(Vector2i(2, 2))
    tile.set_names("sand1", "hole1")
    tile.has_item = "HARD STONE"
    tile.has_item_amount = 2
    state.edit(Vector2i(2, 2)).biome = "DESERT"
    state.put("source_interior_mutations", "2,2", {"kind":"TILE_NAMES", "base":"sand1", "upper":"hole1"})
    state.put("source_interior_mutations", "2,2", {"kind":"TILE_NAMES", "base":"sand2", "upper":"hole1"})
    state.drop("source_plant_farms", "0,0")
    state.put("blocked", Vector2i(2, 2), true)
    check(proxy.name == "sand1" and store.name_at(index) == "sand1", "the edit reached the store and the live proxy")
    var put_back := state.rollback()
    check(not state.recording(), "recording ends")
    check(put_back == [Vector2i(2, 2)], "the edited cell is reported for redrawing")
    check([store.flags[index], store.name_ids[index], store.upper_ids[index], store.has_item_ids[index], store.amounts[index]] == before, "the tile as it was")
    check(proxy.name == "green1" and proxy.name_upper == "tree2" and proxy.has_item == "" and proxy.biome == "", "the live proxy read again")
    check(not state.source_interior_mutations.has("2,2"), "a new mutation taken away")
    check(state.source_plant_farms.get("0,0") == {"base":"green1"}, "a dropped farm put back")
    check(not state.blocked.has(Vector2i(2, 2)), "a local write undone")
    var redo := state.take_dirty()
    check(redo.size() == 2, "an undone write is dirty again (the authority's value follows)")
    # A kept prediction stays.
    state.begin()
    state.edit(Vector2i(1, 1)).set_names("sand1", "")
    state.put("terrain_changes", "1,1", 1)
    state.commit()
    check(state.tile_at(Vector2i(1, 1)).name == "sand1" and state.terrain_changes.get("1,1") == 1, "commit keeps")
    check(state.rollback().is_empty(), "nothing to undo after commit")
    check(AreaState.key_cell("-4,17") == Vector2i(-4, 17) and AreaState.cell_key(Vector2i(-4, 17)) == "-4,17", "cell keys")
    check(state.in_bounds(Vector2i(5, 4)) and not state.in_bounds(Vector2i(6, 4)), "bounds by the tiles")
    print("AREA STATE TEST: %d failed" % failed)
    quit(1 if failed else 0)
