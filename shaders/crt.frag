// shaders/crt.frag
//
// The House's security monitor: the room's picture as a CRT shows it.
// Barrel curvature (the tube bulges; the corners round off into black),
// scanlines, a faint shadow mask, a little RGB fringe toward the edges, an
// inner vignette, a camera's washed colour, grain, a slow rolling bar and
// a touch of flicker. u_anim 0 holds the moving parts still (the motion
// setting). Drawn over the screen rect, sampling the frame-sized picture
// (views/CrtMonitor).

extern float u_time;    // seconds
extern vec2  u_res;     // the screen rect, pixels
extern float u_curve;   // barrel strength (0.08 reads as a tube)
extern float u_anim;    // 1 animated, 0 still
extern vec4  u_rect;    // the picture's part on the tube, in texture uv (x, y, w, h)

float rand(vec2 co) {
    return fract(sin(dot(co, vec2(12.9898, 78.233))) * 43758.5453);
}

vec4 effect(vec4 color, Image tex, vec2 uv, vec2 sc) {
    // The tube's face fills the screen rect up to the bezel, its corners
    // rounded off; a soft edge.
    vec2  local = (uv - u_rect.xy) / u_rect.zw;
    vec2  q    = local * 2.0 - 1.0;
    float rad  = 0.07;
    vec2  e    = abs(q) - vec2(1.0 - rad);
    float d    = length(max(e, 0.0)) - rad;
    float face = 1.0 - smoothstep(-0.010, 0.0, d);
    if (face <= 0.0) return vec4(0.0, 0.0, 0.0, 0.0);

    // Barrel, inside the face: the middle of the picture bulges toward the
    // viewer while the corners still reach the corners, so the picture
    // runs right to the bezel (no black band round it).
    float r2 = dot(q, q);
    vec2 qd  = q * (1.0 + u_curve * r2) / (1.0 + u_curve * 2.0);
    vec2 duv = u_rect.xy + (qd * 0.5 + 0.5) * u_rect.zw;

    // A little colour fringe, stronger toward the edges.
    vec2 off = qd * 0.0022 * r2 * u_rect.zw;
    float rr = Texel(tex, clamp(duv + off, 0.0, 1.0)).r;
    vec4  gg = Texel(tex, clamp(duv, 0.0, 1.0));
    float bb = Texel(tex, clamp(duv - off, 0.0, 1.0)).b;
    vec3 c = vec3(rr, gg.g, bb);

    // A camera's colour: washed toward grey, a hair cool.
    float gray = dot(c, vec3(0.299, 0.587, 0.114));
    c = mix(c, vec3(gray), 0.28) * vec3(0.96, 1.01, 1.03);

    // Scanlines, one every 3 screen pixels, and a faint shadow mask.
    float sl   = sin(local.y * u_res.y * 1.0472);
    float line = 0.80 + 0.20 * sl * sl;
    float mask = 0.94 + 0.06 * sin(sc.x * 2.0944);
    c *= line * mask;

    // The inner vignette of the tube.
    c *= 1.0 - 0.50 * smoothstep(0.35, 1.45, length(q));

    // The moving parts: grain, a slow bright band rolling down, flicker.
    float t = u_time * u_anim;
    c += (rand(duv * u_res + vec2(t * 37.0, t * 11.0)) - 0.5) * 0.07 * u_anim;
    float band = fract(local.y - t * 0.11) - 0.5;
    c *= 1.0 + 0.07 * exp(-band * band * 70.0) * u_anim;
    c *= 1.0 + 0.012 * sin(t * 58.0) * u_anim;

    // A faint glow off the glass so the dark reads as a lit tube.
    c += vec3(0.010, 0.013, 0.014);

    return vec4(c * face, face) * color;
}
