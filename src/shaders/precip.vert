#version 150

uniform mat4 p3d_ModelViewProjectionMatrix;
uniform float osg_FrameTime;

uniform vec3 eye;          // world position of the entity, which follows the camera
uniform vec3 box;          // size of the box of drops around it
uniform float intensity;   // 0 nothing to 1 a downpour
uniform float snow;        // 0 rain to 1 snow
uniform vec2 rain_wind;    // how fast (x z, m/s) the wind carries the drops now
uniform vec2 rain_drift;   // how far (x z) the wind has carried them so far
uniform float fall_distance; // integrated vertical travel at mean particle speed
uniform vec3 eye_velocity; // how fast the camera is moving (m/s)

in vec4 p3d_Vertex;          // the drop's spot in the box, same for all four corners
in vec2 p3d_MultiTexCoord0;  // corner: x -1 or 1 across, y 0 or 1 along the fall
in vec4 p3d_Color;           // r: lowest intensity it shows at, g: speed variation

out vec2 corner;
out float fade;

void main() {
    float t = osg_FrameTime;
    float r = p3d_Color.r;
    if (r > intensity) {
        gl_Position = vec4(2.0, 0.0, 0.0, 1.0);
        return;
    }
    float variation = (16.0 + floor(p3d_Color.g * 8.0 + 0.5)) / 20.0;
    float speed = mix(9.0, 1.2, snow) * variation;
    vec3 sway = snow * 0.4 * vec3(sin(t * 1.3 + r * 40.0), 0.0, cos(t * 1.1 + r * 30.0));
    // Gusts sweep through, pushing the drops they reach harder for a moment.
    float gust_phase = t * 0.6 + dot(p3d_Vertex.xz, vec2(0.08, 0.05));
    vec3 wind = vec3(rain_wind.x, 0.0, rain_wind.y);
    vec3 gust = wind * 0.4 * sin(gust_phase);
    vec3 velocity = wind * (1.0 + 0.24 * cos(gust_phase)) + vec3(0.0, -speed, 0.0);

    // Drops move through the world, not with the camera, and wrap around
    // inside the box as it follows the camera. The wind's push is summed up
    // on the CPU (`rain_drift`), so the drops don't jump when it changes.
    vec3 world = p3d_Vertex.xyz + vec3(rain_drift.x, -fall_distance * variation, rain_drift.y) + gust + sway;
    vec3 local = mod(world - eye + box * 0.5, box) - box * 0.5;

    // A streak (rain) or a small square (snow), turned to face the camera,
    // and nothing at all above the current intensity. Streaks lie along the
    // drop's motion as the moving eye sees it, and stretch with it: walking
    // into the rain, the drops ahead rush up and past, not down. Only half
    // the eye's own speed counts, or a walk tilts them too far.
    vec3 seen = velocity - 0.5 * eye_velocity;
    // A rapid descent can overtake a flake. Keep the drawn streak stable
    // as relative speed passes through zero.
    vec3 along = length(seen) > 0.001 ? normalize(seen) : vec3(0.0, -1.0, 0.0);
    vec3 side = normalize(cross(along, local + vec3(1e-3)));
    float len = mix(0.5, 0.06, snow) * clamp(length(seen) / length(velocity), 1.0, 2.5);
    float width = mix(0.006, 0.03, snow);
    vec3 p = local + side * width * p3d_MultiTexCoord0.x + along * len * (p3d_MultiTexCoord0.y - 0.5);

    gl_Position = p3d_ModelViewProjectionMatrix * vec4(p, 1.0);
    corner = p3d_MultiTexCoord0;
    // Thin out toward the sides of the box and right at the eye.
    fade = (1.0 - smoothstep(0.3, 0.5, length(local.xz) / box.x))
         * (1.0 - smoothstep(0.40, 0.49, abs(local.y) / box.y))
         * smoothstep(0.5, 1.5, length(local));
}
