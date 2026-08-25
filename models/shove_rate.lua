-- models/shove_rate.lua
--
-- Pure computation of the player's per-runout gauntlet rates. Two sources:
-- catalog base (ctx.shove_rate, accumulated by shove_rate_add effects) and
-- a bankroll-tier multiplier (data/bankroll_tiers.lua). Single source of
-- truth; called both at-shove-time (ShoveState locks the value) and live-
-- rendering-time (top bar + SHOVE button render every frame).
--
-- ─── Formula ────────────────────────────────────────────────────────────
--   r1 = clamp((catalog + deck) × mult)   no card covers anything
--   r2 = clamp(deck × mult)               card 6 covers the catalog BASE;
--                                         deck is capped at catalog (never
--                                         more than the things you own)
--                                         until the master capstone lifts it
--   r3 = clamp(deck × mult3)              card 7 covers the MULT: mult3 is
--                                         0, or 999 once the bankroll has
--                                         underflowed (Act 3's way through)
--   clear = r1 × r2 × r3
--
-- A cheat card covers a number. Nothing is halved and nothing is zeroed
-- "forever": the multiplier is the real bankroll multiplier on every
-- runout except the one whose card is on it. Two base sources: `catalog`
-- (ctx.shove_rate, from catalog shove_rate_add effects) and `deck`
-- (ctx.shove_base, from the master deck). The master deck base is the
-- ONLY base that survives card 6, so with no master deck r2 = 0 and R2
-- is unwinnable: the Act 2 gate. R3 is unwinnable until the underflow:
-- the Act 3 gate.
--
-- The 1.0 clamp is a math-reality clamp — you can't have >100% chance.
-- `clear` is what the player is actually risking when they SHOVE; it's the
-- headline number on the SHOVE button. r1/r2/r3 surface in the breakdown
-- tooltip so the player can see where the wall is (math.md: "R3 is always
-- the wall").
--
-- The two cards are the dealer's two cheats. Diegetically: card 6 covers
-- your catalog-as-evidence, card 7 covers your bankroll-as-tribute. The
-- underflow is the bankroll multiplier itself wrapping to 999: it applies
-- to every runout, and R3's covered mult comes out from under the card as
-- that same 999.

local BankrollTiers = require("data.bankroll_tiers")
local Constants     = require("data.constants")

-- Hard ceiling on r1 (the headline shove%). At 1.0 the player would
-- be guaranteed to win runout 1, which trivializes the all-in moment;
-- the cap is a "math reality" lie — they're never literally 100% to
-- win because the dealer always has SOME chance. 0.99 is the highest
-- we'll display.
local R1_DISPLAY_CAP = 0.99

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

local function buildRates(catalog, deck, mult, tier, mult3)
    -- catalog base wins R1; the master-deck base survives card 6; card 7
    -- covers the mult on R3 (mult3: 0, or 999 after the underflow).
    local raw1 = (catalog + deck) * mult
    local raw2 = deck * mult
    local raw3 = deck * (mult3 or 0)
    local r1   = clamp01(raw1)
    local r2   = clamp01(raw2)
    local r3   = clamp01(raw3)
    -- Demo builds hard-gate R2 to a loss: the prototype IS runout 1, and
    -- win-R1/lose-R2 is the deterministic cliffhanger the end-of-demo
    -- modal hangs off. Full builds keep the real formula — the dealer's
    -- cheats HALVE the factors, they don't nullify them, so a deeply
    -- overshot player (raw_r1 ≥ 200% / 400%) genuinely beats cheat 1 /
    -- cheat 2. Zeroing these universally made the full game unwinnable.
    if Constants.FEATURES and Constants.FEATURES.DEMO_CUT then
        r2 = 0
        r3 = 0
    end

    -- Demo-cut only: cap r1 + raw_r1 to 99% so the headline shove%
    -- never reads 100% / overshoot during the prototype build. Outside
    -- the demo, raw_r1 stays uncapped so a deeply-grinded player can
    -- read "220%" / "350%" — the "undeniable edge against a cheating
    -- dealer" reading. r1 (the actual outcome roll) is still clamped
    -- to 1.0 by clamp01 above; the math reality stands either way.
    if Constants.FEATURES and Constants.FEATURES.DEMO_CUT then
        if raw1 > R1_DISPLAY_CAP then raw1 = R1_DISPLAY_CAP end
        if r1   > R1_DISPLAY_CAP then r1   = R1_DISPLAY_CAP end
    end
    return {
        catalog  = catalog,
        deck     = deck,                -- master-deck base (ctx.shove_base)
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
    local deck = (ctx and ctx.shove_base) or 0
    -- The deck can never be worth more than the things you own: it is a
    -- copy of your base that survives the sixth card, not a second base.
    -- 25 deck levels against 18 items is a deck worth 18. The master deck's
    -- capstone removes the limit and doubles it.
    if ctx and ctx.shove_base_double then
        deck = deck * 2
    elseif deck > base then
        deck = base
    end
    local lower, upper = lookupBracket(bankroll or 0)
    local mult = interpolateMult(bankroll or 0, lower, upper)

    -- Card 7 covers the multiplier on R3 only (mult3 = 0). R1 and R2 keep
    -- the real multiplier in every act; zeroing it globally used to make
    -- R1 unwinnable the moment Act 3 began. The underflow is the
    -- multiplier wrapping to 999 for every runout, R3's included.
    local mult3 = 0
    if ShoveRate.underflowed(bankroll) then
        mult  = 999
        mult3 = 999
    end

    local rates = buildRates(base, deck, mult, lower, mult3)
    rates.mult3 = mult3
    rates.bankroll = bankroll or 0
    return rates
end

-- How far the bankroll has bled toward the underflow, 0..1.
--
-- LOG scale, and that is a design call rather than a convenience. The
-- threshold is -100,000,000,000; on a linear scale a player who has lost ten
-- million dollars sits at 0.01% and the bar looks broken for hours. Orders of
-- magnitude move at a readable pace the whole way down.
--
-- Because a log bar overstates early progress, the readout that draws it must
-- also print the real figures -- the bar is the pacing, the numbers are the
-- truth.
--
-- Lives here because this module already owns the threshold read (see the Act
-- 3 branch in compute), so there is one place that knows what underflow means.
function ShoveRate.underflowProgress(bankroll)
    local threshold = Constants.GAMEPLAY.UNDERFLOW_THRESHOLD or -100000000000
    bankroll = bankroll or 0
    if bankroll >= 0 or threshold >= 0 then return 0 end
    -- log10 of a debt under $1 is negative; the clamp is what catches it.
    local p = math.log(-bankroll, 10) / math.log(-threshold, 10)
    if p ~= p then return 0 end                      -- NaN guard
    return math.max(0, math.min(1, p))
end

-- True once the bankroll has fallen past the threshold. Single source of
-- truth: views/ShoveView reads this rather than re-deriving the comparison.
function ShoveRate.underflowed(bankroll)
    local threshold = Constants.GAMEPLAY.UNDERFLOW_THRESHOLD
    return threshold ~= nil and (bankroll or 0) < threshold
end

-- Synthesize a rate struct from a raw catalog base, bypassing ctx. Used by
-- the shove-mode debug hotkeys ([ / ]) which mutate the rate independently
-- of the actual catalog rollup.
function ShoveRate.computeFromBase(catalog, bankroll)
    local lower, upper = lookupBracket(bankroll or 0)
    local mult = interpolateMult(bankroll or 0, lower, upper)
    -- Debug-only synthesis from a raw catalog base; no deck base.
    local rates = buildRates(catalog or 0, 0, mult, lower, 0)
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
    -- Reading order: inputs first (small), takeaway last (md). No color
    -- override on the total — it inherits the tooltip's default heading
    -- color, which keeps it consistent with the top-bar SHOVE cell that
    -- already paints the % red/amber/green from rate_color.
    -- The base is a COUNT of things: every catalog item is one, and the
    -- master deck's base is worth some number of them. Never a percent.
    local per = 0.01
    local lines = {
        { text = string.format("Things you own: %d", math.floor((rates.catalog or 0) / per + 0.5)), style = "sm" },
    }
    -- The deck line exists only once the master deck is contributing. Before
    -- that the only base there is is the count of things you own; a "Deck: 0"
    -- row would reveal the subversion (a base that survives the sixth card)
    -- before the player has any reason to know a second base exists.
    if (rates.deck or 0) > 0 then
        lines[#lines + 1] = { text = string.format("Deck: %d", math.floor((rates.deck or 0) / per + 0.5)), style = "sm" }
    end
    lines[#lines + 1] = { text = string.format("Bankroll Mult: %.1f×", rates.mult),         style = "sm" }
    lines[#lines + 1] = { text = string.format("ALL-IN: %.0f%% to win", rates.raw_r1 * 100), style = "md" }
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
