#version 150

uniform vec3 sky_color;       // at the horizon, where it meets the fog
uniform vec3 to_light;        // direction toward the sun, or the moon at night
uniform vec3 light_color;     // that light's color above the clouds
uniform vec3 ambient_color;   // sky light: dark blue at night, white by day
uniform float precipitation;  // heavier, darker cloud while it rains or snows
uniform vec3 eye;             // camera position in the world

#include "clouds.glsl"

in vec3 dir;

out vec4 frag_color;

const float HAZE = 12000.0;   // distance at which clouds are lost in the haze

void main() {
    vec3 d = normalize(dir);
    if (d.y < 0.01) discard;

    // Where this view ray meets the cloud layer.
    float t = (CLOUD_ALTITUDE - eye.y) / d.y;
    vec2 xz = eye.xz + d.xz * t;
    float n = cloud_field(xz, 5);
    float density = cloud_density(n);
    if (density <= 0.0) discard;

    // Lit on the side facing the light: there the cloud thins out toward it.
    float toward = cloud_field(xz + normalize(to_light.xz + vec2(1e-4)) * 56.0, 5);
    float lit = clamp(0.6 + (n - toward) * 5.0, 0.0, 1.0);
    // Thick cores, a sky full of cloud and rain clouds are darker underneath.
    float edge = cloud_edge();
    float thick = smoothstep(edge, edge + 0.5, n);
    float grey = mix(1.0, 0.75, thick) * mix(1.0, 0.75, cover * cover)
               * mix(1.0, 0.5, precipitation);
    vec3 color = grey * (ambient_color * ambient_color * 0.45 * vec3(0.85, 0.9, 1.0)
                         + light_color * (0.25 + 0.55 * lit));

    color = mix(color, sky_color, 0.7 * smoothstep(0.0, 1.0, t / HAZE));
    frag_color = vec4(color, density * smoothstep(0.01, 0.1, d.y));
}
