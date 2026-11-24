package mesh

import "melange:world"

// ---- Packed vertex format (8 bytes) ----------------------------------------------
// Four u16 words. The GPU reads them as one vec4 attribute (unsigned shorts,
// not normalized: exact floats up to 65535) and chunk.vs converts back to
// integers and unpacks the bit fields; unpack_vertex is its CPU mirror
// (keep the two in sync):
//
//   word 0: x (9 bits) | u (5) << 9                   (2 bits spare)
//   word 1: y (9)      | v (5) << 9  | ao (2) << 14
//   word 2: z (9)      | face (3) << 9 | sky light (4) << 12
//   word 3: tile (8)   | block light (4) << 8          (4 bits spare)
//
// Positions are chunk-local in 1/16 block (0..256), in-tile UVs in 1/16 of
// the tile (0..16), so water's 14/16 top and future 8/16 slabs are exact.
// Light (0..15) is reserved for sky light / block light (roadmap 3–4).

Vertex :: [4]u16

// Units per block for positions and per tile for UVs.
POSITION_SCALE :: 16
MAX_POSITION   :: world.CHUNK_SIZE * POSITION_SCALE // 256: fits 9 bits
MAX_LIGHT      :: 15

#assert(MAX_POSITION < 1 << 9)
#assert(POSITION_SCALE < 1 << 5)
#assert(len(Face) <= 1 << 3)

Unpacked_Vertex :: struct {
	position: [3]u16, // 0..MAX_POSITION, in 1/POSITION_SCALE block
	uv:       [2]u16, // 0..POSITION_SCALE (u, v within the tile; v = 0 at the top)
	face:     Face,
	ao:       u8, // 0..3 (3 = fully lit)
	tile:     world.Tile,
	sky:      u8, // 0..MAX_LIGHT
	block:    u8, // 0..MAX_LIGHT
}

pack_vertex :: #force_inline proc "contextless" (v: Unpacked_Vertex) -> Vertex {
	return {
		v.position.x | v.uv.x << 9,
		v.position.y | v.uv.y << 9 | u16(v.ao) << 14,
		v.position.z | u16(v.face) << 9 | u16(v.sky) << 12,
		u16(v.tile) | u16(v.block) << 8,
	}
}

unpack_vertex :: proc "contextless" (w: Vertex) -> (v: Unpacked_Vertex) {
	v.position = {w.x & 511, w.y & 511, w.z & 511}
	v.uv = {(w.x >> 9) & 31, (w.y >> 9) & 31}
	v.ao = u8(w.y >> 14)
	v.face = Face((w.z >> 9) & 7)
	v.sky = u8((w.z >> 12) & 15)
	v.tile = world.Tile(w.w & 255)
	v.block = u8((w.w >> 8) & 15)
	return
}

// The vertex's chunk-local position in blocks.
vertex_position :: proc "contextless" (w: Vertex) -> [3]f32 {
	p := unpack_vertex(w).position
	return {f32(p.x), f32(p.y), f32(p.z)} / POSITION_SCALE
}

// The two triangles of every face, as offsets into its 4 vertices
// (counter-clockwise).
QUAD_INDICES :: [6]u16{0, 1, 2, 0, 2, 3}

// Fills `out` with QUAD_INDICES for consecutive faces (face f's vertices
// start at 4f): the index buffer every chunk mesh shares. len(out) must be
// a multiple of 6 and at most MAX_FACES * 6.
quad_indices :: proc(out: []u16) {
	for f in 0 ..< len(out) / 6 {
		for k, i in QUAD_INDICES {
			out[f * 6 + i] = u16(f * 4) + k
		}
	}
}
