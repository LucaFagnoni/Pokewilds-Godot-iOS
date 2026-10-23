#include "island.h"

#include "core/crypto/crypto_core.h"
#include "core/object/object.h"

#include <algorithm>
#include <deque>
#include <functional>
#include <queue>

namespace pw {

// --- libGDX math (source_libgdx_math.gd)

static constexpr int SIN_MASK = 16383;
static constexpr double DEG_TO_INDEX = 16384.0 / 360.0;

struct SinTable {
	float v[16384];
	SinTable() {
		for (int index = 0; index < 16384; index++) {
			double phase = f32(f32((double)index + 0.5) / 16384.0);
			v[index] = (float)Math::sin(phase * Math::PI * 2.0);
		}
		for (int degree = 0; degree < 360; degree += 90) {
			int64_t index = ((int64_t)f32((double)degree * f32(DEG_TO_INDEX))) & SIN_MASK;
			v[index] = (float)Math::sin(Math::deg_to_rad((double)degree));
		}
	}
};

static const SinTable &sin_table() {
	static SinTable table;
	return table;
}

Vector2 rotate_deg(const Vector2 &p_vector, double p_degrees) {
	const float *table = sin_table().v;
	double angle = f32(p_degrees);
	double deg_to_index = f32(DEG_TO_INDEX);
	Vector2 indices((float)(f32(angle + 90.0) * deg_to_index), (float)(angle * deg_to_index));
	double cosine = table[((int64_t)(double)indices.x) & SIN_MASK];
	double sine = table[((int64_t)(double)indices.y) & SIN_MASK];
	Vector2 cross((float)((double)p_vector.x * cosine), (float)((double)p_vector.y * sine));
	Vector2 along((float)((double)p_vector.x * sine), (float)((double)p_vector.y * cosine));
	return Vector2((float)((double)cross.x - (double)cross.y), (float)((double)along.x + (double)along.y));
}

double gdx_distance(const Vector2 &p_left, const Vector2 &p_right) {
	Vector2 delta((float)((double)p_right.x - (double)p_left.x), (float)((double)p_right.y - (double)p_left.y));
	Vector2 squared((float)((double)delta.x * (double)delta.x), (float)((double)delta.y * (double)delta.y));
	return f32(Math::sqrt(f32((double)squared.x + (double)squared.y)));
}

// --- Names

namespace {
class Names {
	Mutex mutex;
	std::unordered_map<std::string, int> ids;
	std::string *strings[1 << 16] = {};
	int count = 0;

public:
	Names() { intern(""); }
	int intern(const std::string &p_text) {
		MutexLock lock(mutex);
		auto found = ids.find(p_text);
		if (found != ids.end()) {
			return found->second;
		}
		CRASH_COND_MSG(count >= (1 << 16), "Too many distinct tile names.");
		strings[count] = new std::string(p_text);
		ids.emplace(p_text, count);
		return count++;
	}
	const std::string &str(int p_id) const { return *strings[p_id]; }
};

Names &names() {
	static Names table;
	return table;
}
} // namespace

int intern(const std::string &p_text) {
	return names().intern(p_text);
}

const std::string &name_str(int p_id) {
	return names().str(p_id);
}

int gid(const String &p_text) {
	return intern(std::string(p_text.utf8().get_data()));
}

std::string lower(const std::string &p_text) {
	std::string result = p_text;
	for (char &c : result) {
		if (c >= 'A' && c <= 'Z') {
			c = (char)(c - 'A' + 'a');
		}
	}
	return result;
}

std::string replace_all(const std::string &p_text, const std::string &p_from, const std::string &p_to) {
	if (p_from.empty()) {
		return p_text;
	}
	std::string result;
	size_t at = 0;
	while (true) {
		size_t found = p_text.find(p_from, at);
		if (found == std::string::npos) {
			result += p_text.substr(at);
			return result;
		}
		result += p_text.substr(at, found - at);
		result += p_to;
		at = found + p_from.size();
	}
}

// String.split(delimiter) with empty parts kept.
std::vector<std::string> split(const std::string &p_text, const std::string &p_delimiter) {
	std::vector<std::string> parts;
	size_t at = 0;
	while (true) {
		size_t found = p_text.find(p_delimiter, at);
		if (found == std::string::npos) {
			parts.push_back(p_text.substr(at));
			return parts;
		}
		parts.push_back(p_text.substr(at, found - at));
		at = found + p_delimiter.size();
	}
}

bool Items::operator==(const Items &p_other) const {
	if (list.size() != p_other.list.size()) {
		return false;
	}
	for (const auto &entry : list) {
		bool found = false;
		for (const auto &other : p_other.list) {
			if (other.first == entry.first) {
				found = other.second == entry.second;
				break;
			}
		}
		if (!found) {
			return false;
		}
	}
	return true;
}

Dictionary Items::to_dictionary() const {
	Dictionary result;
	for (const auto &entry : list) {
		result[String::utf8(entry.first.c_str())] = entry.second;
	}
	return result;
}

// --- Data from the GDScript side

Data::Data(Object *p_object) :
		object(p_object) {
	constants = object->call(SNAME("constants"));
	mates = constants[0];
	mates_2 = constants[1];
}

Traits Data::traits(int p_source_base, int p_base, int p_upper) {
	uint64_t key = ((uint64_t)p_source_base << 32) | ((uint64_t)p_base << 16) | (uint64_t)p_upper;
	const Traits *known = traits_memo.getptr(key);
	if (known) {
		return *known;
	}
	Array values = object->call(SNAME("traits"), gs(p_source_base), gs(p_base), gs(p_upper));
	Traits traits;
	traits.water = values[0];
	traits.solid = values[1];
	traits.grass = values[2];
	traits.cuttable = values[3];
	traits.headbutt = values[4];
	traits.tidal = values[5];
	traits.lava = values[6];
	traits.ledge = values[7];
	traits_memo.insert(key, traits);
	return traits;
}

const std::vector<String> &Data::allowed(int p_route_name) {
	auto found = allowed_memo.find(p_route_name);
	if (found != allowed_memo.end()) {
		return found->second;
	}
	Array names = object->call(SNAME("allowed_pokemon"), gs(p_route_name));
	std::vector<String> list;
	for (int index = 0; index < names.size(); index++) {
		list.push_back(names[index]);
	}
	return allowed_memo.emplace(p_route_name, list).first->second;
}

bool Data::is_dungeon(int p_route_name) {
	auto found = dungeon_memo.find(p_route_name);
	if (found != dungeon_memo.end()) {
		return found->second;
	}
	bool result = object->call(SNAME("is_dungeon"), gs(p_route_name));
	dungeon_memo.emplace(p_route_name, result);
	return result;
}

const Dictionary &Data::species(const String &p_name) {
	Dictionary *known = species_memo.getptr(p_name);
	if (known) {
		return *known;
	}
	Dictionary info = object->call(SNAME("species"), p_name);
	species_memo.insert(p_name, info);
	return *species_memo.getptr(p_name);
}

const std::vector<std::vector<int>> &Data::layout(const char *p_method, int p_ordinal) {
	std::string key = std::string(p_method) + ":" + std::to_string(p_ordinal);
	auto found = layout_memo.find(key);
	if (found != layout_memo.end()) {
		return found->second;
	}
	Array rows = object->call(SNAME("layout"), String(p_method), p_ordinal);
	std::vector<std::vector<int>> &result = layout_memo[key];
	for (int row_index = 0; row_index < rows.size(); row_index++) {
		Array row = rows[row_index];
		std::vector<int> ids;
		for (int column = 0; column < row.size(); column++) {
			Variant value = row[column];
			ids.push_back(value.get_type() == Variant::NIL ? -1 : gid(value));
		}
		result.push_back(ids);
	}
	return result;
}

// --- Tiles (source_tile.gd)

static const Vector2i SENTINEL(2147483647, 2147483647);

Gen::Gen(Data &p_data, Vector2i p_origin, int64_t p_radius, int64_t p_island_seed, int64_t p_game_seed, int64_t p_forest_seed, int64_t p_pokemon_seed) :
		data(p_data),
		origin(p_origin),
		radius(p_radius),
		random(p_island_seed),
		global_random(p_game_seed),
		forest_biome_random(p_forest_seed),
		pokemon_random(p_pokemon_seed) {
	// GenIsland1 draws randOffset from Game.rand first.
	int64_t x = global_random.next_int(100) * 16;
	int64_t y = global_random.next_int(100) * 16;
	rand_offset = Vector2i((int32_t)x, (int32_t)y);
	interior_tiles_to_add.resize(102);
}

RouteRef Gen::route(int p_name, int64_t p_level) {
	RouteRef result(memnew(Route));
	result->name = p_name;
	result->level = p_level;
	result->is_dungeon = data.is_dungeon(p_name);
	return result;
}

TileRef Gen::make(int p_name, Vector2i p_position, int p_upper, bool p_color, const RouteRef &p_route, bool p_refresh) {
	TileRef tile(memnew(Tile));
	tile->name = p_name;
	tile->upper = p_upper;
	tile->position = p_position;
	tile->set(F_COLOR, p_color);
	tile->route = p_route;
	rewrite(tile.get(), p_name, p_upper);
	if (p_refresh) {
		refresh(tile.get(), p_name);
	}
	return tile;
}

void Gen::rewrite(Tile *p_tile, int p_name, int p_upper) {
	if (p_upper != 0) {
		return;
	}
	if (p_name == NM("rock1")) {
		p_tile->name = NM("sand1");
		p_tile->upper = NM("rock1");
	} else if (p_name == NM("rock5")) {
		p_tile->name = NM("sand1");
		p_tile->upper = NM("rock5");
	} else if (p_name == NM("tree2")) {
		p_tile->name = NM("green1");
		p_tile->upper = NM("tree2");
	} else if (p_name == NM("tree4")) {
		p_tile->name = NM("snow1");
		p_tile->upper = NM("tree4");
	} else if (p_name == NM("bush1")) {
		p_tile->name = NM("green1");
		if (p_tile->is(F_COLOR)) {
			p_tile->upper = NM("bush2_color");
		}
	} else if (begins(p_name, "cactus") && !(p_name == NM("cactus7") || p_name == NM("cactus8") || p_name == NM("cactus9") || p_name == NM("cactus10"))) {
		p_tile->name = NM("desert6");
		p_tile->upper = p_name;
	} else if (p_name == NM("pedistal1") || p_name == NM("building1_fossilreviver1") || p_name == NM("interiorwall1") || has(p_name, "gravestone") || has(p_name, "sign_")) {
		p_tile->upper = p_name;
	}
}

void Gen::refresh(Tile *p_tile, int p_source_base) {
	int source = p_source_base == 0 ? p_tile->name : p_source_base;
	if (source == NM("bush1") && p_tile->name == NM("green1") && p_tile->upper == 0) {
		source = p_tile->name;
	}
	const Traits &traits = data.traits(source, p_tile->name, p_tile->upper);
	p_tile->set(F_WATER, traits.water);
	p_tile->set(F_SOLID, traits.solid);
	p_tile->set(F_GRASS, traits.grass);
	p_tile->set(F_CUTTABLE, traits.cuttable);
	p_tile->set(F_HEADBUTT, traits.headbutt);
	p_tile->set(F_TIDAL, traits.tidal);
	p_tile->set(F_LAVA, traits.lava);
	bool is_ledge = traits.ledge != Vector2i() || has(p_tile->upper, "ledges3");
	bool fence = p_tile->upper == NM("fence1") || p_tile->upper == NM("fence2");
	bool fence_ns = p_tile->upper == NM("fence1_NS") || p_tile->upper == NM("fence2_NS");
	if (fence) {
		is_ledge = true;
		p_tile->ledge_dir = NM("down");
	} else if (fence_ns) {
		is_ledge = true;
		p_tile->ledge_dir = NM("left");
	}
	p_tile->set(F_LEDGE, is_ledge);
	if (fence || fence_ns) {
	} else if (traits.ledge == Vector2i(0, -1)) {
		p_tile->ledge_dir = NM("up");
	} else if (traits.ledge == Vector2i(0, 1)) {
		p_tile->ledge_dir = NM("down");
	} else if (traits.ledge == Vector2i(-1, 0)) {
		p_tile->ledge_dir = NM("left");
	} else if (traits.ledge == Vector2i(1, 0)) {
		p_tile->ledge_dir = NM("right");
	} else {
		p_tile->ledge_dir = 0;
	}
	if (p_tile->upper == NM("pokeball1") && p_tile->has_item == 0) {
		p_tile->has_item = NM("POKE BALL");
		p_tile->amount = 1;
	} else if (p_tile->upper == NM("ultraball1") && p_tile->has_item == 0) {
		p_tile->has_item = NM("ultra ball");
		p_tile->amount = 1;
	} else if (p_tile->upper == NM("pokemon_mansion_key") && p_tile->has_item == 0) {
		p_tile->has_item = NM("secret key");
		p_tile->amount = 1;
	}
}

void Gen::set_names(Tile *p_tile, int p_name, int p_upper) {
	p_tile->name = p_name;
	p_tile->upper = p_upper;
	rewrite(p_tile, p_name, p_upper);
	refresh(p_tile, p_name);
}

TileRef Gen::copy_at(Tile *p_tile) {
	return copy_at(p_tile, p_tile->position);
}

TileRef Gen::copy_at(Tile *p_tile, Vector2i p_position) {
	TileRef result = make(p_tile->name, p_position, p_tile->upper, p_tile->is(F_COLOR), p_tile->route);
	result->biome = p_tile->biome;
	result->set(F_BOTTOM, p_tile->is(F_BOTTOM));
	result->shore_ocean = p_tile->shore_ocean;
	result->shore_tidal = p_tile->shore_tidal;
	result->has_item = p_tile->has_item;
	result->amount = p_tile->amount;
	if (p_tile->items) {
		result->items.reset(new Items(*p_tile->items));
	}
	if (p_tile->doors) {
		result->doors.reset(new std::vector<Vector2i>(*p_tile->doors));
	}
	return result;
}

void Gen::flip_door(Tile *p_tile) {
	std::vector<std::string> tokens = split(S(p_tile->name), "__");
	if (tokens.size() < 2) {
		return;
	}
	if (tokens[1] == "on") {
		p_tile->name = intern(tokens[0] + "__off");
		p_tile->set(F_SOLID, false);
	} else {
		p_tile->name = intern(tokens[0] + "__on");
		p_tile->set(F_SOLID, true);
	}
}

Tile *Gen::get_tile(TileMap &p_tiles, Vector2i p_position) {
	Cell *cell = p_tiles.getp(p_position);
	if (!cell) {
		return nullptr;
	}
	if (cell->is_int()) {
		TileRef made = copy_at(ocean_tiles[cell->ocean].get(), p_position);
		cell->ocean = -1;
		cell->tile = made;
		return made.get();
	}
	if (cell->mark) {
		data.warnings++;
		return nullptr;
	}
	return cell->tile.get();
}

Tile *Gen::peek(const Cell *p_cell) const {
	if (!p_cell) {
		return nullptr;
	}
	if (p_cell->is_int()) {
		return ocean_tiles[p_cell->ocean].get();
	}
	return p_cell->tile.get();
}

Tile *Gen::peek_tile(Vector2i p_position) {
	return peek(tiles_to_add.getp(p_position));
}

// `map.get(position) as SourceTile`: an ocean int or `true` is no tile
// (an error in GDScript debug builds, counted).
Tile *Gen::as_tile(const Cell *p_cell) {
	if (!p_cell) {
		return nullptr;
	}
	if (p_cell->is_int() || p_cell->mark) {
		data.warnings++;
		return nullptr;
	}
	return p_cell->tile.get();
}

int Gen::name_of(const Cell &p_cell) const {
	return p_cell.is_int() ? ocean_tiles[p_cell.ocean]->name : p_cell.tile->name;
}

// --- Pokemon records

Dictionary Gen::make_pokemon_record(const String &p_name, int64_t p_level, const Dictionary &p_extra) {
	Dictionary record;
	record["name"] = p_name;
	record["level"] = p_level;
	record["shiny"] = pokemon_random.next_int(256) == 0;
	String gender_ratio = data.species(p_name).get("gender_ratio", "GENDER_UNKNOWN");
	if (gender_ratio == "GENDER_UNKNOWN") {
		record["gender"] = "unknown";
	} else {
		int64_t threshold = 0;
		if (gender_ratio == "GENDER_F0") {
			threshold = 0;
		} else if (gender_ratio == "GENDER_F12_5") {
			threshold = 125;
		} else if (gender_ratio == "GENDER_F25") {
			threshold = 250;
		} else if (gender_ratio == "GENDER_F50") {
			threshold = 500;
		} else if (gender_ratio == "GENDER_F75") {
			threshold = 750;
		} else if (gender_ratio == "GENDER_F100") {
			threshold = 1000;
		}
		record["gender"] = pokemon_random.next_int(1000) < threshold ? "female" : "male";
	}
	record.merge(p_extra, true);
	return record;
}

static Dictionary crystal() {
	Dictionary extra;
	extra["generation"] = "CRYSTAL";
	return extra;
}

void Gen::spawn(Vector2i p_position, const String &p_name, int64_t p_level, const Dictionary &p_extra) {
	Dictionary record = make_pokemon_record(p_name, p_level, p_extra);
	record["position"] = p_position;
	pokemon_to_add.set(p_position, record);
}

void Gen::append_stored(Route *p_route, const std::vector<const char *> &p_names, int64_t p_base_level, int64_t p_jitter) {
	String selected = p_names[random.next_int((int64_t)p_names.size())];
	int64_t level = p_base_level + (p_jitter > 0 ? random.next_int(p_jitter) : 0);
	p_route->stored.push_back(make_pokemon_record(selected, level, crystal()));
}

// --- QA stage hashes (_qa_surface_stage / qa_surface_sha256)

String Gen::qa_sha256() {
	std::vector<Vector2i> positions = tiles_to_add.keys();
	std::sort(positions.begin(), positions.end(), [](const Vector2i &a, const Vector2i &b) {
		return a.x < b.x || (a.x == b.x && a.y < b.y);
	});
	CryptoCore::SHA256Context context;
	context.start();
	std::string line;
	for (const Vector2i &position : positions) {
		Tile *tile = peek_tile(position);
		std::string route_name;
		int64_t route_level = 0;
		if (tile->route) {
			route_name = S(tile->route->name);
			route_level = tile->route->level;
		}
		line = std::to_string(position.x) + "," + std::to_string(position.y) + "|" + S(tile->name) + "|" + S(tile->upper) + "|" + route_name + "|" + std::to_string(route_level) + "|" + S(tile->biome) + "|" + std::to_string((int)tile->solid()) + "|" + std::to_string((int)tile->water()) + "|" + std::to_string((int)tile->ledge()) + "\n";
		context.update((const uint8_t *)line.data(), line.size());
	}
	unsigned char hash[32];
	context.finish(hash);
	return String::hex_encode_buffer(hash, 32);
}

void Gen::qa_stage(const char *p_name) {
	if (!qa) {
		return;
	}
	qa_lines.push_back(vformat("STAGE name=%s tiles=%d pokemon=%d sha256=%s rng=%d,%d,%d", p_name, (int64_t)tiles_to_add.size(), (int64_t)pokemon_to_add.size(), qa_sha256(), random.state(), global_random.state(), pokemon_random.state()));
}

// --- generate_surface

void Gen::stand_in_under_mountain() {
	under_mountain.each([&](const Vector2i &p_position, const bool &) {
		Cell *cell = tiles_to_add.getp(p_position);
		if (!cell || !cell->tile) {
			return;
		}
		Tile *tile = cell->tile.get();
		if (tile->position == SENTINEL || tile->name == NM("ledge_grass_down") || tile->name == NM("ledge_ramp_down")) {
			return;
		}
		std::string key = S(tile->name) + "\n" + S(tile->upper) + "\n" + std::to_string((int)tile->solid() + 2 * (int)tile->ledge());
		auto found = stand_ins.find(key);
		TileRef stand_in;
		if (found == stand_ins.end()) {
			stand_in = make(tile->name, SENTINEL, tile->upper, false, RouteRef(), false);
			stand_in->name = tile->name;
			stand_in->upper = tile->upper;
			stand_in->set(F_SOLID, tile->solid());
			stand_in->set(F_LEDGE, tile->ledge());
			stand_ins.emplace(key, stand_in);
		} else {
			stand_in = found->second;
		}
		cell->tile = stand_in;
	});
}

void Gen::generate_surface(std::vector<TileRef> &r_desert_tiles, std::vector<TileRef> &r_deep_forest_tiles) {
	tiles_to_add.clear();
	pokemon_to_add.clear();
	edges.clear();
	keystone_spawns.clear();
	trapinch_spawns.clear();
	bottom_mountain_layer.clear();
	mountain_tiles.clear();
	done_desert = 0;
	num_sand_pits = 0;
	int64_t maximum_distance = radius;
	TileRef origin_tile = make(NM("sand1"), origin);
	put(tiles_to_add, origin_tile->position, origin_tile);
	std::vector<TileRef> endpoints = apply_blotch_mountain(origin_tile, maximum_distance);
	mountain_tiles.each([&](const Vector2i &, const Cell &p_cell) {
		Vector2i position = p_cell.tile->position;
		if (!bottom_mountain_layer.has(position)) {
			under_mountain.set(position, true);
		}
	});
	for (TileRef &tile : endpoints) {
		if (done_desert == 1) {
			apply_blotch("desert", tile, maximum_distance / 18 + maximum_distance / 4, tiles_to_add, 1, true, route(NM("desert1"), 40));
		} else {
			done_desert += 1;
			apply_blotch("island", tile, maximum_distance / 15, tiles_to_add, 1, true, route(NM("forest1"), 40));
		}
	}
	// The overlay below replaces every stand-in.
	under_mountain.clear();
	stand_ins.clear();
	for (Cell &cell : mountain_tiles.values()) {
		Tile *tile = cell.tile.get();
		Tile *existing = as_tile(tiles_to_add.getp(tile->position));
		if (existing && existing->name != NM("water2") && bottom_mountain_layer.has(tile->position)) {
			continue;
		}
		put(tiles_to_add, tile->position, cell.tile);
	}
	for (const Vector2i &position : mountain_tiles.keys()) {
		pokemon_to_add.erase(position);
	}
	qa_stage("mountain_overlay");
	std::vector<TileRef> forest_tiles;
	Vector2i maximum_position = origin;
	Vector2i minimum_position = origin;
	tiles_to_add.each([&](const Vector2i &, const Cell &p_cell) {
		const TileRef &tile = p_cell.tile;
		maximum_position.x = MAX(maximum_position.x, tile->position.x);
		maximum_position.y = MAX(maximum_position.y, tile->position.y);
		minimum_position.x = MIN(minimum_position.x, tile->position.x);
		minimum_position.y = MIN(minimum_position.y, tile->position.y);
		if (has(tile->name, "desert")) {
			r_desert_tiles.push_back(tile);
		} else if (tile->biome == NM("deep_forest")) {
			r_deep_forest_tiles.push_back(tile);
		} else if (tile->route && tile->route->name == NM("forest1")) {
			forest_tiles.push_back(tile);
		}
	});
	int64_t place_number = random.next_int(2) + 2;
	int64_t tries = 20;
	while (!r_deep_forest_tiles.empty() && !forest_tiles.empty()) {
		TileRef patch_origin = forest_tiles[random.next_int((int64_t)forest_tiles.size())];
		bool is_forest = patch_origin->route && patch_origin->route->name == NM("forest1");
		bool near_water = false;
		Vector2 patch_vector(patch_origin->position);
		for (const auto &entry : tiles_to_add.entries) {
			if (entry.live && has(entry.value.tile->name, "water") && (double)Vector2(entry.value.tile->position).distance_squared_to(patch_vector) < 57600.0) {
				near_water = true;
				break;
			}
		}
		// forest_tiles keeps the pre-overlay tiles: the current one is read.
		Tile *current_patch = as_tile(tiles_to_add.getp(patch_origin->position));
		if ((current_patch && current_patch->biome == NM("savanna")) || !is_forest || near_water) {
			tries -= 1;
			if (tries > 0) {
				continue;
			}
			break;
		}
		TileMap new_tiles;
		apply_blotch("savanna1", patch_origin, 800, new_tiles, 0, false, route(NM("savanna2"), 22));
		new_tiles.each([&](const Vector2i &p_position, const Cell &p_cell) {
			if (!mountain_tiles.has(p_position)) {
				tiles_to_add.set(p_position, p_cell);
			}
		});
		qa_stage("savanna");
		place_number -= 1;
		if (place_number <= 0) {
			break;
		}
	}
	place_number = random.next_int(2) + 2;
	tries = 20;
	while (!r_deep_forest_tiles.empty()) {
		TileRef patch_origin = r_deep_forest_tiles[random.next_int((int64_t)r_deep_forest_tiles.size())];
		if (patch_origin->biome == NM("graveyard") || mountain_tiles.has(patch_origin->position)) {
			tries -= 1;
			if (tries > 0) {
				continue;
			}
			break;
		}
		TileMap new_tiles;
		apply_blotch("graveyard1", patch_origin, 300, new_tiles, 0, false, route(NM("graveyard1"), 22));
		new_tiles.each([&](const Vector2i &p_position, const Cell &p_cell) {
			if (!mountain_tiles.has(p_position)) {
				tiles_to_add.set(p_position, p_cell);
			}
		});
		qa_stage("graveyard");
		place_number -= 1;
		if (place_number <= 0) {
			break;
		}
	}
	if (!keystone_spawns.empty()) {
		Vector2i position = keystone_spawns[random.next_int((int64_t)keystone_spawns.size())];
		Tile *old_tile = as_tile(tiles_to_add.getp(position));
		TileRef keystone = make(NM("green12"), position, NM("odd_keystone2"), true, old_tile ? old_tile->route : RouteRef());
		keystone->biome = NM("graveyard");
		put(tiles_to_add, position, keystone);
	}
	apply_source_rivers(r_desert_tiles);
	qa_stage("rivers");
	fill_source_ocean(minimum_position, maximum_position);
	qa_stage("ocean");
	ledgify(tiles_to_add, tiles_to_add, NM("mountain4"), NM("sand4"), NM("beach"));
	qa_stage("before_stalagmites");
	tiles_to_add.each([&](const Vector2i &, const Cell &p_cell) {
		if (p_cell.is_int()) {
			return;
		}
		Tile *tile = p_cell.tile.get();
		if (tile->upper != NM("stalagmite1")) {
			return;
		}
		set_names(tile, NM("stalagmite1"));
		if (random.next_int(10) == 0) {
			set_names(tile, tile->name, NM("tree6"));
		} else if (random.next_int(10) == 0) {
			set_names(tile, tile->name, NM("rock1"));
		} else if (random.next_int(10) == 0) {
			set_names(tile, tile->name, NM("rock1_color"));
		}
	});
	ledgify(tiles_to_add, tiles_to_add, NM("stalagmite1"), NM("mountain4"), NM("beach"));
	for (TileRef &tile : r_desert_tiles) {
		pokemon_to_add.erase(tile->position);
	}
	// Later river/ledge/coast passes can touch graveyard perimeter cells.
	for (const Rect2i &fence_rect : graveyard_fence_bounds) {
		style_graveyard_fence_group(tiles_to_add, fence_rect.position, fence_rect.position + fence_rect.size);
	}
	qa_stage("surface_done");
}

// --- The mountain (GenIsland1.ApplyBlotchMountain)

typedef FlatMap<Tile *, std::pair<TileRef, int64_t>, PtrHasher> LevelMap;

static void set_level(LevelMap &p_levels, const TileRef &p_tile, int64_t p_level) {
	std::pair<TileRef, int64_t> *found = p_levels.getptr(p_tile.get());
	if (found) {
		found->second = p_level;
	} else {
		p_levels.insert(p_tile.get(), std::make_pair(p_tile, p_level));
	}
}

static const Vector2i NEIGHBOURS_8[8] = {
	Vector2i(16, 0), Vector2i(-16, 0), Vector2i(0, 16), Vector2i(0, -16),
	Vector2i(16, 16), Vector2i(-16, 16), Vector2i(-16, -16), Vector2i(16, -16)
};

void Gen::add_mountain_layer(TileMap &p_level_tiles, LevelMap &p_tile_levels, TileMap &p_all_mountain_tiles, int64_t p_new_level, int p_tile_name, const RouteRef &p_route, bool p_ice_allowed) {
	for (Cell &cell : p_level_tiles.values()) {
		Tile *tile = cell.tile.get();
		for (const Vector2i &offset : NEIGHBOURS_8) {
			Vector2i position = tile->position + offset;
			if (p_all_mountain_tiles.has(position)) {
				continue;
			}
			TileRef next_tile = make(p_tile_name, position, 0, true, p_route);
			next_tile->biome = NM("mountain");
			put(p_level_tiles, position, next_tile);
			set_level(p_tile_levels, next_tile, p_new_level);
			put(p_all_mountain_tiles, position, next_tile);
		}
		p_level_tiles.erase(tile->position);
		if (!p_ice_allowed) {
			int64_t *count = no_ice_here.getptr(tile->position);
			if (count) {
				*count += 1;
			} else {
				no_ice_here.insert(tile->position, 1);
			}
		}
	}
}

struct Walker {
	Vector2 direction;
	Vector2i origin;
	int64_t distance = 0;
};

std::vector<TileRef> Gen::grow_mountain_skeleton(Tile *p_origin_tile, TileMap &r_all_tiles, LevelMap &r_tile_levels, TileMap &r_level_tiles, int64_t &r_current_level) {
	TileRef origin_tile(p_origin_tile);
	FlatMap<Tile *, Walker, PtrHasher> walkers;
	TileRef copy_tile = copy_at(p_origin_tile);
	std::vector<TileRef> edge_tiles;
	edge_tiles.push_back(origin_tile);
	edge_tiles.push_back(copy_tile);
	int64_t direction_x = random.next_int(200) - 100;
	int64_t direction_y = random.next_int(200) - 100;
	Vector2 direction_1((float)(double)direction_x, (float)(double)direction_y);
	Vector2 direction_2 = rotate_deg(direction_1, 180.0);
	walkers.insert(origin_tile.get(), Walker{ direction_1, origin_tile->position, radius });
	walkers.insert(copy_tile.get(), Walker{ direction_2, origin_tile->position, radius });
	TileRef copy_tile_2 = copy_at(p_origin_tile);
	TileRef copy_tile_3 = copy_at(p_origin_tile);
	edge_tiles.push_back(copy_tile_2);
	edge_tiles.push_back(copy_tile_3);
	int64_t short_distance = (int64_t)(2.0 * (double)ABS(radius) / 8.0);
	walkers.insert(copy_tile_2.get(), Walker{ rotate_deg(direction_1, 90.0), origin_tile->position, short_distance });
	walkers.insert(copy_tile_3.get(), Walker{ rotate_deg(direction_2, 90.0), origin_tile->position, short_distance });
	std::vector<TileRef> endpoints;
	no_ice_here.clear();
	int64_t current_level = 0;
	int64_t new_level = 0;
	int64_t number_of_layers = 0;
	static const int64_t possible_levels[5] = { 0, 0, -1, -1, -1 };
	// {origin.position: origin, copy.position: copy}: one key, the copy.
	put(r_level_tiles, origin_tile->position, origin_tile);
	put(r_level_tiles, copy_tile->position, copy_tile);
	set_level(r_tile_levels, origin_tile, current_level);
	set_level(r_tile_levels, copy_tile, current_level);
	RouteRef mountain_route = route(NM("mountain1"), 33);
	RouteRef snow_route = route(NM("snow1"), 44);
	while (!edge_tiles.empty() || (double)current_level > -Math::ceil((double)(radius / 6000)) || number_of_layers < 13) {
		std::vector<TileRef> round;
		round.swap(edge_tiles);
		for (TileRef &tile : round) {
			Walker walker = walkers[tile.get()];
			Vector2 current_direction = walker.direction;
			Vector2 tile_origin(walker.origin);
			double distance = gdx_distance(Vector2(tile->position), tile_origin);
			int64_t maximum_distance = walker.distance;
			int64_t put_tile = random.next_int(maximum_distance + 1) + (int64_t)distance - maximum_distance / 32;
			if (put_tile < maximum_distance) {
				int64_t first = random.next_int(ABS((int64_t)(double)current_direction.x) + 1);
				int64_t second = random.next_int(ABS((int64_t)(double)current_direction.y) + 1);
				put_tile = first + second;
				Vector2 new_direction;
				if ((double)put_tile < f32(Math::abs((double)current_direction.y) + 2.0)) {
					new_direction.y = current_direction.y < 0.0f ? -1.0f : 1.0f;
				} else {
					new_direction.x = current_direction.x < 0.0f ? -1.0f : 1.0f;
				}
				Vector2i next_position = tile->position + Vector2i((int32_t)(16.0 * (double)new_direction.x), (int32_t)(16.0 * (double)new_direction.y));
				TileRef next_tile = make(NM("mountain1"), next_position, 0, true, mountain_route);
				put(r_all_tiles, next_position, next_tile);
				edge_tiles.push_back(next_tile);
				walkers.insert(next_tile.get(), Walker{ current_direction, walker.origin, maximum_distance });
				put(r_level_tiles, next_position, next_tile);
				set_level(r_tile_levels, next_tile, new_level);
				double combined_distance = f32((double)(radius + maximum_distance));
				double branch_scale = f32(combined_distance / 350.0);
				double branch_ratio = f32(4.0 / branch_scale);
				int64_t branch_bound = (int64_t)Math::ceil(f32(1.0 / branch_ratio));
				if (random.next_int(branch_bound) == 1) {
					int64_t degrees = random.next_int(80) + 10;
					double remaining_distance = f32(f32((double)maximum_distance) - distance);
					int64_t branch_distance = (int64_t)f32(f32(Math::abs(remaining_distance)) / 8.0);
					Vector2 branch_direction = rotate_deg(current_direction, (double)degrees);
					next_tile = make(NM("mountain1"), tile->position, 0, true, mountain_route);
					edge_tiles.push_back(next_tile);
					walkers.insert(next_tile.get(), Walker{ branch_direction, tile->position, branch_distance });
					branch_direction = rotate_deg(current_direction, (double)(-degrees));
					next_tile = make(NM("mountain1"), tile->position, 0, true, mountain_route);
					edge_tiles.push_back(next_tile);
					walkers.insert(next_tile.get(), Walker{ branch_direction, tile->position, branch_distance });
				}
			} else if (distance > 100.0) {
				endpoints.push_back(tile);
			}
			walkers.erase(tile.get());
		}
		int64_t layer_bound = (int64_t)Math::ceil(1.0 / (1.0 / ((double)radius / 1000.0)));
		if (random.next_int(layer_bound) != 1) {
			continue;
		}
		if (number_of_layers < 10) {
			new_level = current_level + possible_levels[random.next_int(5)];
		} else if (number_of_layers >= radius / 1800) {
			new_level -= 1;
		}
		add_mountain_layer(r_level_tiles, r_tile_levels, r_all_tiles, new_level, new_level <= -1 ? NM("mountain3") : NM("snow1"), new_level <= -1 ? mountain_route : snow_route, number_of_layers >= 10 && number_of_layers < radius / 1800);
		current_level = new_level;
		number_of_layers += 1;
	}
	while (number_of_layers <= radius / 1800) {
		add_mountain_layer(r_level_tiles, r_tile_levels, r_all_tiles, current_level, current_level <= -1 ? NM("mountain3") : NM("snow1"), current_level <= -1 ? mountain_route : snow_route, number_of_layers >= 10 && number_of_layers <= radius / 1800);
		number_of_layers += 1;
	}
	add_mountain_layer(r_level_tiles, r_tile_levels, r_all_tiles, current_level - 1, NM("mountain3"), mountain_route, false);
	add_mountain_layer(r_level_tiles, r_tile_levels, r_all_tiles, current_level - 2, NM("mountain3"), mountain_route, false);
	r_current_level = current_level;
	return endpoints;
}

static const int64_t INFINITE_LEVEL = 2147483647;

namespace {
// _mountain_level_graph: one level slot per distinct tile object.
struct LevelGraph {
	std::vector<int32_t> order;
	std::vector<int32_t> neighbours;
	std::vector<int64_t> levels;
	std::vector<TileRef> tiles;
};
} // namespace

static LevelGraph mountain_level_graph(TileMap &p_all_tiles, LevelMap &p_tile_levels) {
	static const Vector2i offsets[8] = {
		Vector2i(-16, 0), Vector2i(16, 0), Vector2i(0, -16), Vector2i(0, 16),
		Vector2i(-16, 16), Vector2i(16, 16), Vector2i(-16, -16), Vector2i(16, -16)
	};
	LevelGraph graph;
	std::vector<Cell> values = p_all_tiles.values();
	FlatMap<Tile *, int32_t, PtrHasher> slot_by_id;
	graph.order.resize(values.size());
	for (size_t index = 0; index < values.size(); index++) {
		Tile *tile = values[index].tile.get();
		int32_t *known = slot_by_id.getptr(tile);
		int32_t slot;
		if (known) {
			slot = *known;
		} else {
			slot = (int32_t)graph.tiles.size();
			slot_by_id.insert(tile, slot);
			graph.tiles.push_back(values[index].tile);
			std::pair<TileRef, int64_t> *level = p_tile_levels.getptr(tile);
			graph.levels.push_back(level ? level->second : INFINITE_LEVEL);
		}
		graph.order[index] = slot;
	}
	graph.neighbours.resize(values.size() * 8);
	for (size_t index = 0; index < values.size(); index++) {
		Vector2i position = values[index].tile->position;
		for (int k = 0; k < 8; k++) {
			const Cell *neighbour = p_all_tiles.getp(position + offsets[k]);
			graph.neighbours[index * 8 + k] = neighbour ? *slot_by_id.getptr(neighbour->tile.get()) : -1;
		}
	}
	return graph;
}

void Gen::smooth_mountain_levels(TileMap &p_all_tiles, LevelMap &p_tile_levels) {
	LevelGraph graph = mountain_level_graph(p_all_tiles, p_tile_levels);
	std::vector<uint8_t> changed(graph.levels.size());
	size_t count = graph.order.size();
	bool done = false;
	while (!done) {
		done = true;
		for (size_t index = 0; index < count; index++) {
			int32_t slot = graph.order[index];
			int64_t level = graph.levels[slot];
			const int32_t *n = &graph.neighbours[index * 8];
			int64_t left = n[0] < 0 ? INFINITE_LEVEL : graph.levels[n[0]];
			int64_t right = n[1] < 0 ? INFINITE_LEVEL : graph.levels[n[1]];
			int64_t bottom = n[2] < 0 ? INFINITE_LEVEL : graph.levels[n[2]];
			int64_t top = n[3] < 0 ? INFINITE_LEVEL : graph.levels[n[3]];
			int64_t top_left = n[4] < 0 ? INFINITE_LEVEL : graph.levels[n[4]];
			int64_t top_right = n[5] < 0 ? INFINITE_LEVEL : graph.levels[n[5]];
			int64_t bottom_left = n[6] < 0 ? INFINITE_LEVEL : graph.levels[n[6]];
			int64_t bottom_right = n[7] < 0 ? INFINITE_LEVEL : graph.levels[n[7]];
			int64_t below = level - 1;
			bool lower = left < below || right < below || bottom < below || top < below || top_right < below || top_left < below || bottom_left < below || bottom_right < below;
			if (!lower) {
				lower = (left <= below && right <= below) || (top <= below && bottom <= below) || (top <= below && left <= below && bottom_right <= below) || (top <= below && right <= below && bottom_left <= below) || (bottom <= below && right <= below && top_left <= below) || (bottom <= below && left <= below && top_right <= below) || (bottom == level && left <= below && bottom_right <= below) || (bottom == level && right <= below && bottom_left <= below) || (top == level && left <= below && top_right <= below) || (top == level && right <= below && top_left <= below) || (right == level && top <= below && bottom_right <= below) || (right == level && bottom <= below && top_right <= below) || (left == level && bottom <= below && top_left <= below) || (left == level && top <= below && bottom_left <= below);
			}
			if (lower) {
				graph.levels[slot] = below;
				changed[slot] = 1;
				done = false;
			}
		}
	}
	for (size_t slot = 0; slot < graph.levels.size(); slot++) {
		if (changed[slot]) {
			set_level(p_tile_levels, graph.tiles[slot], graph.levels[slot]);
		}
	}
}

void Gen::assign_mountain_ledges(TileMap &p_all_tiles, LevelMap &p_tile_levels) {
	LevelGraph graph = mountain_level_graph(p_all_tiles, p_tile_levels);
	for (size_t index = 0; index < graph.order.size(); index++) {
		Tile *tile = graph.tiles[graph.order[index]].get();
		std::pair<TileRef, int64_t> *known = p_tile_levels.getptr(tile);
		if (!known) {
			data.warnings++;
			continue;
		}
		int64_t level = known->second;
		const int32_t *n = &graph.neighbours[index * 8];
		int64_t left = n[0] < 0 ? INFINITE_LEVEL : graph.levels[n[0]];
		int64_t right = n[1] < 0 ? INFINITE_LEVEL : graph.levels[n[1]];
		int64_t bottom = n[2] < 0 ? INFINITE_LEVEL : graph.levels[n[2]];
		int64_t top = n[3] < 0 ? INFINITE_LEVEL : graph.levels[n[3]];
		int64_t top_left = n[4] < 0 ? INFINITE_LEVEL : graph.levels[n[4]];
		int64_t top_right = n[5] < 0 ? INFINITE_LEVEL : graph.levels[n[5]];
		int64_t bottom_left = n[6] < 0 ? INFINITE_LEVEL : graph.levels[n[6]];
		int64_t bottom_right = n[7] < 0 ? INFINITE_LEVEL : graph.levels[n[7]];
		const char *suffix = "";
		if (left == level && bottom == level - 1 && right == level) {
			suffix = "N";
		} else if (top == level && right == level && bottom == level - 1 && left == level - 1) {
			suffix = "NE";
		} else if (top == level && left == level - 1 && bottom == level) {
			suffix = "E";
		} else if (top == level - 1 && left == level - 1 && right == level && bottom == level) {
			suffix = "SE";
		} else if (top == level - 1 && left == level && right == level) {
			suffix = "S";
		} else if (top == level - 1 && bottom == level && left == level && right == level - 1) {
			suffix = "SW";
		} else if (top == level && bottom == level && right == level - 1) {
			suffix = "W";
		} else if (top == level && left == level && bottom == level - 1 && right == level - 1) {
			suffix = "NW";
		} else if (bottom_right == level - 1 && bottom == level && right == level) {
			suffix = "NW_inner";
		} else if (bottom_left == level - 1 && bottom == level && left == level) {
			suffix = "NE_inner";
		} else if (top_right == level - 1 && top == level && right == level) {
			suffix = "SW_inner";
		} else if (top_left == level - 1 && top == level && left == level) {
			suffix = "SE_inner";
		}
		if (suffix[0] != 0) {
			set_names(tile, tile->name, intern(std::string("ledges3_") + suffix));
		}
	}
}

std::vector<TileRef> Gen::apply_blotch_mountain(const TileRef &p_origin_tile, int64_t p_maximum_distance) {
	// grow_mountain_skeleton makes `mountain_tiles` its map of all tiles.
	TileMap &all_mountain_tiles = mountain_tiles;
	LevelMap tile_levels;
	TileMap level_tiles;
	int64_t skeleton_level = 0;
	std::vector<TileRef> endpoints = grow_mountain_skeleton(p_origin_tile.get(), all_mountain_tiles, tile_levels, level_tiles, skeleton_level);
	int64_t bottom_level = skeleton_level - 2;
	RouteRef volcano_route = route(NM("volcano1"), 22);
	level_tiles.clear();
	TileMap volcano_tiles;
	apply_blotch("volcano1", p_origin_tile, 350, volcano_tiles, 0, false, volcano_route);
	level_tiles.clear();
	apply_blotch("volcano1_lava", p_origin_tile, 200, level_tiles, 0, false, volcano_route);
	ledgify(level_tiles, level_tiles, NM("volcano2"), NM("lava1_"), NM("volcano"));
	volcano_tiles.merge(level_tiles, true);
	ledgify(volcano_tiles, volcano_tiles, NM("volcano1"), NM("lava1_"), NM("volcano"), NM("volcano1"));
	volcano_tiles.each([&](const Vector2i &, const Cell &p_cell) {
		if (p_cell.tile->upper == NM("soot1")) {
			set_names(p_cell.tile.get(), p_cell.tile->upper);
		}
	});
	level_tiles.clear();
	level_tiles.merge(volcano_tiles, true);
	int64_t current_level = -5;
	level_tiles.each([&](const Vector2i &, const Cell &p_cell) {
		set_level(tile_levels, p_cell.tile, current_level);
	});
	for (int index = 0; index < 5; index++) {
		add_mountain_layer(level_tiles, tile_levels, volcano_tiles, current_level, NM("volcano1"), volcano_route, false);
		current_level += 1;
	}
	add_mountain_layer(level_tiles, tile_levels, volcano_tiles, current_level, NM("mountain3"), volcano_route, false);
	add_mountain_layer(level_tiles, tile_levels, volcano_tiles, current_level, NM("mountain3"), volcano_route, false);
	all_mountain_tiles.merge(volcano_tiles, true);
	smooth_mountain_levels(all_mountain_tiles, tile_levels);
	assign_mountain_ledges(all_mountain_tiles, tile_levels);
	TileMap biome_map;
	biome_tiles = &biome_map;
	all_mountain_tiles.each([&](const Vector2i &, const Cell &p_cell) {
		biome_read_cells.insert(p_cell.tile->position, true);
	});
	int64_t placement_bound = (int64_t)Math::ceil((double)p_maximum_distance / 500.0);
	for (Cell &cell : all_mountain_tiles.values()) {
		const TileRef &tile = cell.tile;
		if (random.next_int(placement_bound) != 1) {
			continue;
		}
		double distance = (double)Vector2(tile->position).distance_to(Vector2(p_origin_tile->position));
		int64_t level = (int64_t)(30.0 * (1.0 - (double)Vector2(tile->position).distance_to(Vector2(origin)) / (double)(radius / 12)));
		level = MAX(level, (int64_t)4);
		std::pair<TileRef, int64_t> *known = tile_levels.getptr(tile.get());
		if (!known) {
			data.warnings++;
		}
		if (known && known->second <= current_level) {
			level = 10;
		} else if (level > 30) {
			level = 30;
		}
		if (distance < (double)(p_maximum_distance / 40)) {
			// The peak itself counts as one tile away (see GDScript).
			int64_t snow_size = 7 * (int64_t)((double)p_maximum_distance / MAX(distance, 16.0));
			apply_blotch("mtn_snow1", tile, snow_size, biome_map, 0, false, route(NM("snow1"), level));
		} else {
			apply_blotch("mtn_green1", tile, p_maximum_distance / 240, biome_map, 0, false, route(NM("mountain1"), level));
		}
	}
	biome_tiles = nullptr;
	biome_read_cells.clear();
	for (Cell &cell : all_mountain_tiles.values()) {
		Tile *tile = cell.tile.get();
		if (!no_ice_here.has(tile->position)) {
			Vector2 rotated = rotate_deg(Vector2(tile->position), 45.0);
			double offset_y = (double)(((int64_t)Math::abs((double)rotated.y / 12.0)) % 14 - 7);
			double offset_x = (double)(((int64_t)Math::abs((double)rotated.x / 12.0 - (double)rotated.y / 12.0)) % 14 - 7);
			double offset_1 = Math::abs(offset_x) + Math::abs(offset_y);
			offset_y = (double)ABS(((int64_t)Math::abs((double)rotated.y / 12.0)) % 20 - 10);
			offset_x = (double)ABS(((int64_t)Math::abs((double)rotated.x / 12.0)) % 20 - 10);
			if (offset_1 * ((offset_x + offset_y) / 5.0) > 14.0) {
				set_names(tile, NM("mountain4"), tile->upper);
			}
		}
		if (random.next_int(24) == 0 && !biome_map.has(tile->position)) {
			RouteRef rock_route;
			if (random.next_int(2) == 0) {
				rock_route = route(NM(""), 22);
				append_stored(rock_route.get(), { "slugma", "geodude", "shuckle" }, rock_route->level, 3);
			}
			put(biome_map, tile->position, make(tile->name, tile->position, NM("rock1_color"), true, rock_route));
		}
		if (tile->name == NM("mountain3")) {
			Vector2 rotated = rotate_deg(Vector2(tile->position), -15.0);
			double offset_y = (double)(((int64_t)Math::abs((double)rotated.y / 8.0)) % 14 - 7);
			double offset_x = Math::fmod((double)((int64_t)Math::abs((double)rotated.x / 8.0)) - offset_y * 2.0, 14.0) - 7.0;
			double offset_1 = Math::abs(offset_x) + Math::abs(offset_y);
			offset_y = (double)ABS(((int64_t)Math::abs((double)rotated.y / 8.0)) % 20 - 10);
			offset_x = (double)ABS(((int64_t)Math::abs((double)rotated.x / 8.0)) % 20 - 10);
			if (offset_1 * ((offset_x + offset_y) / 5.0) > 16.0) {
				set_names(tile, NM("mountain6"), tile->upper);
			}
		}
	}
	biome_map.merge(volcano_tiles, true);
	for (Cell &cell : all_mountain_tiles.values()) {
		Tile *mountain_tile = cell.tile.get();
		std::pair<TileRef, int64_t> *known = tile_levels.getptr(mountain_tile);
		if (!known) {
			data.warnings++;
		}
		if (known && known->second <= bottom_level) {
			bottom_mountain_layer.insert(mountain_tile->position, true);
			int64_t *count = no_ice_here.getptr(mountain_tile->position);
			int64_t remaining = (count ? *count : 0) - 1;
			if (remaining > 0) {
				*count = remaining;
			} else {
				no_ice_here.erase(mountain_tile->position);
			}
			mountain_tile->set(F_BOTTOM, true);
			continue;
		}
		Tile *biome_tile = as_tile(biome_map.getp(mountain_tile->position));
		if (!biome_tile) {
			continue;
		}
		if (mountain_tile->upper == 0) {
			put(all_mountain_tiles, biome_tile->position, biome_map.getp(mountain_tile->position)->tile);
			continue;
		}
		mountain_tile->name = biome_tile->name;
		mountain_tile->biome = biome_tile->biome;
		if (has(mountain_tile->name, "grass3")) {
			mountain_tile->name = NM("snow1");
		} else if (has(mountain_tile->name, "grass2")) {
			mountain_tile->name = NM("green1");
		}
		if (has(mountain_tile->upper, "ledges3") && has(mountain_tile->biome, "tundra")) {
			mountain_tile->upper = intern(replace_all(S(mountain_tile->upper), "ledges3", "ledges3snow"));
		} else if (has(mountain_tile->upper, "ledges3") && has(mountain_tile->name, "volcano")) {
			mountain_tile->upper = intern(replace_all(S(mountain_tile->upper), "ledges3", "ledges3volcano"));
		}
		set_names(mountain_tile, mountain_tile->name, mountain_tile->upper);
	}
	ledgify(all_mountain_tiles, all_mountain_tiles, NM("mountain4"), NM("mountain3"), NM("mountain"));
	return endpoints;
}

} // namespace pw
