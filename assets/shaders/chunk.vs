#version 330

// Chunk vertex shader. One packed vertex attribute (mesh.Vertex: 4 x u16,
// read as floats, which are exact); unpacked here exactly like
// mesh.unpack_vertex (keep the two in sync):
//   x: pos.x (9 bits) | u (5) << 9
//   y: pos.y (9)      | v (5) << 9 | ao (2) << 14
//   z: pos.z (9)      | face (3) << 9 | block light bits 0..3 << 12
//   w: tile (8)       | sky light (6) << 8 | block light bits 4..5 << 14
// Light is in 1/4 levels (0..60 = level 0..15).
// Positions are chunk-local in 1/16 block, UVs in 1/16 tile. `vertexPosition`
// is raylib's default attribute name (bound to location 0).

in vec4 vertexPosition;

uniform mat4 mvp;          // projection × view (positions are world space)
uniform vec3 chunkOrigin;  // world position of the chunk's (0, 0, 0) corner
// Brightness per face direction and AO value, index face * 4 + ao
// (mesh.shade_table).
uniform float shadeTable[24];

// `centroid`: with MSAA, evaluate at a sample point inside the triangle
// instead of the pixel center (which can lie outside it at edges), so the
// in-tile position stays within 0..1 at face edges.
centroid out vec2 fragTexCoord; // position within the tile, 0..1
flat out vec2 fragTile;         // atlas tile (column, row)
out vec4 fragColor;
out vec3 fragWorldPos;
out float fragSkyLight;         // smooth sky light level, 0..15 (interpolated)
out float fragBlockLight;       // smooth block light level, 0..15

void main() {
    uvec4 w = uvec4(vertexPosition);
    vec3 local = vec3(w.x & 511u, w.y & 511u, w.z & 511u) / 16.0;
    fragTexCoord = vec2((w.x >> 9) & 31u, (w.y >> 9) & 31u) / 16.0;
    uint ao = (w.y >> 14) & 3u;
    uint face = (w.z >> 9) & 7u;
    uint tile = w.w & 255u;
    fragTile = vec2(tile & 15u, tile >> 4);
    float shade = shadeTable[int(face * 4u + ao)];
    fragColor = vec4(shade, shade, shade, 1.0);
    fragSkyLight = float((w.w >> 8) & 63u) / 4.0;
    fragBlockLight = float(((w.z >> 12) & 15u) | (((w.w >> 14) & 3u) << 4)) / 4.0;
    vec3 world = chunkOrigin + local;
    fragWorldPos = world;
    gl_Position = mvp * vec4(world, 1.0);
}
