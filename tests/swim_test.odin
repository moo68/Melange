package tests

import "core:math"
import "core:testing"
import "melange:geom"
import "melange:world"

// A test pool: solid below Y = `floor` plus `cells`; every other cell below
// Y = `surface` is water, the top one lowered to world.FLUID_SURFACE (still
// water, like the sea). `top_override` > 0 replaces that lowered height
// (shallow-water tests).
Pool :: struct {
	using scene:  Scene,
	surface:      i32,
	top_override: f64,
}

pool_solid :: proc(p: ^Pool, c: [3]i32) -> bool {
	return scene_solid(&p.scene, c)
}

pool_fluid :: proc(p: ^Pool, c: [3]i32) -> f64 {
	if c.y >= p.surface || scene_solid(&p.scene, c) {
		return 0
	}
	if c.y == p.surface - 1 {
		return p.top_override if p.top_override > 0 else f64(world.FLUID_SURFACE)
	}
	return 1
}

// World Y of the pool's water surface.
pool_surface_y :: proc(p: ^Pool) -> f64 {
	return f64(p.surface - 1) + (p.top_override if p.top_override > 0 else f64(world.FLUID_SURFACE))
}

swim :: proc(b: ^geom.Body, input: geom.Body_Input, seconds: f64, p: ^Pool) -> (min_y, max_y: f64) {
	min_y, max_y = b.position.y, b.position.y
	for _ in 0 ..< int(math.round(seconds / geom.PHYSICS_DT)) {
		geom.body_step(b, input, geom.PHYSICS_DT, p, pool_solid, pool_fluid)
		min_y = min(min_y, b.position.y)
		max_y = max(max_y, b.position.y)
	}
	return
}

@(test)
fluid_depth_follows_the_lowered_surface :: proc(t: ^testing.T) {
	p := Pool{scene = {floor = -20}, surface = 1} // water up to Y 0.875
	depth :: proc(p: ^Pool, feet_y: f64) -> f64 {
		return geom.fluid_depth(geom.body_box({0.5, feet_y, 0.5}), p, pool_fluid)
	}
	testing.expect_value(t, depth(&p, 0.875), 0) // touching the surface from above
	testing.expect_value(t, depth(&p, 0.9), 0)
	testing.expect(t, abs(depth(&p, 0.5) - 0.375) < 1e-12)
	testing.expect(t, abs(depth(&p, -0.5) - 1.375) < 1e-12) // two water cells, the lower one full
	testing.expect(t, abs(depth(&p, -5) - geom.BODY_HEIGHT) < 1e-12) // fully under: clamped to the box
	// Half-open cells: feet exactly on a cell boundary don't touch the cell below.
	dry := Pool{scene = {floor = -20}, surface = 0} // water up to Y -0.125
	testing.expect_value(t, depth(&dry, 0), 0)
}

@(test)
idle_bodies_sink_to_the_floor :: proc(t: ^testing.T) {
	p := Pool{scene = {floor = -20}, surface = 1}
	b := geom.Body{position = {0.5, -2, 0.5}}
	swim(&b, {}, 2, &p)
	testing.expect(t, abs(b.velocity.y + geom.SINK_SPEED) < 1e-3, "sinks at SINK_SPEED")
	swim(&b, {}, 15, &p)
	testing.expect(t, b.on_ground, "lands on the floor")
	testing.expect(t, abs(b.position.y - (-20 + geom.COLLISION_SKIN)) < 1e-9)
}

@(test)
crouching_sinks_faster :: proc(t: ^testing.T) {
	p := Pool{scene = {floor = -40}, surface = 1}
	b := geom.Body{position = {0.5, -2, 0.5}}
	swim(&b, {crouch = true}, 3, &p)
	testing.expect(t, abs(b.velocity.y + geom.CROUCH_SINK_SPEED) < 1e-3)
}

@(test)
jump_swims_up_and_treads_water :: proc(t: ^testing.T) {
	p := Pool{scene = {floor = -20}, surface = 1}
	b := geom.Body{position = {0.5, -15, 0.5}}
	swim(&b, {jump = true}, 2, &p)
	testing.expect(t, abs(b.velocity.y - geom.SWIM_UP_SPEED) < 1e-3, "rises at SWIM_UP_SPEED")
	swim(&b, {jump = true}, 10, &p) // reaches the surface
	// Then bobs: the feet travel between about BOB_LOW_DEPTH and
	// BOB_HIGH_DEPTH under the surface, slowly (not a jitter), never leaving
	// the water, the eye always well above it.
	surface := pool_surface_y(&p)
	lo, hi := b.position.y, b.position.y
	turns := 0
	prev_up := b.velocity.y > 0
	for _ in 0 ..< 600 { // 10 s
		swim(&b, {jump = true}, geom.PHYSICS_DT, &p)
		lo, hi = min(lo, b.position.y), max(hi, b.position.y)
		testing.expect(t, b.fluid_depth > 0, "still in the water")
		if up := b.velocity.y > 0; up != prev_up {
			turns += 1
			prev_up = up
		}
	}
	testing.expectf(t, hi - lo > 0.4, "bobs far enough: feet %v..%v", lo, hi)
	testing.expectf(t, surface - hi > geom.BOB_HIGH_DEPTH - 0.2 && surface - lo < geom.BOB_LOW_DEPTH + 0.2, "around the band: feet %v..%v", lo, hi)
	testing.expectf(t, turns >= 12 && turns <= 24, "a ~1 s rhythm: %d turns in 10 s", turns)
	testing.expect(t, lo + geom.EYE_HEIGHT > surface + 0.8, "eye above the surface")
}

