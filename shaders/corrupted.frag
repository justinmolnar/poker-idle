// shaders/corrupted.frag
// A corrupted item in the room: the sprite is still itself, but wrong.
// Horizontal bands of pixels tear sideways and re-settle, colour splits
// into channels at the tears, a slow violet stain crawls through it, and
// now and then a band inverts. Alpha is kept from the untouched texel so
// the silhouette stays the item's own (the room's glow and hit test rely
// on it).

extern float u_time;

float hash(float n) { return fract(sin(n) * 43758.5453); }

vec4 effect(vec4 color, Image texture, vec2 uv, vec2 screen_coords) {
    vec4 base = Texel(texture, uv);
    if (base.a < 0.01) { return vec4(0.0); }

    // Bands: 12 rows of tearing, each with its own timing.
    float band  = floor(uv.y * 12.0);
    float seed  = hash(band + floor(u_time * 6.0) * 0.37);
    float tear  = step(0.78, seed) * (seed - 0.78) * 0.45;      // most bands hold still
    float dir   = step(0.5, hash(band * 3.1 + floor(u_time * 6.0))) * 2.0 - 1.0;
    vec2 off    = vec2(tear * dir, 0.0);

    vec4 r = Texel(texture, uv + off);
    vec4 g = Texel(texture, uv);
    vec4 b = Texel(texture, uv - off);
    vec3 rgb = vec3(r.r, g.g, b.b);

    // A band inverts, briefly.
    float inv = step(0.965, hash(band * 7.7 + floor(u_time * 4.0)));
    rgb = mix(rgb, 1.0 - rgb, inv);

    // Each band carries its own colour damage, drifting over time: a hue
    // rotation (channels swap around), a tint pushed toward one channel,
    // and some bands go flat and grey. Mostly gentle; a few bands are loud.
    float slot   = floor(u_time * 2.5);
    float cseed  = hash(band * 5.3 + slot * 0.71);
    float amount = smoothstep(0.35, 1.0, cseed);                 // how damaged this band is
    vec3 rot     = vec3(rgb.g, rgb.b, rgb.r);                     // channels rotated
    vec3 rot2    = vec3(rgb.b, rgb.r, rgb.g);
    float which  = hash(band * 2.9 + slot);
    vec3 shifted = which < 0.5 ? rot : rot2;
    rgb = mix(rgb, shifted, amount * 0.8);
    vec3 tint = vec3(step(0.66, which), step(0.33, which) * step(which, 0.66), step(which, 0.33));
    rgb = mix(rgb, rgb * (0.55 + tint * 0.9), amount * 0.6);
    float grey = dot(rgb, vec3(0.3, 0.59, 0.11));
    rgb = mix(rgb, vec3(grey), step(0.9, cseed) * 0.7);

    // The stain: a slow violet wash that moves through the sprite.
    float stain = 0.5 + 0.5 * sin(uv.y * 9.0 - u_time * 1.7 + uv.x * 4.0);
    stain = smoothstep(0.55, 0.95, stain) * 0.55;
    rgb = mix(rgb, vec3(0.62, 0.28, 0.85) * (0.4 + 0.6 * dot(rgb, vec3(0.33))), stain);

    // Dropout: a few pixels go dark.
    float drop = step(0.985, hash(floor(uv.x * 64.0) * 13.0 + floor(uv.y * 64.0) * 7.0 + floor(u_time * 10.0)));
    rgb *= 1.0 - drop * 0.85;

    return vec4(rgb * color.rgb, base.a * color.a);
}
