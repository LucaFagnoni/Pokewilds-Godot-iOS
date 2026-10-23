extends RefCounted
## The population's frame by the engine's own module (engine_modules/pokewilds,
## class PokeWildsPopulationSim): WildPopulation.tick and slots_in,
## HabitatPopulation.tick and the ecology pass of rules/population_rules.gd
## (run_ecology_step), the same steps with the same random numbers in the same
## order as their GDScript, in a fraction of the time (an ecology pass is
## 15-35 ms of GDScript on a desktop with a thousand wild Pokemon and fifty
## habitats). Engines without the module (the official editor and templates)
## run the GDScript.
##
## POKEWILDS_NATIVE_POPULATION=0 runs the GDScript; =1 makes a missing native
## class an error (CI checks the native one with it).
## .github/engine/native_population_test.gd checks one against the other.

const CLASS := "PokeWildsPopulationSim"

## False: the GDScript runs whatever the engine has (the parity test turns
## it off and on).
static var enabled := OS.get_environment("POKEWILDS_NATIVE_POPULATION") != "0"
static var _sim: Object = null
static var _made := false

## The native simulation, or null when the GDScript runs. Made on the game
## thread (a worker asking first gets the GDScript).
static func sim() -> Object:
    if not enabled:
        return null
    if not _made:
        if OS.get_thread_caller_id() != OS.get_main_thread_id():
            return null
        _made = true
        if ClassDB.class_exists(CLASS):
            var made: Object = ClassDB.instantiate(CLASS)
            made.call("configure", {"wild": load("res://scripts/wild_population.gd"),
                "rules": load("res://scripts/rules/population_rules.gd"), "ecology": load("res://scripts/pokemon_ecology.gd"),
                "data": load("res://scripts/pokemon_data.gd"), "mew": load("res://scripts/rare_forest_mew.gd"),
                "legendaries": load("res://scripts/rare_biome_legendaries.gd"), "store": load("res://scripts/world_tile_store.gd")})
            if made.call("is_configured"):
                _sim = made
            else:
                push_error("%s could not read the population's scripts: the GDScript runs" % CLASS)
        elif OS.get_environment("POKEWILDS_NATIVE_POPULATION") == "1":
            push_error("POKEWILDS_NATIVE_POPULATION=1, but this engine has no %s" % CLASS)
    return _sim
