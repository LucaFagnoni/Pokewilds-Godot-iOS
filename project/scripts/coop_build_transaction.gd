extends RefCounted
## Host-only commit boundary for every player's existing placement validation.
## Never accepts a client-supplied price or writes personal state before the world.
const Crafting=preload("res://scripts/crafting_data.gd")
const Delta=preload("res://scripts/coop_world_delta.gd")
var state
var areas
var world_delta

func dig(actor:String,id:String,area:String,patches:Array,rewards:Dictionary,choice:String,profile_hash:String)->Dictionary:
    if id.is_empty() or id.length()>48:return {"ok":false,"reason":"invalid_request"}
    var hash_value=state.fingerprint([area,patches,rewards,choice,profile_hash])
    var previous:Dictionary=state.outcomes.get(actor+"/field_dig/"+id,{})
    if not previous.is_empty():
        return previous.duplicate(true) if previous.get("command_hash")==hash_value else {"ok":false,"reason":"reused_request_id"}
    if not state.members.has(actor) or state.members[actor].get("area")!=area:return {"ok":false,"reason":"different_area"}
    for patch in patches:
        if not patch is Dictionary or not patch.get("key") is String:return {"ok":false,"reason":"invalid_changes"}
        if String(patch.key).get_slice("/",0) not in ["source_interior_mutations","source_plant_farms","removed_resources","terrain_changes","built_house_decorations"]:return {"ok":false,"reason":"unrelated_change"}
    var allowed=preload("res://scripts/item_data.gd").all_items()
    for item in rewards:
        var amount=rewards[item]
        if item not in allowed or typeof(amount) not in [TYPE_INT,TYPE_FLOAT]:return {"ok":false,"reason":"invalid_reward"}
        if not is_finite(float(amount)) or float(amount)!=floor(float(amount)) or amount<1 or amount>999:return {"ok":false,"reason":"invalid_reward"}
    var cost:Dictionary={}
    if choice.begins_with("PLANT:"):
        var item=choice.trim_prefix("PLANT:")
        if not preload("res://scripts/source_plant_farming.gd").plantable(item):return {"ok":false,"reason":"invalid_plant"}
        cost[item]=1
    elif not choice.is_empty():
        var info=preload("res://scripts/field_move_data.gd").dig_choice_info(choice)
        if info.is_empty():return {"ok":false,"reason":"invalid_soil"}
        cost[String(info.material)]=1
    var profile:Dictionary=state.records.get("player/"+actor,{})
    if profile.is_empty() or state.fingerprint(profile)!=profile_hash:return {"ok":false,"reason":"profile_changed"}
    if not Crafting.can_afford(profile.get("inventory",{}),cost):return {"ok":false,"reason":"not_enough_materials"}
    var prepared=world_delta.prepare_changes(area,patches)
    if not prepared.get("ok",false):return prepared
    var changed=false
    for change in prepared.changes:
        if change.before!=state.fingerprint(change.after):changed=true;break
    if not changed:return {"ok":false,"reason":"no_change"}
    var updated=profile.duplicate(true)
    Crafting.consume(updated.inventory,cost)
    for item in rewards:Crafting.grant(updated.inventory,String(item),int(rewards[item]))
    prepared.changes.append(state.change("player/"+actor,updated))
    return state.transact(actor,"field_dig/"+id,prepared.changes,hash_value)

func cut(actor:String,id:String,area:String,patches:Array,rewards:Dictionary,profile_hash:String,move:String="CUT")->Dictionary:
    if id.is_empty() or id.length()>48:return {"ok":false,"reason":"invalid_request"}
    if move not in ["CUT","SMASH","HEADBUTT"]:return {"ok":false,"reason":"invalid_move"}
    var hash_value=state.fingerprint([area,patches,rewards,profile_hash,move])
    var previous:Dictionary=state.outcomes.get(actor+"/field_cut/"+id,{})
    if not previous.is_empty():
        return previous.duplicate(true) if previous.get("command_hash")==hash_value else {"ok":false,"reason":"reused_request_id"}
    if not state.members.has(actor) or state.members[actor].get("area")!=area:return {"ok":false,"reason":"different_area"}
    for patch in patches:
        if not patch is Dictionary or not patch.get("key") is String:return {"ok":false,"reason":"invalid_changes"}
        if String(patch.key).get_slice("/",0) not in ["source_interior_mutations","source_plant_farms","removed_resources"]:return {"ok":false,"reason":"unrelated_change"}
    var allowed:Array=["GRASS","LOG","MIRACLE SEED","BERRY SEED"]
    allowed.append_array(Crafting.APRICORNS)
    if move!="CUT":allowed=["HARD STONE","MOON STONE"]
    for item in rewards:
        var amount=rewards[item]
        if item not in allowed or typeof(amount) not in [TYPE_INT,TYPE_FLOAT]:return {"ok":false,"reason":"invalid_reward"}
        if not is_finite(float(amount)) or float(amount)!=floor(float(amount)) or amount<1 or amount>64:return {"ok":false,"reason":"invalid_reward"}
    var profile:Dictionary=state.records.get("player/"+actor,{})
    if profile.is_empty() or state.fingerprint(profile)!=profile_hash:return {"ok":false,"reason":"profile_changed"}
    var prepared=world_delta.prepare_changes(area,patches)
    if not prepared.get("ok",false):return prepared
    var changed=false
    for change in prepared.changes:
        if change.before!=state.fingerprint(change.after):changed=true;break
    if not changed:return {"ok":false,"reason":"no_change"}
    var updated=profile.duplicate(true)
    for item in rewards:Crafting.grant(updated.inventory,String(item),int(rewards[item]))
    prepared.changes.append(state.change("player/"+actor,updated))
    return state.transact(actor,"field_cut/"+id,prepared.changes,hash_value)

