// shaders/room_light.frag
//
// One thing in the room making light (views/RoomLighting, data/room_lights
// emitters), drawn additively into the lightmap as a quad. Two soft
// gaussian falloffs — a light from a small source, brightest at it and
// gone fast, never a disc with a rim:
//   the pool   on a floor item, at its foot, an iso ellipse on the floor;
//              on a wall item, around it on the wall
//   the body   the thing itself lit, near fully, hot towards white at the
//              source
// Dithered so nothing bands, and faded to nothing at the quad's own edge
// so the quad never shows. The glow breathes a little (u_anim 0 holds).
//
// Everything is in the quad's own 0..1 (tex_coords); the caller sizes the
// quad to hold both falloffs and says where their centres and radii are
// (a radius is where the falloff has faded to about 5%).

extern vec3  u_color;
extern float u_alpha;
extern vec2  u_pool_c;
extern vec2  u_pool_r;
extern vec2  u_body_c;
extern vec2  u_body_r;
extern float u_time;
extern float u_anim;

float rand(vec2 co) {
    return fract(sin(dot(co, vec2(12.9898, 78.233))) * 43758.5453);
}

float falloff(float r) { return exp(-r * r * 3.0); }   // ~5% at r = 1

vec4 effect(vec4 color, Image tex, vec2 uv, vec2 p) {
    float dither = (rand(p) - 0.5) * 0.06;

    float rp   = length((uv - u_pool_c) / u_pool_r) + dither;
    float pool = falloff(rp);

    float rb   = length((uv - u_body_c) / u_body_r) + dither;
    float body = falloff(rb);
    float core = falloff(rb * 1.8);

    vec3  c = mix(u_color, vec3(1.0, 0.98, 0.92), core * 0.45);
    float a = max(pool * u_alpha * 1.5, body * max(u_alpha, 0.85));
    a *= 1.0 + 0.03 * u_anim * sin(u_time * 2.1);

    // Nothing at the quad's edge, whatever the radii.
    float e = min(min(uv.x, 1.0 - uv.x), min(uv.y, 1.0 - uv.y));
    a *= smoothstep(0.0, 0.10, e);
    return vec4(c, min(a, 1.0)) * color;
}
