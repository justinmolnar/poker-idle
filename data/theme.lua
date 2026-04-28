-- data/theme.lua
--
-- THE ONE PLACE THAT OWNS A COLOR / FONT / SIZE.
-- ──────────────────────────────────────────────
-- No file outside this one (and views/Theme.lua, which only re-points
-- references) should contain a literal `setColor(0.x, 0.y, ...)`, a raw
-- font-size number, or a hardcoded padding constant. If you find one
-- you're about to write, add a token here and reference it instead.
--
-- The audit grep that proves this:
--   rg "love\.graphics\.setColor\(\s*\d" --type lua    → only the documented
--                                          asset-tint exception below
--   rg "love\.graphics\.newFont"          --type lua    → only main.lua
--
-- Asset-tint exception:
--   When drawing an Image / Canvas / SpriteBatch / Mesh / shader-output rect
--   you usually want the asset's *baked* colors to come through unmodified —
--   that means `setColor(1, 1, 1, alpha)`. Use Theme.assetTint(alpha?) at
--   those sites instead.
--
-- ─── Two palettes ───────────────────────────────────────────────────
--
--   room   — warm, dim, mundane. The grind UI lives here. Beige/amber
--            chrome, soft borders, comfortable contrast. The room you
--            sit in for hours.
--   shove  — sparse, high-contrast, dramatic. Black/red. The terminal
--            ritual. Active only during the all-in gauntlet.
--
-- The palette IS the mode shift. ShoveState calls Theme.setActive("shove")
-- on enter; GrindState calls Theme.setActive("room"). No per-component
-- "if state == shove" branches anywhere else.
--
-- ─── Token namespaces ───────────────────────────────────────────────
--
-- Per-palette (re-pointed by Theme.setActive):
--   bg     = window / chrome / widget / widget_hover / sunken
--   fg     = primary / heading / muted / faint / disabled
--   border = soft / default / strong
--   data   = blue / amber / violet / red (chart series + payouts)
--   status = good / warn / error / info
--   tint   = world (asset multiplier)
--
-- Theme-invariant (one set across both palettes):
--   font   = path_main / size_ui[*]
--   size   = xs / sm / md / lg / xl / kpi (closed type scale)
--   space  = paddings, gaps, row heights, radii, line widths
--
-- ─── Caching warning ────────────────────────────────────────────────
-- Per-palette tokens get RE-POINTED by Theme.setActive(). Consumers MUST
-- read them per-frame (`Theme.bg.widget` in draw, not `local bg = Theme.bg`
-- at top of file) so palette swaps take effect immediately.

local Theme = {}

-- ─── Palettes (pure data) ───────────────────────────────────────────
-- views/Theme.lua reads Theme.palettes and re-points the per-palette
-- tables on setActive(). Adding a palette = one entry here, no code
-- change anywhere else.

Theme.palettes = {

    room = {
        bg = {
            window       = { 0.118, 0.102, 0.090 },  -- dim warm brown
            chrome       = { 0.145, 0.125, 0.110 },
            widget       = { 0.165, 0.143, 0.125 },
            widget_hover = { 0.200, 0.173, 0.150 },
            sunken       = { 0.085, 0.075, 0.065 },
        },
        border = {
            soft    = { 0.25, 0.22, 0.18 },
            default = { 0.40, 0.35, 0.28 },
            strong  = { 0.65, 0.55, 0.40 },
        },
        fg = {
            primary  = { 0.88, 0.82, 0.72 },         -- warm parchment
            heading  = { 0.95, 0.88, 0.75 },
            muted    = { 0.62, 0.56, 0.46 },
            faint    = { 0.42, 0.38, 0.31 },
            disabled = { 0.28, 0.25, 0.20 },
        },
        data = {
            blue   = { 0.55, 0.72, 0.85 },           -- desaturated, fits warm room
            amber  = { 0.92, 0.72, 0.32 },
            violet = { 0.72, 0.55, 0.78 },
            red    = { 0.82, 0.42, 0.38 },
        },
        status = {
            good  = { 0.50, 0.78, 0.45 },
            warn  = { 0.92, 0.72, 0.32 },
            error = { 0.82, 0.42, 0.38 },
            info  = { 0.55, 0.72, 0.85 },
        },
        tint = {
            world = { 1.00, 1.00, 1.00 },
        },
    },

    shove = {
        bg = {
            window       = { 0.020, 0.015, 0.018 },  -- near-black
            chrome       = { 0.035, 0.025, 0.030 },
            widget       = { 0.050, 0.035, 0.040 },
            widget_hover = { 0.080, 0.055, 0.060 },
            sunken       = { 0.000, 0.000, 0.000 },
        },
        border = {
            soft    = { 0.30, 0.10, 0.10 },
            default = { 0.55, 0.18, 0.18 },
            strong  = { 0.85, 0.25, 0.25 },
        },
        fg = {
            primary  = { 0.92, 0.88, 0.85 },         -- bone white
            heading  = { 1.00, 0.95, 0.90 },
            muted    = { 0.55, 0.50, 0.48 },
            faint    = { 0.32, 0.28, 0.27 },
            disabled = { 0.18, 0.15, 0.14 },
        },
        data = {
            blue   = { 0.45, 0.65, 0.85 },
            amber  = { 0.95, 0.70, 0.20 },
            violet = { 0.75, 0.45, 0.95 },
            red    = { 0.95, 0.20, 0.20 },
        },
        status = {
            good  = { 0.45, 0.85, 0.45 },
            warn  = { 0.95, 0.70, 0.20 },
            error = { 0.95, 0.20, 0.20 },
            info  = { 0.45, 0.65, 0.85 },
        },
        tint = {
            world = { 1.00, 1.00, 1.00 },
        },
    },

}

