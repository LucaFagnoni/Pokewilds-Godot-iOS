// After the landmarks: shores, puddles, overworld Pokemon, the required
// dungeons; then the validator (source_generation_validator.gd), the
// adapter's repairs (source_exact_world_adapter.gd), the packed store
// (WorldTileStore.from_dictionary) and the result for GDScript.

#include "island.h"

#include "core/math/vector3i.h"
#include "core/os/os.h"

#include <algorithm>
#include <deque>

namespace pw {

template <typename T>
static bool contains(const std::vector<T> &p_list, const T &p_value) {
	return std::find(p_list.begin(), p_list.end(), p_value) != p_list.end();
}

template <typename T>
static void erase_first(std::vector<T> &p_list, const T &p_value) {
	auto found = std::find(p_list.begin(), p_list.end(), p_value);
	if (found != p_list.end()) {
		p_list.erase(found);
	}
}

static Rect2i centered_rect(Vector2i p_center, Vector2i p_size) {
	return Rect2i(p_center - p_size / 2, p_size);
}

static const Vector2i SHORE_OFFSETS[8] = {
	Vector2i(-16, 0), Vector2i(16, 0), Vector2i(-16, -16),
	Vector2i(16, 16), Vector2i(16, -16), Vector2i(-16, 16),
	Vector2i(0, -16), Vector2i(0, 16)
};

void Gen::postprocess_source_shores() {
	std::vector<TileRef> mountain_water_tiles;
	// The map is walked live; a cell replaced before its turn is seen as a
	// values() snapshot had it: `replaced` keeps that (see GDScript).
	AHashMap<Vector2i, Cell> replaced;
	tiles_to_add.live_for([&](const Vector2i &p_position) {
		Cell raw_tile;
		const Cell *saved = replaced.getptr(p_position);
		if (saved) {
			raw_tile = *saved;
		} else {
			raw_tile = *tiles_to_add.getp(p_position);
		}
		if (raw_tile.is_int() || !raw_tile.tile) {
			return;
		}
		TileRef tile = raw_tile.tile;
		if (tile->route && tile->route->name == NM("wooded_lake_water1")) {
			for (const Vector2i &offset : SHORE_OFFSETS) {
				Tile *next_tile = peek_tile(tile->position + offset);
				if (next_tile && next_tile->name == NM("water2") && (!next_tile->route || next_tile->route->name != NM("wooded_lake_water1"))) {
					set_names(tile.get(), NM("sand3_tidalwater"), tile->upper);
				}
			}
			return;
		}
		if (tile->name == NM("water2") || tile->name == NM("water2_edge1") || has(tile->name, "mountain4") || has(tile->name, "ice") || has(tile->name, "waterfall")) {
			return;
		}
		for (const Vector2i &offset : SHORE_OFFSETS) {
			TileRef next_tile(peek_tile(tile->position + offset));
			if (!next_tile || next_tile->name != NM("water2")) {
				continue;
			}
			// An ocean cell's template has no position of its own.
			Vector2i next_position = next_tile->position;
			const Cell *at = tiles_to_add.getp(tile->position + offset);
			if (at && at->is_int()) {
				next_position = tile->position + offset;
			}
			if (no_ice_here.has(tile->position) && has(tile->upper, "ledges3")) {
				set_names(tile.get(), NM("sand3"), tile->upper);
				if (tile->position.x == next_position.x || tile->position.y == next_position.y) {
					mountain_water_tiles.push_back(tile);
					break;
				}
				continue;
			}
			int shore_name = NM("sand3");
			if (has(tile->name, "desert")) {
				shore_name = NM("sand3_desertEdge");
			} else if (has(tile->name, "_tidal")) {
				shore_name = NM("sand3_tidalwater");
			} else if (tile->biome == NM("beach_blacksand")) {
				shore_name = NM("sand3_black");
			}
			TileRef new_tile = make(shore_name, next_position, 0, true, tile->route);
			if (!replaced.has(new_tile->position)) {
				// What its turn sees: lake water does something there; ocean
				// (an int) and other water2 are skipped; a new key is null.
				const Cell *old = tiles_to_add.getp(new_tile->position);
				Cell value;
				if (old) {
					bool lake = !old->is_int() && old->tile && old->tile->route && old->tile->route->name == NM("wooded_lake_water1");
					if (lake) {
						value = *old;
					} else {
						value.ocean = 0;
					}
				}
				replaced.insert(new_tile->position, value);
			}
			put(tiles_to_add, new_tile->position, new_tile);
			bool excluded = has(tile->biome, "beach") || has(tile->biome, "mountain") || has(tile->biome, "savanna") || has(tile->biome, "wooded_lake") || has(tile->name, "desert") || (tile->route && (tile->route->name == NM("oasis1") || tile->route->name == NM("ruins1_outer"))) || (next_tile->route && next_tile->route->name == NM("wooded_lake_water1"));
			if (!excluded) {
				edges.push_back(new_tile);
			}
		}
	});
	for (TileRef &start_tile : mountain_water_tiles) {
		std::deque<Vector2i> water_positions;
		water_positions.push_back(start_tile->position);
		std::vector<TileRef> new_water_tiles;
		while (!water_positions.empty()) {
			Vector2i position = water_positions.front();
			water_positions.pop_front();
			TileRef next_tile(tile_at(position));
			new_water_tiles.push_back(next_tile);
			if (new_water_tiles.size() > 25) {
				new_water_tiles.clear();
				break;
			}
			if (next_tile && has(next_tile->upper, "ledge")) {
				if (has(next_tile->upper, "N")) {
					water_positions.push_back(position + Vector2i(0, -16));
				}
				if (has(next_tile->upper, "S")) {
					water_positions.push_back(position + Vector2i(0, 16));
				}
				if (has(next_tile->upper, "E")) {
					water_positions.push_back(position + Vector2i(-16, 0));
				}
				if (has(next_tile->upper, "W")) {
					water_positions.push_back(position + Vector2i(16, 0));
				}
				continue;
			}
			if (next_tile && has(next_tile->name, "water")) {
				break;
			}
			new_water_tiles.clear();
			break;
		}
		if (new_water_tiles.size() > 2) {
			int previous_name = 0;
			for (TileRef &waterfall_tile : new_water_tiles) {
				if (has(waterfall_tile->upper, "ledges3")) {
					set_names(waterfall_tile.get(), NM("water2"), waterfall_tile->upper);
					waterfallify(waterfall_tile.get());
					previous_name = waterfall_tile->name;
				} else {
					set_names(waterfall_tile.get(), NM("sand3"), previous_name);
				}
			}
		}
	}
	// coastify changes tiles, never the map.
	for (auto &entry : tiles_to_add.entries) {
		if (entry.live && !entry.value.is_int() && entry.value.tile) {
			coastify(entry.value.tile.get());
		}
	}
}

void Gen::waterfallify(Tile *p_tile) {
	if ((has(p_tile->name, "water") || has(p_tile->name, "lava")) && has(p_tile->upper, "ledges")) {
		const std::string &upper = S(p_tile->upper);
		size_t underscore = upper.find('_');
		if (underscore == std::string::npos) {
			return;
		}
		std::string name = has(p_tile->name, "lava") ? "lavafall" : "waterfall1";
		set_names(p_tile, intern(name + "_" + upper.substr(underscore + 1)), p_tile->upper);
	}
}

static const char *COAST_DIRECTIONS[8] = { "W", "E", "S", "N", "SW", "NE", "SE", "NW" };
static const Vector2i COAST_OFFSETS[8] = {
	Vector2i(-16, 0), Vector2i(16, 0), Vector2i(0, -16), Vector2i(0, 16),
	Vector2i(-16, -16), Vector2i(16, 16), Vector2i(16, -16), Vector2i(-16, 16)
};

static bool diagonal_direction_already_present(const std::string &p_existing, const std::string &p_direction) {
	if (p_direction.size() < 2) {
		return false;
	}
	for (char c : p_direction) {
		if (p_existing.find(std::string("[") + c + "]") != std::string::npos) {
			return true;
		}
	}
	return false;
}

bool Gen::coastify(Tile *p_tile) {
	p_tile->shore_ocean = 0;
	p_tile->shore_tidal = 0;
	if (p_tile->water() || has(p_tile->upper, "ledges") || p_tile->name == NM("ice2") || has(p_tile->name, "bridge") || has(p_tile->name, "waterfall")) {
		return false;
	}
	std::string ocean_direction;
	std::string tidal_direction;
	for (int index = 0; index < 8; index++) {
		Tile *next_tile = peek_tile(p_tile->position + COAST_OFFSETS[index]);
		if (!next_tile || next_tile->name == NM("water6")) {
			continue;
		}
		std::string direction = COAST_DIRECTIONS[index];
		if (!p_tile->tidal() && next_tile->tidal()) {
			if (!diagonal_direction_already_present(tidal_direction, direction)) {
				tidal_direction += "[" + direction + "]";
			}
			continue;
		}
		if (!next_tile->water()) {
			continue;
		}
		if (diagonal_direction_already_present(ocean_direction, direction)) {
			continue;
		}
		ocean_direction += "[" + direction + "]";
		tidal_direction += "[" + direction + "]";
	}
	p_tile->shore_ocean = intern(ocean_direction);
	p_tile->shore_tidal = intern(tidal_direction);
	// PkmnMap.coastify finishes with Tile.init() even with no shore found.
	set_names(p_tile, p_tile->name, p_tile->upper);
	return !ocean_direction.empty() || !tidal_direction.empty();
}

void Gen::postprocess_source_puddles() {
	static const char *directions[4] = { "W", "E", "S", "N" };
	static const Vector2i offsets[4] = { Vector2i(-16, 0), Vector2i(16, 0), Vector2i(0, -16), Vector2i(0, 16) };
	std::vector<TileRef> puddles;
	for (auto &entry : tiles_to_add.entries) {
		if (entry.live && !entry.value.is_int() && entry.value.tile && has(entry.value.tile->name, "_puddle1")) {
			puddles.push_back(entry.value.tile);
		}
	}
	for (TileRef &tile : puddles) {
		std::string direction;
		for (int index = 0; index < 4; index++) {
			Tile *next_tile = peek_tile(tile->position + offsets[index]);
			if (next_tile && has(next_tile->name, "_puddle1")) {
				direction += std::string("[") + directions[index] + "]";
			}
		}
		set_names(tile.get(), intern(replace_all(S(tile->name), "_puddle1", "_puddle1" + direction)), tile->upper);
	}
}

// --- Overworld Pokemon

int64_t Gen::source_spawn_base_chance(int p_route_name) {
	const std::string &name = S(p_route_name);
	if (name.find("oasis") != std::string::npos) {
		return 460;
	}
	if (name.find("ruins") != std::string::npos) {
		return 480;
	}
	if (name == "beach2_water") {
		return 506;
	}
	if (name == "beach2_rocks" || name == "beach2_plateau") {
		return 500;
	}
	if (name == "beach2") {
		return 509;
	}
	if (name.find("beach") != std::string::npos) {
		return 480;
	}
	if (name.find("graveyard") != std::string::npos) {
		return 506;
	}
	if (name == "savanna2") {
		return 509;
	}
	if (name == "mountain1_water1") {
		return 506;
	}
	if (name == "volcano1") {
		return 508;
	}
	if (name == "ocean1") {
		return 511;
	}
	return 509;
}

static Dictionary species_info(Data &p_data, const String &p_name) {
	String normalized = p_name.to_lower();
	Dictionary aliases = p_data.constants[2];
	return p_data.species(aliases.get(normalized, normalized));
}

Array Gen::source_evolutions(const String &p_name) {
	String normalized = p_name.to_lower();
	// Specie.java gives Combee's evolutions to the female form.
	if (normalized == "combee") {
		return Array();
	}
	return species_info(data, normalized).get("evolutions", Array());
}

static int32_t java_hash(const String &p_key) {
	uint32_t result = 0;
	for (int index = 0; index < p_key.length(); index++) {
		result = 31u * result + (uint32_t)p_key[index];
	}
	return (int32_t)result;
}

Array java_evolution_order(const Array &p_evolutions) {
	// Specie.gen2Evos is a java.util.HashMap of String keys: bucket order.
	int64_t capacity = 16;
	while (p_evolutions.size() > (int64_t)((double)capacity * 0.75)) {
		capacity *= 2;
	}
	struct Decorated {
		int64_t bucket;
		int64_t index;
		Variant evolution;
	};
	std::vector<Decorated> decorated;
	for (int index = 0; index < p_evolutions.size(); index++) {
		Dictionary evolution = p_evolutions[index];
		String parameter = evolution.get("parameter", "");
		String key = parameter.is_valid_int() ? parameter : parameter.to_lower().replace("_", " ");
		uint32_t raw = (uint32_t)java_hash(key);
		int64_t spread = (int64_t)(int32_t)(raw ^ (raw >> 16));
		decorated.push_back({ spread & (capacity - 1), index, evolution });
	}
	std::sort(decorated.begin(), decorated.end(), [](const Decorated &a, const Decorated &b) {
		return a.bucket < b.bucket || (a.bucket == b.bucket && a.index < b.index);
	});
	Array ordered;
	for (const Decorated &entry : decorated) {
		ordered.push_back(entry.evolution);
	}
	return ordered;
}

Dictionary Gen::source_random_evolutions(const String &p_start_name, int64_t p_start_level) {
	String pokemon_name = p_start_name;
	int64_t times_evolved = 0;
	while (true) {
		String selected;
		Array ordered = java_evolution_order(source_evolutions(pokemon_name));
		for (int index = 0; index < ordered.size(); index++) {
			Dictionary evolution = ordered[index];
			String parameter = evolution.get("parameter", "");
			if (parameter.is_valid_int()) {
				if (parameter.to_int() <= p_start_level + 10 * (times_evolved + 1) && global_random.next_int(256) >= 128) {
					selected = String(evolution.get("species", pokemon_name)).to_lower();
					break;
				}
			} else if (global_random.next_int(256) >= 192) {
				selected = String(evolution.get("species", pokemon_name)).to_lower();
				break;
			}
		}
		if (selected.is_empty()) {
			break;
		}
		pokemon_name = selected;
		times_evolved += 1;
	}
	Dictionary result;
	result["name"] = pokemon_name;
	result["level"] = p_start_level + 10 * times_evolved;
	return result;
}

bool Gen::source_is_base_species(const String &p_name) {
	String normalized = p_name.to_lower();
	Dictionary overrides = data.constants[3];
	if (overrides.has(normalized)) {
		return String(overrides[normalized]) == normalized;
	}
	Array forms = species_info(data, normalized).get("base_forms", Array());
	if (forms.is_empty()) {
		return true;
	}
	Variant first = forms[0];
	if (first.get_type() == Variant::DICTIONARY) {
		return String(Dictionary(first).get("species", p_name)).to_lower() == p_name;
	}
	return String(first).to_lower() == p_name;
}

bool Gen::source_spawn_requirements_met(Tile *p_tile, const String &p_name) {
	const std::string &route_name = S(p_tile->route->name);
	bool has_evolution = !source_evolutions(p_name).is_empty();
	bool requirements_met = !has_evolution;
	if (route_name.find("beach") != std::string::npos) {
		requirements_met = has_evolution;
	}
	if (route_name.find("ruins") != std::string::npos || route_name.find("graveyard") != std::string::npos) {
		requirements_met = true;
	}
	if (route_name == "beach2" || route_name == "beach2_rocks" || route_name == "beach2_plateau" || route_name == "savanna2" || route_name == "volcano1" || route_name == "wooded_lake1") {
		requirements_met = true;
	}
	if (route_name == "beach2_water") {
		requirements_met = p_tile->water();
	}
	if (route_name == "mountain1_water1") {
		requirements_met = p_tile->water();
	}
	// The final `else if` belongs to the wooded-lake water check only.
	if (route_name == "wooded_lake_water1") {
		requirements_met = p_tile->water();
	} else if (route_name.find("mountain") != std::string::npos) {
		requirements_met = !has_evolution || p_name == "machoke" || p_name == "rhydon" || p_name == "onix";
	}
	if (route_name.find("snow") != std::string::npos) {
		requirements_met = !has_evolution || p_name == "sneasel" || p_name == "piloswine";
	}
	return requirements_met;
}

void Gen::spawn_source_overworld_pokemon() {
	// Ocean cells take part (ocean1 spawns), read through their template.
	tiles_to_add.each([&](const Vector2i &p_key, const Cell &p_cell) {
		Tile *tile;
		Vector2i tile_position;
		if (p_cell.is_int()) {
			tile = ocean_tiles[p_cell.ocean].get();
			tile_position = p_key;
		} else {
			tile = p_cell.tile.get();
			tile_position = tile->position;
		}
		Route *route = tile->route.get();
		if ((tile->solid() && !has(tile->name, "water")) || tile->upper != 0 || !route || route->name == 0 || data.allowed(route->name).empty() || route->dont_spawn || (has(tile->name, "water") && !has(route->name, "beach2") && route->name != NM("ocean1") && route->name != NM("mountain1_water1") && route->name != NM("wooded_lake_water1"))) {
			return;
		}
		const std::vector<String> &allowed = data.allowed(route->name);
		if (route->name == NM("desert1")) {
			if (random.next_int(512) < 511) {
				return;
			}
			String desert_name = allowed[random.next_int((int64_t)allowed.size())].to_lower();
			int64_t desert_level = route->level + global_random.next_int(3);
			if (desert_name == "numel" || desert_name == "kangaskhan" || desert_name == "cubone") {
				desert_level = 10;
			}
			Dictionary extra;
			extra["generation"] = "CRYSTAL";
			extra["aggressive"] = desert_name == "drapion";
			spawn(tile_position, desert_name, desert_level, extra);
			return;
		}
		int64_t base_chance = source_spawn_base_chance(route->name);
		int64_t spawn_roll = random.next_int(512);
		if (spawn_roll < base_chance) {
			return;
		}
		String pokemon_name = allowed[random.next_int((int64_t)allowed.size())].to_lower();
		int64_t pokemon_level = route->level + global_random.next_int(3);
		Dictionary evolved = source_random_evolutions(pokemon_name, pokemon_level);
		pokemon_name = evolved["name"];
		pokemon_level = evolved["level"];
		if (source_is_base_species(pokemon_name)) {
			if (pokemon_level > 10) {
				pokemon_level = 10;
			}
		} else if ((pokemon_name == "bellossom" || pokemon_name == "gardevoir" || pokemon_name == "jumpluff" || pokemon_name == "marill" || pokemon_name == "chansey" || pokemon_name == "blissey" || pokemon_name == "pikachu") && pokemon_level > 30) {
			pokemon_level = 30;
		}
		if (!source_spawn_requirements_met(tile, pokemon_name)) {
			return;
		}
		Dictionary extra;
		extra["generation"] = "CRYSTAL";
		if (pokemon_name == "froslass" || pokemon_name == "sharpedo" || pokemon_name == "primeape") {
			extra["aggressive"] = true;
		}
		if (pokemon_name == "froslass") {
			extra["gender"] = "female";
		} else if (pokemon_name == "gallade") {
			extra["gender"] = "male";
		}
		spawn(tile_position, pokemon_name, pokemon_level, extra);
	});
}

// --- Required dungeons after the source world

void Gen::add_required_regi_after_source_world(const std::vector<TileRef> &p_candidates) {
	static const Vector2i overlap_offsets[7] = { Vector2i(0, -368), Vector2i(-224, 0), Vector2i(144, -240), Vector2i(32, 32), Vector2i(-32, 32), Vector2i(32, -32), Vector2i(-32, -32) };
	for (const TileRef &candidate : p_candidates) {
		if (!candidate || candidate->biome != NM("deep_forest")) {
			continue;
		}
		bool mountain_overlap = false;
		for (const Vector2i &offset : overlap_offsets) {
			if (mountain_tiles.has(candidate->position + offset)) {
				mountain_overlap = true;
				break;
			}
		}
		if (mountain_overlap) {
			continue;
		}
		Rect2i bounds = centered_rect(candidate->position, Vector2i(208, 160));
		bool structure_overlap = false;
		for (const Vector2i &position : regi_exterior_positions(candidate->position)) {
			Tile *tile = peek_tile(position);
			if (tile && (has(tile->name, "pkmnmansion") || has(tile->upper, "pkmnmansion") || has(tile->name, "building") || has(tile->upper, "building") || has(tile->name, "ruins") || tile->upper == NM("pokemon_mansion_key"))) {
				structure_overlap = true;
				break;
			}
		}
		if (structure_overlap) {
			continue;
		}
		generate_regi_dungeon(candidate->position);
		for (const Vector2i &position : pokemon_to_add.keys()) {
			if (bounds.has_point(position)) {
				Tile *tile = peek_tile(position);
				if (tile && (tile->solid() || has(tile->name, "door"))) {
					pokemon_to_add.erase(position);
				}
			}
		}
		if (!contains(already_used_dungeons, std::string("regi1"))) {
			already_used_dungeons.push_back("regi1");
		}
		return;
	}
}

bool Gen::clearing_has_land_access(const Rect2i &p_rect) {
	for (int64_t x = p_rect.position.x; x < p_rect.get_end().x; x += 16) {
		const int64_t ys[2] = { (int64_t)p_rect.position.y - 16, (int64_t)p_rect.get_end().y };
		for (int64_t y : ys) {
			Tile *tile = peek_tile(Vector2i((int32_t)x, (int32_t)y));
			if (tile && !tile->solid() && !tile->water() && !tile->ledge()) {
				return true;
			}
		}
	}
	for (int64_t y = p_rect.position.y; y < p_rect.get_end().y; y += 16) {
		const int64_t xs[2] = { (int64_t)p_rect.position.x - 16, (int64_t)p_rect.get_end().x };
		for (int64_t x : xs) {
			Tile *tile = peek_tile(Vector2i((int32_t)x, (int32_t)y));
			if (tile && !tile->solid() && !tile->water() && !tile->ledge()) {
				return true;
			}
		}
	}
	return false;
}

bool Gen::required_landmark_site(bool p_mansion, Vector2i &r_position, Rect2i &r_bounds) {
	PosSet protected_cells;
	std::vector<Vector2i> candidates;
	for (auto &entry : tiles_to_add.entries) {
		if (!entry.live) {
			continue;
		}
		Tile *tile = peek(&entry.value);
		std::string names = S(tile->name) + " " + S(tile->upper);
		for (const char *marker : { "pkmnmansion", "building", "ruins", "cave", "pokemon_mansion_key", "grave", "fence", "fossil" }) {
			if (names.find(marker) != std::string::npos) {
				protected_cells[entry.key] = true;
				break;
			}
		}
		if (!tile->water() && !tile->solid() && !mountain_tiles.has(entry.key)) {
			candidates.push_back(entry.key);
		}
	}
	// Shared Java interior planes must not overwrite another dungeon's rooms.
	if (p_mansion) {
		for (size_t index = 95; index < interior_tiles_to_add.size(); index++) {
			if (interior_tiles_to_add[index]) {
				interior_tiles_to_add[index]->each([&](const Vector2i &p_position, const Cell &) {
					protected_cells[p_position] = true;
				});
			}
		}
	}
	std::sort(candidates.begin(), candidates.end(), [](const Vector2i &a, const Vector2i &b) {
		int64_t ad = a.length_squared();
		int64_t bd = b.length_squared();
		return ad != bd ? ad < bd : (a.y != b.y ? a.y < b.y : a.x < b.x);
	});
	Vector2i offset = p_mansion ? Vector2i(-336, -384) : Vector2i(-128, -80);
	Vector2i extent = p_mansion ? Vector2i(672, 704) : Vector2i(272, 192);
	for (int pass = 0; pass < 2; pass++) {
		bool prepare_terrain = pass == 1;
		for (const Vector2i &at : candidates) {
			Rect2i rect(at + offset, extent);
			bool valid = true;
			for (int64_t y = rect.position.y; y < rect.get_end().y && valid; y += 16) {
				for (int64_t x = rect.position.x; x < rect.get_end().x; x += 16) {
					Vector2i p((int32_t)x, (int32_t)y);
					Tile *tile = peek_tile(p);
					if (protected_cells.has(p) || !tile) {
						valid = false;
						break;
					}
					if (!prepare_terrain && (mountain_tiles.has(p) || tile->water())) {
						valid = false;
						break;
					}
				}
			}
			if (valid && clearing_has_land_access(rect)) {
				r_position = at;
				r_bounds = rect;
				return true;
			}
		}
	}
	return false;
}

void Gen::prepare_landmark_clearing(const Rect2i &p_rect) {
	RouteRef clearing_route = route(NM("forest1"), 40);
	for (int64_t index = (int64_t)edges.size() - 1; index >= 0; index--) {
		if (p_rect.has_point(edges[index]->position)) {
			edges.erase(edges.begin() + index);
		}
	}
	for (int64_t y = p_rect.position.y; y < p_rect.get_end().y; y += 16) {
		for (int64_t x = p_rect.position.x; x < p_rect.get_end().x; x += 16) {
			Vector2i position((int32_t)x, (int32_t)y);
			put(tiles_to_add, position, make(NM("green1"), position, 0, true, clearing_route));
			mountain_tiles.erase(position);
			pokemon_to_add.erase(position);
			erase_first(trapinch_spawns, position);
			erase_first(keystone_spawns, position);
		}
	}
}

void Gen::complete_missing_landmarks() {
	if (!done_pkmn_mansion) {
		Vector2i at;
		Rect2i bounds;
		if (!required_landmark_site(true, at, bounds)) {
			ERR_PRINT("No safe mansion site exists in generated terrain");
			return;
		}
		prepare_landmark_clearing(bounds);
		generate_mansion(at);
		done_pkmn_mansion = true;
		if (!done_pkmn_mansion_key) {
			Vector2i key_position = at + Vector2i(-16, -352);
			put(tiles_to_add, key_position, make(NM("green1"), key_position, NM("pokemon_mansion_key"), true));
			done_pkmn_mansion_key = true;
		}
		if (!contains(already_used_dungeons, std::string("mansion1"))) {
			already_used_dungeons.push_back("mansion1");
		}
	}
	if (interior_tiles_to_add.size() <= 90 || !interior_tiles_to_add[90] || interior_tiles_to_add[90]->is_empty()) {
		Vector2i at;
		Rect2i bounds;
		if (!required_landmark_site(false, at, bounds)) {
			ERR_PRINT("No safe Regi site exists in generated terrain");
			return;
		}
		prepare_landmark_clearing(bounds);
		generate_regi_dungeon(at);
		done_regi_dungeon = true;
		if (!contains(already_used_dungeons, std::string("regi1"))) {
			already_used_dungeons.push_back("regi1");
		}
	}
}

// --- generate_complete

void Gen::generate_complete(const std::vector<std::string> &p_used_dungeons) {
	validation_records.clear();
	graveyard_fence_bounds.clear();
	interior_pokemon.clear();
	interior_tiles_to_add.clear();
	interior_tiles_to_add.resize(102);
	already_used_dungeons = p_used_dungeons;
	std::vector<TileRef> desert_tiles;
	std::vector<TileRef> deep_forest_tiles;
	generate_surface(desert_tiles, deep_forest_tiles);
	done_pkmn_mansion = false;
	done_pkmn_mansion_key = false;
	done_desert_ruins = false;
	// Regi placement is drawn after the source world (see GDScript).
	done_regi_dungeon = true;
	std::vector<Rect2i> hitboxes;
	Rect2i mansion_box;
	place_source_landmarks(desert_tiles, deep_forest_tiles, hitboxes, mansion_box);
	qa_stage("landmarks");
	desert_tiles.clear();
	cleanup_and_place_deep_forest_landmarks(deep_forest_tiles, hitboxes, mansion_box);
	qa_stage("cleanup");
	postprocess_source_shores();
	qa_stage("shores");
	postprocess_source_puddles();
	qa_stage("puddles");
	spawn_source_overworld_pokemon();
	qa_stage("spawn");
	add_required_regi_after_source_world(deep_forest_tiles);
	qa_stage("regi");
	complete_missing_landmarks();
	qa_stage("complete");
	burrowed_pokemon.clear();
	for (const Vector2i &position : trapinch_spawns) {
		Tile *trap_tile = tile_at(position);
		if (!trap_tile || trap_tile->name != NM("desert2")) {
			continue;
		}
		trap_tile->items_get().set("trapinch", 1);
		Dictionary record;
		record["name"] = "trapinch";
		record["level"] = 22;
		record["position"] = position;
		record["generation"] = "CRYSTAL";
		record["is_trapping"] = true;
		burrowed_pokemon.push_back(record);
	}
	qa_stage("done");
}

// --- The validator

static void add_error(TypedArray<String> &r_errors, const String &p_message) {
	if (!r_errors.has(p_message)) {
		r_errors.push_back(p_message);
	}
}

namespace {
struct LayerView {
	int index;
	OMap<Vector2i, TileRef> tiles;
};
} // namespace

static LayerView *view_of(std::vector<LayerView> &p_layers, int p_index) {
	for (LayerView &layer : p_layers) {
		if (layer.index == p_index) {
			return &layer;
		}
	}
	return nullptr;
}

static bool walkable(Tile *p_tile) {
	return p_tile && (!p_tile->solid() || has(p_tile->upper, "stairs"));
}

static void check_mine_paths(std::vector<LayerView> &p_layers, TypedArray<String> &r_errors) {
	static const Vector2i steps[4] = { Vector2i(16, 0), Vector2i(-16, 0), Vector2i(0, 16), Vector2i(0, -16) };
	AHashMap<Vector3i, bool> seen;
	std::vector<Vector3i> queue;
	if (LayerView *top = view_of(p_layers, 99)) {
		top->tiles.each([&](const Vector2i &, const TileRef &p_tile) {
			if (has(p_tile->upper, "exit")) {
				Vector3i key(p_tile->position.x, p_tile->position.y, 99);
				seen[key] = true;
				queue.push_back(key);
			}
		});
	}
	if (queue.empty()) {
		add_error(r_errors, "Mine surface exit missing");
		return;
	}
	size_t index = 0;
	while (index < queue.size()) {
		Vector3i node = queue[index];
		index += 1;
		Vector2i position(node.x, node.y);
		LayerView *layer = view_of(p_layers, node.z);
		for (const Vector2i &offset : steps) {
			Vector3i next(position.x + offset.x, position.y + offset.y, node.z);
			const TileRef *at = layer->tiles.getp(position + offset);
			if (!seen.has(next) && walkable(at ? at->get() : nullptr)) {
				seen[next] = true;
				queue.push_back(next);
			}
		}
		Tile *tile = layer->tiles.getp(position)->get();
		if (has(tile->upper, "stairs") && !has(tile->upper, "exit")) {
			int target = has(tile->upper, "up") ? node.z + 1 : node.z - 1;
			Vector3i next(position.x, position.y, target);
			LayerView *target_layer = view_of(p_layers, target);
			const TileRef *at = target_layer ? target_layer->tiles.getp(position) : nullptr;
			if (!seen.has(next) && walkable(at ? at->get() : nullptr)) {
				seen[next] = true;
				queue.push_back(next);
			}
		}
	}
	for (LayerView &layer : p_layers) {
		layer.tiles.each([&](const Vector2i &, const TileRef &p_tile) {
			Vector2i position = p_tile->position;
			if (has(p_tile->upper, "stairs") && !seen.has(Vector3i(position.x, position.y, layer.index))) {
				add_error(r_errors, "Mine stairs unreachable");
			}
			if (p_tile->has_item != 0 || p_tile->upper == NM("volcarona")) {
				bool reachable = false;
				for (const Vector2i &offset : steps) {
					if (seen.has(Vector3i(position.x + offset.x, position.y + offset.y, layer.index))) {
						reachable = true;
					}
				}
				if (!reachable) {
					add_error(r_errors, "Mine reward or boss unreachable");
				}
			}
		});
	}
}

static void check_rooms(Gen &p_gen, const std::string &p_kind, std::vector<LayerView> &p_layers, Vector2i p_at, TypedArray<String> &r_errors) {
	String kind = String::utf8(p_kind.c_str());
	if (p_kind == "fossil_lab") {
		LayerView *room = view_of(p_layers, 100);
		if (!room || room->tiles.is_empty()) {
			add_error(r_errors, "Fossil lab interior missing");
		}
		return;
	}
	std::vector<int> expected;
	if (p_kind == "regi") {
		expected = { 90 };
	} else if (p_kind == "mansion") {
		expected = { 95, 96, 97, 98, 99, 100, 101 };
	} else {
		expected = { 95, 96, 97, 98, 99 };
	}
	for (int index : expected) {
		LayerView *layer = view_of(p_layers, index);
		if (!layer || layer->tiles.is_empty()) {
			add_error(r_errors, kind + " floor missing");
		}
	}
	AHashMap<Vector3i, bool> bosses;
	int64_t rewards = 0;
	int64_t switches = 0;
	int64_t stairs = 0;
	for (LayerView &layer : p_layers) {
		int li = layer.index;
		if (p_kind == "mansion" && li >= 96 && !layer.tiles.is_empty()) {
			Vector2i lo(2147483647, 2147483647);
			Vector2i hi = -lo;
			layer.tiles.each([&](const Vector2i &p_position, const TileRef &) {
				lo = Vector2i(MIN(lo.x, p_position.x), MIN(lo.y, p_position.y));
				hi = Vector2i(MAX(hi.x, p_position.x), MAX(hi.y, p_position.y));
			});
			int64_t expected_count = ((int64_t)(hi.x - lo.x) / 16 + 1) * ((int64_t)(hi.y - lo.y) / 16 + 1);
			if ((int64_t)layer.tiles.size() != expected_count) {
				add_error(r_errors, "Mansion floor has holes");
			}
		}
		layer.tiles.each([&](const Vector2i &p_position, const TileRef &p_tile) {
			Tile *tile = p_tile.get();
			if (tile->upper == NM("mewtwo_overworld") || tile->upper == NM("volcarona")) {
				bosses[Vector3i(tile->position.x, tile->position.y, li)] = true;
			}
			if (tile->has_item != 0) {
				rewards += 1;
				bool valid = tile->has_item == NM("ultra ball") && tile->amount == (p_kind == "mansion" ? 1 : 2);
				if (p_kind == "mine" && tile->has_item == NM("ancientpowder") && (tile->amount == 2 || tile->amount == 3 || tile->amount == 4)) {
					valid = true;
				}
				if (!valid) {
					add_error(r_errors, kind + " reward rule mismatch");
				}
			}
			if (has(tile->upper, "stairs")) {
				stairs += 1;
				if (has(tile->upper, "exit")) {
					if (p_kind == "mine" && p_position != p_at) {
						add_error(r_errors, "Mine exit does not match surface entry");
					}
				} else {
					int target = has(tile->upper, "up") ? li + 1 : li - 1;
					LayerView *target_layer = view_of(p_layers, target);
					if (!target_layer || !target_layer->tiles.has(p_position)) {
						add_error(r_errors, kind + " stair destination missing");
					}
				}
			}
			// The door_tiles getter makes the list when it is still null.
			if (tile->name == NM("pkmnmansion_statue1") && !tile->doors_get().empty()) {
				switches += 1;
				LayerView *below = view_of(p_layers, li - 1);
				for (const Vector2i &gate : *tile->doors) {
					const TileRef *target = below ? below->tiles.getp(gate) : nullptr;
					if (!target || !(has((*target)->name, "__on") || has((*target)->name, "__off"))) {
						add_error(r_errors, "Mansion switch gate missing");
					}
				}
			}
		});
	}
	if (p_kind == "regi") {
		LayerView *chamber = view_of(p_layers, 90);
		if (!chamber || chamber->tiles.size() != 960) {
			add_error(r_errors, "Regi chamber incomplete");
		}
		const std::vector<std::vector<int>> &rows = p_gen.data.layout("generateRegiDungeon", 1);
		for (size_t y = 0; y < rows.size(); y++) {
			for (size_t x = 0; x < rows[y].size(); x++) {
				if (rows[y][x] < 0) {
					continue;
				}
				const TileRef *tile = chamber ? chamber->tiles.getp(p_at + Vector2i((int32_t)(-288 + x * 16), (int32_t)(272 - (int64_t)y * 16))) : nullptr;
				if (!tile || (*tile)->name != rows[y][x]) {
					add_error(r_errors, "Regi chamber source layout mismatch");
				}
			}
		}
		int64_t pedestals = 0;
		if (chamber) {
			Items recipes;
			for (const char *regi : { "REGISTEEL", "REGICE", "REGIROCK", "REGIELEKI", "REGIDRAGO" }) {
				recipes.set(regi, 1);
			}
			chamber->tiles.each([&](const Vector2i &, const TileRef &p_tile) {
				if (p_tile->name == NM("cave1_regipedistal1")) {
					pedestals += 1;
					Items snapshot = p_tile->items ? *p_tile->items : Items();
					if (!(snapshot == recipes)) {
						add_error(r_errors, "Regi pedestal recipes incomplete");
					}
				}
			});
		}
		if (pedestals != 1) {
			add_error(r_errors, "Regi pedestal missing");
		}
	} else {
		if (bosses.size() != 1) {
			add_error(r_errors, kind + " boss missing or duplicated");
		}
		if (rewards == 0 || stairs == 0) {
			add_error(r_errors, kind + " rewards or stairs missing");
		}
		if (p_kind == "mansion" && switches == 0) {
			add_error(r_errors, "Mansion switches missing");
		}
	}
	if (p_kind == "mine") {
		check_mine_paths(p_layers, r_errors);
	}
}

Dictionary Gen::validate() {
	TypedArray<String> errors;
	Dictionary counts;
	counts["mansion"] = 0;
	counts["regi"] = 0;
	counts["mine"] = 0;
	counts["fossil_lab"] = 0;
	Array biome_order;
	AHashMap<int, bool> biomes;
	auto add_biome = [&](int p_biome) {
		if (!biomes.has(p_biome)) {
			biomes.insert(p_biome, true);
			biome_order.push_back(gs(p_biome));
		}
	};
	int64_t keys = 0;
	tiles_to_add.each([&](const Vector2i &, const Cell &p_cell) {
		// Ocean cells: no biome, key, forest or oasis.
		if (p_cell.is_int() || !p_cell.tile) {
			return;
		}
		Tile *tile = p_cell.tile.get();
		if (tile->upper == NM("pokemon_mansion_key")) {
			keys += 1;
		}
		if (tile->biome != 0) {
			add_biome(tile->biome);
		}
		if (tile->route) {
			if (tile->route->name == NM("forest1")) {
				add_biome(NM("forest"));
			}
			if (tile->route->name == NM("oasis1")) {
				add_biome(NM("oasis"));
			}
		}
	});
	for (const char *biome : { "forest", "deep_forest", "wooded_lake", "savanna", "desert", "graveyard", "mountain", "tundra", "volcano", "beach", "oasis" }) {
		if (!biomes.has(intern(biome))) {
			errors.push_back(String("Missing biome: ") + biome);
		}
	}
	if (keys == 0) {
		errors.push_back("Mansion key missing");
	}
	AHashMap<Vector2i, std::string> exterior_owners;
	AHashMap<Vector3i, std::string> interior_owners;
	for (ValidationRecord &record : validation_records) {
		const std::string &kind = record.kind;
		String kind_text = String::utf8(kind.c_str());
		counts[kind_text] = int64_t(counts[kind_text]) + 1;
		record.exterior.each([&](const Vector2i &p_position, const Signature &p_signature) {
			const std::string *owner = exterior_owners.getptr(p_position);
			if (owner && *owner != kind) {
				add_error(errors, "Landmark exterior overlap");
			}
			exterior_owners[p_position] = kind;
			Tile *tile = peek_tile(p_position);
			if (!tile || !(signature(tile) == p_signature)) {
				add_error(errors, kind_text + " exterior overwritten or missing");
			}
		});
		std::vector<LayerView> layers;
		for (auto &recorded : record.layers) {
			int li = recorded.first;
			Layer final_layer = li < (int)interior_tiles_to_add.size() ? interior_tiles_to_add[li] : Layer();
			layers.push_back(LayerView{ li, OMap<Vector2i, TileRef>() });
			LayerView &view = layers.back();
			recorded.second.each([&](const Vector2i &p_position, const Signature &p_signature) {
				Vector3i cell(p_position.x, p_position.y, li);
				const std::string *owner = interior_owners.getptr(cell);
				if (owner && *owner != kind) {
					add_error(errors, "Landmark interior overlap");
				}
				interior_owners[cell] = kind;
				const Cell *found = final_layer ? final_layer->getp(p_position) : nullptr;
				Tile *tile = found ? found->tile.get() : nullptr;
				if (!tile || !(signature(tile) == p_signature)) {
					add_error(errors, kind_text + " interior overwritten or missing");
				}
				if (tile) {
					view.tiles.set(p_position, found->tile);
				}
			});
		}
		check_rooms(*this, kind, layers, record.origin, errors);
		int entry_name;
		if (kind == "fossil_lab") {
			entry_name = NM("pkmnmansion_ext_door");
		} else if (kind == "mansion") {
			entry_name = NM("pkmnmansion_ext_locked");
		} else if (kind == "regi") {
			entry_name = NM("cave1_door1");
		} else {
			entry_name = NM("stairs_down2");
		}
		int64_t entries = 0;
		record.exterior.each([&](const Vector2i &p_position, const Signature &) {
			Tile *tile = peek_tile(p_position);
			if (tile && (tile->name == entry_name || tile->upper == entry_name)) {
				entries += 1;
			}
		});
		if (entries != 1) {
			add_error(errors, kind_text + " surface entry missing or duplicated");
		}
		if (kind == "mine") {
			int64_t actors = 0;
			for (int index = 0; index < interior_pokemon.size(); index++) {
				Dictionary actor = interior_pokemon[index];
				if (String(actor.get("name", "")) != "dusclops") {
					continue;
				}
				actors += 1;
				if (int64_t(actor.get("level", 0)) != 44 || !bool(actor.get("aggressive", false))) {
					add_error(errors, "Mine guardian rule mismatch");
				}
				int64_t area_index = actor.get("area_index", -1);
				LayerView *layer = view_of(layers, (int)area_index);
				Variant position = actor.get("position", Variant());
				if ((area_index != 96 && area_index != 97) || !layer || position.get_type() != Variant::VECTOR2I || !layer->tiles.has(position)) {
					add_error(errors, "Mine guardian floor missing");
				}
			}
			if (actors < 4 || actors > 8) {
				add_error(errors, "Mine guardian population missing");
			}
		}
	}
	Array kinds = counts.keys();
	for (int index = 0; index < kinds.size(); index++) {
		int64_t count = counts[kinds[index]];
		if (count != 1) {
			errors.push_back(vformat("Expected one %s, found %d", kinds[index], count));
		}
	}
	Dictionary report;
	report["ok"] = errors.is_empty();
	report["errors"] = errors;
	report["landmarks"] = counts;
	report["biomes"] = biome_order;
	return report;
}

// --- The adapter (SourceExactWorldAdapter.from_generator_result)

namespace {
struct Adapter {
	Gen &gen;
	TileMap &tiles;
	OMap<Vector2i, Dictionary> pokemon;
	std::vector<TileRef> edges;
	Dictionary regi_relocated_cells;

