package tests

import "core:testing"
import "melange:geom"
import "melange:mesh"
import "melange:world"

// ---- Hold-to-repeat -----------------------------------------------------------

@(test)
repeat_fires_on_press_then_every_interval :: proc(t: ^testing.T) {
	cd: f32
	DT :: 0.0625 // exact in binary, so 4 steps are exactly 0.25 s
	testing.expect(t, geom.repeat_update(&cd, true, true, DT, 0.25), "fires on the press")
	fired := 0
	for _ in 0 ..< 3 { 	// 0.1875 s held: not yet
		fired += int(geom.repeat_update(&cd, false, true, DT, 0.25))
	}
	testing.expect_value(t, fired, 0)
	testing.expect(t, geom.repeat_update(&cd, false, true, DT, 0.25), "fires at 0.25 s")
	for _ in 0 ..< 3 {
		fired += int(geom.repeat_update(&cd, false, true, DT, 0.25))
	}
	testing.expect_value(t, fired, 0)
	testing.expect(t, geom.repeat_update(&cd, false, true, DT, 0.25), "fires again at 0.50 s")
}

@(test)
repeat_stops_on_release_and_never_bursts :: proc(t: ^testing.T) {
	cd: f32
	geom.repeat_update(&cd, true, true, 0.01, 0.25)
	testing.expect(t, !geom.repeat_update(&cd, false, false, 1, 0.25), "released: nothing")
	testing.expect(t, !geom.repeat_update(&cd, false, false, 1, 0.25))

	// A 1-second hitch while held fires once, not 4 times in a row.
	geom.repeat_update(&cd, true, true, 0.01, 0.25)
	testing.expect(t, geom.repeat_update(&cd, false, true, 1, 0.25))
	testing.expect(t, !geom.repeat_update(&cd, false, true, 0.01, 0.25), "no catch-up burst")
}

@(test)
place_cell_is_in_front_of_the_hit_face :: proc(t: ^testing.T) {
	cell, ok := geom.place_cell({block = {3, -2, 7}, normal = {0, 1, 0}, dist = 2})
	testing.expect(t, ok)
	testing.expect_value(t, cell, [3]i32{3, -1, 7})
	_, ok = geom.place_cell({block = {3, -2, 7}}) // started inside: no face
	testing.expect(t, !ok)
}

// ---- Edits on a real world ----------------------------------------------------

