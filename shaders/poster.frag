// shaders/poster.frag
//
// THE HOUSE's portrait, printed: a photograph (assets/sprites/house/
// photo.png) put through the game's own medium — chunky pixels, a few
// colours, the golden hour, the windows lit because it is always home —
// so it hangs beside pixel furniture as a print and not a photo. One pass
// over the quad the poster is drawn on:
//   pixels    the picture is sampled on a grid of u_cells art pixels,
//             each a flat block (nearest, at the cell's centre)
//   the hour  graded by what each block IS: the sky (blue) becomes the
//             sunset, amber at the horizon and plum above, clouds lit
//             from below; the green becomes the hillside's olive; the
//             house's white goes cream in the low light
//   windows   u_win rects are lit gold, a pane cross in them and a halo
//             on the wall around them
//   colours   each channel held to u_levels steps, a touch of ordered
//             dither so the sky does not band
//   the paper the corners fall off a little, the way a print does
//
// u_crop is the part of the photo the poster shows (x, y, w, h in 0..1).

extern vec2  u_cells;
extern float u_levels;
extern float u_warm;      // 0 the photo's own colour .. 1 the full grade
extern vec4  u_crop;
extern vec4  u_win[2];    // lit windows, in photo 0..1 (x, y, w, h)
extern vec4  u_roof;      // the roof's band, in photo 0..1: what is neither sky nor green there goes gold

const vec3 SKY_TOP   = vec3(0.45, 0.27, 0.42);
const vec3 SKY_HORIZ = vec3(0.99, 0.84, 0.55);
const vec3 CLOUD_LIT = vec3(0.99, 0.83, 0.68);
const vec3 TREE      = vec3(0.35, 0.46, 0.26);
const vec3 MEADOW    = vec3(0.50, 0.55, 0.32);
const vec3 WALL_LIT  = vec3(0.94, 0.88, 0.74);
const vec3 WINDOW    = vec3(1.00, 0.88, 0.52);
const vec3 PANE      = vec3(0.40, 0.29, 0.23);
const vec3 ROOF      = vec3(0.93, 0.75, 0.30);   // the House's gold

float bayer(vec2 p) {
    vec2 q = floor(mod(p, 4.0));
    float i = q.x + q.y * 4.0;
    float m = 0.0;
    if (i == 0.0) m = 0.0;  else if (i == 1.0) m = 8.0;  else if (i == 2.0) m = 2.0;  else if (i == 3.0) m = 10.0;
    else if (i == 4.0) m = 12.0; else if (i == 5.0) m = 4.0;  else if (i == 6.0) m = 14.0; else if (i == 7.0) m = 6.0;
    else if (i == 8.0) m = 3.0;  else if (i == 9.0) m = 11.0; else if (i == 10.0) m = 1.0; else if (i == 11.0) m = 9.0;
    else if (i == 12.0) m = 15.0; else if (i == 13.0) m = 7.0; else if (i == 14.0) m = 13.0; else m = 5.0;
    return (m + 0.5) / 16.0;
}

vec4 effect(vec4 color, Image tex, vec2 uv, vec2 p) {
    vec2 cell = floor(uv * u_cells);
    vec2 cuv  = (cell + 0.5) / u_cells;
    vec2 suv  = u_crop.xy + cuv * u_crop.zw;      // where in the photo
    vec3 c = Texel(tex, suv).rgb;

    float lum = dot(c, vec3(0.299, 0.587, 0.114));
    float mx = max(c.r, max(c.g, c.b));
    float mn = min(c.r, min(c.g, c.b));
    float sat = (mx > 0.001) ? (mx - mn) / mx : 0.0;
    // The sky is pale: blue over red is the tell, however washed out.
    float blue  = clamp((c.b - c.r) * 6.0, 0.0, 1.0);
    float green = clamp((c.g - max(c.r, c.b)) * 4.0, 0.0, 1.0) * clamp(sat * 3.0, 0.0, 1.0);

    // The sky: the sunset by height, clouds lit from below.
    vec3 sky = mix(SKY_HORIZ, SKY_TOP, clamp((0.42 - suv.y) * 2.6, 0.0, 1.0));
    vec3 skyc = mix(sky, CLOUD_LIT, clamp((lum - 0.6) * 2.5, 0.0, 1.0));
    // The green: the hillside's olive, keeping the photo's light and dark.
    vec3 greenc = mix(TREE, MEADOW, clamp((lum - 0.3) * 2.0, 0.0, 1.0));
    // Everything else (the house, the roof, the path): the low light's cream.
    vec3 restc = c * vec3(1.03, 0.97, 0.87);
    restc = mix(restc, WALL_LIT, clamp((lum - 0.7) * 2.0, 0.0, 1.0) * 0.5);

    // The roof: gold, the House's. What sits in its band and is neither
    // sky nor leaf, keeping the shingles' light and dark.
    vec2 rr = (suv - u_roof.xy) / u_roof.zw;
    float on_roof = (rr.x >= 0.0 && rr.x <= 1.0 && rr.y >= 0.0 && rr.y <= 1.0) ? 1.0 : 0.0;
    vec3 roofc = ROOF * (0.45 + lum * 1.3);

    vec3 graded = restc;
    graded = mix(graded, roofc, on_roof * (1.0 - blue) * (1.0 - green) * 0.85);
    graded = mix(graded, greenc, green);
    graded = mix(graded, skyc, blue);
    c = mix(c, graded, u_warm);

    // The windows: lit, a pane cross, a halo on the wall around them.
    float win = 0.0;
    for (int i = 0; i < 2; i++) {
        vec4 r = u_win[i];
        if (r.z <= 0.0) continue;
        vec2 rel = (suv - r.xy) / r.zw;
        if (rel.x >= 0.0 && rel.x <= 1.0 && rel.y >= 0.0 && rel.y <= 1.0) {
            float cross = (abs(rel.x - 0.5) < 0.05 || abs(rel.y - 0.5) < 0.05) ? 1.0 : 0.0;
            c = mix(WINDOW, PANE, cross);
            win = 1.0 - cross;
        } else {
            vec2 d = max(abs(rel - 0.5) - 0.5, 0.0) * r.zw / u_crop.zw * u_cells / 6.0;
            float halo = exp(-dot(d, d) * 1.5) * 0.35;
            c = mix(c, WINDOW, halo * u_warm);
        }
    }

    // The colours, held to steps, dithered on the art grid.
    float d = (bayer(cell) - 0.5) * 0.5 / u_levels;
    c = floor(c * u_levels + d + 0.5) / u_levels;

    // The paper, and the room's light: the game is dark, so the print is
    // a print on a dim wall, not a lit screen — brought down overall, the
    // corners more so. The windows keep their light (they are the light).
    vec2 v = cuv - 0.5;
    c *= (1.0 - 0.34 * dot(v, v)) * mix(0.72, 1.0, win);

    return vec4(c, 1.0) * color;
}
