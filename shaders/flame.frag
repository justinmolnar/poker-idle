// shaders/flame.frag
//
// The heater's fire: animated flame tongues rising along the bottom of a
// heated table panel. Used by views/TablePanelEffects.drawStatusFire.
//
// Deliberately cartoon fire, not photoreal: the flame field is quantized
// to chunky cells (matching the game's pixel art) and the heat maps to
// four HARD color bands — deep red edge, orange body, yellow heart,
// white-hot base — so it reads as FIRE at a glance from across a board
// of twelve tables, the way Balatro's does.
//
// Drawn as a plain rectangle strip along the panel's felt bottom with
// this shader bound. tex_coords (0..1 across the strip) drive the shape:
// y = 1 is the base of the fire, y = 0 the highest a tongue can lick.
// Everything above the flame body returns alpha 0, so no scissor needed.
//
// Uniforms:
//   u_time      — seconds; scrolls the noise field upward and sways it
//   u_intensity — 0..1 overall alpha (caller fades the last half-second)
//   u_seed      — per-panel phase so neighbouring fires don't march in step
//   u_cells     — vec2 quantize grid (cols, rows): the pixel-art cell count

extern float u_time;
extern float u_intensity;
extern float u_seed;
extern vec2  u_cells;

float hash(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7)) + u_seed) * 43758.5453);
}

float vnoise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    float a = hash(i);
    float b = hash(i + vec2(1.0, 0.0));
    float c = hash(i + vec2(0.0, 1.0));
    float d = hash(i + vec2(1.0, 1.0));
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

float fbm(vec2 p) {
    return 0.55 * vnoise(p)
         + 0.30 * vnoise(p * 2.17)
         + 0.15 * vnoise(p * 4.31);
}

vec4 effect(vec4 color, Image tex, vec2 tc, vec2 sc) {
    // Chunky cells first — every decision below happens per-cell, so the
    // tongues have hard pixel edges instead of smooth gradients.
    vec2 uv = (floor(tc * u_cells) + 0.5) / u_cells;

    // Height above the base: 0.0 at the bottom edge, 1.0 at the strip top.
    float h = 1.0 - uv.y;

    // The flame field: noise scrolling upward, with a slow sideways sway
    // so the tongues lean and recover instead of boiling in place.
    vec2 p = vec2(uv.x * 7.0 + sin(u_time * 0.8 + u_seed) * 0.6,
                  uv.y * 2.6 + u_time * 1.9);
    float n = fbm(p);

    // Heat: strong at the base, eaten by height, carried higher where the
    // noise says a tongue is. A slow flicker keeps the whole line alive.
    float flick = 0.9 + 0.1 * sin(u_time * 6.0 + uv.x * 20.0 + u_seed);
    float heat  = (n * 1.45 - h * (1.05 + 0.35 * h)) * flick;

    if (heat <= 0.02) {
        return vec4(0.0, 0.0, 0.0, 0.0);
    }

    // Four hard bands, hottest last. The steps are what make it cartoon.
    // Pulled ~35% toward their own luminance: ember tones, not neon —
    // fire that sits IN the scene instead of on top of it.
    vec3 col = vec3(0.57, 0.19, 0.12);                    // muted red edge
    if (heat > 0.18) { col = vec3(0.80, 0.43, 0.21); }    // dusty orange
    if (heat > 0.38) { col = vec3(0.91, 0.73, 0.34); }    // sanded yellow
    if (heat > 0.60) { col = vec3(0.97, 0.94, 0.78); }    // pale hot base

    // Translucent throughout — the felt reads through the flames.
    float a = (heat > 0.08) ? 0.55 : 0.30;
    return vec4(col, a * u_intensity);
}
