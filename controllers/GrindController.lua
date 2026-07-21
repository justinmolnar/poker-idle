-- controllers/GrindController.lua
--
-- Sits between GrindState and the model layer. Owns the TablePool, applies
-- per-tick resolutions to bankroll, and routes
-- floating-text emission. Validates and applies purchase intents from the
-- view (run-upgrade and catalog buys).
--
-- The view doesn't mutate state directly — it dispatches intents to this
-- controller. Effects context is cached and only recomputed when an item is
-- bought or run state changes (cheap, since we're not doing it per-frame).

local TablePool      = require("models.TablePool")
local TableModel     = require("models.Table")            -- only for anchorKey()
local Decks          = require("models.Decks")
local Catalog        = require("data.catalog")
local RunUpgrades    = require("data.run_upgrades")
local Stakes         = require("data.stakes")
local GameTypes      = require("data.game_types")
local Constants      = require("data.constants")
local ChipData       = require("data.chips")
local FeedbackIntensity = require("data.feedback_intensity")
local Denoms         = require("services.DenominationBreakdown")
local AnchorRegistry = require("services.AnchorRegistry")
local Confetti       = require("services.Confetti")
local StakeThemes    = require("data.stake_themes")
local Lookups        = require("utils.lookups")
local HandAnalytics  = require("services.HandAnalytics")

-- Chip-bounty key: a (stake, game_type) combo locks one bounty per run.
-- 4 game types × 6 stakes = 24 distinct bounty slots — total ~84 chips for
-- a perfect climb across all combos.
local function bountyKey(stake_id, game_type_id)
    return stake_id .. ":" .. game_type_id
end

local GrindController = {}
GrindController.__index = GrindController

function GrindController:new(game)
    local self = setmetatable({
        game = game,
        -- Pending chip-flight bursts. Controller pushes burst descriptors
        -- (source, dest, chip indices, options); GrindView drains the queue
        -- each frame, builds render closures via views/Chips, and dispatches
        -- to services/FlightSystem. Decouples the controller from the view
        -- layer — no views/* require lives in this file.
        pending_bursts = {},
    }, GrindController)
    -- Compute effects first so the initial pool rebuild gets ctx (matters
    -- for Cold Read and other start-of-table catalog perks).
    self:invalidateEffects()
    self.pool = TablePool:new(game.state, self.ctx, game.poker_events)
    return self
end

-- Push a chip-flight intent onto the queue. GrindView drains this each
-- frame. Source/dest are { x, y } pairs (or nil — burst is dropped). chips
-- is the denomination-index list from DenominationBreakdown.
function GrindController:_queueBurst(source, dest, chips, options)
    if not source or not dest or not chips or #chips == 0 then return end
    self.pending_bursts[#self.pending_bursts + 1] = {
        source  = source,
        dest    = dest,
        chips   = chips,
        options = options,
    }
end

-- Drain and return the queued bursts, clearing the buffer. GrindView calls
-- this each frame.
function GrindController:drainBursts()
    local bursts = self.pending_bursts
    self.pending_bursts = {}
    return bursts
end

-- Recompute the effects context from the player's owned items + run upgrades.
-- Called on construction and after any purchase / prestige reset.
function GrindController:invalidateEffects()
    local n_tables = self.pool and self.pool:count() or 0
    self.ctx = self.game.state:computeEffects(self.game.effects, Catalog, RunUpgrades, { active_tables_count = n_tables })
    -- Latch the transient ultra-unlock effect into persistent state so the
    -- Ultra band stays available (stakeAvailable reads state.ultra_unlocked).
    -- One-way — any effect granting it makes the unlock permanent.
    if self.ctx.ultra_unlocked then
        self.game.state.ultra_unlocked = true
    end
end

-- Maximum concurrent tables. The catalog no longer gates *how many* tables
-- you can open — it gates how many you can open *efficiently*. The hard cap
-- is the visual / sanity bound; the focus mechanic shapes the actual
-- viability curve via currentFocusMult().
function GrindController:tableSlotsCap()
    return Constants.GAMEPLAY.MAX_TABLES
end

-- Focus / efficiency penalty applied to every per-hand $ delta. See the
-- design discussion in the plan file. n_tables beyond capacity gets shaved
-- by base_penalty * penalty_reduce_mult, floored at FOCUS_FLOOR.
function GrindController:currentFocusMult()
    if self.ctx and self.ctx.focus_penalty_immune then
        return 1.0
    end
    local n        = self.pool:count()
    local base_cap = Constants.GAMEPLAY.FOCUS_BASE_CAPACITY
    local cap      = base_cap + ((self.ctx and self.ctx.focus_capacity) or 0)
    local reduce   = (self.ctx and self.ctx.focus_penalty_reduce_mult) or 1
    local penalty  = Constants.GAMEPLAY.FOCUS_BASE_PENALTY * reduce
    local floor_v  = Constants.GAMEPLAY.FOCUS_FLOOR

    local extra = n - cap
    if extra <= 0 then return 1.0 end
    local mult = 1 - penalty * extra
    if mult < floor_v then mult = floor_v end
    return mult
end

-- Effective capacity for the UI — base + ctx bonus (no penalty math).
function GrindController:currentFocusCapacity()
    local base_cap = Constants.GAMEPLAY.FOCUS_BASE_CAPACITY
    return base_cap + ((self.ctx and self.ctx.focus_capacity) or 0)
end

function GrindController:update(dt)
    -- Snapshot per-table state BEFORE the pool ticks so we can detect
    -- transitions afterwards and play the right sound on each.
    local prev_states = {}
    for i, t in ipairs(self.pool.tables) do
        prev_states[i] = t.state
    end

    local resolutions = self.pool:update(dt, self.ctx)

    -- Sound triggers on state transitions. (The idle → dealing chip-flight
    -- emission lives in :dealHand instead — that transition happens
    -- between frames, before the snapshot above can see it.)
    for i, t in ipairs(self.pool.tables) do
        local prev = prev_states[i]
        if prev and prev ~= t.state then
            self:_playStateTransitionSound(prev, t.state, t)
        end
    end

    -- Pending buy-in bursts: addTable / first-frame-after-add can't emit
    -- because the new table has no panel position yet. Resolve once the
    -- view has registered the table's "you" anchor.
    for _, t in ipairs(self.pool.tables) do
        if t._pending_buyin
           and AnchorRegistry.get(TableModel.anchorKey(t, "you"))
           and AnchorRegistry.get("bankroll") then
            self:_emitBuyInChips(t, t._pending_buyin)
            t._pending_buyin = nil
        end
    end

    -- Pending cash-outs: tables flagged for close while mid-hand. Finalise
    -- the moment they return to idle. Iterate in reverse so removal-driven
    -- index shifts don't skip entries.
    for i = #self.pool.tables, 1, -1 do
        local t = self.pool.tables[i]
        if t and t.pending_close and t.state == "idle" then
            self:_finalizeRemove(i)
        end
    end

    -- Tournament payout drain. MttSession.settle stashes a $ amount on the
    -- table; we apply it to bankroll, emit a chip burst, and reset the
    -- per-tournament counter so the player can rebuy for another run.
    for _, t in ipairs(self.pool.tables) do
        local payout = t.mtt and t.mtt:drainPayout()
        if payout ~= nil then
            local hands_cleared = t.mtt.hands_won
            -- Win detection. Two flavors: chip-stack KO (finish 1st) and the
            -- legacy binary tournament (cleared all hand_count hands).
            local gtype = Lookups.findById(GameTypes, t.game_type_id)
            local won_ko     = t.mtt and t.mtt.last_finish == 1
                              and gtype and gtype.chip_stack_table
            local won_legacy = gtype and gtype.binary_outcome
                              and t.mtt and hands_cleared >= (gtype.hand_count or 0)
            local is_win = gtype and (won_ko or won_legacy)
            local center = AnchorRegistry.get(TableModel.anchorKey(t, "center"))
                           or { 0, 0 }

            if payout > 0 then
                self.game.state.bankroll = self.game.state.bankroll + payout
                self:_emitMttPayoutChips(t, payout)
            end
            if Constants.DEBUG.HAND_ANALYTICS then
                local mtt_stake = Lookups.findById(Stakes, t.stake_id)
                HandAnalytics.recordHand({
                    t_start      = love.timer.getTime(),
                    duration     = 0,
                    won          = is_win,
                    delta        = payout,
                    tier         = "mtt_payout",
                    stake_id     = t.stake_id,
                    stake_bb     = mtt_stake and mtt_stake.bb or nil,
                    game_type_id = t.game_type_id,
                    prototype    = Constants.PROTOTYPE_MODE,
                    hands_played = hands_cleared,
                })
            end

            if is_win then
                -- Chip bounty: first jackpot-equivalent per (stake, gtype) per
                -- run. Tournaments only "jackpot" once — on the win — so it's
                -- banked here, not on the per-hand cash path. Rides into the
                -- celebration block below.
                local state = self.game.state
                local cap = 1
                local key = bountyKey(t.stake_id, t.game_type_id)
                local cur = state.stakes_won_this_run[key]
                local count = 0
                if cur == true then
                    count = 1
                elseif type(cur) == "number" then
                    count = cur
                end
                local award = 0
                if count < cap then
                    state.stakes_won_this_run[key] = count + 1
                    state.hands_since_last_bank = 0
                    -- Same award math as the cash jackpot path (incl.
                    -- chip_award_mult AND Pen's flat bonus — this used to
                    -- hand-roll the formula and dropped the Pen add).
                    award = self:bountyAward(t.stake_id)
                    if award > 0 then
                        -- Dogs Playing Poker: the run's first bounty pays +bonus.
                        if not state.first_bounty_this_run then
                            state.first_bounty_this_run = true
                            award = award + ((self.ctx and self.ctx.first_bounty_bonus) or 0)
                        end
                        state.chips_this_run = state.chips_this_run + award
                        state.lifetime_chips_banked = (state.lifetime_chips_banked or 0) + 1
                    end
                else
                    -- Copy Machine: the run's first denied bounty banks anyway.
                    if self.ctx and self.ctx.copy_first_denied and not state.denied_copied_this_run then
                        state.denied_copied_this_run = true
                        local cp = self:bountyAward(t.stake_id)
                        if cp > 0 then
                            state.chips_this_run = state.chips_this_run + cp
                            state.lifetime_chips_banked = (state.lifetime_chips_banked or 0) + 1
                        end
                    else
                        -- Repeat tournament win on an already-banked combo:
                        -- the same "denied" event the cash path counts (feeds
                        -- the chip_denied tutorial hint).
                        state.total_denied_stacks = (state.total_denied_stacks or 0) + 1
                    end
                end

                -- Jackpot-grade table FX + a confetti fountain — the MTT is the
                -- top of the ladder, so the win gets the full spectacle.
                local jp = FeedbackIntensity.jackpot
                t.shake_trauma       = math.max(t.shake_trauma or 0, jp.shake)
                t.vignette_kind      = "good"
                t.vignette_alpha     = math.max(t.vignette_alpha or 0, jp.vignette)
                t.border_pulse_t     = 1.0
                t.border_pulse_color = "good"
                t.glow_t             = math.max(t.glow_t or 0, jp.glow or 1.0)
                Confetti.burst(center, math.floor((jp.confetti_count or 120) * 1.5))

                -- ONE multi-line celebration float anchored at the table center.
                -- The renderer stacks the lines itself, so there are no manual
                -- per-float offsets to collide or drift off the top of view.
                local lg_h = self.game.fonts.lg:getHeight()
                local msg  = "TOURNAMENT WON"
                if payout > 0 then msg = msg .. string.format("\n+$%.2f", payout) end
                if award  > 0 then msg = msg .. string.format("\n+%d {chip}", award) end
                self.game.floating_text.emit(msg, center[1], center[2],
                    { scale = 1.4, font = "lg", color_token = "amber",
                      lifetime = 2.6, arc_y = -math.floor(lg_h * 0.5) })
            elseif payout > 0 then
                -- Partial payout (busted before the win) — a plain cash float.
                self.game.floating_text.emit(string.format("+$%.2f", payout),
                    center[1], center[2])
            end

            t.mtt.hands_won = 0
        end
    end

    if #resolutions == 0 then return end

    local state      = self.game.state
    local focus_mult = self:currentFocusMult()
    for _, r in ipairs(resolutions) do
        -- Apply focus penalty to the actual $ delta — split attention
        -- means smaller wins and harsher relative losses. Floor in
        -- currentFocusMult prevents zero, so a tiny positive delta is
        -- still positive and counts as a win for the chip bounty.
        r.delta = r.delta * focus_mult

        -- Bank capstone: scale every hand's magnitude by a bankroll-log
        -- multiplier, read live here (magnitude-only, commutes with the
        -- focus mult). Lives here rather than in Table so the effects
        -- cache never has to carry live bankroll.
        if self.ctx and self.ctx.earnings_scale_by_bankroll then
            local br = self.game.state.bankroll or 0
            r.delta = r.delta * (1.0 + math.log10(br + 1) * 0.1)
        end

        -- Once-per-run loss voids: The Fridge (first jackpot-tier stack loss)
        -- then Rubber Duck (first loss of any size). Zero the delta before it
        -- lands on stack/bankroll, so the beat simply didn't happen. Cash
        -- tables only — an MTT r.delta is informational (the bust is already
        -- in tbl.stack), so voiding it there just wastes the once-per-run use.
        if r.delta < 0 and not r.chip_stack_table and self.ctx then
            if self.ctx.void_first_stack_loss and r.tier == "jackpot"
               and not state.first_stack_loss_voided_this_run then
                state.first_stack_loss_voided_this_run = true
                r.delta = 0
            elseif self.ctx.void_first_loss and not state.first_loss_voided_this_run then
                state.first_loss_voided_this_run = true
                r.delta = 0
            end
        end

        -- Wins/losses land on the table's stack first. Above the 100bb
        -- cap (= stake.buy_in) the surplus spills to bankroll; below
        -- zero the loss clamps to whatever's actually on the table so
        -- the player can't go negative just from a brutal hand.
        --
        -- Chip-stack tables (8-max KO): tbl.stack has already been
        -- updated by Table:_reconcileChipFlow when the script's
        -- pot_push fired, and r.delta carries the resulting net flow.
        -- Skip the stack write so we don't double-count, and skip the
        -- buy-in cap entirely (a winning seat can hold up to the full
        -- 800bb chip pool, far above the 100bb buy-in).
        local tbl   = self.pool.tables[r.table_idx]
        local stake = tbl and Lookups.findById(Stakes,tbl.stake_id)
        local cap   = (stake and stake.buy_in) or 0
        local overflow_amount = 0
        if tbl and r.chip_stack_table then
            -- No-op: stack already reconciled. r.delta is informational.
        elseif tbl then
            local new_stack = tbl.stack + r.delta
            if new_stack > cap then
                overflow_amount = new_stack - cap
                tbl.stack = cap
                state.bankroll = state.bankroll + overflow_amount
            elseif new_stack < 0 then
                if state.shove_r2_won and stake and stake.band == "ultra" then
                    local excess_loss = -new_stack
                    tbl.stack = 0
                    state.bankroll = state.bankroll - excess_loss
                else
                    r.delta = -tbl.stack
                    tbl.stack = 0
                end
            else
                tbl.stack = new_stack
            end
        else
            -- Defensive fallback: no table found, route to bankroll
            -- with the same negative clamp.
            local new_bankroll = state.bankroll + r.delta
            if new_bankroll < 0 then
                if not state.shove_r2_won then
                    r.delta = -state.bankroll
                    new_bankroll = 0
                end
            end
            state.bankroll = new_bankroll
        end

        -- Analytics: record hand timing and outcome. The start timestamp was
        -- stamped by dealHand() or by the auto-deal re-stamp below. After
        -- recording, we check whether the table already re-entered dealing
        -- (auto-deal MTT path fires inside Table:update before we get here)
        -- and re-stamp so the next resolution has a valid duration.
        if Constants.DEBUG.HAND_ANALYTICS and tbl then
            if tbl._hand_start_t then
                HandAnalytics.recordHand({
                    t_start        = tbl._hand_start_t,
                    duration       = love.timer.getTime() - tbl._hand_start_t,
                    won            = r.won,
                    delta          = r.delta,
                    tier           = r.tier,
                    stake_id       = tbl.stake_id,
                    stake_bb       = stake and stake.bb or nil,
                    game_type_id   = tbl.game_type_id,
                    hand_pace_mult = (self.ctx and self.ctx.hand_pace_mult) or 1,
                    deck_id        = self.game.state.active_deck_id,
                    prototype      = Constants.PROTOTYPE_MODE,
                })
                tbl._hand_start_t = nil
            end
            if tbl.state ~= "idle" then
                tbl._hand_start_t = love.timer.getTime()
            end
        end

        -- Floater label & color. Three flavors:
        --   • cash hand               → "+/-$X.XX"
        --   • chip-stack MTT hand     → "+/-Nbb" (no cash until placement)
        --   • legacy binary MTT hand  → "WIN" / "OUT" (delta is forced 0,
        --                                so a dollar label is meaningless)
        -- Tournament cash payout fires its own "+$X.XX" floater from the
        -- drainPayout block above when the tournament ends.
        local gtype_for_floater = tbl and Lookups.findById(GameTypes, tbl.game_type_id)
        local is_binary = gtype_for_floater and gtype_for_floater.binary_outcome
        local label
        local floater_opts_override = nil
        if is_binary then
            label = r.won and "WIN" or "OUT"
            -- Short-lived so the rapid auto-dealt tournament hands don't pile
            -- their floaters on top of each other.
            floater_opts_override = { color_token = r.won and "good" or "error",
                                      lifetime = 0.85 }
        elseif r.chip_stack_table then
            local stake = tbl and Lookups.findById(Stakes, tbl.stake_id)
            local bb_val = (stake and stake.bb and stake.bb > 0) and stake.bb or 1
            local bb_delta = (r.delta or 0) / bb_val
            if bb_delta >= 0 then
                label = string.format("+%dbb", math.floor(bb_delta + 0.5))
            else
                label = string.format("-%dbb", math.floor(-bb_delta + 0.5))
                floater_opts_override = { color_token = "error" }
            end
        elseif r.delta >= 0 then
            label = string.format("+$%.2f", r.delta)
        else
            label = string.format("-$%.2f", -r.delta)
            -- Loss: override the data-file's amber default with red so
            -- losses read correctly. Without this every tier picks up
            -- color_token="amber" and "-$X.XX" floaters render in gold
            -- like the wins.
            floater_opts_override = { color_token = "error" }
        end

        -- MTT WIN feedback scales with tournament PROGRESS, not the (for a
        -- binary tournament hand, meaningless) pot tier: early hands stay
        -- small and ramp toward large as the stack clears to the win. The
        -- winning hand itself is left to the TOURNAMENT WON banner.
        local mtt_final = false
        if is_binary and r.won and tbl and tbl.mtt then
            local hc   = gtype_for_floater.hand_count or 8
            local n    = math.max(1, math.min(hc, tbl.mtt.hands_won or 1))
            local ramp = { "small", "small", "medium", "medium",
                           "large", "large", "large", "large" }
            r.tier    = ramp[n] or "large"
            -- The winning hand is the one that settled the tournament (payout
            -- pending) — let the TOURNAMENT WON banner stand in for its float.
            mtt_final = (tbl.mtt.pending_payout ~= nil)
        end

        -- Tier-scaled floater opts from data. Small = small + compact;
        -- jackpot = huge + arcing. The data layer paints wins amber
        -- (it pops on green felt); the per-emit overrides above route
        -- losses to red (cash and MTT both).
        local intensity_for_floater = FeedbackIntensity[r.tier] or FeedbackIntensity.small
        local floater_opts = intensity_for_floater.floater
        if floater_opts_override then
            floater_opts = {}
            for k, v in pairs(intensity_for_floater.floater) do floater_opts[k] = v end
            for k, v in pairs(floater_opts_override) do floater_opts[k] = v end
        end
        -- Spawn at the panel center if the anchor exists; falls back to
        -- (r.x, r.y) which is the panel's top-left corner. The center
        -- read sells the float as "above this hand" instead of off in
        -- the corner.
        local cxy   = (tbl and AnchorRegistry.get(TableModel.anchorKey(tbl, "center")))
        local fx    = cxy and cxy[1] or (r.x or 0)
        local fy    = cxy and cxy[2] or (r.y or 0)
        -- Skip the winning hand's per-hand float — the TOURNAMENT WON banner
        -- from the payout-drain block stands in for it (avoids the pile-up).
        if not mtt_final then
            self.game.floating_text.emit(label, fx, fy, floater_opts)
        end

        -- Chip-flight burst on resolution. Three flavors:
        --   • win  → pot to YOU stack
        --   • loss → pot off-screen (chips fly off the bottom)
        --   • overflow (YOU stack hit cap) → YOU to bankroll pile
        self:_emitResolutionChips(r, tbl, overflow_amount)

        -- Tier-scaled resolution FX. Every settle now produces feedback;
        -- magnitude per tier comes from data/feedback_intensity.lua so
        -- there's no `if tier == "jackpot"` branch here. Small resolutions
        -- get a faint border pulse + small slam dip; jackpots get full
        -- shake + vignette + bright border + biggest slam.
        if tbl then
            local intensity = FeedbackIntensity[r.tier] or FeedbackIntensity.small
            local is_win    = r.delta > 0
            tbl.shake_trauma       = math.max(tbl.shake_trauma or 0, intensity.shake)
            if intensity.vignette > 0 then
                tbl.vignette_kind  = is_win and "good" or "bad"
                tbl.vignette_alpha = math.max(tbl.vignette_alpha or 0, intensity.vignette)
            end
            tbl.border_pulse_t     = math.max(tbl.border_pulse_t or 0, intensity.border_pulse)
            tbl.border_pulse_color = is_win and "good" or "bad"
            -- Border-pulse SFX marker — short ding tied to the colored
            -- border flash. Volume scales with the same border_pulse
            -- intensity so Small resolutions barely register and Jackpots
            -- ring out. Stacks with the existing pot_won_/pot_lost_ tier
            -- sound that fires from the state-transition handler.
            local pulse_sound = is_win and "border_pulse_win" or "border_pulse_loss"
            self:_playNamed(pulse_sound, { volume_mult = intensity.border_pulse })
            -- Spectacle layer: jackpot wins only. Radial-glow shader on
            -- the panel + confetti fountain from the table center. Both
            -- gated on intensity fields existing (only jackpot defines
            -- them in data/feedback_intensity.lua) so future tiers can
            -- opt in by adding the same fields.
            if is_win and intensity.glow and intensity.glow > 0 then
                tbl.glow_t = math.max(tbl.glow_t or 0, intensity.glow)
            end
            if is_win and intensity.confetti_count and intensity.confetti_count > 0 then
                -- Inline AnchorRegistry lookup — _anchor() helper is
                -- defined further down in the file and isn't visible
                -- at this point of the load order.
                local center = AnchorRegistry.get(TableModel.anchorKey(tbl, "center"))
                                or { r.x or 0, r.y or 0 }
                Confetti.burst(center, intensity.confetti_count)
            end
        end

        -- Chip-bounty: first jackpot-tier win at this (stake, game_type)
        -- combo this run awards the stake's chip_award. Locked in until
        -- prestige clears it. Non-jackpot wins, losing hands, and
        -- subsequent jackpot wins at the same combo do nothing.
        --
        -- The Pen catalog item (jackpot_chip_add) adds a flat +N to the
        -- bounty award — i.e. each tier's payout becomes worth +1 chip
        -- more when Pen is owned. So a tier whose chip_award is 2 pays
        -- 3 with Pen; a tier whose award is 5 pays 6. The bonus rides
        -- the bounty so it fires exactly when the bounty fires (once
        -- per (stake, gtype) per run), never on subsequent jackpots.
        --
        -- Chip-stack tournaments skip this path — their bounty fires
        -- once per run on a 1st-place tournament win, gated in the
        -- drainPayout block above. Without this skip, a jackpot pot
        -- mid-tournament would bank the (stake, mtt) bounty before
        -- the player has actually won the tournament.
        -- Runs before the bounty check so a banking hand's reset (below)
        -- leaves this at 0, not 1. Drives the tutorial's shove-stall hint.
        state.hands_since_last_bank = (state.hands_since_last_bank or 0) + 1

        if r.delta > 0 and r.tier == "jackpot" and not r.chip_stack_table then
            local tbl = self.pool.tables[r.table_idx]
            if tbl then
                local cap = 1
                local key = bountyKey(tbl.stake_id, tbl.game_type_id)
                local cur = state.stakes_won_this_run[key]
                local count = 0
                if cur == true then
                    count = 1
                elseif type(cur) == "number" then
                    count = cur
                end
                if count < cap then
                    state.stakes_won_this_run[key] = count + 1
                    state.hands_since_last_bank = 0
                    local award = self:bountyAward(tbl.stake_id)
                    if award > 0 then
                        -- Dogs Playing Poker: the run's first bounty pays +bonus.
                        if not state.first_bounty_this_run then
                            state.first_bounty_this_run = true
                            award = award + ((self.ctx and self.ctx.first_bounty_bonus) or 0)
                        end
                        -- Pending chips — commit to state.chips at SHOVE
                        -- time. The float is the satisfying "you locked a
                        -- bounty" signal; the top bar's chip figure stays
                        -- static until shove pulls the trigger on banking.
                        state.chips_this_run = state.chips_this_run + award
                        state.lifetime_chips_banked = (state.lifetime_chips_banked or 0) + 1
                        self.game.floating_text.emit(
                            string.format("+%d {chip}", award),
                            r.x, (r.y or 0) - 28)
                    end
                else
                    -- Copy Machine: the run's first denied bounty banks anyway.
                    if self.ctx and self.ctx.copy_first_denied and not state.denied_copied_this_run then
                        state.denied_copied_this_run = true
                        local cp = self:bountyAward(tbl.stake_id)
                        if cp > 0 then
                            state.chips_this_run = state.chips_this_run + cp
                            state.lifetime_chips_banked = (state.lifetime_chips_banked or 0) + 1
                            self.game.floating_text.emit(
                                string.format("+%d {chip}", cp),
                                r.x, (r.y or 0) - 28)
                        end
                    else
                        -- Denied: this (stake, gtype) already paid its bounty
                        -- this run. Counted (unconditionally, meta-side) so
                        -- the tutorial can explain the once-per-run rule the
                        -- first time it bites.
                        state.total_denied_stacks = (state.total_denied_stacks or 0) + 1
                    end
                end
            end
        end

        -- Anti-chip award: stack loss (r.delta < 0 and r.tier == "jackpot") at High/Ultra stakes during Act 3.
        if r.delta < 0 and r.tier == "jackpot" and not r.chip_stack_table then
            local tbl = self.pool.tables[r.table_idx]
            if tbl then
                local stake = Lookups.findById(Stakes, tbl.stake_id)
                if stake and (stake.band == "high" or stake.band == "ultra") and state.shove_r2_won then
                    local cap = 1
                    local key = bountyKey(tbl.stake_id, tbl.game_type_id)
                    state.anti_stakes_won_this_run = state.anti_stakes_won_this_run or {}
                    local cur = state.anti_stakes_won_this_run[key]
                    local count = (cur == true and 1) or 0
                    if count < cap then
                        state.anti_stakes_won_this_run[key] = true
                        state.hands_since_last_bank = 0
                        local award = self:antiBountyAward(tbl.stake_id)
                        if award > 0 then
                            state.anti_chips_this_run = (state.anti_chips_this_run or 0) + award
                            self.game.floating_text.emit(
                                string.format("+%d {achip}", award),
                                r.x, (r.y or 0) - 28)
                        end
                    end
                end
            end
        end

        -- Hands resolved, ever — unconditional, unlike the deck lifetime
        -- counters below (those start at zero when decks unlock). Drives
        -- tutorial-hint pacing (models/hint_rules.lua "hands_played").
        state.total_hands_played = (state.total_hands_played or 0) + 1
        if r.tier == "large" or r.tier == "jackpot" then
            -- Big outcomes, win or loss — the tutorial's tier hint fires
            -- on the first one.
            state.total_big_outcomes = (state.total_big_outcomes or 0) + 1
        end

        -- Deck-system meta bookkeeping. Lifetime counters drive unlock
        -- thresholds; the resolved-hand event drives active-deck XP. All
        -- of it gates on the system unlock (first gauntlet clear), so no
        -- silent state accrues before decks exist — deck progression
        -- starts from zero the moment the shove is first beaten.
        if Decks.systemUnlocked(state) then
            local n_tables = self.pool:count()
            local gtype_id = tbl and tbl.game_type_id

            -- Lifetime counters: every resolution bumps hands_played; the
            -- rest fire on their conditional events. Bumped BEFORE
            -- checkPendingUnlocks so any threshold crossed by this hand
            -- unlocks immediately.
            state.lifetime_hands_played = (state.lifetime_hands_played or 0) + 1
            if r.delta > 0 then
                state.lifetime_money_won = (state.lifetime_money_won or 0) + r.delta
            elseif r.delta < 0 then
                state.lifetime_money_lost = (state.lifetime_money_lost or 0) + (-r.delta)
            end
            if r.won and r.tier == "jackpot" then
                state.lifetime_jackpot_count = (state.lifetime_jackpot_count or 0) + 1
            end
            if r.won and gtype_id == "mtt" then
                state.lifetime_mtt_hands_won = (state.lifetime_mtt_hands_won or 0) + 1
            end
            if n_tables >= 4 then
                state.lifetime_hands_at_4plus_tables = (state.lifetime_hands_at_4plus_tables or 0) + 1
            end

            -- XP grant for the active deck. Event carries everything the
            -- registered XP rules (parameterized by gtype / tier / etc.)
            -- can filter on.
            local bb           = (stake and stake.bb and stake.bb > 0) and stake.bb or nil
            local stake_tier_idx = stake and Lookups.indexById(Stakes, stake.id) or nil
            local base_cap = Constants.GAMEPLAY.FOCUS_BASE_CAPACITY
            local focus_cap = base_cap + ((self.ctx and self.ctx.focus_capacity) or 0)
            -- Hands played while OVER the focus cap — matches the Multitasker
            -- deck's overwhelmed identity (its unlock, mirroring its XP rule).
            if n_tables > focus_cap then
                state.lifetime_hands_overwhelmed = (state.lifetime_hands_overwhelmed or 0) + 1
            end
            self:_grantDeckXp({
                won            = r.won and true or false,
                delta          = r.delta,
                tier           = r.tier,
                bb_delta       = bb and (r.delta / bb) or 0,
                gtype          = gtype_id,
                stake_tier_idx = stake_tier_idx,
                n_tables       = n_tables,
                focus_capacity = focus_cap,
            })

            -- Newly-met unlock thresholds flip locked decks into the
            -- player's roster. Returns the list of newly-unlocked ids;
            -- effects cache only needs invalidating if anything actually
            -- unlocked.
            local newly = Decks.checkPendingUnlocks(state, self.game.unlock_rules)
            if #newly > 0 then
                self:invalidateEffects()
            end
        end
    end

    -- Resolutions just mutated per-table state (incl. MttSession fields
    -- on tournament tables). Resync so a save mid-MTT-run
    -- captures the latest hand counter. Cheap (4 array writes per
    -- table; bounded by MAX_TABLES).
    self.pool:_syncStateList()
end

-- Grant XP to the active deck for one resolved hand. Returns true on a
-- level-up so the controller can invalidate the effects cache; the model
-- side handles the math + state writes.
function GrindController:_grantDeckXp(event)
    local _, leveled = Decks.gainXp(self.game.state, self.game.xp_rules, event)
    if leveled then
        self:invalidateEffects()
    end
end

-- ─── Purchase intents (called from view button handlers) ─────────────────────

-- Stacking run upgrade purchase. Each click bumps the upgrade's level by one
-- (up to its max_level). Cost for the next level is item.costs[N+1], multiplied
-- by ctx.run_upgrade_cost_mult so the cheap_coaching catalog perk discounts
-- every run-upgrade buy. Returns true on a successful level-up.
-- True if the optional `requires` field on a catalog/run-upgrade item is
-- met by the player's owned_items list. nil/missing → unconditional.
function GrindController:_requirementMet(requires_id)
    if not requires_id then return true end
    for _, owned_id in ipairs(self.game.state.owned_items) do
        if owned_id == requires_id then return true end
    end
    return false
end

-- True if the player has already banked the (stake, gtype) chip bounty
-- this run. Mirrors the bountyKey format used by the resolution loop —
-- keep both writers using the same key format.
function GrindController:bountyBanked(stake_id, game_type_id)
    local key = bountyKey(stake_id, game_type_id)
    local cur = self.game.state.stakes_won_this_run and self.game.state.stakes_won_this_run[key]
    local count = 0
    if cur == true then
        count = 1
    elseif type(cur) == "number" then
        count = cur
    end
    return count >= 1
end

function GrindController:antiBountyBanked(stake_id, game_type_id)
    local key = bountyKey(stake_id, game_type_id)
    local cur = self.game.state.anti_stakes_won_this_run and self.game.state.anti_stakes_won_this_run[key]
    return cur == true
end

-- THE bounty math — base stake.chip_award scaled by ctx.chip_award_mult,
-- then any flat ctx.jackpot_chip_add (Pen) added on top. Every award
-- site (cash jackpot, tournament win) and every display (sidebar "+N"
-- badge) calls this, so payouts can never drift from what's advertised.
function GrindController:bountyAward(stake_id)
    local stake = Lookups.findById(Stakes,stake_id)
    if not stake then return 0 end
    local mult  = (self.ctx and self.ctx.chip_award_mult) or 1
    local bonus = (self.ctx and self.ctx.jackpot_chip_add) or 0
    return math.floor((stake.chip_award or 0) * mult + 0.5) + bonus
end

function GrindController:antiBountyAward(stake_id)
    local stake = Lookups.findById(Stakes, stake_id)
    if not stake then return 0 end
    return stake.anti_chip_award or 0
end

function GrindController:buyRunUpgrade(upgrade_id)
    local state = self.game.state
    -- Find item by id.
    local upgrade
    for _, u in ipairs(RunUpgrades) do
        if u.id == upgrade_id then upgrade = u; break end
    end
    if not upgrade then return false end
    if not self:_requirementMet(upgrade.requires) then return false end

    local current = state.run_upgrade_levels[upgrade_id] or 0
    local max_lvl = self:getRunUpgradeMaxLevel(upgrade)
    if current >= max_lvl then return false end

    local cost_mult = (self.ctx and self.ctx.run_upgrade_cost_mult) or 1
    local cost = 0
    if upgrade.costs then
        if current + 1 <= #upgrade.costs then
            cost = upgrade.costs[current + 1]
        else
            local last_cost = upgrade.costs[#upgrade.costs] or 0
            cost = last_cost * 3.0
        end
    end
    cost = cost * cost_mult
    if state.bankroll < cost then return false end

    state.bankroll = state.bankroll - cost
    state.run_upgrade_levels[upgrade_id] = current + 1
    HandAnalytics.recordEvent({
        t            = love.timer.getTime(),
        type         = "run_upgrade",
        item_id      = upgrade_id,
        level        = current + 1,
        cost_dollars = cost,
        bankroll     = state.bankroll,
    })

    -- Grant deck XP for purchasing upgrade
    self:_grantDeckXp({
        type         = "run_upgrade",
        item_id      = upgrade_id,
        level        = current + 1,
        cost_dollars = cost,
    })

    -- Lifetime counter drives the Investor deck's unlock. Gated like the
    -- other lifetime_* counters (accrue only once the deck system exists).
    if Decks.systemUnlocked(state) then
        state.lifetime_upgrades_bought = (state.lifetime_upgrades_bought or 0) + 1
        Decks.checkPendingUnlocks(state, self.game.unlock_rules)
    end

    self:invalidateEffects()
    self:_playNamed("upgrade_purchased")
    return true
end

-- View helper: returns the current owned level (0 = unowned) and the next
-- level's discounted cost (for the BUY button label). Pass-through to data;
-- views shouldn't reach into state.run_upgrade_levels directly.
function GrindController:getRunUpgradeLevel(upgrade_id)
    return self.game.state.run_upgrade_levels[upgrade_id] or 0
end

-- Highest run-upgrade level worth buying right now. For fill upgrades
-- (fill_scaled) this is FULLY DYNAMIC: the largest fill_window.complete
-- among the stakes currently BUYABLE (stakeAvailable — ultra excluded, it's
-- unfillable), clamped to the cost array. Nothing is hardcoded per tier or
-- act: add/remove/re-gate stakes and the cap follows on its own. Non-fill
-- upgrades keep their static max_level. Investor's bonus levels stack on top.
function GrindController:getRunUpgradeMaxLevel(upgrade)
    if not upgrade then return 0 end
    local max_lvl
    if upgrade.fill_scaled then
        local best = 0
        for _, s in ipairs(Stakes) do
            if s.band ~= "ultra" and self:stakeAvailable(s) then
                local complete = (s.fill_window and s.fill_window.complete) or 0
                if complete > best then best = complete end
            end
        end
        local cap = (upgrade.costs and #upgrade.costs) or best
        max_lvl = math.min(best, cap)
    else
        max_lvl = upgrade.max_level or 1
    end
    max_lvl = max_lvl + ((self.ctx and self.ctx.run_upgrade_bonus_levels) or 0)
    return max_lvl
end

function GrindController:getRunUpgradeNextCost(upgrade)
    if not upgrade then return nil end
    local current = self.game.state.run_upgrade_levels[upgrade.id] or 0
    local max_lvl = self:getRunUpgradeMaxLevel(upgrade)
    if current >= max_lvl then return nil end
    local cost = 0
    if upgrade.costs then
        if current + 1 <= #upgrade.costs then
            cost = upgrade.costs[current + 1]
        else
            local last_cost = upgrade.costs[#upgrade.costs] or 0
            cost = last_cost * 3.0
        end
    end
    return cost * ((self.ctx and self.ctx.run_upgrade_cost_mult) or 1)
end

-- Strand check: would spending `cost` leave the player unable to play any
-- table — no felt to grind back from? True only when there are no
-- playable tables (stack > 0) AND the post-purchase bankroll is below the
-- cheapest stake's adjusted buy-in. Used by the upgrades tab to disable
-- buttons that would silently end the run.
-- Effective buy-in multiplier for a given stake: the unbounded scalar
-- (Discount Sits) times any tier-scoped multipliers (High Roller halves
-- T4+ buy-ins) whose bounds include this stake's tier index. The one
-- place buy-in discounting resolves, so every buy site agrees.
function GrindController:buyInMultFor(stake)
    local ctx  = self.ctx
    local mult = (ctx and ctx.buy_in_mult) or 1
    if ctx and ctx.buy_in_mult_tiered and stake then
        local idx = Lookups.indexById(Stakes, stake.id)
        for _, e in ipairs(ctx.buy_in_mult_tiered) do
            local tier_ok = (not e.tier_min or (idx and idx >= e.tier_min))
                        and (not e.tier_max or (idx and idx <= e.tier_max))
            if tier_ok then mult = mult * (e.value or 1) end
        end
    end
    return mult
end

-- Cheapest table the player could open right now (min buy-in x buy_in_mult).
function GrindController:_cheapestBuyIn()
    local cheapest
    for _, s in ipairs(Stakes) do
        local bi = (s.buy_in or 0) * self:buyInMultFor(s)
        if not cheapest or bi < cheapest then cheapest = bi end
    end
    return cheapest
end

-- True when no open table still holds chips (nothing left in play).
function GrindController:_noLiveTables()
    for _, t in ipairs(self.pool.tables) do
        if (t.stack or 0) > 0 then return false end
    end
    return true
end

function GrindController:wouldStrandRun(cost)
    if not cost or cost <= 0 then return false end
    if not self:_noLiveTables() then return false end
    local cheapest = self:_cheapestBuyIn()
    if not cheapest then return false end
    return (self.game.state.bankroll - cost) < cheapest
end

-- TUTORIAL builds hide SHOVE entirely until the first-ever run banks
-- SHOVE_UNLOCK_CHIPS — the prestige reveals itself when there's something
-- worth banking (the shove_ready hint fires at the same moment). Anyone
-- who has shoved before keeps the button from hand one. No softlock:
-- quick-reset doesn't gate on chips, so a stranded sub-threshold player
-- still has the rescue.
function GrindController:shoveUnlocked()
    if not Constants.FEATURES.TUTORIAL then return true end
    local state = self.game.state
    return (state.shove_count or 0) > 0
        or (state.chips_this_run or 0) >= Constants.GAMEPLAY.SHOVE_UNLOCK_CHIPS
end

-- Bricked: nothing in play and can't afford even the cheapest buy-in — the
-- soft-stuck state the quick-reset rescues.
function GrindController:isStranded()
    if not self:_noLiveTables() then return false end
    local cheapest = self:_cheapestBuyIn()
    if not cheapest then return false end
    return self.game.state.bankroll < cheapest
end

-- Whether the no-cost quick-reset should be offered: bricked and past the
-- intro handicap (owns the Poster). Chips don't gate it — :quickReset banks
-- this run's chips first, so a bricked player who can't yet afford anything in
-- the shop can still bail to a fresh stake without losing them. Before the
-- Poster a reset just lands you right back here, and the first bust should
-- teach Shove + the free Poster, not this. Under FEATURES.TUTORIAL there is
-- no scripted intro to protect, so the rescue is available from the start.
function GrindController:canQuickReset()
    local state = self.game.state
    if not Constants.FEATURES.TUTORIAL then
        local has_poster = false
        for _, id in ipairs(state.owned_items) do
            if id == "poker_poster" then has_poster = true; break end
        end
        if not has_poster then return false end
    end
    return self:isStranded()
end

-- Spot the player a fresh starting stake without a Shove. Banks this run's
-- chips first (so a bricked player who can't afford the shop yet doesn't lose
-- them), then mirrors the post-bust run reset: wipe the run, re-seed starting
-- perks, rebuild the pool. Caller persists.
function GrindController:quickReset()
    local state = self.game.state
    state.chips = state.chips + (state.chips_this_run or 0)
    state.anti_chips = (state.anti_chips or 0) + (state.anti_chips_this_run or 0)
    state:resetRun()
    self:invalidateEffects()
    state:applyStartingPerks(self.ctx)
    self.pool:rebuildFromState(self.ctx)
end

function GrindController:buyCatalogItem(item_id)
    local item
    for _, it in ipairs(Catalog) do
        if it.id == item_id then item = it; break end
    end
    -- Defensive unlock gate: a locked item can't be bought even if the UI is
    -- bypassed. Reuses the same registry the catalog silhouettes check.
    if item and item.unlock and self.game.unlock_rules
       and not self.game.unlock_rules:check(item.unlock, self.game.state) then
        return false
    end
    local chips_before = self.game.state.chips
    if not self.game.state:tryBuyCatalogItem(item) then return false end
    HandAnalytics.recordEvent({
        t          = love.timer.getTime(),
        type       = "catalog",
        item_id    = item_id,
        cost_chips = chips_before - self.game.state.chips,
        chips      = self.game.state.chips,
    })
    self:invalidateEffects()
    self:_playNamed("upgrade_purchased")
    return true
end

function GrindController:corruptCatalogItem(item_id)
    local item
    for _, it in ipairs(Catalog) do
        if it.id == item_id then item = it; break end
    end
    if not self.game.state:tryCorruptItem(item) then return false end
    self:invalidateEffects()
    self:_playNamed("upgrade_purchased")
    return true
end

-- Bankroll-cost-to-open. Adding a table deducts the stake's buy-in (100bb)
-- Whether a stake is offered to the player right now. Low band is always
-- available; mid/high/ultra gate behind their milestone flag (see
-- data/constants STAKE_BAND_GATE), and the whole non-low ladder is off in
-- the prototype build (FEATURES.HIGH_TIER_STAKES). Single source of truth
-- for stake availability — the add-table buttons and the win-chance / stack-
-- rate range tooltips all route through it so they never disagree.
function GrindController:stakeAvailable(stake)
    local band = (stake and stake.band) or "low"
    local gate = Constants.STAKE_BAND_GATE[band]
    if not gate then return true end
    if not Constants.FEATURES.HIGH_TIER_STAKES then return false end
    return self.game.state[gate] == true
end

-- from bankroll, optionally discounted by ctx.buy_in_mult (Discount Sits
-- catalog perk). Game type doesn't change the buy-in. Returns false if
-- not affordable / pool full / unknown stake-or-gametype.
function GrindController:addTable(stake_id, game_type_id)
    if self.pool:count() >= self:tableSlotsCap() then return false end
    local stake = Lookups.findById(Stakes,stake_id)
    if not stake then return false end
    local mult = self:buyInMultFor(stake)
    local cost = (stake.buy_in or 0) * mult
    if self.game.state.bankroll < cost then return false end
    self.game.state.bankroll = self.game.state.bankroll - cost
    self.pool:addTable(stake_id, game_type_id or "six_max", self.ctx)
    self:invalidateEffects()
    -- Any cash left on the table after the discount counts as the table's
    -- starting stack — Table:new already seeds stack to stake.buy_in (the
    -- 100bb cap), so the discount effectively lets the player keep the
    -- difference in bankroll. Net: same stack value, less paid up front.

    -- Stash a pending bankroll → YOU chip burst on the just-added table;
    -- :update emits it once the view has populated panel positions.
    local new_tbl = self.pool.tables[#self.pool.tables]
    if new_tbl then new_tbl._pending_buyin = cost end
    self:_playNamed("table_added")
    return true
end

-- Sum of live stacks at active tables. The "TIED UP" reading on the
-- top bar — money that's not gone, just locked on the felt. Cash
-- tables: tracks the current stack value (which fluctuates with
-- wins/losses), since cash-out refunds that exact amount. Chip-stack
-- tournaments: tracks the buy-in (what was actually paid to sit
-- down), since chip-pile growth during a tournament doesn't convert
-- to cash until the finish-position payout settles at the end. A
-- busted or freshly-settled tournament has tbl.stack = 0 → no
-- contribution either way.
function GrindController:tiedUp()
    local total = 0
    for _, t in ipairs(self.pool.tables) do
        local stack = t.stack or 0
        if stack <= 0 then
            -- Busted or post-settle — nothing locked here.
        else
            local gtype = Lookups.findById(GameTypes, t.game_type_id)
            if gtype and gtype.chip_stack_table then
                local stake = Lookups.findById(Stakes, t.stake_id)
                total = total + ((stake and stake.buy_in) or 0)
            else
                total = total + stack
            end
        end
    end
    return total
end

-- Removing a table refunds the *current stack* (cash-out semantics).
-- Lost it all? You get $0 back. Sitting on a freshly bought-in table
-- with no hands played? Full buy-in returns.
--
-- Chip-stack tournaments: closing mid-tournament forfeits the buy-in.
-- Chips on the table are tournament chips — they don't convert to cash
-- until the finish-position payout settles. A brand-new tournament
-- table (no hand dealt yet → mtt not yet playing) still refunds the
-- buy-in so accidental adds aren't punitive; a busted or post-settle
-- table has stack = 0 already.
function GrindController:_finalizeRemove(idx)
    local t = self.pool.tables[idx]
    if not t then return false end
    local gtype = Lookups.findById(GameTypes, t.game_type_id)
    local refund
    if gtype and gtype.chip_stack_table and t.mtt and t.mtt:isPlaying() then
        refund = 0
    else
        refund = t.stack or 0
    end
    self:_emitCashOutChips(t, refund)
    self.pool:removeTable(idx)
    self.game.state.bankroll = self.game.state.bankroll + refund
    self:invalidateEffects()
    return true
end

function GrindController:removeTable(idx)
    local t = self.pool.tables[idx]
    if not t then return false end
    -- Mid-hand → defer close until the hand resolves and we're idle again.
    -- The update loop scans for pending_close + idle each frame.
    if t.state ~= "idle" then
        t.pending_close = true
        return true
    end
    return self:_finalizeRemove(idx)
end

-- Cash out every active table. Idle tables close now; busy tables get
-- their pending_close flag set and finalise once they return to idle.
function GrindController:cashOutAll()
    if self.pool:count() == 0 then return false end
    -- Reverse iteration: synchronous closes shift indices.
    for i = #self.pool.tables, 1, -1 do
        self:removeTable(i)
    end
    return true
end

-- Stake-up: cash out the current stack and pay the new buy-in (optionally
-- discounted by ctx.buy_in_mult). Net cost = new_buy_in - current_stack.
-- Bankroll must cover that delta. Table:setStake then resets the table's
-- stack to the new buy-in.
function GrindController:changeTableStake(idx, new_stake_id)
    local t = self.pool.tables[idx]
    if not t then return false end
    local new_stake = Lookups.findById(Stakes,new_stake_id)
    if not new_stake then return false end
    -- Never let a table cross into a band the player hasn't unlocked (the
    -- STAKE↑ path must honor the same gate as the add-table buttons).
    if not self:stakeAvailable(new_stake) then return false end
    local mult   = self:buyInMultFor(new_stake)
    local refund = t.stack or 0
    local cost   = (new_stake.buy_in or 0) * mult
    local diff   = cost - refund
    if diff > 0 and self.game.state.bankroll < diff then return false end
    self.game.state.bankroll = self.game.state.bankroll - diff
    self.pool:changeStake(idx, new_stake_id, self.ctx)
    self:_playNamed("stake_up_flourish")
    return true
end

-- Toggle a table's autonomous-cursor opt-out flag. Persists via
-- TablePool's _syncStateList → state.active_table_mutes.
function GrindController:toggleCursorMute(idx)
    local t = self.pool:get(idx)
    if not t then return false end
    t.cursor_muted = not (t.cursor_muted == true)
    self.pool:_syncStateList()
    return true
end

-- Toggle the per-table cursor-rebuy opt-out. Only meaningful when the
-- catalog perk `cursor_rebuy_unlocked` is owned (the [R] header toggle
-- is hidden otherwise). Persists via _syncStateList →
-- state.active_table_rebuy_mutes.
function GrindController:toggleCursorRebuyMute(idx)
    local t = self.pool:get(idx)
    if not t then return false end
    t.cursor_rebuy_muted = not (t.cursor_rebuy_muted == true)
    self.pool:_syncStateList()
    return true
end

-- Click-to-deal entry point. Triggers the per-hand state machine on a
-- specific table. Returns false if the table is already animating a hand
-- or doesn't exist.
function GrindController:dealHand(idx)
    local t = self.pool:get(idx)
    if not t or t:isBusy() then return false end
    -- Stack must be positive to play. Hitting 0 means the table is busted
    -- and the player must :rebuyTable before dealing again.
    if (t.stack or 0) <= 0 then return false end
    if Constants.DEBUG.HAND_ANALYTICS then
        t._hand_start_t = love.timer.getTime()
    end
    local ok = t:deal(self.ctx)
    if ok then self:_emitDealChips(t) end
    return ok
end

-- Defensive sound dispatch — single line so each call site stays terse.
-- opts is an optional table forwarded to SoundService.playNamed
-- (volume_mult etc.) for tier-scaled feedback.
function GrindController:_playNamed(name, opts)
    local sounds = self.game.sounds
    if sounds and sounds.playNamed then sounds.playNamed(name, opts) end
end

-- ── Chip-flight emission helpers ─────────────────────────────────────
-- Each helper composes a denomination breakdown and pushes a burst
-- descriptor onto self.pending_bursts. GrindView drains the queue each
-- frame, builds render closures, and dispatches to services/FlightSystem.
-- This file holds NO views/* require — the controller stays in the data
-- layer, the view owns rendering.
--
-- Anchors come from services/AnchorRegistry, written by views/TablePanel
-- per draw under TableModel.anchorKey(t, slot). The bankroll-pile anchor
-- is registered separately by GrindView under "bankroll".

local function _paletteForStake(stake_id)
    return ChipData.stake_palettes[stake_id] or ChipData.full_palette
end

-- Bottom-edge fallback for "this thing has no anchor yet" cases (first
-- frame after table add — the view hasn't drawn yet so positions aren't
-- known). Reads viewport from DI rather than poking love.graphics.
function GrindController:_offscreenAnchor(x_hint)
    local v = self.game.viewport or { w = 0, h = 0 }
    return { x_hint or (v.w * 0.5), v.h + 80 }
end

local function _anchor(t, slot)
    return AnchorRegistry.get(TableModel.anchorKey(t, slot))
end

function GrindController:_emitDealChips(t)
    if not t then return end
    local you = _anchor(t, "you")
    local pot = _anchor(t, "pot")
    if not you or not pot then return end
    local amount = math.abs(t.outcome_delta or 0)
    if amount <= 0 then return end
    local chips = Denoms.breakdown(amount, ChipData.denominations,
                                   _paletteForStake(t.stake_id),
                                   ChipData.tier_chip_target,
                                   t.outcome_tier or "medium")
    self:_queueBurst(you, pot, chips, { arrival_sound = "chip_land_pot" })
end

function GrindController:_emitBuyInChips(t, amount)
    if not t or amount <= 0 then return end
    local you     = _anchor(t, "you")
    local bank_xy = AnchorRegistry.get("bankroll")
    if not you or not bank_xy then return end
    local stake   = Lookups.findById(Stakes,t.stake_id)
    local bb      = (stake and stake.bb) or 1
    local palette = _paletteForStake(t.stake_id)
    local tier    = Denoms.tierFromUnit(amount / bb)
    local chips   = Denoms.breakdown(amount, ChipData.denominations, palette, ChipData.tier_chip_target, tier)
    self:_queueBurst(bank_xy, you, chips, { arrival_sound = "chip_land_you" })
end

function GrindController:_emitCashOutChips(t, amount)
    if not t or amount <= 0 then return end
    local you     = _anchor(t, "you")
    local bank_xy = AnchorRegistry.get("bankroll")
    if not you or not bank_xy then return end
    local stake   = Lookups.findById(Stakes,t.stake_id)
    local bb      = (stake and stake.bb) or 1
    local palette = _paletteForStake(t.stake_id)
    local tier    = Denoms.tierFromUnit(amount / bb)
    local chips   = Denoms.breakdown(amount, ChipData.denominations, palette, ChipData.tier_chip_target, tier)
    self:_queueBurst(you, bank_xy, chips, { arrival_sound = "chip_land_bankroll" })
end

-- Tournament cash-out: pot/center → bankroll pile. Same shape as cash-out
-- but anchored to the table's pot center (the chip pile from the final
-- hand) so the burst visually originates from where the action ended.
function GrindController:_emitMttPayoutChips(t, amount)
    if not t or amount <= 0 then return end
    local bank_xy = AnchorRegistry.get("bankroll")
    if not bank_xy then return end
    local v       = self.game.viewport or { w = 0, h = 0 }
    local pot     = _anchor(t, "pot")
    local center  = _anchor(t, "center")
    local source  = pot
                    or center
                    or { v.w * 0.5, v.h * 0.5 }
    local stake   = Lookups.findById(Stakes,t.stake_id)
    local bb      = (stake and stake.bb) or 1
    local palette = _paletteForStake(t.stake_id)
    local tier    = Denoms.tierFromUnit(amount / bb)
    local chips   = Denoms.breakdown(amount, ChipData.denominations, palette, ChipData.tier_chip_target, tier)
    self:_queueBurst(source, bank_xy, chips, { arrival_sound = "chip_land_bankroll" })
end

function GrindController:_emitResolutionChips(r, tbl, overflow_amount)
    if not tbl then return end
    local you_xy = _anchor(tbl, "you")
    local pot_xy = _anchor(tbl, "pot")
    if not you_xy or not pot_xy then return end
    local palette = _paletteForStake(tbl.stake_id)
    local tier    = r.tier or "medium"
    -- Tier-scaled visible chip-count cap (data/chips.lua). Jackpots
    -- fountain bigger than the default; tinies stay contained.
    local burst_cap = (ChipData.tier_burst_cap and ChipData.tier_burst_cap[tier])
    -- Per-stake chip tint (data/stake_themes.lua) — T6 = warm gold cast,
    -- T1 = desaturated dim, etc. Multiplied into the chip body color
    -- inside Chips.drawChip.
    local stake_theme = StakeThemes[tbl.stake_id]
    local chip_tint   = stake_theme and stake_theme.chip_tint

    -- Skip the main pot-to-winner burst when poker theater is on — the
    -- script's pot_push anim handler emits that burst with the correct
    -- visible-pot amount and timing. The overflow spill (pot → bankroll
    -- when stack caps) stays unconditional because the script doesn't
    -- model stack-cap overflow.
    local theater_on = Constants.FEATURES and Constants.FEATURES.POKER_THEATER

    if not theater_on and r.delta > 0 then
        local chips = Denoms.breakdown(r.delta, ChipData.denominations, palette, ChipData.tier_chip_target, tier)
        self:_queueBurst(pot_xy, you_xy, chips, {
            arrival_sound = "chip_land_you",
            max_per_event = burst_cap,
            chip_tint     = chip_tint,
        })
    elseif not theater_on and r.delta < 0 then
        local chips = Denoms.breakdown(-r.delta, ChipData.denominations, palette, ChipData.tier_chip_target, tier)
        -- Loss → chips fly to the winning opponent's seat (their cards).
        -- Falls back to off-screen if the panel hasn't drawn yet (first
        -- frame after table add) so the burst still has a destination.
        local target_xy
        if tbl.opponent_idx then
            target_xy = _anchor(tbl, "opp_" .. tbl.opponent_idx)
        end
        target_xy = target_xy or self:_offscreenAnchor(pot_xy[1])
        self:_queueBurst(pot_xy, target_xy, chips, {
            arrival_sound = "chip_land_pot",
            max_per_event = burst_cap,
            chip_tint     = chip_tint,
        })
    end

    if overflow_amount and overflow_amount > 0 then
        local v = self.game.viewport or { w = 0, h = 0 }
        local bank_xy = AnchorRegistry.get("bankroll")
                        or { v.w * 0.5, v.h - 30 }
        local chips = Denoms.breakdown(overflow_amount, ChipData.denominations,
                                       ChipData.full_palette,
                                       ChipData.tier_chip_target,
                                       Denoms.tierFromAmount(overflow_amount))
        self:_queueBurst(you_xy, bank_xy, chips, { arrival_sound = "chip_land_bankroll" })
    end
end

-- Refill a busted table's stack to a fresh 100bb buy-in by spending from
-- bankroll. No-op if the table isn't actually busted, or if the player
-- can't afford the rebuy.
function GrindController:rebuyTable(idx)
    local t = self.pool:get(idx)
    if not t then return false end
    if (t.stack or 0) > 0 then return false end
    local stake = Lookups.findById(Stakes,t.stake_id)
    local buy_in = (stake and stake.buy_in) or 0
    local cost  = buy_in
    if self.ctx then
        local discount = self.ctx.rebuy_discount or 0
        cost = buy_in * (1.0 - discount)
        local free_chance = self.ctx.free_rebuy_chance or 0
        if free_chance > 0 and love.math.random() < free_chance then
            cost = 0
        end
    end
    local state = self.game.state
    if state.bankroll < cost then return false end
    state.bankroll = state.bankroll - cost
    t.stack = buy_in
    -- Tournament tables: rebuy is also "register again" — reset the
    -- per-tournament counter so the next DEAL starts a fresh 8-hand run.
    -- Sync the parallel save arrays so the next autosave tick captures
    -- the post-rebuy state cleanly.
    if t.mtt then t.mtt:reset() end
    self.pool:_syncStateList()
    -- Grant deck XP for rebuy
    self:_grantDeckXp({
        type = "table_rebuy",
    })
    -- Lifetime counter drives the Short Stack deck's unlock. Gated like the
    -- other lifetime_* counters (accrue only once the deck system exists).
    if Decks.systemUnlocked(state) then
        state.lifetime_rebuys = (state.lifetime_rebuys or 0) + 1
        Decks.checkPendingUnlocks(state, self.game.unlock_rules)
    end
    -- Bankroll → YOU stack chip burst (table positions are already known
    -- because the table has been on screen long enough to bust).
    self:_emitBuyInChips(t, buy_in)
    self:_playNamed("rebuy_clack")
    -- Auto-deal the first hand so REBUY is a one-click flow (was two:
    -- click REBUY, then click DEAL). The cursor swarm picks up subsequent
    -- hands as usual.
    self:dealHand(idx)
    return true
end

-- Map per-hand state-machine transitions to sound names. Called from
-- update() with (prev_state, new_state, table). Tables share a single
-- audio queue (sounds clone-on-play), so multiple tables' transitions in
-- the same frame don't cut each other off.
function GrindController:_playStateTransitionSound(_prev, new_state, t)
    local sounds = self.game.sounds
    if not sounds or not sounds.playNamed then return end

    if new_state == "dealing" or new_state == "flop"
       or new_state == "turn" or new_state == "river" then
        sounds.playNamed("card_dealt")
    elseif new_state == "showdown" then
        sounds.playNamed("hole_card_flip")
    elseif new_state == "settling" then
        -- Tier-keyed pot sound: a small win clicks like one chip; a jackpot
        -- lands like a stack with coins layered. data/sounds.lua defines all
        -- 8 entries (4 tiers × win/loss).
        local tier = t.outcome_tier or "medium"
        local key  = (t.outcome_won and "pot_won_" or "pot_lost_") .. tier
        sounds.playNamed(key)
    end
end

-- SHOVE-button intent. Banks the run's pending chips (locked-in bounties
-- only convert to spendable chips if the player actually pulls the trigger)
-- and flips the state machine to the gauntlet. The view dispatches this
-- on click; chips_this_run is NOT zeroed here — the shove state reads it
-- post-gauntlet for the "you banked N chips this run" readout, and the
-- post-modal reset zeros it.
function GrindController:initiateShove()
    local state = self.game.state
    state.chips = state.chips + (state.chips_this_run or 0)
    state.anti_chips = (state.anti_chips or 0) + (state.anti_chips_this_run or 0)
    self.game.state_machine:switch("shove")
end

-- Convenience: deal every idle table in one call. Useful as a future
-- "auto-play" upgrade hook and as a debug shortcut.
function GrindController:dealAll()
    local n = 0
    for _, t in ipairs(self.pool.tables) do
        if not t:isBusy() and (t.stack or 0) > 0 then
            if t:deal(self.ctx) then n = n + 1 end
        end
    end
    return n
end

return GrindController
