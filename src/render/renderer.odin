package render

import "core:fmt"
import "core:os"
import "core:strings"
import "core:slice"
import "core:time"
import "melange:geom"
import "melange:mesh"
import "melange:prof"
import "melange:world"
import rl "third_party:raylib"
import "third_party:raylib/rlgl"

// Max chunks re-meshed + uploaded per frame, so a burst of dirty chunks
// (initial load, explosions) spreads over a few frames instead of stalling one.
DEFAULT_REMESH_BUDGET :: 64

// Relative to the project root (run.sh runs from there).
ATLAS_PATH       :: "assets/textures/atlas.png"
CHUNK_SHADER_VS  :: "assets/shaders/chunk.vs"
CHUNK_SHADER_FS  :: "assets/shaders/chunk.fs"

// Clear color, and the color terrain fades into with distance.
SKY_COLOR :: rl.Color{world.SKY_COLOR.r, world.SKY_COLOR.g, world.SKY_COLOR.b, 255}

// One chunk pass on the GPU: a vertex array object with its packed vertex
// buffer (mesh.Vertex, 8 B each) and the Renderer's shared index buffer.
// No CPU copy is kept. quads = 0: no faces, nothing allocated.
GPU_Mesh :: struct {
	vao, vbo: u32,
	quads:    i32,
}

// A chunk's GPU meshes, one per pass.
Chunk_Meshes :: [mesh.Pass]GPU_Mesh

// The chunk shader for one pass: chunk.fs compiled with `#define CUTOUT`
// (alpha test with discard) or `#define TRANSLUCENT` (outputs the texel's
// alpha for blending); the opaque one has neither, so the GPU keeps early
// depth testing for most of the world.
Pass_Shader :: struct {
	shader:         rl.Shader,
	loc_mvp:        i32,
	loc_chunk_origin: i32,
	loc_texture:    i32,
	loc_camera_pos: i32,
	loc_fog_color:  i32,
	loc_fog_start:  i32,
	loc_fog_end:    i32,
	loc_fog_tint:   i32,
	loc_fog_spherical: i32,
}

// Polygon offset for the translucent pass (raylib's rlgl doesn't wrap it).
// Water faces against glass/leaves lie in those blocks' face plane (see
// world.face_extent); without a bias the two z-fight, since water is drawn
// double-sided. A positive offset makes water lose every depth tie, so the
// other block's face always wins in that plane; away from it the slope-scaled
// bias is far too small to matter. GL 1.1 functions, looked up once through
// raylib's own loader (rlgl.GetProcAddress) after the window exists.
GL_POLYGON_OFFSET_FILL :: 0x8037
POLYGON_OFFSET_FACTOR :: 1 // × the surface's depth slope (grazing angles)
POLYGON_OFFSET_UNITS :: 1 // × the smallest resolvable depth step

Polygon_Offset_Procs :: struct {
	enable:  proc "c" (cap: u32),
	disable: proc "c" (cap: u32),
	offset:  proc "c" (factor, units: f32),
}

// glDrawElements, called directly so the index type is certainly u16 (the
// shared index buffer); looked up like the polygon offset procs.
GL_TRIANGLES      :: 0x0004
GL_UNSIGNED_SHORT :: 0x1403
Draw_Elements_Proc :: proc "c" (mode: u32, count: i32, type: u32, indices: rawptr)

// The packed vertex attribute (mesh.Vertex as one vec4 of unsigned shorts).
// raylib binds `vertexPosition` to location 0 when it links a shader;
// load_pass_shader checks that.
VERTEX_ATTRIB_LOCATION :: 0

