// shaders/radial_glow.frag
//
// Two-zone radial-glow halo for jackpot wins. Used by views/TablePanel.lua.
//
// Inner zone: tight bright core that pushes the color toward white-hot
//             so the center reads as a "flash" rather than a tint.
// Outer zone: long soft halo that bleeds beyond the panel rect.
//
// Bound by drawing a rectangle larger than the panel with the shader
// active and blend-mode ("add", "alphamultiply"). The rect's normalized
// tex_coords (0..1) drive the radial falloff — works the same on both
// native LÖVE and love.js (the previous screen_coords / u_origin
// approach broke on the web build because Emscripten's SDL2 port
// reports gl_FragCoord in canvas pixels while Lua's love.graphics.*
// returns logical pixels, so the two coord spaces didn't agree).
//
// Uniforms:
//   u_color     — vec3 — halo color (caller picks gold/etc.)
//   u_intensity — float 0..1 — overall alpha multiplier (caller decays it)

extern vec3  u_color;
extern float u_intensity;

vec4 effect(vec4 color, Image tex, vec2 tex_coords, vec2 screen_coords) {
    // tex_coords = 0..1 across the rect being drawn. Recenter to
    // -1..1, so r ≈ 1.0 at edges, ~1.4 at corners.
    vec2 d = (tex_coords - vec2(0.5, 0.5)) * 2.0;
    float r = length(d);

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
