#version 330

// Chunk fragment shader: atlas texture x vertex shade x light, then distance fog.
// The renderer also compiles it with `#define CUTOUT` (cutout pass) and
// `#define TRANSLUCENT` (translucent pass).

centroid in vec2 fragTexCoord; // position within the tile, 0..1
flat in vec2 fragTile;         // atlas tile (column, row)
in vec4 fragColor;
in vec3 fragWorldPos;
in float fragSkyLight; // 0..15, interpolated between the face's corners
in float fragBlockLight; // 0..15 (torches, roadmap 4; 0 for now)

uniform sampler2D texture0; // atlas (raylib binds the material's albedo map here)

const int TILE_PX = 16; // pixels per tile side

uniform vec3 cameraPos;
uniform vec3 fogColor;  // = clear color (sky, or deep water under water)
uniform float fogStart; // horizontal distance where fog begins
uniform float fogEnd;   // distance where it's fully opaque
uniform vec3 fogTint;   // multiplied into every texel (white above water)
uniform int fogSpherical; // 1: 3D distance (under water), 0: horizontal
// Day/night: multiplies sky light's brightness (1 by day, world.NIGHT_DAYLIGHT
// at night). Block light isn't scaled, so torches stay bright at night.
uniform float daylight;

out vec4 finalColor;

// Light level (0..15, fractional) -> brightness, like Minecraft's lightmap:
// f / (4 - 3f) (each level ~20% dimmer near the top), half-blended toward
// 1 - (1 - b)^4 (Minecraft's gamma 0.5, lifts the darks), never below
// MIN_BRIGHTNESS so unlit places aren't pure black. Applied per fragment, so
// the light level (not the brightness) is interpolated across faces.
const float LIGHT_GAMMA = 0.5;
const float MIN_BRIGHTNESS = 0.05;
float light_brightness(float level) {
    float f = clamp(level / 15.0, 0.0, 1.0);
    float b = f / (4.0 - 3.0 * f);
    float inv = 1.0 - b;
    b = mix(b, 1.0 - inv * inv * inv * inv, LIGHT_GAMMA);
    return mix(MIN_BRIGHTNESS, 1.0, b);
}

void main() {
    // Exact texel inside this face's tile: never reads a neighboring tile,
    // so every face shows exactly its 16x16 texture, edge to edge.
    ivec2 local = clamp(ivec2(floor(fragTexCoord * float(TILE_PX))), ivec2(0), ivec2(TILE_PX - 1));
    ivec2 texel = ivec2(fragTile) * TILE_PX + local;
    vec4 texel_color = texelFetch(texture0, texel, 0);
#ifdef CUTOUT
    // Cutout pass (glass, leaves): texels are either opaque or clear. Only
    // this variant discards, so the opaque pass keeps early depth testing.
    if (texel_color.a < 0.5) discard;
#endif
    vec3 albedo = texel_color.rgb;
    float light = max(light_brightness(fragSkyLight) * daylight, light_brightness(fragBlockLight));
    vec3 color = albedo * fragColor.rgb * light * fogTint;

    // Above water: horizontal distance, matching the streaming shape (a
    // circle around the camera), so the fog wall lines up with where chunks
    // stop. Under water: 3D, so the seabed below fogs too.
    float dist = fogSpherical != 0 ? length(fragWorldPos - cameraPos) : length(fragWorldPos.xz - cameraPos.xz);
    float fog = smoothstep(fogStart, fogEnd, dist);

#ifdef TRANSLUCENT
    // Blended over what's behind (water): keep the texel's alpha.
    finalColor = vec4(mix(color, fogColor, fog), texel_color.a);
#else
    // Alpha is always 1 (cutout texels that survive the test are opaque).
    finalColor = vec4(mix(color, fogColor, fog), 1.0);
#endif
}
