class_name SourceEventData
extends RefCounted

# Event values in this file mirror PokeWilds 0.8.11's Tile/SpecialBattle
# classes.  Keeping them outside world.gd makes location triggers, save-state
# mutations, and battle presentation share one authoritative definition.

const REGI_SPECIES := [
    "REGISTEEL", "REGIROCK", "REGICE", "REGIDRAGO", "REGIELEKI"
]

const TRAINER_TIPS := [
    "Stand still while holding X to stop using a Field Move.",
    "You can craft POKEBALLS out of Apricorns at a campfire.",
    "If you white out during battle, you will return to the last place you used a sleeping bag.",
    "Using your sleeping bag will slowly restore your party's HP.",
    "Ghosts may appear in the woods at night. A campfire will ward them off.",
    "Use CUT on trees and tall grass to get building materials.",
    "POKEMON will lay EGGS when located near a compatible mate.",
    "Build fences to prevent your POKEMON from wandering off when you let them out of their POKEBALL.",
    "You can build a door between two roof tiles to build a back door to your house.",
    "Sleeping indoors will restore HP twice as fast as sleeping outdoors.",
    "Use CUT on buildings to remove them.",
    "Your POKEMON will be happier if fenced in and located near a shelter.",
    "POKEMON are happier in their natural habitat. Happy POKEMON may give you items!",
    "Sleeping in a bed will cure your POKEMON's status conditions over time.",
    "Be wary of taking EGGS near wild POKEMON. Angry parents may attack!",
    "Use the ESCAPE ROPE to return to the nearest location on the shore.",
    "You can plant Miracle Seeds and Apricorns to grow grass and trees.",
    "You can build a gate by building a door between two fences."
]

const FOSSIL_SPECIES := {
    "OLD AMBER": "aerodactyl",
    "HELIX FOSSIL": "omanyte",
    "DOME FOSSIL": "kabuto",
    "CLAW FOSSIL": "anorith",
    "ROOT FOSSIL": "lileep",
    "SHIELD FOSSIL": "shieldon",
    "SKULL FOSSIL": "cranidos"
}

const REGI_LORE := {
    "REGICE": "Cold... very cold... too cold... but even with heat... it lasts forever...",
    "REGIROCK": "Simple stones... such a creation... each one so unique... but only stones... even in the head...",
    "REGISTEEL": "Metals from underground... so tough... so flexible... yet so old... it has an unearthly presence...",
    "REGIDRAGO": "Such a sad sight... my child... incomplete... just a dragon's head... but you are still so strong...",
    "REGIELEKI": "Such a sad sight... my child... your electricity restrained... but you are still so strong..."
}

const REGI_CRIES := {
    "REGIELEKI": "Zizi zizizi.",
    "REGIDRAGO": "Zagd.",
    "REGISTEEL": "Ji-ji-ze-ji-zoh.",
    "REGIROCK": "Zaza zari za...",
    "REGICE": "Jakiih!"
}

const GHOST_SPECIES := [
    "litwick", "lampent", "chandelure", "mimikyu", "misdreavus",
    "sableye", "gastly", "haunter", "gengar"
]

