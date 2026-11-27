#version 150

uniform mat4 p3d_ModelViewProjectionMatrix;
uniform mat4 p3d_ModelViewMatrix;
uniform mat4 p3d_ModelMatrix;

uniform struct {
    vec4 position;
    vec3 color;
    sampler2DShadow shadowMap;
    mat4 shadowViewMatrix;
} p3d_LightSource[1];

in vec4 p3d_Vertex;
// Red channel carries the water depth under this vertex, divided by 10.
in vec4 p3d_Color;

out vec3 world_pos;
out vec3 view_pos;
out float depth;
out vec4 shadow_coord;

void main() {
    vec4 vp = p3d_ModelViewMatrix * p3d_Vertex;
    gl_Position = p3d_ModelViewProjectionMatrix * p3d_Vertex;
    view_pos = vp.xyz;
    world_pos = (p3d_ModelMatrix * p3d_Vertex).xyz;
    depth = p3d_Color.r * 10.0;
    shadow_coord = p3d_LightSource[0].shadowViewMatrix * vp;
}
