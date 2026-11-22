#version 330

// Chunk vertex shader. Attribute and uniform names are raylib's defaults, so
// LoadShader binds them automatically and DrawMesh fills mvp/matModel.

in vec3 vertexPosition;
in vec2 vertexTexCoord;  // position within the face's tile, 0..1
in vec2 vertexTexCoord2; // atlas tile (column, row)
in vec4 vertexColor;

uniform mat4 mvp;
uniform mat4 matModel;

// `centroid`: with MSAA, evaluate at a sample point inside the triangle
// instead of the pixel center (which can lie outside it at edges), so the
// in-tile position stays within 0..1 at face edges.
centroid out vec2 fragTexCoord;
flat out vec2 fragTile;
out vec4 fragColor;
out vec3 fragWorldPos;

void main() {
    fragTexCoord = vertexTexCoord;
    fragTile = vertexTexCoord2;
    fragColor = vertexColor;
    fragWorldPos = (matModel * vec4(vertexPosition, 1.0)).xyz;
    gl_Position = mvp * vec4(vertexPosition, 1.0);
}
