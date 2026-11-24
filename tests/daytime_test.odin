package tests

import "core:math"

import "core:testing"
import "melange:world"

@(private = "file")
at_hour :: proc(hour: f64) -> world.Sky_State {
	return world.sky_at(world.time_at_hour(0, hour))
}

@(test)
day_night_phases :: proc(t: ^testing.T) {
	// Full day 6:54..18:54, full night 20:42..5:06.
	for h in ([]f64{7, 9, 12, 15, 18.8}) {
		s := at_hour(h)
		testing.expectf(t, s.daylight == 1 && s.color == world.SKY_COLOR, "%v: %v", h, s)
	}
	for h in ([]f64{20.8, 22, 0, 3, 5}) {
		s := at_hour(h)
		testing.expectf(t, s.daylight == world.NIGHT_DAYLIGHT && s.color == world.NIGHT_COLOR, "%v: %v", h, s)
	}
	// Mid-sunrise (6:00) and mid-sunset (19:48): halfway, sunset colored.
	for h in ([]f64{6, 19.8}) {
		s := at_hour(h)
		testing.expectf(t, abs(s.daylight - (1 + world.NIGHT_DAYLIGHT) / 2) < 1e-4, "%v: %v", h, s)
		testing.expect_value(t, s.color, world.SUNSET_COLOR)
	}
	testing.expect_value(t, world.nightness(world.time_at_hour(0, 5.55)), 0.75) // a quarter into sunrise
	testing.expect_value(t, world.nightness(world.time_at_hour(0, 19.35)), 0.25) // a quarter into sunset
	testing.expect_value(t, world.nightness(world.time_at_hour(0, 18.8)), 0) // just before sunset
	// Daylight eases in and out (smoothstep): a quarter through, 15.6% of the way.
	testing.expectf(t, abs(at_hour(19.35).daylight - 0.875) < 1e-5, "%v", at_hour(19.35).daylight)
	// Time 0 is 7:00 on day 1, in full daylight (new worlds and old saves).
	testing.expect_value(t, world.clock_hours(0), 7)
	testing.expect_value(t, world.day_number(0), 1)
	testing.expect_value(t, world.sky_at(0).daylight, 1)
}

// No jumps anywhere, including at the phase borders and the day wrap.
@(test)
day_night_is_continuous :: proc(t: ^testing.T) {
	STEP :: 0.05 // seconds
	prev := world.sky_at(-STEP)
	max_light, max_color := f32(0), 0
	for time := 0.0; time < 2 * world.DAY_LENGTH; time += STEP {
		s := world.sky_at(time)
		n := world.nightness(time)
		testing.expect(t, n >= 0 && n <= 1)
		testing.expect(t, s.daylight >= world.NIGHT_DAYLIGHT && s.daylight <= 1)
		max_light = max(max_light, abs(s.daylight - prev.daylight))
		for c in 0 ..< 3 {
			max_color = max(max_color, abs(int(s.color[c]) - int(prev.color[c])))
		}
		prev = s
	}
	// Steepest smoothstep slope is 1.5 / 90 s per second over the full range.
	testing.expectf(t, max_light < 0.001, "daylight jumps by %v", max_light)
	testing.expectf(t, max_color <= 1, "color jumps by %v", max_color)
}

@(test)
clock_and_days :: proc(t: ^testing.T) {
	testing.expect_value(t, world.clock_hours(world.DAY_LENGTH / 4), 13) // 6 h after 7:00
	testing.expect_value(t, world.clock_hours(world.DAY_LENGTH * 3 / 4), 1)
	testing.expect_value(t, world.day_number(world.DAY_LENGTH - 0.001), 1)
	testing.expect_value(t, world.day_number(world.DAY_LENGTH), 2) // at 7:00
	testing.expect_value(t, world.time_of_day(-1), world.DAY_LENGTH - 1)
	testing.expect_value(t, world.day_number(-1), 0) // consistent with time_of_day
	// Setting the clock keeps the day: 3:00 is late in the current day.
	time := 5 * world.DAY_LENGTH + 100 // day 6, 9:00
	for h in ([]f64{0, 3, 6.99, 7, 12, 19.8, 23.5}) {
		got := world.time_at_hour(time, h)
		testing.expectf(t, world.day_number(got) == 6, "%v -> day %d", h, world.day_number(got))
		testing.expectf(t, abs(world.clock_hours(got) - h) < 1e-9, "%v -> %v", h, world.clock_hours(got))
	}
	testing.expect_value(t, world.time_at_hour(time, 24), world.time_at_hour(time, 0))
}

