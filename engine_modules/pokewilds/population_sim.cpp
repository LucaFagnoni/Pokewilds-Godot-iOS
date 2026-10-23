#include "population_sim.h"

#include "core/object/class_db.h"
#include "core/os/os.h"
#include "core/templates/hash_set.h"
#include "core/templates/local_vector.h"
#include "core/variant/variant_utility.h"

#include <cstring>

// Each function below is the GDScript one of the same name, in its order;
// the comments name it. Constants come from the scripts (configure); the
// numbers written in the GDScript's bodies are written here the same.

namespace {

const Vector2i NO_CELL(INT32_MIN, INT32_MIN);
const Vector2i DOWN(0, 1);
const Vector2i UP(0, -1);

// A record's field as a Dictionary key, made once (no StringName copied for
// each lookup); a property or method name.
#define K(m_name) ([]() -> const Variant & { static const Variant key = StringName(#m_name, true); return key; })()
#define S(m_name) SNAME(#m_name)

_FORCE_INLINE_ bool get_bool(const Dictionary &p_dict, const Variant &p_key) {
	const Variant *value = p_dict.getptr(p_key);
	return value && value->booleanize();
}

_FORCE_INLINE_ double get_float(const Dictionary &p_dict, const Variant &p_key, double p_default) {
	const Variant *value = p_dict.getptr(p_key);
	return value ? double(*value) : p_default;
}

_FORCE_INLINE_ int64_t get_int(const Dictionary &p_dict, const Variant &p_key, int64_t p_default) {
	const Variant *value = p_dict.getptr(p_key);
	return value ? int64_t(*value) : p_default;
}

_FORCE_INLINE_ String get_string(const Dictionary &p_dict, const Variant &p_key) {
	const Variant *value = p_dict.getptr(p_key);
	return value ? String(*value) : String();
}

_FORCE_INLINE_ Dictionary get_dict(const Dictionary &p_dict, const Variant &p_key) {
	const Variant *value = p_dict.getptr(p_key);
	return value ? Dictionary(*value) : Dictionary();
}

_FORCE_INLINE_ Vector2i get_cell(const Dictionary &p_dict, const Variant &p_key) {
	const Variant *value = p_dict.getptr(p_key);
	return value ? Vector2i(*value) : Vector2i();
}

// data[key] = value: a new key as a String, as GDScript writes it.
_FORCE_INLINE_ void put(Dictionary &p_dict, const Variant &p_key, const Variant &p_value) {
	Variant *value = p_dict.getptr(p_key);
	if (value) {
		*value = p_value;
	} else {
		p_dict[String(p_key)] = p_value;
	}
}

_FORCE_INLINE_ Variant named(const Variant &p_value, const StringName &p_key) {
	bool valid = false;
	return p_value.get_named(p_key, valid);
}

_FORCE_INLINE_ bool is_null(const Variant &p_value) {
	return p_value.get_type() == Variant::NIL || (p_value.get_type() == Variant::OBJECT && p_value.get_validated_object() == nullptr);
}

_FORCE_INLINE_ Object *object_of(const Variant &p_value) {
	return p_value.get_type() == Variant::OBJECT ? p_value.get_validated_object() : nullptr;
}

bool equal(const Variant &p_a, const Variant &p_b) {
	bool valid = false;
	Variant result;
	Variant::evaluate(Variant::OP_EQUAL, p_a, p_b, result, valid);
	return valid && result.booleanize();
}

_FORCE_INLINE_ int64_t absi64(int64_t p_value) {
	return p_value < 0 ? -p_value : p_value;
}

_FORCE_INLINE_ int64_t chebyshev(const Vector2i &p_a, const Vector2i &p_b) {
	return MAX(absi64(int64_t(p_a.x) - p_b.x), absi64(int64_t(p_a.y) - p_b.y));
}

// PopulationRules.cardinal_direction.
Vector2i cardinal_direction(const Vector2i &p_delta, bool p_away) {
	Vector2i direction;
	if (absi64(p_delta.x) >= absi64(p_delta.y)) {
		direction = Vector2i(SIGN(p_delta.x), 0);
	} else {
		direction = Vector2i(0, SIGN(p_delta.y));
	}
	return p_away ? -direction : direction;
}

// PokemonEcology.normalize_species.
String normalize_species(const String &p_species) {
	return p_species.to_lower().strip_edges().replace(" ", "_");
}

// PokemonEcology._string_array.
Vector<String> string_array(const Variant &p_values) {
	Vector<String> result;
	if (p_values.get_type() != Variant::ARRAY) {
		return result;
	}
	Array values = p_values;
	for (int index = 0; index < values.size(); index++) {
		result.push_back(String(values[index]).to_upper());
	}
	return result;
}

// PokemonEcology.share_egg_group.
bool share_egg_group(const Vector<String> &p_first, const Vector<String> &p_second) {
	if (p_first.has("EGG_NONE") || p_second.has("EGG_NONE")) {
		return false;
	}
	if (p_first.has("EGG_DITTO") || p_second.has("EGG_DITTO")) {
		return true;
	}
	for (const String &group : p_first) {
		if (p_second.has(group)) {
			return true;
		}
	}
	return false;
}

// PopulationRules.tile_key.
String tile_key(const String &p_value) {
	String key = p_value.to_lower().strip_edges();
	if (key.ends_with(".png")) {
		key = key.trim_suffix(".png");
	}
	return key;
}

// SourceWorldData.is_water.
bool asset_is_water(const String &p_name) {
	String key = p_name.get_file().get_basename().strip_edges().to_lower();
	return (key.begins_with("water") && !key.begins_with("waterfall")) || key.contains("_water");
}

constexpr uint64_t FENCE_BIT = 1;
constexpr uint64_t ROOF_BIT = 2;
constexpr int FIRST_OPTION_BIT = 2;
constexpr int MAX_OPTIONS = 62;

// A tile as the rules read it: a packed cell of the store, or a SourceTile.
struct TileRef {
	int index = -1;
	Object *object = nullptr;
	bool exists() const { return index >= 0 || object != nullptr; }
};

// A record the ecology pass covers (refresh_relationships' descriptor),
// with what can_mate reads of it, worked out once (none of it changes
// during the pass).
struct Rec {
	bool deployed = false;
	Vector2i cell;
	Dictionary data;
	PokeWildsPopulationSim::Species *habitat = nullptr;
	// Its ecology id, and its mate, friend and former mate as the pass has
	// written them (only the pass writes them while it runs).
	String ecology_id;
	String mate_id;
	String friend_id;
	String previous_mate_id;
	bool facts_known = false;
	bool is_egg = false;
	String species;
	Vector<String> groups;
	String gender;
};

// A piece of a cell's names: its bits for the first `known` options.
struct PieceBits {
	uint64_t bits = 0;
	int known = 0;
};

// A tile's base and upper names: their piece, its bits, and grass1.
struct PairInfo {
	String own;
	PieceBits piece;
	bool grass = false;
};

// The window cells' bits of a pass, 8x8 cells a chunk.
struct CellChunk {
	uint64_t known = 0;
	uint64_t bits[64];
};

} // namespace

struct PokeWildsPopulationSim::Species {
	Dictionary info;
	Dictionary behavior;
	String normalized;
	bool habitat_known = false;
	Vector<String> group_names;
	Vector<Vector<String>> group_options;
	bool requires_night = false;
	bool harvest_known = false;
	double harvest_seconds = 0.0;
	Array harvest_items;
};

// The habitat windows of one ecology pass as bits: one per habitat option
// of the species covered, and "fence" and "roof". No option holds a space,
// so an option is in a cell's names (and in the window's, the names joined
// by spaces) exactly when it is in one of the space-separated pieces they
// are made of: each piece's bits are worked out once and or-ed.
// The habitat options seen so far (only ever added to) and the bits of the
// pieces of names and of the tiles' name pairs, kept from pass to pass
// (whether an option is in a string never changes; a string's bits are
// brought up to the options added since it was last asked).
struct PokeWildsPopulationSim::Names {
	Vector<String> options;
	HashMap<String, int> option_index;
	HashMap<String, PieceBits> pieces;
	HashMap<int64_t, PairInfo> pairs;
	ObjectID store;
};

struct PokeWildsPopulationSim::Pass {
	HashMap<Vector2i, uint32_t> chunk_index;
	LocalVector<CellChunk> chunks;
	HashMap<int64_t, String> biomes;
	uint64_t grass_bits = 0;
};

// One call's view of an area (AreaState) and its populations. Packed arrays
// are held while the call runs and given back around each GDScript call that
// may write them (sync_call), so neither side copies them.
struct PokeWildsPopulationSim::Ctx {
	PokeWildsPopulationSim *sim = nullptr;
	Object *state = nullptr;
	Object *tiles = nullptr;
	Object *store = nullptr;
	bool packed = false;
	Dictionary dict_store;
	bool has_dict_store = false;
	Vector2i origin;
	int width = 0;
	int height = 0;
	PackedInt32Array s_flags, s_name_ids, s_upper_ids, s_biome_ids, s_route_ids, s_ledge_dir_ids;
	PackedStringArray s_strings;
	Dictionary s_extra, s_string_ids;
	Dictionary structures, blocked, flowers, landmarks, terrain_changes, memo;
	Callable walkable;
	Object *view = nullptr;
	Rect2i bounds;
	Ref<RandomNumberGenerator> rng;

	// state.wild (or the population ticked), state.habitat, state.eggs.
	Object *wild = nullptr;
	Object *habitat = nullptr;
	Object *eggs = nullptr;
	Dictionary w_records, w_slot_of, w_at_cell, w_buckets;
	PackedInt64Array w_ids;
	PackedInt32Array w_cell_x, w_cell_y, w_flags;
	int64_t w_live = 0;
	// The ticked population's timers: held here, its member empty, while it ticks.
	bool timers_held = false;
	PackedFloat64Array w_timers;
	Dictionary h_records, h_cover;
	int64_t h_covered = 0;
	Dictionary e_records;

	// A wild tick's: the population, its World and co-op coordinator, its RNG.
	Object *population = nullptr;
	Object *world = nullptr;
	Object *players = nullptr;
	bool online = false;
	Ref<RandomNumberGenerator> tick_rng;
	Dictionary flee_routes, flee_started;

	// An ecology pass's.
	Pass *pass = nullptr;
	Dictionary house_cells;
	HashMap<Vector2i, Variant> ice;
	bool ice_scanned = false;
	// placed_bits by cell, made once a pass from flowers, structures and
	// landmarks when they hold few cells (else each cell asks them).
	HashMap<Vector2i, uint64_t> placed;
	int placed_state = 0;
	bool memo_ready = false;

	void load(Object *p_state) {
		state = p_state;
		structures = state->get(S(structures));
		blocked = state->get(S(blocked));
		flowers = state->get(S(flowers));
		landmarks = state->get(S(landmarks));
		terrain_changes = state->get(S(terrain_changes));
		memo = state->get(S(memo));
		walkable = state->get(S(walkable));
		view = object_of(state->get(S(view)));
		bounds = state->get(S(bounds));
		rng = state->get(S(rng));
		wild = object_of(state->get(S(wild)));
		habitat = object_of(state->get(S(habitat)));
		eggs = object_of(state->get(S(eggs)));
		reacquire();
	}

