package world

import "melange:geom"

// Block-editing rules, independent of input (player/edit.odin maps mouse
// buttons onto these).

// Loaded and opaque: what block picking can hit. Unloaded chunks count as empty.
world_is_solid :: proc(w: ^World, b: [3]i32) -> bool {
	id, loaded := world_get_block(w, b)
	return loaded && block_is_opaque(id)
}

// Breaks (sets to air) the block a ray hit. Returns false if nothing changed.
world_break_block :: proc(w: ^World, hit: geom.Ray_Hit) -> bool {
	if !world_is_solid(w, hit.block) {
		return false
	}
	return world_set_block(w, hit.block, AIR)
}

// Places `id` in the empty cell in front of the face a ray hit. Refused
// (returns false) if the ray started inside a block, the cell is `blocked`
// (the player's eye; step 3 replaces this with the player's AABB), or the
// cell isn't loaded air.
world_place_block :: proc(w: ^World, hit: geom.Ray_Hit, id: Block_ID, blocked: [3]i32) -> bool {
	cell, ok := geom.place_cell(hit)
	if !ok || cell == blocked {
		return false
	}
	if current, _ := world_get_block(w, cell); current != AIR {
		return false
	}
	return world_set_block(w, cell, id) // refuses unloaded chunks (which read as air)
}
