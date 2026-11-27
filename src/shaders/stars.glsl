// The stars and the Milky Way, shared by sky.frag and water.frag (which sees
// them reflected), which include this file by name.

uniform float stars;      // 0 none to 1 a clear moonless night
uniform float star_angle; // how far the stars have turned, like the sun, about z

float star_hash(vec3 c) {
    return fract(sin(dot(c, vec3(127.1, 311.7, 74.7))) * 43758.5453);
}

float star_noise(vec3 p) {
    vec3 c = floor(p);
    vec3 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    float a = mix(mix(star_hash(c), star_hash(c + vec3(1, 0, 0)), f.x),
                  mix(star_hash(c + vec3(0, 1, 0)), star_hash(c + vec3(1, 1, 0)), f.x), f.y);
    float b = mix(mix(star_hash(c + vec3(0, 0, 1)), star_hash(c + vec3(1, 0, 1)), f.x),
                  mix(star_hash(c + vec3(0, 1, 1)), star_hash(c + vec3(1, 1, 1)), f.x), f.y);
    return mix(a, b, f.z);
}

// Stars seen along unit direction `s`: at most one per cell of a grid with
// `per_unit` cells per unit, there with chance `chance`. `pixel` is the
// angle one pixel covers; a star is never drawn smaller, only dimmer, so it
// doesn't shimmer.
vec3 star_layer(vec3 s, float per_unit, float chance, float size, float pixel) {
    vec3 q = s * per_unit;
    vec3 cell = floor(q);
    float h = star_hash(cell);
    if (h > chance) return vec3(0.0);
    vec3 at = normalize(cell + 0.3 + 0.4 * vec3(star_hash(cell + 17.0), star_hash(cell + 31.0),
                                                star_hash(cell + 47.0)));
    float bright = pow(star_hash(cell + 61.0), 12.0) * 1.4 + 0.06;
    // Spread over at least a pixel, and as dim as that spreading makes it,
    // but drawn no wider than fades out before the edge of its cell. Where
    // a pixel covers far more sky than that (rippled water), it only dims,
    // or it would sparkle as the waves move.
    float spread = max(size * (0.6 + bright), pixel);
    float r = min(spread, 0.1 / per_unit);
    float over = max(spread / (2.0 * r), 1.0);
    float glow = exp(-dot(s - at, s - at) / (r * r)) * bright * (size * size) / (r * r * over * over) * 4.0;
    // Hot blue-white to cool orange, mostly white.
    float t = star_hash(cell + 73.0);
    vec3 tint = mix(vec3(0.75, 0.85, 1.0), vec3(1.0, 0.8, 0.6), t * t);
    return tint * glow;
}

// Starlight along world direction `d` (above the horizon), before `stars`
// and the sky's own glow have a say. `pixel` as in `star_layer`.
vec3 starlight(vec3 d, float pixel, float t) {
    // Into the stars' own frame, which turns with the sun's path.
    float c = cos(star_angle), sn = sin(star_angle);
    vec3 st = vec3(d.x * c - d.y * sn, d.x * sn + d.y * c, d.z);
    // The Milky Way: a soft band around the sky with dark dust lanes.
    vec3 galaxy = normalize(vec3(0.35, 0.55, 0.76));
    float off = dot(st, galaxy);
    float band = exp(-off * off / 0.03);
    float clumps = star_noise(st * 6.0) * 0.6 + star_noise(st * 15.0) * 0.4;
    float dust = smoothstep(0.45, 0.7, star_noise(st * 9.0 + 3.1)) * exp(-off * off / 0.004);
    float milky = band * (0.4 + 0.8 * clumps) * (1.0 - 0.8 * dust);
    vec3 light = vec3(0.55, 0.58, 0.68) * milky * 0.09;
    light += star_layer(st, 60.0, 0.09, 0.0025, pixel);
    light += star_layer(st, 150.0, 0.06 + 0.3 * band, 0.0011, pixel) * 0.4;
    // Dimmer and twinkling low down, through more air.
    float air = smoothstep(0.0, 0.35, d.y);
    float twinkle = 1.0 - (1.0 - air) * 0.5 * star_noise(vec3(st.xz * 400.0, t * 6.0));
    return light * (0.25 + 0.75 * air) * twinkle;
}

// How much of the stars shows through a sky of color `sky`: none in any
// glow of dusk or moonlight.
float star_visibility(vec3 sky) {
    return stars * smoothstep(0.1, 0.025, dot(sky, vec3(0.3, 0.59, 0.11)));
}
