package tests

import "core:math"
import "core:testing"
import "melange:world"

// Small config so tests are fast; huge budgets so one update finishes the job.
SMALL :: world.Stream_Config {
	radius        = 3,
	vertical      = 1,
	unload_margin = 2,
	load_budget   = 100_000,
	unload_budget = 100_000,
}

// Number of chunks in the load shape for `cfg`.
shape_count :: proc(cfg: world.Stream_Config) -> int {
	n := 0
	for dz in -cfg.radius ..= cfg.radius {
		for dx in -cfg.radius ..= cfg.radius {
			if dx * dx + dz * dz <= cfg.radius * cfg.radius {
				n += 1
			}
		}
	}
	return n * int(2 * cfg.vertical + 1)
}

expect_exactly_shape_loaded :: proc(t: ^testing.T, w: ^world.World, cfg: world.Stream_Config, center: [3]i32) {
	testing.expect_value(t, world.world_loaded_chunk_count(w), shape_count(cfg))
	loaded: [dynamic][3]i32
	defer delete(loaded)
	world.world_collect_loaded(w, &loaded)
	for c in loaded {
		if !world.in_stream_range(cfg, center, c) {
			testing.fail_now(t, "chunk loaded outside the load range")
		}
	}
}

@(test)
initial_update_loads_the_shape :: proc(t: ^testing.T) {
	w: world.World
	world.world_init(&w, 1)
	defer world.world_destroy(&w)
	s: world.Streamer
	world.streamer_init(&s, SMALL)
	defer world.streamer_destroy(&s)

	center := [3]i32{-5, 0, 9}
	testing.expect_value(t, world.streamer_update(&s, &w, center), nil)
	expect_exactly_shape_loaded(t, &w, SMALL, center)
	testing.expect_value(t, s.stats.load_scan_left, 0)
}

@(test)
load_budget_is_respected_nearest_first :: proc(t: ^testing.T) {
	w: world.World
	world.world_init(&w, 1)
	defer world.world_destroy(&w)
	cfg := SMALL
	cfg.load_budget = 7
	s: world.Streamer
	world.streamer_init(&s, cfg)
	defer world.streamer_destroy(&s)

	world.streamer_update(&s, &w, {0, 0, 0})
	testing.expect_value(t, world.world_loaded_chunk_count(&w), 7)
	// Nearest first: the center and its 6 face neighbors (distance 0 and 1).
	testing.expect(t, world.world_get_chunk(&w, {0, 0, 0}) != nil)
	center_neighbors := world.world_get_neighbors(&w, {0, 0, 0})
	testing.expect(t, world.neighbors_complete(&center_neighbors))

	// Further updates keep going until the shape is complete.
	for _ in 0 ..< 100 {
		world.streamer_update(&s, &w, {0, 0, 0})
	}
	expect_exactly_shape_loaded(t, &w, cfg, {0, 0, 0})
}

@(test)
moving_far_unloads_everything_old :: proc(t: ^testing.T) {
	w: world.World
	world.world_init(&w, 1)
	defer world.world_destroy(&w)
	s: world.Streamer
	world.streamer_init(&s, SMALL)
	defer world.streamer_destroy(&s)

	world.streamer_update(&s, &w, {0, 0, 0})
	world.streamer_update(&s, &w, {100, 0, 0})
	testing.expect_value(t, len(s.unloaded), shape_count(SMALL))
	expect_exactly_shape_loaded(t, &w, SMALL, {100, 0, 0})
	// All old regions were released.
	for key in w.regions {
		testing.expect(t, key.x >= 11, "a region near the old center is still alive")
	}
}

// Moving one chunk and back must not unload anything: chunks that left the
// load range are still within the unload margin.
@(test)
small_moves_dont_thrash :: proc(t: ^testing.T) {
	w: world.World
	world.world_init(&w, 1)
	defer world.world_destroy(&w)
	s: world.Streamer
	world.streamer_init(&s, SMALL)
	defer world.streamer_destroy(&s)

	world.streamer_update(&s, &w, {0, 0, 0})
	for i in 0 ..< 10 {
		center := [3]i32{1, 0, 0} if i % 2 == 0 else [3]i32{0, 0, 0}
		world.streamer_update(&s, &w, center)
		testing.expect_value(t, len(s.unloaded), 0)
	}
	// Vertical wobble too.
	world.streamer_update(&s, &w, {0, 1, 0})
	world.streamer_update(&s, &w, {0, 0, 0})
	testing.expect_value(t, len(s.unloaded), 0)
}

