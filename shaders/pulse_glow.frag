// shaders/pulse_glow.frag
// Pulsing aura / glow shader. Animates brightness/glow using u_time.

extern float u_time;

vec4 effect(vec4 color, Image texture, vec2 texture_coords, vec2 screen_coords) {
    vec4 tex = Texel(texture, texture_coords);
    if (tex.a < 0.01) { return vec4(0.0); }

    // Pulsing brightness factor (sin wave between 0.85 and 1.25)
    float pulse = 1.05 + 0.20 * sin(u_time * 3.0);
    
    // Warm golden/bright aura overlay
    vec3 glow = tex.rgb * pulse;
    
    return vec4(glow * color.rgb, tex.a * color.a);
}
