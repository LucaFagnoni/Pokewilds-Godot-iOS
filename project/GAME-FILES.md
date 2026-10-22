# Live saves and settings — .112

Launch the updated Android app once, then close it. Long-press the PokeWilds launcher icon and choose **Game files**. Alternatively, open the system Files app and select **PokeWilds** in the sidebar. This is the live game folder, not an import/export copy.

It contains `game.ini`, `saves/`, and `world_cache/`. New save files appear after saving a game. On normal external-storage initialization, the physical path is `Android/data/com.bebo.pokewilds/files/`. If the game falls back to private storage, the Files location follows that same live folder.

Copy `.json` save files into `saves/`, and their matching `exact_v2_*.bin` caches into `world_cache/`. Include neighboring-world caches. LOAD discovers valid copied saves. Its `.sav` display label does not change the actual `.json` filename. Java-game saves are not automatically converted.

Close the game before copying files or editing settings. Back up saves and caches before replacing them. Uninstalling the app may remove app-specific storage, so keep backups elsewhere.

Android 11+ restricts normal file-manager access to Android/data. Use the PokeWilds location in the system Files app; some manufacturer file-manager apps do not display document providers. The shortcut opens the system manager when available.

Android Back, controller Select, the touch gesture, and in-game menus are unchanged. No mod loader or in-game file-transfer menu is enabled. Desktop storage remains Godot user://.
