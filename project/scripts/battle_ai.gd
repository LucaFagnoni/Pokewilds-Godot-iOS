extends RefCounted
## What the enemy does in a battle (battle_session.gd): its move, whether a
## trainer heals or switches, and both enemy Pokemon's actions in a double
## battle. Draws from the battle's RNG in the order battles always have.
const Battle = preload("res://scripts/battle_engine.gd")

## The enemy's action in a single battle: a move ({"kind":"move", "move"...}),
## a trainer's SUPER POTION ({"kind":"item"}) or switch ({"kind":"switch", "index"}).
static func choose(session) -> Dictionary:
    var context: Dictionary = session.context
    var trainer := String(context.get("kind", "")) == "trainer"
    var enemy: Dictionary = session.enemy
    var choice := Battle.choose_ai_action(enemy, [session.player], [enemy],
        session.field, session.rng, int(context.get("ai_level", 2 if trainer else 1)))
    if not trainer:
        choice["kind"] = "move"
        return choice
    var heal_limit := int(context.get("trainer_heals", 1))
    var heals_used := int(context.get("_trainer_heals_used", 0))
    if heals_used < heal_limit and int(enemy.hp) > 0 and \
            int(enemy.hp) * 3 <= int(enemy.max_hp):
        return {"kind":"item", "item":"SUPER POTION"}
    session.prepare_enemy_records()
    if session.turn_count > 0 and int(enemy.volatile.get("trap_turns", 0)) <= 0 and \
            not bool(enemy.volatile.get("mean_look", false)):
        var switch_index := Battle.best_switch_index(session.enemy_party,
            [session.enemy_index], session.player, session.field)
        if switch_index >= 0 and (float(choice.get("score", 0.0)) < 18.0 or \
                int(enemy.hp) * 4 <= int(enemy.max_hp)):
            return {"kind":"switch", "index":switch_index}
    choice["kind"] = "move"
    return choice

## Adds the living enemy Pokemon's actions to a double battle's turn.
static func add_double_actions(session, actions: Array[Dictionary]) -> void:
    var context: Dictionary = session.context
    var player_entries: Array[Dictionary] = session.living("player")
    var player_targets: Array = []
    for entry in player_entries: player_targets.append(entry.pokemon)
    var enemy_entries: Array[Dictionary] = session.living("enemy")
    var enemy_targets: Array = []
    for entry in enemy_entries: enemy_targets.append(entry.pokemon)
    var reserved_switches: Array[int] = []
    var trainer := String(context.get("kind", "")) == "trainer"
    var double_heal_available := trainer and \
        int(context.get("_trainer_heals_used", 0)) < int(context.get("trainer_heals", 1))
    for enemy_entry in enemy_entries:
        var actor := enemy_entry.pokemon as Dictionary
        var choice := Battle.choose_ai_action(actor, player_targets,
            enemy_targets, session.field, session.rng, int(context.get("ai_level", 2)))
        if double_heal_available and int(actor.hp) * 3 <= int(actor.max_hp):
            actions.append({
                "kind":"enemy_item", "side":"enemy", "slot":int(enemy_entry.slot),
                "move":"", "target_slot":int(enemy_entry.slot), "spread":false
            })
            double_heal_available = false
            continue
        if trainer and float(choice.get("score", 0.0)) < 18.0:
            session.prepare_enemy_records()
            var excluded := [session.enemy_index, session.enemy_partner_index]
            excluded.append_array(reserved_switches)
            var switch_index := Battle.best_switch_index(session.enemy_party,
                excluded, session.player, session.field)
            if switch_index >= 0:
                reserved_switches.append(switch_index)
                actions.append({
                    "kind":"enemy_switch", "side":"enemy", "slot":int(enemy_entry.slot),
                    "switch_index":switch_index, "move":"", "target_slot":-1,
                    "spread":false
                })
                continue
        var target_slot := 0
        var target_pick := clampi(int(choice.get("target", 0)), 0,
            maxi(0, player_entries.size() - 1))
        if not player_entries.is_empty():
            target_slot = int(player_entries[target_pick].slot)
        actions.append({
            "side":"enemy", "slot":int(enemy_entry.slot),
            "move":String(choice.get("move", "STRUGGLE")),
            "target_slot":target_slot, "spread":bool(choice.get("spread", false))
        })
        if Battle.move_targets_self(String(choice.get("move", "STRUGGLE"))):
            actions[-1]["target_side"] = "enemy"
