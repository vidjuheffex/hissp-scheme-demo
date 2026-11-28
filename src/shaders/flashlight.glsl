uniform float flashlight;   // automatic brightness, 0 off to 1 on
uniform float flashlight_shadows;
uniform float flashlight_reach;
uniform float flashlight_spill_cos;

uniform struct {
    vec4 position;
    vec3 spotDirection;
    sampler2DShadow shadowMap;
    mat4 shadowViewMatrix;
} flashlight_source;

const vec3 FLASHLIGHT_COLOR = vec3(1.0, 0.94, 0.84);
const float FLASHLIGHT_INNER_ANGLE = 6.0;
const float FLASHLIGHT_OUTER_ANGLE = 22.0;
const float FLASHLIGHT_SPILL = 0.12;
const float FLASHLIGHT_HALF_DISTANCE = 9.0;

float flashlight_shadow(vec3 view_pos) {
    if (flashlight_shadows < 0.5) return 1.0;
    vec4 coord = flashlight_source.shadowViewMatrix * vec4(view_pos, 1.0);
    vec3 p = coord.xyz / coord.w;
    if (coord.w <= 0.0 || any(lessThan(p, vec3(0.0))) || any(greaterThan(p, vec3(1.0))))
        return 0.0;
    vec2 texel = 1.0 / vec2(textureSize(flashlight_source.shadowMap, 0));
    float lit = 0.0;
    for (int x = -1; x <= 1; ++x) {
        for (int y = -1; y <= 1; ++y) {
            vec4 sample_coord = coord;
            sample_coord.xy += vec2(x, y) * texel * coord.w;
            sample_coord.z -= 0.00004 * coord.w;
            lit += textureProj(flashlight_source.shadowMap, sample_coord);
        }
    }
    return lit / 9.0;
}

// Panda supplies the same hand position and direction used by the shadow
// camera, in view space, so the beam follows mouse look without lag.
float flashlight_beam(vec3 view_pos) {
    if (flashlight <= 0.0) return 0.0;
    vec3 ray = view_pos - flashlight_source.position.xyz;
    float dist = max(length(ray), 1e-4);
    if (dist >= flashlight_reach) return 0.0;
    vec3 axis = normalize(flashlight_source.spotDirection);
    float alignment = dot(ray / dist, axis);
    if (alignment <= flashlight_spill_cos) return 0.0;
    float cone = smoothstep(cos(radians(FLASHLIGHT_OUTER_ANGLE)),
                            cos(radians(FLASHLIGHT_INNER_ANGLE)), alignment);
    // The reflector's dim spill reveals nearby rock beyond the main spot,
    // but still points forward; it never becomes an all-around player glow.
    float spill = smoothstep(flashlight_spill_cos,
                             cos(radians(FLASHLIGHT_OUTER_ANGLE)), alignment);
    float distance_ratio = dist / FLASHLIGHT_HALF_DISTANCE;
    float reach = (1.0 - smoothstep(flashlight_reach * 0.75, flashlight_reach, dist))
                  / (1.0 + distance_ratio * distance_ratio);
    return flashlight * mix(cone, spill, FLASHLIGHT_SPILL) * reach * flashlight_shadow(view_pos);
}

vec3 flashlight_light(vec3 view_pos, vec3 view_normal) {
    float facing = max(dot(normalize(view_normal), normalize(flashlight_source.position.xyz - view_pos)), 0.0);
    return FLASHLIGHT_COLOR * flashlight_beam(view_pos) * facing * 1.6;
}