	void load_tiles() {
		tiles = object_of(state->get(S(tiles)));
		store = nullptr;
		packed = false;
		has_dict_store = false;
		if (!tiles) {
			return;
		}
		Variant raw = tiles->get(S(tiles));
		if (raw.get_type() == Variant::DICTIONARY) {
			dict_store = raw;
			has_dict_store = true;
			return;
		}
		store = object_of(raw);
		if (!store || Ref<Script>(store->get_script()) != sim->store_script) {
			store = nullptr;
			return;
		}
		packed = true;
		origin = store->get(S(origin));
		width = store->get(S(width));
		height = store->get(S(height));
		s_flags = store->get(S(flags));
		s_name_ids = store->get(S(name_ids));
		s_upper_ids = store->get(S(upper_ids));
		s_biome_ids = store->get(S(biome_ids));
		s_route_ids = store->get(S(route_ids));
		s_ledge_dir_ids = store->get(S(ledge_dir_ids));
		s_strings = store->get(S(strings));
		s_extra = store->get(S(extra));
		s_string_ids = store->get(S(string_ids));
	}

	void load_wild() {
		if (!wild) {
			return;
		}
		w_records = wild->get(S(records));
		w_slot_of = wild->get(S(slot_of));
		w_at_cell = wild->get(S(at_cell));
		w_buckets = wild->get(S(buckets));
		w_ids = wild->get(S(ids));
		w_cell_x = wild->get(S(cell_x));
		w_cell_y = wild->get(S(cell_y));
		w_flags = wild->get(S(flags));
		w_live = wild->get(S(live));
		if (timers_held) {
			w_timers = wild->get(S(timers));
			wild->set(S(timers), PackedFloat64Array());
		}
	}

	void load_habitat() {
		if (habitat) {
			h_records = habitat->get(S(records));
			h_cover = habitat->get(S(_cover));
			h_covered = habitat->get(S(_covered));
		}
		e_records = eggs ? Dictionary(eggs->get(S(records))) : Dictionary();
	}

	// Before a GDScript call that may write what is held: it goes back, so
	// the GDScript writes its own arrays.
	void release() {
		if (timers_held && wild) {
			wild->set(S(timers), w_timers);
		}
		w_timers = PackedFloat64Array();
		w_ids = PackedInt64Array();
		w_cell_x = PackedInt32Array();
		w_cell_y = PackedInt32Array();
		w_flags = PackedInt32Array();
		s_flags = PackedInt32Array();
		s_name_ids = PackedInt32Array();
		s_upper_ids = PackedInt32Array();
		s_biome_ids = PackedInt32Array();
		s_route_ids = PackedInt32Array();
		s_ledge_dir_ids = PackedInt32Array();
		s_strings = PackedStringArray();
	}

	void reacquire() {
		// A zone query alone (slots_in) has a population and no area.
		if (state) {
			load_tiles();
		}
		load_wild();
		load_habitat();
	}

	// A GDScript call that may change what is held.
	template <typename... VarArgs>
	Variant sync_call(Object *p_object, const StringName &p_method, VarArgs... p_args) {
		release();
		Variant result = p_object->call(p_method, p_args...);
		reacquire();
		return result;
	}

	// --- Wild population -----------------------------------------------------

	// WildPopulation.sync().
	void wild_sync() {
		if (wild && w_records.size() != w_live) {
			sync_call(wild, S(sync));
		}
	}

	_FORCE_INLINE_ int slot_of(int64_t p_id) const {
		const Variant *slot = w_slot_of.getptr(p_id);
		return slot ? int(*slot) : -1;
	}

	// WildPopulation.id_at(cell, ignored).
	int64_t id_at(const Vector2i &p_cell, int64_t p_ignored = -1) {
		wild_sync();
		const Variant *at = w_at_cell.getptr(p_cell);
		if (!at || at->get_type() == Variant::NIL) {
			return -1;
		}
		if (at->get_type() == Variant::INT) {
			const int64_t id = w_ids[int(*at)];
			return id == p_ignored ? -1 : id;
		}
		Array slots = *at;
		for (int index = 0; index < slots.size(); index++) {
			const int64_t id = w_ids[int(slots[index])];
			if (id != p_ignored) {
				return id;
			}
		}
		return -1;
	}

	// WildPopulation.slots_in(squares).
	PackedInt32Array slots_in(const LocalVector<Vector3i> &p_squares) {
		wild_sync();
		PackedInt32Array result;
		LocalVector<uint8_t> seen;
		seen.resize(w_ids.size());
		if (seen.size()) {
			memset(seen.ptr(), 0, seen.size());
		}
		const int shift = sim->bucket_shift;
		const int32_t *cell_x = w_cell_x.ptr();
		const int32_t *cell_y = w_cell_y.ptr();
		for (const Vector3i &square : p_squares) {
			const int64_t radius = square.z;
			const int64_t from_y = (int64_t(square.y) - radius) >> shift;
			const int64_t to_y = (int64_t(square.y) + radius) >> shift;
			const int64_t from_x = (int64_t(square.x) - radius) >> shift;
			const int64_t to_x = (int64_t(square.x) + radius) >> shift;
			for (int64_t by = from_y; by <= to_y; by++) {
				for (int64_t bx = from_x; bx <= to_x; bx++) {
					const Variant *bucket = w_buckets.getptr(Vector2i(int32_t(bx), int32_t(by)));
					if (!bucket || bucket->get_type() != Variant::ARRAY) {
						continue;
					}
					Array slots = *bucket;
					for (int index = 0; index < slots.size(); index++) {
						const int slot = slots[index];
						if (absi64(int64_t(cell_x[slot]) - square.x) <= radius && absi64(int64_t(cell_y[slot]) - square.y) <= radius && !seen[slot]) {
							seen[slot] = 1;
							result.push_back(slot);
						}
					}
				}
			}
		}
		result.sort();
		return result;
	}

	// HabitatPopulation.near(cell).
	bool habitat_near(const Vector2i &p_cell) {
		if (h_records.size() != h_covered) {
			sync_call(habitat, S(sync));
		}
		return h_cover.has(p_cell);
	}

	// --- Tiles ---------------------------------------------------------------

	// WorldTileStore.index_of(cell * TILE).
	_FORCE_INLINE_ int index_of(const Vector2i &p_cell) const {
		const Vector2i at = (p_cell * sim->tile_size) / sim->tile_size - origin;
		if (at.x < 0 || at.y < 0 || at.x >= width || at.y >= height) {
			return -1;
		}
		const int index = at.y * width + at.x;
		return (s_flags[index] & sim->store_present) ? index : -1;
	}

	// state.tiles.tile_at(cell).
	TileRef tile_at(const Vector2i &p_cell) const {
		TileRef tile;
		if (!tiles) {
			return tile;
		}
		const Vector2i key = p_cell * sim->tile_size;
		if (packed) {
			tile.index = index_of(p_cell);
			if (tile.index < 0) {
				tile.object = object_of(s_extra.get(key, Variant()));
			}
		} else if (has_dict_store) {
			tile.object = object_of(dict_store.get(key, Variant()));
		} else {
			tile.object = object_of(tiles->call(S(tile_at), p_cell));
		}
		return tile;
	}

	bool tile_flag(const TileRef &p_tile, int p_bit, const StringName &p_field) const {
		if (p_tile.index >= 0) {
			return s_flags[p_tile.index] & p_bit;
		}
		return p_tile.object->get(p_field).booleanize();
	}
	bool is_ledge(const TileRef &p_tile) const { return tile_flag(p_tile, sim->store_ledge, S(is_ledge)); }
	bool is_water(const TileRef &p_tile) const { return tile_flag(p_tile, sim->store_water, S(is_water)); }
	bool is_solid_flag(const TileRef &p_tile) const { return tile_flag(p_tile, sim->store_solid, S(is_solid)); }

	String tile_text(const TileRef &p_tile, const PackedInt32Array &p_ids, const StringName &p_field) const {
		if (p_tile.index >= 0) {
			return s_strings[p_ids[p_tile.index]];
		}
		return p_tile.object->get(p_field);
	}
	String tile_name(const TileRef &p_tile) const { return tile_text(p_tile, s_name_ids, S(name)); }
	String tile_upper(const TileRef &p_tile) const { return tile_text(p_tile, s_upper_ids, S(name_upper)); }
	String tile_biome(const TileRef &p_tile) const { return tile_text(p_tile, s_biome_ids, S(biome)); }
	String tile_ledge_dir(const TileRef &p_tile) const { return tile_text(p_tile, s_ledge_dir_ids, S(ledge_dir)); }

	// AreaState.in_bounds (state.tiles.contains_cell, or its bounds).
	bool in_bounds(const Vector2i &p_cell) const {
		if (!tiles) {
			return bounds.has_point(p_cell);
		}
		const Vector2i key = p_cell * sim->tile_size;
		if (packed) {
			return index_of(p_cell) >= 0 || s_extra.has(key);
		}
		if (has_dict_store) {
			return dict_store.has(key);
		}
		return tiles->call(S(contains_cell), p_cell).booleanize();
	}

	String structure_name(const Vector2i &p_cell) const {
		const Variant *structure = structures.getptr(p_cell);
		return structure ? get_string(Dictionary(*structure), K(name)) : String();
	}

	// PopulationRules.permitted_ledge_direction.
	Vector2i permitted_ledge_direction(const TileRef &p_tile) const {
		if (!p_tile.exists()) {
			return Vector2i();
		}
		if ((tile_name(p_tile) + " " + tile_upper(p_tile)).to_lower().contains("ledge_grass_down")) {
			return DOWN;
		}
		const String direction = tile_ledge_dir(p_tile);
		if (direction == "up") {
			return DOWN;
		}
		if (direction == "down") {
			return UP;
		}
		if (direction == "left") {
			return Vector2i(-1, 0);
		}
		if (direction == "right") {
			return Vector2i(1, 0);
		}
		return Vector2i();
	}

	// PopulationRules.in_water (names_at's base name).
	bool in_water(const Vector2i &p_cell) const {
		if (!tiles) {
			return false;
		}
		TileRef tile = tile_at(p_cell);
		if (!tile.exists()) {
			return false;
		}
		const String name = tile_name(tile);
		return name.contains("water") && !name.contains("_tidal");
	}

	// PopulationRules.terrain_kind_at.
	int terrain_kind_at(const Vector2i &p_cell) const {
		if (structure_name(p_cell) == "BRIDGE") {
			return 2;
		}
		TileRef tile = tile_at(p_cell);
		if (!tile.exists()) {
			return 0;
		}
		const String name = tile_name(tile);
		if (is_water(tile) || asset_is_water(name)) {
			return 0;
		}
		if (name.contains("sand") || name.contains("desert") || tile_biome(tile).contains("beach")) {
			return 1;
		}
		return 2;
	}

