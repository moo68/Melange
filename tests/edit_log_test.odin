package tests

import "core:testing"
import "melange:world"

// A streamed world around block column (0, 0)'s surface, fully loaded.
Edit_World :: struct {
	w:       world.World,
	s:       world.Streamer,
	center:  [3]i32,
	surface: i32, // terrain height at (0, 0)
}

edit_world_init :: proc(e: ^Edit_World) {
	world.world_init(&e.w, 1337)
	world.streamer_init(&e.s, SMALL)
	e.surface = world.terrain_height(e.w.seed, 0, 0)
	e.center = world.block_to_chunk({0, e.surface, 0})
	world.streamer_update(&e.s, &e.w, e.center)
}

edit_world_destroy :: proc(e: ^Edit_World) {
	world.streamer_destroy(&e.s)
	world.world_destroy(&e.w)
}

// Walks far away (everything unloads) and back (everything regenerates).
away_and_back :: proc(t: ^testing.T, e: ^Edit_World) {
	world.streamer_update(&e.s, &e.w, e.center + {100, 0, 0})
	testing.expect(t, world.world_get_chunk(&e.w, e.center) == nil, "old area unloaded")
	world.streamer_update(&e.s, &e.w, e.center)
	testing.expect(t, world.world_get_chunk(&e.w, e.center) != nil, "reloaded")
}

// Every loaded chunk equals plain generation plus its logged edits.
expect_generated_plus_edits :: proc(t: ^testing.T, w: ^world.World) {
	loaded: [dynamic][3]i32
	defer delete(loaded)
	world.world_collect_loaded(w, &loaded)
	for coord in loaded {
		want: world.Chunk
		world.generate_chunk(&want, coord, w.seed)
		for e in world.world_chunk_edits(w, coord) {
			want.blocks[e.index] = e.id
		}
		got := world.world_get_chunk(w, coord)
		if got.blocks != want.blocks {
			testing.expectf(t, false, "chunk %v differs from generation + edits", coord)
			return
		}
	}
}

@(test)
edits_survive_unloading :: proc(t: ^testing.T) {
	e: Edit_World
	edit_world_init(&e)
	defer edit_world_destroy(&e)
	h := e.surface
	// Breaks (stone/grass -> air) and placements (air -> block), including
	// blocks on chunk faces, edges and corners (local 0 and 15).
	edits := [?]struct {
		b:  [3]i32,
		id: world.Block_ID,
	} {
		{{0, h, 0}, world.AIR},
		{{0, h - 1, 0}, world.AIR},
		{{0, h + 1, 0}, world.STONE},
		{{-1, h + 2, -1}, world.DIRT},
		{{15, h + 3, 16}, world.GRASS},
		{{16, h - 5, 15}, world.AIR},
	}
	for ed in edits {
		testing.expect(t, world.world_set_block(&e.w, ed.b, ed.id))
	}
	testing.expect_value(t, e.w.edit_count, len(edits))

	away_and_back(t, &e)
	for ed in edits {
		id, loaded := world.world_get_block(&e.w, ed.b)
		testing.expect(t, loaded)
		testing.expectf(t, id == ed.id, "%v: got %v, want %v", ed.b, id, ed.id)
	}
	// And nothing else changed.
	expect_generated_plus_edits(t, &e.w)
}

@(test)
edits_in_sky_chunks_survive :: proc(t: ^testing.T) {
	// Chunks above any terrain skip generation; their edits must still apply.
	e: Edit_World
	edit_world_init(&e)
	defer edit_world_destroy(&e)
	sky := [3]i32{3, (world.TERRAIN_MAX_HEIGHT / world.CHUNK_SIZE + 1) * world.CHUNK_SIZE + 2, 3}
	// SMALL's vertical range is ±1 chunk: center the stream on the sky block.
	e.center = world.block_to_chunk(sky)
	world.streamer_update(&e.s, &e.w, e.center)
	testing.expect(t, world.world_set_block(&e.w, sky, world.STONE))

	away_and_back(t, &e)
	id, _ := world.world_get_block(&e.w, sky)
	testing.expect_value(t, id, world.STONE)
}

@(test)
editing_a_block_again_keeps_one_entry :: proc(t: ^testing.T) {
	e: Edit_World
	edit_world_init(&e)
	defer edit_world_destroy(&e)
	b := [3]i32{2, e.surface + 1, 2}
	for id in ([?]world.Block_ID{world.STONE, world.AIR, world.DIRT}) {
		world.world_set_block(&e.w, b, id)
	}
	world.world_set_block(&e.w, b, world.DIRT) // no-op: nothing new to record
	testing.expect_value(t, e.w.edit_count, 1)
	edits := world.world_chunk_edits(&e.w, world.block_to_chunk(b))
	testing.expect_value(t, len(edits), 1)
	testing.expect_value(t, edits[0].id, world.DIRT)

	away_and_back(t, &e)
	id, _ := world.world_get_block(&e.w, b)
	testing.expect_value(t, id, world.DIRT)
}

@(test)
unloaded_or_unchanged_writes_are_not_logged :: proc(t: ^testing.T) {
	e: Edit_World
	edit_world_init(&e)
	defer edit_world_destroy(&e)
	testing.expect(t, !world.world_set_block(&e.w, {100_000, 5, 0}, world.STONE), "not loaded: refused")
	current, _ := world.world_get_block(&e.w, {0, e.surface, 0})
	world.world_set_block(&e.w, {0, e.surface, 0}, current)
	testing.expect_value(t, e.w.edit_count, 0)
	testing.expect_value(t, len(e.w.edits), 0)
}

@(test)
reloaded_edits_dirty_neighbors_for_meshing :: proc(t: ^testing.T) {
	// A block broken on a chunk's face: when the chunk comes back, the
	// neighbor across that face must be remeshed too (it shows the hole's
	// side). world_create_chunk dirties all neighbors; check it still holds
	// after the edit is applied.
	e: Edit_World
	edit_world_init(&e)
	defer edit_world_destroy(&e)
	b := [3]i32{15, e.surface, 4} // local x = 15: on the +x face
	world.world_set_block(&e.w, b, world.AIR)
	away_and_back(t, &e)
	dirty: [dynamic][3]i32
	defer delete(dirty)
	world.world_collect_dirty(&e.w, &dirty)
	found := false
	for c in dirty {
		found ||= c == world.block_to_chunk(b) + {1, 0, 0}
	}
	testing.expect(t, found, "the neighbor across the face is dirty")
}
