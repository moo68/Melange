package tests

import "core:testing"
import "melange:geom"

@(test)
crosshair_is_centered_and_symmetric :: proc(t: ^testing.T) {
	bars := geom.crosshair_rects(1280, 720, 10, 2)
	h, v := bars[0], bars[1]
	testing.expect_value(t, h, geom.Pixel_Rect{630, 359, 20, 2})
	testing.expect_value(t, v, geom.Pixel_Rect{639, 350, 2, 20})
	// Equal margins to the screen center on every side.
	testing.expect_value(t, 640 - h.x, h.x + h.w - 640)
	testing.expect_value(t, 360 - v.y, v.y + v.h - 360)
	testing.expect_value(t, 640 - v.x, v.x + v.w - 640)
	testing.expect_value(t, 360 - h.y, h.y + h.h - 360)
}

@(test)
crosshair_follows_screen_size :: proc(t: ^testing.T) {
	// After a resize the center moves; the shape doesn't.
	bars := geom.crosshair_rects(1920, 1080, 10, 2)
	testing.expect_value(t, bars[0], geom.Pixel_Rect{950, 539, 20, 2})
	testing.expect_value(t, bars[1], geom.Pixel_Rect{959, 530, 2, 20})
}

@(test)
pixel_rect_grow_adds_a_border :: proc(t: ^testing.T) {
	testing.expect_value(t, geom.pixel_rect_grow({630, 359, 20, 2}, 1), geom.Pixel_Rect{629, 358, 22, 4})
}
