extends Control

const Settings = preload("res://scripts/game_options.gd")
const Progress = preload("res://scripts/pokedex_progress.gd")
var main: Node
var roster: Array = []
var selection := 0
var from_menu := false
var rows: Array[Control] = []
var detail: Control
var counter: Label
var paging: Label
var cry: AudioStreamPlayer
var panels: Array[Panel] = []
var silhouette: ShaderMaterial
var backdrop: ColorRect
const PAGE_SIZE := 6
# Touch: a sprite grid with name search replaces the six-row list.
const GRID_COLUMNS := 4
const GRID_ROWS := 5
const GRID_PAGE := GRID_COLUMNS * GRID_ROWS
var touch_grid := false
var grid_cells: Array[Control] = []
var grid_page_items: Array = []
var query := ""
var searching := false
var search_label: Label
var footer_label: Label

func configure(owner_main: Node) -> void:
    main = owner_main
    var shader:=Shader.new()
    shader.code="shader_type canvas_item; void fragment(){ vec4 pixel=texture(TEXTURE,UV); COLOR=vec4(0.0,0.0,0.0,pixel.a*COLOR.a); }"
    silhouette=ShaderMaterial.new();silhouette.shader=shader
    name = "PokedexMenu"
    size = Vector2(640, 360)
    scale = Vector2(0.5, 0.5)
    z_index = 350
    texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
    mouse_filter = Control.MOUSE_FILTER_STOP
    backdrop = ColorRect.new()
    backdrop.name = "Background"
    backdrop.color = Color.WHITE; backdrop.size = size; backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
    add_child(backdrop)
    get_viewport().size_changed.connect(_fit_backdrop)
    var header := panel(Vector2(2,2), Vector2(636,44))
    text(header,"POKEDEX",Vector2(18,12),Vector2(190,22),20)
    var subtitle := text(header,"WILDS FIELD GUIDE",Vector2(318,15),Vector2(298,18),14)
    var totals := panel(Vector2(2,48),Vector2(636,32))
    counter = text(totals,"",Vector2(16,9),Vector2(602,18),13)
    var list_panel := panel(Vector2(2,82),Vector2(246,240))
    for i in range(PAGE_SIZE):
        var row := Control.new();row.position=Vector2(12,10+i*33);row.size=Vector2(222,33)
        list_panel.add_child(row);rows.append(row)
    paging=text(list_panel,"",Vector2(14,216),Vector2(218,16),12)
    touch_grid = preload("res://scripts/touch_ui.gd").touch_runtime()
    if touch_grid:
        for i in range(GRID_PAGE):
            var cell := Control.new()
            cell.position = Vector2(8 + (i % GRID_COLUMNS) * 58, 6 + int(i / GRID_COLUMNS) * 41)
            cell.size = Vector2(56, 40)
            cell.mouse_filter = Control.MOUSE_FILTER_IGNORE
            list_panel.add_child(cell)
            grid_cells.append(cell)
        paging.position.y = 214
        subtitle.hide()
        search_label = text(header,"",Vector2(250,15),Vector2(200,18),14)
    detail=panel(Vector2(250,82),Vector2(388,240))
    var footer:=panel(Vector2(2,324),Vector2(636,34))
    footer_label = text(footer,"UP/DOWN: SELECT  LEFT/RIGHT: PAGE  A: CRY  B: BACK",Vector2(14,11),Vector2(606,17),12)
    if touch_grid: footer_label.text = "TAP: SELECT   TAP AGAIN: CRY   SWIPE: PAGE"
    cry=AudioStreamPlayer.new();add_child(cry)
    roster=JSON.parse_string(FileAccess.get_file_as_string("res://data/pokedex_roster.json"))
    hide()

func _fit_backdrop() -> void:
    var bounds: Rect2 = get_global_transform_with_canvas().affine_inverse() * get_viewport().get_visible_rect()
    backdrop.position = bounds.position
    backdrop.size = bounds.size

