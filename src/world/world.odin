package world

import "core:mem"

// All loaded chunks, grouped into regions keyed by region coord.
// Everything outside world/ goes through these procs; nothing else touches
// Region memory directly.
World :: struct {
	regions:   map[[3]i32]^Region,
	seed:      i64, // terrain generation seed
	allocator: mem.Allocator,
}

world_init :: proc(w: ^World, seed: i64 = 0, allocator := context.allocator) {
	w.seed = seed
	w.allocator = allocator
	w.regions = make(map[[3]i32]^Region, allocator)
}

world_destroy :: proc(w: ^World) {
	for _, r in w.regions {
		region_destroy(r, w.allocator)
	}
	delete(w.regions)
	w^ = {}
}

// ---- Coordinate conversions -------------------------------------------------
// Arithmetic shift / mask = floor division / modulo, correct for negatives:
// block -1 -> chunk -1, local 15.

block_to_chunk :: #force_inline proc "contextless" (b: [3]i32) -> [3]i32 {
	return {b.x >> CHUNK_SHIFT, b.y >> CHUNK_SHIFT, b.z >> CHUNK_SHIFT}
}

block_to_local :: #force_inline proc "contextless" (b: [3]i32) -> [3]i32 {
	return b & CHUNK_MASK
}

chunk_to_region :: #force_inline proc "contextless" (c: [3]i32) -> [3]i32 {
	return {c.x >> REGION_SHIFT, c.y >> REGION_SHIFT, c.z >> REGION_SHIFT}
}

chunk_to_region_local :: #force_inline proc "contextless" (c: [3]i32) -> [3]i32 {
	return c & REGION_MASK
}

// World block coord of a chunk's (0, 0, 0) corner.
chunk_origin :: #force_inline proc "contextless" (c: [3]i32) -> [3]i32 {
	return c * CHUNK_SIZE
}

// ---- Chunks -----------------------------------------------------------------

// Region and slot index of a chunk, or nil if it isn't loaded.
@(private)
find_slot :: proc(w: ^World, coord: [3]i32) -> (^Region, int) {
	r := w.regions[chunk_to_region(coord)]
	if r == nil {
		return nil, 0
	}
	i := region_index(chunk_to_region_local(coord))
	if !r.loaded[i] {
		return nil, 0
	}
	return r, i
}

// nil if the chunk isn't loaded. This is the ONLY way to tell whether a chunk
// exists: unloaded slots still read as air, so block data can't tell you.
// The pointer is valid until the chunk is unloaded; don't keep it across frames.
world_get_chunk :: proc(w: ^World, coord: [3]i32) -> ^Chunk {
	r, i := find_slot(w, coord)
	if r == nil {
		return nil
	}
	return &r.chunks[i]
}

// Loads an empty (all-air) chunk, or returns the existing one. Marks it and
// its loaded neighbors dirty, so fill it before the next mesh pass.
world_create_chunk :: proc(w: ^World, coord: [3]i32) -> (chunk: ^Chunk, err: mem.Allocator_Error) {
	key := chunk_to_region(coord)
	r := w.regions[key]
	if r == nil {
		r = region_create(w.allocator) or_return
		w.regions[key] = r
	}
	i := region_index(chunk_to_region_local(coord))
	if !r.loaded[i] {
		// The slot is guaranteed zero: fresh mapping, or zeroed on unload.
		r.loaded[i] = true
		r.loaded_count += 1
		r.dirty[i] = true
		mark_neighbors_dirty(w, coord)
	}
	return &r.chunks[i], nil
}

// Unloads a chunk: its memory goes back to the OS and reads as air again.
// The region is released when its last chunk unloads, which invalidates every
// pointer into it.
world_unload_chunk :: proc(w: ^World, coord: [3]i32) {
	r, i := find_slot(w, coord)
	if r == nil {
		return
	}
	_zero_chunk_memory(&r.chunks[i])
	r.loaded[i] = false
	r.dirty[i] = false
	r.loaded_count -= 1
	// Neighbors' border faces toward this chunk are now exposed.
	mark_neighbors_dirty(w, coord)
	if r.loaded_count == 0 {
		region_destroy(r, w.allocator)
		delete_key(&w.regions, chunk_to_region(coord))
	}
}

// The six chunks touching `coord`. Neighbors in the same region are found by
// index; only those across a region border need a map lookup.
world_get_neighbors :: proc(w: ^World, coord: [3]i32) -> (out: Neighbors) {
	r := w.regions[chunk_to_region(coord)]
	local := chunk_to_region_local(coord)
	for face in Face {
		n := local + FACE_NORMALS[face]
		if r != nil && u32(n.x) < REGION_SIZE && u32(n.y) < REGION_SIZE && u32(n.z) < REGION_SIZE {
			i := region_index(n)
			out[face] = &r.chunks[i] if r.loaded[i] else nil
		} else {
			out[face] = world_get_chunk(w, coord + FACE_NORMALS[face])
		}
	}
	return
}

