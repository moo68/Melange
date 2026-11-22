package world

CHUNK_SIZE   :: 16
CHUNK_SHIFT  :: 4
CHUNK_MASK   :: CHUNK_SIZE - 1
CHUNK_VOLUME :: CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE

#assert(1 << CHUNK_SHIFT == CHUNK_SIZE)

// Block data is always one flat array, x fastest, then z, then y.
// A chunk is nothing but its blocks: exactly 8 KB = two 4 KB pages, so chunks
// packed in a region stay page-aligned and each one is backed by RAM
// independently. Per-chunk metadata lives in Region, not here.
Chunk :: struct {
	blocks: [CHUNK_VOLUME]Block_ID,
}

#assert(size_of(Chunk) == 8192)

// Local coords are i32 so neighbor offsets (x - 1, etc.) can go out of range
// and be checked with chunk_in_bounds instead of wrapping.
chunk_index :: #force_inline proc "contextless" (x, y, z: i32) -> int {
	return int(x + z * CHUNK_SIZE + y * CHUNK_SIZE * CHUNK_SIZE)
}

chunk_in_bounds :: #force_inline proc "contextless" (x, y, z: i32) -> bool {
	return u32(x) < CHUNK_SIZE && u32(y) < CHUNK_SIZE && u32(z) < CHUNK_SIZE
}

chunk_get :: #force_inline proc "contextless" (c: ^Chunk, x, y, z: i32) -> Block_ID {
	return c.blocks[chunk_index(x, y, z)]
}

chunk_set :: #force_inline proc "contextless" (c: ^Chunk, x, y, z: i32, id: Block_ID) {
	c.blocks[chunk_index(x, y, z)] = id
}
