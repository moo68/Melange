#+build !linux
package world

// Portable fallbacks: correct, but without the RAM savings of the Linux path.

_disable_huge_pages :: proc "contextless" (data: []byte) {}

_zero_chunk_memory :: proc "contextless" (c: ^Chunk) {
	c^ = {}
}
