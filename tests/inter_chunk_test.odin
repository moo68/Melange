package tests

import "core:testing"
import "melange:mesh"
import "melange:world"

// Block position on the border of a chunk on the side `face` points to,
// e.g. .Pos_X -> {15, 8, 8}, .Neg_Y -> {8, 0, 8}.
border_pos :: proc(face: mesh.Face) -> [3]i32 {
	pos := [3]i32{8, 8, 8}
	n := world.FACE_NORMALS[face]
	for axis in 0 ..< 3 {
		if n[axis] > 0 {
			pos[axis] = S - 1
		} else if n[axis] < 0 {
			pos[axis] = 0
		}
	}
	return pos
}

fill :: proc(c: ^world.Chunk, id: world.Block_ID) {
	for &b in c.blocks {
		b = id
	}
}

faces_with :: proc(c: ^world.Chunk, neighbors: ^mesh.Neighbors) -> int {
	cm: mesh.Chunk_Mesh
	defer mesh.chunk_mesh_destroy(&cm)
	m := &cm[.Opaque]
	mesh.build_chunk_mesh(c, neighbors, &cm)
	return mesh.face_count(m)
}

// For each direction: a block on that border is culled by a full neighbor on
// that side, and not by a full neighbor on the opposite side. This catches
// both the out-of-bounds wrapping and any mix-up of neighbor slots.
@(test)
border_block_culled_by_correct_neighbor :: proc(t: ^testing.T) {
	c := new(world.Chunk)
	defer free(c)
	full := new(world.Chunk)
	defer free(full)
	fill(full, world.STONE)

	for face in mesh.Face {
		c^ = {}
		p := border_pos(face)
		world.chunk_set(c, p.x, p.y, p.z, world.STONE)

		same_side: mesh.Neighbors
		same_side[face] = full
		testing.expectf(t, faces_with(c, &same_side) == 5, "%v: neighbor on that side should cull the border face", face)

		other_side: mesh.Neighbors
		other_side[world.face_opposite(face)] = full
		testing.expectf(t, faces_with(c, &other_side) == 6, "%v: neighbor on the opposite side must not cull it", face)
	}
}

// Only the neighbor block directly across the border matters: one at x=1 in
// the +X neighbor (not touching) must not cull, one at x=0 must.
@(test)
only_touching_neighbor_block_culls :: proc(t: ^testing.T) {
	c := new(world.Chunk)
	defer free(c)
	other := new(world.Chunk)
	defer free(other)
	world.chunk_set(c, 15, 4, 7, world.STONE)

	neighbors: mesh.Neighbors
	neighbors[.Pos_X] = other

	world.chunk_set(other, 1, 4, 7, world.STONE)
	testing.expect_value(t, faces_with(c, &neighbors), 6)

	world.chunk_set(other, 0, 4, 7, world.STONE)
	testing.expect_value(t, faces_with(c, &neighbors), 5)

	// Same x=0 column but a different y/z must not cull.
	other^ = {}
	world.chunk_set(other, 0, 5, 7, world.STONE)
	world.chunk_set(other, 0, 4, 8, world.STONE)
	testing.expect_value(t, faces_with(c, &neighbors), 6)
}

@(test)
full_chunk_between_full_neighbors_has_no_faces :: proc(t: ^testing.T) {
	c := new(world.Chunk)
	defer free(c)
	full := new(world.Chunk)
	defer free(full)
	fill(c, world.STONE)
	fill(full, world.STONE)

	neighbors: mesh.Neighbors
	for face in mesh.Face {
		neighbors[face] = full
	}
	testing.expect_value(t, faces_with(c, &neighbors), 0)

	// Unload one neighbor: exactly that border face layer reappears.
	neighbors[.Neg_Z] = nil
	testing.expect_value(t, faces_with(c, &neighbors), S * S)
}

// An air (or empty) neighbor behaves the same as an unloaded one.
@(test)
air_neighbor_matches_unloaded :: proc(t: ^testing.T) {
	c := new(world.Chunk)
	defer free(c)
	air := new(world.Chunk)
	defer free(air)
	fill(c, world.STONE)

	neighbors: mesh.Neighbors
	for face in mesh.Face {
		neighbors[face] = air
	}
	testing.expect_value(t, faces_with(c, &neighbors), faces_with(c, &no_neighbors))
}

// The buried-chunk fast path must not skip a chunk whose neighbor has a hole
// in the touching layer: test a single air block in each neighbor's border.
@(test)
buried_fast_path_respects_holes :: proc(t: ^testing.T) {
	c := new(world.Chunk)
	defer free(c)
	fill(c, world.STONE)
	walls: [6]world.Chunk
	neighbors: mesh.Neighbors
	for face in mesh.Face {
		fill(&walls[face], world.STONE)
		neighbors[face] = &walls[face]
	}
	testing.expect_value(t, faces_with(c, &neighbors), 0)

	for face in mesh.Face {
		// Punch a hole in the neighbor's layer touching our border block.
		p := border_pos(face) + world.FACE_NORMALS[face]
		h := p & world.CHUNK_MASK
		world.chunk_set(&walls[face], h.x, h.y, h.z, world.AIR)
		testing.expectf(t, faces_with(c, &neighbors) == 1, "%v: hole in neighbor layer must expose one face", face)
		world.chunk_set(&walls[face], h.x, h.y, h.z, world.STONE)
	}

	// A hole inside the chunk itself exposes the 6 faces around it.
	world.chunk_set(c, 8, 8, 8, world.AIR)
	testing.expect_value(t, faces_with(c, &neighbors), 6)
}