func panel(at: Vector2, dimensions: Vector2) -> Panel:
    var node:=Panel.new();node.position=at;node.size=dimensions
    node.mouse_filter=Control.MOUSE_FILTER_IGNORE;add_child(node);panels.append(node)
    return node

func text(parent: Node, value: String, at: Vector2, dimensions: Vector2, font_size: int=14) -> Label:
    var node: Label=main._source_ui_label(parent,"Text",at,dimensions,font_size,value)
    node.clip_text=true
    var width:=node.get_theme_font("font").get_string_size(value,HORIZONTAL_ALIGNMENT_LEFT,-1,font_size).x
    # Fit the complete line, not a clipped line that is then scaled smaller.
    node.size.x=maxf(dimensions.x,ceilf(width))
    node.scale.x=minf(1.0,dimensions.x/maxf(1.0,width))
    return node

func wrapped(parent: Node, value: String, at: Vector2, dimensions: Vector2, font_size: int=12) -> Label:
    var node: Label=main._source_ui_label(parent,"Text",at,dimensions,font_size,value)
    node.autowrap_mode=TextServer.AUTOWRAP_WORD_SMART
    node.add_theme_constant_override("line_spacing",0)
    node.clip_text=true
    return node

func open(via_menu: bool=false) -> void:
    from_menu=via_menu
    main._sync_pokedex_owned()
    for node in panels: node.add_theme_stylebox_override("panel",Settings.style())
    main.world.set_gameplay_enabled(false)
    main.message_panel.hide()
    main.game_menu_box.hide()
    show();_fit_backdrop();refresh()

func close() -> void:
    cry.stop();hide()
    if from_menu:
        main.game_menu_box.show();main._update_game_menu_cursor()
    else:
        main.world.set_gameplay_enabled(not main._field_ui_blocks_gameplay() and not main._sleeping_bag_active())

func handle(event: InputEvent) -> void:
    if searching and event is InputEventKey and event.pressed:
        _search_key(event as InputEventKey)
        return
    if event.is_echo():return
    if event.is_action_pressed("cancel") or event.is_action_pressed("start") or event.is_action_pressed("pokedex"):
        close();return
    var move:=0
    if event.is_action_pressed("move_up"):move=-1
    elif event.is_action_pressed("move_down"):move=1
    elif event.is_action_pressed("move_left") or event.is_action_pressed("shoulder_left"):move=-PAGE_SIZE
    elif event.is_action_pressed("move_right") or event.is_action_pressed("shoulder_right"):move=PAGE_SIZE
    if move:
        selection=wrapi(selection+move,0,roster.size());refresh()
    elif event.is_action_pressed("confirm"): play_cry()

func play_cry() -> void:
    var path:=PokemonData.cry_path(String(roster[selection].species))
    if path.is_empty() or not ResourceLoader.exists(path):return
    cry.stop();cry.stream=load(path);AudioBalance.apply(cry);Settings.route_audio(cry);cry.play()

func clear_children(node: Node) -> void:
    for child in node.get_children():node.remove_child(child);child.queue_free()

func record_name(record: Dictionary) -> String:
    if int(main.pokedex_progress.entries.get(Progress.key(record),0))==0:return "???"
    if String(record.get("form",""))=="mega":return "MEGA GENGAR"
    # Full species/form identifiers avoid the battle HUD's shortened names.
    if String(record.species) in ["nidoran_m","nidoran_f"]:return PokemonData.battle_display_name(String(record.species))
    return String(record.species).replace("_"," ").to_upper()

func portrait(parent: Node, record: Dictionary, at: Vector2, dimensions: Vector2) -> void:
    var display_record:=record.duplicate()
    var known_shiny: bool=bool(main.pokedex_progress.shiny_entries.get(Progress.key(record),false))
    display_record["shiny"]=known_shiny
    var texture: Texture2D=main._party_record_frame(display_record)
    var sprite: TextureRect=main._source_texture_rect(parent,"FrontSprite",at,dimensions,texture)
    if int(main.pokedex_progress.entries.get(Progress.key(record),0))==0:sprite.material=silhouette
    elif known_shiny:
        main._source_texture_rect(parent,"ShinySymbol",at+dimensions-Vector2(8,8),Vector2(8,8),preload("res://scripts/menu_symbol_palette.gd").shiny())