	// SourceExactWorldAdapter.is_solid: berry trees, the savanna tree's trunk
	// (its own cell asks the GDScript), then the tile's flag.
	bool tiles_is_solid(const Vector2i &p_cell) {
		if (!packed) {
			return tiles->call(S(is_solid), p_cell).booleanize();
		}
		const int own = index_of(p_cell);
		if (own >= 0 && s_upper_ids[own] != 0 && s_strings[s_upper_ids[own]].to_lower().begins_with("berrytree_")) {
			return true;
		}
		const Variant *savanna = s_string_ids.getptr(String("tree_savanna1"));
		if (savanna && int64_t(*savanna) >= 0) {
			const int savanna_id = *savanna;
			const int anchor = index_of(p_cell + Vector2i(0, -2));
			if (anchor >= 0 && s_upper_ids[anchor] == savanna_id) {
				return true;
			}
			if (own >= 0 && s_upper_ids[own] == savanna_id) {
				return tiles->call(S(is_solid), p_cell).booleanize();
			}
		}
		TileRef tile = tile_at(p_cell);
		return !tile.exists() || is_solid_flag(tile);
	}

	// PopulationRules.is_walkable.
	bool is_walkable(const Vector2i &p_cell) {
		if (structure_name(p_cell) == "BRIDGE") {
			return !blocked.has(p_cell);
		}
		return tiles && in_bounds(p_cell) && !tiles_is_solid(p_cell) && !blocked.has(p_cell);
	}

	// PopulationRules.walkable: the World's own, else is_walkable.
	bool walkable_at(const Vector2i &p_cell) {
		if (walkable.is_valid()) {
			return walkable.call(p_cell).booleanize();
		}
		return is_walkable(p_cell);
	}

	bool fenced(const Vector2i &p_cell) const {
		const Variant *structure = structures.getptr(p_cell);
		if (!structure) {
			return false;
		}
		Dictionary built = *structure;
		return get_string(built, K(name)) == "FENCE" || get_bool(built, K(gate));
	}

	bool swim_only(const String &p_species) {
		return get_bool(sim->species_of(p_species)->behavior, K(swim_only));
	}

	// PopulationRules.can_enter, but for the Alolan beach Pokemon
	// (can_move_between asks the GDScript for those).
	bool can_enter(const String &p_species, const Vector2i &p_cell) {
		if (!in_bounds(p_cell) || blocked.has(p_cell)) {
			return false;
		}
		if (fenced(p_cell)) {
			return false;
		}
		if (tiles) {
			TileRef tile = tile_at(p_cell);
			if (tile.exists() && (is_ledge(tile) || tile_name(tile).to_lower().contains("fence") || tile_upper(tile).to_lower().contains("fence"))) {
				return false;
			}
		}
		if (swim_only(p_species)) {
			return terrain_kind_at(p_cell) == 0;
		}
		return walkable_at(p_cell) && terrain_kind_at(p_cell) != 0;
	}

	// PopulationRules.can_move_between.
	bool can_move_between(const String &p_species, const Vector2i &p_origin, const Vector2i &p_target) {
		const String lowered = p_species.to_lower();
		if (lowered == "araichu" || lowered == "raichu_alolan" || lowered == "aexeggutor" || lowered == "exeggutor_alolan") {
			return sim->rules_script->call(S(can_move_between), state, p_species, p_origin, p_target).booleanize();
		}
		if (tiles) {
			TileRef destination = tile_at(p_target);
			TileRef current = tile_at(p_origin);
			if (!destination.exists() || is_ledge(destination)) {
				return false;
			}
			if (current.exists() && is_ledge(current) && permitted_ledge_direction(current) == UP && p_target.y < p_origin.y) {
				return false;
			}
		}
		if (!in_water(p_origin)) {
			return can_enter(p_species, p_target);
		}
		if (!in_bounds(p_target) || blocked.has(p_target)) {
			return false;
		}
		if (fenced(p_target)) {
			return false;
		}
		if (tiles) {
			TileRef tile = tile_at(p_target);
			if (!tile.exists()) {
				return false;
			}
			const String name = tile_name(tile);
			if (tile_upper(tile).contains("fence") || name.contains("fence")) {
				return false;
			}
			bool near_shore = false;
			bool target_near_shore = false;
			for (int y = -1; y < 2; y++) {
				for (int x = -1; x < 2; x++) {
					const Vector2i direction(x, y);
					if (!near_shore) {
						TileRef shore = tile_at(p_origin + direction);
						near_shore = shore.exists() && !tile_name(shore).contains("water");
					}
					if (!target_near_shore) {
						TileRef target_shore = tile_at(p_target + direction);
						target_near_shore = target_shore.exists() && !tile_name(target_shore).contains("water");
					}
				}
			}
			if (near_shore && (!target_near_shore || !name.contains("water"))) {
				return false;
			}
			return swim_only(p_species) ? is_water(tile) : (is_water(tile) || !is_solid_flag(tile));
		}
		return can_enter(p_species, p_target);
	}

	// --- Who is who ----------------------------------------------------------

	// PopulationRules.wild_ecology_record.
	Dictionary wild_ecology_record(const String &p_ecology_id) {
		if (p_ecology_id.begins_with("wild:")) {
			const Variant *record = w_records.getptr(p_ecology_id.substr(5).to_int());
			if (record && record->get_type() == Variant::DICTIONARY) {
				Dictionary found = *record;
				if (get_string(found, K(ecology_id)) == p_ecology_id) {
					return found;
				}
			}
		}
		for (const KeyValue<Variant, Variant> &entry : w_records) {
			Dictionary data = entry.value;
			if (get_string(data, K(ecology_id)) == p_ecology_id) {
				return data;
			}
		}
		return Dictionary();
	}

	// PopulationRules.ecology_cell_by_id.
	Vector2i ecology_cell_by_id(const String &p_ecology_id) {
		for (const KeyValue<Variant, Variant> &entry : h_records) {
			Dictionary data = entry.value;
			if (get_string(data, K(ecology_id)) == p_ecology_id) {
				return Vector2i(entry.key);
			}
		}
		Dictionary record = wild_ecology_record(p_ecology_id);
		if (!record.is_empty()) {
			return get_cell(record, K(cell));
		}
		return NO_CELL;
	}

	// PopulationRules.paired_wander_direction.
	Vector2i paired_wander_direction(const Dictionary &p_data, const Vector2i &p_origin, const Vector2i &p_fallback) {
		const String mate_id = get_string(p_data, K(mate_id));
		if (mate_id.is_empty()) {
			return p_fallback;
		}
		const Vector2i mate_cell = ecology_cell_by_id(mate_id);
		if (mate_cell.x <= INT32_MIN) {
			return p_fallback;
		}
		const Vector2i delta = mate_cell - p_origin;
		const int64_t distance = MAX(absi64(delta.x), absi64(delta.y));
		const bool egg_ready = get_bool(p_data, K(can_lay_egg)) && get_float(p_data, K(lay_egg_seconds), sim->lay_egg_seconds) <= 0.0;
		if (egg_ready && distance > 1) {
			return cardinal_direction(delta, false);
		}
		if (distance > sim->habitat_radius) {
			return cardinal_direction(delta, false);
		}
		if (distance == sim->habitat_radius && rng->randf() < 0.25) {
			return cardinal_direction(delta, false);
		}
		if (distance <= 1 && rng->randf() < 0.22) {
			return cardinal_direction(delta, true);
		}
		return p_fallback;
	}

	// PopulationRules.wild_move_delay.
	double wild_move_delay(const String &p_species, const Dictionary &p_data) {
		if (get_bool(p_data, K(burrowed))) {
			return 999999.0;
		}
		const String normalized = p_species.to_lower();
		if (normalized == "diglett" || normalized == "dugtrio" || normalized == "sharpedo") {
			return rng->randf_range(0.35, 0.8);
		}
		if (get_bool(sim->species_of(normalized)->behavior, K(lunge))) {
			return rng->randf_range(0.35, 0.8);
		}
		return rng->randf_range(sim->wild_move_min, sim->wild_move_max);
	}

	// PopulationRules.try_create_parent_egg: its GDScript once the clock ran out.
	void try_create_parent_egg(const Dictionary &p_data, const Vector2i &p_egg_cell, int64_t p_ignored_wild_id) {
		if (get_float(p_data, K(lay_egg_seconds), sim->lay_egg_seconds) > 0.0 || !get_bool(p_data, K(can_lay_egg))) {
			return;
		}
		release();
		sim->rules_script->call(S(try_create_parent_egg), state, p_data, p_egg_cell, p_ignored_wild_id);
		reacquire();
	}

	// PopulationRules._emote.
	void emote(const Dictionary &p_data, const String &p_emote) {
		if (view) {
			view->call(S(_show_ecology_emote), view->call(S(_sprite_of), p_data), p_emote);
		}
	}

	// The wander step's pull to a companion, the same lines in both ticks:
	// to its friend once their clock ran out, else now and then to its mate
	// or friend. `r_tried`: whether that branch was taken.
	Vector2i companion_direction(Dictionary &p_data, const Vector2i &p_old_cell, const Vector2i &p_direction, const Ref<RandomNumberGenerator> &p_rng,
			Object *p_world, bool &r_tried) {
		Vector2i direction = p_direction;
		const String friend_id = get_string(p_data, K(friend_id));
		const bool friend_reunion = !friend_id.is_empty() && get_float(p_data, K(friend_seconds), sim->friend_seconds) <= 0.0;
		String companion_id = friend_id;
		if (friend_reunion) {
			put(p_data, K(friend_seconds), sim->friend_seconds);
			if (p_world) {
				p_world->call(S(_show_friend_reunion), p_data, friend_id);
			}
		} else if (companion_id.is_empty() || p_rng->randf() < 0.18) {
			const Variant *mate = p_data.getptr(K(mate_id));
			companion_id = mate ? String(*mate) : companion_id;
		}
		r_tried = !companion_id.is_empty() && (friend_reunion || p_rng->randf() < 0.20);
		if (r_tried) {
			const Vector2i companion_cell = ecology_cell_by_id(companion_id);
			if (companion_cell.x > INT32_MIN) {
				direction = cardinal_direction(companion_cell - p_old_cell, false);
			}
		}
		return direction;
	}

	// --- WildPopulation.tick -----------------------------------------------

	// WildPopulation._beside_player.
	bool beside_player(const Vector2i &p_cell) const {
		return world && (p_cell == Vector2i(world->get(S(follower_cell))) || p_cell == Vector2i(world->get(S(field_helper_cell))));
	}

	// The free_step of WildPopulation._act's flight.
	bool free_step(const Vector2i &p_step, const Vector2i &p_player_cell, int64_t p_wild_id) {
		return !(p_step == p_player_cell || beside_player(p_step) || (online && players->call(S(occupied), p_step).booleanize()) || id_at(p_step, p_wild_id) >= 0 ||
				e_records.has(p_step) || h_records.has(p_step));
	}

