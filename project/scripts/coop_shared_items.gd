extends RefCounted
## Host-side atomic transfers. Inventory and object changes commit together.
var state
var presence:Dictionary={}
var _command_hash := ""

func _run(actor:String,id:String,operation:String,args:Array)->Dictionary:
    if not state.members.has(actor) or id.is_empty() or id.length()>48:
        return {"ok":false,"reason":"invalid_request"}
    var hash_value:String=state.fingerprint([operation,args])
    var previous:Dictionary=state.outcomes.get(actor+"/"+operation+"/"+id,{})
    if not previous.is_empty():
        if previous.get("command_hash","")!=hash_value:return {"ok":false,"reason":"reused_request_id"}
        return previous.duplicate(true)
    _command_hash=hash_value
    match operation:
        "drop":return _drop(actor,id,args[0],args[1],args[2],args[3],args[4],args[5])
        "pickup":return _pickup(actor,id,args[0])
        "storage_swap":return _swap(actor,id,args)
        "private_sync":return _private_sync(actor,id,args[0],args[1])
        "deposit","deposit_type","withdraw","storage_edit":
            var box:Dictionary=state.records.get("chest/"+String(args[0]),{})
            if box.is_empty():return {"ok":false,"reason":"missing_chest"}
            if operation=="deposit":return _deposit(actor,id,box,args[1],bool(args[2]))
            if operation=="deposit_type":return _deposit_type(actor,id,box,args[1],bool(args[2]))
            if operation=="withdraw":return _withdraw(actor,id,box,args[1],bool(args[2]))
            return _edit(actor,id,box,args[1],args[2],args[3],bool(args[4]))
    return {"ok":false,"reason":"invalid_operation"}

func _commit(actor:String,id:String,changes:Array)->Dictionary:
    return state.transact(actor,id,changes,_command_hash)

func drop(actor:String,request_id:String,item:String,amount:int,area:String,x:int,y:int,thrown:bool=false)->Dictionary:
    return _run(actor,request_id,"drop",[item,amount,area,x,y,thrown])

func _drop(actor:String,request_id:String,item:String,amount:int,area:String,x:int,y:int,thrown:bool=false)->Dictionary:
    var profile:Dictionary=state.records.get("player/"+actor,{})
    var inventory:Dictionary=profile.get("inventory",{})
    var near:=_near(actor,area,x,y)
    if thrown and not near:
        # A thrown ball lands some way off, and the thrower may walk on meanwhile.
        var player:Dictionary=presence.get(actor,{})
        near=player.get("area","?")==area and absi(int(player.get("x",-999999))-x)+absi(int(player.get("y",-999999))-y)<=12
    if amount<=0 or amount>int(inventory.get(item,0)) or not near:return {"ok":false,"reason":"invalid_drop"}
    for existing_key in state.records:
        if not String(existing_key).begins_with("drop/"):continue
        var existing:Dictionary=state.records[existing_key]
        if existing.get("area")==area and int(existing.x)==x and int(existing.y)==y:
            if thrown and existing.get("item")==item:
                # Lands on a pile of the same ball: the pile grows by one.
                var lighter:=profile.duplicate(true)
                lighter.inventory[item]=int(inventory[item])-amount
                var pile:=existing.duplicate(true)
                pile["amount"]=int(existing.amount)+amount
                return _commit(actor,"drop/"+request_id,[state.change("player/"+actor,lighter),state.change(existing_key,pile)])
            return {"ok":false,"reason":"occupied"}
    var key:="drop/"+area+"/"+(actor+"/"+request_id).sha256_text()
    if state.records.has(key):return {"ok":false,"reason":"already_dropped"}
    var changed:=profile.duplicate(true)
    changed.inventory[item]=int(inventory[item])-amount
    return _commit(actor,"drop/"+request_id,[state.change("player/"+actor,changed),
        state.change(key,{"item":item,"amount":amount,"area":area,"x":x,"y":y})])

func pickup(actor:String,request_id:String,key:String)->Dictionary:
    return _run(actor,request_id,"pickup",[key])

func _pickup(actor:String,request_id:String,key:String)->Dictionary:
    if not key.begins_with("drop/"):return {"ok":false}
    var item:Dictionary=state.records.get(key,{})
    if item.is_empty():return {"ok":false,"reason":"already_collected"}
    if not _near(actor,String(item.area),int(item.x),int(item.y)):return {"ok":false,"reason":"too_far"}
    var profile:Dictionary=state.records.get("player/"+actor,{}).duplicate(true)
    if profile.is_empty():return {"ok":false}
    profile.inventory[item.item]=int(profile.inventory.get(item.item,0))+int(item.amount)
    return _commit(actor,"pickup/"+request_id,[state.change(key,null),state.change("player/"+actor,profile)])

