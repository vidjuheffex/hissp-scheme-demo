#version 150

uniform struct {
    vec4 position;
    vec3 color;
    sampler2DShadow shadowMap;
    mat4 shadowViewMatrix;
} p3d_LightSource[1];

uniform mat4 p3d_ViewMatrixInverse;
uniform float osg_FrameTime;
uniform vec4 fog_color;          // also the sky at the horizon
uniform vec3 ambient_color;
uniform float fog_end;
uniform float shadow_bias;
uniform float rain;              // 0 dry to 1 a downpour
uniform float wind_speed;        // about 1 a breeze, 0 dead calm
uniform float overcast;          // greys the sky gradient
uniform float precipitation;     // darkens the clouds
uniform vec3 cloud_light_color;  // sun or moon light on the clouds
uniform vec3 to_light;           // world direction toward the shadow light (sun or moon)

#include "clouds.glsl"
#include "stars.glsl"

in vec3 world_pos;
in vec3 view_pos;
in float depth;   // negative over dry ground
in float ground_slope;
in vec4 shadow_coord;

out vec4 frag_color;

// Value noise with its gradient: (value, d/dx, d/dy).
vec3 noise_grad(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    vec2 u = f * f * (3.0 - 2.0 * f);
    vec2 du = 6.0 * f * (1.0 - f);
    float a = cloud_hash(i);
    float b = cloud_hash(i + vec2(1.0, 0.0));
    float c = cloud_hash(i + vec2(0.0, 1.0));
    float d = cloud_hash(i + vec2(1.0, 1.0));
    float k = a - b - c + d;
    return vec3(a + (b - a) * u.x + (c - a) * u.y + k * u.x * u.y,
                du * (vec2(b - a, c - a) + k * u.yx));
}

// Slope (dh/dx, dh/dz) of the surface: a long swell under wind chop, the
// chop in two layers drifting different ways so it never repeats. `detail`
// (0 to 1) fades the finest chop, which far off would only shimmer. The
// wind raises the chop; in a dead calm only a faint swell is left, and the
// water mirrors the sky.
// How much of the swell is left in a wind of `w`: hardly any in a calm.
float swell(float w) {
    return mix(0.02, 1.0, min(w * w, 1.0));
}

vec2 wave_slope(vec2 p, float t, float detail) {
    float w = min(wind_speed, 1.6);
    float chop = w * sqrt(w);
    vec2 d1 = normalize(vec2(1.0, 0.3));
    vec2 d2 = normalize(vec2(-0.4, 1.0));
    vec2 s = (d1 * cos(dot(d1, p) * 0.35 + t * 0.95) * 0.018
            + d2 * cos(dot(d2, p) * 0.6 + t * 1.25) * 0.018) * swell(w);
    mat2 turn = mat2(0.8, -0.6, 0.6, 0.8);
    for (int layer = 0; layer < 2; ++layer) {
        vec2 flow = layer == 0 ? vec2(0.55, 0.2) : vec2(-0.25, 0.45);
        mat2 m = layer == 0 ? mat2(1.0) : mat2(0.6, 0.8, -0.8, 0.6);
        float freq = 0.8;
        float amp = 0.03;
        for (int i = 0; i < 4; ++i) {
            vec2 q = m * p * freq + flow * t * (1.0 + 0.3 * float(i)) + float(i * 7 + layer * 3);
            vec2 g = noise_grad(q).yz;
            s += amp * freq * (g * m) * (i < 2 ? 1.0 : detail) * chop;
            m = turn * m;
            freq *= 2.1;
            amp *= 0.5;
        }
    }
    return s;
}

// Slope of rings spreading from raindrops. Each cell of a grid gets a drop
// at a random spot and moment, of random size; light rain leaves most cells
// calm. Four offset grids of different sizes keep it from looking regular.
vec2 ripple_slope(vec2 p, float t) {
    vec2 s = vec2(0.0);
    for (int layer = 0; layer < 4; ++layer) {
        float k = float(layer);
        vec2 q = p * (1.1 + 0.37 * k) + vec2(k * 0.37, k * 0.71);
        vec2 cell = floor(q) + k * 31.7;
        float h = cloud_hash(cell);
        if (h > rain) continue;
        float size = 0.25 + 0.2 * cloud_hash(cell + 5.3);
        vec2 center = vec2(cloud_hash(cell + 3.7), cloud_hash(cell + 9.1)) * 0.4 - 0.2;
        float age = fract(t * (0.7 + 0.3 * h) + h * 7.0 + k * 0.29);
        vec2 off = fract(q) - 0.5 - center;
        float r = length(off);
        // A short train of crests that widens and dies away as it spreads.
        float front = r - age * size;
        float width = 0.03 + 0.05 * age;
        float ring = sin(front / width * 2.5) * exp(-front * front / (width * width));
        float fade = (1.0 - age) * (1.0 - age) * smoothstep(0.5, 0.35, r);
        s += off / max(r, 1e-3) * ring * fade * 0.55;
    }
    return s;
}

