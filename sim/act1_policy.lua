-- sim/act1_policy.lua
--
-- THE TOGGLES. sim/act1.lua reads this and decides nothing on its own.
-- Edit this file, rerun `lua sim/act1.lua`, read docs/act1-sim.md.
--
-- Nothing here is a measurement or a claim about the game. It is a
-- description of how a player intends to play, which is the one input a
-- simulator cannot derive for itself. Every number the sim reports is
-- conditional on what is written here.

return {
    -- ─── Sampling ───────────────────────────────────────────────────────
    seeds            = 10,     -- independent playthroughs (--seeds=N overrides)
    max_run_minutes  = 45,     -- runaway guard: abandon a run past this
    max_shoves       = 25,     -- runaway guard: give up on Act 1 past this
    verbose          = false,  -- print every purchase as it happens

    -- ─── Dealing ────────────────────────────────────────────────────────
    -- Tables never deal themselves. "all_idle" = every idle table is dealt
    -- the frame it goes idle, which is the player clicking their own board.
    -- Cursors are not bought (see upgrade_caps), so there is no cursor
    -- branch to model and every hand is correctly player-dealt.
    deal = "all_idle",

    -- ─── The board ──────────────────────────────────────────────────────
    -- Lanes are opened in this order, each as soon as it is affordable
    -- without stranding the run. This is the T1-T3 Heads-Up sweep plus the
    -- T1-T2 Zoom sweep: 1+2+3 doubled by the Gaming Poster, plus 1+2.
    -- Zoom leads. A run restarts on exactly one s001 buy-in ($2 =
    -- INITIAL_BANKROLL = one s001 stack), so the first table is opened with
    -- the last dollar and busting it bricks the run. Heads-Up is the swingy
    -- lane and the chip engine; it goes on second, once there is a buffer.
    -- This is also the order the game forces on the opening run, where
    -- Heads-Up is still locked.
    lanes = {
        { gtype = "zoom", stake = "s001" },
        { gtype = "hu",   stake = "s001" },
        { gtype = "hu",   stake = "s002" },
        { gtype = "zoom", stake = "s002" },
        { gtype = "hu",   stake = "s003" },
    },
    -- Once every lane above is open, keep adding duplicates from the same
    -- list (for money, not bounties — a second table at a banked pair pays
    -- no second bounty). Each duplicate is scored like an upgrade and only
    -- bought if it clears the payback bar.
    repeat_lanes = true,
    -- A lane is opened when it is worth PLAYING, never merely when it is
    -- affordable. Higher stakes are EV-negative until run upgrades fill
    -- them (data/stakes.lua fill_window: s002 completes at level 8, s003 at
    -- 11), and a bounty bought before that costs one to two orders of
    -- magnitude more than the same bounty bought a level or two later:
    -- s002 at level 4 is 8.5% a hand and about $11 of bleed to land a chip
    -- worth 4; at level 5 it is +EV and the chip is free. s003 at level 7
    -- costs ~$647 for six. So: wait for break-even.
    -- A lane opens when EITHER it is worth playing on its own (ev per hand
    -- at or above lane_open_min_ev) OR the bounty on it is cheap enough to
    -- simply buy: expected dollars to land one stack-tier win, which is
    -- -ev / (win_chance x win_dist.stack), under both ceilings below.
    -- s003 on Heads-Up prices at $108 a chip at upgrade level 7, $4.54 at
    -- level 9 and free at 10 -- so the ceiling, not a fixed level, is what
    -- decides when the third stake is worth sitting at.
    lane_open_min_ev = 0.0,      -- $ per hand a lane must clear to be opened
    bounty_max_per_chip = 60.0,  -- ...or buy the chip, up to this much each
    bounty_max_bankroll_share = 0.25,  -- and never more than this of the bank
    -- Once a lane's bounty is banked, a table still under this rate is a
    -- drain on the bankroll that gates the next stake. Close it.
    lane_close_ev    = -0.01,
    -- How many tables past Focus capacity the board is allowed to run.
    -- 0 = never take the focus penalty.
    tables_over_capacity = 0,

    -- ─── Six-max ────────────────────────────────────────────────────────
    -- false: six-max is never opened and Bonsai / Desk Plant are never
    -- bought (14 {chip} to unlock the slowest hands in the game). Set true
    -- to buy the chain and add six_max lanes, which is the comparison run.
    six_max       = false,
    six_max_lanes = {
        { gtype = "six_max", stake = "s001" },
        { gtype = "six_max", stake = "s002" },
    },

    -- ─── Run upgrades (money, reset every shove) ────────────────────────
    -- 0 = never bought. Cursors do nothing for a board that deals itself,
    -- and the Focus ladder is 0.64 / 36 / 940 / 27,000 / 310,000, so level
    -- 4 is out of reach on an Act 1 bankroll no matter what the cap says.
    -- 99 = no policy cap; the engine derives the real one from the stakes
    -- currently buyable (GrindController:getRunUpgradeMaxLevel), which is
    -- 11 in Act 1 because s003's fill window completes at 11. Capping these
    -- below 11 makes the third stake permanently unfillable.
    upgrade_caps = {
        pot_control   = 99,
        sharper_reads = 99,
        focus         = 5,
        cursor        = 0,
        cursor_speed  = 0,
    },
    -- Bought whenever affordable, in cheapest-next order, with no payback
    -- test. These two ARE the run's progression: their levels are what fill
    -- the higher stakes (data/stakes.lua fill_window), so their real return
    -- is a stake becoming playable and a bounty becoming reachable -- which
    -- is chips, and no dollars-per-minute score can see it. Scoring them on
    -- payback stalls the run at level 5 and s003 never opens.
    upgrade_always = { "pot_control", "sharper_reads" },
    -- Everything else (Focus, duplicate tables) still has to pay for itself
    -- this fast at the board's measured earn rate.
    upgrade_payback_minutes = 6,

    -- ─── Catalog (chips, spent between runs) ────────────────────────────
    -- Ordered. Anything not named here falls back to cheapest-first, which
    -- is optimal per chip: every item is a flat +1% shove, so among equals
    -- the cheapest buys the most rate. The list is for items whose OTHER
    -- effect matters more than their 1% — the Poster doubles the chip
    -- engine, the Mirror feeds it.
    catalog_priority = {
        "gaming_poster",
        "mirror",
        "yellow_sticky_note",
        "energy_drink",
        "starter_gift_box",
    },
    -- Never bought, whatever the fallback would say. Bonsai and Desk Plant
    -- move to the priority list when six_max is true.
    catalog_exclude = { "bonsai", "desk_plant", "box_of_mice" },

    -- ─── When a run ends ────────────────────────────────────────────────
    -- Shove once every reachable bounty is banked AND the shove rate has
    -- stopped climbing: r1 gain per minute over the trailing window has
    -- fallen below the floor. The 3-{chip} gate on the first shove is the
    -- engine's own (GrindController:shoveUnlocked), not a policy setting.
    shove = {
        bounty_patience_minutes  = 10,      -- stop waiting on an unbanked lane
        r1_gain_per_minute_floor = 0.0015, -- "the rate has stalled"
        window_minutes           = 3,      -- how far back gain is measured
        min_run_minutes          = 2,      -- never shove before this
    },

    -- The FIRST shove only: go the moment the engine unlocks it (3 {chip})
    -- and the lanes already open have banked, instead of first extending
    -- the board up the stake ladder. This is what the designer's opening
    -- run does -- 4 {chip} is s001 + s002 on Heads-Up plus s001 on Zoom,
    -- shoved without ever opening s003. Set false to sweep the full ladder
    -- before the first shove too.
    first_shove_asap = true,

    -- Wall time the player spends per shove that is not grinding: the
    -- cinematic plus browsing the catalog. Added to elapsed time.
    shove_overhead_seconds = 45,
}
