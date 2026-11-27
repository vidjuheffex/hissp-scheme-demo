#version 150

uniform sampler2D moon_tex;  // the near side, face on (tools/make_moon.py)
uniform vec3 to_sun;         // world-space direction toward the sun
uniform float glare;         // daylight washing the moon out: 0 at night, 1 at midday

in vec3 face_normal;
in vec3 world_normal;

out vec4 frag_color;

void main() {
    // The half facing the sun is lit, which gives the phase; it dims a
    // little toward the terminator.
    float ndl = dot(normalize(world_normal), to_sun);
    float lit = smoothstep(-0.03, 0.08, ndl);
    float shading = mix(0.65, 1.0, smoothstep(0.0, 0.4, ndl));

    // The side toward the player is the face on the texture.
    vec3 f = normalize(face_normal);
    vec3 albedo = texture(moon_tex, f.xy * 0.5 + 0.5).rgb;

    // Two layers: the lit side, which fades into the blue by day (most at
    // midday), and the unlit side, which shows faintly at night (earthshine)
    // and is gone soon after sunrise. Blending them by coverage, rather than
    // darkening the color, keeps the terminator from turning into a dark
    // band against the daytime sky.
    vec3 lit_color = mix(albedo, vec3(0.9, 0.94, 1.0), 0.75 * glare) * shading;
    vec3 dark_color = albedo * 0.08;
    float lit_alpha = lit * mix(1.0, 0.22, glare);
    float dark_alpha = (1.0 - lit) * 0.3 * (1.0 - smoothstep(0.0, 0.3, glare));
    float alpha = lit_alpha + dark_alpha;
    vec3 color = (lit_color * lit_alpha + dark_color * dark_alpha) / max(alpha, 0.001);
    frag_color = vec4(color, alpha);
}
