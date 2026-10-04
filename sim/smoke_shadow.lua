-- sim/smoke_shadow.lua
--
-- services/TextShadow: every print and printf draws a hard shadow first,
-- offset down-right by a fraction of the font's character width, in the
-- shadow colour at the text's own alpha; the text's colour is left as it
-- was; coloured-text tables, empty strings, transparent text and suspended
-- spans get none; a call allocates nothing.
--
-- Standalone: `lua sim/smoke_shadow.lua` from the repo root.

package.path = "./?.lua;" .. package.path
local Stub = require("sim.love_stub"); Stub.base()
local c = Stub.checker()

local Cfg = require("data.text_shadow")
local calls = {}
local color = { 1, 1, 1, 1 }
local font = { getWidth = function(_, s) return 10 * #s end, getHeight = function() return 16 end }
love.graphics.getFont  = function() return font end
love.graphics.getColor = function() return color[1], color[2], color[3], color[4] end
love.graphics.setColor = function(r, g, b, a) color[1], color[2], color[3], color[4] = r, g, b, a or 1 end
love.graphics.print  = function(t, x, y) calls[#calls + 1] = { "print", t, x, y, color[1], color[2], color[3], color[4] } end
love.graphics.printf = function(t, x, y, lim, al) calls[#calls + 1] = { "printf", t, x, y, color[1], color[2], color[3], color[4], lim, al } end

local TS = require("services.TextShadow")
TS.install()
local o = math.max(Cfg.min_px, math.floor(10 * Cfg.char_frac + 0.5))

love.graphics.setColor(0.2, 0.8, 0.4, 0.5)
love.graphics.print("hello", 10, 20)
c.eq(#calls, 3 * o + 1, "a print draws the edge in pixel steps, then the text")
local s, t = calls[1], calls[#calls]
local joined = calls[1][3] == 11 and calls[1][4] == 20 and calls[2][3] == 10 and calls[2][4] == 21
c.ok(joined, "the first step touches the letters (one pixel right, one down)")
local deep = calls[3 * o]
c.ok(deep[3] == 10 + o and deep[4] == 20 + o, "and it reaches " .. o .. " px down-right")
c.ok(s[5] == Cfg.color[1] and s[6] == Cfg.color[2] and s[7] == Cfg.color[3], "in the shadow colour")
c.ok(math.abs(s[8] - 0.5 * Cfg.alpha) < 1e-9, "at the text's alpha")
c.ok(t[3] == 10 and t[4] == 20 and t[5] == 0.2 and t[8] == 0.5, "the text keeps its spot and colour")
c.ok(color[1] == 0.2 and color[4] == 0.5, "the colour is left as it was")

calls = {}
love.graphics.printf("wrapped", 0, 0, 100, "center")
c.ok(#calls == 3 * o + 1 and calls[1][9] == 100 and calls[1][10] == "center", "printf too, with its width and alignment")

calls = {}
love.graphics.setColor(0.1, 0.1, 0.12, 1)
love.graphics.print("dark", 0, 0)
c.eq(#calls, 1, "dark text gets no edge (it read as the text twice)")

calls = {}
love.graphics.print({ { 1, 0, 0 }, "red" }, 0, 0)
love.graphics.print("", 0, 0)
love.graphics.setColor(1, 1, 1, 0)
love.graphics.print("gone", 0, 0)
love.graphics.setColor(1, 1, 1, 1)
TS.suspend(); love.graphics.print("plain", 0, 0); TS.resume()
c.eq(#calls, 4, "no edge for coloured text, empty or transparent text, or a suspended span")

-- Allocation: counting stubs underneath, so only the wrapper is measured.
TS.uninstall()
local n = 0
love.graphics.print = function() n = n + 1 end
TS.install()
love.graphics.print("warm", 1, 2)
collectgarbage("collect"); collectgarbage("stop")
local before = collectgarbage("count")
for _ = 1, 1000 do love.graphics.print("tick", 1, 2) end
local grew = collectgarbage("count") - before
collectgarbage("restart")
c.ok(n == 1001 * (3 * o + 1) and grew < 1, string.format("a thousand prints allocate nothing (%.2f KB, %d draws)", grew, n))

TS.uninstall()
if c.report("smoke_shadow") > 0 then os.exit(1) end