## A player arriving in this world offers the private box their device holds.
func private_sync(actor:String,request_id:String,entries:Array,removed:Array)->Dictionary:
    return _run(actor,request_id,"private_sync",[entries,removed])

func _private_sync(actor:String,request_id:String,entries:Array,removed:Array)->Dictionary:
    var key:="private_box/"+actor
    var here:Array=state.records.get(key,[])
    var merged:Array=preload("res://scripts/coop_private_box.gd").merge(here,entries,removed)
    if preload("res://scripts/coop_patch.gd").same(here,merged):return {"ok":true,"unchanged":true}
    return _commit(actor,"private_sync/"+request_id,[state.change(key,merged)])

func box_key(actor:String,box:Dictionary)->String:
    return "private_box/"+actor if box.get("private",false) else "box/"+String(box.id)

func deposit(actor:String,request_id:String,box:Dictionary,slot:int,pooled:bool=false)->Dictionary:
    return _run(actor,request_id,"deposit",[String(box.get("id","")),slot,pooled])

func _deposit(actor:String,request_id:String,box:Dictionary,slot:int,pooled:bool=false)->Dictionary:
    if not pooled and not _near_box(actor,box):return {"ok":false,"reason":"too_far"}
    var profile:Dictionary=state.records.get("player/"+actor,{}).duplicate(true)
    var party:Array=profile.get("party",[])
    if slot<0 or slot>=party.size() or int(presence.get(actor,{}).get("helper_slot",-1))==slot:return {"ok":false,"reason":"unavailable"}
    var key:=box_key(actor,box)
    var stored:Array=state.records.get(key,[]).duplicate(true)
    if stored.size()>=int(box.get("capacity",4096)):return {"ok":false,"reason":"full"}
    stored.append({"id":(actor+"/"+request_id).sha256_text(),"pokemon":party[slot]})
    party.remove_at(slot);profile.party=party
    return _commit(actor,"deposit/"+request_id,[state.change("player/"+actor,profile),state.change(key,stored)])

func withdraw(actor:String,request_id:String,box:Dictionary,pokemon_id:String,pooled:bool=false)->Dictionary:
    return _run(actor,request_id,"withdraw",[String(box.get("id","")),pokemon_id,pooled])

func _withdraw(actor:String,request_id:String,box:Dictionary,pokemon_id:String,pooled:bool=false)->Dictionary:
    if not pooled and not _near_box(actor,box):return {"ok":false,"reason":"too_far"}
    var profile:Dictionary=state.records.get("player/"+actor,{}).duplicate(true)
    var party:Array=profile.get("party",[])
    if party.size()>=6:return {"ok":false,"reason":"party_full"}
    var key:=box_key(actor,box)
    var stored:Array=state.records.get(key,[]).duplicate(true)
    for index in range(stored.size()):
        if stored[index].id!=pokemon_id:continue
        party.append(stored[index].pokemon);stored.remove_at(index);profile.party=party
        return _commit(actor,"withdraw/"+request_id,[state.change("player/"+actor,profile),state.change(key,stored)])
    return {"ok":false,"reason":"too_late"}

func edit(actor:String,id:String,box:String,pokemon:String,action:String,value:String,pooled:bool)->Dictionary:
    return _run(actor,id,"storage_edit",[box,pokemon,action,value,pooled])

func _edit(actor:String,id:String,box:Dictionary,pokemon:String,action:String,value:String,pooled:bool)->Dictionary:
    if not pooled and not _near_box(actor,box):return {"ok":false,"reason":"too_far"}
    var key=box_key(actor,box)
    var stored:Array=state.records.get(key,[]).duplicate(true)
    for index in range(stored.size()):
        if stored[index].id!=pokemon:continue
        if action=="RELEASE":stored.remove_at(index)
        elif action=="NICKNAME":stored[index].pokemon.nickname=value.substr(0,24)
        elif action=="SWITCH":
            var other=-1
            for j in range(stored.size()):
                if stored[j].id==value:other=j;break
            if other<0:return {"ok":false,"reason":"too_late"}
            var previous=stored[index];stored[index]=stored[other];stored[other]=previous
        else:return {"ok":false,"reason":"invalid_action"}
        return _commit(actor,"storage_edit/"+id,[state.change(key,stored)])
    return {"ok":false,"reason":"too_late"}