	// WildPopulation.flee_direction.
	Vector2i flee_direction(int64_t p_wild_id, const String &p_species, const Vector2i &p_origin, const Vector2i &p_threat) {
		Array route = flee_routes.get(p_wild_id, Array());
		if (!route.is_empty()) {
			const Vector2i planned = route[0];
			if ((planned - p_origin).length_squared() == 1 && (p_threat - planned).length_squared() > 2 && can_move_between(p_species, p_origin, planned) &&
					free_step(planned, p_threat, p_wild_id)) {
				route.pop_front();
				flee_routes[p_wild_id] = route;
				return planned - p_origin;
			}
		}
		HashMap<Vector2i, Vector2i> came;
		HashMap<Vector2i, int> depth;
		came.insert(p_origin, p_origin);
		depth.insert(p_origin, 0);
		LocalVector<Vector2i> queue;
		queue.push_back(p_origin);
		uint32_t head = 0;
		Vector2i goal = p_origin;
		double goal_score = double((p_threat - p_origin).length_squared());
		const Vector2i options[4] = { Vector2i(-1, 0), Vector2i(1, 0), Vector2i(0, -1), Vector2i(0, 1) };
		while (head < queue.size() && int64_t(queue.size()) < sim->flee_search_tiles) {
			const Vector2i cell = queue[head];
			head++;
			if (depth[cell] >= sim->flee_look_ahead) {
				continue;
			}
			for (const Vector2i &option : options) {
				const Vector2i step = cell + option;
				// Never plan a way that brushes past the player.
				if (came.has(step) || (p_threat - step).length_squared() <= 2) {
					continue;
				}
				if (!can_move_between(p_species, cell, step)) {
					continue;
				}
				if (cell == p_origin && !free_step(step, p_threat, p_wild_id)) {
					continue;
				}
				came.insert(step, cell);
				depth.insert(step, depth[cell] + 1);
				queue.push_back(step);
				const double score = double((p_threat - step).length_squared()) - 0.05 * double(depth[step]);
				if (score > goal_score) {
					goal = step;
					goal_score = score;
				}
			}
		}
		route = Array();
		while (goal != p_origin) {
			route.push_front(goal);
			goal = came[goal];
		}
		if (route.is_empty()) {
			flee_routes.erase(p_wild_id);
			return Vector2i();
		}
		const Vector2i first = route.pop_front();
		flee_routes[p_wild_id] = route.slice(0, sim->flee_replan_steps);
		return first - p_origin;
	}

	// WildPopulation.nearby_same_base_species_cell.
	Vector2i nearby_same_base_species_cell(const Dictionary &p_data, const Vector2i &p_center) {
		const String base_species = get_string(p_data, K(base_species));
		const int64_t own_id = get_int(p_data, K(id), -1);
		LocalVector<Vector3i> squares;
		squares.push_back(Vector3i(p_center.x, p_center.y, sim->habitat_radius));
		PackedInt32Array slots = slots_in(squares);
		for (int index = 0; index < slots.size(); index++) {
			const int64_t raw_id = w_ids[slots[index]];
			if (raw_id == own_id) {
				continue;
			}
			Dictionary candidate = w_records[raw_id];
			if (get_string(candidate, K(base_species)) == base_species) {
				return get_cell(candidate, K(cell));
			}
		}
		return NO_CELL;
	}

	// WildPopulation._target: the player `p_data` goes for, its co-op target noted.
	bool target_of(Dictionary &p_data, const Vector2i &p_old_cell, Dictionary &r_target, Vector2i &r_player_cell, bool &r_local) {
		const String before = get_string(p_data, K(coop_target));
		r_target = players->call(S(target_for), p_data, p_old_cell);
		if (get_string(p_data, K(coop_target)) != before) {
			population->call(S(mark), get_int(p_data, K(id), -1));
		}
		if (r_target.is_empty()) {
			return false;
		}
		r_player_cell = Vector2i(int(named(r_target, S(x))), int(named(r_target, S(y))));
		r_local = equal(named(r_target, S(actor)), players->call(S(local_actor)));
		return true;
	}

	// WildPopulation._act: false when a battle began.
	bool act(int64_t p_wild_id, int p_slot, Dictionary &p_data, const Vector2i &p_old_cell, const Vector2i &p_player_cell, bool p_local_target, bool p_is_charmed) {
		const double delay = wild_move_delay(get_string(p_data, K(species)), p_data);
		w_timers.set(p_slot, delay);
		try_create_parent_egg(p_data, p_old_cell, p_wild_id);
		Dictionary behavior = get_dict(p_data, K(behavior));
		if (get_bool(behavior, K(stationary))) {
			return true;
		}
		const Vector2i player_delta = p_player_cell - p_old_cell;
		const int64_t distance_squared = player_delta.length_squared();
		const bool pursuing = get_bool(p_data, K(aggro_player)) && !p_is_charmed;
		const double now = state->get(S(clock));
		if (now < get_float(p_data, K(fed_until), 0.0)) {
			put(p_data, K(anim_phase), 1 - get_int(p_data, K(anim_phase), 0));
			population->call(S(pose), p_wild_id, DOWN, get_int(p_data, K(anim_phase), 0));
			return true;
		}
		if (pursuing && p_local_target && world) {
			const String field_move = world->get(S(active_field_move));
			if (field_move != "SURF" && field_move != "FLY" && distance_squared <= 1 && !world->call(S(encounter_grace_active)).booleanize() &&
					!world->call(S(_repel_blocks), get_int(p_data, K(level), 1)).booleanize()) {
				sync_call(world, S(_begin_wild_encounter), p_wild_id);
				return false;
			}
		}
		Vector2i direction = sim->directions[tick_rng->randi_range(0, 4)];
		// Timid species keep their distance; one that just broke out of a
		// ball runs from the player for a while, from further off.
		const bool scared = now < get_float(p_data, K(ball_flee_until), 0.0);
		const bool timid = get_bool(behavior, K(flee));
		const bool fleeing = (timid && distance_squared <= 16) || (scared && distance_squared <= int64_t(sim->flee_range_tiles) * sim->flee_range_tiles);
		if (fleeing) {
			direction = cardinal_direction(player_delta, true);
		} else if (pursuing && distance_squared <= 64) {
			direction = cardinal_direction(player_delta, false);
		} else {
			bool tried = false;
			direction = companion_direction(p_data, p_old_cell, direction, tick_rng, world, tried);
			if (!tried && tick_rng->randf() < 0.12) {
				const Vector2i same = nearby_same_base_species_cell(p_data, p_old_cell);
				if (same.x > INT32_MIN) {
					direction = cardinal_direction(same - p_old_cell, false);
				}
			}
		}
		if (!pursuing && !fleeing) {
			direction = paired_wander_direction(p_data, p_old_cell, direction);
		}
		if (!scared) {
			flee_routes.erase(p_wild_id);
			flee_started.erase(p_wild_id);
		} else if (fleeing) {
			direction = flee_direction(p_wild_id, get_string(p_data, K(species)), p_old_cell, p_player_cell);
		}
		const Vector2i target = p_old_cell + direction;
		Dictionary source_record = get_dict(p_data, K(source_record));
		if (get_bool(source_record, K(rare_forest_mew)) && !sim->mew_script->call(S(deep_forest_at), state, target).booleanize()) {
			return true;
		}
		const String rare_species = get_string(source_record, K(rare_legendary));
		if (!rare_species.is_empty() && !sim->legendaries_script->call(S(habitat_at), state, rare_species, target).booleanize()) {
			return true;
		}
		if (direction == Vector2i() || !can_move_between(get_string(p_data, K(species)), p_old_cell, target) || target == p_player_cell || beside_player(target) ||
				(online && players->call(S(occupied), target).booleanize()) || id_at(target, p_wild_id) >= 0 || e_records.has(target) || h_records.has(target)) {
			return true;
		}
		const int64_t phase = 1 - get_int(p_data, K(anim_phase), 0);
		put(p_data, K(anim_phase), phase);
		// The step's pace and facing are the Pokemon's own, sprite or not.
		double move_seconds = 0.20;
		if (timid || (scared && fleeing)) {
			move_seconds = 16.0 / (2.0 * 60.0);
		} else if (pursuing) {
			move_seconds = 16.0 / (1.5 * 60.0);
		}
		population->call(S(begin_step), p_wild_id, move_seconds);
		sync_call(population, S(move), p_wild_id, target);
		if (online) {
			players->call(S(mark_motion), p_wild_id);
		}
		put(p_data, K(ball_facing), Vector2(direction));
		population->call(S(pose), p_wild_id, direction, phase);
		if (pursuing || fleeing) {
			w_timers.set(p_slot, move_seconds);
		}
		if (timid) {
			put(p_data, K(flee_steps), get_int(p_data, K(flee_steps), 0) + 1);
			if (get_int(p_data, K(flee_steps), 0) >= 3 && sim->rules_script->call(S(is_tall_grass_cell), state, target).booleanize()) {
				if (world) {
					sync_call(world, S(_remove_wild_pokemon), p_wild_id);
				} else {
					sync_call(population, S(remove), p_wild_id);
				}
			}
		}
		return true;
	}

