#pragma once

// Internals of the native world generator: a line-by-line port of
// project/scripts/source_island_generator.gd (and the GDScript it calls).
// Bit-identical output depends on doing every step exactly as GDScript does:
//  - GDScript `float` is a double and Vector2 holds floats: the same
//    conversions are written out here, with Godot's own Vector2/Rect2i/Math;
//  - a Dictionary keeps insertion order (OMap below), arrays and loops are
//    walked the same way, and objects (tiles, routes) are shared by reference;
//  - never two RNG draws in one C++ expression (argument order is unspecified).

#include "core/math/math_funcs.h"
#include "core/math/rect2i.h"
#include "core/math/vector2.h"
#include "core/math/vector2i.h"
#include "core/os/memory.h"
#include "core/os/mutex.h"
#include "core/string/ustring.h"
#include "core/templates/a_hash_map.h"
#include "core/variant/array.h"
#include "core/variant/dictionary.h"
#include "core/variant/typed_array.h"

#include <cstring>
#include <memory>
#include <string>
#include <unordered_map>
#include <vector>

namespace pw {

// --- java.util.Random and libGDX float math (source_java_random.gd, source_libgdx_math.gd)

static inline double f32(double p_x) { return (double)(float)p_x; }

template <typename T>
constexpr T ABS(T p_value) {
	return p_value < 0 ? -p_value : p_value;
}

struct JavaRandom {
	static constexpr uint64_t MULTIPLIER = 0x5DEECE66DULL;
	static constexpr uint64_t MASK_48 = (1ULL << 48) - 1;
	uint64_t seed = 0;
	// next_int(0): an assert in GDScript debug builds (release returns 0).
	int64_t zero_bounds = 0;