func paint(actor:String,id:String,area:String,patches:Array,profile_hash:String)->Dictionary:
    if id.is_empty() or id.length()>48:return {"ok":false,"reason":"invalid_request"}
    var hash_value=state.fingerprint([area,patches,profile_hash])
    var previous:Dictionary=state.outcomes.get(actor+"/paint/"+id,{})
    if not previous.is_empty():
        return previous.duplicate(true) if previous.get("command_hash")==hash_value else {"ok":false,"reason":"reused_request_id"}
    if not state.members.has(actor) or state.members[actor].get("area")!=area:return {"ok":false,"reason":"different_area"}
    if patches.size()!=1:return {"ok":false,"reason":"invalid_changes"}
    var patch=patches[0]
    if not patch is Dictionary or not patch.get("key") is String or not patch.get("after") is String:return {"ok":false,"reason":"invalid_changes"}
    if String(patch.key).get_slice("/",0)!="built_house_paintings":return {"ok":false,"reason":"unrelated_change"}
    var picture=Delta.decode(patch.after)
    if not picture is int or picture<1 or picture>20:return {"ok":false,"reason":"invalid_picture"}
    var profile:Dictionary=state.records.get("player/"+actor,{})
    if profile.is_empty() or state.fingerprint(profile)!=profile_hash:return {"ok":false,"reason":"profile_changed"}
    if int(profile.get("inventory",{}).get("THIN PAPER",0))<1:return {"ok":false,"reason":"not_enough_materials"}
    var prepared=world_delta.prepare_changes(area,patches)
    if not prepared.get("ok",false):return prepared
    var updated=profile.duplicate(true)
    updated.inventory["THIN PAPER"]=int(updated.inventory["THIN PAPER"])-1
    prepared.changes.append(state.change("player/"+actor,updated))
    return state.transact(actor,"paint/"+id,prepared.changes,hash_value)

