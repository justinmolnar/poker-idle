-- controllers/GrindController.lua
--
-- Sits between GrindState and the model layer. Owns the TablePool, applies
-- per-tick resolutions to bankroll, tracks peak_bankroll, and routes
-- floating-text emission. Validates and applies purchase intents from the
-- view (run-upgrade and catalog buys).
--
-- The view doesn't mutate state directly — it dispatches intents to this
-- controller. Effects context is cached and only recomputed when an item is
-- bought or run state changes (cheap, since we're not doing it per-frame).

local TablePool   = require("models.TablePool")
local Catalog     = require("data.catalog")
local RunUpgrades = require("data.run_upgrades")
local Stakes      = require("data.stakes")
local Constants   = require("data.constants")
local ChipData    = require("data.chips")
local Chips       = require("views.Chips")
local ChipFlight  = require("services.ChipFlightSystem")

local function findStake(id)
    for _, s in ipairs(Stakes) do
        if s.id == id then return s end
    end
end

-- PP-bounty key: a (stake, game_type) combo locks one bounty per run.
-- 4 game types × 6 stakes = 24 distinct bounty slots — total ~84 PP for
-- a perfect climb across all combos.
local function bountyKey(stake_id, game_type_id)
    return stake_id .. ":" .. game_type_id
end

local GrindController = {}
GrindController.__index = GrindController

function GrindController:new(game)
    local self = setmetatable({ game = game }, GrindController)
    -- Compute effects first so the initial pool rebuild gets ctx (matters
    -- for Cold Read and other start-of-table catalog perks).
    self:invalidateEffects()
    self.pool = TablePool:new(game.state, self.ctx)
    return self
end

-- Recompute the effects context from the player's owned items + run upgrades.
-- Called on construction and after any purchase / prestige reset.
function GrindController:invalidateEffects()
    self.ctx = self.game.state:computeEffects(self.game.effects, Catalog, RunUpgrades)
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
    -- view has populated `tbl.you_x`.
    for _, t in ipairs(self.pool.tables) do
        if t._pending_buyin and t.you_x and self.game.bankroll_xy then
            self:_emitBuyInChips(t, t._pending_buyin)
            t._pending_buyin = nil
        end
    end

    if #resolutions == 0 then return end

    local state      = self.game.state
    local focus_mult = self:currentFocusMult()
    for _, r in ipairs(resolutions) do
        -- Apply focus penalty to the actual $ delta — split attention
        -- means smaller wins and harsher relative losses. Floor in
        -- currentFocusMult prevents zero, so a tiny positive delta is
        -- still positive and counts as a win for the PP bounty.
        r.delta = r.delta * focus_mult

        -- Wins/losses land on the table's stack first. Above the 100bb
        -- cap (= stake.buy_in) the surplus spills to bankroll; below
        -- zero the loss clamps to whatever's actually on the table so
        -- the player can't go negative just from a brutal hand.
        local tbl   = self.pool.tables[r.table_idx]
        local stake = tbl and findStake(tbl.stake_id)
        local cap   = (stake and stake.buy_in) or 0
        local overflow_amount = 0
        if tbl then
            local new_stack = tbl.stack + r.delta
            if new_stack > cap then
                overflow_amount = new_stack - cap
                tbl.stack = cap
                state.bankroll = state.bankroll + overflow_amount
            elseif new_stack < 0 then
                r.delta = -tbl.stack
                tbl.stack = 0
            else
                tbl.stack = new_stack
            end
        else
            -- Defensive fallback: no table found, route to bankroll
            -- with the same negative clamp.
            local new_bankroll = state.bankroll + r.delta
            if new_bankroll < 0 then
                r.delta = -state.bankroll
                new_bankroll = 0
            end
            state.bankroll = new_bankroll
        end

        local total_wealth = state.bankroll + self:tiedUp()
        if total_wealth > state.peak_bankroll then
            state.peak_bankroll = total_wealth
        end

        local label
        if r.delta >= 0 then
            label = string.format("+$%.2f", r.delta)
        else
            label = string.format("-$%.2f", -r.delta)
        end
        self.game.floating_text.emit(label, r.x, r.y)

        -- Chip-flight burst on resolution. Three flavors:
        --   • win  → pot to YOU stack
        --   • loss → pot off-screen (chips fly off the bottom)
        --   • overflow (YOU stack hit cap) → YOU to bankroll pile
        self:_emitResolutionChips(r, tbl, overflow_amount)

        -- Jackpot FX: per-table screen shake + colored vignette. Triggered
        -- ONLY on jackpot tier so the moment stays special. Trauma uses the
        -- trauma² model (Table:update decays it); vignette is a simple
        -- alpha-decay overlay tinted by win vs loss.
        if r.tier == "jackpot" and tbl then
            local is_win = r.delta > 0
            tbl.shake_trauma   = math.max(tbl.shake_trauma or 0,
                                          is_win and 0.75 or 0.65)
            tbl.vignette_kind  = is_win and "good" or "bad"
            tbl.vignette_alpha = is_win and 0.70 or 0.65
        end

        -- PP-bounty: first jackpot-tier win at this (stake, game_type)
        -- combo this run awards the stake's pp_award. Locked in until
        -- prestige clears it. Non-jackpot wins, losing hands, and
        -- subsequent jackpot wins at the same combo do nothing.
        if r.delta > 0 and r.tier == "jackpot" then
            local tbl = self.pool.tables[r.table_idx]
            if tbl then
                local key = bountyKey(tbl.stake_id, tbl.game_type_id)
                if not state.stakes_won_this_run[key] then
                    state.stakes_won_this_run[key] = true
                    local stake = findStake(tbl.stake_id)
                    local base_award = stake and stake.pp_award or 0
                    -- pp_award_mult (Endorsement Deal catalog item)
                    -- doubles or otherwise scales bounty payouts.
                    local mult  = (self.ctx and self.ctx.pp_award_mult) or 1
                    local award = math.floor(base_award * mult + 0.5)
                    if award > 0 then
                        -- Pending PP — commits to state.pp at SHOVE time.
                        -- The float is the satisfying "you locked a bounty"
                        -- signal; the top bar's PP figure stays static
                        -- until shove pulls the trigger on banking.
                        state.pp_this_run = state.pp_this_run + award
                        self.game.floating_text.emit(
                            string.format("+%d PP (run)", award),
                            r.x, (r.y or 0) - 28)
                    end
                end
            end
        end
    end
end

-- ─── Purchase intents (called from view button handlers) ─────────────────────

-- Stacking run upgrade purchase. Each click bumps the upgrade's level by one
-- (up to its max_level). Cost for the next level is item.costs[N+1], multiplied
-- by ctx.run_upgrade_cost_mult so the cheap_coaching catalog perk discounts
-- every run-upgrade buy. Returns true on a successful level-up.
function GrindController:buyRunUpgrade(upgrade_id)
    local state = self.game.state
    -- Find item by id.
    local upgrade
    for _, u in ipairs(RunUpgrades) do
        if u.id == upgrade_id then upgrade = u; break end
    end
    if not upgrade then return false end

    local current = state.run_upgrade_levels[upgrade_id] or 0
    local max_lvl = upgrade.max_level or 1
    if current >= max_lvl then return false end

    local cost_mult = (self.ctx and self.ctx.run_upgrade_cost_mult) or 1
    local cost = (upgrade.costs and upgrade.costs[current + 1]) or 0
    cost = cost * cost_mult
    if state.bankroll < cost then return false end

    state.bankroll = state.bankroll - cost
    state.run_upgrade_levels[upgrade_id] = current + 1
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

function GrindController:getRunUpgradeNextCost(upgrade)
    if not upgrade then return nil end
    local current = self.game.state.run_upgrade_levels[upgrade.id] or 0
    if current >= (upgrade.max_level or 1) then return nil end
    local cost = (upgrade.costs and upgrade.costs[current + 1]) or 0
    return cost * ((self.ctx and self.ctx.run_upgrade_cost_mult) or 1)
end

function GrindController:buyCatalogItem(item_id)
    local state = self.game.state
    for _, owned in ipairs(state.owned_items) do
        if owned == item_id then return false end
    end
    local item
    for _, it in ipairs(Catalog) do
        if it.id == item_id then item = it; break end
    end
    if not item then return false end
    if state.pp < item.cost_pp then return false end
    state.pp = state.pp - item.cost_pp
    state.owned_items[#state.owned_items + 1] = item_id
    self:invalidateEffects()
    self:_playNamed("upgrade_purchased")
    return true
end

-- Bankroll-cost-to-open. Adding a table deducts the stake's buy-in (100bb)
-- from bankroll, optionally discounted by ctx.buy_in_mult (Discount Sits
-- catalog perk). Game type doesn't change the buy-in. Returns false if
-- not affordable / pool full / unknown stake-or-gametype.
function GrindController:addTable(stake_id, game_type_id)
    if self.pool:count() >= self:tableSlotsCap() then return false end
    local stake = findStake(stake_id)
    if not stake then return false end
    local mult = (self.ctx and self.ctx.buy_in_mult) or 1
    local cost = (stake.buy_in or 0) * mult
    if self.game.state.bankroll < cost then return false end
    self.game.state.bankroll = self.game.state.bankroll - cost
    self.pool:addTable(stake_id, game_type_id or "six_max", self.ctx)
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
-- top bar — money that's not gone, just locked on the felt. Tracks the
-- *current* stack value (which fluctuates with wins/losses), not the
-- buy-in paid to sit. Cashing out (see :removeTable) refunds whatever
-- the stack is worth at that moment.
function GrindController:tiedUp()
    local total = 0
    for _, t in ipairs(self.pool.tables) do
        total = total + (t.stack or 0)
    end
    return total
end

-- Removing a table refunds the *current stack* (cash-out semantics).
-- Lost it all? You get $0 back. Sitting on a freshly bought-in table
-- with no hands played? Full buy-in returns.
function GrindController:removeTable(idx)
    local t = self.pool.tables[idx]
    if not t then return false end
    local refund = t.stack or 0
    -- YOU stack → bankroll chip burst BEFORE removal (positions still valid).
    self:_emitCashOutChips(t, refund)
    self.pool:removeTable(idx)
    self.game.state.bankroll = self.game.state.bankroll + refund
    -- Cash-out reuses the rebuy clack (a chip-rack thump); no dedicated
    -- sound for "table closed" since the chip-flight thunk on the bankroll
    -- already covers the audible feedback. Skip a redundant cue.
    return true
end

-- Stake-up: cash out the current stack and pay the new buy-in (optionally
-- discounted by ctx.buy_in_mult). Net cost = new_buy_in - current_stack.
-- Bankroll must cover that delta. Table:setStake then resets the table's
-- stack to the new buy-in.
function GrindController:changeTableStake(idx, new_stake_id)
    local t = self.pool.tables[idx]
    if not t then return false end
    local new_stake = findStake(new_stake_id)
    if not new_stake then return false end
    local mult   = (self.ctx and self.ctx.buy_in_mult) or 1
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

-- Click-to-deal entry point. Triggers the per-hand state machine on a
-- specific table. Returns false if the table is already animating a hand
-- or doesn't exist.
function GrindController:dealHand(idx)
    local t = self.pool:get(idx)
    if not t or t:isBusy() then return false end
    -- Stack must be positive to play. Hitting 0 means the table is busted
    -- and the player must :rebuyTable before dealing again.
    if (t.stack or 0) <= 0 then return false end
    local ok = t:deal(self.ctx)
    if ok then self:_emitDealChips(t) end
    return ok
end

-- Defensive sound dispatch — single line so each call site stays terse.
function GrindController:_playNamed(name)
    local sounds = self.game.sounds
    if sounds and sounds.playNamed then sounds.playNamed(name) end
end

-- ── Chip-flight emission helpers (Phase B) ───────────────────────────
-- Each helper composes a chip breakdown via views/Chips and pushes a
-- staggered burst into services/ChipFlightSystem. Anchors come from
-- positions stashed on the table by views/TablePanel during draw.

local function _paletteForStake(stake_id)
    return ChipData.stake_palettes[stake_id] or ChipData.full_palette
end

function GrindController:_emitDealChips(t)
    if not t or not t.you_x or not t.pot_x then return end
    local amount = math.abs(t.outcome_delta or 0)
    if amount <= 0 then return end
    local chips = Chips.breakdown(amount, _paletteForStake(t.stake_id),
                                  t.outcome_tier or "small")
    ChipFlight.emitBurst(
        { t.you_x, t.you_y },
        { t.pot_x, t.pot_y },
        chips,
        { arrival_sound = "chip_land_pot" })
end

function GrindController:_emitBuyInChips(t, amount)
    if not t or not t.you_x or amount <= 0 then return end
    local bank_xy = self.game.bankroll_xy
    if not bank_xy then return end
    local stake   = findStake(t.stake_id)
    local bb      = (stake and stake.bb) or 1
    local palette = _paletteForStake(t.stake_id)
    local tier    = Chips.tierFromBB(amount / bb)
    local chips   = Chips.breakdown(amount, palette, tier)
    ChipFlight.emitBurst(bank_xy, { t.you_x, t.you_y }, chips,
                         { arrival_sound = "chip_land_you" })
end

function GrindController:_emitCashOutChips(t, amount)
    if not t or not t.you_x or amount <= 0 then return end
    local bank_xy = self.game.bankroll_xy
    if not bank_xy then return end
    local stake   = findStake(t.stake_id)
    local bb      = (stake and stake.bb) or 1
    local palette = _paletteForStake(t.stake_id)
    local tier    = Chips.tierFromBB(amount / bb)
    local chips   = Chips.breakdown(amount, palette, tier)
    ChipFlight.emitBurst({ t.you_x, t.you_y }, bank_xy, chips,
                         { arrival_sound = "chip_land_bankroll" })
end

function GrindController:_emitResolutionChips(r, tbl, overflow_amount)
    if not tbl or not tbl.you_x or not tbl.pot_x then return end
    local palette = _paletteForStake(tbl.stake_id)
    local you_xy  = { tbl.you_x, tbl.you_y }
    local pot_xy  = { tbl.pot_x, tbl.pot_y }

    if r.delta > 0 then
        local chips = Chips.breakdown(r.delta, palette, r.tier or "small")
        ChipFlight.emitBurst(pot_xy, you_xy, chips,
                             { arrival_sound = "chip_land_you" })
    elseif r.delta < 0 then
        local chips = Chips.breakdown(-r.delta, palette, r.tier or "small")
        -- Loss → chips fly to the winning opponent's seat (their cards).
        -- Falls back to off-screen if the panel hasn't drawn yet (first
        -- frame after table add) so the burst still has a destination.
        local target_xy
        if tbl._opp_xy and tbl.opponent_idx then
            target_xy = tbl._opp_xy[tbl.opponent_idx]
        end
        target_xy = target_xy or { pot_xy[1], love.graphics.getHeight() + 80 }
        ChipFlight.emitBurst(pot_xy, target_xy, chips,
                             { arrival_sound = "chip_land_pot" })
    end

    if overflow_amount and overflow_amount > 0 then
        local bank_xy = self.game.bankroll_xy
                        or { love.graphics.getWidth() * 0.5,
                             love.graphics.getHeight() - 30 }
        local chips = Chips.breakdown(overflow_amount, ChipData.full_palette,
                                      Chips.tierFromAmount(overflow_amount))
        ChipFlight.emitBurst(you_xy, bank_xy, chips,
                             { arrival_sound = "chip_land_bankroll" })
    end
end

-- Refill a busted table's stack to a fresh 100bb buy-in by spending from
-- bankroll. No-op if the table isn't actually busted, or if the player
-- can't afford the rebuy.
function GrindController:rebuyTable(idx)
    local t = self.pool:get(idx)
    if not t then return false end
    if (t.stack or 0) > 0 then return false end
    local stake = findStake(t.stake_id)
    local cost  = (stake and stake.buy_in) or 0
    local state = self.game.state
    if state.bankroll < cost then return false end
    state.bankroll = state.bankroll - cost
    t.stack = cost
    -- Bankroll → YOU stack chip burst (table positions are already known
    -- because the table has been on screen long enough to bust).
    self:_emitBuyInChips(t, cost)
    self:_playNamed("rebuy_clack")
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
        -- Tier-keyed pot sound: a tiny win clicks like one chip; a jackpot
        -- lands like a stack with coins layered. data/sounds.lua defines all
        -- 8 entries (4 tiers × win/loss).
        local tier = t.outcome_tier or "small"
        local key  = (t.outcome_won and "pot_won_" or "pot_lost_") .. tier
        sounds.playNamed(key)
    end
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
