package tests

import "core:testing"
import "melange:geom"

// Camera at the origin looking down -Z, 90° vertical FOV, square aspect.
// At distance d, the view spans [-d, d] in both x and y.
test_frustum :: proc() -> geom.Frustum {
	return geom.frustum_from_perspective(
		{position = {0, 0, 0}, target = {0, 0, -1}, up = {0, 1, 0}, fovy_deg = 90, aspect = 1, near = 0.1, far = 100},
	)
}

unit_box_at :: proc(f: ^geom.Frustum, center: [3]f32) -> bool {
	return geom.frustum_intersects_aabb(f, center - 0.5, center + 0.5)
}

@(test)
frustum_keeps_boxes_in_view :: proc(t: ^testing.T) {
	f := test_frustum()
	testing.expect(t, unit_box_at(&f, {0, 0, -10}), "straight ahead")
	testing.expect(t, unit_box_at(&f, {8, 0, -10}), "right but inside")
	testing.expect(t, unit_box_at(&f, {0, -8, -10}), "below but inside")
	testing.expect(t, unit_box_at(&f, {0, 0, -99}), "just before far plane")
	// Box containing the camera itself.
	testing.expect(t, geom.frustum_intersects_aabb(&f, {-1, -1, -1}, {1, 1, 1}), "around the camera")
	// Partially inside: straddles the right edge (x = 10 at z = -10).
	testing.expect(t, unit_box_at(&f, {10.3, 0, -10}), "straddling the right edge")
}

@(test)
frustum_culls_boxes_out_of_view :: proc(t: ^testing.T) {
	f := test_frustum()
	testing.expect(t, !unit_box_at(&f, {0, 0, 10}), "behind")
	testing.expect(t, !unit_box_at(&f, {12, 0, -10}), "beyond right edge")
	testing.expect(t, !unit_box_at(&f, {-12, 0, -10}), "beyond left edge")
	testing.expect(t, !unit_box_at(&f, {0, 12, -10}), "above top edge")
	testing.expect(t, !unit_box_at(&f, {0, -12, -10}), "below bottom edge")
	testing.expect(t, !unit_box_at(&f, {0, 0, -101}), "beyond far plane")
}

// Aspect ratio widens the view horizontally only.
@(test)
frustum_respects_aspect :: proc(t: ^testing.T) {
	f := geom.frustum_from_perspective(
		{position = {0, 0, 0}, target = {0, 0, -1}, up = {0, 1, 0}, fovy_deg = 90, aspect = 2, near = 0.1, far = 100},
	)
	testing.expect(t, unit_box_at(&f, {18, 0, -10}), "inside the wider horizontal span")
	testing.expect(t, !unit_box_at(&f, {0, 12, -10}), "vertical span unchanged")
}

// A camera that isn't axis-aligned, to catch sign/orientation mistakes.
@(test)
frustum_follows_camera_orientation :: proc(t: ^testing.T) {
	f := geom.frustum_from_perspective(
		{position = {10, 5, 10}, target = {20, 5, 20}, up = {0, 1, 0}, fovy_deg = 60, aspect = 16.0 / 9.0, near = 0.1, far = 1000},
	)
	testing.expect(t, unit_box_at(&f, {30, 5, 30}), "along the view direction")
	testing.expect(t, !unit_box_at(&f, {0, 5, 0}), "directly behind")
	testing.expect(t, !unit_box_at(&f, {40, 5, -20}), "far off to the side")
}
