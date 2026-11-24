package tests

import "core:testing"
import "melange:geom"
import "melange:mesh"
import "melange:world"

UNKNOWN_BLOCK :: world.Block_ID(999)

@(test)
face_visible_rules :: proc(t: ^testing.T) {
	A, S, G, L, U := world.AIR, world.STONE, world.GLASS, world.LEAVES, UNKNOWN_BLOCK
	cases := []struct {
		id, neighbor: world.Block_ID,
		want:         bool,
	} {
		// Air never has faces.
		{A, A, false}, {A, S, false}, {A, G, false},
		// Opaque blocks hide every face against them.
		{S, S, false}, {G, S, false}, {L, S, false}, {S, U, false},
		// Faces toward air or cutout blocks are visible.
		{S, A, true}, {S, G, true}, {S, L, true}, {U, A, true},
		{G, A, true}, {L, A, true}, {G, L, true}, {L, G, true},
		// Same block: glass culls (one pane), leaves don't (full trees).
		{G, G, false}, {L, L, true},
	}
	for c in cases {
		testing.expectf(t, world.face_visible(c.id, c.neighbor) == c.want, "%v toward %v: want %v", world.block_name(c.id), world.block_name(c.neighbor), c.want)
	}
}

@(test)
block_properties :: proc(t: ^testing.T) {
	testing.expect_value(t, world.block_props(world.STONE).render, world.Block_Render.Opaque)
	testing.expect_value(t, world.block_props(world.GLASS).render, world.Block_Render.Cutout)
	testing.expect_value(t, world.block_props(world.LEAVES).render, world.Block_Render.Cutout)
	testing.expect_value(t, world.block_props(world.AIR).render, world.Block_Render.None)
	for id in ([]world.Block_ID{world.STONE, world.GLASS, world.LEAVES, UNKNOWN_BLOCK}) {
		testing.expectf(t, world.block_is_solid(id), "%v is solid", id)
	}
	testing.expect(t, !world.block_is_solid(world.AIR), "air isn't solid")
	testing.expect(t, !world.block_is_opaque(world.GLASS) && !world.block_is_opaque(world.LEAVES), "cutout blocks aren't opaque")
	// Unknown IDs (newer saves) behave as opaque cubes.
	testing.expect_value(t, world.block_props(UNKNOWN_BLOCK), world.OPAQUE_CUBE)
	testing.expect_value(t, world.block_tile(world.GLASS, .Pos_Y), world.TILE_GLASS)
	testing.expect_value(t, world.block_tile(world.LEAVES, .Neg_X), world.TILE_LEAVES)
	testing.expect_value(t, mesh.tile_coords(world.TILE_GLASS), [2]f32{4, 0})
	testing.expect_value(t, mesh.tile_coords(world.TILE_LEAVES), [2]f32{5, 0})
}

// Builds a chunk holding `blocks` and returns its meshes (caller destroys).
mesh_blocks :: proc(blocks: []struct {
		pos: [3]i32,
		id:  world.Block_ID,
	}) -> (cm: mesh.Chunk_Mesh) {
	c := new(world.Chunk)
	defer free(c)
	for b in blocks {
		world.chunk_set(c, b.pos.x, b.pos.y, b.pos.z, b.id)
	}
	mesh.build_chunk_mesh(c, &no_neighbors, &cm)
	return
}

@(test)
cutout_faces_go_into_the_cutout_pass :: proc(t: ^testing.T) {
	{
		cm := mesh_blocks({{{5, 5, 5}, world.GLASS}})
		defer mesh.chunk_mesh_destroy(&cm)
		testing.expect_value(t, mesh.face_count(&cm[.Opaque]), 0)
		testing.expect_value(t, mesh.face_count(&cm[.Cutout]), 6)
		for v in 0 ..< len(cm[.Cutout].vertices) {
			testing.expect_value(t, vtile(&cm[.Cutout], v), mesh.tile_coords(world.TILE_GLASS))
		}
	}
	{
		cm := mesh_blocks({{{5, 5, 5}, world.STONE}})
		defer mesh.chunk_mesh_destroy(&cm)
		testing.expect_value(t, mesh.face_count(&cm[.Opaque]), 6)
		testing.expect_value(t, mesh.face_count(&cm[.Cutout]), 0)
	}
	{ 	// Two glass blocks: the shared faces are culled (10, not 12).
		cm := mesh_blocks({{{5, 5, 5}, world.GLASS}, {{6, 5, 5}, world.GLASS}})
		defer mesh.chunk_mesh_destroy(&cm)
		testing.expect_value(t, mesh.face_count(&cm[.Cutout]), 10)
	}
	{ 	// Two leaves: both shared faces stay.
		cm := mesh_blocks({{{5, 5, 5}, world.LEAVES}, {{6, 5, 5}, world.LEAVES}})
		defer mesh.chunk_mesh_destroy(&cm)
		testing.expect_value(t, mesh.face_count(&cm[.Cutout]), 12)
	}
	{ 	// Stone next to glass: stone keeps all 6 (seen through the glass),
		// glass loses the one against the stone.
		cm := mesh_blocks({{{5, 5, 5}, world.STONE}, {{6, 5, 5}, world.GLASS}})
		defer mesh.chunk_mesh_destroy(&cm)
		testing.expect_value(t, mesh.face_count(&cm[.Opaque]), 6)
		testing.expect_value(t, mesh.face_count(&cm[.Cutout]), 5)
		expect_ccw(t, &cm[.Cutout])
	}
}

