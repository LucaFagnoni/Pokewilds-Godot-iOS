extends CanvasLayer
## The title screen's art (StartupSplash), laid out on the background's own
## pixels: the background's frames (trees bending in the wind, leaves, the
## lake), clouds drifting across the sky, and the logo, which drops in when
## the title first opens (intro) and now and then catches the light.

const FRAME_SECONDS := 0.2
## Each cloud: its region in title_clouds.png, starting column and row on the
## background, speed in background pixels a second. They pass behind the logo.
const CLOUDS := [
    [Rect2(0, 1, 24, 8), 20.0, 5.0, 0.9],
    [Rect2(25, 3, 16, 6), 160.0, 19.0, 0.6],
    [Rect2(42, 0, 32, 9), 95.0, 31.0, 0.75],
]
const SHINE_EVERY := 6.0
const SHINE_SECONDS := 0.7
const INTRO_SECONDS := 0.9
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
        holder.add_child(cloud)
        clouds.append(cloud)
        cloud_x.append(c[1])
    var shader := Shader.new()
    shader.code = SHINE_SHADER
    var shine := ShaderMaterial.new()
    shine.shader = shader
    shine.set_shader_parameter("size", logo.texture.get_size())
    logo.material = shine
    # Hidden through loading (the boot splash has no logo either) until intro().
    logo.visible = false

## The logo drops in from above, once: the first time the title opens.
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

func _process(delta: float) -> void:
    if not visible:
        return
    var frames := art.texture as AtlasTexture
    frame_time += delta
    if frame_time >= FRAME_SECONDS:
        frame_time -= FRAME_SECONDS
        frames.region.position.x = fmod(frames.region.position.x + frames.region.size.x, frames.atlas.get_width())
    # The background covers the screen keeping its proportions (Artwork's stretch
    # mode): the same scale and offset place the clouds on its pixels.
    var cells := frames.region.size
    var scale := maxf(art.size.x / cells.x, art.size.y / cells.y)
    var origin := (art.size - cells * scale) / 2.0
    var first := -origin.x / scale
    var last := (art.size.x - origin.x) / scale
    for i in clouds.size():
        var size: Vector2 = CLOUDS[i][0].size
        cloud_x[i] += CLOUDS[i][3] * delta
        if cloud_x[i] > last:
            cloud_x[i] = first - size.x
        var cloud := clouds[i]
        cloud.position = origin + Vector2(floorf(cloud_x[i]), CLOUDS[i][2]) * scale
        cloud.size = size * scale
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
