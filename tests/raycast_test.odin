package tests

import "core:math"
import "core:math/linalg"
import "core:math/rand"
import "core:testing"
import "melange:geom"

// Solid = one of these cells.
in_cells :: proc(cells: [][3]i32, c: [3]i32) -> bool {
	for s in cells {
		if s == c {
			return true
		}
	}
	return false
}

cast_cells :: proc(origin, dir: [3]f32, max_dist: f32, cells: [][3]i32) -> (geom.Ray_Hit, bool) {
	return geom.raycast_voxels(origin, dir, max_dist, cells, in_cells)
}

expect_hit :: proc(
	t: ^testing.T,
	hit: geom.Ray_Hit,
	ok: bool,
	block, normal: [3]i32,
	dist: f32,
	loc := #caller_location,
) {
	if !testing.expect(t, ok, "expected a hit", loc = loc) {
		return
	}
	testing.expect_value(t, hit.block, block, loc = loc)
	testing.expect_value(t, hit.normal, normal, loc = loc)
	testing.expectf(t, abs(hit.dist - dist) < 1e-5, "dist %v, want %v", hit.dist, dist, loc = loc)
}

@(test)
raycast_hits_along_each_axis :: proc(t: ^testing.T) {
	dirs := [6][3]i32{{1, 0, 0}, {-1, 0, 0}, {0, 1, 0}, {0, -1, 0}, {0, 0, 1}, {0, 0, -1}}
	for d in dirs {
		cells := [1][3]i32{d * 3}
		dir := [3]f32{f32(d.x), f32(d.y), f32(d.z)}
		hit, ok := cast_cells({0.5, 0.5, 0.5}, dir, 10, cells[:])
		// Enters the far cell's near face, 2.5 blocks away, facing back at us.
		expect_hit(t, hit, ok, d * 3, -d, 2.5)
	}
}

@(test)
raycast_floors_negative_coordinates :: proc(t: ^testing.T) {
	// -0.5 is in cell -1, not 0 (truncation would get this wrong).
	inside := [1][3]i32{{-1, 0, 0}}
	hit, ok := cast_cells({-0.5, 0.5, 0.5}, {1, 0, 0}, 10, inside[:])
	expect_hit(t, hit, ok, {-1, 0, 0}, {0, 0, 0}, 0)

	wall := [1][3]i32{{-4, -1, -2}}
	hit, ok = cast_cells({-0.5, -0.5, -1.5}, {-1, 0, 0}, 10, wall[:])
	expect_hit(t, hit, ok, {-4, -1, -2}, {1, 0, 0}, 2.5)
}

@(test)
raycast_respects_max_dist :: proc(t: ^testing.T) {
	wall := [1][3]i32{{5, 0, 0}}
	hit, ok := cast_cells({0.5, 0.5, 0.5}, {1, 0, 0}, 4.5, wall[:])
	expect_hit(t, hit, ok, {5, 0, 0}, {-1, 0, 0}, 4.5) // exactly at reach: hit
	_, ok = cast_cells({0.5, 0.5, 0.5}, {1, 0, 0}, 4.49, wall[:])
	testing.expect(t, !ok, "just out of reach")
}

@(test)
raycast_misses_in_empty_space :: proc(t: ^testing.T) {
	hit, ok := cast_cells({0.3, 0.7, -0.2}, {0.3, -0.5, 0.8}, 50, nil)
	testing.expect(t, !ok)
	testing.expect_value(t, hit, geom.Ray_Hit{})
}

@(test)
raycast_direction_need_not_be_normalized :: proc(t: ^testing.T) {
	wall := [1][3]i32{{0, 0, -3}}
	hit, ok := cast_cells({0.5, 0.5, 0.5}, {0, 0, -10}, 10, wall[:])
	expect_hit(t, hit, ok, {0, 0, -3}, {0, 0, 1}, 2.5)

	// Zero direction: only the origin's cell counts.
	_, ok = cast_cells({0.5, 0.5, 0.5}, {0, 0, 0}, 10, wall[:])
	testing.expect(t, !ok)
	here := [1][3]i32{{0, 0, 0}}
	hit, ok = cast_cells({0.5, 0.5, 0.5}, {0, 0, 0}, 10, here[:])
	expect_hit(t, hit, ok, {0, 0, 0}, {0, 0, 0}, 0)
}

@(test)
raycast_steps_x_first_through_exact_edges :: proc(t: ^testing.T) {
	// A 45° ray in the xy plane crosses x = 1 and y = 1 at the same point.
	// Ties go x, then y: it visits (1,0,0), never (0,1,0).
	edge_dist := f32(math.SQRT_TWO / 2)
	x_side := [1][3]i32{{1, 0, 0}}
	hit, ok := cast_cells({0.5, 0.5, 0.5}, {1, 1, 0}, 5, x_side[:])
	expect_hit(t, hit, ok, {1, 0, 0}, {-1, 0, 0}, edge_dist)

	y_side := [1][3]i32{{0, 1, 0}}
	_, ok = cast_cells({0.5, 0.5, 0.5}, {1, 1, 0}, 5, y_side[:])
	testing.expect(t, !ok, "the y-side cell is skipped on an exact tie")

	diagonal := [1][3]i32{{1, 1, 0}}
	hit, ok = cast_cells({0.5, 0.5, 0.5}, {1, 1, 0}, 5, diagonal[:])
	expect_hit(t, hit, ok, {1, 1, 0}, {0, -1, 0}, edge_dist) // entered via y, the last step
}