	PackedInt64Array wild_tick(double p_delta, const Array &p_observers) {
		wild_sync();
		population->set(S(_ticking), true);
		population->set(S(_tick_dirty), PackedInt64Array());
		timers_held = true;
		w_timers = population->get(S(timers));
		population->set(S(timers), PackedFloat64Array());
		Vector2i player_cell = world ? Vector2i(world->call(S(_player_cell))) : NO_CELL;
		// Which Pokemon are inside a zone is worked out twice a second.
		const int64_t now_msec = OS::get_singleton()->get_ticks_msec();
		if (now_msec - int64_t(population->get(S(watched_at))) >= 500) {
			population->set(S(watched_at), now_msec);
			LocalVector<Vector3i> zones;
			for (int index = 0; index < p_observers.size(); index++) {
				const Variant &observer = p_observers[index];
				zones.push_back(Vector3i(int(named(observer, S(x))), int(named(observer, S(y))), sim->active_radius + 2));
			}
			for (const KeyValue<Variant, Variant> &entry : h_records) {
				const Vector2i habitat_cell = entry.key;
				zones.push_back(Vector3i(habitat_cell.x, habitat_cell.y, sim->habitat_radius + 2));
			}
			Array watched = population->get(S(watched));
			watched.clear();
			PackedInt32Array slots = slots_in(zones);
			for (int index = 0; index < slots.size(); index++) {
				watched.push_back(w_ids[slots[index]]);
			}
		}
		// Online, a Pokemon is kept going by the players who could chase it.
		LocalVector<Vector2i> chasers;
		bool someone_charms = false;
		for (int index = 0; index < p_observers.size(); index++) {
			const Variant &observer = p_observers[index];
			Dictionary seen = observer;
			if (online && get_bool(seen, K(battle))) {
				continue;
			}
			chasers.push_back(Vector2i(int(named(observer, S(x))), int(named(observer, S(y)))));
			if (online && get_string(seen, K(move)) == "CHARM") {
				someone_charms = true;
			}
		}
		const double now = state->get(S(clock));
		const bool charm_move = world && String(world->get(S(active_field_move))) == "CHARM";
		const bool has_cover = habitat != nullptr;
		Array watched = Array(population->get(S(watched))).duplicate();
		for (int position = 0; position < watched.size(); position++) {
			const int64_t wild_id = watched[position];
			const int slot = slot_of(wild_id);
			if (slot < 0) {
				continue;
			}
			Dictionary data = w_records[wild_id];
			if (get_bool(data, K(ball_reserved)) || (w_flags[slot] & sim->burrowed_flag)) {
				continue;
			}
			const Vector2i old_cell(w_cell_x[slot], w_cell_y[slot]);
			bool local_target = true;
			bool has_target = false;
			Dictionary target_player;
			const bool aggro = get_bool(data, K(aggro_player));
			if (online) {
				if (chasers.is_empty()) {
					continue;
				}
				if (aggro) {
					has_target = true;
					if (!target_of(data, old_cell, target_player, player_cell, local_target)) {
						continue;
					}
				}
			}
			// Near a player (online: one who could chase it) or a habitat.
			bool active = has_cover && habitat_near(old_cell);
			if (!active) {
				if (online && !has_target) {
					for (const Vector2i &chaser : chasers) {
						if (absi64(int64_t(old_cell.x) - chaser.x) <= sim->active_radius && absi64(int64_t(old_cell.y) - chaser.y) <= sim->active_radius) {
							active = true;
							break;
						}
					}
				} else {
					active = absi64(int64_t(old_cell.x) - player_cell.x) <= sim->active_radius && absi64(int64_t(old_cell.y) - player_cell.y) <= sim->active_radius;
				}
				if (!active) {
					continue;
				}
			}
			const Variant was_charmed = data.get(K(charmed), Variant());
			bool is_charmed = false;
			if (online) {
				if (get_float(data, K(ball_charm_until), 0.0) > now) {
					is_charmed = true;
				} else if (someone_charms || charm_move) {
					if (!has_target) {
						has_target = true;
						if (!target_of(data, old_cell, target_player, player_cell, local_target)) {
							continue;
						}
					}
					is_charmed = local_target ? world->call(S(_charm_suppresses), data).booleanize() : players->call(S(remote_charm), data, target_player).booleanize();
				}
			} else if (charm_move || get_float(data, K(ball_charm_until), 0.0) > now) {
				is_charmed = world ? world->call(S(_charm_suppresses), data).booleanize() : true;
			}
			if (was_charmed.get_type() == Variant::NIL || was_charmed.booleanize() != is_charmed) {
				put(data, K(charmed), is_charmed);
			}
			if (!online && world) {
				if (aggro || data.has(K(aggro_audio_tick))) {
					world->call(S(_update_source_aggro_audio), data, old_cell, player_cell, p_delta);
				}
			}
			if (is_charmed && !was_charmed.booleanize() && world) {
				world->call(S(_show_ecology_emote), world->call(S(_sprite_of), data), "heart");
			}
			if (aggro) {
				put(data, K(source_aggro_emote_seconds), get_float(data, K(source_aggro_emote_seconds), 0.0) - p_delta);
				if (get_float(data, K(source_aggro_emote_seconds), 0.0) <= 0.0) {
					if (world) {
						world->call(S(_show_ecology_emote), world->call(S(_sprite_of), data), "skull");
					}
					put(data, K(source_aggro_emote_seconds), 241.0 / 60.0);
				}
			}
			const double move_timer = w_timers[slot] - p_delta;
			w_timers.set(slot, move_timer);
			// One that has just broken out of a ball bolts at once.
			const double flee_until = get_float(data, K(ball_flee_until), 0.0);
			if (now < flee_until && double(flee_started.get(wild_id, -1.0)) != flee_until) {
				flee_started[wild_id] = flee_until;
			} else if (move_timer > 0.0) {
				continue;
			}
			if (online && !has_target) {
				has_target = true;
				if (!target_of(data, old_cell, target_player, player_cell, local_target)) {
					continue;
				}
			}
			if (!act(wild_id, slot, data, old_cell, player_cell, local_target, is_charmed)) {
				break;
			}
		}
		release();
		timers_held = false;
		population->set(S(_ticking), false);
		population->call(S(_maybe_compact));
		return population->get(S(_tick_dirty));
	}

	// --- HabitatPopulation.tick --------------------------------------------

	void habitat_tick(Object *p_population, double p_delta, const Ref<RandomNumberGenerator> &p_rng) {
		Dictionary records = p_population->get(S(records));
		Object *owner = object_of(p_population->get(S(world)));
		Variant held = p_population->get(S(players));
		Object *walkers = is_null(held) ? nullptr : object_of(held);
		Array cells = records.keys();
		for (int position = 0; position < cells.size(); position++) {
			const Vector2i old_cell = cells[position];
			const Variant *raw = records.getptr(old_cell);
			if (!raw) {
				continue;
			}
			Dictionary data = *raw;
			if (data.has(K(house_door))) {
				continue;
			}
			// The Pokemon the player is calling back waits for them.
			if (owner) {
				const String recall_hold = owner->get(S(recall_hold));
				if (!recall_hold.is_empty() && get_string(data, K(ecology_id)) == recall_hold) {
					continue;
				}
				owner->call(S(_update_pokemon_water_visual), data);
			}
			put(data, K(move_timer), get_float(data, K(move_timer), 0.0) - p_delta);
			if (get_float(data, K(move_timer), 0.0) > 0.0) {
				continue;
			}
			put(data, K(move_timer), wild_move_delay(get_string(data, K(species)), Dictionary()));
			try_create_parent_egg(data, old_cell, -1);
			Dictionary behavior = get_dict(data, K(behavior));
			if (get_bool(behavior, K(stationary))) {
				continue;
			}
			if (!get_string(data, K(held_item)).is_empty()) {
				put(data, K(anim_phase), 1 - get_int(data, K(anim_phase), 0));
				if (owner) {
					owner->call(S(_habitat_pose), data, DOWN);
				}
				p_population->call(S(mark), old_cell);
				continue;
			}
			Vector2i direction = sim->directions[p_rng->randi_range(0, 4)];
			bool tried = false;
			direction = companion_direction(data, old_cell, direction, p_rng, owner, tried);
			direction = paired_wander_direction(data, old_cell, direction);
			const Vector2i target = old_cell + direction;
			if (direction == Vector2i() || !can_move_between(get_string(data, K(species)), old_cell, target)) {
				continue;
			}
			if (owner && (target == Vector2i(owner->call(S(_player_cell))) || target == Vector2i(owner->get(S(follower_cell))) || target == Vector2i(owner->get(S(field_helper_cell))))) {
				continue;
			}
			if ((walkers && walkers->call(S(occupied), target).booleanize()) || records.has(target) || id_at(target) >= 0 || e_records.has(target)) {
				continue;
			}
			sync_call(p_population, S(move), old_cell, target);
			put(data, K(cell), target);
			put(data, K(x), target.x);
			put(data, K(y), target.y);
			put(data, K(anim_phase), 1 - get_int(data, K(anim_phase), 0));
			double move_seconds = 0.20;
			if (get_bool(behavior, K(flee))) {
				move_seconds = 16.0 / (2.0 * 60.0);
			}
			if (owner) {
				owner->call(S(_habitat_step_visuals), data, direction, target, move_seconds);
			}
		}
	}

	// --- The ecology pass ----------------------------------------------------

	// PopulationRules.is_night.
	bool is_night() const {
		const double clock = state->get(S(clock));
		return Math::fmod(clock, sim->day_seconds) / sim->day_seconds >= sim->night_start;
	}

	// PokemonEcology.habitat_groups and requires_night of a species.
	Species *species_habitat(const String &p_name) {
		Species *known = sim->species_of(p_name);
		if (!known->habitat_known) {
			known->habitat_known = true;
			Array groups = sim->ecology_script->call(S(habitat_groups), p_name);
			for (int index = 0; index < groups.size(); index++) {
				const String raw = groups[index];
				known->group_names.push_back(raw);
				known->group_options.push_back(raw.to_lower().split("|"));
			}
			known->requires_night = sim->ecology_script->call(S(requires_night), p_name).booleanize();
		}
		return known;
	}

	// The options of `p_species`' habitat among the kept ones; false when
	// they cannot be (an option with a space, too many).
	bool add_options(const String &p_species) {
		Names *kept = sim->names;
		Species *known = species_habitat(p_species);
		for (const Vector<String> &options : known->group_options) {
			for (const String &option : options) {
				if (kept->option_index.has(option)) {
					continue;
				}
				if (option.contains(" ") || kept->options.size() >= MAX_OPTIONS) {
					return false;
				}
				kept->option_index.insert(option, kept->options.size());
				kept->options.push_back(option);
			}
		}
		return true;
	}

	uint64_t group_bits(const Vector<String> &p_options) const {
		uint64_t bits = 0;
		for (const String &option : p_options) {
			const int *index = sim->names->option_index.getptr(option);
			if (index && !option.is_empty()) {
				bits |= uint64_t(1) << (FIRST_OPTION_BIT + *index);
			}
		}
		return bits;
	}

	// `p_piece`'s bits brought up to the options there are.
	uint64_t piece_of(const String &p_piece, PieceBits &r_bits) const {
		const Names *kept = sim->names;
		while (r_bits.known < kept->options.size()) {
			if (p_piece.contains(kept->options[r_bits.known])) {
				r_bits.bits |= uint64_t(1) << (FIRST_OPTION_BIT + r_bits.known);
			}
			r_bits.known++;
		}
		return r_bits.bits;
	}

	uint64_t piece_bits(const String &p_piece) {
		PieceBits *known = sim->names->pieces.getptr(p_piece);
		if (!known) {
			PieceBits made;
			if (p_piece.contains("fence")) {
				made.bits |= FENCE_BIT;
			}
			if (p_piece.contains("roof")) {
				made.bits |= ROOF_BIT;
			}
			known = &sim->names->pieces.insert(p_piece, made)->value;
		}
		return piece_of(p_piece, *known);
	}

	// The terrain_changes "ice:x,y" keys, by cell (placed_names' snow).
	void scan_ice() {
		if (ice_scanned) {
			return;
		}
		ice_scanned = true;
		for (const KeyValue<Variant, Variant> &entry : terrain_changes) {
			const Variant::Type type = entry.key.get_type();
			if (type != Variant::STRING && type != Variant::STRING_NAME) {
				continue;
			}
			const String key = entry.key;
			if (!key.begins_with("ice:")) {
				continue;
			}
			const String rest = key.substr(4);
			const int comma = rest.find(",");
			if (comma < 0) {
				continue;
			}
			const int64_t x = rest.substr(0, comma).to_int();
			const int64_t y = rest.substr(comma + 1).to_int();
			if (x < INT32_MIN || x > INT32_MAX || y < INT32_MIN || y > INT32_MAX || vformat("ice:%d,%d", x, y) != key) {
				continue;
			}
			ice.insert(Vector2i(int32_t(x), int32_t(y)), entry.value);
		}
	}