// The fog follows the sky; under water it darkens with the daylight.
@(test)
fog_follows_the_time_of_day :: proc(t: ^testing.T) {
	cfg := world.DEFAULT_STREAM_CONFIG
	night := world.sky_at(world.time_at_hour(0, 0))
	f := world.fog_for(cfg, false, night)
	testing.expect_value(t, f.color, world.NIGHT_COLOR)
	testing.expect_value(t, f.daylight, world.NIGHT_DAYLIGHT)
	sunset := world.sky_at(world.time_at_hour(0, 19.8))
	testing.expect_value(t, world.fog_for(cfg, false, sunset).color, world.SUNSET_COLOR)
	u := world.fog_for(cfg, true, night)
	c := world.WATER_FOG_COLOR
	testing.expect_value(t, u.color, [3]u8{u8(f32(c.r) * 0.2), u8(f32(c.g) * 0.2), u8(f32(c.b) * 0.2)})
	testing.expect_value(t, u.daylight, world.NIGHT_DAYLIGHT)
	testing.expect_value(t, world.fog_for(cfg, true, world.sky_at(world.time_at_hour(0, 12))).color, world.WATER_FOG_COLOR)
}

@(test)
sky_zenith_follows_the_day :: proc(t: ^testing.T) {
	testing.expect_value(t, at_hour(12).zenith, world.DAY_ZENITH)
	testing.expect_value(t, at_hour(19.8).zenith, world.SUNSET_ZENITH)
	testing.expect_value(t, at_hour(0).zenith, world.NIGHT_ZENITH)
}

// The sun rises in the east (+X) at mid-sunrise, is highest halfway to
// mid-sunset, sets in the west (-X); it's above the horizon exactly between
// those, moves smoothly, and stays in its tilted plane. The moon is opposite.
@(test)
sun_path :: proc(t: ^testing.T) {
	near :: proc(a, b: [3]f32) -> bool {
		d := a - b
		return d.x * d.x + d.y * d.y + d.z * d.z < 1e-8
	}
	sun := proc(hour: f64) -> [3]f32 {return world.sun_direction(world.time_at_hour(0, hour))}
	testing.expectf(t, near(sun(6), {1, 0, 0}), "6:00: %v", sun(6))
	testing.expectf(t, near(sun(19.8), {-1, 0, 0}), "19:48: %v", sun(19.8))
	noon := sun((6 + 19.8) / 2)
	tilt := world.SUN_TILT
	testing.expectf(t, near(noon, {0, math.cos(tilt), math.sin(tilt)}), "highest: %v", noon)
	testing.expectf(t, sun(0).y < -0.9, "midnight-ish: %v", sun(0))
	n := world.sun_arc_normal()
	STEP :: 0.25 // seconds
	prev := world.sun_direction(-STEP)
	for time := 0.0; time < 2 * world.DAY_LENGTH; time += STEP {
		d := world.sun_direction(time)
		hour := world.clock_hours(time)
		above := hour > 6 && hour < 19.8
		testing.expect(t, abs(d.x * d.x + d.y * d.y + d.z * d.z - 1) < 1e-5)
		testing.expect(t, abs(d.x * n.x + d.y * n.y + d.z * n.z) < 1e-5, "in the arc plane")
		if abs(hour - 6) > 0.01 && abs(hour - 19.8) > 0.01 {
			testing.expectf(t, (d.y > 0) == above, "%v: elevation %v", hour, d.y)
		}
		step := d - prev
		testing.expect(t, step.x * step.x + step.y * step.y + step.z * step.z < 0.01 * 0.01, "no jumps")
		prev = d
	}
}
