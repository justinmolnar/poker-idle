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
local ShoveRate = require("models.shove_rate")
local TableModel     = require("models.Table")            -- only for anchorKey()
local TableGrid      = require("models.table_grid")       -- board cells, for bump direction
local Pop            = require("services.Pop")            -- shared-clock bump envelopes
local StatusData     = require("data.statuses")       -- shared slam/shove timing
local Decks          = require("models.Decks")
local Catalog        = require("data.catalog")
local RunUpgrades    = require("data.run_upgrades")
local ProcData       = require("data.procs")
local OutcomeMath    = require("models.outcome_math")
local Stakes         = require("data.stakes")
local GameTypes      = require("data.game_types")
local Constants      = require("data.constants")
local ChipData       = require("data.chips")
local FeedbackIntensity = require("data.feedback_intensity")
local Denoms         = require("services.DenominationBreakdown")
local AnchorRegistry = require("services.AnchorRegistry")
local AwardGlow      = require("views.AwardGlow")
local StakeThemes    = require("data.stake_themes")
local Lookups        = require("utils.lookups")
local HandAnalytics  = require("services.HandAnalytics")
local Format         = require("utils.format")
local CursorPool     = require("services.CursorPool")


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
    self.pool = TablePool:new(game.state, self.ctx, game.poker_events, game.effects,
                              game.event_bus)

    -- A table announces its own transitions; we just make the noise. This
    -- replaces a per-frame snapshot of every table's state plus a diff pass
    -- to work out what had moved, and it catches the transitions that
    -- snapshot structurally could not see: a deal, which happens between
    -- frames, and a hand force-resolved by a proc, which used to need its
    -- own patched-in call at the payload.
    if game.event_bus then
        game.event_bus:subscribe("table_state_changed", function(e)
            self:_playStateTransitionSound(e.from, e.to, e.table)
        end)
    end
    return self
end

-- ── "Pot $X ×N" suffix for the resolution floater ─────────────────────
-- Shows the pot that was on the felt and how much items multiplied it,
-- so the player understands why they got more (or less) than the pot.
-- Omitted when the multiplier rounds to exactly 1× (no item effect).
local function _multSuffix(r)
    if not r then return "" end
    local pot = r.felt_pot or 0
    if pot <= 0 then return "" end

    local payout = math.abs(r.delta or 0)
    -- The player wins the pot minus their own contribution (half the
    -- pot in a heads-up). But outcome_delta is the NET gain/loss after
    -- items scale it.  The multiplier the player cares about is
    -- payout / pot — "the pot said $44, I got $88, that's x2".
    local mult = payout / pot
    if math.abs(mult - 1) < 0.005 then return "" end

    local pot_str = Format.moneyExact(pot)
    local mult_str
    if mult >= 10 or mult <= 0.1 then
        mult_str = string.format("x%.0f", mult)
    else
        mult_str = string.format("x%.2f", mult)
    end
    return string.format("\n%s %s", pot_str, mult_str)
end

-- Push a chip-flight intent onto the queue. GrindView drains this each
-- frame. Source/dest are { x, y } pairs (or nil — burst is dropped). chips
-- is the denomination-index list from DenominationBreakdown.
function GrindController:_queueBurst(source, dest, chips, options)
    if not source or not dest or not chips or #chips == 0 then return end
    self.pending_bursts[#self.pending_bursts + 1] = {
        -- "fly" = loose burst toward a point, "stack" = slot-to-slot
        -- between two real piles. GrindView dispatches on this.
        kind    = (options and options.kind) or "fly",
        source  = source,
        dest    = dest,
        chips   = chips,
        options = options,
    }
end