	explicit JavaRandom(int64_t p_seed = 0) { set_seed(p_seed); }
	void set_seed(int64_t p_seed) { seed = ((uint64_t)p_seed ^ MULTIPLIER) & MASK_48; }
	void advance() { seed = (seed * MULTIPLIER + 0xBULL) & MASK_48; }
	int64_t next_bits(int p_bits) {
		advance();
		return (int64_t)(seed >> (48 - p_bits));
	}
	int64_t next_int(int64_t p_bound) {
		if (p_bound < 0) {
			int64_t value = next_bits(32);
			return value >= 2147483648LL ? value - 4294967296LL : value;
		}
		if (p_bound == 0) {
			zero_bounds++;
		}
		if ((p_bound & -p_bound) == p_bound) {
			advance();
			return (p_bound * (int64_t)(seed >> 17)) >> 31;
		}
		while (true) {
			advance();
			int64_t bits = (int64_t)(seed >> 17);
			int64_t value = bits % p_bound;
			if (bits - value + (p_bound - 1) <= 2147483647LL) {
				return value;
			}
		}
	}
	int64_t next_int() { return next_int(-1); }
	bool next_boolean() { return next_bits(1) != 0; }
	int64_t state() const { return (int64_t)seed; }
};

Vector2 rotate_deg(const Vector2 &p_vector, double p_degrees);
double gdx_distance(const Vector2 &p_left, const Vector2 &p_right);

// --- Tile and route names: interned once per process, compared as ints.

int intern(const std::string &p_text);
const std::string &name_str(int p_id);
// The id of a literal, looked up once per call site.
#define NM(text) ([]() -> int { static const int id_ = ::pw::intern(text); return id_; }())

static inline const std::string &S(int p_id) { return name_str(p_id); }
static inline bool has(int p_id, const char *p_sub) { return S(p_id).find(p_sub) != std::string::npos; }
static inline bool has(int p_id, int p_sub) { return S(p_id).find(S(p_sub)) != std::string::npos; }
static inline bool begins(int p_id, const char *p_prefix) {
	const std::string &text = S(p_id);
	size_t length = strlen(p_prefix);
	return text.size() >= length && text.compare(0, length, p_prefix) == 0;
}
static inline String gs(int p_id) { return String::utf8(S(p_id).c_str()); }
int gid(const String &p_text);
std::string lower(const std::string &p_text);
std::string replace_all(const std::string &p_text, const std::string &p_from, const std::string &p_to);
std::vector<std::string> split(const std::string &p_text, const std::string &p_delimiter);

// --- Objects shared by reference, as GDScript's RefCounted tiles and routes.

template <typename T>
class P {
	T *p = nullptr;

public:
	P() {}
	P(T *p_object) :
			p(p_object) {
		if (p) {
			p->refs++;
		}
	}
	P(const P &p_other) :
			p(p_other.p) {
		if (p) {
			p->refs++;
		}
	}
	P(P &&p_other) noexcept :
			p(p_other.p) { p_other.p = nullptr; }
	~P() { release(); }
	P &operator=(const P &p_other) {
		if (p_other.p) {
			p_other.p->refs++;
		}
		release();
		p = p_other.p;
		return *this;
	}
	P &operator=(P &&p_other) noexcept {
		if (this != &p_other) {
			release();
			p = p_other.p;
			p_other.p = nullptr;
		}
		return *this;
	}
	void release() {
		if (p && --p->refs == 0) {
			memdelete(p);
		}
		p = nullptr;
	}
	T *operator->() const { return p; }
	T &operator*() const { return *p; }
	T *get() const { return p; }
	explicit operator bool() const { return p != nullptr; }
	bool operator==(const P &p_other) const { return p == p_other.p; }
	bool operator!=(const P &p_other) const { return p != p_other.p; }
};

struct Route {
	int32_t refs = 0;
	int name = 0;
	int64_t level = 0;
	Array stored; // stored_pokemon
	int64_t musics_index = 0;
	bool is_dungeon = false;
	bool dont_spawn = false;
};
typedef P<Route> RouteRef;

enum : uint16_t {
	F_COLOR = 1,
	F_SOLID = 2,
	F_LEDGE = 4,
	F_WATER = 8,
	F_GRASS = 16,
	F_CUTTABLE = 32,
	F_HEADBUTT = 64,
	F_TIDAL = 128,
	F_LAVA = 256,
	F_BOTTOM = 512,
};

// A tile's `items`: Dictionary of item name -> amount, in insertion order.
struct Items {
	std::vector<std::pair<std::string, int64_t>> list;
	void set(const std::string &p_key, int64_t p_value) {
		for (auto &entry : list) {
			if (entry.first == p_key) {
				entry.second = p_value;
				return;
			}
		}
		list.emplace_back(p_key, p_value);
	}
	// Dictionary ==: same pairs, any order.
	bool operator==(const Items &p_other) const;
	Dictionary to_dictionary() const;
};

struct Tile {
	int32_t refs = 0;
	int name = 0;
	int upper = 0;
	int biome = 0;
	int ledge_dir = 0;
	int shore_ocean = 0;
	int shore_tidal = 0;
	int has_item = 0;
	uint16_t flags = 0;
	Vector2i position;
	int64_t amount = 0;
	RouteRef route;
	// null as in SourceTile._items/_door_tiles until first asked for.
	std::unique_ptr<Items> items;
	std::unique_ptr<std::vector<Vector2i>> doors;

	bool is(uint16_t p_flag) const { return (flags & p_flag) != 0; }
	void set(uint16_t p_flag, bool p_on) { flags = p_on ? (flags | p_flag) : (flags & ~p_flag); }
	bool solid() const { return is(F_SOLID); }
	bool water() const { return is(F_WATER); }
	bool ledge() const { return is(F_LEDGE); }
	bool tidal() const { return is(F_TIDAL); }
	// The `items` and `door_tiles` getters: made on first use.
	Items &items_get() {
		if (!items) {
			items.reset(new Items);
		}
		return *items;
	}
	std::vector<Vector2i> &doors_get() {
		if (!doors) {
			doors.reset(new std::vector<Vector2i>);
		}
		return *doors;
	}
};
typedef P<Tile> TileRef;

// --- Dictionary semantics: insertion order, erase removes, re-adding appends.

template <typename K, typename V, typename H = HashMapHasherDefault, typename C = HashMapComparatorDefault<K>>
class OMap {
public:
	struct Entry {
		K key;
		V value;
		bool live = true;
	};
	std::vector<Entry> entries;
	AHashMap<K, uint32_t, H, C> index;
	uint32_t dead = 0;
	int iterating = 0;

