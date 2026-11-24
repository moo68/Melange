package mesh

import "melange:world"

// CPU-side mesh for one chunk pass, in chunk-local space (0..CHUNK_SIZE):
// 4 packed vertices per face (see Vertex), in QUAD_INDICES order. No index
// data: every chunk draws with one shared index buffer (quad_indices). No
// raylib dependency here.
Mesh_Data :: struct {
	vertices: [dynamic]Vertex,
}

// Which mesh a face goes into; each pass is drawn with its own shader.
Pass :: enum u8 {
	Opaque, // no discard: keeps early depth testing for most of the world
	Cutout, // alpha-tested (discard), drawn after the opaque pass
	Translucent, // alpha-blended, drawn last: chunks back to front, no depth writes
}

// One chunk's meshes, one per pass (world.Block_Render .Opaque / .Cutout / .Translucent).
Chunk_Mesh :: [Pass]Mesh_Data

// The pass a block's faces go into. Only for blocks that are meshed.
block_pass :: #force_inline proc "contextless" (id: world.Block_ID) -> Pass {
	#partial switch world.block_props(id).render {
	case .Cutout:
		return .Cutout
	case .Translucent:
		return .Translucent
	}
	return .Opaque
}

// Upper bound on faces a chunk can emit: every internal block pair contributes
// at most one face, plus every face on the chunk boundary.
MAX_FACES :: 3 * world.CHUNK_SIZE * world.CHUNK_SIZE * (world.CHUNK_SIZE - 1) + 6 * world.CHUNK_SIZE * world.CHUNK_SIZE
#assert(MAX_FACES * 4 <= 65536, "worst-case chunk must fit u16 indices")

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
// without lighting: top brightest, bottom darkest. Applied by the shader
// (shade_table), not stored in vertices.
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
// Per vertex, look at the 2x2 cells around that corner in the layer on the
// face's open side: the face's own `front` cell, two "side" cells next to it
// and the diagonal "corner" cell. They form two diagonal pairs, (side1,
// side2) and (front, corner):
//   ao = 0 if either pair is fully occluding (enclosed),
//   else 3 - (side1 + side2 + corner + front).
// 3 = fully lit, 0 = darkest. Symmetric in the 4 cells, so coplanar faces
// sharing a corner always agree (no seams). The front cell only occludes
// when it's a cutout block that casts AO (leaves): an opaque one would have
// culled the face, and with air in front this is exactly the classic rule
// (Mikola Lysenko, "Ambient occlusion for Minecraft-like worlds", 0fps.net).
@(rodata)
AO_BRIGHTNESS := [4]f32{0.45, 0.65, 0.82, 1.0}

// Vertex brightness for each face direction and AO value, index
// int(face) * 4 + ao, out of 1: FACE_SHADE × AO_BRIGHTNESS rounded down to
// a byte (as the old baked vertex colors were). The renderer sends it to the
// shader (`shadeTable`), which looks it up from the vertex's face and AO.
shade_table :: proc "contextless" () -> (t: [len(Face) * 4]f32) {
	for face in Face {
		for ao in 0 ..< 4 {
			t[int(face) * 4 + ao] = f32(u8(f32(FACE_SHADE[face]) * AO_BRIGHTNESS[ao])) / 255
		}
	}
	return
}

vertex_ao :: #force_inline proc "contextless" (side1, side2, corner: bool, front := false) -> u8 {
	if (side1 && side2) || (front && corner) {
		return 0
	}
	return 3 - u8(side1) - u8(side2) - u8(corner) - u8(front)
}

// ---- Padded block grid ---------------------------------------------------------
// The chunk plus a 1-block border from all 26 neighbors: block IDs plus the
// properties culling and AO read, looked up once per cell while filling (the
// face loops then read one byte per neighbor, as fast as the old bool grid).
// Culling and AO both read it at fixed offsets, so no lookup ever has to
// branch on chunk borders. Index: x + z*P + y*P*P with x, y, z in 0..17
// (padded coords = chunk-local coords + 1).
P  :: world.CHUNK_SIZE + 2
P3 :: P * P * P
Padded :: struct {
	ids:   [P3]world.Block_ID,
	flags: [P3]world.Block_Flags,
	light: [P3]u8, // world light bytes (sky | block << 4); opaque cells are never read
}

padded_index :: #force_inline proc "contextless" (p: [3]i32) -> int {
	return int(p.x + p.z * P + p.y * P * P)
}

