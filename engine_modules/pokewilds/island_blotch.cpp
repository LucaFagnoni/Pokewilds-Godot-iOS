// GenIsland1.ApplyBlotch and everything it grows (source_island_generator.gd,
// source_forest_generator.gd, source_maze.gd).

#include "island.h"

#include <algorithm>

namespace pw {

static Dictionary crystal() {
	Dictionary extra;
	extra["generation"] = "CRYSTAL";
	return extra;
}

static const Vector2i BLOTCH_EDGE_OFFSETS[4] = { Vector2i(-16, 0), Vector2i(16, 0), Vector2i(0, 16), Vector2i(0, -16) };

static bool is_leaf_blotch(const std::string &p_type) {
	return p_type == "grass" || p_type == "grass_sand" || p_type == "grass_desert1" || p_type == "sand_pit1" || p_type == "ruins1_upper2" || p_type == "pond1" || p_type == "desert_cacti1" || p_type == "desert_cacti2" || p_type == "desert_cacti3" || p_type == "desert_cacti4" || p_type.compare(0, 6, "grass_") == 0;
}

void Gen::apply_blotch(const char *p_type, const TileRef &p_origin_tile, int64_t p_maximum_distance, TileMap &p_tiles, int64_t p_is_maze, bool p_do_next, RouteRef p_route) {
	const std::string type = p_type;
	const TileRef origin_tile = p_origin_tile;
	const int64_t maximum_distance = p_maximum_distance;
	TileMap edge_tiles;
	edge_tiles.set(origin_tile->position, Cell(origin_tile));
	// An island blotch straight on tiles_to_add, before the mountain overlay.
	bool stand_in = !under_mountain.is_empty() && &p_tiles == &tiles_to_add;
	uint32_t size_before = p_tiles.size();
	bool mountain_biome = &p_tiles == biome_tiles;
	std::vector<TileRef> previous_tiles;
	TileRef previous_tile = origin_tile;
	int64_t is_maze = p_is_maze;
	if (type != "beach1") {
		is_maze = 1;
	}
	BlotchState state;
	int64_t new_size = maximum_distance - random.next_int((int64_t)Math::ceil((double)maximum_distance / 4.0)) - maximum_distance / 4;
	if (type == "sand_pit1") {
		new_size = maximum_distance;
	}
	state.done_oasis = maximum_distance;
	state.num_darms = 10;
	state.is_maze = is_maze;
	if (type == "island") {
		state.beach_route = route(NM(""), 2);
		state.deep_forest_route = route(NM("deep_forest"), 33);
	} else if (type == "beach1") {
		state.beach_route = route(NM("beach2_rocks"), 22);
		state.beach_plateau_route = route(NM("beach2_plateau"), 22);
		state.beach_water_route = route(NM("beach2_water"), 22);
	} else if (type == "mtn_green1") {
		state.beach_route = route(NM("mountain1_water1"), 30);
	} else if (type == "wooded_lake1") {
		state.beach_route = route(NM("wooded_lake_water1"), 30);
	}
	int64_t put_sixteenths = 7;
	if (type == "desert" || type == "sand_pit1" || type == "graveyard1") {
		put_sixteenths = 10;
	} else if (type == "beach1") {
		put_sixteenths = 12;
	} else if (type.find("volcano") != std::string::npos) {
		put_sixteenths = 10;
	} else if (type.find("island") != std::string::npos) {
		put_sixteenths = 8;
	} else if (type == "wooded_lake1") {
		put_sixteenths = 12;
	}
	int64_t put_limit = put_sixteenths * maximum_distance / 16;
	bool leaf = is_leaf_blotch(type);
	Vector2 origin_vector(origin_tile->position);
	double previous_distance = (double)Vector2(previous_tile->position).distance_to(origin_vector);
	while (!edge_tiles.is_empty()) {
		std::vector<Cell> round = edge_tiles.values();
		for (Cell &raw_tile : round) {
			TileRef tile = raw_tile.tile;
			Vector2i tile_position = tile->position;
			for (const Vector2i &edge_offset : BLOTCH_EDGE_OFFSETS) {
				Vector2i edge = tile_position + edge_offset;
				if (p_tiles.has(edge)) {
					continue;
				}
				double distance = gdx_distance(Vector2(edge), origin_vector);
				int64_t put_tile = random.next_int(maximum_distance) + (int64_t)distance;
				if (put_tile >= maximum_distance && (int64_t)distance >= put_limit) {
					continue;
				}
				TileRef new_tile;
				if (leaf) {
					new_tile = leaf_blotch_tile(type, edge, distance, maximum_distance, origin_tile.get(), p_route);
				} else {
					new_tile = make_blotch_tile(type, tile.get(), edge, distance, maximum_distance, origin_tile.get(), p_route, p_tiles, state);
				}
				if (!new_tile) {
					continue;
				}
				if (mountain_biome && !biome_read_cells.has(new_tile->position)) {
					Cell mark;
					mark.mark = true;
					p_tiles.set(new_tile->position, mark);
				} else {
					p_tiles.set(new_tile->position, Cell(new_tile));
				}
				edge_tiles.set(new_tile->position, Cell(new_tile));
			}
			double tile_distance = (double)Vector2(tile_position).distance_to(origin_vector);
			if (tile_distance > previous_distance && tile->name != NM("sand1") && tile->name != NM("rock1") && tile->name != NM("tree5")) {
				previous_tile = tile;
				previous_distance = tile_distance;
				// Newest first, as the source's push_front (reversed below).
				previous_tiles.push_back(tile);
			}
			edge_tiles.erase(tile_position);
		}
	}
	std::reverse(previous_tiles.begin(), previous_tiles.end());
	for (Cell &grass : state.grass_tiles.values()) {
		Tile *existing = as_tile(p_tiles.getp(grass.tile->position));
		if (existing && !existing->solid()) {
			p_tiles.set(grass.tile->position, grass);
		}
	}
	state.grass_tiles.clear();
	if (is_maze != 0 && !state.forest_maze_tiles.is_empty()) {
		apply_forest_maze(p_tiles, state.forest_maze_tiles, state.deep_forest_maze_tiles, state);
	}
	if (type == "graveyard1") {
		place_graveyard_fences(p_tiles, state.fence_spawns, p_route);
	}
	stand_in = stand_in && p_tiles.size() != size_before;
	if (stand_in) {
		stand_in_under_mountain();
	}
	continue_blotch(type, maximum_distance, new_size, previous_tiles, p_tiles, is_maze, p_do_next, p_route, state.forest_maze_tiles);
	if (stand_in) {
		stand_in_under_mountain();
	}
}

TileRef Gen::leaf_blotch_tile(const std::string &p_type, Vector2i p_position, double p_distance, int64_t p_maximum_distance, Tile *p_origin_tile, const RouteRef &p_route) {
	const int64_t md = p_maximum_distance;
	if (p_type == "grass") {
		int name = p_route && (has(p_route->name, "savanna") || has(p_route->name, "oasis")) ? NM("grass4") : NM("grass2");
		TileRef tile = make(name, p_position, 0, false, p_route);
		if ((int64_t)p_distance < 3 * md / 8 && md > 300) {
			tile->biome = NM("deep_forest");
		}
		return tile;
	}
	if (p_type == "grass_sand") {
		TileRef tile = make(NM("grass_sand1"), p_position, 0, false, p_route);
		tile->biome = p_origin_tile->biome;
		return tile;
	}
	if (p_type == "grass_desert1") {
		if (p_distance < (double)(2 * md / 3)) {
			return make(NM("grass_sand3"), p_position, 0, true, p_route);
		}
		return make(NM("desert4"), p_position);
	}
	if (p_type.compare(0, 6, "grass_") == 0) {
		return make(intern(p_type), p_position, 0, false, p_route);
	}
	if (p_type == "sand_pit1") {
		if (p_distance < (double)(2 * md / 3)) {
			if (random.next_int(256) < 8) {
				trapinch_spawns.push_back(p_position);
			}
			return make(NM("desert2"), p_position, 0, true, p_route);
		}
		return make(NM("desert4"), p_position);
	}
	if (p_type == "ruins1_upper2") {
		if (random.next_int(3) > 0) {
			return make(NM("ruins1_NSEW"), p_position, 0, true, p_route);
		}
		return make(NM("desert4"), p_position);
	}
	if (p_type == "pond1") {
		return make(NM("water2"), p_position, 0, true, p_route);
	}
	if (p_type == "desert_cacti1") {
		TileRef new_tile = make(NM("desert4"), p_position);
		bool do_cactus = true;
		if (p_distance > 0.0) {
			do_cactus = random.next_int((int64_t)p_distance) < md / 8;
		}
		if (do_cactus) {
			RouteRef temporary_route;
			if (random.next_int(2) == 0) {
				temporary_route = route(NM(""), 22);
				// The one-element source array still consumes nextInt(1).
				random.next_int(1);
				temporary_route->stored.push_back(make_pokemon_record("maractus", temporary_route->level, crystal()));
			}
			if (p_distance < (double)(md / 4)) {
				new_tile = make(NM("cactus2"), p_position, 0, true, temporary_route);
			} else if (p_position.x != p_origin_tile->position.x || p_position.y != p_origin_tile->position.y + 16) {
				new_tile = make(NM("cactus1"), p_position, 0, true, temporary_route);
			}
		}
		return new_tile;
	}
	if (p_type == "desert_cacti3") {
		TileRef new_tile = make(NM("desert4"), p_position, 0, true, p_route);
		bool do_cactus = true;
		if (p_distance > 0.0) {
			do_cactus = random.next_int((int64_t)p_distance) < md / 8;
		}
		if (do_cactus) {
			if (p_distance < (double)(md / 4)) {
				new_tile = make(NM("desert6"), p_position, NM("cactus9"), true);
			} else {
				new_tile = make(NM("desert6"), p_position, NM("cactus8"), true);
			}
		}
		return new_tile;
	}
	if (p_type == "desert_cacti4") {
		TileRef new_tile = make(NM("desert4"), p_position, 0, true, p_route);
		if (random.next_int((int64_t)((double)md - p_distance)) < md) {
			if (p_distance < (double)(md / 4)) {
				if (random.next_int(2) == 1) {
					new_tile = make(NM("desert6"), p_position, NM("cactus7"), true);
				}
			} else {
				new_tile = make(NM("desert6"), p_position, NM("cactus7"), true);
			}
		}
		return new_tile;
	}
	// desert_cacti2's source branch intentionally contains an empty if block.
	return make(NM("desert4"), p_position, 0, true, p_route);
}

TileRef Gen::make_blotch_tile(const std::string &p_type, Tile *p_frontier, Vector2i p_edge, double p_distance, int64_t p_maximum_distance, Tile *p_origin_tile, const RouteRef &p_route, TileMap &p_tiles, BlotchState &p_state) {
	if (p_type == "desert") {
		return make_desert_tile(p_edge, p_maximum_distance, p_route, p_state);
	} else if (p_type == "island") {
		return make_island_tile(p_edge, p_distance, p_maximum_distance, p_route, p_state);
	} else if (p_type == "ruins1_upper") {
		return make_ruins_upper_tile(p_edge, p_distance, p_maximum_distance, p_route, p_state);
	} else if (p_type == "oasis1") {
		return make_oasis_tile(p_edge, p_distance, p_maximum_distance, p_route, p_state);
	} else if (p_type == "beach1") {
		return make_beach_tile(p_edge, p_distance, p_maximum_distance, p_route, p_state);
	} else if (p_type == "savanna1") {
		return make_savanna_tile(p_edge, p_route);
	} else if (p_type == "graveyard1") {
		if (river_contains(p_frontier->position)) {
			return TileRef();
		}
		return make_graveyard_tile(p_edge, p_distance, p_maximum_distance, p_route, p_state);
	} else if (p_type == "mtn_snow1") {
		return make_snow_tile(p_edge, p_route, p_tiles);
	} else if (p_type == "volcano1_lava") {
		return make_volcano_lava_tile(p_frontier, p_edge, p_route, p_tiles);
	} else if (p_type == "volcano1") {
		return make_volcano_tile(p_edge, p_route);
	} else if (p_type == "wooded_lake1") {
		return make_wooded_lake_tile(p_edge, p_route, p_state);
	} else if (p_type == "mtn_green1") {
		return make_green_mountain_tile(p_edge, p_route, p_state);
	}
	ERR_PRINT(String("Unsupported GenIsland1 blotch type: ") + p_type.c_str());
	return TileRef();
}

TileRef Gen::make_desert_tile(Vector2i p_edge, int64_t p_maximum_distance, const RouteRef &p_route, BlotchState &p_state) {
	const int64_t md = p_maximum_distance;
	TileRef new_tile = make(NM("desert4"), p_edge, 0, true, p_route);
	new_tile->biome = NM("desert");
	if (random.next_int(md) < 6) {
		apply_blotch("desert_cacti2", new_tile, 200, p_state.grass_tiles, 0, false, p_route);
		int64_t next_size = random.next_int(40) + 20;
		TileMap new_tiles;
		apply_blotch("desert_cacti1", new_tile, next_size, new_tiles, 0, false, p_route);
		p_state.grass_tiles.merge(new_tiles, true);
	} else if (random.next_int(md) < 3) {
		int64_t next_size = 30 + random.next_int(20);
		TileMap new_tiles;
		apply_blotch("desert_cacti3", new_tile, next_size, new_tiles, 0, false, p_route);
		p_state.grass_tiles.merge(new_tiles, true);
	} else if (random.next_int(md) < 3) {
		new_tile = make(NM("desert4"), p_edge, NM("cactus10"), true, p_route);
	} else if (random.next_int(md) < 3) {
		new_tile = make(NM("desert4"), p_edge, NM("desert4_cracked"), true, p_route);
	} else if (random.next_int(md) < 3) {
		num_sand_pits = 0;
		new_tile = make(NM("desert2_trapinch_spawn"), p_edge, 0, true, p_route);
		TileMap new_tiles;
		apply_blotch("sand_pit1", new_tile, 45, new_tiles, 0, true, route(NM("sand_pit1"), 44));
		p_state.grass_tiles.merge(new_tiles, true);
	} else {
		Vector2 rotated = rotate_deg(Vector2(p_edge), 45.0);
		double offset_y = (double)(Math::posmod((int64_t)((double)rotated.y / 30.0), (int64_t)14) - 7);
		double offset_x = (double)(Math::posmod((int64_t)((double)rotated.x / 30.0 - (double)rotated.y / 30.0), (int64_t)14) - 7);
		double offset_1 = Math::abs(offset_x) + Math::abs(offset_y);
		offset_y = (double)(Math::posmod((int64_t)((double)rotated.y / 30.0), (int64_t)20) - 10);
		offset_x = (double)(Math::posmod((int64_t)((double)rotated.x / 30.0), (int64_t)20) - 10);
		double offset_2 = (Math::abs(offset_x) + Math::abs(offset_y)) / 5.0;
		if (offset_1 * offset_2 > 45.0) {
			int upper = random.next_int(10) < 5 ? NM("berrytree_rawst_full") : 0;
			new_tile = make(NM("desert4"), p_edge, upper, true, p_route);
		}
	}
	if (done_desert < 2) {
		done_desert = 2;
	}
	p_state.done_oasis -= 1;
	return new_tile;
}

TileRef Gen::make_ruins_upper_tile(Vector2i p_edge, double p_distance, int64_t p_maximum_distance, const RouteRef &p_route, BlotchState &p_state) {
	const int64_t md = p_maximum_distance;
	TileRef new_tile = make(NM("desert4"), p_edge);
	if (p_distance < (double)(2 * md / 5)) {
		int64_t put_tile = random.next_int(md) + (int64_t)p_distance;
		if (put_tile < md) {
			new_tile = make(NM("ruins1"), p_edge, 0, true, p_route);
		} else if (p_edge.y % 32 == 0 && p_edge.x % 64 == 0) {
			new_tile = make(NM("ruins1_pillar1"), p_edge, 0, true, p_route);
		}
	} else if (p_distance < (double)(3 * md / 5)) {
		if (random.next_int(20) > 10 && p_edge.y % 32 == 0 && p_edge.x % 64 == 0) {
			int name = random.next_int(20) > 9 ? NM("ruins1_pillar1_broken") : NM("ruins1_pillar1");
			new_tile = make(name, p_edge, 0, true, p_route);
		} else if (random.next_int(20) > p_state.num_darms && p_edge.y % 32 == 0 && p_edge.x % 32 == 0) {
			spawn(new_tile->position, "darmanitanzen", 35, crystal());
			p_state.num_darms += 1;
		}
	} else if (random.next_int(10) > 4) {
		new_tile = make(NM("grass_sand3"), p_edge, 0, true, p_route);
		TileMap new_tiles;
		apply_blotch("grass_desert1", new_tile, 95, new_tiles, 0, true, p_route);
		p_state.grass_tiles.merge(new_tiles, true);
		if (random.next_int(2) > 0) {
			new_tile = make(NM("grass_sand3"), p_edge, 0, true, p_route);
			TileMap more_tiles;
			if (random.next_int(2) > 0) {
				int64_t size = random.next_int(40) + 20;
				apply_blotch("desert_cacti1", new_tile, size, more_tiles, 0, true, p_route);
			} else {
				int64_t size = 30 + random.next_int(20);
				apply_blotch("desert_cacti3", new_tile, size, more_tiles, 0, false, p_route);
			}
			p_state.grass_tiles.merge(more_tiles, true);
		}
	}
	return new_tile;
}

TileRef Gen::make_oasis_tile(Vector2i p_edge, double p_distance, int64_t p_maximum_distance, const RouteRef &p_route, BlotchState &p_state) {
	const int64_t md = p_maximum_distance;
	TileRef new_tile = make(NM("sand1"), p_edge, 0, true, p_route);
	int64_t is_grass = random.next_int(md / 8) + (int64_t)p_distance;
	if (is_grass < md / 2) {
		if ((int64_t)p_distance < 3 * md / 8) {
			int name = random.next_int(24) == 0 ? NM("flower4") : NM("green1");
			new_tile = make(name, p_edge, 0, true, p_route);
		} else {
			new_tile = make(NM("green1"), p_edge, 0, true, p_route);
		}
	}
	bool put_grass = random.next_int(90) < 1;
	if (p_distance < (double)(md / 2)) {
		put_grass = random.next_int(40) < 1;
	}
	bool put_rock = false;
	if (p_distance > (double)(md / 2)) {
		put_rock = random.next_int(10) < 1;
	}
	if (put_grass) {
		apply_blotch("grass", new_tile, 40, p_state.grass_tiles, 0, false, route(NM("oasis1"), 30));
	} else if (random.next_int(10) < 1) {
		RouteRef tree_route = route(NM("oasis1"), 22);
		if (random.next_int(2) == 0) {
			append_stored(tree_route.get(), { "aexeggutor" }, tree_route->level);
		}
		new_tile = make(NM("tree5"), p_edge, 0, true, tree_route);
	} else if (random.next_int(110) < 1) {
		new_tile = make(NM("green1"), p_edge, NM("aloe_large1"), true, p_route);
	} else if (put_rock) {
		RouteRef rock_route = route(NM("oasis1"), 22);
		if (random.next_int(2) == 0) {
			append_stored(rock_route.get(), { "shellder", "krabby", "staryu", "dwebble" }, rock_route->level);
		}
		new_tile = make(new_tile->name, p_edge, NM("rock1_color"), true, rock_route);
	}
	return new_tile;
}

int64_t Gen::source_scaled_level(int64_t p_center_level, double p_distance, int64_t p_maximum_distance) {
	double denominator = f32((double)(2 * p_maximum_distance / 5));
	double ratio = f32(f32(p_distance) / denominator);
	double factor = f32(f32(1.0) - ratio);
	return (int64_t)f32(f32((double)p_center_level) * factor);
}

Vector2i Gen::diagonal_pattern(Vector2i p_position, double p_scale) {
	Vector2 rotated = rotate_deg(Vector2(p_position), 45.0);
	double source_scale = f32(p_scale);
	Vector2 scaled((float)((double)rotated.x / source_scale), (float)((double)rotated.y / source_scale));
	double scaled_y = scaled.y;
	double scaled_x = scaled.x;
	double diagonal = f32(scaled_x - scaled_y);
	int64_t offset_y = ((int64_t)Math::abs(scaled_y)) % 14 - 7;
	int64_t offset_x = ((int64_t)Math::abs(diagonal)) % 14 - 7;
	int64_t offset_1 = ABS(offset_x) + ABS(offset_y);
	offset_y = ABS(((int64_t)Math::abs(scaled_y)) % 20 - 10);
	offset_x = ABS(((int64_t)Math::abs(scaled_x)) % 20 - 10);
	return Vector2i((int32_t)offset_1, (int32_t)(offset_x + offset_y));
}

static const std::vector<const char *> TREE_POKEMON = { "pineco", "aipom", "kakuna", "metapod", "spinarak", "heracross", "ledyba", "hoothoot", "zubat", "pidgey", "spearow", "forretress", "applin" };

TileRef Gen::make_island_tile(Vector2i p_edge, double p_distance, int64_t p_maximum_distance, const RouteRef &p_route, BlotchState &p_state) {
	const int64_t md = p_maximum_distance;
	RouteRef beach_route = p_state.beach_route;
	// The default sand tile is usually replaced: made only when read.
	TileRef new_tile;
	int64_t is_rock = random.next_int(md) + (int64_t)p_distance;
	if (is_rock > md + md / 2) {
		RouteRef rock_route;
		int64_t random_value = random.next_int(3);
		if (random_value == 2) {
			rock_route = route(NM(""), 11);
			append_stored(rock_route.get(), { "shellder", "krabby", "staryu", "dwebble" }, 11, 3);
		}
		new_tile = make(NM("rock1"), p_edge, 0, true, rock_route);
	}
	int64_t is_grass = random.next_int(md / 8) + (int64_t)p_distance;
	if (p_distance < (double)(8 * md / 16)) {
		if ((int64_t)p_distance < 3 * md / 8) {
			int name = random.next_int(24) == 0 ? NM("flower4") : NM("green1");
			new_tile = make(name, p_edge, 0, true, p_route);
		} else if (p_distance > (double)(15 * md / 32)) {
			Vector2 rotated = rotate_deg(Vector2(p_edge), -15.0);
			int64_t offset_y = ((int64_t)Math::abs((double)rotated.y / 8.0)) % 14 - 7;
			int64_t offset_x = (((int64_t)Math::abs((double)rotated.x / 8.0)) - offset_y * 2) % 14 - 7;
			int64_t offset_1 = ABS(offset_x) + ABS(offset_y);
			offset_y = ABS(((int64_t)Math::abs((double)rotated.y / 8.0)) % 20 - 10);
			offset_x = ABS(((int64_t)Math::abs((double)rotated.x / 8.0)) % 20 - 10);
			int64_t offset_2 = (offset_x + offset_y) / 5;
			if (offset_1 * offset_2 > 6) {
				new_tile = make(NM("green1"), p_edge, 0, true, p_route);
			}
		} else {
			new_tile = make(NM("green1"), p_edge, 0, true, p_route);
		}
		Vector2i pattern = diagonal_pattern(p_edge, 30.0);
		if ((double)pattern.x * ((double)pattern.y / 5.0) > 42.0) {
			int upper = 0;
			RouteRef tree_route = p_route;
			if (random.next_int(10) < 5) {
				upper = NM("berrytree_persim_full");
				if (random.next_int(6) == 0) {
					tree_route = route(NM(""), 22);
					append_stored(tree_route.get(), { "sudowoodo" }, 20, 4);
				}
			}
			if (!new_tile) {
				new_tile = make(NM("sand1"), p_edge, 0, true, beach_route);
			}
			new_tile = make(new_tile->name, p_edge, upper, true, tree_route);
		}
	} else if (is_rock <= md + md / 2 && is_grass < md - md / 4 && random.next_int(40) == 0) {
		RouteRef tree_route = route(NM(""), 11);
		int64_t random_value = random.next_int(5);
		if (random_value == 4) {
			int64_t level = 10 + random.next_int(4);
			tree_route->stored.push_back(make_pokemon_record("Exeggutor", level, crystal()));
		} else if (random_value > 1) {
			int64_t level = 10 + random.next_int(4);
			tree_route->stored.push_back(make_pokemon_record("Exeggcute", level, crystal()));
		}
		if (random.next_int(2) == 0) {
			if (!new_tile) {
				new_tile = make(NM("sand1"), p_edge, 0, true, beach_route);
			}
			apply_blotch("grass_sand", new_tile, 35, p_state.grass_tiles, 0, false, route(NM("beach1"), 3));
		}
		if (random.next_int(10) == 0) {
			bool is_unown = unown_counter % 64 == 0;
			unown_counter += 1;
			new_tile = make(NM("sand1"), p_edge, NM("sign1"), true, tree_route);
			new_tile->has_item = is_unown ? NM("trainer_tips_unown") : NM("trainer_tips");
		} else {
			new_tile = make(NM("tree5"), p_edge, 0, true, tree_route);
		}
	} else if (is_rock <= md + md / 2 && is_grass < md - md / 4 && random.next_int(200) == 0) {
		if (!new_tile) {
			new_tile = make(NM("sand1"), p_edge, 0, true, beach_route);
		}
		new_tile = make(new_tile->name, p_edge, NM("pokeball1"), true, p_route);
	} else if (is_rock <= md + md / 2 && is_grass < md - md / 4 && random.next_int(450) == 0) {
		int64_t level = source_scaled_level(md > 300 ? 30 : 15, p_distance, md);
		level = MAX(level, (int64_t)4);
		RouteRef spawn_route;
		if ((int64_t)p_distance < 2 * md / 8 && md > 600) {
			spawn_route = route(NM("deep_forest"), level);
		} else if ((int64_t)p_distance < 3 * md / 8) {
			spawn_route = route(NM("forest1"), level);
		} else {
			spawn_route = route(NM("savanna1"), level);
		}
		const std::vector<String> &allowed = data.allowed(spawn_route->name);
		if (!allowed.empty()) {
			String pokemon_name = allowed[random.next_int((int64_t)allowed.size())];
			int64_t spawn_level = spawn_route->level + random.next_int(3);
			String lower_name = pokemon_name.to_lower();
			Dictionary extra;
			extra["generation"] = "CRYSTAL";
			extra["happiness"] = (lower_name == "ekans" || lower_name == "pidgey" || lower_name == "spearow" || lower_name == "rattata") ? 0 : 70;
			spawn(p_edge, pokemon_name, spawn_level, extra);
			if (data.mates_2.has(lower_name)) {
				spawn(p_edge + Vector2i(16, 0), data.mates_2[lower_name], spawn_route->level);
			}
		}
	} else {
		Vector2i pattern = diagonal_pattern(p_edge, 30.0);
		if ((double)pattern.x * ((double)pattern.y / 5.0) > 39.0) {
			int upper = 0;
			RouteRef tree_route = p_route;
			if (random.next_int(10) < 5) {
				upper = NM("berrytree_pecha_full");
				if (random.next_int(6) == 0) {
					tree_route = route(NM(""), 22);
					append_stored(tree_route.get(), { "sudowoodo" }, 20, 4);
				}
			}
			if (!new_tile) {
				new_tile = make(NM("sand1"), p_edge, 0, true, beach_route);
			}
			new_tile = make(new_tile->name, p_edge, upper, true, tree_route);
		}
	}
	if (p_distance < (double)(md / 4) && md > 300 && random.next_int(750) == 0) {
		int64_t level = source_scaled_level(md > 300 ? 50 : 15, p_distance, md);
		level = MAX(level, (int64_t)4);
		Array names = data.mates.keys();
		String parent_name = names[global_random.next_int(names.size())];
		spawn(p_edge, parent_name, level);
		spawn(p_edge + Vector2i(16, 0), data.mates[parent_name], level);
	}
	if (p_state.is_maze == 0) {
		int64_t is_tree = random.next_int(md / 4) + (int64_t)p_distance;
		if (is_tree < md / 3 && p_edge.y % 32 == 0) {
			new_tile = make(NM("tree2"), p_edge);
		}
	} else if ((int64_t)p_distance + random.next_int(md / 14 + 1) < 8 * md / 16) {
		if (!new_tile) {
			new_tile = make(NM("sand1"), p_edge, 0, true, beach_route);
		}
		// Positions only: a tile here would outlive its replacement.
		p_state.forest_maze_tiles.set(new_tile->position, true);
	}
	if (!new_tile) {
		new_tile = make(NM("sand1"), p_edge, 0, true, beach_route);
	}
	int64_t grass_here = random.next_int(md / 4) + (int64_t)p_distance;
	int64_t grass_here_2 = random.next_int(md);
	int64_t grass_here_3 = random.next_int(md);
	if ((int64_t)p_distance < md - md / 5 && grass_here < 3 * md / 7 && grass_here_2 < md / 4 && (md < 300 || grass_here_3 < md / 8)) {
		int64_t next_size = (int64_t)Math::ceil((double)md / 6.0);
		if (md > 300) {
			next_size = (int64_t)Math::ceil((double)md / 12.0);
		}
		if (md > 1000) {
			next_size = (int64_t)Math::ceil((double)md / 32.0);
		}
		int64_t level = source_scaled_level(md > 300 ? 30 : 15, p_distance, md);
		level = MAX(level, (int64_t)4);
		RouteRef grass_route;
		if ((int64_t)p_distance < 2 * md / 8 && md > 600) {
			grass_route = p_state.deep_forest_route;
		} else if ((int64_t)p_distance < 4 * md / 8) {
			grass_route = route(NM("forest1"), level);
		} else {
			grass_route = route(NM("savanna1"), level);
		}
		apply_blotch("grass", new_tile, next_size, p_state.grass_tiles, 0, false, grass_route);
	}
	if ((int64_t)p_distance < 2 * md / 8 && md > 300) {
		new_tile->biome = NM("deep_forest");
		p_state.deep_forest_maze_tiles.push_back(new_tile->position);
	}
	return new_tile;
}

TileRef Gen::make_beach_tile(Vector2i p_edge, double p_distance, int64_t p_maximum_distance, const RouteRef &p_route, BlotchState &p_state) {
	std::string tile_name = "sand4_tidalwater";
	int upper = 0;
	RouteRef tile_route = p_route;
	if (p_distance > (double)(5 * p_maximum_distance / 9)) {
		tile_name = "water2";
		tile_route = p_state.beach_water_route;
	}
	Vector2 rotated = rotate_deg(Vector2(p_edge), 45.0);
	int64_t ry = (int64_t)Math::abs((double)rotated.y / 16.0);
	int64_t rx = (int64_t)Math::abs((double)rotated.x / 16.0);
	int64_t offset_y = ry % 14 - 7;
	int64_t offset_x = rx % 14 - 7;
	int64_t offset_1 = ABS(offset_x) + ABS(offset_y);
	offset_y = ABS(ry % 20 - 10);
	offset_x = ABS(rx % 20 - 10);
	int64_t offset_2 = offset_x + offset_y;
	offset_y = ABS(ry % 60 - 30);
	offset_x = ABS(rx % 60 - 30);
	int64_t offset_3 = (offset_x + offset_y) * 2;
	if (offset_1 * (offset_2 / 5) * offset_3 <= 320) {
		tile_name = "mountain4";
		if (offset_1 < 2) {
			tile_name = "water2";
		} else if (offset_2 < 7) {
			upper = NM("stalagmite1");
		}
		tile_route = offset_3 >= 30 ? p_state.beach_route : p_state.beach_plateau_route;
	}
	offset_y = ry % 14 - 7;
	offset_x = rx % 14 - 7;
	offset_1 = ABS(offset_x) + ABS(offset_y);
	offset_y = ABS(ry % 20 - 10);
	offset_x = ABS(rx % 20 - 10);
	offset_2 = (offset_x + offset_y) / 5;
	if (offset_1 * offset_2 > 16) {
		tile_name = "water2";
	} else if (tile_name != "water2" && tile_name != "mountain4" && offset_1 * offset_2 < 13 && offset_1 * offset_2 > 9) {
		tile_name += "_puddle1";
	}
	if (tile_name.find("sand4") != std::string::npos && upper == 0) {
		if (random.next_int(50) == 0) {
			upper = NM("tree6");
		} else if (random.next_int(50) == 0) {
			tile_name = "rock1";
		}
	} else if (tile_name == "mountain4" && upper == 0) {
		int64_t rate = offset_3 < 30 ? 20 : 5;
		if (random.next_int(rate) == 0) {
			upper = NM("rock5");
		} else if (random.next_int(rate) == 0) {
			upper = NM("rock1_color");
		}
	}
	TileRef new_tile = make(intern(tile_name), p_edge, upper, true, tile_route);
	new_tile->biome = NM("beach");
	if (random.next_int(70) < 1) {
		apply_blotch("grass_sand", new_tile, 40, p_state.grass_tiles, 0, false, p_route);
	}
	return new_tile;
}

TileRef Gen::make_savanna_tile(Vector2i p_edge, const RouteRef &p_route) {
	int tile_name = NM("green_savanna1");
	int upper = 0;
	RouteRef tile_route = p_route;
	Vector2 rotated = rotate_deg(Vector2(p_edge), -15.0);
	int64_t offset_y = ((int64_t)Math::abs((double)rotated.y / 8.0)) % 14 - 7;
	int64_t offset_x = (((int64_t)Math::abs((double)rotated.x / 8.0)) - offset_y * 2) % 14 - 7;
	int64_t offset_1 = ABS(offset_x) + ABS(offset_y);
	offset_y = ABS(((int64_t)Math::abs((double)rotated.y / 8.0)) % 20 - 10);
	offset_x = ABS(((int64_t)Math::abs((double)rotated.x / 8.0)) % 20 - 10);
	int64_t offset_2 = offset_x + offset_y;
	if (offset_1 * (offset_2 / 5) > 6) {
		tile_name = NM("green_savanna3");
		if (random.next_int(5) == 0) {
			tile_name = p_edge.x % 32 == 0 ? NM("green_savanna4") : NM("green_savanna5");
		}
	} else if (offset_1 * offset_2 < 8) {
		tile_name = NM("sand1");
	}
	rotated = Vector2(p_edge);
	offset_y = ABS(((int64_t)Math::abs((double)rotated.y / 12.0)) % 60 - 30);
	offset_x = ABS(((int64_t)Math::abs((double)rotated.y / 12.0)) % 34 - 12);
	int64_t offset_3 = (offset_x + offset_y) / 2;
	offset_y = ((int64_t)Math::abs((double)rotated.y / 12.0)) % 14 - 7;
	offset_x = ((int64_t)Math::abs((double)rotated.x / 12.0 - (double)offset_3)) % 14 - 7;
	offset_1 = ABS(offset_x) + ABS(offset_y);
	offset_y = ABS(((int64_t)Math::abs((double)rotated.y / 12.0)) % 20 - 10);
	offset_x = ABS(((int64_t)Math::abs((double)rotated.x / 12.0 - (double)offset_3)) % 20 - 10);
	offset_2 = offset_x + offset_y;
	if (offset_1 * (offset_2 / 5) > 16) {
		upper = NM("grass_savanna1");
	} else if (offset_1 * (offset_2 / 5) > 14) {
		upper = NM("grass_savanna2");
	} else if (offset_1 * offset_2 < 1) {
		upper = NM("tree_savanna1");
	} else if (random.next_int(50) == 0) {
		upper = NM("bush_savanna1");
	} else {
		Vector2i pattern = diagonal_pattern(p_edge, 16.0);
		if ((int64_t)pattern.x * ((int64_t)pattern.y / 5) > 36 && random.next_int(10) < 4) {
			upper = NM("berrytree_cheri_full");
			if (random.next_int(6) == 0) {
				tile_route = route(NM(""), 22);
				append_stored(tile_route.get(), { "sudowoodo" }, 20, 4);
			}
		}
	}
	TileRef new_tile = make(tile_name, p_edge, upper, true, tile_route);
	new_tile->biome = NM("savanna");
	return new_tile;
}

TileRef Gen::make_graveyard_tile(Vector2i p_edge, double p_distance, int64_t p_maximum_distance, const RouteRef &p_route, BlotchState &p_state) {
	int tile_name = NM("green12");
	int upper = 0;
	RouteRef tile_route = p_route;
	Vector2 rotated = rotate_deg(Vector2(p_edge), -15.0);
	int64_t offset_y = ((int64_t)Math::abs((double)rotated.y / 8.0)) % 14 - 7;
	int64_t offset_x = (((int64_t)Math::abs((double)rotated.x / 8.0)) - offset_y * 2) % 14 - 7;
	int64_t offset_1 = ABS(offset_x) + ABS(offset_y);
	offset_y = ABS(((int64_t)Math::abs((double)rotated.y / 8.0)) % 20 - 10);
	offset_x = ABS(((int64_t)Math::abs((double)rotated.x / 8.0)) % 20 - 10);
	int64_t offset_2 = (offset_x + offset_y) / 5;
	if (offset_1 * offset_2 > 6) {
		tile_name = NM("green11");
		if (random.next_int(5) == 0) {
			tile_name = random.next_boolean() ? NM("green10") : NM("green9");
		}
	} else if (offset_1 < 2) {
		if (random.next_int(256) < 80) {
			tile_name = NM("flower5");
		}
	} else if (random.next_int(15) == 0) {
		tile_name = NM("flower5");
	}
	if (tile_name != NM("flower5") && random.next_int(110) == 0) {
		int64_t random_value = random.next_int(3);
		if (random_value == 0) {
			upper = NM("tree8");
			if (random.next_int(3) == 2) {
				tile_route = route(NM(""), 30);
				append_stored(tile_route.get(), { "trevenant" }, tile_route->level, 4);
			}
		} else if (random_value == 1) {
			upper = NM("berrytree_chesto_full");
			if (random.next_int(6) == 0) {
				tile_route = route(NM(""), 22);
				append_stored(tile_route.get(), { "sudowoodo" }, 20, 4);
			}
		} else {
			upper = NM("tree9");
			if (random.next_int(3) == 2) {
				tile_route = route(NM(""), 30);
				append_stored(tile_route.get(), { "phantump" }, 10, 4);
			}
		}
	}
	double y = (double)p_edge.y;
	double x = (double)p_edge.x;
	if (Math::fmod(y / 16.0, 2.0) == (double)(int64_t)(Math::fmod(y / 32.0, 11.0) / 5.0) && Math::fmod(x / 16.0, 2.0) == (double)(int64_t)(Math::fmod(x / 16.0 + y / 2.0, 13.0) / 5.0)) {
		Vector2 position(p_edge);
		offset_y = ((int64_t)Math::abs((double)position.y / 16.0)) % 14 - 7;
		offset_x = ((int64_t)Math::abs((double)position.x / 16.0 - (double)position.y / 16.0)) % 14 - 7;
		offset_1 = ABS(offset_x) + ABS(offset_y);
		offset_y = ABS(((int64_t)Math::abs((double)position.y / 16.0)) % 20 - 10);
		offset_x = ABS(((int64_t)Math::abs((double)position.x / 16.0)) % 20 - 10);
		offset_2 = (offset_x + offset_y) / 5;
		if (offset_1 * offset_2 > 9) {
			tile_name = NM("green12");
			upper = NM("gravestone2");
		}
	}
	TileRef new_tile = make(tile_name, p_edge, upper, true, tile_route);
	bool put_grass = random.next_int(90) < 1;
	if (p_distance > (double)(p_maximum_distance / 2)) {
		put_grass = random.next_int(40) < 1;
	}
	if (put_grass) {
		apply_blotch("grass_graveyard1", new_tile, 40, p_state.grass_tiles, 0, false, p_route);
	}
	new_tile->biome = NM("graveyard");
	if (offset_1 < 1) {
		p_state.fence_spawns.push_back(p_edge);
	}
	return new_tile;
}

TileRef Gen::make_snow_tile(Vector2i p_edge, const RouteRef &p_route, TileMap &p_tiles) {
	int tile_name = p_edge.x % 32 == p_edge.y % 32 ? NM("snow5") : NM("snow6");
	int upper = 0;
	RouteRef tile_route = p_route;
	Vector2 rotated = rotate_deg(Vector2(p_edge), -15.0);
	double offset_y = (double)(((int64_t)Math::abs((double)rotated.y / 8.0)) % 14 - 7);
	double offset_x = Math::fmod((double)((int64_t)Math::abs((double)rotated.x / 8.0)) - offset_y * 2.0, 14.0) - 7.0;
	double offset_1 = Math::abs(offset_x) + Math::abs(offset_y);
	offset_y = (double)ABS(((int64_t)Math::abs((double)rotated.y / 8.0)) % 20 - 10);
	offset_x = (double)ABS(((int64_t)Math::abs((double)rotated.x / 8.0)) % 20 - 10);
	double offset_2 = offset_x + offset_y;
	if (offset_1 * (offset_2 / 5.0) > 16.0) {
		tile_name = NM("snow2");
	}
	rotated = Vector2(p_edge);
	offset_y = (double)ABS(((int64_t)Math::abs((double)rotated.y / 12.0)) % 60 - 30);
	offset_x = (double)ABS(((int64_t)Math::abs((double)rotated.y / 12.0)) % 34 - 12);
	double offset_3 = (offset_x + offset_y) / 2.0;
	offset_y = (double)(((int64_t)Math::abs((double)rotated.y / 12.0)) % 14 - 7);
	offset_x = (double)(((int64_t)Math::abs((double)rotated.x / 12.0 - offset_3)) % 14 - 7);
	offset_1 = Math::abs(offset_x) + Math::abs(offset_y);
	offset_y = (double)ABS(((int64_t)Math::abs((double)rotated.y / 12.0)) % 20 - 10);
	offset_x = (double)ABS(((int64_t)Math::abs((double)rotated.x / 12.0 - offset_3)) % 20 - 10);
	offset_2 = offset_x + offset_y;
	if (offset_1 * (offset_2 / 5.0) > 16.0) {
		tile_name = NM("snow3");
	}
	if (!no_ice_here.has(p_edge)) {
		rotated = Vector2(p_edge + Vector2i(256, 256));
		offset_3 = Math::sin((double)rotated.y / 80.0) * 3.0;
		offset_y = Math::abs(Math::fmod(Math::abs((double)rotated.y / 40.0), 14.0) - 7.0);
		offset_x = Math::abs(Math::fmod(Math::abs((double)rotated.x / 40.0 - offset_3), 14.0) - 7.0);
		offset_1 = offset_x + offset_y;
		offset_y = Math::abs(Math::fmod(Math::abs((double)rotated.y / 40.0), 20.0) - 10.0);
		offset_x = Math::abs(Math::fmod(Math::abs((double)rotated.x / 40.0 - offset_3), 20.0) - 10.0);
		offset_2 = offset_x + offset_y;
		if (offset_1 * 5.0 * offset_2 > 500.0) {
			tile_name = NM("ice2");
		}
	}
	if (tile_name == NM("ice2")) {
		if (random.next_int(18) == 0) {
			upper = NM("rock_ice2");
		} else if (random.next_int(56) == 0) {
			tile_name = NM("water6");
			upper = NM("ice2_pit1");
			if (p_edge.x % 32 == 0 && random.next_int(4) == 0) {
				upper = NM("ice2_pit2");
				static const Vector2i offsets[3] = { Vector2i(16, 0), Vector2i(0, 16), Vector2i(16, 16) };
				for (const Vector2i &offset : offsets) {
					TileRef solid_tile = make(tile_name, p_edge + offset, NM("solid"), true, p_route);
					solid_tile->biome = NM("tundra");
					put(p_tiles, solid_tile->position, solid_tile);
				}
			}
		}
	} else {
		Vector2i pattern = diagonal_pattern(p_edge, 12.0);
		if ((double)pattern.x * ((double)pattern.y / 5.0) > 14.0) {
			if (random.next_int(5) < 3) {
				tile_name = NM("snow2");
				upper = NM("tree4");
				if (random.next_int(3) == 2) {
					tile_route = route(NM(""), 22);
					append_stored(tile_route.get(), { "snover" }, 20, 4);
				}
			}
			tile_route->dont_spawn = true;
		} else {
			pattern = diagonal_pattern(p_edge, 30.0);
			if ((double)pattern.x * ((double)pattern.y / 5.0) < 1.0 && random.next_int(10) < 4) {
				upper = NM("berrytree_aspear_full");
				if (random.next_int(6) == 0) {
					tile_route = route(NM(""), 22);
					append_stored(tile_route.get(), { "sudowoodo" }, 20, 4);
				}
			}
		}
	}
	TileRef new_tile = make(tile_name, p_edge, upper, true, tile_route);
	new_tile->biome = NM("tundra");
	return new_tile;
}

TileRef Gen::make_volcano_lava_tile(Tile *p_frontier, Vector2i p_edge, const RouteRef &p_route, TileMap &p_tiles) {
	int tile_name = NM("lava1");
	Vector2 rotated = rotate_deg(Vector2(p_frontier->position + rand_offset), 45.0);
	double offset_y = (double)(((int64_t)Math::abs((double)rotated.y / 12.0)) % 14 - 7);
	double offset_x = (double)(((int64_t)Math::abs((double)rotated.x / 12.0 - (double)rotated.y / 12.0)) % 14 - 7);
	double offset_1 = Math::abs(offset_x) + Math::abs(offset_y);
	offset_y = (double)ABS(((int64_t)Math::abs((double)rotated.y / 12.0)) % 20 - 10);
	offset_x = (double)ABS(((int64_t)Math::abs((double)rotated.x / 12.0)) % 20 - 10);
	if (offset_1 * ((offset_x + offset_y) / 5.0) > 22.0) {
		tile_name = NM("volcano2");
	}
	TileRef new_tile = make(tile_name, p_edge, 0, true, p_route);
	new_tile->biome = NM("volcano");
	// adjustSurroundingTiles runs before newTile is inserted (see GDScript).
	for (int64_t x_offset = -16; x_offset < 17; x_offset += 16) {
		for (int64_t y_offset = -16; y_offset < 17; y_offset += 16) {
			Tile *existing = as_tile(p_tiles.getp(p_edge + Vector2i((int32_t)x_offset, (int32_t)y_offset)));
			if (existing) {
				normalize_bare_lava(existing);
			}
		}
	}
	return new_tile;
}

void Gen::normalize_bare_lava(Tile *p_tile) {
	if (!has(p_tile->name, "lava") || p_tile->upper != 0) {
		return;
	}
	static const char *columns[3] = { "S", "", "N" };
	static const char *rows[3] = { "W", "", "E" };
	std::string extension = "_";
	if (global_random.next_int(3) != 0) {
		if (global_random.next_boolean()) {
			extension += columns[global_random.next_int(3)];
			extension += rows[Math::posmod((int64_t)p_tile->position.x, (int64_t)48) / 16];
		} else {
			extension += columns[Math::posmod((int64_t)p_tile->position.y, (int64_t)48) / 16];
			extension += rows[global_random.next_int(3)];
		}
	}
	set_names(p_tile, intern("lava1" + extension), p_tile->upper);
}

TileRef Gen::make_volcano_tile(Vector2i p_edge, const RouteRef &p_route) {
	int upper = 0;
	RouteRef tile_route = p_route;
	Vector2i shifted = p_edge + rand_offset;
	Vector2 rotated(shifted);
	double offset_y = (double)ABS(((int64_t)Math::abs((double)rotated.y / 12.0)) % 60 - 30);
	double offset_x = (double)ABS(((int64_t)Math::abs((double)rotated.y / 12.0)) % 34 - 12);
	double offset_3 = (offset_x + offset_y) / 2.0;
	offset_y = (double)(((int64_t)Math::abs((double)rotated.y / 12.0)) % 14 - 7);
	offset_x = (double)(((int64_t)Math::abs((double)rotated.x / 12.0 - offset_3)) % 14 - 7);
	double offset_1 = Math::abs(offset_x) + Math::abs(offset_y);
	offset_y = (double)ABS(((int64_t)Math::abs((double)rotated.y / 12.0)) % 20 - 10);
	offset_x = (double)ABS(((int64_t)Math::abs((double)rotated.x / 12.0 - offset_3)) % 20 - 10);
	if (offset_1 * ((offset_x + offset_y) / 5.0) > 16.0) {
		upper = NM("soot1");
	}
	Vector2i pattern = diagonal_pattern(shifted, 12.0);
	if ((double)pattern.x * ((double)pattern.y / 5.0) > 14.0 && random.next_int(5) == 0) {
		upper = NM("rock_volcano1");
	}
	if (random.next_int(50) == 0) {
		upper = NM("rock1_color");
		if (random.next_int(2) == 0) {
			tile_route = route(NM(""), 22);
			append_stored(tile_route.get(), { "slugma", "geodude" }, tile_route->level, 3);
		}
	}
	TileRef new_tile = make(NM("volcano1"), p_edge, upper, true, tile_route);
	new_tile->biome = NM("volcano");
	return new_tile;
}

Vector2 Gen::wavy_pattern(Vector2i p_position, double p_scale) {
	Vector2 rotated(p_position);
	double offset_y = (double)ABS(((int64_t)Math::abs((double)rotated.y / p_scale)) % 60 - 30);
	double offset_x = (double)ABS(((int64_t)Math::abs((double)rotated.y / p_scale)) % 34 - 12);
	double offset_3 = (offset_x + offset_y) / 2.0;
	offset_y = (double)(((int64_t)Math::abs((double)rotated.y / p_scale)) % 14 - 7);
	offset_x = (double)(((int64_t)Math::abs((double)rotated.x / p_scale - offset_3)) % 14 - 7);
	double offset_1 = Math::abs(offset_x) + Math::abs(offset_y);
	offset_y = (double)ABS(((int64_t)Math::abs((double)rotated.y / p_scale)) % 20 - 10);
	offset_x = (double)ABS(((int64_t)Math::abs((double)rotated.x / p_scale - offset_3)) % 20 - 10);
	return Vector2((float)offset_1, (float)(offset_x + offset_y));
}

TileRef Gen::make_wooded_lake_tile(Vector2i p_edge, const RouteRef &p_route, BlotchState &p_state) {
	int tile_name = NM("green1");
	int upper = 0;
	RouteRef tile_route = p_route;
	if (random.next_int(8) == 0) {
		if (random.next_boolean()) {
			tile_name = NM("flower4");
		} else {
			tile_name = p_edge.x % 32 == 0 ? NM("flower2") : NM("flower3");
		}
	}
	Vector2 wavy = wavy_pattern(p_edge, 12.0);
	if ((double)wavy.x * ((double)wavy.y / 5.0) > 16.0) {
		tile_name = NM("grass4");
	}
	Vector2i pattern = diagonal_pattern(p_edge, 30.0);
	if ((double)pattern.x * ((double)pattern.y / 5.0) > 8.0) {
		if (random.next_int(5) < 4) {
			tile_name = NM("green1");
			upper = NM("tree2");
			if (random.next_int(3) == 2) {
				tile_route = route(NM(""), 22);
				append_stored(tile_route.get(), TREE_POKEMON, 20, 4);
			}
		}
		tile_route->dont_spawn = true;
	}
	pattern = diagonal_pattern(p_edge, 16.0);
	if ((double)pattern.x * ((double)pattern.y / 5.0) > 36.0 && random.next_int(10) < 4) {
		upper = NM("berrytree_persim_full");
		if (random.next_int(6) == 0) {
			tile_route = route(NM(""), 22);
			append_stored(tile_route.get(), { "sudowoodo" }, 20, 4);
		}
	}
	pattern = diagonal_pattern(p_edge, 60.0);
	if ((double)pattern.x * ((double)pattern.y / 5.0) < 5.0) {
		tile_name = NM("water2");
		upper = 0;
		tile_route = p_state.beach_route;
	}
	TileRef new_tile = make(tile_name, p_edge, upper, true, tile_route);
	new_tile->biome = NM("wooded_lake");
	return new_tile;
}

TileRef Gen::make_green_mountain_tile(Vector2i p_edge, const RouteRef &p_route, BlotchState &p_state) {
	int tile_name = NM("green1");
	int upper = 0;
	RouteRef tile_route = p_route;
	if (random.next_int(8) == 0) {
		if (random.next_boolean()) {
			tile_name = NM("flower4");
		} else {
			tile_name = p_edge.x % 32 == 0 ? NM("flower2") : NM("flower3");
		}
	}
	Vector2 wavy = wavy_pattern(p_edge, 12.0);
	if ((double)wavy.x * ((double)wavy.y / 5.0) > 16.0) {
		tile_name = NM("grass2");
	}
	Vector2i pattern = diagonal_pattern(p_edge, 12.0);
	if ((double)pattern.x * ((double)pattern.y / 5.0) > 14.0 && random.next_int(5) < 3) {
		tile_name = NM("green1");
		upper = NM("tree2");
		if (random.next_int(3) == 2) {
			tile_route = route(NM(""), 22);
			append_stored(tile_route.get(), TREE_POKEMON, 20, 4);
		}
	}
	if (!no_ice_here.has(p_edge)) {
		Vector2 shifted(p_edge + Vector2i(256, 256));
		double sine_offset = Math::sin((double)shifted.y / 80.0) * 3.0;
		double offset_y = Math::abs(Math::fmod(Math::abs((double)shifted.y / 40.0), 14.0) - 7.0);
		double offset_x = Math::abs(Math::fmod(Math::abs((double)shifted.x / 40.0 - sine_offset), 14.0) - 7.0);
		double offset_1 = offset_x + offset_y;
		offset_y = Math::abs(Math::fmod(Math::abs((double)shifted.y / 40.0), 20.0) - 10.0);
		offset_x = Math::abs(Math::fmod(Math::abs((double)shifted.x / 40.0 - sine_offset), 20.0) - 10.0);
		if (offset_1 * 5.0 * (offset_x + offset_y) > 500.0) {
			tile_name = NM("water2");
			upper = 0;
			tile_route = p_state.beach_route;
		}
	}
	TileRef new_tile = make(tile_name, p_edge, upper, true, tile_route);
	new_tile->biome = NM("mountain");
	return new_tile;
}

// --- Mazes (source_maze.gd) and GenForest2 squares (source_forest_generator.gd)

static void maze_neighbours(int64_t p_x, int64_t p_y, int64_t p_width, int64_t p_height, std::vector<Vector2i> &r_neighbours) {
	r_neighbours.clear();
	if (p_x > 1) {
		r_neighbours.push_back(Vector2i((int32_t)(p_x - 2), (int32_t)p_y));
	}
	if (p_x < p_width - 2) {
		r_neighbours.push_back(Vector2i((int32_t)(p_x + 2), (int32_t)p_y));
	}
	if (p_y > 1) {
		r_neighbours.push_back(Vector2i((int32_t)p_x, (int32_t)(p_y - 2)));
	}
	if (p_y < p_height - 2) {
		r_neighbours.push_back(Vector2i((int32_t)p_x, (int32_t)(p_y + 2)));
	}
}

Maze maze_algo2(int64_t p_width, int64_t p_height, double p_complexity, double p_density, JavaRandom &p_random) {
	int64_t width = p_width / 2 * 2 + 2;
	int64_t height = p_height / 2 * 2 + 2;
	// Java floats before truncating (see GDScript).
	int64_t complexity_steps = (int64_t)f32(f32(p_complexity) * f32((double)(5 * (height + width))));
	int64_t density_steps = (int64_t)f32(f32(p_density) * f32((double)((height / 2) * (width / 2))));
	Maze maze(width, height);
	for (int64_t x = 0; x < width; x++) {
		for (int64_t y = 0; y < height; y++) {
			if (x == 0 || y == 0 || x == width - 2 || y == height - 2) {
				maze.set(x, y, true);
			}
		}
	}
	std::vector<Vector2i> neighbours;
	for (int64_t iteration = 0; iteration < density_steps; iteration++) {
		int64_t x = p_random.next_int(width / 2) * 2;
		int64_t y = p_random.next_int(height / 2) * 2;
		maze.set(x, y, true);
		for (int64_t step = 0; step < complexity_steps; step++) {
			maze_neighbours(x, y, width, height, neighbours);
			if (neighbours.empty()) {
				continue;
			}
			Vector2i selected = neighbours[p_random.next_int((int64_t)neighbours.size())];
			if (maze.get(selected.x, selected.y)) {
				continue;
			}
			maze.set(selected.x, selected.y, true);
			maze.set(selected.x + (x - selected.x) / 2, selected.y + (y - selected.y) / 2, true);
			x = selected.x;
			y = selected.y;
		}
	}
	return maze;
}

Maze maze_algo3(int64_t p_width, int64_t p_height, double p_complexity, double p_density, JavaRandom &p_random, std::vector<Vector2i> &r_start_locations) {
	int64_t width = p_width / 2 * 2 + 2;
	int64_t height = p_height / 2 * 2 + 2;
	std::vector<Vector2i> endpoints;
	Maze maze(width, height);
	std::vector<Vector2i> neighbours;
	int64_t iterations = (int64_t)Math::ceil(p_density);
	int64_t steps = (int64_t)Math::ceil(p_complexity);
	for (int64_t iteration = 0; iteration < iterations; iteration++) {
		int64_t x;
		int64_t y;
		if (!r_start_locations.empty()) {
			Vector2i supplied = r_start_locations.front();
			r_start_locations.erase(r_start_locations.begin());
			x = supplied.x;
			y = supplied.y;
		} else {
			x = p_random.next_int(width / 2) * 2;
			y = p_random.next_int(height / 2) * 2;
		}
		x = CLAMP(x, (int64_t)0, width - 1);
		y = CLAMP(y, (int64_t)0, height - 1);
		maze.set(x, y, true);
		bool placed_one_wall = false;
		for (int64_t step = 0; step < steps; step++) {
			maze_neighbours(x, y, width, height, neighbours);
			if (neighbours.empty()) {
				continue;
			}
			Vector2i selected = neighbours[p_random.next_int((int64_t)neighbours.size())];
			if (maze.get(selected.x, selected.y)) {
				continue;
			}
			maze.set(selected.x, selected.y, true);
			maze.set(selected.x + (x - selected.x) / 2, selected.y + (y - selected.y) / 2, true);
			x = selected.x;
			y = selected.y;
			placed_one_wall = true;
		}
		if (placed_one_wall) {
			endpoints.push_back(Vector2i((int32_t)x, (int32_t)y));
		}
	}
	r_start_locations = endpoints;
	return maze;
}

static std::vector<MazeNode> maze_algo1(int64_t p_width, int64_t p_height, double p_complexity, double p_density, int64_t p_square_size, JavaRandom &p_random) {
	Maze maze = maze_algo2(p_width, p_height, p_complexity, p_density, p_random);
	std::vector<MazeNode> nodes;
	for (int64_t x = 0; x < maze.width / 2; x++) {
		for (int64_t y = 0; y < maze.height / 2; y++) {
			MazeNode node;
			node.x = x;
			node.y = y;
			node.left_open = !maze.get(x * 2, y * 2 + 1);
			node.down_open = !maze.get(x * 2 + 1, y * 2);
			node.square_size = p_square_size;
			nodes.push_back(node);
		}
	}
	return nodes;
}

typedef std::vector<std::vector<int>> Format;

static Format format(std::initializer_list<std::initializer_list<const char *>> p_rows) {
	Format result;
	for (const auto &row : p_rows) {
		std::vector<int> ids;
		for (const char *name : row) {
			ids.push_back(intern(name));
		}
		result.push_back(ids);
	}
	return result;
}

struct Specs {
	std::vector<int> names;
	std::vector<Vector2i> positions;
};

static Specs gen_specs(const Format &p_format, int64_t p_offset_x, int64_t p_offset_y, JavaRandom &p_random) {
	Specs specs;
	int64_t i = 5;
	for (const std::vector<int> &row : p_format) {
		int64_t j = 0;
		for (int raw_name : row) {
			int tile_name = raw_name;
			if (tile_name == NM("either")) {
				tile_name = p_random.next_int(2) == 0 ? NM("solid") : 0;
			}
			if (tile_name != 0) {
				specs.names.push_back(tile_name);
				// Positions go through a Vector2 (floats) in GDScript.
				Vector2 position((float)(j * 16 + p_offset_x), (float)(i * 16 + p_offset_y));
				specs.positions.push_back(Vector2i(position));
			}
			j += 1;
		}
		i -= 1;
	}
	return specs;
}

static void flip_format(Format &r_format) {
	for (int i = 0; i < (int)r_format.size(); i++) {
		for (int j = 0; j < (int)r_format[i].size(); j++) {
			if (i >= 5 - j) {
				break;
			}
			std::swap(r_format[i][j], r_format[5 - j][5 - i]);
		}
	}
}

static void maybe_add_ledge(Format &r_format, JavaRandom &p_random, bool p_clear_vertical) {
	if (p_random.next_int(3) != 1) {
		return;
	}
	int64_t row_index = p_random.next_int((int64_t)r_format.size() - 2) + 1;
	std::vector<int> &row = r_format[row_index];
	bool on_ground = false;
	std::vector<int64_t> ledge_indices;
	for (int64_t i = 0; i < (int64_t)row.size(); i++) {
		if (row[i] != NM("solid")) {
			on_ground = true;
			ledge_indices.push_back(i);
		} else if (on_ground) {
			break;
		}
	}
	ERR_FAIL_COND(ledge_indices.empty());
	int64_t ramp_index = ledge_indices[p_random.next_int((int64_t)ledge_indices.size())];
	for (int64_t index : ledge_indices) {
		row[index] = NM("ledge_grass_down");
		if (index == ramp_index) {
			row[index] = NM("ledge_grass_ramp");
			if (p_clear_vertical) {
				r_format[row_index - 1][index] = 0;
				r_format[row_index + 1][index] = 0;
			}
		}
	}
}

static Specs get_tile_square_specs(const MazeNode &p_node, Vector2i p_start, JavaRandom &p_random) {
	static const Format closed_a = format({ { "solid", "solid", "", "", "either", "either" }, { "solid", "solid", "solid", "", "", "either" }, { "solid", "solid", "solid", "solid", "", "" }, { "solid", "solid", "solid", "solid", "solid", "" }, { "solid", "solid", "solid", "solid", "solid", "solid" }, { "solid", "solid", "solid", "solid", "solid", "solid" } });
	static const Format closed_b = format({ { "solid", "solid", "", "", "solid", "solid" }, { "solid", "solid", "", "", "solid", "solid" }, { "solid", "solid", "either", "", "", "" }, { "solid", "solid", "either", "either", "", "" }, { "solid", "solid", "solid", "solid", "solid", "solid" }, { "solid", "solid", "solid", "solid", "solid", "solid" } });
	static const Format one_a = format({ { "either", "either", "", "", "either", "either" }, { "", "", "", "", "", "" }, { "", "", "", "", "", "" }, { "", "either", "", "either", "", "" }, { "solid", "solid", "solid", "solid", "solid", "solid" }, { "solid", "solid", "solid", "solid", "solid", "solid" } });
	static const Format one_b = format({ { "", "", "", "", "solid", "solid" }, { "", "", "", "solid", "solid", "solid" }, { "", "", "", "", "", "" }, { "", "", "", "", "", "" }, { "solid", "solid", "solid", "solid", "solid", "solid" }, { "solid", "solid", "solid", "solid", "solid", "solid" } });
	static const Format open_a = format({ { "", "", "", "", "solid", "solid" }, { "", "", "", "either", "solid", "solid" }, { "", "", "", "", "either", "" }, { "", "either", "", "", "", "" }, { "solid", "solid", "either", "", "", "" }, { "solid", "solid", "", "", "", "" } });
	static const Format open_b = format({ { "", "", "", "", "", "" }, { "", "", "", "", "", "" }, { "", "", "", "", "", "" }, { "", "", "", "", "", "" }, { "solid", "solid", "", "", "", "" }, { "solid", "solid", "", "", "", "" } });
	int64_t offset_x = p_node.square_size * p_node.x + p_start.x;
	int64_t offset_y = p_node.square_size * p_node.y + p_start.y;
	std::vector<Specs> squares;
	// Route.java creates and mutates an unused array: the draw stays.
	p_random.next_int(6);
	if (!p_node.left_open && !p_node.down_open) {
		squares.push_back(gen_specs(closed_a, offset_x, offset_y, p_random));
		squares.push_back(gen_specs(closed_b, offset_x, offset_y, p_random));
	} else if (p_node.left_open != p_node.down_open) {
		Format current = one_a;
		if (p_node.down_open) {
			flip_format(current);
			maybe_add_ledge(current, p_random, true);
		}
		squares.push_back(gen_specs(current, offset_x, offset_y, p_random));
		current = one_b;
		if (p_node.down_open) {
			flip_format(current);
			maybe_add_ledge(current, p_random, false);
		}
		squares.push_back(gen_specs(current, offset_x, offset_y, p_random));
	} else {
		squares.push_back(gen_specs(open_a, offset_x, offset_y, p_random));
		squares.push_back(gen_specs(open_b, offset_x, offset_y, p_random));
	}
	return squares[p_random.next_int((int64_t)squares.size())];
}

void Gen::apply_forest_maze(TileMap &p_tiles, OMap<Vector2i, bool> &p_forest_maze_tiles, std::vector<Vector2i> &p_deep_forest_positions, BlotchState &p_state) {
	Vector2i bottom_left_corner;
	Vector2i top_right_corner;
	bool first = true;
	p_forest_maze_tiles.each([&](const Vector2i &p_position, const bool &) {
		if (first) {
			bottom_left_corner = p_position;
			top_right_corner = p_position;
			first = false;
		} else {
			bottom_left_corner.x = MIN(bottom_left_corner.x, p_position.x);
			bottom_left_corner.y = MIN(bottom_left_corner.y, p_position.y);
			top_right_corner.x = MAX(top_right_corner.x, p_position.x);
			top_right_corner.y = MAX(top_right_corner.y, p_position.y);
		}
	});
	top_right_corner.x -= (int32_t)Math::posmod((int64_t)top_right_corner.x, (int64_t)96);
	bottom_left_corner.x -= (int32_t)Math::posmod((int64_t)bottom_left_corner.x, (int64_t)96);
	top_right_corner.y += (int32_t)(96 - Math::posmod((int64_t)top_right_corner.y, (int64_t)96));
	bottom_left_corner.y += (int32_t)(96 - Math::posmod((int64_t)bottom_left_corner.y, (int64_t)96));
	std::vector<MazeNode> nodes = maze_algo1(((int64_t)top_right_corner.x - bottom_left_corner.x) * 2 / 96, ((int64_t)top_right_corner.y - bottom_left_corner.y) * 2 / 96, 0.1, 0.9, 96, random);
	for (const MazeNode &node : nodes) {
		// Only the maze cells inside the blotch become tiles.
		Specs square = get_tile_square_specs(node, bottom_left_corner, random);
		for (size_t index = 0; index < square.names.size(); index++) {
			Vector2i position = square.positions[index];
			if (p_forest_maze_tiles.has(position)) {
				TileRef tile = make(square.names[index], position, 0, true);
				put(p_tiles, tile->position, tile);
			}
		}
	}
	if (!p_tiles.is_empty()) {
		// ApplyForestBiome constructs a new java.util.Random per maze.
		JavaRandom forest_pass_random(forest_biome_random.next_int());
		for (int64_t x = bottom_left_corner.x; x < (int64_t)top_right_corner.x + 192; x += 16) {
			for (int64_t y = bottom_left_corner.y; y < (int64_t)top_right_corner.y + 192; y += 16) {
				Vector2i position((int32_t)x, (int32_t)y);
				Tile *tile = as_tile(p_tiles.getp(position));
				if (!tile || tile->name != NM("solid")) {
					continue;
				}
				Tile *right = as_tile(p_tiles.getp(position + Vector2i(16, 0)));
				Tile *up = as_tile(p_tiles.getp(position + Vector2i(0, 16)));
				Tile *up_right = as_tile(p_tiles.getp(position + Vector2i(16, 16)));
				if (ABS((int64_t)position.x - bottom_left_corner.x) % 32 == 0 && ABS((int64_t)position.y - bottom_left_corner.y) % 32 == 0 && right && up && up_right && right->name == NM("solid") && up->name == NM("solid") && up_right->name == NM("solid")) {
					put(p_tiles, position, make(NM("tree_large1"), position, 0, true));
					put(p_tiles, position + Vector2i(16, 0), make(NM("tree_large1_noSprite"), position + Vector2i(16, 0)));
					put(p_tiles, position + Vector2i(0, 16), make(NM("tree_large1_noSprite"), position + Vector2i(0, 16)));
					put(p_tiles, position + Vector2i(16, 16), make(NM("tree_large1_noSprite"), position + Vector2i(16, 16)));
					continue;
				}
				RouteRef bush_route = route(NM(""), 11);
				int64_t random_value = forest_pass_random.next_int(3);
				if (random_value == 2) {
					random_value = forest_pass_random.next_int((int64_t)TREE_POKEMON.size());
					Dictionary stored;
					stored["name"] = TREE_POKEMON[random_value];
					stored["level"] = 10 + forest_pass_random.next_int(4);
					bush_route->stored.push_back(stored);
				}
				put(p_tiles, position, make(NM("bush1"), position, 0, true, bush_route));
			}
		}
	}
	PosSet deep_forest_set;
	for (const Vector2i &position : p_deep_forest_positions) {
		deep_forest_set.insert(position, true);
	}
	for (Cell &cell : p_tiles.values()) {
		Tile *tile = cell.tile.get();
		if (!tile) {
			continue;
		}
		int tile_name = tile->name;
		if (tile_name == NM("ledge_grass_down") || tile_name == NM("ledge_ramp_down")) {
			repair_maze_ledge(p_tiles, tile, 16);
			repair_maze_ledge(p_tiles, tile, -16);
		}
		if (deep_forest_set.has(tile->position)) {
			tile->route = p_state.deep_forest_route;
			tile->biome = NM("deep_forest");
			if (tile->name == NM("grass2")) {
				set_names(tile, NM("grass4"), tile->upper);
			}
		}
	}
}

void Gen::repair_maze_ledge(TileMap &p_tiles, Tile *p_tile, int64_t p_side) {
	Vector2i adjacent_position = p_tile->position + Vector2i((int32_t)p_side, 0);
	Tile *adjacent = as_tile(p_tiles.getp(adjacent_position));
	if (!adjacent || adjacent->solid() || adjacent->ledge()) {
		return;
	}
	TileMap vertical_tiles;
	TileMap horizontal_tiles;
	put(vertical_tiles, adjacent_position, make(p_side > 0 ? NM("ledge1_corner_br") : NM("ledge1_corner_bl"), adjacent_position, 0, true));
	put(horizontal_tiles, adjacent_position, make(NM("ledge_grass_down"), adjacent_position, 0, true));
	for (int64_t distance = 16; distance < 80; distance += 16) {
		Vector2i vertical_position = p_tile->position + Vector2i((int32_t)p_side, (int32_t)distance);
		Tile *vertical = as_tile(p_tiles.getp(vertical_position));
		if (vertical && (vertical->solid() || vertical->ledge())) {
			p_tiles.merge(vertical_tiles, true);
			break;
		}
		Vector2i horizontal_position = p_tile->position + Vector2i((int32_t)(p_side + SIGN(p_side) * distance), 0);
		Tile *horizontal = as_tile(p_tiles.getp(horizontal_position));
		if (horizontal && (horizontal->solid() || horizontal->ledge())) {
			p_tiles.merge(horizontal_tiles, true);
			break;
		}
		put(vertical_tiles, vertical_position, make(p_side > 0 ? NM("ledge1_right") : NM("ledge1_left"), vertical_position, 0, true));
		put(horizontal_tiles, horizontal_position, make(NM("ledge_grass_down"), horizontal_position, 0, true));
	}
}

// --- Graveyard fences

static int64_t graveyard_row_shift(int64_t p_y) {
	return (int64_t)(Math::fmod((double)p_y / 16.0, 2.0) + (double)(int64_t)(Math::fmod((double)p_y / 32.0, 11.0) / 5.0)) * 16;
}

void Gen::place_graveyard_fences(TileMap &p_tiles, std::vector<Vector2i> &p_fence_spawns, const RouteRef &p_route) {
	int64_t number_of_fences = random.next_int(4) + 1;
	while (number_of_fences > 0 && !p_fence_spawns.empty()) {
		number_of_fences -= 1;
		bool done_doll = false;
		int64_t pick = random.next_int((int64_t)p_fence_spawns.size());
		Vector2i edge = p_fence_spawns[pick];
		p_fence_spawns.erase(p_fence_spawns.begin() + pick);
		int64_t size = 4 + random.next_int(3);
		int64_t left = random.next_int(size);
		int64_t door_offset = random.next_int(2) * 16;
		int64_t number_of_doors = random.next_int(4) + 1;
		Vector2i bottom_left_corner = edge + Vector2i((int32_t)(-16 * left), (int32_t)(-16 * left));
		bottom_left_corner.x += bottom_left_corner.x % 32;
		bottom_left_corner.y += (int32_t)graveyard_row_shift(bottom_left_corner.y);
		Vector2i top_right_corner = bottom_left_corner + Vector2i((int32_t)(16 * size), (int32_t)(16 * size));
		top_right_corner.x += top_right_corner.x % 32;
		top_right_corner.y += (int32_t)graveyard_row_shift(top_right_corner.y);
		Vector2i current = bottom_left_corner;
		while (current.y <= top_right_corner.y) {
			int tile_name = NM("flower5");
			int upper = 0;
			bool replace = true;
			if (current == bottom_left_corner) {
				tile_name = NM("green12");
				upper = NM("fence1_NE");
			} else if (current == top_right_corner) {
				tile_name = NM("green12");
				upper = NM("fence1_SW");
			} else if (current == Vector2i(bottom_left_corner.x, top_right_corner.y)) {
				tile_name = NM("green12");
				upper = NM("fence1_SE");
			} else if (current == Vector2i(top_right_corner.x, bottom_left_corner.y)) {
				tile_name = NM("green12");
				upper = NM("fence1_NW");
			} else if (current.y == bottom_left_corner.y || current.y == top_right_corner.y) {
				tile_name = NM("green12");
				upper = NM("fence1");
				if (number_of_doors > 0 && current.x == bottom_left_corner.x + size / 2 * 16 + door_offset) {
					upper = NM("house5_door1");
					number_of_doors -= 1;
				}
			} else if (current.x == bottom_left_corner.x || current.x == top_right_corner.x) {
				tile_name = NM("green12");
				upper = NM("fence1_NS");
				if (random.next_boolean() && number_of_doors > 0 && current.y == bottom_left_corner.y + size / 2 * 16 + door_offset) {
					upper = NM("house5_door1");
					number_of_doors -= 1;
				}
			} else {
				Tile *existing = as_tile(p_tiles.getp(current));
				if (existing) {
					if (existing->upper != 0 && current.y != bottom_left_corner.y + 16) {
						replace = false;
					}
					if (has(existing->upper, "fence")) {
						replace = true;
					}
				}
				if (replace && current.y % 32 == 0 && current.x != bottom_left_corner.x + 16 && current.x != top_right_corner.x - 16 && current.y != bottom_left_corner.y + 16) {
					keystone_spawns.push_back(current);
					if (random.next_int(3) == 0) {
						tile_name = NM("green12");
						upper = NM("gravestone2");
					}
					if (!done_doll && !(size > 5 && random.next_int(3) != 0)) {
						done_doll = true;
						int64_t random_value = random.next_int(3);
						upper = random_value == 0 ? NM("pokedoll1_mimikyu") : (random_value == 1 ? NM("pokedoll1_banette") : NM("pokedoll1"));
					}
				}
			}
			if (replace) {
				TileRef new_tile = make(tile_name, current, upper, true, p_route);
				new_tile->biome = NM("graveyard");
				put(p_tiles, current, new_tile);
			}
			current.x += 16;
			if (current.x > top_right_corner.x) {
				current.x = bottom_left_corner.x;
				current.y += 16;
			}
		}
		graveyard_fence_bounds.push_back(Rect2i(bottom_left_corner, top_right_corner - bottom_left_corner));
		style_graveyard_fence_group(p_tiles, bottom_left_corner, top_right_corner);
	}
}

void Gen::style_graveyard_fence_group(TileMap &p_tiles, Vector2i p_bottom_left, Vector2i p_top_right) {
	for (int64_t y = (int64_t)p_bottom_left.y - 16; y < (int64_t)p_top_right.y + 32; y += 16) {
		for (int64_t x = (int64_t)p_bottom_left.x - 16; x < (int64_t)p_top_right.x + 32; x += 16) {
			Tile *tile = get_tile(p_tiles, Vector2i((int32_t)x, (int32_t)y));
			if (!tile || !has(tile->upper, "fence") || has(tile->upper, "house") || has(tile->upper, "gate")) {
				continue;
			}
			adjust_fence_tile(tile, p_tiles);
		}
	}
	// Visible side rails, whatever the neighbour styling did.
	for (int64_t y = (int64_t)p_bottom_left.y + 16; y < p_top_right.y; y += 16) {
		const int32_t xs[2] = { p_bottom_left.x, p_top_right.x };
		for (int32_t x : xs) {
			Tile *side_tile = get_tile(p_tiles, Vector2i(x, (int32_t)y));
			if (!side_tile || !has(side_tile->upper, "fence") || has(side_tile->upper, "gate") || has(side_tile->upper, "door")) {
				continue;
			}
			std::string fence_base = has(side_tile->upper, "fence2") ? "fence2" : "fence1";
			set_names(side_tile, side_tile->name, intern(fence_base + "_NS"));
		}
	}
	// The four authored corners (a Dictionary literal: a repeated key keeps
	// its first place and takes the last value).
	OMap<Vector2i, int> authored_corners;
	authored_corners.set(p_bottom_left, NM("fence1_NE"));
	authored_corners.set(p_top_right, NM("fence1_SW"));
	authored_corners.set(Vector2i(p_bottom_left.x, p_top_right.y), NM("fence1_SE"));
	authored_corners.set(Vector2i(p_top_right.x, p_bottom_left.y), NM("fence1_NW"));
	authored_corners.each([&](const Vector2i &p_corner, const int &p_upper) {
		Tile *corner_tile = get_tile(p_tiles, p_corner);
		if (corner_tile && !has(corner_tile->upper, "door") && !has(corner_tile->upper, "gate")) {
			set_names(corner_tile, corner_tile->name, p_upper);
		}
	});
	for (int64_t y = p_bottom_left.y; y < (int64_t)p_top_right.y + 16; y += 16) {
		for (int64_t x = p_bottom_left.x; x < (int64_t)p_top_right.x + 16; x += 16) {
			Tile *tile = get_tile(p_tiles, Vector2i((int32_t)x, (int32_t)y));
			if (!tile || !has(tile->upper, "door")) {
				continue;
			}
			Tile *left = get_tile(p_tiles, tile->position + Vector2i(-16, 0));
			Tile *right = get_tile(p_tiles, tile->position + Vector2i(16, 0));
			Tile *up = get_tile(p_tiles, tile->position + Vector2i(0, 16));
			Tile *down = get_tile(p_tiles, tile->position + Vector2i(0, -16));
			if (left && right && (has(left->upper, "fence") || has(left->upper, "gate")) && (has(right->upper, "fence") || has(right->upper, "gate"))) {
				set_names(tile, tile->name, NM("fence1gate1"));
			} else if (up && down && (has(up->upper, "fence") || has(up->upper, "gate")) && (has(down->upper, "fence") || has(down->upper, "gate"))) {
				set_names(tile, tile->name, NM("fence1gate1_NS"));
			}
		}
	}
	// Final perimeter pass: every boundary cell but gates stays a fence.
	for (int64_t y = p_bottom_left.y; y < (int64_t)p_top_right.y + 16; y += 16) {
		for (int64_t x = p_bottom_left.x; x < (int64_t)p_top_right.x + 16; x += 16) {
			bool on_left = x == p_bottom_left.x;
			bool on_right = x == p_top_right.x;
			bool on_bottom = y == p_bottom_left.y;
			bool on_top = y == p_top_right.y;
			if (!(on_left || on_right || on_bottom || on_top)) {
				continue;
			}
			Tile *perimeter_tile = get_tile(p_tiles, Vector2i((int32_t)x, (int32_t)y));
			if (!perimeter_tile) {
				continue;
			}
			std::string current_upper = lower(S(perimeter_tile->upper));
			if (current_upper.find("gate") != std::string::npos || current_upper.find("door") != std::string::npos) {
				continue;
			}
			const char *visible_fence = "fence1";
			if (on_left && on_bottom) {
				visible_fence = "fence1_NE";
			} else if (on_right && on_bottom) {
				visible_fence = "fence1_NW";
			} else if (on_left && on_top) {
				visible_fence = "fence1_SE";
			} else if (on_right && on_top) {
				visible_fence = "fence1_SW";
			} else if (on_left || on_right) {
				visible_fence = "fence1_NS";
			}
			set_names(perimeter_tile, perimeter_tile->name, intern(visible_fence));
		}
	}
}

void Gen::adjust_fence_tile(Tile *p_tile, TileMap &p_tiles) {
	Tile *up = get_tile(p_tiles, p_tile->position + Vector2i(0, 16));
	Tile *down = get_tile(p_tiles, p_tile->position + Vector2i(0, -16));
	Tile *right = get_tile(p_tiles, p_tile->position + Vector2i(16, 0));
	Tile *left = get_tile(p_tiles, p_tile->position + Vector2i(-16, 0));
	std::vector<std::string> tokens = split(S(p_tile->upper), "_");
	std::string base_name = tokens[0];
	for (size_t index = 1; index + 1 < tokens.size(); index++) {
		base_name += "_" + tokens[index];
	}
	bool touch_up = up && S(up->upper).find(base_name) != std::string::npos;
	bool touch_down = down && S(down->upper).find(base_name) != std::string::npos;
	bool touch_right = right && S(right->upper).find(base_name) != std::string::npos;
	bool touch_left = left && S(left->upper).find(base_name) != std::string::npos;
	if (down && has(down->upper, "house")) {
		touch_down = true;
	}
	if (left && has(left->upper, "house") && !has(left->upper, "roof")) {
		touch_left = true;
	}
	if (right && has(right->upper, "house") && !has(right->upper, "roof")) {
		touch_right = true;
	}
	if (up && !has(p_tile->upper, "fence2") && has(up->upper, "house")) {
		touch_up = true;
	}
	if (!(touch_up || touch_down || touch_left || touch_right)) {
		return;
	}
	std::string extension = "_";
	if (touch_up) {
		extension += "N";
	}
	if (touch_down) {
		extension += "S";
	}
	if (touch_right) {
		extension += "E";
	}
	if (touch_left) {
		extension += "W";
	}
	if (touch_left && touch_right && !touch_up && !touch_down) {
		extension = "";
	}
	if ((touch_up || touch_down) && !touch_left && !touch_right) {
		extension = "_NS";
	}
	if (extension.size() == 2) {
		extension = "";
	}
	set_names(p_tile, p_tile->name, intern(base_name + extension));
}

// --- _continue_blotch: the recursive growth into new blotches

void Gen::continue_blotch(const std::string &p_type, int64_t p_maximum_distance, int64_t p_new_size, std::vector<TileRef> &p_previous_tiles, TileMap &p_tiles, int64_t p_is_maze, bool p_do_next, RouteRef p_route, OMap<Vector2i, bool> &p_forest_maze_tiles) {
	if (p_new_size <= 0) {
		return;
	}
	const int64_t md = p_maximum_distance;
	int64_t new_size = p_new_size;
	int64_t is_maze = p_is_maze;
	RouteRef current_route = p_route;
	static const int64_t values[4] = { 1, 1, 2, 3 };
	int64_t number_to_continue = values[random.next_int(4)];
	number_to_continue = MIN(number_to_continue, (int64_t)p_previous_tiles.size());
	TileMap next_island_tiles;
	int64_t next = 0;
	if (p_type == "oasis1") {
		static const int64_t oasis_values[6] = { 3, 3, 4, 4, 5, 5 };
		number_to_continue = oasis_values[random.next_int(6)];
		number_to_continue = MIN(number_to_continue, (int64_t)p_previous_tiles.size());
		new_size += md / 10;
	} else if (p_type == "sand_pit1") {
		if (number_to_continue > 1) {
			number_to_continue = 1;
		}
		if (num_sand_pits >= 20) {
			new_size = 1;
		} else {
			num_sand_pits += 1;
		}
	} else if (p_type == "beach1") {
		new_size = md;
		is_maze -= 1;
		if (!p_previous_tiles.empty() && is_maze > 0) {
			TileRef recursive_origin = p_previous_tiles[next];
			put(p_tiles, recursive_origin->position, recursive_origin);
			apply_blotch("beach1", recursive_origin, new_size, next_island_tiles, is_maze, true, current_route);
		}
	}
	if ((p_type == "island" || p_type == "desert" || p_type == "oasis1" || p_type == "sand_pit1" || p_type == "wooded_lake1") && p_do_next) {
		for (int64_t index = 0; index < number_to_continue; index++) {
			if (p_previous_tiles.empty() || next >= (int64_t)p_previous_tiles.size()) {
				break;
			}
			TileRef recursive_origin = p_previous_tiles[next];
			if (done_desert == 1) {
				put(p_tiles, recursive_origin->position, recursive_origin);
				apply_blotch("desert", recursive_origin, new_size + md / 4, next_island_tiles, 1, true, route(NM("desert1"), 40));
				continue;
			}
			put(p_tiles, recursive_origin->position, recursive_origin);
			std::string new_type = p_type;
			if (p_type == "desert") {
				new_type = "island";
				current_route = route(NM("forest1"), 40);
			} else if (p_type != "wooded_lake1" && done_desert > 1 && new_type != "sand_pit1" && new_type != "oasis1" && random.next_int(5) == 0) {
				current_route = route(NM("wooded_lake1"), 40);
				new_type = "wooded_lake1";
				if (new_size < 400) {
					new_size = 400;
				}
			}
			apply_blotch(new_type.c_str(), recursive_origin, new_size, next_island_tiles, 1, true, current_route);
			// The source's compound assignment: next += rand.nextInt(size-next) + next.
			next += random.next_int((int64_t)p_previous_tiles.size() - next) + next;
			if (next >= (int64_t)p_previous_tiles.size()) {
				break;
			}
		}
	}
	if (p_previous_tiles.size() > 1 && (p_type == "island" || p_type == "wooded_lake1")) {
		TileRef beach_origin = p_previous_tiles[1];
		p_previous_tiles.erase(p_previous_tiles.begin() + 1);
		apply_blotch("beach1", beach_origin, 400, next_island_tiles, 6, false, route(NM("beach2"), 12));
	}
	for (Cell &cell : next_island_tiles.values()) {
		Tile *tile = cell.tile.get();
		if (!tile) {
			data.warnings++;
			continue;
		}
		Vector2i position = tile->position;
		if (p_tiles.has(position)) {
			Tile *existing = as_tile(p_tiles.getp(position));
			if (p_type == "beach1") {
				if (has(tile->name, "sand4") || tile->name == NM("mountain4")) {
					p_tiles.set(position, cell);
				}
				continue;
			}
			if (p_type == "sand_pit1") {
				if (tile->name == NM("desert2")) {
					p_tiles.set(position, cell);
				}
				continue;
			}
			if (has(tile->name, "desert")) {
				p_tiles.set(position, cell);
				continue;
			}
			if (!existing) {
				data.warnings++;
				continue;
			}
			if (has(existing->name, "desert")) {
				continue;
			}
			if (tile->route && tile->route->name == NM("wooded_lake1")) {
				p_tiles.set(position, cell);
				continue;
			}
			if (p_type == "wooded_lake1" || p_type != "island") {
				continue;
			}
			if ((existing->name == NM("sand1") || existing->name == NM("rock1") || existing->name == NM("tree5") || existing->name == NM("grass_sand1")) && tile->name != NM("sand1")) {
				p_tiles.set(position, cell);
			}
			if (tile->name == NM("tree_large1") && !p_forest_maze_tiles.has(position)) {
				p_tiles.set(position, cell);
				static const Vector2i offsets[3] = { Vector2i(16, 0), Vector2i(0, 16), Vector2i(16, 16) };
				for (const Vector2i &offset : offsets) {
					put(p_tiles, position + offset, make(NM("tree_large1_noSprite"), position + offset));
				}
			}
			if (tile->upper == NM("tree2") && !p_forest_maze_tiles.has(position)) {
				p_tiles.set(position, cell);
			}
		} else {
			p_tiles.set(position, cell);
		}
	}
}

} // namespace pw
