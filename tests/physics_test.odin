package tests

import "core:math"
import "core:math/linalg"
import "core:testing"
import "melange:geom"
import "melange:world"

// A test world: solid below Y = `floor` (top floor block at floor - 1) plus
// any extra cells.
Scene :: struct {
	floor: i32,
	cells: [][3]i32,
}

scene_solid :: proc(s: ^Scene, c: [3]i32) -> bool {
	return c.y < s.floor || in_cells(s.cells, c)
}

// Feet standing on the floor (skin above it) at (x, z).
standing :: proc(s: ^Scene, x, z: f64) -> geom.Body {
	return {position = {x, f64(s.floor) + geom.COLLISION_SKIN, z}, on_ground = true}
}

// Runs `seconds` of fixed steps; returns the highest feet Y reached.
simulate :: proc(b: ^geom.Body, input: geom.Body_Input, seconds: f64, s: ^Scene) -> (max_y: f64) {
	max_y = b.position.y
	for _ in 0 ..< int(math.round(seconds / geom.PHYSICS_DT)) {
		geom.body_step(b, input, geom.PHYSICS_DT, s, scene_solid)
		max_y = max(max_y, b.position.y)
	}
	return
}

horizontal_speed :: proc(b: ^geom.Body) -> f64 {
	return linalg.length([2]f64{b.velocity.x, b.velocity.z})
}

// ---- Sweeps ---------------------------------------------------------------------

@(test)
sweep_stops_a_skin_short_of_a_wall :: proc(t: ^testing.T) {
	s := Scene{floor = -100, cells = {{3, 0, 0}}}
	box := geom.AABB{{0.2, 0.1, 0.2}, {0.8, 0.9, 0.8}}
	moved, blocked := geom.sweep_axis(box, 0, 5, &s, scene_solid)
	testing.expect(t, blocked)
	testing.expect(t, abs(moved - (3 - 0.8 - geom.COLLISION_SKIN)) < 1e-12)

	// The same wall from the other side, moving -x.
	far := geom.AABB{{5.2, 0.1, 0.2}, {5.8, 0.9, 0.8}}
	moved, blocked = geom.sweep_axis(far, 0, -5, &s, scene_solid)
	testing.expect(t, blocked)
	testing.expect(t, abs(moved - (4 - 5.2 + geom.COLLISION_SKIN)) < 1e-12)

	// Nothing in the way (wall is in another row): full move.
	off := geom.AABB{{0.2, 0.1, 1.2}, {0.8, 0.9, 1.8}}
	moved, blocked = geom.sweep_axis(off, 0, 5, &s, scene_solid)
	testing.expect(t, !blocked)
	testing.expect_value(t, moved, 5)
}

@(test)
sweep_never_tunnels :: proc(t: ^testing.T) {
	// A 1-block floor at Y = 0 and a fall of 100 blocks in one sweep.
	s := Scene{floor = -1000, cells = {{0, 0, 0}}}
	box := geom.AABB{{0.2, 100, 0.2}, {0.8, 101.8, 0.8}}
	moved, blocked := geom.sweep_axis(box, 1, -100, &s, scene_solid)
	testing.expect(t, blocked)
	testing.expect(t, abs(box.min.y + moved - (1 + geom.COLLISION_SKIN)) < 1e-9)
}

@(test)
sweep_ignores_cells_already_overlapped :: proc(t: ^testing.T) {
	// Stuck inside a block, the box can still move out of it.
	s := Scene{floor = -100, cells = {{0, 0, 0}}}
	box := geom.AABB{{0.2, 0.2, 0.2}, {0.8, 0.8, 0.8}}
	moved, blocked := geom.sweep_axis(box, 0, 2, &s, scene_solid)
	testing.expect(t, !blocked)
	testing.expect_value(t, moved, 2)
}