// Fills `pad` from a neighborhood. Missing (nil) chunks are air. `light`
// nil = full sky light everywhere (tests); missing chunks in it are full sky.
fill_padded :: proc(pad: ^Padded, n: ^Neighborhood, light: ^world.Light_Neighborhood = nil) {
	pad.ids = {} // AIR
	pad.flags = {} // no flags
	for &l in pad.light {
		l = world.SKY_LIGHT_FULL
	}
	for i in 0 ..< len(Neighborhood) {
		c := n[i]
		if c == nil {
			continue
		}
		lref := light[i] if light != nil else world.Light_Ref{nil, .Sky}
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
					ci := world.chunk_index(x, y, z)
					id := c.blocks[ci]
					pi := padded_index(pp)
					pad.ids[pi] = id
					pad.flags[pi] = world.block_flags(id)
					pad.light[pi] = world.light_ref_get(lref, ci)
				}
			}
		}
	}
}

// ---- Meshing ---------------------------------------------------------------------

// Neighborhood alias for convenience.
Neighborhood :: world.Neighborhood

// Rebuilds `out` (every pass) for the center chunk of `n`, lit by `light`
// (the same neighborhood's light; nil = full sky light). Only reads them. Missing
// neighbors are treated as air (the renderer only meshes chunks whose 6 face
// neighbors are loaded; missing edge/corner neighbors only affect AO).
// `out` is cleared, not freed, so reusing the same Mesh_Data across calls
// avoids reallocating once its buffers have grown.
build_chunk_mesh_neighborhood :: proc(n: ^Neighborhood, out: ^Chunk_Mesh, light: ^world.Light_Neighborhood = nil) {
	for &m in out {
		clear(&m.vertices)
	}

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
	fill_padded(&pad, n, light)

	// Loop order matches the block array layout (x fastest) for cache locality.
	for y in i32(0) ..< world.CHUNK_SIZE {
		for z in i32(0) ..< world.CHUNK_SIZE {
			for x in i32(0) ..< world.CHUNK_SIZE {
				id := world.chunk_get(chunk, x, y, z)
				if world.block_props(id).render == .None {
					continue
				}
				dst := &out[block_pass(id)]
				flags := world.block_flags(id)
				cull_same := .Cull_Same in flags
				pos := [3]i32{x, y, z}
				pp := pos + 1
				if .Fluid in flags {
					emit_fluid_faces(dst, &pad, pos, id)
					continue
				}
				for face in Face {
					// Same rule as world.face_visible (tested to agree).
					ni := padded_index(pp + world.FACE_NORMALS[face])
					if .Opaque in pad.flags[ni] || (cull_same && pad.ids[ni] == id) {
						continue // hidden by the neighbor block
					}
					emit_face(dst, &pad, pos, face, id, 0, 1)
				}
			}
		}
	}
}

// Convenience for callers that only have face neighbors (tests): edge and
// corner neighbors are treated as air.
build_chunk_mesh :: proc(chunk: ^world.Chunk, neighbors: ^Neighbors, out: ^Chunk_Mesh) {
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

// AO value (0..3) and smooth sky light (0..MAX_VERTEX_LIGHT) of each of a
// face's 4 corners, in FACE_CORNERS order. Both read the same 2x2 cells per
// corner (see "Ambient occlusion" above).
//
// Smooth light (Minecraft's): the average sky light of those cells that
// aren't opaque (opaque cells hold no light); if both side cells are opaque
// the corner cell is hidden behind them and left out too. The front cell is
// always counted: a visible face's front is never opaque, except a fluid's
// lowered top under a block, which uses the fluid's own cell instead.
// `want_ao` = false gives ao 3 (translucent faces).
face_shading :: proc "contextless" (pad: ^Padded, pos: [3]i32, face: Face, want_ao: bool) -> (ao, light: [4]u8) {
	n := world.FACE_NORMALS[face]
	// The layer of blocks on the face's open side.
	front := pos + 1 + n
	fi := padded_index(front)
	// The face's own front cell (leaves can cover a face and still cast AO).
	front_block := .Casts_AO in pad.flags[fi]
	front_light := pad.light[fi]
	if .Opaque in pad.flags[fi] {
		front_light = pad.light[padded_index(pos + 1)]
	}
	front_sky := u32(world.light_sky(front_light))
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
		i1 := padded_index(front + s1)
		i2 := padded_index(front + s2)
		ic := padded_index(front + s1 + s2)
		f1, f2, fc := pad.flags[i1], pad.flags[i2], pad.flags[ic]
		if want_ao {
			ao[i] = vertex_ao(.Casts_AO in f1, .Casts_AO in f2, .Casts_AO in fc, front_block)
		} else {
			ao[i] = 3
		}
		sum, count := front_sky, u32(1)
		open1, open2 := .Opaque not_in f1, .Opaque not_in f2
		if open1 {
			sum += u32(world.light_sky(pad.light[i1]))
			count += 1
		}
		if open2 {
			sum += u32(world.light_sky(pad.light[i2]))
			count += 1
		}
		if (open1 || open2) && .Opaque not_in fc {
			sum += u32(world.light_sky(pad.light[ic]))
			count += 1
		}
		light[i] = smooth_light(sum, count)
	}
	return
}

