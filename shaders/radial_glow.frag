// shaders/radial_glow.frag
//
// Two-zone radial-glow halo for jackpot wins. Used by views/TablePanel.lua.
//
// Inner zone: tight bright core that pushes the color toward white-hot
//             so the center reads as a "flash" rather than a tint.
// Outer zone: long soft halo that bleeds beyond the panel rect.
//
// Bound by drawing a rectangle larger than the panel with the shader
// active and blend-mode ("add", "alphamultiply"). Caller passes the
// rect's screen-space origin + size so we can compute local coords.
//
// Uniforms:
//   u_color     — vec3 — halo color (caller picks gold/etc.)
//   u_intensity — float 0..1 — overall alpha multiplier (caller decays it)
//   u_origin    — vec2 — screen-space top-left of the rect being drawn
//   u_size      — vec2 — pixel size of the rect

extern vec3  u_color;
extern float u_intensity;
extern vec2  u_origin;
extern vec2  u_size;

vec4 effect(vec4 color, Image tex, vec2 tex_coords, vec2 screen_coords) {
    vec2 local  = screen_coords - u_origin;
    vec2 center = u_size * 0.5;
    // Normalize so the rect's corners read r ≈ 1.4.
    vec2 d = (local - center) / u_size;
    float r = length(d) * 2.0;

    // Bright inner core: tight falloff, full alpha until r ~= 0.30, gone by 0.55.
    float core = clamp(1.0 - r * 1.8, 0.0, 1.0);
    core = core * core;

    // Soft outer halo: long falloff out to r = 1.0+.
    float halo = clamp(1.0 - r * 0.85, 0.0, 1.0);
    halo = halo * halo;

    // Color: white-hot at the center, fade to u_color in the halo.
    vec3 hot   = vec3(1.0, 1.0, 0.92);
    vec3 final = mix(u_color, hot, core);

    // Final alpha: core dominates near center, halo extends outward.
    float a = max(core * 1.0, halo * 0.55);
    return vec4(final, clamp(a * u_intensity, 0.0, 1.0));
}
