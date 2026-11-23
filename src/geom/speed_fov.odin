package geom

import "core:math"

// Speed FOV: the field of view widens with horizontal speed (Minecraft's
// sprint FOV). The multiplier is 1 at WALK_SPEED or slower and
// SPRINT_FOV_SCALE at SPRINT_SPEED or faster, linear in between, so it
// follows the body's acceleration and narrows when a wall stops it.

SPRINT_FOV_SCALE :: 1.15 // Minecraft: (1.3 speed + 1) / 2
// How fast the shown multiplier approaches its target, per second:
// halves the gap every 50 ms (Minecraft's 0.5 per 20 Hz tick); 95% in ~0.22 s.
SPEED_FOV_RATE :: 13.862943611198906 // ln 2 / 0.05

// The multiplier for horizontal speed `speed` (blocks per second).
speed_fov_target :: proc "contextless" (speed: f64) -> f64 {
	t := clamp((speed - WALK_SPEED) / (SPRINT_SPEED - WALK_SPEED), 0, 1)
	return 1 + (SPRINT_FOV_SCALE - 1) * t
}

// `current` after moving toward `target` for `dt` seconds (exact
// exponential: the same result however the time is split into frames).
speed_fov_step :: proc "contextless" (current, target, dt: f64) -> f64 {
	return target + (current - target) * math.exp(-SPEED_FOV_RATE * dt)
}

// The vertical FOV to draw with: `fov` (the setting) times the speed
// multiplier `scale`, with the widening scaled by `effects` (the FOV effects
// setting, 0 = off, 1 = full).
speed_fov_apply :: proc "contextless" (fov, scale, effects: f32) -> f32 {
	return fov * (1 + (scale - 1) * clamp(effects, 0, 1))
}
