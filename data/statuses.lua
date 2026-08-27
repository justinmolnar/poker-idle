-- data/statuses.lua
--
-- Table statuses: the temporary things that happen TO a table. A heater is
-- a table running hot; a tilt is a table playing worse after something bad.
-- Both are poker's own words for the two mental states, which is why they
-- are the vocabulary here.
--
-- ─── HOW A STATUS REACHES THE MATH ──────────────────────────────────────
-- It doesn't have its own math. Each status carries `effects` templates in
-- exactly the vocabulary data/effects.lua already speaks, and they run
-- through the SAME EffectsRegistry every owned item runs through — just
-- onto one table's ctx overlay instead of the global rollup. So a status is
-- an item that lives for six seconds on one table, and no new consumer code
-- exists anywhere in the outcome pipeline.
--
--   mag_field  which field on the effect entry the runtime magnitude lands in
--   mag_sign   -1 to flip it (a tilt is a negative win_chance_shift)
--   mag_form   "one_plus" wraps it as 1 + m, for multiplicative kinds
--
-- ─── LIFETIME IS A PROPERTY OF THE KIND ─────────────────────────────────
--   "seconds"  ticks down on RAW dt (never pace-scaled — a status that
--              speeds a table up must not shorten itself), so statuses also
--              pause correctly when the player is in the room or the shove.
--   "charges"  counts hands, spent when the table deals. "Your next pot is
--              bumped" is deterministic and self-limiting in a way a timer
--              is not, which matters when knockouts arrive every 5-11s.
-- Fixing the mode per KIND is what makes refresh-not-stack unambiguous:
-- there is never a timed heater meeting a charge heater.
--
-- Re-applying a live status REFRESHES it (max of magnitude, max of
-- remaining lifetime) rather than stacking. House style, same as the FX
-- writers in GrindController. Consequence worth knowing: two tournaments
-- running at once extend uptime but do not double the power.
--
-- Colours are Theme token STRINGS, never values (see data/theme.lua).
--
-- Pure data; no logic.

return {

    heater = {
        name     = "HEATER",
        blurb    = "Running hot: win chance raised.",
        lifetime = "seconds",
        polarity = "good",
        icon     = "heater",
        effects  = { { kind = "win_chance_shift", mag_field = "amount" } },
        glow_token = "status_fx.heater",
        wash_token = nil,
    },

    tilt = {
        name     = "TILT",
        blurb    = "Steaming: win chance cut.",
        lifetime = "seconds",
        polarity = "bad",
        icon     = "tilt",
        effects  = { { kind = "win_chance_shift", mag_field = "amount", mag_sign = -1 } },
        glow_token = nil,
        wash_token = "status_fx.tilt",
        -- A tilted table sits LITERALLY tilted, askew on the board, until
        -- it settles. Radians per unit of magnitude, clamped in the view.
        -- The panel's click targets rotate to match, so this can be big
        -- enough to actually read at a glance.
        rotate     = 2.0,
    },

    -- The enchant. tier_bump_chance is already max-combined by
    -- poker_effects and consumed in Table:deal, so a magnitude of 1 is a
    -- guaranteed one-step bump on the next pot and needs no new consumer.
    marked = {
        name     = "MARKED",
        blurb    = "Next pot bumped one tier.",
        lifetime = "charges",
        polarity = "good",
        icon     = "marked",
        effects  = { { kind = "tier_bump_chance", mag_field = "value" } },
        glow_token = "status_fx.heater",
        wash_token = nil,
    },

    -- ─── THE FIST ───────────────────────────────────────────────────────
    -- A table slams when something goes wrong at it: bust a tournament,
    -- lose a whole stack. It rears back, hangs, drives down, and flattens.
    --
    -- Read by BOTH the view (which draws the curve) and the controller
    -- (which waits `duration * rise` before the shockwave leaves), so the
    -- moment of impact is one number and they cannot drift apart. The
    -- neighbours are knocked, and their tilts appear, ON that frame —
    -- nothing reacts while the fist is still in the air.
    -- THE ONE NUMBER THAT MATTERS: contact is duration * (rise + strike),
    -- the end of the downswing, and that is the exact instant the
    -- neighbours are hit. Currently 0.60s. `rise` alone moves it: lower
    -- lands the blow sooner and leaves a longer settle, without changing
    -- how long the whole motion runs.
    slam = {
        duration = 1.50,   -- seconds, whole motion
        rise     = 0.35,   -- fraction spent winding up. Enough anticipation
                           -- to read, not so much that the hit arrives
                           -- after the moment has passed.
        strike   = 0.05,   -- ...and coming down. Short = violent.
        bounces  = 2.5,    -- half-cycles it settles through
    },

    -- THE BUMP: reaching over to shove ONE neighbour. Same three beats as
    -- the fist, for the same reason — draw back, thrust, recover. A shove
    -- with no draw-back is a twitch, which is exactly how the fist read
    -- before it got its wind-up.
    -- Contact is at (rise + strike): the end of the thrust, when it
    -- actually reaches the other table.
    shove = {
        duration = 1.00,
        rise     = 0.38,   -- drawing back away from the target
        strike   = 0.07,   -- ...then across, fast
        bounces  = 2.0,
    },

    -- Below these panel widths the glow/wash treatments are ABSENT rather
    -- than shrunk, and the status speaks through the panel border instead
    -- (same shrink-then-drop discipline as data/felt_style.lua). A status
    -- is never invisible; only its treatment changes.
    gates = {
        glow_min_panel_w = 260,
        chip_min_zone_w  = 90,
    },
}
