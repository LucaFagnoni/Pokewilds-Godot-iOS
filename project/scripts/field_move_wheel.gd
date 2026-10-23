extends RefCounted

## The FIELD MOVE wheel (and its BUILD pages): held open with the wheel trigger,
## aimed with the stick, the move under the stick used on release; a quick tap
## uses the move that breaks what the player faces.
## Split out of main.gd; reaches the game through `main`.

const GameOptions = preload("res://scripts/game_options.gd")
const CraftingData = preload("res://scripts/crafting_data.gd")
const PokemonData = preload("res://scripts/pokemon_data.gd")
const FieldMoveData = preload("res://scripts/field_move_data.gd")
const FIELD_MOVE_WHEEL_ORDER := [
    "BUILD", "CUT", "FLY", "SURF", "DIG",
    "RIDE", "SMASH", "TELEPORT", "FLASH", "CHARM",
    "POWER", "REPEL", "ATTACK", "HEADBUTT", "PAINT"
]
const FIELD_MOVE_REPRESENTATIVES := {
    "BUILD":"machop", "CUT":"chikorita", "FLY":"fearow",
    "SURF":"blastoise", "DIG":"diglett", "RIDE":"tauros",
    "SMASH":"geodude", "TELEPORT":"abra", "FLASH":"charmander",
    "CHARM":"clefairy", "POWER":"pikachu", "REPEL":"grimer",
    "ATTACK":"poochyena", "HEADBUTT":"squirtle", "PAINT":"smeargle"
}

var main: GameMain
var field_quick_tap_at := -1
var field_quick_tap_move := -1

func _init(owner_main: GameMain) -> void:
    main = owner_main

func update_field_move_wheel_input() -> void:
    if Input.is_action_pressed("ball_mechanics") or field_move_wheel_stick().length()>=0.35:
        field_quick_tap_at=-1
    if not is_instance_valid(main.ball_mechanics):
        main.ball_mechanics = preload("res://scripts/ball_mechanics.gd").new()
        main.ball_mechanics.main = main
        main.add_child(main.ball_mechanics)
    if main.ball_mechanics.update_input(): return
    var trigger_held := Input.is_action_pressed("field_move_wheel")
    if main.field_wheel_wait_for_release:
        if not trigger_held: main.field_wheel_wait_for_release = false
        return
    if not main.field_move_wheel_open:
        if trigger_held and _can_open_field_move_wheel():
            open_field_move_wheel()
        return
    if main._field_ui_blocks_gameplay(main.build_wheel_mode):
        close_field_move_wheel(false)
        return
    if trigger_held:
        var stick := field_move_wheel_stick()
        if stick.length() >= 0.35:
            var angle_from_top := fposmod(atan2(stick.y, stick.x) + PI * 0.5, TAU)
            var count := main.field_move_wheel.entries.size()
            if count == 0: return
            var step := TAU / float(count)
            main.field_move_wheel_index = posmod(
                int(floor((angle_from_top + step * 0.5) / step)),
                count
            )
            main.field_move_wheel.select(main.field_move_wheel_index)
        return
    close_field_move_wheel(true)

func _can_open_field_move_wheel() -> bool:
    return (
        GameOptions.enabled("radial") and main.started and not main.generating and not main.battle_active and not main.field_item_busy
        and not main.game_menu_open and not main.craft_menu_open
        and not main.quit_prompt_open and not main.touch_config.visible
        and not main.touch_controls.edit_mode
        and not main._field_ui_blocks_gameplay(main.world.active_field_move == "BUILD") and main.world.gameplay_enabled
    )

func field_move_wheel_stick() -> Vector2:
    for device in Input.get_connected_joypads():
        var stick := Vector2(
            Input.get_joy_axis(device, JOY_AXIS_LEFT_X),
            Input.get_joy_axis(device, JOY_AXIS_LEFT_Y)
        )
        if stick.length() >= 0.20:
            return stick
    return main.input_router.movement_vector()