func commit(builder:String,id:String,owner:String,area:String,epoch:int,recipe_name:String,
        cell:Vector2i,patches:Array,profile_hash:String)->Dictionary:
    if id.is_empty() or id.length()>48:return {"ok":false,"reason":"invalid_request"}
    var hash_value=state.fingerprint([owner,area,epoch,recipe_name,cell,patches,profile_hash])
    var previous:Dictionary=state.outcomes.get(builder+"/build/"+id,{})
    if not previous.is_empty():
        return previous.duplicate(true) if previous.get("command_hash")==hash_value else {"ok":false,"reason":"reused_request_id"}
    if not state.members.has(builder) or state.members[builder].get("area")!=area:
        return {"ok":false,"reason":"different_area"}
    if not areas.can_publish(owner,area,epoch):return {"ok":false,"reason":"stale_authority"}
    var recipe=Crafting.build_recipe(recipe_name)
    if recipe.is_empty():return {"ok":false,"reason":"invalid_recipe"}
    # The builder's own game refuses a tile with a Pokemon or egg on it, but it
    # only knows where they were a moment ago. The host knows where they are.
    if bool(recipe.get("solid",false)):
        var spot=("%d,%d"%[cell.x,cell.y]).uri_encode()
        for group in ["deployed_pokemon","wild_eggs"]:
            if Delta.decode(state.records.get("world/"+area+"/"+group+"/"+spot,Delta.encode(null))) is Dictionary:
                return {"ok":false,"reason":"occupied"}
    var profile:Dictionary=state.records.get("player/"+builder,{})
    if profile.is_empty() or state.fingerprint(profile)!=profile_hash:return {"ok":false,"reason":"profile_changed"}
    if not Crafting.can_afford(profile.get("inventory",{}),recipe.get("cost",{})):
        return {"ok":false,"reason":"not_enough_materials"}
    # A build may update neighboring shell attachments, stair mirrors and house
    # floors, but never Pokemon, event flags, resource rewards or the shared clock.
    for patch in patches:
        if not patch is Dictionary or not patch.get("key") is String:
            return {"ok":false,"reason":"invalid_changes"}
        if String(patch.key).get_slice("/",0) not in ["structures","built_house_floor_tiles",
                "built_house_paintings","built_house_decorations","built_house_origins"]:
            return {"ok":false,"reason":"unrelated_change"}
    var prepared:Dictionary=world_delta.prepare_changes(area,patches)
    if not prepared.get("ok",false):return prepared
    var actually_changed=false
    for change in prepared.changes:
        if change.before!=state.fingerprint(change.after):actually_changed=true;break
    if not actually_changed:return {"ok":false,"reason":"no_change"}
    var changed_profile=profile.duplicate(true)
    Crafting.consume(changed_profile.inventory,recipe.get("cost",{}))
    var changes:Array=prepared.changes
    changes.append(state.change("player/"+builder,changed_profile))
    # Register the chest in the same durable write as its construction. A catch
    # immediately after placement must never wait for a later full-area save.
    if recipe_name in ["STORAGE BOX","PRIVATE CHEST"]:
        var target="structures/"+("%d,%d"%[cell.x,cell.y]).uri_encode()
        var placed:Dictionary={}
        for patch in patches:
            if patch.key==target:
                var value=Delta.decode(patch.after)
                if value is Dictionary:placed=value
        if placed.get("name")!=recipe_name:return {"ok":false,"reason":"missing_placement"}
        var box=area+"|%d,%d"%[cell.x,cell.y]
        changes.append(state.change("chest/"+box,{"id":box,"area":area,"x":cell.x,"y":cell.y,
            "private":recipe_name=="PRIVATE CHEST","capacity":4096}))
        if recipe_name=="STORAGE BOX" and not state.records.has("box/"+box):
            changes.append(state.change("box/"+box,[]))
    elif recipe_name=="BEACON":
        var target="structures/"+("%d,%d"%[cell.x,cell.y]).uri_encode()
        var placed:Dictionary={}
        for patch in patches:
            if patch.key==target:
                var value=Delta.decode(patch.after)
                if value is Dictionary:placed=value
        if placed.get("name")!="BEACON":return {"ok":false,"reason":"missing_placement"}
        if not placed.has("house_door"):
            changes.append(state.change("beacon/"+area+"|%d,%d"%[cell.x,cell.y],
                {"area":area,"x":cell.x,"y":cell.y,"name":"BEACON"}))
    return state.transact(builder,"build/"+id,changes,hash_value)

## A window or clock taken off a house wall. The only change allowed is that
## one decoration disappearing; its own recipe decides the refund.
func remove_decoration(builder:String,id:String,area:String,patches:Array,profile_hash:String)->Dictionary:
    if id.is_empty() or id.length()>48:return {"ok":false,"reason":"invalid_request"}
    var hash_value=state.fingerprint([area,"decoration",patches,profile_hash])
    var previous:Dictionary=state.outcomes.get(builder+"/remove_build/"+id,{})
    if not previous.is_empty():
        if previous.get("command_hash")!=hash_value:return {"ok":false,"reason":"reused_request_id"}
        var replay=previous.duplicate(true)
        replay["refund"]=state.records.get("build_refund/"+builder+"/"+id,{}).duplicate(true)
        return replay
    if not state.members.has(builder) or state.members[builder].get("area")!=area:return {"ok":false,"reason":"different_area"}
    if patches.size()!=1 or not patches[0] is Dictionary or not patches[0].get("key") is String or not patches[0].get("after") is String:
        return {"ok":false,"reason":"invalid_changes"}
    var patch:Dictionary=patches[0]
    if String(patch.key).get_slice("/",0)!="built_house_decorations" or patch.after!=Delta.encode(null):return {"ok":false,"reason":"invalid_removal"}
    var hung=Delta.decode(state.records.get("world/"+area+"/"+String(patch.key),Delta.encode(null)))
    if not hung is Dictionary:return {"ok":false,"reason":"already_removed"}
    var hung_name=String(hung.get("name",""))
    if hung_name!="CLOCK" and hung_name!="WINDOW" and not hung_name.begins_with("INDOOR WINDOW "):return {"ok":false,"reason":"invalid_removal"}
    var profile:Dictionary=state.records.get("player/"+builder,{})
    if profile.is_empty() or state.fingerprint(profile)!=profile_hash:return {"ok":false,"reason":"profile_changed"}
    var prepared:Dictionary=world_delta.prepare_changes(area,patches)
    if not prepared.get("ok",false):return prepared
    var refund:Dictionary=Crafting.build_recipe(hung_name).get("cost",{})
    var changed_profile=profile.duplicate(true)
    for item in refund:Crafting.grant(changed_profile.inventory,String(item),int(refund[item]))
    var changes:Array=prepared.changes
    changes.append(state.change("player/"+builder,changed_profile))
    changes.append(state.change("build_refund/"+builder+"/"+id,refund.duplicate(true)))
    var result:Dictionary=state.transact(builder,"remove_build/"+id,changes,hash_value)
    if result.get("ok",false):result["refund"]=refund.duplicate(true)
    return result

