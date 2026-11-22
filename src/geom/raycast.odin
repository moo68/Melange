package geom

import "core:math"
import "core:math/linalg"

Ray_Hit :: struct {
	block:  [3]i32, // the solid block hit
	// Outward normal of the face the ray entered through: block + normal is
	// the empty block in front of it (where a placed block goes).
	// {0, 0, 0} if the ray started inside `block`.
	normal: [3]i32,
	dist:   f32, // distance from the origin to the entry point (world units)
}

// Walks the voxel grid along a ray (Amanatides & Woo, "A Fast Voxel Traversal
// Algorithm", 1987), visiting every cell the ray passes through in order,
// and returns the first cell where `is_solid(data, cell)` is true within
// `max_dist`. Cell (x, y, z) covers [x, x+1) × [y, y+1) × [z, z+1).
//
// `max_dist` must be finite (an empty world would never end the walk).
// `dir` needn't be normalized; distances are in world units either way. A
// zero `dir` only tests the origin's cell. When the ray crosses an edge or
// corner exactly (several boundaries at the same distance), it steps x before
// y before z, so results are deterministic.
raycast_voxels :: proc(
	origin, dir: [3]f32,
	max_dist: f32,
	data: $T,
	is_solid: proc(data: T, cell: [3]i32) -> bool,
) -> (
	hit: Ray_Hit,
	ok: bool,
) {
	// floor, not truncation: -0.5 is in cell -1.
	cell := [3]i32{i32(math.floor(origin.x)), i32(math.floor(origin.y)), i32(math.floor(origin.z))}
	if is_solid(data, cell) {
		return {block = cell, dist = 0}, true
	}
	length := linalg.length(dir)
	if length == 0 {
		return {}, false
	}
	d := dir / length

	// Per axis: step = direction to the next cell; t_max = distance along
	// the ray to the next boundary on that axis; t_delta = distance between
	// boundaries. An axis the ray doesn't move along never gets crossed.
	step: [3]i32
	t_max, t_delta: [3]f32
	for axis in 0 ..< 3 {
		switch {
		case d[axis] > 0:
			step[axis] = 1
			t_max[axis] = (f32(cell[axis] + 1) - origin[axis]) / d[axis]
			t_delta[axis] = 1 / d[axis]
		case d[axis] < 0:
			step[axis] = -1
			t_max[axis] = (f32(cell[axis]) - origin[axis]) / d[axis]
			t_delta[axis] = -1 / d[axis]
		case:
			t_max[axis] = math.INF_F32
			t_delta[axis] = math.INF_F32
		}
	}

	for {
		// Nearest boundary; strict < keeps the lowest axis on ties.
		axis := 0
		if t_max[1] < t_max[axis] {
			axis = 1
		}
		if t_max[2] < t_max[axis] {
			axis = 2
		}
		t := t_max[axis]
		if t > max_dist {
			return {}, false
		}
		cell[axis] += step[axis]
		if is_solid(data, cell) {
			hit = {block = cell, dist = t}
			hit.normal[axis] = -step[axis]
			return hit, true
		}
		t_max[axis] += t_delta[axis]
	}
}