	// The flowers, structures and landmarks of the area as placed_bits by
	// cell: only cells keyed by a Vector2i are ever found by one.
	void scan_placed() {
		placed_state = 2;
		if (flowers.size() + structures.size() + landmarks.size() > 4096) {
			placed_state = 1;
			return;
		}
		HashSet<Vector2i> cells;
		for (const Dictionary &group : { flowers, structures, landmarks }) {
			for (const KeyValue<Variant, Variant> &entry : group) {
				if (entry.key.get_type() == Variant::VECTOR2I) {
					cells.insert(entry.key);
				}
			}
		}
		for (const Vector2i &cell : cells) {
			placed.insert(cell, lookup_placed_bits(cell));
		}
	}

	// PopulationRules.placed_names, as bits.
	uint64_t placed_bits(const Vector2i &p_cell) {
		if (placed_state == 0) {
			scan_placed();
		}
		uint64_t bits = 0;
		if (placed_state == 2) {
			const uint64_t *known = placed.getptr(p_cell);
			if (known) {
				bits = *known;
			}
		} else {
			bits = lookup_placed_bits(p_cell);
		}
		if (!terrain_changes.is_empty()) {
			scan_ice();
			const Variant *value = ice.getptr(p_cell);
			if (value && value->booleanize()) {
				bits |= piece_bits("snow");
			}
		}
		return bits;
	}

	// placed_names' flowers, structures and landmarks.
	uint64_t lookup_placed_bits(const Vector2i &p_cell) {
		uint64_t bits = 0;
		if (!flowers.is_empty() && flowers.has(p_cell)) {
			bits |= piece_bits("flower");
		}
		if (!structures.is_empty()) {
			const Variant *built = structures.getptr(p_cell);
			if (built) {
				const String built_name = get_string(Dictionary(*built), K(name)).to_lower();
				bits |= piece_bits(built_name);
				if (built_name == "flowers") {
					bits |= piece_bits("flower");
				} else if (built_name == "plant") {
					bits |= piece_bits("potted");
				} else if (built_name == "grave") {
					bits |= piece_bits("gravestone");
				}
			}
		}
		if (!landmarks.is_empty()) {
			const Variant *landmark = landmarks.getptr(p_cell);
			if (landmark) {
				bits |= piece_bits(get_string(Dictionary(*landmark), K(type)).to_lower());
			}
		}
		return bits;
	}

	// PopulationRules._packed_tile_biome (its GDScript, once per kind a pass).
	String packed_tile_biome(int p_index, const Vector2i &p_cell) {
		const int64_t kind = (int64_t(s_biome_ids[p_index]) << 32) | (int64_t(s_route_ids[p_index]) << 1) | int64_t((s_flags[p_index] & sim->store_water) != 0);
		const String *known = pass->biomes.getptr(kind);
		if (known) {
			return *known;
		}
		const String biome = sim->rules_script->call(S(_packed_tile_biome), state, store, p_index, p_cell);
		pass->biomes.insert(kind, biome);
		return biome;
	}

	// PopulationRules.ecology_names_at, as bits.
	uint64_t names_bits(const Vector2i &p_cell) {
		if (!house_cells.is_empty() && house_cells.has(p_cell)) {
			return piece_bits("house_floor") | piece_bits(structure_name(p_cell).to_lower());
		}
		if (packed) {
			const int index = index_of(p_cell);
			if (index >= 0) {
				if (!memo_ready) {
					// The memo ecology_names_at keeps (and _packed_tile_biome reads).
					memo_ready = true;
					if (object_of(memo.get(K(names_store), Variant())) != store) {
						memo[String("names_store")] = store;
						memo[String("names")] = Dictionary();
						memo[String("biomes")] = Dictionary();
					}
				}
				const int64_t pair = (int64_t(s_name_ids[index]) << 24) | int64_t(s_upper_ids[index]);
				PairInfo *own = sim->names->pairs.getptr(pair);
				if (!own) {
					const String name = s_strings[s_name_ids[index]];
					const String upper = s_strings[s_upper_ids[index]];
					PairInfo made;
					made.own = name.to_lower() + " " + upper.to_lower();
					made.piece.bits = (made.own.contains("fence") ? FENCE_BIT : 0) | (made.own.contains("roof") ? ROOF_BIT : 0);
					made.grass = tile_key(name) == "grass1" || tile_key(upper) == "grass1";
					own = &sim->names->pairs.insert(pair, made)->value;
				}
				const uint64_t own_bits = piece_of(own->own, own->piece);
				const int flags = s_flags[index];
				bool grass;
				if ((flags & sim->store_tidal) != 0 && packed_tile_biome(index, p_cell) != "BEACH") {
					grass = false;
				} else {
					grass = own->grass || (flags & sim->store_grass) != 0;
				}
				return own_bits | (grass ? pass->grass_bits : 0) | placed_bits(p_cell);
			}
		}
		if (!in_bounds(p_cell)) {
			return 0;
		}
		return piece_bits(sim->rules_script->call(S(ecology_names_at), state, p_cell, house_cells));
	}

	// The bits of a window cell, worked out once a pass. `r_key` and
	// `r_chunk`: the chunk the cell before was in.
	uint64_t cell_bits(const Vector2i &p_cell, Vector2i &r_key, uint32_t &r_chunk) {
		const Vector2i key(p_cell.x >> 3, p_cell.y >> 3);
		if (r_chunk == UINT32_MAX || key != r_key) {
			r_key = key;
			const uint32_t *known = pass->chunk_index.getptr(key);
			if (known) {
				r_chunk = *known;
			} else {
				r_chunk = pass->chunks.size();
				pass->chunks.push_back(CellChunk());
				pass->chunk_index.insert(key, r_chunk);
			}
		}
		const int local = ((p_cell.y & 7) << 3) | (p_cell.x & 7);
		const uint64_t mask = uint64_t(1) << local;
		if (pass->chunks[r_chunk].known & mask) {
			return pass->chunks[r_chunk].bits[local];
		}
		const uint64_t bits = names_bits(p_cell);
		pass->chunks[r_chunk].known |= mask;
		pass->chunks[r_chunk].bits[local] = bits;
		return bits;
	}

	// PopulationRules.refresh_record_habitat.
	void habitat_window(Dictionary &p_data, Species *p_species, const Vector2i &p_cell, bool p_night) {
		Species *known = p_species;
		uint64_t window = 0;
		int fence_count = 0;
		int roof_count = 0;
		const int radius = sim->habitat_radius;
		Vector2i chunk_key;
		uint32_t chunk = UINT32_MAX;
		for (int y = p_cell.y - radius; y <= p_cell.y + radius; y++) {
			for (int x = p_cell.x - radius; x <= p_cell.x + radius; x++) {
				const uint64_t bits = cell_bits(Vector2i(x, y), chunk_key, chunk);
				window |= bits;
				if (bits & FENCE_BIT) {
					fence_count++;
				} else if (bits & ROOF_BIT) {
					roof_count++;
				}
			}
		}
		TypedArray<String> missing;
		for (int index = 0; index < known->group_names.size(); index++) {
			if (!(window & group_bits(known->group_options[index]))) {
				missing.push_back(known->group_names[index]);
			}
		}
		if (known->requires_night && !p_night) {
			missing.push_back("night");
		}
		put(p_data, K(missing_habitats), missing);
		put(p_data, K(in_habitat), missing.is_empty());
		put(p_data, K(in_shelter), roof_count >= 3 && fence_count >= 2);
	}

	// What PokemonEcology.can_mate reads of a record.
	void facts(Rec &p_rec) {
		if (p_rec.facts_known) {
			return;
		}
		p_rec.facts_known = true;
		p_rec.is_egg = get_bool(p_rec.data, K(is_egg));
		const String raw_species = get_string(p_rec.data, K(species));
		Species *known = sim->species_of(raw_species);
		p_rec.species = known->normalized;
		// PokemonEcology._record_egg_groups.
		if (p_rec.data.has(K(egg_groups))) {
			p_rec.groups = string_array(p_rec.data.get(K(egg_groups), Array()));
		} else {
			Array none;
			none.push_back("EGG_NONE");
			none.push_back("EGG_NONE");
			p_rec.groups = string_array(known->info.get(K(egg_groups), none));
		}
		const Variant *gender = p_rec.data.getptr(K(gender));
		p_rec.gender = (gender ? String(*gender) : String("unknown")).to_lower();
	}

	// PokemonEcology.can_mate.
	bool can_mate(Rec &p_first, Rec &p_second) {
		if (p_first.data.is_empty() || p_second.data.is_empty()) {
			return false;
		}
		facts(p_first);
		facts(p_second);
		if (p_first.is_egg || p_second.is_egg) {
			return false;
		}
		if (p_first.species == "ditto" && p_second.species == "ditto") {
			return false;
		}
		if (!share_egg_group(p_first.groups, p_second.groups)) {
			return false;
		}
		if (p_first.groups.has("EGG_DITTO") || p_second.groups.has("EGG_DITTO")) {
			return true;
		}
		if (p_first.species != p_second.species) {
			return false;
		}
		return p_second.gender == (p_first.gender == "male" ? "female" : "male");
	}

	// PokemonEcology.can_be_friends.
	bool can_be_friends(Rec &p_first, Rec &p_second) {
		facts(p_first);
		facts(p_second);
		if (p_first.groups.has("EGG_DITTO") || p_second.groups.has("EGG_DITTO")) {
			return false;
		}
		if (!share_egg_group(p_first.groups, p_second.groups)) {
			return false;
		}
		if (can_mate(p_first, p_second)) {
			return false;
		}
		return !p_first.is_egg && !p_second.is_egg;
	}

	// PopulationRules.advance_breeding_clock.
	void advance_breeding_clock(Dictionary p_data, double p_delta, bool p_allow_wild_crowding) {
		const bool population_ok = p_allow_wild_crowding || get_int(p_data, K(nearby_pokemon), 0) < 3;
		if (get_bool(p_data, K(can_lay_egg)) && get_bool(p_data, K(in_habitat)) && get_bool(p_data, K(mate_nearby)) && population_ok &&
				get_float(p_data, K(lay_egg_seconds), sim->lay_egg_seconds) > 0.0) {
			put(p_data, K(lay_egg_seconds), MAX(0.0, get_float(p_data, K(lay_egg_seconds), sim->lay_egg_seconds) - p_delta));
		}
		if (!get_string(p_data, K(friend_id)).is_empty() && get_float(p_data, K(friend_seconds), sim->friend_seconds) > 0.0) {
			put(p_data, K(friend_seconds), MAX(0.0, get_float(p_data, K(friend_seconds), sim->friend_seconds) - p_delta));
		}
	}

	// The kept tables for this pass: the pairs of this area's store, every
	// species' options among the options (started again when they are full).
	bool ready_names(const LocalVector<Rec> &p_records) {
		Names *kept = sim->names;
		if (packed && kept->store != store->get_instance_id()) {
			kept->pairs.clear();
			kept->store = store->get_instance_id();
		}
		LocalVector<String> species_names;
		HashSet<Species *> seen;
		for (const Rec &rec : p_records) {
			const String name = get_string(rec.data, K(species));
			Species *known = species_habitat(name);
			if (!seen.has(known)) {
				seen.insert(known);
				species_names.push_back(name);
			}
		}
		for (int attempt = 0; attempt < 2; attempt++) {
			bool fits = true;
			for (const String &name : species_names) {
				if (!add_options(name)) {
					fits = false;
					break;
				}
			}
			if (fits) {
				return true;
			}
			kept->options.clear();
			kept->option_index.clear();
			kept->pieces.clear();
			kept->pairs.clear();
		}
		return false;
	}

