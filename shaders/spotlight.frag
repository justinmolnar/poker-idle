// shaders/spotlight.frag
//
// The story's dim with its targets cut out, in one pass over the frame:
// a dark overlay everywhere except inside each target, with a dithered
// falloff at the edge (no banding), a warm light bleeding out of the hole
// onto the dim around it, and a thin bright edge with a highlight that
// travels round the hole. Up to 8 targets: rects (x, y, w, h) or circles
// (x, y, -radius, 0). u_anim 0 holds the travel and the breathing still.

#define MAX_HOLES 8

extern vec4  u_holes[MAX_HOLES];
extern float u_n;
extern float u_dim;      // the overlay's alpha away from any hole
extern vec3  u_dim_rgb;  // its colour
extern vec3  u_glow;     // the light's colour
extern float u_pad;      // px kept clear round a target
extern float u_feather;  // px the dim takes to arrive
extern float u_time;
extern float u_anim;

float sdRect(vec2 p, vec4 h, float r) {
    vec2 c  = h.xy + h.zw * 0.5;
    vec2 d  = abs(p - c) - h.zw * 0.5 + vec2(r);
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - r;
}

float rand(vec2 co) {
    return fract(sin(dot(co, vec2(12.9898, 78.233))) * 43758.5453);
}

vec4 effect(vec4 color, Image tex, vec2 uv, vec2 p) {
    float d = 1e9;
    vec2  nearest = p;
    for (int i = 0; i < MAX_HOLES; i++) {
        if (float(i) >= u_n) break;
        vec4 h = u_holes[i];
        float sd;
        vec2  c;
        if (h.z < 0.0) { c = h.xy; sd = length(p - c) + h.z; }
        else           { c = h.xy + h.zw * 0.5; sd = sdRect(p, h, 6.0); }
        if (sd < d) { d = sd; nearest = c; }
    }
    float t = u_time * u_anim;
    float breathe = 1.0 + 0.5 * sin(t * 3.0) * u_anim;
    float edge_d = d - u_pad * breathe;         // 0 at the clear edge

    // The dim arrives over u_feather px, dithered so it never bands.
    float dither = (rand(p) - 0.5) * 0.12 * u_feather;
    float dimA = u_dim * smoothstep(0.0, u_feather, edge_d + dither);

    // Light bleeding out of the hole onto the dim.
    float bleed = exp(-max(edge_d, 0.0) / (u_feather * 0.55)) * step(0.0, edge_d);
    float glowA = bleed * (0.26 + 0.05 * sin(t * 3.0) * u_anim);

    // The edge: a thin bright line with a highlight travelling round it.
    vec2  rel = p - nearest;
    float ang = atan(rel.y, rel.x);
    float travel = 0.55 + 0.45 * cos(ang - t * 1.6);
    float edge = (1.0 - smoothstep(0.0, 2.0, abs(edge_d))) * (0.35 + 0.65 * travel);

    // Compose: the dim, lit by the bleed, with the edge on top.
    float a = max(dimA * (1.0 - glowA * 0.5), glowA * 0.35);
    vec3  c = mix(u_dim_rgb, u_glow, clamp(glowA * 1.6, 0.0, 1.0));
    a = max(a, edge * 0.9);
    c = mix(c, vec3(1.0, 0.96, 0.85), edge);
    if (edge_d <= 0.0) { a = max(edge * 0.9, 0.0); }   // inside: clear, but the edge line
    return vec4(c, a) * color;
}