-- Push a chip-SCATTER intent (an explosion out of one point, no
-- destination) onto the same queue. GrindView dispatches on `kind`.
-- Same contract as _queueBurst otherwise: chips is a denomination-index
-- list, the view owns every rendering decision.
function GrindController:_queueScatter(origin, chips, options)
    if not origin or not chips or #chips == 0 then return end
    self.pending_bursts[#self.pending_bursts + 1] = {
        kind    = "scatter",
        source  = origin,
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
-- Bucket the owned procs by trigger, once per rollup. _fireProcs then
-- does a table lookup instead of scanning every proc on every hand.
--
-- It also (re)subscribes, which is the point: the trigger names come out of
-- data/procs.lua and nothing here enumerates them. Gameplay announces what
-- happened; whether any proc cares is decided by the data. Adding a trigger
-- is an edit to that file plus somewhere in the game that publishes the
-- name, and no code in this controller changes at all.
function GrindController:_rebuildProcIndex()
    local index = {}
    for _, id in ipairs((self.ctx and self.ctx.procs) or {}) do
        local proc = ProcData[id]
        if proc and proc.trigger then
            local list = index[proc.trigger]
            if not list then list = {}; index[proc.trigger] = list end
            -- Carry the id so feedback can name the item that fired.
            list[#list + 1] = { id = id, def = proc }
        end
    end
    self.proc_index = index

    local bus = self.game and self.game.event_bus
    if not bus then return end
    -- Drop the old subscriptions before taking new ones, or every rollup
    -- would stack another copy and a proc would fire once per rollup.
    for _, tok in ipairs(self._proc_tokens or {}) do bus:unsubscribe(tok) end
    local tokens = {}
    for trigger in pairs(index) do
        tokens[#tokens + 1] = bus:subscribe(trigger, function(e)
            self:_fireProcs(trigger, e.table, e)
        end)
    end
    self._proc_tokens = tokens
end

-- Fire every proc watching `trigger`. `extra` carries whatever the trigger
-- knows that a selector or payload might want: `out` (the resolution list
-- being iterated, for resolve-style payloads), `n`, `busted_total`.
-- Say what happened. Whether anything listens is not this function's
-- business, and the name is a fact about the game rather than the name of a
-- mechanism: "a stack was lost here", not "run the cooler proc".
--
-- Delivered immediately rather than at the frame's drain, because some of
-- these are announced from inside the resolution loop and a listener may
-- add to the very list that loop is walking (the zoom cascade settles other
-- tables and their resolutions have to be paid this frame, not dropped).
-- Immediate delivery is safe here: we are not inside a dispatch, so the bus
-- queue still flattens any events the listeners themselves raise.
function GrindController:_announce(name, event)
    local bus = self.game and self.game.event_bus
    if not bus then return end
    bus:publish(name, event)
    bus:drain()
end

function GrindController:_fireProcs(trigger, source_tbl, extra)
    local list = self.proc_index and self.proc_index[trigger]
    if not list then return end
    local reg = self.game.procs
    if not reg then return end
    for _, entry in ipairs(list) do
        -- WHO it can happen to. A proc that belongs to one mode's identity
        -- says so here; without this the 6-max cooler tilt fires when a
        -- Heads Up table loses a stack, and HU has no multiway cooler to
        -- lose (docs/gametype-identity-redesign.md: the cooler is "a real
        -- cost for the tank slot").
        local src = entry.def.source
        local ok = not (src and src.gtype)
                   or (source_tbl and source_tbl.game_type_id == src.gtype)
        if ok then
        local event = {
            kind   = trigger,
            source = source_tbl,
            pool   = self.pool,
            ctrl   = self,
            state  = self.game.state,
            ctx    = self.ctx,
            ghost  = entry.def.ghost,
            n      = (extra and extra.n) or 1,
            out    = extra and extra.out,
            busted_total = (extra and extra.busted_total) or 0,
        }
        local touched, hit = reg:fire(entry.def, event)
        if touched > 0 then
            -- Only procs that read as a BLOW get the fist or the shove.
            -- Not everything that reaches another table is violence: the
            -- printer chatters and those hands settle, and animating that
            -- as an assault says something the mechanic does not mean.
            if entry.def.impact ~= false then
                self:_bumpTargets(source_tbl, hit)
            end
            if entry.def.ghost then self:procFired(entry.def.ghost, source_tbl) end
            -- A proc may have put a status on a table that had none, and
            -- the save arrays hold per-table references. Re-sync so the
            -- new list is reachable from state (existing lists tick in
            -- place and need no help).
            self.pool:_syncStateList()
        end
        end
    end
end

-- Make the hit visible: the source table physically shoves the tables it
-- affected, and they rock away from it.
--
-- Direction comes from the board itself — tables own a cell, so the model
-- knows which way a neighbour lies without asking the view anything. One
-- target means a directed lunge; several means the source swells and
-- shoves them all at once, because a table cannot lunge four ways.
function GrindController:_bumpTargets(source_tbl, targets)
    if not targets or #targets == 0 then return end

    local sr, sc
    if source_tbl and source_tbl.slot then
        sr, sc = TableGrid.unpack(source_tbl.slot)
    end

    -- TWO MOTIONS, chosen by how many tables are being hit:
    --   one   -> BUMP. The source reaches over and shoves that table.
    --   many  -> SLAM. It can't shove four directions, so it drives a
    --            fist into the felt and everything around it jumps.
    -- A proc picks which one it gets by how it targets (see data/procs).
    local single = (#targets == 1 and targets[1] ~= source_tbl)

    -- Nothing reacts while the blow is still travelling. A slam connects
    -- when the fist lands; a bump connects at the top of its arc. Until
    -- then the struck tables sit still and show nothing of the status
    -- they have already taken (see Table.impact_wait).
    -- Contact is the END of the downswing (rise + strike), not the start
    -- of it — that is the frame the blow actually arrives.
    local cfg = single and (StatusData.shove or {}) or (StatusData.slam or {})
    local delay = (cfg.duration or 1) * ((cfg.rise or 0.4) + (cfg.strike or 0.06))

    for _, t in ipairs(targets) do
        if t ~= source_tbl and t.slot and sr then
            local tr, tc = TableGrid.unpack(t.slot)
            local dx, dy = tc - sc, tr - sr
            local len = math.sqrt(dx * dx + dy * dy)
            if len > 0 then
                self._pending_impacts = self._pending_impacts or {}
                self._pending_impacts[#self._pending_impacts + 1] = {
                    tbl = t, dx = dx / len, dy = dy / len, t_left = delay,
                }
                t.impact_wait = delay
            end
        end
    end

    if not source_tbl then return end

    if single and targets[1].slot and sr then
        -- BUMP: reach over and shove that one table.
        local tr, tc = TableGrid.unpack(targets[1].slot)
        local dx, dy = tc - sc, tr - sr
        local len = math.sqrt(dx * dx + dy * dy)
        if len > 0 then
            source_tbl.bump_dx, source_tbl.bump_dy = dx / len, dy / len
            source_tbl.bump_out, source_tbl.bump_slam = true, false
            source_tbl.shake_trauma = math.max(source_tbl.shake_trauma or 0, 0.7)
            Pop.trigger("tbl_bump:" .. (source_tbl._id or 0))
        end
    else
        -- SLAM: a fist into the felt, and everything around it jumps.
        source_tbl.bump_dx, source_tbl.bump_dy = 0, 1
        source_tbl.bump_out, source_tbl.bump_slam = false, true
        Pop.trigger("tbl_bump:"  .. (source_tbl._id or 0))
        Pop.trigger("tbl_shove:" .. (source_tbl._id or 0))
        -- Trauma is squared before it becomes pixels, so this needs to be
        -- high to read as a shudder rather than a twitch.
        source_tbl.shake_trauma = math.max(source_tbl.shake_trauma or 0, 1.0)
    end
end

-- Land any shockwaves whose travel time is up. Ticked once per frame
-- from :update, on raw dt — a blow crosses the board at the same speed
-- whatever pace the tables are running at.
function GrindController:_tickImpacts(dt)
    local list = self._pending_impacts
    if not list or #list == 0 then return end
    for i = #list, 1, -1 do
        local e = list[i]
        e.t_left = e.t_left - (dt or 0)
        local t = e.tbl
        if e.t_left <= 0 then
            -- Contact. Knocked away, rattled, and only NOW does whatever
            -- it was given become visible.
            t.bump_dx, t.bump_dy = e.dx, e.dy
            t.bump_out, t.bump_slam = false, false
            t.impact_wait  = 0
            t.shake_trauma = math.max(t.shake_trauma or 0, 0.9)
            Pop.trigger("tbl_bump:" .. (t._id or 0))
            table.remove(list, i)
        else
            t.impact_wait = e.t_left
        end
    end
end

-- Ghost + sound for a proc. itemFired keys off ctx.sources[kind], but
-- every proc shares the kind "proc", so that path would pop every proc
-- item's sprite at once. The proc names its own item instead.
function GrindController:procFired(item_id, tbl)
    local bus = self.game.event_bus
    if not bus or not item_id then return end
    local x, y, pw, ph
    local pos = tbl and AnchorRegistry.get(TableModel.anchorKey(tbl, "center"))
    if pos then x, y, pw, ph = pos[1], pos[2], pos[3], pos[4] end
    bus:publish("item_fired", { item_id = item_id, kind = "proc",
                                x = x, y = y, pw = pw, ph = ph })
end

function GrindController:invalidateEffects()
    local n_tables = self.pool and self.pool:count() or 0
    self.ctx = self.game.state:computeEffects(self.game.effects, Catalog, RunUpgrades, { active_tables_count = n_tables })
    -- Latch the transient ultra-unlock effect into persistent state so the
    -- Ultra band stays available (stakeAvailable reads state.ultra_unlocked).
    -- One-way — any effect granting it makes the unlock permanent.
    if self.ctx.ultra_unlocked then
        self.game.state.ultra_unlocked = true
    end
    self:_rebuildProcIndex()
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
    local cap      = self:currentFocusCapacity()
    local reduce   = (self.ctx and self.ctx.focus_penalty_reduce_mult) or 1
    local penalty  = Constants.GAMEPLAY.FOCUS_BASE_PENALTY * reduce
    local floor_v  = Constants.GAMEPLAY.FOCUS_FLOOR

    local extra = n - cap
    if extra <= 0 then return 1.0 end
    local mult = 1 - penalty * extra
    if mult < floor_v then mult = floor_v end
    return mult
end

-- Effective capacity — base + ctx bonus (no penalty math). THE single source:
-- the penalty math, the overwhelmed counter and the UI all read this, so they
-- cannot disagree about how many tables you can watch.
--
-- Floored, because capacity is a count of tables. Anything that scales run
-- upgrades (the Calculator perk, the Investor deck) multiplies the +1/level
-- that Focus grants, so 3 levels at +15% strength is 3.45 and the top bar
-- cheerfully offered "4 / 7.45 tables". You cannot watch 0.45 of a table. The
-- fractional part still accumulates and pays out when it crosses a whole
-- table, exactly like CursorPool already floors its swarm size.
function GrindController:currentFocusCapacity()
    local base_cap = Constants.GAMEPLAY.FOCUS_BASE_CAPACITY
    return base_cap + math.floor((self.ctx and self.ctx.focus_capacity) or 0)
end

function GrindController:update(dt)
    -- Proc budget is per frame too (services/ProcRegistry).
    if self.game.procs then self.game.procs:beginFrame() end
    -- Shockwaves in flight from a slam or a shove.
    self:_tickImpacts(dt)

    local resolutions = self.pool:update(dt, self.ctx)

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
    -- A tournament that has just settled still holds its payout until the
    -- drain below reads it; closing it first threw the payout (and the
    -- {chip} on a win) away. Such a table waits one tick.
    for i = #self.pool.tables, 1, -1 do
        local t = self.pool.tables[i]
        if t and t.pending_close and t.state == "idle"
           and not (t.mtt and t.mtt.pending_payout ~= nil) then
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
            -- Win detection: chip-stack KO, finish 1st.
            local gtype = Lookups.findById(GameTypes, t.game_type_id)
            local is_win = t.mtt and t.mtt.last_finish == 1
                           and gtype and gtype.chip_stack_table or false
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
                    demo         = Constants.DEMO,
                    hands_played = hands_cleared,
                })
            end

            if is_win then
                -- Chip bounty: first jackpot-equivalent per (stake, gtype) per
                -- run. Tournaments only "jackpot" once — on the win — so it's
                -- banked here, not on the per-hand cash path. Rides into the
                -- celebration block below.
                local state = self.game.state
                state.total_mtt_wins = (state.total_mtt_wins or 0) + 1
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
                            if (self.ctx and self.ctx.first_bounty_bonus or 0) > 0 then self:itemFired("first_bounty_bonus", t) end
                        end
                        self:itemFired("jackpot_chip_add", t)
                        self:itemFired("chip_award_mult", t)
                        state.chips_this_run = state.chips_this_run + award
                        state.lifetime_chips_banked = (state.lifetime_chips_banked or 0) + 1
                        state.total_chips_banked = (state.total_chips_banked or 0) + award
                    end
                else
                    -- Copy Machine: the run's first denied bounty banks anyway.
                    if self.ctx and self.ctx.copy_first_denied and not state.denied_copied_this_run then
                        state.denied_copied_this_run = true
                        self:itemFired("copy_first_denied", t)
                        local cp = self:bountyAward(t.stake_id)
                        if cp > 0 then
                            state.chips_this_run = state.chips_this_run + cp
                            state.lifetime_chips_banked = (state.lifetime_chips_banked or 0) + 1
                            state.total_chips_banked = (state.total_chips_banked or 0) + cp
                        end
                    else
                        -- Repeat tournament win on an already-banked combo:
                        -- the same "denied" event the cash path counts (feeds
                        -- the chip_denied tutorial hint).
                        state.total_denied_stacks = (state.total_denied_stacks or 0) + 1
                    end
                end

                -- Jackpot-grade table FX + the payout detonating — the MTT is
                -- the top of the ladder, so the win gets the full spectacle.
                -- 1.5× the standard chip count for the same reason.
                local jp = FeedbackIntensity.jackpot
                t.shake_trauma       = math.max(t.shake_trauma or 0, jp.shake)
                t.vignette_kind      = "good"
                t.vignette_alpha     = math.max(t.vignette_alpha or 0, jp.vignette)
                t.border_pulse_t     = 1.0
                t.border_pulse_color = "good"
                t.glow_t             = math.max(t.glow_t or 0, jp.glow or 1.0)
                self:_emitAmountExplosion(center, payout, t.stake_id)

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
            else
                -- Out of the money. The most common way a tournament ends
                -- and, until now, the only outcome in the game that said
                -- nothing at all. It is the tilt beat.
                self.game.floating_text.emit("BUSTED",
                    center[1], center[2],
                    { color_token = "error", lifetime = 1.6 })
                self:_announce("on_tournament_miss", { table = t, n = 1 })
            end

            if is_win then
                self:_announce("on_tournament_win", { table = t, n = 1 })
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
        -- Corrupted Gaming Chair: no focus penalty, but every table past
        -- the cap loses bigger.
        if r.delta < 0 and self.ctx and self.ctx.overcap_loss_mult
           and self.pool:count() > self:currentFocusCapacity() then
            r.delta = r.delta * self.ctx.overcap_loss_mult
        end

        -- Bank capstone: every hand's magnitude times the player's actual
        -- bankroll multiplier (the BANK number), read live here so the
        -- effects cache never has to carry live bankroll. The card says
        -- "multiplied by your bankroll multiplier" and means it.
        if self.ctx and self.ctx.earnings_scale_by_bankroll then
            r.delta = r.delta * ShoveRate.bankrollMultiplier(self.game.state.bankroll)
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
                self:itemFired("void_first_stack_loss", r.table)
            elseif self.ctx.void_first_loss and not state.first_loss_voided_this_run then
                state.first_loss_voided_this_run = true
                r.delta = 0
                self:itemFired("void_first_loss", r.table)
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
        local tbl   = r.table
        local stake = tbl and Lookups.findById(Stakes,tbl.stake_id)
        local cap   = (stake and stake.buy_in) or 0
        local overflow_amount = 0
        if tbl and r.chip_stack_table then
            -- No-op: stack already reconciled. r.delta is informational.
        elseif tbl and state.shove_r2_won and stake and stake.band == "ultra"
               and r.delta < 0 and r.tier == "jackpot" then
            -- A STACK loss at Ultra is the underflow. It is not a number you
            -- creep under; losing that much at once breaks the count. The
            -- seat empties and the bankroll lands below the threshold
            -- whatever it was before, whether or not the loss exceeded the
            -- stack (80-100 bb of a 100 bb seat would not have).
            local threshold = Constants.GAMEPLAY.UNDERFLOW_THRESHOLD or -100000000000
            tbl.stack = 0
            if state.bankroll > threshold - 1 then
                state.bankroll = threshold - 1
            end
        elseif tbl then
            local new_stack = tbl.stack + r.delta
            if new_stack > cap then
                overflow_amount = new_stack - cap
                tbl.stack = cap
                state.bankroll = state.bankroll + overflow_amount
            elseif new_stack < 0 then
                if state.shove_r2_won and stake and stake.band == "ultra" then
                    -- A smaller Ultra loss than the seat holds: the excess
                    -- comes off the bankroll (it may go negative). The stack
                    -- loss itself is handled above.
                    local excess_loss = -new_stack
                    tbl.stack = 0
                    state.bankroll = state.bankroll - excess_loss
                else
                    r.delta = -tbl.stack
                    tbl.stack = 0
                    -- The table is busted: its stack is gone. Counted for
                    -- catalog gates, and The Sink drains part of the buy-in
                    -- back to bankroll (bust_refund_pct).
                    state.total_busts = (state.total_busts or 0) + 1
                    local refund_pct = (self.ctx and self.ctx.bust_refund_pct) or 0
                    if refund_pct > 0 and cap > 0 then
                        state.bankroll = state.bankroll + cap * refund_pct
                        self:itemFired("bust_refund_pct", tbl)
                    end
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
                    demo           = Constants.DEMO,
                })
                tbl._hand_start_t = nil
            end
            if tbl.state ~= "idle" then
                tbl._hand_start_t = love.timer.getTime()
            end
        end

        -- Floater label & color. Two flavors:
        --   • cash hand               → "+/-$X.XX"
        --   • chip-stack MTT hand     → "+/-Nbb" (no cash until placement)
        -- Tournament cash payout fires its own "+$X.XX" floater from the
        -- drainPayout block above when the tournament ends.
        local label
        local floater_opts_override = nil
        if r.chip_stack_table then
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
            label = string.format("+$%.2f", r.delta) .. _multSuffix(r)
        else
            label = string.format("-$%.2f", -r.delta) .. _multSuffix(r)
            -- Loss: override the data-file's amber default with red so
            -- losses read correctly. Without this every tier picks up
            -- color_token="amber" and "-$X.XX" floaters render in gold
            -- like the wins.
            floater_opts_override = { color_token = "error" }
        end

        local mtt_final = false

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
            local opts_copy = {}
            for k, v in pairs(floater_opts) do opts_copy[k] = v end
            opts_copy.table = tbl
            -- Scale the vertical drift so the text lands at a consistent
            -- relative position regardless of panel size.  The data-layer
            -- arc_y values were authored for a ~390 px-tall panel; scale
            -- proportionally so a 200 px panel gets half the drift and a
            -- 600 px panel gets more.  Clamped to keep it sane.
            local panel_h = cxy and cxy[4] or 390
            local drift_scale = math.max(0.4, math.min(1.6, panel_h / 390))
            opts_copy.arc_y = (opts_copy.arc_y or -42) * drift_scale
            self.game.floating_text.emit(label, fx, fy, opts_copy)
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
            -- the panel + the pot detonating out of its own pile. Both
            -- gated on intensity fields existing (only jackpot defines
            -- them in data/feedback_intensity.lua) so future tiers can
            -- opt in by adding the same fields.
            if is_win and intensity.glow and intensity.glow > 0 then
                tbl.glow_t = math.max(tbl.glow_t or 0, intensity.glow)
            end
            -- The pot detonates. Raised as a per-table FX flag exactly like
            -- shake_trauma / glow_t above, because only the view knows
            -- where the pile actually is — views/TablePanel:drawPotLabel
            -- consumes this, blows apart the pile it was about to draw,
            -- and stops drawing it.
            if is_win and intensity.chip_burst then
                tbl.pot_explode_pending = true
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

        -- Receipt Printer: a {stack} anywhere settles every Zoom table on
        -- the spot. Appending to `resolutions` mid-iteration is deliberate
        -- — ipairs walks until it hits nil, so the swept hands run through
        -- this exact loop body (bounties, counters, floaters, analytics)
        -- with no duplicated logic and no recursion. A swept hand that is
        -- itself a {stack} appends the next wave the same way, which is
        -- how cascades chain.
        --
        -- WINS only: a jackpot LOSS setting off your engine would read as
        -- being rewarded for getting stacked. Flip the `r.delta > 0` here
        -- if that ever seems worth trying.
        -- Knockouts. Fired ONCE per hand carrying the seat count, not once
        -- per seat: a scheduled multi-bust puts two seats out on the same
        -- hand, and firing twice would be a no-op for a refreshing status
        -- while double-paying a chance-based one. Payloads that should
        -- scale read event.n instead.
        if r.busted_seats then
            self:_announce("on_ko", {
                table = r.table, n = #r.busted_seats, out = resolutions,
                busted_total = r.busted_total,
            })
        end
        if r.delta > 0 and r.tier == "jackpot" and not r.chip_stack_table then
            self:_announce("on_jackpot_win", { table = r.table, out = resolutions })
        end
        if r.delta < 0 and r.tier == "jackpot" and not r.chip_stack_table then
            self:_announce("on_stack_loss", { table = r.table, out = resolutions })
        end

        if r.delta > 0 and r.tier == "jackpot" and not r.chip_stack_table then
            local tbl = r.table
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
                            if (self.ctx and self.ctx.first_bounty_bonus or 0) > 0 then self:itemFired("first_bounty_bonus", tbl) end
                        end
                        self:itemFired("jackpot_chip_add", tbl)
                        self:itemFired("chip_award_mult", tbl)
                        -- Pending chips — commit to state.chips at SHOVE
                        -- time. The float is the satisfying "you locked a
                        -- bounty" signal; the top bar's chip figure stays
                        -- static until shove pulls the trigger on banking.
                        state.chips_this_run = state.chips_this_run + award
                        state.lifetime_chips_banked = (state.lifetime_chips_banked or 0) + 1
                        state.total_chips_banked = (state.total_chips_banked or 0) + award
                        self.game.floating_text.emit(
                            string.format("+%d {chip}", award),
                            r.x, (r.y or 0) - 28)
                    end
                else
                    -- Copy Machine: the run's first denied bounty banks anyway.
                    -- Corrupted: every denied bounty banks with a chance.
                    local copies = self.ctx and self.ctx.copy_first_denied and not state.denied_copied_this_run
                    local copy_chance = self.ctx and self.ctx.copy_denied_chance or 0
                    if not copies and copy_chance > 0 and love.math.random() < copy_chance then
                        copies = true
                    end
                    if copies then
                        state.denied_copied_this_run = true
                        self:itemFired("copy_first_denied", tbl)
                        self:itemFired("copy_denied_chance", tbl)
                        local cp = self:bountyAward(tbl.stake_id)
                        if cp > 0 then
                            state.chips_this_run = state.chips_this_run + cp
                            state.lifetime_chips_banked = (state.lifetime_chips_banked or 0) + 1
                            state.total_chips_banked = (state.total_chips_banked or 0) + cp
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

        -- Anti-chip award: a stack loss (r.delta < 0 and r.tier == "jackpot")
        -- at ANY stake during Act 3, once per stake x game type per run,
        -- alongside the {chip} for winning one. The award ladder is inverse
        -- (antiBountyAward, from ladder position): T1 pays most because a maxed
        -- build almost never loses a stack there.
        if r.delta < 0 and r.tier == "jackpot" and not r.chip_stack_table then
            local tbl = r.table
            if tbl then
                local stake = Lookups.findById(Stakes, tbl.stake_id)
                if stake and state.shove_r2_won then
                    local cap = 1
                    local key = bountyKey(tbl.stake_id, tbl.game_type_id)
                    state.anti_stakes_won_this_run = state.anti_stakes_won_this_run or {}
                    local cur = state.anti_stakes_won_this_run[key]
                    local count = (cur == true and 1) or 0
                    if count < cap then
                        state.anti_stakes_won_this_run[key] = true
                        state.hands_since_last_bank = 0
                        local award = self:antiBountyAward(tbl.stake_id)
                        -- Corrupted Worry Stone: every anti pays more.
                        -- Corrupted Fridge: the run's first pays more still.
                        if self.ctx then
                            award = math.floor(award * (self.ctx.anti_award_mult or 1) + 0.5)
                            if not state.first_anti_this_run then
                                state.first_anti_this_run = true
                                award = math.floor(award * (self.ctx.first_anti_mult or 1) + 0.5)
                            end
                        end
                        -- An anti-chip banking: the chip bank sound, corrupted.
                        self:_playNamed("chip_land_bankroll", { damaged = true })
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

        -- ── Ungated counters ────────────────────────────────────────────
        -- Unconditional, unlike the deck lifetime counters below (those
        -- start at zero when decks unlock). These drive tutorial-hint
        -- pacing (models/hint_rules.lua "hands_played") AND every catalog
        -- unlock gate — a catalog gate must be reachable in Act 1, which
        -- the deck-gated counters are not.
        local n_tables = self.pool:count()
        local gtype_id = tbl and tbl.game_type_id
        local focus_cap = self:currentFocusCapacity()

        state.total_hands_played = (state.total_hands_played or 0) + 1
        if r.tier == "large" or r.tier == "jackpot" then
            -- Big outcomes, win or loss — the tutorial's tier hint fires
            -- on the first one.
            state.total_big_outcomes = (state.total_big_outcomes or 0) + 1
        end
        if r.won and r.tier == "jackpot" then
            state.total_jackpots = (state.total_jackpots or 0) + 1
        elseif (not r.won) and r.tier == "jackpot" then
            state.total_stack_losses = (state.total_stack_losses or 0) + 1
        end
        if r.delta < 0 then
            -- Fuels the Dishwasher's next-run seed (GameState:resetRun
            -- freezes this into last_run_money_lost).
            state.run_money_lost = (state.run_money_lost or 0) + (-r.delta)
        end
        if n_tables >= 4 then
            state.total_hands_at_4plus = (state.total_hands_at_4plus or 0) + 1
        end
        if n_tables > focus_cap then
            state.total_hands_overwhelmed = (state.total_hands_overwhelmed or 0) + 1
        end
        if gtype_id then
            state.total_hands_by_gtype = state.total_hands_by_gtype or {}
            state.total_hands_by_gtype[gtype_id] =
                (state.total_hands_by_gtype[gtype_id] or 0) + 1
        end
        if stake then
            local idx = Lookups.indexById(Stakes, stake.id) or 0
            if idx > (state.highest_stake_idx or 0) then
                state.highest_stake_idx = idx
            end
        end

        -- Deck-system meta bookkeeping. Lifetime counters drive unlock
        -- thresholds; the resolved-hand event drives active-deck XP. All
        -- of it gates on the system unlock (first gauntlet clear), so no
        -- silent state accrues before decks exist — deck progression
        -- starts from zero the moment the shove is first beaten.
        if Decks.systemUnlocked(state) then
            -- n_tables / gtype_id / focus_cap are hoisted above with the
            -- ungated counters.

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
                for _, id in ipairs(newly) do
                    local spec = Decks.specById(id)
                    self:_announceOnDeckCell(
                        "NEW DECK: " .. ((spec and spec.name) or id))
                end
            end
        end
    end

    -- Resolutions just mutated per-table state (incl. MttSession fields
    -- on tournament tables). Resync so a save mid-MTT-run
    -- captures the latest hand counter. Cheap (4 array writes per
    -- table; bounded by MAX_TABLES).
    self.pool:_syncStateList()
