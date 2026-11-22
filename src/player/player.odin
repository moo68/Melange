package player

import "melange:geom"
import rl "third_party:raylib"

// The player: where they are and where they look. main owns it; the camera
// is derived from it every frame (camera_of), never stored back.
Player :: struct {
	position: [3]f32, // the eye (step 3b: feet, with the eye EYE_HEIGHT above)
	yaw:      f32, // degrees, see geom/look.odin
	pitch:    f32, // degrees, clamped by geom.clamp_pitch
}

FOV_Y :: 70 // vertical field of view, degrees

// A player at `eye` looking toward `target`.
player_looking_at :: proc(eye, target: [3]f32) -> Player {
	yaw, pitch := geom.look_angles(target - eye)
	return {position = eye, yaw = yaw, pitch = pitch}
}

// The raylib camera for drawing and picking: at the eye, looking along the
// player's view direction.
camera_of :: proc(p: ^Player) -> rl.Camera3D {
	return {
		position = p.position,
		target = p.position + geom.look_direction(p.yaw, p.pitch),
		up = {0, 1, 0},
		fovy = FOV_Y,
		projection = .PERSPECTIVE,
	}
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
