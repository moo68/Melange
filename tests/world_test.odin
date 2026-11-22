package tests

import "core:testing"
import "melange:world"

@(test)
block_to_chunk_floors_negatives :: proc(t: ^testing.T) {
	testing.expect_value(t, world.block_to_chunk({0, 15, 16}), [3]i32{0, 0, 1})
	testing.expect_value(t, world.block_to_chunk({-1, -16, -17}), [3]i32{-1, -1, -2})
	testing.expect_value(t, world.block_to_local({-1, -16, -17}), [3]i32{15, 0, 15})
	testing.expect_value(t, world.block_to_local({17, 31, 32}), [3]i32{1, 15, 0})
}

@(test)
chunk_to_region_floors_negatives :: proc(t: ^testing.T) {
	testing.expect_value(t, world.chunk_to_region({7, 8, -1}), [3]i32{0, 1, -1})
	testing.expect_value(t, world.chunk_to_region_local({7, 8, -1}), [3]i32{7, 0, 7})
	testing.expect_value(t, world.chunk_to_region({-8, -9, 0}), [3]i32{-1, -2, 0})
}

@(test)
region_index_round_trips :: proc(t: ^testing.T) {
	for i in 0 ..< world.REGION_VOLUME {
		local := world.region_local_from_index(i)
		testing.expect_value(t, world.region_index(local), i)
	}
}

@(test)
fresh_chunk_reads_as_air :: proc(t: ^testing.T) {
	w: world.World
	world.world_init(&w)
	defer world.world_destroy(&w)

	c, err := world.world_create_chunk(&w, {3, -2, 5})
	testing.expect_value(t, err, nil)
	for b in c.blocks {
		if b != world.AIR {
			testing.fail_now(t, "fresh chunk contains non-air")
		}
	}
}

@(test)
unloaded_slot_is_nil_not_air :: proc(t: ^testing.T) {
	w: world.World
	world.world_init(&w)
	defer world.world_destroy(&w)

	_, _ = world.world_create_chunk(&w, {0, 0, 0})
	// Same region, slot never loaded: readable memory, but must report missing.
	testing.expect(t, world.world_get_chunk(&w, {1, 0, 0}) == nil)
	// No region at all.
	testing.expect(t, world.world_get_chunk(&w, {100, 0, 0}) == nil)

	_, ok := world.world_get_block(&w, {16, 0, 0})
	testing.expect(t, !ok, "get_block in an unloaded chunk must report not-ok")
	testing.expect(t, !world.world_set_block(&w, {16, 0, 0}, world.STONE), "set_block in an unloaded chunk must fail")
}

@(test)
get_set_block_round_trip :: proc(t: ^testing.T) {
	w: world.World
	world.world_init(&w)
	defer world.world_destroy(&w)

	_, _ = world.world_create_chunk(&w, {-1, -1, -1})
	testing.expect(t, world.world_set_block(&w, {-1, -16, -5}, world.DIRT))
	id, ok := world.world_get_block(&w, {-1, -16, -5})
	testing.expect(t, ok)
	testing.expect_value(t, id, world.DIRT)

	// Same storage seen through the chunk directly: local (15, 0, 11).
	c := world.world_get_chunk(&w, {-1, -1, -1})
	testing.expect_value(t, world.chunk_get(c, 15, 0, 11), world.DIRT)
}

// Reloading a slot after unload must not resurrect old blocks (the MADV_FREE
// foot-gun). A second chunk keeps the region alive so the slot is reused.
@(test)
unload_then_reload_is_air :: proc(t: ^testing.T) {
	w: world.World
	world.world_init(&w)
	defer world.world_destroy(&w)

	c, _ := world.world_create_chunk(&w, {2, 2, 2})
	_, _ = world.world_create_chunk(&w, {3, 2, 2})
	for &b in c.blocks {
		b = world.STONE
	}
	world.world_unload_chunk(&w, {2, 2, 2})
	testing.expect(t, world.world_get_chunk(&w, {2, 2, 2}) == nil)

	c, _ = world.world_create_chunk(&w, {2, 2, 2})
	for b in c.blocks {
		if b != world.AIR {
			testing.fail_now(t, "reloaded chunk kept stale blocks")
		}
	}
}