// GPU-side state for all chunk meshes. Owns raylib resources, so it must be
// created after InitWindow and destroyed before CloseWindow.
Renderer :: struct {
	// Only chunks with at least one face (in any pass) have an entry.
	meshes:        map[[3]i32]Chunk_Meshes,
	atlas:         rl.Texture2D, // block texture atlas, owned by the Renderer
	// Chunk shaders (assets/shaders/chunk.*), owned by the Renderer.
	shaders:       [mesh.Pass]Pass_Shader,
	// The index buffer every chunk mesh draws with (mesh.quad_indices for
	// mesh.MAX_FACES faces, 147 KB).
	quad_ebo:      u32,
	draw_elements: Draw_Elements_Proc,
	gpu_bytes:     int, // vertex buffer bytes of all chunk meshes
	// Reused for every rebuild: no per-chunk Odin allocations once grown.
	scratch:       mesh.Chunk_Mesh,
	// nil procs if the GL functions weren't found: water then just z-fights
	// with glass/leaves (a warning is printed).
	gl_offset:     Polygon_Offset_Procs,
	// Visible chunks with a cutout / translucent mesh, collected during the
	// opaque pass.
	cutout_visible:      [dynamic][3]i32,
	translucent_visible: [dynamic]world.Chunk_Distance,
	dirty:         [dynamic][3]i32,
	order:         [dynamic]world.Queued_Chunk, // dirty chunks, nearest first
	remesh_budget: int,
	stats:         Stats,
	// The fog last sent to the shaders (renderer_set_fog).
	fog:           world.Fog,
	fog_sent:      bool,
}

Stats :: struct {
	draw_calls:     int, // last frame, all passes
	vertices:       int, // in all chunk meshes now
	culled:         int, // last frame: meshes skipped by frustum culling
	faces_drawn:    int, // last frame
	remeshed:       int, // last frame
	dirty_pending:  int, // dirty chunks left after last update
	mesh_time:      time.Duration, // mesh + upload time, last frame
}

Init_Error :: enum {
	None,
	Atlas,  // ATLAS_PATH missing or unreadable
	Shader, // chunk shader missing or failed to compile (raylib logs the GLSL error)
	GL,     // glDrawElements not found
}

// Loads the atlas and chunk shader. On error nothing is left allocated.
renderer_init :: proc(r: ^Renderer, allocator := context.allocator) -> Init_Error {
	r.atlas = rl.LoadTexture(ATLAS_PATH)
	if !rl.IsTextureValid(r.atlas) {
		return .Atlas
	}
	// Nearest-neighbor for crisp pixels. No mipmaps yet: with an atlas they
	// bleed neighboring tiles together at a distance.
	rl.SetTextureFilter(r.atlas, .POINT)

	ok: [mesh.Pass]bool
	for pass in mesh.Pass {
		r.shaders[pass], ok[pass] = load_pass_shader(pass)
	}
	if !ok[.Opaque] || !ok[.Cutout] || !ok[.Translucent] {
		for pass in mesh.Pass {
			if ok[pass] {
				rl.UnloadShader(r.shaders[pass].shader)
			}
		}
		rl.UnloadTexture(r.atlas)
		r.shaders = {}
		return .Shader
	}

	r.draw_elements = auto_cast rlgl.GetProcAddress("glDrawElements")
	if r.draw_elements == nil {
		for pass in mesh.Pass {
			rl.UnloadShader(r.shaders[pass].shader)
		}
		rl.UnloadTexture(r.atlas)
		r.shaders = {}
		return .GL
	}
	indices := make([]u16, mesh.MAX_FACES * 6, context.temp_allocator)
	mesh.quad_indices(indices)
	r.quad_ebo = rlgl.LoadVertexBufferElement(raw_data(indices), i32(len(indices) * size_of(u16)), false)
	rlgl.DisableVertexBufferElement()
	table := mesh.shade_table()
	for &ps in r.shaders {
		loc := rl.GetShaderLocation(ps.shader, "shadeTable")
		rl.SetShaderValueV(ps.shader, loc, &table, .FLOAT, i32(len(table)))
	}

	r.meshes = make(map[[3]i32]Chunk_Meshes, allocator)
	r.cutout_visible = make([dynamic][3]i32, allocator)
	r.translucent_visible = make([dynamic]world.Chunk_Distance, allocator)
	r.dirty = make([dynamic][3]i32, allocator)
	r.order = make([dynamic]world.Queued_Chunk, allocator)
	r.remesh_budget = DEFAULT_REMESH_BUDGET
	r.gl_offset = {
		enable  = auto_cast rlgl.GetProcAddress("glEnable"),
		disable = auto_cast rlgl.GetProcAddress("glDisable"),
		offset  = auto_cast rlgl.GetProcAddress("glPolygonOffset"),
	}
	if r.gl_offset.enable == nil || r.gl_offset.disable == nil || r.gl_offset.offset == nil {
		fmt.eprintln("warning: glPolygonOffset unavailable; water may flicker against glass and leaves")
		r.gl_offset = {}
	}

	// Effectively off until the caller sets one.
	r.fog_sent = false
	renderer_set_fog(r, {color = world.SKY_COLOR, tint = {1, 1, 1}, start = 0, end = 1e9})
	return .None
}

