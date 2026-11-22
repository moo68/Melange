package player

import rl "third_party:raylib"

// TEMPORARY free-fly camera until real player movement/physics exists.
// Same feel as raylib's CAMERA_FREE (same base speed and mouse sensitivity),
// plus Shift to sprint.

FLY_SPEED         :: 5.4  // blocks per second (raylib's CAMERA_MOVE_SPEED)
FLY_SPRINT_FACTOR :: 5.0
MOUSE_SENSITIVITY :: 0.172 // degrees per pixel (raylib's 0.003 rad)

// Mouse look; WASD move (horizontal); Space up; Ctrl down; Shift sprint.
// Pass look = false to ignore the mouse this frame: right after DisableCursor
// the first mouse delta can be a huge jump (cursor warped to window center).
update_fly_camera :: proc(camera: ^rl.Camera3D, look := true) {
	speed := f32(FLY_SPEED)
	if rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT) {
		speed *= FLY_SPRINT_FACTOR
	}
	step := speed * rl.GetFrameTime()

	// UpdateCameraPro: x = forward, y = right, z = up (in world units).
	move: rl.Vector3
	if rl.IsKeyDown(.W) {move.x += step}
	if rl.IsKeyDown(.S) {move.x -= step}
	if rl.IsKeyDown(.D) {move.y += step}
	if rl.IsKeyDown(.A) {move.y -= step}
	if rl.IsKeyDown(.SPACE) {move.z += step}
	if rl.IsKeyDown(.LEFT_CONTROL) {move.z -= step}

	// x = yaw, y = pitch (degrees).
	mouse := rl.GetMouseDelta() if look else {}
	rotation := rl.Vector3{mouse.x * MOUSE_SENSITIVITY, mouse.y * MOUSE_SENSITIVITY, 0}

	rl.UpdateCameraPro(camera, move, rotation, 0)
}
