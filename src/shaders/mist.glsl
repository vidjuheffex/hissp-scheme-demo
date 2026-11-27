// Valley mist: fog that lies thickest at sea level and thins out a few
// meters up, so it pools in the low ground and the hills stand clear of it.
// Shared by every shader that draws the ground or the sky, which include
// this file by name.

uniform float mist;       // 0 none to 1 thick
uniform float mist_base;  // height the mist is thickest at (sea level)

const float MIST_DEPTH = 4.0;     // meters up over which it thins by e
const float MIST_DENSITY = 0.07;  // per meter at the base, when thick

// How much mist lies between `eye` and `p`, 0 to 1: the density, falling off
// exponentially with height, summed along the line of sight.
float mist_between(vec3 eye, vec3 p) {
    if (mist <= 0.0) return 0.0;
    float a = max(eye.y - mist_base, 0.0) / MIST_DEPTH;
    float b = max(p.y - mist_base, 0.0) / MIST_DEPTH;
    float e = abs(b - a) > 1e-3 ? (exp(-a) - exp(-b)) / (b - a) : exp(-a);
    return 1.0 - exp(-mist * MIST_DENSITY * length(p - eye) * e);
}

// Mist is paler than the sky it's lit by.
vec3 mist_color(vec3 fog) {
    float l = dot(fog, vec3(0.3, 0.59, 0.11));
    return mix(fog, vec3(l * 1.15 + 0.02), 0.65);
}
