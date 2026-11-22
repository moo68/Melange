package render

import "core:mem"
import "core:slice"
import "core:time"
import "melange:geom"
import "melange:mesh"
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
SKY_COLOR :: rl.Color{135, 190, 235, 255}

// GPU-side state for all chunk meshes. Owns raylib resources, so it must be
// created after InitWindow and destroyed before CloseWindow.
Renderer :: struct {
	// Only chunks with at least one face have an entry.
	meshes:        map[[3]i32]rl.Mesh,
	material:      rl.Material,
	atlas:         rl.Texture2D, // block texture atlas, owned by the Renderer
	shader:        rl.Shader, // chunk shader (assets/shaders/chunk.*), owned by the Renderer
	// What LoadMaterialDefault put in the material, restored before
	// UnloadMaterial so it doesn't also unload our shader.
	default_shader: rl.Shader,
	loc_camera_pos: i32,
	loc_fog_color:  i32,
	loc_fog_start:  i32,
	loc_fog_end:    i32,
	// Reused for every rebuild: no per-chunk Odin allocations once grown.
	scratch:       mesh.Mesh_Data,
	dirty:         [dynamic][3]i32,
	order:         [dynamic]world.Queued_Chunk, // dirty chunks, nearest first
	remesh_budget: int,
	stats:         Stats,
}

Stats :: struct {
	draw_calls:     int, // last frame
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

	r.shader = rl.LoadShader(CHUNK_SHADER_VS, CHUNK_SHADER_FS)
	// On a missing file or compile error raylib falls back to its default
	// shader instead of failing, which would silently drop fog etc.
	if !rl.IsShaderValid(r.shader) || r.shader.id == rlgl.GetShaderIdDefault() {
		rl.UnloadTexture(r.atlas)
		return .Shader
	}
	r.loc_camera_pos = rl.GetShaderLocation(r.shader, "cameraPos")
	r.loc_fog_color = rl.GetShaderLocation(r.shader, "fogColor")
	r.loc_fog_start = rl.GetShaderLocation(r.shader, "fogStart")
	r.loc_fog_end = rl.GetShaderLocation(r.shader, "fogEnd")

	r.meshes = make(map[[3]i32]rl.Mesh, allocator)
	r.dirty = make([dynamic][3]i32, allocator)
	r.order = make([dynamic]world.Queued_Chunk, allocator)
	r.material = rl.LoadMaterialDefault()
	r.default_shader = r.material.shader
	r.material.shader = r.shader
	r.material.maps[rl.MaterialMapIndex.ALBEDO].texture = r.atlas
	r.remesh_budget = DEFAULT_REMESH_BUDGET

	sky := [3]f32{f32(SKY_COLOR.r), f32(SKY_COLOR.g), f32(SKY_COLOR.b)} / 255
	rl.SetShaderValue(r.shader, r.loc_fog_color, &sky, .VEC3)
	renderer_set_fog(r, 0, 1e9) // effectively off until the caller sets it
	return .None
}

// Fog fades terrain into SKY_COLOR between `start` and `end` blocks of
// horizontal distance from the camera.
renderer_set_fog :: proc(r: ^Renderer, start, end: f32) {
	start, end := start, end
	rl.SetShaderValue(r.shader, r.loc_fog_start, &start, .FLOAT)
	rl.SetShaderValue(r.shader, r.loc_fog_end, &end, .FLOAT)
}

renderer_destroy :: proc(r: ^Renderer) {
	for _, m in r.meshes {
		rl.UnloadMesh(m)
	}
	delete(r.meshes)
	delete(r.dirty)
	delete(r.order)
	mesh.mesh_data_destroy(&r.scratch)
	// UnloadMaterial also unloads a non-default shader and any non-default
	// textures in its maps, so put the defaults back first; our shader and
	// atlas are unloaded exactly once, here.
	r.material.shader = r.default_shader
	r.material.maps[rl.MaterialMapIndex.ALBEDO].texture.id = rlgl.GetTextureIdDefault()
	rl.UnloadMaterial(r.material)
	rl.UnloadShader(r.shader)
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
	if m, ok := r.meshes[coord]; ok {
		rl.UnloadMesh(m)
		delete_key(&r.meshes, coord)
	}
}

// Draws every chunk mesh inside `frustum`. Call between BeginMode3D / EndMode3D.
renderer_draw :: proc(r: ^Renderer, frustum: ^geom.Frustum, camera_pos: [3]f32) {
	camera_pos := camera_pos
	rl.SetShaderValue(r.shader, r.loc_camera_pos, &camera_pos, .VEC3)

	r.stats.draw_calls = 0
	r.stats.culled = 0
	r.stats.faces_drawn = 0
	for coord, m in r.meshes {
		o := world.chunk_origin(coord)
		box_min := [3]f32{f32(o.x), f32(o.y), f32(o.z)}
		if !geom.frustum_intersects_aabb(frustum, box_min, box_min + world.CHUNK_SIZE) {
			r.stats.culled += 1
			continue
		}
		rl.DrawMesh(m, r.material, rl.MatrixTranslate(f32(o.x), f32(o.y), f32(o.z)))
		r.stats.draw_calls += 1
		r.stats.faces_drawn += int(m.triangleCount) / 2
	}
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
	mesh.build_chunk_mesh_neighborhood(&hood, &r.scratch)
	if mesh.face_count(&r.scratch) > 0 {
		r.meshes[coord] = upload(&r.scratch)
	} // else: empty or fully buried: no mesh, no draw call
	return true
}

// Copies Mesh_Data into raylib-allocated buffers and uploads them.
//
// Why copy: UnloadMesh frees the Mesh's CPU arrays with raylib's own free(),
// so they must come from raylib's allocator (MemAlloc), never Odin's. And the
// pointers can't simply be nil'd after upload, because DrawMesh uses
// `indices != nil` to pick indexed drawing. (Dropping this CPU copy is a
// later memory optimization.)
@(private)
upload :: proc(d: ^mesh.Mesh_Data) -> rl.Mesh {
	m: rl.Mesh
	m.vertexCount = i32(len(d.positions))
	m.triangleCount = i32(len(d.indices) / 3)
	m.vertices = raylib_copy(f32, d.positions[:])
	m.normals = raylib_copy(f32, d.normals[:])
	m.texcoords = raylib_copy(f32, d.texcoords[:])
	m.texcoords2 = raylib_copy(f32, d.tiles[:]) // -> vertexTexCoord2 in the shader
	m.colors = raylib_copy(u8, d.colors[:])
	m.indices = raylib_copy(u16, d.indices[:])
	rl.UploadMesh(&m, false)
	return m
}

// Copies a slice into memory from raylib's allocator, viewed as [^]T.
@(private)
raylib_copy :: proc($T: typeid, src: []$E) -> [^]T {
	bytes := len(src) * size_of(E)
	dst := rl.MemAlloc(u32(bytes))
	mem.copy(dst, raw_data(src), bytes)
	return cast([^]T)dst
}
