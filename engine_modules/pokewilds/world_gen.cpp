#include "world_gen.h"

#include "island.h"

#include "core/object/class_db.h"

Dictionary PokeWildsWorldGen::generate(int64_t p_seed, int p_size_index, const TypedArray<String> &p_used_dungeons, Object *p_data, bool p_qa) {
	return pw::generate_world(p_seed, p_size_index, p_used_dungeons, p_data, p_qa);
}

PackedInt64Array PokeWildsWorldGen::java_random_ints(int64_t p_seed, const PackedInt64Array &p_bounds) {
	pw::JavaRandom random(p_seed);
	PackedInt64Array result;
	for (int64_t bound : p_bounds) {
		result.push_back(random.next_int(bound));
	}
	return result;
}

PackedVector2Array PokeWildsWorldGen::libgdx_rotate(const PackedVector2Array &p_vectors, const PackedFloat64Array &p_degrees) {
	ERR_FAIL_COND_V(p_vectors.size() != p_degrees.size(), PackedVector2Array());
	PackedVector2Array result;
	for (int index = 0; index < p_vectors.size(); index++) {
		result.push_back(pw::rotate_deg(p_vectors[index], p_degrees[index]));
	}
	return result;
}

PackedFloat64Array PokeWildsWorldGen::libgdx_distance(const PackedVector2Array &p_from, const PackedVector2Array &p_to) {
	ERR_FAIL_COND_V(p_from.size() != p_to.size(), PackedFloat64Array());
	PackedFloat64Array result;
	for (int index = 0; index < p_from.size(); index++) {
		result.push_back(pw::gdx_distance(p_from[index], p_to[index]));
	}
	return result;
}

Array PokeWildsWorldGen::java_evolution_order(const Array &p_evolutions) {
	return pw::java_evolution_order(p_evolutions);
}

void PokeWildsWorldGen::_bind_methods() {
	ClassDB::bind_method(D_METHOD("generate", "seed", "size_index", "used_dungeons", "data", "qa"), &PokeWildsWorldGen::generate, DEFVAL(false));
	ClassDB::bind_method(D_METHOD("java_random_ints", "seed", "bounds"), &PokeWildsWorldGen::java_random_ints);
	ClassDB::bind_method(D_METHOD("libgdx_rotate", "vectors", "degrees"), &PokeWildsWorldGen::libgdx_rotate);
	ClassDB::bind_method(D_METHOD("libgdx_distance", "from", "to"), &PokeWildsWorldGen::libgdx_distance);
	ClassDB::bind_method(D_METHOD("java_evolution_order", "evolutions"), &PokeWildsWorldGen::java_evolution_order);
}
