extends RefCounted
## The host explicitly supplies their ZeroTier managed IPv4; never guess a VPN.
const Code=preload("res://scripts/coop_join_code.gd")
const Paths=preload("res://scripts/game_data_paths.gd")
static func address()->String:
    var config=ConfigFile.new()
    if config.load(Paths.path("zerotier.cfg"))!=OK:return ""
    return String(config.get_value("network","address",""))
static func valid_address(value:String)->bool:
    var code=Code.encode(value)
    return not code.is_empty() and not value.begins_with("127.") and not value.begins_with("169.254.") and not value.begins_with("0.")
static func available(value:String)->bool:
    return valid_address(value) and value in IP.get_local_addresses()
static func code()->String:
    var value=address()
    return Code.encode_internet(value) if available(value) else "SETUP"
static func save_address(value:String)->Error:
    if not available(value):return ERR_INVALID_PARAMETER
    var config=ConfigFile.new();config.set_value("network","address",value)
    return config.save(Paths.path("zerotier.cfg"))
