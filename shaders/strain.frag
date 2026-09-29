// shaders/strain.frag
//
// The focus strain over the finished frame: the further the board is over
// its focus cap, the more the whole screen loses focus — colour drains,
// the edges close in, the light drops — except a feathered hole over the
// OVER FOCUS readout in the rail, which stays sharp and red so the eye
// lands on the cause. u_amount 0 = untouched, 1 = the floor. u_hole is
// {x, y, w, h} in source pixels; u_size the source size.

extern float u_amount;
extern vec4  u_hole;
extern vec2  u_size;

vec4 effect(vec4 color, Image texture, vec2 uv, vec2 screen_coords) {
    vec4 px = Texel(texture, uv) * color;
    vec2 p  = uv * u_size;
    // Distance outside the hole (0 inside), feathered over 28px.
    float dx = max(u_hole.x - p.x, p.x - (u_hole.x + u_hole.z));
    float dy = max(u_hole.y - p.y, p.y - (u_hole.y + u_hole.w));
    float dist = max(max(dx, dy), 0.0);
    float keep = 1.0 - smoothstep(0.0, 28.0, dist);
    float a = clamp(u_amount, 0.0, 1.0) * (1.0 - keep);
    // Colour drains.
    float gray = dot(px.rgb, vec3(0.299, 0.587, 0.114));
    vec3 c = mix(px.rgb, vec3(gray), a * 0.85);
    // The edges close in.
    vec2 q = uv * 2.0 - 1.0;
    float vig = smoothstep(0.45, 1.35, length(q));
    c *= 1.0 - a * 0.65 * vig;
    // The light drops.
    c *= 1.0 - a * 0.22;
    return vec4(c, px.a);
}
