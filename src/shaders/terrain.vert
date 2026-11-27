#version 150

uniform mat4 p3d_ModelViewProjectionMatrix;
uniform mat4 p3d_ModelViewMatrix;
uniform mat4 p3d_ModelMatrix;
uniform mat3 p3d_NormalMatrix;

uniform struct {
    vec4 position;
    vec3 color;
    sampler2DShadow shadowMap;
    mat4 shadowViewMatrix;
} p3d_LightSource[1];

in vec4 p3d_Vertex;
in vec3 p3d_Normal;
in vec4 p3d_Color;   // biome weights: r desert, g dry grassland, b snowy; a woods

out vec4 biome;
out vec3 world_pos;
out vec3 world_normal;
out vec3 view_pos;
out vec3 view_normal;
out vec4 shadow_coord;

void main() {
    vec4 vp = p3d_ModelViewMatrix * p3d_Vertex;
    gl_Position = p3d_ModelViewProjectionMatrix * p3d_Vertex;
    view_pos = vp.xyz;
    world_pos = (p3d_ModelMatrix * p3d_Vertex).xyz;
    // Chunks are only ever translated, so model-space normals are world-space.
    world_normal = p3d_Normal;
    view_normal = normalize(p3d_NormalMatrix * p3d_Normal);
    shadow_coord = p3d_LightSource[0].shadowViewMatrix * vp;
    biome = p3d_Color;
}
