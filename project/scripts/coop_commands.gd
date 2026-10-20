extends Node
## Host dispatch for admitted peers. No client may submit raw state transactions.
signal changed(commit: Dictionary)
signal reply(actor: String, id: String, result: Dictionary)
const Shared=preload("res://scripts/coop_shared_items.gd")
const Interactions=preload("res://scripts/coop_interactions.gd")
var state
var session
var items=Shared.new()
var interactions=Interactions.new()
var presence:Dictionary={}
var _budgets:Dictionary={}
var _pending:Array=[]
var _interaction_replies:Dictionary={}
var build_action:Callable
var wild_action:Callable
var population_action:Callable
var horde_action:Callable
var raid_action:Callable
var population_battle_action:Callable
var event_action:Callable
const MAX_PENDING:=128
const MAX_PER_SECOND:=40

func bind(connection, model) -> void:
    session=connection;state=model
    items.state=state;items.presence=presence
    interactions.state=state;interactions.presence=presence
    session.message.connect(_message)
    session.departed.connect(_departed)
    process_mode=Node.PROCESS_MODE_ALWAYS

func _message(peer:int,actor:String,payload:Dictionary)->void:
    if not session.hosting or payload.get("kind","")!="command":return
    var result=execute(actor,payload)
    # The answer says whether it worked. What changed reaches every player,
    # this one included, in the shared commit; sending it here as well put the
    # player's whole record on the wire twice.
    var answer:Dictionary=visible_result(result,actor)
    answer.erase("changes");answer.erase("player_edits")
    var packet={"kind":"command_result","id":payload.get("id",""),"result":answer}
    if session.send_to(peer,packet)==ERR_BUSY and _pending.size()<MAX_PENDING:
        _pending.append({"peer":peer,"packet":packet})

func _process(_delta:float)->void:
    if session==null:return
    var count=mini(maxi(8,ceili(8.0*_delta*60.0)),_pending.size())
    for _index in range(count):
        var queued:Dictionary=_pending.pop_front()
        var error=session.send_to(queued.peer,queued.packet)
        if error==ERR_BUSY:_pending.append(queued)

func _departed(_peer:int,actor:String)->void:
    var result:Dictionary=interactions.player_disconnected(actor)
    if result.get("ok",false):reply.emit(actor,"",result)
    # AreaService owns the leave/authority epoch transition.
    presence.erase(actor);_budgets.erase(actor)
    _interaction_replies.erase(actor)

