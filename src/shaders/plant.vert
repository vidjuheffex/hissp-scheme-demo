#version 150

uniform mat4 p3d_ModelViewProjectionMatrix;
uniform mat4 p3d_ModelViewMatrix;
uniform mat4 p3d_ModelMatrix;
uniform mat4 p3d_ViewMatrix;
uniform mat3 p3d_NormalMatrix;
uniform float osg_FrameTime;
uniform float wind_speed;  // about 1 a breeze, 0 dead calm

uniform struct {
    vec4 position;
    vec3 color;
    sampler2DShadow shadowMap;
    mat4 shadowViewMatrix;
} p3d_LightSource[1];

in vec4 p3d_Vertex;
in vec3 p3d_Normal;
in vec4 p3d_Color;
in vec2 p3d_MultiTexCoord0;   // material + across, height above base

out vec3 albedo;
out vec2 plant;
out vec3 world_pos;
out vec3 rest_pos;    // world position before swaying, for surface detail
out vec3 world_normal;
out vec3 view_pos;
out vec3 view_normal;
out vec4 shadow_coord;

// Matches MAT-BARK and MAT-FOLIAGE in src/world_plants.sld.
const int BARK = 6;
const int FOLIAGE = 8;

void main() {
    vec4 v = p3d_Vertex;
    int material = int(floor(p3d_MultiTexCoord0.x));
    if (material >= BARK && material <= FOLIAGE) {
        // Trees sway in the wind, more the higher up, so the trunk's foot
        // stays put. Each tree has its own phase, from where it stands.
        vec3 wp = (p3d_ModelMatrix * p3d_Vertex).xyz;
        float h = p3d_MultiTexCoord0.y;
        float phase = dot(floor(wp.xz / 6.4), vec2(1.7, 2.3));
        float t = osg_FrameTime;
        float sway = (sin(t * 0.9 + phase) + 0.4 * sin(t * 2.1 + phase * 1.3)) * 0.0012 * h * h;
        float wind = min(wind_speed, 1.8);
        v.xz += vec2(0.8, 0.6) * sway * wind;
        // Leaves flutter.
        if (material == FOLIAGE)
            v.xyz += 0.025 * wind * sin(t * 4.0 + dot(wp, vec3(2.1, 1.7, 2.9))) * p3d_Normal;
    }
    vec4 vp = p3d_ModelViewMatrix * v;
    gl_Position = p3d_ModelViewProjectionMatrix * v;
    view_pos = vp.xyz;
    // Chunks are only ever translated, so model-space normals are world-space.
    world_normal = p3d_Normal;
    view_normal = normalize(p3d_NormalMatrix * p3d_Normal);
    shadow_coord = p3d_LightSource[0].shadowViewMatrix * vp;
    albedo = p3d_Color.rgb;
    plant = p3d_MultiTexCoord0;
    world_pos = (p3d_ModelMatrix * v).xyz;
    rest_pos = (p3d_ModelMatrix * p3d_Vertex).xyz;
}
