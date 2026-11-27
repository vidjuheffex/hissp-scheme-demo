#version 150

uniform struct {
    vec4 position;
    vec3 color;
    sampler2DShadow shadowMap;
    mat4 shadowViewMatrix;
} p3d_LightSource[1];

uniform sampler2D grass_tex;
uniform sampler2D rock_tex;
uniform vec4 fog_color;
uniform float fog_end;
uniform float sea_level;
uniform float shadow_bias;

in vec3 world_pos;
in vec3 world_normal;
in vec3 view_pos;
in vec3 view_normal;
in vec4 shadow_coord;

out vec4 frag_color;

float luma(vec3 c) { return dot(c, vec3(0.299, 0.587, 0.114)); }

// Sample at two unrelated scales/rotations so the tiling doesn't show.
vec3 two_scale(sampler2D tex, vec2 p, float scale) {
    vec2 q = mat2(0.8, -0.6, 0.6, 0.8) * p;
    vec3 a = texture(tex, p / scale).rgb;
    vec3 b = texture(tex, q / (scale * 3.7)).rgb;
    return mix(a, b, 0.45);
}

// Project the rock texture from all three axes so cliffs don't smear.
vec3 triplanar(sampler2D tex, vec3 p, vec3 n, float scale) {
    vec3 w = pow(abs(n), vec3(4.0));
    w /= (w.x + w.y + w.z);
    return two_scale(tex, p.zy, scale) * w.x
         + two_scale(tex, p.xz, scale) * w.y
         + two_scale(tex, p.xy, scale) * w.z;
}

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
    vec3 n = normalize(world_normal);
    float h = world_pos.y;
    float slope = 1.0 - n.y;

    // Large, slow brightness variation that breaks up repetition and band edges.
    float macro = luma(texture(grass_tex, world_pos.xz / 211.0).rgb) * 2.0 - 0.6;

    vec3 grass = two_scale(grass_tex, world_pos.xz, 5.0);
    grass *= 0.85 + 0.3 * macro;
    vec3 rock = triplanar(rock_tex, world_pos, n, 9.0);
    float grain = luma(two_scale(rock_tex, world_pos.xz, 4.0));
    vec3 sand = vec3(0.93, 0.85, 0.64) * (0.75 + 0.5 * grain);
    vec3 seabed = vec3(0.62, 0.58, 0.45) * (0.7 + 0.5 * grain);
    vec3 snow = vec3(0.94, 0.95, 0.98) * (0.9 + 0.15 * grain);

    float jitter = macro * 2.5;
    vec3 albedo = grass;
    albedo = mix(albedo, rock, smoothstep(26.0, 34.0, h + jitter * 2.0));
    albedo = mix(albedo, rock, smoothstep(0.28, 0.45, slope));
    albedo = mix(albedo, sand, 1.0 - smoothstep(sea_level + 0.4, sea_level + 1.8 + jitter * 0.3, h));
    albedo = mix(albedo, seabed, 1.0 - smoothstep(sea_level - 1.5, sea_level, h));
    albedo = mix(albedo, snow,
                 smoothstep(37.0, 40.0, h + jitter * 3.0) * (1.0 - smoothstep(0.35, 0.6, slope)));

    vec3 L = normalize(p3d_LightSource[0].position.xyz);
    float ndl = max(dot(normalize(view_normal), L), 0.0);
    vec3 sky_ambient = mix(vec3(0.20, 0.19, 0.17), vec3(0.36, 0.42, 0.52), n.y * 0.5 + 0.5);
    vec3 light = sky_ambient + p3d_LightSource[0].color * ndl * sun_shadow();
    vec3 color = albedo * light;

    float fog = smoothstep(fog_end * 0.3, fog_end, length(view_pos));
    frag_color = vec4(mix(color, fog_color.rgb, fog), 1.0);
}
