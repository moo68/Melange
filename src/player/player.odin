package player

import "melange:geom"
import "melange:world"
import rl "third_party:raylib"

Move_Mode :: enum u8 {
	Walk, // gravity + collision (geom.body_step at a fixed 60 Hz)
	Fly, // free flight through blocks (debug)
}

// The player. main owns it; the camera is derived from it every frame
// (camera_of), never stored back.
Player :: struct {
	body:        geom.Body, // feet position, velocity, on_ground
	prev_feet:   [3]f64, // feet before the last physics step, for interpolation
	accumulator: f64, // geom.fixed_steps state
	alpha:       f64, // interpolation fraction between prev_feet and body.position
	yaw:         f32, // degrees, see geom/look.odin
	pitch:       f32, // degrees, clamped by geom.clamp_pitch
	mode:        Move_Mode,
	waiting:     bool, // walk physics paused until the chunks around the player load
}

FOV_Y :: 70 // vertical field of view, degrees

// How far up switching to walk mode searches for room when inside terrain.
UNSTUCK_SEARCH :: 128

// A walking player standing on the terrain surface at column (x, z),
// looking along yaw/pitch. Works before any chunk is loaded: terrain
// heights come from the seed alone.
player_spawn :: proc(seed: i64, x, z: i32, yaw, pitch: f32) -> Player {
	feet := [3]f64{f64(x) + 0.5, f64(world.terrain_height(seed, x, z) + 1) + geom.COLLISION_SKIN, f64(z) + 0.5}
	return {body = {position = feet}, prev_feet = feet, yaw = yaw, pitch = pitch, mode = .Walk}
}

// The eye, interpolated between the last two physics states (smooth at any
// frame rate, though physics runs at 60 Hz).
eye_position :: proc(p: ^Player) -> [3]f32 {
	feet := p.prev_feet + (p.body.position - p.prev_feet) * p.alpha
	return {f32(feet.x), f32(feet.y + geom.EYE_HEIGHT), f32(feet.z)}
}

// The player's collision box (placement keeps it clear).
player_box :: proc(p: ^Player) -> geom.AABB {
	return geom.body_box(p.body.position)
}

// The raylib camera for drawing and picking: at the eye, looking along the
// player's view direction.
camera_of :: proc(p: ^Player) -> rl.Camera3D {
	eye := eye_position(p)
	return {
		position = eye,
		target = eye + geom.look_direction(p.yaw, p.pitch),
		up = {0, 1, 0},
		fovy = FOV_Y,
		projection = .PERSPECTIVE,
	}
}

// Switches mode. Entering walk mode inside terrain lifts the player to the
// first spot (≤ UNSTUCK_SEARCH blocks up) where the box fits.
set_mode :: proc(p: ^Player, w: ^world.World, mode: Move_Mode) {
	if mode == p.mode {
		return
	}
	p.mode = mode
	p.body.velocity = {}
	p.body.on_ground = false
	p.accumulator = 0
	if mode == .Walk {
		if lift, ok := geom.find_free_lift(player_box(p), UNSTUCK_SEARCH, w, world.world_blocks_movement); ok {
			p.body.position.y += lift
		}
	}
	p.prev_feet = p.body.position
	p.alpha = 0
}

// Mouse look: right turns right, down looks down. Pass look = false to
// ignore the mouse this frame: right after DisableCursor the first mouse
// delta can be a huge jump (cursor warped to window center).
update_look :: proc(p: ^Player, look := true) {
	if !look {
		return
	}
	mouse := rl.GetMouseDelta()
	p.yaw += mouse.x * MOUSE_SENSITIVITY
	p.pitch = geom.clamp_pitch(p.pitch - mouse.y * MOUSE_SENSITIVITY)
	// Keep yaw in [0, 360) so it never loses float precision over a long session.
	for p.yaw >= 360 {
		p.yaw -= 360
	}
	for p.yaw < 0 {
		p.yaw += 360
	}
}

// Moves the player for this frame, in its current mode.
update_movement :: proc(p: ^Player, w: ^world.World) {
	switch p.mode {
	case .Fly:
		update_fly(p)
	case .Walk:
		update_walk(p, w)
	}
}
