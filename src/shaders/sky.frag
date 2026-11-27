#version 150

uniform vec3 sky_color;   // at the horizon, where it meets the fog
uniform vec3 to_sun;      // world-space direction toward the sun
uniform vec3 sun_color;   // sunlight now: warm at dusk, black at night
uniform float overcast;   // 0 clear to 1 fully overcast
uniform float osg_FrameTime;

#include "stars.glsl"
#include "mist.glsl"

uniform mat4 p3d_ViewMatrixInverse;

in vec3 dir;

out vec4 frag_color;

void main() {
    vec3 d = normalize(dir);
    float up = max(d.y, 0.0);

    // Deeper blue overhead, the same grey all over once overcast.
    vec3 zenith = sky_color * vec3(0.62, 0.78, 1.0);
    vec3 color = mix(sky_color, mix(zenith, sky_color, overcast), smoothstep(0.0, 0.6, up));

    // Glow around the sun.
    float s = max(dot(d, to_sun), 0.0);
    color += sun_color * (0.25 * pow(s, 12.0) + 0.4 * pow(s, 200.0)) * (1.0 - overcast);

    if (stars > 0.0 && d.y > 0.0)
        color += starlight(d, length(fwidth(d)) * 0.8, osg_FrameTime) * star_visibility(color);

    // From inside the mist, the sky low down is lost in it.
    vec3 eye = p3d_ViewMatrixInverse[3].xyz;
    color = mix(color, mist_color(sky_color), mist_between(eye, eye + d * 250.0));
    frag_color = vec4(color, 1.0);
}
