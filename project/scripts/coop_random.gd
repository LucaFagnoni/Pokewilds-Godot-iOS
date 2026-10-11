extends RefCounted
## One shared random source for ONLINE ids. Godot 4.7 on Android leaks a
## /dev/urandom handle every time a new Crypto object seeds itself, so creating
## one per id (several a second while hosting) exhausts the process's files.
static var _crypto:Crypto

static func bytes(count:int)->PackedByteArray:
    if _crypto==null:_crypto=Crypto.new()
    return _crypto.generate_random_bytes(count)

static func hex(count:int)->String:
    return bytes(count).hex_encode()
