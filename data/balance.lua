-- data/balance.lua
--
-- Central Balance & Pacing Engine (Phase 1)
-- Authored taste inputs and derived arithmetic.
-- Preserves hand-authored relative pricing across department shelves, while
-- deriving k and overall price scaling downstream of taste inputs.

local Balance = {}

-- ─── Locked Design Inputs ───────────────────────────────────────────────────
-- Taste parameters from docs/balance-plan.md:
Balance.TOTAL_GAME_HOURS       = 7
Balance.ACT1_HOURS             = 1.5
Balance.ACT2_HOURS             = 4
Balance.ACT3_HOURS             = 1

Balance.RUN_MINUTES            = 20
Balance.ACT1_RUNS_TO_CLEAR     = 3
Balance.ACT1_COMPLETION_AT_WIN = 0.70     -- fraction of Act 1 catalog owned at win (~18 of 25)
Balance.ACT1_SHOVE_TARGET      = 0.80     -- win chance at expected winning shove (Shove 3)
Balance.T3_MULT                = 3

Balance.ACT1_ITEM_COUNT        = 49

-- ─── Derived Math ────────────────────────────────────────────────────────────
-- Target catalog R1 contribution for Act 1 (raw1 = (catalog + deck) * mult)
Balance.CATALOG_TARGET_ACT1    = Balance.ACT1_SHOVE_TARGET / Balance.T3_MULT            -- 0.80 / 3 = 0.2666...

-- Number of items owned at expected Act 1 win
Balance.ITEMS_AT_WIN           = Balance.ACT1_ITEM_COUNT * Balance.ACT1_COMPLETION_AT_WIN  -- 25 * 0.70 = 17.5

-- Shove rate added per catalog item (k)
Balance.K_SHOVE_PER_ITEM       = Balance.CATALOG_TARGET_ACT1 / Balance.ITEMS_AT_WIN       -- 0.2666... / 17.5 = 0.015238...

--- Returns derived chip cost for an item based on its authored base cost
-- @param authored_cost integer hand-authored base chip cost
-- @return integer derived chip cost scaled by pacing
function Balance.getItemCost(authored_cost)
    if not authored_cost or authored_cost <= 0 then return 0 end

    -- Scale cost proportionally with RUN_MINUTES relative to 20-min baseline
    local time_scale = Balance.RUN_MINUTES / 20.0
    local raw_cost = authored_cost * time_scale
    return math.max(1, math.floor(raw_cost + 0.5))
end

--- Returns derived shove_rate_add for catalog items
-- Every catalog item contributes k (~0.0152)
-- @param item_id string catalog item ID
-- @return number shove rate addition
function Balance.getItemShoveRate(item_id)
    if item_id == "poker_poster" or item_id == "no_poster_handicap" or item_id == "unlock_ultra" then
        return 0
    end
    return Balance.K_SHOVE_PER_ITEM
end

--- Returns expected chips per run needed for Act 1 clear
-- @param act1_spend integer total cost of Act 1 items
-- @return integer chips per run target
function Balance.getChipsPerRun(act1_spend)
    local total_spend = act1_spend or 111
    return math.ceil((total_spend * (Balance.RUN_MINUTES / 20.0)) / Balance.ACT1_RUNS_TO_CLEAR)
end

return Balance
