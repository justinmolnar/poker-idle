-- models/shove_rate.lua
--
-- Pure computation of the player's current shove rate. Two sources:
-- catalog base (ctx.shove_rate, accumulated by shove_rate_add effects)
-- and a bankroll-tier multiplier (data/bankroll_tiers.lua). Single
-- source of truth; called both at-shove-time (ShoveState locks the
-- value) and live-rendering-time (top bar + SHOVE button render every
-- frame).
--
-- Formula:
--   total = catalog_base * bankroll_tier_mult
--   total = min(total, 1.0)
--
-- The 1.0 clamp is a math-reality clamp — you can't have >100% chance.
-- Past that point grinding stops paying. Catalog × max bankroll mult
-- alone won't reach 1.0 with the current numbers; the player has to
-- actively combine catalog buys + sustained bankroll grinding to push
-- toward the ceiling.

local BankrollTiers = require("data.bankroll_tiers")

local ShoveRate = {}

-- Linear walk: tier table is 9 rows. Returns the highest row whose
-- threshold ≤ bankroll. Falls back to row 1 (Sub-T1) for negatives.
local function lookupTier(bankroll)
    bankroll = bankroll or 0
    local last = BankrollTiers[1]
    for _, row in ipairs(BankrollTiers) do
        if bankroll >= row.threshold then
            last = row
        else
            break
        end
    end
    return last
end

-- Compute the current shove rate plus a breakdown table that drives
-- the hover tooltip. Pure — no globals, no side effects. Caller passes
-- the latest ctx (catalog rollup) and bankroll snapshot; ShoveRate
-- never reaches into game.state directly.
function ShoveRate.compute(ctx, bankroll)
    local base = (ctx and ctx.shove_rate) or 0
    local tier = lookupTier(bankroll or 0)
    local mult = tier.mult
    local raw  = base * mult
    local total = (raw > 1.0) and 1.0 or raw

    return total, {
        base     = base,
        tier     = tier,        -- { threshold, mult, label }
        bankroll = bankroll or 0,
        total    = total,
        clamped  = raw > 1.0,
    }
end

-- Format the breakdown into the multi-line tooltip shown on hover over
-- the top-bar SHOVE column and the SHOVE button. Returns an array of
-- strings — services/Tooltip.lua accepts arrays directly.
--
-- Lives here (not in the view) so the same lines render consistently
-- everywhere the rate is surfaced.
function ShoveRate.formatBreakdown(b)
    local lines = {
        string.format("SHOVE: %.1f%%", b.total * 100),
        string.format("Base (catalog): %.1f%%", b.base * 100),
        string.format("Bankroll $%s (%s): %d× -> %.1f%%",
            ShoveRate._formatMoney(b.bankroll), b.tier.label, b.tier.mult, b.total * 100),
    }
    if b.clamped then
        lines[#lines + 1] = "(capped at 100% — math ceiling)"
    end
    return lines
end

-- Compact money formatter for the tooltip — keeps the breakdown line
-- readable for both $24 and $1,200,000. Mirrors the convention of
-- utils/format but avoids a require on the engine layer.
function ShoveRate._formatMoney(n)
    n = n or 0
    if n >= 1000000 then return string.format("%.1fM", n / 1000000) end
    if n >= 10000   then return string.format("%.0fk", n / 1000)    end
    if n >= 1000    then return string.format("%.1fk", n / 1000)    end
    return string.format("%.2f", n)
end

return ShoveRate
