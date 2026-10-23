# The host's check of a co-op wild battle (coop_wild_runtime.gd check_battle):
# a battle really played (BattleSession) and reported as it ended is "ok"; the
# same log reported as another ending, against another Pokemon than the one
# claimed, or with more experience than it gave is not; a battle without a log
# is "unreported". resolve() refuses a win or catch that is not "ok".
# Run: godot --headless --path project -s ../server/battle_check_test.gd
extends SceneTree

const Session = preload("res://scripts/battle_session.gd")
const Battle = preload("res://scripts/battle_engine.gd")
const Delta = preload("res://scripts/coop_world_delta.gd")
const CoopState = preload("res://scripts/coop_state.gd")
const Runtime = preload("res://scripts/coop_wild_runtime.gd")

var failed := 0
var checks := 0

func check(ok: bool, what: String) -> void:
    checks += 1
    if not ok:
        failed += 1
        printerr("BATTLE CHECK TEST FAIL: ", what)

class FakeGame:
    extends Node
    var state = CoopState.new()

## The usable move that hits hardest.
static func strongest(pokemon: Dictionary) -> String:
    var best := Session.first_usable_move(pokemon)
    var power := -1
    for move in pokemon.get("moves", []):
        var info := preload("res://scripts/pokemon_data.gd").move_info(String(move))
        if Battle.move_is_usable(pokemon, String(move)) and int(info.get("power", 0)) > power:
            best = String(move); power = int(info.get("power", 0))
    return best

static func plain(value: Variant) -> Variant:
    return Session.whole_numbers(JSON.parse_string(JSON.stringify(value)))

func _initialize() -> void:
    var rng := RandomNumberGenerator.new()
    rng.seed = 3
    var party: Array = [Battle.make_pokemon("machamp", 40, rng, {})]
    party[0]["party_ecology_id"] = "p1"
    var host_party: Array = plain(party)
    var wild := {"species":"rattata", "level":6, "x":4, "y":5, "gender":"male", "source_record":{"generation":1}}
    var context := Session.prepare_context({"kind":"wild", "id":"wild", "can_catch":true, "can_run":true, "fixed_level":true,
        "party":[{"species":"rattata", "level":6}], "terrain":"GRASSY"}, party)
    var session := Session.new()
    session.rng.seed = 11
    check(session.begin(context, party, {"POKE BALL":5}, {"time_of_day":"day", "wild_record":Runtime.wild_facts(wild, false)}), "the battle begins")
    var guard := 0
    while not session.finished and guard < 60:
        guard += 1
        if not session.pending.is_empty():
            match String(session.pending.kind):
                "switch": session.submit(0)
                "forget": session.submit(-1)
                "evolve": session.submit(false)
        else: session.submit({"kind":"move", "move":strongest(session.player)})
    check(session.finished and session.outcome == "defeated", "the battle is won (%s)" % session.outcome)
    var report: Dictionary = plain(session.replay_log(true))
    var after: Array = plain(session.party)

    var game := FakeGame.new()
    game.state.records["player/A"] = {"party":host_party, "inventory":{"POKE BALL":5}, "save":{}}
    game.state.records["wild_claim/0,0/77"] = {"actor":"A", "area":"0,0", "id":77, "record":Delta.encode(wild)}
    var runtime: Node = Runtime.new()
    runtime.game = game
    var args := {"area":"0,0", "wild_id":77, "outcome":"defeated", "calm":false, "battle":report, "profile":{"party":after}}
    check(runtime.check_battle("A", args) == "ok", "the battle as played: ok")
    var other := args.duplicate()
    other.outcome = "captured"
    check(runtime.check_battle("A", other) == "replay_defeated", "reported as a catch: the replay says defeated")
    game.state.records["wild_claim/0,0/77"].record = Delta.encode({"species":"mewtwo", "level":70, "x":4, "y":5})
    check(runtime.check_battle("A", args) == "wrong_enemy", "a battle with another Pokemon than the one claimed")
    game.state.records["wild_claim/0,0/77"].record = Delta.encode(wild)
    var greedy := args.duplicate(true)
    greedy.profile.party[0].exp = int(greedy.profile.party[0].exp) + 50000
    check(runtime.check_battle("A", greedy) == "rewards", "more experience than the battle gave")
    var forged := args.duplicate(true)
    forged.battle.inputs = [{"kind":"move", "move":"NOT A MOVE"}]
    check(runtime.check_battle("A", forged) == "inputs_do_not_fit", "inputs the battle never asked for")
    var bare := args.duplicate()
    bare.battle = {}
    check(runtime.check_battle("A", bare) == "unreported", "a result without a log")
    check(Runtime.same_pokemon(host_party, host_party) and not Runtime.same_pokemon(host_party, after), "same_pokemon: the same team, not one that gained a level or experience")
    check(Runtime.rewards_fit(after, after) and not Runtime.rewards_fit([{"species":"machamp", "party_ecology_id":"p1", "level":99, "exp":0}], after), "rewards_fit")
    runtime.free()
    game.free()
    print("BATTLE CHECK TEST: %d failed (of %d checks)" % [failed, checks])
    quit(1 if failed else 0)
