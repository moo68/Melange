package save

// Helpers for the create world screen: what a typed seed means, whether a
// typed name can be used, and a default name.

import "core:fmt"
import "core:hash"
import "core:os"
import "core:strings"

Seed_Kind :: enum u8 {
	Random, // blank: the caller picks a random seed
	Number, // a base-10 integer that fits in an i64: used as is
	Text, // anything else: hashed (FNV-1a 64)
}

// The seed for the text typed into the seed field. Leading/trailing spaces
// are ignored. Only plain base-10 integers (optional sign) are numbers, so
// "0x10" or "1e5" are text; so is a number outside the i64 range.
seed_from_text :: proc(text: string) -> (seed: i64, kind: Seed_Kind) {
	t := strings.trim_space(text)
	if t == "" {
		return 0, .Random
	}
	if n, ok := parse_decimal_i64(t); ok {
		return n, .Number
	}
	return i64(hash.fnv64a(transmute([]byte)t)), .Text
}

// An optional sign then one or more digits, in the i64 range. (strconv's
// parse_i64 doesn't detect overflow, wrapping instead, and allows '_' and
// prefixes like 0x.)
parse_decimal_i64 :: proc(t: string) -> (value: i64, ok: bool) {
	digits := t
	neg := false
	if len(digits) > 0 && (digits[0] == '-' || digits[0] == '+') {
		neg = digits[0] == '-'
		digits = digits[1:]
	}
	if len(digits) == 0 {
		return 0, false
	}
	limit := u64(max(i64)) + (1 if neg else 0) // |min(i64)| = max(i64) + 1
	mag: u64
	for c in transmute([]byte)digits {
		if c < '0' || c > '9' {
			return 0, false
		}
		d := u64(c - '0')
		if mag > (limit - d) / 10 {
			return 0, false // overflow
		}
		mag = mag * 10 + d
	}
	if neg {
		return i64(-mag) if mag <= u64(max(i64)) else min(i64), true
	}
	return i64(mag), true
}

Name_Problem :: enum u8 {
	None,
	Empty,
	Too_Long, // over MAX_NAME_LEN
	Bad_Chars, // not letters, digits, space, '-', '_'
	Edge_Spaces, // starts or ends with a space
	Exists, // a world (or anything) with that name is already in root
}

// Why `name` can't be used for a new world in `root` (.None if it can).
check_new_name :: proc(root, name: string) -> Name_Problem {
	switch {
	case len(name) == 0:
		return .Empty
	case len(name) > MAX_NAME_LEN:
		return .Too_Long
	}
	for c in transmute([]byte)name {
		switch c {
		case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', ' ', '-', '_':
		case:
			return .Bad_Chars
		}
	}
	if name[0] == ' ' || name[len(name) - 1] == ' ' {
		return .Edge_Spaces
	}
	assert(valid_name(name)) // the checks above are valid_name, spelled out
	if os.exists(world_dir(root, name, context.temp_allocator)) {
		return .Exists
	}
	return .None
}

name_problem_text :: proc(p: Name_Problem) -> string {
	switch p {
	case .None:
		return ""
	case .Empty:
		return "Name can't be empty"
	case .Too_Long:
		return fmt.tprintf("At most %d characters", MAX_NAME_LEN)
	case .Bad_Chars:
		return "Only letters, digits, spaces, - and _"
	case .Edge_Spaces:
		return "No spaces at the start or end"
	case .Exists:
		return "A world with this name already exists"
	}
	return ""
}

DEFAULT_WORLD_NAME :: "New World"
MAX_DEFAULT_NAME_TRIES :: 1000

// "New World", or "New World 2", "New World 3", ... if taken (into buf).
// After MAX_DEFAULT_NAME_TRIES taken names, returns the last one tried
// (the screen then shows it as taken).
default_new_name :: proc(root: string, buf: []u8) -> string {
	name := fmt.bprint(buf, DEFAULT_WORLD_NAME)
	for i in 2 ..= MAX_DEFAULT_NAME_TRIES {
		if check_new_name(root, name) != .Exists {
			return name
		}
		name = fmt.bprintf(buf, "%s %d", DEFAULT_WORLD_NAME, i)
	}
	return name
}
