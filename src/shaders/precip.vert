#version 150

uniform mat4 p3d_ModelViewProjectionMatrix;
uniform float osg_FrameTime;

uniform vec3 eye;          // world position of the entity, which follows the camera
uniform vec3 box;          // size of the box of drops around it
uniform float intensity;   // 0 nothing to 1 a downpour
uniform float snow;        // 0 rain to 1 snow
uniform vec2 wind;         // direction (x z) the wind blows

in vec4 p3d_Vertex;          // the drop's spot in the box, same for all four corners
in vec2 p3d_MultiTexCoord0;  // corner: x -1 or 1 across, y 0 or 1 along the fall
in vec4 p3d_Color;           // r: lowest intensity it shows at, g: speed variation

out vec2 corner;
out float fade;

void main() {
    float t = osg_FrameTime;
    float r = p3d_Color.r;
    float speed = mix(9.0, 1.2, snow) * (0.8 + 0.4 * p3d_Color.g);
    vec3 velocity = vec3(wind.x, 0.0, wind.y) * mix(2.0, 0.8, snow) + vec3(0.0, -speed, 0.0);
    vec3 sway = snow * 0.4 * vec3(sin(t * 1.3 + r * 40.0), 0.0, cos(t * 1.1 + r * 30.0));

    // Drops move through the world, not with the camera, and wrap around
    // inside the box as it follows the camera.
    vec3 world = p3d_Vertex.xyz + velocity * t + sway;
    vec3 local = mod(world - eye + box * 0.5, box) - box * 0.5;

    // A streak along the fall (rain) or a small square (snow), turned to
    // face the camera, and nothing at all above the current intensity.
    vec3 along = normalize(velocity);
    vec3 side = normalize(cross(along, local + vec3(1e-3)));
    float size = step(r, intensity);
    float len = mix(0.5, 0.06, snow) * size;
    float width = mix(0.006, 0.03, snow) * size;
    vec3 p = local + side * width * p3d_MultiTexCoord0.x + along * len * (p3d_MultiTexCoord0.y - 0.5);

    gl_Position = p3d_ModelViewProjectionMatrix * vec4(p, 1.0);
    corner = p3d_MultiTexCoord0;
    // Thin out toward the sides of the box and right at the eye.
    fade = (1.0 - smoothstep(0.3, 0.5, length(local.xz) / box.x))
         * smoothstep(0.5, 1.5, length(local));
}
