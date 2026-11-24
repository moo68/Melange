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
	// Lines are formatted first, then the background is sized to fit them
	// (seeds and stream stats vary a lot in width), then drawn.
	o: Overlay_Lines
	line :: proc(o: ^Overlay_Lines, y: i32, format: string, args: ..any) {
		if o.count == len(o.text) {
			return
		}
		buf := o.text[o.count][:]
		text := fmt.bprintf(buf[:len(buf) - 1], format, ..args)
		buf[len(text)] = 0 // bprintf doesn't null-terminate; DrawText needs a cstring
		o.y[o.count] = y
		o.count += 1
	}
	p := camera.position
	line(&o, 10, "FPS %d", rl.GetFPS())
	line(&o, 32, "pos %.1f %.1f %.1f  seed %d", p.x, p.y, p.z, w.seed)
	line(&o, 54, "chunks %d loaded, %d meshed", world.world_loaded_chunk_count(w), len(r.meshes))
	line(&o, 76, "draw calls %d, culled %d, faces %d", r.stats.draw_calls, r.stats.culled, r.stats.faces_drawn)
	line(&o, 98, "mesh: %d in %.2f ms, %d pending", r.stats.remeshed, ms(r.stats.mesh_time), r.stats.dirty_pending)
	line(
		&o,
		120,
		"stream: +%d (%.2f ms) -%d, to scan %d, regions to check %d",
		s.stats.loaded,
		ms(s.stats.gen_time),
		s.stats.unloaded,
		s.stats.load_scan_left,
		s.stats.unload_regions_left,
	)
	line(&o, 142, "per chunk: gen %.3f ms, mesh %.3f ms", per(s.stats.gen_time, s.stats.loaded), per(r.stats.mesh_time, r.stats.remeshed))
	if hit, ok := target.?; ok {
		b := hit.block
		id, _ := world.world_get_block(w, b)
		line(&o, 164, "target %d %d %d  %s  face %s", b.x, b.y, b.z, world.block_name(id), face_label(hit.normal))
	} else {
		line(&o, 164, "target none")
	}
	line(&o, 186, "place %s  (1 stone, 2 dirt, 3 grass, 4 glass, 5 leaves, 6 water, 7 sand)", world.block_name(selected))
	line(&o, 208, "edits %d in %d chunks", w.edit_count, len(w.edits))
	line(&o, 238, "F1 wireframe [%s]", "on" if wireframe else "off")
	line(&o, 260, "F2 freeze culling [%s]", "on" if cull_frozen else "off")
	line(&o, 282, "F3 debug: flying (F3 again to walk)")

	width: i32 = 0
	for i in 0 ..< o.count {
		width = max(width, rl.MeasureText(cstring(raw_data(o.text[i][:])), OVERLAY_FONT_SIZE))
	}
	bottom := o.y[o.count - 1] + OVERLAY_FONT_SIZE if o.count > 0 else 0
	rl.DrawRectangle(0, 0, width + 2 * OVERLAY_MARGIN, bottom + OVERLAY_MARGIN + 2, {0, 0, 0, 140})
	for i in 0 ..< o.count {
		rl.DrawText(cstring(raw_data(o.text[i][:])), OVERLAY_MARGIN, o.y[i], OVERLAY_FONT_SIZE, rl.RAYWHITE)
	}
}

OVERLAY_FONT_SIZE :: 20
OVERLAY_MARGIN :: 10 // text inset from the window edge; also the box's padding

@(private)
Overlay_Lines :: struct {
	text:  [16][160]u8,
	y:     [16]i32,
	count: int,
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
