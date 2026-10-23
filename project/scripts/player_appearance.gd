extends RefCounted

## The player's look: the colours and trainer models to pick from on the setup
## screen, and the walking, running, sitting, sleeping and battle textures of
## the chosen one (recoloured from the model's sheets).
## Split out of main.gd; reaches the game through `main`.

const TexturePixels = preload("res://scripts/texture_pixels.gd")
const PlayerLooks = preload("res://scripts/player_looks.gd")

var main: GameMain
var player_appearance_texture_cache: Dictionary = {}

func _init(owner_main: GameMain) -> void:
    main = owner_main

func previous_color() -> void:
    main.player_color_index = wrapi(main.player_color_index - 1, 0, PlayerLooks.PLAYER_TEXTURES.size())
    apply_player_appearance()

func next_color() -> void:
    main.player_color_index = wrapi(main.player_color_index + 1, 0, PlayerLooks.PLAYER_TEXTURES.size())
    apply_player_appearance()

func player_model_count() -> int:
    return PlayerLooks.PLAYER_MODEL_NAMES.size()

func previous_model() -> void:
    main.player_model_index = wrapi(
        main.player_model_index - 1, 0, player_model_count()
    )
    apply_player_appearance()

func next_model() -> void:
    main.player_model_index = wrapi(
        main.player_model_index + 1, 0, player_model_count()
    )
    apply_player_appearance()

func change_player_selector(direction: int) -> void:
    if main.menu_col == 1:
        if direction > 0:
            next_color()
        else:
            previous_color()
    elif main.menu_col == 2:
        if direction > 0:
            next_model()
        else:
            previous_model()

func _apply_player_color(index: int) -> void:
    main.player_color_index = clampi(index, 0, PlayerLooks.PLAYER_COLOR_VALUES.size() - 1)
    apply_player_appearance()

func apply_player_appearance() -> void:
    main.player_color_index = clampi(
        main.player_color_index, 0, PlayerLooks.PLAYER_COLOR_VALUES.size() - 1
    )
    main.player_model_index = clampi(
        main.player_model_index, 0, player_model_count() - 1
    )
    main.player_model_name.text = main.custom_player_name if not main.custom_player_name.is_empty() else PlayerLooks.PLAYER_MODEL_NAMES[main.player_model_index].to_upper()
    main._fit_player_name()
    main.player_preview.texture = player_appearance_texture(false)
    main.player_preview.hframes = 8
    main.player_preview.frame = 0
    main.player_color_swatch.texture = recolor_texture(
        preload("res://assets/source_exact/global/select_color1.png"),
        Color.WHITE,
        PlayerLooks.PLAYER_COLOR_VALUES[main.player_color_index],
        "swatch:%d" % main.player_color_index
    )

func player_appearance_texture(running: bool) -> Texture2D:
    var base: Texture2D = (
        main.lazy_texture(PlayerLooks.PLAYER_MODEL_RUN_TEXTURES[main.player_model_index])
        if running
        else main.lazy_texture(PlayerLooks.PLAYER_MODEL_WALK_TEXTURES[main.player_model_index])
    )
    return recolor_texture(
        base,
        PlayerLooks.PLAYER_MODEL_REPLACE_COLORS[main.player_model_index],
        PlayerLooks.PLAYER_COLOR_VALUES[main.player_color_index],
        "%s:%d:%d" % ["run" if running else "walk", main.player_model_index,
            main.player_color_index]
    )

func player_sitting_texture(frame: int = 0) -> Texture2D:
    var texture := recolor_texture(
        main.lazy_texture(PlayerLooks.PLAYER_MODEL_SITTING_TEXTURES[main.player_model_index]),
        PlayerLooks.PLAYER_MODEL_REPLACE_COLORS[main.player_model_index],
        PlayerLooks.PLAYER_COLOR_VALUES[main.player_color_index],
        "sitting:%d:%d" % [main.player_model_index, main.player_color_index])
    # Java Player.Sitting: front pose for stools/couch1, side pose for couch2-5.
    return main._source_texture_region(texture, Rect2(clampi(frame, 0, 2) * 16, 0, 16, 16))

func player_sleeping_texture() -> Texture2D:
    var recolored := recolor_texture(
        main.lazy_texture(PlayerLooks.PLAYER_MODEL_SLEEP_TEXTURES[main.player_model_index]),
        PlayerLooks.PLAYER_MODEL_REPLACE_COLORS[main.player_model_index],
        PlayerLooks.PLAYER_COLOR_VALUES[main.player_color_index],
        "sleep:%d:%d" % [main.player_model_index, main.player_color_index]
    )
    # Summer's source image is 24 px high, while the Java renderer uses the
    # same 24x16 sleeping region as every other character.
    if recolored.get_height() <= 16:
        return recolored
    var source_region := AtlasTexture.new()
    source_region.atlas = recolored
    source_region.region = Rect2(0, 0, 24, 16)
    return source_region

func recolor_texture(
        base: Texture2D, source_color: Color, target_color: Color,
        cache_key: String
    ) -> Texture2D:
    if player_appearance_texture_cache.has(cache_key):
        return player_appearance_texture_cache[cache_key] as Texture2D
    # Imported textures can share their decoded Image. Work on a copy so one
    # chosen color never contaminates another model/color cache entry.
    var image := Image.new()
    image.copy_from(TexturePixels.of(base))
    for y in range(image.get_height()):
        for x in range(image.get_width()):
            var pixel := image.get_pixel(x, y)
            if (pixel.r8 == source_color.r8 and pixel.g8 == source_color.g8
                    and pixel.b8 == source_color.b8 and pixel.a8 > 0):
                image.set_pixel(
                    x, y, Color(target_color.r, target_color.g,
                        target_color.b, pixel.a)
                )
    var texture := ImageTexture.create_from_image(image)
    player_appearance_texture_cache[cache_key] = texture
    return texture

func apply_world_player_textures() -> void:
    var player_node := main.world.get_node_or_null("Player")
    if player_node != null and player_node.has_method("set_character_textures"):
        player_node.call(
            "set_character_textures",
            player_appearance_texture(false),
            player_appearance_texture(true)
        )
        return
    var player_sprite := main.world.get_node_or_null("Player/Sprite2D") as Sprite2D
    if player_sprite != null:
        player_sprite.texture = player_appearance_texture(false)
        player_sprite.hframes = 8
        player_sprite.frame = 0