// The mesher's inlined culling agrees with world.face_visible for every pair.
@(test)
mesher_matches_face_visible :: proc(t: ^testing.T) {
	ids := []world.Block_ID{world.AIR, world.STONE, world.GLASS, world.LEAVES, UNKNOWN_BLOCK}
	for a in ids {
		for b in ids {
			cm := mesh_blocks({{{5, 5, 5}, a}, {{6, 5, 5}, b}})
			defer mesh.chunk_mesh_destroy(&cm)
			check :: proc(t: ^testing.T, cm: ^mesh.Chunk_Mesh, pos: [3]i32, face: world.Face, id, neighbor: world.Block_ID) {
				found := false
				for &m in cm {
					if _, ok := find_face(&m, pos, face); ok {
						found = true
					}
				}
				if id != world.AIR {
					_, in_own_pass := find_face(&cm[mesh.block_pass(id)], pos, face)
					testing.expectf(t, found == in_own_pass, "%v face in the wrong pass", world.block_name(id))
				}
				testing.expectf(t, found == world.face_visible(id, neighbor), "%v toward %v: mesh has face = %v", world.block_name(id), world.block_name(neighbor), found)
			}
			check(t, &cm, {5, 5, 5}, .Pos_X, a, b)
			check(t, &cm, {6, 5, 5}, .Neg_X, b, a)
		}
	}
}

// Leaves darken the AO of faces next to them; glass doesn't.
@(test)
cutout_ao :: proc(t: ^testing.T) {
	for id in ([]world.Block_ID{world.LEAVES, world.GLASS}) {
		cm := mesh_blocks({{{5, 4, 5}, world.STONE}, {{6, 5, 5}, id}})
		defer mesh.chunk_mesh_destroy(&cm)
		m := &cm[.Opaque]
		first, ok := find_face(m, {5, 4, 5}, .Pos_Y)
		testing.expect(t, ok, "floor top face")
		want := 2 if id == world.LEAVES else 3
		testing.expectf(t, vertex_brightness(t, m, first, {6, 5, 5}) == shade_with_ao(.Pos_Y, want), "%v next to the corner: ao %d", world.block_name(id), want)
		testing.expect_value(t, vertex_brightness(t, m, first, {5, 5, 5}), shade_with_ao(.Pos_Y, 3))
	}
}

// Glass and leaves can be picked, broken, and stand on.
@(test)
cutout_blocks_are_solid_in_the_world :: proc(t: ^testing.T) {
	w: world.World
	make_flat_world(&w)
	defer world.world_destroy(&w)
	for id, i in ([]world.Block_ID{world.GLASS, world.LEAVES}) {
		x := i32(5 + 3 * i)
		testing.expect(t, world.world_set_block(&w, {x, 32, 5}, id))
		testing.expect(t, world.world_is_solid(&w, {x, 32, 5}))
		testing.expect(t, world.world_blocks_movement(&w, {x, 32, 5}))
		hit, ok := cast_down(&w, f32(x) + 0.5, 5.5)
		testing.expect(t, ok)
		testing.expectf(t, hit.block == {x, 32, 5}, "ray hits the %v: %v", world.block_name(id), hit.block)
		testing.expect(t, world.world_break_block(&w, hit))
		testing.expect(t, !world.world_is_solid(&w, {x, 32, 5}))
	}
	// A body lands on top of glass instead of falling through.
	testing.expect(t, world.world_set_block(&w, {20, 32, 20}, world.GLASS))
	b := geom.Body{position = {20.5, 36, 20.5}}
	for _ in 0 ..< 120 {
		geom.body_step(&b, {}, geom.PHYSICS_DT, &w, world.world_blocks_movement)
	}
	testing.expect(t, b.on_ground, "standing")
	testing.expectf(t, abs(b.position.y - 33) < 0.01, "on top of the glass: y %v", b.position.y)
}

