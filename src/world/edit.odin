package world

import "melange:geom"

// Block-editing rules, independent of input (player/edit.odin maps mouse
// buttons onto these).

// Loaded and solid: what block picking can hit. Unloaded chunks count as empty.
world_is_solid :: proc(w: ^World, b: [3]i32) -> bool {
	id, loaded := world_get_block(w, b)
	return loaded && block_is_solid(id)
}

// What stops a moving body: solid blocks and, unlike picking, chunks that
// aren't loaded yet, so nobody falls or walks into ungenerated space.
world_blocks_movement :: proc(w: ^World, b: [3]i32) -> bool {
	id, loaded := world_get_block(w, b)
	return !loaded || block_is_solid(id)
}

// Breaks (sets to air) the block a ray hit. Returns false if nothing changed.
world_break_block :: proc(w: ^World, hit: geom.Ray_Hit) -> bool {
	if !world_is_solid(w, hit.block) {
		return false
	}
	return world_set_block(w, hit.block, AIR)
}

// Places `id` in the cell in front of the face a ray hit, if that cell is
// air or Replaceable (water). Refused (returns false) if the ray started
// inside a block, the cell overlaps `keep_clear` (the player's box), the
// cell holds anything else, or it isn't loaded.
world_place_block :: proc(w: ^World, hit: geom.Ray_Hit, id: Block_ID, keep_clear: geom.AABB) -> bool {
	cell, ok := geom.place_cell(hit)
	if !ok || geom.aabb_overlaps_cell(keep_clear, cell) {
		return false
	}
	if current, _ := world_get_block(w, cell); current != AIR && .Replaceable not_in block_flags(current) {
		return false
	}
	return world_set_block(w, cell, id) // refuses unloaded chunks (which read as air)
}
