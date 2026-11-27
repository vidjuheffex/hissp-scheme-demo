#version 150

uniform mat4 p3d_ModelViewProjectionMatrix;
uniform mat4 p3d_ModelViewMatrix;
uniform mat4 p3d_ModelMatrix;
uniform mat4 p3d_ProjectionMatrix;
uniform float osg_FrameTime;
uniform float wind_speed;  // about 1 a breeze, 0 dead calm

uniform struct {
    vec4 position;
    vec3 color;
    sampler2DShadow shadowMap;
    mat4 shadowViewMatrix;
} p3d_LightSource[1];

uniform vec2 grass_fade;   // distance where clumps start sinking, and are gone
uniform vec4 bloom;        // how far into bloom: daisies, spikes, poppies, desert flowers

in vec4 p3d_Vertex;
in vec3 p3d_Normal;        // y: height above the ground (0 at a clump's base);
                           // x: a wildflower's hue, z: its bloom threshold (-1 grass)
in vec2 p3d_MultiTexCoord0;
in vec4 p3d_Color;         // per-clump tint

out vec2 uv;
out vec3 tint;
out vec3 view_pos;
out vec3 world_pos;
out vec4 shadow_coord;
out float flower;          // -1 grass, else which wildflower (0 to 3)
out float hue;

void main() {
    float lift = p3d_Normal.y;
    vec4 v = p3d_Vertex;

    // Sink into the ground near the edge of the grass range instead of popping.
    float dist = length((p3d_ModelViewMatrix * v).xyz);
    float grow = 1.0 - smoothstep(grass_fade.x, grass_fade.y, dist);
    // Wildflowers out of bloom sink away too, each at its own threshold.
    int sprite = int(p3d_MultiTexCoord0.x * 8.0);
    flower = sprite >= 4 ? float(sprite - 4) : -1.0;
    hue = p3d_Normal.x;
    if (flower >= 0.0) {
        float opens = p3d_Normal.z;
        grow *= smoothstep(opens - 0.08, opens + 0.08, bloom[sprite - 4]);
    }
    v.y -= lift * (1.0 - grow);

    // Wind: slow sway plus a faster flutter, varying across the field.
    vec3 wp = (p3d_ModelMatrix * p3d_Vertex).xyz;
    float t = osg_FrameTime;
    float gust = sin(t * 1.3 + wp.x * 0.11 + wp.z * 0.07) * 0.7
               + sin(t * 3.1 + wp.x * 0.43 - wp.z * 0.31) * 0.3;
    v.xz += vec2(0.8, 0.5) * gust * 0.18 * min(wind_speed, 1.8) * lift * grow;

    vec4 vp = p3d_ModelViewMatrix * v;
    gl_Position = p3d_ProjectionMatrix * vp;
    view_pos = vp.xyz;
    world_pos = (p3d_ModelMatrix * v).xyz;
    shadow_coord = p3d_LightSource[0].shadowViewMatrix * vp;
    uv = p3d_MultiTexCoord0;
    tint = p3d_Color.rgb;
}
