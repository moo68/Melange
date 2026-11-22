#+build linux
package world

import "core:sys/linux"

// With THP set to "always", the kernel may back a 2 MB-aligned span with one
// huge page on first write, so writing one chunk would cost 2 MB of RAM.
// Failure only wastes memory, so it's ignored.
_disable_huge_pages :: proc "contextless" (data: []byte) {
	_ = linux.madvise(raw_data(data), uint(len(data)), .NOHUGEPAGE)
}

// Releases a chunk's RAM and guarantees it reads back as zero (AIR).
// MADV_DONTNEED, not MADV_FREE (what virtual.decommit uses): after MADV_FREE
// the old contents may survive until the kernel gets around to reclaiming,
// which would resurrect stale blocks in a reused slot.
_zero_chunk_memory :: proc "contextless" (c: ^Chunk) {
	if linux.madvise(c, size_of(Chunk), .DONTNEED) != .NONE {
		c^ = {} // correctness fallback: zero by hand
	}
}
