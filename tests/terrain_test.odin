package tests

import "core:testing"
import "melange:world"

generate :: proc(coord: [3]i32, seed: i64) -> ^world.Chunk {
	c := new(world.Chunk)
	world.generate_chunk(c, coord, seed)
	return c
}

@(test)
generation_is_deterministic :: proc(t: ^testing.T) {
	a := generate({3, 0, -7}, 42)
	defer free(a)
	b := generate({3, 0, -7}, 42)
	defer free(b)
	testing.expect(t, a.blocks == b.blocks, "same seed + coord must give identical blocks")
}

@(test)
different_seeds_differ :: proc(t: ^testing.T) {
	a := generate({0, 0, 0}, 1)
	defer free(a)
	b := generate({0, 0, 0}, 2)
	defer free(b)
	testing.expect(t, a.blocks != b.blocks)
}

// Every column, read across a vertical stack of chunks, must match the
// column's classification: bare stone (peak/cliff) or stone ... dirt x3,
// grass on top; water above terrain_height up to the sea level, air above. Checks that stacked chunks agree
// with each other and that generate_chunk's shared height grid agrees with
// the single-column terrain_column.
expect_columns_layered :: proc(t: ^testing.T, seed: i64, cx, cz: i32) {
	MIN_CY :: (world.TERRAIN_ALL_STONE_BELOW >> 4) - 1
	MAX_CY :: (world.TERRAIN_MAX_HEIGHT >> 4) + 1
	stack: [MAX_CY - MIN_CY + 1]^world.Chunk
	for &c, i in stack {
		c = generate({cx, i32(i) + MIN_CY, cz}, seed)
	}
	defer for c in stack {
		free(c)
	}

	origin := world.chunk_origin({cx, 0, cz})
	for z in i32(0) ..< world.CHUNK_SIZE {
		for x in i32(0) ..< world.CHUNK_SIZE {
			col := world.terrain_column(seed, origin.x + x, origin.z + z)
			h := col.height
			for wy in i32(MIN_CY * 16) ..< (MAX_CY + 1) * 16 {
				c := stack[(wy >> 4) - MIN_CY]
				got := world.chunk_get(c, x, wy & 15, z)
				want := world.STONE
				switch {
				case wy > h:
					want = world.WATER if wy <= world.TERRAIN_SEA_LEVEL else world.AIR
				case col.bare_stone:
					want = world.STONE
				case wy == h:
					want = world.GRASS
				case wy >= h - world.TERRAIN_DIRT_DEPTH:
					want = world.DIRT
				}
				if got != want {
					testing.fail_now(t, "column layering wrong")
				}
			}
		}
	}
}

@(test)
columns_are_layered_correctly_across_chunks :: proc(t: ^testing.T) {
	SEED :: 7
	// A plains chunk...
	expect_columns_layered(t, SEED, 1, -2)
	// ...an ocean chunk (water over the floor)...
	ocean := find_column(SEED, proc(h: i32) -> bool {return h < world.TERRAIN_SEA_LEVEL - 8})
	expect_columns_layered(t, SEED, ocean.x >> 4, ocean.y >> 4)
	// ...and a mountain chunk (search outward for one with a tall column).
	for r := i32(0); r < 400; r += 1 {
		x := r * 16
		if world.terrain_height(SEED, x, 0) > world.TERRAIN_STONE_LINE + 10 {
			expect_columns_layered(t, SEED, x >> 4, 0)
			return
		}
	}
	testing.fail_now(t, "no mountain found to test")
}