@(test)
swimming_is_slow_and_sprint_does_nothing :: proc(t: ^testing.T) {
	p := Pool{scene = {floor = -20}, surface = 1}
	b := geom.Body{position = {0.5, -10, 0.5}}
	swim(&b, {wish = {1, 0}, sprint = true, jump = true}, 3, &p)
	testing.expect(t, abs(horizontal_speed(&b) - geom.SWIM_SPEED) < 1e-3)
	// Walking on the floor of a pool is just as slow.
	floor := geom.Body{position = {0.5, -20 + geom.COLLISION_SKIN, 0.5}, on_ground = true}
	swim(&floor, {wish = {0, 1}}, 3, &p)
	testing.expect(t, floor.on_ground)
	testing.expect(t, abs(horizontal_speed(&floor) - geom.SWIM_SPEED) < 1e-3)
}

// Hitting the water at speed v, drag takes the body down about
// (v - SINK_SPEED) / WATER_CONTROL blocks (13 at terminal speed, 60 b/s)
// before it's back near SINK_SPEED, plus ~1.5 while the rest decays: about
// the depth of a typical ocean (p10 13, p50 16). No fall damage anyway.
@(test)
water_breaks_a_long_fall :: proc(t: ^testing.T) {
	p := Pool{scene = {floor = -30}, surface = 1}
	b := geom.Body{position = {0.5, 200, 0.5}} // reaches terminal speed
	min_y: f64
	for b.position.y > 0.875 || b.velocity.y < -2 * geom.SINK_SPEED {
		lo, _ := swim(&b, {}, geom.PHYSICS_DT, &p)
		min_y = lo
		if b.on_ground {
			break
		}
	}
	testing.expect(t, !b.on_ground, "slowed before hitting the floor")
	fast := (geom.TERMINAL_FALL - geom.SINK_SPEED) / geom.WATER_CONTROL
	testing.expectf(t, min_y > 0.875 - fast - 2 && min_y < 0.875 - fast, "down %.1f..%.1f blocks (at %v)", fast, fast + 2, min_y)
}

// A pool ending in a shore at x ≥ 3 whose top is `height` blocks above the
// water's top cell (0 = level with it: top 0.125 above the surface).
ledge_pool :: proc(cells: ^[dynamic][3]i32, height: i32) -> Pool {
	for x in i32(3) ..< 12 {
		for y in i32(-5) ..< 1 + height {
			for z in i32(-3) ..= 3 {
				append(cells, [3]i32{x, y, z})
			}
		}
	}
	return {scene = {floor = -5, cells = cells[:]}, surface = 1}
}

@(test)
swimmers_climb_out_level_with_the_water_not_a_block_above :: proc(t: ^testing.T) {
	for height in i32(0) ..= 1 {
		cells: [dynamic][3]i32
		defer delete(cells)
		p := ledge_pool(&cells, height)
		b := geom.Body{position = {1.5, -1, 0.5}}
		swim(&b, {jump = true}, 3, &p) // tread at the surface
		swim(&b, {wish = {1, 0}, jump = true}, 3, &p)
		swim(&b, {}, 1, &p) // let go (held jump re-jumps on landing)
		on_top := b.on_ground && b.position.x > 3 && abs(b.position.y - f64(1 + height) - geom.COLLISION_SKIN) < 1e-6
		testing.expectf(t, on_top == (height == 0), "ledge %d: climbed out = %v (at %v)", height, on_top, b.position)
	}
}

// The exit jump clears a half block on top of the water's block (top 1.5,
// 0.625 above the surface) but not a full one (2.0).
@(test)
exit_jump_reaches_half_a_block :: proc(t: ^testing.T) {
	cells: [dynamic][3]i32
	defer delete(cells)
	p := ledge_pool(&cells, 3) // too tall to climb: just measure the peak
	b := geom.Body{position = {1.5, -1, 0.5}}
	swim(&b, {jump = true}, 3, &p)
	_, peak := swim(&b, {wish = {1, 0}, jump = true}, 3, &p)
	testing.expectf(t, peak > 1.6 && peak < 1.9, "feet peak at %v", peak)
}

@(test)
underwater_walls_cant_be_climbed :: proc(t: ^testing.T) {
	cells: [dynamic][3]i32
	defer delete(cells)
	p := ledge_pool(&cells, 1)
	p.scene.floor = -30
	for y in i32(-30) ..< -5 {
		for z in i32(-3) ..= 3 {
			append(&cells, [3]i32{3, y, z})
		}
	}
	p.scene.cells = cells[:]
	b := geom.Body{position = {2.0, -25, 0.5}}
	for _ in 0 ..< 600 {
		swim(&b, {wish = {1, 0}, jump = true}, geom.PHYSICS_DT, &p)
		if b.position.y + geom.WATER_EXIT_CHECK + geom.BODY_HEIGHT < pool_surface_y(&p) {
			testing.expect(t, b.velocity.y <= geom.SWIM_UP_SPEED + 1e-9, "only swims up deep under water")
		}
	}
}

