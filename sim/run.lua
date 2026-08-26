-- sim/run.lua
--
-- Minimal Act 1 Pacing Simulator (Phase 2)
-- Simulates Act 1 runs under a greedy buy-cheapest-first policy.
-- Outputs catalog completion %, shove win % @ T3, and elapsed time to clear.

io.stdout:setvbuf("no")
local cwd = (love and love.filesystem and love.filesystem.getWorkingDirectory()) or "."
package.path = package.path .. ";" .. cwd .. "/?.lua;" .. cwd .. "/data/?.lua;" .. cwd .. "/models/?.lua"


local Balance   = require("data.balance")
local Catalog   = require("data.catalog")
local ShoveRate = require("models.shove_rate")


local function simulateAct1()
    local owned_set = {}
    local owned_count = 0
    local total_catalog_items = Balance.ACT1_ITEM_COUNT -- 25
    local chips_banked = 0
    local elapsed_minutes = 0
    
    local chips_per_run = Balance.getChipsPerRun()
    local run_duration = Balance.RUN_MINUTES

    print("=========================================================")
    print(string.format(" Act 1 Simulation (RUN_MINUTES=%d, Target Chips/Run=%d)", run_duration, chips_per_run))
    print(" Policy: Greedy Buy-Cheapest-First")
    print("=========================================================")
    print(string.format("%-10s | %-8s | %-12s | %-12s | %-12s", "Shove", "Items", "Catalog %", "Shove @ T3", "Elapsed Time"))
    print("---------------------------------------------------------")

    local shove_number = 1
    local cleared = false

    -- Runaway guard only; the loop is meant to end on `cleared`.
    while shove_number <= 50 and not cleared do
        elapsed_minutes = elapsed_minutes + run_duration
        chips_banked = chips_banked + chips_per_run

        -- Greedy buy cheapest owned-candidate items
        local bought_any = true
        while bought_any do
            bought_any = false
            local cheapest_item = nil
            local cheapest_cost = 999999

            for _, item in ipairs(Catalog) do
                if item.phase ~= "system" and item.id ~= "unlock_ultra" then
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

        -- Calculate cumulative shove rate addition from owned catalog items
        local catalog_shove_sum = 0
        for item_id, _ in pairs(owned_set) do
            catalog_shove_sum = catalog_shove_sum + Balance.getItemShoveRate(item_id)
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
