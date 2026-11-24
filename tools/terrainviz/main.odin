// Terrain preview: renders the world generator's heightmap to PNGs and prints
// statistics, without opening a window. Run via `./run.sh terrain-preview`.
//
//   map.png      hill-shaded top-down map (grass / sand / bare stone / water
//                by depth), 1 px = STEP blocks
//   overview.png the same at 1 px = OVERVIEW_STEP blocks (oceans and continents)
//   profile.png  1:1 side view through the tallest peak on the map
//
// Use it when tuning TERRAIN_* constants in src/world/terrain.odin: it's far
// quicker than flying around in the game.
package terrainviz

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "melange:world"
import rl "third_party:raylib"

MAP_PX :: 640 // map pixels per side
STEP   :: 4   // blocks per map pixel (so the map covers MAP_PX * STEP blocks)
OVERVIEW_STEP :: 16 // overview.png: MAP_PX * 16 = 10,240 blocks across
PROFILE_W :: 1200
PROFILE_H :: 140

Options :: struct {
	seed:    i64,
	out_dir: string,
}

main :: proc() {
	opts, ok := parse_args()
	if !ok {
		os.exit(1)
	}
	rl.SetTraceLogLevel(.WARNING)

	peak := render_map(opts, STEP, "map.png")
	render_map(opts, OVERVIEW_STEP, "overview.png")
	render_profile(opts, peak)
	print_stats(opts.seed)
	fmt.printfln("wrote map.png, overview.png and profile.png to %s (seed %d)", opts.out_dir, opts.seed)
}

parse_args :: proc() -> (opts: Options, ok: bool) {
	opts = {seed = 1337, out_dir = "build/terrain-preview"}
	args := os.args[1:]
	for i := 0; i < len(args); i += 1 {
		if i + 1 >= len(args) {
			fmt.eprintfln("%s needs a value", args[i])
			return opts, false
		}
		switch args[i] {
		case "--seed":
			seed, parsed := strconv.parse_i64(args[i + 1])
			if !parsed {
				fmt.eprintfln("--seed: '%s' is not an integer", args[i + 1])
				return opts, false
			}
			opts.seed = seed
		case "--out":
			opts.out_dir = args[i + 1]
		case:
			fmt.eprintfln("unknown argument '%s' (supported: --seed N, --out DIR)", args[i])
			return opts, false
		}
		i += 1
	}
	if err := os.make_directory_all(opts.out_dir); err != nil && !os.exists(opts.out_dir) {
		fmt.eprintfln("can't create %s: %v", opts.out_dir, err)
		return opts, false
	}
	return opts, true
}

// Hill-shaded map centered on the origin, `step` blocks per pixel. Returns
// the tallest column's (x, z).
render_map :: proc(opts: Options, step: int, file: string) -> (peak: [2]i32) {
	ORIGIN := -MAP_PX * step / 2
	heights := make([]i32, MAP_PX * MAP_PX)
	defer delete(heights)
	for pz in 0 ..< MAP_PX {
		for px in 0 ..< MAP_PX {
			heights[pz * MAP_PX + px] = world.terrain_height(opts.seed, i32(ORIGIN + px * step), i32(ORIGIN + pz * step))
		}
	}
	at :: proc(heights: []i32, px, pz: int) -> i32 {
		return heights[clamp(pz, 0, MAP_PX - 1) * MAP_PX + clamp(px, 0, MAP_PX - 1)]
	}

	img := rl.GenImageColor(MAP_PX, MAP_PX, rl.BLACK)
	defer rl.UnloadImage(img)
	tallest := i32(min(i32))
	for pz in 0 ..< MAP_PX {
		for px in 0 ..< MAP_PX {
			x, z := i32(ORIGIN + px * step), i32(ORIGIN + pz * step)
			col := world.terrain_column(opts.seed, x, z)
			if col.height > tallest {
				tallest, peak = col.height, {x, z}
			}
			// Light from the north-west.
			slope := (at(heights, px + 1, pz) - at(heights, px - 1, pz)) + (at(heights, px, pz + 1) - at(heights, px, pz - 1))
			shade := clamp(1 - 0.12 * f32(slope) / f32(step), 0.4, 1.4)
			base: [3]f32
			if col.height < world.TERRAIN_SEA_LEVEL {
				// Water: lighter in the shallows, no hill shading.
				depth := clamp(f32(world.TERRAIN_SEA_LEVEL - col.height) / 22, 0, 1)
				base = {70 - 45 * depth, 150 - 90 * depth, 215 - 70 * depth}
				shade = 1
			} else if col.bare_stone {
				base = {135, 130, 128}
			} else if col.sand {
				base = {222, 206, 156}
			} else {
				t := clamp(f32(col.height - world.TERRAIN_MIN_HEIGHT) / 40, 0, 1)
				base = {70 + 40 * t, 150 - 20 * t, 55}
			}
			c := base * shade
			rl.ImageDrawPixel(&img, i32(px), i32(pz), {u8(clamp(c.r, 0, 255)), u8(clamp(c.g, 0, 255)), u8(clamp(c.b, 0, 255)), 255})
		}
	}
	rl.ExportImage(img, fmt.ctprintf("%s/%s", opts.out_dir, file))
	return
}