// Loads chunk.vs + chunk.fs for `pass` (the cutout pass with `#define
// CUTOUT` inserted after the #version line). On a missing file or compile
// error raylib falls back to its default shader instead of failing (which
// would silently drop fog etc.), so that counts as failure.
@(private)
load_pass_shader :: proc(pass: mesh.Pass) -> (ps: Pass_Shader, ok: bool) {
	vs_text, vs_err := os.read_entire_file(CHUNK_SHADER_VS, context.temp_allocator)
	fs_text, fs_err := os.read_entire_file(CHUNK_SHADER_FS, context.temp_allocator)
	if vs_err != nil || fs_err != nil {
		return {}, false
	}
	fs := string(fs_text)
	define := ""
	switch pass {
	case .Opaque:
	case .Cutout:
		define = "#define CUTOUT\n"
	case .Translucent:
		define = "#define TRANSLUCENT\n"
	}
	if define != "" {
		eol := strings.index_byte(fs, '\n')
		if eol < 0 || !strings.has_prefix(fs, "#version") {
			return {}, false
		}
		fs = strings.concatenate({fs[:eol + 1], define, fs[eol + 1:]}, context.temp_allocator)
	}
	ps.shader = rl.LoadShaderFromMemory(strings.clone_to_cstring(string(vs_text), context.temp_allocator), strings.clone_to_cstring(fs, context.temp_allocator))
	if !rl.IsShaderValid(ps.shader) || ps.shader.id == rlgl.GetShaderIdDefault() {
		return {}, false
	}
	if rl.GetShaderLocationAttrib(ps.shader, "vertexPosition") != VERTEX_ATTRIB_LOCATION {
		rl.UnloadShader(ps.shader)
		return {}, false
	}
	ps.loc_mvp = rl.GetShaderLocation(ps.shader, "mvp")
	ps.loc_chunk_origin = rl.GetShaderLocation(ps.shader, "chunkOrigin")
	ps.loc_texture = rl.GetShaderLocation(ps.shader, "texture0")
	ps.loc_camera_pos = rl.GetShaderLocation(ps.shader, "cameraPos")
	ps.loc_fog_color = rl.GetShaderLocation(ps.shader, "fogColor")
	ps.loc_fog_start = rl.GetShaderLocation(ps.shader, "fogStart")
	ps.loc_fog_end = rl.GetShaderLocation(ps.shader, "fogEnd")
	ps.loc_fog_tint = rl.GetShaderLocation(ps.shader, "fogTint")
	ps.loc_fog_spherical = rl.GetShaderLocation(ps.shader, "fogSpherical")
	return ps, true
}
// Sets the chunk shaders' fog (see world.Fog). Cheap to call every frame:
// uniforms are only sent when the fog changed.
renderer_set_fog :: proc(r: ^Renderer, fog: world.Fog) {
	if r.fog_sent && r.fog == fog {
		return
	}
	r.fog, r.fog_sent = fog, true
	color := [3]f32{f32(fog.color.r), f32(fog.color.g), f32(fog.color.b)} / 255
	tint, start, end := fog.tint, fog.start, fog.end
	spherical := i32(fog.spherical)
	for &ps in r.shaders {
		rl.SetShaderValue(ps.shader, ps.loc_fog_color, &color, .VEC3)
		rl.SetShaderValue(ps.shader, ps.loc_fog_tint, &tint, .VEC3)
		rl.SetShaderValue(ps.shader, ps.loc_fog_start, &start, .FLOAT)
		rl.SetShaderValue(ps.shader, ps.loc_fog_end, &end, .FLOAT)
		rl.SetShaderValue(ps.shader, ps.loc_fog_spherical, &spherical, .INT)
	}
}

