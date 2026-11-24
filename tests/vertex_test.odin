package tests

import "core:math/rand"
import "core:testing"
import "melange:mesh"
import "melange:world"

@(test)
packed_vertices_round_trip :: proc(t: ^testing.T) {
	r := rand.create(7)
	context.random_generator = rand.default_random_generator(&r)
	check :: proc(t: ^testing.T, v: mesh.Unpacked_Vertex) {
		got := mesh.unpack_vertex(mesh.pack_vertex(v))
		testing.expectf(t, got == v, "round trip: %v -> %v", v, got)
	}
	// Every field at its extremes, alone: no field bleeds into another.
	check(t, {})
	check(t, {position = {mesh.MAX_POSITION, 0, 0}})
	check(t, {position = {0, mesh.MAX_POSITION, 0}})
	check(t, {position = {0, 0, mesh.MAX_POSITION}})
	check(t, {uv = {mesh.POSITION_SCALE, 0}})
	check(t, {uv = {0, mesh.POSITION_SCALE}})
	check(t, {ao = 3})
	check(t, {face = .Neg_Z})
	check(t, {tile = 255})
	check(t, {sky = mesh.VERTEX_LIGHT_MASK})
	check(t, {block = mesh.VERTEX_LIGHT_MASK})
	// All at their maxima together.
	check(t, {position = mesh.MAX_POSITION, uv = mesh.POSITION_SCALE, face = .Neg_Z, ao = 3, tile = 255, sky = mesh.VERTEX_LIGHT_MASK, block = mesh.VERTEX_LIGHT_MASK})
	// Random values over the full ranges.
	for _ in 0 ..< 100_000 {
		check(
			t,
			{
				position = {u16(rand.int_max(mesh.MAX_POSITION + 1)), u16(rand.int_max(mesh.MAX_POSITION + 1)), u16(rand.int_max(mesh.MAX_POSITION + 1))},
				uv = {u16(rand.int_max(mesh.POSITION_SCALE + 1)), u16(rand.int_max(mesh.POSITION_SCALE + 1))},
				face = world.Face(rand.int_max(len(world.Face))),
				ao = u8(rand.int_max(4)),
				tile = world.Tile(rand.int_max(256)),
				sky = u8(rand.int_max(mesh.VERTEX_LIGHT_MASK + 1)),
				block = u8(rand.int_max(mesh.VERTEX_LIGHT_MASK + 1)),
			},
		)
	}
	testing.expect_value(t, size_of(mesh.Vertex), 8)
}

@(test)
shared_quad_indices :: proc(t: ^testing.T) {
	indices := make([]u16, mesh.MAX_FACES * 6)
	defer delete(indices)
	mesh.quad_indices(indices)
	for f in 0 ..< mesh.MAX_FACES {
		b := u16(f * 4)
		want := [6]u16{b, b + 1, b + 2, b, b + 2, b + 3}
		for k in 0 ..< 6 {
			if indices[f * 6 + k] != want[k] {
				testing.fail_now(t, "wrong index pattern")
			}
		}
	}
	testing.expect_value(t, int(indices[len(indices) - 1]), mesh.MAX_FACES * 4 - 1)
}

@(test)
shade_table_matches_face_shade_and_ao :: proc(t: ^testing.T) {
	table := mesh.shade_table()
	for face in world.Face {
		for ao in 0 ..< 4 {
			want := f32(u8(f32(mesh.FACE_SHADE[face]) * mesh.AO_BRIGHTNESS[ao])) / 255
			testing.expect_value(t, table[int(face) * 4 + ao], want)
		}
	}
	testing.expect_value(t, table[int(world.Face.Pos_Y) * 4 + 3], 1)
}

// Real terrain: every face's 4 vertices agree on face and tile, lie in the
// face's plane inside the chunk, have in-tile UVs in range, are fully sky lit
// (until lighting exists), and are emitted so that the shared 0-2 split runs
// along the darker AO diagonal.
@(test)
terrain_mesh_vertices_are_consistent :: proc(t: ^testing.T) {
	w: world.World
	world.world_init(&w, 1337)
	defer world.world_destroy(&w)
	s: world.Streamer
	world.streamer_init(&s, {radius = 3, vertical = 2, unload_margin = 1, load_budget = 1000, unload_budget = 1000})
	defer world.streamer_destroy(&s)
	// A coast (water, sand, steps; see the sand tests in terrain_test).
	spots := [][2]i32{{-1721, -9410}}
	cm: mesh.Chunk_Mesh
	defer mesh.chunk_mesh_destroy(&cm)
	faces_checked, flipped := 0, 0
	for spot in spots {
		h := world.terrain_height(w.seed, spot.x, spot.y)
		center := world.block_to_chunk({spot.x, h, spot.y})
		world.streamer_update(&s, &w, center)
		for dy in i32(-1) ..= 1 {
			for dz in i32(-1) ..= 1 {
				for dx in i32(-1) ..= 1 {
					hood := world.world_get_neighborhood(&w, center + {dx, dy, dz})
					mesh.build_chunk_mesh_neighborhood(&hood, &cm)
					for &m in cm {
						for f in 0 ..< mesh.face_count(&m) {
							v := [4]mesh.Unpacked_Vertex {
								mesh.unpack_vertex(m.vertices[f * 4]),
								mesh.unpack_vertex(m.vertices[f * 4 + 1]),
								mesh.unpack_vertex(m.vertices[f * 4 + 2]),
								mesh.unpack_vertex(m.vertices[f * 4 + 3]),
							}
							n := world.FACE_NORMALS[v[0].face]
							axis := 0 if n.x != 0 else (1 if n.y != 0 else 2)
							for k in 0 ..< 4 {
								testing.expect(t, v[k].face == v[0].face && v[k].tile == v[0].tile)
								testing.expect(t, v[k].position[axis] == v[0].position[axis], "in the face's plane")
								testing.expect(t, v[k].position.x <= mesh.MAX_POSITION && v[k].position.y <= mesh.MAX_POSITION && v[k].position.z <= mesh.MAX_POSITION)
								testing.expect(t, v[k].uv.x <= mesh.POSITION_SCALE && v[k].uv.y <= mesh.POSITION_SCALE)
								testing.expect(t, v[k].sky == mesh.MAX_VERTEX_LIGHT && v[k].block == 0)
							}
							a02 := int(v[0].ao) + int(v[2].ao)
							a13 := int(v[1].ao) + int(v[3].ao)
							testing.expectf(t, a02 <= a13, "split 0-2 must be the darker diagonal: %v", v)
							if a02 < a13 {
								flipped += 1
							}
							faces_checked += 1
						}
					}
				}
			}
		}
	}
	testing.expectf(t, faces_checked > 1000 && flipped > 10, "a real scene: %d faces, %d with uneven AO", faces_checked, flipped)
}
