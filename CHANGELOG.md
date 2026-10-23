# PokeWilds changelog

The first section below is the next version: it becomes the release notes and
the version description in Feather. Write it for players, not developers.

## Next version

### New
- **Double battles against other players:** when you challenge another player there is now DOUBLE BATTLE next to TRADE and BATTLE. If either of you has fewer than two Pokémon able to fight, it becomes a single battle.

### Improvements
- **New worlds are much faster to create:** world generation is about 15 times faster and uses far less memory.
- **Lighter saves:** save files are about 14 times smaller, saving pauses the game for half as long, and the LOAD list opens instantly. Old saves still load as before.
- **Smooth nights:** the game no longer drops frames at night or when a new day starts.
- **Smoother players in co-op:** other players move smoothly even when 4G stutters, with no teleporting.
- **Less battery:** players off screen are no longer drawn.
- **Cheaper walking:** the game does much less work on every step, especially in tall grass.

### Fixes
- **Dedicated server freezes:** autosaves, a player joining and a new day no longer freeze the server for half a second or more.
- **4G disconnects:** a player is only dropped after 30 seconds without signal, not 20.
- **Battles:** all battle logic now lives in one place, shared by wild, trainer, boss and PvP battles. It behaves exactly as before, checked against 30 recorded battles.

### Server and multiplayer
- **Update the server and the app together:** this version uses a new co-op protocol.
- **Automatic cleanup:** the server deletes old area files by itself after each save.
