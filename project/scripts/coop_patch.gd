extends RefCounted
## The difference between two saved records, as a short list of edits.
## A player record is tens of kilobytes; what changes between two checkpoints
## is usually a position or one item count. Sending and journaling the edits
## instead of the whole record is what keeps ONLINE traffic and saves small.
##
## An edit is ["s", path, value] (set), ["d", path] (delete),
## ["a", path, values] (add to the end of a list, such as the explored map) or
## ["r", path] (take one entry out of a list; see diff_list).
## A path is the list of dictionary keys and array indexes leading to the value.
const MAX_EDITS:=4096
const MAX_DEPTH:=12

## Numbers compare by value and dictionary keys by their text, because one
## side of a comparison has often been through JSON (5 becomes 5.0, 3 becomes "3").
static func same(a:Variant,b:Variant)->bool:
    var ta:=typeof(a);var tb:=typeof(b)
    if ta in [TYPE_INT,TYPE_FLOAT] and tb in [TYPE_INT,TYPE_FLOAT]:return float(a)==float(b)
    if ta==TYPE_DICTIONARY and tb==TYPE_DICTIONARY:
        if a.size()!=b.size():return false
        for key in a:
            var other=_lookup(b,key)
            if other==null and not _has(b,key):return false
            if not same(a[key],other):return false
        return true
    if ta==TYPE_ARRAY and tb==TYPE_ARRAY:
        if a.size()!=b.size():return false
        for index in range(a.size()):
            if not same(a[index],b[index]):return false
        return true
    if ta in [TYPE_STRING,TYPE_STRING_NAME] and tb in [TYPE_STRING,TYPE_STRING_NAME]:return String(a)==String(b)
    return ta==tb and a==b

## The key as this dictionary spells it: as given, as text, or as a number.
## Returns null when the dictionary has no such entry.
static func _spelling(dictionary:Dictionary,key:Variant)->Variant:
    if dictionary.has(key):return key
    var text:=str(key)
    if typeof(key)==TYPE_FLOAT and float(int(key))==key:text=str(int(key))
    if dictionary.has(text):return text
    if text.is_valid_int():
        if dictionary.has(int(text)):return int(text)
        if dictionary.has(float(text)):return float(text)
    return null

static func _has(dictionary:Dictionary,key:Variant)->bool:
    return _spelling(dictionary,key)!=null

static func _lookup(dictionary:Dictionary,key:Variant)->Variant:
    var found:Variant=_spelling(dictionary,key)
    return null if found==null else dictionary[found]

## Edits that turn `old` into `new`. An empty list means nothing changed.
static func diff(old:Variant,new:Variant)->Array:
    var edits:Array=[]
    _walk(old,new,[],edits)
    return edits

static func _walk(old:Variant,new:Variant,path:Array,edits:Array)->void:
    # An untouched branch is settled in one comparison rather than a visit to
    # every entry; a player's explored-map list alone is tens of thousands.
    if typeof(old)==typeof(new) and (old is Array or old is Dictionary) and old==new:return
    if old is Dictionary and new is Dictionary and path.size()<MAX_DEPTH:
        for key in new:
            var step:Array=path.duplicate();step.append(str(key))
            if _has(old,key):_walk(_lookup(old,key),new[key],step,edits)
            else:edits.append(["s",step,new[key]])
        for key in old:
            if not _has(new,key):
                var step:Array=path.duplicate();step.append(str(key))
                edits.append(["d",step])
        return
    if old is Array and new is Array and old.size()==new.size() and path.size()<MAX_DEPTH:
        for index in range(new.size()):
            var step:Array=path.duplicate();step.append(index)
            _walk(old[index],new[index],step,edits)
        return
    if old is Array and new is Array and not old.is_empty() and new.size()>old.size() and not path.is_empty():
        var grown:bool=new.slice(0,old.size())==old
        if not grown:
            grown=true
            for index in range(old.size()):
                if not same(old[index],new[index]):grown=false;break
        if grown:edits.append(["a",path,new.slice(old.size())]);return
    if not same(old,new):
        if path.is_empty():edits.append(["s",[],new])
        else:edits.append(["s",path,new])