func execute(actor:String,payload:Dictionary)->Dictionary:
    if state==null or not state.members.has(actor):return {"ok":false,"reason":"not_admitted"}
    var id=payload.get("id")
    var operation=payload.get("op")
    var args=payload.get("args",{})
    if not id is String or id.is_empty() or id.length()>48 or not operation is String or not args is Dictionary:
        return {"ok":false,"reason":"invalid_command"}
    var now=Time.get_ticks_msec()
    var budget:Dictionary=_budgets.get(actor,{"start":now,"count":0})
    if now-int(budget.start)>=1000:budget={"start":now,"count":0}
    budget.count+=1;_budgets[actor]=budget
    if int(budget.count)>MAX_PER_SECOND:return {"ok":false,"reason":"rate_limited"}
    var consent_command:bool=operation in ["interact","answer","trade_offer","trade_confirm","battle_action","battle_done","cancel"]
    # Only these keep their answer by request; a world motion's runs to 16 KB.
    var request_hash:String=state.fingerprint([operation,args]) if consent_command else ""
    if consent_command:
        var saved:Dictionary=_interaction_replies.get(actor,{}).get(id,{})
        if not saved.is_empty():
            if saved.hash!=request_hash:return {"ok":false,"reason":"reused_request_id"}
            return saved.result.duplicate(true)
    var before:int=state.revision
    var result:Dictionary={"ok":false,"reason":"invalid_command"}
    # Strict types prevent malformed packets reaching typed handlers.
    match operation:
        "event_motion":
            if event_action.is_valid() and _strings(args,["area"]) and _integers(args,["epoch"]) and args.get("patches") is Array and args.patches.size()<=2:result=event_action.call(actor,id,operation,args)
        "event_begin":
            if event_action.is_valid() and _strings(args,["key"]) and args.get("context") is String and args.context.length()<=256*1024:result=event_action.call(actor,id,operation,args)
        "event_finish":
            if event_action.is_valid() and _strings(args,["key","base"]) and args.get("outcome") in ["captured","defeated","ran","whiteout"]:
                var profile=args.get("profile")
                if profile is Dictionary and profile.get("party") is Array and profile.party.size()<=6 and profile.get("inventory") is Dictionary and profile.inventory.size()<=1024 and profile.get("save") is Dictionary:result=event_action.call(actor,id,operation,args)
        "population_battle":
            if population_battle_action.is_valid() and _strings(args,["area"]) and _integers(args,["x","y"]) and args.get("group") in ["deployed_pokemon","wild_eggs"]:result=population_battle_action.call(actor,id,operation,args)
        "population_finish":
            if population_battle_action.is_valid() and _strings(args,["base"]) and args.get("outcome") in ["captured","defeated","ran","whiteout"]:
                var profile=args.get("profile")
                if profile is Dictionary and profile.get("party") is Array and profile.party.size()<=6 and profile.get("inventory") is Dictionary and profile.inventory.size()<=1024 and profile.get("save") is Dictionary:result=population_battle_action.call(actor,id,operation,args)
        "raid_join":
            if raid_action.is_valid() and _strings(args,["area"]) and args.get("context") is String and args.context.length()<=256*1024:result=raid_action.call(actor,id,operation,args)
        "raid_damage":
            if raid_action.is_valid() and _strings(args,["boss"]) and _integers(args,["amount"]):result=raid_action.call(actor,id,operation,args)
        "raid_finish":
            if raid_action.is_valid() and _strings(args,["boss","base"]) and args.get("outcome") in ["captured","defeated","ran","whiteout"]:
                var profile=args.get("profile")
                if profile is Dictionary and profile.get("party") is Array and profile.party.size()<=6 and profile.get("inventory") is Dictionary and profile.inventory.size()<=1024 and profile.get("save") is Dictionary:result=raid_action.call(actor,id,operation,args)
        "world_setting":
            if horde_action.is_valid() and ((args.get("key")=="horde" and args.get("value") is bool) or (args.get("key")=="raids" and args.get("value") in ["ALL","LAST"])):result=horde_action.call(actor,id,operation,args)
        "horde_ready":
            if horde_action.is_valid() and _strings(args,["area","event"]) and _integers(args,["epoch"]):result=horde_action.call(actor,id,operation,args)
        "horde_reward":
            if horde_action.is_valid() and _strings(args,["key"]):result=horde_action.call(actor,id,operation,args)
        "deploy":
            if population_action.is_valid() and _strings(args,["area","base"]) and _integers(args,["slot"]) and args.get("record") is String and args.record.length()<=256*1024:result=population_action.call(actor,id,operation,args)
        "recall_population":
            if population_action.is_valid() and _strings(args,["area","group","expected"]) and _integers(args,["x","y"]) and args.get("box") is String:result=population_action.call(actor,id,operation,args)
        "harvest_population":
            if population_action.is_valid() and _strings(args,["area","expected"]) and _integers(args,["x","y"]):result=population_action.call(actor,id,operation,args)
        "population_motion":
            if population_action.is_valid() and _strings(args,["area"]) and _integers(args,["epoch"]) and args.get("patches") is Array:result=population_action.call(actor,id,operation,args)
        "wild_namespace":
            if wild_action.is_valid():result=wild_action.call(actor,id,operation,args)
        "wild_spawn":
            if wild_action.is_valid() and _strings(args,["area"]) and args.get("record") is String and args.record.length()<=256*1024:result=wild_action.call(actor,id,operation,args)
        "wild_claim","wild_release":
            if wild_action.is_valid() and _strings(args,["area"]) and _wild_id(args.get("wild_id")):result=wild_action.call(actor,id,operation,args)
        "wild_finish":
            if wild_action.is_valid() and _strings(args,["area","base","outcome"]) and _wild_id(args.get("wild_id")) and args.get("calm") is bool and args.outcome in ["captured","defeated","ran","whiteout"]:
                var profile=args.get("profile")
                if profile is Dictionary and profile.get("party") is Array and profile.party.size()<=6 and profile.get("inventory") is Dictionary and profile.inventory.size()<=1024 and profile.get("save") is Dictionary and _valid_wild_aftermath(args.get("aftermath",{})):result=wild_action.call(actor,id,operation,args)
        "wild_motion":
            if wild_action.is_valid() and _strings(args,["area"]) and _integers(args,["epoch"]) and args.get("patches") is Array:result=wild_action.call(actor,id,operation,args)
        "field_dig":
            if build_action.is_valid() and _strings(args,["area","profile_hash"]) and args.get("choice") is String and args.get("patches") is Array and args.get("rewards") is Dictionary:
                args["field_dig"]=true
                result=build_action.call(actor,id,args)
        "field_cut":
            if build_action.is_valid() and _strings(args,["area","profile_hash"]) and args.get("patches") is Array and args.get("rewards") is Dictionary:
                args["field_cut"]=true
                args.erase("field_dig")
                result=build_action.call(actor,id,args)
        "paint":
            if build_action.is_valid() and _strings(args,["area","profile_hash"]) and args.get("patches") is Array:
                args["paint"]=true
                args.erase("field_dig")
                args.erase("field_cut")
                result=build_action.call(actor,id,args)
        "build":
            if build_action.is_valid() and _strings(args,["area","recipe","profile_hash"]) and _integers(args,["x","y"]) and args.get("patches") is Array:
                args.erase("remove")
                args.erase("field_dig")
                args.erase("paint")
                args.erase("field_cut")
                result=build_action.call(actor,id,args)
        "remove_build":
            if build_action.is_valid() and _strings(args,["area","move","profile_hash"]) and _integers(args,["x","y"]) and args.get("patches") is Array:
                args["remove"]=true
                args.erase("field_dig")
                args.erase("paint")
                args.erase("field_cut")
                result=build_action.call(actor,id,args)
        "drop":
            if _strings(args,["item","area"]) and _integers(args,["amount","x","y"]):
                result=items.drop(actor,id,args.item,int(args.amount),args.area,int(args.x),int(args.y),args.get("thrown",false)==true)
        "pickup":
            if _strings(args,["key"]):result=items.pickup(actor,id,args.key)
        "deposit":
            if _strings(args,["box"]) and _integers(args,["slot"]):
                result=items.deposit(actor,id,{"id":args.box},int(args.slot),args.get("pooled")==true)
        "deposit_type":
            if _strings(args,["box"]) and _integers(args,["slot"]):result=items.deposit_type(actor,id,args.box,int(args.slot),args.get("pooled")==true)
        "withdraw":
            if _strings(args,["box","pokemon"]):
                result=items.withdraw(actor,id,{"id":args.box},args.pokemon,args.get("pooled")==true)
        "storage_edit":
            if _strings(args,["box","pokemon","action"]) and args.get("value","") is String:
                result=items.edit(actor,id,args.box,args.pokemon,args.action,String(args.get("value","")),args.get("pooled")==true)
        "private_sync":
            if args.get("entries") is Array and args.entries.size()<=4096 and args.get("removed") is Array and args.removed.size()<=8192:
                result=items.private_sync(actor,id,args.entries,args.removed)
        "storage_swap":
            if _strings(args,["box","pokemon","other_box","other_pokemon"]):
                result=items.swap(actor,id,args.box,args.pokemon,args.other_box,args.other_pokemon,args.get("pooled")==true)
        "interact":
            if _strings(args,["target","action"]):result=interactions.request(actor,args.target,args.action)
        "answer":
            if args.get("accept") is bool:result=interactions.answer(actor,args.accept)
        "trade_offer":
            if _integers(args,["slot"]):result=interactions.offer(actor,int(args.slot))
        "trade_confirm":result=interactions.confirm(actor)
        "battle_action":
            if _integers(args,["turn"]) and args.get("action") is Dictionary:result=interactions.battle_action(actor,int(args.turn),args.action)
        "battle_done":result=interactions.battle_done(actor)
        "cancel":result=interactions.cancel(actor)
    if state.revision>before:changed.emit(result.duplicate(true))
    if consent_command:
        if not _interaction_replies.has(actor):_interaction_replies[actor]={}
        var history:Dictionary=_interaction_replies[actor]
        if history.size()>=256:history.erase(history.keys()[0])
        history[id]={"hash":request_hash,"result":result.duplicate(true)}
    reply.emit(actor,id,result.duplicate(true))
    return result

