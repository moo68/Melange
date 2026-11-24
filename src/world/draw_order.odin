package world

import "core:slice"

// A chunk with its squared distance from the camera, for drawing translucent
// chunks back to front.
Chunk_Distance :: struct {
	coord: [3]i32,
	dist2: f32,
}

// Squared distance from `camera` to the center of chunk `coord`.
chunk_center_dist2 :: proc "contextless" (coord: [3]i32, camera: [3]f32) -> f32 {
	o := chunk_origin(coord)
	half :: f32(CHUNK_SIZE) / 2
	d := [3]f32{f32(o.x) + half, f32(o.y) + half, f32(o.z) + half} - camera
	return d.x * d.x + d.y * d.y + d.z * d.z
}

// Sorts farthest first (blending needs what's behind drawn first).
sort_far_first :: proc(items: []Chunk_Distance) {
	slice.sort_by(items, proc(a, b: Chunk_Distance) -> bool {
		return a.dist2 > b.dist2
	})
}