## A whole list (a storage box) changed by what storage does to it: entries
## added at the end, one taken out, or entries changed in place. [] when it
## changed some other way, and is better sent whole. A box of 200 Pokemon is
## 200 KB as text; a deposit or a release went to every player as all of it.
static func diff_list(old:Array,new:Array)->Array:
    if new.size()==old.size():return diff(old,new)
    if new.size()>old.size():return [["a",[],new.slice(old.size())]] if new.slice(0,old.size())==old else []
    if new.size()!=old.size()-1:return []
    var index:=0
    while index<new.size() and new[index]==old[index]:index+=1
    return [["r",[index]]] if old.slice(index+1)==new.slice(index) else []

static func valid(edits:Variant)->bool:
    if not edits is Array or edits.size()>MAX_EDITS:return false
    for edit in edits:
        if not edit is Array or edit.size()<2 or not edit[0] in ["s","d","a","r"] or not edit[1] is Array:return false
        if edit[1].size()>MAX_DEPTH or (edit[0]=="s" and edit.size()!=3) or (edit[0] in ["d","r"] and edit.size()!=2):return false
        if edit[0]=="r" and edit[1].is_empty():return false
        if edit[0]=="a" and (edit.size()!=3 or not edit[2] is Array):return false
        for step in edit[1]:
            if typeof(step) not in [TYPE_STRING,TYPE_INT,TYPE_FLOAT]:return false
    return true

## Returns a changed deep copy of `record`, or null when an edit does not fit
## it (the caller then asks for the whole record instead).
static func apply(record:Variant,edits:Array)->Variant:
    var result:Variant=record.duplicate(true) if record is Dictionary or record is Array else record
    for edit in edits:
        var path:Array=edit[1]
        if path.is_empty():
            if edit[0]=="a" and result is Array:result.append_array(edit[2].duplicate(true));continue
            if edit[0]!="s":return null
            result=edit[2].duplicate(true) if edit[2] is Dictionary or edit[2] is Array else edit[2]
            continue
        var container:Variant=result
        for depth in range(path.size()-1):
            container=_child(container,path[depth])
            if container==null:return null
        var last:Variant=path[-1]
        if edit[0]=="a":
            var list:Variant=_child(container,last)
            if not list is Array:return null
            list.append_array(edit[2].duplicate(true))
            continue
        if container is Dictionary:
            var key:Variant=_key_for(container,last)
            if edit[0]=="r":return null
            if edit[0]=="d":container.erase(key)
            else:container[key]=edit[2].duplicate(true) if edit[2] is Dictionary or edit[2] is Array else edit[2]
        elif container is Array:
            if typeof(last) not in [TYPE_INT,TYPE_FLOAT] or edit[0] not in ["s","r"]:return null
            var index:=int(last)
            if index<0 or index>=container.size():return null
            if edit[0]=="r":container.remove_at(index);continue
            container[index]=edit[2].duplicate(true) if edit[2] is Dictionary or edit[2] is Array else edit[2]
        else:return null
    return result

static func _key_for(container:Dictionary,step:Variant)->Variant:
    # Use the dictionary's own spelling of an existing key; a new key is text,
    # as every key is once a record has been saved.
    var found:Variant=_spelling(container,step)
    if found!=null:return found
    return str(int(step)) if typeof(step)==TYPE_FLOAT and float(int(step))==step else str(step)

static func _child(container:Variant,step:Variant)->Variant:
    if container is Dictionary:
        return _lookup(container,step)
    if container is Array and typeof(step) in [TYPE_INT,TYPE_FLOAT]:
        var index:=int(step)
        return container[index] if index>=0 and index<container.size() else null
    return null