static func event_spec(event_id: String) -> Dictionary:
    var key := event_id.to_lower()
    var common := {
        "id": key,
        "kind": "special",
        "can_run": false,
        "can_catch": true,
        "clear_on_capture": true,
        "clear_on_defeat": true,
        "party": []
    }
    if key in ["mega_charizard_x", "mega_charizard_y", "mega_venusaur", "mega_blastoise", "mega_gyarados", "mega_sharpedo", "mega_kangaskhan"]:
        common.merge({"intro": "", "party": [_member(key, 70)], "clear_on_defeat": false}, true)
        return common
    match key:
        "mewtwo":
            common.merge({
                "intro": "",
                "party": [_member("mewtwo", 50, ["PSYCHIC", "RECOVER", "SWIFT", "DISABLE"])],
                "special_every": 3,
                "source_mewtwo": true,
                "special_message": "A wave of psychic power unleashes!",
                "clear_on_defeat": false,
                "respawn_after_defeat": true
            }, true)
        "volcarona":
            common.merge({
                "intro": "Vraahhbrbrbr!",
                "party": [_member("volcarona", 60)],
                "clear_on_defeat": false
            }, true)
        "spiritomb":
            common.merge({
                "intro": "Yulaaah!",
                "party": [_member("spiritomb", 25)],
                "clear_on_defeat": false
            }, true)
        "doll_banette":
            common.merge({
                "intro": "The doll became animated... and attacked!",
                "party": [_member("banette", 24)]
            }, true)
        "doll_mimikyu":
            common.merge({
                "intro": "The doll became animated... and attacked!",
                "party": [_member("mimikyu", 24)]
            }, true)
        "regigigas":
            common.merge({
                "intro": "",
                "source_boss": "regigigas",
                "party": [_member("regigigas", 70)],
                "clear_on_defeat": false,
                "special_every": 3,
                "special_message": "The ground is shaking violently!"
            }, true)
        "mega_gengar":
            common.merge({
                "intro": "",
                "source_boss": "mega_gengar",
                "party": [_member("gengar", 70, ["SHADOW_CLAW", "NIGHT_SHADE", "LICK"], {
                    "base_stats": [300, 65, 80, 130, 170, 95],
                    "form": "mega", "nickname": "MEGA GENGAR", "catch_rate": 3
                })],
                "clear_on_defeat": false
            }, true)
        "ghost":
            common.merge({
                "kind": "ghost",
                "can_run": true,
                "intro": "A ghost appeared from the darkness!",
                "clear_on_defeat": true
            }, true)
        _:
            var species := key.to_upper()
            if species in REGI_SPECIES:
                common.merge({
                    "intro": String(REGI_CRIES.get(species, "%s awakened!" % species)),
                    "party": [_member(key, 40)],
                    "regi": true,
                    "clear_on_defeat": false
                }, true)
            else:
                return {}
    return common

static func trainer_spec(biome: String, route_level: int, trainer_id: String) -> Dictionary:
    var key := biome.to_upper()
    var teams := {
        "FOREST": ["caterpie", "pidgey", "pikachu"],
        "SAVANNA": ["rattata", "machop", "growlithe"],
        "MOUNTAIN": ["geodude", "zubat", "onix"],
        "DESERT": ["sandshrew", "trapinch", "cacnea"],
        "SNOW": ["swinub", "sneasel", "snorunt"],
        "WOODED_LAKE": ["poliwag", "oddish", "psyduck"]
    }
    var held_items := {
        "FOREST":["SILKY THREAD", "SOFT FEATHER", "MAGNET"],
        "SAVANNA":["BERRY JUICE", "HARD SHELL", "CHARCOAL"],
        "MOUNTAIN":["HARD STONE", "LUM BERRY", "HARD SHELL"],
        "DESERT":["SOFT SAND", "BERRY JUICE", "MIRACLE SEED"],
        "SNOW":["NEVERMELTICE", "LUM BERRY", "NEVERMELTICE"],
        "WOODED_LAKE":["MYSTIC WATER", "MIRACLE SEED", "PERSIM BERRY"]
    }
    var titles := {
        "FOREST": "BUG CATCHER", "SAVANNA": "YOUNGSTER",
        "MOUNTAIN": "HIKER", "DESERT": "RUIN MANIAC",
        "SNOW": "SKIER", "WOODED_LAKE": "FISHER"
    }
    var members: Array = []
    var level := clampi(route_level, 4, 60)
    var team: Array = teams.get(key, ["rattata"])
    var items: Array = held_items.get(key, [""])
    for member_index in range(team.size()):
        var extra := {}
        if member_index < items.size() and not String(items[member_index]).is_empty():
            extra["held_item"] = String(items[member_index])
        members.append(_member(String(team[member_index]), level, [], extra))
        level += 1
    var title := String(titles.get(key, "POKEMON RANGER"))
    var double_battle := key in ["FOREST", "WOODED_LAKE"]
    if double_battle:
        title = "TWINS" if key == "FOREST" else "RANGER DUO"
    return {
        "id": trainer_id,
        "kind": "trainer",
        "trainer_name": title,
        "intro": "%s wants to battle!" % title,
        "victory_text": "%s: You know this place well." % title,
        "can_run": false,
        "can_catch": false,
        "battle_format": "double" if double_battle else "single",
        "ai_level": 2,
        "trainer_heals": 1,
        "clear_on_defeat": false,
        "party": members
    }

static func _member(
        species: String,
        level: int,
        moves: Array = [],
        extra: Dictionary = {}
    ) -> Dictionary:
    var result := {"species": species.to_lower(), "level": level}
    if not moves.is_empty():
        result["moves"] = moves.duplicate()
    result.merge(extra, true)
    return result