@(test)
column_classification :: proc(t: ^testing.T) {
	CLIFF :: i32(world.TERRAIN_CLIFF_STEP)
	// Flat, low: grass-covered.
	testing.expect(t, !world.column_from_heights(5, 5, 5, 5, 5).bare_stone)
	// Steps just under the cliff threshold: still covered.
	testing.expect(t, !world.column_from_heights(5, 5 + CLIFF - 1, 5 - (CLIFF - 1), 5, 5).bare_stone)
	// Cliff (threshold or more to a neighbor, up or down): bare stone.
	testing.expect(t, world.column_from_heights(5, 5, 5, 5 + CLIFF, 5).bare_stone)
	testing.expect(t, world.column_from_heights(5, 5 - CLIFF, 5, 5, 5).bare_stone)
	// At/above the stone line: bare stone even when flat.
	line := i32(world.TERRAIN_STONE_LINE)
	testing.expect(t, world.column_from_heights(line, line, line, line, line).bare_stone)
	testing.expect(t, !world.column_from_heights(line - 1, line - 1, line - 1, line - 1, line - 1).bare_stone)
}

// The rules should actually expose some stone, but not most of the surface.
@(test)
some_surface_is_bare_stone :: proc(t: ^testing.T) {
	bare, n := 0, 0
	for z := i32(-600); z < 600; z += 7 {
		for x := i32(-600); x < 600; x += 7 {
			if world.terrain_column(1337, x, z).bare_stone {
				bare += 1
			}
			n += 1
		}
	}
	pct := 100 * f64(bare) / f64(n)
	testing.expectf(t, pct > 1 && pct < 30, "bare stone on %.1f%% of columns", pct)
}

// Inland plains must be gentle (no step over 1 block away from mountains and
// the coast), coasts and the open sea mostly so, and nothing anywhere may
// spike absurdly (catches a scale mistake).
@(test)
terrain_is_smooth :: proc(t: ^testing.T) {
	max_plains, max_any := i32(0), i32(0)
	coast_n, coast_steep := 0, 0
	for z := i32(-1500); z < 1500; z += 11 {
		for x := i32(-1500); x < 1500; x += 3 {
			d := abs(world.terrain_height(99, x + 1, z) - world.terrain_height(99, x, z))
			max_any = max(max_any, d)
			inland := world.terrain_land_weight(99, x, z) == 1 && world.terrain_land_weight(99, x + 1, z) == 1
			if !inland {
				coast_n += 1
				if d > 1 {
					coast_steep += 1
				}
			} else if world.terrain_mountain_mask(99, x, z) == 0 && world.terrain_mountain_mask(99, x + 1, z) == 0 {
				max_plains = max(max_plains, d)
			}
		}
	}
	testing.expectf(t, max_plains <= 1, "plains step up to %d blocks", max_plains)
	testing.expectf(t, max_any <= 16, "terrain steps up to %d blocks", max_any)
	testing.expect(t, coast_n > 1000, "the sample has coast and sea")
	testing.expectf(t, f64(coast_steep) / f64(coast_n) < 0.03, "coast/sea steps over 1 block: %d of %d", coast_steep, coast_n)
}

// First column on a 64-block spiral-ish scan from the origin whose height
// matches `want`.
find_column :: proc(seed: i64, want: proc(h: i32) -> bool) -> [2]i32 {
	for r := i32(0); r < 400; r += 1 {
		for p in ([4][2]i32{{r, 0}, {-r, 0}, {0, r}, {0, -r}}) {
			c := p * 64
			if want(world.terrain_height(seed, c.x, c.y)) {
				return c
			}
		}
	}
	panic("no such column")
}

// About half the world is water (the continentalness threshold is tuned for
// it), measured over a 40,000-block square for a few seeds; oceans are
// 11-21 blocks deep.
@(test)
about_half_the_world_is_ocean :: proc(t: ^testing.T) {
	total := 0.0
	for seed in ([]i64{1337, 7, 42}) {
		n, water := 0, 0
		for z := i32(-20000); z < 20000; z += 160 {
			for x := i32(-20000); x < 20000; x += 160 {
				h := world.terrain_height(seed, x, z)
				n += 1
				if h < world.TERRAIN_SEA_LEVEL {
					water += 1
				}
			}
		}
		pct := 100 * f64(water) / f64(n)
		testing.expectf(t, pct > 35 && pct < 65, "seed %d: %.1f%% water", seed, pct)
		total += pct
	}
	testing.expectf(t, total / 3 > 42 && total / 3 < 58, "mean water %.1f%%", total / 3)
	testing.expect_value(t, world.TERRAIN_SEA_LEVEL, 0)
	testing.expect_value(t, world.TERRAIN_MIN_HEIGHT, -21)
}

