package geom

// @(require): only used inside parametric procs, which builds that never
// instantiate them (tools/terrainviz) would otherwise flag as unused imports.
@(require) import "core:math"
@(require) import "core:math/linalg"

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

// Water (Minecraft's per-tick numbers as rates): velocity approaches the
// target by 1 - exp(-WATER_CONTROL * dt) on all three axes, i.e. Minecraft's
// ×0.8 drag per 20 Hz tick (20·ln 1.25 ≈ 4.46/s, 95% in 0.67 s). Gravity is
// folded into the vertical target: idle bodies sink. No sprint in water.
WATER_CONTROL      :: 4.46 // per second
SWIM_SPEED         :: 2.0 // horizontal, blocks per second
SINK_SPEED         :: 2.0 // idle
CROUCH_SINK_SPEED  :: 4.0 // crouch held
SWIM_UP_SPEED      :: 2.0 // jump held
// Treading water (jump held) bobs: swim up until the feet are only
// BOB_HIGH_DEPTH under the surface, then stop swimming (sink) until they're
// BOB_LOW_DEPTH deep, then swim up again (Body.swim_rising). Feet travel
// ~0.5 blocks every ~1.1 s, the eye 0.9–1.4 above the water. One threshold
// instead (no hysteresis) jitters: 0.06 blocks, 3.6 times a second.
BOB_HIGH_DEPTH     :: 0.3
BOB_LOW_DEPTH      :: 0.6
// Climbing out: in water, jump held and pushing against a wall, if the box
// raised by this much is out of the fluid (near the surface, so no climbing
// underwater walls), vertical speed becomes WATER_EXIT_SPEED. Reapplied each
// step until the body leaves the water.
WATER_EXIT_CHECK   :: 0.6
// The feet peak at 1.74 over the water's block (0.86 above the surface;
// measured): onto a half block on top of it (1.5), not a full one (2.0).
WATER_EXIT_SPEED   :: 7.0

// One fixed physics step (60 Hz); see fixed_steps.
PHYSICS_DT :: 1.0 / 60.0
// Longest frame time fed to physics; a longer hitch just slows the world
// down instead of running dozens of catch-up steps.
MAX_FRAME_DT :: 0.25

Body :: struct {
	position:  [3]f64, // feet: bottom center of the box
	velocity:  [3]f64,
	on_ground: bool, // standing on something after the last step
	// How deep the feet were in fluid at the start of the last step (0 = not
	// in water; at most BODY_HEIGHT). See fluid_depth.
	fluid_depth: f64,
	swim_rising: bool, // treading water: swimming up (see BOB_HIGH_DEPTH)
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

// How deep box `b`'s bottom is in fluid: the highest fluid surface among the
// cells it overlaps (`fluid_top` = the fluid's top within a cell, 0..1, or 0
// for none) minus b.min.y, clamped to [0, box height]. 0 = not in fluid.
fluid_depth :: proc(b: AABB, data: $T, fluid_top: proc(data: T, cell: [3]i32) -> f64) -> f64 {
	x0, x1 := cell_range(b, 0)
	y0, y1 := cell_range(b, 1)
	z0, z1 := cell_range(b, 2)
	depth := 0.0
	for y in y0 ..= y1 {
		for z in z0 ..= z1 {
			for x in x0 ..= x1 {
				if top := fluid_top(data, {x, y, z}); top > 0 {
					depth = max(depth, f64(y) + top - b.min.y)
				}
			}
		}
	}
	return clamp(depth, 0, b.max.y - b.min.y)
}

// Whether point `p` is inside fluid: its cell holds fluid (`fluid_top` > 0,
// see fluid_depth) and p is below that fluid's top. Used for the camera eye
// (underwater fog). A point exactly on the lowered surface is above it.
point_in_fluid :: proc(p: [3]f64, data: $T, fluid_top: proc(data: T, cell: [3]i32) -> f64) -> bool {
	cell := [3]i32{i32(math.floor(p.x)), i32(math.floor(p.y)), i32(math.floor(p.z))}
	top := fluid_top(data, cell)
	return top > 0 && p.y - f64(cell.y) < top
}

// Advances the body by `dt` seconds. `fluid_top` (optional; nil = no fluid
// anywhere) gives a cell's fluid height, see fluid_depth; in fluid the body
// swims (see WATER_CONTROL).
body_step :: proc(
	b: ^Body,
	input: Body_Input,
	dt: f64,
	data: $T,
	is_solid: proc(data: T, cell: [3]i32) -> bool,
	fluid_top: proc(data: T, cell: [3]i32) -> f64 = nil,
) {
	wish := input.wish
	if l := linalg.length(wish); l > 1 {
		wish /= l
	}
	b.fluid_depth = fluid_depth(body_box(b.position), data, fluid_top) if fluid_top != nil else 0
	if b.fluid_depth > 0 {
		swim_step(b, input, wish, dt, data, is_solid, fluid_top)
		return
	}
	b.swim_rising = false
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

// One step in water (b.fluid_depth > 0); see WATER_CONTROL.
@(private)
swim_step :: proc(
	b: ^Body,
	input: Body_Input,
	wish: [2]f64,
	dt: f64,
	data: $T,
	is_solid: proc(data: T, cell: [3]i32) -> bool,
	fluid_top: proc(data: T, cell: [3]i32) -> f64,
) {
	response := 1 - math.exp(-WATER_CONTROL * dt)
	target := wish * SWIM_SPEED
	b.velocity.x += (target.x - b.velocity.x) * response
	b.velocity.z += (target.y - b.velocity.z) * response

	if b.swim_rising && b.fluid_depth <= BOB_HIGH_DEPTH {
		b.swim_rising = false
	} else if !b.swim_rising && b.fluid_depth >= BOB_LOW_DEPTH {
		b.swim_rising = true
	}
	v0 := b.velocity.y
	if input.jump && b.on_ground && b.fluid_depth < BOB_LOW_DEPTH {
		v0 = JUMP_SPEED // wading: a normal jump
	}
	target_y := -SINK_SPEED
	if input.jump && b.swim_rising {
		target_y = SWIM_UP_SPEED
	} else if input.crouch {
		target_y = -CROUCH_SINK_SPEED
	}
	v1 := v0 + (target_y - v0) * response
	b.velocity.y = v1
	delta := [3]f64{b.velocity.x * dt, (v0 + v1) / 2 * dt, b.velocity.z * dt}

	box := body_box(b.position)
	moved, blocked := move_aabb(box, delta, data, is_solid) // no edge guard in water
	b.position += moved
	for axis in 0 ..< 3 {
		if blocked[axis] {
			b.velocity[axis] = 0
		}
	}
	b.on_ground = blocked.y && delta.y < 0

	// Climbing out onto a ledge: pushing into a wall near the surface.
	if input.jump && (blocked.x || blocked.z) {
		raised := body_box(b.position + {0, WATER_EXIT_CHECK, 0})
		if fluid_depth(raised, data, fluid_top) == 0 {
			b.velocity.y = WATER_EXIT_SPEED
		}
	}
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