end

-- Announce something landing on the DECK cell: a gold pulse on the cell plus
-- a floater rising off it. The same pair a {chip} bounty uses, for the same
-- reason -- this is acknowledgement, not teaching, so it wants the vocabulary
-- the player already reads rather than a new one.
--
-- Both of the events this serves were already detected and thrown away:
-- Decks.checkPendingUnlocks RETURNS the newly-unlocked ids and Decks.gainXp
-- returns a level-up flag, and each was used only to invalidate the effects
-- cache. Deck progression has been completely silent since it shipped.
--
-- Anchored, so it no-ops when the cell is not on screen (the boot-time and
-- deck-select unlock sweeps have no grind view to draw into).
function GrindController:_announceOnDeckCell(text)
    local a = AnchorRegistry.get("cell:deck")
    if not a then return end
    AwardGlow.flash("cell:deck")
    if self.game.floating_text then
        self.game.floating_text.emit(text,
            a[1] + (a[3] or 0) * 0.5, a[2] + (a[4] or 0),
            -- "amber" resolves through Theme.data in GrindView's floater
            -- draw. Without a token this text would default to status.error,
            -- because the auto-color rule only reads a leading "+" as good
            -- news and an unlock does not start with one.
            { color_token = "amber" })
    end
end

-- Grant XP to the active deck for one resolved hand. Returns true on a
-- level-up so the controller can invalidate the effects cache; the model
-- side handles the math + state writes.
function GrindController:_grantDeckXp(event)
    -- Tori Gate multiplies whatever the deck's XP rule returns.
    local xp_mult = (self.ctx and self.ctx.deck_xp_mult) or 1
    local _, leveled = Decks.gainXp(self.game.state, self.game.xp_rules, event, xp_mult)
    if leveled then
        self:invalidateEffects()
        local state = self.game.state
        local lvl   = state.deck_levels and state.active_deck_id
                      and state.deck_levels[state.active_deck_id]
        self:_announceOnDeckCell(lvl and ("DECK L" .. lvl) or "DECK LEVEL UP")
    end
