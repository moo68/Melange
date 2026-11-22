package geom

import "core:math"

// Axis-aligned box in world units. f64: physics positions must stay exact
// far from the origin (at x = 10,000 an f32 step is ~0.001, the size of
// COLLISION_SKIN, which would let boxes slip into blocks).
AABB :: struct {
	min, max: [3]f64,
}

// Gap kept between a moving box and any block it's stopped by, so rounding
// never leaves it overlapping that block.
COLLISION_SKIN :: 0.001

// Integer cells a box overlaps on `axis`, treating cells as half-open
// [c, c+1): a box whose max is exactly 5.0 does not touch cell 5.
@(private)
cell_range :: proc "contextless" (b: AABB, axis: int) -> (lo, hi: i32) {
	return i32(math.floor(b.min[axis])), i32(math.ceil(b.max[axis])) - 1
}

// Whether any cell overlapping `b` is solid.
aabb_overlaps_solid :: proc(b: AABB, data: $T, is_solid: proc(data: T, cell: [3]i32) -> bool) -> bool {
	x0, x1 := cell_range(b, 0)
	y0, y1 := cell_range(b, 1)
	z0, z1 := cell_range(b, 2)
	for y in y0 ..= y1 {
		for z in z0 ..= z1 {
			for x in x0 ..= x1 {
				if is_solid(data, {x, y, z}) {
					return true
				}
			}
		}
	}
	return false
}

// Whether box `b` overlaps cell `c` (a 1×1×1 block).
aabb_overlaps_cell :: proc "contextless" (b: AABB, c: [3]i32) -> bool {
	for axis in 0 ..< 3 {
		lo := f64(c[axis])
		if !(lo < b.max[axis] && lo + 1 > b.min[axis]) {
			return false
		}
	}
	return true
}

// Moves `b` by `delta` along one axis, stopping COLLISION_SKIN short of the
// first solid cell in the way. Cells the box already overlaps are ignored,
// so a box stuck inside blocks can still move out. Sweeps every cell along
// the way, so no speed tunnels through a thin wall.
sweep_axis :: proc(
	b: AABB,
	axis: int,
	delta: f64,
	data: $T,
	is_solid: proc(data: T, cell: [3]i32) -> bool,
) -> (
	moved: f64,
	blocked: bool,
) {
	if delta == 0 {
		return 0, false
	}
	// The cross-section: cells the box covers on the other two axes.
	a1, a2 := (axis + 1) % 3, (axis + 2) % 3
	lo1, hi1 := cell_range(b, a1)
	lo2, hi2 := cell_range(b, a2)
	layer_solid :: proc(c: i32, axis, a1, a2: int, lo1, hi1, lo2, hi2: i32, data: $T, is_solid: proc(data: T, cell: [3]i32) -> bool) -> bool {
		cell: [3]i32
		cell[axis] = c
		for u in lo1 ..= hi1 {
			for v in lo2 ..= hi2 {
				cell[a1], cell[a2] = u, v
				if is_solid(data, cell) {
					return true
				}
			}
		}
		return false
	}

	if delta > 0 {
		// Layers whose low face is at or beyond the leading (max) face and
		// within reach.
		lead := b.max[axis]
		for c := i32(math.ceil(lead)); f64(c) < lead + delta; c += 1 {
			if layer_solid(c, axis, a1, a2, lo1, hi1, lo2, hi2, data, is_solid) {
				return clamp(f64(c) - lead - COLLISION_SKIN, 0, delta), true
			}
		}
	} else {
		lead := b.min[axis]
		for c := i32(math.floor(lead)) - 1; f64(c + 1) > lead + delta; c -= 1 {
			if layer_solid(c, axis, a1, a2, lo1, hi1, lo2, hi2, data, is_solid) {
				return clamp(f64(c + 1) - lead + COLLISION_SKIN, delta, 0), true
			}
		}
	}
	return delta, false
}

// Moves `b` by `delta`, one axis at a time: Y first (so landing is settled
// before sliding), then X, then Z. Returns the displacement actually made
// and which axes were blocked.
move_aabb :: proc(
	b: AABB,
	delta: [3]f64,
	data: $T,
	is_solid: proc(data: T, cell: [3]i32) -> bool,
) -> (
	moved: [3]f64,
	blocked: [3]bool,
) {
	box := b
	for axis in ([3]int{1, 0, 2}) {
		moved[axis], blocked[axis] = sweep_axis(box, axis, delta[axis], data, is_solid)
		box.min[axis] += moved[axis]
		box.max[axis] += moved[axis]
	}
	return
}

// How far up (in whole-block lifts from the cell boundary at or below the
// box's bottom) the box must move to stop overlapping solid cells, searching
// up to `max_lift` blocks. 0 if it's already free; ok = false if no spot.
find_free_lift :: proc(
	b: AABB,
	max_lift: i32,
	data: $T,
	is_solid: proc(data: T, cell: [3]i32) -> bool,
) -> (
	lift: f64,
	ok: bool,
) {
	if !aabb_overlaps_solid(b, data, is_solid) {
		return 0, true
	}
	floor_y := math.floor(b.min.y)
	for k in 1 ..= max_lift {
		dy := floor_y + f64(k) + COLLISION_SKIN - b.min.y
		lifted := b
		lifted.min.y += dy
		lifted.max.y += dy
		if !aabb_overlaps_solid(lifted, data, is_solid) {
			return dy, true
		}
	}
	return 0, false
}
