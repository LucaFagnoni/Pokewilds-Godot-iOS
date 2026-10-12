extends RefCounted

# Independent lifetime collection ledger. Never derive caught history from the
# current party: releases and evolution must not erase earlier registrations.
var entries: Dictionary = {}
var shiny_entries: Dictionary = {}

static func key(record: Dictionary) -> String:
    var species := PokemonData.canonical_species(String(record.get("species", "")))
    if species == "unown": species = "unown_a"
    return species + (":mega" if species == "gengar" and String(record.get("form", "")) == "mega" else "")

func mark(record: Dictionary, caught: bool = false) -> void:
    if record.is_empty() or bool(record.get("is_egg", false)) or bool(record.get("is_ghost", false)):
        return
    var id := key(record)
    if id.is_empty() or PokemonData.info(String(record.get("species", ""))).is_empty(): return
    if PokemonData.is_shiny(record):shiny_entries[id] = true
    entries[id] = maxi(int(entries.get(id, 0)), 2 if caught else 1)

func restore(raw: Variant) -> void:
    entries.clear()
    shiny_entries.clear()
    if raw is Dictionary:
        for id in raw:
            var state := clampi(int(raw[id]), 0, 2)
            if state > 0: entries[String(id)] = state

func seed_owned(raw: Variant) -> void:
    # Used only on known owned collections, never on wild world records.
    if raw is Array:
        for value in raw: seed_owned(value)
    elif raw is Dictionary:
        if raw.has("species"): mark(raw, true)
        else:
            for value in raw.values(): seed_owned(value)

func restore_shiny(raw: Variant) -> void:
    shiny_entries.clear()
    if raw is Dictionary:
        for id in raw:
            if bool(raw[id]) and int(entries.get(id,0))>0:shiny_entries[String(id)]=true
