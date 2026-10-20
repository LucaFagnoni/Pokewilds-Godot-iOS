extends RefCounted
## Player accounts of a dedicated server: an ID and a password. The server only
## keeps a salted hash: verifier = sha256(salt | sha256(id | password)). A login
## proves the verifier against a one-time value the server sends, so after an ID
## exists neither the password nor its verifier crosses the network again. The
## verifier itself travels once, when a first login creates the ID.
## Each account has the actor (the key of its character in the world) it got
## when it was made, so the same ID on any device plays the same character.
const ID_CHARS := "abcdefghijklmnopqrstuvwxyz0123456789_-"
var path := ""
## True: the first login with a new ID creates it. False: only IDs the admin
## made with `account add` can log in.
var open := true
var records: Dictionary = {}

static func valid_id(id: String) -> bool:
    if id.length() < 3 or id.length() > 16: return false
    for character in id:
        if not character in ID_CHARS: return false
    return true

static func secret(id: String, password: String) -> String:
    return ("pokewilds-account|" + id.to_lower() + "|" + password).sha256_text()

static func verifier(salt: String, id: String, password: String) -> String:
    return (salt + "|" + secret(id, password)).sha256_text()

## The character an ID plays when nothing else gave it one.
static func own_actor(id: String) -> String:
    return ("pokewilds-account-actor|" + id.to_lower()).sha256_text()

func load_file(file: String) -> Error:
    path = file
    records = {}
    if not FileAccess.file_exists(path): return OK
    var data = JSON.parse_string(FileAccess.get_file_as_string(path))
    if not data is Dictionary or not data.get("accounts") is Dictionary: return ERR_FILE_CORRUPT
    records = data.accounts
    return OK

func save() -> Error:
    var file := FileAccess.open(path + ".pending", FileAccess.WRITE)
    if file == null: return FileAccess.get_open_error()
    file.store_string(JSON.stringify({"format": 1, "accounts": records}, "  "))
    file.close()
    return DirAccess.rename_absolute(path + ".pending", path)

func exists(id: String) -> bool:
    return records.has(id.to_lower())

func salt(id: String) -> String:
    return String(records.get(id.to_lower(), {}).get("salt", ""))

func actor(id: String) -> String:
    return String(records.get(id.to_lower(), {}).get("actor", ""))

## `proof` = sha256(nonce | verifier), from the player's password.
func check(id: String, nonce: String, proof: String) -> bool:
    var record: Dictionary = records.get(id.to_lower(), {})
    return not record.is_empty() and not nonce.is_empty() and proof == (nonce + "|" + String(record.verifier)).sha256_text()

func owns_actor(value: String) -> bool:
    for record in records.values():
        if record.get("actor") == value: return true
    return false

## Creates an ID from a first login. `device_actor` is the character this
## device already played here before IDs existed: the new ID keeps it.
func register(id: String, account_salt: String, account_verifier: String, device_actor: String, has_character: Callable) -> String:
    var value := own_actor(id)
    if not device_actor.is_empty() and not owns_actor(device_actor) and has_character.is_valid() and has_character.call(device_actor): value = device_actor
    records[id.to_lower()] = {"id": id, "salt": account_salt, "verifier": account_verifier, "actor": value, "created": Time.get_datetime_string_from_system()}
    if save() != OK:
        records.erase(id.to_lower())
        return ""
    return value

## Admin side: make an ID or give one a new password.
func set_password(id: String, password: String) -> Error:
    var record: Dictionary = records.get(id.to_lower(), {"id": id, "actor": own_actor(id), "created": Time.get_datetime_string_from_system()})
    record["salt"] = preload("res://scripts/coop_random.gd").hex(16)
    record["verifier"] = verifier(record.salt, id, password)
    records[id.to_lower()] = record
    return save()

func remove(id: String) -> Error:
    if not records.erase(id.to_lower()): return ERR_DOES_NOT_EXIST
    return save()
