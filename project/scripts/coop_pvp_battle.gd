extends RefCounted
## Host-resolved battle copies. This class has no save, inventory or reward writer.
const Battle=preload("res://scripts/battle_engine.gd")
var actors:Array=[]
var parties:Dictionary={}
var inventories:Dictionary={}
var item_rules:Dictionary={}
var slots:Dictionary={}
var actions:Dictionary={}
var field:Dictionary={}
var events:Array=[]
var pending:Array=[]
var replacement:Dictionary={}
var turn:=0
var finished:=false
var winner:=""
var resolving:=false
var rng=RandomNumberGenerator.new()

func start(first:String,second:String,source:Dictionary,seed_value:int,items:Dictionary={},rules:Dictionary={})->bool:
    actors=[first,second];rng.seed=seed_value
    inventories=items.duplicate(true);item_rules=rules.duplicate(true)
    for actor in actors:
        parties[actor]=[]
        for record in source.get(actor,[]):
            if not record is Dictionary or record.get("is_egg",false):continue
            var pokemon=Battle.ensure_pokemon(record.duplicate(true))
            Battle.reset_battle_state(pokemon)
            parties[actor].append(pokemon)
        slots[actor]=healthy(actor).front() if not healthy(actor).is_empty() else -1
        if slots[actor]<0:return false
    for actor in actors:
        var message=Battle.switch_in_message(current(actor),[current(other(actor))],field)
        if not message.is_empty():_event("message",actor,{"message":message})
    return true

func other(actor:String)->String:return String(actors[1]) if actor==actors[0] else String(actors[0])
func current(actor:String)->Dictionary:return parties[actor][slots[actor]]
func healthy(actor:String)->Array:
    var result:Array=[]
    for index in range(parties[actor].size()):
        if int(parties[actor][index].hp)>0:result.append(index)
    return result

func snapshot()->Dictionary:
    return {"parties":parties.duplicate(true),"slots":slots.duplicate(),"field":field.duplicate(true),
        "turn":turn,"finished":finished,"winner":winner,"replacement":replacement.duplicate(true)}

func submit(actor:String,expected_turn:int,action:Dictionary)->Dictionary:
    if actor not in actors or finished:return {"ok":false,"reason":"not_battling"}
    if expected_turn!=turn:return {"ok":false,"reason":"stale_turn"}
    if not valid_action(action):return {"ok":false,"reason":"invalid_action"}
    var kind=String(action.kind)
    if kind=="run":
        events.clear();finished=true;winner=other(actor)
        _event("finished",actor,{"message":"The battle ended."})
        return _reply()
    if not replacement.is_empty():
        if not replacement.has(actor) or kind!="switch":return {"ok":false,"reason":"replacement_required"}
        var index=int(action.get("index",-1))
        if index not in healthy(actor) or index==slots[actor]:return {"ok":false,"reason":"invalid_switch"}
        events.clear()
        _switch(actor,index,bool(replacement[actor].get("baton",false)))
        replacement.erase(actor)
        _faints()
        if replacement.is_empty() and not finished:_advance()
        return _reply()
    if actions.has(actor):return {"ok":false,"reason":"already_selected"}
    var pokemon=current(actor)
    if kind=="switch":
        var index=int(action.get("index",-1))
        if index not in healthy(actor) or index==slots[actor]:return {"ok":false,"reason":"invalid_switch"}
        if int(pokemon.volatile.get("trap_turns",0))>0 or pokemon.volatile.get("mean_look",false):return {"ok":false,"reason":"trapped"}
    elif kind=="item":
        if not can_use_item(actor,String(action.get("item","")),int(action.get("index",-1))):return {"ok":false,"reason":"unusable_item"}
    elif kind=="move":
        var move=String(action.get("move",""))
        var forced=Battle.forced_move(pokemon)
        if not forced.is_empty():move=forced
        elif move=="STRUGGLE":
            for option in pokemon.moves:
                if Battle.move_is_usable(pokemon,option):return {"ok":false,"reason":"move_available"}
        elif move not in pokemon.moves or not Battle.move_is_usable(pokemon,move):return {"ok":false,"reason":"unusable_move"}
        action=action.duplicate(true);action.move=move
    else:return {"ok":false,"reason":"invalid_action"}
    actions[actor]=action.duplicate(true);actions[actor]["slot"]=slots[actor]
    if actions.size()<2:return {"ok":true,"waiting":true,"state":snapshot(),"events":[]}
    events.clear()
    var a:String=actors[0];var b:String=actors[1]
    var a_first:bool=actions[a].kind!="move"
    if (actions[a].kind=="move")== (actions[b].kind=="move"):
        a_first=Battle.player_moves_first(current(a),String(actions[a].get("move","")),current(b),String(actions[b].get("move","")),rng,field)
    pending=[a,b] if a_first else [b,a]
    resolving=true
    _advance()
    return _reply()

static func valid_action(action:Dictionary)->bool:
    if not action.get("kind") is String:return false
    var kind:String=action.kind
    if kind not in ["run","move","switch","item"]:return false
    if kind in ["switch","item"]:
        var index=action.get("index")
        if not (index is int or index is float):return false
        if not is_finite(float(index)) or float(index)!=floor(float(index)) or float(index)<0 or float(index)>5:return false
    if kind in ["move","item"]:
        var value=action.get("move" if kind=="move" else "item")
        if not value is String or value.is_empty() or value.length()>80:return false
    return true