@(test)
unload_budget_is_respected :: proc(t: ^testing.T) {
	w: world.World
	world.world_init(&w, 1)
	defer world.world_destroy(&w)
	cfg := SMALL
	cfg.unload_budget = 5
	s: world.Streamer
	world.streamer_init(&s, cfg)
	defer world.streamer_destroy(&s)

	world.streamer_update(&s, &w, {0, 0, 0})
	world.streamer_update(&s, &w, {100, 0, 0})
	testing.expect_value(t, len(s.unloaded), 5)
	testing.expect_value(t, s.stats.pending_unloads, shape_count(cfg) - 5)
}

@(test)
neighbors_complete_requires_all_six :: proc(t: ^testing.T) {
	c := new(world.Chunk)
	defer free(c)
	n: world.Neighbors
	for face in world.Face {
		n[face] = c
	}
	testing.expect(t, world.neighbors_complete(&n))
	n[.Neg_Y] = nil
	testing.expect(t, !world.neighbors_complete(&n))
}

// Every block within stream_meshed_distance of the camera (horizontally, and
// within the vertical range minus one chunk) must be in a chunk that is
// meshable: within radius - 1 of the camera's chunk. Brute force over many
// camera positions inside a chunk and directions.
@(test)
meshed_distance_is_conservative :: proc(t: ^testing.T) {
	cfg := world.DEFAULT_STREAM_CONFIG
	inner := cfg
	inner.radius -= 1
	inner.vertical -= 1
	d := world.stream_meshed_distance(cfg)
	testing.expect(t, d > 0)

	for cam_x := f32(0); cam_x < 16; cam_x += 1.7 {
		for cam_z := f32(0); cam_z < 16; cam_z += 1.3 {
			cam := [3]f32{cam_x, 8, cam_z}
			cam_chunk := world.block_to_chunk({i32(cam_x), 8, i32(cam_z)})
			for step in 0 ..< 720 {
				angle := f32(step) * (2 * math.PI / 720)
				for r := f32(0); r <= d; r += 3 {
					px := cam.x + r * math.cos(angle)
					pz := cam.z + r * math.sin(angle)
					b := [3]i32{i32(math.floor(px)), 8, i32(math.floor(pz))}
					if !world.in_stream_range(inner, cam_chunk, world.block_to_chunk(b)) {
						testing.fail_now(t, "a block within the meshed distance is in an unmeshable chunk")
					}
				}
			}
		}
	}
}

// One cache entry per chunk column touched, evicted when the camera moves
// far away; memory is freed (the test allocator reports leaks).
@(test)
height_cache_fills_and_evicts :: proc(t: ^testing.T) {
	w: world.World
	world.world_init(&w, 1)
	defer world.world_destroy(&w)
	s: world.Streamer
	world.streamer_init(&s, SMALL)
	defer world.streamer_destroy(&s)

	world.streamer_update(&s, &w, {0, 0, 0})
	columns := shape_count(SMALL) / int(2 * SMALL.vertical + 1)
	testing.expect_value(t, len(s.heights), columns)
	for key in s.heights {
		testing.expect(t, key.x * key.x + key.y * key.y <= SMALL.radius * SMALL.radius)
	}

	world.streamer_update(&s, &w, {100, 0, 0})
	testing.expect_value(t, len(s.heights), columns)
	for key in s.heights {
		testing.expect(t, key.x >= 100 - SMALL.radius, "stale height column kept after moving away")
	}
}