	explicit Adapter(Gen &p_gen) :
			gen(p_gen), tiles(p_gen.tiles_to_add) {}

	static Vector2i cell_of(Vector2i p_pixel) { return Vector2i(p_pixel.x / 16, p_pixel.y / 16); }

	void repair_regi_mansion_overlap();
	void repair_graveyard_side_fences();
	void normalize_oasis_facades();
	void repair_mansion_roof_grass();
	void normalize_mansion_exterior();
};
} // namespace

void Adapter::repair_regi_mansion_overlap() {
	// Old v2 caches: the required cave over the mansion roof.
	std::vector<Route *> group_order;
	AHashMap<Route *, std::vector<std::pair<std::string, TileRef>>, PtrHasher> corners;
	std::vector<TileRef> cave_doors;
	for (Cell &cell : tiles.values()) {
		if (cell.is_int() || !cell.tile) {
			continue;
		}
		const TileRef &tile = cell.tile;
		if (tile->name == NM("cave1_door1")) {
			cave_doors.push_back(tile);
		}
		if (tile->route && (tile->upper == NM("pkmnmansion_roof_NW") || tile->upper == NM("pkmnmansion_roof_NE") || tile->upper == NM("pkmnmansion_roof_SW") || tile->upper == NM("pkmnmansion_roof_SE"))) {
			Route *key = tile->route.get();
			if (!corners.has(key)) {
				corners.insert(key, {});
				group_order.push_back(key);
			}
			std::string suffix = S(tile->upper).substr(strlen("pkmnmansion_roof_"));
			auto &group = *corners.getptr(key);
			bool replaced = false;
			for (auto &entry : group) {
				if (entry.first == suffix) {
					entry.second = tile;
					replaced = true;
				}
			}
			if (!replaced) {
				group.push_back({ suffix, tile });
			}
		}
	}
	for (Route *key : group_order) {
		auto &group = *corners.getptr(key);
		if (group.size() != 4) {
			continue;
		}
		auto find = [&](const char *p_suffix) -> TileRef {
			for (auto &entry : group) {
				if (entry.first == p_suffix) {
					return entry.second;
				}
			}
			return TileRef();
		};
		TileRef nw = find("NW");
		TileRef ne = find("NE");
		TileRef sw = find("SW");
		Rect2i roof(nw->position.x, MIN(nw->position.y, sw->position.y), 31 * 16, 26 * 16);
		if (ne->position.x - nw->position.x != 30 * 16 || ABS(nw->position.y - sw->position.y) != 25 * 16) {
			continue;
		}
		for (TileRef &door : cave_doors) {
			if (!roof.has_point(door->position)) {
				continue;
			}
			std::vector<TileRef> cave;
			bool contained = true;
			for (Cell &cell : tiles.values()) {
				if (cell.is_int() || !cell.tile) {
					continue;
				}
				if (cell.tile->route == door->route) {
					cave.push_back(cell.tile);
					if (!roof.has_point(cell.tile->position)) {
						contained = false;
					}
				}
			}
			if (!contained || cave.size() != 54) {
				continue;
			}
			std::vector<Vector2i> candidates;
			for (Cell &cell : tiles.values()) {
				if (cell.is_int() || !cell.tile) {
					continue;
				}
				Tile *tile = cell.tile.get();
				if ((tile->biome == NM("deep_forest") || has(tile->name, "deepforest")) && !tile->solid() && !tile->water()) {
					candidates.push_back(tile->position);
				}
			}
			Vector2i door_position = door->position;
			std::sort(candidates.begin(), candidates.end(), [&](const Vector2i &a, const Vector2i &b) {
				int64_t da = (a - door_position).length_squared();
				int64_t db = (b - door_position).length_squared();
				return da != db ? da < db : (a.y != b.y ? a.y < b.y : a.x < b.x);
			});
			Vector2i destination(2147483647, 2147483647);
			for (const Vector2i &candidate : candidates) {
				bool safe = true;
				for (TileRef &original : cave) {
					Vector2i target = candidate + original->position - door_position;
					Tile *tile = gen.peek_tile(target);
					if (roof.grow(16).has_point(target) || pokemon.has(target) || !tile || tile->water() || tile->is(F_LAVA) || tile->ledge() || tile->is(F_BOTTOM) || tile->has_item != 0 || (tile->items && !tile->items->list.empty())) {
						safe = false;
						break;
					}
					if (has(tile->name, "mtn") || has(tile->name, "mountain") || has(tile->name, "cave") || has(tile->name, "ruins") || has(tile->name, "building") || has(tile->name, "pkmnmansion") || has(tile->upper, "pkmnmansion") || has(tile->name, "fence") || has(tile->upper, "fence") || has(tile->name, "grave") || has(tile->upper, "grave") || has(tile->upper, "key")) {
						safe = false;
						break;
					}
				}
				Tile *entrance = gen.peek_tile(candidate + Vector2i(0, -16));
				for (TileRef &original : cave) {
					if (original->position == door_position + Vector2i(0, -16)) {
						entrance = original.get();
					}
				}
				if (!entrance || entrance->solid() || entrance->water()) {
					safe = false;
				}
				if (safe) {
					destination = candidate;
					break;
				}
			}
			if (destination.x == 2147483647) {
				continue;
			}
			Vector2i old_door = door_position;
			regi_relocated_cells[cell_of(old_door + Vector2i(0, -16))] = cell_of(destination + Vector2i(0, -16));
			for (TileRef &original : cave) {
				Vector2i position = original->position;
				std::string suffix = position.y == nw->position.y ? "N" : (position.y == sw->position.y ? "S" : "");
				suffix += position.x == nw->position.x ? "W" : (position.x == ne->position.x ? "E" : "");
				gen.put(tiles, position, gen.make(NM("sand1"), position, intern("pkmnmansion_roof" + (suffix.empty() ? std::string() : "_" + suffix)), true, nw->route));
				TileRef moved = gen.copy_at(original.get(), destination + position - old_door);
				gen.put(tiles, moved->position, moved);
				regi_relocated_cells[cell_of(position)] = cell_of(moved->position);
			}
		}
	}
}

void Adapter::repair_graveyard_side_fences() {
	for (Cell &cell : tiles.values()) {
		if (cell.is_int() || !cell.tile) {
			continue;
		}
		TileRef corner = cell.tile;
		if (corner->upper != NM("fence1_NE")) {
			continue;
		}
		if (corner->biome != NM("graveyard") && (!corner->route || !has(corner->route->name, "graveyard"))) {
			continue;
		}
		for (int64_t width = 4; width < 9; width++) {
			TileRef right(gen.get_tile(tiles, corner->position + Vector2i((int32_t)(width * 16), 0)));
			if (!right || right->upper != NM("fence1_NW") || right->route != corner->route) {
				continue;
			}
			for (int64_t height = 4; height < 10; height++) {
				TileRef left_top(gen.get_tile(tiles, corner->position + Vector2i(0, (int32_t)(height * 16))));
				TileRef right_top(gen.get_tile(tiles, right->position + Vector2i(0, (int32_t)(height * 16))));
				if (!left_top || !right_top || left_top->upper != NM("fence1_SE") || right_top->upper != NM("fence1_SW")) {
					continue;
				}
				if (left_top->route != corner->route || right_top->route != corner->route) {
					continue;
				}
				for (int64_t row = 1; row < height; row++) {
					const int32_t xs[2] = { corner->position.x, right->position.x };
					for (int32_t x : xs) {
						Tile *side = gen.get_tile(tiles, Vector2i(x, (int32_t)(corner->position.y + row * 16)));
						if (!side || side->route != corner->route) {
							continue;
						}
						std::string upper = lower(S(side->upper));
						if (upper.find("door") != std::string::npos || upper.find("gate") != std::string::npos || upper.find("gravestone") != std::string::npos || upper.find("pokedoll") != std::string::npos) {
							continue;
						}
						if (upper.empty() || upper.compare(0, 6, "fence1") == 0 || upper.compare(0, 5, "grass") == 0) {
							if (side->upper != NM("fence1_NS")) {
								gen.set_names(side, side->name, NM("fence1_NS"));
							}
						}
					}
				}
			}
		}
	}
}

static bool is_facade(Tile *p_tile) {
	return begins(p_tile->upper, "pkmnmansion_ext") || begins(p_tile->upper, "pkmnmansion_roof");
}

void Adapter::normalize_oasis_facades() {
	std::vector<Route *> order;
	AHashMap<Route *, std::vector<TileRef>, PtrHasher> facades;
	for (Cell &cell : tiles.values()) {
		if (cell.is_int() || !cell.tile) {
			continue;
		}
		Tile *tile = cell.tile.get();
		if (!tile->route || tile->route->name != NM("oasis1") || !is_facade(tile)) {
			continue;
		}
		Route *key = tile->route.get();
		if (!facades.has(key)) {
			facades.insert(key, {});
			order.push_back(key);
		}
		facades.getptr(key)->push_back(cell.tile);
	}
	for (Route *key : order) {
		std::vector<TileRef> &facade = *facades.getptr(key);
		int32_t low = 2147483647;
		int32_t high = -2147483647 - 1;
		for (TileRef &tile : facade) {
			low = MIN(low, tile->position.y);
			high = MAX(high, tile->position.y);
		}
		TileMap replacements;
		for (TileRef &tile : facade) {
			Vector2i at(tile->position.x, low + high - tile->position.y);
			gen.put(replacements, at, gen.copy_at(tile.get(), at));
			tiles.erase(tile->position);
		}
		tiles.merge(replacements, true);
	}
}

void Adapter::repair_mansion_roof_grass() {
	// GenIsland1.generateMansion: 31 columns, roof rows 3..28.
	std::vector<Route *> order;
	AHashMap<Route *, std::vector<std::pair<std::string, TileRef>>, PtrHasher> groups;
	for (Cell &cell : tiles.values()) {
		if (cell.is_int() || !cell.tile) {
			continue;
		}
		const TileRef &tile = cell.tile;
		if (!tile->route) {
			continue;
		}
		if (!(tile->upper == NM("pkmnmansion_roof_NW") || tile->upper == NM("pkmnmansion_roof_NE") || tile->upper == NM("pkmnmansion_roof_SW") || tile->upper == NM("pkmnmansion_roof_SE"))) {
			continue;
		}
		Route *key = tile->route.get();
		if (!groups.has(key)) {
			groups.insert(key, {});
			order.push_back(key);
		}
		std::string suffix = S(tile->upper).substr(strlen("pkmnmansion_roof_"));
		auto &group = *groups.getptr(key);
		bool replaced = false;
		for (auto &entry : group) {
			if (entry.first == suffix) {
				entry.second = tile;
				replaced = true;
			}
		}
		if (!replaced) {
			group.push_back({ suffix, tile });
		}
	}
	for (Route *key : order) {
		auto &group = *groups.getptr(key);
		if (group.size() != 4) {
			continue;
		}
		auto find = [&](const char *p_suffix) -> TileRef {
			for (auto &entry : group) {
				if (entry.first == p_suffix) {
					return entry.second;
				}
			}
			return TileRef();
		};
		TileRef nw = find("NW");
		TileRef ne = find("NE");
		TileRef sw = find("SW");
		TileRef se = find("SE");
		if (ne->position.x - nw->position.x != 30 * 16 || ABS(sw->position.y - nw->position.y) != 25 * 16) {
			continue;
		}
		if (sw->position.x != nw->position.x || se->position.x != ne->position.x || ne->position.y != nw->position.y || se->position.y != sw->position.y) {
			continue;
		}
		for (int64_t y = MIN(nw->position.y, sw->position.y); y < (int64_t)MAX(nw->position.y, sw->position.y) + 16; y += 16) {
			for (int64_t x = nw->position.x; x < (int64_t)ne->position.x + 16; x += 16) {
				Vector2i position((int32_t)x, (int32_t)y);
				Tile *tile = gen.peek_tile(position);
				if (!tile) {
					continue;
				}
				bool grass_base = begins(tile->name, "grass") || begins(tile->name, "green");
				bool grass_upper = begins(tile->upper, "grass");
				if (!grass_base && !grass_upper) {
					continue;
				}
				if (tile->upper != 0 && !grass_upper && !begins(tile->upper, "pkmnmansion_roof")) {
					continue;
				}
				std::string suffix = y == nw->position.y ? "N" : (y == sw->position.y ? "S" : "");
				suffix += x == nw->position.x ? "W" : (x == ne->position.x ? "E" : "");
				std::string upper = "pkmnmansion_roof" + (suffix.empty() ? std::string() : "_" + suffix);
				gen.put(tiles, position, gen.make(NM("sand1"), position, intern(upper), true, nw->route));
			}
		}
	}
}

void Adapter::normalize_mansion_exterior() {
	// The large non-oasis exterior: the route with most facade tiles.
	std::vector<Route *> order;
	AHashMap<Route *, std::pair<RouteRef, int64_t>, PtrHasher> route_counts;
	for (Cell &cell : tiles.values()) {
		if (cell.is_int() || !cell.tile) {
			continue;
		}
		Tile *tile = cell.tile.get();
		if (!tile->route || !is_facade(tile)) {
			continue;
		}
		if (lower(S(tile->route->name)) == "oasis1") {
			continue;
		}
		Route *key = tile->route.get();
		auto *known = route_counts.getptr(key);
		if (known) {
			known->second += 1;
		} else {
			route_counts.insert(key, std::make_pair(tile->route, (int64_t)1));
			order.push_back(key);
		}
	}
	RouteRef mansion_route;
	int64_t mansion_count = -1;
	for (Route *key : order) {
		auto *entry = route_counts.getptr(key);
		if (entry->second > mansion_count) {
			mansion_count = entry->second;
			mansion_route = entry->first;
		}
	}
	if (!mansion_route) {
		return;
	}
	std::vector<Vector2i> route_positions;
	int32_t minimum_y = 2147483647;
	int32_t maximum_y = -2147483647 - 1;
	for (Cell &cell : tiles.values()) {
		if (cell.is_int() || !cell.tile) {
			continue;
		}
		Tile *tile = cell.tile.get();
		if (tile->route != mansion_route || !is_facade(tile)) {
			continue;
		}
		route_positions.push_back(tile->position);
		minimum_y = MIN(minimum_y, tile->position.y);
		maximum_y = MAX(maximum_y, tile->position.y);
	}
	if (route_positions.empty()) {
		return;
	}
	OMap<Vector2i, Vector2i> position_map;
	TileMap replacements;
	for (const Vector2i &old_position : route_positions) {
		Tile *tile = gen.get_tile(tiles, old_position);
		if (!tile) {
			continue;
		}
		Vector2i new_position(old_position.x, minimum_y + maximum_y - old_position.y);
		position_map.set(old_position, new_position);
		gen.put(replacements, new_position, gen.copy_at(tile, new_position));
	}
	for (const Vector2i &old_position : route_positions) {
		tiles.erase(old_position);
	}
	replacements.each([&](const Vector2i &p_position, const Cell &p_cell) {
		tiles.set(p_position, p_cell);
	});
	OMap<Vector2i, Dictionary> remapped;
	pokemon.each([&](const Vector2i &p_old, const Dictionary &p_record) {
		const Vector2i *mapped = position_map.getp(p_old);
		Vector2i new_position = mapped ? *mapped : p_old;
		Dictionary record = p_record.duplicate(true);
		if (mapped) {
			record["position"] = new_position;
		}
		remapped.set(new_position, record);
	});
	pokemon = remapped;
	for (int index = 0; index < gen.burrowed_pokemon.size(); index++) {
		Dictionary record = gen.burrowed_pokemon[index];
		Vector2i old_position = record.get("position", Vector2i());
		const Vector2i *mapped = position_map.getp(old_position);
		if (mapped) {
			record["position"] = *mapped;
		}
	}
	for (TileRef &edge : edges) {
		const Vector2i *mapped = position_map.getp(edge->position);
		if (mapped) {
			const Cell *replacement = tiles.getp(*mapped);
			if (replacement && replacement->tile) {
				edge = replacement->tile;
			}
		}
	}
}

// --- WorldTileStore.from_dictionary(...).to_record() and the result

static Dictionary pack_store(Gen &p_gen, std::vector<RouteRef> &r_routes, AHashMap<Route *, int32_t, PtrHasher> &r_route_slots) {
	TileMap &tiles = p_gen.tiles_to_add;
	bool first = true;
	Rect2i bounds;
	tiles.each([&](const Vector2i &p_key, const Cell &) {
		Vector2i cell = p_key / 16;
		if (first) {
			bounds = Rect2i(cell, Vector2i(1, 1));
			first = false;
		} else {
			bounds = bounds.expand(cell);
		}
	});
	if (!first) {
		bounds.size += Vector2i(1, 1);
	}
	int64_t width = bounds.size.x;
	int64_t height = bounds.size.y;
	int64_t cells = width * height;
	PackedInt32Array flags, name_ids, upper_ids, biome_ids, shore_ocean_ids, shore_tidal_ids, ledge_dir_ids, has_item_ids, amounts, route_ids;
	for (PackedInt32Array *array : { &flags, &name_ids, &upper_ids, &biome_ids, &shore_ocean_ids, &shore_tidal_ids, &ledge_dir_ids, &has_item_ids, &amounts, &route_ids }) {
		array->resize(cells);
		array->fill(0);
	}
	int32_t *flag_data = flags.ptrw();
	int32_t *name_data = name_ids.ptrw();
	int32_t *upper_data = upper_ids.ptrw();
	int32_t *biome_data = biome_ids.ptrw();
	int32_t *ocean_data = shore_ocean_ids.ptrw();
	int32_t *tidal_data = shore_tidal_ids.ptrw();
	int32_t *ledge_data = ledge_dir_ids.ptrw();
	int32_t *item_data = has_item_ids.ptrw();
	int32_t *amount_data = amounts.ptrw();
	int32_t *route_data = route_ids.ptrw();
	PackedStringArray strings;
	strings.push_back("");
	AHashMap<int, int32_t> string_ids;
	string_ids.insert(0, 0);
	auto sid = [&](int p_name) -> int32_t {
		int32_t *known = string_ids.getptr(p_name);
		if (known) {
			return *known;
		}
		int32_t id = strings.size();
		strings.push_back(gs(p_name));
		string_ids.insert(p_name, id);
		return id;
	};
	Dictionary items;
	Dictionary doors;
	int64_t count = 0;
	tiles.each([&](const Vector2i &p_key, const Cell &p_cell) {
		Tile *tile = p_cell.is_int() ? p_gen.ocean_tiles[p_cell.ocean].get() : p_cell.tile.get();
		if (!tile) {
			return;
		}
		Vector2i at = p_key / 16 - bounds.position;
		int64_t index = (int64_t)at.y * width + at.x;
		if (!(flag_data[index] & 1)) {
			count += 1;
		}
		int32_t bits = 1;
		if (tile->is(F_COLOR)) {
			bits |= 2;
		}
		if (tile->is(F_SOLID)) {
			bits |= 4;
		}
		if (tile->is(F_LEDGE)) {
			bits |= 8;
		}
		if (tile->is(F_WATER)) {
			bits |= 16;
		}
		if (tile->is(F_GRASS)) {
			bits |= 32;
		}
		if (tile->is(F_CUTTABLE)) {
			bits |= 64;
		}
		if (tile->is(F_HEADBUTT)) {
			bits |= 128;
		}
		if (tile->is(F_TIDAL)) {
			bits |= 256;
		}
		if (tile->is(F_LAVA)) {
			bits |= 512;
		}
		if (tile->is(F_BOTTOM)) {
			bits |= 1024;
		}
		flag_data[index] = bits;
		name_data[index] = sid(tile->name);
		upper_data[index] = sid(tile->upper);
		biome_data[index] = sid(tile->biome);
		ocean_data[index] = sid(tile->shore_ocean);
		tidal_data[index] = sid(tile->shore_tidal);
		ledge_data[index] = sid(tile->ledge_dir);
		item_data[index] = sid(tile->has_item);
		amount_data[index] = (int32_t)tile->amount;
		int32_t slot = 0;
		if (tile->route) {
			int32_t *known = r_route_slots.getptr(tile->route.get());
			if (known) {
				slot = *known;
			} else {
				r_routes.push_back(tile->route);
				slot = (int32_t)r_routes.size();
				r_route_slots.insert(tile->route.get(), slot);
			}
		}
		route_data[index] = slot;
		if (!tile->items || tile->items->list.empty()) {
			items.erase(index);
		} else {
			items[index] = tile->items->to_dictionary();
		}
		if (!tile->doors || tile->doors->empty()) {
			doors.erase(index);
		} else {
			Array list;
			for (const Vector2i &door : *tile->doors) {
				list.push_back(door);
			}
			doors[index] = list;
		}
	});
	Dictionary record;
	record["origin"] = bounds.position;
	record["width"] = width;
	record["height"] = height;
	record["count"] = count;
	record["flags"] = flags;
	record["name"] = name_ids;
	record["upper"] = upper_ids;
	record["biome"] = biome_ids;
	record["shore_ocean"] = shore_ocean_ids;
	record["shore_tidal"] = shore_tidal_ids;
	record["ledge_dir"] = ledge_dir_ids;
	record["has_item"] = has_item_ids;
	record["amount"] = amounts;
	record["route"] = route_ids;
	record["items"] = items;
	record["doors"] = doors;
	record["strings"] = strings;
	record["route_count"] = (int64_t)r_routes.size();
	return record;
}

static Array tile_record(Tile *p_tile, AHashMap<Route *, int32_t, PtrHasher> &p_route_slots, std::vector<RouteRef> &r_routes) {
	int32_t route_index = -1;
	if (p_tile->route) {
		int32_t *known = p_route_slots.getptr(p_tile->route.get());
		if (known) {
			route_index = *known - 1;
		} else {
			r_routes.push_back(p_tile->route);
			route_index = (int32_t)r_routes.size() - 1;
			p_route_slots.insert(p_tile->route.get(), route_index + 1);
		}
	}
	Array record;
	record.push_back(gs(p_tile->name));
	record.push_back(p_tile->position);
	record.push_back(gs(p_tile->upper));
	record.push_back(p_tile->is(F_COLOR));
	record.push_back(route_index);
	record.push_back(gs(p_tile->biome));
	record.push_back((int64_t)p_tile->flags);
	record.push_back(gs(p_tile->ledge_dir));
	record.push_back(gs(p_tile->shore_ocean));
	record.push_back(gs(p_tile->shore_tidal));
	record.push_back(gs(p_tile->has_item));
	record.push_back(p_tile->amount);
	record.push_back(p_tile->items ? Variant(p_tile->items->to_dictionary()) : Variant());
	if (p_tile->doors) {
		Array list;
		for (const Vector2i &door : *p_tile->doors) {
			list.push_back(door);
		}
		record.push_back(list);
	} else {
		record.push_back(Variant());
	}
	return record;
}

static Dictionary finish_world(Gen &p_gen, const Dictionary &p_report) {
	Adapter adapter(p_gen);
	adapter.pokemon = p_gen.pokemon_to_add;
	adapter.repair_regi_mansion_overlap();
	adapter.repair_graveyard_side_fences();
	adapter.edges = p_gen.edges;
	adapter.normalize_oasis_facades();
	adapter.repair_mansion_roof_grass();
	adapter.normalize_mansion_exterior();
	std::vector<RouteRef> routes;
	AHashMap<Route *, int32_t, PtrHasher> route_slots;
	Dictionary store = pack_store(p_gen, routes, route_slots);
	// Interior tiles: one record per object (a tile can sit under two keys).
	Array tile_records;
	AHashMap<Tile *, int32_t, PtrHasher> tile_ids;
	Array interiors;
	for (size_t index = 0; index < p_gen.interior_tiles_to_add.size(); index++) {
		const Layer &layer = p_gen.interior_tiles_to_add[index];
		if (!layer) {
			interiors.push_back(Variant());
			continue;
		}
		PackedInt32Array keys;
		PackedInt32Array ids;
		layer->each([&](const Vector2i &p_key, const Cell &p_cell) {
			Tile *tile = p_cell.tile.get();
			int32_t *known = tile_ids.getptr(tile);
			int32_t id;
			if (known) {
				id = *known;
			} else {
				id = tile_records.size();
				tile_records.push_back(tile_record(tile, route_slots, routes));
				tile_ids.insert(tile, id);
			}
			keys.push_back(p_key.x);
			keys.push_back(p_key.y);
			ids.push_back(id);
		});
		Array packed;
		packed.push_back(keys);
		packed.push_back(ids);
		interiors.push_back(packed);
	}
	Array route_records;
	for (RouteRef &route : routes) {
		Array record;
		record.push_back(gs(route->name));
		record.push_back(route->level);
		record.push_back(route->stored);
		record.push_back(route->musics_index);
		record.push_back(route->is_dungeon);
		record.push_back(route->dont_spawn);
		route_records.push_back(record);
	}
	Dictionary pokemon;
	adapter.pokemon.each([&](const Vector2i &p_position, const Dictionary &p_record) {
		pokemon[p_position] = p_record;
	});
	Array edges;
	for (TileRef &edge : adapter.edges) {
		edges.push_back(edge->position);
	}
	TypedArray<String> used;
	for (const std::string &name : p_gen.already_used_dungeons) {
		used.push_back(String::utf8(name.c_str()));
	}
	Dictionary result;
	result["store"] = store;
	result["routes"] = route_records;
	result["interior_tiles"] = tile_records;
	result["interiors"] = interiors;
	result["interior_pokemon"] = p_gen.interior_pokemon;
	result["pokemon"] = pokemon;
	result["burrowed_pokemon"] = p_gen.burrowed_pokemon;
	result["edges"] = edges;
	result["bottom_left"] = p_gen.area_bottom_left;
	result["top_right"] = p_gen.area_top_right;
	result["already_used_dungeons"] = used;
	result["regi_relocated_cells"] = adapter.regi_relocated_cells;
	result["landmark_origins"] = p_gen.landmark_origins;
	result["generation_validation"] = p_report;
	return result;
}

static const int64_t RADII[5] = { 30000, 40000, 50000, 54000, 56000 };

Dictionary generate_world(int64_t p_seed, int p_size_index, const TypedArray<String> &p_used_dungeons, Object *p_data, bool p_qa) {
	ERR_FAIL_NULL_V(p_data, Dictionary());
	uint64_t started = OS::get_singleton()->get_ticks_usec();
	int64_t radius = RADII[CLAMP(p_size_index, 0, 4)];
	Data data(p_data);
	std::vector<std::string> used;
	for (int index = 0; index < p_used_dungeons.size(); index++) {
		used.push_back(String(p_used_dungeons[index]).utf8().get_data());
	}
	Array failures;
	Array qa_lines;
	for (int64_t attempt = 0; attempt < 3; attempt++) {
		// Attempt zero keeps the save's seed; retries are deterministic.
		int64_t attempt_seed = attempt == 0 ? p_seed : ((p_seed ^ (attempt * 0x9E3779B9LL)) & 281474976710655LL);
		Gen gen(data, Vector2i(), radius, attempt_seed ^ 0x50C3E811LL, attempt_seed, attempt_seed ^ 0x6F72657374LL, attempt_seed ^ 0x506F6B656D6F6ELL);
		gen.qa = p_qa;
		gen.generate_complete(used);
		uint64_t validation_started = OS::get_singleton()->get_ticks_usec();
		Dictionary report = gen.validate();
		report["elapsed_ms"] = (int64_t)((OS::get_singleton()->get_ticks_usec() - validation_started) / 1000);
		report["attempt"] = attempt;
		report["attempt_seed"] = attempt_seed;
		for (const String &line : gen.qa_lines) {
			qa_lines.push_back(line);
		}
		int64_t zero_bounds = gen.random.zero_bounds + gen.global_random.zero_bounds + gen.forest_biome_random.zero_bounds + gen.pokemon_random.zero_bounds;
		if (bool(report["ok"])) {
			Dictionary result = finish_world(gen, report);
			result["generation_failures"] = failures;
			result["native_qa"] = qa_lines;
			// Steps where GDScript debug builds would have stopped with an error.
			result["native_warnings"] = (int64_t)data.warnings + zero_bounds;
			result["native_ms"] = (int64_t)((OS::get_singleton()->get_ticks_usec() - started) / 1000);
			return result;
		}
		failures.push_back(report);
	}
	Dictionary error;
	error["generation_error"] = "World validation failed after 3 attempts. Please try another world.";
	error["generation_failures"] = failures;
	error["native_qa"] = qa_lines;
	return error;
}

} // namespace pw
