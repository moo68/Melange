package world

import "core:math"

// ---- Day/night cycle (roadmap 3c) -------------------------------------------------
// World time (World.time) is seconds of play since the world began, at 7:00
// on day 1 (just after sunrise, so new worlds start in full daylight). A day
// lasts DAY_LENGTH seconds (20 minutes, like Minecraft; 50 s per hour) and
// days roll over at 7:00. Phases, in seconds since 6:00:
//
//     -45 .. 45    sunrise (5:06-6:54)    night -> day
//      45 .. 645   day (6:54-18:54)       10 minutes
//     645 .. 735   sunset (18:54-20:42)   day -> night
//     735 .. 1155  night (20:42-5:06)     7 minutes
//
// Everything is a pure function of the time: sky_at gives the daylight
// factor (scales sky light's brightness in the shader, 1 by day, NIGHT_DAYLIGHT
// at night; block light isn't scaled) and the sky color (also the fog and
// clear color). Day/night never remeshes.

DAY_LENGTH         :: 1200.0 // seconds per day
SECONDS_PER_HOUR   :: DAY_LENGTH / 24 // 50
DAY_START_HOUR     :: 7.0 // clock hour at time 0, and where days roll over
SUNRISE_HOUR       :: 6.0 // middle of sunrise; the phases above count from here
TRANSITION_SECONDS :: 90.0 // sunrise and sunset each
DAY_SECONDS        :: 600.0 // full daylight
NIGHT_SECONDS      :: DAY_LENGTH - DAY_SECONDS - 2 * TRANSITION_SECONDS // 420

#assert(NIGHT_SECONDS == 420)

// Sky light's brightness is scaled by this at night (moonlight). Tunable:
// lower = darker nights.
NIGHT_DAYLIGHT :: f32(0.2)

// Sky colors at the horizon (also fog and clear colors): day = SKY_COLOR,
// through a warm sunset/sunrise color halfway, to night. The sky straight up
// (zenith) is deeper; the sky pass blends between them by elevation.
SUNSET_COLOR :: [3]u8{230, 150, 100}
NIGHT_COLOR  :: [3]u8{12, 15, 35}
DAY_ZENITH    :: [3]u8{72, 128, 214}
SUNSET_ZENITH :: [3]u8{78, 88, 150}
NIGHT_ZENITH  :: [3]u8{3, 4, 12}

Sky_State :: struct {
	daylight: f32, // NIGHT_DAYLIGHT..1: multiplies sky light's brightness
	color:    [3]u8, // horizon: sky, fog and clear color (above water)
	zenith:   [3]u8, // the sky straight up
}

// Seconds since the last DAY_START_HOUR, in [0, DAY_LENGTH).
time_of_day :: proc "contextless" (time: f64) -> f64 {
	t := math.mod(time, DAY_LENGTH)
	return t + DAY_LENGTH if t < 0 else t
}

// Day number, starting at 1 (days begin at DAY_START_HOUR).
day_number :: proc "contextless" (time: f64) -> i64 {
	return i64(math.floor(time / DAY_LENGTH)) + 1
}

// Clock time in hours, [0, 24).
clock_hours :: proc "contextless" (time: f64) -> f64 {
	return math.mod(DAY_START_HOUR + time_of_day(time) / SECONDS_PER_HOUR, 24)
}

// `time` moved to clock hour `hour` (0..24), staying in the same day (days
// begin at 7:00, so 3:00 is the end of the current day).
time_at_hour :: proc "contextless" (time: f64, hour: f64) -> f64 {
	since_start := math.mod(math.mod(hour - DAY_START_HOUR, 24) + 24, 24) * SECONDS_PER_HOUR
	return f64(day_number(time) - 1) * DAY_LENGTH + since_start
}

