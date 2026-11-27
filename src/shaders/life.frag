#version 150

uniform vec3 ambient_color;   // the sky's light, to tint bird silhouettes

in vec2 corner;
in float kind;
in float glow;

out vec4 frag_color;

void main() {
    if (kind < 0.25) {
        // A firefly: a hot yellow-green point in a soft halo.
        float d = length(corner);
        float halo = 1.0 - smoothstep(0.0, 1.0, d);
        float core = 1.0 - smoothstep(0.0, 0.3, d);
        float a = glow * (0.5 * halo * halo + core);
        if (a < 0.003) discard;
        frag_color = vec4(vec3(0.85, 1.0, 0.35) * (1.0 + core), clamp(a, 0.0, 1.0));
        return;
    }
    // Bats and birds are silhouettes against the sky.
    vec3 color = kind < 0.75 ? vec3(0.03, 0.025, 0.03) : vec3(0.10, 0.09, 0.08) * ambient_color;
    frag_color = vec4(color, 1.0);
}