// Average of `count` (1..4) light levels summing to `sum`, in vertex light
// units (1/LIGHT_SCALE levels), rounded to nearest: exact for 1, 2 and 4
// cells.
smooth_light :: #force_inline proc "contextless" (sum, count: u32) -> u8 {
	return u8((sum * LIGHT_SCALE * 2 + count) / (count * 2))
}

// A fluid block's faces (water), per world.face_extent: a lowered top, and
// sides cut to the visible height range. Rare, so it just calls the shared
// rule instead of an inlined copy.
emit_fluid_faces :: proc(out: ^Mesh_Data, pad: ^Padded, pos: [3]i32, id: world.Block_ID) {
	UP :: [3]i32{0, 1, 0}
	pp := pos + 1
	above := pad.ids[padded_index(pp + UP)]
	for face in Face {
		np := pp + world.FACE_NORMALS[face]
		neighbor := pad.ids[padded_index(np)]
		neighbor_above := pad.ids[padded_index(np + UP)] if np.y + 1 < P else world.AIR
		lo, hi, visible := world.face_extent(id, neighbor, above, neighbor_above, face)
		if visible {
			emit_face(out, pad, pos, face, id, lo, hi)
		}
	}
}

// Emits one face of the block at `pos`. Corners at the bottom of the block
// go to height `lo`, corners at the top to `hi` (0 and 1 for a full face;
// fluids pass a lowered or partial range), and side faces' in-tile v follows
// the height so the texture isn't squashed. Translucent blocks get no AO
// (shore blocks would smudge the water surface).
emit_face :: proc(out: ^Mesh_Data, pad: ^Padded, pos: [3]i32, face: Face, id: world.Block_ID, lo, hi: f32) {
	// Heights in 1/16 block (POSITION_SCALE): exact for every extent in use
	// (0, FLUID_SURFACE = 14/16, 1).
	lo16, hi16 := u16(lo * POSITION_SCALE), u16(hi * POSITION_SCALE)
	origin := [3]u16{u16(pos.x), u16(pos.y), u16(pos.z)} * POSITION_SCALE
	tile := world.block_tile(id, face)
	ao, light := face_shading(pad, pos, face, world.block_props(id).render != .Translucent)
	side := face != .Pos_Y && face != .Neg_Y
	corners: [4]Vertex
	for corner, i in FACE_CORNERS[face] {
		c := [3]u16{u16(corner.x), u16(corner.y), u16(corner.z)} * POSITION_SCALE
		c.y = lo16 if corner.y == 0 else hi16
		uv := [2]u16{u16(FACE_UVS[i].x), u16(FACE_UVS[i].y)} * POSITION_SCALE
		if side {
			uv.y = POSITION_SCALE - c.y // v = 0 at the top of the tile
		}
		corners[i] = pack_vertex({position = origin + c, uv = uv, face = face, ao = ao[i], tile = tile, sky = light[i]})
	}
	// Each quad is two triangles (QUAD_INDICES: 0-1-2, 0-2-3), and brightness
	// is interpolated per triangle. Splitting along the wrong diagonal makes
	// AO and light look like a diagonal streak, so split along the diagonal
	// whose corners are darker in total (it keeps both triangles' gradients
	// consistent): when that's 1-3, the corners are emitted rotated by one
	// (1, 2, 3, 0), which splits along 1-3 and stays counter-clockwise.
	// Darkness = AO and light together, one AO step weighing as much as 5
	// light levels (its full range ~ light's full range).
	if corner_brightness(ao[0], light[0]) + corner_brightness(ao[2], light[2]) > corner_brightness(ao[1], light[1]) + corner_brightness(ao[3], light[3]) {
		append(&out.vertices, corners[1], corners[2], corners[3], corners[0])
	} else {
		append(&out.vertices, corners[0], corners[1], corners[2], corners[3])
	}
}

// Rough brightness of a face corner for choosing the quad split.
corner_brightness :: #force_inline proc "contextless" (ao, light: u8) -> u32 {
	return u32(ao) * 5 * LIGHT_SCALE + u32(light)
}

face_count :: proc(m: ^Mesh_Data) -> int {
	return len(m.vertices) / 4
}

// Faces in every pass.
chunk_mesh_face_count :: proc(m: ^Chunk_Mesh) -> (n: int) {
	for &p in m {
		n += face_count(&p)
	}
	return
}

chunk_mesh_destroy :: proc(m: ^Chunk_Mesh) {
	for &p in m {
		mesh_data_destroy(&p)
	}
}

mesh_data_destroy :: proc(m: ^Mesh_Data) {
	delete(m.vertices)
}
