package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "melange:save"

DEFAULT_SEED :: 1337

Options :: struct {
	seed:     i64,
	seed_set: bool, // --seed given (a new world uses it; an existing one must match)
	world:    string, // --world NAME: open or create saves/NAME ("" = unsaved world)
	frames:   int, // quit after this many frames (0 = run until closed); for repeatable profiling runs
	direct:   bool, // any of --world/--seed/--frames: skip the title screen, straight into the game
	// --screenshot PATH (needs --frames): save the last frame as a PNG, with
	// mouse look off, so runs with the same seed give the same picture
	// (for before/after pixel diffs of rendering changes).
	screenshot: string,
	// --time H: set the clock to hour H (0..24, e.g. 19.8 = mid-sunset)
	// in the current day.
	time_hour:  f64,
	time_set:   bool,
}

// Parses command-line options. Returns ok = false (after printing why) on bad input.
parse_args :: proc() -> (opts: Options, ok: bool) {
	opts.seed = DEFAULT_SEED
	args := os.args[1:]
	for i := 0; i < len(args); i += 1 {
		switch args[i] {
		case "--seed":
			if i + 1 >= len(args) {
				fmt.eprintln("--seed needs a value")
				return opts, false
			}
			i += 1
			seed, parsed := strconv.parse_i64(args[i])
			if !parsed {
				fmt.eprintfln("--seed: '%s' is not an integer", args[i])
				return opts, false
			}
			opts.seed = seed
			opts.seed_set = true
		case "--world":
			if i + 1 >= len(args) {
				fmt.eprintln("--world needs a name")
				return opts, false
			}
			i += 1
			if !save.valid_name(args[i]) {
				fmt.eprintfln("--world: '%s' isn't a valid name (1-%d letters, digits, spaces, '-' or '_'; no leading/trailing space)", args[i], save.MAX_NAME_LEN)
				return opts, false
			}
			opts.world = args[i]
		case "--frames":
			if i + 1 >= len(args) {
				fmt.eprintln("--frames needs a value")
				return opts, false
			}
			i += 1
			frames, parsed := strconv.parse_int(args[i])
			if !parsed || frames < 1 {
				fmt.eprintfln("--frames: '%s' is not a positive integer", args[i])
				return opts, false
			}
			opts.frames = frames
		case "--time":
			if i + 1 >= len(args) {
				fmt.eprintln("--time needs an hour (0-24)")
				return opts, false
			}
			i += 1
			hour, parsed := strconv.parse_f64(args[i])
			if !parsed || !(hour >= 0 && hour <= 24) {
				fmt.eprintfln("--time: '%s' is not an hour from 0 to 24", args[i])
				return opts, false
			}
			opts.time_hour = hour
			opts.time_set = true
		case "--screenshot":
			if i + 1 >= len(args) {
				fmt.eprintln("--screenshot needs a path")
				return opts, false
			}
			i += 1
			opts.screenshot = args[i]
		case:
			fmt.eprintfln("unknown argument '%s' (supported: --world NAME, --seed N, --frames N, --screenshot PATH, --time H)", args[i])
			return opts, false
		}
	}
	if opts.screenshot != "" && opts.frames == 0 {
		fmt.eprintln("--screenshot needs --frames N (the frame to save is the last one)")
		return opts, false
	}
	opts.direct = opts.world != "" || opts.seed_set || opts.frames > 0
	return opts, true
}