end

-- ─── Purchase intents (called from view button handlers) ─────────────────────

-- Stacking run upgrade purchase. Each click bumps the upgrade's level by one
-- (up to its max_level). Cost for the next level is item.costs[N+1], multiplied
-- by ctx.run_upgrade_cost_mult so the Ring Binder catalog perk discounts
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
-- An effect kind just did something: tell whoever listens which items
-- put it there (ctx.sources, from computeEffects). Sound and any future
-- visual feedback hang off the "item_fired" event; this file stays mute.
function GrindController:itemFired(kind, tbl)
    local ctx = self.ctx
    local bus = self.game.event_bus
    local ids = ctx and ctx.sources and ctx.sources[kind]
    if not bus or not ids then return end
    -- Where the "what fired" ghost shows: the triggering table's centre
    -- anchor, resolved now (the registry is view-written and stales).
    local x, y, pw, ph
    local pos = tbl and AnchorRegistry.get(TableModel.anchorKey(tbl, "center"))
    if pos then x, y, pw, ph = pos[1], pos[2], pos[3], pos[4] end
    for _, id in ipairs(ids) do
        bus:publish("item_fired", { item_id = id, kind = kind,
                                    x = x, y = y, pw = pw, ph = ph })
    end
end

function GrindController:bountyAward(stake_id)
    local stake = Lookups.findById(Stakes,stake_id)
    if not stake then return 0 end
    local mult  = (self.ctx and self.ctx.chip_award_mult) or 1
    local bonus = (self.ctx and self.ctx.jackpot_chip_add) or 0
    return math.floor((stake.chip_award or 0) * mult + 0.5) + bonus
