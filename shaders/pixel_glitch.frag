// shaders/pixel_glitch.frag
// Subtle pixel glitch / RGB split shift effect.

extern float u_time;

vec4 effect(vec4 color, Image texture, vec2 texture_coords, vec2 screen_coords) {
    // Intermittent glitch trigger
    float glitch = step(0.92, fract(sin(u_time * 7.0) * 43758.5453));
    vec2 offset = vec2(glitch * 0.02 * sin(u_time * 25.0), 0.0);

    float r = Texel(texture, texture_coords + offset).r;
    float g = Texel(texture, texture_coords).g;
    float b = Texel(texture, texture_coords - offset).b;
    float a = Texel(texture, texture_coords).a;

    if (a < 0.01) { return vec4(0.0); }

    return vec4(vec3(r, g, b) * color.rgb, a * color.a);
}
