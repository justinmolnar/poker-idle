-- utils/format.lua
-- Number formatting helpers. Stateless.
--
-- Every dollar readout in the game goes through Format.money / price /
-- moneySigned so they all compact the same way: cents under $1,000, then
-- three significant figures with a magnitude suffix. Readouts FLOOR
-- toward zero, never round up, so what you read is never more than what
-- you have (a $0.4999 bankroll shows $0.49, and a "$0.50" buy it can't
-- afford never appears). Prices are already rounded to two significant
-- figures at derivation (models/UpgradePricing), so a price prints exactly.

local Format = {}

-- Thousands suffixes, one per ×1000. The chip faces in data/chips.lua
-- use the same letters so a chip and the readout above it agree.
local UNITS = { "K", "M", "B", "T", "Q", "Qi", "Sx", "Sp" }

-- Guard against "1.15 * 100 = 114.999…" flooring to 114.
local EPS = 1e-6

-- Trim "1.80" → "1.8", "46.30" → "46.3", "540.00" → "540"; leaves "540".
local function trimZeros(s)
    if not s:find("%.") then return s end
    s = s:gsub("0+$", "")
    return (s:gsub("%.$", ""))
end

-- Compact magnitude, no sign, no "$": three significant figures floored
-- toward zero, trailing zeros trimmed. 1234 → "1.23K", 46334323 →
-- "46.3M", 540000000 → "540M", 1e21 → "1Sx". Below 1000 the integer.
function Format.formatBig(n)
    if not n or n ~= n then return "0" end
    local sign = ""
    if n < 0 then sign, n = "-", -n end
    if n < 1000 then return sign .. tostring(math.floor(n + EPS)) end
    local idx = 0
    while n >= 1000 and idx < #UNITS do
        n = n / 1000
        idx = idx + 1
    end
    local s
    if n >= 100 then
        s = string.format("%d", math.floor(n + EPS))
    elseif n >= 10 then
        s = string.format("%.1f", math.floor(n * 10 + EPS) / 10)
    else
        s = string.format("%.2f", math.floor(n * 100 + EPS) / 100)
    end
    return sign .. trimZeros(s) .. UNITS[idx]
end

-- Money: "$0.49", "$535.27", "$1.23K", "$46.3M", "$540M". Cents (floored)
-- under $1,000, compact above. Negative: "-$5.00".
function Format.money(n)
    n = n or 0
    if n ~= n then n = 0 end
    local sign = n < 0 and "-$" or "$"
    local a = math.abs(n)
    if a < 1000 then
        return sign .. string.format("%.2f", math.floor(a * 100 + EPS) / 100)
    end
    return sign .. Format.formatBig(a)
end

-- Same as money; the name survives from when the two differed.
Format.moneyExact = Format.money

-- A price: money() with a whole-dollar amount's ".00" dropped, so a
-- 2-significant-figure price reads "$23", "$180", "$540M" but a small
-- one keeps its cents, "$2.30".
function Format.price(n)
    local s = Format.money(n)
    if s:sub(-3) == ".00" then s = s:sub(1, -4) end
    return s
end

-- Signed money for deltas and floaters: "+$0.07", "+$1.23K", "-$46.3M".
function Format.moneySigned(n)
    n = n or 0
    local s = Format.money(n)
    if n >= 0 then return "+" .. s end
    return s
end

-- Percentage formatting: 0.345 → "34.5%".
function Format.percent(frac, decimals)
    decimals = decimals or 1
    return string.format("%." .. decimals .. "f%%", (frac or 0) * 100)
end

return Format
