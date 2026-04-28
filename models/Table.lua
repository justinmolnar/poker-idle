-- models/Table.lua
--
-- A single ticking poker table at a given stake. Stateful gameplay model —
-- holds tick timer, hands played count, and a ring buffer of recent
-- resolutions for the view to render. Math drives off `data/stakes.lua` plus
-- the player's effects context (`ctx`) passed in on update.
--
-- The view writes screen-space (x, y) onto the Table after layout each frame
-- so floating text can spawn at the table's position when a hand resolves.
-- Tables are TRANSIENT — they're rebuilt from `state.active_table_stakes` on
-- each grind-state-enter, not persisted directly.

local RNG        = require("utils.rng")
local StakesData = require("data.stakes")

local Table = {}
Table.__index = Table

local LAST_RESULTS_CAP = 5

local function findStake(id)
    for _, s in ipairs(StakesData) do
        if s.id == id then return s end
    end
end

function Table:new(stake_id)
    return setmetatable({
        stake_id      = stake_id,
        tick_timer    = 0,
        hands_played  = 0,
        last_results  = {},   -- ring of {won = bool, delta = number}, newest at end
        x             = 0,    -- view writes layout position here each frame
        y             = 0,
    }, Table)
end

function Table:setStake(stake_id)
    self.stake_id   = stake_id
    self.tick_timer = 0      -- reset cadence so the next tick respects the new rate
end

-- Tick one frame. Returns a resolution table when a hand lands this frame,
-- or nil when nothing happened. ctx is the player's computed effects rollup.
function Table:update(dt, ctx)
    local stake = findStake(self.stake_id)
    if not stake then return nil end

    local hands_per_min = stake.hands_per_min + (ctx.hands_per_min or 0)
    if hands_per_min <= 0 then hands_per_min = 1 end
    local interval = 60 / hands_per_min

    self.tick_timer = self.tick_timer + dt
    if self.tick_timer < interval then return nil end
    self.tick_timer = self.tick_timer - interval

    self.hands_played = self.hands_played + 1

    local win_rate = stake.win_rate * (ctx.vs_aggressive or 1)
    if win_rate > 0.995 then win_rate = 0.995 end

    local won = RNG.chance(win_rate)
    local delta
    if won then
        delta = stake.pot_size * (ctx.earnings_mult or 1)
    else
        delta = -stake.bet_size
    end

    self.last_results[#self.last_results + 1] = { won = won, delta = delta }
    if #self.last_results > LAST_RESULTS_CAP then
        table.remove(self.last_results, 1)
    end

    return { won = won, delta = delta, x = self.x, y = self.y }
end

-- Live effective stats for display (post-effects rollup).
function Table:liveStats(ctx)
    local stake = findStake(self.stake_id)
    if not stake then return nil end
    return {
        stake_display = stake.display_name,
        win_rate      = math.min(0.995, stake.win_rate * (ctx.vs_aggressive or 1)),
        pot_size      = stake.pot_size * (ctx.earnings_mult or 1),
        bet_size      = stake.bet_size,
        hands_per_min = math.max(1, stake.hands_per_min + (ctx.hands_per_min or 0)),
    }
end

return Table
