// Terrain preview: renders the world generator's heightmap to PNGs and prints
// statistics, without opening a window. Run via `./run.sh terrain-preview`.
//
//   map.png      hill-shaded top-down map (grass vs bare stone), 1 px = STEP blocks
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

	peak := render_map(opts)
	render_profile(opts, peak)
	print_stats(opts.seed)
	fmt.printfln("wrote %s/map.png and %s/profile.png (seed %d)", opts.out_dir, opts.out_dir, opts.seed)
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

// Hill-shaded map centered on the origin. Returns the tallest column's (x, z).
render_map :: proc(opts: Options) -> (peak: [2]i32) {
	ORIGIN :: -MAP_PX * STEP / 2
	heights := make([]i32, MAP_PX * MAP_PX)
	defer delete(heights)
	for pz in 0 ..< MAP_PX {
		for px in 0 ..< MAP_PX {
			heights[pz * MAP_PX + px] = world.terrain_height(opts.seed, i32(ORIGIN + px * STEP), i32(ORIGIN + pz * STEP))
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
			x, z := i32(ORIGIN + px * STEP), i32(ORIGIN + pz * STEP)
			col := world.terrain_column(opts.seed, x, z)
			if col.height > tallest {
				tallest, peak = col.height, {x, z}
			}
			// Light from the north-west.
			slope := (at(heights, px + 1, pz) - at(heights, px - 1, pz)) + (at(heights, px, pz + 1) - at(heights, px, pz - 1))
			shade := clamp(1 - 0.12 * f32(slope) / STEP, 0.4, 1.4)
			base: [3]f32
			if col.bare_stone {
				base = {135, 130, 128}
			} else {
				t := clamp(f32(col.height - world.TERRAIN_MIN_HEIGHT) / 40, 0, 1)
				base = {70 + 40 * t, 150 - 20 * t, 55}
			}
			c := base * shade
			rl.ImageDrawPixel(&img, i32(px), i32(pz), {u8(clamp(c.r, 0, 255)), u8(clamp(c.g, 0, 255)), u8(clamp(c.b, 0, 255)), 255})
		}
	}
	rl.ExportImage(img, fmt.ctprintf("%s/map.png", opts.out_dir))
	return
}

// Side view along X through `peak`, 1 px = 1 block, sky / grass / dirt / stone.
render_profile :: proc(opts: Options, peak: [2]i32) {
	img := rl.GenImageColor(PROFILE_W, PROFILE_H, {135, 190, 235, 255})
	defer rl.UnloadImage(img)
	for i in 0 ..< PROFILE_W {
		x := peak.x - PROFILE_W / 2 + i32(i)
		col := world.terrain_column(opts.seed, x, peak.y)
		top := PROFILE_H - 1 - (col.height - world.TERRAIN_MIN_HEIGHT + 10)
		for y in max(top, 0) ..< PROFILE_H {
			c := rl.Color{120, 120, 120, 255}
			if !col.bare_stone && y == top {
				c = {80, 160, 60, 255}
			} else if !col.bare_stone && y <= top + world.TERRAIN_DIRT_DEPTH {
				c = {120, 85, 60, 255}
			}
			rl.ImageDrawPixel(&img, i32(i), y, c)
		}
	}
	rl.ExportImage(img, fmt.ctprintf("%s/profile.png", opts.out_dir))
}

// Area fractions, height percentiles and step histograms over a 6000-block square.
print_stats :: proc(seed: i64) {
	n, mountain, foothill, bare := 0, 0, 0, 0
	steps_plains, steps_mountain: [12]int
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
			if m == 0 {
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
}
