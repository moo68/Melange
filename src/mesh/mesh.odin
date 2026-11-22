package mesh

import "core:math/linalg"
import "melange:world"

// CPU-side mesh for one chunk, in chunk-local space (0..CHUNK_SIZE).
// Layout matches what raylib's Mesh expects, so render/ can upload these
// arrays directly. No raylib dependency here.
Mesh_Data :: struct {
	positions: [dynamic][3]f32,
	normals:   [dynamic][3]f32,
	texcoords: [dynamic][2]f32, // position within the face's tile, 0..1 (not atlas UVs)
	tiles:     [dynamic][2]f32, // atlas tile (column, row), same for all 4 vertices of a face
	colors:    [dynamic][4]u8, // directional shade, multiplied with the texture (later: AO/light)
	indices:   [dynamic]u16,
}

// Upper bound on faces a chunk can emit: every internal block pair contributes
// at most one face, plus every face on the chunk boundary.
MAX_FACES :: 3 * world.CHUNK_SIZE * world.CHUNK_SIZE * (world.CHUNK_SIZE - 1) + 6 * world.CHUNK_SIZE * world.CHUNK_SIZE
#assert(MAX_FACES * 4 <= 65536, "worst-case chunk must fit raylib's u16 indices")

// Directions and neighbor sets live in world/; aliased here for convenience.
Face      :: world.Face
Neighbors :: world.Neighbors

// Corners of each face of a unit cube, ordered bottom-left, bottom-right,
// top-right, top-left as seen from outside the cube, so counter-clockwise
// (OpenGL/raylib front face).
@(rodata)
FACE_CORNERS := [Face][4][3]f32 {
	.Pos_X = {{1, 0, 1}, {1, 0, 0}, {1, 1, 0}, {1, 1, 1}},
	.Neg_X = {{0, 0, 0}, {0, 0, 1}, {0, 1, 1}, {0, 1, 0}},
	.Pos_Y = {{0, 1, 1}, {1, 1, 1}, {1, 1, 0}, {0, 1, 0}},
	.Neg_Y = {{0, 0, 0}, {1, 0, 0}, {1, 0, 1}, {0, 0, 1}},
	.Pos_Z = {{0, 0, 1}, {1, 0, 1}, {1, 1, 1}, {0, 1, 1}},
	.Neg_Z = {{1, 0, 0}, {0, 0, 0}, {0, 1, 0}, {1, 1, 0}},
}

// Position within the tile for each FACE_CORNERS corner (0..1). v = 0 is the
// top of the tile (raylib images are top-row first), so side faces show
// their tile upright.
@(rodata)
FACE_UVS := [4][2]f32{{0, 1}, {1, 1}, {1, 0}, {0, 0}}

ATLAS_TILES_PER_ROW :: 16

// Atlas (column, row) of a tile. The shader turns this plus the in-tile
// position into an exact texel with texelFetch, clamped to the tile, so a
// face can never sample a neighboring tile (no UV inset needed).
tile_coords :: #force_inline proc "contextless" (tile: world.Tile) -> [2]f32 {
	return {f32(int(tile) % ATLAS_TILES_PER_ROW), f32(int(tile) / ATLAS_TILES_PER_ROW)}
}

// Fixed per-direction brightness (out of 255) so cube edges are readable
// without lighting: top brightest, bottom darkest.
@(rodata)
FACE_SHADE := [Face]u16 {
	.Pos_Y = 255,
	.Pos_X = 204,
	.Neg_X = 204,
	.Pos_Z = 166,
	.Neg_Z = 166,
	.Neg_Y = 128,
}

// ---- Ambient occlusion ---------------------------------------------------------
// Per vertex, look at the 3 blocks touching that corner on the face's open
// side: two "side" blocks and one diagonal "corner" block.
//   ao = 0 if both sides are solid (the corner can't matter: fully enclosed),
//   else 3 - (side1 + side2 + corner).
// 3 = fully lit, 0 = darkest. (Mikola Lysenko, "Ambient occlusion for
// Minecraft-like worlds", 0fps.net.)
@(rodata)
AO_BRIGHTNESS := [4]f32{0.45, 0.65, 0.82, 1.0}