	uint32_t size() const { return index.size(); }
	bool is_empty() const { return index.size() == 0; }
	bool has(const K &p_key) const { return index.has(p_key); }
	V *getp(const K &p_key) {
		uint32_t *at = index.getptr(p_key);
		return at ? &entries[*at].value : nullptr;
	}
	const V *getp(const K &p_key) const {
		const uint32_t *at = index.getptr(p_key);
		return at ? &entries[*at].value : nullptr;
	}
	V get(const K &p_key) const {
		const V *found = getp(p_key);
		return found ? *found : V();
	}
	void set(const K &p_key, const V &p_value) {
		uint32_t *at = index.getptr(p_key);
		if (at) {
			entries[*at].value = p_value;
			return;
		}
		if (iterating == 0 && dead > 1024 && dead * 2 > entries.size()) {
			compact();
		}
		index.insert(p_key, (uint32_t)entries.size());
		entries.push_back(Entry{ p_key, p_value, true });
	}
	bool erase(const K &p_key) {
		uint32_t *at = index.getptr(p_key);
		if (!at) {
			return false;
		}
		Entry &entry = entries[*at];
		entry.live = false;
		entry.value = V();
		index.erase(p_key);
		dead++;
		return true;
	}
	void clear() {
		entries.clear();
		index.clear();
		dead = 0;
	}
	void compact() {
		std::vector<Entry> kept;
		kept.reserve(index.size());
		index.clear();
		for (Entry &entry : entries) {
			if (entry.live) {
				index.insert(entry.key, (uint32_t)kept.size());
				kept.push_back(std::move(entry));
			}
		}
		entries.swap(kept);
		dead = 0;
	}
	// keys()/values(): copies, as GDScript's.
	std::vector<K> keys() const {
		std::vector<K> result;
		result.reserve(index.size());
		for (const Entry &entry : entries) {
			if (entry.live) {
				result.push_back(entry.key);
			}
		}
		return result;
	}
	std::vector<V> values() const {
		std::vector<V> result;
		result.reserve(index.size());
		for (const Entry &entry : entries) {
			if (entry.live) {
				result.push_back(entry.value);
			}
		}
		return result;
	}
	void merge(const OMap &p_other, bool p_overwrite = true) {
		for (const Entry &entry : p_other.entries) {
			if (entry.live && (p_overwrite || !has(entry.key))) {
				set(entry.key, entry.value);
			}
		}
	}
	// `for key in dict` as GDScript runs it: after the body, the entry that
	// follows the current key (Dictionary::next), so entries added meanwhile
	// are visited and erasing the current key ends the loop.
	template <typename F>
	void live_for(F p_body) {
		iterating++;
		uint32_t at = 0;
		while (at < entries.size() && !entries[at].live) {
			at++;
		}
		while (at < entries.size()) {
			K key = entries[at].key;
			p_body(key);
			uint32_t current = at;
			if (!entries[current].live || !(entries[current].key == key)) {
				const uint32_t *moved = index.getptr(key);
				if (!moved) {
					break;
				}
				current = *moved;
			}
			at = current + 1;
			while (at < entries.size() && !entries[at].live) {
				at++;
			}
		}
		iterating--;
	}
	// Live entries in order; the body must not add or remove keys.
	template <typename F>
	void each(F p_body) const {
		for (const Entry &entry : entries) {
			if (entry.live) {
				p_body(entry.key, entry.value);
			}
		}
	}
};

// A tiles_to_add value: a tile, an ocean cell (an int: index of a shared
// template, see SourceIslandGenerator.ocean_tiles), or `true` (cells of the
// mountain biome map nobody reads).
struct Cell {
	TileRef tile;
	int8_t ocean = -1;
	bool mark = false;
	Cell() {}
	Cell(const TileRef &p_tile) :
			tile(p_tile) {}
	bool is_int() const { return ocean >= 0; }
	bool is_null() const { return !tile && ocean < 0 && !mark; }
};
typedef OMap<Vector2i, Cell> TileMap;
typedef std::shared_ptr<TileMap> Layer;

struct PtrHasher {
	static _FORCE_INLINE_ uint32_t hash(const void *p_pointer) { return hash_one_uint64((uint64_t)p_pointer); }
};
typedef AHashMap<Vector2i, bool> PosSet;

// --- Data the GDScript side owns (one source of truth), asked once per key.

struct Traits {
	bool water = false;
	bool solid = false;
	bool grass = false;
	bool cuttable = false;
	bool headbutt = false;
	bool tidal = false;
	bool lava = false;
	Vector2i ledge;
};

class Data {
	Object *object = nullptr;
	AHashMap<uint64_t, Traits> traits_memo;
	std::unordered_map<int, std::vector<String>> allowed_memo;
	std::unordered_map<int, bool> dungeon_memo;
	HashMap<String, Dictionary> species_memo;
	std::unordered_map<std::string, std::vector<std::vector<int>>> layout_memo;

public:
	// [MATES, MATES_2, SOURCE_SPECIES_ALIASES, SOURCE_BASE_SPECIES_OVERRIDES]
	Array constants;
	Dictionary mates;
	Dictionary mates_2;
	int warnings = 0;

