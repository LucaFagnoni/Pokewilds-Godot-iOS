#include "register_types.h"

#include "population_sim.h"
#include "world_gen.h"

#include "core/object/class_db.h"

void initialize_pokewilds_module(ModuleInitializationLevel p_level) {
	if (p_level == MODULE_INITIALIZATION_LEVEL_SCENE) {
		GDREGISTER_CLASS(PokeWildsWorldGen);
		GDREGISTER_CLASS(PokeWildsPopulationSim);
	}
}

void uninitialize_pokewilds_module(ModuleInitializationLevel p_level) {
}
