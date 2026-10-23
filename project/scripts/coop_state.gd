extends RefCounted
## Host-owned transactional model. No generation or species rules live here.
var revision := 0
var records: Dictionary = {}
var outcomes: Dictionary = {}
var members: Dictionary = {}
var authority: Dictionary = {}
var commit_writer := Callable()
const Patch = preload("res://scripts/coop_patch.gd")
const MAX_CHANGES := 4096
const RECENT_RESULTS := 128
## Receipts exist so a request retried within seconds is not applied twice.
## Older ones are kept as small stubs for a while, then dropped; without a
## limit the world save and its memory grow for as long as the world is played.
const REMEMBERED_RESULTS := 4096
var _recent_outcomes:Array=[]
var _old_outcomes:Array=[]
## Commits that changed state but were not written to the journal: creature
## movement, which the next world save captures. `unwritten` counts those since
## the last journaled commit so a reload can tell a planned gap from a lost
## line; `loose` counts those since the last world save.
var unwritten := 0
var loose := 0
## Goes up whenever a record appears or disappears, never when one only changes
## value. Lets callers keep a list of the keys they care about instead of
## walking every record several times a second.
var key_epoch := 0
var _prints := {}
var replaced := {}
## Indexes over `records`, kept up to date by _index() wherever a record
## changes (apply_committed, which journal replay also goes through, and
## restore). They spare coop_wild_population.gd a walk over every record of
## the world for each claim, namespace or unique Pokemon. Read-only to others.
## actor -> {wild_claim key: true}
var claims_by_actor := {}
## area -> {"world/<area>/wild_pokemon/<id>" key: true}
var wild_by_area := {}
var _namespace_max := 0
var _namespace_stale := false
## Host option: when false nothing is appended to the journal; the world is
## written only by an explicit save. For telling save cost apart from the rest.
static var journal_enabled := true

## A world record is encoded text (coop_world_delta.gd encode), and players
## send the fingerprint of the one they last saw: it is hashed as it is, with
## no JSON copy of it first (16 KB: 67 -> 40 us, the hash itself). Anything
## else is hashed as JSON with sorted keys, after a mark no record text starts
## with: Godot's JSON writer is native and beat sorting and var_to_bytes in
## script (a 300-entry dictionary: 0.68 ms against 1.3 ms). Host and players
## must agree on these: changing them changes Session.PROTOCOL.
static func fingerprint(value: Variant) -> String:
    if value is String: return value.sha256_text()
    return ("\u001f" + JSON.stringify(value, "", true, true)).sha256_text()

## The fingerprint of a stored record, worked out once per change to it. A
## player's record is a few hundred kilobytes and is asked about many times.
func print_of(key: String, missing: Variant = null) -> String:
    if not records.has(key): return fingerprint(missing)
    if not _prints.has(key):
        # A player's record is a few hundred kilobytes, and hashing it took
        # about 45 ms on the host every time it changed: on every save of every
        # player, and several times over for a cut or a build. Nothing needs
        # to know what is in it, only whether it is still the one a player
        # last saw, so it gets a fresh ticket each time it changes instead.
        if key.begins_with("player/"):
            _ticket += 1
            _prints[key] = "t%08x-%d" % [_ticket_salt, _ticket]
        else:
            _prints[key] = fingerprint(records[key])
    return _prints[key]

var _ticket_salt := randi()
var _ticket := 0

## The request hash of a set of changes. A whole player record in it is stood
## in for by its quick built-in hash rather than written out and hashed.
static func _request_print(changes: Array) -> String:
    var light: Array = []
    for change in changes:
        if change is Dictionary and String(change.get("key", "")).begins_with("player/") and change.get("after") is Dictionary:
            var stand_in: Dictionary = change.duplicate()
            stand_in["after"] = (change.after as Dictionary).hash()
            light.append(stand_in)
        else:
            light.append(change)
    return fingerprint(light)

