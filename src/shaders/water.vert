#version 150

uniform mat4 p3d_ModelViewProjectionMatrix;
uniform mat4 p3d_ModelViewMatrix;
uniform mat4 p3d_ModelMatrix;
uniform float osg_FrameTime;

uniform struct {
    vec4 position;
    vec3 color;
    sampler2DShadow shadowMap;
    mat4 shadowViewMatrix;
} p3d_LightSource[1];

in vec4 p3d_Vertex;
// Red carries the water depth under this vertex, divided by 10; green the
// height of ground above the water, likewise; blue the ground's slope / 2.
in vec4 p3d_Color;

out vec3 world_pos;
out vec3 view_pos;
out float depth;
out float ground_slope;
out vec4 shadow_coord;

void main() {
    vec3 wp = (p3d_ModelMatrix * p3d_Vertex).xyz;
    // Slow swells raise and lower the surface a few centimetres, so the
    // water laps up the beach and draws back.
    float t = osg_FrameTime;
    float lap = 0.06 * sin(t * 0.55 + dot(wp.xz, vec2(0.11, 0.07)))
              + 0.03 * sin(t * 1.3 + dot(wp.xz, vec2(-0.05, 0.13)));
    vec4 v = p3d_Vertex + vec4(0.0, lap, 0.0, 0.0);
    vec4 vp = p3d_ModelViewMatrix * v;
    gl_Position = p3d_ModelViewProjectionMatrix * v;
    view_pos = vp.xyz;
    world_pos = wp + vec3(0.0, lap, 0.0);
    // Negative over dry ground, so it crosses zero right at the shoreline.
    depth = (p3d_Color.r - p3d_Color.g) * 10.0 + lap;
    ground_slope = p3d_Color.b * 2.0;
    shadow_coord = p3d_LightSource[0].shadowViewMatrix * vp;
}
