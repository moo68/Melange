package tests

import "core:testing"
import "melange:geom"
import "melange:world"

@(test)
point_in_fluid_follows_the_lowered_surface :: proc(t: ^testing.T) {
	p := Pool{scene = {floor = -20}, surface = 1} // water up to Y 0.875
	in_water :: proc(p: ^Pool, y: f64) -> bool {
		return geom.point_in_fluid({0.5, y, 0.5}, p, pool_fluid)
	}
	testing.expect(t, in_water(&p, 0.874))
	testing.expect(t, !in_water(&p, 0.875), "exactly on the surface is above it")
	testing.expect(t, !in_water(&p, 0.876))
	testing.expect(t, !in_water(&p, 1.5))
	testing.expect(t, !in_water(&p, 0.999), "air above the lowered surface, same cell")
	testing.expect(t, in_water(&p, -0.001), "under stacked water: the full cell below")
	testing.expect(t, in_water(&p, -19.5))
	testing.expect(t, !in_water(&p, -20.5), "inside the floor")
	// Negative coordinates floor correctly.
	testing.expect(t, geom.point_in_fluid({-7.9, 0.5, -3.2}, &p, pool_fluid))
}

@(test)
point_in_fluid_in_a_world :: proc(t: ^testing.T) {
	w: world.World
	world.world_init(&w, 1)
	defer world.world_destroy(&w)
	for y in i32(0) ..< 3 {
		world.world_create_chunk(&w, {0, y - 1, 0})
	}
	world.world_set_block(&w, {2, 0, 2}, world.WATER)
	world.world_set_block(&w, {2, 1, 2}, world.WATER)
	world.world_set_block(&w, {5, 0, 5}, world.GLASS)
	in_water :: proc(w: ^world.World, p: [3]f64) -> bool {
		return geom.point_in_fluid(p, w, world.world_fluid_top)
	}
	testing.expect(t, in_water(&w, {2.5, 0.95, 2.5}), "water under water is full height")
	testing.expect(t, in_water(&w, {2.5, 1.8, 2.5}))
	testing.expect(t, !in_water(&w, {2.5, 1.9, 2.5}), "top block lowered")
	testing.expect(t, !in_water(&w, {5.5, 0.5, 5.5}), "glass isn't fluid")
	testing.expect(t, !in_water(&w, {3.5, 0.5, 2.5}), "air")
	testing.expect(t, !in_water(&w, {40.5, 0.5, 2.5}), "unloaded chunk")
}

@(test)
fog_above_water_is_the_sky_fog :: proc(t: ^testing.T) {
	cfg := world.DEFAULT_STREAM_CONFIG
	f := world.fog_for(cfg, false, world.sky_at(world.time_at_hour(0, 12))) // midday
	meshed := world.stream_meshed_distance(cfg)
	testing.expect_value(t, f.color, world.SKY_COLOR)
	testing.expect_value(t, f.tint, [3]f32{1, 1, 1})
	testing.expect_value(t, f.end, meshed)
	testing.expect_value(t, f.start, meshed * 0.55)
	testing.expect(t, !f.spherical, "horizontal, like the streaming circle")
}

@(test)
fog_under_water_is_close_blue_and_spherical :: proc(t: ^testing.T) {
	cfg := world.DEFAULT_STREAM_CONFIG
	for radius in i32(4) ..= 32 {
		cfg.radius = radius
		f := world.fog_for(cfg, true, world.sky_at(world.time_at_hour(0, 12)))
		meshed := world.stream_meshed_distance(cfg)
		testing.expect_value(t, f.color, world.WATER_FOG_COLOR)
		testing.expect_value(t, f.tint, world.WATER_TINT)
		testing.expect(t, f.spherical)
		testing.expect_value(t, f.start, 0)
		testing.expectf(t, f.end <= meshed, "radius %d: fog end %v beyond the meshed distance %v", radius, f.end, meshed)
		testing.expectf(t, f.end == min(f32(world.WATER_FOG_END), meshed), "radius %d: end %v", radius, f.end)
	}
	cfg.radius = 4
	testing.expect(t, world.fog_for(cfg, true, world.sky_at(0)).end < world.WATER_FOG_END, "capped at the minimum render distance")
}