// The sky seen along world direction `d` from point `p`: the same gradient
// and stars as sky.frag and the same clouds as clouds.frag, simplified.
// `pixel` is the angle one pixel's worth of `d` covers, for the stars.
vec3 sky_toward(vec3 d, vec3 p, float pixel) {
    vec3 horizon = fog_color.rgb;
    vec3 zenith = horizon * vec3(0.62, 0.78, 1.0);
    vec3 color = mix(horizon, mix(zenith, horizon, overcast), smoothstep(0.0, 0.6, d.y));
    // Brighter than in the sky: a few percent of starlight off the water
    // would be lost against the dark, where an eye used to it still sees it.
    if (stars > 0.0 && d.y > 0.0)
        color += starlight(d, pixel, osg_FrameTime) * star_visibility(color) * 3.0;
    if (d.y > 0.02) {
        float t = (CLOUD_ALTITUDE - p.y) / d.y;
        float n = cloud_field(p.xz + d.xz * t, 4);
        float density = cloud_density(n) * smoothstep(0.02, 0.1, d.y);
        float edge = cloud_edge();
        float grey = mix(1.0, 0.75, smoothstep(edge, edge + 0.5, n))
                   * mix(1.0, 0.75, cover * cover) * mix(1.0, 0.5, precipitation);
        vec3 cloud = grey * (ambient_color * ambient_color * 0.45 * vec3(0.85, 0.9, 1.0)
                             + cloud_light_color * 0.65);
        cloud = mix(cloud, horizon, 0.7 * smoothstep(0.0, 1.0, t / 12000.0));
        color = mix(color, cloud, density);
    }
    return color;
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
    // Fade to nothing at the shoreline, so the terrain's edge never shows.
    if (depth <= 0.0) discard;
    float d = depth;
    float shore = d / max(ground_slope, 0.02);
    float edge = smoothstep(0.0, 0.9, shore);

    float t = osg_FrameTime;
    float dist = length(view_pos);
    vec3 eye = p3d_ViewMatrixInverse[3].xyz;
    vec3 V = normalize(eye - world_pos);
    vec3 L = normalize(to_light);

    vec2 slope = wave_slope(world_pos.xz, t, 1.0 - smoothstep(12.0, 60.0, dist));
    // Ripples are too small to see far off, where they would only flicker.
    float near = 1.0 - smoothstep(8.0, 25.0, dist);
    vec2 ripples = vec2(0.0);
    if (rain > 0.0 && near > 0.0) ripples = ripple_slope(world_pos.xz, t) * near;
    slope += ripples;
    vec3 N = normalize(vec3(-slope.x, 1.0, -slope.y));
    float shadow = sun_shadow() * cloud_shadow(world_pos, to_light);

    // Water body: clear green-teal in the shallows, deep blue further out,
    // lit like the ground by sky light plus the sun or moon from above.
    vec3 shallow = vec3(0.10, 0.46, 0.42);
    vec3 deep = vec3(0.02, 0.10, 0.20);
    vec3 body = mix(shallow, deep, smoothstep(0.0, 6.0, d));
    vec3 daylight = ambient_color * 0.45 + p3d_LightSource[0].color * max(L.y, 0.0) * shadow * 0.7;
    body *= daylight;

    // Reflection of the sky and clouds, stronger at grazing angles (Schlick
    // fresnel). Rays bent down by the waves would hit water; mirror them up.
    vec3 R = reflect(-V, N);
    R.y = abs(R.y);
    // Waves spread a pixel's reflection over more sky, smearing the stars,
    // and over time too: any chop at all moves it about from frame to frame.
    float w = min(wind_speed, 1.6);
    float pixel = max(length(fwidth(R)) * 0.8, 0.2 * w * sqrt(w) + 0.05 * swell(w));
    float fresnel = 0.02 + 0.98 * pow(1.0 - max(dot(N, V), 0.0), 5.0);
    vec3 color = mix(body, sky_toward(R, world_pos, pixel), fresnel);
    // Looking down, the water reflects too little for tilted ripples to
    // show by reflection alone; their crests catch the sky light.
    color += sky_toward(vec3(0.0, 1.0, 0.0), world_pos, 1.0) * min(length(ripples), 1.0) * 0.3;

    // Sun glint.
    float rv = max(dot(reflect(-L, N), V), 0.0);
    float spec = (pow(rv, 900.0) * 0.9 + pow(rv, 60.0) * 0.12) * shadow;
    color += p3d_LightSource[0].color * spec;

    // Foam: a thin fringe at the waterline and narrow lines rolling in toward
    // it, both broken into bubbles. Placed by distance from the shore (depth
    // over the slope of the ground), so wide flat shallows stay clear.
    float fringe = smoothstep(0.0, 0.03, depth) * (1.0 - smoothstep(0.15, 0.5, shore));
    float phase = shore * 0.6 + t * 0.22 + noise_grad(world_pos.xz * 0.35).x * 1.2;
    float lines = pow(0.5 + 0.5 * cos(phase * 6.2832), 14.0)
                * (1.0 - smoothstep(1.0, 3.5, shore)) * (1.0 - smoothstep(0.3, 0.8, d));
    vec2 fp = world_pos.xz + vec2(0.0, t * 0.04);
    float bubbles = smoothstep(0.45, 0.85, noise_grad(fp * 6.0).x * 0.65 + noise_grad(fp * 15.0).x * 0.35);
    float foam = max(fringe, lines) * bubbles;
    color = mix(color, vec3(0.95, 0.97, 1.0) * daylight, foam);

    // Clear in the shallows so the seabed shows, murkier with depth.
    float alpha = mix(0.25, 0.95, smoothstep(0.0, 4.0, d));
    alpha = max(max(alpha, fresnel) * edge, foam * 0.85);

    float fog = smoothstep(fog_end * 0.3, fog_end, dist);
    color = mix(color, fog_color.rgb, fog);
    alpha = mix(alpha, 1.0, fog * max(edge, foam));
    frag_color = vec4(color, alpha);
}
