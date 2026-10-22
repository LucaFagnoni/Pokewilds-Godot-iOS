#pragma once

#include "core/object/ref_counted.h"
#include "core/variant/typed_array.h"

// Native port of SourceWorldGenerator.generate_validated plus the adapter's
// repairs (project/scripts/source_*.gd), bit-identical to them. Scripts
// reach it only through ClassDB ("PokeWildsWorldGen"): official engines lack
// it and the game falls back to the GDScript generator, which stays the
// reference (project/scripts/native_world_gen.gd).
class PokeWildsWorldGen : public RefCounted {
	GDCLASS(PokeWildsWorldGen, RefCounted);

protected:
	static void _bind_methods();

public:
	// `data` answers traits/species/allowed_pokemon/is_dungeon/layout/constants
	// from the GDScript tables. `qa` adds the per-stage hashes ("native_qa").
	Dictionary generate(int64_t p_seed, int p_size_index, const TypedArray<String> &p_used_dungeons, Object *p_data, bool p_qa = false);

	// The primitives, for tests against their GDScript twins.
	PackedInt64Array java_random_ints(int64_t p_seed, const PackedInt64Array &p_bounds);
	PackedVector2Array libgdx_rotate(const PackedVector2Array &p_vectors, const PackedFloat64Array &p_degrees);
	PackedFloat64Array libgdx_distance(const PackedVector2Array &p_from, const PackedVector2Array &p_to);
	Array java_evolution_order(const Array &p_evolutions);
};