@(test)
sweep_treats_cells_as_half_open :: proc(t: ^testing.T) {
	// The box's max x is exactly 5.0: it touches cell 5's face but doesn't
	// overlap it, so sliding along z isn't blocked by a block at x = 5.
	s := Scene{floor = -100, cells = {{5, 0, 1}}}
	box := geom.AABB{{4.4, 0.1, 0.2}, {5.0, 0.9, 0.8}}
	moved, blocked := geom.sweep_axis(box, 2, 2, &s, scene_solid)
	testing.expect(t, !blocked)
	testing.expect_value(t, moved, 2)
}

@(test)
move_slides_along_a_wall :: proc(t: ^testing.T) {
	// A wall at x = 2 (all z); moving diagonally +x+z keeps the z motion.
	cells: [dynamic][3]i32
	defer delete(cells)
	for z in i32(-5) ..= 10 {
		append(&cells, [3]i32{2, 0, z}, [3]i32{2, 1, z})
	}
	s := Scene{floor = 0, cells = cells[:]}
	b := standing(&s, 0.5, 0.5)
	moved, blocked := geom.move_aabb(geom.body_box(b.position), {3, 0, 3}, &s, scene_solid)
	testing.expect(t, blocked.x && !blocked.z)
	testing.expect_value(t, moved.z, 3)
	testing.expect(t, abs(b.position.x + moved.x - (2 - 0.3 - geom.COLLISION_SKIN)) < 1e-9)
}

// ---- Bodies ---------------------------------------------------------------------

@(test)
body_falls_and_lands :: proc(t: ^testing.T) {
	s := Scene{floor = 32}
	b := geom.Body{position = {0.5, 40, 0.5}}
	simulate(&b, {}, 3, &s)
	testing.expect(t, b.on_ground)
	testing.expect(t, abs(b.position.y - (32 + geom.COLLISION_SKIN)) < 1e-9)
	testing.expect_value(t, b.velocity.y, 0)
}

@(test)
falling_reaches_terminal_speed :: proc(t: ^testing.T) {
	s := Scene{floor = -100_000}
	b := geom.Body{position = {0.5, 1000, 0.5}}
	simulate(&b, {}, 3, &s) // 32 b/s² reaches 60 b/s in under 2 s
	testing.expect_value(t, b.velocity.y, -geom.TERMINAL_FALL)
}

@(test)
jump_rises_one_and_a_quarter_blocks :: proc(t: ^testing.T) {
	s := Scene{floor = 32}
	b := standing(&s, 0.5, 0.5)
	start := b.position.y
	geom.body_step(&b, {jump = true}, geom.PHYSICS_DT, &s, scene_solid)
	apex := simulate(&b, {}, 2, &s)
	testing.expectf(t, abs(apex - start - 1.25) < 0.01, "jump height %v", apex - start)
	testing.expect(t, b.on_ground, "lands again")
}

@(test)
no_jumping_in_mid_air :: proc(t: ^testing.T) {
	s := Scene{floor = 0}
	b := geom.Body{position = {0.5, 20, 0.5}}
	geom.body_step(&b, {jump = true}, geom.PHYSICS_DT, &s, scene_solid)
	testing.expect(t, b.velocity.y < 0, "still falling")
}

@(test)
holding_jump_jumps_again_on_landing :: proc(t: ^testing.T) {
	s := Scene{floor = 32}
	b := standing(&s, 0.5, 0.5)
	takeoffs := 0
	for _ in 0 ..< 180 { 	// 3 s; one jump lasts ~0.56 s
		was_on_ground := b.on_ground
		geom.body_step(&b, {jump = true}, geom.PHYSICS_DT, &s, scene_solid)
		takeoffs += int(was_on_ground && !b.on_ground)
	}
	testing.expectf(t, takeoffs >= 4, "takeoffs %d", takeoffs)
}