func enroll(actor: String, profile: Dictionary) -> bool:
    if actor.is_empty() or actor.length() > 128: return false
    # A returning player may have picked a new name, model or colour; the host
    # must not keep showing the old one (their portrait in a player battle).
    var area: Variant = members.get(actor, {}).get("area")
    members[actor] = profile.duplicate(true)
    if area != null: members[actor]["area"] = area
    return true

func enter(actor: String, area: String) -> String:
    if not members.has(actor) or area.is_empty(): return ""
    if members[actor].get("area", "") == area and authority.has(area):
        return authority[area]
    leave(actor)
    members[actor]["area"] = area
    if not authority.has(area): authority[area] = actor
    return authority[area]

func leave(actor: String) -> void:
    if not members.has(actor): return
    var area := String(members[actor].get("area", ""))
    members[actor].erase("area")
    if authority.get(area, "") != actor: return
    authority.erase(area)
    for other in members:
        if members[other].get("area", "") == area:
            authority[area] = other
            break

## Who may change what (no deep copies but where ownership changes):
## - `changes`, and every value in them, belong to the commit from this call
##   on: the caller builds them for it and leaves them alone afterwards.
## - The result handed back is the caller's, to read or change; it shares
##   those values. commit_writer turns it into text before returning.
## - `records` hold their own copy of each value (apply_committed), and
##   `outcomes` their own copy of the commit (the receipt); only this script
##   changes either. Receipts are handed out as copies.
func transact(actor: String, id: String, changes: Array, command_hash: String = "", durable: bool = true) -> Dictionary:
    if not members.has(actor) or id.is_empty() or id.length() > 80:
        return {"ok":false,"reason":"invalid_request"}
    var request_key := actor + "/" + id
    var request_hash := _request_print(changes)
    if outcomes.has(request_key):
        if outcomes[request_key].get("request_hash", "") != request_hash:
            return {"ok":false,"reason":"reused_request_id"}
        return outcomes[request_key].duplicate(true)
    if changes.is_empty() or changes.size() > MAX_CHANGES:
        return {"ok":false,"reason":"invalid_changes"}
    var unique := {}
    # Edited records, worked out once here and kept for apply_committed.
    var staged := {}
    for change in changes:
        if not change is Dictionary: return {"ok":false,"reason":"invalid_changes"}
        var key := String(change.get("key", ""))
        if key.is_empty() or key.length() > 256 or unique.has(key):
            return {"ok":false,"reason":"invalid_key"}
        unique[key] = true
        if not change.has("before") or not (change.has("after") or change.has("edits")):
            return {"ok":false,"reason":"missing_value"}
        # Edits must fit the record before anything is written to the journal.
        if change.has("edits"):
            var edited = Patch.apply(records.get(key), change.edits) if Patch.valid(change.edits) else null
            if edited == null: return {"ok":false,"reason":"invalid_changes"}
            staged[key] = edited
        if print_of(key) != String(change.before):
            return {"ok":false,"reason":"conflict","key":key,
                "current":records.get(key),"revision":revision}
    var result := {"ok":true,"revision":revision+1,"actor":actor,"command_hash":command_hash,
        "id":id,"request_hash":request_hash,"changes":changes.duplicate()}
    # What changed in each player's record, worked out once against the record
    # as it was. The journal keeps this, and the owner is sent it, instead of
    # the whole record, which runs to hundreds of kilobytes and took seconds
    # to reach them after every pickup, chest or build.
    var player_edits := {}
    for change in changes:
        var key := String(change.key)
        if key.begins_with("player/") and change.get("after") is Dictionary and records.get(key) is Dictionary:
            var edits := Patch.diff(records[key], change.after)
            if not edits.is_empty() and Patch.valid(edits): player_edits[key] = edits
    # The same for a storage box, for the players only (the journal keeps it whole).
    var list_edits := {}
    for change in changes:
        var key := String(change.key)
        if (key.begins_with("box/") or key.begins_with("private_box/")) and change.get("after") is Array and records.get(key) is Array:
            var edits := Patch.diff_list(records[key], change.after)
            if not edits.is_empty() and Patch.valid(edits): list_edits[key] = edits
    # The encoded records this commit replaces, by key, with the fingerprint
    # they had: the host sends players only what changed in them (coop_game).
    replaced.clear()
    for change in changes:
        if change.get("after") is String and records.get(change.key) is String:
            replaced[String(change.key)] = [String(change.before), records[change.key]]
    # Durable write before acknowledging or changing the visible state.
    if not durable or not journal_enabled: unwritten += 1; loose += 1
    elif commit_writer.is_valid():
        if not commit_writer.call(_journal_form(result, player_edits), unwritten): return {"ok":false,"reason":"save_failed"}
        unwritten = 0
    apply_committed(result, staged)
    for change in changes:
        var key := String(change.key)
        if not key.begins_with("player/"): continue
        if change.has("edits"): _bump_parts(key, change)
        elif player_edits.has(key): _bump_parts(key, {"edits": player_edits[key]})
        else: _bump_parts(key, {})
    if not player_edits.is_empty(): result["player_edits"] = player_edits
    if not list_edits.is_empty(): result["list_edits"] = list_edits
    return result

