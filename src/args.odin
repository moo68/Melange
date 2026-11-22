package main

import "core:fmt"
import "core:os"
import "core:strconv"

DEFAULT_SEED :: 1337

Options :: struct {
	seed:   i64,
	frames: int, // quit after this many frames (0 = run until closed); for repeatable profiling runs
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
		case:
			fmt.eprintfln("unknown argument '%s' (supported: --seed N, --frames N)", args[i])
			return opts, false
		}
	}
	return opts, true
}
