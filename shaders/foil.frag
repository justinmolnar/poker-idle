// shaders/foil.frag
//
// The capstone foil: a maxed deck's back. A Balatro holographic: the art
// stays itself, readable at full colour, and three things move over it,
// all built on flowing noise so nothing draws a straight line:
//
//   1. an oil-slick iridescence, domain-warped so its colours swirl in
//      curved regions and cycle through the whole spectrum;
//   2. a broad diagonal SHINE that sweeps across every couple of seconds,
//      the way a real foil card flashes when it tilts;
//   3. SPARKLES: pinprick glints that twinkle in and out, white-hot.
//
// Only views/DeckArt uses this, at the cap. Sends u_time each frame.

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

    float t = u_time * 0.25;

    // ── The art, as it is ────────────────────────────────────────────
    vec3  art = tex.rgb;
    float L   = luma(art);

    // ── Oil-slick iridescence, full spectrum, swirling ───────────────
    vec2  q   = uv * 3.2;
    float n1  = fbm(q + vec2(t, -t * 0.7));
    float n2  = fbm(q + 3.0 * vec2(n1, n1) + vec2(-t * 0.6, t * 0.5));
    float hue = fract(n2 * 2.6 + t * 0.20 + uv.x * 0.15 - uv.y * 0.10);
    vec3  holo = hsv2rgb(vec3(hue, 1.0, 1.0));

    // ── The sweep: a soft diagonal bar crossing every ~2.4 s ──────────
    float d     = uv.x * 0.8 + uv.y * 0.6;
    float sweep = fract(u_time * 0.42);
    float bar   = 1.0 - smoothstep(0.0, 0.18, abs(d - (sweep * 1.6 - 0.3)));
    // Wobble the bar's edge with noise so it isn't a ruler.
    bar *= 0.7 + 0.3 * fbm(uv * 6.0 + vec2(t * 2.0, 0.0));

    // ── Sparkles: pinpricks that twinkle ─────────────────────────────
    vec2  cell = floor(uv * 34.0);
    float seed = hash(cell);
    float tw   = 0.5 + 0.5 * sin(u_time * (3.0 + seed * 5.0) + seed * 40.0);
    vec2  cuv  = fract(uv * 34.0) - 0.5;
    float dot_ = 1.0 - smoothstep(0.0, 0.16, length(cuv));
    float spark = step(0.82, seed) * dot_ * pow(tw, 3.0);

    // ── Composite ────────────────────────────────────────────────────
    // A film of iridescence screened over the art (stronger on its lit
    // areas, never hiding it), the sweep as a bright band tinted by the
    // local colour, sparkles on top. The art stays recognisable.
    float film    = 0.30 + 0.25 * L;
    vec3  screenB = 1.0 - (1.0 - art) * (1.0 - holo * film);
    vec3  out_rgb = mix(art, screenB, 0.6);
    out_rgb += bar * mix(holo, vec3(1.0), 0.7) * 0.7;
    out_rgb += spark * 1.2;

    return vec4(out_rgb * color.rgb, tex.a * color.a);
}
