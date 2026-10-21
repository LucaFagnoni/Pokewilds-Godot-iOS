extends CanvasLayer
## The title screen's art (StartupSplash): the background's frames (trees
## bending in the wind, leaves, the lake), the loading screen's clouds drifting
## across the sky, and the logo, which drops in when the title first opens
## (intro) and now and then catches the light. Also the title's music.

const FRAME_SECONDS := 0.2
## Each cloud: its region in title_clouds.png (the loading screen's clouds,
## recoloured, one game pixel per pixel as there), where it starts (fractions of
## the screen's width and height) and its speed in game pixels a second. They
## pass behind the logo, over the menu's rows only by their wisps.
const CLOUDS := [
    [Rect2(51, 0, 64, 42), 0.58, 0.02, 2.5],
    [Rect2(0, 0, 35, 24), 0.06, 0.29, 4.0],
    [Rect2(36, 0, 14, 9), 0.33, 0.2, 5.5],
]
const SHINE_EVERY := 6.0
const SHINE_SECONDS := 0.7
const INTRO_SECONDS := 0.9
## The game has no title track of its own: lake6, also heard by wooded lakes,
## from the lofi pack when OPTIONS > LOFI MUSIC is on (as the world picks it).
const TITLE_MUSIC := "lake6"
const MUSIC_FADE_SECONDS := 1.5
## A band of light a few logo pixels wide, on the logo's own pixel grid.
const SHINE_SHADER := """
shader_type canvas_item;
uniform vec2 size;
uniform float band = -1000.0;
void fragment() {
    vec4 c = texture(TEXTURE, UV);
    vec2 t = floor(UV * size);
    float d = t.x + t.y * 0.6 - band;
    if (d >= 0.0 && d < 5.0) c.rgb = mix(c.rgb, vec3(1.0), 0.6);
    COLOR = c;
}
"""

@onready var art: TextureRect = $Artwork
@onready var logo: TextureRect = $Logo
var frame_time := 0.0
var clouds: Array[TextureRect] = []
var cloud_x: Array[float] = []
var shine_wait := 2.5
var shine_time := -1.0
var intro_played := false
var music: AudioStreamPlayer
var music_fade_in: Tween

func _ready() -> void:
    var holder := Control.new()
    holder.name = "Clouds"
    holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
    add_child(holder)
    move_child(holder, logo.get_index())
    var sheet := preload("res://assets/title_clouds.png")
    for c in CLOUDS:
        var look := AtlasTexture.new()
        look.atlas = sheet
        look.region = c[0]
        var cloud := TextureRect.new()
        cloud.texture = look
        cloud.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
        cloud.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
        cloud.mouse_filter = Control.MOUSE_FILTER_IGNORE
        cloud.size = c[0].size
        holder.add_child(cloud)
        clouds.append(cloud)
        cloud_x.append(NAN)  # placed once the screen has a size
    var shader := Shader.new()
    shader.code = SHINE_SHADER
    var shine := ShaderMaterial.new()
    shine.shader = shader
    shine.set_shader_parameter("size", logo.texture.get_size())
    logo.material = shine
    # Hidden through loading (the boot splash has no logo either) until intro().
    logo.visible = false

## The first time the title shows: the logo drops in from above (and the
## menus' music may start, see _process).
func intro() -> void:
    if intro_played:
        return
    intro_played = true
    logo.visible = true
    var lift := -logo.get_parent_area_size().y * 0.45
    logo.offset_top = lift
    logo.offset_bottom = lift
    var drop := create_tween().set_parallel().set_trans(Tween.TRANS_BOUNCE).set_ease(Tween.EASE_OUT)
    drop.tween_property(logo, "offset_top", 0.0, INTRO_SECONDS)
    drop.tween_property(logo, "offset_bottom", 0.0, INTRO_SECONDS)

## The menus' music: from the title through the other menus and the world
## setup. It fades out as soon as a loading screen goes up (a save loading, a
## world being made, a server being joined) and fades back in if that is
## cancelled back to the menus; the world's own music takes over in a game.
func _play_music() -> void:
    music = AudioStreamPlayer.new()
    music.name = "TitleMusic"
    var lofi := "res://assets/lofi/music/%s.ogg" % TITLE_MUSIC
    var use_lofi: bool = preload("res://scripts/game_options.gd").enabled("lofi_music") and ResourceLoader.exists(lofi)
    music.stream = load(lofi if use_lofi else "res://assets/environment/music/%s.ogg" % TITLE_MUSIC)
    add_child(music)
    AudioBalance.apply(music)  # the Music bus (MUSIC volume option) and this file's level
    music.finished.connect(music.play)
    var level := music.volume_db
    music.volume_db = -40.0
    music.play()
    music_fade_in = create_tween()
    music_fade_in.tween_property(music, "volume_db", level, MUSIC_FADE_SECONDS)

func _process(delta: float) -> void:
    var main := get_parent()
    var in_menus: bool = intro_played and not main.started and not main.generation_panel.visible
    if in_menus and music == null:
        _play_music()
    elif not in_menus and music != null:
        if music_fade_in != null:
            music_fade_in.kill()
        var fade := create_tween()
        fade.tween_property(music, "volume_db", -60.0, MUSIC_FADE_SECONDS)
        fade.tween_callback(music.queue_free)
        music = null
    if not visible:
        return
    var frames := art.texture as AtlasTexture
    frame_time += delta
    if frame_time >= FRAME_SECONDS:
        frame_time -= FRAME_SECONDS
        frames.region.position.x = fmod(frames.region.position.x + frames.region.size.x, frames.atlas.get_width())
    # Clouds move a whole game pixel at a time and come back in from the left.
    for i in clouds.size():
        if is_nan(cloud_x[i]):
            cloud_x[i] = CLOUDS[i][1] * art.size.x
        cloud_x[i] += CLOUDS[i][3] * delta
        if cloud_x[i] > art.size.x:
            cloud_x[i] = -clouds[i].size.x
        clouds[i].position = Vector2(floorf(cloud_x[i]), roundf(CLOUDS[i][2] * art.size.y))
    if intro_played:
        _shine(delta)

func _shine(delta: float) -> void:
    var shine := logo.material as ShaderMaterial
    if shine_time < 0.0:
        shine_wait -= delta
        if shine_wait <= 0.0:
            shine_time = 0.0
        return
    shine_time += delta
    var size: Vector2 = logo.texture.get_size()
    var across := size.x + size.y * 0.6 + 10.0
    shine.set_shader_parameter("band", -5.0 + across * shine_time / SHINE_SECONDS)
    if shine_time >= SHINE_SECONDS:
        shine.set_shader_parameter("band", -1000.0)
        shine_time = -1.0
        shine_wait = SHINE_EVERY
