#version 150

uniform mat4 p3d_ViewMatrix;

uniform struct {
    vec4 position;
    vec3 color;
    sampler2DShadow shadowMap;
    mat4 shadowViewMatrix;
} p3d_LightSource[1];

uniform sampler2D clump_tex;
uniform vec4 fog_color;
uniform vec3 ambient_color;
uniform float fog_end;
uniform float shadow_bias;
uniform vec3 to_light;   // world direction toward the shadow light (sun or moon)

#include "clouds.glsl"

in vec2 uv;
in vec3 tint;
in vec3 view_pos;
in vec3 world_pos;
in vec4 shadow_coord;

out vec4 frag_color;

float sun_shadow() {
    vec2 texel = 1.0 / vec2(textureSize(p3d_LightSource[0].shadowMap, 0));
    float lit = 0.0;
    for (int x = -1; x <= 1; ++x) {
        for (int y = -1; y <= 1; ++y) {
            vec4 c = shadow_coord;
            c.xy += vec2(x, y) * texel * 1.5 * c.w;
            c.z -= shadow_bias * c.w;
            lit += textureProj(p3d_LightSource[0].shadowMap, c);
        }
    }
    return lit / 9.0;
}

void main() {
    vec4 texel = texture(clump_tex, uv);
    if (texel.a < 0.5) discard;

    // Blades are thin and lit from all sides, so light them like the ground
    // they grow from (normal up), with some light wrapping around.
    vec3 up = normalize(mat3(p3d_ViewMatrix) * vec3(0.0, 1.0, 0.0));
    vec3 L = normalize(p3d_LightSource[0].position.xyz);
    float ndl = clamp(dot(up, L) * 0.7 + 0.3, 0.0, 1.0);
    vec3 sky_ambient = vec3(0.34, 0.39, 0.46) * ambient_color;
    // Darker toward the base, where blades shade each other.
    float occlusion = mix(0.7, 1.05, uv.y);
    vec3 light = (sky_ambient + p3d_LightSource[0].color * ndl * sun_shadow()
                  * cloud_shadow(world_pos, to_light)) * occlusion;
    vec3 color = texel.rgb * tint * light;

    float fog = smoothstep(fog_end * 0.3, fog_end, length(view_pos));
    frag_color = vec4(mix(color, fog_color.rgb, fog), 1.0);
}
