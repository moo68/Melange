package tests

import "core:math/linalg"
import "core:testing"
import "melange:mesh"
import "melange:world"

@(test)
vertex_ao_rule :: proc(t: ^testing.T) {
	testing.expect_value(t, mesh.vertex_ao(false, false, false), 3)
	testing.expect_value(t, mesh.vertex_ao(true, false, false), 2)
	testing.expect_value(t, mesh.vertex_ao(false, true, false), 2)
	testing.expect_value(t, mesh.vertex_ao(false, false, true), 2)
	testing.expect_value(t, mesh.vertex_ao(true, false, true), 1)
	// Both sides solid: darkest regardless of the corner block.
	testing.expect_value(t, mesh.vertex_ao(true, true, false), 0)
	testing.expect_value(t, mesh.vertex_ao(true, true, true), 0)
}

// The 4 vertices of the face of block `pos` (chunk-local) pointing along
// `face`, as indices into the mesh's vertex arrays; ok = false if absent.
find_face :: proc(m: ^mesh.Mesh_Data, pos: [3]i32, face: world.Face) -> (first: int, ok: bool) {
	n := linalg.array_cast(world.FACE_NORMALS[face], f32)
	want_center := linalg.array_cast(pos, f32) + 0.5 + n * 0.5
	for f in 0 ..< mesh.face_count(m) {
		c := (m.positions[f * 4] + m.positions[f * 4 + 1] + m.positions[f * 4 + 2] + m.positions[f * 4 + 3]) / 4
		if m.normals[f * 4] == n && c == want_center {
			return f * 4, true
		}
	}
	return 0, false
}

// Brightness of the face vertex at corner position `corner` (chunk-local).
vertex_brightness :: proc(t: ^testing.T, m: ^mesh.Mesh_Data, first: int, corner: [3]f32) -> u8 {
	for v in first ..< first + 4 {
		if m.positions[v] == corner {
			return m.colors[v].r
		}
	}
	testing.fail_now(t, "corner not found on face")
}

shade_with_ao :: proc(face: world.Face, ao: int) -> u8 {
	return u8(f32(mesh.FACE_SHADE[face]) * mesh.AO_BRIGHTNESS[ao])
}

// Every triangle must still wind counter-clockwise from outside, including
// the ones whose quad diagonal was flipped for AO.
expect_ccw :: proc(t: ^testing.T, m: ^mesh.Mesh_Data) {
	for i := 0; i < len(m.indices); i += 3 {
		a := m.positions[m.indices[i]]
		b := m.positions[m.indices[i + 1]]
		d := m.positions[m.indices[i + 2]]
		if linalg.dot(linalg.cross(b - a, d - a), m.normals[m.indices[i]]) <= 0 {
			testing.fail_now(t, "a triangle winds the wrong way")
		}
	}
}

@(test)
isolated_block_is_fully_lit :: proc(t: ^testing.T) {
	c := new(world.Chunk)
	defer free(c)
	world.chunk_set(c, 5, 5, 5, world.STONE)
	cm: mesh.Chunk_Mesh
	defer mesh.chunk_mesh_destroy(&cm)
	m := &cm[.Opaque]
	mesh.build_chunk_mesh(c, &no_neighbors, &cm)
	for face in world.Face {
		first, ok := find_face(m, {5, 5, 5}, face)
		testing.expect(t, ok)
		for v in first ..< first + 4 {
			testing.expect_value(t, m.colors[v].r, shade_with_ao(face, 3))
		}
	}
}

// A 3x3 floor at y = 4 with a cube on top of its center. The top face of the
// floor block east of the cube is darkened only on its west edge (touching
// the cube's side), not its east edge.
@(test)
block_next_to_cube_darkens_touching_edge :: proc(t: ^testing.T) {
	c := new(world.Chunk)
	defer free(c)
	for z in i32(4) ..= 6 {
		for x in i32(4) ..= 6 {
			world.chunk_set(c, x, 4, z, world.STONE)
		}
	}
	world.chunk_set(c, 5, 5, 5, world.STONE)
	cm: mesh.Chunk_Mesh
	defer mesh.chunk_mesh_destroy(&cm)
	m := &cm[.Opaque]
	mesh.build_chunk_mesh(c, &no_neighbors, &cm)
	expect_ccw(t, m)

	first, ok := find_face(m, {6, 4, 5}, .Pos_Y)
	testing.expect(t, ok)
	// West edge (x = 6) touches the cube at (5, 5, 5): one side solid -> ao 2.
	testing.expect_value(t, vertex_brightness(t, m, first, {6, 5, 5}), shade_with_ao(.Pos_Y, 2))
	testing.expect_value(t, vertex_brightness(t, m, first, {6, 5, 6}), shade_with_ao(.Pos_Y, 2))
	// East edge (x = 7): nothing above -> fully lit.
	testing.expect_value(t, vertex_brightness(t, m, first, {7, 5, 5}), shade_with_ao(.Pos_Y, 3))
	testing.expect_value(t, vertex_brightness(t, m, first, {7, 5, 6}), shade_with_ao(.Pos_Y, 3))
}