## Building, storing or picking something up hands back the player's whole
## record. Players are still sent it whole; the journal keeps only what changed.
func _journal_form(commit: Dictionary, player_edits: Dictionary) -> Dictionary:
    var slim: Array = []
    var smaller := false
    for change in commit.changes:
        var key := String(change.key)
        if change.has("after") and player_edits.has(key):
            slim.append({"key":key,"before":change.before,"edits":player_edits[key]})
            smaller = true
            continue
        slim.append(change)
    if not smaller: return commit
    var written := commit.duplicate()
    written["changes"] = slim
    return written

func apply_committed(commit: Dictionary, staged: Dictionary = {}) -> bool:
    if int(commit.get("revision", -1)) != revision + 1: return false
    for change in commit.get("changes", []):
        var key := String(change.key)
        _prints.erase(key)
        var old: Variant = records.get(key)
        if change.has("edits"):
            # A record changed in place: only the edits were sent and journaled.
            var edited = staged[key] if staged.has(key) else Patch.apply(old, change.edits)
            if edited == null: return false
            records[key] = edited
        elif change.after == null:
            if records.erase(key): key_epoch += 1
        else:
            if not records.has(key): key_epoch += 1
            records[key] = change.after.duplicate(true) if change.after is Dictionary or change.after is Array else change.after
        _index(key, old, records.get(key))
    revision += 1
    var request_key:=String(commit.actor)+"/"+String(commit.id)
    var receipt:Dictionary=commit.duplicate()
    # A player checkpoint is never replayed from its receipt (a retry only asks
    # whether the id is known), and its changes are a whole player record.
    if String(commit.id).begins_with("profile/"):receipt.erase("changes")
    receipt=receipt.duplicate(true)
    outcomes[request_key] = receipt
    _recent_outcomes.append(request_key)
    if _recent_outcomes.size()>RECENT_RESULTS:
        var older:String=_recent_outcomes.pop_front()
        if outcomes.has(older):
            outcomes[older].erase("changes")
            outcomes[older]["resync"]=true
            _old_outcomes.append(older)
    while _old_outcomes.size()>REMEMBERED_RESULTS:
        outcomes.erase(_old_outcomes.pop_front())
    return true

## A player record in parts, each with its own revision ("player/<actor>" ->
## part -> n), raised by every commit that changes the part. A command reads
## only the parts it declares (coop_game.gd OP_PARTS), and a save of only those
## parts is checked against their revisions, not against the whole record.
const PARTS := {"party": ["party"], "bag": ["inventory"], "pokedex": ["save", "pokedex"], "pokedex_shiny": ["save", "pokedex_shiny"],
    "discovery": ["save", "crafting_state", "discovered_cells"], "position": ["save", "player_x"], "position_y": ["save", "player_y"],
    "storage": ["save", "coop_pending_pokemon"]}
var part_revisions := {}

## The part of a player record a path is in ("save" for the rest of the save).
static func part_of(path: Array) -> String:
    if path.is_empty(): return ""
    for part in PARTS:
        var at: Array = PARTS[part]
        if path.size() >= at.size() and path.slice(0, at.size()) == at: return "position" if part == "position_y" else part
    return "save" if String(path[0]) == "save" else String(path[0])