// `coord` and the 26 chunks around it. Same-region chunks by index; only
// those across a region border need a map lookup.
world_get_neighborhood :: proc(w: ^World, coord: [3]i32) -> (out: Neighborhood) {
	r := w.regions[chunk_to_region(coord)]
	local := chunk_to_region_local(coord)
	for i in 0 ..< len(out) {
		off := neighborhood_offset(i)
		n := local + off
		if r != nil && u32(n.x) < REGION_SIZE && u32(n.y) < REGION_SIZE && u32(n.z) < REGION_SIZE {
			slot := region_index(n)
			out[i] = &r.chunks[slot] if r.loaded[slot] else nil
		} else {
			out[i] = world_get_chunk(w, coord + off)
		}
	}
	return
}

world_loaded_chunk_count :: proc(w: ^World) -> int {
	total := 0
	for _, r in w.regions {
		total += r.loaded_count
	}
	return total
}

// True if all six neighbors are loaded. Chunks are only meshed when this
// holds, so their border faces are always culled against real data.
neighbors_complete :: proc "contextless" (n: ^Neighbors) -> bool {
	for c in n {
		if c == nil {
			return false
		}
	}
	return true
}

// Appends the coords of all loaded chunks to `out` (not cleared first).
world_collect_loaded :: proc(w: ^World, out: ^[dynamic][3]i32) {
	for key, r in w.regions {
		for i in 0 ..< REGION_VOLUME {
			if r.loaded[i] {
				append(out, key * REGION_SIZE + region_local_from_index(i))
			}
		}
	}
}

// ---- Dirty tracking (chunk needs re-meshing) --------------------------------

world_mark_dirty :: proc(w: ^World, coord: [3]i32) {
	r, i := find_slot(w, coord)
	if r != nil {
		r.dirty[i] = true
	}
}

world_is_dirty :: proc(w: ^World, coord: [3]i32) -> bool {
	r, i := find_slot(w, coord)
	return r != nil && r.dirty[i]
}

world_clear_dirty :: proc(w: ^World, coord: [3]i32) {
	r, i := find_slot(w, coord)
	if r != nil {
		r.dirty[i] = false
	}
}

// Appends the coords of all loaded dirty chunks to `out` (not cleared first).
world_collect_dirty :: proc(w: ^World, out: ^[dynamic][3]i32) {
	for key, r in w.regions {
		for i in 0 ..< REGION_VOLUME {
			if r.loaded[i] && r.dirty[i] {
				append(out, key * REGION_SIZE + region_local_from_index(i))
			}
		}
	}
}

// All 26 surrounding chunks: their meshes read this chunk's border blocks
// (faces for culling, edges/corners for AO).
@(private)
mark_neighbors_dirty :: proc(w: ^World, coord: [3]i32) {
	for i in 0 ..< len(Neighborhood) {
		if i != neighborhood_index({0, 0, 0}) {
			world_mark_dirty(w, coord + neighborhood_offset(i))
		}
	}
}

// ---- Blocks (world block coords) --------------------------------------------

// ok = false if the block's chunk isn't loaded.
world_get_block :: proc(w: ^World, b: [3]i32) -> (id: Block_ID, ok: bool) {
	c := world_get_chunk(w, block_to_chunk(b))
	if c == nil {
		return AIR, false
	}
	l := block_to_local(b)
	return chunk_get(c, l.x, l.y, l.z), true
}

// Returns false (and does nothing) if the block's chunk isn't loaded.
// Marks the chunk dirty, plus every neighbor chunk whose mesh reads this
// block: on a chunk face that's 1 neighbor, on an edge 3, on a corner 7
// (meshes read a 1-block border all around, for culling and AO). Setting a block to its current value writes nothing, so setting air
// on untouched memory doesn't allocate RAM.
world_set_block :: proc(w: ^World, b: [3]i32, id: Block_ID) -> bool {
	coord := block_to_chunk(b)
	r, i := find_slot(w, coord)
	if r == nil {
		return false
	}
	l := block_to_local(b)
	c := &r.chunks[i]
	if chunk_get(c, l.x, l.y, l.z) == id {
		return true
	}
	chunk_set(c, l.x, l.y, l.z, id)
	r.dirty[i] = true

	// Per axis: 0 always, plus -1/+1 if the block is on that border.
	lo, hi: [3]i32
	for axis in 0 ..< 3 {
		lo[axis] = -1 if l[axis] == 0 else 0
		hi[axis] = 1 if l[axis] == CHUNK_MASK else 0
	}
	for dy in lo.y ..= hi.y {
		for dz in lo.z ..= hi.z {
			for dx in lo.x ..= hi.x {
				if dx != 0 || dy != 0 || dz != 0 {
					world_mark_dirty(w, coord + {dx, dy, dz})
				}
			}
		}
	}
	return true
}
