#version 150

// Wind lines, all moved here; see `wind-lines-mesh` in src/world_weather.sld
// for how the mesh is laid out. The entity follows the camera, so positions
// here are relative to the eye.

uniform mat4 p3d_ModelViewProjectionMatrix;
uniform float osg_FrameTime;

uniform vec3 eye;          // world position of the entity, which follows the camera
uniform float box;         // lines come and go in a square this wide around the eye
uniform vec2 wind_dir;     // unit (x z) the wind blows toward
uniform vec2 air_drift;    // how far (x z) the wind has carried the lines so far
uniform float wind_speed;  // about 1 a breeze, 0 dead calm
uniform float amount;      // share of the lines out, 0 to 1

in vec4 p3d_Vertex;          // the line's home spot in the square (x z), world height (y)
in vec2 p3d_MultiTexCoord0;  // x 0 tail to 1 head along the line, y -1 or 1 across
in vec4 p3d_Color;           // r: lowest amount it shows at, g and b its own random numbers

out float across;
out float fade;

const float PI = 3.14159265;
// Seconds a line takes to be drawn out and rubbed away again.
const float LIFE = 4.5;

float hash(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

// Point `s` (0 tail to 1 head) on a line `len` meters long blowing along
// `fwd`: a lazy S-curve side to side and a gentle bob, and, if `curl` is 1,
// a loop up and over two thirds of the way along.
vec3 line_path(float s, float len, vec3 fwd, float r, float g, float curl) {
    vec3 side = vec3(-fwd.z, 0.0, fwd.x);
    float theta = 2.0 * PI * smoothstep(0.45, 0.7, s) * curl;
    float radius = 0.06 * len;
    return fwd * (s * len + radius * sin(theta))
         + vec3(0.0, radius * (1.0 - cos(theta)) + 0.04 * len * sin(s * 4.0 + g * 20.0), 0.0)
         + side * 0.1 * len * sin(s * 5.0 + r * 30.0);
}

void main() {
    float t = osg_FrameTime;
    float r = p3d_Color.g;
    float g = p3d_Color.b;
    vec2 uv = p3d_MultiTexCoord0;
    float w = min(wind_speed, 2.0);
    float len = 50.0 + 30.0 * w;
    vec3 fwd = vec3(wind_dir.x, 0.0, wind_dir.y);

    // Each time round the line starts at a new spot, carried along by the
    // wind, and wraps around inside the square as it follows the eye.
    float clock = t / (LIFE * (0.8 + 0.4 * g)) + r * 7.0;
    float cycle = floor(clock);
    float life = fract(clock);
    vec2 spot = p3d_Vertex.xz + air_drift
              + box * vec2(hash(vec2(cycle, r * 91.0)), hash(vec2(g * 53.0, cycle)));
    vec2 local = mod(spot - eye.xz + 0.5 * box, box) - 0.5 * box;
    vec3 start = vec3(local.x, p3d_Vertex.y - eye.y, local.y) - fwd * 0.5 * len;

    // The head draws the line out along its path and the tail follows it,
    // rubbing it out. The ribbon only ever covers the part that shows.
    float head = clamp(life * 1.7, 0.0, 1.0);
    float tail = clamp(life * 1.7 - 0.7, 0.0, 1.0);
    float s = mix(tail, head, uv.x);
    float curl = step(0.5, hash(vec2(cycle * 1.3, g * 17.0)));
    vec3 p = start + line_path(s, len, fwd, r, g, curl);
    vec3 ahead = start + line_path(s + 0.01, len, fwd, r, g, curl);

    // A ribbon turned to face the camera, tapering to points at both ends,
    // about as wide on screen however far off it is.
    vec3 tangent = normalize(ahead - p + vec3(1e-4, 0.0, 0.0));
    vec3 side = normalize(cross(tangent, p) + vec3(0.0, 1e-4, 0.0));
    float show = step(p3d_Color.r, amount);
    float width = 0.003 * length(p) * sin(PI * uv.x)
                * smoothstep(0.0, 0.1, head - tail) * show;
    p += side * width * uv.y;

    gl_Position = p3d_ModelViewProjectionMatrix * vec4(p, 1.0);
    across = uv.y;
    // Gone before the edge of the square, where they wrap.
    fade = show * (1.0 - smoothstep(0.32, 0.46, length(local) / box));
}
