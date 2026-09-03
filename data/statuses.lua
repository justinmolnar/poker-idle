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
--   "run"      never expires on its own. No timer, no charges; it is
--              cleared when the run is. For the things a table EARNS over a
--              run rather than catches for a moment.
--   "punch"    lives until its punch is SPENT: an interrupt-carrying
--              status stays lit from landing until the forced hand
--              finishes (Table:_finalizeHand), however long the table
--              waits to deal. No timer — the visual and the mechanic are
--              one thing, so the fire can neither burn out with the
--              punch still armed nor die before the hand it decides.
--
-- `silent = true` stops a status announcing itself. Anything that reacts to
-- statuses arriving would otherwise react to its own output and feed itself
-- until a budget cut it off. Results are silent; things that happen TO a
-- table are not.
-- Fixing the mode per KIND is what makes refresh-not-stack unambiguous:
-- there is never a timed heater meeting a charge heater.
--
-- Re-applying a live status REFRESHES it (max of magnitude, max of
-- remaining lifetime) rather than stacking. House style, same as the FX
-- writers in GrindController. Consequence worth knowing: two tournaments
-- running at once extend uptime but do not double the power.
--
-- ─── EXCEPT WHERE STACKING IS THE POINT ─────────────────────────────────
-- `stack = "add"` makes a kind accumulate instead: magnitude and charges
-- sum rather than taking the max. That is for the statuses that ARE the
-- engine, where the tenth one landing has to be worth more than the first.
-- `stack_cap` bounds the magnitude, because a status fed by its own
-- consequences has no natural ceiling and this is the only thing between a
-- working build and a number that runs away.
--
-- Colours are Theme token STRINGS, never values (see data/theme.lua).
--
-- Pure data; no logic.

return {

    -- ─── WHAT A MENTAL STATE ACTUALLY DOES ──────────────────────────────
    -- ONE thing, and the player is told exactly what it is: the hand it
    -- lands in ends its way, and the next hand goes the same way. That is
    -- the whole status (see Table:interrupt). No passive half — no win
    -- chance, no pace, no tier moves riding along uninvoiced. A status
    -- whose text says "this hand wins" must not also secretly be four
    -- other buffs.
    --
    -- The empty effects list is therefore THE POINT, not an omission.
    -- `magnitude` is inert for these two (tilt still reads it for the
    -- lean, `rotate` below); a source's `t` is ignored — "punch" lifetime
    -- means the status lasts exactly as long as the punch does.
    --
    -- On TOURNAMENTS (chip-stack KO and legacy) the punch defers whole:
    -- no mid-hand rewrite of a scripted multiway hand — the NEXT hand's
    -- planned outcome is overridden instead (Table:deal), and the plan's
    -- bust steering re-reconciles on the hand after.
    --
    -- Consequence for authors: a CONTINUOUS heater/tilt source is a
    -- design error. Applied with interrupts, it decides every hand
    -- (never-lose / never-win); applied `no_interrupt`, it does nothing
    -- at all. These statuses are punches — author sources as moments,
    -- never as auras.
    heater = {
        name     = "HEATER",
        blurb    = "Running hot: this hand wins, and the next.",
        lifetime = "punch",
        -- Landing mid-hand on a cash table ENDS that hand as a win, and
        -- the next hand wins too; anywhere it can't honestly end a hand
        -- (idle, tournaments, spent scripts) the whole punch lands on the
        -- next hand instead. See Table:interrupt. A status without this
        -- key never interrupts, which is what keeps the silent engine
        -- statuses out of the path: a result must not end a hand.
        interrupt = "win",
        polarity = "good",
        icon     = "heater",
        effects  = {},
        -- Heat LOOKS like heat: animated flame tongues along the panel's
        -- bottom (shaders/flame.frag, TablePanelEffects.drawStatusFire).
        -- The glow is the halo; the fire is the read.
        flame    = true,
        glow_token = "status_fx.heater",
        wash_token = nil,
    },

    -- The mirror.
    tilt = {
        name     = "TILT",
        blurb    = "Steaming: this hand is lost, and the next.",
        lifetime = "punch",
        interrupt = "lose",
        polarity = "bad",
        icon     = "tilt",
        effects  = {},
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

    -- ─── THE ENGINE STATUSES ────────────────────────────────────────────
    -- These two accumulate rather than refresh, because they ARE the 6-max
    -- payoff: the whole build is about landing them repeatedly, so the
    -- tenth has to be worth more than the first.

    -- Marks that keep piling up. Each charge bumps ONE pot a tier, so three
    -- marks means the next three pots, not one enormous one. The magnitude
    -- is a probability and saturates at 1, hence the cap: past that a mark
    -- would look like it bought something and buy nothing.
    --
    -- Note tier_bump_chance is not win-only (models/Table.lua bumps the
    -- rolled tier whether the hand won or lost), so a marked table's losses
    -- run a tier bigger too. On a table that got marked BY being tilted,
    -- that is the fiction working rather than a bug.
    stacked_mark = {
        name     = "MARKED",
        blurb    = "The next pots run a tier bigger.",
        lifetime = "charges",
        -- Silent: this is what the engine PRODUCES. An item that reacts to
        -- statuses landing must not react to its own output, or it feeds
        -- itself until a budget cuts it off.
        silent   = true,
        stack    = "add",
        stack_cap = 1,
        polarity = "good",
        icon     = "marked",
        effects  = { { kind = "tier_bump_chance", mag_field = "value" } },
        glow_token = "status_fx.heater",
        wash_token = nil,
    },

    -- Reading the table better the longer you sit. Not win chance: this
    -- moves the SHAPE of what you win, one rung up the tier ladder, and
    -- win_tier_shift is a list kind so each application is its own roll
    -- that can chain further up. Three templates because the ladder has
    -- three rungs and a shift names its own from/to.
    sharp = {
        name     = "SHARP",
        blurb    = "Wins reach a tier higher.",
        lifetime = "run",
        silent   = true,   -- a result, not an event. See stacked_mark.
        stack    = "add",
        stack_cap = 0.25,
        polarity = "good",
        icon     = "marked",
        effects  = {
            { kind = "win_tier_shift", from = "small",  to = "medium",  mag_field = "chance" },
            { kind = "win_tier_shift", from = "medium", to = "large",   mag_field = "chance" },
            { kind = "win_tier_shift", from = "large",  to = "jackpot", mag_field = "chance" },
        },
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
        -- Below this panel width the heater's flame strip is ABSENT, not
        -- shrunk (the ring still says something is happening). One shader
        -- quad per heated panel, so it can afford to run smaller than the
        -- glow does.
        fire_min_panel_w = 120,
    },
}
