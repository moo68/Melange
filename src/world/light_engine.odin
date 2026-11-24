package world

import "core:mem"
import "core:time"
import "melange:prof"

// ---- Relighting (roadmap 3b) --------------------------------------------------------
// Keeps sky light correct when blocks change (runtime edits, and the edit
// log applied when a chunk loads) and when a chunk loads next to others.
// The standard two-queue flood fill, with light.odin's rules:
//
//   1. Removal: each changed cell's light is cleared and it's queued with its
//      old value. Popping (cell, old): a loaded neighbor that depended on it
//      (dimmer than `old`, or full sky directly below a full-sky cell) is
//      cleared and queued the same way; a neighbor at least as bright is a
//      refill source (it's lit by something else).
//   2. Refill: popping a cell spreads its current light to its neighbors
//      (straight-down sky rule, else max(1, filter) per step); every cell
//      it raises is queued in turn.
//
// All removals run before any refill, so refill sources queued earlier
// whose light was since removed simply spread nothing. The engine reads
// and writes the world only through slots looked up per call (no pointers
// kept between calls) and never writes to unloaded chunks: light stops at
// them. Work is queued (world_set_block, world_light_chunk_loaded) and done
// by world_update_light, once per frame: a single entry point, so it could
// later run on its own thread.
//
// Generated chunks get their light from generate_light, which assumes every
// chunk above is unedited terrain. That's exact except where a loaded chunk
// differs (edits): world_light_chunk_loaded reconciles a new chunk with its
// loaded neighbors.

Light_Node :: struct {
	pos:   [3]i32, // world block coords
	light: u8, // sky light the cell had before it was cleared
}

Light_Stats :: struct {
	changes: int, // changed cells processed by the last update that did work
	removed: int, // cells cleared by it
	raised:  int, // cells raised by its refill
	time:    time.Duration,
}

Light_Engine :: struct {
	changes: [dynamic][3]i32, // cells whose block changed since the last update
	removal: [dynamic]Light_Node, // removal queue (also accepts seeds directly)
	refill:  [dynamic][3]i32, // refill queue / sources
	stats:   Light_Stats,
}

light_engine_init :: proc(e: ^Light_Engine, allocator: mem.Allocator) {
	e.changes = make([dynamic][3]i32, allocator)
	e.removal = make([dynamic]Light_Node, allocator)
	e.refill = make([dynamic][3]i32, allocator)
}

light_engine_destroy :: proc(e: ^Light_Engine) {
	delete(e.changes)
	delete(e.removal)
	delete(e.refill)
}

// Whether relight work is queued.
world_light_pending :: proc(w: ^World) -> bool {
	e := &w.lighting
	return len(e.changes) > 0 || len(e.removal) > 0 || len(e.refill) > 0
}

// Light a cell gets from a neighbor with sky light `from`: straight down
// (`down`) by sky_below, else dimmed by max(1, filter); 0 into opaque blocks.
light_spread :: #force_inline proc "contextless" (from: u8, id: Block_ID, down: bool) -> u8 {
	if down {
		return sky_below(from, id)
	}
	filter := block_light_filter(id)
	if filter >= MAX_LIGHT {
		return 0
	}
	cost := max(filter, 1)
	return from - cost if from > cost else 0
}

// ---- Cell access -------------------------------------------------------------
// One-chunk cache: consecutive cells are mostly in the same chunk. Only valid
// within one call (chunks don't load or unload meanwhile).

@(private = "file")
Cursor :: struct {
	coord: [3]i32,
	r:     ^Region,
	slot:  int,
	valid: bool,
}

@(private = "file")
Cell :: struct {
	r:     ^Region,
	slot:  int,
	index: int, // chunk_index within the chunk
	local: [3]i32,
	coord: [3]i32, // chunk coord
}

@(private = "file")
locate :: #force_inline proc(w: ^World, cur: ^Cursor, p: [3]i32) -> (cell: Cell, ok: bool) {
	coord := block_to_chunk(p)
	if !cur.valid || coord != cur.coord {
		cur.r, cur.slot = find_slot(w, coord)
		cur.coord = coord
		cur.valid = true
	}
	if cur.r == nil {
		return {}, false
	}
	l := block_to_local(p)
	return {cur.r, cur.slot, chunk_index(l.x, l.y, l.z), l, coord}, true
}

@(private = "file")
cell_sky :: #force_inline proc "contextless" (c: Cell) -> u8 {
	return light_sky(light_ref_get(region_light_ref(c.r, c.slot), c.index))
}

@(private = "file")
cell_block :: #force_inline proc "contextless" (c: Cell) -> Block_ID {
	return c.r.chunks[c.slot].blocks[c.index]
}

// Sets a cell's sky light (block light kept). A uniform chunk gets its light
// array on the first write. Marks every chunk whose mesh reads the cell dirty.
@(private = "file")
cell_set_sky :: proc(w: ^World, c: Cell, sky: u8) {
	r, i := c.r, c.slot
	if r.light_state[i] != .Mixed {
		if r.light_state[i] == .Sky {
			for &l in r.light[i].data {
				l = SKY_LIGHT_FULL
			}
		} // Dark: the page already reads as zero
		r.light_state[i] = .Mixed
		w.light_mixed_count += 1
	}
	l := &r.light[i].data[c.index]
	l^ = (l^ & 0xF0) | sky
	r.dirty[i] = true
	mark_border_neighbors_dirty(w, c.coord, c.local)
}

// ---- Update ---------------------------------------------------------------------