@(test)
region_released_with_last_chunk :: proc(t: ^testing.T) {
	w: world.World
	world.world_init(&w)
	defer world.world_destroy(&w)

	_, _ = world.world_create_chunk(&w, {0, 0, 0})
	_, _ = world.world_create_chunk(&w, {7, 7, 7}) // same region
	_, _ = world.world_create_chunk(&w, {8, 0, 0}) // next region
	testing.expect_value(t, len(w.regions), 2)
	testing.expect_value(t, world.world_loaded_chunk_count(&w), 3)

	world.world_unload_chunk(&w, {0, 0, 0})
	testing.expect_value(t, len(w.regions), 2)
	world.world_unload_chunk(&w, {7, 7, 7})
	testing.expect_value(t, len(w.regions), 1)
	world.world_unload_chunk(&w, {7, 7, 7}) // already unloaded: no-op
	testing.expect_value(t, world.world_loaded_chunk_count(&w), 1)
}

// Neighbors inside a region (fast path) and across region borders (map path)
// must both land in the right slots.
@(test)
neighbors_within_and_across_regions :: proc(t: ^testing.T) {
	w: world.World
	world.world_init(&w)
	defer world.world_destroy(&w)

	// {7, 0, 0} sits on the +X edge of region {0,0,0}; {8, 0, 0} is in region {1,0,0}.
	center := [3]i32{7, 0, 0}
	_, _ = world.world_create_chunk(&w, center)
	expected: world.Neighbors
	for face in world.Face {
		coord := center + world.FACE_NORMALS[face]
		expected[face], _ = world.world_create_chunk(&w, coord)
	}
	got := world.world_get_neighbors(&w, center)
	for face in world.Face {
		testing.expectf(t, got[face] == expected[face], "%v neighbor wrong", face)
		testing.expect(t, got[face] != nil)
	}

	// Unload two (one same-region, one cross-region): those slots become nil.
	world.world_unload_chunk(&w, center + world.FACE_NORMALS[.Neg_X])
	world.world_unload_chunk(&w, center + world.FACE_NORMALS[.Pos_X])
	got = world.world_get_neighbors(&w, center)
	testing.expect(t, got[.Neg_X] == nil)
	testing.expect(t, got[.Pos_X] == nil)
	testing.expect(t, got[.Pos_Y] == expected[.Pos_Y])
}

// Helper: load a 3x3x3 block of chunks around the origin, all clean.
load_clean_cube :: proc(w: ^world.World) {
	for y in i32(-1) ..= 1 {
		for z in i32(-1) ..= 1 {
			for x in i32(-1) ..= 1 {
				_, _ = world.world_create_chunk(w, {x, y, z})
			}
		}
	}
	dirty: [dynamic][3]i32
	defer delete(dirty)
	world.world_collect_dirty(w, &dirty)
	for c in dirty {
		world.world_clear_dirty(w, c)
	}
}

collect_dirty_count :: proc(w: ^world.World) -> int {
	dirty: [dynamic][3]i32
	defer delete(dirty)
	world.world_collect_dirty(w, &dirty)
	return len(dirty)
}