func open_field_move_wheel() -> void:
    field_quick_tap_at=-1
    field_quick_tap_move=-1
    if Input.is_action_pressed("field_move_wheel") and not Input.is_action_pressed("ball_mechanics") and field_move_wheel_stick().length()<0.35 and main.world.active_field_move not in ["BUILD","SURF","RIDE","FLY"]:
        field_quick_tap_at=Time.get_ticks_msec()
        field_quick_tap_move=_quick_breakable_field_move()
    main.field_move_wheel_open = true
    main.field_move_wheel_index = -1
    main.build_wheel_mode = main.world.active_field_move == "BUILD"
    if main.build_wheel_mode:
        main.build_wheel_page = int(main.world.get_build_selection_index()) / main.BUILD_WHEEL_PAGE_SIZE
        configure_build_wheel()
        main.build_panel.visible = false
    else:
        main.field_move_wheel.configure(_field_move_wheel_entries(), -1)
    main.field_move_wheel.visible = true
    main.message_panel.visible = false
    main.world.set_gameplay_enabled(false)

func close_field_move_wheel(activate_selection: bool) -> void:
    if not main.field_move_wheel_open:
        return
    var selection := main.field_move_wheel_index
    if activate_selection and not main.build_wheel_mode and selection<0 and field_quick_tap_at>=0:
        var elapsed=Time.get_ticks_msec()-field_quick_tap_at
        if elapsed>=0 and elapsed<250 and field_quick_tap_move==_quick_breakable_field_move():
            selection=field_quick_tap_move
    field_quick_tap_at=-1
    main.field_move_wheel_open = false
    main.field_move_wheel.visible = false
    var can_resume := not main._field_ui_blocks_gameplay(main.build_wheel_mode)
    if main.build_wheel_mode and main.build_menu_open: main.build_panel.visible = true
    main.world.set_gameplay_enabled(can_resume)
    if can_resume and activate_selection and selection >= 0:
        if main.build_wheel_mode:
            main.world.set_build_selection_index(main.build_wheel_page * main.BUILD_WHEEL_PAGE_SIZE + selection)
        else:
            _activate_field_move_wheel_selection(selection)

func _quick_breakable_field_move() -> int:
    var cell:Vector2i=main.world._player_cell()+main.world._facing_cell()
    if main.world.built_structures.has(cell):return -1
    var anchor:Vector2i=main.world._exact_resource_anchor(cell)
    var kind:String=main.world._exact_resource_kind(anchor)
    if kind.is_empty():
        anchor=main.world._resource_object_anchor(cell)
        kind=String(main.world.resource_objects.get(anchor,{}).get("type",""))
    var move_name=""
    if main.world._is_cuttable_grass_cell(cell) or kind in ["tree","bush"]:
        if find_field_move_pokemon_index("CUT")>=0:move_name="CUT"
        elif kind=="tree" and find_field_move_pokemon_index("HEADBUTT")>=0:move_name="HEADBUTT"
    elif kind=="rock" and find_field_move_pokemon_index("SMASH")>=0:move_name="SMASH"
    if move_name.is_empty() or move_name==main.world.active_field_move:return -1
    return FIELD_MOVE_WHEEL_ORDER.find(move_name)

func configure_build_wheel() -> void:
    var entries: Array[Dictionary] = []
    var start := main.build_wheel_page * main.BUILD_WHEEL_PAGE_SIZE
    for index in range(start, mini(start + main.BUILD_WHEEL_PAGE_SIZE, CraftingData.build_recipes().size())):
        var item := String(CraftingData.build_recipes()[index].name)
        entries.append({"move":CraftingData.build_display_name(item), "available":true,
            "texture":main.world._structure_display_texture(item), "build_item":true,
            "cost":CraftingData.build_recipes()[index].get("cost", {}).duplicate()})
    main.field_move_wheel_index = -1
    main.field_move_wheel.configure(entries, -1)
    main.field_move_wheel.page_label = "%d / %d  L / R" % [main.build_wheel_page + 1, ceili(float(CraftingData.build_recipes().size()) / main.BUILD_WHEEL_PAGE_SIZE)]
    main.field_move_wheel.queue_redraw()