@(test)
wading_jumps_normally_in_shallow_water :: proc(t: ^testing.T) {
	// Water only 0.3 deep over the floor: shallower than BOB_LOW_DEPTH.
	p := Pool{scene = {floor = 0}, surface = 1, top_override = 0.3}
	b := geom.Body{position = {0.5, geom.COLLISION_SKIN, 0.5}, on_ground = true}
	_, hi := swim(&b, {jump = true}, geom.PHYSICS_DT * 4, &p)
	testing.expect(t, hi > 0.1, "jumped")
	testing.expect(t, b.velocity.y > geom.SWIM_UP_SPEED, "a real jump, not swimming")
}

@(test)
crouching_in_water_walks_off_edges :: proc(t: ^testing.T) {
	cells: [dynamic][3]i32
	defer delete(cells)
	platform(&cells, 0, 0, -3) // 3×3 top at Y -2, deep under water
	p := Pool{scene = {floor = -30, cells = cells[:]}, surface = 1}
	b := geom.Body{position = {1.5, -2 + geom.COLLISION_SKIN, 1.5}, on_ground = true}
	swim(&b, {wish = {1, 0}, crouch = true}, 4, &p)
	testing.expect(t, b.position.y < -3, "no edge guard in water")
}

@(test)
body_sinks_and_swims_up_in_a_generated_ocean :: proc(t: ^testing.T) {
	w: world.World
	world.world_init(&w, 1337)
	defer world.world_destroy(&w)

	// A column at least 12 blocks under the sea, along +x from the origin.
	x: i32 = 0
	for world.terrain_height(w.seed, x, 0) > world.TERRAIN_SEA_LEVEL - 12 {
		x += 16
		if x > 100_000 {
			testing.fail_now(t, "no deep ocean found")
		}
	}
	floor := world.terrain_height(w.seed, x, 0)
	s: world.Streamer
	world.streamer_init(&s, {radius = 2, vertical = 3, unload_margin = 1, load_budget = 1000, unload_budget = 1000})
	defer world.streamer_destroy(&s)
	world.streamer_update(&s, &w, world.block_to_chunk({x, (floor + world.TERRAIN_SEA_LEVEL) / 2, 0}))

	b := geom.Body{position = {f64(x) + 0.5, f64(world.TERRAIN_SEA_LEVEL) - 1, 0.5}}
	step :: proc(b: ^geom.Body, input: geom.Body_Input, seconds: f64, w: ^world.World) {
		for _ in 0 ..< int(seconds * 60) {
			geom.body_step(b, input, geom.PHYSICS_DT, w, world.world_blocks_movement, world.world_fluid_top)
		}
	}
	step(&b, {}, 15, &w)
	testing.expect(t, b.on_ground, "sank to the seabed")
	testing.expectf(t, b.position.y < f64(floor) + 2, "near the floor at %d: %v", floor, b.position)
	step(&b, {jump = true}, 15, &w)
	surface := f64(world.TERRAIN_SEA_LEVEL) + f64(world.FLUID_SURFACE)
	depth := surface - b.position.y
	testing.expectf(t, depth > geom.BOB_HIGH_DEPTH - 0.2 && depth < geom.BOB_LOW_DEPTH + 0.2, "treading at the surface: %v", b.position)
	testing.expect(t, world.world_fluid_top(&w, {x, world.TERRAIN_SEA_LEVEL, 0}) == f64(world.FLUID_SURFACE))
	testing.expect(t, world.world_fluid_top(&w, {x, world.TERRAIN_SEA_LEVEL - 1, 0}) == 1)
	testing.expect(t, world.world_fluid_top(&w, {x, world.TERRAIN_SEA_LEVEL + 1, 0}) == 0)
}

// Every water entry starts the same: the bob state doesn't carry over from
// the last swim (e.g. after leaving the water mid-rise).
@(test)
leaving_the_water_resets_the_bob :: proc(t: ^testing.T) {
	p := Pool{scene = {floor = -20}, surface = 1}
	b := geom.Body{position = {0.5, 3, 0.5}, swim_rising = true} // above the water
	swim(&b, {jump = true}, geom.PHYSICS_DT, &p)
	testing.expect(t, !b.swim_rising, "reset out of the water")
	// Falling in with jump held: sinks to BOB_LOW_DEPTH before swimming up.
	for b.fluid_depth == 0 || b.velocity.y < 0 {
		swim(&b, {jump = true}, geom.PHYSICS_DT, &p)
		testing.expect(t, b.swim_rising || b.fluid_depth < geom.BOB_LOW_DEPTH + 0.1)
	}
	testing.expect(t, b.fluid_depth >= geom.BOB_LOW_DEPTH)
}
