-- utils/format.lua
-- Number formatting helpers. Stateless.

local Format = {}

-- Abbreviated big-number formatting: 1234 → "1.2K", 4500000 → "4.5M".
-- Always shows one decimal for K and above; below 1000 returns the integer.
function Format.formatBig(n)
    if not n then return "0" end
    local sign = ""
    if n < 0 then sign, n = "-", -n end
    if n < 1000 then return sign .. tostring(math.floor(n)) end
    local units = { "K", "M", "B", "T", "Q" }
    local idx = 0
    while n >= 1000 and idx < #units do
        n = n / 1000
        idx = idx + 1
    end
    return sign .. string.format("%.1f%s", n, units[idx])
end

-- Money formatting with $ prefix and abbreviated big numbers.
function Format.money(n)
    return "$" .. Format.formatBig(n or 0)
end

-- Percentage formatting: 0.345 → "34.5%".
function Format.percent(frac, decimals)
    decimals = decimals or 1
    return string.format("%." .. decimals .. "f%%", (frac or 0) * 100)
end

return Format
