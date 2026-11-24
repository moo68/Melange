package world

import "core:math"
import "core:math/noise"

// Heightmap terrain from 2D OpenSimplex2 noise:
//
//   land   = BASE + plains + mask * mountains
//   height = lerp(ocean_floor, land, land_weight)
//
//   continentalness: very low-frequency noise splitting the world into land
//              and ocean (~50/50); land_weight is a smoothstep across the
//              coastal band, so the land slopes down into the sea.
//   ocean_floor: SEA_LEVEL - OCEAN_DEPTH, varied by gentle noise.
//   plains:    low, gently rolling fBm with a little small-scale detail.
//   mask:      very low-frequency noise pushed through a smoothstep, so it's
//              0 (plains) over most of the world and ramps to 1 inside
//              occasional mountain regions (the ramp gives foothills).
//   mountains: broad fBm "massif" shape raised to a power (flat bases,
//              sharp peaks), roughened by ridged fBm (1 - |noise|) so the
//              crests are craggy. Ridges alone form a maze of thin walls.
//
// No caves/overhangs (that needs 3D noise). Every layer uses its own seed
// offset so layers don't line up. Constants are the tuning knobs.

TERRAIN_BASE_HEIGHT :: 8 // plains surface Y on average

// Oceans. Water fills every column up to the sea level (blocks above the
// surface at Y <= SEA_LEVEL). Land heights are unchanged by this (plains
// never dip below Y 1), so water only forms where the continentalness lowers
// the land: oceans and coastal lagoons.
TERRAIN_SEA_LEVEL        :: 0
TERRAIN_CONT_SCALE       :: 2000.0 // blocks per cycle: oceans/continents ~1000+ blocks across
TERRAIN_CONT_OCTAVES     :: 3
TERRAIN_COAST_CENTER     :: 0.0  // continentalness where land and ocean meet (tuned for ~50% water)
TERRAIN_COAST_WIDTH      :: 0.06 // half-width of the coastal band (land_weight 0..1 across it)
TERRAIN_OCEAN_DEPTH      :: 16   // ocean floor below sea level on average
TERRAIN_FLOOR_SCALE      :: 150.0
TERRAIN_FLOOR_OCTAVES    :: 3
TERRAIN_FLOOR_VARIATION  :: 5    // ocean floor varies within about +/- this

// Plains
TERRAIN_PLAINS_SCALE     :: 220.0 // blocks per cycle of the broadest octave
TERRAIN_PLAINS_OCTAVES   :: 5
TERRAIN_PLAINS_AMPLITUDE :: 7     // plains vary within about +/- this

// Mountain mask
TERRAIN_MASK_SCALE :: 900.0 // size of mountain regions
TERRAIN_MASK_LOW   :: 0.25  // mask noise below this: pure plains
TERRAIN_MASK_HIGH  :: 0.50  // above this: full mountains (between: foothills)

// Mountains
TERRAIN_MASSIF_SCALE       :: 200.0 // size of individual mountains
TERRAIN_MASSIF_OCTAVES     :: 4
// fBm rarely nears +/-1, so stretch the range it actually uses to 0..1:
// below LOW = mountain valley floor (0), above HIGH = summit (1).
TERRAIN_MASSIF_LOW         :: -0.15
TERRAIN_MASSIF_HIGH        :: 0.55
TERRAIN_MASSIF_SHARPNESS   :: 1.7   // power on the stretched shape: higher = pointier peaks
TERRAIN_RIDGE_SCALE        :: 90.0
TERRAIN_RIDGE_OCTAVES      :: 3
TERRAIN_RIDGE_STRENGTH     :: 0.45  // 0 = smooth massifs, 1 = ridges dominate
TERRAIN_MOUNTAIN_AMPLITUDE :: 95    // peak height above the plains

TERRAIN_DIRT_DEPTH :: 3 // dirt layers under the grass (sand columns: sand layers under the top)
// Sand: every non-cliff column under the sea, plus beaches and shores up to
// this many blocks above the sea level inside the coastal band (land_weight
// < 1, so low inland plains stay grass).
TERRAIN_BEACH_HEIGHT :: 2
// Rules for exposing stone at the surface (no grass/dirt):
TERRAIN_STONE_LINE :: 34 // columns at or above this height are bare stone
TERRAIN_CLIFF_STEP :: 3  // ...and so are columns this many blocks above/below a neighbor

