package world

// ---- Light (roadmap 3) ------------------------------------------------------------
// One byte per block: sky light in the low 4 bits, block light (torches,
// roadmap 4) in the high 4. 0 = dark, 15 = full.
//
// Propagation rules (modern Minecraft):
//   - Opaque blocks (light_filter 15) hold no light.
//   - Moving to a neighbor cell costs max(1, filter of that cell): air and
//     glass 1, water and leaves 1 (but see below), so light fades by 1 per
//     block sideways and upward.
//   - Sky light at full strength (15) moves straight down through
//     filter-0 cells without fading; through water/leaves (filter 1) it loses
//     1 per block, so a seabed 15 blocks deep is dark.
//
// Generated terrain is a heightmap (no overhangs, no air below the sea), so
// its sky light is a pure function of each column: 15 above the surface and
// the sea, 14 + y - SEA_LEVEL in water, 0 in the ground (generate_light;
// tested against a flood fill). Edits change that: light_engine.odin
// relights them, and reconciles chunks as they load next to edited ones.

MAX_LIGHT :: 15

Chunk_Light :: struct {
	data: [CHUNK_VOLUME]u8, // same index as Chunk.blocks (chunk_index)
}

#assert(size_of(Chunk_Light) == 4096)

// Most chunks are uniformly lit: buried (all 0) or open air (all sky 15).
// Only Mixed chunks store their light array, so the others cost no RAM.
// Dark is the zero value: a freshly created or unloaded slot is Dark.
Light_State :: enum u8 {
	Dark, // every cell 0
	Sky, // every cell sky 15, block 0
	Mixed, // the light array holds the values
}

SKY_LIGHT_FULL :: u8(MAX_LIGHT) // a light byte with sky 15, block 0

light_sky :: #force_inline proc "contextless" (l: u8) -> u8 {
	return l & 15
}

light_block :: #force_inline proc "contextless" (l: u8) -> u8 {
	return l >> 4
}

// A chunk's light as stored: a uniform state, or a pointer to its array.
// Only valid for the current pass, like ^Chunk.
Light_Ref :: struct {
	data:  ^Chunk_Light, // only when state == .Mixed
	state: Light_State,
}

light_ref_get :: #force_inline proc "contextless" (ref: Light_Ref, index: int) -> u8 {
	switch ref.state {
	case .Dark:
		return 0
	case .Sky:
		return SKY_LIGHT_FULL
	case .Mixed:
		return ref.data.data[index]
	}
	return 0
}

// Light of a chunk and its 26 neighbors, indexed like Neighborhood.
// Missing (unloaded) chunks read as full sky light.
Light_Neighborhood :: [27]Light_Ref

// How much a block dims light passing into it: 0 (air, glass), 1 (water,
// leaves), 15 = opaque (holds no light).
block_light_filter :: #force_inline proc "contextless" (id: Block_ID) -> u8 {
	return block_props(id).light_filter
}

// Sky light of a cell of block `id` lit only from the cell above it, which
// has sky light `above` (the vertical rule above).
sky_below :: #force_inline proc "contextless" (above: u8, id: Block_ID) -> u8 {
	filter := block_light_filter(id)
	if filter >= MAX_LIGHT {
		return 0
	}
	if above == MAX_LIGHT && filter == 0 {
		return MAX_LIGHT
	}
	cost := max(filter, 1)
	return above - cost if above > cost else 0
}

// Sky light at height `wy` in an unedited generated column: 15 above the
// surface and the sea, fading by 1 per water block below the sea's top
// (water's filter is 1), 0 in the ground.
column_sky_light :: proc "contextless" (col: Column, wy: i32) -> u8 {
	if wy <= col.height {
		return 0
	}
	if wy > TERRAIN_SEA_LEVEL {
		return MAX_LIGHT
	}
	// Water from wy up to the sea level: SEA_LEVEL - wy + 1 blocks.
	depth := TERRAIN_SEA_LEVEL - wy + 1
	return u8(max(i32(MAX_LIGHT) - depth, 0))
}