end

-- The {achip} for losing a whole stack at this stake: the ladder's length
-- minus the stake's position, plus one, so the first stake pays the most
-- and the top pays 1. Computed, not authored: it follows the ladder if a
-- stake is added or removed, the way chip_award follows position.
function GrindController:antiBountyAward(stake_id)
    local stake = Lookups.findById(Stakes, stake_id)
    local idx   = Lookups.indexById(Stakes, stake_id)
    if not stake or not idx then return 0 end
    -- Ultra is not a rung. It is played once, to underflow, and pays no
    -- bounty either way. The ladder is every stake below it.
    if stake.band == "ultra" then return 0 end
    local rungs = 0
    for _, s in ipairs(Stakes) do if s.band ~= "ultra" then rungs = rungs + 1 end end
    return rungs - idx + 1
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

    -- Ungated mirror — catalog gates (Ring Binder, Filing Cabinet, Supply
    -- Closet) read this one, so it has to tick in Act 1 too.
    state.total_upgrade_levels = (state.total_upgrade_levels or 0) + 1
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
        -- The EFFECTIVE window (OutcomeMath.effectiveWindow): a widened
        -- window needs more levels to fill, and those must be buyable.
        local best = 0
        for _, s in ipairs(Stakes) do
            if s.band ~= "ultra" and self:stakeAvailable(s) and s.fill_window then
                local _, complete = OutcomeMath.effectiveWindow(s.fill_window, self.ctx)
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
    local state = self.game.state
    -- has_shoved, NOT shove_count: shove_count is bumped by GameState.resetRun,
    -- which the quick-reset rescue button also calls, so bailing out of a
    -- bricked first run used to reveal SHOVE permanently without the player
    -- ever banking the 3 {chip} the gate is supposed to require.
    return state.has_shoved
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

