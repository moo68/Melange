package render

import "core:fmt"
import "core:time"
import "melange:geom"
import "melange:prof"
import "melange:world"
import rl "third_party:raylib"

// Top-left debug text. Call after EndMode3D.
draw_debug_overlay :: proc(r: ^Renderer, w: ^world.World, s: ^world.Streamer, camera: rl.Camera3D, target: Maybe(geom.Ray_Hit), selected: world.Block_ID, wireframe, cull_frozen: bool) {
	prof.scope("debug overlay")
	buf: [256]u8
	p := camera.position
	line :: proc(buf: []u8, y: i32, format: string, args: ..any) {
		text := fmt.bprintf(buf, format, ..args)
		// bprintf doesn't null-terminate; DrawText needs a cstring.
		if len(text) < len(buf) {
			buf[len(text)] = 0
		}
		rl.DrawText(cstring(raw_data(buf)), 10, y, 20, rl.RAYWHITE)
	}
	rl.DrawRectangle(0, 0, 520, 292, {0, 0, 0, 140})
	line(buf[:], 10, "FPS %d", rl.GetFPS())
	line(buf[:], 32, "pos %.1f %.1f %.1f  seed %d", p.x, p.y, p.z, w.seed)
	line(buf[:], 54, "chunks %d loaded, %d meshed", world.world_loaded_chunk_count(w), len(r.meshes))
	line(buf[:], 76, "draw calls %d, culled %d, faces %d", r.stats.draw_calls, r.stats.culled, r.stats.faces_drawn)
	line(buf[:], 98, "mesh: %d in %.2f ms, %d pending", r.stats.remeshed, ms(r.stats.mesh_time), r.stats.dirty_pending)
	line(
		buf[:],
		120,
		"stream: +%d (%.2f ms) -%d, to scan %d, regions to check %d",
		s.stats.loaded,
		ms(s.stats.gen_time),
		s.stats.unloaded,
		s.stats.load_scan_left,
		s.stats.unload_regions_left,
	)
	line(buf[:], 142, "per chunk: gen %.3f ms, mesh %.3f ms", per(s.stats.gen_time, s.stats.loaded), per(r.stats.mesh_time, r.stats.remeshed))
	if hit, ok := target.?; ok {
		b := hit.block
		id, _ := world.world_get_block(w, b)
		line(buf[:], 164, "target %d %d %d  %s  face %s", b.x, b.y, b.z, world.block_name(id), face_label(hit.normal))
	} else {
		line(buf[:], 164, "target none")
	}
	line(buf[:], 186, "place %s  (1 stone, 2 dirt, 3 grass)", world.block_name(selected))
	line(buf[:], 216, "F1 wireframe [%s]", "on" if wireframe else "off")
	line(buf[:], 238, "F2 freeze culling [%s]", "on" if cull_frozen else "off")
	line(buf[:], 260, "F3 debug: flying (F3 again to walk)")
}

@(private)
face_label :: proc(normal: [3]i32) -> string {
	switch normal {
	case {1, 0, 0}:
		return "+X"
	case {-1, 0, 0}:
		return "-X"
	case {0, 1, 0}:
		return "+Y (top)"
	case {0, -1, 0}:
		return "-Y (bottom)"
	case {0, 0, 1}:
		return "+Z"
	case {0, 0, -1}:
		return "-Z"
	}
	return "none (inside)"
}

@(private)
ms :: proc(d: time.Duration) -> f64 {
	return time.duration_milliseconds(d)
}

@(private)
per :: proc(d: time.Duration, n: int) -> f64 {
	return ms(d) / f64(n) if n > 0 else 0
}
