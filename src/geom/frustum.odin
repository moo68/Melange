package geom

import "core:math"
import "core:math/linalg"

// Plane: points p with dot(normal, p) + d >= 0 are on the inside.
Plane :: struct {
	normal: [3]f32,
	d:      f32,
}

Frustum_Side :: enum u8 {
	Near,
	Far,
	Left,
	Right,
	Bottom,
	Top,
}

Frustum :: struct {
	planes: [Frustum_Side]Plane,
}

Perspective :: struct {
	position: [3]f32,
	target:   [3]f32,
	up:       [3]f32,
	fovy_deg: f32, // vertical field of view, degrees
	aspect:   f32, // width / height
	near:     f32,
	far:      f32,
}

// Builds the six planes directly from the camera's geometry (no matrices, so
// no row/column-major conventions to get wrong). Normals point inward.
frustum_from_perspective :: proc(p: Perspective) -> (f: Frustum) {
	forward := linalg.normalize(p.target - p.position)
	right := linalg.normalize(linalg.cross(forward, p.up))
	up := linalg.cross(right, forward)

	ty := math.tan(math.to_radians(p.fovy_deg) * 0.5) // half-height at distance 1
	tx := ty * p.aspect // half-width at distance 1

	f.planes[.Near] = plane_through(forward, p.position + forward * p.near)
	f.planes[.Far] = plane_through(-forward, p.position + forward * p.far)
	// Each side plane contains the eye and one edge of the view rectangle.
	// E.g. the right edge direction is forward + right*tx; its inward normal
	// is forward*tx - right (perpendicular to that edge and to `up`).
	f.planes[.Right] = plane_through(linalg.normalize(forward * tx - right), p.position)
	f.planes[.Left] = plane_through(linalg.normalize(forward * tx + right), p.position)
	f.planes[.Top] = plane_through(linalg.normalize(forward * ty - up), p.position)
	f.planes[.Bottom] = plane_through(linalg.normalize(forward * ty + up), p.position)
	return
}

plane_through :: #force_inline proc "contextless" (normal, point: [3]f32) -> Plane {
	return {normal, -linalg.dot(normal, point)}
}

// Conservative AABB test: false only if the box is fully outside some plane.
// (Boxes near frustum corners may be kept even if just outside; that's fine
// for culling.)
frustum_intersects_aabb :: proc "contextless" (f: ^Frustum, box_min, box_max: [3]f32) -> bool {
	for plane in f.planes {
		// The box corner furthest along the plane normal ("positive vertex").
		pv := [3]f32 {
			box_max.x if plane.normal.x >= 0 else box_min.x,
			box_max.y if plane.normal.y >= 0 else box_min.y,
			box_max.z if plane.normal.z >= 0 else box_min.z,
		}
		if linalg.dot(plane.normal, pv) + plane.d < 0 {
			return false
		}
	}
	return true
}