	// The records refresh_relationships covers: the habitat Pokemon
	// `p_simulated` picks, then the wild ones near a center or a habitat.
	// False when a habitat cannot be read as bits (the GDScript runs).
	bool gather(const Array &p_centers, const Callable &p_simulated, bool p_with_wild, LocalVector<Rec> &r_records, TypedArray<Dictionary> &r_active_wild) {
		LocalVector<Vector3i> squares;
		for (int index = 0; index < p_centers.size(); index++) {
			const Vector2i center = p_centers[index];
			squares.push_back(Vector3i(center.x, center.y, sim->ecology_active_radius));
		}
		Array cells = h_records.keys();
		for (int index = 0; index < cells.size(); index++) {
			const Vector2i cell = cells[index];
			const Variant record = h_records[cell];
			if (p_simulated.is_valid() && !p_simulated.call(record).booleanize()) {
				continue;
			}
			Rec rec;
			rec.deployed = true;
			rec.cell = cell;
			rec.data = record;
			r_records.push_back(rec);
			squares.push_back(Vector3i(cell.x, cell.y, sim->habitat_radius));
		}
		if (p_with_wild) {
			PackedInt32Array slots = slots_in(squares);
			for (int index = 0; index < slots.size(); index++) {
				Dictionary wild_data = w_records[w_ids[slots[index]]];
				if (get_bool(wild_data, K(burrowed))) {
					continue;
				}
				Rec rec;
				rec.cell = get_cell(wild_data, K(cell));
				rec.data = wild_data;
				r_active_wild.push_back(wild_data);
				r_records.push_back(rec);
			}
		}
		HashSet<const void *> seen;
		for (const Rec &rec : r_records) {
			if (seen.has(rec.data.id())) {
				return false;
			}
			seen.insert(rec.data.id());
		}
		for (Rec &rec : r_records) {
			rec.habitat = species_habitat(get_string(rec.data, K(species)));
		}
		if (!ready_names(r_records)) {
			return false;
		}
		pass->grass_bits = piece_bits("grass");
		return true;
	}

	// PopulationRules.refresh_relationships, on gather's records.
	void refresh_relationships(LocalVector<Rec> &p_records) {
		HashMap<String, int> index_by_id;
		const bool night = is_night();
		const int count = p_records.size();
		for (int index = 0; index < count; index++) {
			Rec &rec = p_records[index];
			Dictionary &data = rec.data;
			rec.previous_mate_id = get_string(data, K(mate_id));
			put(data, K(previous_mate_id), rec.previous_mate_id);
			put(data, K(mate_id), String());
			put(data, K(friend_id), String());
			put(data, K(can_lay_egg), false);
			put(data, K(mate_nearby), false);
			put(data, K(nearby_pokemon), 0);
			habitat_window(data, rec.habitat, rec.cell, night);
			rec.ecology_id = get_string(data, K(ecology_id));
			if (!rec.ecology_id.is_empty()) {
				index_by_id[rec.ecology_id] = index;
			}
		}
		// An established compatible pair stays bonded while it wanders a few tiles apart.
		for (int index = 0; index < count; index++) {
			Rec &first = p_records[index];
			if (first.previous_mate_id.is_empty()) {
				continue;
			}
			const int *mate_index = index_by_id.getptr(first.previous_mate_id);
			if (!mate_index || *mate_index <= index) {
				continue;
			}
			Rec &second = p_records[*mate_index];
			if (second.previous_mate_id != first.ecology_id) {
				continue;
			}
			if (chebyshev(first.cell, second.cell) > sim->mate_bond_radius || !can_mate(first, second)) {
				continue;
			}
			first.mate_id = second.ecology_id;
			put(first.data, K(mate_id), first.mate_id);
			second.mate_id = first.ecology_id;
			put(second.data, K(mate_id), second.mate_id);
		}
		// Who stands in each one's window (the records on its cells, and the
		// eggs), from the records and eggs by 8x8 cells.
		HashMap<Vector2i, LocalVector<int>> record_buckets;
		for (int index = 0; index < count; index++) {
			record_buckets[Vector2i(p_records[index].cell.x >> 3, p_records[index].cell.y >> 3)].push_back(index);
		}
		HashMap<Vector2i, LocalVector<Vector2i>> egg_buckets;
		for (const KeyValue<Variant, Variant> &entry : e_records) {
			if (entry.key.get_type() == Variant::VECTOR2I) {
				const Vector2i egg = entry.key;
				egg_buckets[Vector2i(egg.x >> 3, egg.y >> 3)].push_back(egg);
			}
		}
		const int radius = sim->habitat_radius;
		LocalVector<LocalVector<int>> nearby_indices;
		nearby_indices.resize(count);
		for (int index = 0; index < count; index++) {
			Rec &rec = p_records[index];
			const Vector2i center = rec.cell;
			int64_t nearby = 0;
			LocalVector<int> &candidates = nearby_indices[index];
			for (int by = (center.y - radius) >> 3; by <= (center.y + radius) >> 3; by++) {
				for (int bx = (center.x - radius) >> 3; bx <= (center.x + radius) >> 3; bx++) {
					const LocalVector<int> *at = record_buckets.getptr(Vector2i(bx, by));
					if (at) {
						for (const int candidate : *at) {
							if (candidate != index && chebyshev(p_records[candidate].cell, center) <= radius) {
								nearby++;
								candidates.push_back(candidate);
							}
						}
					}
					const LocalVector<Vector2i> *eggs_at = egg_buckets.getptr(Vector2i(bx, by));
					if (eggs_at) {
						for (const Vector2i &egg : *eggs_at) {
							if (chebyshev(egg, center) <= radius) {
								nearby++;
							}
						}
					}
				}
			}
			// The former record-order choice when more than one mate or friend is near.
			candidates.sort();
			put(rec.data, K(nearby_pokemon), nearby);
		}
		for (int index = 0; index < count; index++) {
			Rec &first = p_records[index];
			if (!first.mate_id.is_empty()) {
				continue;
			}
			for (const int candidate : nearby_indices[index]) {
				if (candidate <= index) {
					continue;
				}
				Rec &second = p_records[candidate];
				if (!second.mate_id.is_empty()) {
					continue;
				}
				if (!can_mate(first, second)) {
					continue;
				}
				first.mate_id = second.ecology_id;
				put(first.data, K(mate_id), first.mate_id);
				second.mate_id = first.ecology_id;
				put(second.data, K(mate_id), second.mate_id);
				first.friend_id = String();
				put(first.data, K(friend_id), String());
				second.friend_id = String();
				put(second.data, K(friend_id), String());
				break;
			}
		}
		for (int index = 0; index < count; index++) {
			Rec &first = p_records[index];
			if (!first.mate_id.is_empty() || !first.friend_id.is_empty()) {
				continue;
			}
			for (const int candidate : nearby_indices[index]) {
				if (candidate <= index) {
					continue;
				}
				Rec &second = p_records[candidate];
				if (!second.mate_id.is_empty() || !second.friend_id.is_empty() || !can_be_friends(first, second)) {
					continue;
				}
				first.friend_id = second.ecology_id;
				put(first.data, K(friend_id), first.friend_id);
				second.friend_id = first.ecology_id;
				put(second.data, K(friend_id), second.friend_id);
				break;
			}
		}
		for (int index = 0; index < count; index++) {
			Rec &rec = p_records[index];
			Dictionary &data = rec.data;
			const String mate_id = rec.mate_id;
			if (!mate_id.is_empty()) {
				const int *mate_index = index_by_id.getptr(mate_id);
				if (mate_index) {
					Rec &mate = p_records[*mate_index];
					Array groups = data.get(K(egg_groups), Array());
					put(data, K(can_lay_egg), get_string(data, K(gender)) == "female" || (groups.has("EGG_DITTO") && get_string(mate.data, K(gender)) == "male"));
					put(data, K(mate_nearby), chebyshev(rec.cell, mate.cell) <= radius);
				}
			}
			if (!mate_id.is_empty() && mate_id != rec.previous_mate_id) {
				emote(data, "heart");
			}
			data.erase(K(previous_mate_id));
		}
	}

	// ECOLOGY_FIELDS.map(record.get): what the pass sets of a habitat Pokemon.
	LocalVector<Variant> ecology_values(const Dictionary &p_record) const {
		LocalVector<Variant> values;
		for (int index = 0; index < sim->ecology_fields.size(); index++) {
			values.push_back(p_record.get(sim->ecology_keys[index], Variant()));
		}
		return values;
	}

	// Whether `p_record`'s fields differ from `p_before` (the != of the two
	// maps' Arrays: each pair as Array.recursive_equal compares them).
	bool ecology_changed(const LocalVector<Variant> *p_before, const Dictionary &p_record) const {
		if (!p_before) {
			return true;
		}
		for (int index = 0; index < sim->ecology_fields.size(); index++) {
			if (!(*p_before)[index].hash_compare(p_record.get(sim->ecology_keys[index], Variant()), 1, false)) {
				return true;
			}
		}
		return false;
	}

	// PopulationRules.run_ecology_step once its clock ran out.
	bool ecology_pass(double p_ecology_delta, const Array &p_centers, const Callable &p_simulated, bool p_with_wild, const Callable &p_may_release) {
		if (!habitat) {
			return false;
		}
		Dictionary deployed = h_records;
		HashMap<Vector2i, LocalVector<Variant>> before;
		for (const KeyValue<Variant, Variant> &entry : deployed) {
			before.insert(entry.key, ecology_values(entry.value));
		}
		LocalVector<Rec> records;
		TypedArray<Dictionary> active_wild;
		if (!gather(p_centers, p_simulated, p_with_wild, records, active_wild)) {
			return false;
		}
		refresh_relationships(records);
		release();
		sim->rules_script->call(S(release_old_eggs), state, p_may_release);
		reacquire();
		Array cells = deployed.keys();
		for (int index = 0; index < cells.size(); index++) {
			const Vector2i cell = cells[index];
			if (!deployed.has(cell)) {
				continue;
			}
			Dictionary data = deployed[cell];
			if (p_simulated.is_valid() && !p_simulated.call(data).booleanize()) {
				continue;
			}
			if (get_bool(data, K(in_habitat)) && get_string(data, K(held_item)).is_empty()) {
				const double shelter_multiplier = get_bool(data, K(in_shelter)) ? 2.0 : 1.0;
				put(data, K(harvest_progress), get_float(data, K(harvest_progress), 0.0) + p_ecology_delta * shelter_multiplier);
				Species *known = sim->species_of(get_string(data, K(species)));
				if (!known->harvest_known) {
					known->harvest_known = true;
					known->harvest_seconds = sim->ecology_script->call(S(harvest_seconds), get_string(data, K(species)));
					known->harvest_items = sim->ecology_script->call(S(harvest_items), get_string(data, K(species)));
				}
				if (get_float(data, K(harvest_progress), 0.0) >= known->harvest_seconds && !known->harvest_items.is_empty()) {
					put(data, K(held_item), known->harvest_items[rng->randi_range(0, known->harvest_items.size() - 1)]);
				}
			}
			advance_breeding_clock(data, p_ecology_delta, false);
			if (ecology_changed(before.getptr(cell), data)) {
				habitat->call(S(mark), cell);
			}
		}
		// The wild Pokemon in play are the ones the relationship pass just took.
		for (int index = 0; index < active_wild.size(); index++) {
			advance_breeding_clock(active_wild[index], p_ecology_delta, true);
		}
		return true;
	}
};

