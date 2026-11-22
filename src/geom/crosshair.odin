package geom

// Integer pixel rectangle (x, y = top-left).
Pixel_Rect :: struct {
	x, y, w, h: i32,
}

// The two bars of a "+" centered on a screen of the given size: horizontal
// first, then vertical. Each arm reaches `arm` pixels from the center, bars
// are `thickness` pixels wide. With an even screen size and even thickness
// both bars are exactly symmetric about the center.
crosshair_rects :: proc "contextless" (screen_w, screen_h, arm, thickness: i32) -> [2]Pixel_Rect {
	cx, cy := screen_w / 2, screen_h / 2
	half := thickness / 2
	return {
		{cx - arm, cy - half, 2 * arm, thickness},
		{cx - half, cy - arm, thickness, 2 * arm},
	}
}

// `r` grown by `n` pixels on every side.
pixel_rect_grow :: proc "contextless" (r: Pixel_Rect, n: i32) -> Pixel_Rect {
	return {r.x - n, r.y - n, r.w + 2 * n, r.h + 2 * n}
}