func _advance()->void:
    if not resolving:return
    while not pending.is_empty() and not finished:
        var actor:String=pending.pop_front()
        var action:Dictionary=actions[actor]
        if int(action.slot)!=int(slots[actor]) or int(current(actor).hp)<=0:continue
        if action.kind=="switch":_switch(actor,int(action.index))
        elif action.kind=="item":_item(actor,String(action.item),int(action.index))
        else:_move(actor,String(action.move))
        _faints()
        if not replacement.is_empty() or finished:return
    if finished:return
    for actor in actors:
        var message=Battle.end_turn(current(actor),field,current(other(actor)),rng)
        _event("residual",actor,{"message":message})
    if int(field.get("weather_turns",0))>0:
        field.weather_turns-=1
        if field.weather_turns<=0:field.weather=""
    turn+=1;field.turn_count=turn;actions.clear();resolving=false
    _faints()

func _move(actor:String,move:String)->void:
    var attacker=current(actor);var defender=current(other(actor))
    var repeated=not String(attacker.volatile.get("charge_move","")).is_empty() or int(attacker.volatile.get("bide_turns",0))>0 or int(attacker.volatile.get("locked_turns",0))>0
    if move!="STRUGGLE" and not repeated:attacker.pp[move]=maxi(0,int(attacker.pp.get(move,1))-1)
    field.attacker_is_player=actor==actors[0]
    var result=Battle.use_move(attacker,defender,move,rng,field)
    if not String(result.get("weather","")).is_empty():field.weather=result.weather;field.weather_turns=5
    if result.get("heal_party",false):
        for member in parties[actor]:member.status="";member.status_counter=0;member.toxic_counter=0
    _event("move",actor,{"move":move,"result":result})
    var effect=String(result.get("force_switch",""))
    if effect=="TELEPORT":finished=true;winner="";return
    if effect=="BATON_PASS" and healthy(actor).size()>1:
        replacement[actor]={"baton":true}
    elif effect=="FORCE_SWITCH":
        var target=other(actor);var candidates=healthy(target);candidates.erase(slots[target])
        if not candidates.is_empty():_switch(target,int(candidates[rng.randi_range(0,candidates.size()-1)]))

func can_use_item(actor:String,item:String,index:int)->bool:
    if index<0 or index>=parties[actor].size() or int(inventories.get(actor,{}).get(item,0))<1:return false
    var pokemon:Dictionary=parties[actor][index];var rule:Dictionary=item_rules.get(item,{})
    match String(rule.get("kind","")):
        "heal":return int(pokemon.hp)>0 and int(pokemon.hp)<int(pokemon.max_hp)
        "full_restore":return int(pokemon.hp)>0 and (int(pokemon.hp)<int(pokemon.max_hp) or not String(pokemon.status).is_empty())
        "status":return int(pokemon.hp)>0 and not String(pokemon.status).is_empty() and (rule.get("status","ANY")=="ANY" or rule.status==pokemon.status)
        "confusion":return pokemon.volatile.has("confuse_turns")
        "revive":return int(pokemon.hp)<=0
    return false

func _item(actor:String,item:String,index:int)->void:
    var pokemon:Dictionary=parties[actor][index];var rule:Dictionary=item_rules[item]
    match String(rule.kind):
        "heal":pokemon.hp=mini(int(pokemon.max_hp),int(pokemon.hp)+int(rule.amount))
        "full_restore":pokemon.hp=pokemon.max_hp;pokemon.status="";pokemon.status_counter=0;pokemon.toxic_counter=0
        "status":pokemon.status="";pokemon.status_counter=0;pokemon.toxic_counter=0
        "confusion":pokemon.volatile.erase("confuse_turns")
        "revive":pokemon.hp=maxi(1,int(int(pokemon.max_hp)*float(rule.fraction)))
    inventories[actor][item]-=1
    _event("item",actor,{"message":"Used %s on %s."%[item,Battle.display_name(pokemon)]})

func _switch(actor:String,index:int,baton:bool=false)->void:
    var previous=current(actor)
    var stages:Dictionary=previous.stages.duplicate(true)
    var volatile:Dictionary=previous.volatile.duplicate(true)
    var message=Battle.switch_out_message(previous)
    Battle.reset_battle_state(previous)
    slots[actor]=index
    Battle.reset_battle_state(current(actor))
    if baton:
        current(actor).stages=stages
        # Transfer only passable effects, not charge/disable/encore bookkeeping.
        for key in ["substitute_hp","confuse_turns","focus_energy"]:
            if volatile.has(key):current(actor).volatile[key]=volatile[key]
    var incoming=current(actor)
    var spikes=int(field.get("player_spikes" if actor==actors[0] else "enemy_spikes",0))
    if spikes>0 and "FLYING" not in incoming.types and incoming.get("ability","")!="LEVITATE":
        incoming.hp=maxi(0,int(incoming.hp)-maxi(1,int(int(incoming.max_hp)*spikes/8.0)))
    var arrival=Battle.switch_in_message(current(actor),[current(other(actor))],field)
    _event("switch",actor,{"message":message+" "+arrival})

func _faints()->void:
    var alive:Array=[]
    for actor in actors:
        if not healthy(actor).is_empty():alive.append(actor)
    if alive.size()<2:
        finished=true;winner=String(alive[0]) if alive.size()==1 else ""
        replacement.clear();return
    for actor in actors:
        if int(current(actor).hp)<=0:replacement[actor]={"baton":false}

func _event(kind:String,actor:String,data:Dictionary)->void:
    data=data.duplicate(true);data["kind"]=kind;data["actor"]=actor;data["state"]=snapshot();events.append(data)

func _reply()->Dictionary:return {"ok":true,"state":snapshot(),"events":events.duplicate(true)}