-- ─── Debug markers (theme-invariant) ───────────────────────────────
-- Intentionally garish colors used to make missing-asset / debug-overlay
-- conditions LOUD. Not chrome — these should never be seen by the player.
Theme.debug = {
    missing_fill   = { 1.0, 0.0, 1.0 },          -- magenta: missing sprite body
    missing_border = { 0.0, 0.0, 0.0 },          -- black: missing sprite outline

    -- Shove prototype HUD — drawn over either palette. Picked for high
    -- contrast against the shove palette (near-black bg) where the overlay
    -- spends all its time during the prototype.
    hud_bg     = { 0.00, 0.00, 0.00, 0.78 },     -- translucent black panel fill
    hud_border = { 0.40, 0.40, 0.45, 0.85 },     -- thin grey panel outline
    hud_text   = { 0.95, 0.95, 0.98 },           -- bone white
    hud_dim    = { 0.62, 0.62, 0.68 },           -- secondary labels
    hud_accent = { 0.40, 0.95, 0.55 },           -- lime: shove_rate, clear rate
    hud_warn   = { 0.98, 0.55, 0.40 },           -- soft red: "natural outcome failed" flag
    hud_hot    = { 0.55, 0.85, 1.00 },           -- cyan: hotkey legend keys
}

-- ─── Type scale (theme-invariant) ───────────────────────────────────
-- Closed set. Chrome callers pick from these by name.
Theme.size = {
    xs  = 10,    -- eyebrow caps
    sm  = 11,    -- secondary labels
    md  = 12,    -- default body / UI text
    lg  = 13,    -- section headings
    xl  = 16,    -- modal titles, big numbers
    kpi = 28,    -- bankroll display, PP display
    hero = 64,   -- shove %, terminal moments
}

-- ─── Spacing — base unit 4px ────────────────────────────────────────
Theme.space = {
    unit             = 4,
    widget_pad_x     = 8,
    widget_pad_y     = 6,
    widget_gap       = 6,
    widget_header_h  = 22,
    grid_row_h       = 22,
    chrome_row_h     = 26,
    chrome_gap       = 4,
    popup_pad        = 6,
    modal_margin     = 16,
    radius           = 3,
    hairline         = 1,
    line_strong      = 2,
    dot_r            = 4,
    scrollbar_w      = 6,
    sidebar_width_frac = 0.5,
}

-- ─── Fonts ──────────────────────────────────────────────────────────
-- Single font path for now. Add more entries to switch fonts without
-- touching the call sites.
Theme.font = {
    path_main     = nil,      -- nil = LÖVE default (replace with TTF later)
    size_ui_small = 11,
    size_ui       = 13,
    size_heading  = 16,
    size_kpi      = 28,
    size_hero     = 64,
}

-- Default-active palette name. views/Theme.lua reads this on first load.
Theme.default = "room"

-- Palette display order for cycle().
Theme.order = { "room", "shove" }

return Theme