// The clear color for the current fog (the sky, or deep water under water).
renderer_clear_color :: proc(r: ^Renderer) -> rl.Color {
	return {r.fog.color.r, r.fog.color.g, r.fog.color.b, 255}
}

// Drops every chunk mesh and pending remesh (closing a world); the shader,
// atlas, fog and scratch buffers stay for the next world.
renderer_clear_chunks :: proc(r: ^Renderer) {
	for _, &m in r.meshes {
		unload_chunk_meshes(r, &m)
	}
	clear(&r.meshes)
	clear(&r.dirty)
	clear(&r.order)
	r.stats = {}
}

renderer_destroy :: proc(r: ^Renderer) {
	for _, &m in r.meshes {
		unload_chunk_meshes(r, &m)
	}
	delete(r.meshes)
	delete(r.dirty)
	delete(r.order)
	delete(r.cutout_visible)
	delete(r.translucent_visible)
	mesh.chunk_mesh_destroy(&r.scratch)
	rlgl.UnloadVertexBuffer(r.quad_ebo)
	for ps in r.shaders {
		rl.UnloadShader(ps.shader)
	}
	rl.UnloadTexture(r.atlas)
	r^ = {}
}

// Re-meshes up to `remesh_budget` dirty chunks, nearest to `center` first.
//
// A chunk is only meshed once all 6 neighbors are loaded, so border faces are
// always culled against real data (no fake faces toward unloaded space).
// Dirty chunks missing a neighbor are cleared and lose any mesh; when the
// missing neighbor loads, world_create_chunk marks them dirty again.
renderer_update :: proc(r: ^Renderer, w: ^world.World, center: [3]i32) {
	prof.scope("renderer_update")
	{
		prof.scope("collect dirty")
		clear(&r.dirty)
		world.world_collect_dirty(w, &r.dirty)
		clear(&r.order)
		for c in r.dirty {
			d := c - center
			append(&r.order, world.Queued_Chunk{c, d.x * d.x + d.y * d.y + d.z * d.z})
		}
		slice.sort_by(r.order[:], proc(a, b: world.Queued_Chunk) -> bool {
			return a.dist2 < b.dist2
		})
	}

	start := time.tick_now()
	meshed, processed := 0, 0
	for q in r.order {
		if meshed >= r.remesh_budget {
			break
		}
		processed += 1
		world.world_clear_dirty(w, q.coord)
		if remesh_chunk(r, w, q.coord) {
			meshed += 1
		}
	}
	r.stats.mesh_time = time.tick_since(start)
	r.stats.remeshed = meshed
	r.stats.dirty_pending = len(r.order) - processed
}

// Frees GPU meshes for chunks the world unloaded (Streamer.unloaded).
renderer_forget_chunks :: proc(r: ^Renderer, coords: [][3]i32) {
	for c in coords {
		renderer_forget_chunk(r, c)
	}
}

// Frees a chunk's GPU mesh. Call when the world unloads that chunk.
renderer_forget_chunk :: proc(r: ^Renderer, coord: [3]i32) {
	if m, ok := &r.meshes[coord]; ok {
		unload_chunk_meshes(r, m)
		delete_key(&r.meshes, coord)
	}
}

@(private)
unload_chunk_meshes :: proc(r: ^Renderer, m: ^Chunk_Meshes) {
	for &p in m {
		if p.quads > 0 {
			rlgl.UnloadVertexArray(p.vao)
			rlgl.UnloadVertexBuffer(p.vbo)
			r.gpu_bytes -= int(p.quads) * 4 * size_of(mesh.Vertex)
			r.stats.vertices -= int(p.quads) * 4
		}
		p = {}
	}
}

