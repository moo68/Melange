package main

import "core:fmt"
import "core:os"
import "core:strconv"

DEFAULT_SEED :: 1337

Options :: struct {
	seed: i64,
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
		case:
			fmt.eprintfln("unknown argument '%s' (supported: --seed N)", args[i])
			return opts, false
		}
	}
	return opts, true
}
