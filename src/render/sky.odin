package render

import "core:math"
import "core:math/linalg"
import "core:os"
import "core:strings"
import "melange:prof"
import "melange:world"
import rl "third_party:raylib"
import "third_party:raylib/rlgl"

// The sky pass (roadmap 3d): one fullscreen triangle drawn before the
// chunks, with depth testing and writes off, so terrain simply covers it.
// assets/shaders/sky.fs computes each pixel's view direction from the
// camera basis and draws the gradient, sun and moon.

SKY_SHADER_VS :: "assets/shaders/sky.vs"
SKY_SHADER_FS :: "assets/shaders/sky.fs"

Draw_Arrays_Proc :: proc "c" (mode: u32, first: i32, count: i32)

Sky_Pass :: struct {
	shader:      rl.Shader,
	vao:         u32, // empty: the vertex shader makes the corners from gl_VertexID
	draw_arrays: Draw_Arrays_Proc,
	loc:         struct {
		forward, right, up, tan_half_fov, aspect, horizon, zenith, sun, arc_normal: i32,
	},
}

// Loads the sky shader. False (nothing left allocated) on a missing file,
// compile error or missing GL function.
sky_init :: proc(s: ^Sky_Pass) -> bool {
	vs, vs_err := os.read_entire_file(SKY_SHADER_VS, context.temp_allocator)
	fs, fs_err := os.read_entire_file(SKY_SHADER_FS, context.temp_allocator)
	if vs_err != nil || fs_err != nil {
		return false
	}
	s.shader = rl.LoadShaderFromMemory(strings.clone_to_cstring(string(vs), context.temp_allocator), strings.clone_to_cstring(string(fs), context.temp_allocator))
	// raylib falls back to its default shader on a compile error.
	if !rl.IsShaderValid(s.shader) || s.shader.id == rlgl.GetShaderIdDefault() {
		s^ = {}
		return false
	}
	s.draw_arrays = auto_cast rlgl.GetProcAddress("glDrawArrays")
	if s.draw_arrays == nil {
		rl.UnloadShader(s.shader)
		s^ = {}
		return false
	}
	s.vao = rlgl.LoadVertexArray() // core profile: drawing needs some VAO bound
	get :: proc(s: ^Sky_Pass, name: cstring) -> i32 {
		return rl.GetShaderLocation(s.shader, name)
	}
	s.loc = {
		forward      = get(s, "camForward"),
		right        = get(s, "camRight"),
		up           = get(s, "camUp"),
		tan_half_fov = get(s, "tanHalfFovY"),
		aspect       = get(s, "aspect"),
		horizon      = get(s, "horizonColor"),
		zenith       = get(s, "zenithColor"),
		sun          = get(s, "sunDir"),
		arc_normal   = get(s, "arcNormal"),
	}
	return true
}

sky_destroy :: proc(s: ^Sky_Pass) {
	if s.shader.id != 0 {
		rl.UnloadShader(s.shader)
	}
	if s.vao != 0 {
		rlgl.UnloadVertexArray(s.vao)
	}
	s^ = {}
}

// Draws the sky for `camera` at world time `time` (call after clearing,
// before BeginMode3D). Restores depth testing, depth writes and culling.
renderer_draw_sky :: proc(r: ^Renderer, camera: rl.Camera3D, time: f64) {
	prof.scope("sky")
	s := &r.sky
	sky := world.sky_at(time)
	forward := linalg.normalize(camera.target - camera.position)
	right := linalg.normalize(linalg.cross(forward, camera.up))
	up := linalg.cross(right, forward)
	tan_half := math.tan(camera.fovy * math.RAD_PER_DEG / 2)
	aspect := f32(rl.GetRenderWidth()) / f32(rl.GetRenderHeight())
	horizon := rgb01(sky.color)
	zenith := rgb01(sky.zenith)
	sun := world.sun_direction(time)
	arc := world.sun_arc_normal()

	rlgl.DrawRenderBatchActive() // nothing of raylib's may be pending in its batch
	rlgl.DisableDepthTest()
	rlgl.DisableDepthMask()
	rlgl.DisableBackfaceCulling()
	rlgl.EnableShader(s.shader.id)
	VEC3 :: i32(rl.ShaderUniformDataType.VEC3)
	FLOAT :: i32(rl.ShaderUniformDataType.FLOAT)
	rlgl.SetUniform(s.loc.forward, &forward, VEC3, 1)
	rlgl.SetUniform(s.loc.right, &right, VEC3, 1)
	rlgl.SetUniform(s.loc.up, &up, VEC3, 1)
	rlgl.SetUniform(s.loc.tan_half_fov, &tan_half, FLOAT, 1)
	rlgl.SetUniform(s.loc.aspect, &aspect, FLOAT, 1)
	rlgl.SetUniform(s.loc.horizon, &horizon, VEC3, 1)
	rlgl.SetUniform(s.loc.zenith, &zenith, VEC3, 1)
	rlgl.SetUniform(s.loc.sun, &sun, VEC3, 1)
	rlgl.SetUniform(s.loc.arc_normal, &arc, VEC3, 1)
	rlgl.EnableVertexArray(s.vao)
	s.draw_arrays(GL_TRIANGLES, 0, 3)
	rlgl.DisableVertexArray()
	rlgl.DisableShader()
	rlgl.EnableBackfaceCulling()
	rlgl.EnableDepthMask()
	rlgl.EnableDepthTest()
}

@(private = "file")
rgb01 :: proc(c: [3]u8) -> [3]f32 {
	return {f32(c.r), f32(c.g), f32(c.b)} / 255
}
