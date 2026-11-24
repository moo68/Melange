package world

import "core:mem"
import "core:mem/virtual"

// A region is an 8³ block of chunks stored contiguously in one virtual memory
// mapping (4 MB reserved). Pages get physical RAM only when written, so
// unwritten/air chunks cost nothing. See CLAUDE.md "Region memory rules".
REGION_SIZE   :: 8
REGION_SHIFT  :: 3
REGION_MASK   :: REGION_SIZE - 1
REGION_VOLUME :: REGION_SIZE * REGION_SIZE * REGION_SIZE

#assert(1 << REGION_SHIFT == REGION_SIZE)

REGION_BYTES :: size_of([REGION_VOLUME]Chunk)
REGION_LIGHT_BYTES :: size_of([REGION_VOLUME]Chunk_Light)

Region :: struct {
	// OS-mapped, zero-filled, page-aligned. Never touch it directly from outside
	// world/: a slot is only valid while loaded[i] is true.
	chunks:       ^[REGION_VOLUME]Chunk,
	// Light, in a second mapping with the same rules (4 KB per chunk, one
	// page). Only .Mixed slots are ever written (light.odin).
	light:        ^[REGION_VOLUME]Chunk_Light,
	// Metadata kept out of Chunk so chunks stay exactly 8 KB / page-aligned.
	loaded:       [REGION_VOLUME]bool,
	dirty:        [REGION_VOLUME]bool,
	light_state:  [REGION_VOLUME]Light_State,
	loaded_count: int,
}

// Index of a chunk inside its region; same x -> z -> y order as blocks.
region_index :: #force_inline proc "contextless" (local: [3]i32) -> int {
	return int(local.x + local.z * REGION_SIZE + local.y * REGION_SIZE * REGION_SIZE)
}

region_local_from_index :: #force_inline proc "contextless" (i: int) -> [3]i32 {
	n := i32(i)
	return {n & REGION_MASK, n >> (2 * REGION_SHIFT), (n >> REGION_SHIFT) & REGION_MASK}
}

region_create :: proc(allocator: mem.Allocator) -> (r: ^Region, err: mem.Allocator_Error) {
	r = new(Region, allocator) or_return
	// reserve_and_commit, never reserve alone: reserved-only memory is
	// PROT_NONE and reading it segfaults.
	data, verr := virtual.reserve_and_commit(REGION_BYTES)
	if verr != nil {
		free(r, allocator)
		return nil, verr
	}
	light, lerr := virtual.reserve_and_commit(REGION_LIGHT_BYTES)
	if lerr != nil {
		virtual.release(raw_data(data), REGION_BYTES)
		free(r, allocator)
		return nil, lerr
	}
	// Must happen before anything touches the mappings.
	_disable_huge_pages(data)
	_disable_huge_pages(light)
	r.chunks = cast(^[REGION_VOLUME]Chunk)raw_data(data)
	r.light = cast(^[REGION_VOLUME]Chunk_Light)raw_data(light)
	return r, nil
}

region_destroy :: proc(r: ^Region, allocator: mem.Allocator) {
	virtual.release(r.chunks, REGION_BYTES)
	virtual.release(r.light, REGION_LIGHT_BYTES)
	free(r, allocator)
}