// Hard bounds on terrain_height (it clamps to these). Generation relies on
// them to skip whole chunks without sampling any noise. The lowest point is
// the deepest ocean floor (land is a blend toward it, never below it).
TERRAIN_MIN_HEIGHT :: TERRAIN_SEA_LEVEL - TERRAIN_OCEAN_DEPTH - TERRAIN_FLOOR_VARIATION
TERRAIN_MAX_HEIGHT :: TERRAIN_BASE_HEIGHT + TERRAIN_PLAINS_AMPLITUDE + TERRAIN_MOUNTAIN_AMPLITUDE
// Below this Y every block is stone, whatever the column height.
TERRAIN_ALL_STONE_BELOW :: TERRAIN_MIN_HEIGHT - TERRAIN_DIRT_DEPTH

// Seed offsets per layer (octaves add their index on top).
@(private)
SEED_PLAINS :: 0
@(private)
SEED_MASK :: 100
@(private)
SEED_MASSIF :: 200
@(private)
SEED_RIDGES :: 300
@(private)
SEED_CONT :: 400
@(private)
SEED_FLOOR :: 500

// fBm: sum of `octaves` noise layers, each double the frequency and half the
// amplitude of the last, normalized to about [-1, 1].
@(private)
fbm :: proc(seed: i64, p: noise.Vec2, octaves: int) -> f32 {
	p := p
	sum, amplitude, total := f32(0), f32(1), f32(0)
	for octave in 0 ..< octaves {
		sum += amplitude * noise.noise_2d(seed + i64(octave), p)
		total += amplitude
		amplitude *= 0.5
		p *= 2
	}
	return sum / total
}

// Ridged fBm in [0, 1]: each octave is (1 - |noise|)², which turns the zero
// crossings of the noise into sharp crests. Higher octaves are weighted by
// the previous octave so detail concentrates on the ridges, not the valleys.
@(private)
ridged :: proc(seed: i64, p: noise.Vec2, octaves: int) -> f32 {
	p := p
	sum, amplitude, total, weight := f32(0), f32(1), f32(0), f32(1)
	for octave in 0 ..< octaves {
		r := 1 - abs(noise.noise_2d(seed + i64(octave), p))
		r *= r
		r *= weight
		weight = clamp(r * 2, 0, 1)
		sum += amplitude * r
		total += amplitude
		amplitude *= 0.5
		p *= 2
	}
	return sum / total
}

// Continentalness at a column: ~[-1, 1], ocean below TERRAIN_COAST_CENTER.
terrain_continentalness :: proc(seed: i64, x, z: i32) -> f32 {
	p := noise.Vec2{f64(x), f64(z)} / TERRAIN_CONT_SCALE
	return fbm(seed + SEED_CONT, p, TERRAIN_CONT_OCTAVES)
}

// 0 in open ocean, 1 inland, smooth across the coastal band.
terrain_land_weight :: proc(seed: i64, x, z: i32) -> f32 {
	c := terrain_continentalness(seed, x, z)
	return math.smoothstep(f32(TERRAIN_COAST_CENTER - TERRAIN_COAST_WIDTH), f32(TERRAIN_COAST_CENTER + TERRAIN_COAST_WIDTH), c)
}

// 0 over plains, 1 inside mountain regions, smooth in between.
terrain_mountain_mask :: proc(seed: i64, x, z: i32) -> f32 {
	p := noise.Vec2{f64(x), f64(z)} / TERRAIN_MASK_SCALE
	n := fbm(seed + SEED_MASK, p, 2)
	return math.smoothstep(f32(TERRAIN_MASK_LOW), f32(TERRAIN_MASK_HIGH), n)
}

// Surface height (world block Y of the top solid block) of a column.
// Pure: depends only on seed and column, so it's the same no matter which
// chunk asks, and safe on any thread.
terrain_height :: proc(seed: i64, x, z: i32) -> i32 {
	h, _ := terrain_sample(seed, x, z)
	return h
}

// terrain_height plus the column's land weight (computed anyway), so the
// surface classification needn't sample the continentalness again.
terrain_sample :: proc(seed: i64, x, z: i32) -> (height: i32, land_weight: f32) {
	pos := noise.Vec2{f64(x), f64(z)}
	land_weight = terrain_land_weight(seed, x, z)
	// Each side is only sampled where it contributes.
	floor := f32(0)
	if land_weight < 1 {
		variation := fbm(seed + SEED_FLOOR, pos / TERRAIN_FLOOR_SCALE, TERRAIN_FLOOR_OCTAVES) * TERRAIN_FLOOR_VARIATION
		floor = f32(TERRAIN_SEA_LEVEL - TERRAIN_OCEAN_DEPTH) + variation
	}
	h := floor
	if land_weight > 0 {
		h = math.lerp(floor, terrain_land_height(seed, pos), land_weight)
	}
	// Noise is only approximately in range; clamp so the bounds above are exact.
	return clamp(i32(math.floor(h)), TERRAIN_MIN_HEIGHT, TERRAIN_MAX_HEIGHT), land_weight
}