	explicit Data(Object *p_object);
	const Traits &traits(int p_source_base, int p_base, int p_upper);
	const std::vector<String> &allowed(int p_route_name);
	bool is_dungeon(int p_route_name);
	const Dictionary &species(const String &p_name);
	// SourceLayoutData.rows("GenIsland1", method, ordinal): -1 where null.
	const std::vector<std::vector<int>> &layout(const char *p_method, int p_ordinal);
};

// Specie.gen2Evos' java.util.HashMap order (String keys).
Array java_evolution_order(const Array &p_evolutions);

// --- The generator (SourceIslandGenerator), state as in GDScript.

struct Signature {
	int name = 0;
	int upper = 0;
	int has_item = 0;
	int64_t amount = 0;
	std::vector<Vector2i> doors;
	Items items;
	bool operator==(const Signature &p_other) const {
		return name == p_other.name && upper == p_other.upper && has_item == p_other.has_item && amount == p_other.amount && doors == p_other.doors && items == p_other.items;
	}
};

struct ValidationRecord {
	std::string kind;
	Vector2i origin;
	OMap<Vector2i, Signature> exterior;
	std::vector<std::pair<int, OMap<Vector2i, Signature>>> layers;
};

struct MazeNode {
	int64_t x = 0;
	int64_t y = 0;
	bool left_open = false;
	bool down_open = false;
	int64_t square_size = 0;
};

// SourceMaze's bool grid, maze[x][y].
struct Maze {
	int64_t width = 0;
	int64_t height = 0;
	std::vector<uint8_t> cells;
	Maze(int64_t p_width, int64_t p_height) :
			width(p_width), height(p_height), cells((size_t)(p_width * p_height)) {}
	bool get(int64_t p_x, int64_t p_y) const {
		ERR_FAIL_COND_V(p_x < 0 || p_y < 0 || p_x >= width || p_y >= height, false);
		return cells[p_x * height + p_y] != 0;
	}
	void set(int64_t p_x, int64_t p_y, bool p_value) {
		ERR_FAIL_COND(p_x < 0 || p_y < 0 || p_x >= width || p_y >= height);
		cells[p_x * height + p_y] = p_value;
	}
};

Maze maze_algo2(int64_t p_width, int64_t p_height, double p_complexity, double p_density, JavaRandom &p_random);
Maze maze_algo3(int64_t p_width, int64_t p_height, double p_complexity, double p_density, JavaRandom &p_random, std::vector<Vector2i> &r_start_locations);

// apply_blotch's `state` Dictionary.
struct BlotchState {
	int64_t done_oasis = 0;
	int64_t num_darms = 10;
	TileMap grass_tiles;
	OMap<Vector2i, bool> forest_maze_tiles;
	std::vector<Vector2i> deep_forest_maze_tiles;
	std::vector<Vector2i> fence_spawns;
	RouteRef beach_route;
	RouteRef beach_plateau_route;
	RouteRef beach_water_route;
	RouteRef deep_forest_route;
	int64_t is_maze = 0;
};

class Gen {
public:
	Data &data;
	Vector2i origin;
	int64_t radius = 0;
	JavaRandom random;
	JavaRandom global_random;
	JavaRandom forest_biome_random;
	JavaRandom pokemon_random;
	AHashMap<Vector2i, int64_t> no_ice_here;
	PosSet bottom_mountain_layer;
	TileMap mountain_tiles;
	std::vector<Vector2i> trapinch_spawns;
	std::vector<Vector2i> keystone_spawns;
	OMap<Vector2i, Dictionary> pokemon_to_add;
	Array interior_pokemon;
	Vector2i rand_offset;
	int64_t done_desert = 0;
	int64_t num_sand_pits = 0;
	int64_t unown_counter = 0;
	TileMap tiles_to_add;
	std::vector<Layer> interior_tiles_to_add;
	std::vector<TileRef> edges;
	std::vector<TileRef> ocean_tiles;
	OMap<Vector2i, bool> under_mountain;
	std::unordered_map<std::string, TileRef> stand_ins;
	TileMap *biome_tiles = nullptr;
	PosSet biome_read_cells;
	Vector2i area_bottom_left;
	Vector2i area_top_right;
	bool done_pkmn_mansion = false;
	bool done_pkmn_mansion_key = false;
	bool done_regi_dungeon = false;
	bool done_desert_ruins = false;
	std::vector<Rect2i> graveyard_fence_bounds;
	std::vector<std::string> already_used_dungeons;
	std::vector<ValidationRecord> validation_records;
	// Results of generate_complete.
	Array burrowed_pokemon;
	Array landmark_origins;
	// QA: stage lines (empty unless asked for).
	bool qa = false;
	std::vector<String> qa_lines;