vertex_ao :: #force_inline proc "contextless" (side1, side2, corner: bool) -> u8 {
	if side1 && side2 {
		return 0
	}
	return 3 - u8(side1) - u8(side2) - u8(corner)
}

// ---- Padded opacity grid ---------------------------------------------------------
// The chunk plus a 1-block border from all 26 neighbors, as opacity flags.
// Culling and AO both read it at fixed offsets, so no lookup ever has to
// branch on chunk borders. Index: x + z*P + y*P*P with x, y, z in 0..17
// (padded coords = chunk-local coords + 1).
P  :: world.CHUNK_SIZE + 2
P3 :: P * P * P
Padded :: [P3]bool

padded_index :: #force_inline proc "contextless" (p: [3]i32) -> int {
	return int(p.x + p.z * P + p.y * P * P)
}

// Fills `pad` from a neighborhood. Missing (nil) chunks are air.
fill_padded :: proc(pad: ^Padded, n: ^Neighborhood) {
	pad^ = {}
	for i in 0 ..< len(Neighborhood) {
		c := n[i]
		if c == nil {
			continue
		}
		off := world.neighborhood_offset(i)
		// Per axis, which local coords of chunk `c` land in the padded grid:
		// the center chunk contributes 0..15, a -1 neighbor only its last
		// layer (15), a +1 neighbor only its first layer (0).
		lo, hi: [3]i32
		for axis in 0 ..< 3 {
			switch off[axis] {
			case -1:
				lo[axis], hi[axis] = world.CHUNK_MASK, world.CHUNK_MASK
			case 0:
				lo[axis], hi[axis] = 0, world.CHUNK_MASK
			case 1:
				lo[axis], hi[axis] = 0, 0
			}
		}
		for y in lo.y ..= hi.y {
			for z in lo.z ..= hi.z {
				for x in lo.x ..= hi.x {
					local := [3]i32{x, y, z}
					// padded = local + 1 + 16 * offset
					pp := local + 1 + off * world.CHUNK_SIZE
					pad[padded_index(pp)] = world.block_is_opaque(world.chunk_get(c, x, y, z))
				}
			}
		}
	}
}

// ---- Meshing ---------------------------------------------------------------------

// Neighborhood alias for convenience.
Neighborhood :: world.Neighborhood

// Rebuilds `out` for the center chunk of `n`. Only reads `n`. Missing
// neighbors are treated as air (the renderer only meshes chunks whose 6 face
// neighbors are loaded; missing edge/corner neighbors only affect AO).
// `out` is cleared, not freed, so reusing the same Mesh_Data across calls
// avoids reallocating once its buffers have grown.
build_chunk_mesh_neighborhood :: proc(n: ^Neighborhood, out: ^Mesh_Data) {
	clear(&out.positions)
	clear(&out.normals)
	clear(&out.texcoords)
	clear(&out.tiles)
	clear(&out.colors)
	clear(&out.indices)

	chunk := n[world.neighborhood_index({0, 0, 0})]
	if chunk_fully_air(chunk) {
		return
	}
	// Fast path for buried chunks: if every block is opaque and every
	// neighbor's touching layer is opaque, no face can be visible.
	faces := world.neighborhood_faces(n)
	if chunk_fully_opaque(chunk) && borders_fully_covered(&faces) {
		return
	}

	pad: Padded
	fill_padded(&pad, n)

	// Loop order matches the block array layout (x fastest) for cache locality.
	for y in i32(0) ..< world.CHUNK_SIZE {
		for z in i32(0) ..< world.CHUNK_SIZE {
			for x in i32(0) ..< world.CHUNK_SIZE {
				id := world.chunk_get(chunk, x, y, z)
				if !world.block_is_opaque(id) {
					continue
				}
				pos := [3]i32{x, y, z}
				pp := pos + 1
				for face in Face {
					if pad[padded_index(pp + world.FACE_NORMALS[face])] {
						continue // hidden by an opaque neighbor block
					}
					emit_face(out, &pad, pos, face, id)
				}
			}
		}
	}
}

// Convenience for callers that only have face neighbors (tests): edge and
// corner neighbors are treated as air.
build_chunk_mesh :: proc(chunk: ^world.Chunk, neighbors: ^Neighbors, out: ^Mesh_Data) {
	n := world.neighborhood_from_faces(chunk, neighbors)
	build_chunk_mesh_neighborhood(&n, out)
}

