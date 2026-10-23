#pragma once

#include "core/math/random_number_generator.h"
#include "core/object/ref_counted.h"
#include "core/object/script_language.h"
#include "core/templates/hash_map.h"
#include "core/templates/local_vector.h"
#include "core/variant/typed_array.h"

// Native port of the population's frame: WildPopulation.tick and its zone
// query (project/scripts/wild_population.gd), HabitatPopulation.tick
// (habitat_population.gd) and the ecology pass of rules/population_rules.gd
// (run_ecology_step, refresh_relationships, the habitat windows), with the
// rules they use (where a Pokemon may step, its wait, its mate's cell).
// Bit-identical to the GDScript: the same fields read and written in the
// same order, the same random numbers drawn in the same order, the World's,
// the view's and the co-op coordinator's methods called where the GDScript
// calls them, and the rare branches (an egg laid, a Pokemon moved or
// removed, an encounter begun) left to the GDScript itself. The state stays
// in the GDScript objects: this reads and writes theirs. Scripts reach it
// only through ClassDB ("PokeWildsPopulationSim",
// project/scripts/native_population.gd); engines without it run the
// GDScript, which stays the reference (.github/engine/native_population_test.gd).
class PokeWildsPopulationSim : public RefCounted {
	GDCLASS(PokeWildsPopulationSim, RefCounted);

public:
	struct Species;
	struct Names;
	struct Pass;
	struct Ctx;

private:
	// The GDScript classes the rules live in (constants, static calls).
	Ref<Script> wild_script;
	Ref<Script> rules_script;
	Ref<Script> ecology_script;
	Ref<Script> data_script;
	Ref<Script> mew_script;
	Ref<Script> legendaries_script;
	Ref<Script> store_script;
	bool configured = false;

	// Their constants, read once (configure).
	int bucket_shift = 4;
	int burrowed_flag = 1;
	int active_radius = 24;
	int habitat_radius = 3;
	int flee_range_tiles = 28;
	int flee_look_ahead = 14;
	int flee_search_tiles = 180;
	int flee_replan_steps = 5;
	int ecology_active_radius = 24;
	int mate_bond_radius = 6;
	int tile_size = 16;
	double habitat_check_seconds = 96.0 / 60.0;
	double lay_egg_seconds = 7200.0 / 60.0;
	double friend_seconds = 960.0 / 60.0;
	double wild_move_min = 1.0;
	double wild_move_max = 4.0;
	double day_seconds = (18000.0 + 5000.0) / 60.0;
	double night_start = 18000.0 / (18000.0 + 5000.0);
	int store_present = 1;
	int store_solid = 4;
	int store_ledge = 8;
	int store_water = 16;
	int store_grass = 32;
	int store_tidal = 256;
	Vector2i directions[5];
	Array ecology_fields;
	LocalVector<Variant> ecology_keys;

	// PokemonData.info and what PokemonEcology makes of it, by species name
	// as asked (the species data is loaded once per run).
	HashMap<String, Species *> species;
	// The habitat options and the bits of names' pieces, kept between passes.
	Names *names = nullptr;

	Species *species_of(const String &p_name);

protected:
	static void _bind_methods();

public:
	// `scripts`: {"wild", "rules", "ecology", "data", "mew", "legendaries", "store"}.
	void configure(const Dictionary &p_scripts);
	bool is_configured() const { return configured; }

	// WildPopulation.slots_in(squares).
	PackedInt32Array slots_in(Object *p_population, const Array &p_squares);
	// WildPopulation.tick(delta, observers, rng).
	PackedInt64Array wild_tick(Object *p_population, double p_delta, const Array &p_observers, const Ref<RandomNumberGenerator> &p_rng);
	// HabitatPopulation.tick(delta, rng).
	void habitat_tick(Object *p_population, double p_delta, const Ref<RandomNumberGenerator> &p_rng);
	// PopulationRules.run_ecology_step's pass once its clock ran out
	// (`ecology_delta`). False when it did nothing (a habitat it cannot read
	// as bits): the GDScript runs it then.
	bool ecology_pass(Object *p_state, double p_ecology_delta, const Array &p_centers, const Callable &p_simulated, bool p_with_wild,
			const Dictionary &p_house_cells, const Callable &p_may_release);

	// Single rules, for the parity test against their GDScript twins.
	bool can_move_between(Object *p_state, const String &p_species, const Vector2i &p_origin, const Vector2i &p_target);
	Dictionary refresh_record_habitat(Object *p_state, const Dictionary &p_data, const Vector2i &p_cell, const Dictionary &p_house_cells);
	bool can_mate(const Dictionary &p_first, const Dictionary &p_second);
	bool can_be_friends(const Dictionary &p_first, const Dictionary &p_second);

	PokeWildsPopulationSim();
	~PokeWildsPopulationSim();
};
