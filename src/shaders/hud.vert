#version 150

// Text in the corner readouts; see hud.frag.

uniform mat4 p3d_ModelViewProjectionMatrix;

in vec4 p3d_Vertex;
in vec2 p3d_MultiTexCoord0;
in vec4 p3d_Color;

out vec2 uv;
out vec4 tint;

void main() {
    gl_Position = p3d_ModelViewProjectionMatrix * p3d_Vertex;
    uv = p3d_MultiTexCoord0;
    tint = p3d_Color;
}
