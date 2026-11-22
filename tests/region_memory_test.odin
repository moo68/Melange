#+build linux
package tests

import "core:sys/linux"
import "core:testing"
import "melange:world"

PAGE :: 4096

// Number of 4 KB pages in [data, data+size) that currently have physical RAM.
resident_pages :: proc(t: ^testing.T, data: rawptr, size: int) -> int {
	vec := make([]b8, size / PAGE)
	defer delete(vec)
	err := linux.mincore(data, uint(size), vec)
	testing.expect_value(t, err, linux.Errno.NONE)
	n := 0
	for p in vec {
		if p {
			n += 1
		}
	}
	return n
}

// The whole point of regions: RAM follows what's written, not the 4 MB
// reservation. Also catches transparent huge pages (THP=always on this
// machine) silently backing one write with a 2 MB page.
//
// Note: mincore also reports pages that were only *read* (they're mapped to
// the kernel's shared zero page, which costs no RAM). So this test only does
// writes; it can't distinguish read-only zero pages from real ones.
@(test)
region_ram_follows_writes :: proc(t: ^testing.T) {
	w: world.World
	world.world_init(&w)
	defer world.world_destroy(&w)

	_, _ = world.world_create_chunk(&w, {0, 0, 0})
	_, _ = world.world_create_chunk(&w, {1, 0, 0})
	r := w.regions[{0, 0, 0}]
	testing.expect_value(t, resident_pages(t, r.chunks, world.REGION_BYTES), 0)

	// One real write: one page, not 512 (a huge page).
	world.world_set_block(&w, {0, 0, 0}, world.STONE)
	testing.expect_value(t, resident_pages(t, r.chunks, world.REGION_BYTES), 1)

	// Filling a whole chunk: exactly its two pages.
	c := world.world_get_chunk(&w, {1, 0, 0})
	for &b in c.blocks {
		b = world.STONE
	}
	testing.expect_value(t, resident_pages(t, c, size_of(world.Chunk)), 2)
	testing.expect_value(t, resident_pages(t, r.chunks, world.REGION_BYTES), 3)

	// Unloading gives the RAM back immediately.
	world.world_unload_chunk(&w, {1, 0, 0})
	testing.expect_value(t, resident_pages(t, r.chunks, world.REGION_BYTES), 1)
}
