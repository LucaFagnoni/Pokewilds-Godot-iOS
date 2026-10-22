// Ledges, rivers, the ocean and the landmarks with their interiors
// (source_island_generator.gd).

#include "island.h"

#include "core/math/vector3i.h"

#include <algorithm>
#include <deque>
#include <queue>

namespace pw {

static Dictionary crystal() {
	Dictionary extra;
	extra["generation"] = "CRYSTAL";
	return extra;
}

static Rect2i centered_rect(Vector2i p_center, Vector2i p_size) {
	return Rect2i(p_center - p_size / 2, p_size);
}

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

static void add_dungeon(std::vector<std::string> &p_used, const char *p_name) {
	if (!contains(p_used, std::string(p_name))) {
		p_used.push_back(p_name);
	}
}

// --- ledgify

static const Vector2i LEDGIFY_OFFSETS[8] = {
	Vector2i(-16, 0), Vector2i(16, 0), Vector2i(0, 16), Vector2i(0, -16),
	Vector2i(-16, 16), Vector2i(16, 16), Vector2i(-16, -16), Vector2i(16, -16)
};

static const Vector2i BLOCK_OFFSETS_9[9] = {
	Vector2i(0, 0), Vector2i(16, 0), Vector2i(-16, 0), Vector2i(0, 16), Vector2i(0, -16),
	Vector2i(16, 16), Vector2i(-16, 16), Vector2i(-16, -16), Vector2i(16, -16)
};

void Gen::neighbour_names(TileMap &p_tiles, Vector2i p_position, int p_null_name, int r_names[8]) {
	for (int index = 0; index < 8; index++) {
		const Cell *cell = p_tiles.getp(p_position + LEDGIFY_OFFSETS[index]);
		if (!cell) {
			r_names[index] = p_null_name;
		} else if (cell->mark) {
			data.warnings++;
			r_names[index] = p_null_name;
		} else {
			r_names[index] = name_of(*cell);
		}
	}
}

bool Gen::ledgify_replaces(TileMap &p_tiles, Vector2i p_position, int p_tile_type, int p_null_name) {
	const Cell *current = p_tiles.getp(p_position);
	if (current && !current->mark && name_of(*current) != p_tile_type) {
		return false;
	}
	int names[8];
	neighbour_names(p_tiles, p_position, p_null_name, names);
	bool left_same = names[0] == p_tile_type;
	bool right_same = names[1] == p_tile_type;
	bool up_same = names[2] == p_tile_type;
	bool down_same = names[3] == p_tile_type;
	bool top_left_same = names[4] == p_tile_type;
	bool top_right_same = names[5] == p_tile_type;
	bool bottom_left_same = names[6] == p_tile_type;
	bool bottom_right_same = names[7] == p_tile_type;
	return (!left_same && !right_same) || (!up_same && !down_same) || !(up_same || left_same || bottom_right_same) || !(up_same || right_same || bottom_left_same) || !(down_same || right_same || top_left_same) || !(down_same || left_same || top_right_same) || (down_same && !left_same && !bottom_right_same) || (down_same && !right_same && !bottom_left_same) || (up_same && !left_same && !top_right_same) || (up_same && !right_same && !top_left_same) || (right_same && !up_same && !bottom_right_same) || (right_same && !down_same && !top_right_same) || (left_same && !down_same && !top_left_same) || (left_same && !up_same && !bottom_left_same);
}

void Gen::ledgify_replace(TileMap &p_tiles, TileMap &p_next_island_tiles, Vector2i p_position, int p_replace_with, int p_biome) {
	TileRef replacement = make(p_replace_with, p_position);
	replacement->biome = p_biome;
	put(p_tiles, p_position, replacement);
	put(p_next_island_tiles, p_position, replacement);
}

void Gen::ledgify(TileMap &p_tiles, TileMap &p_next_island_tiles, int p_tile_type, int p_replace_with, int p_biome, int p_null_type) {
	int ledge_type = has(p_tile_type, "volcano") ? NM("ledges3volcano") : NM("ledges3");
	// A missing neighbour reads as a fresh tile of null_type.
	int null_name = make(p_null_type == 0 ? NM("black1") : p_null_type, Vector2i())->name;
	// First of the source's sweeps; it repeats them until one replaces nothing.
	std::vector<Vector2i> changed;
	for (Cell &cell : p_next_island_tiles.values()) {
		if (cell.is_int() || !cell.tile) {
			continue;
		}
		Tile *tile = cell.tile.get();
		if (tile->name == p_tile_type && ledgify_replaces(p_tiles, tile->position, p_tile_type, null_name)) {
			ledgify_replace(p_tiles, p_next_island_tiles, tile->position, p_replace_with, p_biome);
			changed.push_back(tile->position);
		}
	}
	if (!changed.empty()) {
		ledgify_later_sweeps(p_tiles, p_next_island_tiles, p_tile_type, p_replace_with, p_biome, null_name, changed);
	}
	for (Cell &cell : p_next_island_tiles.values()) {
		if (cell.is_int() || !cell.tile) {
			continue;
		}
		const Cell *current = p_tiles.getp(cell.tile->position);
		if (!current || current->is_int() || !current->tile || current->tile->name != p_tile_type) {
			continue;
		}
		TileRef tile = current->tile;
		int names[8];
		neighbour_names(p_tiles, tile->position, null_name, names);
		bool left = names[0] == p_tile_type;
		bool right = names[1] == p_tile_type;
		bool up = names[2] == p_tile_type;
		bool down = names[3] == p_tile_type;
		bool top_left = names[4] == p_tile_type;
		bool top_right = names[5] == p_tile_type;
		bool bottom_left = names[6] == p_tile_type;
		bool bottom_right = names[7] == p_tile_type;
		const char *suffix = "";
		if (left && !down && right) {
			suffix = "_N";
		} else if (up && right && !down && !left) {
			suffix = "_NE";
		} else if (up && !left && down) {
			suffix = "_E";
		} else if (!up && !left && right && down) {
			suffix = "_SE";
		} else if (!up && left && right) {
			suffix = "_S";
		} else if (!up && down && left && !right) {
			suffix = "_SW";
		} else if (up && down && !right) {
			suffix = "_W";
		} else if (up && left && !down && !right) {
			suffix = "_NW";
		} else if (!bottom_right && down && right) {
			suffix = "_NW_inner";
		} else if (!bottom_left && down && left) {
			suffix = "_NE_inner";
		} else if (!top_right && up && right) {
			suffix = "_SW_inner";
		} else if (!top_left && up && left) {
			suffix = "_SE_inner";
		}
		if (suffix[0] != 0) {
			TileRef ledge = make(p_tile_type, tile->position, intern(S(ledge_type) + suffix));
			ledge->biome = p_biome;
			put(p_tiles, tile->position, ledge);
		}
	}
}

// The source's later full sweeps, visiting only what can change (see GDScript).
void Gen::ledgify_later_sweeps(TileMap &p_tiles, TileMap &p_next_island_tiles, int p_tile_type, int p_replace_with, int p_biome, int p_null_name, const std::vector<Vector2i> &p_changed) {
	std::vector<Vector2i> keys = p_next_island_tiles.keys();
	bool plain = false;
	for (const Vector2i &key : keys) {
		const Cell *entry = p_next_island_tiles.getp(key);
		if (!entry->is_int() && (!entry->tile || entry->tile->position != key)) {
			plain = true;
			break;
		}
	}
	if (plain) {
		bool done = false;
		while (!done) {
			done = true;
			for (Cell &cell : p_next_island_tiles.values()) {
				if (cell.is_int() || !cell.tile) {
					continue;
				}
				Tile *tile = cell.tile.get();
				if (tile->name == p_tile_type && ledgify_replaces(p_tiles, tile->position, p_tile_type, p_null_name)) {
					ledgify_replace(p_tiles, p_next_island_tiles, tile->position, p_replace_with, p_biome);
					done = false;
				}
			}
		}
		return;
	}
	AHashMap<Vector2i, int32_t> key_index;
	key_index.reserve((uint32_t)keys.size());
	for (size_t index = 0; index < keys.size(); index++) {
		key_index.insert(keys[index], (int32_t)index);
	}
	auto index_of = [&](Vector2i p_position) -> int32_t {
		const int32_t *found = key_index.getptr(p_position);
		return found ? *found : -1;
	};
	std::vector<uint8_t> queued(keys.size());
	std::priority_queue<int32_t, std::vector<int32_t>, std::greater<int32_t>> heap;
	for (const Vector2i &position : p_changed) {
		for (const Vector2i &offset : BLOCK_OFFSETS_9) {
			int32_t index = index_of(position + offset);
			if (index >= 0 && queued[index] == 0) {
				queued[index] = 1;
				heap.push(index);
			}
		}
	}
	while (!heap.empty()) {
		std::vector<int32_t> next_sweep;
		while (!heap.empty()) {
			int32_t index = heap.top();
			heap.pop();
			queued[index] = 0;
			Vector2i position = keys[index];
			if (name_of(*p_next_island_tiles.getp(position)) != p_tile_type || !ledgify_replaces(p_tiles, position, p_tile_type, p_null_name)) {
				continue;
			}
			ledgify_replace(p_tiles, p_next_island_tiles, position, p_replace_with, p_biome);
			for (const Vector2i &offset : BLOCK_OFFSETS_9) {
				int32_t other = index_of(position + offset);
				if (other < 0) {
					continue;
				}
				if (other > index) {
					if (queued[other] == 0) {
						queued[other] = 1;
						heap.push(other);
					}
				} else {
					next_sweep.push_back(other);
				}
			}
		}
		for (int32_t index : next_sweep) {
			if (queued[index] == 0) {
				queued[index] = 1;
				heap.push(index);
			}
		}
	}
}

// --- Rivers and the ocean

double Gen::source_river_product(Vector2i p_position, double p_scale, double p_ratio) {
	double river_angle = f32(-Math::rad_to_deg(Math::atan(p_ratio)));
	Vector2 rotated = rotate_deg(Vector2(p_position), river_angle);
	double scale = f32(p_scale);
	double wavelength_product = f32(scale * f32(4.0));
	double sine_input = f32(f32((double)rotated.x) / wavelength_product);
	double offset_3 = f32(f32(Math::sin(sine_input)) * f32(4.0));
	double scaled_y = f32(f32((double)rotated.y) / scale);
	double shifted_y = f32(scaled_y - offset_3);
	double offset_1 = f32(Math::abs((double)(Math::posmod((int64_t)shifted_y, (int64_t)14) - 7)) * 2.0);
	double offset_2 = f32(Math::abs((double)(Math::posmod((int64_t)shifted_y, (int64_t)20) - 10)) * 2.0);
	return f32(f32(offset_1 * 5.0) * offset_2);
}

static double river_ratio(Vector2i p_position) {
	if (p_position.y == 0) {
		return p_position.x < 0 ? -Math::INF : Math::INF;
	}
	return f32((double)p_position.x / (double)p_position.y);
}

bool Gen::river_contains(Vector2i p_position) {
	return source_river_product(p_position, 60.0, river_ratio(p_position)) > 850.0;
}

void Gen::apply_source_rivers(const std::vector<TileRef> &p_desert_tiles) {
	// The original object-identity test, not by position: tiles are replaced.
	AHashMap<Tile *, bool, PtrHasher> desert_members;
	for (const TileRef &tile : p_desert_tiles) {
		desert_members.insert(tile.get(), true);
	}
	RouteRef river_route = route(NM("wooded_lake_water1"), 30);
	for (Cell &cell : tiles_to_add.values()) {
		Tile *tile = cell.tile.get();
		if (!tile) {
			continue;
		}
		if (tile->tidal()) {
			continue;
		}
		RouteRef tile_route = river_route;
		int tile_name = NM("water2");
		double scale = 60.0;
		double threshold = 850.0;
		if (desert_members.has(tile)) {
			tile_name = NM("sand1");
			tile_route = tile->route;
			threshold = 1250.0;
		}
		if (mountain_tiles.has(tile->position)) {
			if (no_ice_here.has(tile->position)) {
				continue;
			}
			if (tile->biome == NM("tundra")) {
				tile_name = NM("ice2");
				tile_route = tile->route;
			}
			if (bottom_mountain_layer.has(tile->position)) {
				tile_name = NM("sand3_tidalwater");
				if (tile->biome == NM("desert")) {
					continue;
				}
			}
			scale = 59.0;
		}
		if (source_river_product(tile->position, scale, river_ratio(tile->position)) > threshold && tile_name != NM("waterfall1")) {
			tile->route = tile_route;
			set_names(tile, tile_name);
			pokemon_to_add.erase(tile->position);
		}
	}
}

void Gen::fill_source_ocean(Vector2i p_minimum, Vector2i p_maximum) {
	Vector2i boundary_min = p_minimum - Vector2i(672, 672);
	Vector2i boundary_max(p_maximum.x + 672, p_maximum.y + 336);
	Vector2i fill_maximum = p_maximum + Vector2i(896, 448);
	Vector2i fill_minimum = p_minimum - Vector2i(896, 896);
	RouteRef ocean_route = route(NM("ocean1"), 40);
	ocean_tiles.clear();
	for (int kind = 0; kind < 4; kind++) {
		ocean_tiles.push_back(make((kind & 1) ? NM("water2_edge1") : NM("water2"), Vector2i(), 0, true, (kind & 2) ? ocean_route : RouteRef()));
	}
	for (int64_t x = fill_minimum.x; x < (int64_t)fill_maximum.x + 1; x += 16) {
		for (int64_t y = fill_minimum.y; y < (int64_t)fill_maximum.y + 1; y += 16) {
			Vector2i position((int32_t)x, (int32_t)y);
			if (tiles_to_add.has(position)) {
				continue;
			}
			int kind = y == fill_maximum.y ? 1 : 0;
			if (!(position.x >= boundary_min.x && position.x <= boundary_max.x && position.y >= boundary_min.y && position.y <= boundary_max.y)) {
				kind |= 2;
			}
			Cell ocean;
			ocean.ocean = (int8_t)kind;
			tiles_to_add.set(position, ocean);
		}
	}
	area_bottom_left = fill_minimum;
	area_top_right = fill_maximum;
}

// --- Landmark placement

bool Gen::rect_contains_mountain(const Rect2i &p_rect) {
	for (const auto &entry : mountain_tiles.entries) {
		if (entry.live && p_rect.has_point(entry.key)) {
			return true;
		}
	}
	return false;
}

void Gen::place_source_landmarks(const std::vector<TileRef> &p_desert_tiles, const std::vector<TileRef> &p_deep_forest_tiles, std::vector<Rect2i> &r_hitboxes, Rect2i &r_mansion_box) {
	std::vector<Rect2i> hitboxes = { Rect2i(0, 0, 1056, 1056), Rect2i(0, 0, 640, 640), Rect2i(0, 0, 208, 160) };
	Variant origins[3];
	Rect2i mansion_box = centered_rect(Vector2i(0, 224), Vector2i(528, 496));
	int64_t landmark_index = 0;
	int64_t tries = 0;
	while (landmark_index < 3) {
		if (landmark_index == 0 && done_desert_ruins) {
			landmark_index += 1;
			continue;
		}
		if (landmark_index == 2 && done_regi_dungeon) {
			landmark_index += 1;
			continue;
		}
		const std::vector<TileRef> &candidates = landmark_index < 2 && !p_desert_tiles.empty() ? p_desert_tiles : p_deep_forest_tiles;
		if (candidates.empty()) {
			// Source-size maps always have candidates.
			origins[landmark_index] = Vector2i();
			landmark_index += 1;
			continue;
		}
		TileRef chosen = candidates[random.next_int((int64_t)candidates.size())];
		Vector2i chosen_origin = chosen->position;
		if (landmark_index == 0) {
			int64_t alignment_tries = 0;
			while (alignment_tries < 80 && !p_desert_tiles.empty() && (chosen_origin.x % 32 != 0 || chosen_origin.y % 32 != 16)) {
				chosen = p_desert_tiles[random.next_int((int64_t)p_desert_tiles.size())];
				chosen_origin = chosen->position;
				alignment_tries += 1;
			}
		}
		origins[landmark_index] = chosen_origin;
		hitboxes[landmark_index] = centered_rect(chosen_origin, hitboxes[landmark_index].size);
		if (landmark_index == 0 && hitboxes[landmark_index].intersects(mansion_box)) {
			continue;
		}
		if (landmark_index > 1 && rect_contains_mountain(hitboxes[landmark_index])) {
			continue;
		}
		bool worked = true;
		for (int64_t previous_index = 0; previous_index < landmark_index; previous_index++) {
			if (hitboxes[landmark_index].intersects(hitboxes[previous_index])) {
				worked = false;
				break;
			}
		}
		if (worked || tries > 10) {
			landmark_index += 1;
			tries = 0;
			continue;
		}
		tries += 1;
	}
	if (!done_desert_ruins) {
		generate_desert_ruins(origins[0]);
		already_used_dungeons.push_back("desert_ruins1");
		done_desert_ruins = true;
	}
	generate_oasis(origins[1]);
	landmark_origins.clear();
	for (const Variant &origin_value : origins) {
		landmark_origins.push_back(origin_value);
	}
	r_hitboxes = hitboxes;
	r_mansion_box = mansion_box;
}

static bool mountain_near(const TileMap &p_mountains, Vector2i p_position, bool p_corners) {
	static const Vector2i far[3] = { Vector2i(0, -368), Vector2i(-224, 0), Vector2i(144, -240) };
	static const Vector2i near[4] = { Vector2i(32, 32), Vector2i(-32, 32), Vector2i(32, -32), Vector2i(-32, -32) };
	for (const Vector2i &offset : far) {
		if (p_mountains.has(p_position + offset)) {
			return true;
		}
	}
	if (p_corners) {
		for (const Vector2i &offset : near) {
			if (p_mountains.has(p_position + offset)) {
				return true;
			}
		}
	}
	return false;
}

void Gen::cleanup_and_place_deep_forest_landmarks(const std::vector<TileRef> &p_deep_forest_tiles, const std::vector<Rect2i> &p_hitboxes, Rect2i p_mansion_box) {
	bool complete = false;
	Rect2i mansion_box = p_mansion_box;
	TileMap mansion_exterior;
	while (!complete) {
		complete = true;
		bool restart_pass = false;
		std::vector<Cell> pass = tiles_to_add.values();
		for (Cell &raw_tile : pass) {
			// Untouched ocean: no tree, rock, cactus, pokemon, door or forest.
			if (raw_tile.is_int() || !raw_tile.tile) {
				continue;
			}
			TileRef tile = raw_tile.tile;
			if (has(tile->name, "tree_large1")) {
				repair_incomplete_large_tree(tile.get());
			} else if (tile->name == NM("rock1")) {
				remove_blocking_rock(tile.get());
			} else if (tile->upper == NM("cactus10")) {
				Vector2i solid_position = tile->position + Vector2i(16, 0);
				put(tiles_to_add, solid_position, make(NM("desert4"), solid_position, NM("solid"), true, tile->route));
			}
			if (pokemon_to_add.has(tile->position) && ((tile->solid() && !has(tile->name, "water")) || has(tile->name, "ledge") || has(tile->name, "door") || has(tile->upper, "door"))) {
				pokemon_to_add.erase(tile->position);
			}
			if (tile->biome == NM("deep_forest") && !done_pkmn_mansion && !mountain_near(mountain_tiles, tile->position, false)) {
				Vector2i mansion_position = tile->position;
				if (radius < 40000) {
					mansion_position = Vector2i(0, 224);
				}
				mansion_box = centered_rect(mansion_position, Vector2i(528, 496));
				if (mansion_box.intersects(p_hitboxes[0]) || mansion_box.intersects(p_hitboxes[1])) {
					continue;
				}
				add_dungeon(already_used_dungeons, "mansion1");
				done_pkmn_mansion = true;
				complete = false;
				mansion_exterior = generate_mansion(mansion_position);
				restart_pass = true;
				break;
			}
			Tile *down_tile = peek_tile(tile->position + Vector2i(0, -16));
			if (tile->biome == NM("deep_forest") && has(tile->name, "green") && !done_pkmn_mansion_key && down_tile && !has(down_tile->upper, "tree")) {
				done_pkmn_mansion_key = true;
				complete = false;
				put(tiles_to_add, tile->position, make(tile->name, tile->position, NM("pokemon_mansion_key"), true));
				restart_pass = true;
				break;
			}
			if (tile->biome != NM("deep_forest") || done_regi_dungeon || mountain_near(mountain_tiles, tile->position, true) || random.next_int(3) != 2) {
				continue;
			}
			Rect2i regi_box = centered_rect(tile->position, Vector2i(208, 160));
			bool collides_with_mansion = false;
			for (const auto &entry : mansion_exterior.entries) {
				if (entry.live && regi_box.has_point(entry.value.tile->position)) {
					collides_with_mansion = true;
					break;
				}
			}
			if (collides_with_mansion) {
				continue;
			}
			add_dungeon(already_used_dungeons, "regi1");
			done_regi_dungeon = true;
			complete = false;
			generate_regi_dungeon(tile->position);
			restart_pass = true;
			break;
		}
		if (restart_pass) {
			continue;
		}
	}
	// Required per-map dungeons: retry over the same deep-forest candidates.
	if (!done_pkmn_mansion) {
		for (const TileRef &candidate : p_deep_forest_tiles) {
			if (!candidate || candidate->biome != NM("deep_forest")) {
				continue;
			}
			if (mountain_near(mountain_tiles, candidate->position, false)) {
				continue;
			}
			Rect2i candidate_box = centered_rect(candidate->position, Vector2i(528, 496));
			if (candidate_box.intersects(p_hitboxes[0]) || candidate_box.intersects(p_hitboxes[1])) {
				continue;
			}
			mansion_box = candidate_box;
			add_dungeon(already_used_dungeons, "mansion1");
			done_pkmn_mansion = true;
			mansion_exterior = generate_mansion(candidate->position);
			break;
		}
	}
	if (!done_regi_dungeon) {
		for (const TileRef &candidate : p_deep_forest_tiles) {
			if (!candidate || candidate->biome != NM("deep_forest")) {
				continue;
			}
			if (mountain_near(mountain_tiles, candidate->position, true)) {
				continue;
			}
			Rect2i regi_box = centered_rect(candidate->position, Vector2i(208, 160));
			bool collides = false;
			for (const auto &entry : mansion_exterior.entries) {
				if (entry.live && regi_box.has_point(entry.value.tile->position)) {
					collides = true;
					break;
				}
			}
			if (collides) {
				continue;
			}
			add_dungeon(already_used_dungeons, "regi1");
			done_regi_dungeon = true;
			generate_regi_dungeon(candidate->position);
			break;
		}
	}
}

static const std::vector<const char *> TREE_POKEMON = { "pineco", "aipom", "kakuna", "metapod", "spinarak", "heracross", "ledyba", "hoothoot", "zubat", "pidgey", "spearow", "forretress", "applin" };

void Gen::repair_incomplete_large_tree(Tile *p_tile) {
	bool found = false;
	for (int64_t j = 0; j < 2 && !found; j++) {
		for (int64_t k = 0; k < 2; k++) {
			Vector2i top_left = p_tile->position + Vector2i((int32_t)(-16 * j), (int32_t)(16 * k));
			Vector2i top_right_position = p_tile->position + Vector2i((int32_t)(-16 * j + 16), (int32_t)(16 * k));
			Vector2i bottom_left_position = p_tile->position + Vector2i((int32_t)(-16 * j), (int32_t)(16 * k - 16));
			Vector2i bottom_right_position = p_tile->position + Vector2i((int32_t)(-16 * j + 16), (int32_t)(16 * k - 16));
			Tile *top_left_tile = peek_tile(top_left);
			Tile *top_right_tile = peek_tile(top_right_position);
			Tile *bottom_left_tile = peek_tile(bottom_left_position);
			Tile *bottom_right_tile = peek_tile(bottom_right_position);
			if (top_left_tile && top_left_tile->name == NM("tree_large1_noSprite") && top_right_tile && top_right_tile->name == NM("tree_large1_noSprite") && bottom_left_tile && bottom_left_tile->name == NM("tree_large1") && bottom_right_tile && bottom_right_tile->name == NM("tree_large1_noSprite")) {
				found = true;
				break;
			}
		}
	}
	if (found) {
		return;
	}
	if (random.next_int(3) == 2) {
		p_tile->route = route(NM(""), 22);
		append_stored(p_tile->route.get(), TREE_POKEMON, 20, 4);
	}
	// Fields changed without init(), as the Java source does.
	p_tile->set(F_COLOR, true);
	p_tile->name = NM("bush1");
	p_tile->upper = 0;
}

bool Gen::any_solid(const Vector2i *p_positions, int p_count) {
	for (int index = 0; index < p_count; index++) {
		Tile *tile = peek_tile(p_positions[index]);
		if (tile && tile->solid()) {
			return true;
		}
	}
	return false;
}

void Gen::remove_blocking_rock(Tile *p_tile) {
	Vector2i p = p_tile->position;
	const Vector2i left_side[3] = { p + Vector2i(-16, 0), p + Vector2i(-16, 16), p + Vector2i(-16, -16) };
	const Vector2i right_side[3] = { p + Vector2i(16, 0), p + Vector2i(16, 16), p + Vector2i(16, -16) };
	const Vector2i up_side[3] = { p + Vector2i(0, 16), p + Vector2i(-16, 16), p + Vector2i(16, 16) };
	const Vector2i down_side[3] = { p + Vector2i(0, -16), p + Vector2i(-16, -16), p + Vector2i(16, -16) };
	bool left = any_solid(left_side, 3);
	bool right = any_solid(right_side, 3);
	bool up = any_solid(up_side, 3);
	bool down = any_solid(down_side, 3);
	if ((left && right) || (up && down)) {
		put(tiles_to_add, p, make(NM("sand1"), p, 0, true, p_tile->route));
	}
}

// --- Oasis and fossil lab

void Gen::generate_oasis(Vector2i p_origin) {
	RouteRef oasis_route = route(NM("oasis1"), 30);
	TileRef origin_tile(tile_at(p_origin));
	ERR_FAIL_COND(!origin_tile);
	origin_tile->biome = NM("desert");
	int64_t next_size = 250 + random.next_int(50);
	TileMap new_tiles;
	apply_blotch("oasis1", origin_tile, next_size, new_tiles, 0, true, oasis_route);
	TileMap pond_tiles;
	next_size = next_size / 2;
	apply_blotch("pond1", origin_tile, next_size, pond_tiles, 0, true, oasis_route);
	spawn(origin_tile->position, "milotic", 44);
	new_tiles.merge(pond_tiles, true);
	for (Cell &cell : new_tiles.values()) {
		Tile *tile = cell.tile.get();
		if (tile->upper == NM("aloe_large1")) {
			static const Vector2i offsets[3] = { Vector2i(16, 0), Vector2i(0, 16), Vector2i(16, 16) };
			for (const Vector2i &offset : offsets) {
				put(new_tiles, tile->position + offset, make(NM("green1"), tile->position + offset, NM("solid"), true, tile->route));
			}
		}
	}
	std::vector<TileRef> oasis_tiles;
	for (Cell &cell : new_tiles.values()) {
		TileRef tile = cell.tile;
		if (mountain_tiles.has(tile->position)) {
			continue;
		}
		if (!has(tile->name, "water")) {
			oasis_tiles.push_back(tile);
		}
		put(tiles_to_add, tile->position, tile);
	}
	if (oasis_tiles.empty()) {
		return;
	}
	int64_t pick = random.next_int((int64_t)oasis_tiles.size());
	TileRef building_origin = oasis_tiles[pick];
	oasis_tiles.erase(oasis_tiles.begin() + pick);
	Layer lab_layer = std::make_shared<TileMap>();
	RouteRef lab_route = route(NM("fossil_lab1"), 11);
	const std::vector<std::vector<int>> &lab_rows = data.layout("generateOasis", 0);
	for (size_t row_index = 0; row_index < lab_rows.size(); row_index++) {
		for (size_t column = 0; column < lab_rows[row_index].size(); column++) {
			if (lab_rows[row_index][column] < 0) {
				continue;
			}
			Vector2i position = building_origin->position + Vector2i((int32_t)(-96 + column * 16), (int32_t)(80 - (int64_t)row_index * 16));
			put(*lab_layer, position, make(lab_rows[row_index][column], position, 0, true, lab_route));
		}
	}
	merge_interior_layer(100, lab_layer);
	TileMap exterior;
	const std::vector<std::vector<int>> &facade_rows = data.layout("generateOasis", 1);
	for (size_t row_index = 0; row_index < facade_rows.size(); row_index++) {
		for (size_t column = 0; column < facade_rows[row_index].size(); column++) {
			if (facade_rows[row_index][column] < 0) {
				continue;
			}
			Vector2i position = building_origin->position + Vector2i((int32_t)(-96 + column * 16), (int32_t)(80 - (int64_t)row_index * 16));
			put(exterior, position, make(NM("sand1"), position, facade_rows[row_index][column], true, building_origin->route));
		}
	}
	merge_exterior_preserving_mansion_key(exterior);
	capture("fossil_lab", building_origin->position, exterior, { { 100, lab_layer } });
}

// --- Regi cave

std::vector<Vector2i> Gen::regi_exterior_positions(Vector2i p_origin) {
	std::vector<Vector2i> positions;
	const std::vector<std::vector<int>> &rows = data.layout("generateRegiDungeon", 0);
	for (size_t row_index = 0; row_index < rows.size(); row_index++) {
		for (size_t column = 0; column < rows[row_index].size(); column++) {
			if (rows[row_index][column] >= 0) {
				positions.push_back(p_origin + Vector2i((int32_t)(-96 + column * 16), (int32_t)(80 - (int64_t)row_index * 16)));
			}
		}
	}
	return positions;
}

void Gen::generate_regi_dungeon(Vector2i p_origin) {
	TileMap exterior;
	RouteRef exterior_route = route(NM(""), 2);
	const std::vector<std::vector<int>> &rows = data.layout("generateRegiDungeon", 0);
	for (size_t row_index = 0; row_index < rows.size(); row_index++) {
		for (size_t column = 0; column < rows[row_index].size(); column++) {
			if (rows[row_index][column] < 0) {
				continue;
			}
			Vector2i position = p_origin + Vector2i((int32_t)(-96 + column * 16), (int32_t)(80 - (int64_t)row_index * 16));
			put(exterior, position, make(rows[row_index][column], position, 0, true, exterior_route));
		}
	}
	Vector2i interior_origin = p_origin + Vector2i(-288, 272);
	Layer interior = std::make_shared<TileMap>();
	RouteRef interior_route = route(NM("regi_cave1"), 44);
	const std::vector<std::vector<int>> &chamber = data.layout("generateRegiDungeon", 1);
	for (size_t row_index = 0; row_index < chamber.size(); row_index++) {
		for (size_t column = 0; column < chamber[row_index].size(); column++) {
			if (chamber[row_index][column] < 0) {
				continue;
			}
			Vector2i position = interior_origin + Vector2i((int32_t)(column * 16), (int32_t)(-(int64_t)row_index * 16));
			TileRef tile = make(chamber[row_index][column], position, 0, true, interior_route);
			if (chamber[row_index][column] == NM("cave1_regipedistal1")) {
				tile->items.reset(new Items);
				for (const char *regi : { "REGISTEEL", "REGICE", "REGIROCK", "REGIELEKI", "REGIDRAGO" }) {
					tile->items->set(regi, 1);
				}
			}
			put(*interior, position, tile);
		}
	}
	merge_exterior_preserving_mansion_key(exterior);
	merge_interior_layer(90, interior);
	capture("regi", p_origin, exterior, { { 90, interior } });
}

// --- Desert ruins and the mine below

void Gen::generate_desert_ruins(Vector2i p_origin) {
	RouteRef ruins_route = route(NM("ruins1_outer"), 25);
	TileRef origin_tile(tile_at(p_origin));
	ERR_FAIL_COND(!origin_tile);
	TileMap ruins_tiles;
	TileMap generated;
	apply_blotch("ruins1_upper2", origin_tile, 230, generated, 0, false, ruins_route);
	ruins_tiles.merge(generated, true);
	generated.clear();
	apply_blotch("ruins1_upper", origin_tile, 240, generated, 0, false, ruins_route);
	ruins_tiles.merge(generated, true);
	for (Cell &cell : ruins_tiles.values()) {
		if (has(cell.tile->name, "ruins1")) {
			adjust_ruins_tile(cell.tile.get(), ruins_tiles);
		}
	}
	for (Cell &cell : ruins_tiles.values()) {
		if (!mountain_tiles.has(cell.tile->position)) {
			put(tiles_to_add, cell.tile->position, cell.tile);
		}
	}
	for (int64_t x_offset = -1; x_offset < 2; x_offset++) {
		for (int64_t y_offset = -1; y_offset < 2; y_offset++) {
			Vector2i position = origin_tile->position + Vector2i((int32_t)(16 * x_offset), (int32_t)(16 * y_offset));
			Tile *tile = peek_tile(position);
			if (tile && tile->name != NM("desert4")) {
				put(tiles_to_add, position, make(NM("ruins_floor2"), position, 0, true));
			}
		}
	}
	const Vector2i pillars[4] = {
		origin_tile->position + Vector2i(-32, 16), origin_tile->position + Vector2i(32, 16),
		origin_tile->position + Vector2i(-32, -16), origin_tile->position + Vector2i(32, -16)
	};
	for (const Vector2i &position : pillars) {
		if (random.next_int(3) > 0) {
			put(tiles_to_add, position, make(NM("ruins1_pillar1"), position, 0, true));
		}
	}
	put(tiles_to_add, origin_tile->position, make(NM("ruins1_NSEW"), origin_tile->position, NM("stairs_down2"), true, ruins_route));
	generate_ruins_interior(origin_tile->position);
	// The mine record is captured by the interior generator; add its surface entry.
	validation_records.back().exterior.set(origin_tile->position, signature(tiles_to_add.getp(origin_tile->position)->tile.get()));
}

void Gen::adjust_ruins_tile(Tile *p_tile, TileMap &p_layer) {
	if (has(p_tile->name, "pillar")) {
		return;
	}
	std::vector<std::string> tokens = split(S(p_tile->name), "_");
	std::string base_name = tokens[0];
	for (size_t index = 1; index + 1 < tokens.size(); index++) {
		base_name += "_" + tokens[index];
	}
	std::string extension = "_";
	static const Vector2i check_offsets[4] = { Vector2i(0, 16), Vector2i(0, -16), Vector2i(16, 0), Vector2i(-16, 0) };
	static const char *check_names[4] = { "N", "S", "E", "W" };
	for (int index = 0; index < 4; index++) {
		Tile *adjacent = as_tile(p_layer.getp(p_tile->position + check_offsets[index]));
		if (adjacent && S(adjacent->name).find(base_name) != std::string::npos) {
			extension += check_names[index];
		}
	}
	set_names(p_tile, intern(base_name + extension), p_tile->upper);
}

void Gen::generate_ruins_interior(Vector2i p_origin) {
	const std::vector<std::vector<int>> &fixed_rows = data.layout("generateRuinsInterior", 0);
	std::vector<Layer> interior_tiles;
	for (int index = 0; index < 5; index++) {
		interior_tiles.push_back(std::make_shared<TileMap>());
	}
	Vector2i start_location(10, 10);
	Vector2i layout_origin = p_origin - Vector2i(496, 496);
	std::vector<Vector2i> start_locations;
	std::vector<Vector2i> endpoints = { start_location };
	std::vector<Vector2i> dusclops_positions;
	RouteRef inner_route = route(NM("ruins1_inner"), 22);
	const int64_t last_level = (int64_t)interior_tiles.size() - 1;
	for (int64_t level_number = last_level; level_number >= 0; level_number--) {
		TileMap &current_layer = *interior_tiles[level_number];
		if (level_number == 0) {
			for (size_t row_index = 0; row_index < fixed_rows.size(); row_index++) {
				for (size_t column = 0; column < fixed_rows[row_index].size(); column++) {
					int source_name = fixed_rows[row_index][column];
					if (source_name < 0) {
						continue;
					}
					Vector2i start_position = endpoints[0];
					Vector2i position = layout_origin + Vector2i((int32_t)((start_position.x * 3 - 3 + (int64_t)column) * 16), (int32_t)((start_position.y * 3 + 17 - (int64_t)row_index) * 16));
					TileRef tile;
					if (source_name == NM("ruins_floor2_stairs")) {
						tile = make(NM("blank1"), position, NM("stairs_up1"), true, inner_route);
					} else if (source_name == NM("pedistal1")) {
						tile = make(NM("ruins_floor2"), position, NM("pedistal1"), true, inner_route);
					} else {
						tile = make(source_name, position, 0, true, inner_route);
					}
					if (has(source_name, "pillar")) {
						tile->items_get().set("torch", 1);
					}
					if (row_index == 2 && column == 4) {
						set_names(tile.get(), tile->name, NM("volcarona"));
					}
					put(current_layer, position, tile);
				}
			}
			continue;
		}
		double complexity = 15.0;
		for (const Vector2i &endpoint : endpoints) {
			int upper = level_number == last_level ? NM("stairs_up1_exit") : NM("stairs_up1");
			Vector2i stair_position = layout_origin + Vector2i((endpoint.x * 3 + 1) * 16, (endpoint.y * 3 + 1) * 16);
			put(current_layer, stair_position, make(NM("desert4"), stair_position, upper, true, inner_route));
			start_locations.push_back(endpoint);
			start_locations.push_back(endpoint);
			if (random.next_int(2) != 0 && level_number != last_level) {
				continue;
			}
			start_locations.push_back(endpoint);
			if (level_number != last_level) {
				complexity = 10.0;
			}
		}
		endpoints.clear();
		const int64_t width = 20;
		const int64_t height = 20;
		Maze maze = maze_algo3(width, height, complexity, (double)start_locations.size(), random, start_locations);
		dusclops_positions.clear();
		for (int64_t maze_x = 0; maze_x < maze.width; maze_x++) {
			for (int64_t maze_y = 0; maze_y < maze.height; maze_y++) {
				if (!maze.get(maze_x, maze_y)) {
					continue;
				}
				for (int64_t sub_x = 0; sub_x < 3; sub_x++) {
					for (int64_t sub_y = 0; sub_y < 4; sub_y++) {
						Vector2i position = layout_origin + Vector2i((int32_t)((maze_x * 3 + sub_x) * 16), (int32_t)((maze_y * 3 + sub_y) * 16));
						Tile *existing = as_tile(current_layer.getp(position));
						if (existing && !has(existing->name, "wall")) {
							continue;
						}
						if (sub_y == 3) {
							TileRef wall = make(NM("ruins2_wall1"), position, 0, true);
							if (level_number != last_level && maze_x % 2 == 0 && sub_x == 1 && random.next_int(4) > 0) {
								wall->items_get().set("torch", 1);
							}
							put(current_layer, position, wall);
						} else {
							int tile_name = NM("desert4");
							int64_t offset = ABS((maze_x * 3 + sub_x) % 12 - 6) + ABS((maze_y * 3 + sub_y) % 12 - 6);
							if (level_number == last_level) {
								tile_name = NM("desert4_isGrass");
								if (random.next_int(offset + 1) + offset > 14) {
									tile_name = NM("ruins_floor2");
								}
							} else if (level_number == last_level - 1) {
								tile_name = NM("desert4_isGrass");
								if (random.next_int(offset + 1) + offset > 10) {
									tile_name = NM("ruins_floor2");
								}
							} else if (level_number == last_level - 2) {
								if (random.next_int(offset + 1) + offset > 7) {
									tile_name = NM("ruins_floor2");
								}
							} else {
								tile_name = NM("ruins_floor2");
							}
							put(current_layer, position, make(tile_name, position, 0, true, inner_route));
						}
						if (level_number < 3 && sub_x == 1 && sub_y == 1 && maze_x % 3 == 0 && maze_y % 3 == 0) {
							dusclops_positions.push_back(position);
						}
					}
				}
				Vector2i maze_position((int32_t)maze_x, (int32_t)maze_y);
				if (!contains(start_locations, maze_position) && maze_x % 2 == 0 && maze_y % 2 == 0 && random.next_int(3) == 0) {
					std::vector<Vector2i> pot_positions;
					if (maze_y - 1 >= 0 && !maze.get(maze_x, maze_y - 1)) {
						for (int64_t sub_x = 0; sub_x < 3; sub_x++) {
							pot_positions.push_back(layout_origin + Vector2i((int32_t)((maze_x * 3 + sub_x) * 16), (int32_t)(maze_y * 3 * 16)));
						}
					}
					if (maze_y + 1 < height && !maze.get(maze_x, maze_y + 1)) {
						for (int64_t sub_x = 0; sub_x < 3; sub_x++) {
							pot_positions.push_back(layout_origin + Vector2i((int32_t)((maze_x * 3 + sub_x) * 16), (int32_t)((maze_y * 3 + 2) * 16)));
						}
					}
					if (maze_x + 1 < width && !maze.get(maze_x + 1, maze_y)) {
						for (int64_t sub_y = 0; sub_y < 3; sub_y++) {
							pot_positions.push_back(layout_origin + Vector2i((int32_t)((maze_x * 3 + 2) * 16), (int32_t)((maze_y * 3 + sub_y) * 16)));
						}
					}
					if (maze_x - 1 >= 0 && !maze.get(maze_x - 1, maze_y)) {
						for (int64_t sub_y = 0; sub_y < 3; sub_y++) {
							pot_positions.push_back(layout_origin + Vector2i((int32_t)(maze_x * 3 * 16), (int32_t)((maze_y * 3 + sub_y) * 16)));
						}
					}
					for (const Vector2i &position : pot_positions) {
						if (random.next_int(7) > 3) {
							Tile *tile = as_tile(current_layer.getp(position));
							if (tile) {
								set_names(tile, tile->name, NM("pot1"));
							}
						}
					}
					continue;
				}
				if (level_number == 1 && maze_x % 2 == 0 && maze_y % 2 == 0 && random.next_int(2) == 0) {
					Vector2i position = layout_origin + Vector2i((int32_t)((maze_x * 3 + 1) * 16), (int32_t)((maze_y * 3 + 1) * 16));
					Tile *tile = as_tile(current_layer.getp(position));
					if (tile && tile->upper == 0) {
						set_names(tile, tile->name, NM("ruins_statue1"));
					}
				}
			}
		}
		int64_t dusclops_size = (int64_t)dusclops_positions.size();
		int64_t spawn_index = 0;
		// `2 + random.next_int(3)` is drawn again at every test of the loop.
		while (spawn_index < 2 + random.next_int(3) && spawn_index < dusclops_size) {
			int64_t pick = random.next_int((int64_t)dusclops_positions.size());
			Vector2i position = dusclops_positions[pick];
			dusclops_positions.erase(dusclops_positions.begin() + pick);
			Dictionary extra;
			extra["name"] = "dusclops";
			extra["level"] = 44;
			extra["generation"] = "CRYSTAL";
			extra["position"] = position;
			extra["area_index"] = level_number + 95;
			extra["aggressive"] = true;
			interior_pokemon.push_back(make_pokemon_record("dusclops", 44, extra));
			spawn_index += 1;
		}
		int64_t start_count = (int64_t)start_locations.size();
		int64_t number_of_stairs = level_number == 1 ? 1 : 2;
		for (int64_t stair_index = 0; stair_index < start_count; stair_index++) {
			int64_t pick = random.next_int((int64_t)start_locations.size());
			start_location = start_locations[pick];
			start_locations.erase(start_locations.begin() + pick);
			if (stair_index < number_of_stairs) {
				for (int64_t sub_x = 0; sub_x < 3; sub_x++) {
					for (int64_t sub_y = 0; sub_y < 3; sub_y++) {
						Vector2i position = layout_origin + Vector2i((int32_t)((start_location.x * 3 + sub_x) * 16), (int32_t)((start_location.y * 3 + sub_y) * 16));
						if (sub_x == 1 && sub_y == 1) {
							put(current_layer, position, make(NM("ruins_floor2"), position, NM("stairs_down2"), true, inner_route));
						} else if (random.next_int(5) > 1) {
							put(current_layer, position, make(NM("ruins_floor2"), position, 0, true, inner_route));
						} else {
							put(current_layer, position, make(NM("desert4"), position, 0, true, inner_route));
						}
					}
				}
				endpoints.push_back(start_location);
			} else {
				int64_t number_of_pots = 0;
				for (int64_t sub_x = 0; sub_x < 3; sub_x++) {
					for (int64_t sub_y = 0; sub_y < 3; sub_y++) {
						Vector2i position = layout_origin + Vector2i((int32_t)((start_location.x * 3 + sub_x) * 16), (int32_t)((start_location.y * 3 + sub_y) * 16));
						TileRef tile(as_tile(current_layer.getp(position)));
						if (sub_x == 1 && sub_y == 1) {
							if (!tile || has(tile->upper, "stairs")) {
								continue;
							}
							set_names(tile.get(), tile->name, NM("pokeball1"));
							if (random.next_int(2) == 0) {
								tile->has_item = NM("ultra ball");
								tile->amount = 2;
							} else {
								tile->has_item = NM("ancientpowder");
								tile->amount = random.next_int(3) + 2;
							}
						} else if (random.next_int(7) > 3 && number_of_pots < 2 && tile) {
							put(current_layer, position, make(tile->name, position, NM("pot1"), true, inner_route));
							number_of_pots += 1;
						}
					}
				}
			}
		}
		start_locations.clear();
	}
	interior_tiles.push_back(std::make_shared<TileMap>());
	for (size_t index = 0; index < interior_tiles.size(); index++) {
		merge_interior_layer((int)index + 95, interior_tiles[index]);
	}
	std::vector<std::pair<int, Layer>> validation_layers;
	for (int index = 0; index < 5; index++) {
		validation_layers.push_back({ index + 95, interior_tiles[index] });
	}
	TileMap no_exterior;
	capture("mine", p_origin, no_exterior, validation_layers);
}

// --- Pokemon mansion

std::vector<bool> Gen::mansion_axis_pattern(int64_t p_length, int64_t p_forced_gap, int64_t p_level) {
	std::vector<int64_t> sizes = { 1, 2, 4, 5, 2, 4, 5 };
	if (p_level < 4) {
		sizes.insert(sizes.end(), { 4, 2, 4, 2 });
	}
	std::vector<bool> result;
	int64_t counter = 0;
	for (int64_t index = 0; index < p_length; index++) {
		if (index == p_forced_gap) {
			result.push_back(false);
		} else if (counter == 0) {
			result.push_back(true);
			int64_t pick = random.next_int((int64_t)sizes.size());
			ERR_FAIL_COND_V(pick >= (int64_t)sizes.size(), result);
			counter = sizes[pick];
			sizes.erase(sizes.begin() + pick);
		} else {
			result.push_back(false);
			counter -= 1;
		}
	}
	result.push_back(true);
	return result;
}

TileMap Gen::generate_mansion(Vector2i p_origin) {
	const int64_t height = 28;
	const int64_t width = 30;
	TileMap exterior;
	std::vector<Layer> mansion_interiors(95);
	mansion_interiors.push_back(std::make_shared<TileMap>());
	Vector2i layout_origin = p_origin - Vector2i((int32_t)(width * 16 / 2), (int32_t)(height * 16 / 2));
	RouteRef exterior_route = route(NM("snow1"), 40);
	int64_t windows = 0;
	for (int64_t row_index = -8; row_index < height + 1; row_index++) {
		windows = random.next_int(2) + 1;
		for (int64_t column = 0; column < width + 1; column++) {
			if (column == width - 1) {
				windows = 1;
			}
			Vector2i position = layout_origin + Vector2i((int32_t)(column * 16), (int32_t)(row_index * 16));
			int base = NM("sand1");
			int upper = 0;
			bool place = true;
			if (row_index < 0 && (column == width / 2 || column == width / 2 + 1)) {
				base = random.next_int(6) <= 1 ? NM("sand1") : NM("path1");
			} else if (row_index == -2) {
				base = random.next_int(24) == 0 ? NM("flower4") : NM("green1");
			} else if (row_index == -1) {
				base = NM("sand1");
			} else if (row_index == 0) {
				if (column == 0) {
					upper = NM("pkmnmansion_ext_SW");
				} else if (column == width) {
					upper = NM("pkmnmansion_ext_SE");
				} else if (column == width / 2) {
					upper = NM("pkmnmansion_ext_locked");
				} else {
					upper = windows != 0 ? NM("pkmnmansion_ext_S_windows") : NM("pkmnmansion_ext_S");
				}
			} else if (row_index == 1 || row_index == 2) {
				if (column == 0) {
					upper = NM("pkmnmansion_ext_W");
				} else if (column == width) {
					upper = NM("pkmnmansion_ext_E");
				} else {
					upper = windows != 0 ? NM("pkmnmansion_ext_windows") : NM("pkmnmansion_ext");
				}
			} else if (row_index == 3) {
				if (column == 0) {
					upper = NM("pkmnmansion_roof_SW");
				} else if (column == width) {
					upper = NM("pkmnmansion_roof_SE");
				} else {
					upper = NM("pkmnmansion_roof_S");
				}
			} else if (row_index == height) {
				if (column == 0) {
					upper = NM("pkmnmansion_roof_NW");
				} else if (column == width) {
					upper = NM("pkmnmansion_roof_NE");
				} else {
					upper = NM("pkmnmansion_roof_N");
				}
			} else if (row_index > 0) {
				if (column == 0) {
					upper = NM("pkmnmansion_roof_W");
				} else if (column == width) {
					upper = NM("pkmnmansion_roof_E");
				} else {
					upper = NM("pkmnmansion_roof");
				}
			} else {
				place = false;
			}
			if (place) {
				put(exterior, position, make(base, position, upper, true, exterior_route));
			}
			if (random.next_int(1 + windows) == 0) {
				windows = (windows + 1) % 2;
			}
		}
	}
	layout_origin -= Vector2i(64, 64);
	for (int64_t level_number = 0; level_number < 6; level_number++) {
		RouteRef level_route = route(NM("pkmnmansion1"), 40 - level_number * 2);
		std::vector<bool> row_is_solid = mansion_axis_pattern(27 + (4 - level_number) * 2, 26 + (4 - level_number) * 2, level_number);
		std::vector<bool> column_is_solid = mansion_axis_pattern(29 + (4 - level_number) * 2, 28 + (4 - level_number) * 2, level_number);
		int64_t number_of_rows = 0;
		for (bool value : row_is_solid) {
			if (value) {
				number_of_rows += 2;
			}
		}
		int64_t number_of_columns = 0;
		for (bool value : column_is_solid) {
			if (value) {
				number_of_columns += 2;
			}
		}
		// The final sentinel is not part of numRows/numCols.
		number_of_rows -= 2;
		number_of_columns -= 2;
		Maze maze = maze_algo2(number_of_columns, number_of_rows, 0.05, 0.7, random);
		Layer layer = std::make_shared<TileMap>();
		mansion_interiors.push_back(layer);
		int64_t maze_y = 0;
		for (size_t row_index = 0; row_index < row_is_solid.size(); row_index++) {
			int64_t maze_x = 0;
			for (size_t column = 0; column < column_is_solid.size(); column++) {
				Vector2i position = layout_origin + Vector2i((int32_t)(column * 16), (int32_t)(row_index * 16));
				if (maze.get(maze_x, maze_y)) {
					put(*layer, position, make(NM("pkmnmansion_wall"), position, 0, true));
				} else {
					put(*layer, position, make(NM("pkmnmansion_floor1"), position, 0, true, level_route));
				}
				if (column_is_solid[column] || (column + 1 < column_is_solid.size() && column_is_solid[column + 1])) {
					maze_x += 1;
				}
			}
			if (row_is_solid[row_index] || (row_index + 1 < row_is_solid.size() && row_is_solid[row_index + 1])) {
				maze_y += 1;
			}
		}
		replace_small_mansion_wall_islands(*layer);
		style_mansion_walls(*layer);
		damage_mansion_walls(*layer);
		place_mansion_shelves(*layer);
		place_mansion_tables(*layer, layout_origin);
		layout_origin += Vector2i(16, 16);
	}
	layout_origin -= Vector2i(32, 32);
	connect_mansion_floors(mansion_interiors, layout_origin);
	for (size_t index = 0; index < mansion_interiors.size(); index++) {
		if (mansion_interiors[index]) {
			merge_interior_layer((int)index, mansion_interiors[index]);
		}
	}
	merge_exterior_preserving_mansion_key(exterior);
	std::vector<std::pair<int, Layer>> validation_layers;
	for (int index = 95; index < 102; index++) {
		validation_layers.push_back({ index, mansion_interiors[index] });
	}
	capture("mansion", p_origin, exterior, validation_layers);
	return exterior;
}

static const Vector2i FOUR[4] = { Vector2i(-16, 0), Vector2i(16, 0), Vector2i(0, 16), Vector2i(0, -16) };

void Gen::replace_small_mansion_wall_islands(TileMap &p_layer) {
	PosSet already_checked;
	for (const Vector2i &position : p_layer.keys()) {
		Tile *tile = p_layer.getp(position)->tile.get();
		if (already_checked.has(position) || !tile->solid()) {
			continue;
		}
		already_checked[position] = true;
		int64_t size = 0;
		std::vector<Vector2i> found = { position };
		std::deque<Vector2i> check;
		for (const Vector2i &offset : FOUR) {
			check.push_back(position + offset);
		}
		while (!check.empty()) {
			Vector2i next = check.front();
			check.pop_front();
			if (already_checked.has(next)) {
				continue;
			}
			already_checked[next] = true;
			Tile *next_tile = as_tile(p_layer.getp(next));
			if (!next_tile || !next_tile->solid()) {
				continue;
			}
			size += 1;
			found.push_back(next);
			for (const Vector2i &offset : FOUR) {
				check.push_back(next + offset);
			}
		}
		if (size < 10) {
			for (const Vector2i &found_position : found) {
				put(p_layer, found_position, make(NM("tree_plant1"), found_position, 0, true));
			}
		}
	}
}

bool Gen::is_mansion_wall(TileMap &p_layer, Vector2i p_position) {
	Tile *tile = as_tile(p_layer.getp(p_position));
	return tile && has(tile->name, "pkmnmansion_wall");
}

bool Gen::solid_at(TileMap &p_layer, Vector2i p_position) {
	Tile *tile = as_tile(p_layer.getp(p_position));
	return tile && tile->solid();
}

void Gen::style_mansion_walls(TileMap &p_layer) {
	for (const Vector2i &position : p_layer.keys()) {
		if (!is_mansion_wall(p_layer, position)) {
			continue;
		}
		bool left = is_mansion_wall(p_layer, position + Vector2i(-16, 0));
		bool right = is_mansion_wall(p_layer, position + Vector2i(16, 0));
		bool up = is_mansion_wall(p_layer, position + Vector2i(0, 16));
		bool down = is_mansion_wall(p_layer, position + Vector2i(0, -16));
		int tile_name = NM("pkmnmansion_wall");
		if (down && up) {
			tile_name = NM("pkmnmansion_wall_NS");
		} else if (down && left) {
			tile_name = random.next_int(2) == 0 ? NM("pkmnmansion_wall_N") : NM("pkmnmansion_wall_NE");
		} else if (down && right) {
			tile_name = random.next_int(2) == 0 ? NM("pkmnmansion_wall_N") : NM("pkmnmansion_wall_NW");
		} else if (down) {
			tile_name = NM("pkmnmansion_wall_N");
		} else if (up && left) {
			tile_name = random.next_int(2) == 0 ? NM("pkmnmansion_wall_S") : NM("pkmnmansion_wall_E");
		} else if (up && right) {
			tile_name = random.next_int(2) == 0 ? NM("pkmnmansion_wall_S") : NM("pkmnmansion_wall_W");
		} else if (up) {
			tile_name = NM("pkmnmansion_wall_S");
		} else if (left && right) {
			continue;
		} else if (left) {
			tile_name = NM("pkmnmansion_wall_E");
		} else if (right) {
			tile_name = NM("pkmnmansion_wall_W");
		} else {
			continue;
		}
		put(p_layer, position, make(tile_name, position, 0, true));
	}
}

void Gen::damage_mansion_walls(TileMap &p_layer) {
	PosSet already_checked;
	for (const Vector2i &position : p_layer.keys()) {
		if (already_checked.has(position)) {
			continue;
		}
		already_checked[position] = true;
		Tile *start_tile = p_layer.getp(position)->tile.get();
		if (!has(start_tile->name, "pkmnmansion_wall") || random.next_int(13) != 0) {
			continue;
		}
		int64_t size = 0;
		std::deque<Vector2i> check;
		for (const Vector2i &offset : FOUR) {
			check.push_back(position + offset);
		}
		while (!check.empty()) {
			Vector2i next = check.front();
			check.pop_front();
			if (already_checked.has(next)) {
				continue;
			}
			already_checked[next] = true;
			Tile *tile = as_tile(p_layer.getp(next));
			if (!tile) {
				continue;
			}
			if (!tile->solid()) {
				bool left = solid_at(p_layer, next + Vector2i(-16, 0));
				bool top_left = solid_at(p_layer, next + Vector2i(-16, 16));
				bool bottom_left = solid_at(p_layer, next + Vector2i(-16, -16));
				bool right = solid_at(p_layer, next + Vector2i(16, 0));
				bool top_right = solid_at(p_layer, next + Vector2i(16, 16));
				bool bottom_right = solid_at(p_layer, next + Vector2i(16, -16));
				bool up = solid_at(p_layer, next + Vector2i(0, 16));
				bool down = solid_at(p_layer, next + Vector2i(0, -16));
				if ((left && ((top_right && !up) || (bottom_right && !down))) || (up && ((bottom_left && !left) || (bottom_right && !right))) || (right && ((top_left && !up) || (bottom_left && !down))) || (down && ((top_left && !left) || (top_right && !right)))) {
					continue;
				}
			} else if (!has(tile->name, "pkmnmansion_wall")) {
				continue;
			}
			if (size > 10 && random.next_int(35) - size <= 0) {
				continue;
			}
			size += 1;
			put(p_layer, next, make(NM("pkmnmansion_floor1"), next, NM("rubble1"), true));
			for (const Vector2i &offset : FOUR) {
				check.push_back(next + offset);
			}
		}
	}
}

void Gen::place_mansion_shelves(TileMap &p_layer) {
	PosSet already_checked;
	for (const Vector2i &position : p_layer.keys()) {
		if (already_checked.has(position)) {
			continue;
		}
		already_checked[position] = true;
		Tile *start_tile = p_layer.getp(position)->tile.get();
		if (start_tile->solid()) {
			continue;
		}
		bool near_wall = is_mansion_wall(p_layer, position + Vector2i(0, 16)) || is_mansion_wall(p_layer, position + Vector2i(-16, 0)) || is_mansion_wall(p_layer, position + Vector2i(16, 0));
		if (!near_wall || random.next_int(5) != 0) {
			continue;
		}
		OMap<Vector2i, bool> current_set;
		int64_t size = 0;
		std::deque<Vector2i> check;
		for (const Vector2i &offset : FOUR) {
			check.push_back(position + offset);
		}
		while (!check.empty()) {
			Vector2i next = check.front();
			check.pop_front();
			if (already_checked.has(next)) {
				continue;
			}
			already_checked[next] = true;
			Tile *tile = as_tile(p_layer.getp(next));
			if (!tile || tile->solid()) {
				continue;
			}
			Vector2i left_pos = next + Vector2i(-16, 0);
			Vector2i right_pos = next + Vector2i(16, 0);
			Vector2i up_pos = next + Vector2i(0, 16);
			Vector2i down_pos = next + Vector2i(0, -16);
			bool left_wall = is_mansion_wall(p_layer, left_pos);
			bool right_wall = is_mansion_wall(p_layer, right_pos);
			bool up_wall = is_mansion_wall(p_layer, up_pos);
			bool down_wall = is_mansion_wall(p_layer, down_pos);
			if (down_wall || (left_wall && right_wall) || (!left_wall && !right_wall && !up_wall)) {
				continue;
			}
			bool left = solid_at(p_layer, left_pos);
			bool right = solid_at(p_layer, right_pos);
			bool up = solid_at(p_layer, up_pos);
			bool down = solid_at(p_layer, down_pos);
			bool top_left = solid_at(p_layer, next + Vector2i(-16, 16));
			bool bottom_left = solid_at(p_layer, next + Vector2i(-16, -16));
			bool top_right = solid_at(p_layer, next + Vector2i(16, 16));
			bool bottom_right = solid_at(p_layer, next + Vector2i(16, -16));
			if ((left && ((top_right && !up) || (bottom_right && !down))) || (up && ((bottom_left && !left) || (bottom_right && !right))) || (right && ((top_left && !up) || (bottom_left && !down))) || (down && ((top_left && !left) || (top_right && !right))) || (size > 10 && random.next_int(35) - size <= 0)) {
				continue;
			}
			size += 1;
			current_set.set(next, true);
			for (const Vector2i &offset : FOUR) {
				check.push_back(next + offset);
			}
		}
		if (current_set.size() > 3) {
			current_set.each([&](const Vector2i &p_shelf, const bool &) {
				int name = current_set.has(p_shelf + Vector2i(0, 16)) ? NM("pkmnmansion_shelf1_NS") : NM("pkmnmansion_shelf1");
				put(p_layer, p_shelf, make(name, p_shelf, 0, true));
			});
		}
	}
}

void Gen::place_mansion_tables(TileMap &p_layer, Vector2i p_layout_origin) {
	PosSet already_checked;
	std::vector<TileMap> possible_spots;
	Vector2i position = p_layout_origin;
	while (position.y < p_layout_origin.y + 448) {
		if (position.x > p_layout_origin.x + 480) {
			position.x = p_layout_origin.x - 16;
			position.y += 16;
		} else if (p_layer.has(position) && !already_checked.has(position) && has(p_layer.getp(position)->tile->name, "pkmnmansion_floor1")) {
			int64_t table_height = 4;
			int64_t table_width = 4;
			Vector2i last_working;
			bool found_working = false;
			bool y_direction = false;
			while (true) {
				bool works = true;
				for (int64_t x = 0; x < table_width && works; x++) {
					for (int64_t y = 0; y < table_height; y++) {
						Tile *test = as_tile(p_layer.getp(position + Vector2i((int32_t)(x * 16), (int32_t)(y * 16))));
						if (!test || test->solid()) {
							works = false;
							break;
						}
					}
				}
				if (works) {
					last_working = Vector2i((int32_t)table_width, (int32_t)table_height);
					found_working = true;
					if (y_direction) {
						table_height += 1;
					} else {
						table_width += 1;
					}
				} else if (y_direction) {
					break;
				} else {
					y_direction = true;
				}
			}
			if (found_working) {
				if (last_working.x < 7 && last_working.y < 7) {
					TileMap table_tiles;
					for (int64_t x = 1; x < last_working.x - 1; x++) {
						for (int64_t y = 1; y < last_working.y - 1; y++) {
							Vector2i table_position = position + Vector2i((int32_t)(x * 16), (int32_t)(y * 16));
							int tile_name = NM("table");
							if (x == 1 && y == 1) {
								tile_name = NM("table_SW");
							} else if (x == last_working.x - 2 && y == last_working.y - 2) {
								tile_name = NM("table_NE");
							} else if (x == 1 && y == last_working.y - 2) {
								tile_name = NM("table_NW");
							} else if (x == last_working.x - 2 && y == 1) {
								tile_name = NM("table_SE");
							} else if (x == 1) {
								tile_name = NM("table_W");
							} else if (x == last_working.x - 2) {
								tile_name = NM("table_E");
							} else if (y == 1) {
								tile_name = NM("table_S");
							} else if (y == last_working.y - 2) {
								tile_name = NM("table_N");
							}
							put(table_tiles, table_position, make(tile_name, table_position, 0, true));
						}
					}
					possible_spots.push_back(table_tiles);
				}
				for (int64_t x = 0; x < last_working.x; x++) {
					for (int64_t y = 0; y < last_working.y + 1; y++) {
						already_checked[position + Vector2i((int32_t)(x * 16), (int32_t)(y * 16))] = true;
					}
				}
			}
		}
		position.x += 16;
	}
	for (TileMap &table_tiles : possible_spots) {
		bool works = true;
		for (const auto &entry : table_tiles.entries) {
			if (entry.live && solid_at(p_layer, entry.key)) {
				works = false;
				break;
			}
		}
		if (works) {
			p_layer.merge(table_tiles, true);
		}
	}
}

bool Gen::is_path_between(TileMap &p_layer, Tile *p_a, Tile *p_b) {
	std::deque<Tile *> check_tiles;
	check_tiles.push_back(p_a);
	PosSet already_checked;
	while (!check_tiles.empty()) {
		Tile *tile = check_tiles.front();
		check_tiles.pop_front();
		if (tile && tile->position == p_b->position) {
			return true;
		}
		if (tile != p_a && (!tile || (tile->solid() && !has(tile->upper, "pokeball")) || already_checked.has(tile->position))) {
			continue;
		}
		already_checked[tile->position] = true;
		check_tiles.push_back(as_tile(p_layer.getp(tile->position + Vector2i(-16, 0))));
		check_tiles.push_back(as_tile(p_layer.getp(tile->position + Vector2i(16, 0))));
		check_tiles.push_back(as_tile(p_layer.getp(tile->position + Vector2i(0, -16))));
		check_tiles.push_back(as_tile(p_layer.getp(tile->position + Vector2i(0, 16))));
	}
	return false;
}

std::vector<Vector2i> Gen::mansion_dead_ends(TileMap &p_layer, const std::vector<Vector2i> &p_starts, bool p_strict) {
	PosSet already_checked;
	std::vector<Vector2i> check;
	std::vector<Vector2i> endpoints;
	for (size_t start_index = 0; start_index < p_starts.size(); start_index++) {
		Vector2i start = p_starts[start_index];
		check.push_back(start);
		// The source's strict-pass typo: stairsUp is added twice to
		// alreadyChecked and stairsDown is not initially added at all.
		if (!p_strict || start_index == 0) {
			already_checked[start] = true;
		} else {
			already_checked[p_starts[0]] = true;
		}
	}
	while (!check.empty()) {
		std::vector<Vector2i> round = check;
		for (const Vector2i &position : round) {
			erase_first(check, position);
			bool added_another = false;
			bool touches_table = false;
			bool touches_endpoint = false;
			int64_t number_touching = 0;
			std::vector<Vector2i> shuffled = { position + Vector2i(16, 0), position + Vector2i(-16, 0), position + Vector2i(0, 16), position + Vector2i(0, -16) };
			while (!shuffled.empty()) {
				int64_t pick = random.next_int((int64_t)shuffled.size());
				Vector2i next = shuffled[pick];
				shuffled.erase(shuffled.begin() + pick);
				Tile *next_tile = as_tile(p_layer.getp(next));
				if (p_strict && next_tile && next_tile->solid()) {
					number_touching += 1;
				}
				if (!already_checked.has(next) && next_tile && !next_tile->solid() && !has(next_tile->upper, "stairs")) {
					check.push_back(next);
					already_checked[next] = true;
					added_another = true;
				}
				if (next_tile && has(next_tile->name, "table")) {
					touches_table = true;
				}
				if (contains(endpoints, next)) {
					touches_endpoint = true;
				}
			}
			Tile *tile = as_tile(p_layer.getp(position));
			if (!tile) {
				continue;
			}
			if (p_strict) {
				bool down = solid_at(p_layer, position + Vector2i(0, -16));
				bool bottom_left = solid_at(p_layer, position + Vector2i(-16, -16));
				bool bottom_right = solid_at(p_layer, position + Vector2i(16, -16));
				bool top_left = solid_at(p_layer, position + Vector2i(-16, 16));
				bool top_right = solid_at(p_layer, position + Vector2i(16, 16));
				if (down || (bottom_left && bottom_right) || (top_left && top_right) || number_touching >= 2 || touches_table || touches_endpoint || added_another || has(tile->name, "floor2") || has(tile->name, "rug")) {
					continue;
				}
			} else if (touches_table || touches_endpoint || added_another || has(tile->name, "floor2") || has(tile->name, "rug")) {
				continue;
			}
			endpoints.push_back(position);
		}
	}
	return endpoints;
}

Vector2i Gen::mansion_statue_fallback_position(TileMap &p_layer, const std::vector<Vector2i> &p_blocked) {
	// An untouched floor1 cell farthest from the stairs, no RNG drawn.
	Vector2i best_position;
	int64_t best_distance = -1;
	bool found = false;
	std::vector<Vector2i> keys = p_layer.keys();
	for (const Vector2i &position : keys) {
		if (contains(p_blocked, position)) {
			continue;
		}
		Tile *tile = as_tile(p_layer.getp(position));
		if (!tile || tile->solid() || tile->upper != 0 || !has(tile->name, "floor1")) {
			continue;
		}
		int64_t nearest_stair = 2147483647;
		for (const Vector2i &stair_position : p_blocked) {
			int64_t distance = ABS((int64_t)position.x - stair_position.x) + ABS((int64_t)position.y - stair_position.y);
			nearest_stair = MIN(nearest_stair, distance);
		}
		if (!found || nearest_stair > best_distance) {
			found = true;
			best_position = position;
			best_distance = nearest_stair;
		}
	}
	if (found) {
		return best_position;
	}
	for (int pass = 0; pass < 2; pass++) {
		bool require_empty_upper = pass == 0;
		for (const Vector2i &position : keys) {
			if (contains(p_blocked, position)) {
				continue;
			}
			Tile *tile = as_tile(p_layer.getp(position));
			if (!tile || tile->solid()) {
				continue;
			}
			if (require_empty_upper && tile->upper != 0) {
				continue;
			}
			return position;
		}
	}
	if (!p_blocked.empty()) {
		return p_blocked[0];
	}
	return Vector2i();
}

std::vector<std::vector<TileRef>> Gen::mansion_door_candidates(TileMap &p_layer) {
	std::vector<std::vector<TileRef>> all_doors;
	// The source's alreadyChecked set stays empty.
	for (const Vector2i &position : p_layer.keys()) {
		Tile *current = p_layer.getp(position)->tile.get();
		if (!current->solid()) {
			continue;
		}
		std::vector<Vector2i> directions;
		if (current->name == NM("pkmnmansion_wall_S")) {
			directions = { Vector2i(-16, 0), Vector2i(0, -16), Vector2i(16, 0) };
		} else if (current->name == NM("pkmnmansion_wall_N")) {
			directions = { Vector2i(-16, 0), Vector2i(0, 16), Vector2i(16, 0) };
		} else if (current->name == NM("pkmnmansion_wall_W")) {
			directions = { Vector2i(-16, 0), Vector2i(0, 16), Vector2i(0, -16) };
		} else if (current->name == NM("pkmnmansion_wall_NW")) {
			directions = { Vector2i(-16, 0), Vector2i(0, 16) };
		} else if (current->name == NM("pkmnmansion_wall_E")) {
			directions = { Vector2i(16, 0), Vector2i(0, 16), Vector2i(0, -16) };
		} else if (current->name == NM("pkmnmansion_wall_NE")) {
			directions = { Vector2i(16, 0), Vector2i(0, 16) };
		} else {
			continue;
		}
		int64_t length = 0;
		for (const Vector2i &initial_direction : directions) {
			Vector2i direction = initial_direction;
			std::vector<TileRef> door;
			bool valid_end = false;
			while (true) {
				Tile *next = as_tile(p_layer.getp(current->position + direction));
				if (!next || has(next->name, "rug") || has(next->name, "stairs") || has(next->upper, "stairs") || (next->solid() && !has(next->upper, "pokeball"))) {
					if (next && (has(next->name, "pkmnmansion_wall") || has(next->upper, "rubble"))) {
						valid_end = true;
					}
					break;
				}
				int gate_name = direction.x == 0 ? NM("pkmnmansion_gate_NS__on") : NM("pkmnmansion_gate_EW__on");
				door.push_back(make(gate_name, next->position, 0, true));
				direction += initial_direction;
				length += 1;
			}
			if (valid_end && length < 7) {
				all_doors.push_back(door);
			}
		}
	}
	return all_doors;
}

static bool door_contains_state(const std::vector<TileRef> &p_door, const char *p_state) {
	for (const TileRef &tile : p_door) {
		if (has(tile->name, p_state)) {
			return true;
		}
	}
	return false;
}

void Gen::solve_mansion_doors(TileMap &p_layer, Tile *p_stairs_up, Tile *p_stairs_down, Tile *p_statue, Tile *p_previous_statue, std::vector<std::vector<TileRef>> &p_all_doors) {
	typedef std::vector<TileRef> Door;
	std::vector<Vector2i> &door_tiles = p_previous_statue->doors_get();
	door_tiles.clear();
	for (Door &door : p_all_doors) {
		for (TileRef &tile : door) {
			put(p_layer, tile->position, tile);
			if (!contains(door_tiles, tile->position)) {
				door_tiles.push_back(tile->position);
			}
		}
	}
	auto flip = [&](const Door &p_door) {
		for (const TileRef &tile : p_door) {
			flip_door(tile.get());
		}
	};
	// Doors are Arrays: erase/has compare their elements.
	std::vector<Door> stairs_down_doors = p_all_doors;
	bool changed_door = true;
	while (changed_door) {
		bool path_to_stairs = is_path_between(p_layer, p_stairs_up, p_stairs_down);
		bool path_to_statue = is_path_between(p_layer, p_stairs_up, p_statue);
		changed_door = false;
		int64_t door_index = 0;
		while (door_index < (int64_t)stairs_down_doors.size()) {
			Door door = stairs_down_doors[random.next_int((int64_t)stairs_down_doors.size())];
			flip(door);
			if (!path_to_stairs && is_path_between(p_layer, p_stairs_up, p_stairs_down)) {
				flip(door);
				door_index += 1;
				continue;
			}
			if (path_to_statue && !is_path_between(p_layer, p_stairs_up, p_statue)) {
				// This double flip is present in 0.8.11 and deliberately leaves
				// the door in the once-flipped state.
				flip(door);
				flip(door);
				door_index += 1;
				continue;
			}
			erase_first(stairs_down_doors, door);
			changed_door = true;
			door_index += 1;
		}
	}
	stairs_down_doors.clear();
	for (Door &door : p_all_doors) {
		if (door_contains_state(door, "__on")) {
			stairs_down_doors.push_back(door);
		}
	}
	for (const Vector2i &position : door_tiles) {
		Tile *tile = as_tile(p_layer.getp(position));
		if (tile && has(tile->name, "__off")) {
			flip_door(tile);
		}
	}
	for (Door &door : p_all_doors) {
		for (TileRef &tile : door) {
			if (has(tile->name, "__off")) {
				flip_door(tile.get());
			}
		}
	}
	std::vector<Door> statue_doors;
	for (Door &door : p_all_doors) {
		if (!contains(stairs_down_doors, door)) {
			statue_doors.push_back(door);
		}
	}
	changed_door = true;
	while (changed_door) {
		bool path_to_stairs = is_path_between(p_layer, p_stairs_up, p_stairs_down);
		bool path_to_statue = is_path_between(p_layer, p_stairs_up, p_statue);
		changed_door = false;
		int64_t door_index = 0;
		while (door_index < (int64_t)statue_doors.size()) {
			Door door = statue_doors[random.next_int((int64_t)statue_doors.size())];
			flip(door);
			if (!path_to_statue && is_path_between(p_layer, p_stairs_up, p_statue)) {
				flip(door);
				door_index += 1;
				continue;
			}
			if (path_to_stairs && !is_path_between(p_layer, p_stairs_up, p_stairs_down)) {
				flip(door);
				door_index += 1;
				continue;
			}
			erase_first(statue_doors, door);
			changed_door = true;
			door_index += 1;
		}
	}
	statue_doors.clear();
	for (Door &door : p_all_doors) {
		if (door_contains_state(door, "__on")) {
			statue_doors.push_back(door);
		}
	}
	for (Door &door : p_all_doors) {
		for (TileRef &tile : door) {
			put(p_layer, tile->position, make(NM("pkmnmansion_floor1"), tile->position, 0, true));
			erase_first(door_tiles, tile->position);
		}
	}
	door_tiles.clear();
	for (Door &door : statue_doors) {
		for (TileRef &tile : door) {
			put(p_layer, tile->position, tile);
			door_tiles.push_back(tile->position);
			if (has(tile->name, "__off")) {
				flip_door(tile.get());
			}
		}
	}
	if (!is_path_between(p_layer, p_stairs_up, p_stairs_down)) {
		for (Door &door : statue_doors) {
			for (TileRef &tile : door) {
				put(p_layer, tile->position, make(NM("pkmnmansion_floor1"), tile->position, 0, true));
				erase_first(door_tiles, tile->position);
			}
			if (is_path_between(p_layer, p_stairs_up, p_stairs_down)) {
				break;
			}
		}
	}
	for (Door &door : stairs_down_doors) {
		for (TileRef &tile : door) {
			put(p_layer, tile->position, tile);
			if (!contains(door_tiles, tile->position)) {
				door_tiles.push_back(tile->position);
			}
			if (has(tile->name, "__on")) {
				flip_door(tile.get());
			}
		}
	}
	if (random.next_int(2) == 0) {
		for (const Vector2i &position : door_tiles) {
			Tile *tile = as_tile(p_layer.getp(position));
			if (tile) {
				flip_door(tile);
			}
		}
	}
}

void Gen::make_mewtwo_room(std::vector<Layer> &p_interiors, Vector2i p_stairs_down) {
	Vector2i room_origin = p_stairs_down + Vector2i(-80, -16);
	p_interiors[95] = std::make_shared<TileMap>();
	TileMap &layer = *p_interiors[95];
	TileRef current_tile;
	for (int64_t x = 0; x < 10; x++) {
		for (int64_t y = 0; y < 11; y++) {
			Vector2i position = room_origin + Vector2i((int32_t)(x * 16), (int32_t)(y * 16));
			if ((y == 2 || y == 6) && (x == 2 || x == 3 || x == 6 || x == 7)) {
				current_tile = make(NM("tree_plant1"), position, 0, true);
			} else if (x == 0 || y == 0 || y == 10 || x == 9) {
				current_tile = make(NM("pkmnmansion_wall"), position, 0, true);
			} else if (x == 4 && y == 9) {
				current_tile = make(NM("pkmnmansion_struct1"), position, 0, true);
			} else if (x != 5 || y != 9) {
				if (x == 5 && y == 8) {
					current_tile = make(NM("pkmnmansion_floor1"), position, NM("mewtwo_overworld"), true);
				} else if (x == 5 && y == 1) {
					current_tile = make(NM("pkmnmansion_floor1"), position, NM("stairs_up1"), true);
				} else {
					current_tile = make(NM("pkmnmansion_floor1"), position, 0, true);
				}
			}
			// At (5, 9) the previous Tile object is reused, as in 0.8.11.
			put(layer, position, current_tile);
		}
	}
	style_mansion_walls(layer);
}

void Gen::connect_mansion_floors(std::vector<Layer> &p_interiors, Vector2i p_layout_origin) {
	TileRef next_stairs_up;
	TileMap *current_layer = p_interiors[100].get();
	TileMap *layer_above = p_interiors[101].get();
	RouteRef rug_route = route(NM("pkmnmansion1"), 30);
	int64_t y_max = random.next_int(4) * 2 + 6;
	Vector2i probe = p_layout_origin + Vector2i(240, (int32_t)((y_max - 1) * 16));
	while (layer_above->has(probe) && layer_above->getp(probe)->tile->solid()) {
		y_max += 1;
		probe = p_layout_origin + Vector2i(240, (int32_t)((y_max - 1) * 16));
	}
	TileRef stairs_up;
	for (int64_t x = 0; x < 10; x++) {
		for (int64_t y = 0; y < y_max; y++) {
			Vector2i position = p_layout_origin + Vector2i((int32_t)((x + 10) * 16), (int32_t)(y * 16));
			if (y == y_max - 1 && x == 5) {
				next_stairs_up = make(NM("pkmnmansion_floor2"), position, NM("stairs_up1"), true);
				put(*current_layer, position, next_stairs_up);
				stairs_up = make(NM("pkmnmansion_floor2"), position, NM("stairs_down1"), true);
				put(*layer_above, position, stairs_up);
			} else if (y == 0 && x == 5) {
				put(*current_layer, position, make(NM("pkmnmansion_rug"), position, 0, true, rug_route));
			} else if ((x == 2 || x == 7) && y % 2 == 1 && y != 1) {
				put(*current_layer, position, make(NM("pkmnmansion_block1"), position, 0, true));
			} else if (x == 3) {
				put(*current_layer, position, make(NM("pkmnmansion_floor2_W"), position, 0, true, rug_route));
			} else if (x == 6) {
				put(*current_layer, position, make(NM("pkmnmansion_floor2_E"), position, 0, true, rug_route));
			} else if (x > 3 && x < 6) {
				put(*current_layer, position, make(NM("pkmnmansion_floor2"), position, 0, true, rug_route));
			} else if (y != 0) {
				put(*current_layer, position, make(NM("pkmnmansion_floor1"), position, 0, true, rug_route));
			}
		}
	}
	TileRef previous_statue;
	for (int64_t level_number = 6; level_number > 0; level_number--) {
		current_layer = p_interiors[95 + level_number].get();
		TileMap *layer_below = p_interiors[94 + level_number].get();
		if (!stairs_up) {
			continue;
		}
		std::vector<Vector2i> endpoints = mansion_dead_ends(*current_layer, { stairs_up->position }, false);
		// Original generateMansion crashes on an empty list (seed 65535).
		Vector2i selected = endpoints.empty() ? mansion_statue_fallback_position(*current_layer, { stairs_up->position }) : endpoints.back();
		while (!endpoints.empty()) {
			if (endpoints.size() > 4) {
				int64_t pick = random.next_int(5) + (int64_t)endpoints.size() - 5;
				selected = endpoints[pick];
				endpoints.erase(endpoints.begin() + pick);
			} else {
				selected = endpoints.back();
				endpoints.pop_back();
			}
			Tile *below = as_tile(layer_below->getp(selected));
			if (!below || !below->solid()) {
				break;
			}
		}
		TileRef stairs_down = make(NM("pkmnmansion_floor2"), selected, NM("stairs_down1"), true);
		if (level_number != 6) {
			put(*current_layer, selected, stairs_down);
			next_stairs_up = make(NM("pkmnmansion_floor1"), selected, NM("stairs_up1"), true);
			put(*layer_below, selected, next_stairs_up);
		}
		int64_t maximum_items = random.next_int(3) + 3;
		int64_t item_index = 0;
		while (item_index < maximum_items * 3 && endpoints.size() > 5) {
			selected = endpoints.back();
			endpoints.pop_back();
			if (item_index % 3 == 0) {
				put(*current_layer, selected, make(NM("pkmnmansion_floor1"), selected, NM("ultraball1"), true));
			}
			item_index += 1;
		}
		endpoints = mansion_dead_ends(*current_layer, { stairs_up->position, stairs_down->position }, true);
		// A strict pass can find no dead end: a clear-floor fallback, no RNG.
		bool place_statue = true;
		if (endpoints.empty()) {
			selected = mansion_statue_fallback_position(*current_layer, { stairs_up->position, stairs_down->position });
			place_statue = selected != stairs_up->position && selected != stairs_down->position;
		} else if (endpoints.size() > 4) {
			int64_t pick = random.next_int(5) + (int64_t)endpoints.size() - 5;
			selected = endpoints[pick];
			endpoints.erase(endpoints.begin() + pick);
		} else {
			selected = endpoints.back();
			endpoints.pop_back();
		}
		TileRef statue = make(NM("pkmnmansion_statue1"), selected, 0, true);
		if (level_number != 1 && place_statue) {
			put(*current_layer, selected, statue);
		}
		std::vector<std::vector<TileRef>> all_doors = mansion_door_candidates(*current_layer);
		if (previous_statue) {
			solve_mansion_doors(*current_layer, stairs_up.get(), stairs_down.get(), statue.get(), previous_statue.get(), all_doors);
		}
		if (level_number == 1) {
			make_mewtwo_room(p_interiors, stairs_down->position);
		}
		previous_statue = statue;
		stairs_up = next_stairs_up;
	}
}

void Gen::merge_exterior_preserving_mansion_key(TileMap &p_exterior) {
	for (Cell &cell : p_exterior.values()) {
		const TileRef &tile = cell.tile;
		TileRef existing(tile_at(tile->position));
		if (existing && existing->upper == NM("pokemon_mansion_key")) {
			put(tiles_to_add, tile->position, make(tile->name, existing->position, existing->upper, true, existing->route));
		} else {
			put(tiles_to_add, tile->position, tile);
		}
	}
}

void Gen::merge_interior_layer(int p_index, const Layer &p_layer) {
	while ((int)interior_tiles_to_add.size() <= p_index) {
		interior_tiles_to_add.push_back(nullptr);
	}
	if (!interior_tiles_to_add[p_index]) {
		interior_tiles_to_add[p_index] = p_layer;
	} else {
		interior_tiles_to_add[p_index]->merge(*p_layer, true);
	}
}

// --- generation_validator.gd capture()

Signature Gen::signature(Tile *p_tile) {
	Signature result;
	result.name = p_tile->name;
	result.upper = p_tile->upper;
	result.has_item = p_tile->has_item;
	result.amount = p_tile->amount;
	if (p_tile->doors) {
		result.doors = *p_tile->doors;
	}
	if (p_tile->items) {
		result.items = *p_tile->items;
	}
	return result;
}

void Gen::capture(const char *p_kind, Vector2i p_at, TileMap &p_exterior, const std::vector<std::pair<int, Layer>> &p_layers) {
	ValidationRecord record;
	record.kind = p_kind;
	record.origin = p_at;
	bool mansion = record.kind == "mansion";
	p_exterior.each([&](const Vector2i &p_position, const Cell &p_cell) {
		Tile *tile = p_cell.tile.get();
		if (mansion && (S(tile->name) + S(tile->upper)).find("pkmnmansion") == std::string::npos) {
			return;
		}
		record.exterior.set(p_position, signature(tile));
	});
	for (const auto &layer : p_layers) {
		OMap<Vector2i, Signature> signatures;
		layer.second->each([&](const Vector2i &p_position, const Cell &p_cell) {
			signatures.set(p_position, signature(p_cell.tile.get()));
		});
		record.layers.push_back({ layer.first, signatures });
	}
	validation_records.push_back(record);
}

} // namespace pw
