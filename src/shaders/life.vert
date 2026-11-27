#version 150

// Fireflies, bats and birds, all moved here; see src/world_life.sld for
// how the mesh is laid out. The entity follows the camera, so positions
// here are relative to the eye.

uniform mat4 p3d_ModelViewMatrix;
uniform mat4 p3d_ProjectionMatrix;
uniform float osg_FrameTime;

uniform vec3 eye;            // world position of the entity, which follows the camera
uniform float box;           // fireflies fill a square this wide around the eye
uniform float fireflies;     // 0 none to 1 all of them out
uniform float bats;
uniform float birds;
uniform sampler2D ground;    // ground heights around the player
uniform vec2 ground_corner;  // world (x, z) of the ground grid's outer corner
uniform float ground_size;   // meters the ground grid covers
uniform vec2 drift;          // how far (meters) the wind has carried the clouds

in vec4 p3d_Vertex;          // the creature's anchor
in vec2 p3d_MultiTexCoord0;  // its place on the creature
in vec4 p3d_Color;           // r kind, g and b its own random numbers

out vec2 corner;
out float kind;
out float glow;

const float PI = 3.14159265;

float ground_at(vec2 xz) {
    return texture(ground, (xz - ground_corner) / ground_size).r;
}

// A bat's flight, relative to the eye: wide loops around a spot fixed in
// the world, with sudden jinks on top. The spots wrap around a square
// around the eye, like the fireflies.
const float BAT_SQUARE = 50.0;

vec3 bat_path(vec3 anchor, float r, float s, float t) {
    vec2 spot = mod(anchor.xz - eye.xz + 0.5 * BAT_SQUARE, BAT_SQUARE) - 0.5 * BAT_SQUARE;
    return vec3(spot.x, anchor.y, spot.y)
         + vec3(6.0 * sin(t * 0.7 + r * 30.0), 1.2 * sin(t * 0.5 + s * 9.0), 6.0 * cos(t * 0.9 + s * 30.0))
         + vec3(1.3 * sin(t * 3.1 + r * 9.0), 0.8 * sin(t * 2.3 + s * 7.0), 1.3 * cos(t * 2.7 + s * 11.0));
}

// A bird circling in its flock, relative to the eye. Flocks drift over the
// world downwind and wrap around a big square around the eye.
vec3 bird_path(vec3 anchor, float flock, float s, float t) {
    float square = 200.0;
    vec2 c = vec2(fract(flock * 7.13), fract(flock * 3.71)) * square + 0.2 * drift;
    c = mod(c - eye.xz + 0.5 * square, square) - 0.5 * square;
    float a = t * (0.22 + 0.08 * flock) + s * 0.6;
    float radius = 10.0 + 10.0 * flock;
    return vec3(c.x, 32.0 + 30.0 * flock, c.y)
         + vec3(cos(a) * radius, 1.5 * sin(a * 2.0 + s * 5.0), sin(a) * radius)
         + anchor * 3.0;
}

void main() {
    float t = osg_FrameTime;
    float r = p3d_Color.g;
    float s = p3d_Color.b;
    vec2 uv = p3d_MultiTexCoord0;
    kind = p3d_Color.r;
    corner = uv;
    glow = 0.0;
    vec3 p;
    if (kind < 0.25) {
        // Fireflies drift through the world and wrap around inside the
        // square as it follows the eye, hovering low over the ground and
        // flashing now and then.
        vec2 world = p3d_Vertex.xz
                   + vec2(1.5 * sin(t * 0.30 + r * 40.0), 1.5 * cos(t * 0.27 + s * 40.0))
                   + 0.3 * vec2(sin(t * 1.7 + s * 13.0), cos(t * 1.3 + r * 17.0));
        vec2 local = mod(world - eye.xz + 0.5 * box, box) - 0.5 * box;
        world = eye.xz + local;
        float y = ground_at(world) + 0.35 + 1.8 * p3d_Vertex.y * p3d_Vertex.y
                + 0.25 * sin(t * 0.9 + r * 20.0);
        p = vec3(local.x, y - eye.y, local.y);
        float flash = pow(max(sin(t * (0.6 + 0.6 * s) + r * 50.0), 0.0), 4.0);
        glow = flash * step(r, fireflies) * (1.0 - smoothstep(0.3, 0.5, length(local) / box));
        // A small glow, turned to face the camera.
        vec3 toward = normalize(p + vec3(0.0, 1e-4, 0.0));
        vec3 right = normalize(cross(toward, vec3(0.0, 1.0, 0.0)) + vec3(1e-4, 0.0, 0.0));
        vec3 above = cross(right, toward);
        p += (right * uv.x + above * uv.y) * 0.13 * step(0.001, glow);
        gl_Position = p3d_ProjectionMatrix * (p3d_ModelViewMatrix * vec4(p, 1.0));
        return;
    }
    bool bat = kind < 0.75;
    vec3 a = p3d_Vertex.xyz;
    vec3 here = bat ? bat_path(a, r, s, t) : bird_path(a, r, s, t);
    vec3 ahead = bat ? bat_path(a, r, s, t + 0.05) : bird_path(a, r, s, t + 0.05);
    vec3 forward = normalize(ahead - here + vec3(0.0, 0.0, 1e-4));
    vec3 side = normalize(cross(vec3(0.0, 1.0, 0.0), forward) + vec3(1e-4, 0.0, 0.0));
    vec3 up = cross(forward, side);
    float flap;
    float span;
    float body;
    if (bat) {
        // Quick, ragged wingbeats.
        flap = sin(t * 19.0 + r * 30.0 + s * 50.0);
        span = 0.22;
        body = 0.17;
    } else {
        // Spells of flapping, then gliding on raised wings.
        float glide = smoothstep(0.35, 0.65, 0.5 + 0.5 * sin(t * 0.35 + s * 11.0));
        flap = mix(sin(t * 7.0 + s * 20.0), 0.18, glide);
        span = 0.8;
        body = 0.35;
    }
    float show = step(bat ? s : fract(s * 13.7), bat ? bats : birds);
    // Bats shrink away near the edge of their square rather than pop across.
    if (bat) show *= 1.0 - smoothstep(0.38, 0.48, length(here.xz) / BAT_SQUARE);
    // Wing tips lift and drop with each beat, more than the middle.
    float lift = flap * span * abs(uv.x) * (abs(uv.x) > 0.75 ? 0.6 : 0.3);
    p = here + (forward * uv.y * body + side * uv.x * span + up * lift) * show;
    gl_Position = p3d_ProjectionMatrix * (p3d_ModelViewMatrix * vec4(p, 1.0));
}
