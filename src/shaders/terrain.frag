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
uniform vec3 ambient_color;   // scales the sky light: dark blue at night, white by day
uniform float fog_end;
uniform float sea_level;
uniform float shadow_bias;
uniform float wetness;      // 0 dry to 1 soaked by rain
uniform float snow_cover;   // 0 none to 1 a fresh fall of snow
uniform vec3 to_light;   // world direction toward the shadow light (sun or moon)

#include "clouds.glsl"
#include "mist.glsl"

uniform mat4 p3d_ViewMatrixInverse;

in vec4 biome;   // r desert, g dry grassland, b snowy (grassland is the rest); a woods
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

// Pushes a blend weight toward 0 or 1 by `patch`, most strongly at 0.5.
float patchy(float w, float patch) {
    return smoothstep(0.3, 0.7, w + patch * 4.0 * w * (1.0 - w));
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
    // Darker than white so sunlit snow doesn't clip and keeps its texture.
    vec3 snow = vec3(0.76, 0.80, 0.87) * (0.85 + 0.25 * grain);

    // Ground cover by biome. Snow and sand come in patches across a border
    // instead of a flat mix; `patchy` leaves weights of 0 and 1 alone.
    float patch = (macro - 0.4) * 0.6 + (grain - 0.5) * 0.4;
    float w_desert = patchy(biome.r, patch);
    float w_dry = biome.g;
    float w_snowy = patchy(biome.b, patch);
    float w_grass = max(1.0 - biome.r - biome.g - biome.b, 0.0);
    float w_total = w_desert + w_dry + w_snowy + w_grass;
    if (w_total < 0.001) {
        w_desert = biome.r;
        w_snowy = biome.b;
        w_total = w_desert + w_dry + w_snowy + w_grass;
    }
    w_desert /= w_total;
    w_dry /= w_total;
    w_snowy /= w_total;
    w_grass /= w_total;
    vec3 dry_grass = vec3(0.80, 0.68, 0.38) * (luma(grass) * 2.1 + 0.08);
    // Wind ripples across the sand, broken up by the rock grain.
    float ripple = sin(dot(world_pos.xz, vec2(0.8, 0.6)) * 2.6 + grain * 4.0);
    vec3 desert_sand = vec3(0.90, 0.74, 0.50) * (0.80 + 0.35 * grain + 0.05 * ripple);
    // In the woods, grassland gives way to fallen leaves with mossy patches.
    float litter = luma(two_scale(rock_tex, world_pos.xz * 1.7 + 13.0, 3.0));
    vec3 leaves = mix(vec3(0.30, 0.27, 0.18), vec3(0.42, 0.32, 0.19), litter) * (0.65 + 0.6 * litter);
    vec3 moss = grass * vec3(0.7, 0.8, 0.55);
    vec3 forest_floor = mix(leaves, moss, smoothstep(0.3, 0.75, macro * 0.5 + grain * 0.6));
    vec3 grassland = mix(grass, forest_floor,
                         0.85 * smoothstep(0.25, 0.7, biome.a + patch * 0.5));
    vec3 ground = grassland * w_grass + dry_grass * w_dry + desert_sand * w_desert + snow * w_snowy;
    // Desert rock is warmer, like sandstone.
    rock *= mix(vec3(1.0), vec3(1.18, 0.98, 0.78), w_desert);
    // Cliffs and canyon walls show their layers: bands by height, wandering
    // a little, grey-brown in most places and red and buff in dry country.
    float layer = h + luma(texture(grass_tex, world_pos.xz / 60.0).rgb) * 3.0 + grain * 0.4;
    float band = sin(layer * 1.9) * 0.5 + sin(layer * 0.73 + 1.3) * 0.35 + sin(layer * 4.1) * 0.15;
    vec3 strata = mix(vec3(0.82, 0.79, 0.76), vec3(1.1, 1.06, 1.0), band * 0.5 + 0.5);
    vec3 red_strata = mix(vec3(0.98, 0.62, 0.44), vec3(1.18, 0.98, 0.74), smoothstep(-0.3, 0.3, band));
    strata = mix(strata, red_strata, max(w_desert, w_dry * 0.6));

    float jitter = macro * 2.5;
    vec3 albedo = ground;
    // Bare rock band on high ground, except where snow covers it.
    albedo = mix(albedo, rock, smoothstep(26.0, 34.0, h + jitter * 2.0) * (1.0 - w_snowy));
    albedo = mix(albedo, rock * strata, smoothstep(0.28, 0.45, slope));
    albedo = mix(albedo, sand, 1.0 - smoothstep(sea_level + 0.4, sea_level + 1.8 + jitter * 0.3, h));
    albedo = mix(albedo, seabed, 1.0 - smoothstep(sea_level - 1.5, sea_level, h));
    // Wet ground is darker, except under snow: after rain, and always in a
    // band where the water laps the shore.
    float lapped = 1.0 - smoothstep(sea_level + 0.05, sea_level + 0.5 + jitter * 0.2, h);
    albedo *= 1.0 - 0.35 * max(wetness * (1.0 - w_snowy), lapped);
    // Fresh snow brings the snow line down the mountains and fills in the
    // bare patches of the snowy biome, on ground flat enough to hold it.
    float flat_ground = 1.0 - smoothstep(0.35, 0.6, slope);
    float snow_line = 37.0 - 15.0 * snow_cover;
    albedo = mix(albedo, snow,
                 max(smoothstep(snow_line, snow_line + 3.0, h + jitter * 3.0),
                     snow_cover * biome.b * smoothstep(sea_level, sea_level + 1.0, h))
                 * flat_ground);

    vec3 L = normalize(p3d_LightSource[0].position.xyz);
    float ndl = max(dot(normalize(view_normal), L), 0.0);
    vec3 sky_ambient = mix(vec3(0.20, 0.19, 0.17), vec3(0.36, 0.42, 0.52), n.y * 0.5 + 0.5)
                     * ambient_color;
    vec3 light = sky_ambient
                 + p3d_LightSource[0].color * ndl * sun_shadow() * cloud_shadow(world_pos, to_light);
    vec3 color = albedo * light;

    float fog = smoothstep(fog_end * 0.3, fog_end, length(view_pos));
    color = mix(color, fog_color.rgb, fog);
    color = mix(color, mist_color(fog_color.rgb), mist_between(p3d_ViewMatrixInverse[3].xyz, world_pos));
    frag_color = vec4(color, 1.0);
}
