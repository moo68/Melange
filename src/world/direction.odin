package world

// The six axis directions. Declared in +/- pairs, so the opposite of a face is
// `Face(u8(f) ~ 1)`.
Face :: enum u8 {
	Pos_X,
	Neg_X,
	Pos_Y,
	Neg_Y,
	Pos_Z,
	Neg_Z,
}

@(rodata)
FACE_NORMALS := [Face][3]i32 {
	.Pos_X = {1, 0, 0},
	.Neg_X = {-1, 0, 0},
	.Pos_Y = {0, 1, 0},
	.Neg_Y = {0, -1, 0},
	.Pos_Z = {0, 0, 1},
	.Neg_Z = {0, 0, -1},
}

face_opposite :: #force_inline proc "contextless" (f: Face) -> Face {
	return Face(u8(f) ~ 1)
}

// The six chunks touching a chunk, indexed by the face that points at them
// (neighbors[.Pos_X] is the chunk at coord + {1, 0, 0}). nil = not loaded.
// Only valid for the current pass: never keep across frames.
Neighbors :: [Face]^Chunk

// A chunk and all 26 chunks around it (faces, edges, corners), indexed by
// neighborhood_index(offset) with offset in {-1, 0, 1}³; the center is the
// chunk itself. nil = not loaded. Meshing needs edges/corners for AO.
// Only valid for the current pass, like Neighbors.
Neighborhood :: [27]^Chunk

neighborhood_index :: #force_inline proc "contextless" (offset: [3]i32) -> int {
	return int((offset.x + 1) + (offset.z + 1) * 3 + (offset.y + 1) * 9)
}

neighborhood_offset :: #force_inline proc "contextless" (i: int) -> [3]i32 {
	n := i32(i)
	return {n % 3 - 1, n / 9 - 1, (n / 3) % 3 - 1}
}

// The six face neighbors out of a neighborhood.
neighborhood_faces :: proc "contextless" (n: ^Neighborhood) -> (out: Neighbors) {
	for face in Face {
		out[face] = n[neighborhood_index(FACE_NORMALS[face])]
	}
	return
}

// A neighborhood with only the center and face neighbors known; edge and
// corner neighbors are nil (treated as air).
neighborhood_from_faces :: proc "contextless" (center: ^Chunk, faces: ^Neighbors) -> (out: Neighborhood) {
	out[neighborhood_index({0, 0, 0})] = center
	for face in Face {
		out[neighborhood_index(FACE_NORMALS[face])] = faces[face]
	}
	return
}
