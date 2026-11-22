package player

import "melange:geom"
import rl "third_party:raylib"

// Free-fly movement (passes through blocks). Same feel as raylib's
// CAMERA_FREE, which it replaced: same base speed and mouse sensitivity,
// horizontal movement along the ground plane whatever the pitch, and each
// key moving at full speed on its own axis (so diagonals are √2 faster).

FLY_SPEED         :: 5.4  // blocks per second (raylib's CAMERA_MOVE_SPEED)
FLY_SPRINT_FACTOR :: 5.0
MOUSE_SENSITIVITY :: 0.172 // degrees per pixel (raylib's 0.003 rad)

// WASD move (horizontal); Space up; Ctrl down; Shift sprint.
update_fly :: proc(p: ^Player) {
	speed := f32(FLY_SPEED)
	if rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT) {
		speed *= FLY_SPRINT_FACTOR
	}
	step := speed * rl.GetFrameTime()

	forward, right := geom.look_basis(p.yaw)
	axis :: proc(pos, neg: rl.KeyboardKey) -> f32 {
		return f32(int(rl.IsKeyDown(pos))) - f32(int(rl.IsKeyDown(neg)))
	}
	p.position += forward * axis(.W, .S) * step
	p.position += right * axis(.D, .A) * step
	p.position.y += axis(.SPACE, .LEFT_CONTROL) * step
}
