extends RefCounted

static func values(line: String, prefix: String = "db") -> Array[String]:
    var clean := line.split(";")[0].strip_edges()
    var result: Array[String] = []
    if not clean.begins_with(prefix+" ") and not clean.begins_with(prefix+"\t"): return result
    for token in clean.substr(prefix.length()).split(","):
        result.append(token.strip_edges())
    return result

static func parse(path: String, text: String, database: Dictionary) -> Dictionary:
    var species := path.get_slice("/",1)
    species = {"araichu":"raichu_alolan","aexeggutor":"exeggutor_alolan"}.get(species,species)
    if not database.species.has(species): return {"error":"Unknown species: "+species}
    var lines := text.replace("\r","").split("\n")
    var patch := {}
    var name := path.get_file()
    if name == "base_stats.asm":
        # Original Specie.java uses these physical line numbers, including blanks.
        if lines.size()<17: return {"error":"base_stats.asm needs the original 17-line layout"}
        var stats := values(lines[2])
        if stats.size()!=6: return {"error":"Expected six base stats on line 3"}
        var numbers := []
        for stat in stats:
            if not stat.is_valid_int() or int(stat)<1 or int(stat)>255: return {"error":"Invalid base stat"}
            numbers.append(int(stat))
        patch.stats=numbers
        var types := values(lines[5])
        var valid_types := ["NORMAL","FIRE","WATER","ELECTRIC","GRASS","ICE","FIGHTING","POISON","GROUND","FLYING","PSYCHIC","BUG","ROCK","GHOST","DRAGON","DARK","STEEL","FAIRY"]
        if types.is_empty() or types.size()>2: return {"error":"Invalid type list"}
        for type in types:
            if type not in valid_types: return {"error":"Unknown type: "+type}
        patch.types=types
        for entry in [[6,"catch_rate",0,255],[7,"base_exp",0,65535],[11,"egg_cycles",1,255]]:
            var fields := values(lines[int(entry[0])])
            if fields.size()!=1 or not fields[0].is_valid_int() or int(fields[0])<int(entry[2]) or int(fields[0])>int(entry[3]): return {"error":"Invalid "+String(entry[1])}
            patch[entry[1]]=int(fields[0])
        var gender := values(lines[9])
        if gender.size()!=1 or gender[0] not in ["GENDER_F0","GENDER_F12_5","GENDER_F25","GENDER_F50","GENDER_F75","GENDER_F87_5","GENDER_F100","GENDER_UNKNOWN"]: return {"error":"Unsupported gender ratio"}
        patch.gender_ratio=gender[0]
        var growth := values(lines[15])
        if growth.size()!=1 or growth[0] not in ["GROWTH_FAST","GROWTH_MEDIUM_FAST","GROWTH_MEDIUM_SLOW","GROWTH_SLOW","GROWTH_ERRATIC","GROWTH_FLUCTUATING"]: return {"error":"Unsupported growth group"}
        patch.growth_rate=growth[0]
        var groups := values(lines[16],"dn")
        if groups.size()!=2: return {"error":"Expected two egg groups"}
        var known_groups := ["EGG_MONSTER","EGG_WATER_1","EGG_BUG","EGG_FLYING","EGG_FIELD","EGG_GROUND","EGG_FAIRY","EGG_PLANT","EGG_GRASS","EGG_HUMANSHAPE","EGG_HUMAN_LIKE","EGG_WATER_3","EGG_MINERAL","EGG_INDETERMINATE","EGG_AMORPHOUS","EGG_WATER_2","EGG_DITTO","EGG_DRAGON","EGG_NONE","EGG_NO_EGGS"]
        for i in range(groups.size()):
            if groups[i] not in known_groups: return {"error":"Unknown egg group"}
            if groups[i]=="EGG_GROUND": groups[i]="EGG_FIELD"
        patch.egg_groups=groups
        var nickname := values(lines[0])
        if nickname.size()==1 and not nickname[0].is_empty(): patch.mod_name=nickname[0].trim_prefix("\"").trim_suffix("\"")
    elif name == "egg_moves.asm":
        var moves := []
        for line in lines:
            var fields := values(line)
            if fields.is_empty() or fields==["-1"]: continue
            if fields.size()!=1 or not database.moves.has(fields[0]): return {"error":"Unknown egg move: "+line}
            moves.append(fields[0])
        patch.egg_moves=moves
    elif name == "evos_attacks.asm":
        var moves := []
        var evolutions := []
        for line in lines:
            var fields := values(line)
            if fields.is_empty() or fields==["0"]: continue
            if fields[0].begins_with("EVOLVE_"):
                if fields.size()!=3 or fields[0] not in ["EVOLVE_LEVEL","EVOLVE_ITEM","EVOLVE_TRADE","EVOLVE_HAPPINESS","EVOLVE_MOVE","EVOLVE_INPARTY","EVOLVE_STAT"]: return {"error":"Unsupported evolution row: "+line}
                var target := fields[2].to_lower()
                if not database.species.has(target): return {"error":"Unknown evolution species: "+target}
                evolutions.append({"method":fields[0],"parameter":fields[1],"species":target})
            else:
                if fields.size()!=2 or not fields[0].is_valid_int() or int(fields[0])<1 or int(fields[0])>100 or not database.moves.has(fields[1]): return {"error":"Invalid/unsupported learned move: "+line}
                moves.append({"level":int(fields[0]),"move":fields[1]})
        patch.learnset=moves
        patch.evolutions=evolutions
    else: return {"error":"Unsupported data file"}
    return {"species":species,"patch":patch}
