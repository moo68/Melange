#version 330

// Chunk fragment shader: atlas texture x vertex shade, then distance fog.
// The renderer also compiles it with `#define CUTOUT` (cutout pass) and
// `#define TRANSLUCENT` (translucent pass).

centroid in vec2 fragTexCoord; // position within the tile, 0..1
flat in vec2 fragTile;         // atlas tile (column, row)
in vec4 fragColor;
in vec3 fragWorldPos;

uniform sampler2D texture0; // atlas (raylib binds the material's albedo map here)

const int TILE_PX = 16; // pixels per tile side

uniform vec3 cameraPos;
uniform vec3 fogColor;  // = sky/clear color, so terrain fades into the sky
uniform float fogStart; // horizontal distance where fog begins
uniform float fogEnd;   // horizontal distance where it's fully opaque

out vec4 finalColor;

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
    vec3 color = albedo * fragColor.rgb;

    // Horizontal distance, matching the streaming shape (a circle around the
    // camera), so the fog wall lines up with where chunks stop.
    float dist = length(fragWorldPos.xz - cameraPos.xz);
    float fog = smoothstep(fogStart, fogEnd, dist);

#ifdef TRANSLUCENT
    // Blended over what's behind (water): keep the texel's alpha.
    finalColor = vec4(mix(color, fogColor, fog), texel_color.a);
#else
    // Alpha is always 1 (cutout texels that survive the test are opaque).
    finalColor = vec4(mix(color, fogColor, fog), 1.0);
#endif
}
