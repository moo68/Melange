package settings

// Player settings, kept in settings.json in the project root (gitignored).
// Reading is lenient: missing fields keep their defaults, out-of-range
// values are clamped, unknown fields are ignored; a broken or newer file
// gives the defaults plus a warning (and is only overwritten when the
// player next saves settings). No raylib: main applies them.

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:os"
import "melange:save"

PATH :: "settings.json"
VERSION :: 1

Settings :: struct {
	version:           int,
	render_distance:   int, // chunks (streaming radius)
	fov:               f32, // vertical field of view, degrees
	mouse_sensitivity: f32, // multiplier of player.MOUSE_SENSITIVITY (1 = 100%)
	vsync:             bool,
}

DEFAULT :: Settings {
	version           = VERSION,
	render_distance   = 16,
	fov               = 70,
	mouse_sensitivity = 1,
	vsync             = true,
}

MIN_RENDER_DISTANCE :: 4
MAX_RENDER_DISTANCE :: 32 // more isn't worth the memory until worker threads (~860 MB at 32)
MIN_FOV :: 50
MAX_FOV :: 110
MIN_MOUSE_SENSITIVITY :: 0.1
MAX_MOUSE_SENSITIVITY :: 3

// `s` with every value in range (NaN becomes the default) and the current
// version.
settings_clamp :: proc(s: Settings) -> Settings {
	out := s
	out.version = VERSION
	out.render_distance = clamp(s.render_distance, MIN_RENDER_DISTANCE, MAX_RENDER_DISTANCE)
	out.fov = clamp_f32(s.fov, MIN_FOV, MAX_FOV, DEFAULT.fov)
	out.mouse_sensitivity = clamp_f32(s.mouse_sensitivity, MIN_MOUSE_SENSITIVITY, MAX_MOUSE_SENSITIVITY, DEFAULT.mouse_sensitivity)
	return out
}

@(private = "file")
clamp_f32 :: proc(v, lo, hi, fallback: f32) -> f32 {
	if math.is_nan(v) {
		return fallback
	}
	return clamp(v, lo, hi)
}

// Reads `path`. A missing file is the defaults with no warning; a broken or
// newer one is the defaults plus a warning (temp-allocated).
settings_load :: proc(path: string) -> (s: Settings, warning: string) {
	if !os.exists(path) {
		return DEFAULT, ""
	}
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return DEFAULT, fmt.tprintf("can't read %s (%v); using default settings", path, err)
	}
	s = DEFAULT // fields missing from the file keep these
	if json.unmarshal(data, &s, allocator = context.temp_allocator) != nil {
		return DEFAULT, fmt.tprintf("%s isn't valid; using default settings (it's replaced when you next change settings)", path)
	}
	if s.version > VERSION {
		return DEFAULT, fmt.tprintf("%s is from a newer version; using default settings (it's replaced when you next change settings)", path)
	}
	return settings_clamp(s), ""
}

// Writes `s` (clamped) to `path` safely (temp file + rename).
settings_save :: proc(path: string, s: Settings) -> bool {
	text, err := json.marshal(settings_clamp(s), {pretty = true}, context.temp_allocator)
	if err != nil {
		return false
	}
	return save.write_file_atomic(path, text) == .None
}
