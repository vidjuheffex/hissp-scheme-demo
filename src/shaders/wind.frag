#version 150

uniform vec3 ambient_color;   // the sky's light: white by day, dim blue at night

in float across;
in float fade;

out vec4 frag_color;

void main() {
    float a = 0.6 * fade * (1.0 - smoothstep(0.3, 1.0, abs(across)));
    if (a < 0.003) discard;
    frag_color = vec4(min(ambient_color * 1.1, vec3(1.0)), a);
}