// Chunks x, z in 0..3, y in 0..3; stone below Y = 32 (a flat floor whose top
// layer is Y = 31), air above. Every dirty flag cleared.
make_flat_world :: proc(w: ^world.World) {
	world.world_init(w)
	for cy in i32(0) ..< 4 {
		for cz in i32(0) ..< 4 {
			for cx in i32(0) ..< 4 {
				c, _ := world.world_create_chunk(w, {cx, cy, cz})
				if cy < 2 {
					fill(c, world.STONE)
				}
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

// Straight down from above (x, z), like looking at your feet.
cast_down :: proc(w: ^world.World, x, z: f32) -> (geom.Ray_Hit, bool) {
	return geom.raycast_voxels([3]f32{x, 35, z}, {0, -1, 0}, 10, w, world.world_is_solid)
}

@(test)
world_is_solid_needs_a_loaded_opaque_block :: proc(t: ^testing.T) {
	w: world.World
	make_flat_world(&w)
	defer world.world_destroy(&w)
	testing.expect(t, world.world_is_solid(&w, {5, 31, 5}))
	testing.expect(t, !world.world_is_solid(&w, {5, 32, 5}), "air")
	testing.expect(t, !world.world_is_solid(&w, {-1, 10, 5}), "unloaded")
}

@(test)
breaking_lets_the_ray_through_to_the_next_block :: proc(t: ^testing.T) {
	w: world.World
	make_flat_world(&w)
	defer world.world_destroy(&w)

	hit, ok := cast_down(&w, 20.5, 20.5)
	expect_hit(t, hit, ok, {20, 31, 20}, {0, 1, 0}, 3)
	testing.expect(t, world.world_break_block(&w, hit))
	id, _ := world.world_get_block(&w, {20, 31, 20})
	testing.expect_value(t, id, world.AIR)

	hit, ok = cast_down(&w, 20.5, 20.5)
	expect_hit(t, hit, ok, {20, 30, 20}, {0, 1, 0}, 4)

	// A stale hit (block already gone) changes nothing.
	testing.expect(t, !world.world_break_block(&w, {block = {20, 31, 20}, normal = {0, 1, 0}}))
}

@(test)
placing_goes_in_front_of_the_hit_face :: proc(t: ^testing.T) {
	w: world.World
	make_flat_world(&w)
	defer world.world_destroy(&w)
	far_away := geom.body_box({1000, 1000, 1000}) // player not in the way

	hit, ok := cast_down(&w, 20.5, 20.5)
	testing.expect(t, world.world_place_block(&w, hit, world.DIRT, far_away))
	id, _ := world.world_get_block(&w, {20, 32, 20})
	testing.expect_value(t, id, world.DIRT)
	hit, ok = cast_down(&w, 20.5, 20.5)
	expect_hit(t, hit, ok, {20, 32, 20}, {0, 1, 0}, 2) // the new block is targeted

	// Against a side face: a horizontal ray hits the new block's -X side.
	side, side_ok := geom.raycast_voxels([3]f32{17.5, 32.5, 20.5}, {1, 0, 0}, 5, &w, world.world_is_solid)
	expect_hit(t, side, side_ok, {20, 32, 20}, {-1, 0, 0}, 2.5)
	testing.expect(t, world.world_place_block(&w, side, world.STONE, far_away))
	id, _ = world.world_get_block(&w, {19, 32, 20})
	testing.expect_value(t, id, world.STONE)
}

@(test)
placing_right_next_to_the_player_is_allowed :: proc(t: ^testing.T) {
	w: world.World
	make_flat_world(&w)
	defer world.world_destroy(&w)
	// Standing at x 21.2..21.8: the cell x 20..21 just beside is free to build in.
	hit, _ := cast_down(&w, 20.5, 20.5)
	testing.expect(t, world.world_place_block(&w, hit, world.STONE, geom.body_box({21.5, 32.001, 20.5})))
}

@(test)
placing_is_refused_when_it_cannot_work :: proc(t: ^testing.T) {
	w: world.World
	make_flat_world(&w)
	defer world.world_destroy(&w)
	far_away := geom.body_box({1000, 1000, 1000})

	hit, _ := cast_down(&w, 20.5, 20.5)
	// Into the player's own body: standing on that spot, or overlapping it
	// at head height.
	testing.expect(t, !world.world_place_block(&w, hit, world.STONE, geom.body_box({20.5, 32.001, 20.5})))
	testing.expect(t, !world.world_place_block(&w, hit, world.STONE, geom.body_box({21.2, 30.5, 20.5})))
	// Ray started inside a block: no face.
	testing.expect(t, !world.world_place_block(&w, {block = {20, 31, 20}}, world.STONE, far_away))
	// The cell in front isn't air (stale hit after something was placed there).
	world.world_set_block(&w, {20, 32, 20}, world.DIRT)
	testing.expect(t, !world.world_place_block(&w, hit, world.STONE, far_away))
	id, _ := world.world_get_block(&w, {20, 32, 20})
	testing.expect_value(t, id, world.DIRT)
	// The cell in front is in an unloaded chunk (the world's -X edge).
	testing.expect(t, !world.world_place_block(&w, {block = {0, 20, 5}, normal = {-1, 0, 0}}, world.STONE, far_away))
}

// End to end: place a block on a chunk corner, remesh every chunk the edit
// dirtied, and check the chunk diagonally across the corner (which shares
// only that corner point) now darkens the AO of its floor next to it.
@(test)
corner_edit_updates_ao_in_the_diagonal_chunk :: proc(t: ^testing.T) {
	w: world.World
	make_flat_world(&w)
	defer world.world_destroy(&w)

	// Floor block (31, 31, 31) = local (15, 15, 15) of chunk (1, 1, 1); its
	// top face's corner (32, 32, 32) = local (16, 16, 16).
	DIAGONAL :: [3]i32{1, 1, 1}
	floor_top_corner_brightness :: proc(t: ^testing.T, w: ^world.World) -> u8 {
		hood := world.world_get_neighborhood(w, DIAGONAL)
		m: mesh.Mesh_Data
		defer mesh.mesh_data_destroy(&m)
		mesh.build_chunk_mesh_neighborhood(&hood, &m)
		first, ok := find_face(&m, {15, 15, 15}, .Pos_Y)
		if !testing.expect(t, ok, "floor top face missing") {
			return 0
		}
		return vertex_brightness(t, &m, first, {16, 16, 16})
	}
	before := floor_top_corner_brightness(t, &w)
	testing.expect_value(t, before, shade_with_ao(.Pos_Y, 3)) // open floor: no occlusion

	// Look down at the floor block (32, 31, 32) and place on its top: the
	// new block (32, 32, 32) is local (0, 0, 0) of chunk (2, 2, 2), the
	// corner shared by chunks x, y, z in {1, 2}.
	hit, ok := cast_down(&w, 32.5, 32.5)
	expect_hit(t, hit, ok, {32, 31, 32}, {0, 1, 0}, 3)
	testing.expect(t, world.world_place_block(&w, hit, world.STONE, geom.body_box({1000, 1000, 1000})))

	dirty: [dynamic][3]i32
	defer delete(dirty)
	world.world_collect_dirty(&w, &dirty)
	testing.expect_value(t, len(dirty), 8)
	testing.expect(t, world.world_is_dirty(&w, DIAGONAL), "the diagonal chunk must be remeshed")

	// The diagonal chunk's floor corner is now occluded by the corner block.
	testing.expect_value(t, floor_top_corner_brightness(t, &w), shade_with_ao(.Pos_Y, 2))
}

@(test)
unloaded_chunks_block_movement :: proc(t: ^testing.T) {
	w: world.World
	make_flat_world(&w)
	defer world.world_destroy(&w)
	testing.expect(t, world.world_blocks_movement(&w, {5, 31, 5}), "stone")
	testing.expect(t, !world.world_blocks_movement(&w, {5, 40, 5}), "loaded air")
	testing.expect(t, world.world_blocks_movement(&w, {-1, 40, 5}), "unloaded counts as solid")
	testing.expect(t, !world.world_is_solid(&w, {-1, 40, 5}), "...but not for picking")
}
