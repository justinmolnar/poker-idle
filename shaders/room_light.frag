// shaders/room_light.frag
//
// One thing in the room making light (views/RoomLighting, data/room_lights
// emitters), drawn additively into the lightmap as a quad: a pool on the
// floor at the object's foot — an iso ellipse, bright under the thing,
// thinning to a dithered rim (no banding) — and the thing itself lit, a
// taller soft halo about its body, hot towards white at the source. The
// rim wanders a little with time (u_anim 0 holds it still).
//
// Everything is in the quad's own 0..1 (tex_coords), so the caller sizes
// the quad and says where the foot and the body are inside it.

extern vec3  u_color;
extern float u_alpha;
extern vec2  u_pool_c;   // the foot: the pool's centre
extern vec2  u_pool_r;   // the pool's radii (x wide, y about half: the floor seen from the iso angle)
extern vec2  u_body_c;   // the body's centre
extern vec2  u_body_r;   // the body's radii
extern float u_time;
extern float u_anim;

float rand(vec2 co) {
    return fract(sin(dot(co, vec2(12.9898, 78.233))) * 43758.5453);
}

vec4 effect(vec4 color, Image tex, vec2 uv, vec2 p) {
    float dither = (rand(p) - 0.5) * 0.10;

    // The pool: full under the foot, gone at the rim, squared so the tail
    // is a wash rather than a disc.
    vec2  dp = (uv - u_pool_c) / u_pool_r;
    float rp = length(dp);
    float wobble = 1.0 + u_anim * 0.035 * sin(u_time * 2.1 + dp.x * 2.5) ;
    float pool = 1.0 - smoothstep(0.10, 1.0, rp * wobble + dither);
    pool = pool * pool;

    // The body: the object in its own light.
    vec2  db = (uv - u_body_c) / u_body_r;
    float rb = length(db);
    float body = 1.0 - smoothstep(0.0, 1.0, rb + dither * 0.6);
    body = body * body;

    // The spill: the same pool, wider and faint, so the light reaches
    // across the floor instead of stopping at a rim.
    float spill = 1.0 - smoothstep(0.0, 1.0, rp * 0.55 + dither);
    spill = spill * spill * spill;

    // Hot at the source. The thing itself is lit near fully whatever its
    // reach: a monitor in a dark room is a bright screen first, a pool
    // second. The pool and the spill carry the item's own strength.
    float core = clamp(1.0 - rb * 2.4, 0.0, 1.0);
    vec3  c = mix(u_color, vec3(1.0, 0.98, 0.92), core * 0.45);
    float lit = max(u_alpha, 0.85);
    float a = max(max(pool * u_alpha * 1.6, spill * 0.5 * u_alpha), body * lit);
    return vec4(c, min(a, 1.0)) * color;
}