@(test)
ceiling_stops_a_jump :: proc(t: ^testing.T) {
	// 2.5 blocks of headroom over a 1.8-tall body: 0.7 to spare, less than 1.25.
	cells: [dynamic][3]i32
	defer delete(cells)
	for x in i32(-1) ..= 1 {
		for z in i32(-1) ..= 1 {
			append(&cells, [3]i32{x, 34, z}) // ceiling's underside at Y = 34
		}
	}
	s := Scene{floor = 32, cells = cells[:]}
	b := standing(&s, 0.5, 0.5)
	geom.body_step(&b, {jump = true}, geom.PHYSICS_DT, &s, scene_solid)
	apex := b.position.y
	bumped := false
	for _ in 0 ..< 60 {
		rising := b.velocity.y > 0
		geom.body_step(&b, {jump = true}, geom.PHYSICS_DT, &s, scene_solid) // jump held throughout
		apex = max(apex, b.position.y)
		if rising && b.velocity.y == 0 {
			bumped = true
			testing.expect(t, !b.on_ground, "a ceiling bump isn't landing (no jumping off ceilings)")
		}
	}
	testing.expect(t, bumped)
	testing.expect(t, abs(apex + geom.BODY_HEIGHT - (34 - geom.COLLISION_SKIN)) < 1e-9, "head stops at the ceiling")
}

@(test)
vertical_motion_resolves_before_horizontal :: proc(t: ^testing.T) {
	// Like Minecraft: Y moves first. Falling past a ledge's edge in one step
	// drops the body below the ledge's top, so it hits the ledge's side
	// instead of sliding over and snapping onto it.
	cells: [dynamic][3]i32
	defer delete(cells)
	for z in i32(-2) ..= 2 {
		append(&cells, [3]i32{2, 0, z}) // ledge: top at Y = 1, side at x = 2
	}
	s := Scene{floor = -10, cells = cells[:]}
	box := geom.body_box({1.65, 1.05, 0.5}) // x 1.35..1.95, feet just above the ledge top
	moved, blocked := geom.move_aabb(box, {0.5, -0.1, 0}, &s, scene_solid)
	testing.expect(t, !blocked.y && blocked.x, "fell past the top, then hit the side")
	testing.expect(t, abs(moved.y + 0.1) < 1e-12)
}

@(test)
walking_reaches_walk_and_sprint_speed :: proc(t: ^testing.T) {
	s := Scene{floor = 0}
	b := standing(&s, 0.5, 0.5)
	simulate(&b, {wish = {1, 0}}, 1, &s)
	testing.expect(t, abs(horizontal_speed(&b) - geom.WALK_SPEED) < 1e-3, "walk")
	// Diagonal input isn't faster.
	b = standing(&s, 0.5, 0.5)
	simulate(&b, {wish = {1, 1}}, 1, &s)
	testing.expect(t, abs(horizontal_speed(&b) - geom.WALK_SPEED) < 1e-3, "diagonal walk")
	b = standing(&s, 0.5, 0.5)
	simulate(&b, {wish = {0, -1}, sprint = true}, 1, &s)
	testing.expect(t, abs(horizontal_speed(&b) - geom.SPRINT_SPEED) < 1e-3, "sprint")
	// Ground control is snappy: 95% of walk speed within 0.15 s.
	b = standing(&s, 0.5, 0.5)
	simulate(&b, {wish = {1, 0}}, 0.15, &s)
	testing.expect(t, horizontal_speed(&b) > 0.95 * geom.WALK_SPEED, "snappy start")
}

@(test)
air_control_keeps_momentum :: proc(t: ^testing.T) {
	s := Scene{floor = 0}
	b := standing(&s, 0.5, 0.5)
	simulate(&b, {wish = {1, 0}, sprint = true}, 1, &s)
	geom.body_step(&b, {wish = {1, 0}, sprint = true, jump = true}, geom.PHYSICS_DT, &s, scene_solid)
	// Let go mid-air: speed decays slowly (on the ground it'd be ~gone).
	simulate(&b, {}, 0.3, &s)
	testing.expect(t, !b.on_ground)
	testing.expectf(t, horizontal_speed(&b) > 0.5 * geom.SPRINT_SPEED, "air speed %v", horizontal_speed(&b))
}