func _field_move_wheel_entries() -> Array[Dictionary]:
    var entries: Array[Dictionary] = []
    for move_name in FIELD_MOVE_WHEEL_ORDER:
        var party_index := find_field_move_pokemon_index(move_name)
        var species := String(FIELD_MOVE_REPRESENTATIVES[move_name])
        if party_index >= 0:
            species = String((main.caught_pokemon[party_index] as Dictionary).get(
                "species", species)).to_lower()
        if move_name == "PAINT":
            species = "smeargle"
        entries.append({
            "move": move_name,
            "species": species,
            "available": party_index >= 0,
            "party_index": party_index,
            "texture": field_move_wheel_icon(species, party_index >= 0 and PokemonData.is_shiny(main.caught_pokemon[party_index]), String(main.caught_pokemon[party_index].get("form","")) if party_index>=0 else "")
        })
    return entries

func find_field_move_pokemon_index(move_name: String) -> int:
    for index in range(main.caught_pokemon.size()):
        if typeof(main.caught_pokemon[index]) != TYPE_DICTIONARY:
            continue
        var pokemon := main.caught_pokemon[index] as Dictionary
        if bool(pokemon.get("is_egg", false)) or int(pokemon.get("hp", 1)) <= 0:
            continue
        if FieldMoveData.field_moves_for(String(pokemon.get("species", "")), String(pokemon.get("form", ""))).has(
                move_name):
            return index
    return -1

func field_move_wheel_icon(species: String, shiny: bool = false, form: String = "") -> Texture2D:
    var key := "mega_gengar" if species=="gengar" and form=="mega" else species
    var menu := preload("res://scripts/divinakra_mega_art.gd").texture(key,"menu",shiny)
    if menu != null: return main._source_texture_region(menu,Rect2(64,0,16,16))
    var texture := PokemonData.record_texture({"species":species,"shiny":shiny,"form":form}, "overworld")
    if texture == null:
        texture = PokemonData.texture(species, "front", shiny)
    if texture == null:
        return main.POKEMON_TEXTURES.get(species) as Texture2D
    if texture.has_meta("mega_gengar_walk"):
        var mega_frame := texture.get_width() / 6.0
        return main._source_texture_region(texture,Rect2(mega_frame * 4.0,0,mega_frame,texture.get_height()))
    if texture.get_width() >= 16 and texture.get_height() >= 16:
        var frame := AtlasTexture.new()
        frame.atlas = texture
        frame.region = Rect2(0, 0, 16, 16)
        return frame
    return texture

func _activate_field_move_wheel_selection(selection: int) -> void:
    if selection < 0 or selection >= FIELD_MOVE_WHEEL_ORDER.size():
        return
    var move_name := String(FIELD_MOVE_WHEEL_ORDER[clampi(
        selection, 0, FIELD_MOVE_WHEEL_ORDER.size() - 1)])
    var party_index := find_field_move_pokemon_index(move_name)
    if party_index < 0:
        if move_name != "CUT":
            main.dialogs.show_message("A POKEMON is required to use this FIELD MOVE.")
        return
    main._ensure_party_ecology_id(party_index)
    var pokemon := main.caught_pokemon[party_index] as Dictionary
    if not bool(main.world.call("set_active_field_move", pokemon, move_name)):
        return
    main.world.call("present_field_move_pokemon")
    if move_name == "BUILD":
        main.crafting_menu.open_build_menu()
    elif move_name not in ["CUT", "DIG"]:
        main.dialogs.show_message("%s is using %s." % [
            PokemonData.battle_display_name(String(pokemon.get("species", "POKEMON"))), move_name])
