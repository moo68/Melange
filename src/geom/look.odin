package geom

import "core:math"
import "core:math/linalg"

// Yaw/pitch view angles, in degrees. Y is up. Yaw 0 looks along +X and
// increases toward +Z, which is turning right (right = forward × up).
// Pitch is up from the horizon, positive = looking up.

// Pitch is kept just short of straight up/down so forward never lines up
// with the up vector (the view would flip).
PITCH_LIMIT :: 89.0

clamp_pitch :: proc "contextless" (pitch: f32) -> f32 {
	return clamp(pitch, -PITCH_LIMIT, PITCH_LIMIT)
}

// Unit view direction.
look_direction :: proc "contextless" (yaw, pitch: f32) -> [3]f32 {
	y, p := math.to_radians(yaw), math.to_radians(pitch)
	return {math.cos(p) * math.cos(y), math.sin(p), math.cos(p) * math.sin(y)}
}

// Unit horizontal forward and right vectors for walking/flying along the
// ground plane, whatever the pitch.
look_basis :: proc "contextless" (yaw: f32) -> (forward, right: [3]f32) {
	y := math.to_radians(yaw)
	forward = {math.cos(y), 0, math.sin(y)}
	right = {-math.sin(y), 0, math.cos(y)}
	return
}

// Yaw/pitch that look along `dir` (needn't be normalized; must be nonzero).
// Pitch is clamped like clamp_pitch.
look_angles :: proc "contextless" (dir: [3]f32) -> (yaw, pitch: f32) {
	d := linalg.normalize(dir)
	yaw = math.to_degrees(math.atan2(d.z, d.x))
	pitch = clamp_pitch(math.to_degrees(math.asin(clamp(d.y, -1, 1))))
	return
}
