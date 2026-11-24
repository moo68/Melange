#+build !linux
package world

import "base:intrinsics"

// Portable fallbacks: correct, but without the RAM savings of the Linux path.

_disable_huge_pages :: proc "contextless" (data: []byte) {}

_zero_memory :: proc "contextless" (p: rawptr, size: int) {
	intrinsics.mem_zero(p, size)
}