func _strings(args:Dictionary,keys:Array)->bool:
    for key in keys:
        if not args.get(key) is String or args[key].is_empty() or args[key].length()>256:return false
    return true

static func _valid_wild_aftermath(value:Variant)->bool:
    if not value is Dictionary:return false
    for key in value:
        if key=="aggro_player":
            if not value[key] is bool:return false
        elif key in ["ball_alert_until","flee_steps","ball_flee_until"]:
            if typeof(value[key]) not in [TYPE_INT,TYPE_FLOAT] or not is_finite(float(value[key])) or float(value[key])<0:return false
        else:return false
    return true

func _integers(args:Dictionary,keys:Array)->bool:
    for key in keys:
        var value=args.get(key)
        if not (value is int or value is float):return false
        if not is_finite(float(value)) or float(value)!=floor(float(value)) or abs(float(value))>2147483647:return false
    return true

static func visible_result(result:Dictionary,actor:String)->Dictionary:
    var visible=result.duplicate(true)
    if visible.has("changes"):
        var changes:Array=[]
        for change in visible.changes:
            var key=String(change.get("key",""))
            if key.begins_with("player/") and key!="player/"+actor:continue
            if key.begins_with("private_box/") and key!="private_box/"+actor:continue
            if key.begins_with("horde_reward/") and not key.begins_with("horde_reward/"+actor+"/"):continue
            changes.append(change)
        visible.changes=changes
    var interaction:Dictionary=visible.get("session",{})
    if interaction.has("battle_inventory"):
        var own:Dictionary=interaction.battle_inventory.get(actor,{})
        interaction.battle_inventory={actor:own}
    return visible

static func _wild_id(value:Variant)->bool:
    return (value is int or value is float) and is_finite(float(value)) and float(value)==floor(float(value)) and float(value)>0 and float(value)<9007199254740992.0