	Gen(Data &p_data, Vector2i p_origin, int64_t p_radius, int64_t p_island_seed, int64_t p_game_seed, int64_t p_forest_seed, int64_t p_pokemon_seed);

	// Tiles (source_tile.gd).
	TileRef make(int p_name, Vector2i p_position, int p_upper = 0, bool p_color = false, const RouteRef &p_route = RouteRef(), bool p_refresh = true);
	void rewrite(Tile *p_tile, int p_name, int p_upper);
	void refresh(Tile *p_tile, int p_source_base);
	void set_names(Tile *p_tile, int p_name, int p_upper = 0);
	TileRef copy_at(Tile *p_tile);
	TileRef copy_at(Tile *p_tile, Vector2i p_position);
	void flip_door(Tile *p_tile);
	RouteRef route(int p_name, int64_t p_level);

	// tiles_to_add access (tile_at / peek_tile / _get_tile / _name_of).
	Tile *tile_at(Vector2i p_position) { return get_tile(tiles_to_add, p_position); }
	Tile *get_tile(TileMap &p_tiles, Vector2i p_position);
	Tile *peek_tile(Vector2i p_position);
	Tile *peek(const Cell *p_cell) const;
	Tile *as_tile(const Cell *p_cell);
	int name_of(const Cell &p_cell) const;
	void put(TileMap &p_tiles, Vector2i p_position, const TileRef &p_tile) { p_tiles.set(p_position, Cell(p_tile)); }