func _near_box(actor:String,box:Dictionary)->bool:
    if box.get("retired",false):return false
    var player:Dictionary=presence.get(actor,{})
    var area=String(player.get("area","?"))
    return (area==String(box.get("area","")) or area.get_slice("|",0)==String(box.get("area",""))) and absi(int(player.get("x",-999999))-int(box.get("x",0)))+absi(int(player.get("y",-999999))-int(box.get("y",0)))<=1

static func primary_type(pokemon:Dictionary)->String:
    var types=pokemon.get("types",preload("res://scripts/pokemon_data.gd").info(String(pokemon.get("species",""))).get("types",[]))
    return String(types[0]) if not types.is_empty() else ""

func deposit_type(actor:String,id:String,box:String,slot:int,pooled:bool)->Dictionary:
    return _run(actor,id,"deposit_type",[box,slot,pooled])

func _deposit_type(actor:String,id:String,box:Dictionary,slot:int,pooled:bool)->Dictionary:
    if not pooled and not _near_box(actor,box):return {"ok":false,"reason":"too_far"}
    var profile:Dictionary=state.records.get("player/"+actor,{}).duplicate(true)
    var party:Array=profile.get("party",[])
    if slot<0 or slot>=party.size() or party[slot].get("is_egg",false):return {"ok":false,"reason":"unavailable"}
    var selected_type=primary_type(party[slot])
    var key=box_key(actor,box)
    var stored:Array=state.records.get(key,[]).duplicate(true)
    var remaining:Array=[]
    var healthy=0
    for pokemon in party:
        if not pokemon.get("is_egg",false) and int(pokemon.get("hp",0))>0:healthy+=1
    for index in range(party.size()):
        var pokemon:Dictionary=party[index]
        var is_healthy=not pokemon.get("is_egg",false) and int(pokemon.get("hp",0))>0
        if pokemon.get("is_egg",false) or primary_type(pokemon)!=selected_type or index==int(presence.get(actor,{}).get("helper_slot",-1)) or (is_healthy and healthy<=1) or stored.size()>=int(box.get("capacity",4096)):
            remaining.append(pokemon);continue
        if is_healthy:healthy-=1
        stored.append({"id":(actor+"/"+id+"/"+str(index)).sha256_text(),"pokemon":pokemon})
    if remaining.size()==party.size():return {"ok":false,"reason":"unavailable"}
    profile.party=remaining
    return _commit(actor,"deposit_type/"+id,[state.change(key,stored),state.change("player/"+actor,profile)])

func swap(actor:String,id:String,first_box:String,first_id:String,second_box:String,second_id:String,pooled:bool)->Dictionary:
    return _run(actor,id,"storage_swap",[first_box,first_id,second_box,second_id,pooled])

func _swap(actor:String,id:String,args:Array)->Dictionary:
    var first:Dictionary=state.records.get("chest/"+String(args[0]),{})
    var second:Dictionary=state.records.get("chest/"+String(args[2]),{})
    if first.is_empty() or second.is_empty():return {"ok":false,"reason":"missing_chest"}
    if not args[4] and (not _near_box(actor,first) or not _near_box(actor,second)):return {"ok":false,"reason":"too_far"}
    var first_key=box_key(actor,first);var second_key=box_key(actor,second)
    var a:Array=state.records.get(first_key,[]).duplicate(true)
    var b:Array=a if first_key==second_key else state.records.get(second_key,[]).duplicate(true)
    var ai=-1;var bi=-1
    for index in range(a.size()):
        if a[index].id==args[1]:ai=index
    for index in range(b.size()):
        if b[index].id==args[3]:bi=index
    if ai<0 or bi<0:return {"ok":false,"reason":"too_late"}
    var previous=a[ai];a[ai]=b[bi];b[bi]=previous
    var changes=[state.change(first_key,a)]
    if first_key!=second_key:changes.append(state.change(second_key,b))
    return _commit(actor,"storage_swap/"+id,changes)

func _near(actor:String,area:String,x:int,y:int)->bool:
    var player:Dictionary=presence.get(actor,{})
    return player.get("area","?")==area and absi(int(player.get("x",-999999))-x)+absi(int(player.get("y",-999999))-y)<=1
