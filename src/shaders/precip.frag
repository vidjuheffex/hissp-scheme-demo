#version 150

uniform float snow;           // 0 rain to 1 snow
uniform vec3 light_color;     // sun or moon light, dimmed by the cloud
uniform vec3 ambient_color;   // sky light: dark blue at night, white by day

in vec2 corner;
in float fade;

out vec4 frag_color;

void main() {
    // Rain: a faint streak, soft at the sides and ends. Snow: a soft dot.
    float along = corner.y * 2.0 - 1.0;
    float streak = (1.0 - corner.x * corner.x) * (1.0 - along * along) * 0.35;
    float flake = 1.0 - smoothstep(0.4, 1.0, length(vec2(corner.x, along)));
    float alpha = mix(streak, 0.9 * flake, snow) * fade;
    if (alpha < 0.01) discard;

    vec3 base = mix(vec3(0.75, 0.80, 0.88), vec3(1.0), snow);
    frag_color = vec4(base * (ambient_color * 0.6 + light_color * 0.5), alpha);
}
