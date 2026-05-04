-- models/shove_rate.lua
--
-- Pure computation of the player's per-runout gauntlet rates. Two sources:
-- catalog base (ctx.shove_rate, accumulated by shove_rate_add effects) and
-- a bankroll-tier multiplier (data/bankroll_tiers.lua). Single source of
-- truth; called both at-shove-time (ShoveState locks the value) and live-
-- rendering-time (top bar + SHOVE button render every frame).
--
-- ─── Formula (locked, see docs/math.md) ─────────────────────────────────
--   r1 = clamp(catalog × mult)              (no cheat)
--   r2 = clamp(catalog × (mult / 2))        (cheat 1: bankroll halved)
--   r3 = clamp((catalog / 2) × (mult / 2))  (cheat 2: catalog also halved)
--   clear = r1 × r2 × r3
--
-- The 1.0 clamp is a math-reality clamp — you can't have >100% chance.
-- `clear` is what the player is actually risking when they SHOVE; it's the
-- headline number on the SHOVE button. r1/r2/r3 surface in the breakdown
-- tooltip so the player can see where the wall is (math.md: "R3 is always
-- the wall").
--
-- The two halvings are the dealer's two cheats. Diegetically: cheat 1
-- attacks your bankroll-as-tribute, cheat 2 also disqualifies your
-- catalog-as-evidence. Mechanically: they reduce different multiplicative
-- factors so each runout is structurally weaker than the last.

local BankrollTiers = require("data.bankroll_tiers")

local ShoveRate = {}

-- Walk the tier table to find the (lower, upper) bracket the player's
-- bankroll falls into. Lower defines the player's "tier badge" (label);
-- upper is the next stake's row used for interpolation.
local function lookupBracket(bankroll)
    bankroll = bankroll or 0
    local lower = BankrollTiers[1]
    local upper = nil
    for i, row in ipairs(BankrollTiers) do
        if bankroll >= row.threshold then
            lower = row
            upper = BankrollTiers[i + 1]
        else
            break
        end
    end
    return lower, upper
end

-- Log-interpolate the multiplier between two tier rows. Bankroll grows
-- exponentially (each tier is ~10× the previous), so a linear ramp would
-- spend most of the time near the lower mult. Interpolating in log-space
-- gives a perceptually smooth climb: at the geometric midpoint between
-- T1 ($2) and T2 ($25) — about $7 — mult sits at the midpoint (1.5×),
-- not at the linear midpoint ($13). Same shape applied at every tier
-- pair, so the player feels continuous progress instead of integer
-- jumps at buy-in boundaries.
local function interpolateMult(bankroll, lower, upper)
    if not upper then return lower.mult end
    if lower.mult == upper.mult then return lower.mult end
    -- Avoid log(0) for the Sub-T1 row whose threshold is 0.
    local lo_thr = math.max(0.01, lower.threshold)
    local up_thr = upper.threshold
    local b      = math.max(lo_thr, bankroll)
    local lt = math.log(lo_thr)
    local ut = math.log(up_thr)
    local bt = math.log(b)
    local frac = (bt - lt) / (ut - lt)
    if frac < 0 then frac = 0 end
    if frac > 1 then frac = 1 end
    return lower.mult + (upper.mult - lower.mult) * frac
end

local function clamp01(v)
    if v > 1.0 then return 1.0 end
    if v < 0.0 then return 0.0 end
    return v
end

local function buildRates(catalog, mult, tier)
    local raw1 = catalog * mult
    local raw2 = catalog * (mult / 2)
    local raw3 = (catalog / 2) * (mult / 2)
    local r1   = clamp01(raw1)
    local r2   = clamp01(raw2)
    local r3   = clamp01(raw3)
    return {
        catalog  = catalog,
        tier     = tier,                -- { threshold, mult, label }
        mult     = mult,
        -- Clamped values (used by the actual outcome roll — math reality
        -- can't have a probability > 1.0).
        r1       = r1,
        r2       = r2,
        r3       = r3,
        -- Raw / unclamped values for display. The headline shove % shows
        -- raw_r1 (with no 100% ceiling) so the player can see "220%"
        -- when they've grinded so hard the dealer's first cheat doesn't
        -- matter — diegetically: undeniable edge against a cheating
        -- dealer. The tooltip surfaces all three raw values for the same
        -- reason ("R3: 110% — even the second cheat won't stop me").
        raw_r1   = raw1,
        raw_r2   = raw2,
        raw_r3   = raw3,
        clear    = r1 * r2 * r3,
        clamped  = { r1 = raw1 > 1.0, r2 = raw2 > 1.0, r3 = raw3 > 1.0 },
    }
end

-- Compute the current per-runout rates plus the gauntlet clear. Pure — no
-- globals, no side effects. Caller passes the latest ctx (catalog rollup)
-- and bankroll snapshot; ShoveRate never reaches into game.state directly.
--
-- Returns a single struct so every caller walks the same shape (catalog,
-- mult, r1, r2, r3, clear, tier, bankroll, clamped). The previous two-
-- return shape (total, breakdown) was removed when the gauntlet halving
-- landed.
function ShoveRate.compute(ctx, bankroll)
    local base = (ctx and ctx.shove_rate) or 0
    local lower, upper = lookupBracket(bankroll or 0)
    local mult = interpolateMult(bankroll or 0, lower, upper)
    local rates = buildRates(base, mult, lower)
    rates.bankroll = bankroll or 0
    return rates
end

-- Synthesize a rate struct from a raw catalog base, bypassing ctx. Used by
-- the shove-mode debug hotkeys ([ / ]) which mutate the rate independently
-- of the actual catalog rollup.
function ShoveRate.computeFromBase(catalog, bankroll)
    local lower, upper = lookupBracket(bankroll or 0)
    local mult = interpolateMult(bankroll or 0, lower, upper)
    local rates = buildRates(catalog or 0, mult, lower)
    rates.bankroll = bankroll or 0
    return rates
end

-- Format the rate struct into the multi-line tooltip shown on hover over
-- the top-bar SHOVE column and the SHOVE button. Returns an array of
-- strings — services/Tooltip.lua accepts arrays directly.
--
-- Lives here (not in the view) so the same lines render consistently
-- everywhere the rate is surfaced.
-- Player-facing breakdown of the shove %. Only exposes what the player
-- knows pre-reveal: this is a single all-in hand, here's your win
-- chance and where it came from. R2/R3, the gauntlet, the dealer's
-- cheats — all of that is a diegetic surprise, NOT something the
-- tooltip should pre-spoil.
function ShoveRate.formatBreakdown(rates)
    return {
        string.format("ALL-IN: %.0f%% to win", rates.raw_r1 * 100),
        string.format("Catalog base: %.1f%%", rates.catalog * 100),
        string.format("Bankroll $%s (%s): %.1f× mult",
            ShoveRate._formatMoney(rates.bankroll),
            rates.tier.label, rates.mult),
    }
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