// Coplanar faces that share a corner must give it the same brightness, or
// a seam shows. Leaves cast AO and don't cull the face behind them, so the
// face's own front cell must count too (a face under a leaf was fully lit
// while the floor around it was darkened). Random scenes of stone, glass,
// leaves and air.
@(test)
shared_corners_agree_with_cutout_blocks :: proc(t: ^testing.T) {
	ids := [4]world.Block_ID{world.AIR, world.STONE, world.GLASS, world.LEAVES}
	state := u32(12345)
	next :: proc(s: ^u32) -> u32 {
		s^ = s^ * 1664525 + 1013904223
		return s^ >> 16
	}
	Key :: struct {
		pos:    [3]f32,
		normal: [3]f32,
	}
	seen := make(map[Key]u8)
	defer delete(seen)
	for scene in 0 ..< 60 {
		c := new(world.Chunk)
		defer free(c)
		for y in i32(2) ..< 9 {
			for z in i32(2) ..< 9 {
				for x in i32(2) ..< 9 {
					world.chunk_set(c, x, y, z, ids[next(&state) % 4])
				}
			}
		}
		cm: mesh.Chunk_Mesh
		defer mesh.chunk_mesh_destroy(&cm)
		mesh.build_chunk_mesh(c, &no_neighbors, &cm)
		clear(&seen)
		for &m in cm {
			for v in 0 ..< len(m.vertices) {
				k := Key{vpos(&m, v), vnormal(&m, v)}
				b := vbright(&m, v)
				if prev, ok := seen[k]; ok && prev != b {
					testing.fail_now(t, "coplanar faces disagree on a shared corner's brightness")
				}
				seen[k] = b
			}
		}
		_ = scene
	}
}

// The face under a leaf block is darkened like the floor around it.
@(test)
face_under_leaves_is_occluded :: proc(t: ^testing.T) {
	cm := mesh_blocks({{{5, 4, 5}, world.STONE}, {{6, 4, 5}, world.STONE}, {{5, 5, 5}, world.LEAVES}})
	defer mesh.chunk_mesh_destroy(&cm)
	m := &cm[.Opaque]
	under, ok := find_face(m, {5, 4, 5}, .Pos_Y)
	testing.expect(t, ok)
	beside, ok2 := find_face(m, {6, 4, 5}, .Pos_Y)
	testing.expect(t, ok2)
	// The shared edge x = 6: one occluder (the leaf) for both faces.
	for z in ([]f32{5, 6}) {
		testing.expect_value(t, vertex_brightness(t, m, under, {6, 5, z}), shade_with_ao(.Pos_Y, 2))
		testing.expect_value(t, vertex_brightness(t, m, beside, {6, 5, z}), shade_with_ao(.Pos_Y, 2))
	}
	// Under glass nothing changes.
	cg := mesh_blocks({{{5, 4, 5}, world.STONE}, {{5, 5, 5}, world.GLASS}})
	defer mesh.chunk_mesh_destroy(&cg)
	g, ok3 := find_face(&cg[.Opaque], {5, 4, 5}, .Pos_Y)
	testing.expect(t, ok3)
	testing.expect_value(t, vertex_brightness(t, &cg[.Opaque], g, {6, 5, 6}), shade_with_ao(.Pos_Y, 3))
}

@(test)
vertex_ao_counts_the_front_cell :: proc(t: ^testing.T) {
	// Air in front: the classic rule.
	testing.expect_value(t, mesh.vertex_ao(true, true, false, false), 0)
	testing.expect_value(t, mesh.vertex_ao(true, false, true, false), 1)
	// An AO-casting front cell counts like the others, and front + corner
	// (the other diagonal pair) is as dark as both sides.
	testing.expect_value(t, mesh.vertex_ao(false, false, false, true), 2)
	testing.expect_value(t, mesh.vertex_ao(true, false, false, true), 1)
	testing.expect_value(t, mesh.vertex_ao(false, false, true, true), 0)
}
