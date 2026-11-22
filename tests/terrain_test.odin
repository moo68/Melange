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
// grass on top; air above terrain_height. Checks that stacked chunks agree
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
					want = world.AIR
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

// Plains must be gentle (no step over 1 block where there are no mountains),
// and nothing anywhere may spike absurdly (catches a scale mistake).
@(test)
terrain_is_smooth :: proc(t: ^testing.T) {
	max_plains, max_any := i32(0), i32(0)
	for z := i32(-1500); z < 1500; z += 11 {
		for x := i32(-1500); x < 1500; x += 3 {
			d := abs(world.terrain_height(99, x + 1, z) - world.terrain_height(99, x, z))
			max_any = max(max_any, d)
			if world.terrain_mountain_mask(99, x, z) == 0 && world.terrain_mountain_mask(99, x + 1, z) == 0 {
				max_plains = max(max_plains, d)
			}
		}
	}
	testing.expectf(t, max_plains <= 1, "plains step up to %d blocks", max_plains)
	testing.expectf(t, max_any <= 16, "terrain steps up to %d blocks", max_any)
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
	// A plains column and the first mountain column found.
	cols := [2][2]i32{{3, -5}, {0, 0}}
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
