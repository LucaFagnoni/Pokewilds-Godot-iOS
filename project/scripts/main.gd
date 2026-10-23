extends Node
class_name GameMain
const TexturePixels = preload("res://scripts/texture_pixels.gd")

@onready var input_router: InputRouter = get_node("/root/InputRouterSingleton")

signal battle_party_chosen(index: int)
signal battle_text_finished
## Every battle line as it is shown, and how each battle ends: the hooks
## server/battle_transcript_record.gd records battle transcripts with.
signal battle_text_shown(message: String)
signal battle_ended(outcome: String)
signal mansion_switch_answered(pressed: bool)

var adjacent_worlds: Dictionary = {}
var current_world_grid := Vector2i.ZERO
var map_waypoints: Dictionary = {}
var waypoint_ui: Node
# Finger input for menus and the minimap (touch_ui.gd); active on phones.
var touch_ui: Node
var edge_travel_busy := false
var edge_sky: Node2D
signal progression_confirmed
signal progression_choice_made(value: int)

const DataPaths = preload("res://scripts/game_data_paths.gd")
const WorldSaves = preload("res://scripts/world_saves.gd")
var saves := WorldSaves.new("user://saves")
var touch_config_panel := preload("res://scripts/touch_config_panel.gd").new(self)
var setup_screen := preload("res://scripts/setup_screen.gd").new(self)
var appearance := preload("res://scripts/player_appearance.gd").new(self)
## The screens open over the field (screen_stack.gd); the *_open flags are views of it.
var screens := preload("res://scripts/screen_stack.gd").new()
var saving := preload("res://scripts/game_saving.gd").new(self)
var dialogs := preload("res://scripts/dialogs.gd").new(self)
var start_menu := preload("res://scripts/game_menu.gd").new(self)
var bag_menu := preload("res://scripts/bag_menu.gd").new(self)
var party_menu := preload("res://scripts/party_menu.gd").new(self)
var storage := preload("res://scripts/storage_menu.gd").new(self)
var crafting_menu := preload("res://scripts/crafting_menu.gd").new(self)
var move_wheel := preload("res://scripts/field_move_wheel.gd").new(self)
var minimap := preload("res://scripts/minimap.gd").new(self)
const CraftingData = preload("res://scripts/crafting_data.gd")
const ItemData = preload("res://scripts/item_data.gd")
const FieldMoveData = preload("res://scripts/field_move_data.gd")
const PokemonData = preload("res://scripts/pokemon_data.gd")
const PokemonEcology = preload("res://scripts/pokemon_ecology.gd")
const BattleEngine = preload("res://scripts/battle_engine.gd")
const BattleSession = preload("res://scripts/battle_session.gd")
const PokemonState = preload("res://scripts/pokemon_state.gd")
const SourceEventData = preload("res://scripts/source_event_data.gd")
const FieldMoveRadial = preload("res://scripts/field_move_radial.gd")
const SOURCE_MALE_SYMBOL = preload("res://assets/source_exact/global/male_symbol1.png")
const SOURCE_FEMALE_SYMBOL = preload("res://assets/source_exact/global/female_symbol1.png")

const PlayerLooks = preload("res://scripts/player_looks.gd")
const PLAYER_TEXTURES = PlayerLooks.PLAYER_TEXTURES
const PLAYER_RUN_TEXTURES = PlayerLooks.PLAYER_RUN_TEXTURES
const PLAYER_COLOR_NAMES = PlayerLooks.PLAYER_COLOR_NAMES
const PLAYER_COLOR_VALUES = PlayerLooks.PLAYER_COLOR_VALUES
const PLAYER_MODEL_NAMES = PlayerLooks.PLAYER_MODEL_NAMES
const PLAYER_MODEL_WALK_TEXTURES = PlayerLooks.PLAYER_MODEL_WALK_TEXTURES
const PLAYER_MODEL_RUN_TEXTURES = PlayerLooks.PLAYER_MODEL_RUN_TEXTURES
const PLAYER_MODEL_SLEEP_TEXTURES = PlayerLooks.PLAYER_MODEL_SLEEP_TEXTURES
const PLAYER_MODEL_SITTING_TEXTURES = PlayerLooks.PLAYER_MODEL_SITTING_TEXTURES
const PLAYER_MODEL_BATTLE_BACK_TEXTURES = PlayerLooks.PLAYER_MODEL_BATTLE_BACK_TEXTURES
const PLAYER_MODEL_REPLACE_COLORS = PlayerLooks.PLAYER_MODEL_REPLACE_COLORS
const PLAYER_MODEL_BATTLE_REPLACE_COLORS = PlayerLooks.PLAYER_MODEL_BATTLE_REPLACE_COLORS
const POKEMON_EGG_TEXTURE := preload("res://assets/pokemon_egg.png")
const GHOST_BATTLE_SHEET := preload("res://assets/events/ghost_battle_front.png")
const ITEM_BAG_POCKET_TEXTURE := preload("res://assets/item_bag_pockets.png")
const SOURCE_BATTLE_INTRO_PATH := "res://assets/source_exact/battle/battle_intro_anim1_sheet1.png"
const SOURCE_POKEBALL_TEXTURE := preload(
    "res://assets/source_exact/global/pokeball1_color.png")
const SOURCE_CAPTURE_POOF: Texture2D = preload(
    "res://assets/source_exact/global/poof_sheet1.png")
const SOURCE_POKEBALL_WIGGLE_TEXTURE := preload(
    "res://assets/source_exact/global/pokeball_wiggleSheet1_color.png")
const SOURCE_EVOLUTION_BACKGROUND := preload(
    "res://assets/source_exact/battle/battle_bg3.png")
const SOURCE_HATCH_BACKGROUND := preload(
    "res://assets/source_exact/battle/intro_frame6.png")
const SOURCE_LEVEL_STATS_BACKGROUND := preload(
    "res://assets/source_exact/battle/gsc/levelup_stats_screen1.png")
const SOURCE_ATTACK_MENU_BACKGROUND := preload(
    "res://assets/source_exact/menu/attack_screen1.png")
const SOURCE_PARTY_BACKGROUND := preload(
    "res://assets/source_exact/menu/gsc/background1.png")
const JOHTO_FONT := preload("res://assets/source_text_font.fnt")
const SYMBOL_FONT := preload("res://assets/fonts.ttf")
const DIALOGUE_BORDER := preload("res://assets/pokewilds_dialogue_border.png")
const SOURCE_SOUND_ROOT := "res://assets/source_audio/sounds/"
const EXP_GAIN_AUDIO_PATH := SOURCE_SOUND_ROOT + "xp-gain1.ogg"
const LEVEL_UP_AUDIO_PATH := SOURCE_SOUND_ROOT + "xp-levelup1.ogg"
const SOURCE_FRAME_TIME := 1.0 / 60.0
const BATTLE_ENTRY_SLIDE_PX_PER_FRAME: float = 4.0
const SOURCE_EXP_UNITS := 68
const SOURCE_LEVEL_STATS_MIN_FRAMES := 82
const SOURCE_EVOLUTION_CANCEL_END_FRAME := 464
const SOURCE_HATCH_COMPLETE_FRAME := 588
const BATTLE_TEXT_CHAR_DELAY := 0.05
const MESSAGE_HOLD_SECONDS := 1.2
const ITEM_MENU_VISIBLE_ROWS := 5
const EGG_HATCH_STEPS := 20 * PokemonEcology.EGG_STEP_INTERVAL
const STARTING_INVENTORY := {
    "POTION":0,
    "SLEEPING BAG":1,
    "ESCAPE ROPE":1
}

const POKEMON_TEXTURES := {
    "pidgey": preload("res://assets/pokemon_pidgey.png"),
    "rattata": preload("res://assets/pokemon_rattata.png"),
    "caterpie": preload("res://assets/pokemon_caterpie.png"),
    "pikachu": preload("res://assets/pokemon_pikachu.png"),
    "machop": preload("res://assets/pokemon_machop.png")
}

const BATTLE_BALL_BONUS := {
    "POKE BALL":1.0, "GREAT BALL":1.5, "ULTRA BALL":2.0,
    "HEAVY BALL":1.5, "LURE BALL":1.0, "FRIEND BALL":1.0,
    "LOVE BALL":1.0, "LEVEL BALL":1.0, "FAST BALL":1.0,
    "MOON BALL":1.0, "DUSK BALL":1.0, "NET BALL":1.0,
    "DIVE BALL":1.0, "QUICK BALL":1.0, "HEAL BALL":1.0,
    "NEST BALL":1.0, "DREAM BALL":1.0, "TIMER BALL":1.0,
    "MASTER BALL":999.0, "PARK BALL":999.0
}

const BATTLE_ITEM_RULES := BattleSession.ITEM_RULES

var sign_dialog: ConfirmationDialog
var sign_edit: LineEdit
var sign_edit_cell := Vector2i.ZERO
var sign_edit_mode := "SIGN"

@onready var setup_panel: Control = $UI/SetupPanel
@onready var world: Node2D = $World
@onready var touch_controls: TouchControls = $UI/TouchControls
@onready var touch_config: Panel = $UI/TouchConfig

@onready var player_model_name: Label = $UI/SetupPanel/PlayerModelName
@onready var world_edit: LineEdit = $UI/SetupPanel/WorldEdit
@onready var start_button: Button = $UI/SetupPanel/StartButton
@onready var menu_status: Label = $UI/SetupPanel/Status
@onready var player_preview: Sprite2D = $UI/SetupPanel/PlayerPreview
@onready var player_color_swatch: TextureRect = $UI/SetupPanel/PlayerColorSwatch

@onready var generation_panel: Control = $UI/GenerationPanel
@onready var generation_status: Label = $UI/GenerationPanel/Status
@onready var generation_tip_title: Label = $UI/GenerationPanel/ControlsTitle
@onready var generation_tip_text: Label = $UI/GenerationPanel/Controls

@onready var message_panel: Panel = $UI/MessagePanel
@onready var message_label: Label = $UI/MessagePanel/Message

@onready var battle_panel: Control = $UI/BattlePanel
@onready var battle_transition: ColorRect = $UI/BattlePanel/Transition
@onready var source_command_frame: TextureRect = $UI/BattlePanel/ExactBattleCommandFrame
@onready var source_single_hud: Control = $UI/BattlePanel/SourceSingleHud
@onready var source_enemy_name: Label = $UI/BattlePanel/SourceSingleHud/EnemyName
@onready var source_enemy_level: Label = $UI/BattlePanel/SourceSingleHud/EnemyLevel
@onready var source_enemy_status: Label = $UI/BattlePanel/SourceSingleHud/EnemyStatus
@onready var source_enemy_gender: TextureRect = $UI/BattlePanel/SourceSingleHud/EnemyGender
@onready var source_enemy_hp_fill: ColorRect = $UI/BattlePanel/SourceSingleHud/EnemyHPFill
@onready var source_player_name: Label = $UI/BattlePanel/SourceSingleHud/PlayerName
@onready var source_player_level: Label = $UI/BattlePanel/SourceSingleHud/PlayerLevel
@onready var source_player_status: Label = $UI/BattlePanel/SourceSingleHud/PlayerStatus
@onready var source_player_gender: TextureRect = $UI/BattlePanel/SourceSingleHud/PlayerGender
@onready var source_player_hp_fill: ColorRect = $UI/BattlePanel/SourceSingleHud/PlayerHPFill
@onready var source_player_hp_current: Label = $UI/BattlePanel/SourceSingleHud/PlayerHPCurrent
@onready var source_player_hp_max: Label = $UI/BattlePanel/SourceSingleHud/PlayerHPMax
@onready var source_player_exp_fill: ColorRect = $UI/BattlePanel/SourceSingleHud/EXPFill
@onready var source_command_cursor: TextureRect = $UI/BattlePanel/SourceSingleHud/SourceCommandCursor
@onready var player_battle_sprite: TextureRect = $UI/BattlePanel/PlayerSprite
@onready var enemy_sprite: TextureRect = $UI/BattlePanel/EnemySprite
@onready var player_partner_sprite: TextureRect = $UI/BattlePanel/PlayerPartnerSprite
@onready var enemy_partner_sprite: TextureRect = $UI/BattlePanel/EnemyPartnerSprite
@onready var double_status: Label = $UI/BattlePanel/DoubleStatus
@onready var battle_weather_overlay: ColorRect = $UI/BattlePanel/WeatherOverlay
@onready var battle_move_animation: TextureRect = $UI/BattlePanel/MoveAnimation
@onready var battle_field_label: Label = $UI/BattlePanel/FieldLabel
@onready var enemy_hud: Control = $UI/BattlePanel/EnemyHud
@onready var enemy_label: Label = $UI/BattlePanel/EnemyHud/EnemyLabel
@onready var enemy_level_label: Label = $UI/BattlePanel/EnemyHud/Level
@onready var enemy_gender_label: Label = $UI/BattlePanel/EnemyHud/Gender
@onready var enemy_hp_fill: ColorRect = $UI/BattlePanel/EnemyHud/HPFill
@onready var player_hud: Control = $UI/BattlePanel/PlayerHud
@onready var player_battle_label: Label = $UI/BattlePanel/PlayerHud/Name
@onready var player_level_label: Label = $UI/BattlePanel/PlayerHud/Level
@onready var player_gender_label: Label = $UI/BattlePanel/PlayerHud/Gender
@onready var player_hp_fill: ColorRect = $UI/BattlePanel/PlayerHud/HPFill
@onready var player_hp_value: Label = $UI/BattlePanel/PlayerHud/HPValue
@onready var player_exp_fill: ColorRect = $UI/BattlePanel/PlayerHud/EXPFill
@onready var battle_status: Label = $UI/BattlePanel/BattleStatus
@onready var battle_command_box: Panel = $UI/BattlePanel/CommandBox
@onready var battle_command_divider: ColorRect = $UI/BattlePanel/CommandBox/Divider
@onready var battle_actions: Control = $UI/BattlePanel/Actions
@onready var battle_message_arrow: Label = $UI/BattlePanel/MessageArrow
@onready var fight_button: Button = $UI/BattlePanel/Actions/Fight
@onready var item_button: Button = $UI/BattlePanel/Actions/Item
@onready var party_button: Button = $UI/BattlePanel/Actions/Party
@onready var catch_button: Button = $UI/BattlePanel/Actions/Catch
@onready var run_button: Button = $UI/BattlePanel/Actions/Run
@onready var battle_command_cursor: Label = $UI/BattlePanel/Actions/Cursor
@onready var battle_move_type_box: Panel = $UI/BattlePanel/MoveTypeBox
@onready var battle_move_type: Label = $UI/BattlePanel/MoveTypeBox/Type
@onready var battle_move_pp: Label = $UI/BattlePanel/MoveTypeBox/PP
@onready var battle_move_box: Panel = $UI/BattlePanel/MoveBox
@onready var battle_move_cursor: Label = $UI/BattlePanel/MoveBox/Cursor
@onready var battle_move_list: Label = $UI/BattlePanel/MoveBox/List
@onready var battle_audio: AudioStreamPlayer = $UI/BattlePanel/BattleAudio
@onready var battle_submenu: Control = $UI/BattlePanel/BattleSubmenu
@onready var battle_submenu_title: Label = $UI/BattlePanel/BattleSubmenu/Window/Title
@onready var battle_submenu_cursor: Label = $UI/BattlePanel/BattleSubmenu/Window/Cursor
@onready var battle_submenu_list: Label = $UI/BattlePanel/BattleSubmenu/Window/List
@onready var battle_submenu_hint: Label = $UI/BattlePanel/BattleSubmenu/Window/Hint

@onready var progression_overlay: Control = $UI/ProgressionOverlay
@onready var progression_background: TextureRect = $UI/ProgressionOverlay/Background
@onready var progression_animation: TextureRect = $UI/ProgressionOverlay/Animation
@onready var progression_sprite_top: TextureRect = $UI/ProgressionOverlay/SpriteTop
@onready var progression_sprite_bottom: TextureRect = $UI/ProgressionOverlay/SpriteBottom
@onready var progression_title: Label = $UI/ProgressionOverlay/Title
@onready var progression_list: Label = $UI/ProgressionOverlay/List
@onready var progression_values: Label = $UI/ProgressionOverlay/Values
@onready var progression_cursor: Label = $UI/ProgressionOverlay/Cursor
@onready var progression_detail: Label = $UI/ProgressionOverlay/Detail
@onready var progression_hint: Label = $UI/ProgressionOverlay/Hint

@onready var show_touch: CheckButton = $UI/TouchConfig/VBox/ShowTouch
@onready var auto_hide: CheckButton = $UI/TouchConfig/VBox/AutoHide
@onready var touch_opacity_label: Label = $UI/TouchConfig/VBox/OpacityLabel
@onready var touch_opacity_slider: HSlider = $UI/TouchConfig/VBox/Opacity
@onready var touch_size_label: Label = $UI/TouchConfig/VBox/SizeLabel
@onready var touch_size_slider: HSlider = $UI/TouchConfig/VBox/Size
@onready var touch_theme_button: Button = $UI/TouchConfig/VBox/ThemeMode

@onready var game_menu: Control = $UI/GameMenu
@onready var game_menu_box: Panel = $UI/GameMenu/MenuBox
@onready var game_menu_cursor: Label = $UI/GameMenu/MenuBox/Cursor
@onready var game_menu_detail: Panel = $UI/GameMenu/DetailBox
@onready var game_menu_detail_title: Label = $UI/GameMenu/DetailBox/Title
@onready var game_menu_detail_body: Label = $UI/GameMenu/DetailBox/Body
@onready var game_menu_map_screen: Control = $UI/GameMenu/MapScreen
@onready var game_menu_map: Control = $UI/GameMenu/MapScreen/MapCanvas
@onready var guide_menu: Panel = $UI/GameMenu/GuideMenu
@onready var guide_menu_cursor: Label = $UI/GameMenu/GuideMenu/Cursor
@onready var guide_menu_up_arrow: Label = $UI/GameMenu/GuideMenu/UpArrow
@onready var guide_menu_down_arrow: Label = $UI/GameMenu/GuideMenu/DownArrow
@onready var guide_menu_rows: Array[Label] = [
    $UI/GameMenu/GuideMenu/FieldMoves,
    $UI/GameMenu/GuideMenu/Crafting,
    $UI/GameMenu/GuideMenu/Fainting,
    $UI/GameMenu/GuideMenu/Ghosts
]
@onready var item_pocket_menu: Control = $UI/GameMenu/ItemPocketMenu
@onready var item_pocket_label: TextureRect = $UI/GameMenu/ItemPocketMenu/PocketLabel
@onready var item_pocket_bag: TextureRect = $UI/GameMenu/ItemPocketMenu/PocketBag
@onready var item_pocket_cursor: Control = $UI/GameMenu/ItemPocketMenu/Cursor
@onready var item_pocket_list: Label = $UI/GameMenu/ItemPocketMenu/List
@onready var item_pocket_quantities: Label = $UI/GameMenu/ItemPocketMenu/Quantities
@onready var item_pocket_description: Label = $UI/GameMenu/ItemPocketMenu/Description
@onready var pokemon_menu: Control = $UI/GameMenu/PokemonMenu
@onready var pokemon_menu_cursor: Label = $UI/GameMenu/PokemonMenu/Cursor
@onready var pokemon_menu_sprite: TextureRect = $UI/GameMenu/PokemonMenu/PokemonSprite
@onready var pokemon_menu_name: Label = $UI/GameMenu/PokemonMenu/Name
@onready var pokemon_menu_level: Label = $UI/GameMenu/PokemonMenu/Level
@onready var pokemon_menu_hp_value: Label = $UI/GameMenu/PokemonMenu/HPValue
@onready var pokemon_menu_hp_fill: ColorRect = $UI/GameMenu/PokemonMenu/HPBar/Fill
@onready var pokemon_menu_prompt: Label = $UI/GameMenu/PokemonMenu/PromptBox/Prompt
@onready var save_confirm: Panel = $UI/GameMenu/SaveConfirm
@onready var save_confirm_cursor: Label = $UI/GameMenu/SaveConfirm/Cursor
@onready var quit_prompt: Panel = $UI/QuitPrompt
@onready var quit_prompt_title: Label = $UI/QuitPrompt/Title
@onready var quit_prompt_cursor: Label = $UI/QuitPrompt/Cursor
@onready var crafting_panel: Panel = $UI/CraftingPanel
@onready var crafting_title: Label = $UI/CraftingPanel/Title
@onready var crafting_cursor: Label = $UI/CraftingPanel/Cursor
@onready var crafting_list: Label = $UI/CraftingPanel/List
@onready var crafting_cost: RichTextLabel = $UI/CraftingPanel/Cost
@onready var build_panel: Panel = $UI/BuildPanel
@onready var build_title: Label = $UI/BuildPanel/Title
@onready var build_builder: Label = $UI/BuildPanel/Builder
@onready var build_cursor: Label = $UI/BuildPanel/Cursor
@onready var build_list: Label = $UI/BuildPanel/List
@onready var build_cost: RichTextLabel = $UI/BuildPanel/Cost
@onready var resource_popup: Panel = $UI/ResourcePopup
@onready var resource_popup_text: Label = $UI/ResourcePopup/Text

var started := false
var generating := false
var generation_tip_timer := 0.0
var generation_tip_index := -1
var battle_active: bool:
    get: return screens.is_open(&"battle")
    set(value): screens.set_open(&"battle", value)
var battle_turn_busy := false
var battle_player: Dictionary = {}
var battle_enemy: Dictionary = {}
var battle_context: Dictionary = {}
var battle_enemy_party: Array = []
var battle_enemy_party_index := 0
var battle_is_double := false
var battle_player_partner: Dictionary = {}
var battle_enemy_partner: Dictionary = {}
var battle_partner_party_index := -1
var battle_enemy_partner_party_index := -1
var battle_double_command_slot := 0
var battle_double_actions: Array[Dictionary] = []
var battle_double_pending_move := ""
var battle_double_replacement_slot := -1
var battle_result_sent := false
var battle_party_index := 0
var battle_move_index := 0
var battle_command_index := 0
var battle_ui_mode := "INTRO"
var battle_rng := RandomNumberGenerator.new()
## The battle on screen (scripts/battle_session.gd): this file plays its events.
var battle_session: BattleSession
var battle_turn_count := 0
var battle_field: Dictionary = {}
var battle_submenu_mode := ""
var battle_submenu_index := 0
var battle_submenu_entries: Array[Dictionary] = []
var battle_pending_item := ""
var last_battle_ball := ""
var battle_item_pocket_open := false
var battle_item_pocket_index := ItemData.POCKET_ITEMS
var battle_item_menu_names: Array[String] = []
var battle_item_menu_index := 0
var source_effect_playing := false
var source_boss: Control
var source_boss_move_type := "NORMAL"
var source_mewtwo: Control
var source_mewtwo_intro_seen := false
## 1.65 MB of JSON, parsed on a thread from startup; the first use waits for it.
var battle_animation_manifest: Dictionary:
    get:
        if battle_animation_manifest_thread != null:
            _battle_animation_manifest = battle_animation_manifest_thread.wait_to_finish()
            battle_animation_manifest_thread = null
        return _battle_animation_manifest
var _battle_animation_manifest: Dictionary = {}
var battle_animation_manifest_thread: Thread
var battle_animation_cache: Dictionary = {}
var battle_directive_cache: Dictionary = {}

## Textures only some looks/screens need load on first use and stay cached.
var lazy_textures: Dictionary = {}
func lazy_texture(path: String) -> Texture2D:
    var texture = lazy_textures.get(path)
    if texture == null:
        texture = load(path)
        lazy_textures[path] = texture
    return texture

## A move's atlas page is 0.1-8 MB decoded: keep only the current move's (at most two).
func _cache_battle_sheet(path: String, sheet: Texture2D) -> void:
    if battle_animation_cache.size() >= 2: battle_animation_cache.clear()
    battle_animation_cache[path] = sheet
var battle_sprite_alpha_cache: Dictionary = {}
var battle_sprite_animation_elapsed := 0.0
var battle_sprite_animation_frame := 0
const BATTLE_SPRITE_FRAME_SECONDS := 0.18
var battle_player_cry_played := false
var battle_capture_ball: TextureRect = null
var battle_text_full := ""
var battle_text_busy := false
var battle_text_accumulator := 0.0
var mansion_switch_open: bool:
    get: return screens.is_open(&"mansion_switch")
    set(value): screens.set_open(&"mansion_switch", value)
var mansion_switch_stage := 0
var mansion_switch_index := 0
var battle_entry_pending: bool:
    get: return screens.is_open(&"battle_entry")
    set(value): screens.set_open(&"battle_entry", value)
var progression_move_frame: Panel
var progression_type_frame: Panel
var progression_choice_frame: Panel
var progression_move_rows: Array[Label] = []
var progression_type_label: Label
var progression_pp_label: Label
var progression_menu_cursor: Label
var progression_yes_no_cursor: Label
var overworld_evolution_item := ""
var overworld_evolution_running := false
var capture_experience_presenting := false
var progression_active: bool:
    get: return screens.is_open(&"progression")
    set(value): screens.set_open(&"progression", value)
var progression_mode := ""
var hatch_skip_requested := false
const HATCH_PLAYBACK_SPEED := 1.2
var progression_waiting_input := false
var progression_choice_index := 0
# The move last shown on the forget screen, kept across its YES/NO questions.
var progression_move_index := 0
var progression_pending_move := ""
var progression_pokemon: Dictionary = {}
var progression_level_dialogue: Panel
var progression_level_message: Label
var setup_load_panel: Control
var setup_load_name: Label
var setup_load_index := 0
var setup_load_entries: Array[Dictionary] = []
var setup_load_open: bool:
    get: return screens.is_open(&"setup_load")
    set(value): screens.set_open(&"setup_load", value)
var setup_load_committed := false
var setup_load_path := ""
var pokemon_action_list: Label
var pokemon_action_open := false
var pokemon_action_index := 0
var pokemon_switch_selecting := false
var pokemon_switch_source_index := -1
var setup_go_cursor: TextureRect
var pokemon_party_rows: Array[Dictionary] = []
var progression_stats_frame: Panel
var progression_stats_fields: Array[Label] = []
var pokemon_stats_overlay: Control
var pokemon_stats_body_left: Label
var pokemon_stats_body_right: Label
var pokemon_stats_open: bool:
    get: return screens.is_open(&"pokemon_stats")
    set(value): screens.set_open(&"pokemon_stats", value)
var battle_party_view: Control
var battle_party_cursor: Label
var battle_party_sprite: TextureRect
var battle_party_name: Label
var battle_party_level: Label
var battle_party_gender: TextureRect
var battle_party_hp_value: Label
var battle_party_hp_fill: ColorRect
var battle_party_prompt: Label
var battle_party_action_panel: Panel
var battle_party_action_cursor: TextureRect
var battle_party_action_list: Label
var battle_party_action_open := false
var battle_party_action_index := 0
var battle_party_action_entries: Array[String] = []
var battle_party_rows: Array[Dictionary] = []
var battle_clean_command_cursor: TextureRect
var evolution_cancel_requested := false
var evolution_greyscale_material: ShaderMaterial
var player_color_index := 0
var player_model_index := 0
var current_species := ""
var current_level := 1
var caught_species = []
var pokedex_progress = preload("res://scripts/pokedex_progress.gd").new()
var pokedex_menu: Control
var android_back_bridge: Object
var android_back_bridge_checked := false
var caught_pokemon = []
var inventory: Dictionary = CraftingData.ensure_inventory(STARTING_INVENTORY)
var pokemon_storage: Dictionary = {}
## Single-player only: the box under this name is what every purple SHARED
## chest opens. It is kept in a file of its own beside the saves, so the same
## Pokemon are in it whichever single-player save is loaded. STORAGE BOXES are
## unchanged and belong to their own save.
const SHARED_STORAGE_KEY := "SHARED"
## The number the shared storage was last written under.
var shared_storage_serial := 0
## How the last write of the shared storage went, told after SAVE.
var shared_storage_error := OK
## Writes the world save in the background (see _write_single_player_save).
var save_thread: Thread
var storage_rows: Array[Dictionary] = []
var storage_action_labels: Array[Label] = []
var storage_choice_label: Label
var storage_no_label: Label
var storage_nickname: LineEdit
var storage_mode := "LIST"
var storage_action_index := 0
var storage_yes := true
var storage_pending := ""
var storage_switch_from := -1
const POKEMON_STORAGE_CAPACITY := 0 # 0 retains the source unlimited chest.
var overflow_recovery_notice := ""
var storage_pooled := false
var storage_menu_open: bool:
    get: return screens.is_open(&"storage")
    set(value): screens.set_open(&"storage", value)
var storage_box_key := ""
var preferred_storage_box := ""
var storage_column := 0
var storage_index := 0
var storage_box_window_start := 0
var trainer_tip_open: bool:
    get: return screens.is_open(&"trainer_tip")
    set(value): screens.set_open(&"trainer_tip", value)
var trainer_tip_continue: Label
var item_menu_names: Array[String] = []
var item_menu_index := 0
var item_pocket_context := ""
var bag_action_ui: Control
var safari_ui: Control
## The full map's picture, kept up to date while playing (source_map_raster.gd).
var map_raster = preload("res://scripts/source_map_raster.gd").new(self)
var planting_bag_target: Variant = null
var field_item_busy: bool:
    get: return screens.is_open(&"field_item")
    set(value): screens.set_open(&"field_item", value)
var sleeping_bag_heal_accumulator := 0.0
var craft_menu_open: bool:
    get: return screens.is_open(&"crafting")
    set(value): screens.set_open(&"crafting", value)
var build_menu_open: bool:
    get: return screens.is_open(&"build_menu")
    set(value): screens.set_open(&"build_menu", value)
var build_menu_index := 0
var resource_popup_timer := 0.0
var resource_popup_name := ""
var resource_popup_amount := 0
const SOURCE_MAP_TILE_PIXELS := 4
const DEFAULT_MAP_ZOOM := 3.0 / SOURCE_MAP_TILE_PIXELS
const MINIMAP_SIZE := Vector2(64.0, 64.0)
const MINIMAP_MAP_RADIUS := 26.4
const MAP_VIEWPORT_CENTER := Vector2(160.0, 78.0)
const MAP_VIEWPORT_SIZE := Vector2(320.0, 156.0)
var map_zoom := DEFAULT_MAP_ZOOM
var map_pan := Vector2.ZERO
var map_view_node: TextureRect
var dig_reward_label: Label
var dig_reward_seconds := 0.0
var minimap_north: Control
var minimap_root: Control
var minimap_map: TextureRect
var teleport_map_mode := false
var teleport_destinations: Array = []
var ball_mechanics: Node2D
var field_move_wheel: FieldMoveRadial
var field_move_wheel_open := false
var field_move_wheel_index := -1
var build_wheel_mode := false
var build_wheel_page := 0
var field_wheel_wait_for_release := false
const BUILD_WHEEL_PAGE_SIZE := 12
var last_android_back_msec := -10000
var game_menu_open: bool:
    get: return screens.is_open(&"game_menu")
    set(value): screens.set_open(&"game_menu", value)
var game_menu_detail_open := false
var game_menu_index := 0
var guide_menu_open := false
var guide_topic_open := false
var guide_menu_index := 0
var pokemon_menu_open := false
var pokemon_menu_index := 0
var egg_step_timer := 0
var friendship_step_timer := 0
var next_party_ecology_id := 1
var save_confirm_open := false
var save_confirm_index := 0
var quit_prompt_open: bool:
    get: return screens.is_open(&"quit_prompt")
    set(value): screens.set_open(&"quit_prompt", value)
var quit_prompt_index := 0 # 0 = YES, 1 = NO
var egg_pickup_open: bool:
    get: return screens.is_open(&"egg_prompt")
    set(value): screens.set_open(&"egg_prompt", value)
var egg_pickup_stage := 0 # 0 = discovery text, 1 = YES/NO
var egg_pickup_index := 0 # 0 = YES, 1 = NO
var egg_pickup_cell := Vector2i(-2147483648, -2147483648)
var egg_dialogue_panel: Panel
var egg_dialogue_label: Label
var egg_dialogue_arrow: Label
var egg_choice_panel: Panel
var egg_choice_cursor: Label
var wild_pokemon_prompt_open: bool:
    get: return screens.is_open(&"wild_prompt")
    set(value): screens.set_open(&"wild_prompt", value)
var wild_pokemon_prompt_stage := 0
var wild_pokemon_prompt_index := 0
var wild_pokemon_prompt_id := -1
var wild_pokemon_prompt_species := ""
var wild_pokemon_prompt_kind := ""
var deployed_prompt_cell := Vector2i.ZERO
var deployed_prompt_id := ""
# A wild-Pokemon prompt is opened synchronously by the same A/confirm event
# that interacted with the overworld Pokemon. Do not allow that opening press
# to also dismiss or advance the new prompt: arm confirmation only after the
# player releases A/start, so the next confirmation is a genuinely new press.
var wild_pokemon_prompt_confirm_armed := false
var wild_dialogue_panel: Panel
var wild_dialogue_label: Label
var wild_dialogue_arrow: Label
var wild_choice_panel: Panel
var wild_choice_cursor: Label
const GAME_MENU_OPTIONS := ["POKEDEX", "POKEMON", "ITEM", "STORAGE", "MAP", "GUIDE", "OPTIONS", "SAVE", "EXIT"]
const GameOptions = preload("res://scripts/game_options.gd")
var options_menu: Control
var game_files_menu: Control
const GUIDE_TOPICS := [
    {
        "name": "FIELD MOVES",
        "body": "Stand still while holding X to stop using a Field Move."
    },
    {
        "name": "CRAFTING",
        "body": "You can craft items at a campfire. Craft POKE BALLS using Apricorns."
    },
    {
        "name": "FAINTING",
        "body": "If you white out during battle, you will return to the last place you used a sleeping bag."
    },
    {
        "name": "GHOSTS",
        "body": "Ghosts may appear in the woods at night. A campfire will ward them off."
    },
    {
        "name": "BUILDING 1",
        "body": "Grass types know CUT. Use CUT on trees and tall grass to get building materials."
    },
    {
        "name": "BUILDING 2",
        "body": "Fighting-types know BUILD. Use CUT on buildings to remove them."
    },
    {
        "name": "BREEDING 3",
        "body": "POKEMON will lay EGGS when located near a compatible mate."
    },
    {
        "name": "HABITATS 1",
        "body": "Build fences to prevent your POKEMON from wandering off when you let them out of their POKE BALL."
    },
    {
        "name": "HABITATS 2",
        "body": "Your POKEMON will be happier if fenced in and located near a shelter."
    },
    {
        "name": "HABITATS 3",
        "body": "POKEMON are happier in their natural habitat. If happy enough, they may give you items!"
    },
    {
        "name": "WILDS EGGS",
        "body": "Be wary of taking EGGS near wild POKEMON. Angry parents may attack!"
    },
    {
        "name": "BACK DOORS",
        "body": "Build a door between two house tiles to make a back or side door to your house."
    },
    {
        "name": "HEALING 1",
        "body": "Sleeping indoors restores HP twice as fast as sleeping outdoors."
    },
    {
        "name": "HEALING 2",
        "body": "Sleeping in a bed will over time cure your POKEMON's status conditions."
    },
    {
        "name": "HEALING 3",
        "body": "Using your sleeping bag will slowly restore your party's HP."
    },
    {
        "name": "ESCAPE ROPE",
        "body": "Use the ESCAPE ROPE to return to the nearest location on the shore."
    },
    {
        "name": "PLANTS",
        "body": "Plant Miracle Seeds and Apricorns to grow grass and trees."
    },
    {
        "name": "GATES",
        "body": "Build a gate by building a door between two fences."
    },
    {
        "name": "EGGS",
        "body": "Eggs must be carried to hatch. RIDE counts while FLY does not."
    },
    {
        "name": "ROCK SMASH",
        "body": "Rock types know SMASH. Use it on boulders to collect rocks. Rocks respawn daily."
    },
    {
        "name": "SOFT BED 1",
        "body": "Collect Soft Feather and Silky Thread to make a soft bed for your home."
    },
    {
        "name": "SOFT BED 2",
        "body": "Bug types drop Silky Thread. Flying types drop Soft Feather."
    }
]
var message_timer := 0.0
var coop_game: Node
var coop_menu: Control
var online_label: Label
var menu_row := 0
var menu_col := 0
var selected_mode := "NEW"
var selected_world_size := 1 # S=0, M=1, L=2, XL=3, XXL=4
var menu_nav_cooldown := 0.0
const MENU_NAV_DELAY := 0.18
const MENU_STICK_ACTIVATION := 0.72
const MENU_STICK_RELEASE := 0.38
const MENU_STICK_REPEAT_MSEC := 320
var last_menu_stick_token := 0
var last_menu_stick_msec := -10000
var menu_stick_state_by_device: Dictionary = {}

const MENU_ROW_LOCAL := 0
const MENU_ROW_MODE := 1
const MENU_ROW_SIZE := 2
const MENU_ROW_WORLD_NAME := 3
const MENU_ROW_PLAYER_NAME := 4
const MENU_ROW_COLOR := 5

const WORLD_SIZE_NAMES := ["S", "M", "L", "XL", "XXL"]
const BUILD_COST_READY_COLOR := Color(0.0, 0.0, 0.0, 1.0)
const BUILD_COST_MISSING_COLOR := Color(0.52, 0.52, 0.52, 1.0)

var text_entry_target := "" # "" or "world"
var text_entry_buffer := ""
var new_world_sequence := 0

var startup_complete := false
var shared_save_folder: Node

var dark_mode_ui: Node

func _ready() -> void:
    _watch_screens()
    # Keep initialization and Android folder synchronization offscreen.
    $UI.hide()
    world.hide()
    generation_panel.hide()
    var storage_error := DataPaths.initialize()
    if storage_error != OK: push_error("Could not prepare game files: %s" % error_string(storage_error))
    shared_save_folder = preload("res://scripts/shared_save_folder.gd").new()
    add_child(shared_save_folder)
    set_process(false)
    set_process_input(false)
    set_process_unhandled_input(false)
    await shared_save_folder.prepare(self)
    saves = WorldSaves.new(DataPaths.path("saves"))
    GameOptions.load_settings()
    GameOptions.reset_launch_options()
    GameOptions.apply_audio()
    shared_save_folder.start_exports.call_deferred(self)
    _setup_options.call_deferred()
    setup_screen.setup_generation_clouds()
    _build_source_ui()
    minimap.build_dig_minimap_ui()
    world.visible = false
    setup_panel.visible = false
    generation_panel.visible = false
    battle_panel.visible = false
    battle_submenu.visible = false
    battle_move_animation.texture = null
    progression_overlay.visible = false
    setup_load_panel.visible = false
    pokemon_stats_overlay.visible = false
    battle_party_view.visible = false
    progression_animation.texture = null
    _create_evolution_greyscale_material()
    battle_move_type_box.visible = false
    battle_move_box.visible = false
    battle_message_arrow.visible = false
    _update_battle_command_cursor()
    message_panel.visible = false
    touch_config.visible = false
    game_menu.visible = false
    game_menu_map_screen.visible = false
    item_pocket_menu.z_index = 100
    item_pocket_menu.visible = false
    save_confirm.visible = false
    quit_prompt.visible = false
    crafting_panel.visible = false
    build_panel.visible = false
    resource_popup.visible = false
    battle_transition.visible = false
    field_move_wheel = FieldMoveRadial.new()
    field_move_wheel.name = "FieldMoveWheel"
    field_move_wheel.z_index = 250
    $UI.add_child(field_move_wheel)
    touch_controls.set_game_active(true)
    battle_rng.randomize()
    battle_animation_manifest_thread = Thread.new()
    battle_animation_manifest_thread.start(_load_battle_animation_manifest)

    world_edit.text = "PokeWilds"
    setup_screen.load_setup()
    saves.start_cache_cleanup()
    setup_screen.update_classic_menu_labels()

    # WORLD NAME uses the source-style 24-character entry buffer. Keep the
    # LineEdit itself out of keyboard/controller focus so its native caret
    # handling cannot consume D-pad navigation or resize the field while typing.
    world_edit.focus_mode = Control.FOCUS_NONE
    # The game opens its own keyboard (_show_virtual_keyboard_custom), never the system one.
    world_edit.virtual_keyboard_enabled = false
    world_edit.expand_to_text_length = false
    world_edit.mouse_filter = Control.MOUSE_FILTER_STOP

    player_preview.hframes = 8
    player_preview.frame = 0
    appearance.apply_player_appearance()

    start_button.pressed.connect(_start_game)
    $UI/SetupPanel/ColorUp.pressed.connect(appearance.next_color)
    $UI/SetupPanel/ColorDown.pressed.connect(appearance.previous_color)
    $UI/SetupPanel/ModelUp.pressed.connect(appearance.next_model)
    $UI/SetupPanel/ModelDown.pressed.connect(appearance.previous_model)

    world_edit.gui_input.connect(setup_screen.display_field_gui_input.bind("world"))
    world_edit.max_length = 24
    player_model_name.mouse_filter = Control.MOUSE_FILTER_STOP
    player_model_name.gui_input.connect(setup_screen.display_field_gui_input.bind("player"))
    player_model_name.size.x = 210
    setup_screen.fit_player_name()

    world.generation_progress.connect(setup_screen.on_generation_progress)
    world.encounter_requested.connect(_on_encounter_requested)
    if world.has_signal("battle_requested"):
        world.connect("battle_requested", Callable(self, "_on_battle_requested"))
    world.world_message.connect(dialogs.show_message)
    world.unown_message.connect(dialogs.show_unown_message)
    if world.has_signal("trainer_tip_message"):
        world.connect("trainer_tip_message", Callable(self,
            "_show_trainer_tip_message"))
    if world.has_signal("item_collected"):
        world.connect("item_collected", Callable(self, "_on_item_collected"))
    world.crafting_station_requested.connect(crafting_menu.open_crafting_menu)
    world.material_collected.connect(_on_material_collected)
    world.connect("dig_reward_collected", Callable(self, "_on_dig_reward_collected"))
    if world.has_signal("material_bundle_collected"):
        world.connect("material_bundle_collected", Callable(self, "_on_material_bundle_collected"))
    if world.has_signal("paint_requested"):
        world.connect("paint_requested", Callable(self, "_on_paint_requested"))
    if world.has_signal("teleport_map_requested"):
        world.connect("teleport_map_requested", Callable(self, "_open_teleport_map"))
    world.build_requested.connect(_on_build_requested)
    if world.has_signal("build_selection_changed"):
        world.connect(
            "build_selection_changed",
            Callable(self, "_on_world_build_selection_changed")
        )
    if world.has_signal("dig_requested"):
        world.connect("dig_requested", Callable(self, "_on_dig_requested"))
    world.build_refund_requested.connect(_on_build_refund_requested)
    if world.has_signal("structure_removal_requested"):
        world.connect("structure_removal_requested", Callable(self, "_on_structure_removal_requested"))
    world.pokemon_recalled.connect(_on_pokemon_recalled)
    world.deployed_recall_requested.connect(_on_deployed_recall_requested)
    world.structure_action.connect(_on_structure_action)
    dialogs.create_sign_editor()
    if world.has_signal("egg_collected"):
        world.connect("egg_collected", Callable(self, "_on_egg_collected"))
    if world.has_signal("egg_pickup_prompt_requested"):
        world.connect(
            "egg_pickup_prompt_requested",
            Callable(self, "_on_egg_pickup_prompt_requested")
        )
    if world.has_signal("wild_pokemon_prompt_requested"):
        world.connect(
            "wild_pokemon_prompt_requested",
            Callable(self, "_on_wild_pokemon_prompt_requested")
        )
    if world.has_signal("player_stepped"):
        world.connect("player_stepped", Callable(self, "_on_player_stepped"))
    if world.has_signal("pokemon_ecology_changed"):
        world.connect(
            "pokemon_ecology_changed",
            Callable(self, "_on_pokemon_ecology_changed")
        )

    fight_button.pressed.connect(_open_battle_move_menu)
    item_button.pressed.connect(_open_battle_item_menu)
    party_button.pressed.connect(_open_battle_party_menu.bind("PARTY"))
    catch_button.pressed.connect(_battle_catch)
    run_button.pressed.connect(_battle_run)

    show_touch.button_pressed = touch_controls.touch_enabled
    auto_hide.button_pressed = touch_controls.auto_hide_controller
    touch_opacity_slider.value = touch_controls.control_opacity * 100.0
    touch_size_slider.value = touch_controls.control_scale * 100.0
    show_touch.toggled.connect(touch_config_panel.show_touch_changed)
    auto_hide.toggled.connect(touch_config_panel.auto_hide_changed)
    touch_opacity_slider.value_changed.connect(touch_config_panel.touch_opacity_changed)
    touch_size_slider.value_changed.connect(touch_config_panel.touch_size_changed)
    touch_theme_button.pressed.connect(touch_config_panel.cycle_touch_theme)
    touch_controls.control_theme_changed.connect(touch_config_panel.on_touch_theme_changed)
    touch_controls.touch_config_requested.connect(
        touch_config_panel.open_touch_config
    )
    $UI/TouchConfig/VBox/MoveControls.pressed.connect(touch_config_panel.move_controls)
    $UI/TouchConfig/VBox/ResetLayout.pressed.connect(touch_config_panel.reset_layout)
    $UI/TouchConfig/VBox/Close.pressed.connect(touch_config_panel.close_touch_config)
    var files_button := Button.new()
    files_button.name="GameFiles";files_button.text="GAME FILES"
    $UI/TouchConfig/VBox.add_child(files_button)
    $UI/TouchConfig/VBox.move_child(files_button,$UI/TouchConfig/VBox/Close.get_index())
    files_button.pressed.connect(_open_game_files_menu)
    # iOS exposes user:// directly in the Files app; the folder picker is Android-only.
    files_button.visible = OS.get_name() == "Android"
    var mods_button := Button.new()
    mods_button.name="Modding";mods_button.text="MODDING"
    $UI/TouchConfig/VBox.add_child(mods_button)
    $UI/TouchConfig/VBox.move_child(mods_button,files_button.get_index()+1)
    mods_button.pressed.connect(_open_modding_menu)
    touch_config_panel.refresh_touch_config_labels()
    touch_config_panel.apply_touch_config_theme()

    coop_game = preload("res://scripts/coop_game.gd").new()
    add_child(coop_game)
    coop_game.configure(self)
    coop_menu = preload("res://scripts/coop_menu.gd").new()
    $UI.add_child(coop_menu)
    coop_menu.configure(self)
    coop_menu.chosen.connect(coop_game.choose)
    var mode_label: Label = $UI/SetupPanel/ModeLabel
    online_label = _source_ui_label(setup_panel,"OnlineLabel",
        Vector2(mode_label.position.x + JOHTO_FONT.get_string_size("NEW        ",HORIZONTAL_ALIGNMENT_LEFT,-1,12).x,6),
        Vector2(80,18),12,"BACK")
    # The top row is one control: BACK to the SOLO / CO-OP choice.
    # The current mode is already shown in the status corner.
    online_label.hide()
    var back_label := $UI/SetupPanel/LocalLabel as Label
    back_label.text="BACK"
    back_label.mouse_filter=Control.MOUSE_FILTER_STOP
    back_label.gui_input.connect(func(event):
        if event is InputEventMouseButton and event.pressed and event.button_index==MOUSE_BUTTON_LEFT and not started and not generating:
            menu_row=MENU_ROW_LOCAL;menu_col=0;setup_screen.update_menu_cursor();coop_game.cancel_join();coop_menu.open())
    setup_screen.setup_menu_navigation()
    _create_egg_pickup_ui()
    _create_wild_pokemon_prompt_ui()
    setup_screen.update_classic_menu_labels()
    setup_screen.update_menu_cursor()
    $UI.set_script(preload("res://scripts/proportional_ui_layout.gd"))
    $UI._ready()
    touch_ui = preload("res://scripts/touch_ui.gd").new()
    add_child(touch_ui)
    touch_ui.configure(self, $UI)
    setup_panel.show()
    $UI.show()
    $StartupSplash.hide()
    # First choice after the splash: SOLO or CO-OP.
    coop_menu.open()
    dark_mode_ui = preload("res://scripts/dark_mode.gd").new()
    add_child(dark_mode_ui)
    dark_mode_ui.configure($UI)
    dark_mode_ui.set_enabled(GameOptions.enabled("dark_mode"))
    startup_complete = true
    set_process(true)
    set_process_input(true)
    set_process_unhandled_input(true)

func _create_egg_pickup_ui() -> void:
    # Dedicated source-style egg prompt. It reuses the exact border and fonts
    # used by the rest of this port instead of introducing a second UI theme.
    egg_dialogue_panel = Panel.new()
    egg_dialogue_panel.name = "EggDialogue"
    # Match the compact source dialogue footprint instead of covering half of
    # the 320x180 playfield. Keep the approved border/font and anchor it at the
    # bottom edge exactly like the other source-style message boxes.
    # Keep the compact bar from M74.3.9.1, but give the two-line egg reveal
    # six more pixels of vertical breathing room. Preserve the same 2 px side
    # inset and 2 px bottom inset on the 320x180 source viewport.
    egg_dialogue_panel.position = Vector2(2, 126)
    egg_dialogue_panel.size = Vector2(316, 52)
    egg_dialogue_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
    egg_dialogue_panel.add_theme_stylebox_override("panel", _classic_dialogue_style())
    egg_dialogue_panel.visible = false
    $UI.add_child(egg_dialogue_panel)

    egg_dialogue_label = _source_ui_label(
        egg_dialogue_panel, "Message", Vector2(14, 6), Vector2(278, 40),
        10, ""
    )
    egg_dialogue_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    egg_dialogue_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER

    egg_dialogue_arrow = _source_ui_label(
        egg_dialogue_panel, "Arrow", Vector2(282, 30), Vector2(20, 16),
        10, "▼", true
    )
    egg_dialogue_arrow.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER

    egg_choice_panel = Panel.new()
    egg_choice_panel.name = "EggChoice"
    # Keep the YES/NO box exactly attached to the message bar's top-right
    # corner, but trim the oversized empty padding from the previous pass.
    # Right edge: 318 px. Bottom edge: 126 px, exactly matching the dialogue.
    egg_choice_panel.position = Vector2(234, 56)
    egg_choice_panel.size = Vector2(84, 70)
    egg_choice_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
    egg_choice_panel.add_theme_stylebox_override("panel", _classic_dialogue_style())
    egg_choice_panel.visible = false
    $UI.add_child(egg_choice_panel)

    egg_choice_cursor = _source_ui_label(
        egg_choice_panel, "Cursor", Vector2(11, 9), Vector2(14, 20),
        10, "▶", true
    )
    egg_choice_cursor.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
    var egg_yes := _source_ui_label(
        egg_choice_panel, "Yes", Vector2(28, 10), Vector2(46, 22), 10, "YES"
    )
    var egg_no := _source_ui_label(
        egg_choice_panel, "No", Vector2(28, 38), Vector2(46, 22), 10, "NO"
    )
    egg_yes.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
    egg_no.vertical_alignment = VERTICAL_ALIGNMENT_CENTER

func _create_wild_pokemon_prompt_ui() -> void:
    # Deliberately clone the egg prompt geometry/theme so wild interactions
    # retain the user's approved text, border and aligned YES/NO ticks.
    wild_dialogue_panel = Panel.new()
    wild_dialogue_panel.name = "WildPokemonDialogue"
    wild_dialogue_panel.position = Vector2(2, 126)
    wild_dialogue_panel.size = Vector2(316, 52)
    wild_dialogue_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
    wild_dialogue_panel.add_theme_stylebox_override("panel", _classic_dialogue_style())
    wild_dialogue_panel.visible = false
    $UI.add_child(wild_dialogue_panel)

    wild_dialogue_label = _source_ui_label(
        wild_dialogue_panel, "Message", Vector2(14, 6), Vector2(278, 40), 10, ""
    )
    wild_dialogue_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    wild_dialogue_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER

    wild_dialogue_arrow = _source_ui_label(
        wild_dialogue_panel, "Arrow", Vector2(282, 30), Vector2(20, 16),
        10, "▼", true
    )
    wild_dialogue_arrow.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER

    wild_choice_panel = Panel.new()
    wild_choice_panel.name = "WildPokemonChoice"
    wild_choice_panel.position = Vector2(234, 56)
    wild_choice_panel.size = Vector2(84, 70)
    wild_choice_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
    wild_choice_panel.add_theme_stylebox_override("panel", _classic_dialogue_style())
    wild_choice_panel.visible = false
    $UI.add_child(wild_choice_panel)

    wild_choice_cursor = _source_ui_label(
        wild_choice_panel, "Cursor", Vector2(11, 9), Vector2(14, 20),
        10, "▶", true
    )
    wild_choice_cursor.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
    var wild_yes := _source_ui_label(
        wild_choice_panel, "Yes", Vector2(28, 10), Vector2(46, 22), 10, "YES"
    )
    var wild_no := _source_ui_label(
        wild_choice_panel, "No", Vector2(28, 38), Vector2(46, 22), 10, "NO"
    )
    wild_yes.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
    wild_no.vertical_alignment = VERTICAL_ALIGNMENT_CENTER

## minimap.gd under its old names, for the scripts and tests that call them on main.
func _minimap_paint(changed: Rect2i, bounds: Rect2i, exact_world) -> void: minimap.minimap_paint(changed, bounds, exact_world)
func _minimap_render(region: Rect2i, bounds: Rect2i, exact_world) -> Image: return minimap.minimap_render(region, bounds, exact_world)
func _show_map_menu() -> void: minimap.show_map_menu()
func _open_teleport_map(destinations: Array) -> void: minimap.open_teleport_map(destinations)
func _update_map_transform() -> void: minimap.update_map_transform()
func _set_map_zoom(value: float) -> void: minimap.set_map_zoom(value)


## Other players in this area, drawn like the local player's own marker.
var minimap_others: Dictionary = {}

func _setup_options() -> void:
    options_menu = preload("res://scripts/options_menu.gd").new()
    $UI.add_child(options_menu)
    options_menu.configure(self)
    pokedex_menu = preload("res://scripts/pokedex_menu.gd").new()
    $UI.add_child(pokedex_menu)
    pokedex_menu.configure(self)
    show_touch.get_parent().get_node("Title").text = "CONTROLS"
    game_menu_box.position = Vector2(214, 7)
    game_menu_box.size = Vector2(102, 166)
    for child in game_menu_box.get_children():
        if child != game_menu_cursor: child.hide()
    for index in range(GAME_MENU_OPTIONS.size()):
        _source_ui_label(game_menu_box,"Option%d" % index,Vector2(28,11+index*17),Vector2(68,17),11,GAME_MENU_OPTIONS[index])
    _apply_game_options()
    start_menu.update_game_menu_cursor()
    _route_existing_audio(self)

func _route_existing_audio(node: Node) -> void:
    if node is AudioStreamPlayer: GameOptions.route_audio(node)
    for child in node.get_children(): _route_existing_audio(child)

func _apply_game_options() -> void:
    GameOptions.apply_audio()
    if is_instance_valid(world.environment_system): world.environment_system.apply_music_pack()
    preload("res://scripts/emote_style.gd").refresh_tree(get_tree())
    for marker in get_tree().get_nodes_in_group("styled_held_emotes"):
        marker.texture = preload("res://scripts/held_item_emote.gd").texture()
    touch_controls.set_button_layout(int(GameOptions.values.button_layout))
    input_router.set_button_layout(int(GameOptions.values.button_layout))
    input_router.diagonal_enabled = GameOptions.enabled("diagonal")
    input_router.auto_run_enabled = GameOptions.enabled("auto_run")
    if not GameOptions.enabled("radial") and field_move_wheel_open: move_wheel.close_field_move_wheel(false)
    if not GameOptions.enabled("zoom"):
        world.camera_zoom_level = 1.0
        world.player.camera.zoom = Vector2.ONE
        map_zoom = DEFAULT_MAP_ZOOM
    if not GameOptions.enabled("minimap") and is_instance_valid(minimap_root): minimap_root.hide()
    if is_instance_valid(waypoint_ui):
        if not GameOptions.enabled("map_waypoint") and waypoint_ui.naming: waypoint_ui.cancel_name()
        waypoint_ui.rebuild_markers()
        waypoint_ui.update_minimap(0.0)
    GameOptions.refresh_frames($UI)
    if is_instance_valid(dark_mode_ui): dark_mode_ui.set_enabled(GameOptions.enabled("dark_mode"))
    if not source_effect_playing: _restore_battle_background()

func _classic_dialogue_style() -> StyleBoxTexture:
    return GameOptions.style()

func _source_ui_label(parent: Node, node_name: String, at: Vector2,
        dimensions: Vector2, font_size: int, initial_text: String = "",
        use_symbol_font: bool = false) -> Label:
    var label := Label.new()
    label.name = node_name
    label.position = at
    label.size = dimensions
    label.text = initial_text
    label.mouse_filter = Control.MOUSE_FILTER_IGNORE
    label.add_theme_font_override("font", SYMBOL_FONT if use_symbol_font else JOHTO_FONT)
    label.add_theme_font_size_override("font_size", font_size)
    label.add_theme_color_override("font_color", Color.BLACK)
    parent.add_child(label)
    return label

func _align_menu_tick(marker: Control, row: Label, line_index: int = 0) -> void:
    # Center the native 5x7 tick on the eight-pixel Johto capital glyphs.
    # Symbol-font baselines differ from the bitmap font used by the words.
    if marker is Label:
        marker.text = ""
        if not marker.has_node("PixelTick"):
            # In dark mode the shared cursor holds its recoloured texture; a tick
            # must start from the original or dark mode recolours it twice.
            _source_texture_rect(marker, "PixelTick", Vector2.ZERO,
                Vector2(5, 7), source_command_cursor.get_meta("tick_source", source_command_cursor.texture))
    var font_size := row.get_theme_font_size("font_size")
    var line_height := row.get_theme_font("font").get_height(font_size)
    var top := row.position.y
    if row.vertical_alignment == VERTICAL_ALIGNMENT_CENTER:
        top += (row.size.y - line_height) / 2.0
    elif row.vertical_alignment == VERTICAL_ALIGNMENT_BOTTOM:
        top += row.size.y - line_height
    marker.position.y = roundf(top + line_index * (line_height + row.get_theme_constant("line_spacing")) + 4.0 * float(font_size) / 10.0 - 3.5)

func _align_control_tick(marker: Control, row: Control) -> void:
    var font_size := row.get_theme_font_size("font_size")
    var line_height := row.get_theme_font("font").get_height(font_size)
    var top := row.global_position.y
    if row is Button:
        var style := row.get_theme_stylebox("normal")
        var above := style.get_margin(SIDE_TOP)
        var below := style.get_margin(SIDE_BOTTOM)
        top += above + (row.size.y-above-below-line_height)*0.5
    elif row is Label:
        if row.vertical_alignment == VERTICAL_ALIGNMENT_CENTER: top += (row.size.y-line_height)*0.5
        elif row.vertical_alignment == VERTICAL_ALIGNMENT_BOTTOM: top += row.size.y-line_height
    marker.global_position.y = roundf(top+4.0*font_size/10.0-marker.size.y*0.5)

func _source_texture_rect(parent: Node, node_name: String, at: Vector2,
        dimensions: Vector2, texture: Texture2D = null) -> TextureRect:
    var rect := TextureRect.new()
    rect.name = node_name
    rect.position = at
    rect.size = dimensions
    rect.texture = texture
    rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
    rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
    rect.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
    rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
    parent.add_child(rect)
    return rect

## bag_menu.gd under its old names, for the scripts and tests that call them on main.
func _use_overworld_item(item: String) -> void: bag_menu.use_overworld_item(item)
func _refresh_evolution_item_target() -> void: bag_menu.refresh_evolution_item_target()
func _consume_inventory_item(item: String) -> void: bag_menu.consume_inventory_item(item)
func _sleeping_bag_active() -> bool: return bag_menu.sleeping_bag_active()

func _configure_wide_single_battle_layout() -> void:
    # Keep every source HUD element uniformly scaled, then move the enemy
    # group left and the player group right.  This fills the 16:9 viewport
    # without widening individual pixels or warping the Johto font.
    const ENEMY_SHIFT = -40.0
    const PLAYER_SHIFT = 40.0
    for node_name in ["EnemyFrame", "EnemyLevelChar", "EnemyName",
            "EnemyLevel", "EnemyStatus", "EnemyGender", "EnemyHPTrack", "EnemyHPFill"]:
        var node = source_single_hud.get_node(node_name) as Control
        node.position.x += ENEMY_SHIFT
    for node_name in ["PlayerFrame", "PlayerLevelChar", "PlayerName",
            "PlayerLevel", "PlayerStatus", "PlayerGender", "PlayerHPTrack", "PlayerHPFill",
            "PlayerHPCurrent", "PlayerHPMax", "EXPFill"]:
        var node = source_single_hud.get_node(node_name) as Control
        node.position.x += PLAYER_SHIFT

    battle_clean_command_cursor = _source_texture_rect(
        battle_actions, "CleanCommandCursor", Vector2.ZERO, Vector2(5, 7),
        source_command_cursor.texture)
    battle_clean_command_cursor.stretch_mode = TextureRect.STRETCH_SCALE
    battle_clean_command_cursor.z_index = 3
    battle_command_cursor.visible = false

## party_menu.gd under its old names, for the scripts and tests that call them on main.
func _refresh_pokemon_category_menu() -> void: party_menu.refresh_pokemon_category_menu()
func _finish_pokemon_switch() -> void: party_menu.finish_pokemon_switch()
func _party_record_frame(row_data: Dictionary) -> Texture2D: return party_menu.party_record_frame(row_data)

func _build_source_ui() -> void:
    bag_menu.configure_clean_item_pocket_layout()
    _configure_wide_single_battle_layout()
    setup_go_cursor = _source_texture_rect(setup_panel, "GoCursor",
        Vector2.ZERO, Vector2(6, 8), source_command_cursor.texture)
    setup_go_cursor.stretch_mode = TextureRect.STRETCH_SCALE
    setup_go_cursor.visible = false
    # Source-style save selector shown before a saved world is loaded.
    setup_load_panel = Control.new()
    setup_load_panel.name = "SourceLoadSelector"
    setup_load_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    setup_load_panel.z_index = 340
    $UI.add_child(setup_load_panel)
    var load_backdrop = ColorRect.new()
    load_backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    load_backdrop.color = Color.WHITE
    load_backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
    setup_load_panel.add_child(load_backdrop)
    var load_frame = Panel.new()
    load_frame.name = "LoadFrame"
    load_frame.position = Vector2(16, 14)
    load_frame.size = Vector2(288, 152)
    load_frame.add_theme_stylebox_override("panel", _classic_dialogue_style())
    setup_load_panel.add_child(load_frame)
    var load_title = _source_ui_label(load_frame, "Title", Vector2(20, 17),
        Vector2(248, 18), 12, "LOAD GAME")
    load_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    _source_ui_label(load_frame, "Previous", Vector2(32, 65),
        Vector2(10, 12), 9, "◀", true)
    setup_load_name = _source_ui_label(load_frame, "SaveName", Vector2(48, 62),
        Vector2(192, 16), 10, "default.sav")
    setup_load_name.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    setup_load_name.clip_text = true
    setup_load_name.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
    # When the save was made, and whether it is the world's autosave.
    _source_ui_label(load_frame, "SaveInfo", Vector2(48, 80),
        Vector2(192, 10), 7, "").horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    _source_ui_label(load_frame, "Next", Vector2(246, 65),
        Vector2(10, 12), 9, "▶", true)
    _source_ui_label(load_frame, "GoCursor", Vector2(108, 101),
        Vector2(7, 10), 7, "▶", true)
    _source_ui_label(load_frame, "Go", Vector2(117, 102),
        Vector2(55, 15), 11, "Go!")
    _align_menu_tick(load_frame.get_node("GoCursor"), load_frame.get_node("Go"))
    _align_menu_tick(load_frame.get_node("Previous"), setup_load_name)
    _align_menu_tick(load_frame.get_node("Next"), setup_load_name)
    (load_frame.get_node("Previous/PixelTick") as TextureRect).flip_h = true

    storage.build_storage_menu_ui()

    # Keep the MessagePanel's existing down arrow; no extra right-side arrow.
    trainer_tip_continue = null

    party_menu.build_party_menu_ui()

    # Battle PKMN selection uses the same source party row and dialogue border.
    battle_party_view = Control.new()
    battle_party_view.name = "SourcePartyView"
    battle_party_view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    battle_party_view.z_index = 10
    battle_submenu.add_child(battle_party_view)
    var battle_party_backdrop = ColorRect.new()
    battle_party_backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    battle_party_backdrop.color = Color.WHITE
    battle_party_backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
    battle_party_view.add_child(battle_party_backdrop)
    battle_party_cursor = _source_ui_label(battle_party_view, "Cursor",
        Vector2(4, 10), Vector2(10, 16), 9, "▶", true)
    battle_party_sprite = _source_texture_rect(battle_party_view, "PokemonSprite",
        Vector2(20, 6), Vector2(32, 32))
    battle_party_name = _source_ui_label(battle_party_view, "Name",
        Vector2(58, 10), Vector2(130, 18), 10)
    battle_party_level = _source_ui_label(battle_party_view, "Level",
        Vector2(150, 26), Vector2(44, 16), 9)
    battle_party_gender = _source_texture_rect(battle_party_view, "Gender",
        Vector2(62, 29), Vector2(10, 10), SOURCE_MALE_SYMBOL)
    battle_party_hp_value = _source_ui_label(battle_party_view, "HPValue",
        Vector2(230, 9), Vector2(72, 18), 10)
    battle_party_hp_value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
    var battle_hp_bar = ColorRect.new()
    battle_hp_bar.name = "HPBar"
    battle_hp_bar.position = Vector2(208, 34)
    battle_hp_bar.size = Vector2(94, 10)
    battle_hp_bar.color = Color.BLACK
    battle_party_view.add_child(battle_hp_bar)
    _source_ui_label(battle_hp_bar, "HPLabel", Vector2(-25, -2),
        Vector2(27, 12), 8, "HP:").add_theme_color_override(
            "font_color", Color8(240, 194, 69))
    battle_party_hp_fill = ColorRect.new()
    battle_party_hp_fill.name = "Fill"
    battle_party_hp_fill.position = Vector2(3, 3)
    battle_party_hp_fill.size = Vector2(88, 4)
    battle_party_hp_fill.color = Color8(0, 184, 0)
    battle_hp_bar.add_child(battle_party_hp_fill)
    var battle_prompt_panel = Panel.new()
    battle_prompt_panel.name = "PromptBox"
    battle_prompt_panel.position = Vector2(4, 138)
    battle_prompt_panel.size = Vector2(312, 40)
    battle_prompt_panel.add_theme_stylebox_override("panel", _classic_dialogue_style())
    battle_party_view.add_child(battle_prompt_panel)
    battle_party_prompt = _source_ui_label(battle_prompt_panel, "Prompt",
        Vector2(14, 10), Vector2(280, 18), 10, "Choose a POKEMON.")
    battle_party_action_panel = Panel.new()
    battle_party_action_panel.name = "PokemonActionMenu"
    battle_party_action_panel.position = Vector2(166, 40)
    battle_party_action_panel.size = Vector2(150, 138)
    battle_party_action_panel.add_theme_stylebox_override(
        "panel", _classic_dialogue_style())
    battle_party_view.add_child(battle_party_action_panel)
    battle_party_action_cursor = _source_texture_rect(battle_party_action_panel,
        "Cursor", Vector2(12, 10), Vector2(5, 7), source_command_cursor.texture)
    battle_party_action_cursor.stretch_mode = TextureRect.STRETCH_SCALE
    battle_party_action_list = _source_ui_label(battle_party_action_panel,
        "List", Vector2(28, 10), Vector2(110, 116), 10)
    battle_party_action_list.add_theme_constant_override("line_spacing", 6)
    battle_party_action_panel.visible = false
    battle_party_cursor.visible = false
    battle_party_sprite.visible = false
    battle_party_name.visible = false
    battle_party_level.visible = false
    battle_party_gender.visible = false
    battle_party_hp_value.visible = false
    battle_hp_bar.visible = false
    for row_index in range(6):
        battle_party_rows.append(party_menu.create_party_list_row(
            battle_party_view, row_index))
    battle_prompt_panel.move_to_front()
    battle_party_action_panel.move_to_front()

    party_menu.build_pokemon_stats_ui()
    progression_level_dialogue = Panel.new()
    progression_level_dialogue.name = "LevelUpDialogueBorder"
    progression_level_dialogue.position = Vector2(4, 121)
    progression_level_dialogue.size = Vector2(312, 57)
    progression_level_dialogue.add_theme_stylebox_override(
        "panel", _classic_dialogue_style())
    progression_level_dialogue.z_index = 1
    progression_overlay.add_child(progression_level_dialogue)
    progression_level_message = _source_ui_label(
        progression_level_dialogue, "LevelUpMessage", Vector2(12, 10),
        Vector2(282, 32), 10)
    progression_level_message.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    progression_level_message.clip_text = true
    progression_level_dialogue.visible = false
    progression_stats_frame = Panel.new()
    progression_stats_frame.name = "LevelUpStatsBorder"
    progression_stats_frame.position = Vector2(142, 0)
    progression_stats_frame.size = Vector2(178, 121)
    progression_stats_frame.add_theme_stylebox_override("panel", _classic_dialogue_style())
    progression_stats_frame.z_index = 2
    progression_overlay.add_child(progression_stats_frame)
    for index in range(5):
        var stat_name = _source_ui_label(progression_stats_frame, "Stat%d" % index,
            Vector2(16, 7 + index * 20), Vector2(108, 13), 10,
            ["ATTACK", "DEFENSE", "SPCL.ATK", "SPCL.DEF", "SPEED"][index])
        stat_name.mouse_filter = Control.MOUSE_FILTER_IGNORE
        var value = _source_ui_label(progression_stats_frame, "Value%d" % index,
            Vector2(132, 7 + index * 20), Vector2(32, 13), 10)
        value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
        progression_stats_fields.append(value)
    progression_stats_frame.visible = false
    progression_hint.z_index = 2
    progression_list.z_index = 2
    progression_values.z_index = 2
    progression_sprite_top.z_index = 2
    _create_progression_menu_frames()

## storage_menu.gd under its old names, for the scripts and tests that call them on main.
func _storage_pool_locations() -> Array: return storage.storage_pool_locations()
func _storage_deposit_key() -> String: return storage.storage_deposit_key()
func _storage_entries() -> Array: return storage.storage_entries()
func _refresh_storage_menu() -> void: storage.refresh_storage_menu()
func _storage_notice(text: String) -> void: storage.storage_notice(text)
func _storage_is_active(pokemon: Dictionary) -> bool: return storage.storage_is_active(pokemon)
func _built_storage_keys() -> Array[String]: return storage.built_storage_keys()

## The top row: minimap, clock, FPS counter, battery (status_hud.gd).
var status_hud = preload("res://scripts/status_hud.gd").new(self)
const HudStyle = preload("res://scripts/hud_style.gd")

var last_input_msec := 0

## Battery saver: OFF keeps 60 FPS; ON draws 30; AUTO draws 30 only while
## nothing moves (no input for a second, player still, no battle turn
## playing), which is most of the time spent in menus and dialogue.
func _apply_battery_saver() -> void:
    var mode := int(GameOptions.values.get("battery_saver", 1))
    var fps := 60
    if mode == 2:
        fps = 30
    elif mode == 1:
        var moving: bool = Time.get_ticks_msec() - last_input_msec < 1000
        if not moving and battle_active: moving = battle_turn_busy or battle_text_busy
        if not moving and started and is_instance_valid(world) and is_instance_valid(world.player):
            moving = world.player.velocity.length_squared() > 0.01 or world.active_field_move == "FLY"
        if not moving: fps = 30
    # At 3-4x game speed a 30 FPS step can cross a whole tile and skip its
    # encounters and triggers: never drop frames while moving that fast.
    if fps == 30 and float(GameOptions.values.get("game_speed", 1.0)) >= 3.0 and started and is_instance_valid(world) \
            and is_instance_valid(world.player) and world.player.velocity.length_squared() > 0.01:
        fps = 60
    if Engine.max_fps != fps: Engine.max_fps = fps

func _process(delta: float) -> void:
    status_hud.update_fps(delta)
    _apply_battery_saver()
    _hide_world_under_battle()
    if started and world.generated and not generating:
        map_raster.update(game_menu_map_screen.visible)

    _poll_android_back_bridge()
    # On touch, menus have their own controls: the bumpers only page the wheels.
    var touch_menus: bool = is_instance_valid(touch_ui) and touch_ui.enabled
    touch_controls.set_shoulders_visible(field_move_wheel_open or (not touch_menus and (not started or _field_ui_blocks_gameplay())))
    if is_instance_valid(edge_sky):
        var flying_overworld: bool = world.active_field_move in ["FLY", "SURF"] and world.active_area_id == "OVERWORLD"
        if edge_sky.visible and not flying_overworld:
            world._configure_camera()
        edge_sky.visible = flying_overworld
    move_wheel.update_field_move_wheel_input()
    minimap.update_dig_hud_and_minimap(delta)
    party_menu.update_party_sprite_animation(delta)
    _update_battle_sprite_animation(delta)
    _stop_fainted_active_field_move()
    bag_menu.update_sleeping_bag_rest(delta)

    if build_menu_open:
        if String(world.get("active_field_move")) != "BUILD":
            build_menu_open = false
            build_panel.visible = false
        elif not CraftingData.build_recipes().is_empty():
            var world_build_index := int(world.call("get_build_selection_index"))
            if world_build_index != build_menu_index:
                build_menu_index = world_build_index
                crafting_menu.apply_build_hud_selection()

    if generating:
        generation_tip_timer -= delta
        if generation_tip_timer <= 0.0:
            dialogs.show_generation_tip()

    if resource_popup_timer > 0.0:
        resource_popup_timer -= delta
        if resource_popup_timer <= 0.0:
            resource_popup.visible = false

    if game_menu_open and game_menu_detail_open and game_menu_map_screen.visible and not teleport_map_mode:
        world.set_gameplay_enabled(false)
        if is_instance_valid(waypoint_ui):waypoint_ui.move_cursor(delta)

    dialogs.update_message_box(delta)

    if menu_nav_cooldown > 0.0:
        menu_nav_cooldown = max(0.0, menu_nav_cooldown - delta)

    if battle_text_busy:
        battle_text_accumulator += delta * GameOptions.text_multiplier()
        var characters_to_add := int(battle_text_accumulator / BATTLE_TEXT_CHAR_DELAY)
        if characters_to_add > 0:
            battle_text_accumulator -= float(characters_to_add) * BATTLE_TEXT_CHAR_DELAY
            battle_status.visible_characters = mini(
                battle_text_full.length(), battle_status.visible_characters + characters_to_add)
            if battle_status.visible_characters >= battle_text_full.length():
                _finish_battle_text()

## dialogs.gd under its old names, for the scripts and tests that call them on main.
func _show_message(message: String) -> void: dialogs.show_message(message)
func _show_trainer_tip_message(message: String) -> void: dialogs.show_trainer_tip_message(message)

## field_move_wheel.gd under its old names, for the scripts and tests that call them on main.
func _field_move_wheel_stick() -> Vector2: return move_wheel.field_move_wheel_stick()
func _open_field_move_wheel() -> void: move_wheel.open_field_move_wheel()
func _close_field_move_wheel(activate_selection: bool) -> void: move_wheel.close_field_move_wheel(activate_selection)
func _field_move_wheel_icon(species: String, shiny: bool = false, form: String = "") -> Texture2D: return move_wheel.field_move_wheel_icon(species, shiny, form)

func _field_ui_blocks_gameplay(ignore_build_hud: bool = false) -> bool:
    if is_instance_valid(coop_game) and coop_game.active and (coop_game.raids.active or coop_game.events.active or not coop_game.population_battles.claim.is_empty()):return true
    if is_instance_valid(coop_game) and coop_game.active and (coop_game.wild.encounter_pending or not coop_game.wild.encounter.is_empty()):return true
    if is_instance_valid(coop_game) and coop_game.active and not coop_game.session.trusted and started:return true
    return screens.blocks_gameplay(&"build_menu" if ignore_build_hud else &"")

## The screens other scripts draw: open while their node is shown.
func _watch_screens() -> void:
    screens.watch(&"coop_interaction", func(): return is_instance_valid(coop_game) and is_instance_valid(coop_game.interaction_ui) and coop_game.interaction_ui.visible)
    screens.watch(&"coop_chat", func(): return is_instance_valid(coop_game) and is_instance_valid(coop_game.chat) and coop_game.chat.visible)
    screens.watch(&"pokedex", func(): return is_instance_valid(pokedex_menu) and pokedex_menu.visible)
    screens.watch(&"touch_config", func(): return touch_config.visible)
    screens.watch(&"touch_layout_edit", func(): return touch_controls.edit_mode)
    screens.watch(&"game_files", func(): return is_instance_valid(game_files_menu) and game_files_menu.visible)
    screens.watch(&"mods", func(): return is_instance_valid(mod_menu_panel) and mod_menu_panel.visible)
    # OPTIONS can be open without the game menu (back from MOVE BUTTONS):
    # the field's ball icons and HUD stay away from it too.
    screens.watch(&"options", func(): return is_instance_valid(options_menu) and options_menu.visible)

func _stop_fainted_active_field_move() -> void:
    if not started or battle_active:
        return
    var active_move := String(world.get("active_field_move"))
    if active_move.is_empty():
        return
    var active_pokemon := world.get("active_field_pokemon") as Dictionary
    var active_id := int(active_pokemon.get("ecology_id", -1))
    var active_species := String(active_pokemon.get("species", "")).to_lower()
    for raw_entry in caught_pokemon:
        if typeof(raw_entry) != TYPE_DICTIONARY:
            continue
        var entry := raw_entry as Dictionary
        var same_pokemon := (
            active_id >= 0 and int(entry.get("ecology_id", -2)) == active_id
        ) or (
            active_id < 0 and String(entry.get("species", "")).to_lower() ==
                active_species
        )
        if same_pokemon and int(entry.get("hp", 0)) > 0:
            return
    world.call("clear_active_field_move", true)

func _start_battle_text(message: String) -> void:
    battle_text_full = message
    battle_status.text = message
    battle_status.visible_characters = 0
    battle_text_accumulator = 0.0
    battle_text_busy = not message.is_empty()
    if message.is_empty():
        battle_status.visible_characters = -1
    else:
        battle_text_shown.emit(message)

func _type_battle_text(message: String) -> void:
    if overworld_evolution_running:
        progression_overlay.show()
        progression_level_dialogue.show()
        _set_evolution_message(message)
    _start_battle_text(message)
    if battle_text_busy:
        await battle_text_finished

func _finish_battle_text() -> void:
    if not battle_text_busy:
        return
    battle_status.text = battle_text_full
    battle_status.visible_characters = -1
    battle_text_busy = false
    battle_text_accumulator = 0.0
    battle_text_finished.emit()

func _create_evolution_greyscale_material() -> void:
    var shader := Shader.new()
    # This is the nonlinear 5-bit greyscale shader used by EvolutionAnim in
    # the source JAR, translated directly to Godot's canvas shader syntax.
    shader.code = (
        "shader_type canvas_item;\n" +
        "void fragment() {\n" +
        "  vec4 c = texture(TEXTURE, UV) * COLOR;\n" +
        "  float r = floor(c.r * 31.0);\n" +
        "  float g = floor(c.g * 31.0);\n" +
        "  float b = floor(c.b * 31.0);\n" +
        "  float sum = r + g + b;\n" +
        "  float grey = floor(sum * sum * sum / 25947.0) / 31.0;\n" +
        "  COLOR = vec4(vec3(grey), c.a);\n" +
        "}\n"
    )
    evolution_greyscale_material = ShaderMaterial.new()
    evolution_greyscale_material.shader = shader

func _handle_progression_input(event: InputEvent) -> void:
    if progression_mode == "HATCH_ANIMATION":
        if event.is_action_pressed("confirm") and not event.is_echo():
            hatch_skip_requested = true
        get_viewport().set_input_as_handled()
        return
    if progression_mode == "EVOLUTION":
        if not overworld_evolution_running and event.is_action_pressed("cancel"):
            evolution_cancel_requested = true
            get_viewport().set_input_as_handled()
        return
    if progression_mode in ["STATS", "HATCH_DONE"]:
        if progression_waiting_input and (event.is_action_pressed("confirm") or
                event.is_action_pressed("start")):
            progression_waiting_input = false
            progression_confirmed.emit()
            get_viewport().set_input_as_handled()
        return
    if progression_mode == "MOVE_SELECT":
        var moves: Array = progression_pokemon.get("moves", [])
        if moves.is_empty():
            return
        if event.is_action_pressed("move_up") or event.is_action_pressed("move_left"):
            progression_choice_index = wrapi(
                progression_choice_index - 1, 0, moves.size())
            _refresh_progression_move_menu()
        elif event.is_action_pressed("move_down") or event.is_action_pressed("move_right"):
            progression_choice_index = wrapi(
                progression_choice_index + 1, 0, moves.size())
            _refresh_progression_move_menu()
        elif event.is_action_pressed("confirm"):
            progression_mode = ""
            progression_choice_made.emit(progression_choice_index)
        elif event.is_action_pressed("cancel"):
            _show_progression_yes_no(
                "Give up on learning %s?" % progression_pending_move.replace("_", " "),
                "MOVE_GIVEUP")
        else:
            return
        get_viewport().set_input_as_handled()
        return
    if progression_mode in ["MOVE_GIVEUP", "YES_NO"]:
        if event.is_action_pressed("move_up") or event.is_action_pressed("move_down") or \
                event.is_action_pressed("move_left") or event.is_action_pressed("move_right"):
            progression_choice_index = 1 - progression_choice_index
            _refresh_progression_yes_no()
        elif event.is_action_pressed("confirm"):
            if progression_mode == "MOVE_GIVEUP":
                if progression_choice_index == 0:
                    progression_mode = ""
                    progression_choice_made.emit(-1)
                else:
                    _show_progression_move_menu(
                        progression_pokemon, progression_pending_move)
            else:
                progression_mode = ""
                progression_choice_made.emit(
                    1 if progression_choice_index == 0 else 0)
        elif event.is_action_pressed("cancel"):
            if progression_mode == "MOVE_GIVEUP":
                _show_progression_move_menu(
                    progression_pokemon, progression_pending_move)
            else:
                progression_mode = ""
                progression_choice_made.emit(0)
        else:
            return
        get_viewport().set_input_as_handled()

func _reset_progression_overlay() -> void:
    progression_level_message.add_theme_font_size_override("font_size", 10)
    progression_level_message.position = Vector2(12,10)
    progression_level_message.size = Vector2(282,32)
    for panel in [progression_move_frame, progression_type_frame, progression_choice_frame]:
        if panel != null:
            panel.hide()
    progression_background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    progression_background.position = Vector2.ZERO
    progression_animation.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    progression_animation.position = Vector2.ZERO
    progression_background.texture = null
    progression_animation.texture = null
    progression_sprite_top.texture = null
    progression_sprite_bottom.texture = null
    progression_sprite_top.material = null
    progression_sprite_bottom.material = null
    progression_sprite_top.visible = false
    progression_sprite_bottom.visible = false
    progression_title.visible = false
    progression_list.visible = false
    progression_values.visible = false
    progression_cursor.visible = false
    progression_detail.visible = false
    progression_hint.visible = false
    progression_level_dialogue.visible = false
    if progression_stats_frame != null:
        progression_stats_frame.visible = false

func _hide_progression_overlay() -> void:
    progression_mode = ""
    progression_waiting_input = false
    progression_overlay.visible = capture_experience_presenting
    _reset_progression_overlay()

func _source_texture_region(texture: Texture2D, region: Rect2) -> Texture2D:
    if texture == null:
        return null
    var atlas := AtlasTexture.new()
    atlas.atlas = texture
    atlas.region = region
    return atlas

## Per-frame data of an animation (decoded at load): 8 uint16 per frame, see tools/battle_atlas.py.
func _battle_frame_table(source_key: String) -> PackedByteArray:
    var animation: Dictionary = battle_animation_manifest.get("animations", {}).get(source_key, {})
    return animation.get("frame_table", PackedByteArray())

## One frame of a battle animation. A frame stores only the crop of its
## non-transparent pixels (tools/battle_atlas.py); the AtlasTexture margin puts
## the crop back at its offset, so it draws like the full frame. Null when the
## frame is empty. `clip` limits the frame to a part of it.
func _source_animation_frame_texture(source_key: String,
        frame_index: int, clip: Rect2 = Rect2()) -> Texture2D:
    var animation: Dictionary = battle_animation_manifest.get("animations", {}).get(source_key, {})
    if animation.is_empty():
        return null
    var table := _battle_frame_table(source_key)
    var at := frame_index * 16
    if at < 0 or at + 16 > table.size():
        return null
    var shown := Rect2(table.decode_u16(at + 10), table.decode_u16(at + 12),
        table.decode_u16(at + 6), table.decode_u16(at + 8))
    var view := clip if clip.has_area() else Rect2(0.0, 0.0,
        float(animation.get("frame_width", 160)), float(animation.get("frame_height", 144)))
    var part := shown.intersection(view)
    if not part.has_area():
        return null
    var page_path := String((animation.get("pages", []) as Array)[table.decode_u16(at)])
    var sheet := battle_animation_cache.get(page_path) as Texture2D
    if sheet == null and ResourceLoader.exists(page_path):
        sheet = load(page_path) as Texture2D
        if sheet != null:
            _cache_battle_sheet(page_path, sheet)
    if sheet == null:
        return null
    var atlas := AtlasTexture.new()
    atlas.atlas = sheet
    atlas.region = Rect2(Vector2(table.decode_u16(at + 2), table.decode_u16(at + 4))
        + part.position - shown.position, part.size)
    atlas.margin = Rect2(part.position - view.position, view.size - part.size)
    return atlas

func _source_animation_directive(source_key: String,
        frame_index: int) -> Dictionary:
    return _battle_directive(source_key, frame_index + 1)

## Frames store an index into the manifest's shared directive table.
func _battle_directive(source_key: String, frame_number: int) -> Dictionary:
    var table := _battle_frame_table(source_key)
    var at := (frame_number - 1) * 16 + 14
    if frame_number < 1 or at + 2 > table.size(): return {}
    var index := table.decode_u16(at)
    if index == 0xFFFF: return {}
    var directive = battle_directive_cache.get(index)
    if directive == null:
        directive = JSON.parse_string(battle_animation_manifest.get("directive_table", [])[index])
        battle_directive_cache[index] = directive
    return directive

func _show_level_up_stats(pokemon: Dictionary) -> void:
    _reset_progression_overlay()
    progression_overlay.visible = true
    progression_background.texture = null
    var species := String(pokemon.get("species", "machop"))
    var stats_texture := PokemonData.record_texture(pokemon, "back")
    if stats_texture == null:
        stats_texture = PokemonData.record_texture(pokemon, "front")
    progression_sprite_top.texture = _battle_sprite_frame(stats_texture)
    # Stands on the text box (top edge at 123), as it does during the battle.
    progression_sprite_top.position = Vector2(14, 29)
    progression_sprite_top.size = Vector2(116, 94)
    progression_sprite_top.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
    progression_sprite_top.visible = progression_sprite_top.texture != null
    var stats: Dictionary = pokemon.get("stats", {})
    for index in range(5):
        progression_stats_fields[index].text = str(int(stats.get(
            ["attack", "defense", "sp_attack", "sp_defense", "speed"][index], 0)))
    progression_stats_frame.visible = true
    progression_level_message.text = "%s grew to LV.%d!" % [
        PokemonState.display_name(pokemon).to_upper(),
        int(pokemon.get("level", 1))
    ]
    progression_level_dialogue.visible = true
    progression_mode = "STATS"
    progression_waiting_input = false
    await get_tree().create_timer(
        SOURCE_LEVEL_STATS_MIN_FRAMES * SOURCE_FRAME_TIME).timeout
    progression_waiting_input = true
    progression_hint.text = ""
    progression_hint.visible = false
    await progression_confirmed
    _hide_progression_overlay()

func _progression_panel(label: String, rect: Rect2) -> Panel:
    var panel := Panel.new()
    panel.name = label
    panel.position = rect.position
    panel.size = rect.size
    panel.z_index = 2
    panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
    panel.add_theme_stylebox_override("panel", _classic_dialogue_style())
    progression_overlay.add_child(panel)
    panel.hide()
    return panel

func _create_progression_menu_frames() -> void:
    progression_type_frame = _progression_panel("MoveTypeBorder", Rect2(142, 2, 176, 117))
    progression_move_frame = _progression_panel("MoveListBorder", Rect2(2, 2, 138, 117))
    progression_choice_frame = _progression_panel("MoveChoiceBorder", Rect2(234, 51, 84, 70))
    progression_type_label = _source_ui_label(progression_type_frame, "Type", Vector2(10, 10), Vector2(156, 95), 8)
    progression_type_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    progression_pp_label = _source_ui_label(progression_type_frame, "PP", Vector2(12, 67), Vector2(94, 34), 10)
    for index in range(4):
        var row := _source_ui_label(progression_move_frame, "Move%d" % index,
            Vector2(24, 10 + index * 25), Vector2(104, 20), 10)
        row.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
        progression_move_rows.append(row)
    progression_menu_cursor = _source_ui_label(progression_move_frame, "Tick", Vector2(8, 10), Vector2(14, 20), 10, "▶", true)
    progression_menu_cursor.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
    progression_yes_no_cursor = _source_ui_label(progression_choice_frame, "Tick", Vector2(11, 8), Vector2(14, 20), 10, "▶", true)
    progression_yes_no_cursor.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
    for index in range(2):
        var row := _source_ui_label(progression_choice_frame, "Choice%d" % index,
            Vector2(28, 10 + index * 28), Vector2(46, 22), 10, "YES" if index == 0 else "NO")
        row.vertical_alignment = VERTICAL_ALIGNMENT_CENTER

func _show_progression_move_menu(pokemon: Dictionary, move_name: String) -> void:
    _reset_progression_overlay()
    progression_overlay.show()
    progression_pokemon = pokemon
    progression_pending_move = move_name.to_upper().replace(" ", "_")
    var moves: Array = pokemon.get("moves", [])
    progression_choice_index = clampi(progression_move_index, 0, maxi(0, moves.size() - 1))
    progression_level_message.text = "Which move should be forgotten?"
    progression_level_dialogue.show()
    progression_move_frame.show()
    progression_type_frame.show()
    progression_mode = "MOVE_SELECT"
    _refresh_progression_move_menu()

func _refresh_progression_move_menu() -> void:
    progression_move_index = progression_choice_index
    var moves: Array = progression_pokemon.get("moves", [])
    for index in range(4):
        var row := progression_move_rows[index]
        row.text = String(moves[index]).replace("_", " ") if index < moves.size() else "-"
        var font_size := 10
        while font_size > 6 and row.get_theme_font("font").get_string_size(row.text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x > row.size.x:
            font_size -= 1
        row.add_theme_font_size_override("font_size", font_size)
    _align_menu_tick(progression_menu_cursor, progression_move_rows[progression_choice_index])
    if moves.is_empty():
        progression_type_label.text = "TYPE/\n---"
        progression_pp_label.text = "PP\n0/0"
        return
    var selected := String(moves[progression_choice_index])
    var move_data := PokemonData.move_info(selected)
    var maximum_pp := int(move_data.get("pp", 0))
    var current_pp := int((progression_pokemon.get("pp", {}) as Dictionary).get(selected, maximum_pp))
    var details = preload("res://scripts/move_details.gd")
    progression_pp_label.hide()
    progression_type_label.text = "%s\nPP %d / %d\n\n%s" % [details.stats_text(selected).replace("  PP %d" % maximum_pp,""),current_pp,maximum_pp,details.effect_text(selected)]
    progression_level_message.add_theme_font_size_override("font_size", 7)
    progression_level_message.position = Vector2(12,7)
    progression_level_message.size = Vector2(288,44)
    progression_level_message.text = "NEW: %s  (%s)\n%s\n%s" % [progression_pending_move.replace("_"," "), PokemonState.display_name(progression_pokemon).to_upper(), details.stats_text(progression_pending_move).replace("\n","  "), details.effect_text(progression_pending_move)]

func _show_progression_yes_no(prompt: String, mode: String = "YES_NO") -> void:
    _reset_progression_overlay()
    progression_overlay.show()
    progression_level_message.text = prompt
    progression_level_dialogue.show()
    progression_choice_frame.show()
    progression_choice_index = 0
    progression_mode = mode
    _refresh_progression_yes_no()

func _refresh_progression_yes_no() -> void:
    _align_menu_tick(progression_yes_no_cursor, progression_choice_frame.get_node("Choice%d" % progression_choice_index))

func _ask_progression_yes_no(prompt: String) -> bool:
    _show_progression_yes_no(prompt)
    var result = await progression_choice_made
    return int(result) == 1

func _choose_move_to_forget(pokemon: Dictionary,
        move_name: String) -> int:
    progression_move_index = 0
    while true:
        _show_progression_move_menu(pokemon, move_name)
        var choice = await progression_choice_made
        var selected_index := int(choice)
        if selected_index < 0:
            _hide_progression_overlay()
            return -1
        var moves: Array = pokemon.get("moves", [])
        if selected_index >= moves.size():
            continue
        var forgotten := String(moves[selected_index]).replace("_", " ")
        if await _ask_progression_yes_no("Replace %s?" % forgotten):
            _hide_progression_overlay()
            return selected_index
    return -1

## A battle's experience screens are main.gd's own: the choices made on them
## (a move to forget, an evolution let through or stopped) go in the battle's
## history so a replay of it makes the same ones.
func _note_battle_choice(choice: Variant) -> void:
    if battle_active and battle_session != null and battle_session.running:
        battle_session.history.append(choice)

func _learn_level_moves(pokemon: Dictionary, moves_to_learn: Array) -> void:
    var display_name := PokemonState.display_name(pokemon).to_upper()
    for raw_move in moves_to_learn:
        var move_name := String(raw_move).to_upper().replace(" ", "_")
        if (pokemon.get("moves", []) as Array).has(move_name):
            continue
        if (pokemon.get("moves", []) as Array).size() < 4:
            if BattleEngine.learn_move(pokemon, move_name):
                _play_source_battle_sound("fanfare1.ogg")
                await _type_battle_text("%s learned %s!" % [
                    display_name, move_name.replace("_", " ")])
            continue
        await _type_battle_text("%s is trying to learn %s." % [
            display_name, move_name.replace("_", " ")])
        await _type_battle_text("Which move should be forgotten?")
        var replace_index := await _choose_move_to_forget(pokemon, move_name)
        _note_battle_choice(replace_index)
        if replace_index < 0:
            await _type_battle_text("%s did not learn %s." % [
                display_name, move_name.replace("_", " ")])
            continue
        var old_move := String((pokemon.get("moves", []) as Array)[replace_index])
        await _type_battle_text("And one... two... three... POOF!")
        await _type_battle_text("%s forgot %s and..." % [
            display_name, old_move.replace("_", " ")])
        if BattleEngine.learn_move(pokemon, move_name, replace_index):
            _play_source_battle_sound("fanfare1.ogg")
            await _type_battle_text("%s learned %s!" % [
                display_name, move_name.replace("_", " ")])

func _experience_bar_index(species: String, level: int,
        experience: int) -> int:
    if level >= 100:
        return SOURCE_EXP_UNITS
    var floor_exp := BattleEngine.exp_for_level(species, level)
    var ceiling_exp := BattleEngine.exp_for_level(species, level + 1)
    return clampi(int(floor(float(SOURCE_EXP_UNITS) *
        float(experience - floor_exp) /
        maxf(1.0, float(ceiling_exp - floor_exp)))), 0, SOURCE_EXP_UNITS)

func _animate_experience_segment(pokemon: Dictionary, from_exp: int,
        to_exp: int) -> void:
    var species := String(pokemon.get("species", "machop"))
    var level := int(pokemon.get("level", 1))
    var start_index := _experience_bar_index(species, level, from_exp)
    var target_index := _experience_bar_index(species, level, to_exp)
    var segment_start := preload("res://scripts/game_clock.gd").ticks_usec()
    for bar_index in range(start_index + 1, target_index + 1):
        _set_player_exp_bar_ratio(
            float(bar_index) / float(SOURCE_EXP_UNITS))
        var deadline := segment_start + int((bar_index - start_index) * SOURCE_FRAME_TIME * 1000000.0)
        while preload("res://scripts/game_clock.gd").ticks_usec() < deadline:
            await get_tree().process_frame

func _set_player_exp_bar_ratio(ratio: float) -> void:
    var clamped := clampf(ratio, 0.0, 1.0)
    var legacy_width := roundf(96.0 * clamped)
    var source_width := roundf(66.0 * clamped)
    # Both bars share a fixed right edge like the source GSC HUD.
    player_exp_fill.position.x = 145.0 - legacy_width
    player_exp_fill.size.x = legacy_width
    source_player_exp_fill.position.x = 184.0 - source_width
    source_player_exp_fill.size.x = source_width
    player_exp_fill.color = Color8(47, 152, 233)
    source_player_exp_fill.color = Color8(32, 136, 248)

func _world_source_time_of_day() -> String:
    if world.has_method("source_time_of_day"):
        return String(world.call("source_time_of_day"))
    return "day"

func _run_experience_progression(pokemon: Dictionary, amount: int,
        party_index: int, defer_evolution: bool = false) -> void:
    progression_active = true
    progression_mode = ""
    _hide_progression_overlay()
    var original_hud_pokemon := battle_player
    var showing_other_pokemon := not is_same(pokemon, battle_player)
    if showing_other_pokemon:
        battle_player = pokemon
        _update_battle_hud()

    var current_exp := int(pokemon.get("exp", BattleEngine.exp_for_level(
        String(pokemon.get("species", "machop")), int(pokemon.get("level", 1)))))
    var target_exp := current_exp + maxi(0, amount)
    var gained_level := false
    if int(pokemon.get("level", 1)) < 100 and target_exp > current_exp:
        _play_source_battle_sound("xp-gain1.ogg")
        await get_tree().create_timer(9.0 * SOURCE_FRAME_TIME).timeout

    while int(pokemon.get("level", 1)) < 100:
        var next_level_exp := BattleEngine.exp_for_level(
            String(pokemon.get("species", "machop")),
            int(pokemon.get("level", 1)) + 1)
        if target_exp < next_level_exp:
            break
        await _animate_experience_segment(pokemon, current_exp, next_level_exp)
        pokemon["exp"] = next_level_exp
        battle_audio.stop()
        _play_level_up_sound()
        _set_player_exp_bar_ratio(1.0)
        # The source holds a completely filled bar before it rolls into the
        # next level rather than clearing it on the same frame.
        await get_tree().create_timer(9.0 * SOURCE_FRAME_TIME).timeout
        var level_result := BattleEngine.gain_level(pokemon)
        gained_level = true
        current_exp = next_level_exp
        if party_index >= 0 and party_index < caught_pokemon.size():
            caught_pokemon[party_index] = pokemon
        _update_battle_hud()
        _play_source_battle_sound("fanfare1.ogg")
        await _type_battle_text("%s grew to level %d!" % [
            PokemonState.display_name(pokemon).to_upper(), int(pokemon.level)])
        await _learn_level_moves(pokemon, level_result.get("moves", []))
        if int(pokemon.get("level", 1)) < 100 and target_exp >= \
                BattleEngine.exp_for_level(String(pokemon.species),
                    int(pokemon.level) + 1):
            _play_source_battle_sound("xp-gain1.ogg")

    if int(pokemon.get("level", 1)) < 100 and target_exp > current_exp:
        await _animate_experience_segment(pokemon, current_exp, target_exp)
    pokemon["exp"] = target_exp
    battle_audio.stop()
    if party_index >= 0 and party_index < caught_pokemon.size():
        caught_pokemon[party_index] = pokemon
    _update_battle_hud()

    if gained_level:
        await _show_level_up_stats(pokemon)
        if not defer_evolution:
            await _check_reward_evolution(pokemon, party_index)

    if showing_other_pokemon:
        battle_player = original_hud_pokemon
        _update_battle_hud()
    _hide_progression_overlay()
    progression_pokemon = {}
    progression_pending_move = ""
    progression_active = false

func _set_progression_sprite_half(node: TextureRect, texture: Texture2D,
        top_half: bool, greyscale: bool,
        source_baseline_y: float = 72.0, bottom_height: int = -1,
        horizontal_scale: float = 2.0, horizontal_offset: float = 0.0) -> void:
    if texture == null:
        node.texture = null
        node.visible = false
        return
    var width := texture.get_width()
    var height := texture.get_height()
    var split := height - bottom_height if bottom_height >= 0 else int(height / 2.0)
    var region_y := 0 if top_half else split
    var region_height := split if top_half else height - split
    node.texture = _source_texture_region(texture,
        Rect2(0, region_y, width, region_height))
    var source_left := 84.0 - float(width) / 2.0
    var source_top := 144.0 - source_baseline_y - float(height)
    node.position = Vector2(
        horizontal_offset + source_left * horizontal_scale,
        (source_top + float(region_y)) * 1.25)
    node.size = Vector2(float(width) * horizontal_scale, float(region_height) * 1.25)
    node.material = evolution_greyscale_material if greyscale else null
    node.visible = true

func _set_evolution_sprite_halves(old_texture: Texture2D,
        new_texture: Texture2D, directive: Dictionary,
        sprites_visible: bool) -> void:
    if not sprites_visible:
        progression_sprite_top.visible = false
        progression_sprite_bottom.visible = false
        return
    var greyscale := bool(directive.get("sprite_greyscale", false))
    var top_texture := new_texture if bool(directive.get(
        "evo_top_sprite_changed", false)) else old_texture
    var bottom_texture := new_texture if bool(directive.get(
        "evo_bottom_sprite_changed", false)) else old_texture
    _set_progression_sprite_half(
        progression_sprite_top, top_texture, true, greyscale, 72.0,
        int(old_texture.get_height() / 2.0), 1.25, 60.0)
    _set_progression_sprite_half(
        progression_sprite_bottom, bottom_texture, false, greyscale, 72.0,
        int(old_texture.get_height() / 2.0), 1.25, 60.0)

func _set_progression_full_sprite(texture: Texture2D,
        source_baseline_y: float) -> void:
    if texture == null:
        progression_sprite_top.visible = false
        progression_sprite_bottom.visible = false
        return
    progression_sprite_bottom.visible = false
    progression_sprite_top.texture = texture
    progression_sprite_top.material = null
    progression_sprite_top.position = Vector2(
        (84.0 - float(texture.get_width()) / 2.0) * 2.0,
        (144.0 - source_baseline_y - float(texture.get_height())) * 1.25)
    progression_sprite_top.size = Vector2(
        float(texture.get_width()) * 2.0,
        float(texture.get_height()) * 1.25)
    progression_sprite_top.visible = true

func _set_hatch_progression_canvas() -> void:
    # The source hatch canvas is 160x144. Fit it to the 320x180 viewport with
    # one uniform scale (1.25x) so the egg/Pokemon are never horizontally
    # stretched; the remaining 60 px on each side are intentional pillarbox.
    for node in [progression_background, progression_animation]:
        node.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
        node.position = Vector2(60.0, 0.0)
        node.size = Vector2(200.0, 180.0)

func _set_hatch_sprite_half(node: TextureRect, texture: Texture2D,
        top_half: bool, source_baseline_y: float = 64.0) -> void:
    if texture == null:
        node.texture = null
        node.visible = false
        return
    var width := texture.get_width()
    var height := texture.get_height()
    var split := int(height / 2.0)
    var region_y := 0 if top_half else split
    var region_height := split if top_half else height - split
    node.texture = _source_texture_region(texture,
        Rect2(0, region_y, width, region_height))
    var scale := 1.25
    var source_left := 84.0 - float(width) / 2.0
    var source_top := 144.0 - source_baseline_y - float(height)
    node.position = Vector2(
        60.0 + source_left * scale,
        (source_top + float(region_y)) * scale)
    node.size = Vector2(float(width) * scale, float(region_height) * scale)
    node.material = null
    node.visible = true

func _set_hatch_full_sprite(texture: Texture2D,
        source_baseline_y: float = 64.0) -> void:
    if texture == null:
        progression_sprite_top.visible = false
        progression_sprite_bottom.visible = false
        return
    var scale := 1.25
    progression_sprite_bottom.visible = false
    progression_sprite_top.texture = texture
    progression_sprite_top.material = null
    progression_sprite_top.position = Vector2(
        60.0 + (84.0 - float(texture.get_width()) / 2.0) * scale,
        (144.0 - source_baseline_y - float(texture.get_height())) * scale)
    progression_sprite_top.size = Vector2(
        float(texture.get_width()) * scale,
        float(texture.get_height()) * scale)
    progression_sprite_top.visible = true

func _set_hatch_sprite_halves(texture: Texture2D,
        show_bottom: bool, show_top: bool) -> void:
    if show_top:
        _set_hatch_sprite_half(
            progression_sprite_top, texture, true, 64.0)
    else:
        progression_sprite_top.visible = false
    if show_bottom:
        _set_hatch_sprite_half(
            progression_sprite_bottom, texture, false, 64.0)
    else:
        progression_sprite_bottom.visible = false

func _play_battle_animation_sound(source_key: String) -> void:
    var audio_entries: Dictionary = battle_animation_manifest.get("audio", {})
    var audio_path := String(audio_entries.get(source_key, ""))
    if not audio_path.is_empty() and ResourceLoader.exists(audio_path):
        battle_audio.stream = load(audio_path) as AudioStream
        AudioBalance.apply(battle_audio)
        battle_audio.play()

func _play_progression_cry(pokemon: Dictionary) -> void:
    var cry_path := PokemonData.cry_path(String(pokemon.get("species", "")))
    if cry_path.is_empty() or not ResourceLoader.exists(cry_path):
        return
    var cry_player := AudioStreamPlayer.new()
    cry_player.stream = load(cry_path) as AudioStream
    cry_player.finished.connect(func() -> void: cry_player.queue_free())
    add_child(cry_player)
    AudioBalance.apply(cry_player)
    cry_player.play()

func _run_egg_hatch_sequence(party_index: int, hatched: Dictionary) -> void:
    progression_active = true
    progression_mode = ""
    field_item_busy = true
    world.set_gameplay_enabled(false)
    caught_pokemon[party_index] = hatched
    pokedex_progress.mark(hatched, true)
    var species := String(hatched.get("species", "pidgey")).to_lower()
    if not caught_species.has(species):
        caught_species.append(species)

    # PlayerStanding waits 61 + 3 source frames before its random hatch cue.
    await get_tree().create_timer(61.0 * SOURCE_FRAME_TIME).timeout
    await get_tree().create_timer(3.0 * SOURCE_FRAME_TIME).timeout
    message_timer = 0.0
    message_label.text = ["Huh?", "Oh?"][battle_rng.randi_range(0, 1)]
    message_panel.visible = true
    await get_tree().create_timer(51.0 * SOURCE_FRAME_TIME).timeout
    message_panel.visible = false

    _reset_progression_overlay()
    progression_overlay.visible = true
    _set_hatch_progression_canvas()
    progression_background.texture = _source_texture_region(
        SOURCE_HATCH_BACKGROUND, Rect2(0, 0, 160, 144))
    progression_mode = "HATCH_ANIMATION"
    var skip_hint := _source_ui_label(progression_overlay, "HatchSkipHint", Vector2(190, 167), Vector2(124, 11), 7, "Press A to skip")
    skip_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
    skip_hint.z_index = 10
    hatch_skip_requested = false
    var previous_pitch := battle_audio.pitch_scale
    battle_audio.pitch_scale = HATCH_PLAYBACK_SPEED
    _play_battle_animation_sound("egg_hatch_gsc")
    var front_sheet := PokemonData.record_texture(hatched, "front")
    var front_frame := _battle_sprite_frame(front_sheet)
    var show_bottom := false
    var show_top := false
    # One elapsed-time clock advances both visuals and pitched source audio.
    # Per-frame timers accumulated extra display frames on slower devices.
    var hatch_start := preload("res://scripts/game_clock.gd").ticks_usec()
    var last_frame := -1
    while not hatch_skip_requested:
        var frame_index := int(float(preload("res://scripts/game_clock.gd").ticks_usec() - hatch_start) / 1000000.0 * HATCH_PLAYBACK_SPEED / SOURCE_FRAME_TIME)
        if frame_index >= SOURCE_HATCH_COMPLETE_FRAME:
            break
        progression_animation.texture = _source_animation_frame_texture(
            "egg_hatch_gsc", frame_index)
        for directive_frame in range(last_frame + 1, frame_index + 1):
            var directive := _source_animation_directive("egg_hatch_gsc", directive_frame)
            show_bottom = show_bottom or bool(directive.get("draw_hatch_bottom_sprite", false))
            show_top = show_top or bool(directive.get("draw_hatch_top_sprite", false))
        last_frame = frame_index
        _set_hatch_sprite_halves(front_frame, show_bottom, show_top)
        await get_tree().process_frame

    battle_audio.stop()
    battle_audio.pitch_scale = previous_pitch
    skip_hint.queue_free()
    progression_mode = "HATCH_REVEAL"
    progression_animation.texture = null
    var intro_frame_count := 1
    if front_sheet != null and front_sheet.get_width() > 0:
        intro_frame_count = maxi(1, roundi(
            float(front_sheet.get_height()) / float(front_sheet.get_width())))
    var cry_started := false
    var reveal_start := preload("res://scripts/game_clock.gd").ticks_usec()
    for intro_index in range(intro_frame_count):
        var sprite_frame := front_frame
        if front_sheet != null and front_sheet.get_height() > front_sheet.get_width():
            var frame_height := mini(front_sheet.get_height(), front_sheet.get_width())
            sprite_frame = _source_texture_region(front_sheet, Rect2(
                0, intro_index * frame_height,
                front_sheet.get_width(), frame_height))
        _set_hatch_full_sprite(sprite_frame, 64.0)
        var deadline := reveal_start + int((intro_index + 1) * SOURCE_FRAME_TIME * 1000000.0)
        while preload("res://scripts/game_clock.gd").ticks_usec() < deadline:
            await get_tree().process_frame
        if intro_index == 3:
            _play_progression_cry(hatched)
            cry_started = true
    if not cry_started:
        _play_progression_cry(hatched)
    await get_tree().create_timer(4.0 * SOURCE_FRAME_TIME).timeout

    _hide_progression_overlay()
    _play_source_battle_sound("fanfare2.ogg")
    message_timer = 0.0
    message_label.text = "%s came out of its EGG!" % \
        PokemonState.display_name(hatched).to_upper()
    message_panel.visible = true
    progression_mode = "HATCH_DONE"
    progression_waiting_input = true
    await progression_confirmed
    await get_tree().create_timer(13.0 * SOURCE_FRAME_TIME).timeout
    battle_audio.stop()
    message_panel.visible = false
    progression_mode = ""
    progression_waiting_input = false
    progression_active = false
    field_item_busy = false
    world.set_gameplay_enabled(true)

func _evolution_sprite_texture(species: String, shiny: bool) -> Texture2D:
    return PokemonData.texture(species, "front", shiny)

func _set_evolution_message(message: String) -> void:
    var font := progression_level_message.get_theme_font("font")
    var result := message
    var chosen_size := 10
    for size in range(10, 4, -1):
        var lines: Array[String] = [""]
        for word in message.split(" "):
            var candidate := word if lines[-1].is_empty() else lines[-1] + " " + word
            if font.get_string_size(candidate, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x > 282 and not lines[-1].is_empty():
                lines.append(word)
            else:
                lines[-1] = candidate
        if lines.size() <= 2:
            result = "\n".join(lines)
            chosen_size = size
            break
    progression_level_message.add_theme_font_size_override("font_size", chosen_size)
    progression_level_message.text = result

func _run_evolution_sequence(pokemon: Dictionary, new_species: String,
        party_index: int) -> bool:
    new_species = BattleEngine.resolved_evolution_species(pokemon, new_species)
    var old_display_name := PokemonState.display_name(pokemon).to_upper()
    var old_texture := _battle_sprite_frame(
        _evolution_sprite_texture(String(pokemon.get("species", "")), PokemonData.is_shiny(pokemon)))
    var new_texture := _battle_sprite_frame(
        _evolution_sprite_texture(new_species, PokemonData.is_shiny(pokemon)))
    await _type_battle_text("What? %s is evolving!" % old_display_name)
    await get_tree().create_timer(51.0 * SOURCE_FRAME_TIME).timeout

    _reset_progression_overlay()
    progression_overlay.visible = true
    # Keep the source animation in its native proportions above the approved
    # dialogue panel; its baked-in vanilla border must not replace our UI.
    progression_background.texture = null
    progression_animation.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
    progression_animation.position = Vector2(60.0, 0.0)
    progression_animation.size = Vector2(200.0, 120.0)
    progression_level_dialogue.visible = true
    _set_evolution_message("What? %s is evolving!" % old_display_name)
    progression_mode = "EVOLUTION"
    evolution_cancel_requested = false
    var evolution_music_states: Array[bool] = world.environment_system.pause_music_for_evolution()
    _play_source_battle_sound("evolution1.ogg")
    var animations: Dictionary = battle_animation_manifest.get("animations", {})
    var animation: Dictionary = animations.get("evolve_gsc", {})
    var frame_count := int(animation.get("frames", 502))
    var fanfare_played := false
    var evolution_started_usec := preload("res://scripts/game_clock.gd").ticks_usec()
    for frame_index in range(frame_count):
        if frame_index >= SOURCE_EVOLUTION_CANCEL_END_FRAME:
            progression_mode = "EVOLUTION_FINISHING"
        progression_animation.texture = _source_animation_frame_texture(
            "evolve_gsc", frame_index, Rect2(0, 0, 160, 96))
        var directive := _source_animation_directive("evolve_gsc", frame_index)
        _set_evolution_sprite_halves(
            old_texture, new_texture, directive, frame_index >= 33)
        if bool(directive.get("play_evo_fanfare", false)) and not fanfare_played:
            fanfare_played = true
            _play_source_battle_sound("evolve_fanfare1.ogg")
        # Absolute deadlines preserve the source's 60 Hz timeline. Creating a
        # fresh one-frame timer per frame accumulated an extra render-frame wait.
        var deadline := evolution_started_usec + int(
            float(frame_index + 1) * SOURCE_FRAME_TIME * 1000000.0)
        while preload("res://scripts/game_clock.gd").ticks_usec() < deadline:
            await get_tree().process_frame
        if evolution_cancel_requested:
            break
    battle_audio.stop()
    world.environment_system.resume_music_after_evolution(evolution_music_states)
    progression_mode = "EVOLUTION_DONE"
    progression_animation.texture = null
    _note_battle_choice(not evolution_cancel_requested)

    if evolution_cancel_requested:
        _set_evolution_sprite_halves(old_texture, old_texture, {}, true)
        await get_tree().create_timer(30.0 * SOURCE_FRAME_TIME).timeout
        _set_evolution_message("Huh? %s stopped evolving!" % old_display_name)
        await _type_battle_text("Huh? %s stopped evolving!" % old_display_name)
        _hide_progression_overlay()
        return false

    if not BattleEngine.apply_evolution(pokemon, new_species):
        _hide_progression_overlay()
        return false
    pokedex_progress.mark(pokemon, true)
    _set_evolution_sprite_halves(new_texture, new_texture, {}, true)
    if party_index >= 0 and party_index < caught_pokemon.size():
        caught_pokemon[party_index] = pokemon
    _refresh_battle_sprites()
    _update_battle_hud()
    _play_pokemon_cry(pokemon)
    await get_tree().create_timer(30.0 * SOURCE_FRAME_TIME).timeout
    _play_source_battle_sound("fanfare2.ogg")
    _set_evolution_message("Congratulations! Your %s evolved into %s!" % [
        old_display_name, new_species.to_upper().replace("_", " ")])
    await _type_battle_text("Congratulations! Your %s evolved into %s!" % [
        old_display_name, new_species.to_upper().replace("_", " ")])
    _hide_progression_overlay()
    await _learn_level_moves(pokemon, BattleEngine.moves_learned_at_level(
        new_species, int(pokemon.get("level", 1))))
    return true

func _notification(what: int) -> void:
    if not startup_complete: return
    if what in [NOTIFICATION_APPLICATION_FOCUS_OUT, NOTIFICATION_WM_WINDOW_FOCUS_OUT]:
        start_menu_ticket += 1
        start_menu_pending = false
        start_menu_held = false
        # Releases can be delivered to the other window while unfocused.
        # Clear virtual controls as well as physical actions; preserve UI locks.
        for action in InputMap.get_actions():
            Input.action_release(action)
        if is_node_ready():
            touch_controls._release_all()
        return
    if what == NOTIFICATION_APPLICATION_PAUSED:
        saving.save_on_pause()
        return
    if what in [NOTIFICATION_APPLICATION_FOCUS_IN, NOTIFICATION_WM_WINDOW_FOCUS_IN]:
        if is_node_ready() and _is_android_touch_runtime():
            touch_controls.refresh_system_theme()
            if touch_config.visible:
                touch_config_panel.apply_touch_config_theme()
        return

    if what != NOTIFICATION_WM_GO_BACK_REQUEST:
        return

    # Android system Back requests quit; controller Select has its own map action.
    if not _is_android_touch_runtime():
        if started and not quit_prompt_open:
            start_menu.open_quit_prompt()
        return
    _handle_android_back_request()

func _handle_android_back_request() -> void:
    if not _is_android_touch_runtime() or progression_active:
        return
    if is_instance_valid(waypoint_ui):
        if waypoint_ui.naming:
            waypoint_ui.cancel_name()
            last_android_back_msec = Time.get_ticks_msec()
            return
        if Time.get_ticks_msec() - waypoint_ui.closed_msec < 350:
            return
    var now := Time.get_ticks_msec()
    # Android can deliver one press as both a key event and a window Back
    # notification. Handle that pair once so the panel cannot open then close.
    if now - last_android_back_msec < 250:
        return
    last_android_back_msec = now
    if is_instance_valid(game_files_menu) and game_files_menu.visible:
        game_files_menu.close()
    elif is_instance_valid(mod_menu_panel) and mod_menu_panel.visible:
        mod_menu_panel.call("_close")
    elif touch_controls.edit_mode:
        touch_controls.end_edit()
        touch_config_panel.open_touch_config()
    elif touch_config.visible:
        touch_config_panel.close_touch_config()
    else:
        if is_instance_valid(pokedex_menu) and pokedex_menu.visible:
            pokedex_menu.close()
        start_menu.open_quit_prompt()

func _poll_android_back_bridge() -> void:
    if not android_back_bridge_checked:
        android_back_bridge_checked = true
        if OS.get_name() == "Android" and Engine.has_singleton("JavaClassWrapper"):
            var wrapper = Engine.get_singleton("JavaClassWrapper")
            android_back_bridge = wrapper.wrap("com.godot.game.PokeWildsBack")
    if android_back_bridge == null: return
    var action: int = int(android_back_bridge.consumeEvent())
    if action == 1:
        _handle_android_back_request()
    elif action == 2:
        _handle_android_controls_gesture()

func _handle_android_controls_gesture() -> void:
    if progression_active or quit_prompt_open: return
    if is_instance_valid(pokedex_menu) and pokedex_menu.visible: pokedex_menu.close()
    if touch_controls.edit_mode:
        touch_controls.end_edit()
        touch_config_panel.open_touch_config()
    elif touch_config.visible:
        touch_config_panel.close_touch_config()
    else:
        touch_config_panel.open_touch_config()

func _input(event: InputEvent) -> void:
    last_input_msec = Time.get_ticks_msec()
    if is_instance_valid(touch_ui) and touch_ui.handle(event):
        get_viewport().set_input_as_handled()
        return
    if startup_complete and _menu_stick_event_is_blocked(event):
        get_viewport().set_input_as_handled()
        return
    if startup_complete and is_instance_valid(coop_game) and coop_game.handle_input(event):
        get_viewport().set_input_as_handled()
        return
    if startup_complete and is_instance_valid(coop_menu) and coop_menu.visible:
        coop_menu.handle(event)
        if not event is InputEventMouse and not event is InputEventScreenTouch and not event is InputEventScreenDrag and not coop_menu.accepts_text_key(event):
            get_viewport().set_input_as_handled()
        return
    if is_instance_valid(ball_mechanics) and is_instance_valid(ball_mechanics.capture_screen) and not capture_experience_presenting:
        get_viewport().set_input_as_handled()
        return
    if not startup_complete: return
    if is_instance_valid(waypoint_ui) and waypoint_ui.naming:
        waypoint_ui.handle_input(event)
        return # Dispatch before focused controls consume controller buttons.
    if game_menu_open and game_menu_detail_open and game_menu_map_screen.visible:
        start_menu.handle_game_menu_input(event)
        get_viewport().set_input_as_handled()
        return
    # Depending on the Android device/launcher, the hardware Back control can
    # arrive as KEY_BACK instead of a window Back notification.
    if event is InputEventKey and event.pressed and not event.echo and \
            _is_android_touch_runtime() and (event.keycode == KEY_BACK or \
                event.physical_keycode == KEY_BACK):
        _handle_android_back_request()
        get_viewport().set_input_as_handled()
        return
    if is_instance_valid(safari_ui) and battle_active and not quit_prompt_open and not touch_config.visible:
        safari_ui.handle(event)
        get_viewport().set_input_as_handled()
        return
    if is_instance_valid(bag_action_ui) and not quit_prompt_open and not touch_config.visible:
        bag_action_ui.handle(event)
        get_viewport().set_input_as_handled()
        return
    if is_instance_valid(pokedex_menu) and pokedex_menu.visible and not quit_prompt_open and not touch_config.visible:
        pokedex_menu.handle(event)
        get_viewport().set_input_as_handled()
        return
    if is_instance_valid(game_files_menu) and game_files_menu.visible:
        game_files_menu.handle(event)
        if not event is InputEventMouse and not event is InputEventScreenTouch and not event is InputEventScreenDrag:
            get_viewport().set_input_as_handled()
        return
    if is_instance_valid(mod_menu_panel) and mod_menu_panel.visible:
        mod_menu_panel.handle(event)
        if not event is InputEventMouse and not event is InputEventScreenTouch and not event is InputEventScreenDrag:
            get_viewport().set_input_as_handled()
        return


    if touch_config.visible:
        setup_screen.handle_swipe_menu(event)
        if not event is InputEventMouse and not event is InputEventScreenTouch and not event is InputEventScreenDrag:
            get_viewport().set_input_as_handled()
        return
    if is_instance_valid(options_menu) and options_menu.visible:
        if is_instance_valid(options_menu.internet_setup) and options_menu.internet_setup.accepts_text_key(event):return
        options_menu.handle(event)
        if is_instance_valid(options_menu.internet_setup) and (event is InputEventMouse or event is InputEventScreenTouch or event is InputEventScreenDrag):return
        get_viewport().set_input_as_handled()
        return
    if field_move_wheel_open:
        if is_instance_valid(ball_mechanics) and ball_mechanics.handle(event):
            get_viewport().set_input_as_handled()
            return
        # L2 release and stick direction are polled in _process so the wheel
        # remains modal without stealing its selection axis from the player.
        if build_wheel_mode and (event.is_action_pressed("shoulder_left") or event.is_action_pressed("shoulder_right")):
            var pages := ceili(float(CraftingData.build_recipes().size()) / BUILD_WHEEL_PAGE_SIZE)
            build_wheel_page = posmod(build_wheel_page + (1 if event.is_action_pressed("shoulder_right") else -1), pages)
            move_wheel.configure_build_wheel()
        elif event.is_action_pressed("cancel"):
            move_wheel.close_field_move_wheel(false)
            field_wheel_wait_for_release = true
            if build_menu_open:
                crafting_menu.close_build_menu()
            elif not world.active_field_move.is_empty():
                world.clear_active_field_move()
        get_viewport().set_input_as_handled()
        return


    if build_menu_open and not field_move_wheel_open and not battle_active and not battle_entry_pending and not quit_prompt_open and event.is_action_pressed("cancel"):
        crafting_menu.close_build_menu()
        get_viewport().set_input_as_handled()
        return
    if started and event.is_action_pressed("cancel") and not world.active_field_move.is_empty() and not _field_ui_blocks_gameplay() and not bag_menu.sleeping_bag_active() and not world.house_transition_active and not is_instance_valid(world.stool_seated_sprite):
        world.clear_active_field_move()
        get_viewport().set_input_as_handled()
        return
    if event is InputEventJoypadButton and event.button_index == JOY_BUTTON_START and not event.pressed:
        start_menu_held = false
    # Start/Select must never activate a focused control behind the quit modal.
    if quit_prompt_open and (event.is_action("start") or event.is_action("quit_menu")):
        get_viewport().set_input_as_handled()
        return
    # Capture printable WORLD NAME keys before Control focus can consume them.
    # Navigation/confirm/cancel still fall through to _unhandled_input.
    if text_entry_target != "" and event is InputEventKey:
        var text_key := event as InputEventKey
        if text_key.pressed and not text_key.echo:
            if text_key.keycode == KEY_BACKSPACE:
                if not text_entry_buffer.is_empty():
                    text_entry_buffer = text_entry_buffer.left(text_entry_buffer.length() - 1)
                    setup_screen.refresh_text_entry_display()
                get_viewport().set_input_as_handled()
                return
            if text_key.unicode >= 32 and text_key.unicode != 127:
                if text_entry_buffer.length() < 24:
                    text_entry_buffer += String.chr(text_key.unicode)
                    setup_screen.refresh_text_entry_display()
                get_viewport().set_input_as_handled()
                return
    if setup_load_open:
        setup_screen.handle_setup_load_input(event)
        return

func _unhandled_input(event: InputEvent) -> void:
    if not startup_complete: return
    if is_instance_valid(coop_menu) and coop_menu.visible:return
    if is_instance_valid(waypoint_ui) and waypoint_ui.naming:
        return
    if is_instance_valid(world.stool_seated_sprite):
        if event.is_action_pressed("cancel"):
            world.end_stool_sitting()
        else:
            for action in ["move_up", "move_down", "move_left", "move_right"]:
                if event.is_action_pressed(action):
                    world.turn_seated_player(action)
                    break
        get_viewport().set_input_as_handled()
        return
    if world.house_transition_active:
        get_viewport().set_input_as_handled()
        return
    if mansion_switch_open:
        _handle_mansion_switch_input(event)
        return
    if wild_pokemon_prompt_open:
        _handle_wild_pokemon_prompt_input(event)
        return
    if egg_pickup_open:
        _handle_egg_pickup_input(event)
        return
    if storage_menu_open:
        storage.handle_storage_menu_input(event)
        return
    if trainer_tip_open:
        if event.is_action_pressed("confirm") or event.is_action_pressed("start"):
            dialogs.advance_trainer_tip()
            get_viewport().set_input_as_handled()
        elif event.is_action_pressed("cancel"):
            dialogs.close_trainer_tip()
            get_viewport().set_input_as_handled()
        return

    if setup_load_open:
        setup_screen.handle_setup_load_input(event)
        return

    if pokemon_stats_open:
        party_menu.handle_pokemon_stats_input(event)
        return

    if event.is_action_pressed("touch_config"):
        if not _is_android_touch_runtime():
            return
        if touch_controls.edit_mode:
            touch_controls.end_edit()
            touch_config_panel.open_touch_config()
        elif touch_config.visible:
            touch_config_panel.close_touch_config()
        else:
            touch_config_panel.open_touch_config()
        get_viewport().set_input_as_handled()
        return

    if touch_config.visible:
        if event.is_action_pressed("cancel") or event.is_action_pressed("start"):
            touch_config_panel.close_touch_config()
            get_viewport().set_input_as_handled()
        return

    if touch_controls.edit_mode:
        if event.is_action_pressed("quit_menu") or event.is_action_pressed("cancel"):
            touch_controls.end_edit()
            touch_config_panel.open_touch_config()
            get_viewport().set_input_as_handled()
        return

    if progression_active:
        _handle_progression_input(event)
        return


    if quit_prompt_open:
        start_menu.handle_quit_prompt_input(event)
        return

    if battle_entry_pending:
        return

    if event.is_action_pressed("quit_menu"):
        start_menu.open_quit_prompt()
        get_viewport().set_input_as_handled()
        return

    if battle_active:
        if battle_text_busy and (event.is_action_pressed("confirm") or
                event.is_action_pressed("start")):
            _finish_battle_text()
            get_viewport().set_input_as_handled()
            return
        if battle_text_busy:
            return
        if battle_item_pocket_open:
            _handle_battle_item_pocket_input(event)
            return
        if not battle_submenu_mode.is_empty():
            _handle_battle_submenu_input(event)
            return
        if battle_ui_mode == "INTRO":
            if event.is_action_pressed("confirm") or event.is_action_pressed("start"):
                _advance_battle_intro()
                get_viewport().set_input_as_handled()
            return
        if battle_ui_mode == "MOVE":
            _handle_battle_move_input(event)
            return
        if battle_ui_mode != "COMMAND":
            return
        if event.is_action_pressed("move_up"):
            _move_battle_command(0, -1)
            get_viewport().set_input_as_handled()
        elif event.is_action_pressed("move_down"):
            _move_battle_command(0, 1)
            get_viewport().set_input_as_handled()
        elif event.is_action_pressed("move_left"):
            _move_battle_command(-1, 0)
            get_viewport().set_input_as_handled()
        elif event.is_action_pressed("move_right"):
            _move_battle_command(1, 0)
            get_viewport().set_input_as_handled()
        elif event.is_action_pressed("confirm"):
            _activate_battle_command()
            get_viewport().set_input_as_handled()
        elif event.is_action_pressed("pokedex"):
            _repeat_last_battle_ball()
            get_viewport().set_input_as_handled()
        elif event.is_action_pressed("battle_catch"):
            _battle_catch()
            get_viewport().set_input_as_handled()
        elif event.is_action_pressed("shoulder_left"):
            _cycle_battle_move(-1)
            get_viewport().set_input_as_handled()
        elif event.is_action_pressed("shoulder_right"):
            _cycle_battle_move(1)
            get_viewport().set_input_as_handled()
        elif event.is_action_pressed("start"):
            _open_battle_party_menu("PARTY")
            get_viewport().set_input_as_handled()
        elif event.is_action_pressed("cancel"):
            _battle_run()
            get_viewport().set_input_as_handled()
        return

    if generating:
        return

    if build_menu_open:
        crafting_menu.handle_build_menu_input(event)
        return

    if craft_menu_open:
        crafting_menu.handle_crafting_input(event)
        return

    if started:
        if event.is_action_pressed("map_open"):
            if game_menu_open and game_menu_detail_open and game_menu_map_screen.visible and not teleport_map_mode:
                start_menu.close_game_menu()
            elif not _field_ui_blocks_gameplay() and not field_move_wheel_open and not bag_menu.sleeping_bag_active():
                start_menu.open_game_menu()
                minimap.show_map_menu()
            get_viewport().set_input_as_handled()
            return
        if game_menu_open:
            start_menu.handle_game_menu_input(event)
            return

        if bag_menu.sleeping_bag_active():
            if event.is_action_pressed("cancel"):
                bag_menu.end_sleeping_bag_rest()
                get_viewport().set_input_as_handled()
            elif event.is_action_pressed("start"):
                start_menu.queue_start_menu(event)
                get_viewport().set_input_as_handled()
            # Confirm and movement do not dismiss the sleeping bag.
            return

        if event.is_action_pressed("pokedex"):
            if not _field_ui_blocks_gameplay() and not field_move_wheel_open:
                pokedex_menu.open(false)
            get_viewport().set_input_as_handled()
            return

        if event.is_action_pressed("build_menu"):
            crafting_menu.open_build_menu()
            get_viewport().set_input_as_handled()
            return

        if GameOptions.enabled("zoom") and event.is_action_pressed("zoom_in"):
            var zoom_percent = int(world.call("adjust_camera_zoom", 1))
            dialogs.show_message("ZOOM %d%%" % zoom_percent)
            get_viewport().set_input_as_handled()
            return

        if GameOptions.enabled("zoom") and event.is_action_pressed("zoom_out"):
            var zoom_percent = int(world.call("adjust_camera_zoom", -1))
            dialogs.show_message("ZOOM %d%%" % zoom_percent)
            get_viewport().set_input_as_handled()
            return

        if event.is_action_pressed("start"):
            start_menu.queue_start_menu(event)
            get_viewport().set_input_as_handled()
        return

    # Text-entry mode never owns controller focus. If the user navigates away,
    # accept the current text, close the Android keyboard, and continue moving
    # through the menu in the same input press.
    if text_entry_target != "":
        if event.is_action_pressed("move_up"):
            setup_screen.finish_text_entry(true)
            setup_screen.move_menu_vertical(-1)
            menu_nav_cooldown = MENU_NAV_DELAY
            get_viewport().set_input_as_handled()
            return

        if event.is_action_pressed("move_down"):
            setup_screen.finish_text_entry(true)
            setup_screen.move_menu_vertical(1)
            menu_nav_cooldown = MENU_NAV_DELAY
            get_viewport().set_input_as_handled()
            return

        if event.is_action_pressed("move_left"):
            setup_screen.finish_text_entry(true)
            setup_screen.menu_left_right(-1)
            menu_nav_cooldown = MENU_NAV_DELAY
            get_viewport().set_input_as_handled()
            return

        if event.is_action_pressed("move_right"):
            setup_screen.finish_text_entry(true)
            setup_screen.menu_left_right(1)
            menu_nav_cooldown = MENU_NAV_DELAY
            get_viewport().set_input_as_handled()
            return

        if event.is_action_pressed("confirm") or event.is_action_pressed("start"):
            setup_screen.finish_text_entry(true)
            get_viewport().set_input_as_handled()
            return

        if event.is_action_pressed("cancel"):
            setup_screen.finish_text_entry(true)
            get_viewport().set_input_as_handled()
            return

        # Characters from the Android soft keyboard arrive as key events.
        if event is InputEventKey:
            var key = event as InputEventKey
            if key.pressed and not key.echo:
                if key.keycode == KEY_BACKSPACE:
                    if text_entry_buffer.length() > 0:
                        text_entry_buffer = text_entry_buffer.left(text_entry_buffer.length() - 1)
                        setup_screen.refresh_text_entry_display()
                    get_viewport().set_input_as_handled()
                    return

                if key.unicode >= 32 and key.unicode != 127:
                    if text_entry_buffer.length() < 24:
                        text_entry_buffer += String.chr(key.unicode)
                        setup_screen.refresh_text_entry_display()
                    get_viewport().set_input_as_handled()
                    return

        return

    # Restore D-pad / left-stick menu navigation using the EXISTING actions.
    if event.is_action_pressed("move_up"):
        if menu_nav_cooldown <= 0.0:
            if menu_row == MENU_ROW_COLOR and menu_col > 0:
                appearance.change_player_selector(1)
            else:
                setup_screen.move_menu_vertical(-1)
            menu_nav_cooldown = MENU_NAV_DELAY
        get_viewport().set_input_as_handled()
        return

    if event.is_action_pressed("move_down"):
        if menu_nav_cooldown <= 0.0:
            if menu_row == MENU_ROW_COLOR and menu_col > 0:
                appearance.change_player_selector(-1)
            else:
                setup_screen.move_menu_vertical(1)
            menu_nav_cooldown = MENU_NAV_DELAY
        get_viewport().set_input_as_handled()
        return

    if event.is_action_pressed("move_left"):
        if menu_nav_cooldown <= 0.0:
            setup_screen.menu_left_right(-1)
            menu_nav_cooldown = MENU_NAV_DELAY
        get_viewport().set_input_as_handled()
        return

    if event.is_action_pressed("move_right"):
        if menu_nav_cooldown <= 0.0:
            setup_screen.menu_left_right(1)
            menu_nav_cooldown = MENU_NAV_DELAY
        get_viewport().set_input_as_handled()
        return

    if event.is_action_pressed("confirm"):
        setup_screen.activate_menu_item()
        get_viewport().set_input_as_handled()
        return

    if event.is_action_pressed("cancel"):
        # Leaving either PLAYER selector returns focus to the PLAYER row so
        # vertical navigation works again.  It must never trap the user in
        # color/model selection.
        if menu_row == MENU_ROW_COLOR and menu_col > 0:
            menu_col = 0
            setup_screen.update_menu_cursor()
            get_viewport().set_input_as_handled()
        elif not started and not generating:
            # Back to the SOLO / CO-OP choice.
            coop_game.cancel_join();coop_menu.open()
            get_viewport().set_input_as_handled()
        return

    if event.is_action_pressed("start"):
        _start_game()
        get_viewport().set_input_as_handled()

func _menu_context_uses_stick_filter() -> bool:
    if is_instance_valid(coop_game) and is_instance_valid(coop_game.interaction_ui) and coop_game.interaction_ui.visible:return true
    if is_instance_valid(coop_menu) and coop_menu.visible:return true
    if is_instance_valid(waypoint_ui) and waypoint_ui.naming:return true
    if is_instance_valid(game_files_menu) and game_files_menu.visible:return true
    if is_instance_valid(mod_menu_panel) and mod_menu_panel.visible:return true
    if is_instance_valid(bag_action_ui):return true
    # The map and radial wheel poll continuously and need the stick's full
    # range. Row/command menus need deliberate, discrete direction presses.
    if field_move_wheel_open:
        return false
    if game_menu_open and game_menu_detail_open and game_menu_map_screen.visible:
        return false
    return (
        not started
        or mansion_switch_open or wild_pokemon_prompt_open or egg_pickup_open
        or storage_menu_open or trainer_tip_open
        or (is_instance_valid(pokedex_menu) and pokedex_menu.visible)
        or (is_instance_valid(options_menu) and options_menu.visible)
        or setup_load_open
        or pokemon_stats_open
        or touch_config.visible
        or progression_active
        or quit_prompt_open
        or battle_active
        or build_menu_open
        or craft_menu_open
        or game_menu_open
    )

func _menu_stick_event_is_blocked(event: InputEvent) -> bool:
    if not event is InputEventJoypadMotion:
        return false
    var motion := event as InputEventJoypadMotion
    if motion.axis not in [JOY_AXIS_LEFT_X, JOY_AXIS_LEFT_Y]:
        return false
    if not _menu_context_uses_stick_filter():
        last_menu_stick_token = 0
        menu_stick_state_by_device.clear()
        return false

    var stick: Vector2 = menu_stick_state_by_device.get(
        motion.device, Vector2.ZERO
    )
    if motion.axis == JOY_AXIS_LEFT_X:
        stick.x = motion.axis_value
    else:
        stick.y = motion.axis_value
    menu_stick_state_by_device[motion.device] = stick
    if stick.length() <= MENU_STICK_RELEASE:
        last_menu_stick_token = 0
        return true
    if stick.length() < MENU_STICK_ACTIVATION:
        return true

    var dominant_axis := (
        JOY_AXIS_LEFT_X if absf(stick.x) >= absf(stick.y)
        else JOY_AXIS_LEFT_Y
    )
    if motion.axis != dominant_axis:
        return true
    var dominant_value := stick.x if dominant_axis == JOY_AXIS_LEFT_X else stick.y
    var direction_sign := -1 if dominant_value < 0.0 else 1
    var token := (1 if dominant_axis == JOY_AXIS_LEFT_X else 2) * direction_sign
    var now := Time.get_ticks_msec()
    if token != last_menu_stick_token:
        if last_menu_stick_token != 0 and now - last_menu_stick_msec < MENU_STICK_REPEAT_MSEC:
            return true
        last_menu_stick_token = token
        last_menu_stick_msec = now
        return false
    if now - last_menu_stick_msec >= MENU_STICK_REPEAT_MSEC:
        last_menu_stick_msec = now
        return false
    return true

func touch_on() -> bool:
    return is_instance_valid(touch_ui) and touch_ui.enabled

func _is_android_touch_runtime() -> bool:
    return OS.has_feature("mobile") or (
        is_instance_valid(touch_controls)
        and bool(touch_controls.get("android_runtime"))
    )

## setup_screen.gd under its old names, for the scripts and tests that call them on main.
func _set_join_layout(joining: bool) -> void: setup_screen.set_join_layout(joining)
func _update_classic_menu_labels() -> void: setup_screen.update_classic_menu_labels()
func _update_menu_cursor() -> void: setup_screen.update_menu_cursor()
func _open_setup_load_selector() -> void: setup_screen.open_setup_load_selector()
func _refresh_setup_load_selector() -> void: setup_screen.refresh_setup_load_selector()
func _begin_text_entry(target: String) -> void: setup_screen.begin_text_entry(target)
func _finish_text_entry(accept: bool) -> void: setup_screen.finish_text_entry(accept)
func _paste_text_entry() -> void: setup_screen.paste_text_entry()
func _copy_text_entry() -> void: setup_screen.copy_text_entry()



func _start_game() -> void:
    if started or generating:
        return

    if not coop_game.join_setup_code.is_empty() and not coop_game.active:
        await coop_game.choose("JOIN",coop_game.join_setup_code)
        return

    if coop_game.new_setup_pending and not coop_game.active:
        if selected_mode=="LOAD":
            coop_menu.open();await coop_game.choose("LIST","")
        else:
            await coop_game.choose("NEW","")
        return

    if selected_mode == "LOAD" and not setup_load_committed and not coop_game.active:
        setup_screen.open_setup_load_selector()
        return

    generating = true
    setup_load_committed = false
    setup_screen.save_setup()
    setup_screen.hide_virtual_keyboard()

    setup_panel.visible = false
    generation_panel.visible = true
    generation_status.text = (
        "LOADING...\nPLEASE WAIT..."
        if selected_mode == "LOAD"
        else "Generating...\nPlease wait..."
    )
    generation_tip_index = -1
    generation_tip_timer = 0.0
    dialogs.show_generation_tip()

    world.visible = true

    var world_name := world_edit.text.strip_edges()
    if world_name.is_empty():
        world_name = "PokeWilds"

    var seed_value: int
    var load_data = {}

    if selected_mode == "NEW":
        GameOptions.restore_game_options({},world_name,true)
        _apply_game_options()
        preferred_storage_box = ""
        map_waypoints.clear()
        adjacent_worlds.clear()
        current_world_grid = Vector2i.ZERO
        inventory = CraftingData.ensure_inventory(STARTING_INVENTORY)
        caught_pokemon = [_make_starter_machop()]
        caught_species = ["machop"]
        pokedex_progress.restore({})
        pokedex_progress.seed_owned(caught_pokemon)
        new_world_sequence += 1
        var seed_rng := RandomNumberGenerator.new()
        seed_rng.randomize()
        seed_value = (
            world_name.hash()
            ^ int(Time.get_unix_time_from_system() * 1000000.0)
            ^ Time.get_ticks_usec()
            ^ seed_rng.randi()
            ^ (new_world_sequence * 0x45D9F3B)
        )
    else:
        load_data = coop_game.pending_game.duplicate(true) if coop_game.active else (
            saves.read(setup_load_path)
            if not setup_load_path.is_empty()
            else saving.read_game_save(world_name)
        )
        setup_load_path = ""
        if load_data.is_empty():
            generation_panel.visible = false
            setup_panel.visible = true
            generating = false
            menu_status.text = "NO SAVE FILE"
            return
        seed_value = int(load_data.get("world_seed", 81102))
        selected_world_size = int(load_data.get("world_size", selected_world_size))

    if selected_mode == "LOAD":
        GameOptions.restore_game_options(load_data.get("options", {}),String(load_data.get("world_name",world_name)))

    if seed_value == 0:
        seed_value = 81102

    generation_status.text = (
        "LOADING...\nPLEASE WAIT..."
        if selected_mode == "LOAD"
        else "Generating...\nPlease wait..."
    )

    await world.generate_world(
        seed_value, selected_world_size, selected_mode == "LOAD"
    )
    if not world.generation_error.is_empty():
        generation_panel.hide()
        setup_panel.show()
        generating = false
        menu_status.text = "GENERATION FAILED"
        dialogs.show_message(world.generation_error)
        return

    appearance.apply_world_player_textures()

    if selected_mode == "LOAD" and not load_data.is_empty():
        await saving.restore_game_save(load_data)
    if not coop_game.active:
        var loading: bool = selected_mode == "LOAD" and not load_data.is_empty()
        var held = pokemon_storage.get(SHARED_STORAGE_KEY, [])
        var adopted: Dictionary = preload("res://scripts/shared_storage.gd").adopt(
            {SHARED_STORAGE_KEY: held if held is Array else []} if loading else {},
            loading and bool(load_data.get("storage_shared", false)),
            int(load_data.get("storage_serial", 0)) if loading else 0)
        var shared_box = adopted.storage.get(SHARED_STORAGE_KEY, [])
        pokemon_storage[SHARED_STORAGE_KEY] = shared_box if shared_box is Array else []
        shared_storage_serial = int(adopted.serial)
        pokedex_progress.seed_owned(pokemon_storage[SHARED_STORAGE_KEY])

    _ensure_machop_lead(false)
    world.call("clear_active_field_move", false)
    await minimap.warm_map_cache()
    await _draw_world_view()

    if coop_game.active and not await coop_game.game_started():
        generation_panel.hide();setup_panel.show();generating=false
        # Leave properly and say so. Returning to this screen alone kept the
        # link to the host open and the loaded world's music playing, with no
        # word of what had gone wrong.
        if coop_game.active:
            coop_game.end_session("THE HOST DID NOT ANSWER.\nTRY AGAIN." if not coop_game.hosting else "ONLINE GAME COULD NOT START.")
        return
    generation_panel.visible = false
    started = true
    generating = false
    touch_controls.set_game_active(true)
    dialogs.show_message("Welcome, %s!" % player_model_name.text.strip_edges() if overflow_recovery_notice.is_empty() else overflow_recovery_notice)
    overflow_recovery_notice = ""

func _make_starter_machop() -> Dictionary:
    return BattleEngine.make_pokemon("machop", 5, battle_rng, {
        "original_trainer": player_model_name.text.strip_edges(),
        "met_location": "STARTING SHORE"
    })

func _ensure_machop_lead(heal_after_whiteout: bool) -> void:
    # Keep the existing repair for malformed records, without adding/reordering Pokemon.
    for index in range(caught_pokemon.size() - 1, -1, -1):
        if typeof(caught_pokemon[index]) == TYPE_DICTIONARY and String(
                caught_pokemon[index].get("species", "")).is_empty():
            caught_pokemon.remove_at(index)
    if not heal_after_whiteout: return
    for index in range(caught_pokemon.size()):
        var pokemon: Dictionary = caught_pokemon[index]
        if bool(pokemon.get("is_egg", false)): continue
        # CheckWhitedOut: HP only; status/PP and party ordering are retained.
        pokemon["hp"] = int(int(pokemon.get("max_hp", 1)) / 2)
        caught_pokemon[index] = pokemon

## player_appearance.gd under its old names, for the scripts and tests that call them on main.
func _previous_color() -> void: appearance.previous_color()
func _next_color() -> void: appearance.next_color()
func _previous_model() -> void: appearance.previous_model()
func _next_model() -> void: appearance.next_model()
func _player_sitting_texture(frame: int = 0) -> Texture2D: return appearance.player_sitting_texture(frame)
func _recolor_texture(base: Texture2D, source_color: Color, target_color: Color, cache_key: String) -> Texture2D: return appearance.recolor_texture(base, source_color, target_color, cache_key)

func _current_battle_terrain() -> String:
    var player_node := world.get_node_or_null("Player") as Node2D
    if player_node == null:
        return "GRASSY"
    var cell := Vector2i(
        int(floor(player_node.position.x / 16.0)),
        int(floor(player_node.position.y / 16.0))
    )
    if world.has_method("battle_terrain_at"):
        return String(world.call("battle_terrain_at", cell))
    return "GRASSY"

func _on_encounter_requested(species: String, level: int) -> void:
    if is_instance_valid(coop_game) and coop_game.active and coop_game.building.collecting:
        coop_game.building.field_encounter={"species":species,"level":level,"record":world.pending_encounter_record.duplicate(true)}
        return
    _start_battle_context({
        "id": "wild", "kind": "wild", "can_run": true,
        "can_catch": true,
        "party": [{"species": species, "level": level}]
    })

func _on_battle_requested(context: Dictionary) -> void:
    var event_id := String(context.get("id", ""))
    # Tile/PlayerStanding use ! for a bite, a ghost, an animated doll or tree.
    var source_alert := bool(context.get("source_player_alert", false)) or (
        event_id.begins_with("ghost") or event_id.begins_with("sudowoodo_tree_")
        or event_id in ["doll_banette", "doll_mimikyu"])
    _start_battle_context(context, source_alert)

func _party_reference_level() -> int:
    return BattleSession.reference_level(caught_pokemon)

func wild_level_for_player(source_level: int) -> int:
    return BattleSession.wild_level(caught_pokemon, source_level)

func _start_battle_context(context: Dictionary, source_alert: bool = false) -> void:
    if battle_active or battle_entry_pending:
        return

    var prepared_context = BattleSession.prepare_context(context, caught_pokemon)
    var raw_party = prepared_context.get("party", [])
    if typeof(raw_party) != TYPE_ARRAY or (raw_party as Array).is_empty():
        return
    battle_session = null
    if caught_pokemon.is_empty():
        if coop_game.active and coop_game.raids.eligible(prepared_context):
            dialogs.show_message("You need a Pokemon to fight in this raid.")
            return
        if coop_game.active and coop_game.events.eligible(prepared_context):
            if not await coop_game.events.begin(prepared_context):return
        if build_menu_open:
            crafting_menu.close_build_menu()
        safari_ui = preload("res://scripts/source_safari_encounter.gd").new()
        $UI.add_child(safari_ui)
        await safari_ui.start(self, prepared_context, source_alert)
        return
    # Reserve input before any await: a held/released wheel must not reopen
    # movement or activate a field move over the encounter/progression screen.
    battle_entry_pending = true
    if coop_game.active and coop_game.events.eligible(prepared_context):
        if not await coop_game.events.begin(prepared_context):
            battle_entry_pending=false;world.set_gameplay_enabled(true);return
    if coop_game.active and coop_game.raids.eligible(prepared_context):
        if not await coop_game.raids.begin(prepared_context):
            battle_entry_pending=false;world.set_gameplay_enabled(true);return
        raw_party=prepared_context.party
    if build_menu_open:
        crafting_menu.close_build_menu()
    move_wheel.close_field_move_wheel(false)
    world.set_gameplay_enabled(false)
    while progression_active or mansion_switch_open:
        await get_tree().process_frame
    if source_alert:
        world._show_ecology_emote(world.player.sprite, "!")
        await get_tree().create_timer(60.0 / 60.0).timeout
    battle_context = prepared_context
    world.environment_system.prepare_battle_music(battle_context)
    battle_enemy_party = []
    battle_enemy_party_index = 0
    battle_is_double = String(context.get("battle_format", "single")) == "double" and \
        (raw_party as Array).size() >= 2
    battle_player_partner = {}
    battle_enemy_partner = {}
    battle_partner_party_index = -1
    battle_enemy_partner_party_index = -1
    battle_double_command_slot = 0
    battle_double_actions.clear()
    battle_double_pending_move = ""
    battle_double_replacement_slot = -1
    battle_result_sent = false
    battle_player_cry_played = false
    var first_member = (raw_party as Array)[0] as Dictionary
    var species = String(first_member.get("species", "rattata")).to_lower()
    var level = maxi(1, int(first_member.get("level", 1)))

    battle_active = true
    battle_entry_pending = false
    battle_turn_busy = false
    battle_move_index = 0
    battle_command_index = 0
    battle_ui_mode = "INTRO"
    _update_battle_command_cursor()
    battle_turn_count = 0
    _close_battle_submenu()
    battle_pending_item = ""
    battle_item_pocket_open = false
    battle_item_pocket_index = ItemData.POCKET_ITEMS
    battle_item_menu_names.clear()
    battle_item_menu_index = 0
    item_pocket_menu.visible = false
    # What the battle reads from the world, as it begins.
    var battle_facts := {
        "time_of_day":"night" if world.environment_system.is_night_time() else "day",
        "terrain":_current_battle_terrain()
    }
    current_species = species
    current_level = level
    world.set_gameplay_enabled(false)
    var mewtwo_route_volumes: Array[float] = []
    if bool(battle_context.get("source_mewtwo", false)):
        battle_turn_busy = true
        for music_player in world.environment_system.music_players:
            mewtwo_route_volumes.append(music_player.volume_db)
            if music_player.playing:
                var fade := create_tween()
                fade.tween_property(music_player,"volume_linear",0.0,maxf(1.0/60.0,music_player.volume_linear/0.025/60.0))
        var prelude_start := preload("res://scripts/game_clock.gd").ticks_usec()
        while preload("res://scripts/game_clock.gd").ticks_usec()-prelude_start < 333333:
            await get_tree().process_frame
        dialogs.show_message("...")
        while preload("res://scripts/game_clock.gd").ticks_usec()-prelude_start < 2000000:
            await get_tree().process_frame
        message_panel.hide()
        message_timer=0.0
    if String(battle_context.get("source_boss", "")) == "regigigas":
        battle_turn_busy=true
        dialogs.show_message("...")
        for music_player in world.environment_system.music_players:
            mewtwo_route_volumes.append(music_player.volume_db)
            if music_player.playing:
                create_tween().tween_property(music_player,"volume_linear",0.0,75.0/60.0)
        var regi_deadline := preload("res://scripts/game_clock.gd").ticks_usec()+2750000 # 75 fade + 90 wait ticks
        while preload("res://scripts/game_clock.gd").ticks_usec()<regi_deadline:await get_tree().process_frame
        message_panel.hide()
        message_timer=0.0
    if world.has_method("set_environment_battle_active"):
        world.call("set_environment_battle_active", true)
    for music_index in range(mewtwo_route_volumes.size()):
        world.environment_system.music_players[music_index].volume_db=mewtwo_route_volumes[music_index]
    touch_config.visible = false

    if String(battle_context.get("kind", "wild")) == "wild" and world.has_method("take_pending_encounter_record"):
        battle_facts["wild_record"] = world.call("take_pending_encounter_record")
    if is_instance_valid(ball_mechanics) and not ball_mechanics.requested_battler.is_empty():
        battle_facts["requested"] = ball_mechanics.requested_battler
        ball_mechanics.requested_battler = ""
    battle_session = BattleSession.new()
    battle_session.stepwise = true
    # The battle draws from main's RNG, as it always has (a transcript seeds it).
    battle_session.rng = battle_rng
    var able_to_battle := battle_session.begin(battle_context, caught_pokemon, inventory, battle_facts)
    _pull_battle_state()
    if coop_game.active and coop_game.raids.active:coop_game.raids.apply_hp()
    if not able_to_battle:
        battle_panel.visible = true
        await _type_battle_text("You have no Pokemon able to battle.")
        await get_tree().create_timer(0.4).timeout
        _end_battle("whiteout")
        return
    _request_pokemon_cry(battle_enemy)
    _request_pokemon_cry(battle_player)

    var battle_texture: Texture2D = PokemonData.record_texture(battle_enemy, "front")
    if battle_texture == null:
        battle_texture = POKEMON_TEXTURES.get(species) as Texture2D
    if String(battle_context.get("kind", "")) == "ghost" and not bool(battle_context.get("ghost_revealed", true)):
        battle_texture = _ghost_battle_texture()
    enemy_sprite.texture = _battle_sprite_frame(battle_texture)
    player_battle_sprite.texture = _trainer_battle_texture()
    enemy_sprite.visible = true
    player_battle_sprite.visible = true
    enemy_sprite.modulate = Color.WHITE
    player_battle_sprite.modulate = Color.WHITE
    _show_battle_intro_screen()
    battle_status.text = ""
    battle_status.visible_characters = -1
    battle_text_busy = false
    battle_ui_mode = "TRANSITION"
    battle_panel.visible = false
    _set_double_battle_layout()
    _update_battle_field_visuals()
    _update_battle_hud()
    if not String(battle_context.get("source_boss", "")).is_empty():
        await _play_source_boss_intro()
        return
    if bool(battle_context.get("source_mewtwo", false)):
        await _play_source_mewtwo_intro()
        await _play_source_mewtwo_sendout()
        return
    else:
        await _play_battle_transition()
    if bool(battle_context.get("pvp",false)):
        _show_battle_intro_screen()
        return
    if PokemonData.is_shiny(battle_enemy) and not (String(battle_context.get("kind", "")) == "ghost" and not bool(battle_context.get("ghost_revealed", true))):
        await _play_source_battle_feedback("SHINY", false, {})
    if bool(battle_enemy.get("is_ghost", false)):
        source_effect_playing = true
        await _play_source_ghost_intro(true)
        source_effect_playing = false
    else:
        _play_pokemon_cry(battle_enemy)
        if String(battle_enemy.get("species", "")) == "mew":
            await _play_mew_battle_intro()
    _show_battle_intro_screen()

func _play_mew_battle_intro() -> void:
    if not GameOptions.enabled("battle_animations"): return
    var frames: Array = JSON.parse_string(FileAccess.get_file_as_string("res://data/mew_intro_frames.json"))
    var texture := PokemonData.record_texture(battle_enemy,"front")
    var elapsed := 0.0
    source_effect_playing = true
    while battle_active and int(elapsed*60.0) < frames.size():
        enemy_sprite.texture = _battle_sprite_frame_at(texture,int(frames[int(elapsed*60.0)]))
        await get_tree().process_frame
        elapsed += get_process_delta_time()
    enemy_sprite.texture = _battle_sprite_frame(texture)
    source_effect_playing = false

var source_boss_sendout_finished := false

func _play_source_boss_intro() -> void:
    battle_turn_busy=true
    _show_battle_intro_screen()
    _start_battle_text("")
    var kind := String(battle_context.source_boss)
    if kind=="regigigas" and GameOptions.enabled("battle_animations"):
        battle_panel.hide()
        var deadline := preload("res://scripts/game_clock.gd").ticks_usec()+int(190.0*1000000.0/60.0)
        while preload("res://scripts/game_clock.gd").ticks_usec()<deadline:await get_tree().process_frame
    await _play_battle_transition(123 if kind=="regigigas" else 154)
    source_boss=preload("res://scripts/source_boss_battle.gd").new()
    battle_panel.add_child(source_boss)
    battle_panel.move_child(source_boss,1)
    source_boss.setup(self,kind,bool(battle_enemy.get("shiny",false)))
    source_boss_sendout_finished=false
    source_boss.sendout_due.connect(_play_source_boss_sendout)
    await source_boss.play_intro()
    if kind=="regigigas":await _play_source_boss_sendout()
    while not source_boss_sendout_finished:await get_tree().process_frame

func _play_source_boss_sendout() -> void:
    await _play_source_mewtwo_sendout(false)
    source_boss_sendout_finished=true

func _play_source_mewtwo_intro() -> void:
    battle_turn_busy = true
    _show_battle_intro_screen()
    enemy_sprite.visible = false
    player_battle_sprite.visible = false
    _start_battle_text("")
    var speech: Dictionary = preload("res://scripts/source_mewtwo_battle.gd").SPEECH
    if not source_mewtwo_intro_seen:
        var elapsed := 0.0
        var tick := 0
        while tick < 1708:
            await get_tree().process_frame
            elapsed += get_process_delta_time()
            var target := mini(1708, int(elapsed * 60.0))
            while tick < target:
                if speech.has(tick): _start_battle_text(String(speech[tick]))
                tick += 1
    else:
        world.environment_system.battle_music.seek(28.55)
    source_mewtwo_intro_seen = true
    _start_battle_text("")
    await _play_battle_transition(154)
    source_mewtwo = preload("res://scripts/source_mewtwo_battle.gd").new()
    battle_panel.add_child(source_mewtwo)
    battle_panel.move_child(source_mewtwo, 1)
    source_mewtwo.setup(self, bool(battle_enemy.get("shiny", false)))
    enemy_sprite.texture = source_mewtwo.body
    enemy_sprite.visible = true
    player_battle_sprite.visible = true
    await source_mewtwo.play_intro()

func _play_source_mewtwo_sendout(show_wild_intro: bool = true) -> void:
    if show_wild_intro:
        _play_pokemon_cry(battle_enemy)
        _show_battle_intro_screen()
    if not GameOptions.enabled("battle_animations"):
        _start_battle_text("Go! %s!" % PokemonState.display_name(battle_player))
        player_battle_sprite.visible = true
        battle_turn_busy = false
        _show_battle_command_screen()
        return
    await get_tree().create_timer(39.0/60.0).timeout
    var trainer_position := player_battle_sprite.position
    # MovePlayerOffScreen keeps the trainer still for 38 ticks, then steps out.
    var start_time := preload("res://scripts/game_clock.gd").ticks_usec()
    var deadlines := [38,40,43,46,49,52,55]
    var offsets := [0,-8,-16,-8,-16,-8,-16]
    var displacement := 0
    for step in range(deadlines.size()):
        while preload("res://scripts/game_clock.gd").ticks_usec()-start_time < int(deadlines[step]*1000000.0/60.0):
            await get_tree().process_frame
        displacement += int(offsets[step])
        player_battle_sprite.position = trainer_position+Vector2(displacement,0)
    player_battle_sprite.visible=false
    player_battle_sprite.position=trainer_position
    _start_battle_text("Go! %s!" % PokemonState.display_name(battle_player))
    var sendout := preload("res://scripts/source_pokemon_sendout.gd").new()
    battle_panel.add_child(sendout)
    sendout.position=player_battle_sprite.position
    sendout.size=player_battle_sprite.size
    sendout.z_index=player_battle_sprite.z_index
    sendout.setup(_battle_sprite_frame(PokemonData.record_texture(battle_player,"back")))
    await sendout.play(self)
    sendout.queue_free()
    if PokemonData.is_shiny(battle_player):
        player_battle_sprite.visible = true
        await _play_source_battle_feedback("SHINY", true, {})
    player_battle_sprite.visible=true
    battle_turn_busy=false
    _show_battle_command_screen()

func _play_battle_transition(source_frames: int = 28) -> void:
    if not GameOptions.enabled("battle_animations"):
        battle_transition.hide()
        battle_panel.show()
        return
    # PokeWilds 0.8.11 ships 28 authored 160x144 transition frames in this
    # sheet. Draw them over the live route, then reveal the prepared battle.
    battle_transition.visible = false
    battle_panel.visible = false
    var overlay := TextureRect.new()
    overlay.name = "SourceBattleTransition"
    overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
    overlay.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
    overlay.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
    overlay.stretch_mode = TextureRect.STRETCH_SCALE
    overlay.position = Vector2.ZERO
    overlay.size = get_viewport().get_visible_rect().size
    overlay.z_index = 1000
    $UI.add_child(overlay)
    var intro_sheet: Texture2D = load(SOURCE_BATTLE_INTRO_PATH)
    var transition_deadline := preload("res://scripts/game_clock.gd").ticks_usec()
    for tick in range(source_frames):
        var frame_index := mini(27, tick)
        var frame := AtlasTexture.new()
        frame.atlas = intro_sheet
        frame.region = Rect2(float(frame_index * 160), 0.0, 160.0, 144.0)
        overlay.texture = frame
        transition_deadline += 16667
        while preload("res://scripts/game_clock.gd").ticks_usec() < transition_deadline:
            await get_tree().process_frame
    battle_panel.visible = true
    overlay.queue_free()

## The Safari encounter's enemy (source_safari_encounter.gd), made and fitted
## to the overworld Pokemon as a battle's would be (battle_session.gd).
func _make_context_enemy(member: Dictionary) -> Dictionary:
    var maker := BattleSession.new()
    maker.rng = battle_rng
    maker.context = battle_context
    return maker.make_enemy(member)

func _apply_pending_wild_record(enemy: Dictionary, level: int) -> Dictionary:
    if String(battle_context.get("kind", "wild")) != "wild" or not world.has_method("take_pending_encounter_record"):
        return enemy
    var maker := BattleSession.new()
    maker.context = battle_context
    maker.world = {"wild_record":world.call("take_pending_encounter_record")}
    return maker.apply_wild_record(enemy, level)

func _trainer_battle_texture() -> Texture2D:
    player_model_index = clampi(
        player_model_index, 0, PLAYER_MODEL_BATTLE_BACK_TEXTURES.size() - 1
    )
    player_color_index = clampi(
        player_color_index, 0, PLAYER_COLOR_VALUES.size() - 1
    )
    return appearance.recolor_texture(
        lazy_texture(PLAYER_MODEL_BATTLE_BACK_TEXTURES[player_model_index]),
        PLAYER_MODEL_BATTLE_REPLACE_COLORS[player_model_index],
        PLAYER_COLOR_VALUES[player_color_index],
        "battle_back:%d:%d" % [player_model_index, player_color_index]
    )

func _ghost_battle_texture() -> Texture2D:
    var atlas := AtlasTexture.new()
    atlas.atlas = GHOST_BATTLE_SHEET
    atlas.region = Rect2(0, 0, GHOST_BATTLE_SHEET.get_width(), GHOST_BATTLE_SHEET.get_width())
    return atlas

var battle_sprite_frame_counts: Dictionary = {}
var battle_sprite_facts: Dictionary = {}

## Imported sheets come with what the GPU check below would find worked out
## beforehand (tools/battle_sprite_facts.gd): reading a sprite back from the GPU
## stalls the iPhone. [idle frames, frames whose background is removed...], or
## [] for art the table does not know (mods), which is checked as before.
func _battle_sprite_facts(texture: Texture2D) -> Array:
    if not texture is CompressedTexture2D: return []
    if battle_sprite_facts.is_empty():
        var parsed = JSON.parse_string(FileAccess.get_file_as_string("res://data/battle_sprite_facts.json"))
        battle_sprite_facts = parsed if parsed is Dictionary else {}
        battle_sprite_facts["plain"] = PackedInt64Array(battle_sprite_facts.get("plain", []))
    var key := "%s:%dx%d" % [texture.resource_path, texture.get_width(), texture.get_height()]
    var listed: Array = (battle_sprite_facts.get("listed", {}) as Dictionary).get(key, [])
    if not listed.is_empty(): return listed
    # Most sheets animate every frame and keep their background: only a hash.
    var plain: PackedInt64Array = battle_sprite_facts.plain
    var at := plain.bsearch(key.hash())
    return [_battle_sprite_sheet_frames(texture)] if at < plain.size() and plain[at] == key.hash() else []

## How many frames the sheet holds, stacked top to bottom.
func _battle_sprite_sheet_frames(texture: Texture2D) -> int:
    if texture == null:
        return 0
    var texture_width: int = texture.get_width()
    var texture_height: int = texture.get_height()
    if texture_width <= 0 or texture_height <= texture_width:
        return 1
    if texture_height % texture_width == 0:
        return maxi(1, int(texture_height / texture_width))
    return maxi(1, roundi(float(texture_height) / float(texture_width)))

## How many of those frames the idle animation steps through.
func _battle_sprite_frame_count(texture: Texture2D) -> int:
    var count := _battle_sprite_sheet_frames(texture)
    if count < 2:
        return count
    var texture_width: int = texture.get_width()
    var texture_height: int = texture.get_height()
    if texture_height % texture_width != 0:
        return count
    # An idle animation is the same pose with small changes. A sheet whose
    # second frame is a different drawing (Mega Gyarados) is not one: flipping
    # between the two makes the Pokemon thrash about. Show its first frame.
    var facts := _battle_sprite_facts(texture)
    if not facts.is_empty(): return int(facts[0])
    var key := texture.resource_path if not texture.resource_path.is_empty() else str(texture.get_instance_id())
    if not battle_sprite_frame_counts.has(key):
        var image := TexturePixels.of(texture)
        var different := 0
        if image != null and not image.is_empty():
            for y in range(texture_width):
                for x in range(texture_width):
                    if image.get_pixel(x, y) != image.get_pixel(x, y + texture_width):
                        different += 1
        # Real idle animations in the game change under two thirds of the frame.
        battle_sprite_frame_counts[key] = 1 if different * 10 > texture_width * texture_width * 7 else count
    return int(battle_sprite_frame_counts[key])

func _battle_sprite_frame_at(texture: Texture2D, animation_frame: int) -> Texture2D:
    if texture == null:
        return null
    # The sheet is always cut into its frames; a sheet that is not animated
    # stays on the first one instead of being drawn whole.
    var frame_count := _battle_sprite_sheet_frames(texture)
    var frame_index := posmod(animation_frame, maxi(1, _battle_sprite_frame_count(texture)))
    var cache_key := texture.resource_path
    if cache_key.is_empty():
        cache_key = str(texture.get_instance_id())
    cache_key += "#%d" % frame_index
    if battle_sprite_alpha_cache.has(cache_key):
        return battle_sprite_alpha_cache[cache_key] as Texture2D
    var texture_width: int = texture.get_width()
    var texture_height: int = texture.get_height()
    var result: Texture2D = texture
    if frame_count > 1 and texture_width > 0:
        var frame_height := texture_width if texture_height % texture_width == 0 else \
            ceili(float(texture_height) / float(frame_count))
        var frame_y := mini(frame_index * frame_height, maxi(0, texture_height - 1))
        var frame := AtlasTexture.new()
        frame.atlas = texture
        frame.region = Rect2(
            0, frame_y, texture_width,
            mini(frame_height, texture_height - frame_y)
        )
        result = frame
    var facts := _battle_sprite_facts(texture)
    if facts.is_empty() or facts.slice(1).has(float(frame_index)):
        result = _remove_connected_sprite_background(result)
    # Each entry keeps its Pokemon's sheet loaded: hold only the recent ones.
    if battle_sprite_alpha_cache.size() >= 48: battle_sprite_alpha_cache.clear()
    battle_sprite_alpha_cache[cache_key] = result
    return result

func _battle_sprite_frame(texture: Texture2D) -> Texture2D:
    return _battle_sprite_frame_at(texture, 0)

func _update_battle_sprite_animation(delta: float) -> void:
    if not GameOptions.enabled("battle_animations"):
        if battle_sprite_animation_frame != 0:
            battle_sprite_animation_frame = 0
            _refresh_battle_sprites()
        return
    if source_effect_playing:
        return
    if not battle_active or battle_panel == null or not battle_panel.visible:
        battle_sprite_animation_elapsed = 0.0
        battle_sprite_animation_frame = 0
        return
    # The INTRO intentionally holds the trainer back sprite. Refreshing the
    # Pokemon animation here swaps that texture mid-intro and causes flashing.
    if battle_ui_mode in ["INTRO", "TRANSITION"]:
        battle_sprite_animation_elapsed = 0.0
        battle_sprite_animation_frame = 0
        return
    battle_sprite_animation_elapsed += delta
    if battle_sprite_animation_elapsed < BATTLE_SPRITE_FRAME_SECONDS:
        return
    battle_sprite_animation_elapsed = fmod(
        battle_sprite_animation_elapsed, BATTLE_SPRITE_FRAME_SECONDS)
    battle_sprite_animation_frame += 1
    _refresh_battle_sprites()

func _remove_connected_sprite_background(texture: Texture2D) -> Texture2D:
    var image := TexturePixels.of(texture)
    if image == null or image.is_empty():
        return texture
    image.convert(Image.FORMAT_RGBA8)
    var width := image.get_width()
    var height := image.get_height()
    # A sheet that already has a see-through background has nothing to remove.
    # White that reaches its edge is part of the Pokemon (Noivern's white ruff
    # on its back sprite), and erasing it left a hole that showed in dark mode.
    for corner in [Vector2i.ZERO, Vector2i(width - 1, 0), Vector2i(0, height - 1), Vector2i(width - 1, height - 1)]:
        if image.get_pixelv(corner).a < 0.01:
            return texture
    var pending: Array[Vector2i] = []
    for x in range(width):
        pending.append(Vector2i(x, 0))
        pending.append(Vector2i(x, height - 1))
    for y in range(height):
        pending.append(Vector2i(0, y))
        pending.append(Vector2i(width - 1, y))
    var visited: Dictionary = {}
    var removed := 0
    while not pending.is_empty():
        var cell: Vector2i = pending.pop_back()
        if cell.x < 0 or cell.y < 0 or cell.x >= width or cell.y >= height or \
                visited.has(cell):
            continue
        visited[cell] = true
        var color := image.get_pixelv(cell)
        var lightest := maxf(color.r, maxf(color.g, color.b))
        var darkest := minf(color.r, minf(color.g, color.b))
        if color.a < 0.01 or darkest < 0.82 or lightest - darkest > 0.12:
            continue
        color.a = 0.0
        image.set_pixelv(cell, color)
        removed += 1
        pending.append(cell + Vector2i.LEFT)
        pending.append(cell + Vector2i.RIGHT)
        pending.append(cell + Vector2i.UP)
        pending.append(cell + Vector2i.DOWN)
    if removed <= 0:
        return texture
    return TexturePixels.texture_from(image)

func _set_battle_message_width(full_width: bool) -> void:
    battle_status.offset_left = 16.0
    battle_status.offset_top = 135.0
    battle_status.offset_right = 300.0 if full_width else 125.0
    battle_status.offset_bottom = 175.0

var world_hidden_by_battle := false

## An opaque battle or menu screen covers the whole field: stop drawing the world under it.
func _hide_world_under_battle() -> void:
    var backdrop: ColorRect = battle_panel.get_node("Background")
    var covered: bool = battle_active and battle_panel.visible and backdrop.visible         and backdrop.color.a >= 1.0 and battle_panel.modulate.a >= 1.0
    _pause_field_reflections(covered)
    # Full-screen touch menus (the map, the bag, the party...) are opaque too.
    if not covered and is_instance_valid(touch_ui):
        var menu_backdrop: ColorRect = touch_ui.surfaces.backdrop
        covered = is_instance_valid(menu_backdrop) and menu_backdrop.visible and menu_backdrop.color.a >= 1.0
    if covered == world_hidden_by_battle: return
    world_hidden_by_battle = covered
    # Only the drawing is switched off: toggling `visible` notified all ~18k
    # nodes under the world (~9 ms at every battle start and end). The title
    # screen's own world.visible = false still wins.
    RenderingServer.canvas_item_set_visible(world.get_canvas_item(), world.visible and not covered)

var paused_reflections: Node = null

## Under an opaque battle screen the field is not drawn, so its water
## reflections (about a sixth of a battle frame's CPU) need not be worked out.
## The tile streams keep running: they also bring in the tide, which has to be
## in place the moment the field shows again.
func _pause_field_reflections(paused: bool) -> void:
    if paused == is_instance_valid(paused_reflections): return
    if not paused:
        paused_reflections.set_process(true)
        paused_reflections = null
        return
    var reflections := world.get_node_or_null("ExactReflectionLayer")
    if reflections != null and reflections.is_processing():
        reflections.set_process(false)
        paused_reflections = reflections

func _restore_battle_background() -> void:
    if not is_instance_valid(battle_panel): return
    var backdrop: ColorRect = battle_panel.get_node("Background")
    backdrop.color = preload("res://scripts/dark_mode.gd").BACKGROUND if GameOptions.enabled("dark_mode") else Color.WHITE
    backdrop.show()

func _show_battle_intro_screen() -> void:
    _restore_battle_background()
    battle_ui_mode = "INTRO"
    source_command_frame.visible = false
    source_single_hud.visible = false
    source_command_cursor.visible = false
    enemy_hud.visible = false
    player_hud.visible = false
    battle_command_box.visible = true
    battle_command_divider.visible = false
    battle_actions.visible = false
    battle_actions.modulate = Color.WHITE
    battle_status.visible = true
    battle_move_type_box.visible = false
    battle_move_box.visible = false
    battle_message_arrow.visible = false
    _set_battle_message_width(true)
    player_battle_sprite.texture = _trainer_battle_texture()
    player_battle_sprite.visible = true
    enemy_sprite.visible = true
    player_battle_sprite.modulate = Color.WHITE
    enemy_sprite.modulate = Color.WHITE
    if bool(battle_context.get("pvp",false)):
        enemy_sprite.texture = preload("res://scripts/coop_trainer_portraits.gd").texture(self,battle_context.get("trainer_visual",{}))
    _start_battle_text(BattleSession.intro_text(battle_context, battle_enemy))

func _advance_battle_intro() -> void:
    if source_effect_playing: return
    var messages: Array = battle_context.get("_entry_messages", [])
    if not messages.is_empty():
        _start_battle_text(String(messages.pop_front()))
        battle_context["_entry_messages"] = messages
        return
    battle_context.erase("_entry_messages")
    if PokemonData.is_shiny(battle_player) and not battle_player_cry_played:
        _refresh_battle_sprites()
        await _play_source_battle_feedback("SHINY", true, {})
    _show_battle_command_screen()

func _show_battle_command_screen() -> void:
    if not battle_active or battle_player.is_empty() or battle_enemy.is_empty():
        return
    _restore_battle_background()
    battle_ui_mode = "COMMAND"
    var source_single := not battle_is_double
    # The authored top HUD remains source-accurate, but the command area uses
    # the project's dialogue border across the full viewport.
    source_command_frame.visible = false
    source_single_hud.visible = source_single
    source_command_cursor.visible = false
    enemy_hud.visible = not source_single
    player_hud.visible = not source_single
    battle_command_box.visible = true
    battle_command_divider.visible = true
    battle_actions.visible = true
    battle_actions.modulate = Color.WHITE
    battle_status.visible = true
    battle_move_type_box.visible = false
    battle_move_box.visible = false
    battle_message_arrow.visible = false
    _set_battle_message_width(false)
    _refresh_battle_sprites()
    if not battle_player_cry_played:
        battle_player_cry_played = true
        _play_pokemon_cry(battle_player)
    _update_battle_hud()
    _update_battle_command_cursor()
    _start_battle_text(BattleSession.command_text(_command_pokemon()))

func _command_pokemon() -> Dictionary:
    if battle_is_double and battle_double_command_slot == 1 and \
            not battle_player_partner.is_empty():
        return battle_player_partner
    return battle_player

func _show_battle_message_screen() -> void:
    battle_ui_mode = "MESSAGE"
    var source_single := not battle_is_double
    source_command_frame.visible = false
    source_single_hud.visible = source_single
    source_command_cursor.visible = false
    enemy_hud.visible = not source_single and not battle_enemy.is_empty()
    player_hud.visible = not source_single and not battle_player.is_empty()
    battle_command_box.visible = true
    battle_command_divider.visible = false
    battle_actions.visible = false
    battle_actions.modulate = Color.WHITE
    battle_status.visible = true
    battle_move_type_box.visible = false
    battle_move_box.visible = false
    battle_message_arrow.visible = false
    _set_battle_message_width(true)

# --- the battle screen plays the battle session's events -------------------------

## The battle just fought as the co-op host can replay it (battle_session.gd
## replay_log(); coop_wild_runtime.gd sends it with a wild battle's result),
## or {} when no battle session fought it (the Safari encounter).
func battle_report() -> Dictionary:
    return battle_session.replay_log() if battle_session != null and battle_session.finished else {}

## This screen's copies of what the battle session holds (the HUD, sprites,
## menus and co-op read them).
func _pull_battle_state() -> void:
    var session := battle_session
    battle_player = session.player
    battle_enemy = session.enemy
    battle_player_partner = session.partner
    battle_enemy_partner = session.enemy_partner
    battle_party_index = session.party_index
    battle_partner_party_index = session.partner_index
    battle_enemy_party = session.enemy_party
    battle_enemy_party_index = session.enemy_index
    battle_enemy_partner_party_index = session.enemy_partner_index
    battle_field = session.field
    battle_is_double = session.double
    battle_turn_count = session.turn_count
    battle_exp_participants = session.participants
    current_species = String(battle_enemy.get("species", current_species))
    current_level = int(battle_enemy.get("level", current_level))

## Plays the session's events one at a time, the battle waiting for each; a
## request (a Pokemon to send out) is answered from the party menu.
func _battle_play(events: Array) -> void:
    var session := battle_session
    while true:
        var answer = null
        for event in events:
            if session != battle_session or (not battle_active and not session.finished):
                # The battle was ended from outside (a co-op game closing).
                session.abandon()
                return
            _pull_battle_state()
            answer = await _play_battle_event(event)
        if not session.running:
            return
        events = session.resume(answer)

func _play_battle_event(event: Dictionary) -> Variant:
    match String(event.kind):
        "text":
            if bool(event.get("hud", false)):
                _update_battle_hud()
            await _type_battle_text(String(event.text))
            if float(event.get("wait", 0.0)) > 0.0:
                await get_tree().create_timer(float(event.wait)).timeout
        "wait":
            await get_tree().create_timer(float(event.seconds)).timeout
        "message_screen":
            _show_battle_message_screen()
        "command":
            if battle_is_double:
                battle_double_actions.clear()
                battle_double_command_slot = int(event.get("slot", 0))
                battle_move_index = 0
            battle_turn_busy = false
            _show_battle_command_screen()
        "end":
            _end_battle(String(event.outcome))
        "move":
            await _play_move_event(event)
        "double_move":
            await _play_double_move_event(event)
        "residual":
            await _play_residual_event(event)
        "end_turn":
            await _play_end_turn_event(event)
        "poison_check":
            await _play_poison_status_feedback(event.pokemon, bool(event.player_side),
                int(event.hp_before), bool(event.poisoned))
        "double_end_turn":
            _update_battle_field_visuals()
            if not String(event.text).is_empty():
                await _type_battle_text(String(event.text))
                await get_tree().create_timer(0.1).timeout
        "player_switch", "enemy_switch":
            if bool(event.get("reset_move", false)):
                battle_move_index = 0
            _refresh_battle_sprites()
            if bool(event.get("hud", false)):
                _update_battle_hud()
            _play_pokemon_cry(event.pokemon)
            if not String(event.text).is_empty():
                await _type_battle_text(String(event.text))
                await get_tree().create_timer(float(event.wait)).timeout
        "refresh":
            _refresh_battle_sprites()
            _update_battle_hud()
        "victory_music":
            world.environment_system.play_victory_music()
        "throw":
            _play_source_battle_sound("throw_pokeball1.ogg")
            await _play_source_throw_animation(bool(event.captured), int(event.shakes))
        "caught":
            await _play_caught_event(event)
        "experience":
            await _run_experience_progression(event.pokemon, int(event.amount),
                int(event.index), bool(event.defer_evolution))
        "evolution_check":
            await _check_reward_evolution(event.pokemon, int(event.index))
        "boss_special":
            await _play_boss_special(event)
        "special_damage":
            await _play_special_damage(event)
        "silph_scope_fade":
            await _play_silph_scope_fade()
        "silph_scope_reveal":
            await _play_silph_scope_reveal()
        "switch":
            # A Pokemon to send out: after a faint, Baton Pass or Roar.
            if String(event.reason) == "DOUBLE_FORCED":
                battle_double_replacement_slot = int(event.get("slot", 0))
            _open_battle_party_menu(String(event.reason))
            return int(await battle_party_chosen)
    return null

## A move: its first sentence, its animation, the HP bars, the rest of its
## message and any status it caused.
func _play_move_event(event: Dictionary) -> void:
    var result: Dictionary = event.result
    var player_attacks := bool(event.player_side)
    var attacker: Dictionary = event.attacker
    var defender: Dictionary = event.defender
    var attacker_hp_before := int(event.attacker_hp_before)
    var defender_hp_before := int(event.defender_hp_before)
    if coop_game.active and coop_game.raids.active:await coop_game.raids.sync_damage(int(event.raid_hp_before))
    if bool(event.weather):
        _update_battle_field_visuals()
    var message_parts := BattleSession.message_parts(String(result.message))
    _start_battle_text(message_parts[0])
    if battle_text_busy:
        await battle_text_finished
    if not bool(result.get("executed", false)):
        await _play_blocked_status_feedback(attacker, player_attacks, String(result.get("message", "")))
    else:
        await _play_battle_feedback(String(result.get("animation_move", event.move)),
            player_attacks, result, defender)
    if battle_text_busy:
        await battle_text_finished
    _refresh_battle_sprites()
    await _animate_visible_battle_hp(defender, int(defender.hp) if bool(result.get("hp_feedback_complete", false)) else defender_hp_before,
        int(defender.get("hp", 0)))
    if int(defender.hp) != defender_hp_before:
        await get_tree().create_timer(13.0 / 60.0).timeout
    await _animate_visible_battle_hp(attacker, attacker_hp_before,
        int(attacker.get("hp", 0)))
    if int(attacker.hp) != attacker_hp_before:
        await get_tree().create_timer(13.0 / 60.0).timeout
    _update_battle_hud()
    if not message_parts[1].is_empty():
        await _type_battle_text(message_parts[1])
    await _play_new_status_feedback(defender, not player_attacks, event.status_before, result)
    await get_tree().create_timer(0.1).timeout

## A double battle's move on one of its targets.
func _play_double_move_event(event: Dictionary) -> void:
    var result: Dictionary = event.result
    var player_side := bool(event.player_side)
    var attacker: Dictionary = event.attacker
    var defender: Dictionary = event.defender
    var attacker_hp_before := int(event.attacker_hp_before)
    var defender_hp_before := int(event.defender_hp_before)
    var message_parts := BattleSession.message_parts(String(result.message))
    _start_battle_text("Target %s: %s" % [
        BattleEngine.display_name(defender),
        message_parts[0]])
    if battle_text_busy:
        await battle_text_finished
    if not bool(result.get("executed", false)):
        await _play_blocked_status_feedback(attacker, player_side, String(result.get("message", "")))
    else:
        await _play_battle_feedback(String(result.get("animation_move", event.move)),
            player_side, result, defender)
    if battle_text_busy:
        await battle_text_finished
    _refresh_battle_sprites()
    await _animate_visible_battle_hp(defender, int(defender.hp) if bool(result.get("hp_feedback_complete", false)) else defender_hp_before,
        int(defender.get("hp", 0)))
    if int(defender.hp) != defender_hp_before:
        await get_tree().create_timer(13.0 / 60.0).timeout
    await _animate_visible_battle_hp(attacker, attacker_hp_before,
        int(attacker.get("hp", 0)))
    if int(attacker.hp) != attacker_hp_before:
        await get_tree().create_timer(13.0 / 60.0).timeout
    _update_battle_hud()
    if not message_parts[1].is_empty():
        await _type_battle_text(message_parts[1])
    await _play_new_status_feedback(defender, bool(event.target_player_side),
        event.status_before, result)
    await get_tree().create_timer(0.08).timeout

## Burn, poison or a curse after a Pokemon's own action.
func _play_residual_event(event: Dictionary) -> void:
    var pokemon: Dictionary = event.pokemon
    var player_side := bool(event.player_side)
    var hp_before := int(event.hp_before)
    if not player_side and coop_game.active and coop_game.raids.active:await coop_game.raids.sync_damage(hp_before)
    var message := String(event.message)
    if message.is_empty(): return
    await _type_battle_text(message)
    await _play_poison_status_feedback(pokemon, player_side, hp_before, bool(event.poisoned))
    await _animate_visible_battle_hp(pokemon, hp_before, int(pokemon.hp))
    _update_battle_hud()
    await get_tree().create_timer(13.0 / 60.0).timeout

## A single battle's end of turn: residual damage, the weather, its message.
func _play_end_turn_event(event: Dictionary) -> void:
    var player_hp_before := int(event.player_hp_before)
    var enemy_hp_before := int(event.enemy_hp_before)
    if coop_game.active and coop_game.raids.active:await coop_game.raids.sync_damage(enemy_hp_before)
    if bool(event.weather_ended):
        _update_battle_field_visuals()
    await _play_poison_status_feedback(battle_player,true,player_hp_before,bool(event.player_poisoned))
    await _play_poison_status_feedback(battle_enemy,false,enemy_hp_before,bool(event.enemy_poisoned))
    await _animate_battle_hp_change(battle_player, player_hp_before,
        int(battle_player.get("hp", 0)), true)
    await _animate_battle_hp_change(battle_enemy, enemy_hp_before,
        int(battle_enemy.get("hp", 0)), false)
    _update_battle_hud()
    if not String(event.text).is_empty():
        await _type_battle_text(String(event.text))
        await get_tree().create_timer(0.125).timeout

## A caught Pokemon joins the party or storage; the Pokedex and caught list
## learn of it.
func _play_caught_event(event: Dictionary) -> void:
    var captured: Dictionary = event.pokemon
    if not caught_species.has(current_species):
        caught_species.append(current_species)
    if coop_game.active and coop_game.raids.active:coop_game.raids.normalize_capture(captured)
    pokedex_progress.mark(captured, true)
    var destination := _route_received_pokemon(captured)
    _play_source_battle_sound("catch_fanfare.ogg")
    await _type_battle_text("Caught %s!" % String(event.name))
    var notice := _received_pokemon_notice(captured, destination)
    if not notice.is_empty(): await _type_battle_text(notice)

var regigigas_special_running := false

## Mewtwo's psychic wave, or Regigigas's quake up to the moment it lands.
func _play_boss_special(event: Dictionary) -> void:
    await get_tree().create_timer(3.0 / 60.0).timeout
    if String(event.boss) == "mewtwo":
        await _type_battle_text("A wave of psychic power unleashes!")
        await source_mewtwo.play_special()
        return
    await _type_battle_text("The ground is shaking violently!")
    source_boss_move_type = String(event.move_type)
    var damage_due := [false]
    source_boss.special_damage_due.connect(func() -> void: damage_due[0] = true, CONNECT_ONE_SHOT)
    regigigas_special_running = true
    _run_regigigas_special()
    while not damage_due[0]:
        await get_tree().process_frame
    if not battle_active or int(battle_player.get("hp",0)) <= 0:
        return
    # Battle.java selects the impact cue using the preceding ordinary move's
    # type, but computes special damage using Ground (battle_session.gd).
    var scale := BattleEngine.effectiveness(source_boss_move_type,battle_player.types)
    var cue := "SUPER_EFFECTIVE" if scale>1.0 else "NOT_VERY_EFFECTIVE" if scale>0.0 and scale<1.0 else "NEUTRAL_EFFECTIVE"
    await _play_source_battle_feedback(cue,false,{})

func _run_regigigas_special() -> void:
    await source_boss.play_special()
    regigigas_special_running = false

## The HP a boss special took, then the rest of its animation.
func _play_special_damage(event: Dictionary) -> void:
    var pokemon: Dictionary = event.pokemon
    await _animate_visible_battle_hp(pokemon, int(event.hp_before), int(pokemon.hp))
    _update_battle_hud()
    if String(event.boss) == "regigigas":
        while regigigas_special_running:
            await get_tree().process_frame
        if is_instance_valid(source_boss):source_boss.set_palette_stage(0)
    await get_tree().create_timer(30.0/60.0).timeout

var silph_scope_fade: TextureRect
var silph_scope_started := 0

## The SILPH SCOPE's fade up to the moment the ghost is revealed
## (Battle.java: a 96-tick reveal alongside FadeAnim(slow=8), 144 ticks).
func _play_silph_scope_fade() -> void:
    source_effect_playing = true
    silph_scope_fade = TextureRect.new()
    silph_scope_fade.texture = preload("res://assets/events/source_fade.png")
    silph_scope_fade.position = Vector2.ZERO
    silph_scope_fade.size = Vector2(320, 180)
    silph_scope_fade.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
    silph_scope_fade.mouse_filter = Control.MOUSE_FILTER_IGNORE
    battle_panel.add_child(silph_scope_fade)
    silph_scope_started = preload("res://scripts/game_clock.gd").ticks_usec()
    await _play_silph_scope_frames(0, 96)

## The revealed Pokemon, the rest of the fade and its intro.
func _play_silph_scope_reveal() -> void:
    await _play_silph_scope_frames(96, 144)
    silph_scope_fade.queue_free()
    await _play_source_ghost_intro(false)
    source_effect_playing = false
    await get_tree().create_timer(3.0 * SOURCE_FRAME_TIME).timeout

func _play_silph_scope_frames(first: int, last: int) -> void:
    for frame in range(first, last):
        silph_scope_fade.modulate.a = (0.0 if frame < 16 else 0.25 if frame < 32 else
            0.5 if frame < 48 else 1.0 if frame < 96 else
            0.75 if frame < 112 else 0.5 if frame < 128 else 0.25)
        if frame == 96:
            pokedex_progress.mark(battle_enemy)
            _refresh_battle_sprites()
            _update_battle_hud()
        while preload("res://scripts/game_clock.gd").ticks_usec() - silph_scope_started < int((frame + 1) * 1000000.0 / 60.0):
            await get_tree().process_frame

func _open_battle_move_menu() -> void:
    var command_actor := _command_pokemon()
    if not battle_active or battle_turn_busy or command_actor.is_empty():
        return
    var forced := BattleEngine.forced_move(command_actor)
    if not forced.is_empty():
        _battle_fight()
        return
    var moves: Array = command_actor.get("moves", ["TACKLE"])
    if moves.is_empty():
        _battle_fight()
        return
    battle_move_index = clampi(battle_move_index, 0, mini(4, moves.size()) - 1)
    battle_ui_mode = "MOVE"
    var source_single := not battle_is_double
    source_command_frame.visible = false
    source_single_hud.visible = source_single
    source_command_cursor.visible = false
    enemy_hud.visible = not source_single
    player_hud.visible = not source_single
    battle_command_box.visible = false
    battle_actions.visible = false
    battle_actions.modulate = Color.WHITE
    battle_status.visible = false
    battle_message_arrow.visible = false
    battle_move_type_box.visible = true
    battle_move_box.visible = true
    _refresh_battle_move_menu()

func _handle_battle_move_input(event: InputEvent) -> void:
    if event.is_action_pressed("move_up") or event.is_action_pressed("move_left"):
        _move_battle_move(-1)
    elif event.is_action_pressed("move_down") or event.is_action_pressed("move_right"):
        _move_battle_move(1)
    elif event.is_action_pressed("shoulder_left"):
        _move_battle_move(-1)
    elif event.is_action_pressed("shoulder_right"):
        _move_battle_move(1)
    elif event.is_action_pressed("confirm"):
        _show_battle_message_screen()
        _battle_fight()
    elif event.is_action_pressed("cancel"):
        _show_battle_command_screen()
    else:
        return
    get_viewport().set_input_as_handled()

func _move_battle_move(direction: int) -> void:
    var moves: Array = _command_pokemon().get("moves", ["TACKLE"])
    var count := mini(4, moves.size())
    if count <= 0:
        return
    battle_move_index = wrapi(battle_move_index + direction, 0, count)
    _refresh_battle_move_menu()

func _refresh_battle_move_menu() -> void:
    var command_actor := _command_pokemon()
    var moves: Array = command_actor.get("moves", ["TACKLE"])
    var lines: Array[String] = []
    for index in range(4):
        if index < moves.size():
            lines.append(String(moves[index]).replace("_", " "))
        else:
            lines.append("-")
    battle_move_list.text = "\n".join(lines)
    battle_move_cursor.position.x = 12.0
    _align_menu_tick(battle_move_cursor, battle_move_list, battle_move_index)
    if moves.is_empty():
        battle_move_type.text = "NORMAL"
        battle_move_pp.text = "0/0"
        return
    var selected := String(moves[clampi(battle_move_index, 0, moves.size() - 1)])
    var move_data := PokemonData.move_info(selected)
    battle_move_type.text = String(move_data.get("type", "NORMAL"))
    var maximum_pp := int(move_data.get("pp", 0))
    var current_pp := int((command_actor.get("pp", {}) as Dictionary).get(selected, maximum_pp))
    battle_move_pp.text = "%d/%d" % [current_pp, maximum_pp]

func _move_battle_command(horizontal: int, vertical: int) -> void:
    if battle_turn_busy:
        return
    var column := battle_command_index % 2
    var row := int(battle_command_index / 2)
    if horizontal != 0:
        column = wrapi(column + horizontal, 0, 2)
    if vertical != 0:
        row = wrapi(row + vertical, 0, 2)
    battle_command_index = row * 2 + column
    _update_battle_command_cursor()

func _update_battle_command_cursor() -> void:
    if battle_command_cursor == null:
        return
    const CURSOR_POSITIONS = [
        Vector2(0, 1), Vector2(79, 1),
        Vector2(0, 24), Vector2(79, 24)
    ]
    battle_command_cursor.position = CURSOR_POSITIONS[battle_command_index]
    if battle_clean_command_cursor != null:
        var selected_button: Button = [fight_button, party_button,
            item_button, run_button][battle_command_index]
        var font_size: int = selected_button.get_theme_font_size("font_size")
        var command_width: float = JOHTO_FONT.get_string_size(
            selected_button.text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size).x
        var text_left: float = selected_button.position.x + (
            selected_button.size.x - command_width) * 0.5
        var gap: float = 2.0 if battle_command_index == 3 else 1.0
        battle_clean_command_cursor.position = Vector2(
            floorf(text_left - battle_clean_command_cursor.size.x - gap),
            roundf(selected_button.position.y +
                (selected_button.size.y - battle_clean_command_cursor.size.y) * 0.5 - 3.0)
        )
        battle_clean_command_cursor.visible = battle_actions.visible
    const SOURCE_CURSOR_POSITIONS = [
        Vector2(73, 112), Vector2(122, 112),
        Vector2(73, 128), Vector2(122, 128)
    ]
    source_command_cursor.position = SOURCE_CURSOR_POSITIONS[battle_command_index]

func _activate_battle_command() -> void:
    if battle_turn_busy:
        return
    if battle_is_double:
        match battle_command_index:
            0:
                _open_battle_move_menu()
            1:
                battle_double_replacement_slot = battle_double_command_slot
                _open_battle_party_menu("DOUBLE_SWITCH")
            2:
                _open_battle_item_menu()
            3:
                if is_instance_valid(coop_game.pvp) and coop_game.pvp.active:
                    _battle_run()
                else:
                    _start_battle_text("There is no running from this double battle!")
        return
    match battle_command_index:
        0:
            _open_battle_move_menu()
        1:
            _open_battle_party_menu("PARTY")
        2:
            _open_battle_item_menu()
        3:
            _battle_run()

func _cycle_battle_move(direction: int) -> void:
    var command_actor := _command_pokemon()
    if battle_turn_busy or command_actor.is_empty():
        return
    var forced := BattleEngine.forced_move(command_actor)
    if not forced.is_empty():
        _start_battle_text("%s is locked into %s." % [
            PokemonState.display_name(battle_player), forced.replace("_", " ")])
        return
    var moves: Array = command_actor.get("moves", ["TACKLE"])
    if moves.is_empty():
        return
    for attempt in range(moves.size()):
        battle_move_index = wrapi(battle_move_index + direction, 0, moves.size())
        if BattleEngine.move_is_usable(command_actor, String(moves[battle_move_index])):
            break
    var selected := String(moves[battle_move_index]).replace("_", " ")
    var pp_left := int((battle_player.get("pp", {}) as Dictionary).get(moves[battle_move_index], 0))
    _start_battle_text("%s  PP %d" % [selected, pp_left])

func _first_healthy_party_index() -> int:
    for index in range(caught_pokemon.size()):
        if (
                typeof(caught_pokemon[index]) == TYPE_DICTIONARY
                and bool((caught_pokemon[index] as Dictionary).get("is_egg", false))
            ):
            continue
        var candidate := BattleEngine.ensure_pokemon(caught_pokemon[index])
        caught_pokemon[index] = candidate
        if int(candidate.hp) > 0:
            return index
    return -1

func _battle_fight() -> void:
    if is_instance_valid(coop_game.pvp) and coop_game.pvp.active and not battle_is_double:
        if not battle_turn_busy:coop_game.pvp.submit({"kind":"move","move":_selected_player_move()})
        return
    if not battle_active or battle_turn_busy:
        return
    if battle_is_double:
        _queue_double_player_move()
        return
    battle_turn_busy = true
    _show_battle_message_screen()
    await _battle_play(battle_session.submit({"kind":"move", "move":_selected_player_move()}))

func _queue_double_player_move() -> void:
    var actor := _command_pokemon()
    if actor.is_empty() or int(actor.get("hp", 0)) <= 0:
        _advance_double_command_slot()
        return
    var move_name := _selected_player_move()
    if BattleEngine.move_targets_self(move_name):
        _store_double_player_action(move_name, battle_double_command_slot, "player")
        return
    if BattleEngine.move_targets_all(move_name):
        _store_double_player_action(move_name, -1)
        return
    battle_double_pending_move = move_name
    battle_submenu_mode = "DOUBLE_TARGET"
    battle_submenu_index = 0
    battle_submenu_entries.clear()
    for slot in range(2):
        var target := _double_actor("enemy", slot)
        if not target.is_empty() and int(target.get("hp", 0)) > 0:
            battle_submenu_entries.append({"target_slot":slot, "pokemon":target})
    if battle_submenu_entries.is_empty():
        _store_double_player_action(move_name, -1)
        return
    battle_submenu.visible = true
    _refresh_battle_submenu()

func _store_double_player_action(move_name: String, target_slot: int,
        target_side: String = "enemy") -> void:
    _close_battle_submenu()
    battle_double_actions.append({
        "side":"player", "slot":battle_double_command_slot,
        "move":move_name, "target_slot":target_slot,
        "target_side":target_side,
        "spread":BattleEngine.move_targets_all(move_name)
    })
    battle_double_pending_move = ""
    _advance_double_command_slot()

func _advance_double_command_slot() -> void:
    if battle_double_command_slot == 0 and not battle_player_partner.is_empty() and \
            int(battle_player_partner.get("hp", 0)) > 0:
        battle_double_command_slot = 1
        battle_move_index = 0
        _show_battle_command_screen()
        return
    if is_instance_valid(coop_game.pvp) and coop_game.pvp.active:
        coop_game.pvp.submit({"kind":"double", "actions":battle_double_actions.duplicate(true)})
        return
    battle_turn_busy = true
    _show_battle_message_screen()
    await _battle_play(battle_session.submit({"kind":"double", "actions":battle_double_actions.duplicate(true)}))

func _double_actor(side: String, slot: int) -> Dictionary:
    if side == "player":
        return battle_player if slot == 0 else battle_player_partner
    return battle_enemy if slot == 0 else battle_enemy_partner

var battle_exp_participants: Array[int] = []

func _check_reward_evolution(pokemon: Dictionary, party_index: int) -> void:
    var target := BattleEngine.evolution_target(pokemon, caught_pokemon, _world_source_time_of_day())
    if not target.is_empty():
        var was_active := progression_active
        var previous_actor := battle_player
        progression_active = true
        battle_player = pokemon
        await _run_evolution_sequence(pokemon, target, party_index)
        battle_player = previous_actor
        progression_active = was_active
        progression_mode = ""
        _refresh_battle_sprites()
        _update_battle_hud()

func _selected_player_move() -> String:
    var command_actor := _command_pokemon()
    var moves: Array = command_actor.get("moves", ["TACKLE"])
    if BattleEngine.forced_move(command_actor).is_empty() and not moves.is_empty():
        battle_move_index = clampi(battle_move_index, 0, moves.size() - 1)
    return BattleSession.chosen_move(command_actor, battle_move_index)

func _battle_catch() -> void:
    if not battle_active or battle_turn_busy:
        return
    if not bool(battle_context.get("can_catch", true)):
        if String(battle_context.get("kind", "")) == "trainer":
            _start_battle_text("You cannot catch another Trainer's POKEMON!")
        else:
            _start_battle_text("The POKEMON cannot be identified without the SILPH SCOPE.")
        return
    var ball := _best_available_ball()
    if ball.is_empty():
        _start_battle_text("You have no Poke Balls.")
        return
    await _battle_throw_ball(ball)

func _repeat_last_battle_ball() -> void:
    if not battle_active or battle_turn_busy or battle_ui_mode != "COMMAND":
        return
    if String(battle_context.get("kind", "")) == "trainer" or not bool(battle_context.get("can_catch", true)):
        return
    if last_battle_ball.is_empty():
        return
    if int(inventory.get(last_battle_ball, 0)) <= 0:
        return
    await _battle_throw_ball(last_battle_ball)

func _battle_throw_ball(ball: String) -> void:
    if not battle_active or battle_turn_busy or int(inventory.get(ball, 0)) <= 0:
        return
    if coop_game.active and coop_game.raids.active and await coop_game.raids.block_ball(ball):return
    if not bool(battle_context.get("can_catch", true)):
        _start_battle_text("You cannot throw a POKE BALL here.")
        return
    _close_battle_submenu()
    last_battle_ball = ball
    battle_turn_busy = true
    _show_battle_message_screen()
    # What a ball's odds read from the world, as it is thrown.
    await _battle_play(battle_session.submit({"kind":"ball", "ball":ball,
        "night":_world_source_time_of_day() == "night",
        "indoors":String(world.get("active_area_id")) != "OVERWORLD",
        "surfing":String(world.get("active_field_move")) == "SURF"}))

func _best_available_ball() -> String:
    for ball in ["QUICK BALL", "DREAM BALL", "DUSK BALL", "TIMER BALL",
            "NET BALL", "DIVE BALL", "LURE BALL", "LEVEL BALL", "LOVE BALL",
            "FAST BALL", "ULTRA BALL", "GREAT BALL", "HEAVY BALL",
            "NEST BALL", "HEAL BALL", "FRIEND BALL", "MOON BALL",
            "MASTER BALL", "PARK BALL", "POKE BALL"]:
        if int(inventory.get(ball, 0)) > 0:
            return ball
    return ""

func _battle_switch_next() -> void:
    _open_battle_party_menu("PARTY")

func _battle_use_healing_item() -> void:
    _open_battle_item_menu()

func _open_battle_item_menu(reset_selection: bool = true) -> void:
    if not battle_active or battle_turn_busy:
        return
    _close_battle_submenu()
    if reset_selection:
        battle_item_menu_index = 0
    if item_pocket_menu.get_parent() != battle_panel:
        item_pocket_menu.reparent(battle_panel, false)
    item_pocket_context = "BATTLE"
    battle_item_pocket_open = true
    battle_ui_mode = "ITEM_BAG"
    item_pocket_menu.visible = true
    _refresh_battle_item_pocket_menu()

func _refresh_battle_item_pocket_menu() -> void:
    battle_item_menu_names.clear()
    for raw_item_name in ItemData.items_for_pocket(battle_item_pocket_index):
        var item_name := String(raw_item_name)
        if planting_bag_target != null and item_pocket_context == "OVERWORLD":
            if not bag_menu.planting_bag_item_allowed(item_name): continue
        if int(inventory.get(item_name, 0)) > 0:
            battle_item_menu_names.append(item_name)

    battle_item_menu_index = clampi(battle_item_menu_index, 0,
        battle_item_menu_names.size())
    var label_atlas := AtlasTexture.new()
    label_atlas.atlas = ITEM_BAG_POCKET_TEXTURE
    label_atlas.region = Rect2(battle_item_pocket_index * 41, 0, 41, 24)
    item_pocket_label.texture = label_atlas
    var bag_atlas := AtlasTexture.new()
    bag_atlas.atlas = ITEM_BAG_POCKET_TEXTURE
    bag_atlas.region = Rect2(battle_item_pocket_index * 41, 24, 41, 26)
    item_pocket_bag.texture = bag_atlas

    var entries: Array[String] = battle_item_menu_names.duplicate()
    entries.append("CANCEL")
    var page_start := (
        int(battle_item_menu_index / ITEM_MENU_VISIBLE_ROWS) * ITEM_MENU_VISIBLE_ROWS
    )
    var page_end := mini(page_start + ITEM_MENU_VISIBLE_ROWS, entries.size())
    var item_lines: Array[String] = []
    var quantity_lines: Array[String] = []
    for index in range(page_start, page_end):
        var entry: String = entries[index]
        item_lines.append(entry)
        quantity_lines.append("" if entry == "CANCEL" else
            "x %d" % int(inventory.get(entry, 0)))
    item_pocket_list.text = "\n".join(item_lines)
    item_pocket_quantities.text = "\n".join(quantity_lines)
    var item_font_size := item_pocket_list.get_theme_font_size("font_size")
    var item_pitch := JOHTO_FONT.get_height(item_font_size) + float(
        item_pocket_list.get_theme_constant("line_spacing"))
    # Match the arrow's top to the selected word's actual ink line instead of
    # carrying over the old scaled-background magic number.
    item_pocket_cursor.position.y = roundf(
        item_pocket_list.position.y
        + float(battle_item_menu_index - page_start) * item_pitch
    )
    var selected_name := String(battle_item_menu_names[battle_item_menu_index])         if battle_item_menu_index < battle_item_menu_names.size() else ""
    if selected_name != bag_notice_item: bag_notice = ""
    if not bag_notice.is_empty():
        item_pocket_description.text = bag_notice
    elif not selected_name.is_empty():
        item_pocket_description.text = ItemData.description(selected_name)
    else:
        item_pocket_description.text = ""

func _switch_battle_item_pocket(direction: int) -> void:
    battle_item_pocket_index = wrapi(battle_item_pocket_index + direction, 0,
        ItemData.POCKET_COUNT)
    battle_item_menu_index = 0
    _refresh_battle_item_pocket_menu()

func _close_battle_item_pocket_menu(return_to_command: bool = true) -> void:
    battle_item_pocket_open = false
    item_pocket_context = ""
    item_pocket_menu.visible = false
    if return_to_command and battle_active:
        _show_battle_command_screen()

func _handle_battle_item_pocket_input(event: InputEvent) -> void:
    if event.is_action_pressed("cancel") or event.is_action_pressed("start"):
        _close_battle_item_pocket_menu()
    elif (event.is_action_pressed("move_left") or
            event.is_action_pressed("shoulder_left")):
        _switch_battle_item_pocket(-1)
    elif (event.is_action_pressed("move_right") or
            event.is_action_pressed("shoulder_right")):
        _switch_battle_item_pocket(1)
    elif event.is_action_pressed("move_up"):
        battle_item_menu_index = wrapi(battle_item_menu_index - 1, 0,
            battle_item_menu_names.size() + 1)
        _refresh_battle_item_pocket_menu()
    elif event.is_action_pressed("move_down"):
        battle_item_menu_index = wrapi(battle_item_menu_index + 1, 0,
            battle_item_menu_names.size() + 1)
        _refresh_battle_item_pocket_menu()
    elif event.is_action_pressed("confirm"):
        _confirm_battle_item_pocket()
    else:
        return
    get_viewport().set_input_as_handled()

func _confirm_battle_item_pocket() -> void:
    if battle_item_menu_index >= battle_item_menu_names.size():
        _close_battle_item_pocket_menu()
        return
    var item_name: String = battle_item_menu_names[battle_item_menu_index]
    if BATTLE_BALL_BONUS.has(item_name):
        _close_battle_item_pocket_menu(false)
        await _battle_throw_ball(item_name)
        return
    if BATTLE_ITEM_RULES.has(item_name):
        battle_pending_item = item_name
        _close_battle_item_pocket_menu(false)
        _open_battle_party_menu("ITEM_TARGET")
        return
    if item_name == "SILPH SCOPE":
        if not bool(battle_enemy.get("is_ghost", false)):
            item_pocket_description.text = "It won't have any effect in battle."
            return
        _close_battle_item_pocket_menu(false)
        await _battle_use_silph_scope()
        return
    if item_name == "POKE DOLL":
        _close_battle_item_pocket_menu(false)
        await _battle_use_poke_doll()
        return
    item_pocket_description.text = "It won't have any effect in battle."

func _battle_use_silph_scope() -> void:
    if not battle_active or battle_turn_busy or int(inventory.get("SILPH SCOPE", 0)) <= 0 or not bool(battle_enemy.get("is_ghost", false)):
        return
    battle_turn_busy = true
    _show_battle_message_screen()
    await _battle_play(battle_session.submit({"kind":"silph_scope"}))

func _play_source_ghost_intro(hidden: bool) -> void:
    var timelines: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(
        "res://data/source_ghost_intro.json"))
    var species := "ghost" if hidden else String(battle_enemy.species)
    var frames: Array = timelines.get(species, [])
    var texture: Texture2D = GHOST_BATTLE_SHEET if hidden else load("res://assets/events/ghost_intros/%s%s.png" % [species, "-shiny" if PokemonData.is_shiny(battle_enemy) else ""])
    if not GameOptions.enabled("battle_animations"):
        enemy_sprite.texture = _battle_sprite_frame(texture)
        _play_pokemon_cry(battle_enemy)
        return
    var started := preload("res://scripts/game_clock.gd").ticks_usec()
    for tick in range(frames.size()):
        if tick == 4: _play_pokemon_cry(battle_enemy)
        # Ghost frame 4 is intentionally beyond the four-frame source sheet:
        # it is the blank part of the source flicker, not wrapped frame zero.
        enemy_sprite.texture = (_battle_sprite_frame_at(texture, int(frames[tick]))
            if int(frames[tick]) < _battle_sprite_frame_count(texture) else null)
        while preload("res://scripts/game_clock.gd").ticks_usec() - started < int((tick + 1) * 1000000.0 / 60.0):
            await get_tree().process_frame
    enemy_sprite.texture = _battle_sprite_frame(texture)

func _battle_use_poke_doll() -> void:
    if (not battle_active or battle_turn_busy or
            int(inventory.get("POKE DOLL", 0)) <= 0):
        return
    if not bool(battle_context.get("can_run", true)):
        _start_battle_text("The POKE DOLL cannot end this battle.")
        return
    battle_turn_busy = true
    _show_battle_message_screen()
    await _battle_play(battle_session.submit({"kind":"poke_doll"}))

func _open_battle_party_menu(mode: String) -> void:
    if not battle_active:
        return
    if battle_turn_busy and mode not in ["FORCED", "BATON_PASS", "DOUBLE_FORCED"]:
        return
    battle_submenu_entries.clear()
    for index in range(mini(6, caught_pokemon.size())):
        var pokemon := BattleEngine.ensure_pokemon(caught_pokemon[index])
        caught_pokemon[index] = pokemon
        battle_submenu_entries.append({"index":index, "pokemon":pokemon})
    if battle_submenu_entries.is_empty():
        _start_battle_text("Your party is empty.")
        return
    battle_submenu_mode = mode
    battle_party_action_open = false
    battle_party_action_panel.visible = false
    battle_submenu_index = clampi(battle_party_index, 0, battle_submenu_entries.size() - 1)
    if mode in ["FORCED", "BATON_PASS", "DOUBLE_FORCED"] and \
            battle_submenu_index in [battle_party_index, battle_partner_party_index]:
        for entry_index in range(battle_submenu_entries.size()):
            var candidate: Dictionary = battle_submenu_entries[entry_index].pokemon
            if (
                    entry_index not in [battle_party_index, battle_partner_party_index]
                    and int(candidate.hp) > 0
                    and not bool(candidate.get("is_egg", false))
                ):
                battle_submenu_index = entry_index
                break
    battle_submenu.visible = true
    _refresh_battle_submenu()

func _handle_battle_submenu_input(event: InputEvent) -> void:
    if battle_submenu_entries.is_empty():
        _close_battle_submenu()
        return
    if battle_party_action_open:
        if event.is_action_pressed("move_up"):
            battle_party_action_index = wrapi(battle_party_action_index - 1, 0,
                battle_party_action_entries.size())
            _refresh_battle_party_action_menu()
        elif event.is_action_pressed("move_down"):
            battle_party_action_index = wrapi(battle_party_action_index + 1, 0,
                battle_party_action_entries.size())
            _refresh_battle_party_action_menu()
        elif event.is_action_pressed("confirm"):
            _activate_battle_party_action()
        elif event.is_action_pressed("cancel") or event.is_action_pressed("start"):
            battle_party_action_open = false
            battle_party_action_panel.visible = false
        else:
            return
        get_viewport().set_input_as_handled()
        return
    if event.is_action_pressed("move_up"):
        battle_submenu_index = wrapi(battle_submenu_index - 1, 0, battle_submenu_entries.size())
        _refresh_battle_submenu()
    elif event.is_action_pressed("move_down"):
        battle_submenu_index = wrapi(battle_submenu_index + 1, 0, battle_submenu_entries.size())
        _refresh_battle_submenu()
    elif event.is_action_pressed("move_left"):
        battle_submenu_index = maxi(0, battle_submenu_index - 6)
        _refresh_battle_submenu()
    elif event.is_action_pressed("move_right"):
        battle_submenu_index = mini(battle_submenu_entries.size() - 1,
            battle_submenu_index + 6)
        _refresh_battle_submenu()
    elif event.is_action_pressed("confirm"):
        _confirm_battle_submenu()
    elif event.is_action_pressed("cancel"):
        if battle_submenu_mode in ["FORCED", "BATON_PASS", "DOUBLE_FORCED"]:
            _start_battle_text("Choose a Pokemon able to battle.")
        elif battle_submenu_mode == "ITEM_TARGET":
            _close_battle_submenu()
            _open_battle_item_menu(false)
        elif battle_submenu_mode == "DOUBLE_TARGET":
            _close_battle_submenu()
            battle_double_pending_move = ""
            _open_battle_move_menu()
        else:
            _close_battle_submenu()
    else:
        return
    get_viewport().set_input_as_handled()

func _confirm_battle_submenu() -> void:
    if battle_submenu_entries.is_empty() or battle_turn_busy and battle_submenu_mode not in [
            "FORCED", "BATON_PASS", "DOUBLE_FORCED"]:
        return
    var entry: Dictionary = battle_submenu_entries[battle_submenu_index]
    if battle_submenu_mode == "DOUBLE_TARGET":
        _store_double_player_action(battle_double_pending_move,
            int(entry.get("target_slot", 0)))
        return
    if battle_submenu_mode == "ITEM":
        var item_name := String(entry.name)
        if String(entry.kind) == "ball":
            await _battle_throw_ball(item_name)
        else:
            battle_pending_item = item_name
            _open_battle_party_menu("ITEM_TARGET")
        return
    var party_index := int(entry.index)
    if battle_submenu_mode == "ITEM_TARGET":
        if not _can_use_battle_item_on(battle_pending_item, party_index):
            return
        await _use_battle_item_on(battle_pending_item, party_index)
        return
    if bool((entry.pokemon as Dictionary).get("is_egg", false)):
        _start_battle_text("An EGG cannot battle.")
        return
    if battle_submenu_mode == "PARTY":
        _open_battle_party_action_menu()
        return
    if party_index in [battle_party_index, battle_partner_party_index] or \
            int((entry.pokemon as Dictionary).hp) <= 0:
        battle_party_action_open = false
        battle_party_action_panel.visible = false
        battle_party_prompt.text = "Choose another Pokemon able to battle."
        return
    if battle_submenu_mode == "DOUBLE_SWITCH":
        var switching_actor := _command_pokemon()
        if int(switching_actor.volatile.get("trap_turns", 0)) > 0 or \
                bool(switching_actor.volatile.get("mean_look", false)):
            _start_battle_text("%s cannot switch out!" % PokemonState.display_name(switching_actor))
            return
        _close_battle_submenu()
        battle_double_actions.append({
            "kind":"switch", "side":"player", "slot":battle_double_command_slot,
            "switch_index":party_index, "move":"", "target_slot":-1,
            "spread":false
        })
        _advance_double_command_slot()
        return
    var forced_slot := battle_double_replacement_slot if battle_submenu_mode == "DOUBLE_FORCED" else -1
    _close_battle_submenu()
    if is_instance_valid(coop_game.pvp) and coop_game.pvp.active:
        var switch := {"kind":"switch","index":party_index}
        if forced_slot >= 0: switch["slot"] = forced_slot
        coop_game.pvp.submit(switch)
        return
    battle_party_chosen.emit(party_index)

func _refresh_battle_submenu() -> void:
    if battle_submenu_entries.is_empty():
        return
    var uses_party_view := battle_submenu_mode not in ["ITEM", "DOUBLE_TARGET"]
    battle_party_view.visible = uses_party_view
    $UI/BattlePanel/BattleSubmenu/Dim.visible = not uses_party_view
    $UI/BattlePanel/BattleSubmenu/Window.visible = not uses_party_view
    if uses_party_view:
        _refresh_battle_party_view()
        return
    var page_start := int(battle_submenu_index / 6) * 6
    var page_end := mini(page_start + 6, battle_submenu_entries.size())
    var lines: Array[String] = []
    for index in range(page_start, page_end):
        var entry: Dictionary = battle_submenu_entries[index]
        if battle_submenu_mode == "DOUBLE_TARGET":
            var target: Dictionary = entry.pokemon
            lines.append("%-12s L%02d  HP %3d/%3d" % [
                BattleEngine.display_name(target).left(12), int(target.level),
                int(target.hp), int(target.max_hp)])
        elif battle_submenu_mode == "ITEM":
            lines.append("%-18s x%d" % [String(entry.name), int(inventory.get(String(entry.name), 0))])
        else:
            var pokemon: Dictionary = entry.pokemon
            if bool(pokemon.get("is_egg", false)):
                lines.append("EGG        --  ---/---")
                continue
            var active := " ACTIVE" if int(entry.index) == battle_party_index else ""
            var status := String(pokemon.get("status", ""))
            if not status.is_empty():
                status = " " + status.left(3)
            lines.append("%-10s L%02d %3d/%3d%s%s" % [
                PokemonState.display_name(pokemon).left(10), int(pokemon.level),
                int(pokemon.hp), int(pokemon.max_hp), status, active])
    battle_submenu_list.text = "\n".join(lines)
    _align_menu_tick(battle_submenu_cursor, battle_submenu_list, battle_submenu_index - page_start)
    if battle_submenu_mode == "DOUBLE_TARGET":
        battle_submenu_title.text = "CHOOSE A TARGET"
        battle_submenu_hint.text = "A TARGET   B MOVES"
    elif battle_submenu_mode == "ITEM":
        battle_submenu_title.text = "BATTLE ITEMS  %d/%d" % [battle_submenu_index + 1, battle_submenu_entries.size()]
        battle_submenu_hint.text = "A USE   B BACK   LEFT/RIGHT PAGE"
    elif battle_submenu_mode == "ITEM_TARGET":
        battle_submenu_title.text = "%s: CHOOSE TARGET" % battle_pending_item
        battle_submenu_hint.text = "A USE   B ITEMS"
    elif battle_submenu_mode == "BATON_PASS":
        battle_submenu_title.text = "BATON PASS: CHOOSE POKEMON"
        battle_submenu_hint.text = "A SELECT"
    elif battle_submenu_mode == "FORCED":
        battle_submenu_title.text = "CHOOSE NEXT POKEMON"
        battle_submenu_hint.text = "A SELECT"
    elif battle_submenu_mode == "DOUBLE_FORCED":
        battle_submenu_title.text = "REPLACE FAINTED POKEMON"
        battle_submenu_hint.text = "A SELECT"
    elif battle_submenu_mode == "DOUBLE_SWITCH":
        battle_submenu_title.text = "SWITCH ACTIVE POKEMON"
        battle_submenu_hint.text = "A SWITCH   B BACK"
    else:
        battle_submenu_title.text = "POKEMON  %d/%d" % [battle_submenu_index + 1, battle_submenu_entries.size()]
        battle_submenu_hint.text = "A SWITCH   B BACK   LEFT/RIGHT PAGE"

func _close_battle_submenu() -> void:
    battle_submenu_mode = ""
    battle_submenu_entries.clear()
    battle_party_action_open = false
    battle_party_action_panel.visible = false
    battle_party_view.visible = false
    $UI/BattlePanel/BattleSubmenu/Dim.visible = true
    $UI/BattlePanel/BattleSubmenu/Window.visible = true
    battle_submenu.visible = false

func _refresh_battle_party_view() -> void:
    if battle_submenu_entries.is_empty():
        return
    battle_submenu_index = clampi(battle_submenu_index, 0,
        battle_submenu_entries.size() - 1)
    var visible_party: Array = []
    for entry in battle_submenu_entries:
        visible_party.append((entry as Dictionary).pokemon)
    party_menu.refresh_party_list_rows(battle_party_rows, visible_party,
        battle_submenu_index)
    battle_party_prompt.text = {
        "ITEM_TARGET":"Use %s on which POKEMON?" % battle_pending_item,
        "FORCED":"Choose next POKEMON.",
        "BATON_PASS":"Choose a POKEMON.",
        "DOUBLE_FORCED":"Choose a replacement.",
        "DOUBLE_SWITCH":"Switch which POKEMON?"
    }.get(battle_submenu_mode, "Choose a POKEMON.")

func _open_battle_party_action_menu() -> void:
    var pokemon := battle_submenu_entries[battle_submenu_index].pokemon as Dictionary
    battle_party_action_entries = party_menu.pokemon_world_actions(
        String(pokemon.get("species", "")), pokemon)
    battle_party_action_index = 0
    battle_party_action_open = true
    battle_party_action_panel.visible = true
    _refresh_battle_party_action_menu()

func _refresh_battle_party_action_menu() -> void:
    battle_party_action_index = wrapi(battle_party_action_index, 0,
        battle_party_action_entries.size())
    party_menu.refresh_source_action_rows(battle_party_action_list, battle_party_action_cursor,
        battle_party_action_entries, battle_party_action_index)

func _activate_battle_party_action() -> void:
    var action := String(battle_party_action_entries[battle_party_action_index])
    var entry := battle_submenu_entries[battle_submenu_index]
    if action == "CANCEL":
        battle_party_action_open = false
        battle_party_action_panel.visible = false
        return
    if action == "STATS":
        battle_party_action_open = false
        battle_party_action_panel.visible = false
        party_menu.open_pokemon_stats(entry.pokemon as Dictionary, "BATTLE")
        return
    if action == "SWITCH":
        await _switch_from_battle_party_action(int(entry.index))
        return
    battle_party_action_open = false
    battle_party_action_panel.visible = false
    battle_party_prompt.text = "That action cannot be used during battle."

func _switch_from_battle_party_action(party_index: int) -> void:
    if is_instance_valid(coop_game.pvp) and coop_game.pvp.active and not battle_is_double:
        coop_game.pvp.submit({"kind":"switch","index":party_index})
        return
    if party_index in [battle_party_index, battle_partner_party_index] or \
            int((battle_submenu_entries[battle_submenu_index].pokemon as Dictionary).hp) <= 0:
        battle_party_action_open = false
        battle_party_action_panel.visible = false
        battle_party_prompt.text = "Choose another Pokemon able to battle."
        return
    if int(battle_player.volatile.get("trap_turns", 0)) > 0 or \
            bool(battle_player.volatile.get("mean_look", false)):
        battle_party_action_open = false
        battle_party_action_panel.visible = false
        battle_party_prompt.text = "%s cannot switch out!" % PokemonState.display_name(battle_player)
        return
    _close_battle_submenu()
    if is_instance_valid(coop_game.pvp) and coop_game.pvp.active:
        _queue_pvp_double_choice({"kind":"switch", "switch_index":party_index})
        return
    battle_turn_busy = true
    await _battle_play(battle_session.submit({"kind":"switch", "index":party_index}))

## A PvP double battle's switch or item: the commanded slot's choice for the
## turn (the host checks it with the rest).
func _queue_pvp_double_choice(choice: Dictionary) -> void:
    choice.merge({"side":"player", "slot":battle_double_command_slot, "move":"", "target_slot":-1, "spread":false})
    battle_double_actions.append(choice)
    _advance_double_command_slot()

func _can_use_battle_item_on(item_name: String, party_index: int) -> bool:
    var pokemon := BattleEngine.ensure_pokemon(caught_pokemon[party_index])
    caught_pokemon[party_index] = pokemon
    var refusal := BattleSession.pokemon_item_refusal(pokemon, item_name)
    if refusal.is_empty():
        return true
    if refusal != "-":
        _start_battle_text(refusal)
    return false

func _use_battle_item_on(item_name: String, party_index: int) -> void:
    if is_instance_valid(coop_game.pvp) and coop_game.pvp.active:
        if not battle_is_double:
            coop_game.pvp.submit({"kind":"item","item":item_name,"index":party_index})
            return
        battle_pending_item = ""
        _close_battle_submenu()
        _queue_pvp_double_choice({"kind":"use_item", "item":item_name, "index":party_index})
        return
    battle_pending_item = ""
    _close_battle_submenu()
    battle_turn_busy = true
    _show_battle_message_screen()
    await _battle_play(battle_session.submit({"kind":"item", "item":item_name, "index":party_index}))
    if battle_is_double and battle_active:
        # In a double battle an item takes its Pokemon's place in the turn.
        battle_turn_busy = false
        _advance_double_command_slot()

func _battle_run() -> void:
    if is_instance_valid(coop_game.pvp) and coop_game.pvp.active:
        coop_game.pvp.submit({"kind":"run"})
        return
    if not battle_active or battle_turn_busy:
        return
    var refusal := battle_session.refusal({"kind":"run"})
    if not refusal.is_empty():
        _start_battle_text(refusal)
        return
    battle_turn_busy = true
    _show_battle_message_screen()
    await _battle_play(battle_session.submit({"kind":"run"}))

func _end_battle(outcome: String = "") -> void:
    var ending_pvp=is_instance_valid(coop_game.pvp) and coop_game.pvp.active
    var ending_raid=coop_game.active and coop_game.raids.active
    var ending_population=coop_game.active and not coop_game.population_battles.claim.is_empty()
    var ending_event=coop_game.active and coop_game.events.active
    if ending_pvp:outcome=""
    if battle_session != null and battle_session.running and not battle_session.finished:
        battle_session.abandon()
    battle_ended.emit(outcome)
    if is_instance_valid(source_boss):
        source_boss.set_palette_stage(0)
        source_boss.queue_free()
        source_boss=null
    if is_instance_valid(source_mewtwo):
        source_mewtwo.queue_free()
        source_mewtwo = null
    player_battle_sprite.modulate = Color.WHITE
    if world.roaming_ghosts != null and String(battle_context.get("id", "")).begins_with("roaming_ghost_"):
        world.roaming_ghosts.complete(String(battle_context.id), outcome, battle_enemy)
    if world.source_night_events != null and String(battle_context.get("id", "")).begins_with("source_night_"):
        world.source_night_events.complete(outcome)
    var ended_wild_battle := String(battle_context.get("kind", "")) == "wild"
    if not outcome.is_empty() and not battle_result_sent:
        battle_result_sent = true
        if not ending_raid and not ending_population and not ending_event and world.has_method("complete_battle_event"):
            world.call("complete_battle_event", {
                "outcome": outcome,
                "context": battle_context.duplicate(true),
                "mine_pokemon": battle_enemy.duplicate(true) if battle_context.has("mine_pokemon_id") else {}
            })
    battle_active = false
    battle_turn_busy = false
    battle_text_busy = false
    battle_text_accumulator = 0.0
    battle_status.visible_characters = -1
    battle_ui_mode = "INTRO"
    _close_battle_submenu()
    battle_pending_item = ""
    battle_item_pocket_open = false
    item_pocket_context = ""
    battle_item_menu_names.clear()
    battle_item_menu_index = 0
    item_pocket_menu.visible = false
    battle_audio.stop()
    _release_cry_requests()
    battle_move_animation.texture = null
    _clear_battle_capture_ball()
    for index in range(caught_pokemon.size()):
        if typeof(caught_pokemon[index]) == TYPE_DICTIONARY:
            BattleEngine.reset_battle_state(caught_pokemon[index])
            caught_pokemon[index].erase("_double_faint_announced")
            caught_pokemon[index].erase("_double_faint_processed")
    # These battle dictionaries are also stored in the party arrays. Replacing
    # the references preserves those party records; clear() erased Machop and
    # made ensure_pokemon rebuild the empty entry as its Rattata fallback.
    battle_player = {}
    battle_enemy = {}
    battle_player_partner = {}
    battle_enemy_partner = {}
    battle_context = {}
    battle_enemy_party.clear()
    battle_enemy_party_index = 0
    battle_is_double = false
    battle_partner_party_index = -1
    battle_enemy_partner_party_index = -1
    battle_double_command_slot = 0
    battle_double_actions.clear()
    battle_double_pending_move = ""
    battle_double_replacement_slot = -1
    player_partner_sprite.visible = false
    enemy_partner_sprite.visible = false
    double_status.visible = false
    _set_double_battle_layout()
    battle_field.clear()
    battle_panel.visible = false
    if world.has_method("set_environment_battle_active"):
        world.call("set_environment_battle_active", false)
    if coop_game.active and not coop_game.wild.encounter.is_empty():
        if not await coop_game.wild.finish_encounter(outcome):return
    if ending_raid:
        if not await coop_game.raids.finish(outcome):return
    if ending_population:
        if not await coop_game.population_battles.finish(outcome):return
    if ending_event:
        if not await coop_game.events.finish(outcome):return
    if outcome == "whiteout" and world.has_method("respawn_after_whiteout"):
        _ensure_machop_lead(true)
        world.call("clear_active_field_move", false)
        if is_instance_valid(coop_game) and coop_game.active:
            if not await coop_game.rest.before_whiteout():return
        world.call("respawn_after_whiteout")
        world.player.velocity=Vector2.ZERO
        world.player.camera.reset_smoothing()
        if coop_game.active:await coop_game.checkpoint_player()
        dialogs.show_message("You are being returned to the last safe place!")
    world.set_gameplay_enabled(true)
    if ended_wild_battle and world.has_method("begin_encounter_grace"):
        world.call("begin_encounter_grace")
    if ending_pvp:coop_game.pvp.restore()

func _exit_tree() -> void:
    var _joined := battle_animation_manifest # a thread must be waited for
    if save_thread != null:
        save_thread.wait_to_finish() # the save lands before the game goes
    saves.wait_for_cache_cleanup()

func _load_battle_animation_manifest() -> Dictionary:
    const MANIFEST_PATH = "res://assets/battle_animations/manifest.json"
    if not FileAccess.file_exists(MANIFEST_PATH):
        return {}
    var file = FileAccess.open(MANIFEST_PATH, FileAccess.READ)
    if file == null:
        return {}
    var parsed = JSON.parse_string(file.get_as_text())
    if typeof(parsed) != TYPE_DICTIONARY:
        return {}
    # The base64 text costs 4 bytes per character as a String, the bytes 1.
    for animation in (parsed.get("animations", {}) as Dictionary).values():
        animation["frame_table"] = Marshalls.base64_to_raw(String(animation.get("frame_table", "")))
    return parsed

func _play_status_on_pokemon(animation: String, pokemon: Dictionary, player_side: bool) -> void:
    # Source LoadAndPlayAnimation selects enemy_gsc for the player's Pokemon:
    # sheet names describe the attacking side, not the status owner.
    var original_position := battle_move_animation.position
    if battle_is_double:
        if player_side and is_same(pokemon, battle_player_partner):
            battle_move_animation.position += player_partner_sprite.position-player_battle_sprite.position
        elif not player_side and is_same(pokemon, battle_enemy_partner):
            battle_move_animation.position += enemy_partner_sprite.position-enemy_sprite.position
    await _play_battle_feedback(animation, not player_side, {"damage":0})
    battle_move_animation.position = original_position

func _play_new_status_feedback(pokemon: Dictionary, player_side: bool,
        before: Dictionary, result: Dictionary) -> void:
    if int(pokemon.get("hp", 0)) <= 0 or not bool(result.get("executed", false)):
        return
    for status in BattleSession.new_statuses(before, BattleSession.status_snapshot(pokemon)):
        # Battle.getAttackAction: hit effects wait 49 frames, then the status
        # animation (except sleep/poison/attract), 30 frames, then the message.
        if int(result.get("damage", 0)) > 0:
            await get_tree().create_timer(49.0 / 60.0).timeout
        var animation := String({"BURN":"status_burn", "FREEZE":"status_freeze",
            "PARALYSIS":"status_paralyze", "CONFUSION":"status_confuse"}.get(status, ""))
        if not animation.is_empty():
            await _play_status_on_pokemon(animation, pokemon, player_side)
        await get_tree().create_timer(30.0 / 60.0).timeout
        var description := String(BattleSession.STATUS_TEXT.get(status, ""))
        if not description.is_empty():
            await _type_battle_text("%s %s" % [BattleEngine.display_name(pokemon), description])

func _play_poison_status_feedback(pokemon: Dictionary, player_side: bool,
        hp_before: int, poisoned_before: bool) -> void:
    if poisoned_before and int(pokemon.get("hp",0))<hp_before and             String(pokemon.get("ability","")) not in ["POISON HEAL","MAGIC GUARD"]:
        await _play_status_on_pokemon("status_poison",pokemon,player_side)

func _play_blocked_status_feedback(attacker: Dictionary, player_side: bool,
        message: String) -> void:
    var status: String = String(attacker.get("status", "")).to_upper()
    var lower_message: String = message.to_lower()
    if status == "SLEEP" and "asleep" in lower_message:
        await _play_status_on_pokemon("status_sleep", attacker, player_side)
    elif "confused" in lower_message or "confusion" in lower_message:
        await _play_status_on_pokemon("status_confuse", attacker, player_side)
    elif status == "PARALYSIS" and "paralyzed" in lower_message:
        await _play_status_on_pokemon("status_paralyze", attacker, player_side)

func _play_battle_feedback(move_name: String, player_attacks: bool,
        result: Dictionary, target: Dictionary = {}) -> void:
    var normalized := move_name.to_lower().replace(" ", "_")
    var hits := maxi(1,int(result.get("hits",1)))
    var shown_hp := int(result.get("defender_hp_before", 0))
    var show_each_hit := hits > 1 and not target.is_empty() and not bool(result.get("hit_substitute", false))
    var alternating := normalized in ["double_kick","doubleslap","fury_swipes"]
    for hit in range(hits):
        var frame_move := normalized + ("_left" if hit % 2 == 0 else "_right") if alternating else normalized
        await _play_source_battle_feedback(frame_move,player_attacks,result)
        var last_hit := hit == hits - 1
        # Java places effectiveness before the final HP change, not after it.
        if last_hit and int(result.get("damage",0)) > 0 and normalized not in ["neutral_effective","super_effective","not_very_effective"]:
            var effectiveness := float(result.get("effectiveness",1.0))
            var hit_name := "super_effective" if effectiveness>1.0 else "not_very_effective" if effectiveness<1.0 else "neutral_effective"
            await _play_source_battle_feedback(hit_name,player_attacks,{"damage":0})
        if show_each_hit:
            # Endure, Sturdy and Disguise may reduce the final applied damage.
            # Never animate past the HP that the mechanics actually retained.
            var next_hp := maxi(int(target.get("hp", 0)), shown_hp-int(result.hit_damages[hit]))
            await _animate_visible_battle_hp(target, shown_hp, next_hp)
            shown_hp = next_hp
        if not last_hit:
            await get_tree().create_timer(43.0/60.0).timeout
            var critical_hits: Array = result.get("hit_criticals", [])
            if hit < critical_hits.size() and bool(critical_hits[hit]):
                await _type_battle_text("Critical hit!")
    if show_each_hit: result["hp_feedback_complete"] = true

func _play_source_battle_feedback(move_name: String, player_attacks: bool,
        result: Dictionary) -> void:
    if not GameOptions.enabled("battle_animations"):
        return
    var procedural_key := move_name.to_upper().replace(" ","_")
    if procedural_key=="CRUSH_GRIP" or (is_instance_valid(source_boss) and source_boss.kind=="mega_gengar" and not player_attacks and procedural_key in ["SHADOW_CLAW","NIGHT_SHADE","LICK"]):
        var procedural := preload("res://scripts/source_procedural_attack.gd").new()
        battle_panel.add_child(procedural)
        procedural.setup(self,procedural_key,player_attacks)
        source_effect_playing=true
        await procedural.play()
        procedural.queue_free()
        source_effect_playing=false
        if is_instance_valid(source_boss):enemy_sprite.texture=source_boss.body
        return
    var normalized := move_name.to_lower().replace(" ", "_")
    var source_key := _battle_source_key(normalized,
        "player" if player_attacks else "enemy")
    var audio_entries: Dictionary = battle_animation_manifest.get("audio", {})
    var audio_path := String(audio_entries.get(source_key,
        audio_entries.get(normalized, "")))
    if not audio_path.is_empty() and ResourceLoader.exists(audio_path):
        battle_audio.stream = load(audio_path) as AudioStream
        AudioBalance.apply(battle_audio)
        battle_audio.play()

    var animations: Dictionary = battle_animation_manifest.get("animations", {})
    var animation: Dictionary = animations.get(source_key, {})
    # Status moves without authored source frames intentionally have no made-up
    # lunge/pulse. Only the source animation library is rendered here.
    if animation.is_empty():
        return
    var frames := int(animation.get("frames", 0))
    var visual_end_frame := int(animation.get("visual_end_frame", frames - 1))
    frames = mini(frames, visual_end_frame + 1)
    var frame_time := float(animation.get("frame_time", 1.0 / 60.0))
    var player_origin := player_battle_sprite.position
    var enemy_origin := enemy_sprite.position
    var animation_origin := battle_move_animation.position
    var player_scale := player_battle_sprite.scale
    var enemy_scale := enemy_sprite.scale
    var player_modulate := player_battle_sprite.modulate
    var enemy_modulate := enemy_sprite.modulate
    var player_visible := player_battle_sprite.visible
    var enemy_visible := enemy_sprite.visible
    var player_hud_visible := player_hud.visible
    var enemy_hud_visible := enemy_hud.visible
    var source_hud_visible := source_single_hud.visible
    var effects = preload("res://scripts/source_battle_effects.gd").new()
    effects.begin(self, source_key)
    source_effect_playing = true
    var animation_deadline := preload("res://scripts/game_clock.gd").ticks_usec()
    for frame_index in range(frames):
        battle_move_animation.texture = _source_animation_frame_texture(source_key, frame_index)
        var directive := _battle_directive(source_key, frame_index + 1)
        _apply_source_battle_frame(
            directive, source_key, player_origin, enemy_origin, animation_origin)
        await effects.apply(directive, frame_index + 1)
        animation_deadline += roundi(frame_time * 1000000.0)
        while preload("res://scripts/game_clock.gd").ticks_usec() < animation_deadline:
            await get_tree().process_frame
    effects.finish()
    source_effect_playing = false
    battle_move_animation.texture = null
    battle_move_animation.position = animation_origin
    player_battle_sprite.position = player_origin
    enemy_sprite.position = enemy_origin
    player_battle_sprite.scale = player_scale
    enemy_sprite.scale = enemy_scale
    player_battle_sprite.modulate = player_modulate
    enemy_sprite.modulate = enemy_modulate
    player_battle_sprite.visible = player_visible
    enemy_sprite.visible = enemy_visible
    player_hud.visible = player_hud_visible
    enemy_hud.visible = enemy_hud_visible
    source_single_hud.visible = source_hud_visible

func _source_frame_number(frame: Dictionary, key: String, fallback: float = 0.0) -> float:
    return float(frame.get(key, fallback))

func _apply_source_battle_frame(frame: Dictionary, source_key: String,
        player_origin: Vector2, enemy_origin: Vector2,
        animation_origin: Vector2) -> void:
    var actor_is_player := "_player_" in source_key
    var actor := player_battle_sprite if actor_is_player else enemy_sprite
    player_battle_sprite.position = player_origin + Vector2(
        _source_frame_number(frame, "player_translate_x"),
        -_source_frame_number(frame, "player_translate_y"))
    enemy_sprite.position = enemy_origin + Vector2(
        _source_frame_number(frame, "enemy_translate_x") +
            _source_frame_number(frame, "enemy_sprite_translate_x"),
        -_source_frame_number(frame, "enemy_translate_y") -
            _source_frame_number(frame, "enemy_sprite_translate_y"))
    if actor_is_player:
        actor.position += Vector2(
            _source_frame_number(frame, "sprite_translate_x") +
                _source_frame_number(frame, "player_sprite_translate_x"),
            _source_frame_number(frame, "sprite_translate_y") +
                _source_frame_number(frame, "player_sprite_translate_y"))
    else:
        actor.position += Vector2(
            _source_frame_number(frame, "sprite_translate_x"),
            _source_frame_number(frame, "sprite_translate_y"))
    battle_move_animation.position = animation_origin + Vector2(
        _source_frame_number(frame, "screen_translate_x"),
        _source_frame_number(frame, "screen_translate_y"))
    if battle_is_double:
        player_hud.visible = not bool(frame.get("player_healthbar_gone", false))
        enemy_hud.visible = not bool(frame.get("enemy_healthbar_gone", false))
    else:
        player_hud.visible = false
        enemy_hud.visible = false
        source_single_hud.visible = not (
            bool(frame.get("player_healthbar_gone", false)) and
            bool(frame.get("enemy_healthbar_gone", false)))
    player_battle_sprite.visible = not (
        bool(frame.get("player_sprite_gone", false)) or
        bool(frame.get("player_sprite_hide", false)))
    enemy_sprite.visible = not (
        bool(frame.get("enemy_sprite_gone", false)) or
        bool(frame.get("enemy_sprite_hide", false)))
    if bool(frame.get("player_sprite_show", false)):
        player_battle_sprite.visible = true
    if bool(frame.get("enemy_sprite_show", false)):
        enemy_sprite.visible = true
    player_battle_sprite.scale = Vector2(0.5, 0.5) if bool(
        frame.get("player_shrink", false)) else Vector2.ONE
    enemy_sprite.scale = Vector2(0.5, 0.5) if bool(
        frame.get("enemy_shrink", false)) else Vector2.ONE
    player_battle_sprite.modulate = Color(0.68, 0.68, 0.68, 1.0) if bool(
        frame.get("sprite_greyscale", false)) and actor_is_player else Color.WHITE
    enemy_sprite.modulate = Color(0.68, 0.68, 0.68, 1.0) if bool(
        frame.get("sprite_greyscale", false)) and not actor_is_player else Color.WHITE
    if bool(frame.get("user_cry", false)):
        _play_pokemon_cry(battle_player if actor_is_player else battle_enemy)

func _battle_source_key(normalized_move: String, side: String) -> String:
    if normalized_move == "curse":
        var attacker: Dictionary = battle_player if side == "player" else battle_enemy
        if "GHOST" in attacker.get("types", []): normalized_move = "curse_ghost"
    var animations: Dictionary = battle_animation_manifest.get("animations", {})
    var exact := "%s_%s_gsc" % [normalized_move, side]
    if animations.has(exact):
        return exact
    # Only spelling differences; never substitute another move's animation.
    var aliases := {"feint_attack":"faint_attack", "ancient_power":"ancientpower"}
    var aliased := String(aliases.get(normalized_move, normalized_move))
    var alias_key := "%s_%s_gsc" % [aliased, side]
    if animations.has(alias_key):
        return alias_key
    return exact

func _play_generic_battle_animation(player_attacks: bool, damaging: bool) -> void:
    var attacker_sprite := player_battle_sprite if player_attacks else enemy_sprite
    var target_sprite := enemy_sprite if player_attacks else player_battle_sprite
    if not damaging:
        var pulse := create_tween()
        pulse.tween_property(attacker_sprite, "modulate", Color(1.45, 1.45, 1.45, 1), 0.08)
        pulse.tween_property(attacker_sprite, "modulate", Color.WHITE, 0.11)
        await pulse.finished
        return
    var origin := attacker_sprite.position
    var direction := Vector2(10.0, -2.0) if player_attacks else Vector2(-10.0, 2.0)
    target_sprite.modulate = Color(1.0, 0.45, 0.45, 1.0)
    var lunge := create_tween()
    lunge.tween_property(attacker_sprite, "position", origin + direction, 0.08)
    lunge.tween_property(attacker_sprite, "position", origin, 0.10)
    await lunge.finished
    target_sprite.modulate = Color.WHITE

func _play_source_capture_poof() -> void:
    if not GameOptions.enabled("battle_animations"):
        return
    var poof: TextureRect = TextureRect.new()
    poof.name = "SourceCapturePoof"
    poof.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
    poof.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
    poof.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
    poof.size = Vector2(48, 48)
    poof.position = enemy_sprite.position + enemy_sprite.size * 0.5 - Vector2(24, 24)
    poof.mouse_filter = Control.MOUSE_FILTER_IGNORE
    poof.z_index = 259
    battle_panel.add_child(poof)
    _play_source_battle_sound("poof1.ogg")
    for frame_index in range(5):
        var frame: AtlasTexture = AtlasTexture.new()
        frame.atlas = SOURCE_CAPTURE_POOF
        frame.region = Rect2(frame_index * 48, 0, 48, 48)
        poof.texture = frame
        await get_tree().create_timer(4.0 * SOURCE_FRAME_TIME).timeout
    poof.queue_free()

func _play_source_throw_animation(captured: bool, shakes: int = 3) -> void:
    _clear_battle_capture_ball()
    if not GameOptions.enabled("battle_animations"):
        enemy_sprite.visible = not captured
        return
    battle_capture_ball = TextureRect.new()
    battle_capture_ball.name = "SourcePokeBall"
    battle_capture_ball.texture = _battle_ball_art(SOURCE_POKEBALL_TEXTURE)
    battle_capture_ball.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
    battle_capture_ball.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
    battle_capture_ball.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
    battle_capture_ball.size = Vector2(24.0, 24.0)
    battle_capture_ball.mouse_filter = Control.MOUSE_FILTER_IGNORE
    battle_capture_ball.z_index = 260
    battle_panel.add_child(battle_capture_ball)
    var start = player_battle_sprite.position + Vector2(
        player_battle_sprite.size.x * 0.72, player_battle_sprite.size.y * 0.35)
    var target = enemy_sprite.position + enemy_sprite.size * 0.5 - Vector2(12.0, 12.0)
    battle_capture_ball.position = start
    var midpoint = start.lerp(target, 0.5) + Vector2(0.0, -34.0)
    var throw_tween = create_tween()
    throw_tween.tween_property(battle_capture_ball, "position", midpoint, 0.16)
    throw_tween.tween_property(battle_capture_ball, "position", target, 0.18)
    await throw_tween.finished
    await _play_source_capture_poof()
    enemy_sprite.visible = false
    for wiggle in range(shakes):
        var frame = AtlasTexture.new()
        frame.atlas = _battle_ball_art(SOURCE_POKEBALL_WIGGLE_TEXTURE)
        frame.region = Rect2(float(wiggle * 12), 0.0, 12.0, 12.0)
        battle_capture_ball.texture = frame
        _play_source_battle_sound("pokeball_wiggle1.ogg")
        await get_tree().create_timer(43.0 * SOURCE_FRAME_TIME).timeout
    if not captured:
        _clear_battle_capture_ball()
        await _play_source_capture_poof()
        enemy_sprite.visible = true

var battle_ball_art: Dictionary = {}

## The thrown ball in the colours of the ball that was actually used. The
## field already recolours the shell this way; battle always showed a POKE BALL.
func _battle_ball_art(source: Texture2D) -> Texture2D:
    if last_battle_ball.is_empty() or last_battle_ball == "POKE BALL":
        return source
    var key := source.resource_path + "|" + last_battle_ball
    if not battle_ball_art.has(key):
        battle_ball_art[key] = ImageTexture.create_from_image(
            preload("res://scripts/ball_shell_colors.gd").recolor(TexturePixels.of(source), last_battle_ball))
    return battle_ball_art[key]

func _clear_battle_capture_ball() -> void:
    if battle_capture_ball != null and is_instance_valid(battle_capture_ball):
        battle_capture_ball.queue_free()
    battle_capture_ball = null

func _set_double_battle_layout() -> void:
    player_partner_sprite.visible = battle_is_double and not battle_player_partner.is_empty()
    enemy_partner_sprite.visible = battle_is_double and not battle_enemy_partner.is_empty()
    double_status.visible = battle_is_double
    if battle_is_double:
        player_battle_sprite.position = Vector2(18.0, 46.0)
        player_battle_sprite.size = Vector2(70.0, 68.0)
        enemy_sprite.position = Vector2(232.0, 4.0)
        enemy_sprite.size = Vector2(62.0, 54.0)
    else:
        # Spread the two sprites into the added 16:9 side space while keeping
        # each sprite's aspect ratio intact.
        # The back sprite stands on the text box, whose top edge is at 123.
        # It used to stop seven pixels short, leaving a strip of background
        # under every Pokemon drawn to be cut off by the box.
        player_battle_sprite.position = Vector2(26.0, 41.0)
        player_battle_sprite.size = Vector2(84.0, 82.0)
        enemy_sprite.position = Vector2(210.0, 2.0)
        enemy_sprite.size = Vector2(82.0, 64.0)

func _refresh_battle_sprites() -> void:
    if battle_player.is_empty() or battle_enemy.is_empty():
        return
    var player_texture := PokemonData.record_texture(battle_player, "back")
    var player_uses_front := player_texture == null
    if player_uses_front:
        player_texture = PokemonData.record_texture(battle_player, "front")
    player_battle_sprite.texture = (
        _battle_sprite_frame_at(player_texture, battle_sprite_animation_frame)
    )
    if battle_active and not bool(battle_context.get("pvp",false)):
        if not bool(battle_context.get("requires_silph_scope", false)) or bool(battle_context.get("ghost_revealed", false)):
            pokedex_progress.mark(battle_enemy)
            if battle_is_double: pokedex_progress.mark(battle_enemy_partner)
    var enemy_texture := PokemonData.record_texture(battle_enemy, "front")
    if enemy_texture == null:
        enemy_texture = POKEMON_TEXTURES.get(String(battle_enemy.species)) as Texture2D
    var ghost_hidden := String(battle_context.get("kind", "")) == "ghost" and \
        not bool(battle_context.get("ghost_revealed", true))
    if ghost_hidden:
        enemy_texture = _ghost_battle_texture()
    enemy_sprite.texture = (
        _battle_sprite_frame(enemy_texture) if ghost_hidden or String(battle_enemy.get("species","")) == "mew"
        else _battle_sprite_frame_at(enemy_texture, battle_sprite_animation_frame)
    )
    if is_instance_valid(source_boss):
        enemy_sprite.texture=source_boss.body
    if is_instance_valid(source_mewtwo):
        enemy_sprite.texture = source_mewtwo.body
    if battle_is_double:
        if not battle_player_partner.is_empty():
            var ally_texture := PokemonData.record_texture(battle_player_partner, "back")
            var ally_uses_front := ally_texture == null
            if ally_uses_front:
                ally_texture = PokemonData.record_texture(battle_player_partner, "front")
            player_partner_sprite.texture = (
                _battle_sprite_frame_at(ally_texture, battle_sprite_animation_frame)
            )
        if not battle_enemy_partner.is_empty():
            var foe_texture := PokemonData.record_texture(battle_enemy_partner, "front")
            if foe_texture == null:
                foe_texture = POKEMON_TEXTURES.get(String(battle_enemy_partner.species)) as Texture2D
            enemy_partner_sprite.texture = _battle_sprite_frame_at(
                foe_texture, battle_sprite_animation_frame)
        player_partner_sprite.visible = not battle_player_partner.is_empty() and \
            int(battle_player_partner.get("hp", 0)) > 0
        enemy_partner_sprite.visible = not battle_enemy_partner.is_empty() and \
            int(battle_enemy_partner.get("hp", 0)) > 0

func _update_battle_hud() -> void:
    if battle_player.is_empty() or battle_enemy.is_empty():
        return
    var enemy_status = String(battle_enemy.get("status", ""))
    if not enemy_status.is_empty():
        enemy_status = " " + enemy_status.left(3)
    var player_status = String(battle_player.get("status", ""))
    if not player_status.is_empty():
        player_status = " " + player_status.left(3)
    var enemy_display_name = PokemonState.battle_display_name(battle_enemy).to_upper()
    if String(battle_context.get("kind", "")) == "ghost" and not bool(battle_context.get("ghost_revealed", true)):
        enemy_display_name = "GHOST"
    enemy_label.text = "%s  LV %d%s" % [
        enemy_display_name.left(10),
        int(battle_enemy.level), enemy_status
    ]
    enemy_level_label.text = ""
    enemy_gender_label.text = "" if bool(battle_enemy.get("is_ghost", false)) else _gender_symbol(battle_enemy)
    player_battle_label.text = "%s  LV %d%s" % [
        PokemonState.battle_display_name(battle_player).to_upper().left(9),
        int(battle_player.level), player_status
    ]
    player_level_label.text = ""
    player_gender_label.text = _gender_symbol(battle_player)
    party_menu.set_fitting_pokemon_name(source_enemy_name, battle_enemy, enemy_display_name)
    _fit_source_battle_level(source_enemy_level, source_enemy_gender, "EnemyLevelChar", int(battle_enemy.level))
    source_enemy_status.text = _battle_status_abbreviation(battle_enemy)
    _size_battle_status_label(source_enemy_status, battle_enemy, 11.0)
    _set_source_gender(source_enemy_gender, battle_enemy)
    if bool(battle_enemy.get("is_ghost", false)): source_enemy_gender.visible = false
    party_menu.set_fitting_pokemon_name(source_player_name, battle_player)
    _fit_source_battle_level(source_player_level, source_player_gender, "PlayerLevelChar", int(battle_player.level))
    source_player_status.text = _battle_status_abbreviation(battle_player)
    _size_battle_status_label(source_player_status, battle_player, 63.0)
    _set_source_gender(source_player_gender, battle_player)
    var enemy_ratio = clampf(
        float(battle_enemy.hp) / maxf(1.0, float(battle_enemy.max_hp)), 0.0, 1.0)
    var player_ratio = clampf(
        float(battle_player.hp) / maxf(1.0, float(battle_player.max_hp)), 0.0, 1.0)
    enemy_hp_fill.size.x = _battle_hp_width(enemy_ratio, 106.0)
    player_hp_fill.size.x = _battle_hp_width(player_ratio, 110.0)
    enemy_hp_fill.color = _battle_hp_color(enemy_ratio)
    player_hp_fill.color = _battle_hp_color(player_ratio)
    player_hp_value.text = "%d/ %d" % [int(battle_player.hp), int(battle_player.max_hp)]
    source_enemy_hp_fill.size.x = _battle_hp_width(enemy_ratio, 48.0)
    source_player_hp_fill.size.x = _battle_hp_width(player_ratio, 48.0)
    source_enemy_hp_fill.color = _battle_hp_color(enemy_ratio)
    source_player_hp_fill.color = _battle_hp_color(player_ratio)
    source_player_hp_current.text = str(int(battle_player.hp))
    source_player_hp_max.text = str(int(battle_player.max_hp))
    var player_level = int(battle_player.get("level", 1))
    var exp_ratio = 1.0
    if player_level < 100:
        var exp_floor = BattleEngine.exp_for_level(
            String(battle_player.get("species", "machop")), player_level)
        var exp_ceiling = BattleEngine.exp_for_level(
            String(battle_player.get("species", "machop")), player_level + 1)
        exp_ratio = clampf(float(int(battle_player.get("exp", exp_floor)) - exp_floor) /
            maxf(1.0, float(exp_ceiling - exp_floor)), 0.0, 1.0)
    _set_player_exp_bar_ratio(exp_ratio)
    if battle_is_double:
        var ally_text = "NO ALLY"
        var foe_text = "NO FOE"
        if not battle_player_partner.is_empty():
            ally_text = "%s %d/%d" % [PokemonState.battle_display_name(battle_player_partner).to_upper().left(9),
                int(battle_player_partner.hp), int(battle_player_partner.max_hp)]
        if not battle_enemy_partner.is_empty():
            foe_text = "%s %d/%d" % [PokemonState.battle_display_name(battle_enemy_partner).to_upper().left(9),
                int(battle_enemy_partner.hp), int(battle_enemy_partner.max_hp)]
        double_status.text = "%s     FOE: %s" % [ally_text, foe_text]
    var terrain_name = String(battle_field.get("terrain", "GRASSY")).replace("_", " ")
    var weather_name = String(battle_field.get("weather", ""))
    battle_field_label.text = "%s FIELD" % terrain_name
    if not weather_name.is_empty():
        battle_field_label.text += " / %s %d" % [weather_name,
            int(battle_field.get("weather_turns", 0))]

func _size_battle_status_label(label: Label, pokemon: Dictionary, base_y: float) -> void:
    var compact := String(pokemon.get("status", "")).to_upper() in ["SLEEP", "POISON", "TOXIC", "PARALYSIS"]
    label.add_theme_font_size_override("font_size", 9 if compact else 10)
    label.position.y = base_y - (1.0 if compact else 0.0)

func _battle_status_abbreviation(pokemon: Dictionary) -> String:
    return {
        "BURN":"BRN", "POISON":"PSN", "TOXIC":"PSN",
        "PARALYSIS":"PAR", "SLEEP":"SLP", "FREEZE":"FRZ"
    }.get(String(pokemon.get("status", "")).to_upper(), "")

func _resolved_battle_gender(pokemon: Dictionary) -> String:
    var species: String = String(pokemon.get("species", "")).to_lower()
    if species in ["nidoran_f", "nidoran-f", "nidoran♀"]:
        return "female"
    if species in ["nidoran_m", "nidoran-m", "nidoran♂"]:
        return "male"
    return String(pokemon.get("gender", "")).to_lower()

func _gender_symbol(pokemon: Dictionary) -> String:
    var gender: String = _resolved_battle_gender(pokemon)
    if gender in ["female", "f", "♀"]:
        return "♀"
    if gender in ["male", "m", "♂"]:
        return "♂"
    return ""

func _fit_source_battle_level(label: Label, gender: Control, prefix_name: String, level: int) -> void:
    var prefix := source_single_hud.get_node(prefix_name) as Control
    if not label.has_meta("level_origin_x"):
        label.set_meta("level_origin_x", label.position.x)
        prefix.set_meta("level_origin_x", prefix.position.x)
    label.text = str(level)
    var width := label.get_theme_font("font").get_string_size(label.text, HORIZONTAL_ALIGNMENT_LEFT, -1, label.get_theme_font_size("font_size")).x
    var original: float = label.get_meta("level_origin_x")
    var shift := minf(0.0, gender.position.x - 2.0 - original - width) if level >= 100 else 0.0
    label.position.x = original + shift
    prefix.position.x = float(prefix.get_meta("level_origin_x")) + shift

func _set_source_gender(target: TextureRect, pokemon: Dictionary) -> void:
    var gender: String = _resolved_battle_gender(pokemon)
    target.visible = gender in ["female", "f", "♀", "male", "m", "♂"]
    if gender in ["female", "f", "♀"]:
        target.texture = SOURCE_FEMALE_SYMBOL
    elif target.visible:
        target.texture = SOURCE_MALE_SYMBOL

func _play_level_up_sound() -> void:
    if ResourceLoader.exists(LEVEL_UP_AUDIO_PATH):
        battle_audio.stream = load(LEVEL_UP_AUDIO_PATH) as AudioStream
        AudioBalance.apply(battle_audio)
        battle_audio.play()

func _play_source_battle_feedback_audio(key: String) -> void:
    var path := String((battle_animation_manifest.get("audio",{}) as Dictionary).get(key,""))
    if not path.is_empty() and ResourceLoader.exists(path):
        battle_audio.stream=load(path)
        AudioBalance.apply(battle_audio)
        battle_audio.play()

func _play_source_battle_sound(filename: String) -> void:
    var normalized := filename
    if not normalized.to_lower().ends_with(".ogg"):
        normalized += ".ogg"
    var path := SOURCE_SOUND_ROOT + normalized
    if ResourceLoader.exists(path):
        battle_audio.stream = load(path) as AudioStream
        AudioBalance.apply(battle_audio)
        battle_audio.play()

func _pokemon_cry_path(pokemon: Dictionary) -> String:
    if pokemon.is_empty():
        return ""
    var cry_path := "res://assets/source_audio/cries/000.ogg" if bool(pokemon.get("is_ghost", false)) else PokemonData.cry_path(String(pokemon.get("species", "")))
    return cry_path if not cry_path.is_empty() and ResourceLoader.exists(cry_path) else ""

## Cries a battle is about to play load on a worker thread during the transition.
var cry_requests: Dictionary = {}
func _request_pokemon_cry(pokemon: Dictionary) -> void:
    var cry_path := _pokemon_cry_path(pokemon)
    if not cry_path.is_empty() and not cry_requests.has(cry_path) and ResourceLoader.load_threaded_request(cry_path) == OK:
        cry_requests[cry_path] = true

## Hands back (and so releases) cries requested but never played.
func _release_cry_requests() -> void:
    for cry_path in cry_requests: ResourceLoader.load_threaded_get(cry_path)
    cry_requests.clear()

func _play_pokemon_cry(pokemon: Dictionary, gain: float = 1.0) -> void:
    var cry_path := _pokemon_cry_path(pokemon)
    if cry_path.is_empty():
        return
    battle_audio.stream = (ResourceLoader.load_threaded_get(cry_path) if cry_requests.erase(cry_path) else load(cry_path)) as AudioStream
    AudioBalance.apply(battle_audio)
    battle_audio.volume_db += linear_to_db(maxf(gain, 0.001))
    battle_audio.play()

func _battle_hp_color(ratio: float) -> Color:
    if ratio <= 0.20:
        return Color8(248, 0, 0, 255)
    if ratio <= 0.50:
        return Color8(248, 184, 0, 255)
    return Color8(0, 184, 0, 255)

func _battle_hp_width(ratio: float, maximum_width: float) -> float:
    if ratio <= 0.0:
        return 0.0
    return maxf(1.0, roundf(maximum_width * ratio))

func _set_animated_battle_hp(pokemon: Dictionary, displayed_hp: int,
        player_side: bool) -> void:
    var maximum := maxi(1, int(pokemon.get("max_hp", 1)))
    var ratio := clampf(float(displayed_hp) / float(maximum), 0.0, 1.0)
    if player_side:
        player_hp_fill.size.x = _battle_hp_width(ratio, 110.0)
        player_hp_fill.color = _battle_hp_color(ratio)
        player_hp_value.text = "%d/ %d" % [displayed_hp, maximum]
        source_player_hp_fill.size.x = _battle_hp_width(ratio, 48.0)
        source_player_hp_fill.color = _battle_hp_color(ratio)
        source_player_hp_current.text = str(displayed_hp)
        source_player_hp_max.text = str(maximum)
    else:
        enemy_hp_fill.size.x = _battle_hp_width(ratio, 106.0)
        enemy_hp_fill.color = _battle_hp_color(ratio)
        source_enemy_hp_fill.size.x = _battle_hp_width(ratio, 48.0)
        source_enemy_hp_fill.color = _battle_hp_color(ratio)

func _animate_battle_hp_change(pokemon: Dictionary, from_hp: int,
        to_hp: int, player_side: bool) -> void:
    if from_hp == to_hp:
        return
    var maximum := maxi(1, int(pokemon.get("max_hp", 1)))
    var start_width := roundi(48.0 * float(from_hp) / float(maximum))
    var end_width := roundi(48.0 * float(to_hp) / float(maximum))
    var frames := maxi(1, absi(start_width - end_width))
    var hp_start := preload("res://scripts/game_clock.gd").ticks_usec()
    for frame_index in range(1, frames + 1):
        var shown_hp := roundi(lerpf(float(from_hp), float(to_hp),
            float(frame_index) / float(frames)))
        _set_animated_battle_hp(pokemon, shown_hp, player_side)
        var deadline := hp_start + int(frame_index * SOURCE_FRAME_TIME * 1000000.0)
        while preload("res://scripts/game_clock.gd").ticks_usec() < deadline:
            await get_tree().process_frame

func _animate_visible_battle_hp(pokemon: Dictionary, from_hp: int,
        to_hp: int) -> void:
    if is_same(pokemon, battle_player):
        await _animate_battle_hp_change(pokemon, from_hp, to_hp, true)
    elif is_same(pokemon, battle_enemy):
        await _animate_battle_hp_change(pokemon, from_hp, to_hp, false)

func _update_battle_field_visuals() -> void:
    var color := Color(0.18, 0.55, 0.18, 0.06)
    match String(battle_field.get("terrain", "GRASSY")):
        "AQUATIC": color = Color(0.18, 0.38, 0.82, 0.09)
        "SANDY": color = Color(0.72, 0.55, 0.22, 0.10)
    match String(battle_field.get("weather", "")):
        "RAIN": color = Color(0.12, 0.30, 0.75, 0.19)
        "SUN": color = Color(1.0, 0.72, 0.15, 0.15)
        "SANDSTORM": color = Color(0.65, 0.48, 0.20, 0.21)
    battle_weather_overlay.color = color
    _update_battle_hud()

## Set when a message arrives while the bag is open: shown in the bag's own
## description box (the field dialogue box is hidden under the bag) until a
## different item is selected.
var bag_notice := ""
var bag_notice_item := ""

## game_menu.gd under its old names, for the scripts and tests that call them on main.
func _open_game_menu() -> void: start_menu.open_game_menu()
func _close_game_menu() -> void: start_menu.close_game_menu()
func _update_game_menu_cursor() -> void: start_menu.update_game_menu_cursor()
func _activate_game_menu_option() -> void: start_menu.activate_game_menu_option()
func _update_save_confirm_cursor() -> void: start_menu.update_save_confirm_cursor()
func _update_quit_prompt_cursor() -> void: start_menu.update_quit_prompt_cursor()

## game_saving.gd under its old names, for the scripts and tests that call them on main.
func _capture_game_save(version: int = 2, personal_only: bool = false) -> Dictionary: return saving.capture_game_save(version, personal_only)
func _save_current_game() -> void: await saving.save_current_game()

## crafting_menu.gd under its old names, for the scripts and tests that call them on main.
func _open_build_menu() -> void: crafting_menu.open_build_menu()
func _close_build_menu(stop_building: bool = true) -> void: crafting_menu.close_build_menu(stop_building)
func _on_world_build_selection_changed(index: int) -> void: crafting_menu.on_world_build_selection_changed(index)

func _on_dig_reward_collected(items: Dictionary, grant_items: bool = true) -> void:
    if is_instance_valid(coop_game) and coop_game.active and coop_game.building.collect(items):return
    if world.get_meta("ball_action_reward", false) or world.active_field_move != "DIG":
        _on_material_bundle_collected(items,grant_items)
        return
    var lines: Array[String] = []
    for raw_name in items:
        var item := ItemData.normalize_name(String(raw_name))
        var amount := int(items[raw_name])
        if grant_items:CraftingData.grant(inventory, item, amount)
        lines.append("Got x%d %s" % [amount, item])
    dig_reward_label.text = "\n".join(lines)
    minimap.fit_compact_dig_label(dig_reward_label)
    dig_reward_seconds = 1.8
    minimap.update_dig_hud_and_minimap(0.0)

func _on_material_collected(item_name: String, amount: int) -> void:
    if is_instance_valid(coop_game) and coop_game.active and coop_game.building.collect({ItemData.normalize_name(item_name):amount}):return
    var normalized := ItemData.normalize_name(item_name)
    CraftingData.grant(inventory, normalized, amount)
    dialogs.show_acquired_resource(normalized, amount)

func _on_material_bundle_collected(items: Dictionary, grant_items: bool = true) -> void:
    if is_instance_valid(coop_game) and coop_game.active and coop_game.building.collect(items):return
    var lines: Array[String] = ["GOT"]
    for raw_name in items.keys():
        var normalized := ItemData.normalize_name(String(raw_name))
        var amount := maxi(1, int(items[raw_name]))
        if grant_items:CraftingData.grant(inventory, normalized, amount)
        lines.append("x%d %s" % [amount, normalized])
    resource_popup_name = ""
    resource_popup_amount = 0
    resource_popup_text.text = "\n".join(lines)
    resource_popup.visible = true
    resource_popup_timer = 0.9

func _on_paint_requested(picture_index: int, cell: Vector2i) -> void:
    if int(inventory.get("THIN PAPER", 0)) <= 0:
        dialogs.show_message("PAINT needs 1 THIN PAPER.")
        return
    if is_instance_valid(coop_game) and coop_game.active:
        coop_game.building.paint(picture_index,cell)
        return
    if world.has_method("apply_paint") and bool(world.call("apply_paint", picture_index, cell)):
        inventory["THIN PAPER"] = int(inventory.get("THIN PAPER", 0)) - 1

func _on_build_requested(build_name: String, cell: Vector2i) -> void:
    var recipe := CraftingData.build_recipe(build_name)
    if recipe.is_empty():
        return
    var cost: Dictionary = recipe.get("cost", {})
    if not CraftingData.can_afford(inventory, cost):
        dialogs.show_message("Not enough materials for %s." % build_name)
        return
    if is_instance_valid(coop_game) and coop_game.active:
        coop_game.building.build(build_name,cell)
        return
    if world.place_structure(build_name, cell):
        CraftingData.consume(inventory, cost)

func _on_dig_requested(choice: String, cell: Vector2i, material: String) -> void:
    if int(inventory.get(material, 0)) <= 0:
        dialogs.show_message("DIG needs %s to place %s." % [material, choice])
        return
    if is_instance_valid(coop_game) and coop_game.active and not coop_game.building.collecting:
        coop_game.building.dig(cell,choice)
        return
    if world.has_method("apply_dig_choice"):
        if bool(world.call("apply_dig_choice", cell, choice)):
            if is_instance_valid(coop_game) and coop_game.active and coop_game.building.collecting:coop_game.building.field_choice=choice
            else:inventory[material] = int(inventory.get(material, 0)) - 1

func _on_build_refund_requested(refund: Dictionary, grant_items: bool = true) -> void:
    if refund.is_empty():
        return
    if refund.size() == 1:
        var raw_name = refund.keys()[0]
        var normalized := ItemData.normalize_name(String(raw_name))
        var amount := maxi(1, int(refund[raw_name]))
        if grant_items:CraftingData.grant(inventory, normalized, amount)
        dialogs.show_acquired_resource(normalized, amount)
        return
    var lines: Array[String] = ["GOT"]
    for raw_name in refund.keys():
        var normalized := ItemData.normalize_name(String(raw_name))
        var amount := maxi(1, int(refund[raw_name]))
        if grant_items:CraftingData.grant(inventory, normalized, amount)
        lines.append("x%d %s" % [amount, normalized])
    resource_popup_name = ""
    resource_popup_amount = 0
    resource_popup_text.text = "\n".join(lines)
    resource_popup.visible = true
    resource_popup_timer = 0.9

func _on_structure_removal_requested(cell: Vector2i, move: String) -> void:
    if move == "CUT" and not String(world.house_wall_decoration_at(cell)).is_empty():
        if is_instance_valid(coop_game) and coop_game.active:
            coop_game.building.remove_decoration(cell)
        else:
            world.remove_house_wall_decoration(cell, true)
        return
    var online: bool = is_instance_valid(coop_game) and coop_game.active
    var wipe_public := false
    if world.built_structures.has(cell):
        var build_name := String((world.built_structures[cell] as Dictionary).get("name", ""))
        # A STORAGE BOX can be cut with Pokemon in it while another one stands
        # in this world: its Pokemon stay reachable from the others. The last
        # one takes every stored Pokemon with it, so only the host may cut it,
        # and only after saying yes twice to prompts that start on NO.
        # The box itself, or boxes inside a house that go with the piece of its
        # outside being cut: the same questions either way.
        var boxes_going := 1 if build_name == "STORAGE BOX" else 0
        for inside_cell in world.house_interior_cells_behind(cell):
            if String(world.built_structures.get(inside_cell, {}).get("name", "")) == "STORAGE BOX":
                boxes_going += 1
        if boxes_going > 0 and storage.public_box_count() - boxes_going < 1:
            if online and not coop_game.hosting:
                dialogs.show_message("Sorry, a guest cannot cut the last public box in a world.")
                return
            if not await dialogs.ask_yes_no_starting_on_no("Last STORAGE BOX in this world!\nCut it and lose stored POKEMON?"):
                return
            if not await dialogs.ask_yes_no_starting_on_no("Are you sure? Stored POKEMON\ncannot be brought back."):
                return
            if not world.built_structures.has(cell):
                return
            wipe_public = true
    if online:
        coop_game.building.remove(cell,move,wipe_public)
        return
    if wipe_public:
        # PRIVATE CHEST contents belong to the player, not to this world.
        var private_keys: Array[String] = []
        for built_cell in world.built_structures:
            if String(world.built_structures[built_cell].get("name", "")) == "PRIVATE CHEST":
                private_keys.append(storage.world_storage_key(world._cell_key(built_cell),current_world_grid))
        for key in pokemon_storage.keys():
            if not String(key) in private_keys and String(key) != SHARED_STORAGE_KEY: pokemon_storage.erase(key)
    if world.has_method("remove_structure_with_field_move"):
        world.call("remove_structure_with_field_move", cell, move)

func _route_received_pokemon(pokemon: Dictionary, allow_party: bool = true) -> String:
    # Every acquisition shares this boundary; the visible party has six slots.
    if allow_party and caught_pokemon.size() < 6:
        caught_pokemon.append(pokemon)
        pokedex_progress.mark(pokemon, true)
        return "PARTY"
    if is_instance_valid(coop_game) and coop_game.active:return coop_game.storage.route_received(pokemon)
    for key in storage.built_storage_keys():
        var box: Array = pokemon_storage.get(key, [])
        if POKEMON_STORAGE_CAPACITY > 0 and box.size() >= POKEMON_STORAGE_CAPACITY:
            continue
        box.append(pokemon)
        pokemon_storage[key] = box
        pokedex_progress.mark(pokemon, true)
        return "STORAGE"
    # User-requested fallback uses source SelectedMenu.releasePokemon:
    # released records are removed from ownership, not left in hidden slots.
    return "RELEASED"

func _received_pokemon_notice(pokemon: Dictionary, destination: String) -> String:
    var name := "EGG" if bool(pokemon.get("is_egg", false)) else PokemonState.display_name(pokemon).to_upper()
    if destination == "STORAGE":
        return "%s has been sent to storage." % name
    if destination == "RELEASED":
        return "You have no more room in storage! %s was released to the wild." % name
    return ""

func _recover_hidden_party_overflow() -> void:
    var stored := 0
    var released := 0
    while caught_pokemon.size() > 6:
        var pokemon: Dictionary = caught_pokemon.pop_at(6)
        var destination := _route_received_pokemon(pokemon, false)
        if destination == "STORAGE": stored += 1
        else: released += 1
    overflow_recovery_notice = ""
    if stored > 0:
        overflow_recovery_notice = "%d hidden party entries were sent to storage." % stored
    if released > 0:
        overflow_recovery_notice = "You have no more room in storage! %d excess party entries were released to the wild." % released + (" %d were sent to storage." % stored if stored > 0 else "")

func _can_receive_overworld_pokemon() -> bool:
    if caught_pokemon.size() < 6:
        return true
    for key in storage.built_storage_keys():
        if POKEMON_STORAGE_CAPACITY <= 0 or (pokemon_storage.get(key, []) as Array).size() < POKEMON_STORAGE_CAPACITY:
            return true
    return false

func _on_deployed_recall_requested(cell: Vector2i, species: String, message: String) -> void:
    _on_wild_pokemon_prompt_requested(-1, species, "DEPLOYED")
    if not wild_pokemon_prompt_open or wild_pokemon_prompt_kind != "DEPLOYED":
        return
    deployed_prompt_cell = cell
    # Online the Pokemon goes on walking while its prompt is open (the host or
    # another player moves it): the answer is about this Pokemon, not this tile.
    deployed_prompt_id = String(world.deployed_pokemon.get(cell, {}).get("ecology_id", ""))
    world.recall_hold = deployed_prompt_id
    wild_dialogue_label.text = message

func _on_pokemon_recalled(pokemon_data: Dictionary) -> void:
    var destination := _route_received_pokemon(pokemon_data)
    var species := String(pokemon_data.get("species", ""))
    if not species.is_empty() and not caught_species.has(species):
        caught_species.append(species)
    world.play_source_sound("seed1")
    var notice := _received_pokemon_notice(pokemon_data, destination)
    if not notice.is_empty(): dialogs.show_message(notice)

func _on_wild_pokemon_prompt_requested(
        wild_id: int, species: String, kind: String
    ) -> void:
    if (
            wild_pokemon_prompt_open or egg_pickup_open or battle_active
            or game_menu_open or craft_menu_open or build_menu_open
            or storage_menu_open or trainer_tip_open
        ):
        return
    wild_pokemon_prompt_open = true
    wild_pokemon_prompt_stage = 0
    wild_pokemon_prompt_index = 0
    wild_pokemon_prompt_id = wild_id
    wild_pokemon_prompt_species = PokemonData.battle_display_name(species).replace("_", " ")
    wild_pokemon_prompt_kind = kind.to_upper()
    # Friendly, but still shaken by a failed catch: same choice, other words.
    var frightened := wild_pokemon_prompt_kind == "FRIGHTENED"
    if frightened: wild_pokemon_prompt_kind = "FRIENDLY"
    wild_pokemon_prompt_confirm_armed = false
    world.set_gameplay_enabled(false)
    message_panel.visible = false
    wild_dialogue_panel.visible = true
    wild_choice_panel.visible = false
    wild_dialogue_arrow.visible = true
    if wild_pokemon_prompt_kind == "FRIENDLY":
        wild_dialogue_label.text = ("%s is frightened." if frightened else "%s seems friendly.") % wild_pokemon_prompt_species
    elif wild_pokemon_prompt_kind == "PROVOKED":
        wild_dialogue_label.text = "%s was provoked!" % wild_pokemon_prompt_species
        _schedule_wild_pokemon_prompt_resolution(wild_id, "PROVOKED", 0.325)
    else:
        # PROVOKE_WARNING (and legacy PROVOKE) is a complete first interaction.
        # The opening A must be released before the warning can be dismissed.
        wild_dialogue_label.text = "%s seems aggressive... it may attack if provoked!" % wild_pokemon_prompt_species
        # Source DisplayText waits for a fresh confirm before closing.

func _schedule_wild_pokemon_prompt_resolution(
        wild_id: int, kind: String, delay: float
    ) -> void:
    var timer := get_tree().create_timer(delay)
    timer.timeout.connect(
        Callable(self, "_finish_wild_pokemon_prompt_resolution").bind(
            wild_id, kind
        )
    )

func _finish_wild_pokemon_prompt_resolution(wild_id: int, kind: String) -> void:
    # Timers are identity-checked so a stale timeout can never close or resolve
    # a later Pokemon prompt. This also gives the first box a real closed gap
    # before a second A is accepted by normal overworld interaction again.
    if (
            not wild_pokemon_prompt_open
            or wild_pokemon_prompt_id != wild_id
            or wild_pokemon_prompt_kind != kind
        ):
        return
    if kind in ["PROVOKE", "PROVOKE_WARNING"]:
        if world.has_method("mark_wild_provocation_warning"):
            world.call("mark_wild_provocation_warning", wild_id)
        _close_wild_pokemon_prompt()
        return
    if kind == "PROVOKED":
        _close_wild_pokemon_prompt()
        if world.has_method("confirm_wild_provocation"):
            world.call("confirm_wild_provocation", wild_id)

func _show_friendly_party_choice() -> void:
    wild_pokemon_prompt_stage = 1
    wild_pokemon_prompt_index = 0
    wild_dialogue_label.text = "Add %s to your party?" % wild_pokemon_prompt_species
    wild_dialogue_arrow.visible = false
    wild_choice_panel.visible = true
    _update_wild_pokemon_prompt_cursor()

func _update_wild_pokemon_prompt_cursor() -> void:
    if wild_choice_cursor == null:
        return
    _align_menu_tick(wild_choice_cursor, wild_choice_panel.get_node("Yes" if wild_pokemon_prompt_index == 0 else "No"))

func _close_wild_pokemon_prompt(restore_gameplay: bool = true) -> void:
    wild_pokemon_prompt_open = false
    wild_pokemon_prompt_stage = 0
    wild_pokemon_prompt_index = 0
    wild_pokemon_prompt_id = -1
    wild_pokemon_prompt_species = ""
    wild_pokemon_prompt_kind = ""
    wild_pokemon_prompt_confirm_armed = false
    if world != null and world.recall_hold == deployed_prompt_id:
        world.recall_hold = ""
    if wild_dialogue_panel != null:
        wild_dialogue_panel.visible = false
    if wild_choice_panel != null:
        wild_choice_panel.visible = false
    if (
            restore_gameplay and started and not battle_active
            and not game_menu_open and not craft_menu_open
            and not build_menu_open and not storage_menu_open
            and not trainer_tip_open and not egg_pickup_open
        ):
        world.set_gameplay_enabled(true)

func _recruit_friendly_wild(wild_id: int, species: String) -> void:
    if not world.has_method("take_friendly_wild"):
        _close_wild_pokemon_prompt()
        return
    if not _can_receive_overworld_pokemon():
        _close_wild_pokemon_prompt()
        dialogs.show_message("Your party and storage are full.")
        return
    # Online the host keeps the record of every wild Pokemon. It is claimed and
    # then reported as taken, exactly as a capture in battle is. Taking it from
    # this game alone left it on the host: it came back in the field and could
    # be taken again and again.
    var online: bool = is_instance_valid(coop_game) and coop_game.active
    if online:
        _close_wild_pokemon_prompt(false)
        # A save or another action on its way must not swallow the answer.
        await coop_game.wait_free()
        coop_game.wild.refused = ""
        if not await coop_game.wild.reserve(wild_id):
            if coop_game.active and not battle_active:
                world.set_gameplay_enabled(not _field_ui_blocks_gameplay(build_menu_open))
                dialogs.show_message(coop_game.population.refusal(
                    coop_game.wild.refused if not coop_game.wild.refused.is_empty() else "too_late", species.to_upper()))
            return
        coop_game.wild.applying = true
    var record = world.call("take_friendly_wild", wild_id)
    if online:
        coop_game.wild.applying = false
    if typeof(record) != TYPE_DICTIONARY or (record as Dictionary).is_empty():
        if online:
            var claimed_area := String(coop_game.wild.encounter.get("area", ""))
            coop_game.wild.encounter.clear()
            coop_game.wild.original_profile.clear()
            await coop_game.command("wild_release", {"area":claimed_area, "wild_id":wild_id})
            if coop_game.active:
                world.set_gameplay_enabled(not _field_ui_blocks_gameplay(build_menu_open))
        _close_wild_pokemon_prompt()
        dialogs.show_message("Too late! %s is no longer here." % species.to_upper())
        return
    var source := (record as Dictionary).duplicate(true)
    var nested_source = source.get("source_record", {})
    if typeof(nested_source) == TYPE_DICTIONARY:
        for raw_key in (nested_source as Dictionary).keys():
            var key := String(raw_key)
            if not source.has(key):
                source[key] = (nested_source as Dictionary)[raw_key]
    for ecology_key in [
            "source_record", "x", "y", "id", "home_biome", "burrowed",
            "move_timer", "anim_phase", "warned", "aggro_player",
            "provocation_count", "provocation_limit", "fed_until",
            "flee_steps", "charmed", "lay_egg_seconds"
        ]:
        source.erase(ecology_key)
    var normalized_species := String(
        source.get("species", species.to_lower())
    ).to_lower()
    var pokemon := BattleEngine.make_pokemon(
        normalized_species, maxi(1, int(source.get("level", 2))), null, source
    )
    var destination := _route_received_pokemon(pokemon)
    if not caught_species.has(normalized_species):
        caught_species.append(normalized_species)
    if online and not await coop_game.wild.finish_encounter("captured"):
        return
    _close_wild_pokemon_prompt()
    world.play_source_sound("seed1")
    var notice := _received_pokemon_notice(pokemon, destination)
    if not notice.is_empty(): dialogs.show_message(notice)

func _handle_wild_pokemon_prompt_input(event: InputEvent) -> void:
    if wild_pokemon_prompt_kind in ["PROVOKE", "PROVOKE_WARNING", "PROVOKED"]:
        if not wild_pokemon_prompt_confirm_armed:
            if event.is_action_released("confirm") or event.is_action_released("start"):
                wild_pokemon_prompt_confirm_armed = true
                get_viewport().set_input_as_handled()
            return
        if event.is_action_pressed("confirm") or event.is_action_pressed("start"):
            _finish_wild_pokemon_prompt_resolution(wild_pokemon_prompt_id,wild_pokemon_prompt_kind)
            get_viewport().set_input_as_handled()
        return

    # Friendly recruitment keeps its normal explicit A-driven dialogue flow,
    # but still requires release of the opening interaction first.
    if not wild_pokemon_prompt_confirm_armed:
        if event.is_action_released("confirm") or event.is_action_released("start"):
            wild_pokemon_prompt_confirm_armed = true
            get_viewport().set_input_as_handled()
        return

    if wild_pokemon_prompt_stage == 0:
        if event.is_action_pressed("confirm") or event.is_action_pressed("start"):
            _show_friendly_party_choice()
            get_viewport().set_input_as_handled()
        elif event.is_action_pressed("cancel"):
            _close_wild_pokemon_prompt()
            get_viewport().set_input_as_handled()
        return

    if event.is_action_pressed("move_up") or event.is_action_pressed("move_down"):
        wild_pokemon_prompt_index = 1 - wild_pokemon_prompt_index
        _update_wild_pokemon_prompt_cursor()
        get_viewport().set_input_as_handled()
    elif event.is_action_pressed("cancel"):
        _close_wild_pokemon_prompt()
        get_viewport().set_input_as_handled()
    elif event.is_action_pressed("confirm") or event.is_action_pressed("start"):
        var chosen_id := wild_pokemon_prompt_id
        var chosen_species := wild_pokemon_prompt_species
        if wild_pokemon_prompt_index == 0:
            if wild_pokemon_prompt_kind == "DEPLOYED":
                var cell := deployed_prompt_cell
                var identity := deployed_prompt_id
                _close_wild_pokemon_prompt()
                # Where that Pokemon stands now: it may have walked on, and
                # another may have stepped onto the tile it was asked on.
                if not identity.is_empty():
                    for shown in world.deployed_pokemon:
                        if String(world.deployed_pokemon[shown].get("ecology_id", "")) == identity:
                            cell = shown
                            break
                var data: Dictionary = world.deployed_pokemon.get(cell, {})
                if not identity.is_empty() and String(data.get("ecology_id", "")) != identity:
                    data = {"ecology_id": identity}
                # Online the host finds it by its id even when this game no longer shows it.
                if data.has("species") or (is_instance_valid(coop_game) and coop_game.active):
                    world._recall_deployed_pokemon(cell, data)
                else:
                    dialogs.show_message("It went away.")
            else:
                _recruit_friendly_wild(chosen_id, chosen_species)
        else:
            _close_wild_pokemon_prompt()
        get_viewport().set_input_as_handled()

func _handle_mansion_switch_input(event: InputEvent) -> void:
    if mansion_switch_stage == 3:
        if event.is_action_pressed("confirm") or event.is_action_pressed("start"):
            mansion_switch_stage = 2
            mansion_switch_answered.emit(true)
            get_viewport().set_input_as_handled()
        return
    if mansion_switch_stage == 2:
        return
    if event.is_action_pressed("cancel"):
        mansion_switch_stage = 2
        mansion_switch_answered.emit(false)
    elif mansion_switch_stage == 0 and (event.is_action_pressed("confirm") or event.is_action_pressed("start")):
        mansion_switch_stage = 1
        egg_dialogue_arrow.hide()
        egg_choice_panel.show()
        _align_menu_tick(egg_choice_cursor, egg_choice_panel.get_node("Yes"))
    elif mansion_switch_stage == 1:
        if event.is_action_pressed("move_up") or event.is_action_pressed("move_down"):
            mansion_switch_index = 1 - mansion_switch_index
            _align_menu_tick(egg_choice_cursor, egg_choice_panel.get_node("Yes" if mansion_switch_index == 0 else "No"))
        elif event.is_action_pressed("confirm") or event.is_action_pressed("start"):
            mansion_switch_stage = 2
            mansion_switch_answered.emit(mansion_switch_index == 0)
        else:
            return
    else:
        return
    get_viewport().set_input_as_handled()

func _on_egg_pickup_prompt_requested(cell: Vector2i) -> void:
    if egg_pickup_open or battle_active or game_menu_open or craft_menu_open or build_menu_open:
        return
    egg_pickup_open = true
    egg_pickup_stage = 0
    egg_pickup_index = 0
    egg_pickup_cell = cell
    world.set_gameplay_enabled(false)
    message_panel.visible = false
    egg_dialogue_panel.visible = true
    egg_choice_panel.visible = false
    egg_dialogue_label.text = "Hey!  A POKéMON\negg!"
    egg_dialogue_arrow.visible = true

func _show_egg_pickup_choice() -> void:
    egg_pickup_stage = 1
    egg_pickup_index = 0
    egg_dialogue_label.text = "Pick it up?"
    egg_dialogue_arrow.visible = false
    egg_choice_panel.visible = true
    _update_egg_pickup_cursor()

func _update_egg_pickup_cursor() -> void:
    if egg_choice_cursor == null:
        return
    # User-requested one-pixel upward adjustment to both egg choice ticks.
    _align_menu_tick(egg_choice_cursor, egg_choice_panel.get_node("Yes" if egg_pickup_index == 0 else "No"))

func _close_egg_pickup_prompt() -> void:
    egg_pickup_open = false
    egg_pickup_stage = 0
    egg_pickup_index = 0
    egg_pickup_cell = Vector2i(-2147483648, -2147483648)
    if egg_dialogue_panel != null:
        egg_dialogue_panel.visible = false
    if egg_choice_panel != null:
        egg_choice_panel.visible = false
    if (
            started and not battle_active and not game_menu_open
            and not craft_menu_open and not build_menu_open
            and not storage_menu_open and not trainer_tip_open
        ):
        world.set_gameplay_enabled(true)

func _handle_egg_pickup_input(event: InputEvent) -> void:
    if egg_pickup_stage == 0:
        if event.is_action_pressed("confirm") or event.is_action_pressed("start"):
            _show_egg_pickup_choice()
            get_viewport().set_input_as_handled()
        elif event.is_action_pressed("cancel"):
            _close_egg_pickup_prompt()
            get_viewport().set_input_as_handled()
        return

    if event.is_action_pressed("move_up") or event.is_action_pressed("move_down"):
        egg_pickup_index = 1 - egg_pickup_index
        _update_egg_pickup_cursor()
        get_viewport().set_input_as_handled()
    elif event.is_action_pressed("cancel"):
        _close_egg_pickup_prompt()
        get_viewport().set_input_as_handled()
    elif event.is_action_pressed("confirm") or event.is_action_pressed("start"):
        var chosen_cell := egg_pickup_cell
        var take_egg := egg_pickup_index == 0
        _close_egg_pickup_prompt()
        if take_egg and world.has_method("confirm_wild_egg_pickup"):
            world.call("confirm_wild_egg_pickup", chosen_cell)
        get_viewport().set_input_as_handled()

func _on_egg_collected(species: String) -> void:
    var egg_record: Dictionary = {}
    if world.has_method("take_pending_egg_record"):
        egg_record = world.call("take_pending_egg_record")
    if bool(egg_record.get("dropped_party_egg", false)):
        for key in ["dropped_party_egg", "house_door", "house_floor", "x", "y"]: egg_record.erase(key)
        var destination := _route_received_pokemon(egg_record)
        world.play_source_sound("Berry_Get")
        dialogs.show_message("You picked up the EGG." if destination == "PARTY" else "The EGG was sent to storage.")
        return
    if egg_record.is_empty():
        egg_record = {
            "species": species.to_lower(),
            "egg_species": species.to_lower(),
            "level": 5,
            "hatch_cycles": maxi(
                1, int(PokemonData.info(species).get("egg_cycles", 20))
            ),
            "inherited_moves": []
        }
    species = String(egg_record.get(
        "egg_species", egg_record.get("species", species)
    )).to_lower()
    var level := maxi(1, int(egg_record.get("level", 5)))
    var cycles := maxi(1, int(egg_record.get(
        "hatch_cycles", PokemonData.info(species).get("egg_cycles", 20)
    )))
    var egg := _pokemon_from_egg_record(egg_record, species, level)
    egg["is_egg"] = true
    egg["egg_species"] = species
    egg["hatch_cycles"] = cycles
    egg["hatch_steps"] = maxi(
        1, cycles * PokemonEcology.EGG_STEP_INTERVAL - egg_step_timer
    )
    egg["hp"] = 0
    var destination := _route_received_pokemon(egg)
    world.play_source_sound("Berry_Get")
    var notice := _received_pokemon_notice(egg, destination)
    dialogs.show_message("%s received an EGG." % player_model_name.text.strip_edges() if notice.is_empty() else notice)

func _on_player_stepped() -> void:
    egg_step_timer = wrapi(
        egg_step_timer + 1, 0, PokemonEcology.EGG_STEP_INTERVAL
    )
    var advance_cycle := egg_step_timer == 0
    friendship_step_timer = wrapi(
        friendship_step_timer + 1,
        0,
        PokemonEcology.FRIENDSHIP_STEP_INTERVAL
    )
    if friendship_step_timer == 0:
        for party_index in range(caught_pokemon.size()):
            var raw_party_record = caught_pokemon[party_index]
            if typeof(raw_party_record) != TYPE_DICTIONARY:
                continue
            var party_record := raw_party_record as Dictionary
            if bool(party_record.get("is_egg", false)):
                continue
            var happiness := mini(
                PokemonEcology.MAX_HAPPINESS,
                int(party_record.get(
                    "happiness", party_record.get("friendship", 70)
                )) + 1
            )
            party_record["happiness"] = happiness
            party_record["friendship"] = happiness
            caught_pokemon[party_index] = party_record
    for index in range(caught_pokemon.size()):
        if typeof(caught_pokemon[index]) != TYPE_DICTIONARY:
            continue
        var entry: Dictionary = caught_pokemon[index]
        if not bool(entry.get("is_egg", false)):
            continue
        var cycles := int(entry.get("hatch_cycles", -1))
        if cycles < 0:
            cycles = maxi(1, ceili(
                float(entry.get("hatch_steps", EGG_HATCH_STEPS))
                / float(PokemonEcology.EGG_STEP_INTERVAL)
            ))
        if advance_cycle:
            cycles = maxi(0, cycles - 1)
        entry["hatch_cycles"] = cycles
        entry["hatch_steps"] = maxi(
            0, cycles * PokemonEcology.EGG_STEP_INTERVAL - egg_step_timer
        )
        if cycles > 0:
            caught_pokemon[index] = entry
            continue
        var species := String(entry.get(
            "egg_species", entry.get("species", "pidgey")
        )).to_lower()
        var level := maxi(1, int(entry.get("level", 5)))
        var hatched := _pokemon_from_egg_record(entry, species, level)
        hatched["happiness"] = 100
        hatched["friendship"] = 100
        await _run_egg_hatch_sequence(index, hatched)
        # PlayerStanding returns after the first ready egg; another ready egg
        # is handled on a later step instead of merging hatch sequences.
        return

func _ensure_party_ecology_id(index: int) -> String:
    if index < 0 or index >= caught_pokemon.size():
        return ""
    var entry = caught_pokemon[index]
    if typeof(entry) != TYPE_DICTIONARY:
        return ""
    var record := entry as Dictionary
    var ecology_id := String(record.get("party_ecology_id", ""))
    var occupied := {}
    var duplicate := false
    for other_index in range(caught_pokemon.size()):
        var other = caught_pokemon[other_index]
        if typeof(other) != TYPE_DICTIONARY: continue
        var other_id := String(other.get("party_ecology_id", ""))
        if not other_id.is_empty(): occupied[other_id] = true
        if other_index < index and not ecology_id.is_empty() and other_id == ecology_id:
            duplicate = true
    if ecology_id.is_empty() or duplicate:
        ecology_id = "party:%d" % next_party_ecology_id
        while occupied.has(ecology_id):
            next_party_ecology_id += 1
            ecology_id = "party:%d" % next_party_ecology_id
        next_party_ecology_id += 1
        record["party_ecology_id"] = ecology_id
        caught_pokemon[index] = record
    return ecology_id

func _on_pokemon_ecology_changed(pokemon_data: Dictionary) -> void:
    var ecology_id := String(pokemon_data.get("party_ecology_id", ""))
    if ecology_id.is_empty():
        return
    for index in range(caught_pokemon.size()):
        var raw_record = caught_pokemon[index]
        if typeof(raw_record) != TYPE_DICTIONARY:
            continue
        var record := raw_record as Dictionary
        if String(record.get("party_ecology_id", "")) != ecology_id:
            continue
        for property in ["happiness", "friendship"]:
            if pokemon_data.has(property):
                record[property] = pokemon_data[property]
        caught_pokemon[index] = record
        return

func _pokemon_from_egg_record(
        egg_record: Dictionary, species: String, level: int
    ) -> Dictionary:
    var pokemon := BattleEngine.make_pokemon(species, level, battle_rng, egg_record)
    # This helper produces the hatched Pokemon. Egg collection adds its egg
    # markers again afterward, while actual hatching must not retain them.
    for egg_property in ["is_egg", "egg_species", "hatch_cycles", "hatch_steps"]:
        pokemon.erase(egg_property)
    for property in [
            "gender", "shiny", "is_shiny", "generation",
            "parent_ids", "inherited_moves", "personality", "nature",
            "ability_slot", "ivs", "evs", "original_trainer", "trainer_id",
            "met_level", "met_location", "pokeball", "ribbons", "markings", "pokerus"
        ]:
        if egg_record.has(property):
            pokemon[property] = egg_record[property]
    if egg_record.has("shiny") or egg_record.has("is_shiny") or egg_record.has("isShiny"):
        pokemon["shiny"] = PokemonData.is_shiny(egg_record)
        pokemon["is_shiny"] = bool(pokemon["shiny"])

    var moves: Array[String] = []
    for raw_move in pokemon.get("moves", []):
        moves.append(String(raw_move).to_upper().replace(" ", "_"))
    var inherited_index := moves.size() if moves.size() < 4 else 0
    var inherited = egg_record.get("inherited_moves", [])
    if typeof(inherited) == TYPE_ARRAY:
        for raw_move in inherited:
            var move := String(raw_move).to_upper().replace(" ", "_")
            if PokemonData.move_info(move).is_empty() or moves.has(move):
                continue
            if moves.size() < 4:
                moves.append(move)
            else:
                moves[inherited_index] = move
            inherited_index = (inherited_index + 1) % 4
    pokemon["moves"] = moves
    var pp := {}
    for move in moves:
        pp[move] = int(PokemonData.move_info(move).get("pp", 35))
    pokemon["pp"] = pp
    pokemon["hp"] = maxi(1, int(pokemon.get("max_hp", 1)))
    pokemon["status"] = ""
    pokemon["status_counter"] = 0
    pokemon["toxic_counter"] = 0
    return pokemon

func _on_structure_action(action: String) -> void:
    if action.begins_with("PLANT_HOLE:"):
        bag_menu.open_planting_bag(Vector2i(int(action.get_slice(":",1)), int(action.get_slice(":",2))))
    elif action == "SHORE_SURF":
        await _prompt_shore_surf()
    elif action == "DRESSER":
        appearance.next_color()
        appearance.apply_world_player_textures()
        dialogs.show_message("Changed outfit color to %s." % PLAYER_COLOR_NAMES[player_color_index])
    elif action == "VANITY":
        appearance.next_color()
        appearance.apply_world_player_textures()
        dialogs.show_message("The VANITY changed your appearance to %s." % PLAYER_COLOR_NAMES[player_color_index])
    elif action.begins_with("BED:"):
        await _prompt_bed_rest(Vector2i(int(action.get_slice(":",1)),int(action.get_slice(":",2))))
    elif action.begins_with("STORAGE:"):
        storage.open_storage_menu(action.trim_prefix("STORAGE:"))
    elif action.begins_with("SIGN_EDIT:"):
        var parts := action.split(":", true, 3)
        if parts.size() >= 4:
            sign_edit_mode = "SIGN"
            sign_dialog.title = "Write on the sign"
            sign_edit.placeholder_text = "Sign text"
            sign_edit_cell = Vector2i(int(parts[1]), int(parts[2]))
            sign_edit.text = String(parts[3])
            sign_dialog.popup_centered(Vector2i(260, 104))
            sign_edit.grab_focus()
    elif action.begins_with("BEACON_EDIT:"):
        var beacon_parts := action.split(":", true, 3)
        if beacon_parts.size() >= 4:
            sign_edit_mode = "BEACON"
            sign_dialog.title = "Name the BEACON"
            sign_edit.placeholder_text = "Beacon name"
            sign_edit_cell = Vector2i(int(beacon_parts[1]), int(beacon_parts[2]))
            sign_edit.text = String(beacon_parts[3])
            sign_dialog.popup_centered(Vector2i(260, 104))
            sign_edit.grab_focus()
    elif action.begins_with("MANSION_SWITCH:"):
        var parts := action.split(":")
        if parts.size() != 3 or mansion_switch_open or _field_ui_blocks_gameplay():
            return
        mansion_switch_open = true
        mansion_switch_stage = 0
        mansion_switch_index = 0
        world.set_gameplay_enabled(false)
        message_panel.hide()
        egg_dialogue_label.text = "A hidden switch! Press it?"
        egg_dialogue_arrow.show()
        egg_dialogue_panel.show()
        egg_choice_panel.hide()
        var pressed: bool = await mansion_switch_answered
        egg_dialogue_panel.hide()
        egg_choice_panel.hide()
        await get_tree().create_timer((20.0 if pressed else 3.0) / 60.0).timeout
        if pressed:
            world.play_source_sound("enter1")
            SourceMansionRuntime.press_switch(world, Vector2i(int(parts[1]), int(parts[2])))
        mansion_switch_open = false
        world.set_gameplay_enabled(not _field_ui_blocks_gameplay())
    elif action.begins_with("MANSION_LOCK:"):
        if int(inventory.get("SECRET KEY", 0)) <= 0:
            dialogs.show_message("It's locked...")
            return
        var parts := action.split(":")
        if parts.size() != 3:
            return
        var cell := Vector2i(int(parts[1]), int(parts[2]))
        if world.unlock_mansion_door(cell):
            inventory["SECRET KEY"] = int(inventory.get("SECRET KEY", 0)) - 1
            dialogs.show_message("The SECRET KEY opened the door!")
    elif action.begins_with("ODD_KEYSTONE:"):
        var parts := action.split(":")
        if parts.size() != 4:
            return
        var cell := Vector2i(int(parts[1]), int(parts[2]))
        var remaining := maxi(0, int(parts[3]))
        var available := int(inventory.get("LIFE FORCE", 0))
        if available <= 0:
            dialogs.show_message("A voice whispers from within... bring %d..." % remaining)
            return
        var used := int(world.call("add_keystone_life_force", cell, mini(available, remaining)))
        inventory["LIFE FORCE"] = maxi(0, available - used)

func _on_item_collected(item_name: String) -> void:
    if is_instance_valid(coop_game) and coop_game.active and coop_game.building.collect({ItemData.normalize_name(item_name):1}):return
    if String(world.get("active_field_move")) == "DIG":
        _on_dig_reward_collected({item_name:1})
        return
    CraftingData.grant(inventory, ItemData.normalize_name(item_name), 1)
    var normalized := ItemData.normalize_name(item_name)
    dialogs.show_acquired_resource(normalized, 1)

## touch_config_panel.gd under its old names, for the scripts and tests that call them on main.
func _open_touch_config(from_options: bool = false) -> void: touch_config_panel.open_touch_config(from_options)


func _open_modding_menu() -> void:
    touch_config.hide()
    if not is_instance_valid(mod_menu_panel):
        mod_menu_panel=preload("res://scripts/modding_menu.gd").new()
        $UI.add_child(mod_menu_panel)
        mod_menu_panel.configure(self)
    mod_menu_panel.open()

func _open_game_files_menu() -> void:
    touch_config.hide()
    if not is_instance_valid(game_files_menu):
        game_files_menu=preload("res://scripts/game_files_menu.gd").new()
        $UI.add_child(game_files_menu)
        game_files_menu.configure(self)
    game_files_menu.open()

var mod_menu_panel: Control

const START_DOUBLE_TAP_SECONDS := 0.28
var start_menu_ticket := 0
var start_menu_pending := false
var start_menu_held := false

func _prompt_shore_surf() -> void:
    var party_index := move_wheel.find_field_move_pokemon_index("SURF")
    if party_index < 0 or _field_ui_blocks_gameplay():
        return
    var target: Vector2i = world._player_cell() + world._facing_cell()
    if not world._can_prompt_shore_surf(target):
        return
    # Reuse the tested two-stage egg/switch dialogue and its exact tick offsets.
    mansion_switch_open = true
    mansion_switch_stage = 0
    mansion_switch_index = 0
    world.set_gameplay_enabled(false)
    message_panel.hide()
    egg_dialogue_label.text = "Want to SURF?"
    egg_dialogue_arrow.show()
    egg_dialogue_panel.show()
    egg_choice_panel.hide()
    var accepted: bool = await mansion_switch_answered
    egg_choice_panel.hide()
    egg_dialogue_arrow.hide()
    if accepted and world._can_prompt_shore_surf(target):
        _ensure_party_ecology_id(party_index)
        var pokemon: Dictionary = caught_pokemon[party_index]
        var name := String(pokemon.get("nickname", "")).strip_edges()
        if name.is_empty(): name = PokemonData.battle_display_name(String(pokemon.get("species", "POKEMON")))
        egg_dialogue_label.text = "%s is using SURF!" % name.to_upper()
        await get_tree().create_timer(3.0 / 60.0).timeout
        _play_pokemon_cry(pokemon)
        mansion_switch_stage = 3
        egg_dialogue_arrow.show()
        await mansion_switch_answered
        egg_dialogue_arrow.hide()
        if world.set_active_field_move(pokemon, "SURF"):
            world.present_field_move_pokemon()
            var entry := create_tween()
            entry.tween_property(world.player, "position", world._cell_center(target), 16.0 / 120.0)
            await entry.finished
    else:
        await get_tree().create_timer(10.0 / 60.0).timeout
    egg_dialogue_panel.hide()
    mansion_switch_open = false
    world.set_gameplay_enabled(not _field_ui_blocks_gameplay())

func _prompt_bed_rest(cell: Vector2i) -> void:
    if _field_ui_blocks_gameplay(): return
    mansion_switch_open = true
    mansion_switch_stage = 0
    mansion_switch_index = 0
    world.set_gameplay_enabled(false)
    message_panel.hide()
    egg_dialogue_label.text = "Do you want to sleep?"
    egg_dialogue_arrow.show()
    egg_dialogue_panel.show()
    egg_choice_panel.hide()
    var accepted: bool = await mansion_switch_answered
    egg_choice_panel.hide()
    egg_dialogue_panel.hide()
    egg_dialogue_arrow.hide()
    mansion_switch_open = false
    if accepted:
        field_item_busy = true
        await get_tree().create_timer(20.0/60.0).timeout
        if world.begin_bed_rest(cell):
            sleeping_bag_heal_accumulator = 0.0
            return
        field_item_busy = false
    world.set_gameplay_enabled(not _field_ui_blocks_gameplay())


func _world_grid_key(grid: Vector2i) -> String:
    return "%d,%d" % [grid.x, grid.y]

func _show_flying_edge_sky() -> void:
    var bounds: Rect2i = world.get_map_bounds()
    if not is_instance_valid(edge_sky):
        edge_sky = preload("res://scripts/world_boundary_water.gd").new()
        edge_sky.name = "WorldBoundaryWater"
        world.get_node("GroundLayer").add_child(edge_sky)
        edge_sky.configure(world)
    edge_sky.visible = true
    var camera = world.player.camera
    camera.limit_left = bounds.position.x*16-192
    camera.limit_top = bounds.position.y*16-192
    camera.limit_right = bounds.end.x*16+192
    camera.limit_bottom = bounds.end.y*16+192

func check_flying_map_edge() -> void:
    if not started or generating or edge_travel_busy or _field_ui_blocks_gameplay():
        return
    if world.active_area_id != "OVERWORLD" or world.active_field_move not in ["FLY","SURF"]: return
    _show_flying_edge_sky()
    var bounds: Rect2i = world.get_map_bounds()
    var cell: Vector2i = world._player_cell()
    if bounds.has_point(cell):
        if world.active_field_move != "SURF": return
        var facing: Vector2i = world._facing_cell()
        var intent: Vector2 = world.player.input_router.movement_vector()
        if bounds.has_point(cell+facing) or (world.player.velocity.dot(Vector2(facing))<=0 and intent.dot(Vector2(facing))<=0): return
        cell += facing
    var direction := Vector2i.ZERO
    if cell.x < bounds.position.x: direction = Vector2i.LEFT
    elif cell.x >= bounds.end.x: direction = Vector2i.RIGHT
    elif cell.y < bounds.position.y: direction = Vector2i.UP
    elif cell.y >= bounds.end.y: direction = Vector2i.DOWN
    edge_travel_busy = true
    world.set_gameplay_enabled(false)
    _prompt_adjacent_world.call_deferred(direction)

func _prompt_adjacent_world(direction: Vector2i) -> void:
    mansion_switch_open = true
    mansion_switch_stage = 0
    mansion_switch_index = 0
    message_panel.hide()
    egg_dialogue_label.text = "Going further will take you to a new area... keep going?"
    egg_dialogue_arrow.show()
    egg_dialogue_panel.show()
    egg_choice_panel.hide()
    var accepted: bool = await mansion_switch_answered
    egg_choice_panel.hide()
    egg_dialogue_arrow.hide()
    egg_dialogue_panel.hide()
    if accepted:
        await _travel_adjacent_world(direction)
    else:
        var bounds: Rect2i = world.get_map_bounds()
        var cell: Vector2i = world._player_cell()
        cell.x = clampi(cell.x, bounds.position.x, bounds.end.x-1)
        cell.y = clampi(cell.y, bounds.position.y, bounds.end.y-1)
        world.player.position = world._cell_center(cell)
        world.player.facing = -Vector2(direction)
        world._place_field_helper_live()
    mansion_switch_open = false
    edge_travel_busy = false
    world.set_gameplay_enabled(not _field_ui_blocks_gameplay())

func _travel_adjacent_world(direction: Vector2i) -> void:
    var online_destination:Dictionary={}
    if is_instance_valid(coop_game) and coop_game.active:
        online_destination=await coop_game.prepare_travel(current_world_grid+direction)
        if online_destination.has("error"):dialogs.show_message(String(online_destination.error));return
    var bounds: Rect2i = world.get_map_bounds()
    var cell: Vector2i = world._player_cell()
    var fraction := Vector2(cell-bounds.position)/Vector2(bounds.size)
    var mount: Dictionary = world.active_field_pokemon.duplicate(true)
    var travel_move := String(world.active_field_move)
    var elapsed: float = world.world_elapsed_seconds
    var key := _world_grid_key(current_world_grid)
    adjacent_worlds[key] = {"seed":world.world_seed,"size":world.map_size_index,"state":world.get_crafting_save_state()}
    current_world_grid += direction
    var destination: Dictionary = adjacent_worlds.get(_world_grid_key(current_world_grid), {})
    if not online_destination.is_empty():destination={} if online_destination.get("new",false) else online_destination
    var seed_value := int(destination.get("seed", 0))
    if seed_value == 0:
        var random := RandomNumberGenerator.new()
        random.randomize()
        seed_value = int(random.randi_range(1,2147483646))
    # Java chooses 40000, 50000, 54000 or 56000 radius parameters.
    var size_index := int(destination.get("size", randi_range(1,4)))
    generating = true
    var travel_view: Control
    if destination.is_empty():
        # A new area takes minutes to generate. It was shown as a plain grey
        # screen with the player hovering in it and no word of what was
        # happening, so it looked as if the game had stopped. It now has the
        # same sky, trainer tips and message as every other loading screen.
        generation_status.text = "GENERATING WORLD...\nPLEASE WAIT..."
        dialogs.show_generation_tip()
        generation_panel.show()
        await get_tree().process_frame
    else:
        generation_status.text = "LOADING...\nPLEASE WAIT...."
        generation_panel.show()
    await world.generate_world(seed_value, size_index, not destination.is_empty())
    if not world.generation_error.is_empty():
        current_world_grid -= direction
        # Preflight failure leaves the current world's terrain and items intact.
        world.player.position = world._cell_center(Vector2i(
            clampi(cell.x,bounds.position.x,bounds.end.x-1),
            clampi(cell.y,bounds.position.y,bounds.end.y-1)))
        world.player.facing = -Vector2(direction)
        # Failed preflight retains the existing mount along with the world.
        world.fly_phase = "HOVER"
        world.fly_height = 32.0
        world._place_field_helper_live()
        if is_instance_valid(travel_view): travel_view.queue_free()
        generation_panel.hide()
        generating = false
        dialogs.show_message(world.generation_error)
        return
    world.set_gameplay_enabled(false)
    if not destination.is_empty(): await world.restore_crafting_save_state(destination.state)
    world.world_elapsed_seconds = elapsed
    appearance.apply_world_player_textures()
    bounds = world.get_map_bounds()
    cell = bounds.position + Vector2i(Vector2(bounds.size)*fraction)
    cell.x = clampi(cell.x,bounds.position.x,bounds.end.x-1)
    cell.y = clampi(cell.y,bounds.position.y,bounds.end.y-1)
    if direction == Vector2i.LEFT: cell.x = bounds.end.x-1
    elif direction == Vector2i.RIGHT: cell.x = bounds.position.x
    elif direction == Vector2i.UP: cell.y = bounds.end.y-1
    else: cell.y = bounds.position.y
    world.player.position = world._cell_center(cell)
    world.player.facing = Vector2(direction)
    if travel_move == "SURF":
        # Find water along the destination edge rather than mounting on dry land.
        var water_cell := cell
        var found := false
        for offset in range(maxi(bounds.size.x,bounds.size.y)):
            for sign_value in [1,-1]:
                var candidate: Vector2i = cell + (Vector2i.DOWN if direction.x!=0 else Vector2i.RIGHT)*offset*sign_value
                if bounds.has_point(candidate) and world.terrain_kind_at(candidate)==0:
                    water_cell=candidate;found=true;break
            if found: break
        if found: world.player.position=world._cell_center(water_cell)
    world.set_active_field_move(mount, travel_move, travel_move=="SURF")
    world.fly_phase = "HOVER"
    world.fly_height = 32.0
    world._place_field_helper_live()
    world.begin_encounter_grace()
    # Generating a new area uncovers the map around wherever the player
    # stood in the area they left, which in the new one is somewhere they
    # have never been: a lone explored circle far from where they arrive.
    if destination.is_empty(): world.discovered_cells.clear()
    world.reveal_player_area()
    minimap.invalidate_travel_maps()
    _show_flying_edge_sky()
    world.player.camera.reset_smoothing()
    if is_instance_valid(coop_game) and coop_game.active:
        if not await coop_game.finish_travel():
            coop_game.end_session("ONLINE AREA COULD NOT BE SAVED. SESSION ENDED.")
            return
    await _draw_world_view()
    if is_instance_valid(travel_view): travel_view.queue_free()
    message_panel.hide()
    generation_panel.hide()
    generating = false

func _sync_pokedex_owned() -> void:
    pokedex_progress.seed_owned(caught_pokemon)
    pokedex_progress.seed_owned(pokemon_storage)
    pokedex_progress.seed_owned(world.deployed_pokemon)
    for cached_world in adjacent_worlds.values():
        if cached_world is Dictionary:
            var crafting: Dictionary = cached_world.get("state", {})
            pokedex_progress.seed_owned(crafting.get("deployed_pokemon", []))

## The overworld tiles draw by map block as the view nears them: the ones
## in view are drawn before the loading screen goes.
func _draw_world_view() -> void:
    for path in ["GroundLayer/ExactBaseTileStream", "DecorLayer/ExactUpperTileStream"]:
        var stream := world.get_node_or_null(path)
        if stream != null and stream.has_method("draw_view_async"): await stream.draw_view_async()
    await _warm_world_shaders()

## A canvas shader is compiled when it is first drawn: tens of ms each on a
## phone, so the first frame showing a coast, the tide, a night light or a
## swimming Pokemon stalled. Each one in the world is drawn once here, as a
## pixel under the loading screen: one in the first frame, then twice as many
## in each next one while the frames draw quickly (the shaders were compiled
## before), and one a frame after a frame that took long to draw (it compiled).
func _warm_world_shaders() -> void:
    if DisplayServer.get_name() == "headless": return
    var materials := {}
    for node in world.find_children("*", "CanvasItem", true, false):
        var material: Material = (node as CanvasItem).material
        if material != null: materials[material.shader if material is ShaderMaterial else material] = material
    for path in ["GroundLayer/ExactBaseTileStream", "DecorLayer/ExactUpperTileStream"]:
        # Animated tiles' shader: on TileSet tiles, not nodes.
        var stream := world.get_node_or_null(path)
        var shader = null if stream == null else stream.get("resident_shader")
        if shader is Shader:
            var material := ShaderMaterial.new()
            material.shader = shader
            materials[shader] = material
    for material in world.warm_up_materials(): materials[material.shader] = material
    # A Pokemon coming out of its ball is drawn as a silhouette first.
    var silhouette: ShaderMaterial = preload("res://scripts/ball_mechanics.gd").silhouette(Color.WHITE)
    materials[silhouette.shader] = silhouette
    var timing := {"pre": 0, "draw": 0.0}
    var on_pre := func(): timing.pre = Time.get_ticks_usec()
    var on_post := func(): timing.draw = (Time.get_ticks_usec() - int(timing.pre)) / 1000.0
    RenderingServer.frame_pre_draw.connect(on_pre)
    RenderingServer.frame_post_draw.connect(on_post)
    var warm := Node2D.new()
    warm.position = world.player.position
    world.add_child(warm)
    var pending: Array = materials.values()
    var batch := 1
    while not pending.is_empty():
        for dot in warm.get_children(): dot.queue_free()
        for material in pending.slice(0, batch):
            var dot := Node2D.new()
            dot.material = material
            dot.draw.connect(func(): dot.draw_rect(Rect2(0, 0, 1, 1), Color.WHITE))
            warm.add_child(dot)
        pending = pending.slice(batch)
        await get_tree().process_frame
        batch = 1 if float(timing.draw) > 6.0 else batch * 2
    warm.queue_free()
    RenderingServer.frame_pre_draw.disconnect(on_pre)
    RenderingServer.frame_post_draw.disconnect(on_post)


