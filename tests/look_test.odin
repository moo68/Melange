package tests

import "core:math"
import "core:math/linalg"
import "core:testing"
import "melange:geom"

expect_vec :: proc(t: ^testing.T, got, want: [3]f32, loc := #caller_location) {
	testing.expectf(t, linalg.length(got - want) < 1e-5, "got %v, want %v", got, want, loc = loc)
}

@(test)
look_direction_follows_the_convention :: proc(t: ^testing.T) {
	expect_vec(t, geom.look_direction(0, 0), {1, 0, 0}) // yaw 0 = +X
	expect_vec(t, geom.look_direction(90, 0), {0, 0, 1}) // yaw grows toward +Z
	expect_vec(t, geom.look_direction(180, 0), {-1, 0, 0})
	expect_vec(t, geom.look_direction(0, 89), {math.cos(math.to_radians(f32(89))), math.sin(math.to_radians(f32(89))), 0}) // pitch up = +Y
	for yaw in ([]f32{0, 37, 200, 359}) {
		for pitch in ([]f32{-89, -30, 0, 45, 89}) {
			testing.expect(t, abs(linalg.length(geom.look_direction(yaw, pitch)) - 1) < 1e-5, "unit length")
		}
	}
}

@(test)
look_basis_right_is_the_cameras_right :: proc(t: ^testing.T) {
	for yaw in ([]f32{0, 45, 90, 135, 210, 300}) {
		forward, right := geom.look_basis(yaw)
		testing.expect(t, abs(linalg.length(forward) - 1) < 1e-5 && abs(linalg.length(right) - 1) < 1e-5, "unit vectors")
		testing.expect(t, forward.y == 0 && right.y == 0, "horizontal")
		testing.expect(t, abs(linalg.dot(forward, right)) < 1e-6, "perpendicular")
		// The camera's right (what raylib renders as screen-right) is forward × up.
		expect_vec(t, right, linalg.normalize(linalg.cross(geom.look_direction(yaw, 30), [3]f32{0, 1, 0})))
		// Forward is the view direction flattened, whatever the pitch.
		flat := geom.look_direction(yaw, 60)
		flat.y = 0
		expect_vec(t, forward, linalg.normalize(flat))
		// Turning right (yaw up) swings forward toward the old right.
		next, _ := geom.look_basis(yaw + 1)
		testing.expect(t, linalg.dot(next - forward, right) > 0, "yaw increase turns right")
	}
}

@(test)
look_angles_round_trip :: proc(t: ^testing.T) {
	for yaw in ([]f32{0, 45, 120, -100, 179}) {
		for pitch in ([]f32{-80, -10, 0, 33, 88}) {
			y, p := geom.look_angles(geom.look_direction(yaw, pitch))
			expect_vec(t, geom.look_direction(y, p), geom.look_direction(yaw, pitch))
			testing.expect(t, abs(p - pitch) < 1e-3, "pitch survives")
		}
	}
	// The old hard-coded start view (from {0,50,0} toward {20,40,20}).
	y, p := geom.look_angles({20, -10, 20})
	expect_vec(t, geom.look_direction(y, p), linalg.normalize([3]f32{20, -10, 20}))
	// Straight up is clamped short of vertical.
	_, p = geom.look_angles({0, 5, 0})
	testing.expect_value(t, p, geom.PITCH_LIMIT)
}

@(test)
pitch_is_clamped_short_of_vertical :: proc(t: ^testing.T) {
	testing.expect_value(t, geom.clamp_pitch(120), geom.PITCH_LIMIT)
	testing.expect_value(t, geom.clamp_pitch(-95), -geom.PITCH_LIMIT)
	testing.expect_value(t, geom.clamp_pitch(12.5), 12.5)
	testing.expect(t, geom.PITCH_LIMIT < 90)
}
