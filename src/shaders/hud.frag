#version 150

// The font's own anti-aliased coverage, used as is. Ursina's text shaders
// expect a distance-field font and cut ordinary glyphs at a hard edge.

uniform sampler2D p3d_Texture0;
uniform vec4 p3d_ColorScale;

in vec2 uv;
in vec4 tint;

out vec4 frag_color;

void main() {
    float coverage = texture(p3d_Texture0, uv).a;
    frag_color = vec4(tint.rgb, tint.a * coverage) * p3d_ColorScale;
}
