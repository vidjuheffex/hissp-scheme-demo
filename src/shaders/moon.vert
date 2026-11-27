#version 150

uniform mat4 p3d_ModelViewProjectionMatrix;
uniform mat4 p3d_ModelMatrix;

in vec4 p3d_Vertex;

// The model is a unit sphere around its origin, so positions are normals.
// The entity is turned to face the player with its +z side.
out vec3 face_normal;
out vec3 world_normal;

void main() {
    gl_Position = p3d_ModelViewProjectionMatrix * p3d_Vertex;
    face_normal = p3d_Vertex.xyz;
    world_normal = mat3(p3d_ModelMatrix) * p3d_Vertex.xyz;
}
