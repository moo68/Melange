#+build linux
package world

import "base:intrinsics"
import "core:sys/linux"

// With THP set to "always", the kernel may back a 2 MB-aligned span with one
// huge page on first write, so writing one chunk would cost 2 MB of RAM.
// Failure only wastes memory, so it's ignored.
_disable_huge_pages :: proc "contextless" (data: []byte) {
	_ = linux.madvise(raw_data(data), uint(len(data)), .NOHUGEPAGE)
}

// Releases a chunk's (or its light's) RAM and guarantees it reads back as
// zero (AIR / dark).
// MADV_DONTNEED, not MADV_FREE (what virtual.decommit uses): after MADV_FREE
// the old contents may survive until the kernel gets around to reclaiming,
// which would resurrect stale blocks in a reused slot.
// `size` must be a multiple of the page size.
_zero_memory :: proc "contextless" (p: rawptr, size: int) {
	if linux.madvise(p, uint(size), .DONTNEED) != .NONE {
		intrinsics.mem_zero(p, size) // correctness fallback: zero by hand
	}
}
