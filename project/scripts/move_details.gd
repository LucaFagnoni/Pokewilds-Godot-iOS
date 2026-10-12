extends RefCounted
const Data = preload("res://scripts/pokemon_data.gd")
const Rules = preload("res://scripts/source_battle_rules.gd")
const EFFECTS = {
"NORMAL_HIT":"Deals damage.", "ALWAYS_HIT":"Bypasses accuracy checks.",
"SLEEP":"Puts the target to sleep.", "POISON":"Poisons the target.", "TOXIC":"Badly poisons the target.",
"BURN":"Burns the target.", "PARALYZE":"Paralyzes the target.", "CONFUSE":"Confuses the target.",
"POISON_HIT":"May poison the target.", "BURN_HIT":"May burn the target.", "FREEZE_HIT":"May freeze the target.",
"PARALYZE_HIT":"May paralyze the target.", "CONFUSE_HIT":"May confuse the target.", "FLINCH_HIT":"May make the target flinch.",
"MULTI_HIT":"Strikes multiple times.", "DOUBLE_HIT":"Strikes twice.", "POISON_MULTI_HIT":"Strikes twice. may poison.",
"TRIPLE_KICK":"Three hits with rising power.", "BEAT_UP":"Party members join the attack.",
"RECOIL_HIT":"Deals damage with recoil.", "LEECH_HIT":"Restores HP from damage dealt.", "DRAINING_KISS":"Restores HP from damage dealt.",
"DREAM_EATER":"Drains HP from a sleeping target.", "HEAL":"Restores the user's HP.", "HEAL_BELL":"Cures the party's status problems.",
"MORNING_SUN":"Restores HP. weather affects healing.", "SYNTHESIS":"Restores HP. weather affects healing.", "MOONLIGHT":"Restores HP. weather affects healing.",
"SELFDESTRUCT":"The user faints after attacking.", "OHKO":"Knocks out the target if it hits.",
"STATIC_DAMAGE":"Deals fixed damage.", "LEVEL_DAMAGE":"Damage equals the user's level.", "PSYWAVE":"Deals variable damage based on level.",
"SUPER_FANG":"Cuts the target's remaining HP.", "FALSE_SWIPE":"Leaves the target with at least 1 HP.",
"PRIORITY_HIT":"Has increased move priority.", "COUNTER":"Returns physical damage.", "MIRROR_COAT":"Returns special damage.",
"PROTECT":"Blocks attacks this turn.", "ENDURE":"Survives attacks with at least 1 HP.", "SUBSTITUTE":"Spends HP to create a substitute.",
"LEECH_SEED":"Drains the target's HP each turn.", "NIGHTMARE":"Hurts a sleeping target each turn.", "CURSE":"Effect depends on the user's type.",
"DESTINY_BOND":"Can take the attacker down too.", "PERISH_SONG":"Affected Pokemon faint after a countdown.",
"DISABLE":"Temporarily disables a used move.", "ENCORE":"Makes the target repeat its move.", "SPITE":"Reduces the target's move PP.",
"ATTRACT":"Infatuates a compatible target.", "SWAGGER":"Raises the target's Attack and confuses it.",
"MEAN_LOOK":"Prevents the target from escaping.", "TRAP_TARGET":"Traps and damages the target over time.",
"FORCE_SWITCH":"Forces the target out when allowed.", "TELEPORT":"Escapes when permitted.",
"REFLECT":"Reduces physical damage to the user's side.", "LIGHT_SCREEN":"Reduces special damage to the user's side.",
"MIST":"Protects against stat reduction.", "SAFEGUARD":"Protects against status conditions.", "SPIKES":"Sets a hazard on the opposing side.",
"RAIN_DANCE":"Starts rain.", "SUNNY_DAY":"Starts harsh sunlight.", "SANDSTORM":"Starts a sandstorm.",
"RESET_STATS":"Resets stat changes.", "PSYCH_UP":"Copies the target's stat changes.", "BATON_PASS":"Passes effects to a replacement.",
"FOCUS_ENERGY":"Raises the critical-hit rate.", "DEFENSE_CURL":"Raises Defense and supports rolling attacks.",
"BELLY_DRUM":"Spends HP to maximize Attack.", "ALL_UP_HIT":"May raise all combat stats.",
"LOCK_ON":"Helps the next attack hit.", "FORESIGHT":"Identifies the target for later attacks.",
"CONVERSION":"Changes the user's type from its moves.", "CONVERSION2":"Changes type to resist a used move.",
"TRANSFORM":"Copies the target's form and moves.", "MIMIC":"Temporarily copies a used move.", "SKETCH":"Permanently copies a used move.",
"MIRROR_MOVE":"Repeats the target's last move.", "METRONOME":"Uses a randomly selected move.", "SLEEP_TALK":"Uses another move while asleep.",
"SNORE":"Only works while asleep. may flinch.", "SPLASH":"Has no battle effect.", "THIEF":"Can steal the target's held item.",
"PAY_DAY":"Scatters money during battle.", "PAIN_SPLIT":"Shares remaining HP with the target.",
"HIDDEN_POWER":"Type and power depend on the user.", "RETURN":"Power increases with happiness.", "FRUSTRATION":"Power increases with unhappiness.",
"REVERSAL":"Stronger when the user has less HP.", "CRUSH_GRIP":"Stronger when the target has more HP.", "DRAGON_ENERGY":"Stronger when the user has more HP.",
"PRESENT":"May damage or heal the target.", "MAGNITUDE":"Attacks with randomly selected power.",
"FURY_CUTTER":"Successive hits become stronger.", "ROLLOUT":"Repeats with increasing power.", "RAGE":"Raises Attack when the user is hit.",
"RAMPAGE":"Attacks repeatedly, then confuses the user.", "BIDE":"Stores damage and returns it.",
"HYPER_BEAM":"Requires a recharge after attacking.", "JUMP_KICK":"The user is hurt if the attack misses.",
"FLY":"Takes two turns. hides the user before striking.", "SOLARBEAM":"Charges before attacking. sunlight helps.",
"RAZOR_WIND":"Charges before attacking.", "SKULL_BASH":"Raises Defense before attacking next turn.", "SKY_ATTACK":"Charges before a powerful attack.",
"FUTURE_SIGHT":"Strikes after a delay.", "PURSUIT":"Punishes a target switching out.",
"EARTHQUAKE":"Hits targets underground harder.", "GUST":"Hits airborne targets harder.", "TWISTER":"May flinch. hits airborne targets harder.",
"STOMP":"May flinch. punishes a minimized target.", "RAPID_SPIN":"Clears traps and entry hazards.",
"THUNDER":"May paralyze. weather affects accuracy.", "SACRED_FIRE":"May burn the target.", "FLAME_WHEEL":"May burn. thaws the user.",
"TRI_ATTACK":"May burn, freeze or paralyze."
}

