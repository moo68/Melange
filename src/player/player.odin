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
	eye_height:  f64, // above the feet; lower while crouching (geom.eye_height_step)
	prev_eye_height: f64, // before the last physics step, for interpolation
	yaw:         f32, // degrees, see geom/look.odin
	pitch:       f32, // degrees, clamped by geom.clamp_pitch
	mode:        Move_Mode,
	waiting:     bool, // walk physics paused until the chunks around the player load
}

FOV_Y :: 70 // default vertical field of view, degrees (settings.DEFAULT.fov)

// How far up switching to walk mode searches for room when inside terrain.
UNSTUCK_SEARCH :: 128

// A walking player standing on the terrain surface at column (x, z),
// looking along yaw/pitch. Works before any chunk is loaded: terrain
// heights come from the seed alone.
player_spawn :: proc(seed: i64, x, z: i32, yaw, pitch: f32) -> Player {
	feet := [3]f64{f64(x) + 0.5, f64(world.terrain_height(seed, x, z) + 1) + geom.COLLISION_SKIN, f64(z) + 0.5}
	return player_at(feet, yaw, pitch)
}

// A walking player with its feet at `feet` (e.g. restored from a save).
player_at :: proc(feet: [3]f64, yaw, pitch: f32) -> Player {
	return {
		body = {position = feet},
		prev_feet = feet,
		eye_height = geom.EYE_HEIGHT,
		prev_eye_height = geom.EYE_HEIGHT,
		yaw = yaw,
		pitch = pitch,
		mode = .Walk,
	}
}

// The eye, interpolated between the last two physics states (smooth at any
// frame rate, though physics runs at 60 Hz).
eye_position :: proc(p: ^Player) -> [3]f32 {
	feet := p.prev_feet + (p.body.position - p.prev_feet) * p.alpha
	eye := p.prev_eye_height + (p.eye_height - p.prev_eye_height) * p.alpha
	return {f32(feet.x), f32(feet.y + eye), f32(feet.z)}
}

// The player's collision box (placement keeps it clear).
player_box :: proc(p: ^Player) -> geom.AABB {
	return geom.body_box(p.body.position)
}

// The raylib camera for drawing and picking: at the eye, looking along the
// player's view direction, with a vertical field of view of `fov_y` degrees
// (the fov setting; FOV_Y is the default).
camera_of :: proc(p: ^Player, fov_y: f32 = FOV_Y) -> rl.Camera3D {
	eye := eye_position(p)
	return {
		position = eye,
		target = eye + geom.look_direction(p.yaw, p.pitch),
		up = {0, 1, 0},
		fovy = fov_y,
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
	p.eye_height = geom.EYE_HEIGHT // stand up (fly mode has no crouch)
	p.prev_eye_height = geom.EYE_HEIGHT
	if mode == .Walk {
		if lift, ok := geom.find_free_lift(player_box(p), UNSTUCK_SEARCH, w, world.world_blocks_movement); ok {
			p.body.position.y += lift
		}
	}
	p.prev_feet = p.body.position
	p.alpha = 0
}

// Frames to ignore the mouse for after DisableCursor: raylib reports one
// huge bogus delta (the cursor warping to the window center) on frame 1 or 2
// (measured 2026-11-23; with only 2 ignored it hit about half the starts and
// turned the restored view, usually downward). 10 leaves a safe margin and is
// at most ~0.17 s even at 60 fps.
CAPTURE_IGNORE_FRAMES :: 10

// Mouse look: right turns right, down looks down. Pass look = false to
// ignore the mouse this frame (see CAPTURE_IGNORE_FRAMES). `sensitivity`
// scales MOUSE_SENSITIVITY (the mouse sensitivity setting, 1 = 100%).
update_look :: proc(p: ^Player, look := true, sensitivity: f32 = 1) {
	if !look {
		return
	}
	mouse := rl.GetMouseDelta()
	deg_per_px := MOUSE_SENSITIVITY * sensitivity
	p.yaw += mouse.x * deg_per_px
	p.pitch = geom.clamp_pitch(p.pitch - mouse.y * deg_per_px)
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