// Pseudo-random world, ~20% solid.
hashed_solid :: proc(_: int, c: [3]i32) -> bool {
	h := u32(c.x) * 73856093 ~ u32(c.y) * 19349663 ~ u32(c.z) * 83492791
	h ~= h >> 13
	h *= 0x5bd1e995
	h ~= h >> 15
	return h % 5 == 0
}

// Reference: exact ray/box (slab) intersection against every solid cell near
// the ray, keeping the nearest entry. Slow but independent of the traversal.
reference_cast :: proc(origin, dir: [3]f64, max_dist: f64) -> (hit: geom.Ray_Hit, second_best: f64, ok: bool) {
	best := math.INF_F64
	second_best = math.INF_F64
	lo := linalg.floor(origin - max_dist)
	hi := linalg.floor(origin + max_dist)
	for z := i32(lo.z); z <= i32(hi.z); z += 1 {
		for y := i32(lo.y); y <= i32(hi.y); y += 1 {
			for x := i32(lo.x); x <= i32(hi.x); x += 1 {
				c := [3]i32{x, y, z}
				if !hashed_solid(0, c) {
					continue
				}
				t_enter, t_exit := -math.INF_F64, math.INF_F64
				enter_axis := -1
				for axis in 0 ..< 3 {
					b0, b1 := f64(c[axis]), f64(c[axis] + 1)
					if dir[axis] == 0 {
						if origin[axis] < b0 || origin[axis] >= b1 {
							t_enter = math.INF_F64 // parallel and outside the slab
						}
						continue
					}
					t0, t1 := (b0 - origin[axis]) / dir[axis], (b1 - origin[axis]) / dir[axis]
					if t0 > t1 {
						t0, t1 = t1, t0
					}
					if t0 > t_enter {
						t_enter, enter_axis = t0, axis
					}
					t_exit = min(t_exit, t1)
				}
				if t_enter > t_exit || t_exit <= 0 || t_enter > max_dist {
					continue
				}
				entry := max(t_enter, 0)
				if entry < best {
					second_best = best
					best = entry
					hit = {block = c, dist = f32(entry)}
					hit.normal = {}
					if t_enter > 0 {
						hit.normal[enter_axis] = -1 if dir[enter_axis] > 0 else 1
					}
				} else {
					second_best = min(second_best, entry)
				}
			}
		}
	}
	return hit, second_best, best < math.INF_F64
}

@(test)
raycast_matches_reference_on_random_rays :: proc(t: ^testing.T) {
	RAYS :: 400
	hits, misses, inside := 0, 0, 0
	for _ in 0 ..< RAYS {
		origin := [3]f32{rand.float32_range(-40, 40), rand.float32_range(-40, 40), rand.float32_range(-40, 40)}
		dir := linalg.normalize([3]f32{rand.float32_range(-1, 1), rand.float32_range(-1, 1), rand.float32_range(-1, 1)})
		max_dist := rand.float32_range(0.5, 8)

		o64 := [3]f64{f64(origin.x), f64(origin.y), f64(origin.z)}
		d64 := [3]f64{f64(dir.x), f64(dir.y), f64(dir.z)}
		want, second, want_ok := reference_cast(o64, d64, f64(max_dist))
		// Skip rays too close to a tie (two cells entered at almost the same
		// distance) or to the reach limit: f32 vs f64 may legitimately differ.
		if want_ok && (second - f64(want.dist) < 1e-4 || f64(max_dist) - f64(want.dist) < 1e-4) {
			continue
		}

		got, got_ok := geom.raycast_voxels(origin, dir, max_dist, 0, hashed_solid)
		if !testing.expectf(t, got_ok == want_ok, "origin %v dir %v max %v: hit %v, reference %v (%v)", origin, dir, max_dist, got_ok, want_ok, want) {
			return
		}
		if !want_ok {
			misses += 1
			continue
		}
		if want.normal == {} {
			inside += 1
		} else {
			hits += 1
		}
		ok := testing.expectf(t, got.block == want.block && got.normal == want.normal && abs(got.dist - want.dist) < 1e-3, "origin %v dir %v: got %v, reference %v", origin, dir, got, want)
		if !ok {
			return
		}
	}
	// The random world must exercise all three outcomes.
	testing.expectf(t, hits > 100 && misses > 20 && inside > 20, "coverage: %d hits, %d misses, %d inside", hits, misses, inside)
}