// How far into night `time` is: 0 by day, 1 at night, linear through
// sunrise and sunset (the same path both ways).
nightness :: proc "contextless" (time: f64) -> f32 {
	// Seconds since the last SUNRISE_HOUR.
	u := time_of_day(time + (DAY_START_HOUR - SUNRISE_HOUR) * SECONDS_PER_HOUR)
	HALF :: TRANSITION_SECONDS / 2
	if u >= DAY_LENGTH - HALF {
		u -= DAY_LENGTH // the first half of sunrise belongs to the previous night
	}
	switch {
	case u < HALF:
		return f32(1 - (u + HALF) / TRANSITION_SECONDS) // sunrise
	case u < HALF + DAY_SECONDS:
		return 0
	case u < HALF + DAY_SECONDS + TRANSITION_SECONDS:
		return f32((u - HALF - DAY_SECONDS) / TRANSITION_SECONDS) // sunset
	}
	return 1
}

sky_at :: proc "contextless" (time: f64) -> Sky_State {
	n := nightness(time)
	daylight := math.lerp(f32(1), NIGHT_DAYLIGHT, math.smoothstep(f32(0), 1, n))
	return {daylight, blend_sky(n, SKY_COLOR, SUNSET_COLOR, NIGHT_COLOR), blend_sky(n, DAY_ZENITH, SUNSET_ZENITH, NIGHT_ZENITH)}
}

// Day -> sunset color over the first half of nightness `n`, sunset -> night
// over the second.
@(private = "file")
blend_sky :: proc "contextless" (n: f32, day, sunset, night: [3]u8) -> [3]u8 {
	color: [3]f32
	if n < 0.5 {
		color = math.lerp(rgb_f32(day), rgb_f32(sunset), math.smoothstep(f32(0), 1, n * 2))
	} else {
		color = math.lerp(rgb_f32(sunset), rgb_f32(night), math.smoothstep(f32(0), 1, n * 2 - 1))
	}
	return {u8(math.round(color.r)), u8(math.round(color.g)), u8(math.round(color.b))}
}

// ---- Sun and moon ---------------------------------------------------------------
// The sun crosses the sky on a circle through east (+X) and west (-X),
// tilted SUN_TILT toward +Z (0, like Minecraft: straight overhead at its
// highest, and its square stays upright at the horizon; a tilt turns it
// on its way up). It's on
// the horizon at mid-sunrise (6:00, east) and mid-sunset (19:48, west):
// the day half of its arc takes those 13.8 hours, the night half the other
// 10.2. The moon is always opposite.

SUN_TILT :: f32(0) // radians the arc leans toward +Z
SUNSET_HOUR :: SUNRISE_HOUR + (TRANSITION_SECONDS + DAY_SECONDS) / SECONDS_PER_HOUR // 19.8
SUN_UP_SECONDS :: (SUNSET_HOUR - SUNRISE_HOUR) * SECONDS_PER_HOUR // 690

// The sun's angle along its arc: 0 rising (east), π/2 highest, π setting
// (west), π..2π below the horizon.
sun_angle :: proc "contextless" (time: f64) -> f32 {
	s := time_of_day(time + (DAY_START_HOUR - SUNRISE_HOUR) * SECONDS_PER_HOUR) // since 6:00
	if s < SUN_UP_SECONDS {
		return f32(math.PI * s / SUN_UP_SECONDS)
	}
	return f32(math.PI + math.PI * (s - SUN_UP_SECONDS) / (DAY_LENGTH - SUN_UP_SECONDS))
}

// Unit vector toward the sun.
sun_direction :: proc "contextless" (time: f64) -> [3]f32 {
	a := sun_angle(time)
	return {math.cos(a), math.sin(a) * math.cos(SUN_TILT), math.sin(a) * math.sin(SUN_TILT)}
}

// Normal of the plane the sun and moon move in (perpendicular to their
// direction at all times): the sky pass orients their squares by it.
sun_arc_normal :: proc "contextless" () -> [3]f32 {
	return {0, -math.sin(SUN_TILT), math.cos(SUN_TILT)}
}

@(private = "file")
rgb_f32 :: proc "contextless" (c: [3]u8) -> [3]f32 {
	return {f32(c.r), f32(c.g), f32(c.b)}
}

// Advances world time by `dt` seconds of play.
world_advance_time :: proc "contextless" (w: ^World, dt: f64) {
	w.time += dt
}
