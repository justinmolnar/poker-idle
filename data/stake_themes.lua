-- data/stake_themes.lua
--
-- Per-stake visual identity. Each stake_id maps to a palette table that
-- views/TablePanel.lua reads to render felt color, panel border, header
-- chrome, and a chip-color tint multiplier.
--
-- T1 should look cheap and dim; T6 should look like the Bellagio. Climbing
-- stakes is a visible upgrade — the player should feel the room change
-- around them as they sit at higher buy-ins.
--
-- Schema (all fields optional; views fall back to default Theme tokens
-- when a key is absent):
--   {
--     felt_tint    = { r, g, b, a },   -- felt fill, alpha-blended
--     border_color = { r, g, b, a },   -- panel-rect border line color
--     border_width = number,           -- panel-rect border line width
--     header_bg    = { r, g, b, a },   -- header strip fill
--     chip_tint    = { r, g, b },      -- multiplied into chip body color
--                                       -- ({1,1,1} = no tint, identity)
--   }

return {
    -- T1 — $0.01/$0.02. Scuffed cheap-card-room olive. Dim, plain border.
    s001 = {
        felt_tint    = { 0.20, 0.30, 0.18, 0.40 },
        border_color = { 0.35, 0.30, 0.22, 0.85 },
        border_width = 1,
        header_bg    = { 0.18, 0.18, 0.16, 0.92 },
        chip_tint    = { 0.85, 0.85, 0.80 },             -- desaturated, dim
    },
    -- T2 — $0.05/$0.10. Cleaner green, the standard cash-game look.
    s002 = {
        felt_tint    = { 0.12, 0.42, 0.22, 0.55 },
        border_color = { 0.55, 0.45, 0.25, 0.90 },        -- brass-ish
        border_width = 1,
        header_bg    = { 0.16, 0.20, 0.16, 0.94 },
        chip_tint    = { 0.95, 0.95, 0.92 },
    },
    -- T3 — $0.50/$1. Blue felt, brass trim. More upscale.
    s003 = {
        felt_tint    = { 0.12, 0.28, 0.52, 0.58 },
        border_color = { 0.70, 0.55, 0.30, 0.95 },        -- brass
        border_width = 2,
        header_bg    = { 0.14, 0.18, 0.26, 0.94 },
        chip_tint    = { 1.00, 1.00, 1.00 },
    },
    -- T4 — $5/$10. Deeper green, brighter accents.
    s004 = {
        felt_tint    = { 0.10, 0.48, 0.28, 0.62 },
        border_color = { 0.85, 0.70, 0.35, 0.95 },        -- bright brass
        border_width = 2,
        header_bg    = { 0.14, 0.22, 0.18, 0.95 },
        chip_tint    = { 1.05, 1.05, 1.00 },               -- slight warm boost
    },
    -- T5 — $50/$100. Purple-felt high-roller room.
    s005 = {
        felt_tint    = { 0.28, 0.12, 0.42, 0.62 },
        border_color = { 0.85, 0.55, 1.00, 0.95 },        -- neon violet
        border_width = 3,
        header_bg    = { 0.18, 0.10, 0.24, 0.96 },
        chip_tint    = { 1.10, 1.05, 1.20 },
    },
    -- T6 — $500/$1000. Black-and-gold. The big show.
    s006 = {
        felt_tint    = { 0.06, 0.06, 0.12, 0.78 },
        border_color = { 1.00, 0.85, 0.30, 1.00 },        -- gold
        border_width = 4,
        header_bg    = { 0.10, 0.08, 0.04, 0.98 },
        chip_tint    = { 1.20, 1.10, 0.90 },               -- warm gold cast
    },
}