// Draws every chunk mesh inside `frustum`. Call between BeginMode3D / EndMode3D.
// The opaque pass first, then the cutout pass (alpha-tested, so it needs no
// sorting; drawing it second lets opaque terrain behind leaves fill the depth
// buffer first), then the translucent pass: chunks sorted back to front,
// alpha-blended, depth-tested but not written (water behind water still
// shows), double-sided (the surface is visible from underwater), and with a
// polygon offset (see GL_POLYGON_OFFSET_FILL) so it never z-fights. Faces
// within one chunk aren't sorted; with one uniform water color that's
// invisible.
renderer_draw :: proc(r: ^Renderer, frustum: ^geom.Frustum, camera_pos: [3]f32) {
	prof.scope("renderer_draw")
	// Our draws bypass raylib's batch: flush whatever it has queued first.
	rlgl.DrawRenderBatchActive()
	// Set up by BeginMode3D; chunk positions are world space (chunkOrigin +
	// local), so this is the whole transform.
	// rl.Matrix is the math matrix (row-major), so this is projection × view;
	// rl.MatrixMultiply(view, projection) would be the C idiom's order, not
	// the binding's (it's plain left * right).
	mvp := rlgl.GetMatrixProjection() * rlgl.GetMatrixModelview()
	camera_pos := camera_pos

	r.stats.draw_calls = 0
	r.stats.culled = 0
	r.stats.faces_drawn = 0
	clear(&r.cutout_visible)
	clear(&r.translucent_visible)
	rlgl.ActiveTextureSlot(0)
	rlgl.EnableTexture(r.atlas.id)

	begin_pass(r, .Opaque, &mvp, &camera_pos)
	for coord, &m in r.meshes {
		o := world.chunk_origin(coord)
		box_min := [3]f32{f32(o.x), f32(o.y), f32(o.z)}
		if !geom.frustum_intersects_aabb(frustum, box_min, box_min + world.CHUNK_SIZE) {
			r.stats.culled += 1
			continue
		}
		draw_pass_mesh(r, .Opaque, &m[.Opaque], o)
		if m[.Cutout].quads > 0 {
			append(&r.cutout_visible, coord)
		}
		if m[.Translucent].quads > 0 {
			append(&r.translucent_visible, world.Chunk_Distance{coord, world.chunk_center_dist2(coord, camera_pos)})
		}
	}
	begin_pass(r, .Cutout, &mvp, &camera_pos)
	for coord in r.cutout_visible {
		m := r.meshes[coord][.Cutout]
		draw_pass_mesh(r, .Cutout, &m, world.chunk_origin(coord))
	}
	if len(r.translucent_visible) > 0 {
		world.sort_far_first(r.translucent_visible[:])
		begin_pass(r, .Translucent, &mvp, &camera_pos)
		// raylib keeps GL_BLEND on with alpha blending (its default mode);
		// set it explicitly anyway, it only flushes the (empty) batch.
		rl.BeginBlendMode(.ALPHA)
		rlgl.DisableDepthMask()
		rlgl.DisableBackfaceCulling()
		if r.gl_offset.offset != nil {
			r.gl_offset.offset(POLYGON_OFFSET_FACTOR, POLYGON_OFFSET_UNITS)
			r.gl_offset.enable(GL_POLYGON_OFFSET_FILL)
		}
		for q in r.translucent_visible {
			m := r.meshes[q.coord][.Translucent]
			draw_pass_mesh(r, .Translucent, &m, world.chunk_origin(q.coord))
		}
		if r.gl_offset.offset != nil {
			r.gl_offset.disable(GL_POLYGON_OFFSET_FILL)
		}
		rlgl.EnableBackfaceCulling()
		rlgl.EnableDepthMask()
		rl.EndBlendMode()
	}
	rlgl.DisableVertexArray()
	rlgl.DisableShader()
	rlgl.DisableTexture()
}

