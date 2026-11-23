package world

import "core:encoding/endian"
import "core:slice"

// The edit log: every block changed at runtime (world_set_block), grouped by
// chunk, so edits survive their chunk being unloaded and regenerated. The
// streamer re-applies a chunk's edits right after generating it.
// Saved to disk as edits.bin (edit_log_encode / edit_log_decode; files in
// package save).

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

// ---- Serialization (edits.bin) ----------------------------------------------
// Little-endian:
//   header:    magic "MLEDITS\0", version u32, chunk_count u32
//   per chunk: coord [3]i32, count u32, count x {index u16, id u16}
// Chunks are written sorted by coord (deterministic output); a chunk's edits
// keep log order.

EDIT_LOG_MAGIC :: "MLEDITS\x00"
EDIT_LOG_VERSION :: 1
EDIT_LOG_HEADER_SIZE :: 16
EDIT_LOG_CHUNK_HEADER_SIZE :: 16
EDIT_LOG_ENTRY_SIZE :: 4

Decode_Error :: enum u8 {
	None,
	Log_Not_Empty, // decode only into a world with no edits
	Bad_Magic,
	Newer_Version, // written by a later version of the game
	Bad_Version,
	Truncated,
	Bad_Count, // a chunk with 0 or more than CHUNK_VOLUME edits
	Bad_Index, // a block index >= CHUNK_VOLUME
	Duplicate_Index, // the same block twice in one chunk
	Duplicate_Chunk,
	Trailing_Data,
}

// Appends the serialized edit log to `out`.
edit_log_encode :: proc(w: ^World, out: ^[dynamic]byte) {
	coords := make([][3]i32, len(w.edits), context.temp_allocator)
	i := 0
	for coord in w.edits {
		coords[i] = coord
		i += 1
	}
	slice.sort_by(coords, proc(a, b: [3]i32) -> bool {
		if a.x != b.x {
			return a.x < b.x
		}
		if a.y != b.y {
			return a.y < b.y
		}
		return a.z < b.z
	})

	append(out, EDIT_LOG_MAGIC)
	put_u32(out, EDIT_LOG_VERSION)
	put_u32(out, u32(len(coords)))
	for coord in coords {
		list := w.edits[coord]
		for c in coord {
			put_u32(out, u32(c))
		}
		put_u32(out, u32(len(list)))
		for e in list {
			put_u16(out, e.index)
			put_u16(out, u16(e.id))
		}
	}
}

// Loads a serialized edit log into `w`, whose log must be empty. Everything
// is validated; on any error the log is left empty (never half-loaded).
// Unknown block IDs are kept (they render as the "undefined" tile).
edit_log_decode :: proc(w: ^World, data: []byte) -> (err: Decode_Error) {
	if len(w.edits) != 0 {
		return .Log_Not_Empty
	}
	defer if err != .None {
		edit_log_clear(w)
	}

	r := data
	if len(r) < EDIT_LOG_HEADER_SIZE {
		return .Truncated
	}
	if string(r[:8]) != EDIT_LOG_MAGIC {
		return .Bad_Magic
	}
	version := get_u32(r[8:])
	switch {
	case version > EDIT_LOG_VERSION:
		return .Newer_Version
	case version != EDIT_LOG_VERSION:
		return .Bad_Version
	}
	chunk_count := get_u32(r[12:])
	r = r[EDIT_LOG_HEADER_SIZE:]

	seen: [CHUNK_VOLUME]bool // indices of the current chunk; cleared after each
	for _ in 0 ..< chunk_count {
		if len(r) < EDIT_LOG_CHUNK_HEADER_SIZE {
			return .Truncated
		}
		coord := [3]i32{i32(get_u32(r[0:])), i32(get_u32(r[4:])), i32(get_u32(r[8:]))}
		count := get_u32(r[12:])
		r = r[EDIT_LOG_CHUNK_HEADER_SIZE:]
		if count == 0 || count > CHUNK_VOLUME {
			return .Bad_Count
		}
		if len(r) < int(count) * EDIT_LOG_ENTRY_SIZE {
			return .Truncated
		}
		_, list, just_inserted, _ := map_entry(&w.edits, coord)
		if !just_inserted {
			return .Duplicate_Chunk
		}
		list^ = make([dynamic]Block_Edit, 0, count, w.allocator)
		for i in 0 ..< int(count) {
			e := r[i * EDIT_LOG_ENTRY_SIZE:]
			index := get_u16(e[0:])
			if int(index) >= CHUNK_VOLUME {
				return .Bad_Index
			}
			if seen[index] {
				return .Duplicate_Index
			}
			seen[index] = true
			append(list, Block_Edit{index, Block_ID(get_u16(e[2:]))})
		}
		for e in list {
			seen[e.index] = false
		}
		w.edit_count += int(count)
		r = r[int(count) * EDIT_LOG_ENTRY_SIZE:]
	}
	if len(r) != 0 {
		return .Trailing_Data
	}
	return .None
}

@(private = "file")
edit_log_clear :: proc(w: ^World) {
	for _, list in w.edits {
		delete(list)
	}
	clear(&w.edits)
	w.edit_count = 0
}

@(private = "file")
put_u32 :: proc(out: ^[dynamic]byte, v: u32) {
	b: [4]byte
	endian.put_u32(b[:], .Little, v)
	append(out, ..b[:])
}

@(private = "file")
put_u16 :: proc(out: ^[dynamic]byte, v: u16) {
	b: [2]byte
	endian.put_u16(b[:], .Little, v)
	append(out, ..b[:])
}

// Callers check lengths first.
@(private = "file")
get_u32 :: proc(b: []byte) -> u32 {
	v, _ := endian.get_u32(b, .Little)
	return v
}

@(private = "file")
get_u16 :: proc(b: []byte) -> u16 {
	v, _ := endian.get_u16(b, .Little)
	return v
}