// Sky light of a freshly generated chunk (before edits are applied), from
// its blocks and its column's heights (the light entering through its top).
// Pure. Writes `out` only for a Mixed result (out may be scratch memory).
generate_light :: proc(out: ^Chunk_Light, c: ^Chunk, coord: [3]i32, ch: ^Column_Heights) -> Light_State {
	bottom := coord.y * CHUNK_SIZE
	top := bottom + CHUNK_SIZE - 1
	if bottom > max(ch.max_height, TERRAIN_SEA_LEVEL) {
		return .Sky // all air under open sky (generation's own fast path)
	}
	if top < TERRAIN_ALL_STONE_BELOW {
		return .Dark // all stone
	}
	any_lit, any_dark := false, false
	for z in i32(0) ..< CHUNK_SIZE {
		for x in i32(0) ..< CHUNK_SIZE {
			l := column_sky_light(ch.columns[z][x], top + 1)
			for y := i32(CHUNK_MASK); y >= 0; y -= 1 {
				i := chunk_index(x, y, z)
				l = sky_below(l, c.blocks[i])
				out.data[i] = l
				any_dark ||= l != MAX_LIGHT
				any_lit ||= l != 0
			}
		}
	}
	if !any_lit {
		return .Dark
	}
	if !any_dark {
		return .Sky
	}
	return .Mixed
}

// ---- World access --------------------------------------------------------------

// The stored light of a loaded chunk; ok = false if it isn't loaded.
world_get_light_ref :: proc(w: ^World, coord: [3]i32) -> (ref: Light_Ref, ok: bool) {
	r, i := find_slot(w, coord)
	if r == nil {
		return {}, false
	}
	return region_light_ref(r, i), true
}

@(private)
region_light_ref :: #force_inline proc "contextless" (r: ^Region, i: int) -> Light_Ref {
	state := r.light_state[i]
	return {&r.light[i] if state == .Mixed else nil, state}
}

// Sets a loaded chunk's light: a uniform state, or (Mixed) a copy of `src`.
// Only Mixed chunks touch their light memory. Doesn't mark anything dirty
// (world_create_chunk already did, for a new chunk).
world_set_chunk_light :: proc(w: ^World, coord: [3]i32, state: Light_State, src: ^Chunk_Light) {
	r, i := find_slot(w, coord)
	if r == nil {
		return
	}
	if state == .Mixed {
		r.light[i] = src^
	} else if r.light_state[i] == .Mixed {
		_zero_memory(&r.light[i], size_of(Chunk_Light))
	}
	if (state == .Mixed) != (r.light_state[i] == .Mixed) {
		w.light_mixed_count += 1 if state == .Mixed else -1
	}
	r.light_state[i] = state
}

// Light byte of a block; ok = false if its chunk isn't loaded.
world_get_light :: proc(w: ^World, b: [3]i32) -> (light: u8, ok: bool) {
	ref := world_get_light_ref(w, block_to_chunk(b)) or_return
	l := block_to_local(b)
	return light_ref_get(ref, chunk_index(l.x, l.y, l.z)), true
}

// The light of `coord` and its 26 neighbors (missing chunks: full sky).
world_get_light_neighborhood :: proc(w: ^World, coord: [3]i32) -> (out: Light_Neighborhood) {
	r := w.regions[chunk_to_region(coord)]
	local := chunk_to_region_local(coord)
	for i in 0 ..< len(out) {
		off := neighborhood_offset(i)
		n := local + off
		out[i] = {nil, .Sky}
		if r != nil && u32(n.x) < REGION_SIZE && u32(n.y) < REGION_SIZE && u32(n.z) < REGION_SIZE {
			slot := region_index(n)
			if r.loaded[slot] {
				out[i] = region_light_ref(r, slot)
			}
		} else if ref, ok := world_get_light_ref(w, coord + off); ok {
			out[i] = ref
		}
	}
	return
}
