package world

// The edit log: every block changed at runtime (world_set_block), grouped by
// chunk, so edits survive their chunk being unloaded and regenerated. The
// streamer re-applies a chunk's edits right after generating it.
// Session-only for now (nothing is saved to disk).

Block_Edit :: struct {
	index: u16, // chunk_index within the chunk, 0..CHUNK_VOLUME-1
	id:    Block_ID, // the block there now
}

#assert(CHUNK_VOLUME <= 1 << 16)

// Records that block `index` of chunk `coord` is now `id`, replacing any
// earlier edit of the same block.
@(private)
edit_log_record :: proc(w: ^World, coord: [3]i32, index: int, id: Block_ID) {
	_, list, just_inserted, _ := map_entry(&w.edits, coord)
	if just_inserted {
		list^ = make([dynamic]Block_Edit, w.allocator)
	}
	for &e in list {
		if int(e.index) == index {
			e.id = id
			return
		}
	}
	append(list, Block_Edit{u16(index), id})
	w.edit_count += 1
}

// Writes chunk `coord`'s logged edits into `c`. Call right after generating
// it (before the next mesh pass; world_create_chunk already marked it and
// its neighbors dirty).
world_apply_edits :: proc(w: ^World, coord: [3]i32, c: ^Chunk) {
	list, ok := w.edits[coord]
	if !ok {
		return
	}
	for e in list {
		c.blocks[e.index] = e.id
	}
}

// The logged edits of chunk `coord` (nil if none). Valid until the next edit.
world_chunk_edits :: proc(w: ^World, coord: [3]i32) -> []Block_Edit {
	return w.edits[coord][:]
}

@(private)
edit_log_destroy :: proc(w: ^World) {
	for _, list in w.edits {
		delete(list)
	}
	delete(w.edits)
}