// Walls on both sides of the corridor z = 0, along x, `height` blocks tall
// before a ceiling; the corridor starts at x = 2.
corridor :: proc(cells: ^[dynamic][3]i32, height: i32) {
	for x in i32(2) ..= 8 {
		for y in i32(0) ..= height {
			append(cells, [3]i32{x, y, -1}, [3]i32{x, y, 1})
		}
		append(cells, [3]i32{x, height, 0}) // ceiling
	}
}

@(test)
body_fits_a_two_tall_gap_but_not_one :: proc(t: ^testing.T) {
	two: [dynamic][3]i32
	defer delete(two)
	corridor(&two, 2)
	s := Scene{floor = 0, cells = two[:]}
	b := standing(&s, 0.5, 0.5)
	simulate(&b, {wish = {1, 0}}, 2, &s)
	testing.expectf(t, b.position.x > 6, "walked through the 2-tall gap: x %v", b.position.x)

	one: [dynamic][3]i32
	defer delete(one)
	corridor(&one, 1)
	s = Scene{floor = 0, cells = one[:]}
	b = standing(&s, 0.5, 0.5)
	simulate(&b, {wish = {1, 0}}, 2, &s)
	testing.expect(t, abs(b.position.x - (2 - 0.3 - geom.COLLISION_SKIN)) < 1e-9, "stopped at the 1-tall gap")
}

@(test)
jump_clears_one_block_steps_not_two :: proc(t: ^testing.T) {
	step: [dynamic][3]i32
	defer delete(step)
	for x in i32(2) ..= 10 {
		for z in i32(-3) ..= 3 {
			append(&step, [3]i32{x, 0, z})
		}
	}
	s := Scene{floor = 0, cells = step[:]}
	b := standing(&s, 0.5, 0.5)
	simulate(&b, {wish = {1, 0}, jump = true}, 2, &s)
	testing.expectf(t, b.position.x > 3 && b.position.y > 1, "on top of the 1-block step: %v", b.position)

	wall: [dynamic][3]i32
	defer delete(wall)
	for x in i32(2) ..= 10 {
		for z in i32(-3) ..= 3 {
			append(&wall, [3]i32{x, 0, z}, [3]i32{x, 1, z})
		}
	}
	s = Scene{floor = 0, cells = wall[:]}
	b = standing(&s, 0.5, 0.5)
	simulate(&b, {wish = {1, 0}, jump = true}, 2, &s)
	testing.expectf(t, b.position.x < 2, "a 2-block step stops it: %v", b.position)
}

@(test)
standing_works_far_from_the_origin :: proc(t: ^testing.T) {
	// f64 positions: at x = 1,000,000 an f32 couldn't resolve the skin.
	s := Scene{floor = 64}
	b := standing(&s, 1_000_000.5, -1_000_000.5)
	simulate(&b, {wish = {1, 0}}, 2, &s)
	testing.expect(t, b.on_ground)
	testing.expect(t, abs(b.position.y - (64 + geom.COLLISION_SKIN)) < 1e-6)
}

// ---- Fixed steps ------------------------------------------------------------------

@(test)
fixed_steps_add_up_whatever_the_frame_times :: proc(t: ^testing.T) {
	frame_patterns := [?][]f64{{1.0 / 240}, {1.0 / 60}, {1.0 / 144, 1.0 / 30, 0.002}}
	positions: [len(frame_patterns)][3]f64
	for pattern, i in frame_patterns {
		s := Scene{floor = 0}
		b := standing(&s, 0.5, 0.5)
		acc: f64
		steps_total, elapsed := 0, 0.0
		for f := 0; elapsed < 2.0 - 1e-9; f += 1 {
			dt := pattern[f % len(pattern)]
			dt = min(dt, 2.0 - elapsed)
			elapsed += dt
			steps, alpha := geom.fixed_steps(&acc, dt)
			testing.expect(t, alpha >= 0 && alpha < 1, "alpha in [0, 1)")
			for _ in 0 ..< steps {
				geom.body_step(&b, {wish = {0.6, 0.8}, jump = true}, geom.PHYSICS_DT, &s, scene_solid)
			}
			steps_total += steps
		}
		testing.expectf(t, steps_total == 120 || steps_total == 119, "pattern %d: %d steps in 2 s", i, steps_total)
		// Top up to exactly 120 steps so all patterns compare the same span.
		for _ in steps_total ..< 120 {
			geom.body_step(&b, {wish = {0.6, 0.8}, jump = true}, geom.PHYSICS_DT, &s, scene_solid)
		}
		positions[i] = b.position
	}
	testing.expect_value(t, positions[1], positions[0])
	testing.expect_value(t, positions[2], positions[0])
}