// Floor block with walls on its -X and -Z sides: the inside corner vertex
// has both sides solid -> darkest (ao 0).
@(test)
inside_corner_is_darkest :: proc(t: ^testing.T) {
	c := new(world.Chunk)
	defer free(c)
	world.chunk_set(c, 5, 4, 5, world.STONE)
	world.chunk_set(c, 4, 5, 5, world.STONE)
	world.chunk_set(c, 5, 5, 4, world.STONE)
	cm: mesh.Chunk_Mesh
	defer mesh.chunk_mesh_destroy(&cm)
	m := &cm[.Opaque]
	mesh.build_chunk_mesh(c, &no_neighbors, &cm)
	expect_ccw(t, m)

	first, ok := find_face(m, {5, 4, 5}, .Pos_Y)
	testing.expect(t, ok)
	testing.expect_value(t, vertex_brightness(t, m, first, {5, 5, 5}), shade_with_ao(.Pos_Y, 0))
	testing.expect_value(t, vertex_brightness(t, m, first, {6, 5, 6}), shade_with_ao(.Pos_Y, 3))
}

// AO across a chunk *corner*: block at local (15, 5, 15); the only occluder
// sits diagonally at world (16, 6, 16), i.e. in the (+1, 0, +1) neighbor
// chunk. Its top face's (16, 6, 16) corner must be darkened, which requires
// the edge neighbor in the neighborhood. The split must also use the
// diagonal through that dark vertex.
@(test)
ao_reads_diagonal_neighbor_chunk :: proc(t: ^testing.T) {
	center := new(world.Chunk)
	defer free(center)
	diagonal := new(world.Chunk)
	defer free(diagonal)
	world.chunk_set(center, 15, 5, 15, world.STONE)
	world.chunk_set(diagonal, 0, 6, 0, world.STONE)

	n: world.Neighborhood
	n[world.neighborhood_index({0, 0, 0})] = center
	n[world.neighborhood_index({1, 0, 1})] = diagonal
	cm: mesh.Chunk_Mesh
	defer mesh.chunk_mesh_destroy(&cm)
	m := &cm[.Opaque]
	mesh.build_chunk_mesh_neighborhood(&n, &cm)
	expect_ccw(t, m)

	first, ok := find_face(m, {15, 5, 15}, .Pos_Y)
	testing.expect(t, ok)
	testing.expect_value(t, vertex_brightness(t, m, first, {16, 6, 16}), shade_with_ao(.Pos_Y, 2))
	testing.expect_value(t, vertex_brightness(t, m, first, {15, 6, 15}), shade_with_ao(.Pos_Y, 3))

	// Quad split: the dark vertex must be in both triangles.
	dark := -1
	for v in first ..< first + 4 {
		if m.positions[v] == {16, 6, 16} {
			dark = v
		}
	}
	face_index := first / 4
	tri_has :: proc(m: ^mesh.Mesh_Data, tri: int, v: int) -> bool {
		for k in 0 ..< 3 {
			if int(m.indices[tri * 3 + k]) == v {
				return true
			}
		}
		return false
	}
	testing.expect(t, tri_has(m, face_index * 2, dark) && tri_has(m, face_index * 2 + 1, dark), "quad not split through the dark corner")

	// Without the diagonal chunk the same corner is fully lit.
	n[world.neighborhood_index({1, 0, 1})] = nil
	mesh.build_chunk_mesh_neighborhood(&n, &cm)
	first, ok = find_face(m, {15, 5, 15}, .Pos_Y)
	testing.expect(t, ok)
	testing.expect_value(t, vertex_brightness(t, m, first, {16, 6, 16}), shade_with_ao(.Pos_Y, 3))
}
