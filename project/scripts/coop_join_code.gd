extends RefCounted
## Direct IPv4 endpoint, fixed mod port; no registry or relay.
const PORT := 54555
# Separate code namespace; both types still decode to a direct IPv4 endpoint.
const INTERNET_TAG: int = 0x100000000
const ALPHABET := "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"

static func local_endpoints() -> Array[Dictionary]:
    var result: Array[Dictionary] = []
    var seen := {}
    for interface in IP.get_local_interfaces():
        for address in interface.get("addresses", []):
            var text := String(address)
            if text.begins_with("127.") or text.begins_with("169.254."): continue
            var code := encode(text)
            if code.is_empty() or seen.has(text): continue
            seen[text] = true
            result.append({"address":text,"code":code,
                "interface":String(interface.get("friendly", interface.get("name", "NETWORK")))})
    return result

static func encode_internet(address: String) -> String:
    return encode(address, true)

static func encode(address: String, internet: bool = false) -> String:
    var octets := address.split(".")
    if octets.size() != 4: return ""
    var value: int = 0
    for octet in octets:
        if octet.is_empty() or not octet.is_valid_int(): return ""
        var number := int(octet)
        if number < 0 or number > 255 or str(number) != octet: return ""
        value = (value << 8) | number
    if value == 0 or value >= 0xe0000000: return ""
    if internet: value += INTERNET_TAG
    var result := ""
    for digit in range(7):
        result = ALPHABET[value % 36] + result
        value = int(value / 36)
    return result + _check(result)

static func decode(code: String) -> String:
    code = code.strip_edges().to_upper()
    if code.length() != 8 or code[7] != _check(code.substr(0, 7)): return ""
    var value: int = 0
    for index in range(7):
        var digit := ALPHABET.find(code[index])
        if digit < 0: return ""
        value = value * 36 + digit
    if value >= INTERNET_TAG: value -= INTERNET_TAG
    if value <= 0 or value >= 0xe0000000: return ""
    return "%d.%d.%d.%d" % [(value >> 24) & 255, (value >> 16) & 255,
        (value >> 8) & 255, value & 255]

static func _check(text: String) -> String:
    var sum: int = 0
    for index in range(text.length()):
        var digit := ALPHABET.find(text[index])
        if digit < 0: return "?"
        sum = (sum * 17 + digit) % 36
    return ALPHABET[sum]
