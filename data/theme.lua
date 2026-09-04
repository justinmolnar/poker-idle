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
-- One palette on every screen (2026-09): every state calls
-- Theme.setActive("room"). The "shove" palette below is retired and kept
-- only so nothing that names it breaks; a tool that looked different on
-- the shove screen than on the grind was a bug, not a mode. No per-component
-- "if state == shove" branches anywhere else.
--
-- ─── Token namespaces ───────────────────────────────────────────────
--
-- Per-palette (re-pointed by Theme.setActive):
--   bg     = window / chrome / widget / widget_hover / sunken / felt
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
            -- Playing surface. Unused in the room palette (the grind felt is
            -- tinted per stake via data/stake_themes), but both palettes carry
            -- the same key set so a view can read Theme.bg.felt either side.
            felt         = { 0.10, 0.16, 0.12 },
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
        -- Table statuses (data/statuses.lua). Deliberately NOT the
        -- status.good/error pair above: those mean "a hand just won or
        -- lost", and a heater has to read as a lasting condition rather
        -- than a result. Hot orange stays clear of the stack gold.
        --
        -- `tilt` is used as a MULTIPLY target, not as a tint: it is what
        -- the felt gets multiplied DOWN toward. So it is dark and nearly
        -- neutral on purpose — a saturated blue here would paint the
        -- table blue instead of draining the colour out of it. Channels
        -- close together = desaturate; overall darkness = the lights
        -- going out.
        status_fx = {
            heater = { 0.98, 0.52, 0.28 },
            tilt   = { 0.30, 0.33, 0.40 },
        },
        tier = {
            -- Outcome-tier color ramps for the per-table history bars.
            -- Keyed by the internal tier id (small/medium/large/stack);
            -- stack is the "Stack" tier and pops gold (win) / hot pink
            -- (loss) so the big result reads at a glance.
            win = {
                small   = { 0.38, 0.56, 0.34 },
                medium  = { 0.46, 0.72, 0.42 },
                large   = { 0.56, 0.86, 0.48 },
                stack = { 0.96, 0.78, 0.30 },
            },
            loss = {
                small   = { 0.52, 0.33, 0.31 },
                medium  = { 0.70, 0.40, 0.37 },
                large   = { 0.86, 0.44, 0.40 },
                stack = { 0.95, 0.32, 0.52 },
            },
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
            -- The gauntlet's playing surface. Deliberately NOT the grind
            -- table's green: the shove reads as a different, more serious
            -- room, so the felt is deep and desaturated.
            felt         = { 0.045, 0.075, 0.060 },
        },
        border = {
            -- Oxblood leather, not alert red. These were {0.85,0.25,0.25}
            -- and the whole table read as an error state; the dealer's win
            -- glow is the only thing on this screen that gets to be red now.
            soft    = { 0.22, 0.09, 0.09 },
            default = { 0.34, 0.13, 0.13 },
            strong  = { 0.48, 0.18, 0.18 },
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
        status_fx = {
            heater = { 1.00, 0.55, 0.25 },
            tilt   = { 0.28, 0.31, 0.38 },
        },
        },
        tier = {
            win = {
                small   = { 0.34, 0.62, 0.34 },
                medium  = { 0.42, 0.78, 0.42 },
                large   = { 0.52, 0.92, 0.50 },
                stack = { 1.00, 0.82, 0.28 },
            },
            loss = {
                small   = { 0.62, 0.26, 0.26 },
                medium  = { 0.80, 0.30, 0.30 },
                large   = { 0.95, 0.34, 0.34 },
                stack = { 1.00, 0.28, 0.55 },
            },
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

-- ─── Currency glyph (theme-invariant) ───────────────────────────────
-- The Gold Chip reads as the same gold object in any palette. Used by
-- the procedural chip placeholder (views/Chips.drawGlyph) until real
-- sprite art lands at assets/sprites/ui/icons/chip.
Theme.currency = {
    chip      = { 0.93, 0.75, 0.30 },   -- warm gold disc
    chip_ring = { 0.52, 0.40, 0.14 },   -- darker rim / inner ring
    achip     = { 0.65, 0.35, 0.95 },   -- purple disc for anti-chips
    achip_ring= { 0.35, 0.15, 0.55 },   -- darker rim
}

-- ─── Playing cards (theme-invariant) ────────────────────────────────
-- A card is a card in any palette. Used by views/CardSprites when the
-- drawn card is too small for its sprite to show a rank and it falls
-- back to a plate with a single rank letter. Suit colors are the real
-- ones — a red suit has to read as red, not as the palette's error tone.
Theme.card = {
    face   = { 0.93, 0.92, 0.87 },   -- bone plate (a card's paper)
    red    = { 0.80, 0.18, 0.18 },   -- hearts / diamonds
    black  = { 0.12, 0.12, 0.15 },   -- clubs / spades
    back   = { 0.22, 0.28, 0.42 },   -- face-down plate
    edge   = { 0.06, 0.06, 0.08 },   -- plate outline
}

-- ─── Type scale (theme-invariant) ───────────────────────────────────
-- Closed set. Chrome callers pick from these by name.
Theme.size = {
    xs  = 10,    -- eyebrow caps
    sm  = 11,    -- secondary labels
    md  = 12,    -- default body / UI text
    lg  = 13,    -- section headings
    xl  = 16,    -- modal titles, big numbers
    kpi = 28,    -- bankroll display, chip display
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
-- Three universal sizes. Chunky pixel font (Thin Sans) — Balatro-feel:
-- prominent numbers tower over labels. lg pulls double duty for the
-- bankroll-class big-number tier AND cinematic moments (Shove cinematic,
-- Credits) — collapsed from the old kpi/hero split.
Theme.font = {
    path_main = "assets/fonts/Thin Sans.ttf",
    size_sm   = 8,
    size_md   = 16,
    size_lg   = 24,
}

-- Default-active palette name. views/Theme.lua reads this on first load.
Theme.default = "room"

-- Palette display order for cycle().
Theme.order = { "room", "shove" }

return Theme
