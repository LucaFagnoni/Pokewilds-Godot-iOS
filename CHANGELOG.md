# PokeWilds changelog

The first section below is the next version: it becomes the release notes and
the version description in Feather. Write it for players, not developers.

## Next version

### Improvements
- **Smoother near lots of Pokémon:** wild Pokémon, habitat Pokémon and eggs now run in the game's engine itself. The habitat check, every second and a half, takes about a twelfth of the time it did, so the game no longer hitches near habitats, and the wild Pokémon around you cost about a third as much every frame. A dedicated server running areas full of players and Pokémon no longer takes a long frame for that check either.
- **Long-played worlds load faster:** the ground you have cut, dug, planted and built on is kept in a lighter form. Loading a world with a lot of it takes about 40% less time, saving it is quicker, and the short pause it caused once a second is gone. Old saves still load as before.

### Fixes
- **Dig sites no longer multiply when you load:** loading a world, or joining one in co-op, added a second set of the day's dig sites each time. A loaded world now has exactly the dig sites it was saved with.

## 0.10.419

### New
- **Double battles against other players:** when you challenge another player there is now DOUBLE BATTLE next to TRADE and BATTLE. If either of you has fewer than two Pokémon able to fight, it becomes a single battle.

### Improvements
- **New worlds are much faster to create:** world generation is about 15 times faster and uses far less memory.
- **Lighter saves:** save files are about 14 times smaller, saving pauses the game for half as long, and the LOAD list opens instantly. Old saves still load as before.
- **Smooth nights:** the game no longer drops frames at night or when a new day starts.
- **Smooth tides:** the tide coming in or going out now costs about 6 times less work, and no longer slows the game down while it turns.
- **Smoother players in co-op:** other players move smoothly even when 4G stutters, with no teleporting.
- **Less battery:** players off screen are no longer drawn.
- **Cheaper walking:** the game does much less work on every step, especially in tall grass.
- **Lighter wild Pokémon:** areas full of wild Pokémon, habitats and eggs cost far less: only the Pokémon on screen get a sprite, and finding nearby Pokémon is up to 40 times faster.
- **Digging and cutting in co-op answer at once:** the hole or the cut grass shows straight away, and the host decides what you find, so everyone sees the same ground and gets fair rewards.
- **Lighter co-op traffic:** wild Pokémon movement and changes to the ground are sent in a compact form; a server with players standing around sends about a fifth of what it did.
- **Fewer waits in co-op:** digging, cutting, picking up and storing things no longer save your whole game first.
- **Building in co-op answers at once:** building, painting and cutting down what you built show straight away, you can place several pieces in a row without waiting, and the host checks every piece and pays back what it cost. Signs, beacon names, torches, windows and the PLANT's seed are now the same for every player.
- **No hitches when players change areas:** a server no longer stutters for everyone while players walk into another area or a new one is made.
- **No hitches when a server saves:** autosaves no longer make a server stutter for everyone, even on a long-played world, and a save cut short by a crash or a power cut still loses nothing.

### Fixes
- **Dedicated server freezes:** autosaves, a player joining and a new day no longer freeze the server for half a second or more.
- **4G disconnects:** a player is only dropped after 30 seconds without signal, not 20.
- **Battles:** all battle logic now lives in one place, shared by wild, trainer, boss and PvP battles. It behaves exactly as before, checked against 30 recorded battles.
- **No more "REJOIN THE WORLD":** when the host turns down a dig, a cut or a build, the action is simply undone and you keep playing.
- **Wild battles in co-op:** when the host does not accept a battle's result, your party and bag go back to how they were and the game goes on instead of ending the session.
- **Server backups:** if a server's world file gets damaged, the server's backup copy is no longer overwritten by the damaged one at the next save.

### Downloads
- **The Android file is now called `Pokewilds-arm64.apk`:** it runs on 64-bit ARM phones, which is nearly every Android phone from the last years.

### Server and multiplayer
- **Update the server and the app together:** this version uses a new co-op protocol.
- **Automatic cleanup:** the server deletes old area files by itself after each save.
- **The server checks wild battles:** a win or a catch only counts when the server's own replay of the battle ends the same way (`enforce_battles` in server.cfg).
- **New areas made inside the server:** with the fast world generator the server makes new areas itself instead of starting a second copy of the game (`area_generation` in server.cfg).
- **The server moves every area's Pokémon:** on a dedicated server the wild and habitat Pokémon, their eggs, hordes and the roaming Megas are run by the server in every area, not by the first player's phone. Phones only show them: less battery and almost no upload, and a slow connection no longer freezes the Pokémon for everyone else (`population_authority` in server.cfg).
- **New areas arrive ready:** on a dedicated server, the first Pokémon and the roaming Megas of a new area are placed by the server, so your phone no longer places and uploads them when you walk into a new area, and every player sees the same Megas there. Items dropped on the ground now also stop the server's Pokémon from walking over them.
