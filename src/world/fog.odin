package world

// Which fog the chunk shader uses: pure (no raylib) so it's testable; the
// renderer turns it into uniforms (render.renderer_set_fog).

// The sky (and clear color) above water; render.SKY_COLOR is the same.
SKY_COLOR :: [3]u8{135, 190, 235}

// Under water: the water tile's mean color (45, 98, 199) at 60% brightness,
// so the fog matches the water seen from above, only deeper.
WATER_FOG_COLOR :: [3]u8{27, 59, 119}
// Multiplied into every texel under water: fog starting at 0 barely shows
// up close (4% at 4 blocks), so without it the seabed in front of you
// wouldn't look under water.
WATER_TINT :: [3]f32{0.55, 0.75, 1.0}
// Under water the fog is fully opaque this far away (3D distance), capped
// by stream_meshed_distance (25 blocks at the minimum render distance).
WATER_FOG_END :: 32.0

Fog :: struct {
	color:     [3]u8, // what the world fades into; also the clear color
	tint:      [3]f32, // multiplied into every texel (white = none)
	start:     f32, // distance where fog begins
	end:       f32, // distance where it's fully opaque
	// true: 3D distance from the camera (under water: looking down at the
	// seabed fogs it too); false: horizontal distance, matching the
	// streaming circle.
	spherical: bool,
}

// The fog for a camera under water or not, with streaming config `cfg`.
// Above water it's fully fogged just before chunks can be missing, so the
// world's edge and chunks popping in are never visible.
fog_for :: proc(cfg: Stream_Config, underwater: bool) -> Fog {
	meshed := stream_meshed_distance(cfg)
	if underwater {
		return {color = WATER_FOG_COLOR, tint = WATER_TINT, start = 0, end = min(WATER_FOG_END, meshed), spherical = true}
	}
	return {color = SKY_COLOR, tint = {1, 1, 1}, start = meshed * 0.55, end = meshed}
}
