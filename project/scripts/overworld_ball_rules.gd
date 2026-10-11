# SPDX-License-Identifier: MIT
# Adapted from the supplied BallSpecs, BallOdds, BallWorld and BallEligibility.
extends RefCounted
const Data = preload("res://scripts/pokemon_data.gd")
const BattleRules = preload("res://scripts/source_battle_rules.gd")
const BALLS = ["POKE BALL","GREAT BALL","ULTRA BALL","LOVE BALL","FAST BALL","LURE BALL","MOON BALL","FRIEND BALL","HEAVY BALL","DUSK BALL","NET BALL","DIVE BALL","QUICK BALL","HEAL BALL","NEST BALL","DREAM BALL","TIMER BALL","LEVEL BALL","MASTER BALL"]
const SPECIAL = ["mewtwo","regigigas","regirock","regice","registeel","regidrago","regieleki","darmanitanzen"]
const FIELD_MOVES = FieldMoveData.FIELD_MOVE_ORDER

static func throw_range(ball: String) -> int:
    match ball:
        "GREAT BALL", "PARK BALL": return 6
        "ULTRA BALL", "LURE BALL": return 7
        "MASTER BALL", "FAST BALL": return 8
        "HEAVY BALL": return 3
        "NEST BALL", "DREAM BALL": return 4
    return 5

static func frames_per_tile(ball: String) -> int:
    if ball=="HEAVY BALL": return 5
    return 1 if ball in ["FAST BALL","QUICK BALL"] else 3

static func reference_level(party: Array) -> float:
    var levels = []
    for mon in party:
        if not mon.get("is_egg",false): levels.append(int(mon.get("level",1)))
    if levels.is_empty(): return 0.0
    levels.sort()
    var lowest = levels[0]
    levels.reverse()
    while levels.size()<3: levels.append(lowest)
    return (levels[0]+levels[1]+levels[2])/3.0

static func catch_value(target: Dictionary, party: Array, ball: String, context: Dictionary) -> int:
    var info = Data.info(str(target.get("species","")))
    var rate = int(info.get("catch_rate",45))
    var level = int(target.get("level",1))
    var stealth = bool(context.get("stealth",false))
    var water = bool(context.get("water",false))
    var status = str(target.get("status","")).to_lower()
    var first = {}
    for member in party:
        if not member.get("is_egg",false) and int(member.get("hp",0))>0:
            first = member
            break
    var weight = BattleRules.source_catch_weight(info)
    match ball:
        "GREAT BALL", "PARK BALL": rate = int(PackedFloat32Array([rate*1.5])[0])
        "ULTRA BALL": rate *= 2
        "DUSK BALL":
            if context.get("dusk",false): rate = int(PackedFloat32Array([rate*3.5])[0])
        "FAST BALL":
            if int(info.get("stats",[0,0,0,0])[3])>=100: rate *= 4
        "QUICK BALL":
            if stealth: rate *= 5
        "LURE BALL":
            if water: rate *= 3
        "TIMER BALL":
            if context.get("alert",false): rate *= 3
        "NET BALL":
            if "WATER" in info.get("types",[]) or "BUG" in info.get("types",[]):
                rate = int(PackedFloat32Array([rate*PackedFloat32Array([1.0+PackedFloat32Array([0.30004883])[0]])[0]])[0])
        "DIVE BALL":
            if water: rate = int(PackedFloat32Array([rate*3.5])[0])
        "NEST BALL":
            if level<=29: rate = int(PackedFloat32Array([rate*PackedFloat32Array([(41.0-level)/10.0])[0]])[0])
        "DREAM BALL":
            if status=="sleep": rate *= 4
        "HEAVY BALL": rate += -20 if weight<100 else 0 if weight<200 else 20 if weight<300 else 30
        "LEVEL BALL":
            var party_level = int(first.get("level",0))
            rate *= 8 if party_level/4>level else 4 if party_level/2>level else 2 if party_level>level else 1
        "LOVE BALL":
            if str(first.get("species",""))==str(target.get("species","")) and str(first.get("gender","unknown"))!="unknown" and str(target.get("gender","unknown"))!="unknown" and first.get("gender")!=target.get("gender"):
                rate *= 8
        "MOON BALL":
            if target.get("species","") in ["clefairy","jigglypuff","nidorina","nidorino"]: rate *= 4
    var reference = reference_level(party)
    var factor = clampf(reference/level,0.1,1.0) if reference>0 and level>0 else 1.0
    rate = int(mini(255,rate)*(factor*(1.5 if stealth else 1.0)))
    var maximum = 3*int(target.get("max_hp",target.get("hp",20)))
    var hp = 2*int(target.get("hp",20))
    if maximum>255:
        maximum = maximum/2/2
        hp = hp/2/2
    var value = maxi(1,int((maximum-hp)*rate/maximum)) if maximum!=0 else 1
    return mini(255,value+(10 if status in ["sleep","freeze"] else 0))

static func roll(target: Dictionary, party: Array, ball: String, context: Dictionary, rng: RandomNumberGenerator) -> int:
    if ball=="MASTER BALL": return -1
    var value = catch_value(target,party,ball,context)
    if rng.randi_range(0,255)<=value: return -1
    var limits = [1,2,3,4,5,7,10,15,20,30,40,50,60,80,100,120,140,160,180,200,220,240,254,255]
    var chances = [63,75,84,90,95,103,113,126,134,149,160,169,177,191,201,211,220,227,234,240,246,251,253,255]
    var index = 0
    while value>limits[index]: index += 1
    for shake in range(3):
        if rng.randi_range(0,255)>=chances[index]: return shake
    return 3

static func classify(tile: SourceTile, direction: Vector2i) -> String:
    if tile==null: return "NONE"
    if tile.is_solid: return "WATER" if tile.is_water and not tile.is_lava else "BLOCKED"
    var name = tile.name+" "+tile.name_upper
    if tile.is_lava: return "BLOCKED"
    for blocked in ["gate","sign","door","stairs","warp"]:
        if blocked in name: return "BLOCKED"
    if tile.is_ledge:
        var facing = {Vector2i.UP:"up",Vector2i.DOWN:"down",Vector2i.LEFT:"left",Vector2i.RIGHT:"right"}.get(direction,"")
        if tile.ledge_dir=="up": return "BLOCKED" if facing=="down" else "OPEN"
        return "OPEN" if tile.ledge_dir==facing else "BLOCKED"
    return "WATER" if tile.is_water else "OPEN"

static func eligible(record: Dictionary) -> bool:
    var source = record.get("source_record",{})
    return not (record.get("owned",false) or record.get("is_egg",false) or record.get("is_ghost",false) or record.get("burrowed",false) or source.get("is_ghost",false) or source.get("is_trapping",false) or record.get("species","") in SPECIAL or record.get("ball_reserved",false))
