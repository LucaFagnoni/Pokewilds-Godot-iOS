class_name SourceBattleRules
extends RefCounted
const PokemonData = preload("res://scripts/pokemon_data.gd")

# Battle.java gen2CalcDamage / gen2DetermineCrit / gen2CalcIfCaught,
# original 0.8.11. Keep integer truncation and the source's unusual rules.
static func critical_threshold(move: String) -> int:
    if move in ["AERO_BLAST", "CRABHAMMER", "CROSS_CHOP", "KARATE_CHOP", "RAZOR_LEAF", "SLASH"]: return 64
    if move == "AIR_CUTTER": return 32
    return 17

static func damage(level: int, power: int, attack: int, defense: int,
        critical: bool, double_hit: bool, stab: bool, type_scale: float,
        random_roll: int) -> int:
    var amount := int(floor(floor((int(2 * level / 5) + 2) * float(attack) * power / maxi(1, defense)) / 50.0)) + 2
    if critical: amount *= 2
    if double_hit: amount *= 2
    amount = mini(997, amount) + 2
    if stab: amount = int(amount * 1.5)
    amount = int(amount * type_scale)
    return int(amount * random_roll / 255)

static func catch_threshold(target: Dictionary, modified_rate: int) -> int:
    var m := 3 * maxi(1, int(target.max_hp))
    var h := 2 * int(target.hp)
    if m > 255:
        m = int(int(m / 2) / 2)
        h = int(int(h / 2) / 2)
    var amount := maxi(1, int((m - h) * mini(255, modified_rate) / m))
    if String(target.get("status", "")) in ["SLEEP", "FREEZE"]: amount += 10
    return mini(255, amount)

static func ball_rate(target: Dictionary, player: Dictionary, ball: String, context: Dictionary) -> int:
    var info := PokemonData.info(String(target.species))
    var rate := int(target.get("catch_rate", info.get("catch_rate", 45)))
    var turn := int(context.get("turn", 1))
    match ball:
        "GREAT BALL", "PARK BALL": rate = int(rate * 1.5)
        "ULTRA BALL": rate *= 2
        "DUSK BALL":
            if bool(context.get("night", false)) or bool(context.get("indoors", false)): rate = int(rate * 3.5)
        "FAST BALL":
            if int(info.get("stats", [0,0,0,0])[3]) >= 100: rate *= 4
        "QUICK BALL":
            if turn == 1: rate *= 5
        "NET BALL":
            if "WATER" in target.get("types", []) or "BUG" in target.get("types", []): rate = int(_java_float(rate * minf(_java_float(1.0 + _java_float(turn * 0.300048828125)), 4.0)))
        "DIVE BALL":
            if bool(context.get("surfing", false)) or bool(context.get("fishing", false)): rate = int(rate * 3.5)
        "NEST BALL":
            if int(target.level) <= 29: rate = int(_java_float(rate * _java_float((41.0 - int(target.level)) / 10.0)))
        "DREAM BALL":
            if String(target.get("status", "")) == "SLEEP": rate *= 4
        "HEAVY BALL":
            var weight := source_catch_weight(info)
            rate += -20 if weight < 100.0 else 0 if weight < 200.0 else 20 if weight < 300.0 else 30
        "LEVEL BALL":
            if int(int(player.level) / 4) > int(target.level): rate *= 8
            elif int(int(player.level) / 2) > int(target.level): rate *= 4
            elif int(player.level) > int(target.level): rate *= 2
        "LOVE BALL":
            var a := String(player.get("gender", "unknown")).to_lower()
            var b := String(target.get("gender", "unknown")).to_lower()
            if a in ["male", "female"] and b in ["male", "female"] and a != b and String(player.species) == String(target.species): rate *= 8
        "MOON BALL":
            if String(target.species) in ["clefairy", "jigglypuff", "nidorina", "nidorino"]: rate *= 4
    return mini(255, rate)

static var _categories: Dictionary = {}
static func move_category(move_name: String) -> String:
    if _categories.is_empty():
        _categories = JSON.parse_string(FileAccess.get_file_as_string("res://data/source_move_categories.json"))
    # Attack.java treats a missing category as non-physical.
    return String(_categories.get(move_name.to_upper().replace(" ", "_"), "SPECIAL"))

static func accuracy_threshold(accuracy: int, attack_stage: int, evasion_stage: int) -> int:
    # Battle.getAttackAction: integer 255 scale, separate truncation per stage.
    var value := int(accuracy * 255 / 100)
    value = maxi(1, int(float(value) * float(maxi(3,3+attack_stage)) / float(maxi(3,3-attack_stage))))
    value = maxi(1, int(float(value) * float(maxi(3,3-evasion_stage)) / float(maxi(3,3+evasion_stage))))
    return mini(255,value)

static func effect_roll(chance: int, rng: RandomNumberGenerator) -> bool:
    var threshold := int(chance * 255 / 100)
    return threshold >= 255 or rng.randi_range(0,255) < threshold

# Pokemon.loadWeights keeps the first weight for each national dex number.
static var _catch_weights: Dictionary = {}
static func source_catch_weight(info: Dictionary) -> float:
    # These added forms have authored weights but no Java weight-table entry.
    if info.has("mega_habitat"): return float(info.get("weight_kg", 0.0))
    if _catch_weights.is_empty():
        _catch_weights = JSON.parse_string(FileAccess.get_file_as_string("res://data/source_catch_weights.json"))
    return float(_catch_weights.get(str(int(info.get("dex", 0))), info.get("weight_kg", 0.0)))

static func _java_float(value: float) -> float:
    return PackedFloat32Array([value])[0]
