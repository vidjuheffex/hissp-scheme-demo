#version 150

uniform sampler2D moon_tex;  // the near side, face on (tools/make_moon.py)
uniform vec3 to_sun;         // world-space direction toward the sun
uniform float daylight;      // 0 at night, 1 in full daylight

in vec3 face_normal;
in vec3 world_normal;

out vec4 frag_color;

void main() {
    // The half facing the sun is lit, which gives the phase; it dims a
    // little toward the terminator.
    float ndl = dot(normalize(world_normal), to_sun);
    float lit = smoothstep(-0.03, 0.08, ndl) * mix(0.65, 1.0, smoothstep(0.0, 0.4, ndl));

    // The side toward the player is the face on the texture.
    vec3 f = normalize(face_normal);
    vec3 albedo = texture(moon_tex, f.xy * 0.5 + 0.5).rgb;

    // The unlit side shows faintly at night (earthshine) and not at all by
    // day, when the whole moon is paler against the blue.
    vec3 color = mix(albedo * 0.08, albedo, lit);
    float alpha = mix(0.3 * (1.0 - daylight), mix(1.0, 0.45, daylight), smoothstep(0.0, 0.1, lit));
    frag_color = vec4(color, alpha);
}