func remove(builder:String,id:String,area:String,cell:Vector2i,move:String,patches:Array,profile_hash:String)->Dictionary:
    if id.is_empty() or id.length()>48 or move not in ["CUT","SMASH"]:return {"ok":false,"reason":"invalid_request"}
    var hash_value=state.fingerprint([area,cell,move,patches,profile_hash])
    var previous:Dictionary=state.outcomes.get(builder+"/remove_build/"+id,{})
    if not previous.is_empty():
        if previous.get("command_hash")!=hash_value:return {"ok":false,"reason":"reused_request_id"}
        var replay=previous.duplicate(true)
        replay["refund"]=state.records.get("build_refund/"+builder+"/"+id,{}).duplicate(true)
        return replay
    if not state.members.has(builder) or state.members[builder].get("area")!=area:return {"ok":false,"reason":"different_area"}
    var key="structures/"+("%d,%d"%[cell.x,cell.y]).uri_encode()
    var raw=Delta.decode(state.records.get("world/"+area+"/"+key,Delta.encode(null)))
    if not raw is Dictionary:return {"ok":false,"reason":"already_removed"}
    var grave_or_statue=raw.get("name") in ["GRAVE","STATUE"]
    if (move=="CUT" and grave_or_statue) or (move=="SMASH" and not grave_or_statue):return {"ok":false,"reason":"wrong_field_move"}
    var removed=false
    for patch in patches:
        if not patch is Dictionary or not patch.get("key") is String or not patch.get("after") is String:return {"ok":false,"reason":"invalid_changes"}
        var group=String(patch.key).get_slice("/",0)
        if group not in ["structures","built_house_decorations","built_house_floor_tiles","built_house_paintings","source_interior_mutations"]:return {"ok":false,"reason":"unrelated_change"}
        if group=="structures" and patch.after!=Delta.encode(null):
            # Removing a piece reshapes the pieces joined to it (a wall or fence
            # run reconnects), which rewrites their records. That is allowed;
            # adding a piece or turning one into something else is not.
            var joined=Delta.decode(state.records.get("world/"+area+"/"+String(patch.key),Delta.encode(null)))
            var reshaped=Delta.decode(patch.after)
            if not joined is Dictionary or not reshaped is Dictionary or joined.get("name")!=reshaped.get("name") or joined.get("recipe_name")!=reshaped.get("recipe_name"):
                return {"ok":false,"reason":"invalid_removal"}
        if patch.key==key and patch.after==Delta.encode(null):removed=true
    if not removed:return {"ok":false,"reason":"missing_removal"}
    var profile:Dictionary=state.records.get("player/"+builder,{})
    if profile.is_empty() or state.fingerprint(profile)!=profile_hash:return {"ok":false,"reason":"profile_changed"}
    var box=area+"|%d,%d"%[cell.x,cell.y]
    if raw.get("name")=="STORAGE BOX" and not state.records.get("box/"+box,[]).is_empty():return {"ok":false,"reason":"box_not_empty"}
    var prepared:Dictionary=world_delta.prepare_changes(area,patches)
    if not prepared.get("ok",false):return prepared
    var refund:Dictionary=Crafting.build_recipe(String(raw.get("recipe_name",raw.get("name","")))).get("cost",{})
    var changed_profile=profile.duplicate(true)
    for item in refund:Crafting.grant(changed_profile.inventory,String(item),int(refund[item]))
    var changes:Array=prepared.changes
    changes.append(state.change("player/"+builder,changed_profile))
    changes.append(state.change("build_refund/"+builder+"/"+id,refund.duplicate(true)))
    if state.records.has("chest/"+box):
        var chest:Dictionary=state.records["chest/"+box].duplicate(true);chest["retired"]=true
        changes.append(state.change("chest/"+box,chest))
    if state.records.has("beacon/"+box):changes.append(state.change("beacon/"+box,null))
    var result:Dictionary=state.transact(builder,"remove_build/"+id,changes,hash_value)
    if result.get("ok",false):
        # The caller displays the existing GOT popup; inventory was already
        # changed atomically, so the popup must not grant the refund again.
        result["refund"]=refund.duplicate(true)
    return result
