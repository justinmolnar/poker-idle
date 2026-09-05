-- data/feedback_intensity.lua
--
-- Per-tier feedback intensity. Single source of truth for every juice
-- value that scales by outcome tier (shake amplitude, vignette alpha,
-- border-pulse alpha, slam down-spike, future shader/confetti driving).
--
-- Triggers in controllers/GrindController.lua read this table by tier
-- name and write the values to per-table FX state in models/Table.lua.
-- No `if tier == "stack"` branches anywhere — adding a new tier or
-- rebalancing intensities is a one-data-file edit.
--
-- Tier ladder (from data/pot_tiers.lua):
--   small    — modal outcome on most hands. Should be barely there.
--   medium   — noticeable but not loud.
--   large  — clearly felt; meaningful pot.
--   stack — every juice trick on. The rare moment.
--
-- All values 0..1 unless noted; per-system code maps them to actual
-- pixels / alpha / decibels.

return {
    small = {
        shake        = 0.20,
        vignette     = 0.0,
        border_pulse = 0.55,
        floater = {
            scale       = 1.00,
            font        = "md",
            arc_x       = 0,
            arc_y       = -64,
            lifetime    = 1.6,
            color_token = "won",          -- gold so it pops on green felt
            -- Real font the settled number rests in. Text is never left at
            -- a fractional scale — the pop is transient, the rest state is
            -- always one of the rasterized sizes. Same font on EVERY tier:
            -- the tier speaks through the pop; parked numbers are uniform.
            settle_font = "sm",
        },
    },
    medium = {
        shake        = 0.45,
        vignette     = 0.0,
        border_pulse = 0.80,
        floater = {
            scale       = 1.20,
            font        = "md",
            arc_x       = 0,
            arc_y       = -72,
            lifetime    = 1.8,
            color_token = "won",
            settle_font = "sm",
        },
    },
    large = {
        shake        = 0.75,
        vignette     = 0.55,
        border_pulse = 1.00,
        floater = {
            scale       = 1.45,
            font        = "lg",
            arc_x       = 18,
            arc_y       = -96,
            lifetime    = 2.0,
            color_token = "won",
            settle_font = "sm",
        },
        -- No chip burst at Large — the detonating pot is reserved for
        -- Stack so the player never mistakes a Large win for the big one.
        -- Large still carries full shake/vignette/border-pulse and a large
        -- floater.
    },
    stack = {
        shake        = 1.00,
        vignette     = 1.00,
        border_pulse = 1.00,
        floater = {
            scale       = 1.90,             -- big but still reads
            font        = "lg",
            arc_x       = 36,
            arc_y       = -120,
            lifetime    = 2.5,
            color_token = "won",
            settle_font = "sm",
        },
        -- The pot detonates — the pile itself comes apart, each chip
        -- leaving from where it sat. No count here on purpose: the number
        -- of chips in the air IS the number of chips that were in the pot.
        -- To make the explosion thicker, raise tier_chip_target.stack in
        -- data/chips.lua, which makes the PILE thicker too — they can't
        -- disagree, which is the point.
        chip_burst = true,
        glow       = 1.00,
    },
}