	// Generation (in source order).
	void generate_complete(const std::vector<std::string> &p_used_dungeons);
	void generate_surface(std::vector<TileRef> &r_desert_tiles, std::vector<TileRef> &r_deep_forest_tiles);
	void qa_stage(const char *p_name);
	String qa_sha256();
	void stand_in_under_mountain();
	std::vector<TileRef> grow_mountain_skeleton(Tile *p_origin_tile, TileMap &r_all_tiles, AHashMap<Tile *, std::pair<TileRef, int64_t>, PtrHasher> &r_tile_levels, TileMap &r_level_tiles, int64_t &r_current_level);
	void add_mountain_layer(TileMap &p_level_tiles, AHashMap<Tile *, std::pair<TileRef, int64_t>, PtrHasher> &p_tile_levels, TileMap &p_all_mountain_tiles, int64_t p_new_level, int p_tile_name, const RouteRef &p_route, bool p_ice_allowed);
	std::vector<TileRef> apply_blotch_mountain(const TileRef &p_origin_tile, int64_t p_maximum_distance);
	void smooth_mountain_levels(TileMap &p_all_tiles, AHashMap<Tile *, std::pair<TileRef, int64_t>, PtrHasher> &p_tile_levels);
	void assign_mountain_ledges(TileMap &p_all_tiles, AHashMap<Tile *, std::pair<TileRef, int64_t>, PtrHasher> &p_tile_levels);
	void apply_blotch(const char *p_type, const TileRef &p_origin_tile, int64_t p_maximum_distance, TileMap &p_tiles, int64_t p_is_maze, bool p_do_next, RouteRef p_route);
	TileRef leaf_blotch_tile(const std::string &p_type, Vector2i p_position, double p_distance, int64_t p_maximum_distance, Tile *p_origin_tile, const RouteRef &p_route);
	TileRef make_blotch_tile(const std::string &p_type, Tile *p_frontier, Vector2i p_edge, double p_distance, int64_t p_maximum_distance, Tile *p_origin_tile, const RouteRef &p_route, TileMap &p_tiles, BlotchState &p_state);
	void append_stored(Route *p_route, const std::vector<const char *> &p_names, int64_t p_base_level, int64_t p_jitter = 0);
	void spawn(Vector2i p_position, const String &p_name, int64_t p_level, const Dictionary &p_extra = Dictionary());
	Dictionary make_pokemon_record(const String &p_name, int64_t p_level, const Dictionary &p_extra = Dictionary());
	TileRef make_desert_tile(Vector2i p_edge, int64_t p_maximum_distance, const RouteRef &p_route, BlotchState &p_state);
	TileRef make_ruins_upper_tile(Vector2i p_edge, double p_distance, int64_t p_maximum_distance, const RouteRef &p_route, BlotchState &p_state);
	TileRef make_oasis_tile(Vector2i p_edge, double p_distance, int64_t p_maximum_distance, const RouteRef &p_route, BlotchState &p_state);
	TileRef make_island_tile(Vector2i p_edge, double p_distance, int64_t p_maximum_distance, const RouteRef &p_route, BlotchState &p_state);
	int64_t source_scaled_level(int64_t p_center_level, double p_distance, int64_t p_maximum_distance);
	Vector2i diagonal_pattern(Vector2i p_position, double p_scale);
	TileRef make_beach_tile(Vector2i p_edge, double p_distance, int64_t p_maximum_distance, const RouteRef &p_route, BlotchState &p_state);
	TileRef make_savanna_tile(Vector2i p_edge, const RouteRef &p_route);
	TileRef make_graveyard_tile(Vector2i p_edge, double p_distance, int64_t p_maximum_distance, const RouteRef &p_route, BlotchState &p_state);
	TileRef make_snow_tile(Vector2i p_edge, const RouteRef &p_route, TileMap &p_tiles);
	TileRef make_volcano_lava_tile(Tile *p_frontier, Vector2i p_edge, const RouteRef &p_route, TileMap &p_tiles);
	void normalize_bare_lava(Tile *p_tile);
	TileRef make_volcano_tile(Vector2i p_edge, const RouteRef &p_route);
	TileRef make_wooded_lake_tile(Vector2i p_edge, const RouteRef &p_route, BlotchState &p_state);
	TileRef make_green_mountain_tile(Vector2i p_edge, const RouteRef &p_route, BlotchState &p_state);
	Vector2 wavy_pattern(Vector2i p_position, double p_scale);
	void apply_forest_maze(TileMap &p_tiles, OMap<Vector2i, bool> &p_forest_maze_tiles, std::vector<Vector2i> &p_deep_forest_positions, BlotchState &p_state);
	void repair_maze_ledge(TileMap &p_tiles, Tile *p_tile, int64_t p_side);
	void place_graveyard_fences(TileMap &p_tiles, std::vector<Vector2i> &p_fence_spawns, const RouteRef &p_route);
	void style_graveyard_fence_group(TileMap &p_tiles, Vector2i p_bottom_left, Vector2i p_top_right);
	void adjust_fence_tile(Tile *p_tile, TileMap &p_tiles);
	void continue_blotch(const std::string &p_type, int64_t p_maximum_distance, int64_t p_new_size, std::vector<TileRef> &p_previous_tiles, TileMap &p_tiles, int64_t p_is_maze, bool p_do_next, RouteRef p_route, OMap<Vector2i, bool> &p_forest_maze_tiles);
	void ledgify(TileMap &p_tiles, TileMap &p_next_island_tiles, int p_tile_type, int p_replace_with, int p_biome, int p_null_type = 0);
	bool ledgify_replaces(TileMap &p_tiles, Vector2i p_position, int p_tile_type, int p_null_name);
	void ledgify_replace(TileMap &p_tiles, TileMap &p_next_island_tiles, Vector2i p_position, int p_replace_with, int p_biome);
	void ledgify_later_sweeps(TileMap &p_tiles, TileMap &p_next_island_tiles, int p_tile_type, int p_replace_with, int p_biome, int p_null_name, const std::vector<Vector2i> &p_changed);
	void neighbour_names(TileMap &p_tiles, Vector2i p_position, int p_null_name, int r_names[8]);
	void apply_source_rivers(const std::vector<TileRef> &p_desert_tiles);
	double source_river_product(Vector2i p_position, double p_scale, double p_ratio);
	bool river_contains(Vector2i p_position);
	void fill_source_ocean(Vector2i p_minimum, Vector2i p_maximum);

