# SCons profile for a stripped Godot 4.7.2 export template: pass profile=<this file>
# plus target=template_release on the command line (a profile cannot set target).
# PokeWilds is 2D-only on the GL Compatibility renderer; everything else goes.
# The game is ~64k lines of GDScript: its CPU time is the interpreter, which
# -Oz (size_extra) slows down. -O2 costs a few MB of binary and saves CPU,
# that is battery.
optimize = "speed_trade"
debug_symbols = "no"

disable_3d = "yes"
disable_physics_3d = "yes"
disable_navigation_2d = "yes"
disable_navigation_3d = "yes"
disable_xr = "yes"
# disable_advanced_gui stays off: the game uses RichTextLabel and FileDialog.

vulkan = "no"
metal = "no"
opengl3 = "yes"
brotli = "no"
accesskit = "no"
sdl = "no"

# Only what scripts and imported resources actually need at runtime.
modules_enabled_by_default = "no"
module_gdscript_enabled = "yes"
module_godot_physics_2d_enabled = "yes"  # CharacterBody2D, CollisionShape2D
module_freetype_enabled = "yes"          # TTF fonts
module_text_server_fb_enabled = "yes"    # Latin text only: autowrap/trim
module_webp_enabled = "yes"              # every imported texture is lossless WebP
module_ogg_enabled = "yes"
module_vorbis_enabled = "yes"            # music, cries, mod audio
module_zip_enabled = "yes"               # ZIPReader for .pwmod packs
module_regex_enabled = "yes"
module_noise_enabled = "yes"             # FastNoiseLite world generation
module_mbedtls_enabled = "yes"           # HTTPS lobby list, Crypto
