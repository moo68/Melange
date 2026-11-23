package tests

import "core:math"
import "core:os"
import "core:strings"
import "core:testing"
import "melange:settings"
import "melange:world"

settings_test_path :: proc(test_name: string) -> string {
	root := test_saves_root(test_name)
	return strings.concatenate({root, "/settings.json"}, context.temp_allocator)
}

@(test)
settings_defaults_and_round_trip :: proc(t: ^testing.T) {
	path := settings_test_path("settings_round_trip")
	defer os.remove_all("build/test-saves/settings_round_trip")

	// No file: defaults, no warning.
	s, warning := settings.settings_load(path)
	testing.expect_value(t, s, settings.DEFAULT)
	testing.expect_value(t, warning, "")
	testing.expect_value(t, settings.DEFAULT.render_distance, 16)
	testing.expect_value(t, int(world.DEFAULT_STREAM_CONFIG.radius), settings.DEFAULT.render_distance)
	testing.expect_value(t, settings.settings_clamp(settings.DEFAULT), settings.DEFAULT)

	custom := settings.Settings {
		version           = settings.VERSION,
		render_distance   = 7,
		fov               = 95,
		mouse_sensitivity = 0.35,
		fov_effects       = 0.25,
		vsync             = false,
	}
	testing.expect(t, settings.settings_save(path, custom), "saved")
	testing.expect(t, !os.exists(strings.concatenate({path, ".tmp"}, context.temp_allocator)), "no temp file left")
	got, w2 := settings.settings_load(path)
	testing.expect_value(t, w2, "")
	testing.expect_value(t, got, custom)

	// What's written is already clamped (not only on reading it back).
	wild := custom
	wild.render_distance = 999
	testing.expect(t, settings.settings_save(path, wild), "saved")
	data, err := os.read_entire_file(path, context.temp_allocator)
	testing.expect(t, err == nil, "read back")
	testing.expectf(t, strings.contains(string(data), `"render_distance": 32`), "file holds the clamped value: %s", string(data))
}

@(test)
settings_read_leniently :: proc(t: ^testing.T) {
	path := settings_test_path("settings_lenient")
	defer os.remove_all("build/test-saves/settings_lenient")

	cases := []struct {
		text: string,
		want: settings.Settings,
		warn: bool,
	} {
		// Missing fields keep their defaults; unknown ones are ignored.
		{`{"fov": 90}`, {version = 1, render_distance = 16, fov = 90, mouse_sensitivity = 1, fov_effects = 1, vsync = true}, false},
		{`{"vsync": false, "keybinds": {"jump": "space"}, "render_distance": 20}`, {version = 1, render_distance = 20, fov = 70, mouse_sensitivity = 1, fov_effects = 1, vsync = false}, false},
		{`{}`, settings.DEFAULT, false},
		{`{"fov_effects": 0}`, {version = 1, render_distance = 16, fov = 70, mouse_sensitivity = 1, fov_effects = 0, vsync = true}, false},
		{`{"fov_effects": 2.5}`, settings.DEFAULT, false},
		{`{"fov_effects": -1}`, {version = 1, render_distance = 16, fov = 70, mouse_sensitivity = 1, fov_effects = 0, vsync = true}, false},
		// Out of range: clamped.
		{`{"render_distance": 1000, "fov": 500, "mouse_sensitivity": 99}`, {version = 1, render_distance = 32, fov = 110, mouse_sensitivity = 3, fov_effects = 1, vsync = true}, false},
		{`{"render_distance": -5, "fov": -1, "mouse_sensitivity": 0}`, {version = 1, render_distance = 4, fov = 50, mouse_sensitivity = 0.1, fov_effects = 1, vsync = true}, false},
		{`{"render_distance": 4, "fov": 50, "mouse_sensitivity": 0.1}`, {version = 1, render_distance = 4, fov = 50, mouse_sensitivity = 0.1, fov_effects = 1, vsync = true}, false},
		{`{"render_distance": 32, "fov": 110, "mouse_sensitivity": 3}`, {version = 1, render_distance = 32, fov = 110, mouse_sensitivity = 3, fov_effects = 1, vsync = true}, false},
		// An older version (0) is read; a newer one gives defaults + a warning.
		{`{"version": 0, "fov": 80}`, {version = 1, render_distance = 16, fov = 80, mouse_sensitivity = 1, fov_effects = 1, vsync = true}, false},
		{`{"version": 2, "fov": 80}`, settings.DEFAULT, true},
		// Broken: defaults + a warning.
		{`{"fov": `, settings.DEFAULT, true},
		{`{"render_distance": 20, "fov": `, settings.DEFAULT, true}, // not half-read
		{`{"render_distance": 20, "fov": "wide"}`, settings.DEFAULT, true}, // nor half-applied
		{`{"fov": "wide"}`, settings.DEFAULT, true},
		{``, settings.DEFAULT, true},
	}
	for c in cases {
		write_file(t, path, c.text)
		got, warning := settings.settings_load(path)
		testing.expectf(t, got == c.want, "%s: %v, want %v", c.text, got, c.want)
		testing.expectf(t, (warning != "") == c.warn, "%s: warning '%s'", c.text, warning)
	}
}

@(test)
settings_clamp_handles_nan :: proc(t: ^testing.T) {
	s := settings.DEFAULT
	s.fov = math.nan_f32()
	s.mouse_sensitivity = math.nan_f32()
	s.fov_effects = math.nan_f32()
	s.version = 0
	got := settings.settings_clamp(s)
	testing.expect_value(t, got, settings.DEFAULT)
}

// The fog distance is safe at every render distance the settings allow:
// every block within stream_meshed_distance is in a meshable chunk.
@(test)
meshed_distance_holds_for_every_render_distance :: proc(t: ^testing.T) {
	for radius in settings.MIN_RENDER_DISTANCE ..= settings.MAX_RENDER_DISTANCE {
		cfg := world.DEFAULT_STREAM_CONFIG
		cfg.radius = i32(radius)
		inner := cfg
		inner.radius -= 1
		d := world.stream_meshed_distance(cfg)
		testing.expectf(t, d > 0, "radius %d: meshed distance %v", radius, d)
		for cam_x := f32(0.5); cam_x < 16; cam_x += 5 {
			for cam_z := f32(0.5); cam_z < 16; cam_z += 5 {
				cam_chunk := world.block_to_chunk({i32(cam_x), 8, i32(cam_z)})
				for step in 0 ..< 360 {
					angle := f32(step) * (2 * math.PI / 360)
					px := cam_x + d * math.cos(angle)
					pz := cam_z + d * math.sin(angle)
					b := [3]i32{i32(math.floor(px)), 8, i32(math.floor(pz))}
					if !world.in_stream_range(inner, cam_chunk, world.block_to_chunk(b)) {
						testing.fail_now(t, "a block at the meshed distance is in an unmeshable chunk")
					}
				}
			}
		}
	}
}
