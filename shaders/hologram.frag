// shaders/hologram.frag
// Sci-fi holographic scanline shader with cyan/blue tinting and moving scanlines.

extern float u_time;

vec4 effect(vec4 color, Image texture, vec2 texture_coords, vec2 screen_coords) {
    vec4 tex = Texel(texture, texture_coords);
    if (tex.a < 0.01) { return vec4(0.0); }

    // Moving horizontal scanlines
    float scanline = sin((texture_coords.y + u_time * 0.15) * 120.0) * 0.15 + 0.85;

    // Convert to cyan/blue sci-fi hologram color tint
    float gray = dot(tex.rgb, vec3(0.299, 0.587, 0.114));
    vec3 holo = vec3(gray * 0.3, gray * 0.85, gray * 1.0) * scanline;
    
    // Subtle alpha pulse
    float alpha = tex.a * (0.85 + 0.15 * sin(u_time * 4.0));

    return vec4(holo * color.rgb, alpha * color.a);
}
