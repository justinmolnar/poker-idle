-- sim/lint_catalog_economy.lua
--
-- The book's economy, checked against data/catalog_pages.lua rules 5-8 and
-- data/balance.lua CATALOG_CHIP_BUDGET:
--
--   budget    the Act 1 shelves (no `act = 2`) and the Act 2 shelves each
--             sum to their number, ±tol, after CatalogLoader.deriveAll
--   chains    every `requires` points at a card on the same shelf or at the
--             shelf's Value Buys intro; a chain is contiguous, root first
--   ladder    down a shelf cost_chip never decreases (Value Buys too)
--   naked     every ownable card has an unlock, a requires, or is an intro
--   act flag  a gate that cannot be met before the R1 win carries `act = 2`
--             or a `mystery` (the teaser pattern: Prize Vase)
--
-- Usage:
--   lua sim/lint_catalog_economy.lua            (sums per shelf and act, then errors)
--   lua sim/lint_catalog_economy.lua --quiet    (errors only)
-- Exit code 1 on any error, so it can gate a build like the other lints.

package.path = "./?.lua;" .. package.path

local CatalogLoader = require("models.catalog_loader")
local Catalog = CatalogLoader.deriveAll(require("data.catalog"))
local Pages   = require("data.catalog_pages")
local Balance = require("data.balance")

local quiet = arg and arg[1] == "--quiet"
local errors = 0
local function err(where, msg)
    errors = errors + 1
    print(("ERROR %s: %s"):format(where, msg))
end
local function info(msg) if not quiet then print(msg) end end

local by = {}
for _, it in ipairs(Catalog) do by[it.id] = it end

-- ── pages: home shelf per id, the intros ───────────────────────────────
local home, vb = {}, nil
for _, pg in ipairs(Pages) do
    if pg.id == "value_buys" then vb = pg end
    for _, id in ipairs(pg.items or {}) do home[id] = pg end
end
local intro_of = {}                 -- shelf id -> intro id
local is_intro = {}
if vb then
    for id, sid in pairs(vb.shelf_of or {}) do intro_of[sid] = id; is_intro[id] = true end
end

-- ── budget ─────────────────────────────────────────────────────────────
local B = Balance.CATALOG_CHIP_BUDGET or {}
local sums = CatalogLoader.actSums(Catalog)
info(("Act 1 shelves: %d items, %d {chip} (budget %s ±%s)"):format(sums.act1_items, sums.act1, tostring(B.act1), tostring(B.tol)))
info(("Act 2 shelves: %d items, %d {chip} (budget %s ±%s)"):format(sums.act2_items, sums.act2, tostring(B.act2), tostring(B.tol)))
info(("whole book:    %d items, %d {chip}"):format(sums.act1_items + sums.act2_items, sums.act1 + sums.act2))
if B.act1 and math.abs(sums.act1 - B.act1) > (B.tol or 0) then
    err("budget", ("Act 1 shelves sum to %d, budget %d ±%d"):format(sums.act1, B.act1, B.tol or 0))
end
if B.act2 and math.abs(sums.act2 - B.act2) > (B.tol or 0) then
    err("budget", ("Act 2 shelves sum to %d, budget %d ±%d"):format(sums.act2, B.act2, B.tol or 0))
end

-- ── per shelf: sums, ladder, chains ────────────────────────────────────
for _, pg in ipairs(Pages) do
    local items = pg.items or {}
    local sum, prev, prev_id = 0, -1, nil
    local pos = {}
    for i, id in ipairs(items) do pos[id] = i end
    for i, id in ipairs(items) do
        local it = by[id]
        if it and CatalogLoader.isOwnable(it) then
            local c = it.cost_chip or 0
            sum = sum + c
            if c < prev then
                err("ladder " .. pg.id, ("%s (%d) sits after %s (%d); a shelf reads cheapest first"):format(id, c, prev_id, prev))
            end
            prev, prev_id = c, id
            local req = it.requires
            if req then
                local root = by[req]
                if not root then
                    err("chain " .. pg.id, ("%s requires %s, which is not in the catalog"):format(id, req))
                elseif pg.id ~= "value_buys" and req == intro_of[pg.id] then
                    -- the shelf's intro on page one: allowed, nothing to be adjacent to
                elseif home[req] ~= pg then
                    err("chain " .. pg.id, ("%s requires %s, which is on %s; a chain stays on its shelf or roots in the shelf's intro"):format(
                        id, req, home[req] and home[req].id or "no page"))
                else
                    -- contiguous, root first: the root is above, and every card
                    -- between the root and this one is in the same chain
                    local rp = pos[req]
                    if not rp or rp > i then
                        err("chain " .. pg.id, ("%s requires %s, which is listed after it; root first"):format(id, req))
                    else
                        for k = rp + 1, i - 1 do
                            local mid = by[items[k]]
                            local r = mid and mid.requires
                            local in_chain = false
                            while r do
                                if r == req then in_chain = true break end
                                r = by[r] and by[r].requires
                            end
                            if not in_chain then
                                err("chain " .. pg.id, ("%s sits between %s and %s but is not in that chain; a chain is contiguous"):format(items[k], req, id))
                                break
                            end
                        end
                    end
                end
            end
        end
    end
    info(("  %-11s %3d {chip}  %s"):format(pg.id, sum, table.concat((function()
        local t = {}
        for _, id in ipairs(items) do t[#t + 1] = ("%s %d"):format(id, by[id] and by[id].cost_chip or 0) end
        return t
    end)(), ", ")))
end

-- ── naked cards, act flags ─────────────────────────────────────────────
local ACT2_ONLY_GATE = { total_ko_wins = true, decks_unlocked_count = true, shove_r1_won = true }
for _, it in ipairs(Catalog) do
    if CatalogLoader.isOwnable(it) and not it.retired and not it.hidden then
        if not it.unlock and not it.requires and not is_intro[it.id] then
            err("naked", it.id .. " has no unlock, no requires, and is not a Value Buys intro")
        end
        local k = it.unlock and it.unlock.kind
        if k and (ACT2_ONLY_GATE[k] or k:match("^lifetime_")) and it.act ~= 2 and not it.unlock.mystery then
            err("act", ("%s gates on %s, which cannot be met before the R1 win, but is not act = 2 (or a mystery teaser)"):format(it.id, k))
        end
    end
end

print(("\n%d error%s"):format(errors, errors == 1 and "" or "s"))
os.exit(errors > 0 and 1 or 0)