@(test)
load_order_covers_the_shape_nearest_first :: proc(t: ^testing.T) {
	cfg := world.DEFAULT_STREAM_CONFIG
	order: [dynamic][3]i32
	defer delete(order)
	world.build_load_order(&order, cfg)
	testing.expect_value(t, len(order), shape_count(cfg))
	seen := make(map[[3]i32]bool)
	defer delete(seen)
	prev := i32(-1)
	for o in order {
		testing.expect(t, world.in_stream_range(cfg, {0, 0, 0}, o), "offset inside the shape")
		testing.expect(t, !seen[o], "no duplicates")
		seen[o] = true
		d := o.x * o.x + o.y * o.y + o.z * o.z
		testing.expect(t, d >= prev, "nearest first")
		prev = d
	}
	testing.expect_value(t, order[0], [3]i32{0, 0, 0})
}

@(test)
scan_budget_limits_lookups_per_update :: proc(t: ^testing.T) {
	w: world.World
	world.world_init(&w, 1)
	defer world.world_destroy(&w)
	cfg := SMALL
	cfg.scan_budget = 10
	s: world.Streamer
	world.streamer_init(&s, cfg)
	defer world.streamer_destroy(&s)

	// Empty world: every position checked is missing, so 10 load per update.
	world.streamer_update(&s, &w, {0, 0, 0})
	testing.expect_value(t, s.stats.loaded, 10)
	testing.expect_value(t, s.stats.load_scan_left, shape_count(cfg) - 10)
	for _ in 0 ..< 100 {
		world.streamer_update(&s, &w, {0, 0, 0})
	}
	expect_exactly_shape_loaded(t, &w, cfg, {0, 0, 0})

	// After a 1-chunk move, the new slice is at the far end of the order:
	// skipping the loaded chunks also counts against the budget, so the
	// first updates find nothing (the old code scanned it all at once).
	world.streamer_update(&s, &w, {1, 0, 0})
	testing.expect_value(t, s.stats.loaded, 0)
	testing.expect_value(t, s.stats.load_scan_left, shape_count(cfg) - 10)
	for _ in 0 ..< 100 {
		world.streamer_update(&s, &w, {1, 0, 0})
	}
	testing.expect_value(t, s.stats.load_scan_left, 0)
}

@(test)
loading_stays_nearest_first_while_moving :: proc(t: ^testing.T) {
	// One chunk per update while the center wanders: every chunk loaded is
	// one of the nearest missing chunks in range of the current center
	// (checked by brute force), and nothing loads outside the range.
	w: world.World
	world.world_init(&w, 1)
	defer world.world_destroy(&w)
	cfg := SMALL
	cfg.load_budget = 1
	s: world.Streamer
	world.streamer_init(&s, cfg)
	defer world.streamer_destroy(&s)

	before := make(map[[3]i32]bool)
	defer delete(before)
	loaded: [dynamic][3]i32
	defer delete(loaded)
	path := [?][3]i32{{0, 0, 0}, {1, 0, 0}, {1, 0, 1}, {1, 1, 1}, {0, 1, 1}, {-3, 1, 1}, {-3, 0, 1}, {9, 0, 1}}
	loads := 0
	for center in path {
		for _ in 0 ..< 40 {
			clear(&before)
			clear(&loaded)
			world.world_collect_loaded(&w, &loaded)
			for c in loaded {
				before[c] = true
			}
			// Nearest missing distance around this center, by brute force.
			best := max(i32)
			r, v := cfg.radius, cfg.vertical
			for dy in -v ..= v {
				for dz in -r ..= r {
					for dx in -r ..= r {
						c := center + {dx, dy, dz}
						if world.in_stream_range(cfg, center, c) && !before[c] {
							best = min(best, dx * dx + dy * dy + dz * dz)
						}
					}
				}
			}

			world.streamer_update(&s, &w, center)
			if s.stats.loaded == 0 {
				testing.expect_value(t, best, max(i32)) // nothing missing
				continue
			}
			loads += 1
			clear(&loaded)
			world.world_collect_loaded(&w, &loaded)
			for c in loaded {
				if !before[c] {
					d := c - center
					testing.expect(t, world.in_stream_range(cfg, center, c), "loaded inside the range")
					testing.expectf(t, d.x * d.x + d.y * d.y + d.z * d.z == best, "loaded %v at dist² %d, nearest missing %d", c, d.x * d.x + d.y * d.y + d.z * d.z, best)
				}
			}
		}
	}
	testing.expectf(t, loads > 100, "exercised: %d loads", loads)
}