chunk_fully_air :: proc(chunk: ^world.Chunk) -> bool {
	for b in chunk.blocks {
		if b != world.AIR {
			return false
		}
	}
	return true
}

chunk_fully_opaque :: proc(chunk: ^world.Chunk) -> bool {
	for b in chunk.blocks {
		if !world.block_is_opaque(b) {
			return false
		}
	}
	return true
}

// True if, for every face, the neighbor's layer touching this chunk is fully
// opaque. A nil (unloaded) neighbor counts as air, so it never covers.
borders_fully_covered :: proc(neighbors: ^Neighbors) -> bool {
	for face in Face {
		other := neighbors[face]
		if other == nil {
			return false
		}
		n := world.FACE_NORMALS[face]
		// The axis this face points along, and the neighbor's layer on it
		// that touches us: x = 0 for the +X neighbor, x = 15 for -X, etc.
		axis := 0 if n.x != 0 else (1 if n.y != 0 else 2)
		layer := i32(0) if n[axis] > 0 else world.CHUNK_MASK
		for a in i32(0) ..< world.CHUNK_SIZE {
			for b in i32(0) ..< world.CHUNK_SIZE {
				p: [3]i32
				p[axis] = layer
				p[(axis + 1) % 3] = a
				p[(axis + 2) % 3] = b
				if !world.block_is_opaque(world.chunk_get(other, p.x, p.y, p.z)) {
					return false
				}
			}
		}
	}
	return true
}

// AO value (0..3) of each of a face's 4 corners, in FACE_CORNERS order.
face_ao :: proc "contextless" (pad: ^Padded, pos: [3]i32, face: Face) -> (ao: [4]u8) {
	n := world.FACE_NORMALS[face]
	// The layer of blocks on the face's open side.
	front := pos + 1 + n
	for corner, i in FACE_CORNERS[face] {
		// Along each of the face's two tangent axes, step toward this
		// corner: -1 if the corner is at 0 on that axis, +1 if at 1.
		s1, s2: [3]i32
		first := true
		for axis in 0 ..< 3 {
			if n[axis] != 0 {
				continue
			}
			step: [3]i32
			step[axis] = i32(corner[axis]) * 2 - 1
			if first {
				s1 = step
				first = false
			} else {
				s2 = step
			}
		}
		side1 := pad[padded_index(front + s1)]
		side2 := pad[padded_index(front + s2)]
		corner_block := pad[padded_index(front + s1 + s2)]
		ao[i] = vertex_ao(side1, side2, corner_block)
	}
	return
}

emit_face :: proc(out: ^Mesh_Data, pad: ^Padded, pos: [3]i32, face: Face, id: world.Block_ID) {
	base := u16(len(out.positions))
	origin := linalg.array_cast(pos, f32)
	normal := linalg.array_cast(world.FACE_NORMALS[face], f32)
	tile := tile_coords(world.block_tile(id, face))
	ao := face_ao(pad, pos, face)
	for corner, i in FACE_CORNERS[face] {
		b := u8(f32(FACE_SHADE[face]) * AO_BRIGHTNESS[ao[i]])
		append(&out.positions, origin + corner)
		append(&out.normals, normal)
		append(&out.texcoords, FACE_UVS[i])
		append(&out.tiles, tile)
		append(&out.colors, [4]u8{b, b, b, 255})
	}
	// Each quad is two triangles, and brightness is interpolated per
	// triangle. Splitting along the wrong diagonal makes AO look like a
	// diagonal streak, so split along the diagonal whose corners are darker
	// in total (it keeps both triangles' gradients consistent). Both
	// orderings stay counter-clockwise.
	if u32(ao[0]) + u32(ao[2]) > u32(ao[1]) + u32(ao[3]) {
		append(&out.indices, base + 1, base + 2, base + 3, base + 1, base + 3, base)
	} else {
		append(&out.indices, base, base + 1, base + 2, base, base + 2, base + 3)
	}
}

face_count :: proc(m: ^Mesh_Data) -> int {
	return len(m.indices) / 6
}

mesh_data_destroy :: proc(m: ^Mesh_Data) {
	delete(m.positions)
	delete(m.normals)
	delete(m.texcoords)
	delete(m.tiles)
	delete(m.colors)
	delete(m.indices)
}
