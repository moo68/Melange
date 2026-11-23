package tests

import "core:math"
import "core:testing"
import "melange:geom"

@(test)
speed_fov_target_follows_speed :: proc(t: ^testing.T) {
	near :: proc(a, b: f64) -> bool {return abs(a - b) < 1e-12}
	testing.expect(t, near(geom.speed_fov_target(0), 1), "standing")
	testing.expect(t, near(geom.speed_fov_target(geom.CROUCH_SPEED), 1), "crouching")
	testing.expect(t, near(geom.speed_fov_target(geom.WALK_SPEED), 1), "walking")
	testing.expect(t, near(geom.speed_fov_target(geom.SPRINT_SPEED), geom.SPRINT_FOV_SCALE), "sprinting")
	testing.expect(t, near(geom.speed_fov_target(100), geom.SPRINT_FOV_SCALE), "clamped above")
	mid := (geom.WALK_SPEED + geom.SPRINT_SPEED) / 2
	testing.expect(t, near(geom.speed_fov_target(mid), (1 + geom.SPRINT_FOV_SCALE) / 2), "linear between")
	testing.expect_value(t, geom.SPRINT_FOV_SCALE, 1.15)
}

@(test)
speed_fov_step_is_frame_rate_independent :: proc(t: ^testing.T) {
	// Same total time split into 30, 60, 144, 240 and 1000 fps frames.
	want := geom.speed_fov_step(1, 1.15, 0.5)
	for fps in ([]f64{30, 60, 144, 240, 1000}) {
		v := 1.0
		for _ in 0 ..< int(0.5 * fps) {
			v = geom.speed_fov_step(v, 1.15, 1 / fps)
		}
		testing.expectf(t, abs(v - want) < 1e-9, "%v fps: %v, want %v", fps, v, want)
	}
	// Half the gap every 50 ms; 95% in ~0.22 s; never overshoots.
	testing.expect(t, abs(geom.speed_fov_step(1, 1.15, 0.05) - 1.075) < 1e-9, "halves the gap in 50 ms")
	t95 := math.ln(f64(20)) / geom.SPEED_FOV_RATE
	testing.expectf(t, t95 > 0.2 && t95 < 0.23, "95%% after %v s", t95)
	testing.expect(t, geom.speed_fov_step(1.15, 1, 10) >= 1, "no overshoot going down")
	testing.expect(t, geom.speed_fov_step(1, 1.15, 10) <= 1.15, "no overshoot going up")
}

@(test)
speed_fov_apply_scales_with_effects :: proc(t: ^testing.T) {
	testing.expect(t, abs(geom.speed_fov_apply(70, 1.15, 1) - 80.5) < 1e-4, "full effect")
	testing.expect(t, abs(geom.speed_fov_apply(70, 1.15, 0.5) - 75.25) < 1e-4, "half effect")
	testing.expect_value(t, geom.speed_fov_apply(70, 1.15, 0), 70)
	testing.expect_value(t, geom.speed_fov_apply(70, 1, 1), 70)
	testing.expect_value(t, geom.speed_fov_apply(70, 1.15, -3), 70) // clamped
	testing.expect(t, abs(geom.speed_fov_apply(70, 1.15, 5) - 80.5) < 1e-4, "clamped to full")
}

// Walking a body on flat ground: walk speed never widens the FOV, sprinting
// reaches the full scale, and running into a wall brings it back to 1.
@(test)
speed_fov_from_body_motion :: proc(t: ^testing.T) {
	scene := Scene{floor = 0, cells = {{20, 0, 0}, {20, 1, 0}}}
	b := geom.Body{position = {0.5, geom.COLLISION_SKIN, 0.5}, on_ground = true}
	speed_target :: proc(b: geom.Body) -> f64 {
		return geom.speed_fov_target(math.sqrt(b.velocity.x * b.velocity.x + b.velocity.z * b.velocity.z))
	}
	fov := 1.0
	for _ in 0 ..< 60 {
		geom.body_step(&b, {wish = {1, 0}}, geom.PHYSICS_DT, &scene, scene_solid)
		fov = geom.speed_fov_step(fov, speed_target(b), geom.PHYSICS_DT)
	}
	testing.expectf(t, fov == 1, "walking: %v", fov)
	for _ in 0 ..< 60 {
		geom.body_step(&b, {wish = {1, 0}, sprint = true}, geom.PHYSICS_DT, &scene, scene_solid)
		fov = geom.speed_fov_step(fov, speed_target(b), geom.PHYSICS_DT)
	}
	testing.expectf(t, abs(fov - geom.SPRINT_FOV_SCALE) < 0.002, "sprinting: %v", fov)
	for _ in 0 ..< 240 { 	// reaches the wall at x = 20 and keeps pushing
		geom.body_step(&b, {wish = {1, 0}, sprint = true}, geom.PHYSICS_DT, &scene, scene_solid)
		fov = geom.speed_fov_step(fov, speed_target(b), geom.PHYSICS_DT)
	}
	testing.expectf(t, b.position.x < 20 && b.position.x > 19, "stopped at the wall: %v", b.position.x)
	testing.expectf(t, abs(fov - 1) < 0.002, "against the wall: %v", fov)
}