@(test)
set_block_marks_only_needed_chunks_dirty :: proc(t: ^testing.T) {
	w: world.World
	world.world_init(&w)
	defer world.world_destroy(&w)
	load_clean_cube(&w)
	testing.expect_value(t, collect_dirty_count(&w), 0)

	// Interior block: only its own chunk.
	world.world_set_block(&w, {5, 5, 5}, world.STONE)
	testing.expect(t, world.world_is_dirty(&w, {0, 0, 0}))
	testing.expect_value(t, collect_dirty_count(&w), 1)
	world.world_clear_dirty(&w, {0, 0, 0})

	// +X border (local x = 15): also the +X neighbor.
	world.world_set_block(&w, {15, 5, 5}, world.STONE)
	testing.expect(t, world.world_is_dirty(&w, {1, 0, 0}))
	testing.expect_value(t, collect_dirty_count(&w), 2)
	world.world_clear_dirty(&w, {0, 0, 0})
	world.world_clear_dirty(&w, {1, 0, 0})

	// Edge (x = 15, z = 0): +X, -Z and the diagonal (+X, -Z) chunk, whose
	// AO reads this block.
	world.world_set_block(&w, {15, 7, 0}, world.STONE)
	testing.expect(t, world.world_is_dirty(&w, {1, 0, 0}))
	testing.expect(t, world.world_is_dirty(&w, {0, 0, -1}))
	testing.expect(t, world.world_is_dirty(&w, {1, 0, -1}))
	testing.expect_value(t, collect_dirty_count(&w), 4)
	for c in ([][3]i32{{0, 0, 0}, {1, 0, 0}, {0, 0, -1}, {1, 0, -1}}) {
		world.world_clear_dirty(&w, c)
	}

	// Corner (0, 0, 0): all 7 chunks sharing that corner, plus its own.
	world.world_set_block(&w, {0, 0, 0}, world.STONE)
	for dy in i32(-1) ..= 0 {
		for dz in i32(-1) ..= 0 {
			for dx in i32(-1) ..= 0 {
				testing.expectf(t, world.world_is_dirty(&w, {dx, dy, dz}), "chunk %v not dirty", [3]i32{dx, dy, dz})
			}
		}
	}
	testing.expect_value(t, collect_dirty_count(&w), 8)
}

// world_get_neighborhood must put each of the 26 neighbors (and the center)
// in the right slot, both inside a region and across region borders.
@(test)
neighborhood_within_and_across_regions :: proc(t: ^testing.T) {
	w: world.World
	world.world_init(&w)
	defer world.world_destroy(&w)

	// {7, 7, 7} is the far corner of region {0,0,0}: 7 of its neighbors are in
	// other regions.
	center := [3]i32{7, 7, 7}
	expected: world.Neighborhood
	for i in 0 ..< len(expected) {
		expected[i], _ = world.world_create_chunk(&w, center + world.neighborhood_offset(i))
	}
	got := world.world_get_neighborhood(&w, center)
	for i in 0 ..< len(got) {
		testing.expectf(t, got[i] == expected[i] && got[i] != nil, "slot %d (offset %v) wrong", i, world.neighborhood_offset(i))
	}
	for i in 0 ..< len(got) {
		testing.expect_value(t, world.neighborhood_index(world.neighborhood_offset(i)), i)
	}

	world.world_unload_chunk(&w, center + {1, 1, 1})
	got = world.world_get_neighborhood(&w, center)
	testing.expect(t, got[world.neighborhood_index({1, 1, 1})] == nil)
}

@(test)
setting_same_value_is_a_no_op :: proc(t: ^testing.T) {
	w: world.World
	world.world_init(&w)
	defer world.world_destroy(&w)
	load_clean_cube(&w)

	testing.expect(t, world.world_set_block(&w, {3, 3, 3}, world.AIR))
	testing.expect_value(t, collect_dirty_count(&w), 0)
}

@(test)
collect_dirty_reports_world_coords :: proc(t: ^testing.T) {
	w: world.World
	world.world_init(&w)
	defer world.world_destroy(&w)

	_, _ = world.world_create_chunk(&w, {-9, 3, 17})
	dirty: [dynamic][3]i32
	defer delete(dirty)
	world.world_collect_dirty(&w, &dirty)
	testing.expect_value(t, len(dirty), 1)
	testing.expect_value(t, dirty[0], [3]i32{-9, 3, 17})
}