// Side view along X through `peak`, 1 px = 1 block, sky / grass / dirt / stone.
render_profile :: proc(opts: Options, peak: [2]i32) {
	img := rl.GenImageColor(PROFILE_W, PROFILE_H, {135, 190, 235, 255})
	defer rl.UnloadImage(img)
	for i in 0 ..< PROFILE_W {
		x := peak.x - PROFILE_W / 2 + i32(i)
		col := world.terrain_column(opts.seed, x, peak.y)
		to_y :: proc(h: i32) -> i32 {
			return PROFILE_H - 1 - (h - world.TERRAIN_MIN_HEIGHT + 10)
		}
		top := to_y(col.height)
		for y in max(to_y(world.TERRAIN_SEA_LEVEL), 0) ..< top {
			rl.ImageDrawPixel(&img, i32(i), y, {50, 100, 200, 255}) // water above the floor
		}
		for y in max(top, 0) ..< PROFILE_H {
			c := rl.Color{120, 120, 120, 255}
			if col.sand && y <= top + world.TERRAIN_DIRT_DEPTH {
				c = {222, 206, 156, 255}
			} else if !col.bare_stone && y == top {
				c = {80, 160, 60, 255}
			} else if !col.bare_stone && y <= top + world.TERRAIN_DIRT_DEPTH {
				c = {120, 85, 60, 255}
			}
			rl.ImageDrawPixel(&img, i32(i), y, c)
		}
	}
	rl.ExportImage(img, fmt.ctprintf("%s/profile.png", opts.out_dir))
}

// Area fractions, height percentiles and step histograms over a 6000-block
// square; the water fraction over a 40,000-block square (oceans are huge).
print_stats :: proc(seed: i64) {
	n, mountain, foothill, bare, beach, land, seabed, sandy_seabed := 0, 0, 0, 0, 0, 0, 0, 0
	steps_plains, steps_mountain, steps_coast: [12]int
	all: [dynamic]i32
	defer delete(all)
	for z := i32(-3000); z < 3000; z += 5 {
		for x := i32(-3000); x < 3000; x += 5 {
			m := world.terrain_mountain_mask(seed, x, z)
			col := world.terrain_column(seed, x, z)
			step := max(abs(world.terrain_height(seed, x + 1, z) - col.height), abs(world.terrain_height(seed, x, z + 1) - col.height))
			append(&all, col.height)
			n += 1
			if m >= 0.99 {
				mountain += 1
			} else if m > 0 {
				foothill += 1
			}
			if col.bare_stone {
				bare += 1
			}
			if col.height >= world.TERRAIN_SEA_LEVEL {
				land += 1
				if col.sand {
					beach += 1
				}
			} else {
				seabed += 1
				if col.sand {
					sandy_seabed += 1
				}
			}
			lw := world.terrain_land_weight(seed, x, z)
			if lw < 1 {
				steps_coast[min(step, 11)] += 1 // ocean and coastal band
			} else if m == 0 {
				steps_plains[min(step, 11)] += 1
			} else {
				steps_mountain[min(step, 11)] += 1
			}
		}
	}
	slice.sort(all[:])
	pct :: proc(a, n: int) -> f64 {
		return 100 * f64(a) / f64(max(n, 1))
	}
	fmt.printfln(
		"area: plains %.1f%%, foothills %.1f%%, mountains %.1f%%, bare stone %.1f%%",
		pct(n - mountain - foothill, n),
		pct(foothill, n),
		pct(mountain, n),
		pct(bare, n),
	)
	fmt.printfln(
		"height: min %d, p10 %d, p50 %d, p90 %d, p99 %d, max %d (bounds %d..%d)",
		all[0],
		all[len(all) / 10],
		all[len(all) / 2],
		all[len(all) * 9 / 10],
		all[len(all) * 99 / 100],
		all[len(all) - 1],
		world.TERRAIN_MIN_HEIGHT,
		world.TERRAIN_MAX_HEIGHT,
	)
	print_steps :: proc(label: string, steps: [12]int) {
		total := 0
		for c in steps {
			total += c
		}
		fmt.printf("%s steps:", label)
		for c, i in steps {
			if c > 0 {
				fmt.printf(" %d:%.1f%%", i, pct(c, total))
			}
		}
		fmt.println()
	}
	print_steps("plains  ", steps_plains)
	print_steps("mountain", steps_mountain)
	print_steps("coast+sea", steps_coast)
	fmt.printfln("sand: beaches/shores %.1f%% of land, %.1f%% of the seabed (the rest: underwater cliffs)", pct(beach, land), pct(sandy_seabed, seabed))

	// Water over a big area: this seed, then the mean over 8 seeds.
	water_stats(seed, true)
	total := 0.0
	for s in i64(0) ..< 8 {
		total += water_stats(seed + s * 1000, false)
	}
	fmt.printfln("water mean over 8 seeds: %.1f%%", total / 8)
}

// Water fraction (and depth spread when `verbose`) over a 40,000-block square.
water_stats :: proc(seed: i64, verbose: bool) -> f64 {
	n, water := 0, 0
	depths: [dynamic]i32
	defer delete(depths)
	for z := i32(-20000); z < 20000; z += 80 {
		for x := i32(-20000); x < 20000; x += 80 {
			h := world.terrain_height(seed, x, z)
			n += 1
			if h < world.TERRAIN_SEA_LEVEL {
				water += 1
				if verbose {
					append(&depths, world.TERRAIN_SEA_LEVEL - h)
				}
			}
		}
	}
	frac := 100 * f64(water) / f64(n)
	if verbose && len(depths) > 0 {
		slice.sort(depths[:])
		fmt.printfln(
			"water (40k square): %.1f%%, depth p10 %d, p50 %d, p90 %d, max %d",
			frac,
			depths[len(depths) / 10],
			depths[len(depths) / 2],
			depths[len(depths) * 9 / 10],
			depths[len(depths) - 1],
		)
	}
	return frac
}