// The land surface before blending toward the ocean floor (plains + mountains).
@(private)
terrain_land_height :: proc(seed: i64, pos: noise.Vec2) -> f32 {
	x, z := i32(pos.x), i32(pos.y)
	plains := fbm(seed + SEED_PLAINS, pos / TERRAIN_PLAINS_SCALE, TERRAIN_PLAINS_OCTAVES) * TERRAIN_PLAINS_AMPLITUDE

	h := f32(TERRAIN_BASE_HEIGHT) + plains
	mask := terrain_mountain_mask(seed, x, z)
	if mask > 0 {
		// Only sampled where it matters: most columns are plains.
		shape := fbm(seed + SEED_MASSIF, pos / TERRAIN_MASSIF_SCALE, TERRAIN_MASSIF_OCTAVES)
		shape = clamp((shape - TERRAIN_MASSIF_LOW) / (TERRAIN_MASSIF_HIGH - TERRAIN_MASSIF_LOW), 0, 1)
		shape = math.pow(shape, TERRAIN_MASSIF_SHARPNESS)
		r := ridged(seed + SEED_RIDGES, pos / TERRAIN_RIDGE_SCALE, TERRAIN_RIDGE_OCTAVES)
		m := shape * (1 - TERRAIN_RIDGE_STRENGTH + TERRAIN_RIDGE_STRENGTH * r)
		h += mask * m * TERRAIN_MOUNTAIN_AMPLITUDE
	}
	return h
}

// What a column looks like at the surface.
Column :: struct {
	height:     i32,  // Y of the top solid block
	bare_stone: bool, // no cover: peak above the stone line, or a cliff (also underwater)
	sand:       bool, // sand instead of grass/dirt: seabed, beach or shore (never with bare_stone)
}

// Classify a column from its height, its 4 horizontal neighbors' heights and
// whether it's in the coastal band / ocean (`coastal` = land_weight < 1).
column_from_heights :: proc "contextless" (h, east, west, south, north: i32, coastal: bool) -> Column {
	step := max(abs(east - h), abs(west - h), abs(south - h), abs(north - h))
	bare := h >= TERRAIN_STONE_LINE || step >= TERRAIN_CLIFF_STEP
	return {h, bare, !bare && coastal && h <= TERRAIN_SEA_LEVEL + TERRAIN_BEACH_HEIGHT}
}

// Single-column version (samples 5 heights). generate_chunk uses a shared
// height grid instead, but must agree with this exactly.
terrain_column :: proc(seed: i64, x, z: i32) -> Column {
	h, land_weight := terrain_sample(seed, x, z)
	return column_from_heights(
		h,
		terrain_height(seed, x + 1, z),
		terrain_height(seed, x - 1, z),
		terrain_height(seed, x, z + 1),
		terrain_height(seed, x, z - 1),
		land_weight < 1,
	)
}

// Block at height `wy` in a column: water fills above the surface up to
// the sea level.
column_block :: proc "contextless" (col: Column, wy: i32) -> Block_ID {
	switch {
	case wy > col.height:
		return WATER if wy <= TERRAIN_SEA_LEVEL else AIR
	case col.bare_stone:
		return STONE
	case col.sand:
		return SAND if wy >= col.height - TERRAIN_DIRT_DEPTH else STONE
	case wy == col.height:
		return GRASS
	case wy >= col.height - TERRAIN_DIRT_DEPTH:
		return DIRT
	}
	return STONE
}

// The surface of one column of chunks (all chunks sharing cx, cz): heights on
// an 18x18 grid (the 16x16 columns plus a 1-column border, needed to judge
// steepness at the edges), each column classified, and the max height.
// Computed once per chunk column and shared by every chunk stacked in it,
// so noise is sampled once per column instead of once per chunk.
Column_Heights :: struct {
	columns:    [CHUNK_SIZE][CHUNK_SIZE]Column, // [z][x], local to the chunk column
	max_height: i32, // highest surface in the 16x16 (not the border)
}