@(test)
fixed_steps_cap_long_frames :: proc(t: ^testing.T) {
	acc: f64
	steps, _ := geom.fixed_steps(&acc, 1.0) // a 1-second hitch
	testing.expect_value(t, steps, 15) // MAX_FRAME_DT = 0.25 s worth
}

@(test)
free_lift_finds_room_above :: proc(t: ^testing.T) {
	s := Scene{floor = 32}
	inside := geom.body_box({0.5, 30.5, 0.5}) // feet 1.5 blocks into the ground
	lift, ok := geom.find_free_lift(inside, 128, &s, scene_solid)
	testing.expect(t, ok)
	testing.expect(t, abs(30.5 + lift - (32 + geom.COLLISION_SKIN)) < 1e-9, "feet just on top")

	lift, ok = geom.find_free_lift(geom.body_box({0.5, 40, 0.5}), 128, &s, scene_solid)
	testing.expect(t, ok && lift == 0, "already free: stays put")

	_, ok = geom.find_free_lift(geom.body_box({0.5, -500, 0.5}), 128, &s, scene_solid)
	testing.expect(t, !ok, "no room within the search")
}

// ---- On real terrain ----------------------------------------------------------------

@(test)
body_stands_and_walks_on_generated_terrain :: proc(t: ^testing.T) {
	w: world.World
	world.world_init(&w, 1337)
	defer world.world_destroy(&w)
	s: world.Streamer
	world.streamer_init(&s, {radius = 3, vertical = 3, unload_margin = 1, load_budget = 1000, unload_budget = 1000})
	defer world.streamer_destroy(&s)

	// Spawn like player_spawn: on top of the column's surface block.
	surface := world.terrain_height(w.seed, 0, 0)
	b := geom.Body{position = {0.5, f64(surface + 1) + geom.COLLISION_SKIN, 0.5}}
	world.streamer_update(&s, &w, world.block_to_chunk({0, surface, 0}))

	// Standing still: lands immediately and stays exactly there.
	for _ in 0 ..< 120 {
		geom.body_step(&b, {}, geom.PHYSICS_DT, &w, world.world_blocks_movement)
	}
	testing.expect(t, b.on_ground)
	testing.expect(t, abs(b.position.y - (f64(surface + 1) + geom.COLLISION_SKIN)) < 1e-9, "stands on the surface")

	// Walk (jump held, so 1-block plains steps are climbed) for 4 s.
	for _ in 0 ..< 240 {
		geom.body_step(&b, {wish = {1, 0.3}, jump = true}, geom.PHYSICS_DT, &w, world.world_blocks_movement)
	}
	// Then stand until landed, and check we're on top of real ground, not in it.
	for _ in 0 ..< 120 {
		geom.body_step(&b, {}, geom.PHYSICS_DT, &w, world.world_blocks_movement)
	}
	testing.expect(t, b.on_ground)
	testing.expectf(t, b.position.x > 5, "walked somewhere: %v", b.position)
	testing.expect(t, !geom.aabb_overlaps_solid(geom.body_box(b.position), &w, world.world_blocks_movement), "not inside terrain")
	under := [3]i32{i32(math.floor(b.position.x)), i32(math.floor(b.position.y)) - 1, i32(math.floor(b.position.z))}
	testing.expect(t, abs(b.position.y - f64(under.y + 1) - geom.COLLISION_SKIN) < 1e-9, "feet a skin above a block top")
}
