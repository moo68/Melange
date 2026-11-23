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
// and which axes were blocked. With keep_support, if the Y move ended on the
// ground, X and Z are also clamped by edge_clamp (and count as blocked when
// it shortens them), so the box can't walk off an edge (crouching).
move_aabb :: proc(
	b: AABB,
	delta: [3]f64,
	data: $T,
	is_solid: proc(data: T, cell: [3]i32) -> bool,
	keep_support := false,
) -> (
	moved: [3]f64,
	blocked: [3]bool,
) {
	box := b
	for axis in ([3]int{1, 0, 2}) {
		moved[axis], blocked[axis] = sweep_axis(box, axis, delta[axis], data, is_solid)
		if axis != 1 && keep_support && blocked.y && delta.y < 0 {
			clamped := edge_clamp(box, axis, moved[axis], data, is_solid)
			blocked[axis] ||= clamped != moved[axis]
			moved[axis] = clamped
		}
		box.min[axis] += moved[axis]
		box.max[axis] += moved[axis]
	}
	return
}

// How far below the bottom of a box solid cells count as support for
// edge_clamp. Less than one block: a 1-block drop is an edge.
SUPPORT_DEPTH :: 0.5

// Shortens a horizontal move of `b` by `delta` along `axis` (0 = x, 2 = z)
// so the box stays continuously supported: some solid cell within
// SUPPORT_DEPTH below its bottom stays under its footprint, overlapping it by
// at least COLLISION_SKIN. Exact (not stepped), so a 0.6-wide box can hang
// up to 0.3 - COLLISION_SKIN over an edge. Returns `delta` unchanged if the
// box isn't supported to begin with. Assumes the box is at most 1 block wide
// on `axis`, so it can't straddle a gap.
edge_clamp :: proc(b: AABB, axis: int, delta: f64, data: $T, is_solid: proc(data: T, cell: [3]i32) -> bool) -> f64 {
	if delta == 0 {
		return 0
	}
	// The support slab under the box, and its range on the other horizontal
	// axis. Its top stays a skin below the feet so a box resting a skin above
	// a block top doesn't count its own (air) layer.
	slab := b
	slab.max.y = b.min.y - COLLISION_SKIN
	slab.min.y = b.min.y - SUPPORT_DEPTH
	other := 2 - axis
	y0, y1 := cell_range(slab, 1)
	o0, o1 := cell_range(slab, other)
	column_solid :: proc(c: i32, axis, other: int, y0, y1, o0, o1: i32, data: $T, is_solid: proc(data: T, cell: [3]i32) -> bool) -> bool {
		cell: [3]i32
		cell[axis] = c
		for y in y0 ..= y1 {
			for o in o0 ..= o1 {
				cell.y, cell[other] = y, o
				if is_solid(data, cell) {
					return true
				}
			}
		}
		return false
	}

	lo, hi := cell_range(b, axis)
	if delta > 0 {
		// The furthest supported column among those under the box, then
		// the run of supported columns ahead of it. The box's back face
		// must stay a skin short of the run's far end.
		edge := lo - 1
		for c := hi; c >= lo; c -= 1 {
			if column_solid(c, axis, other, y0, y1, o0, o1, data, is_solid) {
				edge = c
				break
			}
		}
		if edge < lo {
			return delta
		}
		for f64(edge + 1) - COLLISION_SKIN - b.min[axis] < delta && column_solid(edge + 1, axis, other, y0, y1, o0, o1, data, is_solid) {
			edge += 1
		}
		return clamp(f64(edge + 1) - COLLISION_SKIN - b.min[axis], 0, delta)
	} else {
		edge := hi + 1
		for c := lo; c <= hi; c += 1 {
			if column_solid(c, axis, other, y0, y1, o0, o1, data, is_solid) {
				edge = c
				break
			}
		}
		if edge > hi {
			return delta
		}
		for f64(edge) + COLLISION_SKIN - b.max[axis] > delta && column_solid(edge - 1, axis, other, y0, y1, o0, o1, data, is_solid) {
			edge -= 1
		}
		return clamp(f64(edge) + COLLISION_SKIN - b.max[axis], delta, 0)
	}
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