// Does all queued relight work. Call once per frame after edits and
// streaming, before meshing.
world_update_light :: proc(w: ^World) {
	if !world_light_pending(w) {
		return
	}
	prof.scope("relight")
	e := &w.lighting
	start := time.tick_now()
	stats := Light_Stats {
		changes = len(e.changes),
	}
	cur: Cursor

	for p in e.changes {
		c := locate(w, &cur, p) or_continue
		old := cell_sky(c)
		if old != 0 {
			cell_set_sky(w, c, 0)
		}
		append(&e.removal, Light_Node{p, old})
	}
	clear(&e.changes)

	for head := 0; head < len(e.removal); head += 1 {
		n := e.removal[head]
		for face in Face {
			q := n.pos + FACE_NORMALS[face]
			c := locate(w, &cur, q) or_continue
			ql := cell_sky(c)
			if ql == 0 {
				continue
			}
			if ql < n.light || (face == .Neg_Y && n.light == MAX_LIGHT && ql == MAX_LIGHT) {
				cell_set_sky(w, c, 0) // it depended on n
				append(&e.removal, Light_Node{q, ql})
				stats.removed += 1
			} else {
				append(&e.refill, q) // lit by something else: spreads again
			}
		}
	}
	clear(&e.removal)

	for head := 0; head < len(e.refill); head += 1 {
		p := e.refill[head]
		c := locate(w, &cur, p) or_continue
		pl := cell_sky(c)
		if pl <= 1 {
			continue // can't raise anything
		}
		for face in Face {
			q := p + FACE_NORMALS[face]
			qc := locate(w, &cur, q) or_continue
			cand := light_spread(pl, cell_block(qc), face == .Neg_Y)
			if cand > cell_sky(qc) {
				cell_set_sky(w, qc, cand)
				append(&e.refill, q)
				stats.raised += 1
			}
		}
	}
	clear(&e.refill)

	stats.time = time.tick_since(start)
	e.stats = stats
}

// ---- Chunk loading -------------------------------------------------------------

// Queues the relight work for a chunk that was just loaded: generated, its
// light set from generate_light, then its logged edits applied. Call right
// after that (world_load_generated_chunk does).
//   - Its edited cells are queued as changes (its light is still the
//     generated terrain's).
//   - Top face: generate_light assumed unedited terrain above. If the chunk
//     above is loaded and lets less light down into a top cell than that
//     cell has (a roof up there), the cell is cleared and queued for
//     removal (generated light is lit only from above, so it depended on it).
//   - All six faces: where a cell on one side would raise its neighbor on
//     the other (light spreading through edits on either side), the brighter
//     one is queued as a refill source. Nothing for unedited terrain.
world_light_chunk_loaded :: proc(w: ^World, coord: [3]i32) {
	r, i := find_slot(w, coord)
	if r == nil {
		return
	}
	e := &w.lighting
	origin := chunk_origin(coord)
	if list, ok := w.edits[coord]; ok {
		for ed in list {
			append(&e.changes, origin + local_from_index(int(ed.index)))
		}
	}

	c := &r.chunks[i]
	if ar, ai := find_slot(w, coord + {0, 1, 0}); ar != nil {
		above := region_light_ref(ar, ai)
		for z in i32(0) ..< CHUNK_SIZE {
			for x in i32(0) ..< CHUNK_SIZE {
				top := chunk_index(x, CHUNK_MASK, z)
				have := light_sky(light_ref_get(region_light_ref(r, i), top))
				get := sky_below(light_sky(light_ref_get(above, chunk_index(x, 0, z))), c.blocks[top])
				if get < have {
					p := origin + {x, CHUNK_MASK, z}
					cell_set_sky(w, {r, i, top, {x, CHUNK_MASK, z}, coord}, 0)
					append(&e.removal, Light_Node{p, have})
				}
			}
		}
	}

	ours := region_light_ref(r, i)
	for face in Face {
		nr, ni := find_slot(w, coord + FACE_NORMALS[face])
		if nr == nil {
			continue
		}
		theirs := region_light_ref(nr, ni)
		if ours.state == .Dark && theirs.state == .Dark {
			continue // nothing to spread either way
		}
		nc := &nr.chunks[ni]
		n := FACE_NORMALS[face]
		axis := 0 if n.x != 0 else (1 if n.y != 0 else 2)
		// Our layer on this face and the neighbor's touching layer.
		our_layer := i32(CHUNK_MASK) if n[axis] > 0 else 0
		their_layer := CHUNK_MASK - our_layer
		down_to_them := face == .Neg_Y
		down_to_us := face == .Pos_Y
		for a in i32(0) ..< CHUNK_SIZE {
			for b in i32(0) ..< CHUNK_SIZE {
				p, q: [3]i32
				p[axis], q[axis] = our_layer, their_layer
				p[(axis + 1) % 3], q[(axis + 1) % 3] = a, a
				p[(axis + 2) % 3], q[(axis + 2) % 3] = b, b
				pi, qi := chunk_index(p.x, p.y, p.z), chunk_index(q.x, q.y, q.z)
				pl := light_sky(light_ref_get(ours, pi))
				ql := light_sky(light_ref_get(theirs, qi))
				if light_spread(pl, nc.blocks[qi], down_to_them) > ql {
					append(&e.refill, origin + p)
				}
				if light_spread(ql, c.blocks[pi], down_to_us) > pl {
					append(&e.refill, origin + n * CHUNK_SIZE + q)
				}
			}
		}
	}
}

// Local coords of a chunk_index.
local_from_index :: #force_inline proc "contextless" (index: int) -> [3]i32 {
	n := i32(index)
	return {n & CHUNK_MASK, n >> (2 * CHUNK_SHIFT), (n >> CHUNK_SHIFT) & CHUNK_MASK}
}
