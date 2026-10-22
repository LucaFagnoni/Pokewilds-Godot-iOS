extends Panel
const Network=preload("res://scripts/coop_zerotier.gd")
const Settings=preload("res://scripts/game_options.gd")
var main:Node
var edit:LineEdit
var info:Label
func configure(owner_main:Node)->void:
    main=owner_main;name="ZeroTierSetup";position=Vector2(24,12);size=Vector2(272,156);z_index=550
    add_theme_stylebox_override("panel",Settings.style())
    main._source_ui_label(self,"Title",Vector2(12,10),Vector2(248,16),10,"ZEROTIER INTERNET")
    info=main._source_ui_label(self,"Info",Vector2(12,31),Vector2(248, 42.0),8,"Enter your managed IPv4 from ZeroTier.\nFriends must join the same approved network.")
    info.autowrap_mode=TextServer.AUTOWRAP_WORD_SMART
    edit=LineEdit.new();edit.position=Vector2(12,78);edit.size=Vector2(248,24);edit.max_length=15
    edit.add_theme_font_override("font",main.JOHTO_FONT);edit.add_theme_font_size_override("font_size",9)
    add_child(edit);edit.text=Network.address();edit.text_submitted.connect(func(_value):save())
    for entry in [["SAVE" if main.touch_on() else "A: SAVE",12,save],["BACK" if main.touch_on() else "B: BACK",142,close]]:
        var button=Button.new();button.text=entry[0];button.position=Vector2(entry[1],114);button.size=Vector2(118,28)
        button.add_theme_font_override("font",main.JOHTO_FONT);button.add_theme_font_size_override("font_size",9)
        button.add_theme_stylebox_override("normal",Settings.style());button.pressed.connect(entry[2]);add_child(button)
    edit.grab_focus()
    if DisplayServer.has_feature(DisplayServer.FEATURE_VIRTUAL_KEYBOARD):DisplayServer.virtual_keyboard_show(edit.text)
func accepts_text_key(event:InputEvent)->bool:
    return event is InputEventKey and event.keycode not in [KEY_ENTER,KEY_KP_ENTER,KEY_ESCAPE,KEY_BACK]
func handle(event:InputEvent)->void:
    if event.is_echo():return
    if event.is_action_pressed("cancel") or (event is InputEventKey and event.pressed and event.keycode in [KEY_ESCAPE,KEY_BACK]):close()
    elif event.is_action_pressed("confirm") or (event is InputEventKey and event.pressed and event.keycode in [KEY_ENTER,KEY_KP_ENTER]):save()
func save()->void:
    var value=edit.text.strip_edges()
    if not Network.valid_address(value):info.text="Enter the managed IPv4, not the network ID or device ID.";return
    if not Network.available(value):info.text="That address is not active here. Connect ZeroTier and check your managed IPv4.";return
    if Network.save_address(value)!=OK:info.text="Could not save the address. Please try again.";return
    close()
func close()->void:
    edit.release_focus()
    if DisplayServer.has_feature(DisplayServer.FEATURE_VIRTUAL_KEYBOARD):DisplayServer.virtual_keyboard_hide()
    main.options_menu.internet_setup=null
    main.options_menu.refresh()
    queue_free()
