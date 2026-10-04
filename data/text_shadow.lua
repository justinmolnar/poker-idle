-- data/text_shadow.lua
--
-- The hard drop shadow under every printed string (services/TextShadow):
-- a solid copy of the text, offset down and to the right, drawn first.
-- The offset scales with the font: `char_frac` of the width of a "0" in
-- that font, rounded, never under `min_px`. The shadow takes the text's own
-- alpha times `alpha`, so text that fades leaves no shadow behind.
return {
    enabled   = true,
    color     = { 0, 0, 0 },
    alpha     = 1.0,
    char_frac = 0.3,
    min_px    = 1,
}
