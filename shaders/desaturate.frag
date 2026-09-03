// shaders/desaturate.frag
//
// Uniform desaturation for the last-hand residue: a finished hand held on
// an idle felt is drawn through this so the whole scene (felt, cards,
// text, decor) goes grey together and reads as inert. u_amount 0 = full
// color, 1 = full greyscale. Shapes and text sample LÖVE's default white
// texel, so one setShader wrap covers textured and untextured draws alike.

extern float u_amount;

vec4 effect(vec4 color, Image texture, vec2 texture_coords, vec2 screen_coords) {
    vec4 px = Texel(texture, texture_coords) * color;
    float gray = dot(px.rgb, vec3(0.299, 0.587, 0.114));
    return vec4(mix(px.rgb, vec3(gray), clamp(u_amount, 0.0, 1.0)), px.a);
}