func revisions_of(actor: String) -> Dictionary:
    return part_revisions.get("player/" + actor, {})

func _bump_parts(key: String, change: Dictionary) -> void:
    var held: Dictionary = part_revisions.get_or_add(key, {})
    if change.has("edits"):
        var touched := {}
        for edit in change.edits:
            if edit is Array and edit.size() > 1 and edit[1] is Array: touched[part_of(edit[1])] = true
        for part in touched: held[part] = int(held.get(part, 0)) + 1
    else:
        for part in ["party", "bag", "pokedex", "pokedex_shiny", "discovery", "position", "storage", "save"]:
            held[part] = int(held.get(part, 0)) + 1

func change(key: String, value: Variant) -> Dictionary:
    return {"key":key,"before":print_of(key),"after":value}

## The same change written as edits to the stored record, when it has one.
## Returns {} when the record already equals `value`.
func change_edits(key: String, value: Variant) -> Dictionary:
    if not records.has(key): return change(key, value)
    var edits := Patch.diff(records[key], value)
    if edits.is_empty(): return {}
    return {"key":key,"before":print_of(key),"edits":edits}

func snapshot() -> Dictionary:
    return {"revision":revision,"records":records.duplicate(true),
        "outcomes":outcomes.duplicate(true),"members":members.duplicate(true)}

func restore(data: Dictionary) -> bool:
    if not data.get("records") is Dictionary or not data.get("outcomes") is Dictionary or not data.get("members") is Dictionary:
        return false
    revision = int(data.get("revision", 0))
    unwritten = 0; loose = 0; key_epoch += 1
    records = data.records.duplicate(true)
    _prints.clear()
    reindex()
    # No request survives a restart of the host, so only receipts that still
    # carry their changes are worth keeping; stubs from earlier sessions go.
    outcomes = {}
    _recent_outcomes.clear();_old_outcomes.clear()
    for key in data.outcomes:
        var saved=data.outcomes[key]
        if saved is Dictionary and saved.has("changes") and _recent_outcomes.size()<RECENT_RESULTS:
            outcomes[key]=saved.duplicate(true);_recent_outcomes.append(key)
    members = data.members.duplicate(true)
    authority.clear()
    for actor in members: members[actor].erase("area")
    return true

## Builds the indexes again from `records`; for code that sets records directly.
func reindex() -> void:
    claims_by_actor.clear(); wild_by_area.clear(); _namespace_max = 0; _namespace_stale = false
    for key in records: _index(key, null, records[key])

func _index(key: String, old: Variant, now: Variant) -> void:
    if key.begins_with("wild_claim/"):
        if old is Dictionary: _unlist(claims_by_actor, String(old.get("actor", "")), key)
        if now is Dictionary: _list(claims_by_actor, String(now.get("actor", "")), key)
    elif key.begins_with("wild_namespace/"):
        if now != null and int(now) >= _namespace_max: _namespace_max = int(now)
        elif old != null and int(old) >= _namespace_max: _namespace_stale = true
    elif key.begins_with("world/") and key.get_slice("/", 2) == "wild_pokemon":
        if old == null and now != null: _list(wild_by_area, key.get_slice("/", 1), key)
        elif old != null and now == null: _unlist(wild_by_area, key.get_slice("/", 1), key)

static func _list(index: Dictionary, group: String, key: String) -> void:
    if not index.has(group): index[group] = {}
    index[group][key] = true

static func _unlist(index: Dictionary, group: String, key: String) -> void:
    var keys: Dictionary = index.get(group, {})
    keys.erase(key)
    if keys.is_empty(): index.erase(group)

## The highest wild namespace handed out so far; 0 when none.
func namespace_max() -> int:
    if _namespace_stale:
        _namespace_stale = false; _namespace_max = 0
        for key in records:
            if String(key).begins_with("wild_namespace/"): _namespace_max = maxi(_namespace_max, int(records[key]))
    return _namespace_max
