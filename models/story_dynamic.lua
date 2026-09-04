-- models/story_dynamic.lua
--
-- Live numbers for the House's dialog. data/story.lua text may carry
-- {dyn:NAME} tokens; views/StoryView resolves them through this module the
-- moment a block lands, so the typewriter speaks the numbers the player's
-- game shows RIGHT NOW instead of copy frozen at authoring time ("the duel
-- runs a third" was a guess; the readout under the table is not). Every
-- handler is pcall-guarded with an English fallback: dialog must never
-- crash, and a missing number just reads as the House rounding.

local OutcomeMath = require("models.outcome_math")
local Stakes      = require("data.stakes")
local GameTypes   = require("data.game_types")
local Lookups     = require("utils.lookups")

local StoryDynamic = {}

-- The stack-band odds the EV readout under a table displays, for the
-- player's current stake at `gtype_id`: win_chance × stack band share,
-- formatted exactly like views/TablePanelStats does ("%.1f%%").
local function stackOdds(game, gtype_id)
    local stake = Lookups.findById(Stakes,
        game.state.current_stake_id or "s001")
    local gtype = Lookups.findById(GameTypes, gtype_id)
    local s = OutcomeMath.evStats(game.grind and game.grind.ctx, gtype, stake)
    local pct = (s.pool.win_chance or 0)
              * ((s.pool.win_dist and s.pool.win_dist.stack) or 0) * 100
    return string.format("%.1f%%", pct)
end

local NUMBER_WORDS = { "two", "three", "four", "five", "six",
                       "seven", "eight", "nine", "ten" }

local HANDLERS = {
    stack_odds_zoom = { fn = function(g) return stackOdds(g, "zoom") end,
                        fallback = "under a percent" },
    stack_odds_hu   = { fn = function(g) return stackOdds(g, "hu") end,
                        fallback = "about a third" },
    -- The NL2 → NL10 jump in buy-in terms, spelled out ("five"). The old
    -- copy claimed "ten times"; the ladder is data, so ask the data.
    stake_mult_s002 = { fn = function()
        local a = Lookups.findById(Stakes, "s001")
        local b = Lookups.findById(Stakes, "s002")
        local m = math.floor((b.buy_in or 0)
                  / math.max(1e-9, a.buy_in or 1) + 0.5)
        return NUMBER_WORDS[m - 1] or tostring(m)
    end, fallback = "five" },
}

-- Replace every {dyn:NAME} in `text`. Unknown names keep a visible stub
-- (never silently vanish — a typo should be seen in playtest).
function StoryDynamic.resolve(game, text)
    if not text or not text:find("{dyn:", 1, true) then return text end
    return (text:gsub("{dyn:([%w_]+)}", function(name)
        local h = HANDLERS[name]
        if not h then return "{" .. name .. "?}" end
        local ok, out = pcall(h.fn, game)
        if ok and out then return out end
        return h.fallback
    end))
end

return StoryDynamic