// Water fills exactly the cells between an ocean floor and the sea level;
// nothing above the sea is water, and chunks above both the sea and the
// column's surface are skipped as air.
@(test)
ocean_chunks_hold_water :: proc(t: ^testing.T) {
	SEED :: 1337
	ocean := find_column(SEED, proc(h: i32) -> bool {return h < -10})
	cx, cz := ocean.x >> 4, ocean.y >> 4
	ch := new(world.Column_Heights)
	defer free(ch)
	world.column_heights_compute(ch, SEED, cx, cz)
	testing.expect(t, ch.max_height < world.TERRAIN_SEA_LEVEL, "the whole 16x16 is underwater")
	water := 0
	for cy in i32(-2) ..= 1 {
		c := new(world.Chunk)
		defer free(c)
		world.generate_chunk_from_heights(c, {cx, cy, cz}, ch)
		for y in i32(0) ..< 16 {
			wy := cy * 16 + y
			for z in i32(0) ..< 16 {
				for x in i32(0) ..< 16 {
					h := ch.columns[z][x].height
					got := world.chunk_get(c, x, y, z)
					if wy > h && wy <= world.TERRAIN_SEA_LEVEL {
						if got != world.WATER {
							testing.fail_now(t, "missing water between the floor and the sea level")
						}
						water += 1
					} else if got == world.WATER {
						testing.fail_now(t, "water outside the sea")
					}
				}
			}
		}
		if cy == 1 {
			// Bottom at Y 16: above the sea and this column's surface.
			for b in c.blocks {
				testing.expect(t, b == world.AIR, "chunk above the sea isn't empty")
			}
		}
	}
	testing.expect(t, water > 16 * 16 * 10, "a deep ocean column holds water")
}

// New players spawn on land: the origin itself if it's land, otherwise the
// nearest land found by the ring search.
@(test)
spawn_search_finds_land :: proc(t: ^testing.T) {
	for seed in ([]i64{1337, 7, 42, 99, 5}) {
		land, ok := world.find_land(seed, 0, 0)
		testing.expectf(t, ok, "seed %d: land found", seed)
		testing.expectf(t, world.terrain_height(seed, land.x, land.y) > world.TERRAIN_SEA_LEVEL, "seed %d: spawn %v is above the sea", seed, land)
	}
	// Starting on land returns that column.
	l := find_column(1337, proc(h: i32) -> bool {return h > 3})
	got, _ := world.find_land(1337, l.x, l.y)
	testing.expect_value(t, got, l)
	// Starting deep in an ocean finds land that isn't absurdly far.
	o := find_column(1337, proc(h: i32) -> bool {return h < -12})
	got2, ok2 := world.find_land(1337, o.x, o.y)
	testing.expect(t, ok2)
	testing.expect(t, world.terrain_height(1337, got2.x, got2.y) > world.TERRAIN_SEA_LEVEL)
	d := got2 - o
	testing.expectf(t, max(abs(d.x), abs(d.y)) <= world.SPAWN_SEARCH_RADIUS, "land at %v from %v", got2, o)
}