func refresh() -> void:
    if roster.is_empty():return
    var seen:=0;var caught:=0
    for record in roster:
        var state:=int(main.pokedex_progress.entries.get(Progress.key(record),0))
        if state>0:seen+=1
        if state==2:caught+=1
    counter.text="SEEN %d   CAUGHT %d   %d ENTRIES / FORMS" % [seen,caught,roster.size()]
    if touch_grid:
        _refresh_grid()
    var first:=int(selection/PAGE_SIZE)*PAGE_SIZE
    for i in range(0 if touch_grid else PAGE_SIZE):
        var row:=rows[i];clear_children(row)
        if first+i>=roster.size():continue
        var record: Dictionary=roster[first+i]
        portrait(row,record,Vector2(12,0),Vector2(30,30))
        var label:=text(row,record_name(record),Vector2(48,1),Vector2(172,15),13)
        var state:=int(main.pokedex_progress.entries.get(Progress.key(record),0))
        text(row,["UNSEEN","SEEN","CAUGHT"][state],Vector2(48,17),Vector2(172,14),11)
        if first+i==selection:
            var tick: TextureRect=main._source_texture_rect(row,"Tick",Vector2(0,0),Vector2(5,7),main.source_command_cursor.texture)
            tick.position.y = roundf((30.0-tick.size.y)*0.5)
    if not touch_grid:
        paging.text="PREV   %d / %d   NEXT" % [int(selection/PAGE_SIZE)+1,ceili(float(roster.size())/PAGE_SIZE)]
    clear_children(detail)
    var selected: Dictionary=roster[selection]
    var data:=PokemonData.info(String(selected.species))
    if String(selected.get("form","")) == "mega":
        var boss: Dictionary = SourceEventData.event_spec("mega_gengar").party[0]
        data["stats"] = boss.base_stats
        data["catch_rate"] = boss.catch_rate
    text(detail,"No. %03d  %s" % [int(data.get("dex",0)),record_name(selected)],Vector2(14,10),Vector2(360,21),16)
    portrait(detail,selected,Vector2(18,34),Vector2(56,56))
    if int(main.pokedex_progress.entries.get(Progress.key(selected),0))<2:return
    text(detail," / ".join(data.get("types",[])),Vector2(92,34),Vector2(280,18),14)
    var state:=int(main.pokedex_progress.entries.get(Progress.key(selected),0))
    text(detail,"STATUS: "+["UNSEEN","SEEN","CAUGHT"][state],Vector2(92,54),Vector2(278,17),13)
    text(detail,"%s m / %s kg" % [str(data.get("height_m","?")),str(data.get("weight_kg","?"))],Vector2(92,74),Vector2(278,17),14)
    text(detail,"BASE STATS",Vector2(14,96),Vector2(360,16),12)
    var stats: Array=data.get("stats",[])
    var names: Array=["HP","ATK","DEF","SPEED","SP. ATK","SP. DEF"]
    for i in range(mini(stats.size(),6)):
        text(detail,"%s %d" % [names[i],int(stats[i])],Vector2(14+(i%3)*121,113+int(i/3)*17),Vector2(116,17),13)
    text(detail,"CATCH %d/255   %s" % [int(data.get("catch_rate",0)),String(data.get("growth_rate","")).trim_prefix("GROWTH_").replace("_"," ")],Vector2(14,150),Vector2(360,17),12)
    var habitats:=PokemonEcology.habitat_groups(String(selected.species))
    var habitat_text:=", ".join(habitats).replace("green12","graveyard").replace("green","grassland").replace("|","/").replace("_"," ").to_upper()
    if String(selected.species) == "mew" or (String(selected.species) == "gengar" and String(selected.get("form", "")) == "mega"): habitat_text = "DEEP FOREST"
    if preload("res://scripts/rare_biome_legendaries.gd").HABITATS.has(String(selected.species)):
        habitat_text = String(preload("res://scripts/rare_biome_legendaries.gd").HABITATS[String(selected.species)]).replace("_", " ")
    if data.has("mega_habitat"): habitat_text = String(data.mega_habitat)
    text(detail,"HABITAT: "+habitat_text,Vector2(14,173),Vector2(360,17),12)
    text(detail,"FIELD SKILLS",Vector2(14,194),Vector2(360,15),12)
    var skills:=FieldMoveData.field_moves_for(String(selected.species), String(selected.get("form", "")))
    wrapped(detail,", ".join(skills) if not skills.is_empty() else "NONE",Vector2(14,210),Vector2(360,24),11)