// --- PokeWildsPopulationSim -------------------------------------------------

PokeWildsPopulationSim::PokeWildsPopulationSim() {
	names = memnew(Names);
	directions[0] = Vector2i(0, 0);
	directions[1] = Vector2i(-1, 0);
	directions[2] = Vector2i(1, 0);
	directions[3] = Vector2i(0, -1);
	directions[4] = Vector2i(0, 1);
}

PokeWildsPopulationSim::~PokeWildsPopulationSim() {
	memdelete(names);
	for (KeyValue<String, Species *> &entry : species) {
		memdelete(entry.value);
	}
}

void PokeWildsPopulationSim::configure(const Dictionary &p_scripts) {
	wild_script = p_scripts.get("wild", Variant());
	rules_script = p_scripts.get("rules", Variant());
	ecology_script = p_scripts.get("ecology", Variant());
	data_script = p_scripts.get("data", Variant());
	mew_script = p_scripts.get("mew", Variant());
	legendaries_script = p_scripts.get("legendaries", Variant());
	store_script = p_scripts.get("store", Variant());
	ERR_FAIL_COND_MSG(wild_script.is_null() || rules_script.is_null() || ecology_script.is_null() || data_script.is_null() || mew_script.is_null() ||
					legendaries_script.is_null() || store_script.is_null(),
			"PokeWildsPopulationSim.configure: a script is missing.");
	bucket_shift = wild_script->get(S(BUCKET_SHIFT));
	burrowed_flag = wild_script->get(S(BURROWED));
	active_radius = wild_script->get(S(ACTIVE_RADIUS));
	flee_range_tiles = wild_script->get(S(FLEE_RANGE_TILES));
	flee_look_ahead = wild_script->get(S(FLEE_LOOK_AHEAD));
	flee_search_tiles = wild_script->get(S(FLEE_SEARCH_TILES));
	flee_replan_steps = wild_script->get(S(FLEE_REPLAN_STEPS));
	Array dirs = wild_script->get(S(DIRECTIONS));
	ERR_FAIL_COND_MSG(dirs.size() != 5, "PokeWildsPopulationSim.configure: five DIRECTIONS expected.");
	for (int index = 0; index < 5; index++) {
		directions[index] = dirs[index];
	}
	habitat_radius = ecology_script->get(S(HABITAT_RADIUS));
	habitat_check_seconds = ecology_script->get(S(HABITAT_CHECK_SECONDS));
	lay_egg_seconds = ecology_script->get(S(LAY_EGG_SECONDS));
	friend_seconds = ecology_script->get(S(FRIEND_SECONDS));
	ecology_active_radius = rules_script->get(S(ECOLOGY_ACTIVE_RADIUS));
	mate_bond_radius = rules_script->get(S(MATE_BOND_RADIUS));
	day_seconds = rules_script->get(S(DAY_SECONDS));
	night_start = rules_script->get(S(NIGHT_START));
	wild_move_min = rules_script->get(S(WILD_MOVE_MIN));
	wild_move_max = rules_script->get(S(WILD_MOVE_MAX));
	ecology_fields = rules_script->get(S(ECOLOGY_FIELDS));
	ecology_keys.clear();
	for (int index = 0; index < ecology_fields.size(); index++) {
		ecology_keys.push_back(StringName(String(ecology_fields[index])));
	}
	tile_size = store_script->get(S(TILE));
	store_present = store_script->get(S(PRESENT));
	store_solid = store_script->get(S(SOLID));
	store_ledge = store_script->get(S(LEDGE));
	store_water = store_script->get(S(WATER));
	store_grass = store_script->get(S(GRASS));
	store_tidal = store_script->get(S(TIDAL));
	configured = tile_size > 0;
}

PokeWildsPopulationSim::Species *PokeWildsPopulationSim::species_of(const String &p_name) {
	Species **known = species.getptr(p_name);
	if (known) {
		return *known;
	}
	Species *made = memnew(Species);
	made->info = data_script->call(S(info), p_name);
	made->behavior = get_dict(made->info, K(overworld_behavior));
	made->normalized = normalize_species(p_name);
	species.insert(p_name, made);
	return made;
}

PackedInt32Array PokeWildsPopulationSim::slots_in(Object *p_population, const Array &p_squares) {
	ERR_FAIL_COND_V(!configured || !p_population, PackedInt32Array());
	Ctx ctx;
	ctx.sim = this;
	ctx.wild = p_population;
	ctx.load_wild();
	LocalVector<Vector3i> squares;
	for (int index = 0; index < p_squares.size(); index++) {
		squares.push_back(p_squares[index]);
	}
	return ctx.slots_in(squares);
}

PackedInt64Array PokeWildsPopulationSim::wild_tick(Object *p_population, double p_delta, const Array &p_observers, const Ref<RandomNumberGenerator> &p_rng) {
	ERR_FAIL_COND_V(!configured || !p_population || p_rng.is_null(), PackedInt64Array());
	Object *area = object_of(p_population->get(S(area)));
	ERR_FAIL_NULL_V(area, PackedInt64Array());
	Ctx ctx;
	ctx.sim = this;
	ctx.load(area);
	// The population ticked is the one asked (an area's own, as a rule).
	if (ctx.wild != p_population) {
		ctx.wild = p_population;
		ctx.load_wild();
	}
	ctx.population = p_population;
	ctx.tick_rng = p_rng;
	Variant players = p_population->get(S(players));
	ctx.online = !is_null(players);
	ctx.players = ctx.online ? object_of(players) : nullptr;
	ctx.world = object_of(p_population->get(S(world)));
	ctx.flee_routes = p_population->get(S(flee_routes));
	ctx.flee_started = p_population->get(S(flee_started));
	return ctx.wild_tick(p_delta, p_observers);
}

void PokeWildsPopulationSim::habitat_tick(Object *p_population, double p_delta, const Ref<RandomNumberGenerator> &p_rng) {
	ERR_FAIL_COND(!configured || !p_population || p_rng.is_null());
	Object *area = object_of(p_population->get(S(area)));
	ERR_FAIL_NULL(area);
	Ctx ctx;
	ctx.sim = this;
	ctx.load(area);
	ctx.habitat_tick(p_population, p_delta, p_rng);
}

bool PokeWildsPopulationSim::ecology_pass(Object *p_state, double p_ecology_delta, const Array &p_centers, const Callable &p_simulated, bool p_with_wild,
		const Dictionary &p_house_cells, const Callable &p_may_release) {
	ERR_FAIL_COND_V(!configured || !p_state, false);
	Ctx ctx;
	ctx.sim = this;
	ctx.load(p_state);
	Pass pass;
	ctx.pass = &pass;
	ctx.house_cells = p_house_cells;
	return ctx.ecology_pass(p_ecology_delta, p_centers, p_simulated, p_with_wild, p_may_release);
}

bool PokeWildsPopulationSim::can_move_between(Object *p_state, const String &p_species, const Vector2i &p_origin, const Vector2i &p_target) {
	ERR_FAIL_COND_V(!configured || !p_state, false);
	Ctx ctx;
	ctx.sim = this;
	ctx.load(p_state);
	return ctx.can_move_between(p_species, p_origin, p_target);
}

Dictionary PokeWildsPopulationSim::refresh_record_habitat(Object *p_state, const Dictionary &p_data, const Vector2i &p_cell, const Dictionary &p_house_cells) {
	ERR_FAIL_COND_V(!configured || !p_state, Dictionary());
	Ctx ctx;
	ctx.sim = this;
	ctx.load(p_state);
	Pass pass;
	ctx.pass = &pass;
	ctx.house_cells = p_house_cells;
	Dictionary data = p_data;
	LocalVector<Rec> records;
	Rec rec;
	rec.data = data;
	records.push_back(rec);
	if (!ctx.ready_names(records)) {
		return Dictionary();
	}
	pass.grass_bits = ctx.piece_bits("grass");
	ctx.habitat_window(data, ctx.species_habitat(get_string(data, K(species))), p_cell, ctx.is_night());
	return data;
}

bool PokeWildsPopulationSim::can_mate(const Dictionary &p_first, const Dictionary &p_second) {
	ERR_FAIL_COND_V(!configured, false);
	Ctx ctx;
	ctx.sim = this;
	Rec first;
	first.data = p_first;
	Rec second;
	second.data = p_second;
	return ctx.can_mate(first, second);
}

bool PokeWildsPopulationSim::can_be_friends(const Dictionary &p_first, const Dictionary &p_second) {
	ERR_FAIL_COND_V(!configured, false);
	Ctx ctx;
	ctx.sim = this;
	Rec first;
	first.data = p_first;
	Rec second;
	second.data = p_second;
	return ctx.can_be_friends(first, second);
}

void PokeWildsPopulationSim::_bind_methods() {
	ClassDB::bind_method(D_METHOD("configure", "scripts"), &PokeWildsPopulationSim::configure);
	ClassDB::bind_method(D_METHOD("is_configured"), &PokeWildsPopulationSim::is_configured);
	ClassDB::bind_method(D_METHOD("slots_in", "population", "squares"), &PokeWildsPopulationSim::slots_in);
	ClassDB::bind_method(D_METHOD("wild_tick", "population", "delta", "observers", "rng"), &PokeWildsPopulationSim::wild_tick);
	ClassDB::bind_method(D_METHOD("habitat_tick", "population", "delta", "rng"), &PokeWildsPopulationSim::habitat_tick);
	ClassDB::bind_method(D_METHOD("ecology_pass", "state", "ecology_delta", "centers", "simulated", "with_wild", "house_cells", "may_release"),
			&PokeWildsPopulationSim::ecology_pass);
	ClassDB::bind_method(D_METHOD("can_move_between", "state", "species", "origin", "target"), &PokeWildsPopulationSim::can_move_between);
	ClassDB::bind_method(D_METHOD("refresh_record_habitat", "state", "data", "cell", "house_cells"), &PokeWildsPopulationSim::refresh_record_habitat);
	ClassDB::bind_method(D_METHOD("can_mate", "first", "second"), &PokeWildsPopulationSim::can_mate);
	ClassDB::bind_method(D_METHOD("can_be_friends", "first", "second"), &PokeWildsPopulationSim::can_be_friends);
}
