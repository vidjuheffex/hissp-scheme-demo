#version 150

uniform mat4 p3d_ModelViewProjectionMatrix;

in vec4 p3d_Vertex;

// The dome is a sphere centered on the camera and never rotated, so a
// vertex's position is the direction it's seen in.
out vec3 dir;

void main() {
    gl_Position = p3d_ModelViewProjectionMatrix * p3d_Vertex;
    dir = p3d_Vertex.xyz;
}