// Activates a pass's shader with this frame's per-pass uniforms.
@(private)
begin_pass :: proc(r: ^Renderer, pass: mesh.Pass, mvp: ^rl.Matrix, camera_pos: ^[3]f32) {
	ps := &r.shaders[pass]
	rlgl.EnableShader(ps.shader.id)
	rlgl.SetUniformMatrix(ps.loc_mvp, mvp^)
	rlgl.SetUniform(ps.loc_camera_pos, camera_pos, i32(rl.ShaderUniformDataType.VEC3), 1)
	slot: i32 = 0
	rlgl.SetUniform(ps.loc_texture, &slot, i32(rl.ShaderUniformDataType.INT), 1)
}

// Draws one chunk pass with its pass's shader active (begin_pass).
@(private)
draw_pass_mesh :: proc(r: ^Renderer, pass: mesh.Pass, m: ^GPU_Mesh, o: [3]i32) {
	if m.quads == 0 {
		return
	}
	origin := [3]f32{f32(o.x), f32(o.y), f32(o.z)}
	rlgl.SetUniform(r.shaders[pass].loc_chunk_origin, &origin, i32(rl.ShaderUniformDataType.VEC3), 1)
	rlgl.EnableVertexArray(m.vao)
	r.draw_elements(GL_TRIANGLES, m.quads * 6, GL_UNSIGNED_SHORT, nil)
	r.stats.draw_calls += 1
	r.stats.faces_drawn += int(m.quads)
}

// Rebuilds one chunk's mesh. Returns false if it was skipped without meshing
// (not loaded, or a neighbor is missing); any old mesh is dropped either way.
@(private)
remesh_chunk :: proc(r: ^Renderer, w: ^world.World, coord: [3]i32) -> bool {
	renderer_forget_chunk(r, coord)

	if world.world_get_chunk(w, coord) == nil {
		return false
	}
	// All 26 surrounding chunks: faces for culling, edges/corners for AO.
	// Only the 6 face neighbors are required; a missing edge/corner chunk just
	// means slightly brighter AO at that corner until it loads (and its
	// loading re-dirties this chunk).
	hood := world.world_get_neighborhood(w, coord)
	faces := world.neighborhood_faces(&hood)
	if !world.neighbors_complete(&faces) {
		return false
	}
	light := world.world_get_light_neighborhood(w, coord)
	prof.begin("mesh chunk")
	mesh.build_chunk_mesh_neighborhood(&hood, &r.scratch, &light)
	prof.end()
	if mesh.chunk_mesh_face_count(&r.scratch) > 0 {
		prof.scope("upload")
		gpu: Chunk_Meshes
		for pass in mesh.Pass {
			if mesh.face_count(&r.scratch[pass]) > 0 {
				gpu[pass] = upload(r, &r.scratch[pass])
			}
		}
		r.meshes[coord] = gpu
	} // else: empty or fully buried: no mesh, no draw call
	return true
}

// Uploads one pass's packed vertices into a new vertex array object bound
// to the shared index buffer. The CPU data stays in the caller's scratch
// mesh (reused), so nothing is kept per chunk on the CPU.
@(private)
upload :: proc(r: ^Renderer, d: ^mesh.Mesh_Data) -> (g: GPU_Mesh) {
	g.quads = i32(mesh.face_count(d))
	bytes := len(d.vertices) * size_of(mesh.Vertex)
	g.vao = rlgl.LoadVertexArray()
	rlgl.EnableVertexArray(g.vao)
	g.vbo = rlgl.LoadVertexBuffer(raw_data(d.vertices), i32(bytes), false)
	rlgl.SetVertexAttribute(VERTEX_ATTRIB_LOCATION, 4, GL_UNSIGNED_SHORT, false, size_of(mesh.Vertex), 0)
	rlgl.EnableVertexAttribute(VERTEX_ATTRIB_LOCATION)
	rlgl.EnableVertexBufferElement(r.quad_ebo) // recorded in the VAO
	// Unbind the VAO first: unbinding the index buffer while it's bound
	// would remove it from the VAO.
	rlgl.DisableVertexArray()
	rlgl.DisableVertexBuffer()
	rlgl.DisableVertexBufferElement()
	r.gpu_bytes += bytes
	r.stats.vertices += len(d.vertices)
	return
}