// Mostly plains, with occasional mountains that reach well above them.
@(test)
terrain_is_mostly_plains_with_mountains :: proc(t: ^testing.T) {
	n, mountain := 0, 0
	lo, hi := i32(max(i32)), i32(min(i32))
	for z := i32(-3000); z < 3000; z += 41 {
		for x := i32(-3000); x < 3000; x += 41 {
			if world.terrain_mountain_mask(5, x, z) > 0 {
				mountain += 1
			}
			h := world.terrain_height(5, x, z)
			lo, hi = min(lo, h), max(hi, h)
			n += 1
		}
	}
	pct := 100 * f64(mountain) / f64(n)
	testing.expectf(t, pct > 10 && pct < 50, "mountain regions cover %.1f%% (want occasional)", pct)
	testing.expectf(t, lo >= world.TERRAIN_MIN_HEIGHT && hi <= world.TERRAIN_MAX_HEIGHT, "heights %d..%d out of bounds", lo, hi)
	testing.expectf(t, hi > world.TERRAIN_BASE_HEIGHT + 50, "tallest peak only %d", hi)
}

// Chunks entirely above/below the terrain's height bounds take shortcuts
// (no noise sampled); check they still produce the right blocks.
@(test)
generation_fast_paths :: proc(t: ^testing.T) {
	sky_y := i32(world.TERRAIN_MAX_HEIGHT / 16 + 1)
	deep_y := i32(world.TERRAIN_ALL_STONE_BELOW / 16 - 2)

	sky := generate({4, sky_y, 4}, 3)
	defer free(sky)
	for b in sky.blocks {
		if b != world.AIR {
			testing.fail_now(t, "sky chunk has non-air")
		}
	}
	deep := generate({4, deep_y, 4}, 3)
	defer free(deep)
	for b in deep.blocks {
		if b != world.STONE {
			testing.fail_now(t, "deep chunk has non-stone")
		}
	}
}

// Generating from a precomputed Column_Heights must give exactly the same
// blocks as computing heights per chunk, for every chunk in a column stack
// (deep stone, surface, sky below/above the global max), in plains and
// mountains.
@(test)
cached_heights_match_direct_generation :: proc(t: ^testing.T) {
	SEED :: 11
	MIN_CY :: (world.TERRAIN_ALL_STONE_BELOW >> 4) - 1
	MAX_CY :: (world.TERRAIN_MAX_HEIGHT >> 4) + 1
	// A plains column, the first mountain column found and an ocean column.
	ocean := find_column(SEED, proc(h: i32) -> bool {return h < -8})
	cols := [3][2]i32{{3, -5}, {0, 0}, {ocean.x >> 4, ocean.y >> 4}}
	for r := i32(0); r < 400; r += 1 {
		if world.terrain_height(SEED, r * 16, 0) > world.TERRAIN_STONE_LINE + 10 {
			cols[1] = {r, 0}
			break
		}
	}
	for col in cols {
		ch := new(world.Column_Heights)
		defer free(ch)
		world.column_heights_compute(ch, SEED, col.x, col.y)
		for cy in i32(MIN_CY) ..= MAX_CY {
			a := generate({col.x, cy, col.y}, SEED)
			defer free(a)
			b := new(world.Chunk)
			defer free(b)
			world.generate_chunk_from_heights(b, {col.x, cy, col.y}, ch)
			testing.expectf(t, a.blocks == b.blocks, "column %v chunk y %d differs", col, cy)
		}
	}
}

// max_height is the true maximum of the 16x16, and a chunk whose bottom is
// above it comes out all air (the fast path that skips sky chunks).
@(test)
column_max_height_and_sky_skip :: proc(t: ^testing.T) {
	SEED :: 3
	ch := new(world.Column_Heights)
	defer free(ch)
	world.column_heights_compute(ch, SEED, -4, 9)
	want := i32(min(i32))
	for z in i32(0) ..< 16 {
		for x in i32(0) ..< 16 {
			want = max(want, world.terrain_height(SEED, -4 * 16 + x, 9 * 16 + z))
		}
	}
	testing.expect_value(t, ch.max_height, want)

	above := (ch.max_height >> 4) + 1
	c := new(world.Chunk)
	defer free(c)
	world.generate_chunk_from_heights(c, {-4, above, 9}, ch)
	for b in c.blocks {
		if b != world.AIR {
			testing.fail_now(t, "chunk above the column's max height isn't empty")
		}
	}
}
