// shaders/rainbow_shift.frag
// Smoothly cycles sprite colors through a rainbow spectrum over time.

extern float u_time;

vec3 hsv2rgb(vec3 c) {
    vec4 K = vec4(1.0, 2.0/3.0, 1.0/3.0, 3.0);
    vec3 p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www);
    return c.z * mix(K.xxx, clamp(p - K.xxx, 0.0, 1.0), c.y);
}

vec4 effect(vec4 color, Image texture, vec2 texture_coords, vec2 screen_coords) {
    vec4 tex = Texel(texture, texture_coords);
    if (tex.a < 0.01) { return vec4(0.0); }

    // Cycle hue over time
    float hue = fract(u_time * 0.2 + texture_coords.x * 0.2);
    vec3 rainbow = hsv2rgb(vec3(hue, 0.7, 1.0));

    // Blend rainbow tint onto texture luminance
    float luma = dot(tex.rgb, vec3(0.299, 0.587, 0.114));
    vec3 out_rgb = mix(tex.rgb, rainbow * luma * 1.2, 0.50);

    return vec4(out_rgb * color.rgb, tex.a * color.a);
}
