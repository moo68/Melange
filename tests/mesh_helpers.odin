package tests

import "core:math/linalg"
import "melange:mesh"
import "melange:world"

// Reading packed mesh vertices (mesh.Vertex) in tests.

vpos :: proc(m: ^mesh.Mesh_Data, v: int) -> [3]f32 {
	return mesh.vertex_position(m.vertices[v])
}

vnormal :: proc(m: ^mesh.Mesh_Data, v: int) -> [3]f32 {
	return linalg.array_cast(world.FACE_NORMALS[mesh.unpack_vertex(m.vertices[v]).face], f32)
}

// In-tile position, 0..1.
vuv :: proc(m: ^mesh.Mesh_Data, v: int) -> [2]f32 {
	uv := mesh.unpack_vertex(m.vertices[v]).uv
	return {f32(uv.x), f32(uv.y)} / mesh.POSITION_SCALE
}

// Atlas (column, row).
vtile :: proc(m: ^mesh.Mesh_Data, v: int) -> [2]f32 {
	return mesh.tile_coords(mesh.unpack_vertex(m.vertices[v]).tile)
}

vao :: proc(m: ^mesh.Mesh_Data, v: int) -> u8 {
	return mesh.unpack_vertex(m.vertices[v]).ao
}

// Brightness out of 255 the shader gives the vertex (mesh.shade_table).
vbright :: proc(m: ^mesh.Mesh_Data, v: int) -> u8 {
	u := mesh.unpack_vertex(m.vertices[v])
	return u8(f32(mesh.FACE_SHADE[u.face]) * mesh.AO_BRIGHTNESS[u.ao])
}

// The vertex index of triangle corner i (0 ..< index_count) with the shared
// quad index buffer.
index_at :: proc(i: int) -> int {
	quad := mesh.QUAD_INDICES
	return i / 6 * 4 + int(quad[i % 6])
}

index_count :: proc(m: ^mesh.Mesh_Data) -> int {
	return mesh.face_count(m) * 6
}
