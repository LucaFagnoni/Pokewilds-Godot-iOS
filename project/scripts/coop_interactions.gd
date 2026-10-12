extends RefCounted
## Host-side two-player consent. Parties are read from the host's player records.
const State=preload("res://scripts/coop_state.gd")
var state
var sessions: Dictionary={}
var player_sessions: Dictionary={}
var presence: Dictionary={}
var battles:Dictionary={}
var battle_item_rules:Dictionary={}

func request(actor: String, other: String, kind: String) -> Dictionary:
    if kind not in ["TRADE","BATTLE"] or actor==other:return {"ok":false}
    if player_sessions.has(actor) or player_sessions.has(other):return {"ok":false,"reason":"busy"}
    if not presence.has(actor) or not presence.has(other):return {"ok":false,"reason":"offline"}
    var first:Dictionary=presence[actor];var second:Dictionary=presence[other]
    if first.get("battle",false) or second.get("battle",false):return {"ok":false,"reason":"in_battle"}
    if first.get("area","")!=second.get("area",""):return {"ok":false,"reason":"different_area"}
    var delta:=Vector2i(int(second.x)-int(first.x),int(second.y)-int(first.y))
    if absi(delta.x)>1 or absi(delta.y)>1:return {"ok":false,"reason":"not_adjacent"}
    # Standing shoulder to shoulder the two may be counted in one tile, or in
    # tiles that touch at a corner. The other must only not be behind.
    if delta.x*int(first.get("fx",0))+delta.y*int(first.get("fy",0))<0:return {"ok":false,"reason":"not_facing"}
    var id:="interaction-"+preload("res://scripts/coop_random.gd").hex(16)
    sessions[id]={"id":id,"kind":kind,"a":actor,"b":other,"accepted":false,
        "offers":{},"confirmed":{},"created":Time.get_ticks_msec()}
    player_sessions[actor]=id;player_sessions[other]=id
    return {"ok":true,"session":sessions[id].duplicate(true)}

func answer(actor: String, accept: bool) -> Dictionary:
    var session:=_session(actor)
    if session.is_empty() or actor!=session.b or session.accepted:return {"ok":false}
    if not accept:return cancel(actor)
    session.accepted=true
    if session.kind=="BATTLE":
        var first=_profile(session.a);var second=_profile(session.b)
        if first.is_empty() or second.is_empty():return cancel(actor)
        # These are independent copies. PvP never writes into saved player records.
        session["battle_parties"]={session.a:first.get("party",[]).duplicate(true),session.b:second.get("party",[]).duplicate(true)}
        session["battle_inventory"]={session.a:first.get("inventory",{}).duplicate(true),session.b:second.get("inventory",{}).duplicate(true)}
        var model=preload("res://scripts/coop_pvp_battle.gd").new()
        if not model.start(session.a,session.b,session.battle_parties,Time.get_ticks_usec(),session.battle_inventory,battle_item_rules):return cancel(actor,"no_healthy_pokemon")
        battles[session.id]=model
        session["battle_state"]=model.snapshot()
        session["trainers"]={session.a:state.members.get(session.a,{}).duplicate(true),session.b:state.members.get(session.b,{}).duplicate(true)}
    return {"ok":true,"session":session.duplicate(true)}

func battle_action(actor:String,turn:int,action:Dictionary)->Dictionary:
    var session=_session(actor)
    if session.is_empty() or not battles.has(session.id):return {"ok":false,"reason":"not_battling"}
    var result:Dictionary=battles[session.id].submit(actor,turn,action)
    if not result.get("ok",false):return result
    session["battle_state"]=result.state
    session["battle_inventory"]=battles[session.id].inventories.duplicate(true)
    session["battle_events"]=result.events
    session["battle_revision"]=int(session.get("battle_revision",0))+1
    result["session"]=session.duplicate(true)
    return result

func battle_done(actor:String)->Dictionary:
    var session=_session(actor)
    if session.is_empty() or not battles.has(session.id) or not battles[session.id].finished:return {"ok":false,"reason":"battle_not_finished"}
    if not session.has("battle_done"):session["battle_done"]={}
    session.battle_done[actor]=true
    if session.battle_done.size()==2:return finish_battle(actor)
    return {"ok":true,"waiting":true}

func offer(actor: String, slot: int) -> Dictionary:
    var session:=_session(actor)
    if session.is_empty() or not session.accepted or session.kind!="TRADE":return {"ok":false}
    var profile:=_profile(actor)
    var party:Array=profile.get("party",[])
    if slot<0 or slot>=party.size():return {"ok":false,"reason":"invalid_slot"}
    if int(presence.get(actor,{}).get("helper_slot",-1))==slot:return {"ok":false,"reason":"field_move_active"}
    session.offers[actor]={"slot":slot,"pokemon":party[slot].duplicate(true),"profile_hash":State.fingerprint(profile)}
    session.confirmed.clear()
    return {"ok":true,"session":session.duplicate(true)}

func confirm(actor: String) -> Dictionary:
    var session:=_session(actor)
    if session.is_empty() or session.kind!="TRADE" or session.offers.size()!=2:return {"ok":false}
    for player in [session.a,session.b]:
        if State.fingerprint(_profile(player))!=session.offers[player].profile_hash:
            return cancel(actor,"party_changed")
    session.confirmed[actor]=true
    if session.confirmed.size()!=2:return {"ok":true,"waiting":true}
    var first:=_profile(session.a).duplicate(true);var second:=_profile(session.b).duplicate(true)
    var a_slot:=int(session.offers[session.a].slot);var b_slot:=int(session.offers[session.b].slot)
    var pokemon=first.party[a_slot]
    first.party[a_slot]=second.party[b_slot]
    second.party[b_slot]=pokemon
    var result:Dictionary=state.transact(session.a,"trade/"+session.id,[
        state.change("player/"+session.a,first),state.change("player/"+session.b,second)])
    if result.get("ok",false):
        result["kind"]="trade_complete"
        _remove(session)
    return result

func cancel(actor: String, reason: String="cancelled") -> Dictionary:
    var session:=_session(actor)
    if session.is_empty():return {"ok":false}
    var result:Dictionary={"ok":true,"kind":"closed","reason":reason,"a":session.a,"b":session.b,"id":session.id}
    _remove(session)
    return result

func player_disconnected(actor: String) -> Dictionary:
    presence.erase(actor)
    return cancel(actor,"disconnected")

func finish_battle(actor: String) -> Dictionary:
    var session:=_session(actor)
    if session.is_empty() or session.kind!="BATTLE":return {"ok":false}
    # Dropping temporary battle copies is sufficient on win, loss, quit or disconnect.
    # No EXP, inventory writes, caught/seen history, whiteout, or reward callbacks.
    return cancel(actor,"battle_finished")

func _profile(actor: String) -> Dictionary:
    return state.records.get("player/"+actor,{})

func _session(actor: String) -> Dictionary:
    return sessions.get(player_sessions.get(actor,""),{})

func _remove(session: Dictionary) -> void:
    battles.erase(session.id)
    player_sessions.erase(session.a);player_sessions.erase(session.b);sessions.erase(session.id)