# --- touch grid and search --------------------------------------------------------

## Roster indices that match the search (only names the player has seen).
func visible_indices() -> Array:
    var result := []
    var needle := query.strip_edges().to_upper()
    for i in roster.size():
        if needle.is_empty() or record_name(roster[i]).contains(needle): result.append(i)
    return result

func grid_page() -> int:
    var items := visible_indices()
    var at := maxi(0, items.find(selection))
    return int(at / GRID_PAGE)

func page_count() -> int:
    return maxi(1, ceili(float(visible_indices().size()) / GRID_PAGE))

func turn_page(direction: int) -> void:
    var items := visible_indices()
    if items.is_empty(): return
    var page := clampi(grid_page() + direction, 0, page_count() - 1)
    selection = int(items[page * GRID_PAGE])
    refresh()

func _refresh_grid() -> void:
    var items := visible_indices()
    if not items.is_empty() and not items.has(selection): selection = int(items[0])
    var first := grid_page() * GRID_PAGE
    grid_page_items = items.slice(first, first + GRID_PAGE)
    for i in grid_cells.size():
        var cell := grid_cells[i]
        clear_children(cell)
        if i >= grid_page_items.size(): continue
        var index := int(grid_page_items[i])
        var record: Dictionary = roster[index]
        if index == selection:
            var frame := ColorRect.new()
            frame.size = cell.size
            frame.color = Color8(248, 208, 64, 140)
            frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
            cell.add_child(frame)
        portrait(cell, record, Vector2(14, 1), Vector2(28, 28))
        var number := text(cell, "%03d" % int(PokemonData.info(String(record.species)).get("dex", 0)), Vector2(0, 30), Vector2(56, 10), 8)
        number.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    paging.text = "PAGE %d / %d" % [grid_page() + 1, page_count()]
    search_label.text = ("SEARCH: " + query + "_") if searching else (("FILTER: " + query) if not query.is_empty() else "")

func begin_search() -> void:
    searching = true
    query = ""
    refresh()
    if DisplayServer.has_feature(DisplayServer.FEATURE_VIRTUAL_KEYBOARD):
        DisplayServer.virtual_keyboard_show("", Rect2i(), DisplayServer.KEYBOARD_TYPE_DEFAULT, 16)

func end_search(clear: bool) -> void:
    searching = false
    if clear: query = ""
    if DisplayServer.has_feature(DisplayServer.FEATURE_VIRTUAL_KEYBOARD):
        DisplayServer.virtual_keyboard_hide()
    refresh()

func _search_key(event: InputEventKey) -> void:
    if event.keycode in [KEY_ENTER, KEY_KP_ENTER, KEY_ESCAPE]:
        end_search(event.keycode == KEY_ESCAPE)
    elif event.keycode == KEY_BACKSPACE:
        query = query.left(-1)
        refresh()
    elif event.unicode >= 32 and query.length() < 16:
        query += char(event.unicode).to_upper()
        refresh()
