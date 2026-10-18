extends CanvasLayer
## The world expands with the display. Existing menu coordinates stay 320x180.
const DESIGN := Vector2(320,180)
const FULL_SCREEN := ["TouchControls", "TouchChrome", "TouchBackdrop", "SourceBattleTransition", "WorldTravelView"]
var centers: Dictionary = {}

func _ready() -> void:
    get_viewport().size_changed.connect(refresh)
    child_entered_tree.connect(_added)
    refresh()

func _added(_child: Node) -> void:
    refresh.call_deferred()

func refresh() -> void:
    var extent := get_viewport().get_visible_rect().size
    var center := (extent-DESIGN)*0.5
    for child in get_children():
        if not child is Control: continue
        var control := child as Control
        if String(control.name) in FULL_SCREEN:
            control.set_anchors_preset(Control.PRESET_TOP_LEFT, true)
            control.position = Vector2.ZERO
            control.size = extent
            continue
        var id := control.get_instance_id()
        if not centers.has(id):
            var desired_position := control.position-Vector2(control.anchor_left,control.anchor_top)*(extent-DESIGN)
            var desired_size := control.size-Vector2(control.anchor_right-control.anchor_left,control.anchor_bottom-control.anchor_top)*(extent-DESIGN)
            control.set_anchors_preset(Control.PRESET_TOP_LEFT, true)
            control.position = desired_position
            control.size = desired_size
            centers[id] = Vector2.ZERO
        control.position += center-Vector2(centers[id])
        centers[id] = center
        # Full-screen artwork covers the expanded canvas behind centered content.
        for child_background in control.get_children():
            var background := child_background as Control
            if background == null: continue
            if not background is TextureRect and not background is ColorRect: continue
            if not background.has_meta("wide_background"):
                if background.size.x < 319.0 or background.size.y < 179.0: continue
                background.set_meta("wide_background", true)
                background.set_anchors_preset(Control.PRESET_TOP_LEFT, true)
            background.position = -control.position
            background.size = extent
