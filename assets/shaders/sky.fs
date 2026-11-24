#version 330

// Sky pass: a gradient from the horizon color (= the fog color, so distant
// terrain blends into it) to the zenith color, plus a square pixel-art sun
// and moon (Minecraft-style) with a soft glow. Below the horizon it's the
// horizon color, like the fog. Colors and directions come from
// world.sky_at / world.sun_direction.

in vec2 ndc;

uniform vec3 camForward;  // camera basis (unit vectors)
uniform vec3 camRight;
uniform vec3 camUp;
uniform float tanHalfFovY;
uniform float aspect;     // width / height
uniform vec3 horizonColor; // 0..1
uniform vec3 zenithColor;
uniform vec3 sunDir;      // unit vector toward the sun (the moon is opposite)
uniform vec3 arcNormal;   // normal of the sun's path plane

out vec4 finalColor;

const float SUN_SIZE = 0.10;  // half-size of the square, in tan(angle) (~5.7°)
const float MOON_SIZE = 0.075;
const float BODY_PIXELS = 8.0; // pixel-art cells across each body
const vec3 SUN_CORE = vec3(1.0, 0.99, 0.90);
const vec3 SUN_RIM = vec3(1.0, 0.88, 0.55);
const vec3 SUN_GLOW = vec3(1.0, 0.85, 0.6);
const vec3 MOON_LIGHT = vec3(0.86, 0.88, 0.92);
const vec3 MOON_DARK = vec3(0.62, 0.65, 0.72);

// Where `dir` hits the square of a body at `body` (unit vector), in cells
// 0..BODY_PIXELS on each axis; outside the square: negative.
vec2 body_cell(vec3 dir, vec3 body, float size) {
    float d = dot(dir, body);
    if (d <= 0.0) return vec2(-1.0);
    vec3 q = dir / d - body; // on the plane tangent to the sky at the body
    vec2 uv = vec2(dot(q, arcNormal), dot(q, cross(body, arcNormal))) / size;
    if (abs(uv.x) >= 1.0 || abs(uv.y) >= 1.0) return vec2(-1.0);
    return floor((uv * 0.5 + 0.5) * BODY_PIXELS);
}

// A fixed per-cell pattern (moon craters).
float hash(vec2 c) {
    return fract(sin(dot(c, vec2(12.9898, 78.233))) * 43758.5453);
}

void main() {
    vec3 dir = normalize(camForward + ndc.x * aspect * tanHalfFovY * camRight + ndc.y * tanHalfFovY * camUp);
    float h = max(dir.y, 0.0);
    // Most of the change happens near the horizon.
    vec3 color = mix(horizonColor, zenithColor, sqrt(h));

    if (dir.y > 0.0) {
        // Glow around the sun, fading out as it sets.
        float sun_up = smoothstep(-0.1, 0.1, sunDir.y);
        float s = max(dot(dir, sunDir), 0.0);
        color += SUN_GLOW * (pow(s, 48.0) * 0.35 + pow(s, 400.0) * 0.4) * sun_up;

        vec2 c = body_cell(dir, sunDir, SUN_SIZE);
        if (c.x >= 0.0) {
            bool rim = c.x < 1.0 || c.y < 1.0 || c.x >= BODY_PIXELS - 1.0 || c.y >= BODY_PIXELS - 1.0;
            color = rim ? SUN_RIM : SUN_CORE;
        }
        c = body_cell(dir, -sunDir, MOON_SIZE);
        if (c.x >= 0.0) {
            color = hash(c) < 0.3 ? MOON_DARK : MOON_LIGHT;
        }
    }
    // Dither by up to half a color step: the dark night gradient spans only
    // a few 8-bit levels and would show rings otherwise.
    color += (hash(gl_FragCoord.xy) - 0.5) / 255.0;
    finalColor = vec4(color, 1.0);
}