static func effect_text(move: String) -> String:
    var data = Data.move_info(move)
    var effect = str(data.get("effect","")).trim_prefix("EFFECT_")
    if EFFECTS.has(effect): return EFFECTS[effect]
    for stat in ["SP_ATK","SP_DEF","ACCURACY","EVASION","ATTACK","DEFENSE","SPEED"]:
        if not effect.begins_with(stat+"_"): continue
        var part = effect.trim_prefix(stat+"_")
        var name = {"SP_ATK":"Sp. Atk","SP_DEF":"Sp. Def"}.get(stat,stat.capitalize())
        var result = ("Raises " if part.begins_with("UP") else "Lowers ")+str(name)
        if part.ends_with("_2"): result += " sharply"
        if part.ends_with("_HIT"): result = "May "+result.to_lower().replace("raises ","raise ").replace("lowers ","lower ")
        return result+"."
    return "Effect: "+effect.replace("_"," ").capitalize()+"."

static func stats_text(move: String) -> String:
    var data = Data.move_info(move)
    var power = int(data.get("power",0))
    var category = "STATUS" if power==0 else Rules.move_category(move)
    return "%s / %s\nPOWER %s  ACC %d%%  PP %d" % [data.get("type","---"),category,str(power) if power>1 else "--",int(data.get("accuracy",0)),int(data.get("pp",0))]
