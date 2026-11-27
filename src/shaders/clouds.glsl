// The cloud layer, shared by the sky and everything that clouds shade.
// Shaders pull this in with an include line naming this file (the game
// splices it in when it loads them).

uniform float cover;   // 0 clear to 1 overcast
uniform vec2 drift;    // how far (meters) the wind has carried the clouds

const float CLOUD_ALTITUDE = 520.0;   // world height of the cloud layer
const float CLOUD_SCALE = 1400.0;     // meters across the largest cloud features

float cloud_hash(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float cloud_noise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    vec2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(cloud_hash(i), cloud_hash(i + vec2(1.0, 0.0)), u.x),
               mix(cloud_hash(i + vec2(0.0, 1.0)), cloud_hash(i + vec2(1.0, 1.0)), u.x), u.y);
}

// Cloud noise at world (x, z) on the layer, 0 to 1. Fewer octaves give the
// same clouds without their finest detail.
float cloud_field(vec2 xz, int octaves) {
    vec2 p = (xz - drift) / CLOUD_SCALE;
    mat2 turn = mat2(0.8, -0.6, 0.6, 0.8);
    float sum = 0.0;
    float amp = 0.5;
    float total = 0.0;
    for (int i = 0; i < octaves; ++i) {
        sum += amp * cloud_noise(p);
        total += amp;
        p = turn * p * 2.03 + vec2(17.1, 9.2);
        amp *= 0.5;
    }
    return sum / total;
}

// Field value where clouds begin; more cover lowers it, so clouds grow and
// merge. The field never goes below about 0.15, so full cover leaves no gaps.
float cloud_edge() {
    return mix(0.75, -0.05, pow(cover, 1.5));
}

float cloud_density(float field) {
    float edge = cloud_edge();
    return smoothstep(edge, edge + 0.22, field);
}

// Share of direct light reaching world point `p` past the clouds, for light
// coming from direction `to_light`. Thick cloud lets a quarter through.
float cloud_shadow(vec3 p, vec3 to_light) {
    vec3 l = normalize(to_light);
    vec2 q = p.xz + l.xz / max(l.y, 0.08) * (CLOUD_ALTITUDE - p.y);
    return 1.0 - 0.75 * cloud_density(cloud_field(q, 3));
}
