package render

import "melange:geom"
import rl "third_party:raylib"
import "third_party:raylib/rlgl"

// The frustum raylib will actually render with in BeginMode3D: same FOV,
// framebuffer aspect, and near/far clip planes (queried from rlgl, since the
// binding's constants don't match the compiled library's defaults).
camera_frustum :: proc(camera: rl.Camera3D) -> geom.Frustum {
	return geom.frustum_from_perspective(
		{
			position = camera.position,
			target = camera.target,
			up = camera.up,
			fovy_deg = camera.fovy,
			aspect = f32(rl.GetRenderWidth()) / f32(rl.GetRenderHeight()),
			near = f32(rlgl.GetCullDistanceNear()),
			far = f32(rlgl.GetCullDistanceFar()),
		},
	)
}
