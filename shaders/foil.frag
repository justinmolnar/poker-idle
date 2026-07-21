// shaders/foil.frag
//
// Balatro-style holographic foil over the card art — a vivid oil-slick
// iridescence with a live moving shine.
//
// Built on flowing NOISE, not sines (sin(dot(uv,dir)) draws parallel lines
// that cross into a lattice — the cheap look to avoid). Domain-warped fbm
// gives smooth, curved, organic colour regions: NO straight lines, NO
// lattice, NO single sliding gradient. Two soft glare layers drift over it
// for a holographic shine. Screen-blended firmly so it clearly reads as a
// foil film on the card, while the art still shows through.

extern float u_time;

vec3 hsv2rgb(vec3 c) {
    vec4 K = vec4(1.0, 2.0/3.0, 1.0/3.0, 3.0);
    vec3 p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www);
    return c.z * mix(K.xxx, clamp(p - K.xxx, 0.0, 1.0), c.y);
}
float luma(vec3 c) { return dot(c, vec3(0.299, 0.587, 0.114)); }

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float noise(vec2 p) {
    vec2 i = floor(p), f = fract(p);
    vec2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash(i),                hash(i + vec2(1.0, 0.0)), u.x),
               mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), u.x), u.y);
}
float fbm(vec2 p) {
    float v = 0.0, a = 0.5;
    for (int k = 0; k < 4; k++) { v += a * noise(p); p *= 2.0; a *= 0.5; }
    return v;
}

vec4 effect(vec4 color, Image texture, vec2 uv, vec2 screen_coords) {
    vec4 tex = Texel(texture, uv);
    if (tex.a < 0.01) { discard; }

    float t = u_time * 0.18;              // lively but not frantic

    // ── Flowing oil-slick colour ─────────────────────────────────────
    // Domain-warp the noise with itself so the iridescence swirls in soft
    // organic regions. Enough frequency + hue range to show several vivid
    // colours across the card, still smooth (no lines).
    vec2  q   = uv * 4.0;
    float n1  = fbm(q + vec2(t, -t * 0.6));
    float n2  = fbm(q + 2.5 * vec2(n1, n1) + vec2(-t * 0.5, t * 0.4));
    float hue = fract(n2 * 1.8 + t * 0.12);
    vec3  holo = hsv2rgb(vec3(hue, 0.85, 1.0));

    // ── Live holographic shine ───────────────────────────────────────
    // Two feathered low-frequency noise peaks drifting at different
    // speeds — broad moving highlights, never sharp lines.
    float g1 = smoothstep(0.55, 0.90, fbm(uv * 2.2 + vec2(-t * 1.1, t * 0.6)));
    float g2 = smoothstep(0.60, 1.00, fbm(uv * 3.5 + vec2( t * 0.8, -t * 0.9)));
    float glare = g1 * 0.7 + g2 * 0.5;

    // ── Composite: firm foil film, art still visible ─────────────────
    vec3  art = tex.rgb;
    float L   = luma(art);

    // Screen-blend the iridescent film in strongly, brighter on lit areas.
    float irid_w  = 0.45 + 0.30 * L;
    vec3  screenB = 1.0 - (1.0 - art) * (1.0 - holo * irid_w);
    vec3  out_rgb = mix(art, screenB, 0.70);

    // Bright shine on top, tinted by the local holo colour.
    out_rgb += glare * mix(holo, vec3(1.0), 0.6) * (0.4 + 0.6 * L);

    return vec4(out_rgb * color.rgb, tex.a * color.a);
}
