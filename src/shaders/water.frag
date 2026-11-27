#version 150

uniform struct {
    vec4 position;
    vec3 color;
    sampler2DShadow shadowMap;
    mat4 shadowViewMatrix;
} p3d_LightSource[1];

uniform mat3 p3d_NormalMatrix;
uniform float osg_FrameTime;
uniform vec4 fog_color;
uniform float fog_end;
uniform float shadow_bias;

in vec3 world_pos;
in vec3 view_pos;
in float depth;
in vec4 shadow_coord;

out vec4 frag_color;

// Slope (dh/dx, dh/dz) of a sum of travelling sine waves.
vec2 wave_slope(vec2 p, float t) {
    vec2 s = vec2(0.0);
    vec2 dirs[6] = vec2[](vec2(1.0, 0.3), vec2(-0.4, 1.0), vec2(0.7, -0.8),
                          vec2(-1.0, -0.2), vec2(0.2, 0.9), vec2(0.9, -0.4));
    float freqs[6] = float[](0.4, 0.7, 1.3, 2.3, 3.9, 6.1);
    float amps[6] = float[](0.06, 0.035, 0.02, 0.011, 0.006, 0.0035);
    for (int i = 0; i < 6; ++i) {
        vec2 d = normalize(dirs[i]);
        float phase = dot(d, p) * freqs[i] + t * sqrt(freqs[i]) * 1.6;
        s += d * cos(phase) * freqs[i] * amps[i];
    }
    return s;
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
    float t = osg_FrameTime;
    vec2 slope = wave_slope(world_pos.xz, t);
    vec3 n_world = normalize(vec3(-slope.x, 1.0, -slope.y));
    vec3 N = normalize(p3d_NormalMatrix * n_world);
    vec3 V = normalize(-view_pos);
    vec3 L = normalize(p3d_LightSource[0].position.xyz);
    float shadow = sun_shadow();

    // Water body: turquoise in the shallows, deep blue further out.
    float d = max(depth, 0.0);
    vec3 shallow = vec3(0.10, 0.52, 0.56);
    vec3 deep = vec3(0.02, 0.11, 0.24);
    vec3 body = mix(shallow, deep, smoothstep(0.0, 7.0, d));
    body *= 0.55 + 0.45 * shadow;

    // Sky reflection, stronger at grazing angles (Schlick fresnel).
    float fresnel = 0.02 + 0.98 * pow(1.0 - max(dot(N, V), 0.0), 5.0);
    vec3 sky = fog_color.rgb * 1.05;
    vec3 color = mix(body, sky, clamp(fresnel * 0.9, 0.0, 1.0));

    // Sun glint.
    vec3 R = reflect(-L, N);
    float rv = max(dot(R, V), 0.0);
    float spec = (pow(rv, 900.0) * 0.9 + pow(rv, 60.0) * 0.12) * shadow;
    color += p3d_LightSource[0].color * spec;

    // Foam line along the shore, gently pulsing.
    float shore = 1.0 - smoothstep(0.0, 0.6, d);
    float pulse = 0.65 + 0.35 * sin(t * 1.7 + world_pos.x * 0.6 + world_pos.z * 0.45);
    float foam = shore * pulse;
    color = mix(color, vec3(0.95, 0.97, 1.0), foam * 0.8);

    float alpha = mix(0.45, 0.93, smoothstep(0.0, 3.0, d));
    alpha = max(alpha, max(fresnel, foam * 0.85));

    float fog = smoothstep(fog_end * 0.3, fog_end, length(view_pos));
    color = mix(color, fog_color.rgb, fog);
    alpha = mix(alpha, 1.0, fog);
    frag_color = vec4(color, alpha);
}