// Pure function of seed + chunk column (cx, cz).
column_heights_compute :: proc(out: ^Column_Heights, seed: i64, cx, cz: i32) {
	P :: CHUNK_SIZE + 2
	ox, oz := cx * CHUNK_SIZE, cz * CHUNK_SIZE
	heights: [P][P]i32 // [z+1][x+1]
	coastal: [CHUNK_SIZE][CHUNK_SIZE]bool // [z][x], the 16x16 only
	for z in i32(-1) ..= CHUNK_SIZE {
		for x in i32(-1) ..= CHUNK_SIZE {
			h, land_weight := terrain_sample(seed, ox + x, oz + z)
			heights[z + 1][x + 1] = h
			if x >= 0 && x < CHUNK_SIZE && z >= 0 && z < CHUNK_SIZE {
				coastal[z][x] = land_weight < 1
			}
		}
	}
	out.max_height = min(i32)
	for z in 1 ..= CHUNK_SIZE {
		for x in 1 ..= CHUNK_SIZE {
			col := column_from_heights(
				heights[z][x],
				heights[z][x + 1],
				heights[z][x - 1],
				heights[z + 1][x],
				heights[z - 1][x],
				coastal[z - 1][x - 1],
			)
			out.columns[z - 1][x - 1] = col
			out.max_height = max(out.max_height, col.height)
		}
	}
}

// Fills one freshly created (all-air) chunk from its column's precomputed
// heights (must be for the same seed and coord.xz). Pure. Air is never
// written, so sky costs no RAM.
generate_chunk_from_heights :: proc(c: ^Chunk, coord: [3]i32, ch: ^Column_Heights) {
	bottom := coord.y * CHUNK_SIZE
	top := bottom + CHUNK_SIZE - 1

	// Fast paths, no per-block work:
	if bottom > max(ch.max_height, TERRAIN_SEA_LEVEL) {
		return // entirely above this column's surface and the sea: leave it as zeroed air
	}
	if top < TERRAIN_ALL_STONE_BELOW {
		for &b in c.blocks {
			b = STONE
		}
		return
	}
	// Fill in memory order (y outer, x inner).
	for y in i32(0) ..< CHUNK_SIZE {
		wy := bottom + y
		for z in i32(0) ..< CHUNK_SIZE {
			for x in i32(0) ..< CHUNK_SIZE {
				id := column_block(ch.columns[z][x], wy)
				if id != AIR {
					chunk_set(c, x, y, z, id) // air is never written
				}
			}
		}
	}
}

// Convenience without a cache: computes the column's heights itself (skipping
// that entirely for chunks above TERRAIN_MAX_HEIGHT or below the dirt).
// Same result as generate_chunk_from_heights. Pure.
generate_chunk :: proc(c: ^Chunk, coord: [3]i32, seed: i64) {
	bottom := coord.y * CHUNK_SIZE
	if bottom > TERRAIN_MAX_HEIGHT {
		return
	}
	ch: Column_Heights
	if bottom + CHUNK_SIZE - 1 < TERRAIN_ALL_STONE_BELOW {
		ch.max_height = TERRAIN_MAX_HEIGHT // only the stone fast path will run
	} else {
		column_heights_compute(&ch, seed, coord.x, coord.z)
	}
	generate_chunk_from_heights(c, coord, &ch)
}

// Spawn search: the nearest column (by ring, then scan order) at or near
// (x, z) whose surface is above the sea, checked on a SPAWN_SEARCH_STEP grid
// out to SPAWN_SEARCH_RADIUS. Returns (x, z) itself if it's land, and
// falls back to it (ok = false) if no land is found. Pure.
SPAWN_SEARCH_STEP :: 16
SPAWN_SEARCH_RADIUS :: 8192 // a few continent widths

find_land :: proc(seed: i64, x, z: i32) -> (land: [2]i32, ok: bool) {
	if terrain_height(seed, x, z) > TERRAIN_SEA_LEVEL {
		return {x, z}, true
	}
	for r := i32(1); r * SPAWN_SEARCH_STEP <= SPAWN_SEARCH_RADIUS; r += 1 {
		// The square ring at Chebyshev distance r (in grid steps).
		for i := -r; i <= r; i += 1 {
			for offset in ([4][2]i32{{i, -r}, {i, r}, {-r, i}, {r, i}}) {
				// Corners appear twice; harmless.
				p := [2]i32{x, z} + offset * SPAWN_SEARCH_STEP
				if terrain_height(seed, p.x, p.y) > TERRAIN_SEA_LEVEL {
					return p, true
				}
			}
		}
	}
	return {x, z}, false
}
