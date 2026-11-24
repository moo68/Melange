package tests

import "core:math/linalg"
import "core:testing"
import "melange:mesh"
import "melange:world"

S :: world.CHUNK_SIZE

// All neighbors unloaded: chunk borders behave as air.
no_neighbors: mesh.Neighbors

// Builds the mesh for `chunk` and returns its face count.
mesh_faces :: proc(chunk: ^world.Chunk) -> int {
	cm: mesh.Chunk_Mesh
	defer mesh.chunk_mesh_destroy(&cm)
	m := &cm[.Opaque]
	mesh.build_chunk_mesh(chunk, &no_neighbors, &cm)
	return mesh.face_count(m)
}

@(test)
empty_chunk_has_no_faces :: proc(t: ^testing.T) {
	c := new(world.Chunk)
	defer free(c)
	testing.expect_value(t, mesh_faces(c), 0)
}

@(test)
single_block_has_six_faces :: proc(t: ^testing.T) {
	c := new(world.Chunk)
	defer free(c)
	world.chunk_set(c, 5, 5, 5, world.STONE)

	cm: mesh.Chunk_Mesh
	defer mesh.chunk_mesh_destroy(&cm)
	m := &cm[.Opaque]
	mesh.build_chunk_mesh(c, &no_neighbors, &cm)
	testing.expect_value(t, mesh.face_count(m), 6)
	testing.expect_value(t, len(m.positions), 24)
	testing.expect_value(t, len(m.indices), 36)
}

@(test)
adjacent_blocks_cull_shared_face :: proc(t: ^testing.T) {
	c := new(world.Chunk)
	defer free(c)
	world.chunk_set(c, 5, 5, 5, world.STONE)
	world.chunk_set(c, 6, 5, 5, world.STONE)
	testing.expect_value(t, mesh_faces(c), 10)
}

@(test)
solid_cube_only_shows_its_surface :: proc(t: ^testing.T) {
	c := new(world.Chunk)
	defer free(c)
	for y in i32(2) ..< 5 {
		for z in i32(2) ..< 5 {
			for x in i32(2) ..< 5 {
				world.chunk_set(c, x, y, z, world.STONE)
			}
		}
	}
	testing.expect_value(t, mesh_faces(c), 6 * 3 * 3)
}

@(test)
full_chunk_emits_border_faces_only :: proc(t: ^testing.T) {
	c := new(world.Chunk)
	defer free(c)
	for &b in c.blocks {
		b = world.STONE
	}
	testing.expect_value(t, mesh_faces(c), 6 * S * S)
}

@(test)
checkerboard_worst_case_fits_u16 :: proc(t: ^testing.T) {
	c := new(world.Chunk)
	defer free(c)
	for y in i32(0) ..< S {
		for z in i32(0) ..< S {
			for x in i32(0) ..< S {
				if (x + y + z) % 2 == 0 {
					world.chunk_set(c, x, y, z, world.STONE)
				}
			}
		}
	}
	cm: mesh.Chunk_Mesh
	defer mesh.chunk_mesh_destroy(&cm)
	m := &cm[.Opaque]
	mesh.build_chunk_mesh(c, &no_neighbors, &cm)
	testing.expect_value(t, mesh.face_count(m), 3 * S * S * S)
	testing.expect(t, len(m.positions) <= 65536, "vertex count overflows u16 indices")
}

// Every triangle must wind counter-clockwise when viewed from outside, i.e.
// its geometric normal points the same way as the stored face normal.
@(test)
triangles_wind_counter_clockwise :: proc(t: ^testing.T) {
	c := new(world.Chunk)
	defer free(c)
	world.chunk_set(c, 3, 3, 3, world.STONE)

	cm: mesh.Chunk_Mesh
	defer mesh.chunk_mesh_destroy(&cm)
	m := &cm[.Opaque]
	mesh.build_chunk_mesh(c, &no_neighbors, &cm)

	for i := 0; i < len(m.indices); i += 3 {
		a := m.positions[m.indices[i]]
		b := m.positions[m.indices[i + 1]]
		d := m.positions[m.indices[i + 2]]
		geometric := linalg.cross(b - a, d - a)
		stored := m.normals[m.indices[i]]
		testing.expectf(t, linalg.dot(geometric, stored) > 0, "triangle %d winds the wrong way", i / 3)
	}
}

@(test)
rebuild_clears_previous_mesh :: proc(t: ^testing.T) {
	c := new(world.Chunk)
	defer free(c)
	world.chunk_set(c, 0, 0, 0, world.STONE)

	cm: mesh.Chunk_Mesh
	defer mesh.chunk_mesh_destroy(&cm)
	m := &cm[.Opaque]
	mesh.build_chunk_mesh(c, &no_neighbors, &cm)
	mesh.build_chunk_mesh(c, &no_neighbors, &cm)
	testing.expect_value(t, mesh.face_count(m), 6)
}