-- Whether the no-cost quick-reset should be offered: bricked. Chips don't
-- gate it — :quickReset banks this run's chips first, so a bricked player
-- who can't yet afford anything in the shop can still bail to a fresh
-- stake without losing them.
function GrindController:canQuickReset()
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
    -- Run-start perks are silent: they land while the player is between
    -- screens (the deck modal, the reset), which is nowhere to hear them.
    state:applyStartingPerks(self.ctx)
    -- Queued chip bursts reference anchors of tables the rebuild replaces.
    self.pending_bursts = {}
    self.pool:rebuildFromState(self.ctx)
end

-- The player physically pulled the COMING SOON sticker off `item_id`. Records
-- it so the reveal sticks across sessions; the view owns the drag, the model
-- owns the fact. No-op if already peeled.
function GrindController:peelCatalogSticker(item_id)
    local state = self.game.state
    state.peeled_items = state.peeled_items or {}
    for _, id in ipairs(state.peeled_items) do
        if id == item_id then return false end
    end
    state.peeled_items[#state.peeled_items + 1] = item_id
    self:_playNamed("hole_card_flip")
    return true
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
-- Single source of truth
-- for stake availability — the add-table buttons and the win-chance / stack-
-- rate range tooltips all route through it so they never disagree.
function GrindController:stakeAvailable(stake)
    local band = (stake and stake.band) or "low"
    local gate = Constants.STAKE_BAND_GATE[band]
    if not gate then return true end
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
function GrindController:_finalizeRemove(idx, quiet)
    local t = self.pool.tables[idx]
    if not t then return false end
    local gtype = Lookups.findById(GameTypes, t.game_type_id)
    local refund
    if gtype and gtype.chip_stack_table and t.mtt and t.mtt:isPlaying() then
        refund = 0
    else
        refund = t.stack or 0
    end
    if not quiet then self:_emitCashOutChips(t, refund) end
    self.pool:removeTable(idx)
    self.game.state.bankroll = self.game.state.bankroll + refund
    self:invalidateEffects()
    return true
end

function GrindController:removeTable(idx)
    local t = self.pool.tables[idx]
    if not t then return false end
    -- Mid-hand → defer close until the hand resolves and we're idle again.
    -- The update loop scans for pending_close + idle each frame. A settled
    -- tournament whose payout has not been drained yet defers the same
    -- way, so the X never eats a cash.
    if t.state ~= "idle" or (t.mtt and t.mtt.pending_payout ~= nil) then
        t.pending_close = true
        return true
    end
    return self:_finalizeRemove(idx)
end

-- Cash out every active table. Idle tables close now; busy tables get
-- their pending_close flag set and finalise once they return to idle.
-- `force` closes every table NOW (mid-hand included) instead of deferring
-- busy ones to pending_close — the SHOVE entry needs an empty pool this
-- frame. A settled tournament's undrained payout is credited first so the
-- forced close can't eat a cash; forced closes are also quiet (no chip
-- bursts into a screen we're leaving).
function GrindController:cashOutAll(force)
    if self.pool:count() == 0 then return false end
    -- Reverse iteration: synchronous closes shift indices.
    for i = #self.pool.tables, 1, -1 do
        if force then
            local t = self.pool.tables[i]
            if t and t.mtt and t.mtt.pending_payout ~= nil then
                local payout = t.mtt:drainPayout()
                if payout and payout > 0 then
                    self.game.state.bankroll = self.game.state.bankroll + payout
                end
            end
            self:_finalizeRemove(i, true)
        else
            self:removeTable(i)
        end
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

-- Seat a table (identified by its runtime _id — indices go stale between
-- the drag's frames) in a specific board cell. An empty cell moves it; an
-- occupied one swaps the two. Called from GrindView's drag drop, outside
-- the update tick, so the prev_states[i] snapshot never spans a move.
-- The cell persists through _syncStateList (active_table_slot).
function GrindController:moveTableToSlot(table_id, slot)
    local from_idx
    for i, t in ipairs(self.pool.tables) do
        if t._id == table_id then from_idx = i; break end
    end
    if not from_idx then return false end   -- table closed mid-drag
    if not self.pool:moveToSlot(from_idx, slot) then return false end
    -- Cursor claims are keyed by pool index, and pool order is reading
    -- order of the board — so a move can renumber. Release them so no
    -- cursor silently re-aims at whatever table now sits at its index.
    CursorPool.releaseAllTargets()
    return true
end

-- ── Bulk table actions, scoped to one (stake, game type) ────────────────
-- The sidebar's +ADD row for a combo owns the tables it opened, so its
-- trailing buttons operate on exactly that set. `stake_id` / `gtype_id` nil
-- means "every table", which is what the global cursor controls pass.

local function tableMatches(t, stake_id, gtype_id)
    return (stake_id == nil or t.stake_id == stake_id)
       and (gtype_id == nil or t.game_type_id == gtype_id)
end

-- Close every table of this combo, banking each one's stack. Reverse
-- iteration: removeTable is synchronous for idle tables and shifts indices.
function GrindController:cashOutType(stake_id, gtype_id)
    local n = 0
    for i = #self.pool.tables, 1, -1 do
        local t = self.pool.tables[i]
        if t and tableMatches(t, stake_id, gtype_id) then
            self:removeTable(i)
            n = n + 1
        end
    end
    return n
end

-- How many tables of this combo are open, and how many of them the cursors
-- are currently muted on. The view needs both: the first to disable a button
-- with nothing to act on, the second to decide whether the toggle reads as
-- ON or OFF for the group.
function GrindController:typeCursorState(stake_id, gtype_id)
    local total, deal_muted, rebuy_muted = 0, 0, 0
    for _, t in ipairs(self.pool.tables) do
        if tableMatches(t, stake_id, gtype_id) then
            total = total + 1
            if t.cursor_muted == true       then deal_muted  = deal_muted + 1 end
            if t.cursor_rebuy_muted == true then rebuy_muted = rebuy_muted + 1 end
        end
    end
    return total, deal_muted, rebuy_muted
end

-- Set (not toggle) the cursor-deal mute across a combo. Setting rather than
-- toggling is what makes a group control predictable: a mixed group snaps to
-- one state instead of inverting each table into a different mixed state.
function GrindController:setTypeCursorMute(stake_id, gtype_id, muted)
    local n = 0
    for _, t in ipairs(self.pool.tables) do
        if tableMatches(t, stake_id, gtype_id) then
            t.cursor_muted = muted and true or false
            n = n + 1
        end
    end
    if n > 0 then self.pool:_syncStateList() end
    return n
end

function GrindController:setTypeCursorRebuyMute(stake_id, gtype_id, muted)
    local n = 0
    for _, t in ipairs(self.pool.tables) do
        if tableMatches(t, stake_id, gtype_id) then
            t.cursor_rebuy_muted = muted and true or false
            n = n + 1
        end
    end
    if n > 0 then self.pool:_syncStateList() end
    return n
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
    if ok then
        -- New hand, new pile: clear any spent detonation so the pot draws
        -- again. Set here rather than in Table:deal because these are view
        -- FX fields.
        t.pot_exploded, t.pot_explode_pending = nil, nil
    end
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

-- Palette for an amount that may be a PAYOUT rather than table money —
-- see services/DenominationBreakdown.paletteForAmount for the why.
local function _paletteForAmount(stake_id, amount)
    return Denoms.paletteForAmount(ChipData, stake_id, amount)
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

function GrindController:_emitBuyInChips(t, amount)
    if not t or amount <= 0 then return end
    local you     = _anchor(t, "you")
    local bank_xy = AnchorRegistry.get("bankroll")
    if not you or not bank_xy then return end
    local stake   = Lookups.findById(Stakes,t.stake_id)
    local bb      = (stake and stake.bb) or 1
    local palette = _paletteForAmount(t.stake_id, amount)
    local tier    = Denoms.tierFromUnit(amount / bb)
    local chips   = Denoms.breakdown(amount, ChipData.denominations, palette, ChipData.tier_chip_target, tier)
    self:_queueBurst(bank_xy, you, chips, {
        kind          = "stack",
        amount        = amount,
        arrival_sound = "chip_land_you",
        source_key    = "bankroll",
        dest_key      = TableModel.anchorKey(t, "you"),
    })
end

function GrindController:_emitCashOutChips(t, amount)
    if not t or amount <= 0 then return end
    local you     = _anchor(t, "you")
    local bank_xy = AnchorRegistry.get("bankroll")
    if not you or not bank_xy then return end
    local stake   = Lookups.findById(Stakes,t.stake_id)
    local bb      = (stake and stake.bb) or 1
    local palette = _paletteForAmount(t.stake_id, amount)
    local tier    = Denoms.tierFromUnit(amount / bb)
    local chips   = Denoms.breakdown(amount, ChipData.denominations, palette, ChipData.tier_chip_target, tier)
    self:_queueBurst(you, bank_xy, chips, {
        kind          = "stack",
        amount        = amount,
        arrival_sound = "chip_land_bankroll",
        source_key    = TableModel.anchorKey(t, "you"),
        dest_key      = "bankroll",
    })
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
    local palette = _paletteForAmount(t.stake_id, amount)
    local tier    = Denoms.tierFromUnit(amount / bb)
    local chips   = Denoms.breakdown(amount, ChipData.denominations, palette, ChipData.tier_chip_target, tier)
    self:_queueBurst(source, bank_xy, chips, {
        kind          = "stack",
        amount        = amount,
        arrival_sound = "chip_land_bankroll",
        source_key    = pot and TableModel.anchorKey(t, "pot") or nil,
        dest_key      = "bankroll",
    })
end

function GrindController:_emitResolutionChips(r, tbl, overflow_amount)
    if not tbl then return end
    local you_xy = _anchor(tbl, "you")
    local pot_xy = _anchor(tbl, "pot")
    if not you_xy or not pot_xy then return end
    -- r.delta is a payout, not table money — at high multipliers it runs
    -- straight past what the stake's four chips can express.
    local palette = _paletteForAmount(tbl.stake_id, math.abs(r.delta or 0))
    local tier    = r.tier or "medium"
    -- No per-tier burst cap here any more. These are pile-to-pile
    -- transfers: capping the count would leave the destination short by
    -- every chip the cap declined to carry. The pile's own tier already
    -- decides how many chips there are to move (data/chips.lua
    -- tier_chip_target), which is the honest version of the same knob.
    -- Per-stake chip tint (data/stake_themes.lua) — T6 = warm gold cast,
    -- T1 = desaturated dim, etc. Multiplied into the chip body color
    -- inside Chips.drawChip.
    local stake_theme = StakeThemes[tbl.stake_id]
    local chip_tint   = stake_theme and stake_theme.chip_tint

    -- The script's pot_push handler owns the entire payout — it
    -- fabricates whatever the multipliers added on top of the visible
    -- pot and splits it across the stack and the bankroll per the
    -- buy-in cap, whether or not the pot detonated. So the overflow
    -- spill below skips when the push pays out (it would be the same
    -- chips a second time).
    local push_pays_out = r.delta > 0

    if overflow_amount and overflow_amount > 0 and not push_pays_out then
        local v = self.game.viewport or { w = 0, h = 0 }
        local bank_xy = AnchorRegistry.get("bankroll")
                        or { v.w * 0.5, v.h - 30 }
        local chips = Denoms.breakdown(overflow_amount, ChipData.denominations,
                                       ChipData.full_palette,
                                       ChipData.tier_chip_target,
                                       Denoms.tierFromAmount(overflow_amount))
        self:_queueBurst(you_xy, bank_xy, chips, {
            kind          = "stack",
            amount        = overflow_amount,
            arrival_sound = "chip_land_bankroll",
            source_key    = TableModel.anchorKey(tbl, "you"),
            dest_key      = "bankroll",
        })
    end
end

-- Detonation for celebrations with NO pot pile on screen to come apart —
-- the tournament win, whose felt-center pot slot holds the HAND x/x counter
-- instead of chips. Forms a pile out of the amount at `origin` and blows it
-- apart in the same motion.
--
-- The cash-table jackpot does NOT come through here: that pile is real and
-- already drawn, so it detonates in place via the pot_explode_pending flag
-- (see the resolution FX block above).
--
-- Chip count is whatever the breakdown produces — never padded out to a
-- target, so this stays the real chips rather than a multiplied copy.
-- `origin` is the table's center anchor, which carries the panel size —
-- the burst scales to the table it came off rather than throwing a fixed
-- 300px cloud over a panel that may be a quarter that wide.
function GrindController:_emitAmountExplosion(origin, amount, stake_id)
    if not origin or not amount or amount <= 0 then return end
    local chips = Denoms.breakdown(amount, ChipData.denominations,
                                   _paletteForAmount(stake_id, amount),
                                   ChipData.tier_chip_target,
                                   Denoms.tierFromAmount(amount))
    if not chips or #chips == 0 then return end
    local stake_theme = StakeThemes[stake_id]
    self:_queueScatter(origin, chips, {
        chip_tint = stake_theme and stake_theme.chip_tint,
        within    = (origin[3] and origin[4]) and { origin[3], origin[4] } or nil,
    })
end

-- What a rebuy at table `idx` costs right now: the stake's buy-in less
-- ctx.rebuy_discount. DETERMINISTIC — free_rebuy_chance is deliberately not
-- rolled here, because the view calls this every frame to label the REBUY
-- button and to test affordability; rolling would reroll on every draw. The
-- free roll happens once, inside rebuyTable, and only ever lowers the price.
-- Mirrors buyInMultFor: the controller owns cost math, the view reads it.
function GrindController:rebuyCostFor(idx)
    local t = self.pool:get(idx)
    if not t then return 0 end
    local stake  = Lookups.findById(Stakes, t.stake_id)
    local buy_in = (stake and stake.buy_in) or 0
    local discount = (self.ctx and self.ctx.rebuy_discount) or 0
    return buy_in * (1.0 - discount)
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
    local cost   = self:rebuyCostFor(idx)
    if self.ctx then
        local free_chance = self.ctx.free_rebuy_chance or 0
        if free_chance > 0 and love.math.random() < free_chance then
            cost = 0
            self:itemFired("free_rebuy_chance", t)
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
    -- Ungated mirror — catalog gates (Night Table, Medical Kit) read this
    -- one, so it has to tick in Act 1 too.
    state.total_rebuys = (state.total_rebuys or 0) + 1
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
    -- The only place this is set: the tutorial's SHOVE gate needs a signal
    -- that means "actually shoved", not "started another run".
    state.has_shoved = true
    self.game.state_machine:switch("shove")
end

-- Convenience: deal every idle table in one call. Useful as a future
-- "auto-play" upgrade hook and as a debug shortcut.
function GrindController:dealAll()
    local n = 0
    for _, t in ipairs(self.pool.tables) do
        if not t:isBusy() and (t.stack or 0) > 0 then
            if t:deal(self.ctx) then
                t.pot_exploded, t.pot_explode_pending = nil, nil
                n = n + 1
            end
        end
    end
    return n
end

return GrindController
