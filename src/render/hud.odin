package render

import "melange:geom"
import rl "third_party:raylib"

CROSSHAIR_ARM       :: 10 // pixels from the center to the end of each arm
CROSSHAIR_THICKNESS :: 2  // even, so the bars are symmetric on even screen sizes
CROSSHAIR_OUTLINE   :: 1  // dark border so it reads on any background
CROSSHAIR_COLOR     :: rl.Color{255, 255, 255, 230}
CROSSHAIR_BORDER    :: rl.Color{0, 0, 0, 200}

// A "+" at the screen center (where block picking aims). Call after
// EndMode3D, in screen space.
draw_crosshair :: proc() {
	bars := geom.crosshair_rects(rl.GetScreenWidth(), rl.GetScreenHeight(), CROSSHAIR_ARM, CROSSHAIR_THICKNESS)
	// Both borders first, so neither bar's border is drawn over the other bar.
	for b in bars {
		o := geom.pixel_rect_grow(b, CROSSHAIR_OUTLINE)
		rl.DrawRectangle(o.x, o.y, o.w, o.h, CROSSHAIR_BORDER)
	}
	for b in bars {
		rl.DrawRectangle(b.x, b.y, b.w, b.h, CROSSHAIR_COLOR)
	}
}
