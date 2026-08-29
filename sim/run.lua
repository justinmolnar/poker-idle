-- sim/run.lua
--
-- Minimal Act 1 Pacing Simulator (Phase 2)
-- Simulates Act 1 runs under a greedy buy-cheapest-first policy.
-- Outputs catalog completion %, shove win % @ T3, and elapsed time to clear.

io.stdout:setvbuf("no")
local cwd = (love and love.filesystem and love.filesystem.getWorkingDirectory()) or "."
package.path = package.path .. ";" .. cwd .. "/?.lua;" .. cwd .. "/data/?.lua;" .. cwd .. "/models/?.lua"


local CatalogLoader = require("models.catalog_loader")
CatalogLoader.deriveAll(require("data.catalog"))
local Balance   = require("data.balance")
local Catalog   = require("data.catalog")
local ShoveRate = require("models.shove_rate")


local function simulateAct1()
    local owned_set = {}
    local owned_count = 0
    local total_catalog_items = Balance.ACT1_ITEM_COUNT -- 25
    local chips_banked = 0
    local elapsed_minutes = 0
    
    -- Income model: bounties are the chip source — one per (stake, gtype)
    -- per run, at the stake's chip_award. An Act 1 run plays the first
    -- three stakes across ~3 lanes (zoom, HU, and eventually the bought
    -- 6-max — nobody sweeps every combo every run), so the base is
    -- sum(first 3 awards) × 3, and the Fight Night poster doubles the HU
    -- lane once owned. This replaces the old CatalogLoader.chipsPerRun
    -- target, which was circular — it assumed income equals whatever the
    -- spend requires.
    local Stakes = require("data.stakes")
    local act1_award = 0
    for i = 1, math.min(3, #Stakes) do
        act1_award = act1_award + (Stakes[i].chip_award or 0)
    end
    local run_duration = Balance.RUN_MINUTES

    print("=========================================================")
    print(string.format(" Act 1 Simulation (RUN_MINUTES=%d, Base Chips/Run=%d)", run_duration, act1_award * 3))
    print(" Policy: Greedy Buy-Cheapest-First")
    print("=========================================================")
    print(string.format("%-10s | %-8s | %-12s | %-12s | %-12s", "Shove", "Items", "Catalog %", "Shove @ T3", "Elapsed Time"))
    print("---------------------------------------------------------")

    local shove_number = 1
    local cleared = false

    -- Runaway guard only; the loop is meant to end on `cleared`.
    while shove_number <= 50 and not cleared do
        elapsed_minutes = elapsed_minutes + run_duration
        -- Two flat lanes (zoom + 6-max) and an HU lane the Fight Night
        -- poster doubles.
        local hu_lane = owned_set["fight_night"] and 2 or 1
        local chips_per_run = act1_award * (2 + hu_lane)
        chips_banked = chips_banked + chips_per_run

        -- Greedy buy cheapest owned-candidate items
        local bought_any = true
        while bought_any do
            bought_any = false
            local cheapest_item = nil
            local cheapest_cost = 999999

            for _, item in ipairs(Catalog) do
                -- Honest shelf: stat-gated items sit behind counters an
                -- Act 1 run never reaches (a gate under ~25 is hit inside
                -- act 1 and counts as open), and a requires-chain link is
                -- only buyable once its base is owned — same rules the
                -- game enforces (GrindController:1602, GameState:808).
                local gate_open = not item.unlock
                                  or (item.unlock.threshold or 0) <= 25
                if CatalogLoader.isOwnable(item)
                   and gate_open
                   and (not item.requires or owned_set[item.requires]) then
                    if not owned_set[item.id] then
                        local cost = item.cost_chip or 0
                        if cost <= chips_banked and cost < cheapest_cost then
                            cheapest_cost = cost
                            cheapest_item = item
                        end
                    end
                end
            end

            if cheapest_item then
                chips_banked = chips_banked - cheapest_cost
                owned_set[cheapest_item.id] = true
                owned_count = owned_count + 1
                bought_any = true
            end
        end

        -- Calculate cumulative shove rate addition from owned catalog items.
        -- Only ownable ones ever land in owned_set (the buy loop above uses
        -- the same test), so this is the flat rate per item.
        local catalog_shove_sum = 0
        for _, item in ipairs(Catalog) do
            if owned_set[item.id] then
                catalog_shove_sum = catalog_shove_sum + CatalogLoader.itemShoveRate(item)
            end
        end

        -- Calculate R1 shove win percentage at T3 (multiplier = 3)
        local rates = ShoveRate.computeFromBase(catalog_shove_sum, 100)


        local catalog_pct = (owned_count / total_catalog_items) * 100.0
        local shove_pct = rates.r1 * 100.0

        print(string.format("Shove %-4d | %-8d | %-11.1f%% | %-11.1f%% | %.1f mins",
            shove_number, owned_count, catalog_pct, shove_pct, elapsed_minutes))

        if rates.r1 >= Balance.ACT1_SHOVE_TARGET then
            cleared = true
        end

        shove_number = shove_number + 1
    end

    print("---------------------------------------------------------")
    if cleared then
        print(string.format("Act 1 Cleared in %.1f minutes (%d runs)!", elapsed_minutes, shove_number - 1))
    else
        print("Act 1 not cleared within max shoves.")
    end
    print("=========================================================")
end

simulateAct1()