	// Landmarks.
	void place_source_landmarks(const std::vector<TileRef> &p_desert_tiles, const std::vector<TileRef> &p_deep_forest_tiles, std::vector<Rect2i> &r_hitboxes, Rect2i &r_mansion_box);
	bool rect_contains_mountain(const Rect2i &p_rect);
	void cleanup_and_place_deep_forest_landmarks(const std::vector<TileRef> &p_deep_forest_tiles, const std::vector<Rect2i> &p_hitboxes, Rect2i p_mansion_box);
	void repair_incomplete_large_tree(Tile *p_tile);
	void remove_blocking_rock(Tile *p_tile);
	bool any_solid(const Vector2i *p_positions, int p_count);
	void generate_oasis(Vector2i p_origin);
	std::vector<Vector2i> regi_exterior_positions(Vector2i p_origin);
	void generate_regi_dungeon(Vector2i p_origin);
	void generate_desert_ruins(Vector2i p_origin);
	void adjust_ruins_tile(Tile *p_tile, TileMap &p_layer);
	void generate_ruins_interior(Vector2i p_origin);
	TileMap generate_mansion(Vector2i p_origin);
	std::vector<bool> mansion_axis_pattern(int64_t p_length, int64_t p_forced_gap, int64_t p_level);
	void replace_small_mansion_wall_islands(TileMap &p_layer);
	bool is_mansion_wall(TileMap &p_layer, Vector2i p_position);
	void style_mansion_walls(TileMap &p_layer);
	bool solid_at(TileMap &p_layer, Vector2i p_position);
	void damage_mansion_walls(TileMap &p_layer);
	void place_mansion_shelves(TileMap &p_layer);
	void place_mansion_tables(TileMap &p_layer, Vector2i p_layout_origin);
	void connect_mansion_floors(std::vector<Layer> &p_interiors, Vector2i p_layout_origin);
	std::vector<Vector2i> mansion_dead_ends(TileMap &p_layer, const std::vector<Vector2i> &p_starts, bool p_strict);
	Vector2i mansion_statue_fallback_position(TileMap &p_layer, const std::vector<Vector2i> &p_blocked);
	std::vector<std::vector<TileRef>> mansion_door_candidates(TileMap &p_layer);
	void solve_mansion_doors(TileMap &p_layer, Tile *p_stairs_up, Tile *p_stairs_down, Tile *p_statue, Tile *p_previous_statue, std::vector<std::vector<TileRef>> &p_all_doors);
	void make_mewtwo_room(std::vector<Layer> &p_interiors, Vector2i p_stairs_down);
	void merge_exterior_preserving_mansion_key(TileMap &p_exterior);
	void merge_interior_layer(int p_index, const Layer &p_layer);
	bool is_path_between(TileMap &p_layer, Tile *p_a, Tile *p_b);
	void capture(const char *p_kind, Vector2i p_at, TileMap &p_exterior, const std::vector<std::pair<int, Layer>> &p_layers);
	Signature signature(Tile *p_tile);

	// After the landmarks.
	void postprocess_source_shores();
	void waterfallify(Tile *p_tile);
	bool coastify(Tile *p_tile);
	void postprocess_source_puddles();
	void spawn_source_overworld_pokemon();
	int64_t source_spawn_base_chance(int p_route_name);
	Dictionary source_random_evolutions(const String &p_start_name, int64_t p_start_level);
	bool source_is_base_species(const String &p_name);
	Array source_evolutions(const String &p_name);
	bool source_spawn_requirements_met(Tile *p_tile, const String &p_name);
	void add_required_regi_after_source_world(const std::vector<TileRef> &p_candidates);
	void complete_missing_landmarks();
	bool required_landmark_site(bool p_mansion, Vector2i &r_position, Rect2i &r_bounds);
	bool clearing_has_land_access(const Rect2i &p_rect);
	void prepare_landmark_clearing(const Rect2i &p_rect);

	// generation_validator.gd
	Dictionary validate();
};

// The whole world (see world_gen.h).
Dictionary generate_world(int64_t p_seed, int p_size_index, const TypedArray<String> &p_used_dungeons, Object *p_data, bool p_qa);

} // namespace pw
