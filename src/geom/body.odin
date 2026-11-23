package geom

import "core:math"
import "core:math/linalg"

// Walking physics for an upright box (the player). Pure: input is plain
// values, the world is an is_solid callback. Numbers are Minecraft's.

BODY_WIDTH  :: 0.6 // x and z
BODY_HEIGHT :: 1.8
EYE_HEIGHT  :: 1.62 // above the feet
CROUCH_EYE_HEIGHT :: 1.27
// How fast the eye moves between EYE_HEIGHT and CROUCH_EYE_HEIGHT, blocks per
// second: the 0.35-block change takes 0.1 s.
EYE_HEIGHT_RATE :: 3.5

WALK_SPEED   :: 4.317 // blocks per second
SPRINT_SPEED :: 5.912
CROUCH_SPEED :: 0.3 * WALK_SPEED // 1.295; crouching beats sprinting
GRAVITY      :: 32.0 // blocks per second²
TERMINAL_FALL :: 60.0 // max fall speed, blocks per second
// sqrt(2 * GRAVITY * 1.25): the feet rise 1.25 blocks, enough to clear a
// 1-block step but not a 2-block one.
JUMP_SPEED :: 8.944

// How fast horizontal velocity approaches the input's target speed:
// v += (target - v) * (1 - exp(-rate * dt)). On the ground ~95% in 0.15 s
// (snappy); in the air a tenth of that, so jumps keep their momentum.
GROUND_CONTROL :: 20.0 // per second
AIR_CONTROL    :: 2.0

// One fixed physics step (60 Hz); see fixed_steps.
PHYSICS_DT :: 1.0 / 60.0
// Longest frame time fed to physics; a longer hitch just slows the world
// down instead of running dozens of catch-up steps.
MAX_FRAME_DT :: 0.25

Body :: struct {
	position:  [3]f64, // feet: bottom center of the box
	velocity:  [3]f64,
	on_ground: bool, // standing on something after the last step
}

Body_Input :: struct {
	wish:   [2]f64, // desired horizontal direction (x, z); length is clamped to 1
	jump:   bool, // held: jumps whenever on the ground
	sprint: bool,
	// Slower, and while on the ground the body won't walk off an edge (see
	// edge_clamp). Jumping off still works.
	crouch: bool,
}

// The body's collision box with its feet at `feet`.
body_box :: proc "contextless" (feet: [3]f64) -> AABB {
	h :: BODY_WIDTH / 2
	return {min = feet - {h, 0, h}, max = feet + {h, BODY_HEIGHT, h}}
}

// Advances the body by `dt` seconds.
body_step :: proc(b: ^Body, input: Body_Input, dt: f64, data: $T, is_solid: proc(data: T, cell: [3]i32) -> bool) {
	wish := input.wish
	if l := linalg.length(wish); l > 1 {
		wish /= l
	}
	speed := WALK_SPEED
	if input.crouch {
		speed = CROUCH_SPEED
	} else if input.sprint {
		speed = SPRINT_SPEED
	}
	target := wish * speed
	response := 1 - math.exp(-(GROUND_CONTROL if b.on_ground else AIR_CONTROL) * dt)
	b.velocity.x += (target.x - b.velocity.x) * response
	b.velocity.z += (target.y - b.velocity.z) * response

	if input.jump && b.on_ground {
		b.velocity.y = JUMP_SPEED
	}
	// Constant acceleration within the step: average velocity is exact,
	// so jump height doesn't depend on the step size (until terminal speed).
	v0 := b.velocity.y
	v1 := max(v0 - GRAVITY * dt, -TERMINAL_FALL)
	b.velocity.y = v1
	delta := [3]f64{b.velocity.x * dt, (v0 + v1) / 2 * dt, b.velocity.z * dt}

	moved, blocked := move_aabb(body_box(b.position), delta, data, is_solid, keep_support = input.crouch)
	b.position += moved
	for axis in 0 ..< 3 {
		if blocked[axis] {
			b.velocity[axis] = 0 // landed, bumped a ceiling, hit a wall, or stopped at an edge
		}
	}
	b.on_ground = blocked.y && delta.y < 0
}

// The eye's height above the feet after one step of `dt`: moves toward
// CROUCH_EYE_HEIGHT or EYE_HEIGHT at EYE_HEIGHT_RATE, never past it.
eye_height_step :: proc "contextless" (current: f64, crouch: bool, dt: f64) -> f64 {
	target := CROUCH_EYE_HEIGHT if crouch else EYE_HEIGHT
	step := EYE_HEIGHT_RATE * dt
	return clamp(target, current - step, current + step)
}

// Fixed-timestep bookkeeping: adds the frame's time to `accumulator` and
// returns how many PHYSICS_DT steps to run now, plus `alpha` in [0, 1): how
// far the leftover time is into the next step (for interpolating what's
// drawn between the last two physics states).
fixed_steps :: proc "contextless" (accumulator: ^f64, frame_dt: f64) -> (steps: int, alpha: f64) {
	accumulator^ += min(frame_dt, MAX_FRAME_DT)
	for accumulator^ >= PHYSICS_DT {
		accumulator^ -= PHYSICS_DT
		steps += 1
	}
	return steps, accumulator^ / PHYSICS_DT
}
