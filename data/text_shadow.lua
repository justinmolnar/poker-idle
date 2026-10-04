-- data/text_shadow.lua
--
-- The edge under every printed string (services/TextShadow): solid copies
-- of the text stepped down and to the right, one pixel at a time, so it
-- sits ON the letters like a border on their bottom-right side rather than
-- a second copy floating off them. Its depth scales with the font:
-- `char_frac` of the width of a "0", rounded, never under `min_px`. It takes
-- the text's own alpha times `alpha`, so fading text leaves nothing behind.
-- Text darker than `skip_below` (luminance 0..1) gets none: a dark edge on
-- dark text only reads as the text twice.
return {
    enabled   = true,
    color     = { 0, 0, 0 },
    alpha     = 1.0,
    char_frac = 0.12,
    skip_below = 0.4,
    min_px    = 1,
}
