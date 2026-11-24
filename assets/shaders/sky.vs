#version 330

// Sky pass: one triangle covering the screen (no vertex buffer: corners
// from gl_VertexID), drawn before the chunks with depth testing off.

out vec2 ndc; // normalized device coords, -1..1 on screen

void main() {
    vec2 p = vec2((gl_VertexID << 1) & 2, gl_VertexID & 2); // (0,0) (2,0) (0,2)
    ndc = p * 2.0 - 1.0;
    gl_Position = vec4(ndc, 0.0, 1.0);
}
