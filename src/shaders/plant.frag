#version 150

uniform struct {
    vec4 position;
    vec3 color;
    sampler2DShadow shadowMap;
    mat4 shadowViewMatrix;
} p3d_LightSource[1];

uniform vec4 fog_color;
uniform vec3 ambient_color;
uniform float fog_end;
uniform float shadow_bias;
uniform vec3 to_light;   // world direction toward the shadow light (sun or moon)

#include "clouds.glsl"

in vec3 albedo;
in vec2 plant;   // x: material (whole part) + across an agave leaf; y: height above base
in vec3 world_pos;
in vec3 world_normal;
in vec3 view_pos;
in vec3 view_normal;
in vec4 shadow_coord;

out vec4 frag_color;

// Matches the MAT-... constants in src/world_plants.sld.
const int PAD = 0;
const int BARREL = 1;
const int CHOLLA = 2;
const int CANE = 3;
const int LEAF = 4;

float sun_shadow() {
    vec2 texel = 1.0 / vec2(textureSize(p3d_LightSource[0].shadowMap, 0));
    float lit = 0.0;
    for (int x = -1; x <= 1; ++x) {
        for (int y = -1; y <= 1; ++y) {
            vec4 c = shadow_coord;
            c.xy += vec2(x, y) * texel * 1.5 * c.w;
            // Plants are thin and close to their own shadow; a larger bias
            // keeps them from shadowing themselves in stripes.
            c.z -= shadow_bias * 2.0 * c.w;
            lit += textureProj(p3d_LightSource[0].shadowMap, c);
        }
    }
    return lit / 9.0;
}

float hash(vec3 c) {
    return fract(sin(dot(c, vec3(127.1, 311.7, 74.7))) * 43758.5453);
}

// Scattered round dots, `per_meter` cells per meter, 0..1 coverage.
float dots(vec3 p, float per_meter, float radius) {
    vec3 q = p * per_meter;
    vec3 cell = floor(q);
    vec3 centre = 0.3 + 0.4 * vec3(hash(cell), hash(cell + 17.0), hash(cell + 31.0));
    return 1.0 - smoothstep(radius * 0.6, radius, length(fract(q) - centre));
}

// Smooth blotches for mottling.
float blotch(vec3 p) {
    vec3 c = floor(p);
    vec3 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    float a = mix(mix(hash(c), hash(c + vec3(1, 0, 0)), f.x),
                  mix(hash(c + vec3(0, 1, 0)), hash(c + vec3(1, 1, 0)), f.x), f.y);
    float b = mix(mix(hash(c + vec3(0, 0, 1)), hash(c + vec3(1, 0, 1)), f.x),
                  mix(hash(c + vec3(0, 1, 1)), hash(c + vec3(1, 1, 1)), f.x), f.y);
    return mix(a, b, f.z);
}

void main() {
    int material = int(floor(plant.x));
    float across = fract(plant.x) / 0.45 - 1.0;
    float height = plant.y;
    float dist = length(view_pos);
    // Small detail fades to its average with distance instead of shimmering.
    float detail = 1.0 - smoothstep(6.0, 20.0, dist);

    vec3 color = albedo;
    float thin = 0.0;    // how much light shows through from behind
    float sheen = 0.0;   // waxy highlight
    if (material == PAD) {
        color *= 0.9 + 0.2 * blotch(world_pos * 5.0);
        // Areoles: brown dots with a pale tuft of glochids.
        float d = mix(0.05, dots(world_pos, 10.0, 0.14), detail);
        float halo = mix(0.08, dots(world_pos, 10.0, 0.26), detail) - d;
        color = mix(color, vec3(0.86, 0.82, 0.62), halo * 0.5);
        color = mix(color, vec3(0.45, 0.36, 0.24), d * 0.8);
        thin = 0.6;
        sheen = 0.15;
    } else if (material == BARREL) {
        // Dense red-brown spines, thickest toward the crown, a few pale.
        vec3 spine = vec3(0.64, 0.38, 0.24);
        color = mix(color, spine, 0.15 + 0.3 * smoothstep(0.2, 0.9, height));
        float red = mix(0.25, dots(world_pos, 20.0, 0.38), detail);
        float pale = mix(0.06, dots(world_pos + 0.37, 12.0, 0.22), detail);
        color = mix(color, spine, red * 0.45);
        color = mix(color, vec3(0.88, 0.82, 0.64), pale * 0.4);
    } else if (material == CHOLLA) {
        // So many pale spines the stems look silvery.
        float spines = mix(0.5, dots(world_pos, 38.0, 0.45), detail);
        color = mix(color, vec3(0.90, 0.87, 0.72), 0.25 + spines * 0.6);
    } else if (material == CANE) {
        float thorns = mix(0.04, dots(world_pos, 11.0, 0.2), detail);
        color = mix(color, vec3(0.25, 0.20, 0.16), thorns);
        thin = 0.3;
    } else if (material == LEAF) {
        // Pale waxy middle, faint lengthwise lines, dark toothed margins.
        float edge = smoothstep(0.7, 1.0, abs(across));
        color *= 1.06 - 0.12 * abs(across) + 0.05 * cos(across * 9.0) * detail;
        float teeth = mix(0.3, step(0.55, fract(height * 14.0)), detail);
        color = mix(color, vec3(0.32, 0.25, 0.18), edge * (0.5 + 0.5 * teeth));
        thin = 0.7;
        sheen = 0.25;
    }

    // Thin parts (leaves, canes) are seen from both sides.
    float side = gl_FrontFacing ? 1.0 : -1.0;
    vec3 n = normalize(world_normal) * side;
    vec3 N = normalize(view_normal) * side;
    vec3 L = normalize(p3d_LightSource[0].position.xyz);
    vec3 V = normalize(-view_pos);
    float shadow = sun_shadow() * cloud_shadow(world_pos, to_light);
    // A little wrap so the shaded side of a cactus isn't flat black.
    float ndl = clamp(dot(N, L) * 0.85 + 0.15, 0.0, 1.0);
    // Darker near the ground, where the plant shades itself and the soil.
    float ao = smoothstep(0.0, 0.45, height);
    vec3 sky_ambient = mix(vec3(0.20, 0.19, 0.17), vec3(0.36, 0.42, 0.52), n.y * 0.5 + 0.5)
                     * ambient_color * mix(0.45, 1.0, ao);
    vec3 sun = p3d_LightSource[0].color * shadow;
    vec3 light = sky_ambient + sun * ndl * mix(0.8, 1.0, ao);
    // Backlit pads and leaves glow.
    float behind = pow(clamp(dot(V, -L), 0.0, 1.0), 3.0);
    vec3 glow = sun * behind * thin * 0.6 * vec3(1.0, 1.15, 0.55);
    float spec = pow(clamp(dot(reflect(-L, N), V), 0.0, 1.0), 12.0) * sheen;
    vec3 lit = color * (light + glow) + sun * spec;

    float fog = smoothstep(fog_end * 0.3, fog_end, dist);
    frag_color = vec4(mix(lit, fog_color.rgb, fog), 1.0);
}
